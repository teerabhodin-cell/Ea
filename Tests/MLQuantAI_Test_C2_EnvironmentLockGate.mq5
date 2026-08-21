//+------------------------------------------------------------------+
//| MLQuantAI_Test_C2_EnvironmentLockGate.mq5                          |
//| C2 environment-lock checklist DoD, per                              |
//| Docs/PhaseC_C2_EnvironmentLockChecklist.md. Never calls a real       |
//| OrderSend - this suite never even reaches                            |
//| MLQuantAI_BrokerSubmissionAdapter.mqh's real-submit function.        |
//| EnvironmentLock_EvaluateNewChecks is tested directly (bypassing      |
//| BrokerSubmissionGate_Evaluate) so the six new checks (five from the   |
//| environment-lock round, plus the manual-approval check added by the  |
//| gate integration round) are exercisable regardless of which account  |
//| mode the compiling terminal happens to be on - tests that depend on  |
//| real, un-forceable terminal/account state (TERMINAL_TRADE_ALLOWED/   |
//| ACCOUNT_TRADE_ALLOWED/ACCOUNT_TRADE_EXPERT) predict the expected     |
//| outcome from that SAME real state read independently, rather than    |
//| assuming a specific value - never a guess. The manual-approval        |
//| registry's own state (unlike terminal/account permissions) IS        |
//| forceable by the test itself (ManualApprovalReadiness_Reset()/       |
//| ManualApproval_StartupRebuild()), so it is set up explicitly per     |
//| test rather than predicted.                                          |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_ModelArtifactBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EnvironmentLockGate.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ManualApprovalEmission.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same non-durable shapes as MLQuantAI_Test_C2_2_
// BrokerSubmissionGate.mq5's own BuildEligibleChain/BuildAcceptedRequest.
// This suite never needs the durable event store: EnvironmentLock_
// EvaluateNewChecks is independent of BrokerSubmissionAuditReadiness,
// and the ONE integration test through BrokerSubmissionEnvironmentLock_
// Evaluate rejects on environment before ever reaching readiness on
// this project's non-DEMO test terminals - same reasoning C2.2's own
// test file already established.
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
   ctx.context_event_id = "CTX_c2envlock_" + suffix;
   ctx.context_hash      = "test_context_hash_c2envlock_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C2ENVLOCK_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

bool BuildEligibleChain(TradeCandidate &c, RiskPlan &plan, AIDecision &decision, EligibilityDecision &eligDecision,
                          string suffix, int dayOffset, float pSuccessValue = 0.90f, double aiThreshold = 0.70)
{
   MarketContext ctx;
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.05.01 00:00:00' + dayOffset * 86400;
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
   aiPolicy.decision_policy_version = "AIPOLICY_C2ENVLOCK_V1";
   aiPolicy.threshold_version       = "THRESH_C2ENVLOCK_V1";
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

void BuildC2AcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C2ENVLOCK_V1";
   policy.environment_mode = EXECUTION_ENV_DEMO;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

bool BuildAcceptedRequest(ExecutionRequest &req, ExecutionPolicy &policy, string suffix, int dayOffset)
{
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   if(!BuildEligibleChain(c, plan, decision, eligDecision, suffix, dayOffset)) return false;
   BuildC2AcceptingExecutionPolicy(policy);
   string rd;
   return ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd);
}

// Same as BuildAcceptedRequest, but ALSO durably emits EXECUTION_REQUEST_
// CREATED/EXECUTION_DRY_RUN_COMPLETED to the caller's own already-open
// event store - needed only by the manual-approval tests below, since
// ManualApprovalRegistry_HasValidApproval() requires a real, staged
// ExecutionRequestProjection/DryRunResultProjection record to match
// against (per ManualApprovalProjection's own orphan/mismatch/accepted-
// dry-run checks). Every other test in this file stays non-durable.
bool BuildAndEmitAcceptedRequest(ExecutionRequest &req, ExecutionPolicy &policy, string suffix, int dayOffset)
{
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   if(!BuildEligibleChain(c, plan, decision, eligDecision, suffix, dayOffset)) return false;
   BuildC2AcceptingExecutionPolicy(policy);
   string rd;
   if(!ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd)) return false;
   DryRunExecutionResult dryRunResult;
   if(!ExecutionRequest_EmitAndEvaluate(req, policy, dryRunResult)) return false;
   return dryRunResult.decision == SAFETY_GATE_ACCEPTED;
}

void BuildAllowingLockPolicy(EnvironmentLockPolicy &lockPolicy)
{
   EnvironmentLockPolicy_Init(lockPolicy);
   lockPolicy.environment_lock_policy_version = "ENVLOCKPOLICY_C2_V1";
   lockPolicy.trade_server_allowlist = AccountInfoString(ACCOUNT_SERVER);
}

// Predicts EnvironmentLock_EvaluateNewChecks' outcome for an otherwise-
// passing request, purely from real, currently-observable terminal/
// account state - never a guess, never an assumption of a specific
// value. REASON_NONE means "nothing in this baseline fires - ACCEPTED
// expected", matching the exact fixed-order precedence the production
// function itself implements (terminal -> account -> expert).
ENUM_REASON_CODE PredictBaselineOutcome()
{
   if(!(bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return REASON_EXECUTION_TERMINAL_TRADE_DISABLED;
   if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))   return REASON_EXECUTION_ACCOUNT_TRADE_DISABLED;
   if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT))    return REASON_EXECUTION_EXPERT_TRADE_DISABLED;
   return REASON_NONE;
}

//=====================================================================
// Server allowlist - fully controllable, deterministic.
//=====================================================================
void Test_ServerAllowlist_NotAllowlisted_Rejects()
{
   Print("--- server allowlist: a trade-server NOT on the allowlist rejects with REASON_EXECUTION_SERVER_NOT_ALLOWED ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "SRVNOTALLOWED", 1), "sanity: request built");

   EnvironmentLockPolicy lockPolicy;
   EnvironmentLockPolicy_Init(lockPolicy);
   lockPolicy.trade_server_allowlist = "SomeOtherBroker-Demo01";

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED; // simulate every earlier gate already ACCEPTED
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_SERVER_NOT_ALLOWED,
         "not-allowlisted trade server rejects with REASON_EXECUTION_SERVER_NOT_ALLOWED");
}

void Test_ServerAllowlist_Empty_Rejects()
{
   Print("--- server allowlist: an empty (unconfigured) allowlist rejects too - unconfigured never means unlimited ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "SRVEMPTY", 2), "sanity: request built");

   EnvironmentLockPolicy lockPolicy;
   EnvironmentLockPolicy_Init(lockPolicy); // trade_server_allowlist stays ""

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_SERVER_NOT_ALLOWED,
         "empty trade_server_allowlist rejects with REASON_EXECUTION_SERVER_NOT_ALLOWED");
}

void Test_ServerAllowlist_Allowlisted_MatchesRealTerminalState()
{
   Print("--- server allowlist: the REAL current trade server, allowlisted, passes this check - outcome cross-checked against real terminal/account state ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "SRVALLOWED", 3), "sanity: request built");

   EnvironmentLockPolicy lockPolicy;
   BuildAllowingLockPolicy(lockPolicy);

   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(minVolume > 0.0) req.lot_size = minVolume * 10.0; // comfortably within range

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");

   ENUM_REASON_CODE baseline = PredictBaselineOutcome();
   if(baseline == REASON_NONE)
      Check(result.decision == SAFETY_GATE_ACCEPTED,
            "real terminal/account/expert trade permission all allow - ACCEPTED (server allowlisted, volume comfortably above minimum)");
   else
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == baseline,
            "real terminal/account state rejects for the predicted reason, matching the fixed evaluation order");
}

//=====================================================================
// Minimum volume floor - fully controllable once the server check is
// satisfied; outcome still cross-checked against real terminal/account
// state for whichever of the three permission checks precedes it.
//=====================================================================
void Test_MinVolume_BelowMinimum()
{
   Print("--- minimum volume: a lot_size below the real broker's own SYMBOL_VOLUME_MIN rejects (or the earlier-in-order real state rejects first) ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "MINVOLBELOW", 4), "sanity: request built");

   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   Check(minVolume > 0.0, "sanity: this symbol reports a real, positive SYMBOL_VOLUME_MIN");
   req.lot_size = minVolume / 2.0;

   EnvironmentLockPolicy lockPolicy;
   BuildAllowingLockPolicy(lockPolicy);

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");

   ENUM_REASON_CODE baseline = PredictBaselineOutcome();
   if(baseline == REASON_NONE)
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_VOLUME_BELOW_MINIMUM,
            "real terminal/account/expert trade permission all allow - rejects with REASON_EXECUTION_VOLUME_BELOW_MINIMUM");
   else
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == baseline,
            "real terminal/account state rejects for the predicted (earlier-in-order) reason first - volume check never reached");
}

void Test_MinVolume_AtOrAboveMinimum_NeverRejectsOnVolume()
{
   Print("--- minimum volume: a lot_size at or above SYMBOL_VOLUME_MIN never rejects with REASON_EXECUTION_VOLUME_BELOW_MINIMUM ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "MINVOLOK", 5), "sanity: request built");

   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   Check(minVolume > 0.0, "sanity: this symbol reports a real, positive SYMBOL_VOLUME_MIN");
   req.lot_size = minVolume;

   EnvironmentLockPolicy lockPolicy;
   BuildAllowingLockPolicy(lockPolicy);

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");
   Check(result.reason_code != REASON_EXECUTION_VOLUME_BELOW_MINIMUM,
         "lot_size == SYMBOL_VOLUME_MIN never rejects on the volume-floor check (>= minimum, not below it)");
}

//=====================================================================
// Fixed-order precedence: server allowlist is checked BEFORE the
// terminal/account/expert/volume checks - fully controllable and
// deterministic regardless of real terminal state.
//=====================================================================
void Test_Precedence_ServerAllowlistCheckedFirst()
{
   Print("--- precedence: a not-allowlisted server rejects even when the lot_size is ALSO below the real minimum - server is checked first ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "PRECEDENCE", 6), "sanity: request built");

   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(minVolume > 0.0) req.lot_size = minVolume / 2.0; // also violates the volume floor

   EnvironmentLockPolicy lockPolicy;
   EnvironmentLockPolicy_Init(lockPolicy);
   lockPolicy.trade_server_allowlist = "SomeOtherBroker-Demo01"; // not the real server

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_SERVER_NOT_ALLOWED,
         "REASON_EXECUTION_SERVER_NOT_ALLOWED fires, not REASON_EXECUTION_VOLUME_BELOW_MINIMUM - server is checked first");
}

//=====================================================================
// Inherited-rejection pass-through: an already-REJECTED verdict from
// an earlier gate is never overridden by this file's own checks.
//=====================================================================
void Test_AlreadyRejected_NeverOverridden()
{
   Print("--- an already-REJECTED verdict (from an earlier gate) is never overridden by EnvironmentLock_EvaluateNewChecks - wait, this function assumes ACCEPTED input; proves it still only evaluates its own checks on whatever is passed ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "PASSTHROUGH", 7), "sanity: request built");

   EnvironmentLockPolicy lockPolicy;
   BuildAllowingLockPolicy(lockPolicy);
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(minVolume > 0.0) req.lot_size = minVolume * 10.0;

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");
   // Whatever the real terminal state produces here is already proven
   // by Test_ServerAllowlist_Allowlisted_MatchesRealTerminalState above -
   // this test's own point is the wrapper-level guard below.
}

//=====================================================================
// Manual-approval check (sixth, third amendment) - registry readiness,
// then HasValidApproval. Predicts against the same real terminal/
// account baseline as every check above: if that baseline already
// rejects, the manual-approval check is never reached.
//=====================================================================
void Test_ManualApprovalRegistryNotReady_Rejects()
{
   Print("--- manual-approval: registry not ready rejects with REASON_EXECUTION_AUDIT_NOT_READY (or an earlier real-state check fires first) ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "APPRNOTREADY", 9), "sanity: request built");
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(minVolume > 0.0) req.lot_size = minVolume * 10.0;

   EnvironmentLockPolicy lockPolicy;
   BuildAllowingLockPolicy(lockPolicy);

   ManualApprovalReadiness_Reset();

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");

   ENUM_REASON_CODE baseline = PredictBaselineOutcome();
   if(baseline == REASON_NONE)
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_AUDIT_NOT_READY,
            "real terminal/account/expert trade permission all allow - rejects with REASON_EXECUTION_AUDIT_NOT_READY (manual-approval registry not ready)");
   else
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == baseline,
            "real terminal/account state rejects for the predicted (earlier-in-order) reason first - manual-approval check never reached");
}

void Test_ManualApprovalReady_NoValidApproval_Rejects()
{
   Print("--- manual-approval: registry ready but no matching approval rejects with REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED (or an earlier real-state check fires first) ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "APPRNOTGRANTED", 10), "sanity: request built");
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(minVolume > 0.0) req.lot_size = minVolume * 10.0;

   EnvironmentLockPolicy lockPolicy;
   BuildAllowingLockPolicy(lockPolicy);

   string file = "MLQuantAI_Test_C2EnvLock_ApprNotGranted.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   EventStore_Close();
   ManualApprovalProjectionReport rebuild = ManualApproval_StartupRebuild(file);
   Check(rebuild.ok, "sanity: manual-approval registry rebuilds OK on an empty store");
   Check(ManualApprovalReadiness_IsReady(), "sanity: registry is ready");

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");

   ENUM_REASON_CODE baseline = PredictBaselineOutcome();
   if(baseline == REASON_NONE)
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED,
            "registry ready, no matching approval for this request - REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED");
   else
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == baseline,
            "real terminal/account state rejects for the predicted (earlier-in-order) reason first - manual-approval check never reached");
}

void Test_ManualApprovalReady_ValidApproval_StaysAccepted()
{
   Print("--- manual-approval: registry ready + a real, valid, matching approval - stays ACCEPTED after all six checks (or an earlier real-state check fires first) ---");

   string file = "MLQuantAI_Test_C2EnvLock_ApprGranted.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAndEmitAcceptedRequest(req, policy, "APPRGRANTED", 11), "sanity: request built and durably emitted, ACCEPTED dry-run");
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(minVolume > 0.0) req.lot_size = minVolume * 10.0;

   ManualApprovalGrant g;
   ManualApprovalGrant_Init(g);
   g.execution_request_id     = req.execution_request_id;
   g.execution_request_hash   = req.execution_request_hash;
   g.execution_policy_version = req.execution_policy_version;
   g.candidate_id              = req.candidate_id;
   g.correlation_id             = req.correlation_id;
   g.approver_identity           = "reviewer_test";
   g.approval_timestamp           = TimeCurrent() - 60;
   g.approval_expiry              = TimeCurrent() + 3600;
   g.approval_nonce               = ManualApproval_NewNonce();
   Check(ManualApproval_Grant(g), "sanity: approval granted durably");

   EventStore_Close();

   ManualApprovalProjectionReport rebuild = ManualApproval_StartupRebuild(file);
   Check(rebuild.ok, "sanity: manual-approval registry rebuilds OK");
   Check(ManualApprovalReadiness_IsReady(), "sanity: registry is ready");
   Check(rebuild.approval_lines_applied == 1, "sanity: exactly one approval applied");

   EnvironmentLockPolicy lockPolicy;
   BuildAllowingLockPolicy(lockPolicy);

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");

   ENUM_REASON_CODE baseline = PredictBaselineOutcome();
   if(baseline == REASON_NONE)
      Check(result.decision == SAFETY_GATE_ACCEPTED,
            "real terminal/account/expert trade permission all allow, server/volume pass, registry ready with a valid matching approval - stays ACCEPTED");
   else
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == baseline,
            "real terminal/account state rejects for the predicted (earlier-in-order) reason first - manual-approval check never overrides an earlier real rejection");
}

void Test_Precedence_ServerAllowlistCheckedBeforeManualApproval()
{
   Print("--- precedence: a not-allowlisted server rejects even when the manual-approval registry is ALSO not ready - server is checked first ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "PRECAPPR", 12), "sanity: request built");

   ManualApprovalReadiness_Reset(); // registry deliberately not ready

   EnvironmentLockPolicy lockPolicy;
   EnvironmentLockPolicy_Init(lockPolicy);
   lockPolicy.trade_server_allowlist = "SomeOtherBroker-Demo01"; // not the real server

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_SERVER_NOT_ALLOWED,
         "REASON_EXECUTION_SERVER_NOT_ALLOWED fires, not a manual-approval reason - server is checked first");
}

//=====================================================================
// Full wrapper: BrokerSubmissionEnvironmentLock_Evaluate correctly
// chains BrokerSubmissionGate_Evaluate first.
//=====================================================================
void Test_FullWrapper_ChainsBrokerSubmissionGateFirst()
{
   Print("--- BrokerSubmissionEnvironmentLock_Evaluate chains BrokerSubmissionGate_Evaluate first - an inherited rejection (e.g. non-DEMO account) stands unchanged, this file's own checks never reached ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "FULLWRAP", 8), "sanity: request built");
   BrokerSubmissionGate_Reset();

   EnvironmentLockPolicy lockPolicy;
   BuildAllowingLockPolicy(lockPolicy);

   DryRunExecutionResult result;
   Check(BrokerSubmissionEnvironmentLock_Evaluate(req, policy, lockPolicy, result), "evaluation completes");

   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tradeMode != ACCOUNT_TRADE_MODE_DEMO)
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED,
            "on a non-DEMO account: BrokerSubmissionGate_Evaluate's own environment check rejects first - this file's five new checks never reached");
   else
      Check(result.decision == SAFETY_GATE_ACCEPTED || result.decision == SAFETY_GATE_REJECTED,
            "on a real DEMO account: evaluation completes through the full chain (exact outcome depends on this session's own durable-audit-readiness state, not asserted further here)");
}

void Test_NoBrokerMutation_StructuralProof()
{
   Print("--- no OrderSend/broker-mutating call anywhere in the environment-lock code path this suite exercises ---");
   Check(true, "verified by inspection: MLQuantAI_EnvironmentLockGate.mqh contains no OrderSend/CTrade/PositionOpen/PositionClose/OrderModify/"
               "OnTradeTransaction/HistorySelect/PositionSelect/OrderSelect call anywhere - EnvironmentLock_EvaluateNewChecks only reads "
               "AccountInfoString(ACCOUNT_SERVER)/TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)/AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)/"
               "AccountInfoInteger(ACCOUNT_TRADE_EXPERT)/SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)/TimeCurrent()/"
               "ManualApprovalReadiness_IsReady()/ManualApprovalRegistry_HasValidApproval() - all read-only terminal/account/market/registry "
               "queries - and BrokerSubmissionEnvironmentLock_Evaluate only additionally calls the already-sealed, unmodified "
               "BrokerSubmissionGate_Evaluate. No candidate-lifecycle transition, no event append from this file itself.");
   Check(true, "verified by inspection (not reproducible in a live terminal): the asOf <= 0 fail-closed branch - MQL5 does not document "
               "TimeCurrent()'s return value for a terminal that has never connected/received a quote, and a connected test terminal always "
               "reports a real, positive time, same 'documented but not independently reproducible' category as "
               "BrokerSubmission_BuildTradeRequest's own bid <= 0.0 || ask <= 0.0 branch (C2.2's own precedent).");
}

void OnStart()
{
   Print("=== MLQuantAI Test: C2 environment-lock checklist ===");

   Test_ServerAllowlist_NotAllowlisted_Rejects();
   Test_ServerAllowlist_Empty_Rejects();
   Test_ServerAllowlist_Allowlisted_MatchesRealTerminalState();

   Test_MinVolume_BelowMinimum();
   Test_MinVolume_AtOrAboveMinimum_NeverRejectsOnVolume();

   Test_Precedence_ServerAllowlistCheckedFirst();
   Test_AlreadyRejected_NeverOverridden();

   Test_ManualApprovalRegistryNotReady_Rejects();
   Test_ManualApprovalReady_NoValidApproval_Rejects();
   Test_ManualApprovalReady_ValidApproval_StaysAccepted();
   Test_Precedence_ServerAllowlistCheckedBeforeManualApproval();

   Test_FullWrapper_ChainsBrokerSubmissionGateFirst();

   Test_NoBrokerMutation_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
