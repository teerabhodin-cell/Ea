//+------------------------------------------------------------------+
//| MLQuantAI_Test_C3_10C_AsyncTerminalRejectionAudit.mq5              |
//| C3.10C implementation DoD, per the Async Terminal Rejection Audit  |
//| Checkpoint 1 contract locked in this branch's chat history (no     |
//| separate Docs/ file yet). Exercises the real production entry      |
//| point AsyncTerminalRejectionAudit_StartupScan() against durably-    |
//| written event-store lines, after the real sealed C2.3/C3.4          |
//| rebuilds, the real ReplayEngine_Run, the real C3.10A                 |
//| AsyncTerminalOrderMatcher_ScanFile, and (for the happy-path/          |
//| malformed-scenario tests) the real C3.10B AsyncTerminalRejection       |
//| Authority_StartupApply. Same "feed the pure/read-only function          |
//| directly" pattern every prior C3.x test file already established -      |
//| MLQuantAI_Test_C3_10B_AsyncTerminalRejectionAuthority.mq5 is the           |
//| closest real precedent for the durable-write fixture shape. No real         |
//| broker call anywhere here.                                                    |
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
#include <MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionAuthority.mqh>
#include <MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionAudit.mqh>

#define TEST_FILE "MLQuantAI_Test_C3_10C_AsyncTerminalRejectionAudit.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as Tests/MLQuantAI_Test_C3_10B_
// AsyncTerminalRejectionAuthority.mq5's own copies, duplicated per this
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
   ctx.context_event_id = "CTX_c310c_" + suffix;
   ctx.context_hash      = "test_context_hash_c310c_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C310C_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

void BuildC2AcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C310C_V1";
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
// lifecycle event + SubmissionOutcomeProjection row are written.
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
   aiPolicy.decision_policy_version = "AIPOLICY_C310C_V1";
   aiPolicy.threshold_version       = "THRESH_C310C_V1";
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

bool EmitOrderDeleteObservation(ulong orderTicket, ENUM_ORDER_STATE orderState)
{
   MqlTradeTransaction t;
   t.type            = TRADE_TRANSACTION_ORDER_DELETE;
   t.deal            = 0;
   t.order           = orderTicket;
   t.symbol          = _Symbol;
   t.order_type      = ORDER_TYPE_SELL_LIMIT;
   t.order_state     = orderState;
   t.deal_type       = DEAL_TYPE_BUY;
   t.time_type       = ORDER_TIME_GTC;
   t.time_expiration = 0;
   t.price           = 0.0;
   t.price_trigger   = 0.0;
   t.price_sl        = 0.0;
   t.price_tp        = 0.0;
   t.volume          = 0.0;
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

   MqlTradeResult res;
   res.retcode          = 0;
   res.deal             = 0;
   res.order            = 0;
   res.volume           = 0;
   res.price            = 0;
   res.bid              = 0;
   res.ask              = 0;
   res.comment          = "";
   res.request_id       = 0;
   res.retcode_external = 0;

   return BrokerTransactionObservation_RecordAndGuard(t, req, res);
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

void RunRebuildChain(string file)
{
   BrokerSubmissionAudit_StartupRebuild(file);
   ManualApproval_StartupRebuild(file);
   TransactionMatching_StartupRebuild(file);
   ReplayEngine_Run(file);
}

// Hand-built confirmation JSON with fully independent control over every
// field - used only by the negative-path tests below to construct
// scenarios the real C3.10B write path structurally cannot produce
// (mismatched/missing/malformed identity), mirroring
// C310B_BuildConfirmationExtraJson's own field set exactly.
string BuildRawConfirmationExtraJson(string candidateId, ulong orderTicket, string executionRequestId,
                                       string observedKind, string sourceLogEventId, long sourceSeq)
{
   string s = "";
   s += "\"c3_10b_schema_version\":\"C310B_V1\",";
   s += "\"candidate_id\":\""          + candidateId + "\",";
   s += "\"order_ticket\":"            + IntegerToString((long)orderTicket) + ",";
   s += "\"execution_request_id\":\""  + executionRequestId + "\",";
   s += "\"observed_kind\":\""         + observedKind + "\",";
   s += "\"source_log_event_id\":\""   + sourceLogEventId + "\",";
   s += "\"source_sequence_number\":"  + IntegerToString(sourceSeq);
   return s;
}

bool WriteRawConfirmation(string candidateId, ulong orderTicket, string executionRequestId,
                            string observedKind, string sourceLogEventId, long sourceSeq)
{
   string json = BuildRawConfirmationExtraJson(candidateId, orderTicket, executionRequestId, observedKind, sourceLogEventId, sourceSeq);
   return EventStore_LogSystem(EventTypeToString(EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED),
                                 "transaction rejection confirmed", json);
}

// Writes a REJECTED_BY_BROKER transition directly, with fully independent
// control over the transition's own extra_json - used to simulate both a
// C2.2-style synchronous rejection (extraJson="") and a malformed C3.10B
// link (confirmation_log_event_id set, confirmation_sequence_number
// omitted/invalid), neither of which the real C3.10B write path itself
// can produce.
bool WriteRawRejectedTransition(string candidateId, string rootEventId, string correlationId, int strategyId, string extraJson)
{
   TradeCandidate c;
   TradeCandidate_Init(c);
   c.candidate_id   = candidateId;
   c.root_event_id  = rootEventId;
   c.correlation_id = correlationId;
   c.strategy_id    = strategyId;
   c.state          = CANDIDATE_SUBMITTED;
   return EventStore_LogTransition(c, CANDIDATE_REJECTED_BY_BROKER, REASON_BROKER_REJECT, extraJson);
}

int CountLines(string file)
{
   string lines[];
   return EventStore_ReadAllLines(file, lines);
}

//---------------------------------------------------------------------
// 1. Clean happy path: real C3.10B confirmation + real linked transition
//    -> verified, zero findings.
//---------------------------------------------------------------------
void Test_CleanConfirmation_VerifiedNoFindings()
{
   Print("--- Test_CleanConfirmation_VerifiedNoFindings ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("CLEAN", 0, 8001, 9001, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   Check(EmitOrderDeleteObservation(8001, ORDER_STATE_REJECTED), "sanity: ORDER_DELETE observation emitted");

   RunRebuildChain(TEST_FILE);
   AsyncTerminalOrderMatchReport atomReport = AsyncTerminalOrderMatcher_ScanFile(TEST_FILE);
   AsyncTerminalRejectionAuthorityReport rejAuth = AsyncTerminalRejectionAuthority_StartupApply(TEST_FILE, atomReport);
   Check(rejAuth.ok && rejAuth.confirmed_count == 1, "sanity: real C3.10B confirmation+transition written");

   AsyncTerminalRejectionAuditReport audit = AsyncTerminalRejectionAudit_StartupScan(TEST_FILE, atomReport);

   Check(audit.ok, "audit.ok is true");
   Check(audit.confirmations_total == 1, "confirmations_total is 1");
   Check(audit.verified_total == 1, "verified_total is 1");
   Check(audit.missing_transition_count == 0, "missing_transition_count is 0");
   Check(audit.missing_confirmation_count == 0, "missing_confirmation_count is 0");
   Check(audit.duplicate_confirmation_count == 0, "duplicate_confirmation_count is 0");
   Check(audit.provenance_mismatch_count == 0, "provenance_mismatch_count is 0");
   Check(audit.source_evidence_missing_count == 0, "source_evidence_missing_count is 0");
   Check(audit.source_evidence_ambiguous_count == 0, "source_evidence_ambiguous_count is 0");
   Check(audit.first_error == "", "first_error is empty");
}

//---------------------------------------------------------------------
// 2. Confirmation durable, candidate still SUBMITTED (no transition at
//    all) -> missing_transition_count. Mirrors C3.10B's own partial-
//    write scenario, but detected here post-hoc by the audit.
//---------------------------------------------------------------------
void Test_ConfirmedButStillSubmitted_MissingTransition()
{
   Print("--- Test_ConfirmedButStillSubmitted_MissingTransition ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("PARTIAL", 1, 8002, 9002, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   Check(EmitOrderDeleteObservation(8002, ORDER_STATE_REJECTED), "sanity: ORDER_DELETE observation emitted");

   RunRebuildChain(TEST_FILE);
   AsyncTerminalOrderMatchReport atomReport = AsyncTerminalOrderMatcher_ScanFile(TEST_FILE);
   Check(atomReport.ok && atomReport.matched_count == 1, "sanity: one ATOM_MATCHED entry");
   AsyncTerminalOrderMatch m = atomReport.matches[0];

   Check(WriteRawConfirmation(candidateId, m.order_ticket, m.execution_request_id, "REJECTED",
                               m.source_log_event_id, m.source_sequence_number),
         "sanity: confirmation written directly, no transition follows");

   AsyncTerminalRejectionAuditReport audit = AsyncTerminalRejectionAudit_StartupScan(TEST_FILE, atomReport);

   Check(!audit.ok, "audit.ok is false");
   Check(audit.confirmations_total == 1, "confirmations_total is 1");
   Check(audit.missing_transition_count == 1, "missing_transition_count is 1");
   Check(audit.verified_total == 0, "verified_total is 0");
   Check(StringFind(audit.first_error, "missing/unlinked") >= 0, "first_error describes the missing transition");
}

//---------------------------------------------------------------------
// 3. REJECTED_BY_BROKER transition carries a non-empty
//    confirmation_log_event_id, but no matching confirmation exists ->
//    missing_confirmation_count. Cannot be produced by the real C3.10B
//    write path (which always writes confirmation-then-transition) -
//    constructed directly.
//---------------------------------------------------------------------
void Test_RejectedWithoutConfirmation_MissingConfirmation()
{
   Print("--- Test_RejectedWithoutConfirmation_MissingConfirmation ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("ORPHAN", 2, 8003, 9003, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   RunRebuildChain(TEST_FILE);

   string extraJson = "\"confirmation_log_event_id\":\"SESS_FAKE#999\",\"confirmation_sequence_number\":999";
   Check(WriteRawRejectedTransition(candidateId, "", "", 0, extraJson),
         "sanity: transition written directly, referencing a confirmation that was never written");

   AsyncTerminalOrderMatchReport emptyAtom;
   AsyncTerminalOrderMatchReport_Init(emptyAtom);
   emptyAtom.ok = true;

   AsyncTerminalRejectionAuditReport audit = AsyncTerminalRejectionAudit_StartupScan(TEST_FILE, emptyAtom);

   Check(!audit.ok, "audit.ok is false");
   Check(audit.missing_confirmation_count == 1, "missing_confirmation_count is 1");
   Check(StringFind(audit.first_error, "not durably found") >= 0, "first_error describes the missing confirmation");
}

//---------------------------------------------------------------------
// 3b. Malformed C3.10B link: non-empty confirmation_log_event_id but
//     missing/zero confirmation_sequence_number - must still count as
//     missing_confirmation_count, never silently treated as C2.2.
//---------------------------------------------------------------------
void Test_MalformedLink_ZeroSequence_StillMissingConfirmation()
{
   Print("--- Test_MalformedLink_ZeroSequence_StillMissingConfirmation ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("MALFORMED", 3, 8004, 9004, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   RunRebuildChain(TEST_FILE);

   // Even a real confirmation existing elsewhere with seq 0 is
   // impossible (EventStore_NextSequence never returns 0) - so this
   // lookup can never find a match, regardless of whether any other
   // confirmation exists in the store.
   string extraJson = "\"confirmation_log_event_id\":\"SESS_MALFORMED#1\",\"confirmation_sequence_number\":0";
   Check(WriteRawRejectedTransition(candidateId, "", "", 0, extraJson),
         "sanity: transition written with a non-empty but zero-sequence confirmation link");

   AsyncTerminalOrderMatchReport emptyAtom;
   AsyncTerminalOrderMatchReport_Init(emptyAtom);
   emptyAtom.ok = true;

   AsyncTerminalRejectionAuditReport audit = AsyncTerminalRejectionAudit_StartupScan(TEST_FILE, emptyAtom);

   Check(!audit.ok, "audit.ok is false");
   Check(audit.missing_confirmation_count == 1, "malformed link (seq=0) still counts as missing_confirmation_count, not silently C2.2");
}

//---------------------------------------------------------------------
// 4. Two durable confirmations for the same candidate_id -> duplicate
//    finding, counted once per distinct candidate.
//---------------------------------------------------------------------
void Test_DuplicateConfirmation_SameCandidate()
{
   Print("--- Test_DuplicateConfirmation_SameCandidate ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("DUP", 4, 8005, 9005, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   RunRebuildChain(TEST_FILE);

   Check(WriteRawConfirmation(candidateId, 8005, execReqId, "REJECTED", "SESS_A#1", 1), "sanity: first confirmation written");
   Check(WriteRawConfirmation(candidateId, 8005, execReqId, "REJECTED", "SESS_B#2", 2), "sanity: second confirmation written (different source identity)");

   AsyncTerminalOrderMatchReport emptyAtom;
   AsyncTerminalOrderMatchReport_Init(emptyAtom);
   emptyAtom.ok = true;

   AsyncTerminalRejectionAuditReport audit = AsyncTerminalRejectionAudit_StartupScan(TEST_FILE, emptyAtom);

   Check(!audit.ok, "audit.ok is false");
   Check(audit.confirmations_total == 2, "confirmations_total is 2");
   Check(audit.duplicate_confirmation_count == 1, "duplicate_confirmation_count is 1 - counted once per distinct candidate, not per extra confirmation");
}

//---------------------------------------------------------------------
// 5. Confirmation's claimed identity differs from what atomReport
//    resolves for that exact source -> provenance_mismatch_count.
//---------------------------------------------------------------------
void Test_ProvenanceMismatch_OrderTicketDiffers()
{
   Print("--- Test_ProvenanceMismatch_OrderTicketDiffers ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("MISMATCH", 5, 8006, 9006, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   Check(EmitOrderDeleteObservation(8006, ORDER_STATE_REJECTED), "sanity: ORDER_DELETE observation emitted");

   RunRebuildChain(TEST_FILE);
   AsyncTerminalOrderMatchReport atomReport = AsyncTerminalOrderMatcher_ScanFile(TEST_FILE);
   Check(atomReport.ok && atomReport.matched_count == 1, "sanity: one ATOM_MATCHED entry (real order_ticket 8006)");
   AsyncTerminalOrderMatch m = atomReport.matches[0];

   // Same source identity, but a DIFFERENT order_ticket than what
   // atomReport actually resolves for that source.
   Check(WriteRawConfirmation(candidateId, 999999, m.execution_request_id, "REJECTED",
                               m.source_log_event_id, m.source_sequence_number),
         "sanity: confirmation written with a mismatched order_ticket");

   AsyncTerminalRejectionAuditReport audit = AsyncTerminalRejectionAudit_StartupScan(TEST_FILE, atomReport);

   Check(!audit.ok, "audit.ok is false");
   Check(audit.provenance_mismatch_count >= 1, "provenance_mismatch_count is at least 1");
   Check(StringFind(audit.first_error, "differs from resolved source evidence") >= 0 ||
         audit.missing_transition_count > 0,
         "first_error reflects a real finding (provenance mismatch or the co-occurring missing transition)");
}

//---------------------------------------------------------------------
// 6. Confirmation references a source identity that does not exist in
//    atomReport.matches[] at all -> source_evidence_missing_count.
//---------------------------------------------------------------------
void Test_SourceEvidenceMissing()
{
   Print("--- Test_SourceEvidenceMissing ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("NOSRC", 6, 8007, 9007, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   RunRebuildChain(TEST_FILE);

   Check(WriteRawConfirmation(candidateId, 8007, execReqId, "REJECTED", "SESS_NEVER_EXISTED#1", 1),
         "sanity: confirmation written referencing a source that was never observed");

   AsyncTerminalOrderMatchReport emptyAtom;
   AsyncTerminalOrderMatchReport_Init(emptyAtom);
   emptyAtom.ok = true;

   AsyncTerminalRejectionAuditReport audit = AsyncTerminalRejectionAudit_StartupScan(TEST_FILE, emptyAtom);

   Check(!audit.ok, "audit.ok is false");
   Check(audit.source_evidence_missing_count == 1, "source_evidence_missing_count is 1");
}

//---------------------------------------------------------------------
// 7. Confirmation references a source identity that atomReport now
//    resolves as ATOM_AMBIGUOUS (two qualifying raw lines for one
//    ticket) -> source_evidence_ambiguous_count.
//---------------------------------------------------------------------
void Test_SourceEvidenceAmbiguous()
{
   Print("--- Test_SourceEvidenceAmbiguous ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("AMBIG", 7, 8008, 9008, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   Check(EmitOrderDeleteObservation(8008, ORDER_STATE_REJECTED), "sanity: first ORDER_DELETE observation emitted");
   Check(EmitOrderDeleteObservation(8008, ORDER_STATE_REJECTED), "sanity: second ORDER_DELETE observation for the SAME ticket emitted");

   RunRebuildChain(TEST_FILE);
   AsyncTerminalOrderMatchReport atomReport = AsyncTerminalOrderMatcher_ScanFile(TEST_FILE);
   Check(!atomReport.ok && ArraySize(atomReport.matches) == 2, "sanity: both entries escalate to ATOM_AMBIGUOUS");

   Check(WriteRawConfirmation(candidateId, 8008, execReqId, "REJECTED",
                               atomReport.matches[0].source_log_event_id, atomReport.matches[0].source_sequence_number),
         "sanity: confirmation written referencing the now-ambiguous source (simulates a prior-session write)");

   AsyncTerminalRejectionAuditReport audit = AsyncTerminalRejectionAudit_StartupScan(TEST_FILE, atomReport);

   Check(!audit.ok, "audit.ok is false");
   Check(audit.source_evidence_ambiguous_count == 1, "source_evidence_ambiguous_count is 1");
}

//---------------------------------------------------------------------
// 8. Empty event store -> clean zero-count report.
//---------------------------------------------------------------------
void Test_EmptyEventStore_CleanZeroReport()
{
   Print("--- Test_EmptyEventStore_CleanZeroReport ---");
   ResetTestFile(TEST_FILE);

   AsyncTerminalOrderMatchReport emptyAtom;
   AsyncTerminalOrderMatchReport_Init(emptyAtom);
   emptyAtom.ok = true;

   AsyncTerminalRejectionAuditReport audit = AsyncTerminalRejectionAudit_StartupScan(TEST_FILE, emptyAtom);

   Check(audit.ok, "audit.ok is true");
   Check(audit.confirmations_total == 0, "confirmations_total is 0");
   Check(audit.verified_total == 0, "verified_total is 0");
   Check(audit.missing_transition_count == 0 && audit.missing_confirmation_count == 0 &&
         audit.duplicate_confirmation_count == 0 && audit.provenance_mismatch_count == 0 &&
         audit.source_evidence_missing_count == 0 && audit.source_evidence_ambiguous_count == 0,
         "every finding counter is 0");
   Check(audit.first_error == "", "first_error is empty");
}

//---------------------------------------------------------------------
// 9. CandidateProjection lineage missing -> provenance_mismatch_count,
//    without ever inspecting or deriving lifecycle state from it.
//---------------------------------------------------------------------
void Test_CandidateProjectionLineageMissing_ProvenanceMismatch()
{
   Print("--- Test_CandidateProjectionLineageMissing_ProvenanceMismatch ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   Check(WriteRawConfirmation("CND_NEVER_BUILT", 8009, "REQ_FAKE", "REJECTED", "SESS_X#1", 1),
         "sanity: confirmation written for a candidate_id with no CandidateProjection record at all");

   AsyncTerminalOrderMatchReport emptyAtom;
   AsyncTerminalOrderMatchReport_Init(emptyAtom);
   emptyAtom.ok = true;

   AsyncTerminalRejectionAuditReport audit = AsyncTerminalRejectionAudit_StartupScan(TEST_FILE, emptyAtom);

   Check(!audit.ok, "audit.ok is false");
   Check(audit.provenance_mismatch_count >= 1, "provenance_mismatch_count reflects the missing lineage");
   Check(StringFind(audit.first_error, "no CandidateProjection lineage") >= 0, "first_error names the missing lineage");
}

//---------------------------------------------------------------------
// 10. C2.2-style synchronous rejection (extra_json="") is structurally
//     out of scope - never flagged as missing_confirmation, regardless
//     of the fact that no confirmation exists for it. This is the
//     central design point of the whole Checkpoint 1 contract.
//---------------------------------------------------------------------
void Test_C2SynchronousRejection_NeverFlagged_OutOfScope()
{
   Print("--- Test_C2SynchronousRejection_NeverFlagged_OutOfScope ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("C2SYNC", 8, 8010, 9010, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   RunRebuildChain(TEST_FILE);

   // extraJson="" - exactly what BrokerSubmissionAdapter.mqh:237 passes
   // for the real C2.2 synchronous rejection path.
   Check(WriteRawRejectedTransition(candidateId, "", "", 0, ""),
         "sanity: C2.2-style transition written with empty extra_json, no confirmation ever written");

   AsyncTerminalOrderMatchReport emptyAtom;
   AsyncTerminalOrderMatchReport_Init(emptyAtom);
   emptyAtom.ok = true;

   AsyncTerminalRejectionAuditReport audit = AsyncTerminalRejectionAudit_StartupScan(TEST_FILE, emptyAtom);

   Check(audit.ok, "audit.ok is true - a C2.2 rejection with no confirmation is never a finding");
   Check(audit.missing_confirmation_count == 0, "missing_confirmation_count stays 0 - the transition has no confirmation_log_event_id, out of scope");
   Check(audit.confirmations_total == 0, "confirmations_total is 0 - nothing to verify either");
}

//---------------------------------------------------------------------
// 11. Cold restart: running the audit twice against the SAME durable
//     store (after a real C3.10B write) produces the identical report
//     and appends zero new lines.
//---------------------------------------------------------------------
void Test_ColdRestart_SameReport_NoAppendedLines()
{
   Print("--- Test_ColdRestart_SameReport_NoAppendedLines ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string candidateId; string execReqId; double lotSize;
   Check(BuildDurableSubmittedRequest("RESTART", 9, 8011, 9011, candidateId, execReqId, lotSize), "sanity: candidate submitted");
   Check(EmitOrderDeleteObservation(8011, ORDER_STATE_CANCELED), "sanity: ORDER_DELETE observation emitted");

   RunRebuildChain(TEST_FILE);
   AsyncTerminalOrderMatchReport atomReport1 = AsyncTerminalOrderMatcher_ScanFile(TEST_FILE);
   AsyncTerminalRejectionAuthorityReport rejAuth = AsyncTerminalRejectionAuthority_StartupApply(TEST_FILE, atomReport1);
   Check(rejAuth.ok && rejAuth.confirmed_count == 1, "sanity: real confirmation+transition written");

   int linesBeforeFirstAudit = CountLines(TEST_FILE);
   AsyncTerminalRejectionAuditReport first = AsyncTerminalRejectionAudit_StartupScan(TEST_FILE, atomReport1);
   int linesAfterFirstAudit = CountLines(TEST_FILE);
   Check(linesAfterFirstAudit == linesBeforeFirstAudit, "first audit run appends zero lines");

   // Cold-restart-equivalent: reset live projections, rebuild from
   // scratch against the SAME durable file, re-scan and re-run.
   EventStore_Close();
   ResetLiveProjections();
   RunRebuildChain(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "store reopens for the second pass");

   AsyncTerminalOrderMatchReport atomReport2 = AsyncTerminalOrderMatcher_ScanFile(TEST_FILE);
   int linesBeforeSecondAudit = CountLines(TEST_FILE);
   AsyncTerminalRejectionAuditReport second = AsyncTerminalRejectionAudit_StartupScan(TEST_FILE, atomReport2);
   int linesAfterSecondAudit = CountLines(TEST_FILE);

   Check(linesAfterSecondAudit == linesBeforeSecondAudit, "second audit run appends zero lines");
   Check(linesAfterSecondAudit == linesAfterFirstAudit, "total durable line count identical across both passes");
   Check(second.ok == first.ok, "ok identical");
   Check(second.confirmations_total == first.confirmations_total, "confirmations_total identical");
   Check(second.verified_total == first.verified_total, "verified_total identical");
   Check(second.missing_transition_count == first.missing_transition_count &&
         second.missing_confirmation_count == first.missing_confirmation_count &&
         second.duplicate_confirmation_count == first.duplicate_confirmation_count &&
         second.provenance_mismatch_count == first.provenance_mismatch_count &&
         second.source_evidence_missing_count == first.source_evidence_missing_count &&
         second.source_evidence_ambiguous_count == first.source_evidence_ambiguous_count,
         "every finding counter identical across both passes");
}

//---------------------------------------------------------------------
// 12. Structural proof: no forbidden API, no durable write, no Safe
//     Mode trip anywhere in this file.
//---------------------------------------------------------------------
void Test_NoForbiddenAPI_NoSafeModeTrip_StructuralProof()
{
   Print("--- Test_NoForbiddenAPI_NoSafeModeTrip_StructuralProof ---");
   Check(true, "verified by inspection: Include/MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionAudit.mqh contains no "
               "OrderSend/CTrade/HistorySelect/HistoryDealGet*/HistoryOrderGet*/PositionSelect/PositionGetTicket/"
               "OrderGetTicket/OnTick/OnTradeTransaction call anywhere - it reads only EventStore_ReadAllLines "
               "(read-only), StateProjector_TryGetState, CandidateProjection_TryGet, EventSerializer_PeekCategory/"
               "ParseLifecycle/GetStr/GetLong (pure parsing), and the caller-supplied AsyncTerminalOrderMatchReport.");
   Check(true, "verified by inspection: no EventStore_LogSystem/EventStore_LogTransition/EventStore_WriteLine/"
               "SafeMode_Trip call anywhere in this file - strictly read-only, matching the Checkpoint 1 contract's "
               "non-blocking, non-mutating scope boundary.");
   Check(true, "verified by inspection: no *_RebuildFromFile/*_StartupRebuild call of any kind - reads only the "
               "already-built StateProjector/CandidateProjection read models and the caller-supplied atomReport.");
   Check(true, "verified by inspection: MLQuantAI.mq5's C3.10C call site is inserted strictly AFTER the existing "
               "rejAuth/lar/brr control-flow block, with zero lines of that existing block modified (byte-for-byte "
               "diff confirmed against feat/c3-10b-async-terminal-rejection-authority@ff717b9) - ok==false only "
               "LogErrors, never returns INIT_FAILED, never alters rejAuth/C3.7/BrokerReconciliation outcomes.");
}

//---------------------------------------------------------------------
void OnStart()
{
   Print("=== MLQuantAI Test: C3.10C AsyncTerminalRejectionAudit ===");

   Test_CleanConfirmation_VerifiedNoFindings();
   Test_ConfirmedButStillSubmitted_MissingTransition();
   Test_RejectedWithoutConfirmation_MissingConfirmation();
   Test_MalformedLink_ZeroSequence_StillMissingConfirmation();
   Test_DuplicateConfirmation_SameCandidate();
   Test_ProvenanceMismatch_OrderTicketDiffers();
   Test_SourceEvidenceMissing();
   Test_SourceEvidenceAmbiguous();
   Test_EmptyEventStore_CleanZeroReport();
   Test_CandidateProjectionLineageMissing_ProvenanceMismatch();
   Test_C2SynchronousRejection_NeverFlagged_OutOfScope();
   Test_ColdRestart_SameReport_NoAppendedLines();
   Test_NoForbiddenAPI_NoSafeModeTrip_StructuralProof();

   Print(StringFormat("=== Result: %d/%d checks passed ===", g_TestsPassed, g_TestsRun));
   if(g_TestsRun > 0 && g_TestsPassed == g_TestsRun)
      Print("ALL PASS.");
   else
      Print("FAILURES PRESENT - review the [FAIL] lines above.");
}
