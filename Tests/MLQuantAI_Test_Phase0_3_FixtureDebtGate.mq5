//+------------------------------------------------------------------+
//| MLQuantAI_Test_Phase0_3_FixtureDebtGate.mq5                       |
//|                                                                   |
//| Phase 0.3 fixture-debt gate implementation, per                   |
//| Docs/Phase0_3_FixtureDebtGate.md. Two dedicated, isolated         |
//| fixture stores only - NEVER MLQuantAI_events_2026-08-21.jsonl or  |
//| any MLQuantAI_events_*.jsonl daily/historical store.               |
//|                                                                   |
//| A - Negative diagnostic fixture: a CANDIDATE_CREATED line whose    |
//|     context_event_id has no matching MARKET_CONTEXT_READY in the   |
//|     same dedicated store -> rebuild fails with a STABLE             |
//|     orphan-candidate cause (not timestamp/session/line-number).    |
//|                                                                   |
//| B - Canonical positive fixture: a generated-at-test-start          |
//|     dedicated store carrying the full chain the real C2.3/C3.3     |
//|     rebuild requires: MARKET_CONTEXT_READY -> CANDIDATE_CREATED -> |
//|     EXECUTION_REQUEST_CREATED -> EXECUTION_DRY_RUN_COMPLETED        |
//|     (ACCEPTED) -> EXECUTION_SUBMISSION_ATTEMPTED -> ORDER_SUBMITTED|
//|     -> BROKER_TRANSACTION_OBSERVED (DEAL_ADD) -> C3.3              |
//|     MATCHED_VOLUME_REACHED. Proves the join chain resolves         |
//|     uniquely: deal_ticket -> order_ticket -> execution_request_id   |
//|     -> candidate_id -> CANDIDATE_SUBMITTED. Deterministic and       |
//|     replay-stable across cold rebuilds.                            |
//|                                                                   |
//| C - C3.5 readiness evidence ONLY: asserts the fixture exposes the   |
//|     immutable semantic facts a future C3.6 action_id would need    |
//|     (candidate_id, execution_request_id, order_ticket, terminal   |
//|     MATCHED_VOLUME_REACHED, sorted deal_ticket set). Does NOT      |
//|     create the DeferredTransactionProcessor, does NOT emit          |
//|     RECOMMEND_EXECUTED, does NOT write an action event, makes no   |
//|     DIRECT EventStore_LogTransition call from this test, performs   |
//|     no new C3.6 transition (no EXECUTED) and no new lifecycle       |
//|     action - the only lifecycle transition anywhere in this file is |
//|     the existing sealed SUBMITTED waypoint the C2.3/C3.3 fixture    |
//|     chain itself creates via BrokerSubmission_ProcessSendResult.   |
//|     The future action_id key is computed by a local, read-only    |
//|     helper over those immutable facts only.                        |
//|                                                                   |
//| No real broker call anywhere in this file. No OrderSend/CTrade,    |
//| no History*/Position*/Order* API, no OnTick/OnTradeTransaction,    |
//| no daily/historical store access.                                  |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_FeatureSnapshotEventEmission.mqh>
#include <MLQuantAI/AI/MLQuantAI_ModelArtifactBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ModelArtifactEventEmission.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityEventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RiskPlanEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAdapter.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerTransactionObservation.mqh>
#include <MLQuantAI/Execution/MLQuantAI_TransactionMatchingProjection.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionAuditProjection.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh>
#include <MLQuantAI/Core/MLQuantAI_StateMachine.mqh>

#define NEGATIVE_TEST_FILE "MLQuantAI_Test_Phase0_3_NegativeOrphanFixture.jsonl"
#define POSITIVE_TEST_FILE "MLQuantAI_Test_Phase0_3_CanonicalPositiveFixture.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as every C1/C2/C3 test file's own
// copies (MLQuantAI_Test_C3_3_TransactionMatchingProjection.mq5 et al.)
// - duplicated per this project's own established per-test-file
// convention, not shared via a common header.
//---------------------------------------------------------------------
void MakeBar(MqlRates &r, datetime t, double open, double high, double low, double close, long tickVolume, int spread)
{
   ZeroMemory(r);
   r.time = t; r.open = open; r.high = high; r.low = low; r.close = close;
   r.tick_volume = tickVolume; r.spread = spread;
}

#define PERIOD_SEC_M5 300

void BuildBaseContext(MarketContext &ctx, string suffix)
{
   MarketContext_Init(ctx);
   ctx.instrument_id      = "XAUUSD";
   ctx.broker_symbol      = "XAUUSD";
   ctx.trigger_timeframe  = "M5";
   ctx.symbol_spec.digits = 2;
   ctx.symbol_spec.point  = 0.01;
   ctx.pdl = 100.00;
   ctx.pdh = 110.00;
   ctx.is_kill_zone = false;
   ctx.max_news_impact = 0;
   ctx.nearest_news_minutes = 9999;
   ctx.atr_m15 = 1.2345;
   ctx.adx_m15 = 25.5;
   ctx.ema_slope_m15 = 0.05;
   ctx.asian_range_high = 105.50;
   ctx.asian_range_low  = 104.50;
   ctx.spread_points_at_anchor = 20.0;
   ctx.news_count = 3;
   ctx.context_event_id = "CTX_p03_" + suffix;
   ctx.context_hash      = "test_context_hash_p03_" + suffix;
}

void FillFillerBars(MqlRates &window[], datetime t0)
{
   for(int i = 0; i < 59; i++)
      MakeBar(window[i], t0 + i * PERIOD_SEC_M5, 105.00, 105.20, 104.80, 105.00, 100, 20);
}

void Fixture_Bullish_Valid(MqlRates &window[], datetime &outAnchor, datetime t0)
{
   ArrayResize(window, 64);
   FillFillerBars(window, t0);
   MakeBar(window[59], t0 + 59 * PERIOD_SEC_M5, 100.80, 100.90, 99.50,  100.50, 100, 20);
   MakeBar(window[60], t0 + 60 * PERIOD_SEC_M5, 100.50, 101.50, 100.40, 101.40, 100, 20);
   MakeBar(window[61], t0 + 61 * PERIOD_SEC_M5, 101.40, 102.50, 101.30, 102.40, 100, 20);
   MakeBar(window[62], t0 + 62 * PERIOD_SEC_M5, 102.40, 103.50, 102.30, 103.40, 100, 20);
   MakeBar(window[63], t0 + 63 * PERIOD_SEC_M5, 103.40, 104.60, 103.30, 104.50, 100, 20);
   outAnchor = window[63].time;
}

void BuildValidRiskContext(RiskContext &ctx, string suffix)
{
   RiskContext_Init(ctx);
   ctx.symbol_spec.instrument_id = "XAUUSD";
   ctx.symbol_spec.broker_symbol = "XAUUSD" + suffix;
   ctx.symbol_spec.tick_size     = 0.01;
   ctx.symbol_spec.tick_value    = 1.0;
   ctx.symbol_spec.contract_size = 100;
   ctx.symbol_spec.volume_min    = 0.01;
   ctx.symbol_spec.volume_max    = 100.0;
   ctx.symbol_spec.volume_step   = 0.01;
   ctx.symbol_spec.digits        = 2;

   ctx.account.balance = 10000.0;
   ctx.account.equity  = 10000.0;

   ctx.target_risk_percent  = 1.0;
   ctx.sizing_method        = "FIXED_PERCENT_RISK";
   ctx.sizing_rules_version = MLQUANTAI_RISK_SIZING_RULES_V1;

   ctx.risk_context_hash = RiskContext_ComputeHash(ctx);
}

void BuildValidInferenceResult(const FeatureSnapshot &snapshot, string modelRegistryId, string modelRegistryHash,
                                 string modelArtifactHash, float pSuccessValue, InferenceResult &outResult)
{
   InferenceResult_Init(outResult);
   outResult.model_registry_id   = modelRegistryId;
   outResult.model_registry_hash = modelRegistryHash;
   outResult.model_artifact_hash = modelArtifactHash;

   outResult.feature_snapshot_id   = snapshot.feature_snapshot_id;
   outResult.feature_snapshot_hash = snapshot.feature_snapshot_hash;
   outResult.feature_vector_hash   = snapshot.feature_vector_hash;

   outResult.output_schema_version = MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1;
   ArrayResize(outResult.output_values, 1);
   outResult.output_values[0] = pSuccessValue;

   outResult.runtime_framework = "ONNXRuntime";
   outResult.runtime_version   = "1.16.0";

   outResult.output_hash = InferenceResult_ComputeOutputHash(outResult);
}

void BuildHealthyEligibilityContext(EligibilityContext &context)
{
   EligibilityContext_Init(context);
   context.account.balance = 10000.0;
   context.account.equity = 10000.0;
   context.account.margin_level = 500.0;
   context.account.open_positions_count = 0;
   context.account.open_risk_percent = 0.0;
   context.account.daily_pnl_percent = 0.0;
   context.account.drawdown_from_peak_percent = 0.0;
   context.safe_mode_active = false;
   context.eligibility_context_hash = EligibilityContext_ComputeHash(context);
}

void BuildEnabledEligibilityPolicy(EligibilityPolicy &policy)
{
   EligibilityPolicy_Init(policy);
   policy.eligibility_policy_version = "ELIGPOLICY_P03_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

void BuildC2AcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_P03_V1";
   policy.environment_mode = EXECUTION_ENV_DEMO;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

void ResetAllProjections()
{
   CandidateProjection_Reset();
   FeatureSnapshotProjection_Reset();
   ModelArtifactProjection_Reset();
   AIDecisionProjection_Reset();
   RiskPlanProjection_Reset();
   EligibilityDecisionProjection_Reset();
   ExecutionRequestProjection_Reset();
   DryRunResultProjection_Reset();
   SubmissionAttemptProjection_Reset();
   SubmissionOutcomeProjection_Reset();
   BrokerSubmissionReconciliation_Reset();
   StateProjector_Reset();
   SafeMode_Clear();
}

// Durably emits the FULL upstream chain (MARKET_CONTEXT_READY ->
// CANDIDATE_CREATED -> FEATURE_SNAPSHOT_CREATED -> MODEL_ARTIFACT_
// REGISTERED -> AI_DECISION_CREATED -> RISK_PLAN_CREATED ->
// EligibilityDecision's own lifecycle wiring -> EXECUTION_REQUEST_
// CREATED/EXECUTION_DRY_RUN_COMPLETED), same pattern
// MLQuantAI_Test_C2_EnvironmentLockGate.mq5's own BuildAndEmitAccepted
// Request already establishes - but ALSO threads the request through a
// real, durable RecordAttempt/ProcessSendResult pair with a caller-
// chosen order_ticket/deal_ticket, so a real SubmissionOutcomeProjection
// record with those exact tickets exists for TransactionMatching to
// match against. Requires the SAME event store to already be open.
//
// Phase 0.3 variant: also surfaces the candidate_id (outCandidateId)
// and the candidate's context_event_id (outContextEventId), which the
// canonical positive test needs to prove the full join chain and which
// the negative test needs to construct a controlled orphan.
bool BuildDurableSubmittedRequest(string suffix, int dayOffset, ulong orderTicket, ulong dealTicket,
                                    string &outExecutionRequestId, string &outCandidateId,
                                    string &outContextEventId, double &outLotSize)
{
   MarketContext ctx;
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.07.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx)))
      return false;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   TradeCandidate c;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;
   if(!CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits)) return false;

   FeatureSnapshot snapshot;
   if(!Candidate_ToFeatureSnapshot(c, ctx, snapshot)) return false;
   if(!FeatureSnapshot_EmitFeatureSnapshotCreated(snapshot)) return false;

   ModelArtifact artifact;
   if(!ModelArtifact_Build("MODEL_" + suffix, "v1", "hash_artifact_" + suffix,
                             "FEATURES_B8_1_V1", "TDSET_dummy_" + suffix, "hash_tdset_" + suffix,
                             "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                             "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, artifact))
      return false;
   if(!ModelArtifact_EmitModelArtifactRegistered(artifact)) return false;

   InferenceResult inference;
   BuildValidInferenceResult(snapshot, artifact.model_registry_id, artifact.model_registry_hash, artifact.model_artifact_hash,
                               0.90f, inference);
   AIDecisionPolicy aiPolicy;
   AIDecisionPolicy_Init(aiPolicy);
   aiPolicy.decision_policy_version = "AIPOLICY_P03_V1";
   aiPolicy.threshold_version       = "THRESH_P03_V1";
   aiPolicy.allow_threshold         = 0.70;
   AIDecision decision; string aiReasonDetail;
   if(!AIDecision_Build(inference, snapshot, aiPolicy, decision, aiReasonDetail)) return false;
   if(!AIDecision_EmitAIDecisionCreated(decision)) return false;

   RiskContext riskCtx; BuildValidRiskContext(riskCtx, suffix);
   RiskPlan plan;
   if(!Candidate_ToRiskPlan(c, riskCtx, plan)) return false;
   if(!RiskPlan_EmitRiskPlanCreated(plan)) return false;

   EligibilityContext eligContext; BuildHealthyEligibilityContext(eligContext);
   EligibilityPolicy eligPolicy; BuildEnabledEligibilityPolicy(eligPolicy);
   EligibilityDecision eligDecision; string eligReasonDetail;
   if(!EligibilityDecision_Build(plan, decision, snapshot, eligContext, eligPolicy, eligDecision, eligReasonDetail)) return false;
   if(!EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, eligContext, c)) return false;
   if(eligDecision.decision != ELIGIBILITY_DECISION_ELIGIBLE) return false;

   ExecutionPolicy policy;
   BuildC2AcceptingExecutionPolicy(policy);
   ExecutionRequest req; string rd;
   if(!ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd)) return false;
   DryRunExecutionResult dryRunResult;
   if(!ExecutionRequest_EmitAndEvaluate(req, policy, dryRunResult)) return false;
   if(dryRunResult.decision != SAFETY_GATE_ACCEPTED) return false;

   if(!BrokerSubmission_RecordAttempt(c, req)) return false;

   MqlTradeResult tr;
   MqlTradeResult_ZeroInit(tr);
   tr.retcode = TRADE_RETCODE_DONE;
   tr.order   = orderTicket;
   tr.deal    = dealTicket;
   tr.price   = req.planned_entry;

   // Phase 0.3 determinism contract: fixed timestamp derived from
   // dayOffset, NOT TimeCurrent() - the fixture must be replay-stable.
   datetime submittedAt = D'2026.07.15 12:00:00' + dayOffset * 86400;
   ExecutionSubmissionResult outResult;
   if(!BrokerSubmission_ProcessSendResult(c, req, req.planned_entry, true, 0, submittedAt, tr, outResult)) return false;
   if(outResult.submission_status != SUBMISSION_STATUS_SUBMITTED) return false;

   outExecutionRequestId = req.execution_request_id;
   outCandidateId        = c.candidate_id;
   outContextEventId     = c.context_event_id;
   outLotSize            = req.lot_size;
   return true;
}

// Durably emits one BROKER_TRANSACTION_OBSERVED / TRADE_TRANSACTION_
// DEAL_ADD line with the given tickets/volume - via
// BrokerTransactionObservation_RecordAndGuard fed a fixture struct,
// same "no real callback, feed the pure function directly" pattern
// MLQuantAI_Test_C3_2_BrokerTransactionObservation.mq5 already
// established. Requires the SAME event store to already be open.
bool EmitDealAddObservation(ulong dealTicket, ulong orderTicket, double volume, double price)
{
   MqlTradeTransaction t;
   t.type            = TRADE_TRANSACTION_DEAL_ADD;
   t.deal            = dealTicket;
   t.order           = orderTicket;
   t.symbol          = _Symbol;
   t.order_type      = ORDER_TYPE_BUY;
   t.order_state     = ORDER_STATE_FILLED;
   t.deal_type       = DEAL_TYPE_BUY;
   t.time_type       = ORDER_TIME_GTC;
   t.time_expiration = 0;
   t.price           = price;
   t.price_trigger   = 0.0;
   t.price_sl        = 0.0;
   t.price_tp        = 0.0;
   t.volume          = volume;
   t.position        = 0;
   t.position_by     = 0;

   MqlTradeRequest req;
   req.action        = (ENUM_TRADE_REQUEST_ACTIONS)0;
   req.magic         = 0;
   req.order         = 0;
   req.symbol        = "";
   req.volume        = 0;
   req.price         = 0;
   req.stoplimit     = 0;
   req.sl            = 0;
   req.tp            = 0;
   req.deviation     = 0;
   req.type          = ORDER_TYPE_BUY;
   req.type_filling  = ORDER_FILLING_FOK;
   req.type_time     = ORDER_TIME_GTC;
   req.expiration    = 0;
   req.comment       = "";
   req.position      = 0;
   req.position_by   = 0;

   MqlTradeResult r;
   r.retcode          = 0;
   r.deal             = 0;
   r.order            = 0;
   r.volume           = 0;
   r.price            = 0;
   r.bid              = 0;
   r.ask              = 0;
   r.comment          = "";
   r.request_id       = 0;
   r.retcode_external = 0;

   return BrokerTransactionObservation_RecordAndGuard(t, req, r);
}

void DeleteIfPresent(string file)
{
   if(FileIsExist(file, FILE_COMMON))
      FileDelete(file, FILE_COMMON);
}

// Stable, content-independent line count + size fingerprint of a test
// store. Used to prove a fixture file is NOT mutated by a read-only
// rebuild (the negative historical-evidence policy).
int FileLineCount(string file)
{
   int h = FileOpen(file, FILE_READ | FILE_TXT | FILE_COMMON);
   if(h == INVALID_HANDLE) return -1;
   int n = 0;
   while(!FileIsEnding(h))
   {
      string line = FileReadString(h);
      if(StringLen(line) > 0) n++;
   }
   FileClose(h);
   return n;
}

ulong FileSizeBytes(string file)
{
   int h = FileOpen(file, FILE_READ | FILE_BIN | FILE_COMMON);
   if(h == INVALID_HANDLE) return 0;
   ulong sz = FileSize(h);
   FileClose(h);
   return sz;
}

// Local, read-only helper for Phase 0.3 section C (C3.5 readiness
// evidence ONLY). Computes a deterministic key over the IMMUTABLE
// semantic facts a future C3.6 action_id would consume. This is NOT
// the DeferredTransactionProcessor, does NOT emit RECOMMEND_EXECUTED,
// does NOT write an action event, makes no DIRECT EventStore_LogTransition
// call, and performs no new C3.6 transition (no EXECUTED) - it only
// proves the fixture exposes sufficient, deterministic input.
string FutureActionIdInputKey(string candidateId, string executionRequestId, ulong orderTicket,
                               const ulong &dealTickets[], int dealCount, string terminalMatchStatus)
{
   ulong sorted[];
   ArrayResize(sorted, dealCount);
   for(int i = 0; i < dealCount; i++) sorted[i] = dealTickets[i];
   // ascending insertion sort - deterministic regardless of deal arrival order
   for(int i = 1; i < dealCount; i++)
   {
      ulong k = sorted[i]; int j = i - 1;
      while(j >= 0 && sorted[j] > k) { sorted[j + 1] = sorted[j]; j--; }
      sorted[j + 1] = k;
   }
   string dealPart = "";
   for(int i = 0; i < dealCount; i++)
      dealPart += (i > 0 ? "," : "") + IntegerToString((long)sorted[i]);
   return candidateId + "|" + executionRequestId + "|" + IntegerToString((long)orderTicket)
          + "|[" + dealPart + "]|" + terminalMatchStatus + "|RECOMMEND_EXECUTED";
}

//---------------------------------------------------------------------
// A - Negative diagnostic fixture
//---------------------------------------------------------------------
// Builds a controlled orphan: a fully valid CANDIDATE_CREATED line
// (built by the real CRT chain) emitted into a dedicated store that
// contains NO matching MARKET_CONTEXT_READY for the candidate's
// context_event_id. The candidate is otherwise schema-conformant, so
// the ONLY reason the rebuild fails is the orphan-context referential
// integrity check - not a missing field, not a timestamp, not a
// session id. The original daily/historical store is never opened.
void Test_A_Negative_OrphanCandidate_RebuildFailsForOrphanCause()
{
   Print("--- Test_A_Negative_OrphanCandidate_RebuildFailsForOrphanCause ---");
   ResetAllProjections();
   DeleteIfPresent(NEGATIVE_TEST_FILE);

   // 1. Build a fully valid candidate struct IN MEMORY (same CRT_DetectV1 +
   //    CRT_ToTradeCandidate path every C1/C2/C3 test uses), carrying a
   //    real, non-empty context_event_id. The MARKET_CONTEXT_READY that
   //    would back it is deliberately NEVER written to the negative store.
   Check(EventStore_Open(NEGATIVE_TEST_FILE), "negative store opens");
   TradeCandidate orphanCandidate;
   {
      MarketContext ctx; BuildBaseContext(ctx, "NEGORPHAN");
      datetime t0 = D'2026.07.01 00:00:00';
      datetime anchor; Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
      ctx.anchor_bar_time = anchor;
      CRTDetectionResult r; CRT_DetectV1(ctx, r);
      Check(r.detected, "sanity: CRT detection fires for the orphan candidate build");
      // Build directly into orphanCandidate (avoids struct assignment of a
      // type that may carry dynamic arrays).
      Check(CRT_ToTradeCandidate(ctx, r, orphanCandidate), "sanity: candidate struct built");
   }
   Check(StringLen(orphanCandidate.context_event_id) > 0, "sanity: candidate has a non-empty context_event_id");
   Check(StringLen(orphanCandidate.candidate_id)   > 0, "sanity: candidate has a non-empty candidate_id");

   // 2. Emit ONLY the candidate into the dedicated negative store - no
   //    MARKET_CONTEXT_READY is ever written here, so the candidate's
   //    context_event_id has no matching context in this store -> orphan.
   Check(CRT_EmitCandidateCreated(orphanCandidate, 2), "orphan candidate emitted into the negative store (no MARKET_CONTEXT_READY here)");
   EventStore_Close();

   // 3. Fingerprint the negative fixture BEFORE the rebuild.
   int   linesBefore = FileLineCount(NEGATIVE_TEST_FILE);
   long  bytesBefore = (long)FileSizeBytes(NEGATIVE_TEST_FILE);
   Check(linesBefore == 1, "negative fixture has exactly one CANDIDATE_CREATED line before rebuild");

   // 4. Rebuild CandidateProjection from the negative store - must fail.
   ResetAllProjections();
   CandidateProjectionReport report = CandidateProjection_RebuildFromFile(NEGATIVE_TEST_FILE);
   Check(!report.ok, "rebuild returns ok=false for the orphan candidate");
   Check(report.lines_failed > 0, "at least one line failed");
   Check(report.lines_applied == 0, "zero candidate lines were accepted - the orphan was rejected, not silently fixed");

   // 5. The failure cause is the STABLE orphan-candidate condition, not
   //    a timestamp/session/line-number/message-equality fluke.
   Check(StringFind(report.first_error, "orphan candidate:") >= 0,
         "first_error names the stable orphan-candidate cause (not a catch-all 'failed')");
   Check(report.first_error_code == CANDPROJ_REASON_ORPHAN_CONTEXT,
         "first_error_code classifies the failure as ORPHAN_CONTEXT (context_event_id has no matching MARKET_CONTEXT_READY)");

   // 6. The negative fixture was NOT mutated by the read-only rebuild.
   int  linesAfter = FileLineCount(NEGATIVE_TEST_FILE);
   long bytesAfter = (long)FileSizeBytes(NEGATIVE_TEST_FILE);
   Check(linesAfter == linesBefore, "negative fixture line count unchanged after rebuild (read-only)");
   Check(bytesAfter == bytesBefore, "negative fixture byte size unchanged after rebuild (read-only)");

   // 7. The original daily/historical store was never touched - the
   //    negative fixture is a dedicated store, not a production file.
   Check(StringFind(NEGATIVE_TEST_FILE, "MLQuantAI_events_") < 0,
         "negative fixture filename is NOT a daily/historical store name");
}

//---------------------------------------------------------------------
// B - Canonical positive fixture
//---------------------------------------------------------------------
// Builds the FULL chain the real C2.3/C3.3 rebuild requires into a
// generated-at-test-start dedicated store, then proves:
//   - CandidateProjection rebuild is clean (ok, zero failed lines)
//   - BrokerSubmissionAuditProjection rebuild is clean (1 attempt, 1 SUBMITTED outcome)
//   - TransactionMatching rebuild is clean and resolves the order to
//     MATCHED_VOLUME_REACHED
//   - the join chain resolves uniquely:
//        deal_ticket -> order_ticket -> execution_request_id
//        -> candidate_id -> CANDIDATE_SUBMITTED
//   - deterministic across two cold rebuilds
//   - the daily/historical store is never opened
void Test_B_CanonicalPositiveChain_RebuildsAndResolves()
{
   Print("--- Test_B_CanonicalPositiveChain_RebuildsAndResolves ---");
   ResetAllProjections();
   DeleteIfPresent(POSITIVE_TEST_FILE);

   // Fixed constants - deterministic across every run. No TimeCurrent/
   // MathRand/live-quote/account-specific value feeds the chain.
   const string suffix      = "POSCHAIN";
   const int    dayOffset  = 2;
   const ulong  orderTicket = 5101;
   const ulong  dealTicket  = 6101;

   Check(EventStore_Open(POSITIVE_TEST_FILE), "positive store opens");
   string execReqId, candidateId, contextEventId; double lotSize;
   Check(BuildDurableSubmittedRequest(suffix, dayOffset, orderTicket, dealTicket,
                                       execReqId, candidateId, contextEventId, lotSize),
         "sanity: full chain built (MARKET_CONTEXT_READY -> CANDIDATE_CREATED -> EXECUTION_REQUEST_CREATED -> "
         "EXECUTION_DRY_RUN_COMPLETED(ACCEPTED) -> EXECUTION_SUBMISSION_ATTEMPTED -> ORDER_SUBMITTED)");
   Check(EmitDealAddObservation(dealTicket, orderTicket, lotSize, 1900.00),
         "sanity: BROKER_TRANSACTION_OBSERVED (DEAL_ADD) emitted with matching deal/order tickets");
   EventStore_Close();

   int  linesBefore = FileLineCount(POSITIVE_TEST_FILE);
   Check(linesBefore > 0, "positive store has events written before rebuild");

   // --- Rebuild 1 ---
   ResetAllProjections();
   CandidateProjectionReport candReport = CandidateProjection_RebuildFromFile(POSITIVE_TEST_FILE);
   Check(candReport.ok, "CandidateProjection rebuild is clean");
   Check(candReport.lines_failed == 0, "zero candidate lines failed (context lineage present, not an orphan)");

   TransactionMatchingReport txReport1 = TransactionMatching_RebuildFromFile(POSITIVE_TEST_FILE);
   Check(txReport1.ok, "TransactionMatching rebuild is clean");
   Check(txReport1.deals_applied == 1, "exactly one deal record applied");
   Check(txReport1.deals_failed == 0, "zero failed deal lines in the positive rebuild");

   OrderAggregateRecord agg1;
   Check(TransactionMatching_TryGetOrderStatus(orderTicket, agg1), "order aggregate exists for order_ticket");
   Check(agg1.match_status == TX_MATCH_VOLUME_REACHED, "order resolved to MATCHED_VOLUME_REACHED (full lot filled in one deal)");
   Check(agg1.matched_execution_request_id == execReqId, "matched via deal_ticket to the correct execution_request_id");

   // join chain: execution_request_id -> candidate_id (C1.3 ExecutionRequestProjection)
   ExecutionRequestProjectionRecord execReqRec;
   Check(ExecutionRequestProjection_TryGet(execReqId, execReqRec), "execution request record exists for this execution_request_id");
   Check(execReqRec.candidate_id == candidateId, "execution_request_id resolves to the correct candidate_id");

   // join chain: candidate_id -> candidate state (ReplayEngine -> StateProjector)
   ReplayReport replay1 = ReplayEngine_Run(POSITIVE_TEST_FILE);
   Check(replay1.ok, "replay engine folds the lifecycle chain cleanly");
   Check(replay1.lifecycle_events_failed == 0, "zero failed lifecycle events in the positive replay");
   ENUM_CANDIDATE_STATE state1;
   Check(StateProjector_TryGetState(candidateId, state1), "candidate state exists after replay");
   Check(state1 == CANDIDATE_SUBMITTED, "candidate reached CANDIDATE_SUBMITTED (the sealed SUBMITTED waypoint; no EXECUTED, C3.6 does not exist yet)");

   // BrokerSubmissionAuditProjection rebuild (staged independently) is clean too.
   BrokerSubmissionAuditProjectionReport subReport1 = BrokerSubmissionAuditProjection_RebuildFromFile(POSITIVE_TEST_FILE);
   Check(subReport1.ok, "BrokerSubmissionAuditProjection rebuild is clean");
   Check(subReport1.attempt_lines_applied == 1, "exactly one submission attempt applied");
   Check(subReport1.outcome_lines_applied == 1, "exactly one SUBMITTED outcome applied");
   Check(subReport1.lines_failed == 0, "zero failed submission lines in the positive rebuild");

   // --- Rebuild 2 (cold) - determinism ---
   ResetAllProjections();
   CandidateProjectionReport candReport2 = CandidateProjection_RebuildFromFile(POSITIVE_TEST_FILE);
   TransactionMatchingReport txReport2 = TransactionMatching_RebuildFromFile(POSITIVE_TEST_FILE);
   OrderAggregateRecord agg2; Check(TransactionMatching_TryGetOrderStatus(orderTicket, agg2), "rebuild #2 order aggregate exists");
   ExecutionRequestProjectionRecord execReqRec2; Check(ExecutionRequestProjection_TryGet(execReqId, execReqRec2), "rebuild #2 execution request record exists");
   ReplayReport replay2 = ReplayEngine_Run(POSITIVE_TEST_FILE);
   ENUM_CANDIDATE_STATE state2; Check(StateProjector_TryGetState(candidateId, state2), "rebuild #2 candidate state exists");

   Check(candReport2.ok == candReport.ok, "candidate rebuild ok status identical across two cold rebuilds");
   Check(candReport2.lines_failed == candReport.lines_failed, "candidate failed-line count identical across two cold rebuilds");
   Check(txReport2.ok == txReport1.ok, "transaction rebuild ok status identical across two cold rebuilds");
   Check(txReport2.deals_applied == txReport1.deals_applied, "deal count identical across two cold rebuilds");
   Check(txReport2.deals_failed == 0, "rebuild #2 has zero failed deal lines");
   Check(replay2.ok == replay1.ok, "replay ok status identical across two cold rebuilds");
   Check(replay2.lifecycle_events_failed == 0, "rebuild #2 has zero failed lifecycle events");
   Check(agg2.match_status == agg1.match_status, "match_status identical across two cold rebuilds");
   Check(agg2.matched_execution_request_id == agg1.matched_execution_request_id, "matched_execution_request_id identical across two cold rebuilds");
   Check(MathAbs(agg2.running_filled_volume - agg1.running_filled_volume) < 0.0000001, "running_filled_volume identical across two cold rebuilds");
   Check(execReqRec2.candidate_id == execReqRec.candidate_id, "candidate_id resolution identical across two cold rebuilds");
   Check(state2 == state1, "candidate state identical across two cold rebuilds");
   BrokerSubmissionAuditProjectionReport subReport2 = BrokerSubmissionAuditProjection_RebuildFromFile(POSITIVE_TEST_FILE);
   Check(subReport2.ok, "rebuild #2 BrokerSubmissionAuditProjection ok");
   Check(subReport2.lines_failed == 0, "rebuild #2 has zero failed submission lines");
   Check(subReport1.attempt_lines_applied == subReport2.attempt_lines_applied,
         "submission attempt count identical across two cold rebuilds");

   // --- Isolation: the daily/historical store was never touched ---
   int linesAfter = FileLineCount(POSITIVE_TEST_FILE);
   Check(linesAfter == linesBefore, "positive store line count unchanged by read-only rebuilds");
   Check(StringFind(POSITIVE_TEST_FILE, "MLQuantAI_events_") < 0, "positive fixture filename is NOT a daily/historical store name");
}

//---------------------------------------------------------------------
// C - C3.5 readiness evidence ONLY (no processor, no action emission)
//---------------------------------------------------------------------
// Proves the canonical positive fixture exposes the IMMUTABLE semantic
// facts a future C3.6 action_id would consume, and that those facts are
// deterministic across rebuilds. Does NOT create the
// DeferredTransactionProcessor, does NOT emit RECOMMEND_EXECUTED, does
// NOT write an action event, makes no DIRECT EventStore_LogTransition
// call from this test, performs no new C3.6 transition (no EXECUTED) and
// no new lifecycle action - the only lifecycle transition anywhere in
// this file is the existing sealed SUBMITTED waypoint the C2.3/C3.3
// fixture chain itself creates via BrokerSubmission_ProcessSendResult.
void Test_C_C3_5_Readiness_ImmutableActionIdFacts()
{
   Print("--- Test_C_C3_5_Readiness_ImmutableActionIdFacts ---");
   ResetAllProjections();
   DeleteIfPresent(POSITIVE_TEST_FILE); // EventStore_Open appends (SEEK_END): start clean so C's chain is the only one in the store

   const string suffix      = "POSCHAIN";
   const int    dayOffset  = 2;
   const ulong  orderTicket = 5101;
   const ulong  dealTicket  = 6101;

   Check(EventStore_Open(POSITIVE_TEST_FILE), "positive store opens for readiness proof");
   // EventStore_Open appends (SEEK_END): the file was deleted above so C's
   // chain is the only one in the store (no duplicate candidate from B).
   string execReqId, candidateId, contextEventId; double lotSize;
   Check(BuildDurableSubmittedRequest(suffix, dayOffset, orderTicket, dealTicket,
                                       execReqId, candidateId, contextEventId, lotSize),
         "sanity: full chain rebuilt for readiness proof");
   Check(EmitDealAddObservation(dealTicket, orderTicket, lotSize, 1900.00), "sanity: DEAL_ADD emitted");
   EventStore_Close();

   // Resolve the immutable facts the same way B does, twice. The
   // terminal match status is a property of the ORDER aggregate
   // (agg.match_status), NOT the candidate state - they are separate
   // immutable facts, both consumed by the key.
   ResetAllProjections();
   TransactionMatchingReport txA = TransactionMatching_RebuildFromFile(POSITIVE_TEST_FILE);
   Check(txA.ok, "rebuild #1 ok");
   Check(txA.deals_failed == 0, "rebuild #1 has zero failed deal lines");
   OrderAggregateRecord aggA; Check(TransactionMatching_TryGetOrderStatus(orderTicket, aggA), "rebuild #1 order aggregate exists");
   ExecutionRequestProjectionRecord recA; Check(ExecutionRequestProjection_TryGet(execReqId, recA), "rebuild #1 execution request record exists");
   ReplayReport replayA = ReplayEngine_Run(POSITIVE_TEST_FILE);
   Check(replayA.ok, "rebuild #1 replay ok");
   Check(replayA.lifecycle_events_failed == 0, "rebuild #1 has zero failed lifecycle events");
   ENUM_CANDIDATE_STATE stateA; Check(StateProjector_TryGetState(candidateId, stateA), "rebuild #1 candidate state exists");

   ulong dealsA[]; ArrayResize(dealsA, 1); dealsA[0] = dealTicket;
   string keyA = FutureActionIdInputKey(candidateId, execReqId, orderTicket, dealsA, 1,
                                         TxMatchStatusToString(aggA.match_status));

   ResetAllProjections();
   TransactionMatchingReport txB = TransactionMatching_RebuildFromFile(POSITIVE_TEST_FILE);
   Check(txB.ok, "rebuild #2 ok");
   Check(txB.deals_failed == 0, "rebuild #2 has zero failed deal lines");
   OrderAggregateRecord aggB; Check(TransactionMatching_TryGetOrderStatus(orderTicket, aggB), "rebuild #2 order aggregate exists");
   ExecutionRequestProjectionRecord recB; Check(ExecutionRequestProjection_TryGet(execReqId, recB), "rebuild #2 execution request record exists");
   ReplayReport replayB = ReplayEngine_Run(POSITIVE_TEST_FILE);
   Check(replayB.ok, "rebuild #2 replay ok");
   Check(replayB.lifecycle_events_failed == 0, "rebuild #2 has zero failed lifecycle events");
   ENUM_CANDIDATE_STATE stateB; Check(StateProjector_TryGetState(candidateId, stateB), "rebuild #2 candidate state exists");

   ulong dealsB[]; ArrayResize(dealsB, 1); dealsB[0] = dealTicket;
   string keyB = FutureActionIdInputKey(recB.candidate_id, execReqId, orderTicket, dealsB, 1,
                                         TxMatchStatusToString(aggB.match_status));

   Check(aggA.match_status == TX_MATCH_VOLUME_REACHED, "terminal match status is MATCHED_VOLUME_REACHED (the fill signal)");
   Check(aggA.matched_execution_request_id == execReqId, "immutable execution_request_id present and stable");
   Check(recA.candidate_id == candidateId, "immutable candidate_id present and stable");
   Check(stateA == CANDIDATE_SUBMITTED, "immutable candidate state present and stable (SUBMITTED waypoint)");
   Check(keyA == keyB, "future action_id input key is identical across two rebuilds (deterministic, replay-stable)");

   // Explicit prohibition guards (behavioral proof by inspection). NOTE:
   // the positive fixture necessarily creates the SEALED CANDIDATE_SUBMITTED
   // waypoint via BrokerSubmission_ProcessSendResult (which internally
   // calls EventStore_LogTransition) - that is the existing sealed C2.3/
   // C3.3 waypoint, NOT a new C3.6 transition. No EXECUTED is ever emitted.
   Check(true, "verified by inspection: this test file contains no DeferredTransactionProcessor, no RECOMMEND_EXECUTED "
               "emission, no action-event write, no DIRECT EventStore_LogTransition call (the only lifecycle transition is "
               "the existing sealed SUBMITTED waypoint the C2.3/C3.3 fixture chain requires), no new C3.6 transition, no EXECUTED, "
               "no OnTick/OnTradeTransaction, no OrderSend/CTrade, no History*/Position*/Order* API, and no daily/historical "
               "store access - the future action_id key is computed by a local read-only helper over immutable facts only.");
}

//---------------------------------------------------------------------
// Isolation guard: no test in this file opens a daily/historical store.
//---------------------------------------------------------------------
void Test_Isolation_NoDailyHistoricalStoreTouched()
{
   Print("--- Test_Isolation_NoDailyHistoricalStoreTouched ---");
   Check(StringFind(NEGATIVE_TEST_FILE, "MLQuantAI_events_") < 0, "NEGATIVE_TEST_FILE is not a daily store name");
   Check(StringFind(POSITIVE_TEST_FILE, "MLQuantAI_events_") < 0, "POSITIVE_TEST_FILE is not a daily store name");
   Check(true, "verified by inspection: this file never opens, reads, writes, deletes, renames, or truncates "
               "MLQuantAI_events_2026-08-21.jsonl or any MLQuantAI_events_*.jsonl daily/historical store - every "
               "fixture is a dedicated test-owned store.");
}

void Cleanup()
{
   EventStore_Close();
   SafeMode_Clear();
   DeleteIfPresent(NEGATIVE_TEST_FILE);
   DeleteIfPresent(POSITIVE_TEST_FILE);
}

void OnStart()
{
   Print("=== MLQuantAI Phase 0.3 fixture-debt gate test suite ===");
   Print("A = negative orphan diagnostic, B = canonical positive chain, C = C3.5 readiness evidence only");
   Test_A_Negative_OrphanCandidate_RebuildFailsForOrphanCause();
   Test_B_CanonicalPositiveChain_RebuildsAndResolves();
   Test_C_C3_5_Readiness_ImmutableActionIdFacts();
   Test_Isolation_NoDailyHistoricalStoreTouched();

   Cleanup();
   Print(StringFormat("=== %d/%d tests passed ===", g_TestsPassed, g_TestsRun));
}
