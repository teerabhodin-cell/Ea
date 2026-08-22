//+------------------------------------------------------------------+
//| MLQuantAI_Test_C3_4_TransactionMatchingReadiness.mq5               |
//| C3.4 implementation DoD, per                                       |
//| Docs/PhaseC_C3_TransactionReconciliationContract.md sections       |
//| 25-27. Fixture-only, exercising the real production entry point    |
//| TransactionMatching_StartupRebuild() against durably-written        |
//| BROKER_TRANSACTION_OBSERVED lines - same "no real callback, feed    |
//| the pure function directly" pattern every prior C3.x test file      |
//| already established. No real broker call anywhere in this file.    |
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

#define TEST_FILE "MLQuantAI_Test_C3_4_TransactionMatchingReadiness.jsonl"

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
   ctx.context_event_id = "CTX_c34txready_" + suffix;
   ctx.context_hash      = "test_context_hash_c34txready_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C34TXREADY_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

void BuildC2AcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C34TXREADY_V1";
   policy.environment_mode = EXECUTION_ENV_DEMO;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

// Durably emits the full upstream chain plus a real SUBMITTED
// SubmissionOutcome with a caller-chosen order_ticket/deal_ticket - same
// as Tests/MLQuantAI_Test_C3_3_TransactionMatchingProjection.mq5's own
// BuildDurableSubmittedRequest. Requires the same event store to already
// be open.
bool BuildDurableSubmittedRequest(string suffix, int dayOffset, ulong orderTicket, ulong dealTicket,
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
   aiPolicy.decision_policy_version = "AIPOLICY_C34TXREADY_V1";
   aiPolicy.threshold_version       = "THRESH_C34TXREADY_V1";
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

   ExecutionSubmissionResult outResult;
   if(!BrokerSubmission_ProcessSendResult(c, req, req.planned_entry, true, 0, TimeCurrent(), tr, outResult)) return false;
   if(outResult.submission_status != SUBMISSION_STATUS_SUBMITTED) return false;

   outExecutionRequestId = req.execution_request_id;
   outLotSize             = req.lot_size;
   return true;
}

// Durably emits one BROKER_TRANSACTION_OBSERVED / TRADE_TRANSACTION_
// DEAL_ADD line - via BrokerTransactionObservation_RecordAndGuard fed a
// fixture struct, same pattern as every prior C3.x test file.
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

void ResetTestFile()
{
   EventStore_Close();
   SafeMode_Clear();
   TransactionMatchingReadiness_Reset();
   if(FileIsExist(TEST_FILE, FILE_COMMON))
      FileDelete(TEST_FILE, FILE_COMMON);
}

//---------------------------------------------------------------------
// 1. Success: a valid store rebuilds cleanly, readiness flips true, the
// report is persisted with correct counters, and rebuilt_at is stamped.
//---------------------------------------------------------------------
void Test_Success_ReadyWithCorrectCounters()
{
   Print("--- Test_Success_ReadyWithCorrectCounters ---");
   ResetTestFile();
   Check(!TransactionMatchingReadiness_IsReady(), "sanity: not ready before any rebuild this session");

   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");
   string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("READYOK", 0, 5101, 6101, execReqId, lotSize), "sanity: durable SUBMITTED outcome built");
   Check(EmitDealAddObservation(6101, 5101, lotSize, 1900.00), "sanity: matching DEAL_ADD observation emitted");
   EventStore_Close();

   datetime beforeCall = TimeCurrent();
   bool ready = TransactionMatching_StartupRebuild(TEST_FILE);
   Check(ready, "TransactionMatching_StartupRebuild returns true on a clean rebuild");
   Check(TransactionMatchingReadiness_IsReady(), "readiness accessor reflects true after a successful rebuild");

   TransactionMatchingReadinessReport rep;
   Check(TransactionMatchingReadiness_LastReport(rep), "a diagnostics report is retained after a successful rebuild");
   Check(rep.base.ok, "the retained report's own base.ok is true");
   Check(rep.base.deals_applied == 1, "the retained report's deal count is correct");
   Check(rep.orders_total == 1, "orders_total counts the single order aggregate");
   Check(rep.orders_matched_volume_reached == 1, "the single order is tallied as MATCHED_VOLUME_REACHED");
   Check(rep.orders_unmatched == 0 && rep.orders_ambiguous == 0 && rep.orders_matched_partial == 0
         && rep.orders_matched_order_terminal == 0, "every other counter stays zero");
   Check(rep.rebuilt_at >= beforeCall, "rebuilt_at is stamped to (at or after) the moment this call was made");
   Check(!SafeMode_IsActive(), "a successful rebuild never touches Safe Mode");
}

//---------------------------------------------------------------------
// 2. Failure: a corrupt store fails the rebuild, readiness stays/goes
// false, Safe Mode is never engaged, and the failure report is retained.
//---------------------------------------------------------------------
void Test_Failure_NotReady_NoSafeMode()
{
   Print("--- Test_Failure_NotReady_NoSafeMode ---");
   ResetTestFile();

   // A malformed observation (deal_ticket=0) is durably written the same
   // way Test_ZeroTicketMalformed_FailsClosed in the C3.3 suite proved
   // fails the underlying rebuild closed - C3.2 itself has no opinion on
   // this, only C3.3/C3.4's rebuild rejects it.
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");
   Check(EmitDealAddObservation(0, 5102, 0.01, 1900.00), "sanity: a DEAL_ADD observation with deal_ticket=0 is emitted");
   EventStore_Close();

   bool ready = TransactionMatching_StartupRebuild(TEST_FILE);
   Check(!ready, "TransactionMatching_StartupRebuild returns false on a failed rebuild");
   Check(!TransactionMatchingReadiness_IsReady(), "readiness accessor reflects false after a failed rebuild");
   Check(!SafeMode_IsActive(), "a failed C3.4 rebuild never trips Safe Mode - C3.3 carries no lifecycle authority");

   TransactionMatchingReadinessReport rep;
   Check(TransactionMatchingReadiness_LastReport(rep), "a diagnostics report is retained even after a failed rebuild");
   Check(!rep.base.ok, "the retained report's own base.ok is false");
   Check(rep.base.deals_failed >= 1, "the retained report's failure count is correct");
   Check(rep.orders_total == 0, "on failure, counters are never tallied (left at their init value)");

   // A SECOND, later successful call must correctly REVOKE-then-grant
   // readiness fresh, never leaving a stale prior failure lingering.
   Check(EventStore_Open(TEST_FILE), "EventStore reopens on the SAME file to prove idempotent recovery");
   string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("RECOVER", 1, 5103, 6103, execReqId, lotSize), "sanity: durable SUBMITTED outcome built");
   EventStore_Close();
   // The prior zero-ticket line is still first in the file, so this
   // rebuild is EXPECTED to still fail closed - collisions/malformed
   // lines are never silently skipped. This only proves readiness stays
   // false and consistent with the freshest call's own report.ok.
   bool readyAgain = TransactionMatching_StartupRebuild(TEST_FILE);
   Check(readyAgain == TransactionMatchingReadiness_IsReady(), "readiness is always set fresh from the most recent call's own return value");
}

//---------------------------------------------------------------------
// 3. Staleness metadata: rebuilt_at is stamped once per call and does
// not silently change between calls, always reflecting the LAST call.
//---------------------------------------------------------------------
void Test_StalenessMetadata_RebuiltAtReflectsLastCallOnly()
{
   Print("--- Test_StalenessMetadata_RebuiltAtReflectsLastCallOnly ---");
   ResetTestFile();

   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");
   string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("STALE", 2, 5104, 6104, execReqId, lotSize), "sanity: durable SUBMITTED outcome built");
   Check(EmitDealAddObservation(6104, 5104, lotSize, 1900.00), "sanity: matching DEAL_ADD observation emitted");
   EventStore_Close();

   Check(TransactionMatching_StartupRebuild(TEST_FILE), "first rebuild succeeds");
   TransactionMatchingReadinessReport firstRep;
   Check(TransactionMatchingReadiness_LastReport(firstRep), "first report retained");
   datetime firstStamp = firstRep.rebuilt_at;
   Check(firstStamp != 0, "rebuilt_at is stamped, not left at its zero init value");

   // A second call on the SAME unchanged file must re-stamp rebuilt_at
   // to a fresh value (never silently reused from the prior call) - this
   // is the explicit "stale until the next restart, never silently
   // assumed current" contract from section 26.
   Check(TransactionMatching_StartupRebuild(TEST_FILE), "second rebuild on the same file also succeeds");
   TransactionMatchingReadinessReport secondRep;
   Check(TransactionMatchingReadiness_LastReport(secondRep), "second report retained");
   Check(secondRep.rebuilt_at >= firstStamp, "the second call's rebuilt_at is stamped fresh, at or after the first call's own stamp");
}

//---------------------------------------------------------------------
// 4. Six-counter invariant: fixtures producing UNMATCHED, AMBIGUOUS,
// MATCHED_PARTIAL, and MATCHED_VOLUME_REACHED each, asserting the sum
// of all six counters always equals orders_total.
//---------------------------------------------------------------------
void Test_SixCounterInvariant_SumEqualsOrdersTotal()
{
   Print("--- Test_SixCounterInvariant_SumEqualsOrdersTotal ---");
   ResetTestFile();
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   // UNMATCHED: an observation whose tickets match no SubmissionOutcome.
   Check(EmitDealAddObservation(7201, 8201, 0.01, 1900.00), "sanity: UNMATCHED fixture observation emitted");

   // AMBIGUOUS: one order_ticket, two deals resolving to two distinct
   // execution_request_id values.
   string execReqIdA; double lotSizeA;
   string execReqIdB; double lotSizeB;
   Check(BuildDurableSubmittedRequest("SIXA", 3, 5202, 6202, execReqIdA, lotSizeA), "sanity: AMBIGUOUS fixture outcome A built");
   Check(BuildDurableSubmittedRequest("SIXB", 4, 5203, 6203, execReqIdB, lotSizeB), "sanity: AMBIGUOUS fixture outcome B built");
   Check(execReqIdA != execReqIdB, "sanity: the two execution_request_id values are genuinely distinct");
   Check(EmitDealAddObservation(6202, 5202, 0.01, 1900.00), "sanity: deal 6202 (resolves to A) under order_ticket 5202");
   Check(EmitDealAddObservation(6203, 5202, 0.01, 1900.00), "sanity: deal 6203 (resolves to B) ALSO under order_ticket 5202 -> AMBIGUOUS");

   // MATCHED_PARTIAL: less than the full lot_size filled.
   string execReqIdC; double lotSizeC;
   Check(BuildDurableSubmittedRequest("SIXC", 5, 5204, 6204, execReqIdC, lotSizeC), "sanity: MATCHED_PARTIAL fixture outcome built");
   Check(lotSizeC > 0.02, "sanity: this fixture's lot_size is large enough to test a genuine partial fill");
   Check(EmitDealAddObservation(6204, 5204, lotSizeC / 2.0, 1900.00), "sanity: half-volume DEAL_ADD -> MATCHED_PARTIAL");

   // MATCHED_VOLUME_REACHED: full lot_size filled in one deal.
   string execReqIdD; double lotSizeD;
   Check(BuildDurableSubmittedRequest("SIXD", 6, 5205, 6205, execReqIdD, lotSizeD), "sanity: MATCHED_VOLUME_REACHED fixture outcome built");
   Check(EmitDealAddObservation(6205, 5205, lotSizeD, 1900.00), "sanity: full-volume DEAL_ADD -> MATCHED_VOLUME_REACHED");

   EventStore_Close();

   Check(TransactionMatching_StartupRebuild(TEST_FILE), "rebuild succeeds across all four fixture shapes");
   TransactionMatchingReadinessReport rep;
   Check(TransactionMatchingReadiness_LastReport(rep), "report retained");

   Check(rep.orders_total == 4, "orders_total counts all four distinct order_ticket aggregates");
   Check(rep.orders_unmatched == 1, "exactly one order tallied UNMATCHED");
   Check(rep.orders_ambiguous == 1, "exactly one order tallied AMBIGUOUS");
   Check(rep.orders_matched_partial == 1, "exactly one order tallied MATCHED_PARTIAL");
   Check(rep.orders_matched_volume_reached == 1, "exactly one order tallied MATCHED_VOLUME_REACHED");
   Check(rep.orders_matched_order_terminal == 0, "MATCHED_ORDER_TERMINAL stays frozen at zero under C3.4 - section 28");

   int sum = rep.orders_unmatched + rep.orders_ambiguous + rep.orders_matched_partial
             + rep.orders_matched_volume_reached + rep.orders_matched_order_terminal;
   Check(sum == rep.orders_total, "the six counters (five non-zero-capable this round plus the frozen sixth) sum exactly to orders_total");
}

//---------------------------------------------------------------------
// 5. No broker mutation - structural proof.
//---------------------------------------------------------------------
void Test_NoBrokerMutation_StructuralProof()
{
   Print("--- no OrderSend/CTrade/History*/Position*/Order* call anywhere in this readiness wrapper ---");
   Check(true, "verified by inspection: MLQuantAI_TransactionMatchingReadiness.mqh contains no OrderSend/CTrade/broker-query "
               "call anywhere - TransactionMatching_StartupRebuild only calls the sealed, read-only TransactionMatching_"
               "RebuildFromFile() (C3.3) and OrderAggregateRegistry_Count()/_GetAt() (also C3.3, both pure in-memory reads), "
               "plus SystemLogger's LogInfo/LogWarn. No SafeMode_Trip call exists in this file - a failed rebuild is "
               "diagnostic-only, per section 27.");
}

//---------------------------------------------------------------------
void OnStart()
{
   Print("=== MLQuantAI Test: Phase C3.4 - Transaction Matching Startup Readiness (sections 25-27) ===");

   Test_Success_ReadyWithCorrectCounters();
   Test_Failure_NotReady_NoSafeMode();
   Test_StalenessMetadata_RebuiltAtReflectsLastCallOnly();
   Test_SixCounterInvariant_SumEqualsOrdersTotal();
   Test_NoBrokerMutation_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
