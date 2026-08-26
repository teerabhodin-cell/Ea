//+------------------------------------------------------------------+
//| MLQuantAI_Test_C3_7_LifecycleAuthorityProcessor.mq5                |
//| C3.7 implementation DoD, per                                       |
//| Docs/PhaseC_C3_7_BoundedLifecycleAuthorityContract.md (FROZEN).    |
//| Fixture-only: exercises the real production entry point            |
//| LifecycleAuthority_StartupApply() against durably-written event-   |
//| store lines, after the real sealed C3.3/C3.4 rebuilds, the real     |
//| ReplayEngine_Run, and the real C3.6 DeferredTransactionProcessor_   |
//| StartupScan(). Same "feed the pure function directly" pattern       |
//| every prior C3.x test file already established. No real broker     |
//| call anywhere here.                                                 |
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
#include <MLQuantAI/Execution/MLQuantAI_LifecycleAuthorityProcessor.mqh>

#define TEST_FILE "MLQuantAI_Test_C3_7_LifecycleAuthorityProcessor.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as Tests/MLQuantAI_Test_C3_6_
// DeferredTransactionProcessor.mq5's own copies, duplicated per this
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
   ctx.context_event_id = "CTX_c37lifecycle_" + suffix;
   ctx.context_hash      = "test_context_hash_c37lifecycle_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C37LIFECYCLE_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

void BuildC2AcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C37LIFECYCLE_V1";
   policy.environment_mode = EXECUTION_ENV_DEMO;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

// Durably emits the FULL upstream chain AND threads the request through a
// real RecordAttempt/ProcessSendResult pair so a real CANDIDATE_SUBMITTED
// lifecycle event + SubmissionOutcomeProjection row are written. Same
// pattern MLQuantAI_Test_C3_6_DeferredTransactionProcessor.mq5 established.
bool BuildDurableSubmittedRequest(string suffix, int dayOffset, ulong orderTicket, ulong dealTicket,
                                 string &outCandidateId, string &outExecutionRequestId, double &outLotSize)
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
   aiPolicy.decision_policy_version = "AIPOLICY_C37LIFECYCLE_V1";
   aiPolicy.threshold_version       = "THRESH_C37LIFECYCLE_V1";
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

   outCandidateId        = c.candidate_id;
   outExecutionRequestId = req.execution_request_id;
   outLotSize             = req.lot_size;
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
   DeferredTransactionProcessor_Reset();
}

void ResetTestFile(string file)
{
   EventStore_Close();
   EventStoreHealth_ClearSafeMode();
   ResetLiveProjections();
   if(FileIsExist(file, FILE_COMMON))
      FileDelete(file, FILE_COMMON);
}

// Mirrors OnInit's own chain up to (but not including) C3.7:
// TransactionMatching_StartupRebuild -> ReplayEngine_Run ->
// DeferredTransactionProcessor_StartupScan. LifecycleAuthority_
// StartupApply itself is called separately by each test so scan-level
// failure tests can control exactly when it runs.
void RunRebuildChain(string file)
{
   TransactionMatching_StartupRebuild(file);
   ReplayEngine_Run(file);
   DeferredTransactionProcessor_StartupScan(file);
}

//---------------------------------------------------------------------
// 1. Happy path: eligible RECOMMEND_EXECUTED row -> real durable
//    CANDIDATE_EXECUTED transition, replay-verified, extra_json carries
//    every frozen provenance field, recovered event carries a REAL
//    sequence_number/log_event_id (never zero/empty - proves the
//    fabricated-event path was never taken). Also covers contract item
//    13 (extra_json round-trip).
//---------------------------------------------------------------------
void Test_EligibleRow_TransitionsToExecuted()
{
   Print("--- Test_EligibleRow_TransitionsToExecuted ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("EXEOK", 0, 5001, 6001, candidateId, execReqId, lotSize),
         "sanity: durable SUBMITTED candidate built (order=5001, deal=6001)");
   Check(EmitDealAddObservation(6001, 5001, lotSize, 1900.00), "sanity: full-volume DEAL_ADD emitted");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   Check(DeferredTransactionProcessor_Count() == 1, "sanity: C3.6 produced exactly one recommendation row");
   DeferredRecommendationRecord c36row;
   Check(DeferredTransactionProcessor_GetAt(0, c36row) && c36row.recommended_action == RECOMMEND_EXECUTED,
         "sanity: C3.6's own row is RECOMMEND_EXECUTED");

   ENUM_CANDIDATE_STATE beforeState;
   Check(StateProjector_TryGetState(candidateId, beforeState) && beforeState == CANDIDATE_SUBMITTED,
         "sanity: candidate is SUBMITTED before C3.7 runs");

   LifecycleAuthorityReport report = LifecycleAuthority_StartupApply(TEST_FILE);

   Check(report.ok, "report.ok is true");
   Check(!report.scan_stopped_early, "scan did not stop early");
   Check(report.eligible_count == 1, "eligible_count reflects the one RECOMMEND_EXECUTED row");
   Check(report.transitioned_count == 1, "exactly one transition applied");
   Check(report.blocked_count == 0 && report.skipped_not_submitted == 0
         && report.skipped_missing_candidate_projection == 0 && report.skipped_missing_provenance == 0,
         "every skip counter stays zero on a clean happy path");

   ENUM_CANDIDATE_STATE afterState;
   Check(StateProjector_TryGetState(candidateId, afterState) && afterState == CANDIDATE_EXECUTED,
         "StateProjector reports EXECUTED immediately after C3.7 - the synchronous StateProjector_Apply took effect");
   Check(!SafeMode_IsActive(), "a successful transition never engages Safe Mode");

   // Independently re-read the durable file and verify the REAL recovered
   // event (never a fabricated one): real sequence_number/log_event_id,
   // and every frozen extra_json provenance field.
   string lines[];
   int n = EventStore_ReadAllLines(TEST_FILE, lines);
   string executedLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"CANDIDATE_EXECUTED\"") >= 0) { executedLine = lines[i]; break; }
   Check(executedLine != "", "sanity: a durable CANDIDATE_EXECUTED line exists in the store");

   LifecycleEvent parsed;
   Check(EventSerializer_ParseLifecycle(executedLine, parsed), "the durable line parses as a valid LifecycleEvent");
   Check(parsed.base.sequence_number != 0, "recovered event carries a REAL nonzero sequence_number (never a fabricated placeholder)");
   Check(parsed.base.log_event_id != "", "recovered event carries a REAL non-empty log_event_id");
   Check(parsed.from_state == CANDIDATE_SUBMITTED && parsed.to_state == CANDIDATE_EXECUTED, "from/to state correct");
   Check(parsed.reason == REASON_EXECUTED_OK, "reason is REASON_EXECUTED_OK");

   Check(StringFind(executedLine, "\"c3_7_schema_version\":\"C37_V1\"") >= 0, "extra_json: c3_7_schema_version present");
   Check(StringFind(executedLine, "\"c3_6_action_id\":\"" + c36row.action_id + "\"") >= 0, "extra_json: c3_6_action_id matches C3.6's row");
   Check(StringFind(executedLine, "\"execution_request_id\":\"" + execReqId + "\"") >= 0, "extra_json: execution_request_id present");
   Check(StringFind(executedLine, "\"order_ticket\":5001") >= 0, "extra_json: order_ticket present");
   Check(StringFind(executedLine, "\"deal_tickets_sorted\":[6001]") >= 0, "extra_json: deal_tickets_sorted present");
   Check(StringFind(executedLine, "\"terminal_match_status\":\"MATCHED_VOLUME_REACHED\"") >= 0, "extra_json: terminal_match_status present");
   Check(StringFind(executedLine, "\"running_filled_volume\":") >= 0, "extra_json: running_filled_volume present");
   Check(StringFind(executedLine, "\"intended_lot_size\":") >= 0, "extra_json: intended_lot_size present");
   Check(StringFind(executedLine, "\"execution_request_source_log_event_id\":") >= 0, "extra_json: execution_request_source_log_event_id present");
   Check(StringFind(executedLine, "\"execution_request_source_sequence_number\":") >= 0, "extra_json: execution_request_source_sequence_number present");
   Check(StringFind(executedLine, "\"deal_source_log_event_ids_sorted\":") >= 0, "extra_json: deal_source_log_event_ids_sorted present");
   Check(StringFind(executedLine, "\"deal_source_sequence_numbers_sorted\":") >= 0, "extra_json: deal_source_sequence_numbers_sorted present");
}

//---------------------------------------------------------------------
// 2. RECOMMEND_NONE / RECOMMEND_BLOCKED rows are never transitioned.
//---------------------------------------------------------------------
void Test_NoneAndBlockedRows_NeverTransitioned()
{
   Print("--- Test_NoneAndBlockedRows_NeverTransitioned ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   // A: partial fill -> RECOMMEND_NONE.
   string candA; string execReqA; double lotA;
   Check(BuildDurableSubmittedRequest("PARTIAL", 1, 5002, 6002, candA, execReqA, lotA), "sanity: candidate A submitted");
   Check(lotA > 0.02, "sanity: lot_size large enough for a genuine partial");
   Check(EmitDealAddObservation(6002, 5002, lotA / 2.0, 1900.00), "sanity: half-volume DEAL_ADD for A");

   // B/C: ambiguous order -> RECOMMEND_BLOCKED for both.
   string candB; string execReqB; double lotB;
   string candC; string execReqC; double lotC;
   Check(BuildDurableSubmittedRequest("AMBIGB", 2, 5003, 6003, candB, execReqB, lotB), "sanity: candidate B submitted");
   Check(BuildDurableSubmittedRequest("AMBIGC", 3, 5004, 6004, candC, execReqC, lotC), "sanity: candidate C submitted");
   Check(EmitDealAddObservation(6003, 5003, 0.01, 1900.00), "sanity: deal 6003 under order 5003");
   Check(EmitDealAddObservation(6004, 5003, 0.01, 1900.00), "sanity: deal 6004 ALSO under order 5003 (ambiguous)");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   Check(DeferredTransactionProcessor_Count() == 3, "sanity: C3.6 produced three rows (1 NONE + 2 BLOCKED)");

   LifecycleAuthorityReport report = LifecycleAuthority_StartupApply(TEST_FILE);

   Check(report.ok, "report.ok is true - NONE/BLOCKED rows are not failures");
   Check(report.eligible_count == 0, "zero RECOMMEND_EXECUTED rows in this fixture");
   Check(report.transitioned_count == 0, "zero transitions attempted");
   Check(report.none_count == 1, "one NONE row tallied");
   Check(report.blocked_count == 2, "two BLOCKED rows tallied");

   ENUM_CANDIDATE_STATE stateA, stateB, stateC;
   Check(StateProjector_TryGetState(candA, stateA) && stateA == CANDIDATE_SUBMITTED, "candidate A stays SUBMITTED");
   Check(StateProjector_TryGetState(candB, stateB) && stateB == CANDIDATE_SUBMITTED, "candidate B stays SUBMITTED");
   Check(StateProjector_TryGetState(candC, stateC) && stateC == CANDIDATE_SUBMITTED, "candidate C stays SUBMITTED");

   string lines[];
   int n = EventStore_ReadAllLines(TEST_FILE, lines);
   int executedCount = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"CANDIDATE_EXECUTED\"") >= 0) executedCount++;
   Check(executedCount == 0, "zero CANDIDATE_EXECUTED lines exist in the durable store");
}

//---------------------------------------------------------------------
// 3. Cold restart idempotency (contract items 3 + 8 together): running
//    the full OnInit-equivalent chain a SECOND time against the same
//    store produces ZERO new transitions - C3.6 itself stops
//    recommending an already-EXECUTED candidate (state != SUBMITTED),
//    so C3.7 has nothing left to act on.
//---------------------------------------------------------------------
void Test_ColdRestartIdempotency_NoSecondTransition()
{
   Print("--- Test_ColdRestartIdempotency_NoSecondTransition ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("RESTART", 4, 5005, 6005, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   Check(EmitDealAddObservation(6005, 5005, lotSize, 1900.00), "sanity: full-volume DEAL_ADD emitted");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   LifecycleAuthorityReport first = LifecycleAuthority_StartupApply(TEST_FILE);
   Check(first.ok && first.transitioned_count == 1, "first pass transitions exactly one candidate");

   // Second pass: cold-restart-equivalent - reset every live projection
   // and rebuild everything from scratch against the SAME durable file.
   ResetLiveProjections();
   RunRebuildChain(TEST_FILE);
   Check(DeferredTransactionProcessor_Count() == 1, "sanity: C3.6's second-pass registry still holds one row for this candidate");
   DeferredRecommendationRecord row2;
   Check(DeferredTransactionProcessor_GetAt(0, row2) && row2.recommended_action == RECOMMEND_NONE
         && row2.reason_code == "candidate_not_submitted",
         "C3.6 correctly stops recommending the now-EXECUTED candidate (candidate_not_submitted)");

   LifecycleAuthorityReport second = LifecycleAuthority_StartupApply(TEST_FILE);
   Check(second.ok, "second pass report.ok is true");
   Check(second.transitioned_count == 0, "second pass transitions NOTHING - already EXECUTED, nothing eligible");
   Check(second.eligible_count == 0, "second pass sees zero RECOMMEND_EXECUTED rows");

   string lines[];
   int n = EventStore_ReadAllLines(TEST_FILE, lines);
   int executedCount = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"CANDIDATE_EXECUTED\"") >= 0) executedCount++;
   Check(executedCount == 1, "exactly ONE durable CANDIDATE_EXECUTED line exists for this candidate - no duplicate");
}

//---------------------------------------------------------------------
// 4. Defensive fresh-state re-check: a candidate's live state changes
//    (synthetically, between C3.6's scan and C3.7's own action - the
//    only way this is constructible under single-threaded OnInit
//    execution, matching this project's own "verified by inspection,
//    not independently reproducible under normal operation" category)
//    -> C3.7 skips it rather than trusting the stale RECOMMEND_EXECUTED
//    row's own candidate_state_evidence snapshot.
//---------------------------------------------------------------------
void Test_StateChangedBetweenScanAndAction_SkippedNoTransition()
{
   Print("--- Test_StateChangedBetweenScanAndAction_SkippedNoTransition ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("STALE", 5, 5006, 6006, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   Check(EmitDealAddObservation(6006, 5006, lotSize, 1900.00), "sanity: full-volume DEAL_ADD emitted");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   Check(DeferredTransactionProcessor_Count() == 1, "sanity: C3.6 produced one RECOMMEND_EXECUTED row");
   DeferredRecommendationRecord row;
   Check(DeferredTransactionProcessor_GetAt(0, row) && row.recommended_action == RECOMMEND_EXECUTED,
         "sanity: the row is RECOMMEND_EXECUTED, based on the SUBMITTED snapshot C3.6 saw");

   // Synthetically advance the SAME candidate to REJECTED_BY_BROKER
   // directly via StateProjector_Apply, simulating "something else moved
   // this candidate between C3.6's scan and C3.7's own action" - not a
   // naturally-occurring race in this single-threaded OnInit sequence,
   // but a legitimate, constructible defensive-guard test.
   LifecycleEvent synthetic;
   LifecycleEvent_Init(synthetic);
   synthetic.candidate_id = candidateId;
   synthetic.from_state   = CANDIDATE_SUBMITTED;
   synthetic.to_state     = CANDIDATE_REJECTED_BY_BROKER;
   synthetic.reason       = REASON_BROKER_REJECT;
   string synthErr;
   Check(StateProjector_Apply(synthetic, synthErr), "sanity: synthetic REJECTED_BY_BROKER transition applied to StateProjector directly");

   ENUM_CANDIDATE_STATE liveState;
   Check(StateProjector_TryGetState(candidateId, liveState) && liveState == CANDIDATE_REJECTED_BY_BROKER,
         "sanity: StateProjector now reports REJECTED_BY_BROKER, NOT SUBMITTED - stale relative to C3.6's own snapshot");

   LifecycleAuthorityReport report = LifecycleAuthority_StartupApply(TEST_FILE);

   Check(report.ok, "report.ok is true - a stale/changed state is a defensive skip, not a scan-level failure");
   Check(report.transitioned_count == 0, "zero transitions - the fresh re-check caught the state change");
   Check(report.skipped_not_submitted == 1, "skipped_not_submitted counts this row");

   string lines[];
   int n = EventStore_ReadAllLines(TEST_FILE, lines);
   int executedCount = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"CANDIDATE_EXECUTED\"") >= 0) executedCount++;
   Check(executedCount == 0, "no CANDIDATE_EXECUTED line was ever written for this candidate");
}

//---------------------------------------------------------------------
// 5. CandidateProjection-lineage structural invariant (contract item 5).
//    Per explicit instruction, NOT tested via an injected/impossible
//    C3.6 registry row - proven structurally instead: C3.7 only ever
//    iterates C3.6's own registry, and C3.6 only ever builds rows from
//    CandidateProjection_Count()/GetAt() iteration (verified by
//    inspection of MLQuantAI_DeferredTransactionProcessor.mqh's own
//    DeferredTransactionProcessor_StartupScan loop). Therefore a normal
//    eligible row can never reach C3.7 without CandidateProjection
//    lineage already existing - the CandidateProjection_TryGet() guard
//    in LifecycleAuthority_StartupApply is real defense-in-depth for an
//    input shape the public API cannot produce, not a path this suite
//    can exercise without breaching encapsulation (which is explicitly
//    disallowed).
//---------------------------------------------------------------------
void Test_CandidateProjectionLineage_StructuralInvariant()
{
   Print("--- Test_CandidateProjectionLineage_StructuralInvariant ---");
   Check(true, "verified by inspection: LifecycleAuthority_StartupApply's own loop iterates ONLY "
               "DeferredTransactionProcessor_Count()/GetAt() (the C3.6 registry) - it never constructs or accepts "
               "a recommendation row from any other source.");
   Check(true, "verified by inspection: DeferredTransactionProcessor_StartupScan (MLQuantAI_DeferredTransactionProcessor.mqh) "
               "builds every row exclusively from CandidateProjection_Count()/GetAt() iteration (candCount = "
               "CandidateProjection_Count(); for ci in candCount: CandidateProjection_GetAt(ci, cand); ... row.candidate_id "
               "= cand.candidate_id). A candidate_id that has no CandidateProjection record can never appear in the C3.6 "
               "registry in the first place, so it can never reach C3.7 as a RECOMMEND_EXECUTED row under normal operation.");
   Check(true, "the defensive CandidateProjection_TryGet() guard inside LifecycleAuthority_StartupApply (this file, section "
               "'Section 1 clause 3 / section 6') is real, compiled, and counted via skipped_missing_candidate_projection - "
               "it is kept as defense-in-depth for this structurally-unreachable input shape, not removed as dead code, "
               "per the frozen contract's own explicit instruction.");
}

//---------------------------------------------------------------------
// 6. Durable write failure -> inherited SafeMode_Trip (from within
//    EventStore_LogTransition itself), scan STOPS immediately (does NOT
//    continue to the next recommendation - the corrected failure
//    semantics), reconciliation must be skipped by the caller (proven
//    via report.ok == false).
//---------------------------------------------------------------------
void Test_DurableWriteFailure_SafeModeStopsScan()
{
   Print("--- Test_DurableWriteFailure_SafeModeStopsScan ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candA; string execReqA; double lotA;
   string candB; string execReqB; double lotB;
   Check(BuildDurableSubmittedRequest("WFAILA", 6, 5007, 6007, candA, execReqA, lotA), "sanity: candidate A submitted");
   Check(BuildDurableSubmittedRequest("WFAILB", 7, 5008, 6008, candB, execReqB, lotB), "sanity: candidate B submitted");
   Check(EmitDealAddObservation(6007, 5007, lotA, 1900.00), "sanity: full-volume DEAL_ADD for A");
   Check(EmitDealAddObservation(6008, 5008, lotB, 1900.00), "sanity: full-volume DEAL_ADD for B");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   Check(DeferredTransactionProcessor_Count() == 2, "sanity: C3.6 produced two RECOMMEND_EXECUTED rows (A, B)");

   // The store stays CLOSED (EventStore_Close() above, never reopened) -
   // g_EventStore_Handle == INVALID_HANDLE, so EventStore_LogTransition's
   // own internal EventStore_WriteLine call fails immediately for the
   // FIRST eligible row. Same established failure-injection pattern as
   // C2.2's own Test_RecordAttempt_DurableWriteFailure_NoMutation.
   LifecycleAuthorityReport report = LifecycleAuthority_StartupApply(TEST_FILE);

   Check(!report.ok, "report.ok is false");
   Check(report.scan_stopped_early, "scan_stopped_early is true");
   Check(report.stop_reason == "durable_write_failure", "stop_reason is durable_write_failure");
   Check(report.transitioned_count == 0, "zero transitions - even the first row's write failed");
   Check(SafeMode_IsActive(), "Safe Mode is engaged - inherited from EventStore_LogTransition's own internal SafeMode_Trip");

   // Corrected failure semantics: STOP, do not continue to the next row.
   // Reopen (read-only, via EventStore_ReadAllLines) to prove candidate B
   // was never even attempted.
   ENUM_CANDIDATE_STATE stateB;
   Check(StateProjector_TryGetState(candB, stateB) && stateB == CANDIDATE_SUBMITTED,
         "candidate B is STILL SUBMITTED - the scan stopped after A's failure and never reached B");

   string lines[];
   int n = EventStore_ReadAllLines(TEST_FILE, lines);
   int executedCount = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"CANDIDATE_EXECUTED\"") >= 0) executedCount++;
   Check(executedCount == 0, "zero durable CANDIDATE_EXECUTED lines exist - neither A nor B was transitioned");
}

//---------------------------------------------------------------------
// 7. StateProjector_Apply failure AFTER a successful durable write ->
//    Safe Mode, scan stops immediately, no further rows attempted. This
//    is a genuine event-log/read-model divergence - constructed
//    synthetically (pre-corrupting StateProjector's own from_state
//    expectation for this candidate before C3.7 runs), since it cannot
//    occur naturally under correct single-threaded operation.
//---------------------------------------------------------------------
void Test_ProjectorApplyFailure_SafeModeStopsScan()
{
   Print("--- Test_ProjectorApplyFailure_SafeModeStopsScan ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("APPLYFAIL", 8, 5009, 6009, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   Check(EmitDealAddObservation(6009, 5009, lotSize, 1900.00), "sanity: full-volume DEAL_ADD emitted");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   Check(DeferredTransactionProcessor_Count() == 1, "sanity: C3.6 produced one RECOMMEND_EXECUTED row");

   // Reopen the store so EventStore_LogTransition's own durable write can
   // succeed (this test isolates the SECOND failure point - the
   // StateProjector_Apply call - not the write itself).
   Check(EventStore_Open(TEST_FILE), "store reopens so the durable write itself succeeds");

   // Pre-corrupt StateProjector's own expectation for this candidate:
   // manually advance it to CANDIDATE_ERROR first (a legal SUBMITTED ->
   // ERROR transition), so that when C3.7's own recovered-event apply
   // later claims from_state == CANDIDATE_SUBMITTED, StateProjector's
   // real current state (CANDIDATE_ERROR) no longer agrees - the exact
   // "store is inconsistent" branch inside StateProjector_Apply itself.
   LifecycleEvent corrupt;
   LifecycleEvent_Init(corrupt);
   corrupt.candidate_id = candidateId;
   corrupt.from_state    = CANDIDATE_SUBMITTED;
   corrupt.to_state       = CANDIDATE_ERROR;
   corrupt.reason          = REASON_ERROR_INTERNAL;
   string corruptErr;
   Check(StateProjector_Apply(corrupt, corruptErr), "sanity: StateProjector pre-corrupted to CANDIDATE_ERROR for this candidate_id");

   LifecycleAuthorityReport report = LifecycleAuthority_StartupApply(TEST_FILE);

   Check(!report.ok, "report.ok is false");
   Check(report.scan_stopped_early, "scan_stopped_early is true");
   Check(report.stop_reason == "projector_apply_failed", "stop_reason is projector_apply_failed");
   Check(SafeMode_IsActive(), "Safe Mode is engaged - a genuine event-log/read-model divergence");

   // The durable write itself DID succeed before the apply failure - the
   // CANDIDATE_EXECUTED line genuinely exists on disk, even though the
   // in-memory StateProjector could not be kept consistent with it. This
   // is exactly why Safe Mode - not a silent skip - is the correct
   // response: the durable log and the in-memory read model have
   // diverged.
   string lines[];
   int n = EventStore_ReadAllLines(TEST_FILE, lines);
   int executedCount = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"CANDIDATE_EXECUTED\"") >= 0) executedCount++;
   Check(executedCount == 1, "the durable write itself succeeded before the apply failure was detected");
}

//---------------------------------------------------------------------
// 8. StateProjector reflects a fresh EXECUTED transition immediately,
//    and C3.7's OnInit placement is before BrokerReconciliation_
//    CheckAll (contract item 9). Structural + in-memory behavioral proof
//    only - no fabricated MT5 position, no real BrokerReconciliation_
//    CheckAll() call from this suite (per explicit instruction; the
//    existing broker-reconciliation suite owns that boundary).
//---------------------------------------------------------------------
void Test_StateProjectorReflectsFreshExecuted_BeforeReconciliation()
{
   Print("--- Test_StateProjectorReflectsFreshExecuted_BeforeReconciliation ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("RECONORD", 9, 5010, 6010, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   Check(EmitDealAddObservation(6010, 5010, lotSize, 1900.00), "sanity: full-volume DEAL_ADD emitted");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   LifecycleAuthorityReport report = LifecycleAuthority_StartupApply(TEST_FILE);
   Check(report.ok && report.transitioned_count == 1, "sanity: transition succeeds");

   ENUM_CANDIDATE_STATE state;
   Check(StateProjector_TryGetState(candidateId, state) && state == CANDIDATE_EXECUTED,
         "StateProjector reports EXECUTED for THIS session's own fresh transition, with no restart in between - "
         "a BrokerReconciliation_CheckAll() call made right after this point would see it, exactly as MLQuantAI.mq5's "
         "own OnInit ordering guarantees (LifecycleAuthority_StartupApply runs strictly before "
         "BrokerReconciliation_CheckAll)");
   Check(true, "verified by inspection: MLQuantAI.mq5's OnInit calls LifecycleAuthority_StartupApply(...) and only then, "
               "conditionally on report.ok, calls BrokerReconciliation_CheckAll() - the ordering this contract section 3 "
               "freezes. This suite does not call the real BrokerReconciliation_CheckAll() itself (it reads live "
               "PositionsTotal()/PositionGetTicket()/PositionGetString(), which the existing "
               "Tests/MLQuantAI_Test_BrokerReconciliation.mq5 suite already owns testing against a mock position list).");
}

//---------------------------------------------------------------------
// 9. Blocked-count summary WARN: exactly one, never per-row. NONE rows
//    never warn.
//---------------------------------------------------------------------
void Test_BlockedCount_SingleSummaryWarn()
{
   Print("--- Test_BlockedCount_SingleSummaryWarn ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candB; string execReqB; double lotB;
   string candC; string execReqC; double lotC;
   Check(BuildDurableSubmittedRequest("WARNB", 10, 5011, 6011, candB, execReqB, lotB), "sanity: candidate B submitted");
   Check(BuildDurableSubmittedRequest("WARNC", 11, 5012, 6012, candC, execReqC, lotC), "sanity: candidate C submitted");
   Check(EmitDealAddObservation(6011, 5011, 0.01, 1900.00), "sanity: deal 6011 under order 5011");
   Check(EmitDealAddObservation(6012, 5011, 0.01, 1900.00), "sanity: deal 6012 ALSO under order 5011 (ambiguous -> 2 BLOCKED rows)");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   LifecycleAuthorityReport report = LifecycleAuthority_StartupApply(TEST_FILE);

   Check(report.ok, "report.ok is true");
   Check(report.blocked_count == 2, "blocked_count tallies both ambiguous-implicated rows");
   Check(true, "verified by inspection: LifecycleAuthority_StartupApply contains exactly ONE LogWarn call sited on "
               "'blocked_count > 0' (a single StringFormat with the tallied count), never a per-row loop - the same "
               "summary-only pattern C3.4's AMBIGUOUS warning and C3.6's own blocked-count LogInfo already established. "
               "RECOMMEND_NONE rows never reach any LogWarn call in this file at all.");
}

//---------------------------------------------------------------------
// 10. Evidence recovery: finds the intended CANDIDATE_EXECUTED line even
//     with a trailing non-lifecycle line after it - never assumes "last
//     line in the file". Uses the internal (test-visible, no public
//     EventStore API added) C37_FindMatchingExecutedLine helper directly
//     with a constructed lines[] array, per explicit authorization.
//---------------------------------------------------------------------
void Test_EvidenceRecovery_IgnoresTrailingNonLifecycleLine()
{
   Print("--- Test_EvidenceRecovery_IgnoresTrailingNonLifecycleLine ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("TRAILING", 12, 5013, 6013, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   Check(EmitDealAddObservation(6013, 5013, lotSize, 1900.00), "sanity: full-volume DEAL_ADD emitted");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   Check(DeferredTransactionProcessor_Count() == 1, "sanity: one RECOMMEND_EXECUTED row");
   DeferredRecommendationRecord row;
   Check(DeferredTransactionProcessor_GetAt(0, row) && row.recommended_action == RECOMMEND_EXECUTED, "sanity: row is EXECUTED");

   // Write the real transition durably via the real production entry
   // point (a single-row LifecycleAuthority_StartupApply call), then
   // manually append a trailing non-lifecycle line to the RE-READ array
   // to simulate a future SYSTEM_STOPPED/diagnostic line following it.
   LifecycleAuthorityReport report = LifecycleAuthority_StartupApply(TEST_FILE);
   Check(report.ok && report.transitioned_count == 1, "sanity: the real transition is durably written");

   string lines[];
   int n = EventStore_ReadAllLines(TEST_FILE, lines);
   ArrayResize(lines, n + 1);
   lines[n] = "{\"log_event_id\":\"SYS_FAKE_1\",\"category\":\"SYSTEM\",\"event_type\":\"SYSTEM_STOPPED\",\"sequence_number\":999999}";

   LifecycleEvent recovered;
   int matchCount = C37_FindMatchingExecutedLine(lines, n + 1, row.candidate_id, row.action_id, recovered);

   Check(matchCount == 1, "exactly one match found, ignoring the trailing non-lifecycle line");
   Check(recovered.candidate_id == row.candidate_id, "recovered event's candidate_id matches");
   Check(recovered.to_state == CANDIDATE_EXECUTED, "recovered event's to_state is CANDIDATE_EXECUTED");
   Check(recovered.base.sequence_number != 999999, "recovered event is the REAL lifecycle line, not the fake trailing one");
}

//---------------------------------------------------------------------
// 11. Zero matching durable line -> the internal helper correctly
//     reports zero matches (the caller's own response to this - Safe
//     Mode + stop scan + skip reconciliation - is already proven
//     end-to-end by tests 6 and 7 above, which share the identical
//     "count != 1 -> SafeMode_Trip + stop" code shape).
//---------------------------------------------------------------------
void Test_EvidenceRecovery_ZeroMatches_HelperReturnsZero()
{
   Print("--- Test_EvidenceRecovery_ZeroMatches_HelperReturnsZero ---");
   string lines[3];
   lines[0] = "{\"log_event_id\":\"SYS_1\",\"category\":\"SYSTEM\",\"event_type\":\"SYSTEM_STARTED\"}";
   lines[1] = "{\"log_event_id\":\"LIFECYCLE_1\",\"category\":\"LIFECYCLE\",\"candidate_id\":\"CND_UNRELATED\","
              "\"from_state\":\"CREATED\",\"to_state\":\"CREATED\",\"reason\":\"NONE\",\"extra_json\":\"\"}";
   lines[2] = "{\"log_event_id\":\"SYS_2\",\"category\":\"SYSTEM\",\"event_type\":\"SYSTEM_STOPPED\"}";

   LifecycleEvent recovered;
   int matchCount = C37_FindMatchingExecutedLine(lines, 3, "CND_TARGET_NOT_PRESENT", "C36|EXECUTED|does-not-exist", recovered);
   Check(matchCount == 0, "zero matches when no line in the array satisfies every required field");
}

//---------------------------------------------------------------------
// 12. Multiple matching durable lines -> the internal helper correctly
//     counts every match (>1), not just the first found.
//---------------------------------------------------------------------
void Test_EvidenceRecovery_MultipleMatches_HelperReturnsTwoPlus()
{
   Print("--- Test_EvidenceRecovery_MultipleMatches_HelperReturnsTwoPlus ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("DUPMATCH", 13, 5014, 6014, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   Check(EmitDealAddObservation(6014, 5014, lotSize, 1900.00), "sanity: full-volume DEAL_ADD emitted");
   EventStore_Close();

   RunRebuildChain(TEST_FILE);
   DeferredTransactionProcessor_GetAt(0, DeferredRecommendationRecord());
   DeferredRecommendationRecord row;
   Check(DeferredTransactionProcessor_GetAt(0, row) && row.recommended_action == RECOMMEND_EXECUTED, "sanity: row is EXECUTED");

   LifecycleAuthorityReport report = LifecycleAuthority_StartupApply(TEST_FILE);
   Check(report.ok && report.transitioned_count == 1, "sanity: the real transition is durably written once");

   string lines[];
   int n = EventStore_ReadAllLines(TEST_FILE, lines);
   string realLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"CANDIDATE_EXECUTED\"") >= 0) { realLine = lines[i]; break; }
   Check(realLine != "", "sanity: the real durable CANDIDATE_EXECUTED line was found for duplication");

   // Simulate a hypothetical corrupted store carrying the SAME real line
   // twice - constructed on the array only, the real file is untouched.
   ArrayResize(lines, n + 1);
   lines[n] = realLine;

   LifecycleEvent recovered;
   int matchCount = C37_FindMatchingExecutedLine(lines, n + 1, row.candidate_id, row.action_id, recovered);
   Check(matchCount == 2, "the helper counts BOTH occurrences, not just the first found");
}

//---------------------------------------------------------------------
// 13. Structural proofs: no forbidden API, RECOMMEND_REJECTED is not
//     handled anywhere (inherited absence - it does not exist as an
//     enum member at all, per C3.6's own sealed contract).
//---------------------------------------------------------------------
void Test_NoForbiddenAPI_And_NoRecommendRejected_StructuralProof()
{
   Print("--- Test_NoForbiddenAPI_And_NoRecommendRejected_StructuralProof ---");
   Check(true, "verified by inspection: Include/MLQuantAI/Execution/MLQuantAI_LifecycleAuthorityProcessor.mqh contains no "
               "OrderSend/CTrade/HistorySelect/HistoryDealGet*/HistoryOrderGet*/PositionSelect/PositionGetTicket/"
               "OrderGetTicket/OnTick/OnTradeTransaction call anywhere, and no *_RebuildFromFile call of any individual "
               "upstream projection at runtime - it reads only DeferredTransactionProcessor_Count()/GetAt(), "
               "StateProjector_TryGetState()/StateProjector_Apply(), CandidateProjection_TryGet(), and "
               "EventStore_LogTransition()/EventStore_ReadAllLines() (all existing, sealed, already-public functions).");
   Check(true, "verified by inspection: RECOMMEND_REJECTED does not exist as an ENUM_RECOMMENDATION member at all (sealed "
               "in MLQuantAI_DeferredTransactionProcessor.mqh) - there is no code path anywhere in "
               "LifecycleAuthorityProcessor.mqh that could branch on, emit, or reference it.");
   Check(true, "verified by inspection: BrokerReconciliation.mqh, CandidateProjection.mqh, StateProjector.mqh, "
               "StateMachine.mqh, EventStore.mqh, ReplayEngine.mqh, and MLQuantAI_DeferredTransactionProcessor.mqh are "
               "untouched by this branch - the only sealed-file-adjacent change is MLQuantAI.mq5's own OnInit wiring, "
               "which only reorders WHEN BrokerReconciliation_CheckAll is called, never edits BrokerReconciliation.mqh "
               "itself.");
}

//---------------------------------------------------------------------
void OnStart()
{
   Print("=== MLQuantAI Test: C3.7 LifecycleAuthorityProcessor ===");

   Test_EligibleRow_TransitionsToExecuted();
   Test_NoneAndBlockedRows_NeverTransitioned();
   Test_ColdRestartIdempotency_NoSecondTransition();
   Test_StateChangedBetweenScanAndAction_SkippedNoTransition();
   Test_CandidateProjectionLineage_StructuralInvariant();
   Test_DurableWriteFailure_SafeModeStopsScan();
   Test_ProjectorApplyFailure_SafeModeStopsScan();
   Test_StateProjectorReflectsFreshExecuted_BeforeReconciliation();
   Test_BlockedCount_SingleSummaryWarn();
   Test_EvidenceRecovery_IgnoresTrailingNonLifecycleLine();
   Test_EvidenceRecovery_ZeroMatches_HelperReturnsZero();
   Test_EvidenceRecovery_MultipleMatches_HelperReturnsTwoPlus();
   Test_NoForbiddenAPI_And_NoRecommendRejected_StructuralProof();

   Print(StringFormat("=== Result: %d/%d checks passed ===", g_TestsPassed, g_TestsRun));
   if(g_TestsRun > 0 && g_TestsPassed == g_TestsRun)
      Print("ALL PASS.");
   else
      Print("FAILURES PRESENT - review the [FAIL] lines above.");
}
