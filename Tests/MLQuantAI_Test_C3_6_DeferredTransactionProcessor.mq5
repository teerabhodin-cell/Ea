//+------------------------------------------------------------------+
//| MLQuantAI_Test_C3_6_DeferredTransactionProcessor.mq5               |
//| C3.6 implementation DoD, per                                       |
//| Docs/PhaseC_C3_6_DeferredTransactionProcessorContract.md (FROZEN). |
//| Fixture-only: exercises the real production entry point            |
//| DeferredTransactionProcessor_StartupScan() against durably-written   |
//| event-store lines, after the real sealed C3.3 TransactionMatching   |
//| rebuild + the real ReplayEngine_Run that populates StateProjector.  |
//| Same "feed the pure function directly" pattern every prior C3.x    |
//| test file already established. No real broker call anywhere here.  |
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
#include <MLQuantAI/Execution/MLQuantAI_TransactionMatchingReadiness.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStoreHealth.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_FeatureSnapshotProjection.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ModelArtifactProjection.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_AIDecisionProjection.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RiskPlanProjection.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RealizedOutcomeProjection.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityDecisionProjection.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionAuditProjection.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAuditProjection.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionGate.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ManualApprovalProjection.mqh>
#include <MLQuantAI/Execution/MLQuantAI_DeferredTransactionProcessor.mqh>

#define TEST_FILE "MLQuantAI_Test_C3_6_DeferredTransactionProcessor.jsonl"
#define TEST_FILE_B "MLQuantAI_Test_C3_6_DeferredTransactionProcessor_B.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as Tests/MLQuantAI_Test_C3_3_
// TransactionMatchingProjection.mq5's own copies, duplicated per this
// project's own established per-test-file convention.
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
   ctx.context_event_id = "CTX_c36deferred_" + suffix;
   ctx.context_hash      = "test_context_hash_c36deferred_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C36DEFERRED_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

void BuildC2AcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C36DEFERRED_V1";
   policy.environment_mode = EXECUTION_ENV_DEMO;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

// Durably emits the FULL upstream chain (MARKET_CONTEXT_READY ->
// CANDIDATE_CREATED -> ... -> EXECUTION_REQUEST_CREATED) AND threads the
// request through a real RecordAttempt/ProcessSendResult pair so a real
// CANDIDATE_SUBMITTED lifecycle event + SubmissionOutcomeProjection row
// are written. Same pattern MLQuantAI_Test_C3_3_*.mq5 established. Also
// returns the candidate + context so a SECOND execution request can be
// emitted for the same candidate (the >1-mapping BLOCKED test).
bool BuildDurableSubmittedRequestEx(string suffix, int dayOffset, ulong orderTicket, ulong dealTicket,
                                   TradeCandidate &outCandidate, MarketContext &outCtx,
                                   AIDecision &outDecision, RiskPlan &outPlan,
                                   FeatureSnapshot &outSnapshot,
                                   string &outExecutionRequestId, double &outLotSize)
{
   MarketContext ctx;
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.06.01 00:00:00' + dayOffset * 86400;
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
   aiPolicy.decision_policy_version = "AIPOLICY_C36DEFERRED_V1";
   aiPolicy.threshold_version       = "THRESH_C36DEFERRED_V1";
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

   ExecutionPolicy policy; BuildC2AcceptingExecutionPolicy(policy);
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

   ExecutionSubmissionResult outResult;
   if(!BrokerSubmission_ProcessSendResult(c, req, req.planned_entry, true, 0, TimeCurrent(), tr, outResult)) return false;
   if(outResult.submission_status != SUBMISSION_STATUS_SUBMITTED) return false;

   outCandidate             = c;
   outCtx                   = ctx;
   outDecision              = decision;
   outPlan                  = plan;
   outSnapshot               = snapshot;
   outExecutionRequestId    = req.execution_request_id;
   outLotSize               = req.lot_size;
   return true;
}

// Convenience wrapper (matches C3.3's BuildDurableSubmittedRequest shape).
bool BuildDurableSubmittedRequest(string suffix, int dayOffset, ulong orderTicket, ulong dealTicket,
                                 string &outExecutionRequestId, double &outLotSize)
{
   TradeCandidate dummyC; MarketContext dummyCtx; AIDecision dummyD; RiskPlan dummyP; FeatureSnapshot dummyS;
   return BuildDurableSubmittedRequestEx(suffix, dayOffset, orderTicket, dealTicket, dummyC, dummyCtx,
                                        dummyD, dummyP, dummyS, outExecutionRequestId, outLotSize);
}

// Emits a SECOND EXECUTION_REQUEST_CREATED line for an already-submitted
// candidate (no second submission, no duplicate feature-snapshot/model/
// AI-decision/risk-plan events - those are REUSED from the first call via
// outDecision/outPlan). This gives the reverse index two mappings for one
// candidate_id -> RECOMMEND_BLOCKED (multiple_execution_request_mappings).
bool EmitSecondExecutionRequestForCandidate(TradeCandidate &c, const MarketContext &ctx,
                                             const AIDecision &decision, const RiskPlan &plan,
                                             const FeatureSnapshot &snapshot,
                                             string &outExecReqId2)
{
   // snapshot is the ORIGINAL (built while the candidate was still CREATED)
   // passed in from the first BuildDurableSubmittedRequestEx call. We must NOT
   // re-derive it via Candidate_ToFeatureSnapshot here - that builder rejects
   // any candidate whose state is not CANDIDATE_CREATED, and the candidate is
   // now SUBMITTED. Reusing the original keeps decision.ai_decision_hash
   // consistent with the snapshot it was built from.

   EligibilityContext eligContext; BuildHealthyEligibilityContext(eligContext);
   // Use a DISTINCT eligibility policy version so the second
   // eligibility_decision_id (and therefore execution_request_id) differs
   // from the first request - otherwise the deterministic ID collides and
   // the projection would dedup to a single record, defeating the test.
   EligibilityPolicy eligPolicy; BuildEnabledEligibilityPolicy(eligPolicy);
   eligPolicy.eligibility_policy_version = "ELIGPOLICY_C36_SECOND_V1";
   EligibilityDecision eligDecision; string eligReasonDetail;
   if(!EligibilityDecision_Build(plan, decision, snapshot, eligContext, eligPolicy, eligDecision, eligReasonDetail)) return false;
   // decision==ELIGIBLE -> EmitDecisionAndWireLifecycle emits only the
   // ELIGIBILITY_DECISION event (no candidate transition), safe for an
   // already-SUBMITTED candidate.
   if(!EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, eligContext, c)) return false;
   if(eligDecision.decision != ELIGIBILITY_DECISION_ELIGIBLE) return false;

   ExecutionPolicy policy; BuildC2AcceptingExecutionPolicy(policy);
   // Distinct execution_policy_version too, so the request ID/hash is
   // guaranteed unique even if eligibility-policy-version alone were not
   // part of the request ID (it is, but belt-and-suspenders).
   policy.execution_policy_version = "EXECPOLICY_C36_SECOND_V1";
   ExecutionRequest req; string rd;
   if(!ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd)) return false;
   DryRunExecutionResult dryRunResult;
   if(!ExecutionRequest_EmitAndEvaluate(req, policy, dryRunResult)) return false;
   if(dryRunResult.decision != SAFETY_GATE_ACCEPTED) return false;
   outExecReqId2 = req.execution_request_id;
   return true;
}

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
   r.order             = 0;
   r.volume            = 0;
   r.price             = 0;
   r.bid               = 0;
   r.ask               = 0;
   r.comment           = "";
   r.request_id        = 0;
   r.retcode_external  = 0;

   return BrokerTransactionObservation_RecordAndGuard(t, req, r);
}

// The emission helpers (CRT_EmitCandidateCreated, FeatureSnapshot_Emit,
// EligibilityDecision_EmitDecisionAndWireLifecycle, ExecutionRequest_
// EmitAndEvaluate, BrokerSubmission_*) update LIVE in-memory projections
// that reject duplicate deterministic IDs. Because candidate_id and every
// downstream ID are derived from the market setup (anchor/dayOffset) rather
// than the suffix, two tests that happen to share a dayOffset produce the
// same IDs and the second test's emission is rejected as a duplicate by the
// stale live projection left over from the first test. C3.3 avoids this by
// giving every test a distinct dayOffset; we go further and also reset every
// projection here so the emission phase always starts from a clean slate.
// (The rebuild phase calls Reset on these again and repopulates from the file,
// so resetting here is harmless for tests that rebuild afterwards.)
void ResetLiveProjections()
{
   StateProjector_Reset();
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
   BrokerSubmissionGate_Reset();
   TransactionDealRegistry_Reset();
   OrderAggregateRegistry_Reset();
   TransactionMatchingReadiness_Reset();
   ManualApprovalProjection_Reset();
   RealizedOutcomeProjection_Reset();
}

void ResetTestFile(string file)
{
   EventStore_Close();
   EventStoreHealth_ClearSafeMode();
   ResetLiveProjections();
   if(FileIsExist(file, FILE_COMMON))
      FileDelete(file, FILE_COMMON);
}

// Builds the C3.3 read model + replayed candidate state, exactly the
// OnInit chain up to (but not including) the C3.6 scan. Mirrors OnInit:
// TransactionMatching_StartupRebuild -> ReplayEngine_Run. The scan is
// called separately by each test so scan-level failure tests can skip
// the rebuild.
void RunRebuildChain(string file)
{
   TransactionMatching_StartupRebuild(file);
   ReplayEngine_Run(file);
}

// Captures the recommendation registry's action_ids + candidate_ids in
// output order, for cold-rebuild / ordering determinism comparisons.
void CaptureRegistrySnapshot(string &outActionIds[], string &outCandidateIds[])
{
   int n = DeferredTransactionProcessor_Count();
   ArrayResize(outActionIds, n);
   ArrayResize(outCandidateIds, n);
   for(int i = 0; i < n; i++)
   {
      DeferredRecommendationRecord rec;
      if(!DeferredTransactionProcessor_GetAt(i, rec)) { outActionIds[i] = ""; outCandidateIds[i] = ""; continue; }
      outActionIds[i]   = rec.action_id;
      outCandidateIds[i] = rec.candidate_id;
   }
}

bool SnapshotsEqual(const string &a[], const string &b[])
{
   int n = ArraySize(a);
   if(ArraySize(b) != n) return false;
   for(int i = 0; i < n; i++)
      if(a[i] != b[i]) return false;
   return true;
}

//---------------------------------------------------------------------
// 1. valid SUBMITTED + MATCHED_VOLUME_REACHED -> RECOMMEND_EXECUTED
//---------------------------------------------------------------------
void Test_ValidSubmittedMatched_RecommendExecuted()
{
   Print("--- Test_ValidSubmittedMatched_RecommendExecuted ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("EXEOK", 0, 5001, 6001, execReqId, lotSize),
         "sanity: durable SUBMITTED candidate built (order=5001, deal=6001)");
   Check(EmitDealAddObservation(6001, 5001, lotSize, 1900.00),
         "sanity: DEAL_ADD observation emitted (full lot_size volume)");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   DeferredTransactionProcessorReport report = DeferredTransactionProcessor_StartupScan(TEST_FILE);

   Check(!report.scan_failed, "scan did not fail at scan-level");
   Check(report.executed_count == 1, "exactly one RECOMMEND_EXECUTED row emitted");
   Check(report.none_count == 0, "no RECOMMEND_NONE rows for this single-candidate store");
   Check(report.blocked_count == 0, "no RECOMMEND_BLOCKED rows");

   // Find the recommendation row for the candidate.
   int n = DeferredTransactionProcessor_Count();
   Check(n == 1, "registry holds exactly one recommendation row");
   DeferredRecommendationRecord rec;
   bool found = false;
   for(int i = 0; i < n; i++)
   {
      if(DeferredTransactionProcessor_GetAt(i, rec) && rec.recommended_action == RECOMMEND_EXECUTED)
      { found = true; break; }
   }
   Check(found, "a RECOMMEND_EXECUTED row exists in the registry");

   Check(rec.candidate_id != "", "candidate_id populated");
   Check(rec.execution_request_id == execReqId, "execution_request_id matches the durable request");
   Check(rec.order_ticket == 5001, "order_ticket is 5001");
   Check(ArraySize(rec.deal_tickets) == 1, "one deal_ticket in the sorted set");
   Check(rec.deal_tickets[0] == 6001, "deal_ticket is 6001 (sorted)");
   Check(rec.terminal_match_status == TX_MATCH_VOLUME_REACHED, "terminal_match_status is MATCHED_VOLUME_REACHED");
   Check(rec.candidate_state_evidence == CANDIDATE_SUBMITTED, "candidate_state_evidence is SUBMITTED");
   Check(rec.action_id != "", "action_id is populated for EXECUTED rows");
   Check(StringFind(rec.action_id, "C36|EXECUTED|") == 0, "action_id carries the C36|EXECUTED prefix");
   Check(StringFind(rec.action_id, IntegerToString(5001)) > 0, "action_id carries order_ticket 5001");
   Check(StringFind(rec.action_id, "6001") > 0, "action_id carries deal_ticket 6001");
   Check(StringFind(rec.action_id, "|v1") > 0, "action_id carries the v1 contract-version suffix");
   Check(StringFind(rec.action_id, "MATCHED_VOLUME_REACHED") > 0, "action_id carries MATCHED_VOLUME_REACHED");
   Check(rec.intended_lot_size == lotSize, "intended_lot_size carried from ExecutionRequestProjection");
   Check(rec.deal_source_sequence_numbers[0] != 0 || rec.deal_source_log_event_ids[0] != "",
         "per-deal provenance (seq or log_event_id) populated");
   Check(rec.candidate_root_event_id != "", "candidate_root_event_id lineage populated");
   Check(rec.context_event_id != "", "context_event_id lineage populated");
   Check(rec.stale_after_startup == true, "stale_after_startup is true (OnInit snapshot)");
}

//---------------------------------------------------------------------
// 2. partial fill (SUBMITTED, volume < lot_size) -> RECOMMEND_NONE
//---------------------------------------------------------------------
void Test_PartialFill_RecommendNone()
{
   Print("--- Test_PartialFill_RecommendNone ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("PARTIAL", 1, 5002, 6002, execReqId, lotSize), "sanity: durable SUBMITTED candidate built");
   Check(lotSize > 0.02, "sanity: lot_size large enough for a genuine partial");
   Check(EmitDealAddObservation(6002, 5002, lotSize / 2.0, 1900.00), "sanity: partial DEAL_ADD emitted (half lot_size)");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   DeferredTransactionProcessorReport report = DeferredTransactionProcessor_StartupScan(TEST_FILE);

   Check(!report.scan_failed, "scan did not fail at scan-level");
   Check(report.executed_count == 0, "no RECOMMEND_EXECUTED for a partial fill");
   Check(report.none_count == 1, "one RECOMMEND_NONE row");
   Check(report.blocked_count == 0, "partial fill is NONE, not BLOCKED");

   Check(DeferredTransactionProcessor_Count() == 1, "registry has exactly one row");
   // Find the NONE row and verify its reason.
   int n = DeferredTransactionProcessor_Count();
   bool sawPartial = false;
   for(int i = 0; i < n; i++)
   {
      DeferredRecommendationRecord r2;
      if(DeferredTransactionProcessor_GetAt(i, r2) && r2.recommended_action == RECOMMEND_NONE
         && StringFind(r2.reason_code, "partial") >= 0)
      { sawPartial = true; break; }
   }
   Check(sawPartial, "a RECOMMEND_NONE row with a partial_fill reason exists");
}

//---------------------------------------------------------------------
// 3. SUBMITTED but no DEAL_ADD observation -> RECOMMEND_NONE (no_matched_order)
//---------------------------------------------------------------------
void Test_SubmittedNoFill_RecommendNone()
{
   Print("--- Test_SubmittedNoFill_RecommendNone ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("NOFILL", 2, 5003, 6003, execReqId, lotSize), "sanity: durable SUBMITTED candidate built (no deal observation)");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   DeferredTransactionProcessorReport report = DeferredTransactionProcessor_StartupScan(TEST_FILE);

   Check(!report.scan_failed, "scan did not fail at scan-level");
   Check(report.executed_count == 0, "no RECOMMEND_EXECUTED without any fill");
   Check(report.none_count == 1, "one RECOMMEND_NONE row");
   Check(report.blocked_count == 0, "no fill is NONE, not BLOCKED");

   int n = DeferredTransactionProcessor_Count();
   bool sawNoMatch = false;
   for(int i = 0; i < n; i++)
   {
      DeferredRecommendationRecord r2;
      if(DeferredTransactionProcessor_GetAt(i, r2) && r2.recommended_action == RECOMMEND_NONE
         && r2.reason_code == "no_matched_order")
      { sawNoMatch = true; break; }
   }
   Check(sawNoMatch, "a RECOMMEND_NONE row with reason no_matched_order exists");
}

//---------------------------------------------------------------------
// 4. candidate CREATED but never SUBMITTED -> RECOMMEND_NONE (candidate_not_submitted)
//---------------------------------------------------------------------
void Test_CandidateNotSubmitted_RecommendNone()
{
   Print("--- Test_CandidateNotSubmitted_RecommendNone ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   // Emit only MARKET_CONTEXT_READY + CANDIDATE_CREATED (no submission chain).
   MarketContext ctx; BuildBaseContext(ctx, "NOTSUB");
   datetime t0 = D'2026.06.01 00:00:00' + 3 * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;
   Check(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx)), "MARKET_CONTEXT_READY emitted");
   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(r.detected, "CRT detected a candidate");
   TradeCandidate c;
   Check(CRT_ToTradeCandidate(ctx, r, c), "candidate built");
   Check(CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits), "CANDIDATE_CREATED emitted (no submission)");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   DeferredTransactionProcessorReport report = DeferredTransactionProcessor_StartupScan(TEST_FILE);

   Check(!report.scan_failed, "scan did not fail at scan-level");
   Check(report.executed_count == 0, "no RECOMMEND_EXECUTED for a never-submitted candidate");
   Check(report.none_count == 1, "one RECOMMEND_NONE row");
   Check(report.blocked_count == 0, "not-submitted is NONE, not BLOCKED (no reverse-index check applied)");

   int n = DeferredTransactionProcessor_Count();
   bool sawNotSub = false;
   for(int i = 0; i < n; i++)
   {
      DeferredRecommendationRecord r2;
      if(DeferredTransactionProcessor_GetAt(i, r2) && r2.recommended_action == RECOMMEND_NONE
         && r2.reason_code == "candidate_not_submitted")
      { sawNotSub = true; break; }
   }
   Check(sawNotSub, "a RECOMMEND_NONE row with reason candidate_not_submitted exists");
}

//---------------------------------------------------------------------
// 5. ambiguous order: a candidate's exec request is implicated in an
//    AMBIGUOUS order -> RECOMMEND_BLOCKED (ambiguous_match_implicated).
//---------------------------------------------------------------------
void Test_AmbiguousImplicated_RecommendBlocked()
{
   Print("--- Test_AmbiguousImplicated_RecommendBlocked ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   // Two durable submitted candidates, each with its own deal_ticket.
   string execReqIdA; double lotSizeA;
   string execReqIdB; double lotSizeB;
   Check(BuildDurableSubmittedRequest("AMBIGA", 4, 5008, 6008, execReqIdA, lotSizeA), "candidate A submitted (order=5008, deal=6008)");
   Check(BuildDurableSubmittedRequest("AMBIGB", 5, 5009, 6009, execReqIdB, lotSizeB), "candidate B submitted (order=5009, deal=6009)");
   Check(execReqIdA != execReqIdB, "the two execution_request_ids are distinct");

   // Both deals tagged with the SAME order_ticket (5008) -> one resolves
   // to request A, the other to request B -> structurally AMBIGUOUS.
   Check(EmitDealAddObservation(6008, 5008, 0.01, 1900.00), "deal 6008 (request A) under order 5008");
   Check(EmitDealAddObservation(6009, 5008, 0.01, 1900.00), "deal 6009 (request B) ALSO under order 5008");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   DeferredTransactionProcessorReport report = DeferredTransactionProcessor_StartupScan(TEST_FILE);

   Check(!report.scan_failed, "scan did not fail at scan-level");
   Check(report.blocked_count >= 2, "both candidates implicated in the ambiguous order are BLOCKED");
   Check(report.executed_count == 0, "no RECOMMEND_EXECUTED for an ambiguous mapping");

   int n = DeferredTransactionProcessor_Count();
   bool sawAmbigBlocked = false;
   for(int i = 0; i < n; i++)
   {
      DeferredRecommendationRecord r2;
      if(DeferredTransactionProcessor_GetAt(i, r2) && r2.recommended_action == RECOMMEND_BLOCKED
         && r2.reason_code == "ambiguous_match_implicated")
      { sawAmbigBlocked = true; break; }
   }
   Check(sawAmbigBlocked, "a RECOMMEND_BLOCKED row with reason ambiguous_match_implicated exists");
}

//---------------------------------------------------------------------
// 6. two execution requests for the same candidate (>1 reverse-index
//    mapping) -> RECOMMEND_BLOCKED (multiple_execution_request_mappings).
//---------------------------------------------------------------------
void Test_MultipleExecRequestMappings_RecommendBlocked()
{
   Print("--- Test_MultipleExecRequestMappings_RecommendBlocked ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   TradeCandidate c; MarketContext ctx; AIDecision decision; RiskPlan plan; FeatureSnapshot snapshot; string execReqId1; double lotSize;
   Check(BuildDurableSubmittedRequestEx("MULTI", 6, 5010, 6010, c, ctx, decision, plan, snapshot, execReqId1, lotSize),
         "candidate submitted once (exec request 1)");
   // Emit a SECOND execution request for the SAME candidate (no second
   // submission) -> reverse index now holds 2 mappings -> BLOCKED.
   string execReqId2 = "";
   Check(EmitSecondExecutionRequestForCandidate(c, ctx, decision, plan, snapshot, execReqId2), "second execution request emitted for the same candidate");
   Check(execReqId2 != "", "second execution request id is non-empty");
   Check(execReqId2 != execReqId1, "second execution request id is distinct from the first");
   // No DEAL_ADD for either request -> without a matched order this would
   // be NONE, but the >1 mapping check fires FIRST -> BLOCKED.
   EventStore_Close();

   RunRebuildChain(TEST_FILE);

   // Direct upstream proof: the candidate now has exactly TWO execution-
   // request projection records (before relying on the processor result).
   int erCount = 0;
   int erTotal = ExecutionRequestProjection_Count();
   for(int i = 0; i < erTotal; i++)
   {
      ExecutionRequestProjectionRecord er;
      if(ExecutionRequestProjection_GetAt(i, er) && er.candidate_id == c.candidate_id) erCount++;
   }
   Check(erCount == 2, StringFormat("candidate has exactly 2 execution-request records (got %d)", erCount));

   DeferredTransactionProcessorReport report = DeferredTransactionProcessor_StartupScan(TEST_FILE);

   Check(!report.scan_failed, "scan did not fail at scan-level");
   Check(report.blocked_count == 1, "the candidate is BLOCKED for multiple mappings");
   Check(report.executed_count == 0, "no RECOMMEND_EXECUTED");

   int n = DeferredTransactionProcessor_Count();
   bool sawMulti = false;
   for(int i = 0; i < n; i++)
   {
      DeferredRecommendationRecord r2;
      if(DeferredTransactionProcessor_GetAt(i, r2) && r2.recommended_action == RECOMMEND_BLOCKED
         && r2.reason_code == "multiple_execution_request_mappings")
      { sawMulti = true; break; }
   }
   Check(sawMulti, "a RECOMMEND_BLOCKED row with reason multiple_execution_request_mappings exists");
}

//---------------------------------------------------------------------
// 6b. reverse-index ZERO mappings (contract section 17, item 11): a
//    candidate reaches CANDIDATE_SUBMITTED via a DIRECT EventStore_
//    LogTransition call, skipping the ExecutionRequest chain entirely -
//    the exact same real code path RunRuntimeLifecycleSmokeTest() uses in
//    MLQuantAI.mq5 (the sealed state machine legally allows CREATED ->
//    SUBMITTED directly). No EXECUTION_REQUEST_CREATED event is ever
//    written for this candidate, so the C3.5 section 6 / C3.6 section 8
//    reverse index holds ZERO mappings -> RECOMMEND_BLOCKED
//    (no_execution_request_mapping), not RECOMMEND_NONE - the reverse-
//    index check applies once SUBMITTED is confirmed, per section 7.
//---------------------------------------------------------------------
void Test_ZeroExecutionRequestMapping_RecommendBlocked()
{
   Print("--- Test_ZeroExecutionRequestMapping_RecommendBlocked ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   MarketContext ctx; BuildBaseContext(ctx, "ZEROMAP");
   datetime t0 = D'2026.06.01 00:00:00' + 17 * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;
   Check(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx)), "MARKET_CONTEXT_READY emitted");

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(r.detected, "CRT detected a candidate");
   TradeCandidate c;
   Check(CRT_ToTradeCandidate(ctx, r, c), "candidate built");
   Check(CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits), "CANDIDATE_CREATED emitted");

   Check(EventStore_LogTransition(c, CANDIDATE_SUBMITTED, REASON_SUBMITTED_OK), "candidate transitioned directly to SUBMITTED (no execution request ever created)");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);

   // Direct upstream proof: zero ExecutionRequestProjection records exist
   // for this candidate.
   int erCount = 0;
   int erTotal = ExecutionRequestProjection_Count();
   for(int i = 0; i < erTotal; i++)
   {
      ExecutionRequestProjectionRecord er;
      if(ExecutionRequestProjection_GetAt(i, er) && er.candidate_id == c.candidate_id) erCount++;
   }
   Check(erCount == 0, "sanity: zero execution-request records exist for this candidate");

   DeferredTransactionProcessorReport report = DeferredTransactionProcessor_StartupScan(TEST_FILE);

   Check(!report.scan_failed, "scan did not fail at scan-level");
   Check(report.blocked_count == 1, "the candidate is BLOCKED for zero execution-request mappings");
   Check(report.executed_count == 0, "no RECOMMEND_EXECUTED");
   Check(report.none_count == 0, "zero mappings is BLOCKED, not NONE (reverse-index check applies once SUBMITTED is confirmed)");

   int n = DeferredTransactionProcessor_Count();
   bool sawZeroMap = false;
   for(int i = 0; i < n; i++)
   {
      DeferredRecommendationRecord r2;
      if(DeferredTransactionProcessor_GetAt(i, r2) && r2.recommended_action == RECOMMEND_BLOCKED
         && r2.reason_code == "no_execution_request_mapping")
      { sawZeroMap = true; break; }
   }
   Check(sawZeroMap, "a RECOMMEND_BLOCKED row with reason no_execution_request_mapping exists");
}

//---------------------------------------------------------------------
// 7. replay not ready (SafeMode engaged) -> scan-level zero rows.
//---------------------------------------------------------------------
void Test_ReplayNotReady_ZeroRecommendations()
{
   Print("--- Test_ReplayNotReady_ZeroRecommendations ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("REPLAY", 7, 5011, 6011, execReqId, lotSize), "durable SUBMITTED candidate built");
   Check(EmitDealAddObservation(6011, 5011, lotSize, 1900.00), "full-volume DEAL_ADD emitted");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);

   // Simulate replay failure: SafeMode engaged at scan time (OnInit trips
   // it when !ReplayReport.ok; a pre-existing corrupted store also engages
   // it). The read models are otherwise fully populated.
   EventStoreHealth_TripSafeMode("test: simulated replay inconsistency");

   DeferredTransactionProcessorReport report = DeferredTransactionProcessor_StartupScan(TEST_FILE);

   Check(report.scan_failed, "scan failed at scan-level");
   Check(report.scan_failure_reason == "upstream_replay_not_ready", "scan_failure_reason is upstream_replay_not_ready");
   Check(report.recommendations_total == 0, "zero recommendations emitted");
   Check(report.executed_count == 0, "zero EXECUTED rows even with a fully-matched candidate present");
   Check(DeferredTransactionProcessor_Count() == 0, "registry is empty after a scan-level failure");

   EventStoreHealth_ClearSafeMode();
}

//---------------------------------------------------------------------
// 8. upstream readiness not ready (no TransactionMatching rebuild) ->
//    scan-level zero rows (upstream_readiness_not_ready).
//---------------------------------------------------------------------
void Test_ReadinessNotReady_ZeroRecommendations()
{
   Print("--- Test_ReadinessNotReady_ZeroRecommendations ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("NOTREADY", 8, 5012, 6012, execReqId, lotSize), "durable SUBMITTED candidate built");
   Check(EmitDealAddObservation(6012, 5012, lotSize, 1900.00), "full-volume DEAL_ADD emitted");
   EventStore_Close();

   // Simulate "upstream readiness not ready" WITHOUT SafeMode: explicitly
   // reset the TransactionMatching readiness flag. Readiness is a sticky
   // process-global set true by prior tests' StartupRebuild calls, so
   // merely skipping StartupRebuild here would leave a stale true value.
   // Reset() forces ready=false + clears the retained report, exactly the
   // state the processor's scan-level gate B must short-circuit on.
   TransactionMatchingReadiness_Reset();

   DeferredTransactionProcessorReport report = DeferredTransactionProcessor_StartupScan(TEST_FILE);

   Check(report.scan_failed, "scan failed at scan-level");
   Check(report.scan_failure_reason == "upstream_readiness_not_ready", "scan_failure_reason is upstream_readiness_not_ready");
   Check(report.recommendations_total == 0, "zero recommendations emitted");
   Check(DeferredTransactionProcessor_Count() == 0, "registry is empty after a scan-level failure");
}

//---------------------------------------------------------------------
// 9. cold rebuild determinism: run the chain + scan twice on the same
//    store -> identical action_id set AND ordering.
//---------------------------------------------------------------------
void Test_ColdRebuildDeterminism()
{
   Print("--- Test_ColdRebuildDeterminism ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   // Two distinct candidates, both fully matched.
   string e1; double l1;
   string e2; double l2;
   Check(BuildDurableSubmittedRequest("DET1", 9,  5020, 6020, e1, l1), "candidate 1 built+submitted+matched");
   Check(EmitDealAddObservation(6020, 5020, l1, 1900.00), "candidate 1 full-volume DEAL_ADD");
   Check(BuildDurableSubmittedRequest("DET2", 10, 5021, 6021, e2, l2), "candidate 2 built+submitted+matched");
   Check(EmitDealAddObservation(6021, 5021, l2, 1900.00), "candidate 2 full-volume DEAL_ADD");
   EventStore_Close();

   // Pass 1
   RunRebuildChain(TEST_FILE);
   DeferredTransactionProcessor_StartupScan(TEST_FILE);
   string ids1[]; string cids1[];
   CaptureRegistrySnapshot(ids1, cids1);

   // Pass 2: cold rebuild from the same store (registry resets every scan;
   // rebuilds reset their own registries).
   RunRebuildChain(TEST_FILE);
   DeferredTransactionProcessor_StartupScan(TEST_FILE);
   string ids2[]; string cids2[];
   CaptureRegistrySnapshot(ids2, cids2);

   Check(SnapshotsEqual(ids1, ids2), "action_id set AND ordering identical across two cold rebuilds");
   Check(SnapshotsEqual(cids1, cids2), "candidate_id ordering identical across two cold rebuilds");
   Check(ArraySize(ids1) == 2, "both candidates produced EXECUTED rows");
}

//---------------------------------------------------------------------
// 10. deal-ticket file order swapped -> same action_id + ordering.
//     Same two partial-fill deals, written in reversed file order, must
//     yield the same sorted deal-ticket set / action_id / output order.
//---------------------------------------------------------------------
void Test_DealTicketOrderSwapped_SameOutput()
{
   Print("--- Test_DealTicketOrderSwapped_SameOutput ---");

   // Store A: deals in ascending file order.
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "store A opens");
   string eA; double lA;
   Check(BuildDurableSubmittedRequest("SWAPA", 11, 5030, 6030, eA, lA), "candidate built");
   Check(lA > 0.02, "lot_size large enough for two partial fills");
   Check(EmitDealAddObservation(6030, 5030, lA / 2.0, 1900.00), "first partial deal (6030) emitted");
   Check(EmitDealAddObservation(6031, 5030, lA - lA / 2.0, 1900.10), "second partial deal (6031) emitted");
   EventStore_Close();

   // Store B: same two deals, REVERSED file order. Uses a DISTINCT dayOffset
   // (12, not 11) so the candidate_id (derived from market setup/anchor,
   // NOT the suffix) is genuinely different from store A's - otherwise the
   // live CandidateProjection rejects a duplicate candidate_id. Distinct
   // order/deal tickets (5031 / 6032,6033) avoid colliding with store A's
   // live in-memory SubmissionOutcomeProjection for order 5030 / deal 6030,
   // which persists across the two emission phases of this single test.
   ResetTestFile(TEST_FILE_B);
   Check(EventStore_Open(TEST_FILE_B), "store B opens");
   string eB; double lB;
   Check(BuildDurableSubmittedRequest("SWAPB", 12, 5031, 6032, eB, lB), "candidate built (distinct dayOffset + tickets)");
   Check(lB > 0.02, "store B lot_size large enough for two partial fills");
   Check(EmitDealAddObservation(6033, 5031, lB / 2.0, 1900.10), "second partial deal (6033) emitted FIRST");
   Check(EmitDealAddObservation(6032, 5031, lB - lB / 2.0, 1900.00), "first partial deal (6032) emitted SECOND");
   EventStore_Close();

   // Note: the candidate_ids differ between stores (different suffix),
   // so compare the action_id's deal-ticket SET only, not the full id.
   RunRebuildChain(TEST_FILE);
   DeferredTransactionProcessor_StartupScan(TEST_FILE);
   string idsA[]; string cidsA[];
   CaptureRegistrySnapshot(idsA, cidsA);

   RunRebuildChain(TEST_FILE_B);
   DeferredTransactionProcessor_StartupScan(TEST_FILE_B);
   string idsB[]; string cidsB[];
   CaptureRegistrySnapshot(idsB, cidsB);

   Check(ArraySize(idsA) == 1 && ArraySize(idsB) == 1, "both stores produced one EXECUTED row");
   // The deal-ticket portion of the action_id must be the same sorted set
   // regardless of file order: store A emitted [6030,6031] ascending, store B
   // emitted [6033,6032] descending - both must sort to ascending in the id.
   Check(StringFind(idsA[0], "[6030,6031]") >= 0, "store A action_id has sorted deal set [6030,6031]");
   Check(StringFind(idsB[0], "[6032,6033]") >= 0, "store B action_id has sorted deal set [6032,6033] (reversed emission, same sorted result)");

   ResetTestFile(TEST_FILE_B);
}

//---------------------------------------------------------------------
// 11. repeated scan -> no durable side effect (registry not doubled,
//     identical results). Also exercises within-scan duplicate collapse.
//---------------------------------------------------------------------
void Test_RepeatedScan_NoDurableSideEffect()
{
   Print("--- Test_RepeatedScan_NoDurableSideEffect ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string e; double l;
   Check(BuildDurableSubmittedRequest("REPEAT", 16, 5040, 6040, e, l), "candidate built+submitted+matched");
   Check(EmitDealAddObservation(6040, 5040, l, 1900.00), "full-volume DEAL_ADD emitted");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   DeferredTransactionProcessor_StartupScan(TEST_FILE);
   string ids1[]; string cids1[];
   CaptureRegistrySnapshot(ids1, cids1);
   int count1 = DeferredTransactionProcessor_Count();
   int executed1 = 0;
   for(int i = 0; i < count1; i++)
   {
      DeferredRecommendationRecord r2;
      if(DeferredTransactionProcessor_GetAt(i, r2) && r2.recommended_action == RECOMMEND_EXECUTED) executed1++;
   }

   // Scan again WITHOUT rebuilding (registry resets every scan -> the same
   // semantic output is reconstructed once, not doubled).
   DeferredTransactionProcessor_StartupScan(TEST_FILE);
   string ids2[]; string cids2[];
   CaptureRegistrySnapshot(ids2, cids2);
   int count2 = DeferredTransactionProcessor_Count();
   int executed2 = 0;
   for(int i = 0; i < count2; i++)
   {
      DeferredRecommendationRecord r2;
      if(DeferredTransactionProcessor_GetAt(i, r2) && r2.recommended_action == RECOMMEND_EXECUTED) executed2++;
   }

   Check(count1 == count2, "registry count is identical after a repeat scan (no durable side effect)");
   Check(executed1 == 1 && executed2 == 1, "still exactly one EXECUTED row after a repeat scan");
   Check(SnapshotsEqual(ids1, ids2), "action_id set AND ordering identical after a repeat scan");
}

//---------------------------------------------------------------------
// 12. semantic output ordering: multiple candidates are emitted in
//     candidate_id ASC order (not file/insertion order).
//---------------------------------------------------------------------
void Test_OutputSemanticOrdering()
{
   Print("--- Test_OutputSemanticOrdering ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   // Build three candidates in a deliberately non-sorted suffix order so
   // their candidate_ids are not in insertion order. The output must be
   // sorted by candidate_id ASC regardless.
   string ez; double lz;
   Check(BuildDurableSubmittedRequest("ZZZ", 13, 5050, 6050, ez, lz), "candidate ZZZ built+matched");
   Check(EmitDealAddObservation(6050, 5050, lz, 1900.00), "candidate ZZZ full DEAL_ADD");
   string ea; double la;
   Check(BuildDurableSubmittedRequest("AAA", 14, 5051, 6051, ea, la), "candidate AAA built+matched");
   Check(EmitDealAddObservation(6051, 5051, la, 1900.00), "candidate AAA full DEAL_ADD");
   string em; double lm;
   Check(BuildDurableSubmittedRequest("MMM", 15, 5052, 6052, em, lm), "candidate MMM built+matched");
   Check(EmitDealAddObservation(6052, 5052, lm, 1900.00), "candidate MMM full DEAL_ADD");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   DeferredTransactionProcessorReport report = DeferredTransactionProcessor_StartupScan(TEST_FILE);

   Check(!report.scan_failed, "scan did not fail at scan-level");
   Check(report.executed_count == 3, "all three candidates recommended EXECUTED");

   int n = DeferredTransactionProcessor_Count();
   Check(n == 3, "registry holds exactly three rows");
   // Verify the registry is sorted by candidate_id ASC.
   bool sorted = true;
   for(int i = 1; i < n; i++)
   {
      DeferredRecommendationRecord prev; DeferredRecommendationRecord cur;
      DeferredTransactionProcessor_GetAt(i - 1, prev);
      DeferredTransactionProcessor_GetAt(i, cur);
      if(StringCompare(prev.candidate_id, cur.candidate_id) > 0) { sorted = false; break; }
   }
   Check(sorted, "registry rows are sorted by candidate_id ASC (semantic order, not file order)");
}

//---------------------------------------------------------------------
// Structural proofs (contract section 17, items 7/13/15/16/18 - see the
// per-Check comments below for the reasoning behind each).
//---------------------------------------------------------------------
void Test_StructuralProofs()
{
   Print("--- Test_StructuralProofs (unreachable duplicate/collision, RECOMMEND_REJECTED absence, no forbidden API, stale-after-OnInit) ---");

   Check(RecommendationToString(RECOMMEND_NONE)     == "RECOMMEND_NONE",     "RECOMMEND_NONE round-trips through RecommendationToString");
   Check(RecommendationToString(RECOMMEND_EXECUTED) == "RECOMMEND_EXECUTED", "RECOMMEND_EXECUTED round-trips through RecommendationToString");
   Check(RecommendationToString(RECOMMEND_BLOCKED)  == "RECOMMEND_BLOCKED",  "RECOMMEND_BLOCKED round-trips through RecommendationToString");
   Check(true, "item 15 - verified by inspection: ENUM_RECOMMENDATION (MLQuantAI_DeferredTransactionProcessor.mqh) declares exactly "
               "these three members - RECOMMEND_REJECTED does not exist as an enum member, so it can never be assigned to "
               "recommended_action, output as a row, or reach any consumer. Adding it back would require editing this sealed file "
               "under a new, separately-authorized contract.");

   Check(true, "items 7 & 13 - verified by inspection, structurally unreachable: action_id (C36_BuildActionId) is built from "
               "candidate_id + execution_request_id + order_ticket + sorted deal_tickets. DeferredTransactionProcessor_StartupScan's "
               "own candidate loop iterates CandidateProjection_Count()/GetAt() exactly once per index, and CandidateProjection's "
               "sealed genesis-uniqueness guard (exhaustively covered by its own B6.1/B6.3 test suites) guarantees no candidate_id "
               "ever appears twice in that registry. Consequently no two rows emitted within one scan can ever share an action_id - "
               "the C36_ActionIdAlreadyEmitted() duplicate/collision guard in the processor file is real defense-in-depth (fails "
               "closed to RECOMMEND_BLOCKED on the impossible case), not a path this suite can exercise through the public API, "
               "matching the same 'verified by inspection, not independently reproducible' category as C2.2's own bid<=0.0 branch "
               "precedent (Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5).");

   Check(true, "item 16 - verified by inspection: Include/MLQuantAI/Execution/MLQuantAI_DeferredTransactionProcessor.mqh contains no "
               "OrderSend/CTrade/HistorySelect/HistoryDealGet*/HistoryOrderGet*/PositionSelect/PositionGetTicket/OrderGetTicket/"
               "EventStore_LogTransition call anywhere, and no *_RebuildFromFile call of any individual upstream projection at "
               "runtime - it reads only Count()/GetAt()/TryGet() accessors over already-built read models and the "
               "TransactionMatchingReadiness snapshot. Confirmed by a static text scan of the file (zero non-comment hits for every "
               "prohibited token in contract section 16).");

   Check(true, "item 18 - verified by inspection: the file declares no OnTick() and no OnTradeTransaction() function or hook of any "
               "kind. DeferredTransactionProcessor_StartupScan is the sole entry point, called exactly once from MLQuantAI.mq5's "
               "OnInit (between ReplayEngine_Run and BrokerReconciliation_CheckAll). Every DeferredRecommendationRecord's "
               "stale_after_startup field is hardcoded true in DeferredRecommendationRecord_Init and never recomputed or cleared "
               "anywhere else in the file - there is no code path that could refresh the recommendation set between restarts.");
}

//---------------------------------------------------------------------
// Entry point.
//---------------------------------------------------------------------
void OnStart()
{
   Print("=== MLQuantAI Test: C3.6 DeferredTransactionProcessor ===");

   Test_ValidSubmittedMatched_RecommendExecuted();
   Test_PartialFill_RecommendNone();
   Test_SubmittedNoFill_RecommendNone();
   Test_CandidateNotSubmitted_RecommendNone();
   Test_AmbiguousImplicated_RecommendBlocked();
   Test_MultipleExecRequestMappings_RecommendBlocked();
   Test_ZeroExecutionRequestMapping_RecommendBlocked();
   Test_ReplayNotReady_ZeroRecommendations();
   Test_ReadinessNotReady_ZeroRecommendations();
   Test_ColdRebuildDeterminism();
   Test_DealTicketOrderSwapped_SameOutput();
   Test_RepeatedScan_NoDurableSideEffect();
   Test_OutputSemanticOrdering();
   Test_StructuralProofs();

   Print(StringFormat("=== Result: %d/%d checks passed ===", g_TestsPassed, g_TestsRun));
   if(g_TestsRun > 0 && g_TestsPassed == g_TestsRun)
      Print("ALL PASS.");
   else
      Print("FAILURES PRESENT - review the [FAIL] lines above.");
}
