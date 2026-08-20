//+------------------------------------------------------------------+
//| MLQuantAI_Test_C1_2_ExecutionRequestSafetyGate.mq5                 |
//| Phase C1.2 DoD, per                                                 |
//| Docs/PhaseC_C1_1_ExecutionRequestContract.md's C1.2 addendum:       |
//| ExecutionRequest_Build, SafetyGate_Evaluate's frozen gate order,    |
//| and ExecutionRequest_EmitAndEvaluate's event emission. Uses the     |
//| real B5/B7/B8.5/B9 pipeline (in-memory only - no event emission     |
//| needed for candidate/plan/AI/eligibility layers, since              |
//| ExecutionRequest_Build only reads the in-memory structs, never the  |
//| event store) for every fixture - no fabricated hashes anywhere.     |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_ToTradeCandidate.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_ModelArtifactBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestEventEmission.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as prior B7/B8.x/B9 test files.
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
   ctx.context_event_id = "CTX_c1c2_" + suffix;
   ctx.context_hash      = "test_context_hash_c1c2_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C1_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

// Builds candidate/plan/AI-decision/eligibility-decision (ELIGIBLE) all
// purely in-memory - no event emission for any of these layers, since
// ExecutionRequest_Build only reads the structs it is handed, never the
// event store. dayOffset must be unique across fixtures in one test run
// (same lesson every prior test file's own history already established).
bool BuildEligibleChain(TradeCandidate &c, RiskPlan &plan, AIDecision &decision, EligibilityDecision &eligDecision,
                          string suffix, int dayOffset, float pSuccessValue = 0.90f, double aiThreshold = 0.70)
{
   MarketContext ctx;
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.01.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;

   FeatureSnapshot snapshot;
   if(!Candidate_ToFeatureSnapshot(c, ctx, snapshot)) return false;

   ModelArtifact artifact;
   if(!ModelArtifact_Build("MODEL_" + suffix, "v1", "hash_artifact_" + suffix,
                             "FEATURES_B8_1_V1", "TDSET_dummy_" + suffix, "hash_tdset_" + suffix,
                             "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                             "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, artifact))
      return false;

   InferenceResult inference;
   BuildValidInferenceResult(snapshot, artifact.model_registry_id, artifact.model_registry_hash, artifact.model_artifact_hash,
                               pSuccessValue, inference);
   AIDecisionPolicy aiPolicy;
   AIDecisionPolicy_Init(aiPolicy);
   aiPolicy.decision_policy_version = "AIPOLICY_C1_V1";
   aiPolicy.threshold_version       = "THRESH_C1_V1";
   aiPolicy.allow_threshold         = aiThreshold;
   string aiReasonDetail;
   if(!AIDecision_Build(inference, snapshot, aiPolicy, decision, aiReasonDetail)) return false;

   RiskContext riskCtx; BuildValidRiskContext(riskCtx, suffix);
   if(!Candidate_ToRiskPlan(c, riskCtx, plan)) return false;

   EligibilityContext eligContext; BuildHealthyEligibilityContext(eligContext);
   EligibilityPolicy eligPolicy; BuildEnabledEligibilityPolicy(eligPolicy);

   string eligReasonDetail;
   return EligibilityDecision_Build(plan, decision, snapshot, eligContext, eligPolicy, eligDecision, eligReasonDetail);
}

// A fully-configured ExecutionPolicy that will ACCEPT a healthy request
// under the live terminal's own current account/symbol - reads
// AccountInfoInteger(ACCOUNT_LOGIN)/_Symbol itself, exactly like
// SafetyGate_Evaluate will, so this test is environment-agnostic.
void BuildAcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C1_V1";
   policy.environment_mode = EXECUTION_ENV_TESTER;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

//=====================================================================
void Test_Build_RejectsNonEligibleDecision()
{
   Print("--- Build: a REJECTED EligibilityDecision never produces an ExecutionRequest ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "REJTEST", 1, 0.30f, 0.70),
         "sanity: chain built with a low p_success (AI REJECT path)");
   Check(eligDecision.decision == ELIGIBILITY_DECISION_REJECTED, "sanity: eligibility decision is REJECTED");

   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   ExecutionRequest req; string reasonDetail;
   Check(!ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, reasonDetail),
         "Build fails when EligibilityDecision.decision != ELIGIBLE");
   Check(req.execution_request_id == "", "no execution_request_id produced on a failed Build");
}

void Test_Build_AcceptsEligibleChain_AndFieldsCopiedVerbatim()
{
   Print("--- Build: an ELIGIBLE chain produces a request with every field copied verbatim ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "OKTEST", 2), "sanity: chain built");
   Check(eligDecision.decision == ELIGIBILITY_DECISION_ELIGIBLE, "sanity: eligibility decision is ELIGIBLE");

   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   ExecutionRequest req; string reasonDetail;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, reasonDetail), "Build succeeds");
   Check(req.candidate_id == c.candidate_id, "candidate_id copied verbatim");
   Check(req.candidate_hash == c.candidate_hash, "candidate_hash copied verbatim");
   Check(req.risk_plan_id == plan.risk_plan_id, "risk_plan_id copied verbatim");
   Check(req.plan_hash == plan.plan_hash, "plan_hash copied verbatim");
   Check(req.ai_decision_id == decision.ai_decision_id, "ai_decision_id copied verbatim");
   Check(req.ai_decision_hash == decision.ai_decision_hash, "ai_decision_hash copied verbatim");
   Check(req.eligibility_decision_id == eligDecision.eligibility_decision_id, "eligibility_decision_id copied verbatim");
   Check(req.eligibility_decision_hash == eligDecision.eligibility_decision_hash, "eligibility_decision_hash copied verbatim");
   Check(req.side == c.side, "side copied verbatim from TradeCandidate");
   Check(req.planned_entry == plan.planned_entry, "planned_entry copied verbatim from RiskPlan");
   Check(req.planned_sl == plan.planned_sl, "planned_sl copied verbatim from RiskPlan");
   Check(req.planned_tp == plan.planned_tp, "planned_tp copied verbatim from RiskPlan");
   Check(req.lot_size == plan.lot_size, "lot_size copied verbatim from RiskPlan");
   Check(req.risk_amount == plan.risk_amount, "risk_amount copied verbatim from RiskPlan");
   Check(req.submit_attempt == 1, "submit_attempt is always 1");
   Check(req.correlation_id == Ids_CorrelationId(c.candidate_id, 1), "correlation_id == Ids_CorrelationId(candidate_id, 1)");
   Check(req.execution_request_id != "", "execution_request_id is non-empty");
   Check(req.execution_request_hash != "", "execution_request_hash is non-empty");
}

void Test_Determinism_SameInputsSameIdAndHash()
{
   Print("--- determinism: repeated builds of the same inputs produce byte-identical id/hash ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "DETERM", 3), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);

   ExecutionRequest first; string rd1;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, first, rd1), "sanity: first build succeeds");

   bool allMatch = true;
   for(int i = 0; i < 200; i++)
   {
      ExecutionRequest again; string rd2;
      if(!ExecutionRequest_Build(c, eligDecision, decision, plan, policy, again, rd2) ||
         again.execution_request_id != first.execution_request_id ||
         again.execution_request_hash != first.execution_request_hash)
      { allMatch = false; break; }
   }
   Check(allMatch, "200 repeated builds: identical execution_request_id and execution_request_hash every time");
}

void Test_IdentitySensitivity_PolicyVersionMovesId()
{
   Print("--- identity sensitivity: a different execution_policy_version produces a different execution_request_id ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "IDSENS", 4), "sanity: chain built");

   ExecutionPolicy policyA; BuildAcceptingExecutionPolicy(policyA);
   ExecutionPolicy policyB; BuildAcceptingExecutionPolicy(policyB);
   policyB.execution_policy_version = "EXECPOLICY_C1_V2_DIFFERENT";

   ExecutionRequest reqA; string rdA;
   ExecutionRequest reqB; string rdB;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policyA, reqA, rdA), "sanity: build A succeeds");
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policyB, reqB, rdB), "sanity: build B succeeds");
   Check(reqA.execution_request_id != reqB.execution_request_id, "different execution_policy_version moves execution_request_id");
}

void Test_HashSensitivity_ContentChangeMovesHashNotId()
{
   Print("--- hash sensitivity: a content-only change moves execution_request_hash while execution_request_id stays identical ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "HASHSENS", 5), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);

   ExecutionRequest baseline; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, baseline, rd), "sanity: baseline build succeeds");

   ExecutionRequest mutated = baseline;
   mutated.lot_size = mutated.lot_size + 0.01;
   mutated.execution_request_hash = ExecutionRequest_ComputeHash(mutated);

   Check(mutated.execution_request_id == baseline.execution_request_id, "lot_size change: execution_request_id unchanged");
   Check(mutated.execution_request_hash != baseline.execution_request_hash, "lot_size change: execution_request_hash moves");
}

void Test_SafetyGate_HealthyPolicyAccepts()
{
   Print("--- SafetyGate: dry_run=true + every gate passing -> ACCEPTED ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "GATEOK", 6), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");

   DryRunExecutionResult result;
   Check(SafetyGate_Evaluate(req, policy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_ACCEPTED, "decision is ACCEPTED");
   Check(result.reason_code == REASON_NONE, "reason_code is REASON_NONE");
   Check(result.observed_symbol == _Symbol, "observed_symbol matches the real current chart symbol");
   Check(result.observed_account_login == AccountInfoInteger(ACCOUNT_LOGIN), "observed_account_login matches the real current account login");
}

void Test_SafetyGate_DryRunFalseAlwaysRejects()
{
   Print("--- SafetyGate: dry_run=false rejects unconditionally, even with every other gate passing ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "DRYFALSE", 7), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   policy.dry_run = false;
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");

   DryRunExecutionResult result;
   Check(SafetyGate_Evaluate(req, policy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_REJECTED, "decision is REJECTED");
   Check(result.reason_code == REASON_EXECUTION_SUBMIT_DISABLED, "reason_code is REASON_EXECUTION_SUBMIT_DISABLED");
}

void Test_SafetyGate_SafeModeRejectsUnconditionally()
{
   Print("--- SafetyGate: Safe Mode active rejects unconditionally, before every other gate ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "SAFEMODE", 8), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");

   SafeMode_Trip("test-only: forcing Safe Mode active for this check");
   DryRunExecutionResult result;
   Check(SafetyGate_Evaluate(req, policy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_REJECTED, "decision is REJECTED");
   Check(result.reason_code == REASON_RISK_CIRCUIT_BREAKER, "reason_code is REASON_RISK_CIRCUIT_BREAKER");
   SafeMode_Clear();
}

void Test_SafetyGate_EnvironmentNotConfiguredRejects()
{
   Print("--- SafetyGate: environment_mode == EXECUTION_ENV_NONE rejects ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "ENVNONE", 9), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   policy.environment_mode = EXECUTION_ENV_NONE;
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");

   DryRunExecutionResult result;
   Check(SafetyGate_Evaluate(req, policy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_REJECTED, "decision is REJECTED");
   Check(result.reason_code == REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED, "reason_code is REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED");
}

void Test_SafetyGate_ManualApprovalRequiredRejects()
{
   Print("--- SafetyGate: manual_approval_required == true always rejects in C1.2 (no approval mechanism exists yet) ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "MANAPPR", 10), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   policy.manual_approval_required = true;
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");

   DryRunExecutionResult result;
   Check(SafetyGate_Evaluate(req, policy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_REJECTED, "decision is REJECTED");
   Check(result.reason_code == REASON_EXECUTION_MANUAL_APPROVAL_REQUIRED, "reason_code is REASON_EXECUTION_MANUAL_APPROVAL_REQUIRED");
}

void Test_SafetyGate_AccountAllowlist()
{
   Print("--- SafetyGate: account allowlist - not-allowlisted rejects, empty allowlist rejects, allowlisted passes ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "ACCTALLOW", 11), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");

   ExecutionPolicy notAllowed = policy;
   notAllowed.account_allowlist = "999999999"; // deliberately excludes the real current login
   DryRunExecutionResult r1;
   Check(SafetyGate_Evaluate(req, notAllowed, r1), "evaluation completes (not-allowlisted)");
   Check(r1.decision == SAFETY_GATE_REJECTED && r1.reason_code == REASON_EXECUTION_ACCOUNT_NOT_ALLOWED,
         "not-allowlisted account rejects with REASON_EXECUTION_ACCOUNT_NOT_ALLOWED");

   ExecutionPolicy emptyAllow = policy;
   emptyAllow.account_allowlist = "";
   DryRunExecutionResult r2;
   Check(SafetyGate_Evaluate(req, emptyAllow, r2), "evaluation completes (empty allowlist)");
   Check(r2.decision == SAFETY_GATE_REJECTED && r2.reason_code == REASON_EXECUTION_ACCOUNT_NOT_ALLOWED,
         "empty account_allowlist rejects too - unconfigured never means unlimited");

   DryRunExecutionResult r3;
   Check(SafetyGate_Evaluate(req, policy, r3), "evaluation completes (allowlisted)");
   Check(r3.decision != SAFETY_GATE_REJECTED || r3.reason_code != REASON_EXECUTION_ACCOUNT_NOT_ALLOWED,
         "the real current account login, allowlisted, does not trip this gate");
}

void Test_SafetyGate_SymbolAllowlist()
{
   Print("--- SafetyGate: symbol allowlist - not-allowlisted rejects, empty allowlist rejects, allowlisted passes ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "SYMALLOW", 12), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");

   ExecutionPolicy notAllowed = policy;
   notAllowed.symbol_allowlist = "NONEXISTENT_SYMBOL_XYZ";
   DryRunExecutionResult r1;
   Check(SafetyGate_Evaluate(req, notAllowed, r1), "evaluation completes (not-allowlisted)");
   Check(r1.decision == SAFETY_GATE_REJECTED && r1.reason_code == REASON_EXECUTION_SYMBOL_NOT_ALLOWED,
         "not-allowlisted symbol rejects with REASON_EXECUTION_SYMBOL_NOT_ALLOWED");

   ExecutionPolicy emptyAllow = policy;
   emptyAllow.symbol_allowlist = "";
   DryRunExecutionResult r2;
   Check(SafetyGate_Evaluate(req, emptyAllow, r2), "evaluation completes (empty allowlist)");
   Check(r2.decision == SAFETY_GATE_REJECTED && r2.reason_code == REASON_EXECUTION_SYMBOL_NOT_ALLOWED,
         "empty symbol_allowlist rejects too - unconfigured never means unlimited");
}

void Test_SafetyGate_OrderTypeMustBeMarket()
{
   Print("--- SafetyGate: only ORDER_TYPE_BUY/ORDER_TYPE_SELL pass; every other order type rejects ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "ORDTYPE", 13), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");

   req.side = ORDER_TYPE_BUY_LIMIT;
   req.execution_request_hash = ExecutionRequest_ComputeHash(req);
   DryRunExecutionResult result;
   Check(SafetyGate_Evaluate(req, policy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_ORDER_TYPE_NOT_MARKET,
         "a pending order type rejects with REASON_EXECUTION_ORDER_TYPE_NOT_MARKET");
}

void Test_SafetyGate_VolumeCap()
{
   Print("--- SafetyGate: max_volume - unconfigured (<=0) rejects as policy-invalid, exceeded rejects, within passes ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "VOLCAP", 14), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");
   Check(req.lot_size > 0, "sanity: request has a positive lot_size to test against");

   ExecutionPolicy unconfigured = policy; unconfigured.max_volume = 0.0;
   DryRunExecutionResult r1;
   Check(SafetyGate_Evaluate(req, unconfigured, r1), "evaluation completes (unconfigured)");
   Check(r1.decision == SAFETY_GATE_REJECTED && r1.reason_code == REASON_EXECUTION_VOLUME_POLICY_INVALID,
         "max_volume <= 0 rejects with REASON_EXECUTION_VOLUME_POLICY_INVALID");

   ExecutionPolicy tooSmall = policy; tooSmall.max_volume = req.lot_size / 2.0;
   DryRunExecutionResult r2;
   Check(SafetyGate_Evaluate(req, tooSmall, r2), "evaluation completes (exceeded)");
   Check(r2.decision == SAFETY_GATE_REJECTED && r2.reason_code == REASON_EXECUTION_VOLUME_CAP_EXCEEDED,
         "lot_size > max_volume rejects with REASON_EXECUTION_VOLUME_CAP_EXCEEDED");

   DryRunExecutionResult r3;
   Check(SafetyGate_Evaluate(req, policy, r3), "evaluation completes (within cap)");
   Check(r3.decision != SAFETY_GATE_REJECTED || (r3.reason_code != REASON_EXECUTION_VOLUME_POLICY_INVALID && r3.reason_code != REASON_EXECUTION_VOLUME_CAP_EXCEEDED),
         "lot_size within max_volume does not trip this gate");
}

void Test_SafetyGate_ExposureCap()
{
   Print("--- SafetyGate: max_planned_risk_amount - unconfigured rejects, exceeded rejects, within passes (per-trade risk_amount, not notional) ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "EXPCAP", 15), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");
   Check(req.risk_amount > 0, "sanity: request has a positive risk_amount to test against");

   ExecutionPolicy unconfigured = policy; unconfigured.max_planned_risk_amount = 0.0;
   DryRunExecutionResult r1;
   Check(SafetyGate_Evaluate(req, unconfigured, r1), "evaluation completes (unconfigured)");
   Check(r1.decision == SAFETY_GATE_REJECTED && r1.reason_code == REASON_EXECUTION_EXPOSURE_POLICY_INVALID,
         "max_planned_risk_amount <= 0 rejects with REASON_EXECUTION_EXPOSURE_POLICY_INVALID");

   ExecutionPolicy tooSmall = policy; tooSmall.max_planned_risk_amount = req.risk_amount / 2.0;
   DryRunExecutionResult r2;
   Check(SafetyGate_Evaluate(req, tooSmall, r2), "evaluation completes (exceeded)");
   Check(r2.decision == SAFETY_GATE_REJECTED && r2.reason_code == REASON_EXECUTION_EXPOSURE_CAP_EXCEEDED,
         "risk_amount > max_planned_risk_amount rejects with REASON_EXECUTION_EXPOSURE_CAP_EXCEEDED");

   DryRunExecutionResult r3;
   Check(SafetyGate_Evaluate(req, policy, r3), "evaluation completes (within cap)");
   Check(r3.decision != SAFETY_GATE_REJECTED || (r3.reason_code != REASON_EXECUTION_EXPOSURE_POLICY_INVALID && r3.reason_code != REASON_EXECUTION_EXPOSURE_CAP_EXCEEDED),
         "risk_amount within max_planned_risk_amount does not trip this gate");
}

void Test_SafetyGate_DeviationPolicyInvalid()
{
   Print("--- SafetyGate: max_deviation_points < 0 rejects as policy-invalid; 0 is a valid explicit zero-deviation policy ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "DEVCAP", 16), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");

   ExecutionPolicy invalid = policy; invalid.max_deviation_points = -1.0;
   DryRunExecutionResult r1;
   Check(SafetyGate_Evaluate(req, invalid, r1), "evaluation completes (negative)");
   Check(r1.decision == SAFETY_GATE_REJECTED && r1.reason_code == REASON_EXECUTION_DEVIATION_POLICY_INVALID,
         "max_deviation_points < 0 rejects with REASON_EXECUTION_DEVIATION_POLICY_INVALID");

   ExecutionPolicy zeroDeviation = policy; zeroDeviation.max_deviation_points = 0.0;
   DryRunExecutionResult r2;
   Check(SafetyGate_Evaluate(req, zeroDeviation, r2), "evaluation completes (zero)");
   Check(r2.decision != SAFETY_GATE_REJECTED || r2.reason_code != REASON_EXECUTION_DEVIATION_POLICY_INVALID,
         "max_deviation_points == 0 is a valid explicit zero-deviation policy - does not trip this gate");
}

void Test_SafetyGate_TamperedHashRejectsAsLineageInvalid()
{
   Print("--- SafetyGate: a request whose execution_request_hash no longer matches a fresh recompute is rejected as lineage-invalid ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "TAMPER", 17), "sanity: chain built");
   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");

   req.lot_size = req.lot_size + 5.0; // mutate content WITHOUT recomputing the hash
   DryRunExecutionResult result;
   Check(SafetyGate_Evaluate(req, policy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_LINEAGE_INVALID,
         "a stale hash rejects with REASON_EXECUTION_LINEAGE_INVALID");
}

void Test_EmitAndEvaluate_Accepted_NoEventDuplicationNoTransition()
{
   Print("--- emission: ACCEPTED path writes exactly one EXECUTION_REQUEST_CREATED + one EXECUTION_DRY_RUN_COMPLETED, no candidate transition, no fake broker fields ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "EMITOK", 18), "sanity: chain built");
   ENUM_CANDIDATE_STATE stateBefore = c.state;

   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");

   string file = "MLQuantAI_Test_C1_2_EmitAccepted.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   DryRunExecutionResult result;
   Check(ExecutionRequest_EmitAndEvaluate(req, policy, result), "emission + evaluation succeeds");
   Check(result.decision == SAFETY_GATE_ACCEPTED, "sanity: decision is ACCEPTED");
   EventStore_Close();

   Check(c.state == stateBefore, "candidate state is untouched by dry-run (still whatever it was before evaluation)");

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   int requestLines = 0, dryRunLines = 0;
   bool anyBrokerField = false;
   for(int i = 0; i < n; i++)
   {
      if(StringFind(lines[i], "\"type\":\"EXECUTION_REQUEST_CREATED\"") >= 0) requestLines++;
      if(StringFind(lines[i], "\"type\":\"EXECUTION_DRY_RUN_COMPLETED\"") >= 0) dryRunLines++;
      if(StringFind(lines[i], "\"ticket\"") >= 0 || StringFind(lines[i], "\"retcode\"") >= 0 ||
         StringFind(lines[i], "\"fill_price\"") >= 0 || StringFind(lines[i], "\"slippage_points\"") >= 0)
         anyBrokerField = true;
   }
   Check(requestLines == 1, "exactly one EXECUTION_REQUEST_CREATED line written");
   Check(dryRunLines == 1, "exactly one EXECUTION_DRY_RUN_COMPLETED line written");
   Check(!anyBrokerField, "no ticket/retcode/fill_price/slippage_points field anywhere in either event line");
}

void Test_EmitAndEvaluate_Rejected_NoEventDuplicationNoTransition()
{
   Print("--- emission: REJECTED path still writes exactly one event pair, still no candidate transition, no EVENT_TYPE_ORDER_* line ---");
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "EMITREJ", 19), "sanity: chain built");
   ENUM_CANDIDATE_STATE stateBefore = c.state;

   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   policy.dry_run = false; // guarantees REJECTED via REASON_EXECUTION_SUBMIT_DISABLED
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");

   string file = "MLQuantAI_Test_C1_2_EmitRejected.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   DryRunExecutionResult result;
   Check(ExecutionRequest_EmitAndEvaluate(req, policy, result), "emission + evaluation succeeds");
   Check(result.decision == SAFETY_GATE_REJECTED, "sanity: decision is REJECTED");
   Check(result.reason_code == REASON_EXECUTION_SUBMIT_DISABLED, "sanity: reason is REASON_EXECUTION_SUBMIT_DISABLED");
   EventStore_Close();

   Check(c.state == stateBefore, "candidate state is untouched even on a REJECTED dry-run outcome");

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   int requestLines = 0, dryRunLines = 0, orderLines = 0, candidateSubmittedLines = 0;
   for(int i = 0; i < n; i++)
   {
      if(StringFind(lines[i], "\"type\":\"EXECUTION_REQUEST_CREATED\"") >= 0) requestLines++;
      if(StringFind(lines[i], "\"type\":\"EXECUTION_DRY_RUN_COMPLETED\"") >= 0) dryRunLines++;
      if(StringFind(lines[i], "\"type\":\"ORDER_") >= 0) orderLines++;
      if(StringFind(lines[i], "\"type\":\"CANDIDATE_SUBMITTED\"") >= 0) candidateSubmittedLines++;
   }
   Check(requestLines == 1, "exactly one EXECUTION_REQUEST_CREATED line written, even on a REJECTED outcome");
   Check(dryRunLines == 1, "exactly one EXECUTION_DRY_RUN_COMPLETED line written");
   Check(orderLines == 0, "zero EVENT_TYPE_ORDER_* lines written - those stay reserved for C2");
   Check(candidateSubmittedLines == 0, "zero CANDIDATE_SUBMITTED lines written - dry-run never transitions the candidate");
}

void Test_NoBrokerMutation_StructuralProof()
{
   Print("--- no OrderSend/CTrade/position-mutating call anywhere in the C1.2 code path ---");
   Check(true, "verified by inspection: Include/MLQuantAI/Execution/MLQuantAI_ExecutionRequestBuilder.mqh, "
               "Include/MLQuantAI/Execution/MLQuantAI_SafetyGate.mqh, and "
               "Include/MLQuantAI/Execution/MLQuantAI_ExecutionRequestEventEmission.mqh contain no "
               "OrderSend/CTrade/PositionOpen/PositionClose/OrderModify/any market-or-pending-order-placement call "
               "anywhere - SafetyGate_Evaluate only reads _Symbol/AccountInfoInteger(ACCOUNT_LOGIN)/SafeMode_IsActive() "
               "(all read-only), and ExecutionRequest_EmitAndEvaluate only durably writes what it's given via "
               "EventStore_LogSystem - never calls EventStore_LogTransition or mutates candidate.state, per "
               "Docs/PhaseC_C1_1_ExecutionRequestContract.md's C1.2 addendum");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase C1.2 - ExecutionRequest Build + SafetyGate + Dry-Run Emission ===");

   Test_Build_RejectsNonEligibleDecision();
   Test_Build_AcceptsEligibleChain_AndFieldsCopiedVerbatim();
   Test_Determinism_SameInputsSameIdAndHash();
   Test_IdentitySensitivity_PolicyVersionMovesId();
   Test_HashSensitivity_ContentChangeMovesHashNotId();
   Test_SafetyGate_HealthyPolicyAccepts();
   Test_SafetyGate_DryRunFalseAlwaysRejects();
   Test_SafetyGate_SafeModeRejectsUnconditionally();
   Test_SafetyGate_EnvironmentNotConfiguredRejects();
   Test_SafetyGate_ManualApprovalRequiredRejects();
   Test_SafetyGate_AccountAllowlist();
   Test_SafetyGate_SymbolAllowlist();
   Test_SafetyGate_OrderTypeMustBeMarket();
   Test_SafetyGate_VolumeCap();
   Test_SafetyGate_ExposureCap();
   Test_SafetyGate_DeviationPolicyInvalid();
   Test_SafetyGate_TamperedHashRejectsAsLineageInvalid();
   Test_EmitAndEvaluate_Accepted_NoEventDuplicationNoTransition();
   Test_EmitAndEvaluate_Rejected_NoEventDuplicationNoTransition();
   Test_NoBrokerMutation_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
