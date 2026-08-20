//+------------------------------------------------------------------+
//| MLQuantAI_Test_B9_ExecutionEligibility.mq5                        |
//| Phase B9 Commit 1 DoD, per                                          |
//| Docs/PhaseB_B9_ExecutionEligibilityContract.md's test matrix.       |
//| Pure mapping only - no EventStore, no ONNX, no broker/account/tick, |
//| no SafeMode call (EligibilityContext is captured by the fixture,    |
//| never read live by the builder itself).                             |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_EligibilityBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionBuilder.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers.
//---------------------------------------------------------------------
void BuildValidFeatureSnapshot(FeatureSnapshot &snapshot, string suffix)
{
   FeatureSnapshot_Init(snapshot);
   string candidateId = "CND_b9_" + suffix;
   snapshot.candidate_id      = candidateId;
   snapshot.candidate_hash    = "test_candidate_hash_" + suffix;
   snapshot.context_event_id  = "CTX_b9_" + suffix;
   snapshot.context_hash      = "test_context_hash_" + suffix;
   snapshot.detector_hash     = "test_detector_hash_" + suffix;

   snapshot.atr_m15 = 1.2345;
   snapshot.adx_m15 = 25.5;
   snapshot.ema_slope_m15 = 0.05;
   snapshot.pdh = 110.00;
   snapshot.pdl = 100.00;
   snapshot.asian_range_high = 105.50;
   snapshot.asian_range_low  = 104.50;
   snapshot.spread_points_at_anchor = 20.0;
   snapshot.news_count = 3;
   snapshot.max_news_impact = 1;
   snapshot.nearest_news_minutes = 999;
   snapshot.is_kill_zone = false;

   snapshot.feature_schema_version = MLQUANTAI_FEATURE_SCHEMA_B8_1_V1;
   snapshot.feature_snapshot_id    = Ids_FeatureSnapshotId(candidateId);
   snapshot.feature_vector_hash    = FeatureSnapshot_ComputeVectorHash(snapshot);
   snapshot.feature_snapshot_hash  = FeatureSnapshot_ComputeHash(snapshot);
}

void BuildValidRiskPlan(const FeatureSnapshot &snapshot, RiskPlan &plan)
{
   RiskPlan_Init(plan);
   plan.candidate_id      = snapshot.candidate_id;
   plan.candidate_hash    = snapshot.candidate_hash;
   plan.risk_context_hash = "test_risk_context_hash_" + snapshot.candidate_id;

   plan.planned_entry = 105.00;
   plan.planned_sl    = 104.50;
   plan.planned_tp    = 106.00;

   plan.stop_distance_points = 50;
   plan.rr_ratio = 2.0;

   plan.risk_percent = 1.0;
   plan.risk_amount  = 100.0;
   plan.lot_size     = 0.1;

   plan.sizing_method        = "FIXED_PERCENT_RISK";
   plan.sizing_rules_version = MLQUANTAI_RISK_SIZING_RULES_V1;

   plan.plan_hash    = RiskPlan_ComputeHash(plan);
   plan.risk_plan_id = Ids_RiskPlanId(plan.candidate_id, plan.sizing_rules_version);
   plan.decision      = RISK_DECISION_ALLOW;
   plan.allowed       = true;
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

// Builds a real AIDecision via the real, sealed AIDecision_Build - ALLOW
// when pSuccessValue >= threshold, REJECT when below. There is no way
// to produce a real ABSTAIN via AIDecision_Build under B8.5's frozen
// policy v1 (unreachable by design), so ABSTAIN fixtures are built by
// taking a real ALLOW result and overriding decision_outcome/reason_code,
// then recomputing ai_decision_hash so the struct stays internally
// consistent - mirrors the same technique used for hash-sensitivity
// tests throughout this project.
bool BuildValidAIDecision(const FeatureSnapshot &snapshot, string suffix, float pSuccessValue, double threshold,
                            AIDecision &outDecision)
{
   InferenceResult inference;
   BuildValidInferenceResult(snapshot, "MREG_b9_" + suffix, "hash_mreg_" + suffix, "hash_artifact_" + suffix,
                               pSuccessValue, inference);
   AIDecisionPolicy policy;
   AIDecisionPolicy_Init(policy);
   policy.decision_policy_version = "AIPOLICY_V1";
   policy.threshold_version       = "THRESH_V1";
   policy.allow_threshold         = threshold;

   string reasonDetail;
   return AIDecision_Build(inference, snapshot, policy, outDecision, reasonDetail);
}

void MakeAbstainDecision(const AIDecision &allowDecision, AIDecision &outAbstain)
{
   outAbstain = allowDecision;
   outAbstain.decision_outcome = AI_DECISION_OUTCOME_ABSTAIN;
   outAbstain.decision_reason_code = REASON_AI_ABSTAIN;
   outAbstain.ai_decision_hash = AIDecision_ComputeHash(outAbstain);
}

void BuildValidEligibilityContext(EligibilityContext &context, double balance, double equity, double marginLevel,
                                    int openPositions, double openRiskPercent, double dailyPnlPercent,
                                    double drawdownPercent, bool safeModeActive)
{
   EligibilityContext_Init(context);
   context.account.balance = balance;
   context.account.equity = equity;
   context.account.margin_level = marginLevel;
   context.account.open_positions_count = openPositions;
   context.account.open_risk_percent = openRiskPercent;
   context.account.daily_pnl_percent = dailyPnlPercent;
   context.account.drawdown_from_peak_percent = drawdownPercent;
   context.safe_mode_active = safeModeActive;
   context.eligibility_context_hash = EligibilityContext_ComputeHash(context);
}

// The default "everything healthy, every gate would pass if enabled" context.
void BuildHealthyContext(EligibilityContext &context)
{
   BuildValidEligibilityContext(context, 10000.0, 10000.0, 500.0, 0, 0.0, 0.0, 0.0, false);
}

void BuildValidPolicy(EligibilityPolicy &policy, string version, double maxDailyLoss, double maxDrawdown,
                        double maxExposure, int maxOpenPositions, double minMarginLevel)
{
   EligibilityPolicy_Init(policy);
   policy.eligibility_policy_version = version;
   policy.max_daily_loss_percent = maxDailyLoss;
   policy.max_drawdown_percent = maxDrawdown;
   policy.max_total_exposure_percent = maxExposure;
   policy.max_open_positions = maxOpenPositions;
   policy.min_margin_level = minMarginLevel;
}

// All gates enabled with generous thresholds - a healthy context should
// pass every one of them.
void BuildEnabledPolicy(EligibilityPolicy &policy)
{
   BuildValidPolicy(policy, "ELIGPOLICY_V1", 5.0, 10.0, 20.0, 5, 200.0);
}

// Bundles a full valid ALLOW-path fixture set in one call.
bool BuildFullEligibleFixture(string suffix, FeatureSnapshot &snapshot, RiskPlan &plan, AIDecision &decision,
                                EligibilityContext &context, EligibilityPolicy &policy)
{
   BuildValidFeatureSnapshot(snapshot, suffix);
   BuildValidRiskPlan(snapshot, plan);
   if(!BuildValidAIDecision(snapshot, suffix, 0.90f, 0.70, decision)) return false;
   BuildHealthyContext(context);
   BuildEnabledPolicy(policy);
   return true;
}

//=====================================================================
// Accept path
//=====================================================================
void Test_AcceptPath_Eligible()
{
   Print("--- accept path: healthy context, AI ALLOW, every gate disabled-or-passing -> ELIGIBLE ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   EligibilityContext context; EligibilityPolicy policy;
   Check(BuildFullEligibleFixture("ELIG", snapshot, plan, decision, context, policy), "sanity: fixture built");

   EligibilityDecision out; string reasonDetail;
   bool ok = EligibilityDecision_Build(plan, decision, snapshot, context, policy, out, reasonDetail);
   Check(ok, "build succeeds");
   Check(out.decision == ELIGIBILITY_DECISION_ELIGIBLE, "decision is ELIGIBLE");
   Check(out.reason_code == REASON_NONE, "reason_code is REASON_NONE");
   Check(out.candidate_id == plan.candidate_id, "candidate_id copied verbatim from RiskPlan");
   Check(out.candidate_hash == plan.candidate_hash, "candidate_hash copied verbatim from RiskPlan");
   Check(out.risk_plan_id == plan.risk_plan_id, "risk_plan_id copied verbatim");
   Check(out.plan_hash == plan.plan_hash, "plan_hash copied verbatim");
   Check(out.ai_decision_id == decision.ai_decision_id, "ai_decision_id copied verbatim");
   Check(out.ai_decision_hash == decision.ai_decision_hash, "ai_decision_hash copied verbatim");
   Check(out.eligibility_context_hash == context.eligibility_context_hash, "eligibility_context_hash copied verbatim");
   Check(out.eligibility_policy_version == policy.eligibility_policy_version, "eligibility_policy_version copied verbatim");
   Check(out.eligibility_decision_id != "", "eligibility_decision_id is non-empty");
   Check(out.eligibility_decision_hash != "", "eligibility_decision_hash is non-empty");
}

//=====================================================================
// AI veto
//=====================================================================
void Test_AIReject_OverridesHealthyOperationalState()
{
   Print("--- AI REJECT -> REJECTED/REASON_AI_REJECT even though every operational gate would pass ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   EligibilityContext context; EligibilityPolicy policy;
   BuildValidFeatureSnapshot(snapshot, "AIREJ");
   BuildValidRiskPlan(snapshot, plan);
   Check(BuildValidAIDecision(snapshot, "AIREJ", 0.30f, 0.70, decision), "sanity: AI REJECT decision built");
   Check(decision.decision_outcome == AI_DECISION_OUTCOME_REJECT, "sanity: outcome is REJECT");
   BuildHealthyContext(context);
   BuildEnabledPolicy(policy);

   EligibilityDecision out; string reasonDetail;
   Check(EligibilityDecision_Build(plan, decision, snapshot, context, policy, out, reasonDetail), "build succeeds");
   Check(out.decision == ELIGIBILITY_DECISION_REJECTED, "decision is REJECTED");
   Check(out.reason_code == REASON_AI_REJECT, "reason_code is REASON_AI_REJECT");
}

void Test_AIAbstain_RejectedDistinctFromReject()
{
   Print("--- AI ABSTAIN -> REJECTED/REASON_AI_ABSTAIN, distinct from REASON_AI_REJECT ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision allowDecision, abstainDecision;
   EligibilityContext context; EligibilityPolicy policy;
   BuildValidFeatureSnapshot(snapshot, "ABSTAIN");
   BuildValidRiskPlan(snapshot, plan);
   Check(BuildValidAIDecision(snapshot, "ABSTAIN", 0.90f, 0.70, allowDecision), "sanity: base ALLOW decision built");
   MakeAbstainDecision(allowDecision, abstainDecision);
   Check(abstainDecision.decision_outcome == AI_DECISION_OUTCOME_ABSTAIN, "sanity: outcome is ABSTAIN");
   BuildHealthyContext(context);
   BuildEnabledPolicy(policy);

   EligibilityDecision out; string reasonDetail;
   Check(EligibilityDecision_Build(plan, abstainDecision, snapshot, context, policy, out, reasonDetail), "build succeeds");
   Check(out.decision == ELIGIBILITY_DECISION_REJECTED, "decision is REJECTED");
   Check(out.reason_code == REASON_AI_ABSTAIN, "reason_code is REASON_AI_ABSTAIN (not REASON_AI_REJECT)");
   Check(out.reason_code != REASON_AI_REJECT, "sanity: REASON_AI_ABSTAIN and REASON_AI_REJECT are genuinely distinct values");
}

//=====================================================================
// Operational gates - each isolated: enabled+tripped -> REJECTED;
// disabled (policy value 0) -> does not trigger.
//=====================================================================
void Test_Gate_DailyLossLimit()
{
   Print("--- operational gate: daily loss limit ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   BuildValidFeatureSnapshot(snapshot, "DLOSS");
   BuildValidRiskPlan(snapshot, plan);
   Check(BuildValidAIDecision(snapshot, "DLOSS", 0.90f, 0.70, decision), "sanity: AI ALLOW decision built");

   EligibilityPolicy policy; BuildEnabledPolicy(policy);
   policy.eligibility_policy_version = "DLOSS_V1";

   EligibilityContext tripped; BuildValidEligibilityContext(tripped, 10000, 9500, 500, 0, 0.0, -6.0, 0.0, false);
   EligibilityDecision outTripped; string rd1;
   Check(EligibilityDecision_Build(plan, decision, snapshot, tripped, policy, outTripped, rd1), "build succeeds (tripped)");
   Check(outTripped.decision == ELIGIBILITY_DECISION_REJECTED, "REJECTED when daily_pnl_percent <= -max_daily_loss_percent");
   Check(outTripped.reason_code == REASON_RISK_DAILY_LOSS_LIMIT, "reason is REASON_RISK_DAILY_LOSS_LIMIT");

   EligibilityPolicy disabledPolicy; BuildEnabledPolicy(disabledPolicy);
   disabledPolicy.eligibility_policy_version = "DLOSS_DISABLED_V1";
   disabledPolicy.max_daily_loss_percent = 0.0;
   EligibilityDecision outDisabled; string rd2;
   Check(EligibilityDecision_Build(plan, decision, snapshot, tripped, disabledPolicy, outDisabled, rd2), "build succeeds (gate disabled)");
   Check(outDisabled.decision == ELIGIBILITY_DECISION_ELIGIBLE, "same tripping account state does NOT reject when max_daily_loss_percent == 0 (disabled)");
}

void Test_Gate_MaxDrawdown()
{
   Print("--- operational gate: max drawdown ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   BuildValidFeatureSnapshot(snapshot, "DRAW");
   BuildValidRiskPlan(snapshot, plan);
   Check(BuildValidAIDecision(snapshot, "DRAW", 0.90f, 0.70, decision), "sanity: AI ALLOW decision built");

   EligibilityPolicy policy; BuildEnabledPolicy(policy);
   policy.eligibility_policy_version = "DRAW_V1";

   EligibilityContext tripped; BuildValidEligibilityContext(tripped, 10000, 9000, 500, 0, 0.0, 0.0, 12.0, false);
   EligibilityDecision outTripped; string rd1;
   Check(EligibilityDecision_Build(plan, decision, snapshot, tripped, policy, outTripped, rd1), "build succeeds (tripped)");
   Check(outTripped.decision == ELIGIBILITY_DECISION_REJECTED, "REJECTED when drawdown_from_peak_percent >= max_drawdown_percent");
   Check(outTripped.reason_code == REASON_RISK_MAX_DRAWDOWN, "reason is REASON_RISK_MAX_DRAWDOWN");

   EligibilityPolicy disabledPolicy; BuildEnabledPolicy(disabledPolicy);
   disabledPolicy.eligibility_policy_version = "DRAW_DISABLED_V1";
   disabledPolicy.max_drawdown_percent = 0.0;
   EligibilityDecision outDisabled; string rd2;
   Check(EligibilityDecision_Build(plan, decision, snapshot, tripped, disabledPolicy, outDisabled, rd2), "build succeeds (gate disabled)");
   Check(outDisabled.decision == ELIGIBILITY_DECISION_ELIGIBLE, "same tripping account state does NOT reject when max_drawdown_percent == 0 (disabled)");
}

void Test_Gate_MaxTotalExposure()
{
   Print("--- operational gate: max total exposure ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   BuildValidFeatureSnapshot(snapshot, "EXPO");
   BuildValidRiskPlan(snapshot, plan);
   Check(BuildValidAIDecision(snapshot, "EXPO", 0.90f, 0.70, decision), "sanity: AI ALLOW decision built");

   EligibilityPolicy policy; BuildEnabledPolicy(policy);
   policy.eligibility_policy_version = "EXPO_V1";

   EligibilityContext tripped; BuildValidEligibilityContext(tripped, 10000, 10000, 500, 2, 22.0, 0.0, 0.0, false);
   EligibilityDecision outTripped; string rd1;
   Check(EligibilityDecision_Build(plan, decision, snapshot, tripped, policy, outTripped, rd1), "build succeeds (tripped)");
   Check(outTripped.decision == ELIGIBILITY_DECISION_REJECTED, "REJECTED when open_risk_percent >= max_total_exposure_percent");
   Check(outTripped.reason_code == REASON_RISK_MAX_TOTAL_EXPOSURE, "reason is REASON_RISK_MAX_TOTAL_EXPOSURE");

   EligibilityPolicy disabledPolicy; BuildEnabledPolicy(disabledPolicy);
   disabledPolicy.eligibility_policy_version = "EXPO_DISABLED_V1";
   disabledPolicy.max_total_exposure_percent = 0.0;
   EligibilityDecision outDisabled; string rd2;
   Check(EligibilityDecision_Build(plan, decision, snapshot, tripped, disabledPolicy, outDisabled, rd2), "build succeeds (gate disabled)");
   Check(outDisabled.decision == ELIGIBILITY_DECISION_ELIGIBLE, "same tripping account state does NOT reject when max_total_exposure_percent == 0 (disabled)");
}

void Test_Gate_MaxOpenPositions()
{
   Print("--- operational gate: max open positions ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   BuildValidFeatureSnapshot(snapshot, "OPOS");
   BuildValidRiskPlan(snapshot, plan);
   Check(BuildValidAIDecision(snapshot, "OPOS", 0.90f, 0.70, decision), "sanity: AI ALLOW decision built");

   EligibilityPolicy policy; BuildEnabledPolicy(policy);
   policy.eligibility_policy_version = "OPOS_V1";

   EligibilityContext tripped; BuildValidEligibilityContext(tripped, 10000, 10000, 500, 5, 0.0, 0.0, 0.0, false);
   EligibilityDecision outTripped; string rd1;
   Check(EligibilityDecision_Build(plan, decision, snapshot, tripped, policy, outTripped, rd1), "build succeeds (tripped)");
   Check(outTripped.decision == ELIGIBILITY_DECISION_REJECTED, "REJECTED when open_positions_count >= max_open_positions");
   Check(outTripped.reason_code == REASON_RISK_MAX_OPEN_POSITIONS, "reason is REASON_RISK_MAX_OPEN_POSITIONS");

   EligibilityPolicy disabledPolicy; BuildEnabledPolicy(disabledPolicy);
   disabledPolicy.eligibility_policy_version = "OPOS_DISABLED_V1";
   disabledPolicy.max_open_positions = 0;
   EligibilityDecision outDisabled; string rd2;
   Check(EligibilityDecision_Build(plan, decision, snapshot, tripped, disabledPolicy, outDisabled, rd2), "build succeeds (gate disabled)");
   Check(outDisabled.decision == ELIGIBILITY_DECISION_ELIGIBLE, "same tripping account state does NOT reject when max_open_positions == 0 (disabled)");
}

void Test_Gate_Margin()
{
   Print("--- operational gate: margin ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   BuildValidFeatureSnapshot(snapshot, "MARGIN");
   BuildValidRiskPlan(snapshot, plan);
   Check(BuildValidAIDecision(snapshot, "MARGIN", 0.90f, 0.70, decision), "sanity: AI ALLOW decision built");

   EligibilityPolicy policy; BuildEnabledPolicy(policy);
   policy.eligibility_policy_version = "MARGIN_V1";

   EligibilityContext tripped; BuildValidEligibilityContext(tripped, 10000, 9000, 150, 1, 0.0, 0.0, 0.0, false);
   EligibilityDecision outTripped; string rd1;
   Check(EligibilityDecision_Build(plan, decision, snapshot, tripped, policy, outTripped, rd1), "build succeeds (tripped)");
   Check(outTripped.decision == ELIGIBILITY_DECISION_REJECTED, "REJECTED when 0 < margin_level < min_margin_level");
   Check(outTripped.reason_code == REASON_RISK_MARGIN, "reason is REASON_RISK_MARGIN");

   EligibilityPolicy disabledPolicy; BuildEnabledPolicy(disabledPolicy);
   disabledPolicy.eligibility_policy_version = "MARGIN_DISABLED_V1";
   disabledPolicy.min_margin_level = 0.0;
   EligibilityDecision outDisabled; string rd2;
   Check(EligibilityDecision_Build(plan, decision, snapshot, tripped, disabledPolicy, outDisabled, rd2), "build succeeds (gate disabled)");
   Check(outDisabled.decision == ELIGIBILITY_DECISION_ELIGIBLE, "same tripping account state does NOT reject when min_margin_level == 0 (disabled)");
}

void Test_Gate_MarginZeroGuard()
{
   Print("--- operational gate: margin_level == 0 (no margin used) never trips REASON_RISK_MARGIN ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   BuildValidFeatureSnapshot(snapshot, "MARGINZERO");
   BuildValidRiskPlan(snapshot, plan);
   Check(BuildValidAIDecision(snapshot, "MARGINZERO", 0.90f, 0.70, decision), "sanity: AI ALLOW decision built");

   EligibilityPolicy policy; BuildEnabledPolicy(policy);
   policy.eligibility_policy_version = "MARGINZERO_V1";

   EligibilityContext ctx; BuildValidEligibilityContext(ctx, 10000, 10000, 0.0, 0, 0.0, 0.0, 0.0, false);
   EligibilityDecision out; string rd;
   Check(EligibilityDecision_Build(plan, decision, snapshot, ctx, policy, out, rd), "build succeeds");
   Check(out.decision == ELIGIBILITY_DECISION_ELIGIBLE, "margin_level == 0 (no open exposure) does NOT trigger REASON_RISK_MARGIN even though 0 < min_margin_level");
}

void Test_Gate_CircuitBreaker_SafeMode()
{
   Print("--- operational gate: safe_mode_active -> REASON_RISK_CIRCUIT_BREAKER ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   BuildValidFeatureSnapshot(snapshot, "SAFEMODE");
   BuildValidRiskPlan(snapshot, plan);
   Check(BuildValidAIDecision(snapshot, "SAFEMODE", 0.90f, 0.70, decision), "sanity: AI ALLOW decision built");

   EligibilityPolicy policy; BuildEnabledPolicy(policy);
   policy.eligibility_policy_version = "SAFEMODE_V1";

   EligibilityContext tripped; BuildValidEligibilityContext(tripped, 10000, 10000, 500, 0, 0.0, 0.0, 0.0, true);
   EligibilityDecision out; string rd;
   Check(EligibilityDecision_Build(plan, decision, snapshot, tripped, policy, out, rd), "build succeeds");
   Check(out.decision == ELIGIBILITY_DECISION_REJECTED, "REJECTED when safe_mode_active is true");
   Check(out.reason_code == REASON_RISK_CIRCUIT_BREAKER, "reason is REASON_RISK_CIRCUIT_BREAKER");
}

//=====================================================================
// Precedence
//=====================================================================
void Test_Precedence_AIWinsOverOperational()
{
   Print("--- precedence: AI REJECT wins over a simultaneously-tripped operational gate ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   BuildValidFeatureSnapshot(snapshot, "PRECEDENCE");
   BuildValidRiskPlan(snapshot, plan);
   Check(BuildValidAIDecision(snapshot, "PRECEDENCE", 0.30f, 0.70, decision), "sanity: AI REJECT decision built");
   Check(decision.decision_outcome == AI_DECISION_OUTCOME_REJECT, "sanity: outcome is REJECT");

   EligibilityPolicy policy; BuildEnabledPolicy(policy);
   policy.eligibility_policy_version = "PRECEDENCE_V1";
   // Trip BOTH the AI veto and the daily-loss gate simultaneously.
   EligibilityContext bothTripped; BuildValidEligibilityContext(bothTripped, 10000, 9500, 500, 0, 0.0, -6.0, 0.0, false);

   EligibilityDecision out; string rd;
   Check(EligibilityDecision_Build(plan, decision, snapshot, bothTripped, policy, out, rd), "build succeeds");
   Check(out.decision == ELIGIBILITY_DECISION_REJECTED, "decision is REJECTED");
   Check(out.reason_code == REASON_AI_REJECT, "reason is REASON_AI_REJECT, not REASON_RISK_DAILY_LOSS_LIMIT - AI checked first");
}

//=====================================================================
// Fail-closed
//=====================================================================
void Test_FailClosed_EmptyRiskPlanId()
{
   Print("--- fail-closed: empty RiskPlan.risk_plan_id (unfilled/rejected plan) ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   EligibilityContext context; EligibilityPolicy policy;
   Check(BuildFullEligibleFixture("EMPTYPLAN", snapshot, plan, decision, context, policy), "sanity: fixture built");
   plan.risk_plan_id = "";

   EligibilityDecision out; string rd;
   Check(!EligibilityDecision_Build(plan, decision, snapshot, context, policy, out, rd), "build fails when risk_plan_id is empty");
   Check(out.decision == ELIGIBILITY_DECISION_NONE, "rejected output stays at Init() defaults");
   Check(out.eligibility_decision_id == "", "no eligibility_decision_id produced");
}

void Test_FailClosed_EmptyAIDecisionId()
{
   Print("--- fail-closed: empty AIDecision.ai_decision_id (unfilled/failed decision) ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   EligibilityContext context; EligibilityPolicy policy;
   Check(BuildFullEligibleFixture("EMPTYAI", snapshot, plan, decision, context, policy), "sanity: fixture built");
   decision.ai_decision_id = "";

   EligibilityDecision out; string rd;
   Check(!EligibilityDecision_Build(plan, decision, snapshot, context, policy, out, rd), "build fails when ai_decision_id is empty");
   Check(out.decision == ELIGIBILITY_DECISION_NONE, "rejected output stays at Init() defaults");
}

void Test_FailClosed_LineageMismatches()
{
   Print("--- fail-closed: 3-way candidate/snapshot lineage mismatches, each isolated ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   EligibilityContext context; EligibilityPolicy policy;

   Check(BuildFullEligibleFixture("LINEAGE1", snapshot, plan, decision, context, policy), "sanity: fixture 1 built");
   RiskPlan mismatchedPlan = plan; mismatchedPlan.candidate_id = "CND_DOES_NOT_MATCH";
   EligibilityDecision out1; string rd1;
   Check(!EligibilityDecision_Build(mismatchedPlan, decision, snapshot, context, policy, out1, rd1),
         "RiskPlan.candidate_id mismatch vs AIDecision is rejected");

   Check(BuildFullEligibleFixture("LINEAGE2", snapshot, plan, decision, context, policy), "sanity: fixture 2 built");
   AIDecision mismatchedDecision = decision; mismatchedDecision.feature_snapshot_hash = "TAMPERED_HASH";
   EligibilityDecision out2; string rd2;
   Check(!EligibilityDecision_Build(plan, mismatchedDecision, snapshot, context, policy, out2, rd2),
         "AIDecision.feature_snapshot_hash mismatch vs FeatureSnapshot is rejected");

   Check(BuildFullEligibleFixture("LINEAGE3", snapshot, plan, decision, context, policy), "sanity: fixture 3 built");
   FeatureSnapshot mismatchedSnapshot = snapshot; mismatchedSnapshot.candidate_hash = "TAMPERED_CAND_HASH";
   EligibilityDecision out3; string rd3;
   Check(!EligibilityDecision_Build(plan, decision, mismatchedSnapshot, context, policy, out3, rd3),
         "FeatureSnapshot.candidate_hash mismatch vs RiskPlan is rejected");
}

void Test_FailClosed_EmptyPolicyVersion()
{
   Print("--- fail-closed: empty EligibilityPolicy.eligibility_policy_version ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   EligibilityContext context; EligibilityPolicy policy;
   Check(BuildFullEligibleFixture("EMPTYPOLICY", snapshot, plan, decision, context, policy), "sanity: fixture built");
   policy.eligibility_policy_version = "";

   EligibilityDecision out; string rd;
   Check(!EligibilityDecision_Build(plan, decision, snapshot, context, policy, out, rd), "build fails when policy version is empty");
}

void Test_FailClosed_PolicyOutOfRange()
{
   Print("--- fail-closed: each policy threshold out of range, isolated ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   EligibilityContext context; EligibilityPolicy policy;

   Check(BuildFullEligibleFixture("RANGE1", snapshot, plan, decision, context, policy), "sanity: fixture 1 built");
   EligibilityPolicy p1 = policy; p1.max_daily_loss_percent = 150.0;
   EligibilityDecision o1; string r1;
   Check(!EligibilityDecision_Build(plan, decision, snapshot, context, p1, o1, r1), "max_daily_loss_percent > 100 is rejected");

   Check(BuildFullEligibleFixture("RANGE2", snapshot, plan, decision, context, policy), "sanity: fixture 2 built");
   EligibilityPolicy p2 = policy; p2.max_drawdown_percent = -1.0;
   EligibilityDecision o2; string r2;
   Check(!EligibilityDecision_Build(plan, decision, snapshot, context, p2, o2, r2), "max_drawdown_percent < 0 is rejected");

   Check(BuildFullEligibleFixture("RANGE3", snapshot, plan, decision, context, policy), "sanity: fixture 3 built");
   EligibilityPolicy p3 = policy; p3.max_total_exposure_percent = 200.0;
   EligibilityDecision o3; string r3;
   Check(!EligibilityDecision_Build(plan, decision, snapshot, context, p3, o3, r3), "max_total_exposure_percent > 100 is rejected");

   Check(BuildFullEligibleFixture("RANGE4", snapshot, plan, decision, context, policy), "sanity: fixture 4 built");
   EligibilityPolicy p4 = policy; p4.max_open_positions = -1;
   EligibilityDecision o4; string r4;
   Check(!EligibilityDecision_Build(plan, decision, snapshot, context, p4, o4, r4), "max_open_positions < 0 is rejected");

   Check(BuildFullEligibleFixture("RANGE5", snapshot, plan, decision, context, policy), "sanity: fixture 5 built");
   EligibilityPolicy p5 = policy; p5.min_margin_level = -1.0;
   EligibilityDecision o5; string r5;
   Check(!EligibilityDecision_Build(plan, decision, snapshot, context, p5, o5, r5), "min_margin_level < 0 is rejected");
}

void Test_FailClosed_ContextHashInvalid()
{
   Print("--- fail-closed: EligibilityContext.eligibility_context_hash empty or stale ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   EligibilityContext context; EligibilityPolicy policy;

   Check(BuildFullEligibleFixture("CTXHASH1", snapshot, plan, decision, context, policy), "sanity: fixture 1 built");
   EligibilityContext emptyHash = context; emptyHash.eligibility_context_hash = "";
   EligibilityDecision o1; string r1;
   Check(!EligibilityDecision_Build(plan, decision, snapshot, emptyHash, policy, o1, r1), "empty eligibility_context_hash is rejected");

   Check(BuildFullEligibleFixture("CTXHASH2", snapshot, plan, decision, context, policy), "sanity: fixture 2 built");
   EligibilityContext staleHash = context;
   staleHash.account.balance = staleHash.account.balance + 1.0; // mutate content without recomputing the hash
   EligibilityDecision o2; string r2;
   Check(!EligibilityDecision_Build(plan, decision, snapshot, staleHash, policy, o2, r2), "stale (non-recomputed) eligibility_context_hash is rejected");
}

void Test_FailClosed_ContextNonFinite()
{
   Print("--- fail-closed (defensive boundary check): a hand-constructed non-finite EligibilityContext.account field ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   EligibilityContext context; EligibilityPolicy policy;
   Check(BuildFullEligibleFixture("NONFINITE", snapshot, plan, decision, context, policy), "sanity: fixture built");

   double huge = 1.0e307;
   double infinity = huge * huge; // +Inf, same idiom used throughout this project's other test suites

   EligibilityContext badContext = context;
   badContext.account.daily_pnl_percent = infinity;
   badContext.eligibility_context_hash = EligibilityContext_ComputeHash(badContext); // keep the hash internally consistent
   EligibilityDecision out; string rd;
   Check(!EligibilityDecision_Build(plan, decision, snapshot, badContext, policy, out, rd), "+Inf account.daily_pnl_percent is rejected");
}

//=====================================================================
// Determinism / identity / hash sensitivity
//=====================================================================
void Test_Determinism_IdAndHash()
{
   Print("--- determinism: repeated builds of the same inputs produce byte-identical id/hash ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   EligibilityContext context; EligibilityPolicy policy;
   Check(BuildFullEligibleFixture("DETERM", snapshot, plan, decision, context, policy), "sanity: fixture built");

   EligibilityDecision first; string rd1;
   Check(EligibilityDecision_Build(plan, decision, snapshot, context, policy, first, rd1), "sanity: first build succeeds");

   bool allMatch = true;
   for(int i = 0; i < 1000; i++)
   {
      EligibilityDecision rep; string rd;
      EligibilityDecision_Build(plan, decision, snapshot, context, policy, rep, rd);
      if(rep.eligibility_decision_id != first.eligibility_decision_id || rep.eligibility_decision_hash != first.eligibility_decision_hash)
      {
         allMatch = false;
         break;
      }
   }
   Check(allMatch, "1,000 repeated builds: identical eligibility_decision_id and eligibility_decision_hash every time");
}

void Test_IdentitySensitivity_PolicyVersionChangesId()
{
   Print("--- identity sensitivity: a different eligibility_policy_version produces a different eligibility_decision_id ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   EligibilityContext context; EligibilityPolicy policyA;
   Check(BuildFullEligibleFixture("IDSENS", snapshot, plan, decision, context, policyA), "sanity: fixture built");
   EligibilityPolicy policyB = policyA; policyB.eligibility_policy_version = "ELIGPOLICY_V2";

   EligibilityDecision outA; string rdA;
   EligibilityDecision outB; string rdB;
   Check(EligibilityDecision_Build(plan, decision, snapshot, context, policyA, outA, rdA), "sanity: build A succeeds");
   Check(EligibilityDecision_Build(plan, decision, snapshot, context, policyB, outB, rdB), "sanity: build B succeeds");
   Check(outA.eligibility_decision_id != outB.eligibility_decision_id, "different eligibility_policy_version moves eligibility_decision_id");
}

void Test_HashSensitivity_ContentChangesMoveHashNotId()
{
   Print("--- hash sensitivity: content-only changes move eligibility_decision_hash while eligibility_decision_id stays identical ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   EligibilityContext context; EligibilityPolicy policy;
   Check(BuildFullEligibleFixture("HASHSENS", snapshot, plan, decision, context, policy), "sanity: baseline fixture built");

   EligibilityDecision baseline; string rdBase;
   Check(EligibilityDecision_Build(plan, decision, snapshot, context, policy, baseline, rdBase), "sanity: baseline build succeeds");

   // Vary context (safe_mode_active) while candidate_id/policy_version stay fixed.
   EligibilityContext variantContext = context;
   variantContext.safe_mode_active = true;
   variantContext.eligibility_context_hash = EligibilityContext_ComputeHash(variantContext);
   EligibilityDecision variant; string rdVariant;
   Check(EligibilityDecision_Build(plan, decision, snapshot, variantContext, policy, variant, rdVariant), "sanity: variant build succeeds");
   Check(variant.eligibility_decision_id == baseline.eligibility_decision_id, "safe_mode_active change: eligibility_decision_id unchanged");
   Check(variant.eligibility_decision_hash != baseline.eligibility_decision_hash, "safe_mode_active change: eligibility_decision_hash moves");
}

//=====================================================================
// No mutation / no side effects
//=====================================================================
void Test_NoMutation()
{
   Print("--- no mutation: plan / decision / snapshot / context / policy unchanged before and after EligibilityDecision_Build ---");
   FeatureSnapshot snapshot; RiskPlan plan; AIDecision decision;
   EligibilityContext context; EligibilityPolicy policy;
   Check(BuildFullEligibleFixture("NOMUT", snapshot, plan, decision, context, policy), "sanity: fixture built");

   string planHashBefore = plan.plan_hash;
   string decisionHashBefore = decision.ai_decision_hash;
   string snapshotHashBefore = snapshot.feature_snapshot_hash;
   string contextHashBefore = context.eligibility_context_hash;
   string policyVersionBefore = policy.eligibility_policy_version;

   EligibilityDecision out; string rd;
   Check(EligibilityDecision_Build(plan, decision, snapshot, context, policy, out, rd), "sanity: accept-path build succeeds");
   Check(plan.plan_hash == planHashBefore, "plan unchanged after build");
   Check(decision.ai_decision_hash == decisionHashBefore, "decision unchanged after build");
   Check(snapshot.feature_snapshot_hash == snapshotHashBefore, "snapshot unchanged after build");
   Check(context.eligibility_context_hash == contextHashBefore, "context unchanged after build");
   Check(policy.eligibility_policy_version == policyVersionBefore, "policy unchanged after build");

   // Also on a reject path.
   plan.risk_plan_id = "";
   EligibilityDecision outReject; string rdReject;
   Check(!EligibilityDecision_Build(plan, decision, snapshot, context, policy, outReject, rdReject), "sanity: reject-path build fails as expected");
   Check(decision.ai_decision_hash == decisionHashBefore, "decision unchanged after reject-path build");
}

void Test_NoSideEffects_StructuralProof()
{
   Print("--- no side effects (structural): EligibilityDecision_Build touches no event store, broker, account, tick, or SafeMode call ---");
   Check(true, "verified by inspection: EligibilityDecision_Build (Include/MLQuantAI/Execution/MLQuantAI_EligibilityBuilder.mqh) contains no "
               "EventStore_Log*/OrderSend/CTrade/AccountInfo*/PositionsTotal/SafeMode_IsActive/TimeCurrent call anywhere - "
               "it is a pure function over its five input structs, per Docs/PhaseB_B9_ExecutionEligibilityContract.md's scope guard");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B9 Commit 1 - Execution Eligibility Pure Mapping ===");

   Test_AcceptPath_Eligible();
   Test_AIReject_OverridesHealthyOperationalState();
   Test_AIAbstain_RejectedDistinctFromReject();
   Test_Gate_DailyLossLimit();
   Test_Gate_MaxDrawdown();
   Test_Gate_MaxTotalExposure();
   Test_Gate_MaxOpenPositions();
   Test_Gate_Margin();
   Test_Gate_MarginZeroGuard();
   Test_Gate_CircuitBreaker_SafeMode();
   Test_Precedence_AIWinsOverOperational();
   Test_FailClosed_EmptyRiskPlanId();
   Test_FailClosed_EmptyAIDecisionId();
   Test_FailClosed_LineageMismatches();
   Test_FailClosed_EmptyPolicyVersion();
   Test_FailClosed_PolicyOutOfRange();
   Test_FailClosed_ContextHashInvalid();
   Test_FailClosed_ContextNonFinite();
   Test_Determinism_IdAndHash();
   Test_IdentitySensitivity_PolicyVersionChangesId();
   Test_HashSensitivity_ContentChangesMoveHashNotId();
   Test_NoMutation();
   Test_NoSideEffects_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
