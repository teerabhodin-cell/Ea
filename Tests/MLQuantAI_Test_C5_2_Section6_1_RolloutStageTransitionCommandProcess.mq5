//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Section6_1_RolloutStageTransitionCommandProcess.mq5|
//| §6.1 Evidence-Gate Design Contract Rev.4 (QA-frozen DESIGN FREEZE,      |
//| Docs/PhaseC_C5_2_Section6_1_PipelineOutsideTesterDesignContract.md §8):  |
//| the 3 required regression-test directions, at the full                   |
//| RolloutStageTransitionCommand_Process() integration level (Step 2's         |
//| §1.2 branch + Step 3's §1.5 tie):                                            |
//|   TEST 1 - the declared crossing, evidence present -> ACCEPT                   |
//|   TEST 2 - an UNDECLARED crossing pair -> ORIGINAL REJECT preserved               |
//|            (Commit-2's own frozen regression test #6, reproduced here to          |
//|            prove it is byte-for-byte unaffected by the §6.1 amendment)              |
//|   TEST 3 - the declared pair, but the WRONG environment -> REJECT                     |
//| Also proves QA's Diff Review Blocker-B ruling: reason_code is IDENTICAL for              |
//| both the original blanket-check rejection and the crossing-predicate                        |
//| rejection ("current_state_environment_invalid") - only crossing_gate_reason/                   |
//| crossing_gate_diagnostic differ, and only for the declared pair.                                   |
//| NO OrderSend/CTrade anywhere in this file. Safe to run on a real account.                            |
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
#include <MLQuantAI/Execution/MLQuantAI_RolloutStageTransitionCommandProcess.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_C6_1_RolloutStageTransitionCommandProcess.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as §6.2/§6.1's own test files, duplicated
// here per this codebase's established per-test-file convention.
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
   ctx.context_event_id = "CTX_c61cmd_" + suffix;
   ctx.context_hash      = "test_context_hash_c61cmd_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C6_1CMD_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

void BuildAcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C6_1CMD_V1";
   policy.environment_mode = EXECUTION_ENV_TESTER;
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
}

bool BuildFullChain(TradeCandidate &c, string suffix, int dayOffset)
{
   FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult dryRunResult;

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
                               0.90f, inference);
   AIDecisionPolicy aiPolicy;
   AIDecisionPolicy_Init(aiPolicy);
   aiPolicy.decision_policy_version = "AIPOLICY_C6_1CMD_V1";
   aiPolicy.threshold_version       = "THRESH_C6_1CMD_V1";
   aiPolicy.allow_threshold         = 0.70;
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

   if(!ExecutionRequest_EmitAndEvaluate(req, execPolicy, dryRunResult)) return false;
   return dryRunResult.decision == SAFETY_GATE_ACCEPTED;
}

void EmitRolloutStageChanged(string fromStage, string toStage, string envMode)
{
   string extraJson = "\"from_stage\":\"" + fromStage + "\",\"to_stage\":\"" + toStage + "\",\"environment_mode\":\"" + envMode + "\"";
   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_ROLLOUT_STAGE_CHANGED), "test: rollout stage changed", extraJson);
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI_Test_C5_2_Section6_1_RolloutStageTransitionCommandProcess.mq5 ===");

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   SafeMode_Clear();
   g_RolloutIntegrityFatalHalt = false;
   ResetAllProjections();
   Check(EventStore_Open(TEST_EVENT_STORE_FILE), "setup: event store opens");

   //=====================================================================
   // TEST 2 (§8): an UNDECLARED crossing pair -> ORIGINAL REJECT preserved.
   // Byte-for-byte Commit-2's own frozen regression test #6: current stage
   // DEMO_BOUNDED_AUTOMATION recorded under DEMO, queried under real LIVE,
   // target LIVE_SHADOW itself perfectly valid under LIVE. This pair is
   // NOT in §1.2's whitelist, so Step 2 must still run the ORIGINAL
   // blanket check and reject BEFORE the evaluator is ever reached.
   //=====================================================================
   Print("--- TEST 2: undeclared pair (DEMO_BOUNDED_AUTOMATION -> LIVE_SHADOW) under LIVE -> CURRENT_STATE_INVALID, byte-for-byte test #6 ---");
   {
      string lines[1];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"DEMO_REAL_SUBMIT\",\"to_stage\":\"DEMO_BOUNDED_AUTOMATION\",\"environment_mode\":\"DEMO\"}";

      RolloutStageTransitionCommandResult result;
      RolloutStageTransitionCommand_Process(ROLLOUT_STAGE_LIVE_SHADOW, "qa_operator", "evidence_ref", lines, EXECUTION_ENV_LIVE, result);
      Check(result.status == ROLLOUT_STAGE_TRANSITION_CMD_CURRENT_STATE_INVALID, "status == CURRENT_STATE_INVALID");
      Check(result.reason_code == "current_state_environment_invalid", "reason_code == current_state_environment_invalid (unchanged string)");
      Check(result.crossing_gate_reason == ROLLOUT_STAGE_61_CROSSING_NONE, "crossing_gate_reason stays NONE - this pair never reaches the crossing predicate");
      Check(result.crossing_gate_diagnostic == "", "crossing_gate_diagnostic stays \"\"");
      Check(result.current_stage == ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION, "current_stage correctly reports DEMO_BOUNDED_AUTOMATION");
      Check(result.evaluation == ROLLOUT_TRANSITION_NONE, "evaluation is NEVER populated - RolloutStageTransition_Evaluate is never reached");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == 0, "NO new durable line appended - the laundering scenario is still closed");
   }

   //=====================================================================
   // TEST 3 (§8): the declared pair, but the WRONG environment -> REJECT.
   // Proves the exception is scoped to exactly EXECUTION_ENV_DEMO, never
   // "this pair may cross under anything."
   //=====================================================================
   Print("--- TEST 3: declared pair (TEST_FIXTURE -> DEMO_DRY_RUN), but environment_mode == LIVE (not DEMO) -> CURRENT_STATE_INVALID via crossing predicate ---");
   {
      string lines[1];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"NONE\",\"to_stage\":\"TEST_FIXTURE\",\"environment_mode\":\"TESTER\"}";

      RolloutStageTransitionCommandResult result;
      RolloutStageTransitionCommand_Process(ROLLOUT_STAGE_DEMO_DRY_RUN, "qa_operator", "evidence_ref", lines, EXECUTION_ENV_LIVE, result);
      Check(result.status == ROLLOUT_STAGE_TRANSITION_CMD_CURRENT_STATE_INVALID, "status == CURRENT_STATE_INVALID (same status as the blanket check)");
      Check(result.reason_code == "current_state_environment_invalid", "reason_code == current_state_environment_invalid (SAME string as TEST 2 - Blocker B)");
      Check(result.crossing_gate_reason == ROLLOUT_STAGE_61_CROSSING_ENVIRONMENT_NOT_DEMO, "crossing_gate_reason == ENVIRONMENT_NOT_DEMO - THIS is where the detail lives");
      Check(result.crossing_gate_diagnostic != "", "crossing_gate_diagnostic is populated with the crossing predicate's own detail");
      Check(result.evaluation == ROLLOUT_TRANSITION_NONE, "evaluation is NEVER populated");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == 0, "NO new durable line appended");
   }

   //=====================================================================
   // TEST 1 (§8): the declared crossing, evidence present -> ACCEPT.
   // Real TEST_FIXTURE anchor durably earned under TESTER, 3 distinct
   // lineage-complete Tester-validated dry-run completions in-window,
   // fresh environment_mode == DEMO -> Step 2's crossing predicate ALLOWs,
   // Step 3's IsForwardPairImplemented(TEST_FIXTURE, DEMO_DRY_RUN) (§1.5)
   // agrees -> TRANSITIONED, ALLOWED_FORWARD, one new durable line.
   //=====================================================================
   Print("--- TEST 1: declared crossing (TEST_FIXTURE -> DEMO_DRY_RUN), fresh DEMO, 3 Tester-validated completions -> TRANSITIONED / ALLOWED_FORWARD ---");
   {
      EmitRolloutStageChanged("NONE", "TEST_FIXTURE", "TESTER");

      TradeCandidate c1, c2, c3;
      Check(BuildFullChain(c1, "t1_a", 10), "fixture: candidate 1 dry-run ACCEPTED");
      Check(BuildFullChain(c2, "t1_b", 11), "fixture: candidate 2 dry-run ACCEPTED");
      Check(BuildFullChain(c3, "t1_c", 12), "fixture: candidate 3 dry-run ACCEPTED");

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
      int countBefore = ArraySize(lines);

      RolloutStageTransitionCommandResult result;
      RolloutStageTransitionCommand_Process(ROLLOUT_STAGE_DEMO_DRY_RUN, "qa_operator", "evidence_ref", lines, EXECUTION_ENV_DEMO, result);
      Check(result.status == ROLLOUT_STAGE_TRANSITION_CMD_TRANSITIONED, "status == TRANSITIONED");
      Check(result.evaluation == ROLLOUT_TRANSITION_ALLOWED_FORWARD, "evaluation == ALLOWED_FORWARD (§1.5's tie between Step 2 and Step 3)");
      Check(result.current_stage == ROLLOUT_STAGE_TEST_FIXTURE, "current_stage correctly reports TEST_FIXTURE");
      Check(result.crossing_gate_reason == ROLLOUT_STAGE_61_CROSSING_NONE, "crossing_gate_reason stays NONE on the ALLOW path - it is a rejection-detail field only");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == countBefore + 1, "exactly one new durable EXECUTION_ROLLOUT_STAGE_CHANGED line appended");

      RolloutStageProjection_ReplayCurrent(linesAfter, result.current_stage);
      Check(result.current_stage == ROLLOUT_STAGE_DEMO_DRY_RUN, "the durable log now replays current_stage == DEMO_DRY_RUN");
   }

   //=====================================================================
   // Sanity (unaffected by §6.1): §6.2 pair (criteria not frozen w.r.t.
   // Step 3, but still gated by its own evidence gate first) remains
   // exactly as before - TEST 1 above did not accidentally widen any
   // OTHER pair's behavior.
   //=====================================================================
   Print("--- sanity: DEMO_BOUNDED_AUTOMATION -> LIVE_SHADOW is STILL undeclared/false, even after TEST 1's ALLOW above ---");
   {
      Check(isDeclaredEnvironmentCrossingPair(ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION, ROLLOUT_STAGE_LIVE_SHADOW) == false,
            "isDeclaredEnvironmentCrossingPair(DEMO_BOUNDED_AUTOMATION, LIVE_SHADOW) still false");
      Check(RolloutStageTransition_IsForwardPairImplemented(ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION, ROLLOUT_STAGE_LIVE_SHADOW) == false,
            "IsForwardPairImplemented(DEMO_BOUNDED_AUTOMATION, LIVE_SHADOW) still false - §6.4 does not exist");
   }

   EventStore_Close();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
