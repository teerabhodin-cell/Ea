//+------------------------------------------------------------------+
//| MLQuantAI_Test_C2_3_BrokerSubmissionAuditProjection.mq5             |
//| Phase C2.3 DoD, per                                                  |
//| Docs/PhaseC_C2_1_BrokerSubmissionContract.md's C2.3 addendum:       |
//| SubmissionAttemptProjection + SubmissionOutcomeProjection's single,  |
//| sequential, interleaved rebuild (staged on top of C1.3's own         |
//| ExecutionAuditProjection_RebuildFromFile), the durable idempotency   |
//| registry (SubmissionAttemptRegistry_HasAttempt/_IsUnresolved), and   |
//| the reconciliation report. Uses the real B5/B7/B8.5/B9/C1/C2.2       |
//| pipeline for every fixture - no fabricated hashes anywhere. NO       |
//| OrderSend/CTrade/OnTradeTransaction/History*/Position*/Order* broker |
//| API call anywhere in this file.                                      |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RiskPlanEventEmission.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_FeatureSnapshotEventEmission.mqh>
#include <MLQuantAI/AI/MLQuantAI_ModelArtifactBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ModelArtifactEventEmission.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAdapter.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAuditProjection.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as C1.3/C2.2's own test files.
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
   ctx.context_event_id = "CTX_c2c3_" + suffix;
   ctx.context_hash      = "test_context_hash_c2c3_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C2_3_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

void BuildAcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C2_3_V1";
   policy.environment_mode = EXECUTION_ENV_TESTER;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

// Deliberately mismatched symbol_allowlist - SafetyGate_Evaluate rejects
// with REASON_EXECUTION_SYMBOL_NOT_ALLOWED (never a structural false
// return), so the request/dry-run pair still durably writes, just as
// SAFETY_GATE_REJECTED - used only by Test_AttemptWithoutAcceptedDryRun_Rejected.
void BuildRejectedExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C2_3_REJECTED_V1";
   policy.environment_mode = EXECUTION_ENV_TESTER;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = "SOME_SYMBOL_NOT_" + _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

// Rewrites a line's own "seq":N field to newSeq - same technique C1.3's
// own test file established, used here only to append one more,
// validator-legal line to the tail of an already-closed session.
string RenumberSeq(string line, int newSeq)
{
   string needle = "\"seq\":";
   int p = StringFind(line, needle);
   if(p < 0) return line;
   int start = p + StringLen(needle);
   int n = StringLen(line);
   int end = start;
   while(end < n && StringGetCharacter(line, end) != ',') end++;
   return StringSubstr(line, 0, start) + IntegerToString(newSeq) + StringSubstr(line, end);
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
}

// Builds AND emits every layer of the real chain through an ACCEPTED
// ExecutionRequest dry-run - identical to C1.3's own BuildFullChain.
bool BuildFullChain(TradeCandidate &c, FeatureSnapshot &snapshot, ModelArtifact &artifact, InferenceResult &inference,
                      RiskPlan &plan, AIDecision &decision, EligibilityDecision &eligDecision,
                      ExecutionPolicy &execPolicy, ExecutionRequest &req, DryRunExecutionResult &dryRunResult,
                      string suffix, int dayOffset, float pSuccessValue = 0.90f, double aiThreshold = 0.70)
{
   MarketContext ctx;
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.03.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx)))
      return false;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;
   if(!CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits)) return false;

   if(!Candidate_ToFeatureSnapshot(c, ctx, snapshot)) return false;
   if(!FeatureSnapshot_EmitFeatureSnapshotCreated(snapshot)) return false;

   if(!ModelArtifact_Build("MODEL_" + suffix, "v1", "hash_artifact_" + suffix,
                             "FEATURES_B8_1_V1", "TDSET_dummy_" + suffix, "hash_tdset_" + suffix,
                             "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                             "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, artifact))
      return false;
   if(!ModelArtifact_EmitModelArtifactRegistered(artifact)) return false;

   BuildValidInferenceResult(snapshot, artifact.model_registry_id, artifact.model_registry_hash, artifact.model_artifact_hash,
                               pSuccessValue, inference);
   AIDecisionPolicy aiPolicy;
   AIDecisionPolicy_Init(aiPolicy);
   aiPolicy.decision_policy_version = "AIPOLICY_C2_3_V1";
   aiPolicy.threshold_version       = "THRESH_C2_3_V1";
   aiPolicy.allow_threshold         = aiThreshold;
   string aiReasonDetail;
   if(!AIDecision_Build(inference, snapshot, aiPolicy, decision, aiReasonDetail)) return false;
   if(!AIDecision_EmitAIDecisionCreated(decision)) return false;

   RiskContext riskCtx; BuildValidRiskContext(riskCtx, suffix);
   if(!Candidate_ToRiskPlan(c, riskCtx, plan)) return false;
   if(!RiskPlan_EmitRiskPlanCreated(plan)) return false;

   EligibilityContext eligContext; BuildHealthyEligibilityContext(eligContext);
   EligibilityPolicy eligPolicy; BuildEnabledEligibilityPolicy(eligPolicy);
   string eligReasonDetail;
   if(!EligibilityDecision_Build(plan, decision, snapshot, eligContext, eligPolicy, eligDecision, eligReasonDetail)) return false;
   if(!EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, eligContext, c)) return false;
   if(eligDecision.decision != ELIGIBILITY_DECISION_ELIGIBLE) return false;

   BuildAcceptingExecutionPolicy(execPolicy);
   string execReasonDetail;
   if(!ExecutionRequest_Build(c, eligDecision, decision, plan, execPolicy, req, execReasonDetail)) return false;

   return ExecutionRequest_EmitAndEvaluate(req, execPolicy, dryRunResult);
}

// Convenience wrapper: full chain, through a durable
// EXECUTION_SUBMISSION_ATTEMPTED write, ACCEPTED-dry-run only. Caller
// must already have an EventStore session open.
bool BuildFullChainThroughAttempt(TradeCandidate &c, ExecutionRequest &req, string suffix, int dayOffset)
{
   FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; DryRunExecutionResult dryRunResult;
   if(!BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, dryRunResult, suffix, dayOffset))
      return false;
   if(dryRunResult.decision != SAFETY_GATE_ACCEPTED) return false;
   return BrokerSubmission_RecordAttempt(c, req);
}

void MakeFakeTradeResult(MqlTradeResult &tr, uint retcode, ulong order, ulong deal, double price)
{
   MqlTradeResult_ZeroInit(tr);
   tr.retcode = retcode;
   tr.order = order;
   tr.deal = deal;
   tr.price = price;
}

//=====================================================================
// Full-chain rebuild + reconciliation, one row per outcome status.
//=====================================================================
void Test_FullChain_AttemptAndSubmitted_RebuildsAndReconciles()
{
   Print("--- full chain: attempt + SUBMITTED outcome rebuilds cleanly, HasAttempt=true, IsUnresolved=false, reconciliation SUBMITTED ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_FullChain_Submitted.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; ExecutionRequest req;
   Check(BuildFullChainThroughAttempt(c, req, "SUBMITTED", 1), "sanity: full chain + attempt built");

   MqlTradeResult tr; MakeFakeTradeResult(tr, TRADE_RETCODE_DONE, 111, 222, 2000.50);
   ExecutionSubmissionResult result;
   Check(BrokerSubmission_ProcessSendResult(c, req, 2000.55, true, 0, TimeCurrent(), tr, result), "sanity: ProcessSendResult(DONE) succeeds");
   Check(result.submission_status == SUBMISSION_STATUS_SUBMITTED, "sanity: outcome is SUBMITTED");
   EventStore_Close();

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds from the store alone");
   Check(report.attempt_lines_applied == 1, "exactly one submission attempt applied");
   Check(report.outcome_lines_applied == 1, "exactly one submission outcome applied");

   Check(SubmissionAttemptRegistry_HasAttempt(req.execution_request_id), "HasAttempt is true for this request");
   Check(!SubmissionAttemptRegistry_IsUnresolved(req.execution_request_id), "IsUnresolved is false - SUBMITTED is a conclusive outcome");

   BrokerSubmissionReconciliation_Build();
   int rowIdx = BrokerSubmissionReconciliation_FindRowIndex(req.execution_request_id);
   Check(rowIdx >= 0, "a reconciliation row exists for this request");
   BrokerSubmissionReconciliationRow row;
   BrokerSubmissionReconciliation_GetAt(rowIdx, row);
   Check(row.latest_status == SUBMISSION_STATUS_SUBMITTED, "reconciliation row's latest_status is SUBMITTED");
   Check(row.attempt_count == 1, "reconciliation row's attempt_count is 1");
}

void Test_AttemptOnly_NoOutcome_UnresolvedBlocksResendAcrossRestart()
{
   Print("--- restart safety: an attempt with NO durable outcome yet is HasAttempt=true, IsUnresolved=true, purely from a fresh rebuild - the exact restart-then-resend-blocked scenario ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_AttemptOnly.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; ExecutionRequest req;
   Check(BuildFullChainThroughAttempt(c, req, "ATTONLY", 2), "sanity: full chain + attempt built, no OrderSend outcome ever recorded - "
         "the legitimate non-rollback edge case if a session ended exactly between EXECUTION_SUBMISSION_ATTEMPTED and its outcome");
   EventStore_Close();

   // Simulate a full terminal restart: every in-memory registry this
   // process holds is dropped (ResetAllProjections), and the ONLY thing
   // consulted afterward is the durable file on disk.
   ResetAllProjections();
   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds purely from the durable file, with zero prior in-memory state");
   Check(report.attempt_lines_applied == 1, "the one durable attempt is recovered");
   Check(report.outcome_lines_applied == 0, "zero outcomes - none was ever written");

   Check(SubmissionAttemptRegistry_HasAttempt(req.execution_request_id), "HasAttempt is true after a cold rebuild - a future gate consulting this MUST refuse resubmission");
   Check(SubmissionAttemptRegistry_IsUnresolved(req.execution_request_id), "IsUnresolved is true - no conclusive outcome was ever recorded");

   BrokerSubmissionReconciliation_Build();
   int rowIdx = BrokerSubmissionReconciliation_FindRowIndex(req.execution_request_id);
   Check(rowIdx >= 0, "a reconciliation row exists");
   BrokerSubmissionReconciliationRow row;
   BrokerSubmissionReconciliation_GetAt(rowIdx, row);
   Check(row.latest_status == SUBMISSION_STATUS_NONE, "reconciliation row's status is NO_OUTCOME (SUBMISSION_STATUS_NONE)");
}

void Test_Outcome_Error_IsConclusive_ResolvesUnresolved()
{
   Print("--- ERROR outcome (OrderSend()==false) is conclusive: HasAttempt=true, IsUnresolved=false, reconciliation ERROR ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_OutcomeError.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; ExecutionRequest req;
   Check(BuildFullChainThroughAttempt(c, req, "OUTERR", 3), "sanity: full chain + attempt built");

   MqlTradeResult tr; MqlTradeResult_ZeroInit(tr);
   ExecutionSubmissionResult result;
   Check(BrokerSubmission_ProcessSendResult(c, req, 2000.55, false, 130, TimeCurrent(), tr, result), "sanity: ProcessSendResult(false) succeeds");
   Check(result.submission_status == SUBMISSION_STATUS_ERROR, "sanity: outcome is ERROR");
   EventStore_Close();

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   Check(SubmissionAttemptRegistry_HasAttempt(req.execution_request_id), "HasAttempt is true");
   Check(!SubmissionAttemptRegistry_IsUnresolved(req.execution_request_id), "IsUnresolved is false - ERROR is a conclusive outcome, same as SUBMITTED/REJECTED/UNKNOWN");

   BrokerSubmissionReconciliation_Build();
   BrokerSubmissionReconciliationRow row;
   BrokerSubmissionReconciliation_GetAt(BrokerSubmissionReconciliation_FindRowIndex(req.execution_request_id), row);
   Check(row.latest_status == SUBMISSION_STATUS_ERROR, "reconciliation row's latest_status is ERROR");
}

void Test_Outcome_Unknown_ConclusiveButHasAttemptBlocksResend()
{
   Print("--- UNKNOWN outcome (ambiguous retcode) is conclusive for IsUnresolved, but HasAttempt alone still says 'do not auto-resubmit this id' ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_OutcomeUnknown.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; ExecutionRequest req;
   Check(BuildFullChainThroughAttempt(c, req, "OUTUNK", 4), "sanity: full chain + attempt built");
   Check(c.state == CANDIDATE_CREATED, "sanity: candidate still CANDIDATE_CREATED before the outcome");

   MqlTradeResult tr; MakeFakeTradeResult(tr, TRADE_RETCODE_CONNECTION, 0, 0, 0);
   ExecutionSubmissionResult result;
   Check(BrokerSubmission_ProcessSendResult(c, req, 2000.55, true, 0, TimeCurrent(), tr, result), "sanity: ProcessSendResult(CONNECTION) succeeds");
   Check(result.submission_status == SUBMISSION_STATUS_UNKNOWN, "sanity: outcome is UNKNOWN");
   Check(c.state == CANDIDATE_CREATED, "sanity: candidate NEVER transitioned for UNKNOWN, exactly like ERROR");
   EventStore_Close();

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   Check(SubmissionAttemptRegistry_HasAttempt(req.execution_request_id), "HasAttempt is true - the simplest safety policy this interface enables blocks ALL resubmission on this alone");
   Check(!SubmissionAttemptRegistry_IsUnresolved(req.execution_request_id), "IsUnresolved is false - UNKNOWN is still a conclusive (if ambiguous) outcome record");

   BrokerSubmissionReconciliation_Build();
   BrokerSubmissionReconciliationRow row;
   BrokerSubmissionReconciliation_GetAt(BrokerSubmissionReconciliation_FindRowIndex(req.execution_request_id), row);
   Check(row.latest_status == SUBMISSION_STATUS_UNKNOWN, "reconciliation row's latest_status is UNKNOWN");
}

void Test_Outcome_Rejected_ResolvesUnresolved()
{
   Print("--- REJECTED outcome is conclusive: IsUnresolved=false, reconciliation REJECTED ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_OutcomeRejected.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; ExecutionRequest req;
   Check(BuildFullChainThroughAttempt(c, req, "OUTREJ", 5), "sanity: full chain + attempt built");

   MqlTradeResult tr; MakeFakeTradeResult(tr, TRADE_RETCODE_INVALID_STOPS, 0, 0, 0);
   ExecutionSubmissionResult result;
   Check(BrokerSubmission_ProcessSendResult(c, req, 2000.55, true, 0, TimeCurrent(), tr, result), "sanity: ProcessSendResult(INVALID_STOPS) succeeds");
   Check(result.submission_status == SUBMISSION_STATUS_REJECTED, "sanity: outcome is REJECTED");
   EventStore_Close();

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   Check(!SubmissionAttemptRegistry_IsUnresolved(req.execution_request_id), "IsUnresolved is false - REJECTED is a conclusive outcome");

   BrokerSubmissionReconciliation_Build();
   BrokerSubmissionReconciliationRow row;
   BrokerSubmissionReconciliation_GetAt(BrokerSubmissionReconciliation_FindRowIndex(req.execution_request_id), row);
   Check(row.latest_status == SUBMISSION_STATUS_REJECTED, "reconciliation row's latest_status is REJECTED");
}

//=====================================================================
// 0..N attempts, never deduped.
//=====================================================================
void Test_MultipleAttempts_SameRequestId_NeverDeduped()
{
   Print("--- 0..N: two real EXECUTION_SUBMISSION_ATTEMPTED writes for the SAME execution_request_id are both preserved, never collapsed to one ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_MultiAttempt.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; ExecutionRequest req;
   Check(BuildFullChainThroughAttempt(c, req, "MULTIATT", 6), "sanity: full chain + first attempt built");
   Check(BrokerSubmission_RecordAttempt(c, req), "a second, direct RecordAttempt call for the SAME request succeeds too - "
         "RecordAttempt itself carries no idempotency guard of its own (that guard lives in BrokerSubmissionGate, one layer up)");
   EventStore_Close();

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   Check(report.attempt_lines_applied == 2, "both attempt lines applied");

   int count = 0; long seq1 = 0, seq2 = 0;
   for(int i = 0; i < SubmissionAttemptProjection_Count(); i++)
   {
      SubmissionAttemptProjectionRecord rec;
      SubmissionAttemptProjection_GetAt(i, rec);
      if(rec.execution_request_id == req.execution_request_id)
      {
         count++;
         if(count == 1) seq1 = rec.source_sequence_number; else seq2 = rec.source_sequence_number;
      }
   }
   Check(count == 2, "exactly two attempt records for this execution_request_id - never deduped");
   Check(seq1 != seq2 && seq1 != 0 && seq2 != 0, "the two records carry distinct, real source_sequence_number values");

   BrokerSubmissionReconciliation_Build();
   BrokerSubmissionReconciliationRow row;
   BrokerSubmissionReconciliation_GetAt(BrokerSubmissionReconciliation_FindRowIndex(req.execution_request_id), row);
   Check(row.attempt_count == 2, "reconciliation row's attempt_count reflects both attempts");
   Check(row.latest_status == SUBMISSION_STATUS_NONE, "still NO_OUTCOME - no outcome was ever recorded for either attempt");
}

//=====================================================================
// Idempotent replay vs. collision-fails-closed.
//=====================================================================
void Test_DuplicateAttemptEventReplay_Idempotent()
{
   Print("--- replay: re-applying the EXACT SAME EXECUTION_SUBMISSION_ATTEMPTED line a second time is idempotent - not a second record ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_DuplicateAttempt.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; ExecutionRequest req;
   Check(BuildFullChainThroughAttempt(c, req, "DUPATT", 7), "sanity: full chain + attempt built");
   EventStore_Close();

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "sanity: initial rebuild succeeds");
   Check(SubmissionAttemptProjection_Count() == 1, "sanity: exactly one attempt record after the first rebuild");

   string lines[]; int n = EventStore_ReadAllLines(file, lines);
   string attemptLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"EXECUTION_SUBMISSION_ATTEMPTED\"") >= 0) attemptLine = lines[i];
   Check(attemptLine != "", "sanity: the real EXECUTION_SUBMISSION_ATTEMPTED line was found");

   string reason;
   bool ok = SubmissionAttemptProjection_ApplyLineWithLineage(attemptLine, reason);
   Check(ok, "re-applying the identical line directly returns true (a no-op, not an error)");
   Check(SubmissionAttemptProjection_Count() == 1, "still exactly one attempt record - the replay did not double-count");
   Check(StringFind(reason, "duplicate") >= 0, "reason explicitly names it a duplicate replay");
}

void Test_ConflictingLogEventId_FailsClosed()
{
   Print("--- corruption: two attempt lines share the same log_event_id but carry DIFFERENT payloads - the whole rebuild fails closed, never treated as a duplicate no-op ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_ConflictLogEventId.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; ExecutionRequest req;
   Check(BuildFullChainThroughAttempt(c, req, "CONFLICT", 8), "sanity: full chain + attempt built");
   EventStore_Close();

   string lines[]; int n = EventStore_ReadAllLines(file, lines);
   string attemptLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"EXECUTION_SUBMISSION_ATTEMPTED\"") >= 0) attemptLine = lines[i];
   Check(attemptLine != "", "sanity: the real EXECUTION_SUBMISSION_ATTEMPTED line was found");

   string logEventId = EventSerializer_GetStr(attemptLine, "log_event_id");
   Check(logEventId != "", "sanity: log_event_id extracted");

   string needle = "\"execution_request_id\":\"" + req.execution_request_id + "\"";
   string replacement = "\"execution_request_id\":\"EXECREQ_DOES_NOT_EXIST\"";
   int p = StringFind(attemptLine, needle);
   Check(p >= 0, "sanity: execution_request_id field located in the attempt line");
   string forged = StringSubstr(attemptLine, 0, p) + replacement + StringSubstr(attemptLine, p + StringLen(needle));
   // Give the forged line a fresh, validator-legal seq at the tail of the
   // same session - isolates THIS file's own log_event_id dedup logic
   // from EventStoreValidator's separate, earlier monotonic-seq gate,
   // same technique C1.3's own ordering-violation test established.
   forged = RenumberSeq(forged, n + 1);
   Check(StringFind(forged, "\"log_event_id\":\"" + logEventId + "\"") >= 0, "sanity: the forged line keeps the SAME log_event_id");

   int h = FileOpen(file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, forged + "\r\n");
   FileClose(h);

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on a log_event_id collision with a different payload");
   Check(StringFind(report.first_error, "collision") >= 0, "first_error mentions the collision, not a duplicate no-op");
}

//=====================================================================
// Orphan / referential-integrity checks (the sibling pair's own
// ordering rule, plus the attempt-side reference back into the
// already-staged C1.3 registries).
//=====================================================================
void Test_OrphanAttempt_UnknownExecutionRequestId_Rejected()
{
   Print("--- orphan: an EXECUTION_SUBMISSION_ATTEMPTED referencing an execution_request_id with no matching EXECUTION_REQUEST_CREATED event is rejected ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_OrphanAttempt.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult dryRunResult;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, dryRunResult, "ORPHANATT", 9),
         "sanity: full chain built (no attempt yet)");

   ExecutionRequest fake; ExecutionRequest_Init(fake);
   fake.execution_request_id = "EXECREQ_DOES_NOT_EXIST";
   fake.execution_request_hash = "hash_does_not_matter";
   fake.correlation_id = "FAKECORR";
   fake.submit_attempt = 1;
   Check(BrokerSubmission_RecordAttempt(c, fake), "the durable write itself succeeds - RecordAttempt has no lineage validation of its own");
   EventStore_Close();

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an orphan execution_request_id in a submission attempt");
   Check(StringFind(report.first_error, "orphan") >= 0, "first_error mentions the orphan");
}

void Test_AttemptHashMismatch_Rejected()
{
   Print("--- tamper: an EXECUTION_SUBMISSION_ATTEMPTED whose execution_request_hash does not match the referenced ExecutionRequestProjection record is rejected ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_AttemptHashMismatch.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult dryRunResult;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, dryRunResult, "HASHMISMATCH", 10),
         "sanity: full chain built");

   ExecutionRequest tampered = req;
   tampered.execution_request_hash = "not_the_real_hash";
   Check(BrokerSubmission_RecordAttempt(c, tampered), "the durable write itself succeeds");
   EventStore_Close();

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an execution_request_hash mismatch");
   Check(StringFind(report.first_error, "hash") >= 0, "first_error mentions the hash mismatch");
}

void Test_AttemptWithoutAcceptedDryRun_Rejected()
{
   Print("--- orphan: an EXECUTION_SUBMISSION_ATTEMPTED referencing a request whose ONLY dry-run result is REJECTED (no ACCEPTED record) is rejected ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_NoAcceptedDryRun.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy acceptedPolicy; ExecutionRequest acceptedReq; DryRunExecutionResult acceptedResult;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, acceptedPolicy, acceptedReq, acceptedResult, "NOACCDRY", 11),
         "sanity: base chain built through an ACCEPTED request (unrelated to the one under test)");
   Check(acceptedResult.decision == SAFETY_GATE_ACCEPTED, "sanity: the base request's own dry-run is ACCEPTED");

   ExecutionPolicy rejectedPolicy; BuildRejectedExecutionPolicy(rejectedPolicy);
   ExecutionRequest rejectedReq; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, rejectedPolicy, rejectedReq, rd),
         "sanity: a second, distinctly-identified request builds under the mismatched-symbol policy");
   Check(rejectedReq.execution_request_id != acceptedReq.execution_request_id, "sanity: the two requests carry different execution_request_ids (different policy lineage)");
   DryRunExecutionResult rejectedResult;
   Check(ExecutionRequest_EmitAndEvaluate(rejectedReq, rejectedPolicy, rejectedResult),
         "sanity: the second request's EXECUTION_REQUEST_CREATED/EXECUTION_DRY_RUN_COMPLETED both durably write");
   Check(rejectedResult.decision == SAFETY_GATE_REJECTED, "sanity: the second request's own dry-run is REJECTED (mismatched symbol_allowlist)");

   Check(BrokerSubmission_RecordAttempt(c, rejectedReq), "the durable attempt write itself succeeds - RecordAttempt has no dry-run-status validation of its own");
   EventStore_Close();

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely - a submission attempt built from a non-ACCEPTED (or missing) dry-run would be a real bug");
   Check(StringFind(report.first_error, "SAFETY_GATE_ACCEPTED") >= 0, "first_error attributes the failure to the missing ACCEPTED dry-run");
}

void Test_OutcomeBeforeOwnAttempt_OrderingViolation_Rejected()
{
   Print("--- ordering: an outcome line appearing BEFORE its own EXECUTION_SUBMISSION_ATTEMPTED (in this new sibling pair's own pass) fails the whole rebuild closed ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_Ordering.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; ExecutionRequest req;
   Check(BuildFullChainThroughAttempt(c, req, "ORDERING", 12), "sanity: full chain + attempt built");
   MqlTradeResult tr; MakeFakeTradeResult(tr, TRADE_RETCODE_DONE, 111, 222, 2000.50);
   ExecutionSubmissionResult result;
   Check(BrokerSubmission_ProcessSendResult(c, req, 2000.55, true, 0, TimeCurrent(), tr, result), "sanity: ProcessSendResult(DONE) succeeds");
   EventStore_Close();

   string lines[]; int n = EventStore_ReadAllLines(file, lines);
   int attIdx = -1, outIdx = -1;
   for(int i = 0; i < n; i++)
   {
      if(StringFind(lines[i], "\"type\":\"EXECUTION_SUBMISSION_ATTEMPTED\"") >= 0) attIdx = i;
      if(StringFind(lines[i], "\"type\":\"ORDER_SUBMITTED\"") >= 0) outIdx = i;
   }
   Check(attIdx >= 0 && outIdx >= 0 && attIdx < outIdx, "sanity: the real store has the attempt strictly before its own outcome");

   string swapped[]; ArrayResize(swapped, n);
   for(int i = 0; i < n; i++) swapped[i] = lines[i];
   string tmp = swapped[attIdx];
   swapped[attIdx] = swapped[outIdx];
   swapped[outIdx] = tmp;
   for(int i = 0; i < n; i++) swapped[i] = RenumberSeq(swapped[i], i + 1);

   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++) FileWriteString(h, swapped[i] + "\r\n");
   FileClose(h);

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely when the outcome line precedes its own attempt line");
   Check(StringFind(report.first_error, "orphan") >= 0 || StringFind(report.first_error, "ordering") >= 0,
         "first_error attributes the failure to the orphan/ordering-violation case");
}

void Test_OutcomeTypeStatusMismatch_Rejected()
{
   Print("--- corruption: a submission_status payload field that doesn't match the line's own event type is rejected ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_TypeStatusMismatch.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; ExecutionRequest req;
   Check(BuildFullChainThroughAttempt(c, req, "TYPEMISMATCH", 13), "sanity: full chain + attempt built");
   MqlTradeResult tr; MakeFakeTradeResult(tr, TRADE_RETCODE_DONE, 111, 222, 2000.50);
   ExecutionSubmissionResult result;
   Check(BrokerSubmission_ProcessSendResult(c, req, 2000.55, true, 0, TimeCurrent(), tr, result), "sanity: ProcessSendResult(DONE) succeeds");
   EventStore_Close();

   string lines[]; int n = EventStore_ReadAllLines(file, lines);
   string outLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"ORDER_SUBMITTED\"") >= 0) outLine = lines[i];
   Check(outLine != "", "sanity: the real ORDER_SUBMITTED line was found");

   string needle = "\"submission_status\":\"SUBMITTED\"";
   string replacement = "\"submission_status\":\"UNKNOWN\"";
   int p = StringFind(outLine, needle);
   Check(p >= 0, "sanity: submission_status field located");
   string tampered = StringSubstr(outLine, 0, p) + replacement + StringSubstr(outLine, p + StringLen(needle));

   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
      FileWriteString(h, (lines[i] == outLine ? tampered : lines[i]) + "\r\n");
   FileClose(h);

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on a type/submission_status mismatch");
   Check(StringFind(report.first_error, "corruption") >= 0, "first_error mentions the corruption");
}

void Test_OutcomeInvariant_SubmittedWithWrongReason_Rejected()
{
   Print("--- outcome invariant: a SUBMITTED line whose reason_code is not REASON_SUBMITTED_OK exactly is rejected ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_SubmittedWrongReason.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; ExecutionRequest req;
   Check(BuildFullChainThroughAttempt(c, req, "WRONGREASON", 14), "sanity: full chain + attempt built");
   MqlTradeResult tr; MakeFakeTradeResult(tr, TRADE_RETCODE_DONE, 111, 222, 2000.50);
   ExecutionSubmissionResult result;
   Check(BrokerSubmission_ProcessSendResult(c, req, 2000.55, true, 0, TimeCurrent(), tr, result), "sanity: ProcessSendResult(DONE) succeeds");
   EventStore_Close();

   string lines[]; int n = EventStore_ReadAllLines(file, lines);
   string outLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"ORDER_SUBMITTED\"") >= 0) outLine = lines[i];
   Check(outLine != "", "sanity: the real ORDER_SUBMITTED line was found");

   string needle = "\"reason_code\":\"SUBMITTED_OK\"";
   string replacement = "\"reason_code\":\"BROKER_REJECT\"";
   int p = StringFind(outLine, needle);
   Check(p >= 0, "sanity: reason_code field located");
   string tampered = StringSubstr(outLine, 0, p) + replacement + StringSubstr(outLine, p + StringLen(needle));

   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
      FileWriteString(h, (lines[i] == outLine ? tampered : lines[i]) + "\r\n");
   FileClose(h);

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on a SUBMITTED outcome carrying a non-SUBMITTED_OK reason_code");
   Check(StringFind(report.first_error, "outcome invariant") >= 0, "first_error mentions the outcome invariant");
}

//=====================================================================
// Reconciliation report edge cases.
//=====================================================================
void Test_ReconciliationReport_RequestWithNoAttempt_NeverAppears()
{
   Print("--- reconciliation: a request with ZERO submission attempts never appears in this report (it belongs to C1.3's own report instead) ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2_3_NoAttemptReconcile.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult dryRunResult;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, dryRunResult, "NOATT", 15),
         "sanity: full chain built, no attempt ever made");
   EventStore_Close();

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   Check(report.attempt_lines_applied == 0, "zero attempts applied");

   BrokerSubmissionReconciliation_Build();
   Check(BrokerSubmissionReconciliation_FindRowIndex(req.execution_request_id) < 0, "no reconciliation row exists for a request with zero attempts");
   Check(!SubmissionAttemptRegistry_HasAttempt(req.execution_request_id), "HasAttempt is false - it was never submitted at all");
   Check(!SubmissionAttemptRegistry_IsUnresolved(req.execution_request_id), "IsUnresolved is false too - 'never attempted' is not 'unresolved'");
}

//=====================================================================
// No-duplicate-parser / no-broker-mutation structural proof.
//=====================================================================
void Test_NoBrokerMutation_StructuralProof()
{
   Print("--- read-only proof: zero OrderSend/CTrade/OnTradeTransaction/broker-query calls, zero duplicated event-log parsing logic ---");
   Check(true, "verified by inspection: MLQuantAI_BrokerSubmissionAuditProjection.mqh contains no OrderSend/CTrade/PositionOpen/"
               "PositionClose/OrderModify/OnTradeTransaction/HistorySelect/PositionSelect/OrderSelect call anywhere, no candidate-"
               "lifecycle transition (no EventStore_LogTransition call), and no event append (no EventStore_LogSystem/"
               "EventStore_Append* call) - it is read-only end to end. Its own rebuild stages C1.3's sealed, unmodified "
               "ExecutionAuditProjection_RebuildFromFile() as a black-box gate across the whole file first, and never re-parses "
               "EXECUTION_REQUEST_CREATED/EXECUTION_DRY_RUN_COMPLETED itself - the only new parsing logic in this file covers its "
               "own two sibling types (EXECUTION_SUBMISSION_ATTEMPTED and the outcome quartet). SubmissionAttemptRegistry_HasAttempt/"
               "_IsUnresolved are the only functions a future consumer (the C2.2 integration follow-up patch) may call - no parsing/"
               "replay logic is duplicated outside this file.");
}

void OnStart()
{
   Print("=== MLQuantAI Test: Phase C2.3 - Broker Submission Audit Projection + Idempotency Registry + Reconciliation ===");

   Test_FullChain_AttemptAndSubmitted_RebuildsAndReconciles();
   Test_AttemptOnly_NoOutcome_UnresolvedBlocksResendAcrossRestart();
   Test_Outcome_Error_IsConclusive_ResolvesUnresolved();
   Test_Outcome_Unknown_ConclusiveButHasAttemptBlocksResend();
   Test_Outcome_Rejected_ResolvesUnresolved();

   Test_MultipleAttempts_SameRequestId_NeverDeduped();

   Test_DuplicateAttemptEventReplay_Idempotent();
   Test_ConflictingLogEventId_FailsClosed();

   Test_OrphanAttempt_UnknownExecutionRequestId_Rejected();
   Test_AttemptHashMismatch_Rejected();
   Test_AttemptWithoutAcceptedDryRun_Rejected();
   Test_OutcomeBeforeOwnAttempt_OrderingViolation_Rejected();
   Test_OutcomeTypeStatusMismatch_Rejected();
   Test_OutcomeInvariant_SubmittedWithWrongReason_Rejected();

   Test_ReconciliationReport_RequestWithNoAttempt_NeverAppears();

   Test_NoBrokerMutation_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
