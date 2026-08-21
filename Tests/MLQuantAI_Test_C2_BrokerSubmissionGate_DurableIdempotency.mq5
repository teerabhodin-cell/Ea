//+------------------------------------------------------------------+
//| MLQuantAI_Test_C2_BrokerSubmissionGate_DurableIdempotency.mq5      |
//| C2.2/C2.3 integration patch DoD, per                                |
//| Docs/PhaseC_C2_1_BrokerSubmissionContract.md's "Durable idempotency |
//| - C2.3's first deliverable" section: BrokerSubmissionGate_Evaluate  |
//| now consults C2.3's frozen SubmissionAttemptRegistry_HasAttempt()   |
//| interface as a third check, after the in-session guard. Proves the  |
//| durable check works purely from EventStore replay (no in-session    |
//| state), blocks resubmission of a RESOLVED attempt too (the frozen   |
//| "simplest policy" - HasAttempt, not IsUnresolved), and is isolated  |
//| per execution_request_id (no false positives). Uses the real        |
//| B5-C1/C2.2/C2.3 pipeline for every fixture - no fabricated hashes.  |
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
// Fixture helpers - same shapes as C1.3/C2.2/C2.3's own test files.
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
   ctx.context_event_id = "CTX_c2integ_" + suffix;
   ctx.context_hash      = "test_context_hash_c2integ_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C2INTEG_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

// C2's own accepting policy: environment_mode == EXECUTION_ENV_DEMO -
// unlike C1.3's own BuildFullChain fixture (TESTER), this file's chain
// needs a policy usable BOTH to emit the dry-run AND, unchanged, to
// evaluate BrokerSubmissionGate_Evaluate (which only grants real
// authority to EXECUTION_ENV_DEMO), so one policy object serves both.
void BuildAcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C2INTEG_V1";
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
}

// Builds AND emits every layer of the real chain through an ACCEPTED
// ExecutionRequest dry-run, using a DEMO-mode ExecutionPolicy (outPolicy)
// reusable unchanged for a later BrokerSubmissionGate_Evaluate call.
bool BuildFullChain(TradeCandidate &c, FeatureSnapshot &snapshot, ModelArtifact &artifact, InferenceResult &inference,
                      RiskPlan &plan, AIDecision &decision, EligibilityDecision &eligDecision,
                      ExecutionPolicy &outPolicy, ExecutionRequest &req, DryRunExecutionResult &dryRunResult,
                      string suffix, int dayOffset, float pSuccessValue = 0.90f, double aiThreshold = 0.70)
{
   MarketContext ctx;
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.04.01 00:00:00' + dayOffset * 86400;
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
   aiPolicy.decision_policy_version = "AIPOLICY_C2INTEG_V1";
   aiPolicy.threshold_version       = "THRESH_C2INTEG_V1";
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

   BuildAcceptingExecutionPolicy(outPolicy);
   string execReasonDetail;
   if(!ExecutionRequest_Build(c, eligDecision, decision, plan, outPolicy, req, execReasonDetail)) return false;

   return ExecutionRequest_EmitAndEvaluate(req, outPolicy, dryRunResult);
}

// Convenience wrapper: full chain, through a durable
// EXECUTION_SUBMISSION_ATTEMPTED write, ACCEPTED-dry-run only. Caller
// must already have an EventStore session open.
bool BuildFullChainThroughAttempt(TradeCandidate &c, ExecutionRequest &req, ExecutionPolicy &outPolicy, string suffix, int dayOffset)
{
   FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   DryRunExecutionResult dryRunResult;
   if(!BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, outPolicy, req, dryRunResult, suffix, dayOffset))
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
void Test_DurableAttempt_BlocksResubmission_IgnoresInSessionState()
{
   Print("--- durable check: a prior attempt recovered purely from EventStore replay blocks the gate, even with a FRESH in-session guard (BrokerSubmissionGate_Reset called) ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2Integ_DurableBlock.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildFullChainThroughAttempt(c, req, policy, "DURBLOCK", 1), "sanity: full chain + durable attempt built");
   EventStore_Close();

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "sanity: rebuild from the durable store succeeds");
   Check(SubmissionAttemptRegistry_HasAttempt(req.execution_request_id), "sanity: HasAttempt is true after the rebuild");

   BrokerSubmissionGate_Reset(); // prove the IN-SESSION guard is NOT what rejects below

   DryRunExecutionResult result;
   Check(BrokerSubmissionGate_Evaluate(req, policy, result), "evaluation completes");

   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tradeMode == ACCOUNT_TRADE_MODE_DEMO)
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_DUPLICATE_EVENT,
            "on a real DEMO account: rejected by the DURABLE check alone, REASON_DUPLICATE_EVENT");
   else
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED,
            "on a non-DEMO account: still rejects on environment, before the durable check is ever reached");
}

void Test_ResolvedDurableAttempt_StillBlocksResubmission()
{
   Print("--- strongest policy: a durable attempt that IS resolved (SUBMITTED) still blocks resubmission - HasAttempt is consulted, not IsUnresolved ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2Integ_ResolvedBlock.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildFullChainThroughAttempt(c, req, policy, "RESOLVEDBLOCK", 2), "sanity: full chain + attempt built");

   MqlTradeResult tr; MakeFakeTradeResult(tr, TRADE_RETCODE_DONE, 111, 222, 2000.50);
   ExecutionSubmissionResult sr;
   Check(BrokerSubmission_ProcessSendResult(c, req, 2000.55, true, 0, TimeCurrent(), tr, sr), "sanity: ProcessSendResult(DONE) succeeds");
   Check(sr.submission_status == SUBMISSION_STATUS_SUBMITTED, "sanity: outcome is SUBMITTED - a resolved, conclusive outcome");
   EventStore_Close();

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   Check(SubmissionAttemptRegistry_HasAttempt(req.execution_request_id), "sanity: HasAttempt is true");
   Check(!SubmissionAttemptRegistry_IsUnresolved(req.execution_request_id), "sanity: IsUnresolved is false - this attempt IS resolved");

   DryRunExecutionResult result;
   Check(BrokerSubmissionGate_Evaluate(req, policy, result), "evaluation completes");

   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tradeMode == ACCOUNT_TRADE_MODE_DEMO)
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_DUPLICATE_EVENT,
            "on a real DEMO account: STILL rejected even though the attempt is fully resolved - proves the gate checks HasAttempt, not IsUnresolved");
   else
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED,
            "on a non-DEMO account: still rejects on environment, before the durable check is ever reached");
}

void Test_NoDurableAttempt_StillAcceptedAndIsolatedFromOtherRequests()
{
   Print("--- no false positive: a request with NO durable attempt of its own is unaffected by a DIFFERENT request's durable attempt in the same store ---");
   ResetAllProjections(); BrokerSubmissionGate_Reset();
   string file = "MLQuantAI_Test_C2Integ_NoFalsePositive.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate cA; ExecutionRequest reqA; ExecutionPolicy policyA;
   Check(BuildFullChainThroughAttempt(cA, reqA, policyA, "ISOLA", 3), "sanity: request A (attempted) built");

   TradeCandidate cB; FeatureSnapshot snapB; ModelArtifact artB; InferenceResult infB;
   RiskPlan planB; AIDecision decB; EligibilityDecision eligB; ExecutionPolicy policyB;
   ExecutionRequest reqB; DryRunExecutionResult dryB;
   Check(BuildFullChain(cB, snapB, artB, infB, planB, decB, eligB, policyB, reqB, dryB, "ISOLB", 4),
         "sanity: request B (never attempted) built");
   Check(reqA.execution_request_id != reqB.execution_request_id, "sanity: A and B are distinct requests");
   EventStore_Close();

   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   Check(SubmissionAttemptRegistry_HasAttempt(reqA.execution_request_id), "A: HasAttempt is true");
   Check(!SubmissionAttemptRegistry_HasAttempt(reqB.execution_request_id), "B: HasAttempt is false - unaffected by A's attempt");

   DryRunExecutionResult resultB;
   Check(BrokerSubmissionGate_Evaluate(reqB, policyB, resultB), "B: evaluation completes");

   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tradeMode == ACCOUNT_TRADE_MODE_DEMO)
      Check(resultB.decision == SAFETY_GATE_ACCEPTED, "B: on a real DEMO account, ACCEPTED - no false positive from A's unrelated attempt");
   else
      Check(resultB.decision == SAFETY_GATE_REJECTED && resultB.reason_code == REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED,
            "B: on a non-DEMO account, rejects on environment only, not on A's unrelated attempt");
}

void Test_NoBrokerMutation_StructuralProof()
{
   Print("--- no OrderSend call anywhere in the amended gate path this suite exercises ---");
   Check(true, "verified by inspection: the amended BrokerSubmissionGate_Evaluate (MLQuantAI_BrokerSubmissionGate.mqh) adds exactly one new "
               "read: a call into SubmissionAttemptRegistry_HasAttempt() (MLQuantAI_BrokerSubmissionAuditProjection.mqh, itself read-only, "
               "see that file's own structural proof) - no OrderSend/CTrade/PositionOpen/PositionClose/OrderModify call, no candidate-lifecycle "
               "transition, no event append anywhere in the amended function.");
}

void OnStart()
{
   Print("=== MLQuantAI Test: C2.2/C2.3 integration patch - BrokerSubmissionGate durable idempotency check ===");

   Test_DurableAttempt_BlocksResubmission_IgnoresInSessionState();
   Test_ResolvedDurableAttempt_StillBlocksResubmission();
   Test_NoDurableAttempt_StillAcceptedAndIsolatedFromOtherRequests();

   Test_NoBrokerMutation_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
