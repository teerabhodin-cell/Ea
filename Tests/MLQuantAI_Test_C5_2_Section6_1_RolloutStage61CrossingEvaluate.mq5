//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Section6_1_RolloutStage61CrossingEvaluate.mq5  |
//| §6.1 Evidence-Gate Design Contract Rev.4 (QA-frozen DESIGN FREEZE,  |
//| Docs/PhaseC_C5_2_Section6_1_PipelineOutsideTesterDesignContract.md): |
//| direct unit-level coverage of isDeclaredEnvironmentCrossingPair()     |
//| and RolloutStage61Crossing_Evaluate() through the real, authoritative  |
//| path - a genuine EventStore file, real fresh CandidateProjection/        |
//| ExecutionAuditProjection rebuilds, real CRT/execution-request pipeline    |
//| fixtures (identical convention to C1.3/C2.2/C2.3/§6.2's own test files).   |
//| NO OrderSend/CTrade anywhere in this file - §6.1 has no broker-submission   |
//| concept at all (pre-DEMO_DRY_RUN), so no broker fixture is needed. Safe       |
//| to run on a real account.                                                       |
//|                                                                                     |
//| Deliberately NOT separately exercised here (same precedent as §6.2's own            |
//| P1 duplicate_conflicting): ROLLOUT_STAGE_61_CROSSING_AUDIT_CHAIN_BROKEN's              |
//| P1-lineage branches and TARGET_ENVIRONMENT_INVALID are structurally                      |
//| unreachable through this authoritative path (the fresh rebuilds/cross-                     |
//| validity table make them defense-in-depth-only) - flagged to QA for the                       |
//| same "confirmed unreachable, accepted" ruling §6.2's P1 duplicate_conflicting                    |
//| received, rather than asserted here.                                                                |
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
#include <MLQuantAI/Execution/MLQuantAI_RolloutStage61CrossingEvaluate.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_C6_1_RolloutStage61CrossingEvaluate.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as §6.2's own test file
// (MLQuantAI_Test_C5_2_Section6_2_RolloutGateReadinessEvaluate.mq5),
// duplicated here per this codebase's established per-test-file
// convention (BuildFullChain's own header comment already documents
// this is "identical to C1.3/C2.3's own BuildFullChain").
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
   ctx.context_event_id = "CTX_c61_" + suffix;
   ctx.context_hash      = "test_context_hash_c61_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C6_1_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

// Tester-side dry-run policy - environment_mode == EXECUTION_ENV_TESTER,
// matching §6.1's own architectural fact (§0/§3's P1 provenance
// clarification): TEST_FIXTURE is Tester-only, so a genuine dry-run
// completion recorded while the durable log's own current window is
// anchored to TEST_FIXTURE is, by construction, a real Tester-side
// completion.
void BuildAcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C6_1_V1";
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

// Builds AND emits every layer of the real chain through an ACCEPTED
// ExecutionRequest dry-run - identical to §6.2's own BuildFullChain.
// Produces exactly one CANDIDATE_CREATED + one EXECUTION_REQUEST_CREATED +
// one EXECUTION_DRY_RUN_COMPLETED, with genuine lineage all the way back
// to CANDIDATE_CREATED - exactly what §6.1's own P1 needs.
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
   aiPolicy.decision_policy_version = "AIPOLICY_C6_1_V1";
   aiPolicy.threshold_version       = "THRESH_C6_1_V1";
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

// §2's window anchor line, written directly via the low-level
// EventStore_LogSystem() API - matches the same "fabricate the exact
// durable shape the function-under-test reads" convention §6.2's own
// EmitDemoDryRunWindowBoundary() already uses. `envMode` lets one test
// group deliberately corrupt the anchor's own recorded environment_mode
// (§1.3 item 4).
void EmitTestFixtureWindowBoundary(string envMode = "TESTER")
{
   string extraJson = "\"from_stage\":\"NONE\",\"to_stage\":\"TEST_FIXTURE\",\"environment_mode\":\"" + envMode + "\"";
   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_ROLLOUT_STAGE_CHANGED), "test: entering TEST_FIXTURE", extraJson);
}

RolloutStage61CrossingResult EvaluateFresh(ENUM_EXECUTION_ROLLOUT_STAGE fromStage, ENUM_EXECUTION_ROLLOUT_STAGE toStage, ENUM_EXECUTION_ENVIRONMENT_MODE envMode)
{
   string lines[];
   EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
   return RolloutStage61Crossing_Evaluate(fromStage, toStage, lines, envMode);
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI_Test_C5_2_Section6_1_RolloutStage61CrossingEvaluate.mq5 ===");

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   SafeMode_Clear();
   g_RolloutIntegrityFatalHalt = false;
   ResetAllProjections();
   Check(EventStore_Open(TEST_EVENT_STORE_FILE), "setup: event store opens");

   //=====================================================================
   Print("--- §1.2 isDeclaredEnvironmentCrossingPair(): closed, per-pair whitelist ---");
   {
      Check(isDeclaredEnvironmentCrossingPair(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN) == true,
            "TEST_FIXTURE -> DEMO_DRY_RUN == true (the one declared pair)");
      Check(isDeclaredEnvironmentCrossingPair(ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION, ROLLOUT_STAGE_LIVE_SHADOW) == false,
            "DEMO_BOUNDED_AUTOMATION -> LIVE_SHADOW == false (§6.4 does not exist)");
      Check(isDeclaredEnvironmentCrossingPair(ROLLOUT_STAGE_NONE, ROLLOUT_STAGE_TEST_FIXTURE) == false,
            "NONE -> TEST_FIXTURE == false (§6.0's own pair, not a crossing pair)");
      Check(isDeclaredEnvironmentCrossingPair(ROLLOUT_STAGE_DEMO_DRY_RUN, ROLLOUT_STAGE_DEMO_REAL_SUBMIT) == false,
            "DEMO_DRY_RUN -> DEMO_REAL_SUBMIT == false (§6.2's own pair, not a crossing pair)");
      Check(isDeclaredEnvironmentCrossingPair(ROLLOUT_STAGE_DEMO_DRY_RUN, ROLLOUT_STAGE_TEST_FIXTURE) == false,
            "reversed direction (DEMO_DRY_RUN -> TEST_FIXTURE) == false - identity check is direction-sensitive");
      Check(isDeclaredEnvironmentCrossingPair(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_TEST_FIXTURE) == false,
            "same-stage (TEST_FIXTURE -> TEST_FIXTURE) == false - sanity");
   }

   //=====================================================================
   Print("--- §1.3 items 1/2: wrong pair, self-enforced even if called directly -> WRONG_PAIR ---");
   {
      string emptyLines[];
      RolloutStage61CrossingResult res = RolloutStage61Crossing_Evaluate(ROLLOUT_STAGE_DEMO_DRY_RUN, ROLLOUT_STAGE_DEMO_REAL_SUBMIT, emptyLines, EXECUTION_ENV_DEMO);
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_STAGE_61_CROSSING_WRONG_PAIR, "reason == WRONG_PAIR (§6.2's own pair passed in directly)");

      RolloutStage61CrossingResult res2 = RolloutStage61Crossing_Evaluate(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_NONE, emptyLines, EXECUTION_ENV_DEMO);
      Check(!res2.allow, "allow == false");
      Check(res2.reason == ROLLOUT_STAGE_61_CROSSING_WRONG_PAIR, "reason == WRONG_PAIR (reversed direction passed in directly)");
   }

   //=====================================================================
   Print("--- §1.3 item 3: correct pair, but environment_mode != DEMO -> ENVIRONMENT_NOT_DEMO (checked BEFORE the window lookup) ---");
   {
      string emptyLines[];
      RolloutStage61CrossingResult res = RolloutStage61Crossing_Evaluate(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, emptyLines, EXECUTION_ENV_LIVE);
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_STAGE_61_CROSSING_ENVIRONMENT_NOT_DEMO, "reason == ENVIRONMENT_NOT_DEMO (LIVE)");

      RolloutStage61CrossingResult res2 = RolloutStage61Crossing_Evaluate(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, emptyLines, EXECUTION_ENV_TESTER);
      Check(!res2.allow, "allow == false");
      Check(res2.reason == ROLLOUT_STAGE_61_CROSSING_ENVIRONMENT_NOT_DEMO, "reason == ENVIRONMENT_NOT_DEMO (TESTER)");
   }

   //=====================================================================
   Print("--- §2: correct pair, DEMO environment, but no TEST_FIXTURE anchor line exists yet -> WINDOW_NOT_FOUND ---");
   {
      RolloutStage61CrossingResult res = EvaluateFresh(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO);
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_STAGE_61_CROSSING_WINDOW_NOT_FOUND, "reason == WINDOW_NOT_FOUND");
   }

   //=====================================================================
   Print("--- §1.3 item 4: TEST_FIXTURE anchor exists but its OWN environment_mode field is 'DEMO', not 'TESTER' -> SOURCE_STAGE_NOT_DURABLY_TESTER ---");
   EmitTestFixtureWindowBoundary("DEMO"); // corrupted/hand-edited anchor - claims TEST_FIXTURE without ever being earned under TESTER
   {
      RolloutStage61CrossingResult res = EvaluateFresh(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO);
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_STAGE_61_CROSSING_SOURCE_STAGE_NOT_DURABLY_TESTER, "reason == SOURCE_STAGE_NOT_DURABLY_TESTER");
   }

   //=====================================================================
   Print("--- fresh, genuine window: TEST_FIXTURE earned under TESTER -> item 4 passes, but 0 completions -> INSUFFICIENT_TESTER_VALIDATED_COMPLETIONS ---");
   EmitTestFixtureWindowBoundary("TESTER");
   {
      RolloutStage61CrossingResult res = EvaluateFresh(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO);
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_STAGE_61_CROSSING_INSUFFICIENT_TESTER_COMPLETIONS, "reason == INSUFFICIENT_TESTER_VALIDATED_COMPLETIONS (0 completions)");
   }

   //=====================================================================
   Print("--- same window, 1 then 2 distinct lineage-complete completions -> still INSUFFICIENT_TESTER_VALIDATED_COMPLETIONS ---");
   {
      TradeCandidate c1;
      Check(BuildFullChain(c1, "p1_a", 0), "fixture: candidate 1 dry-run ACCEPTED");
      RolloutStage61CrossingResult res1 = EvaluateFresh(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO);
      Check(!res1.allow, "allow == false (1 completion)");
      Check(res1.reason == ROLLOUT_STAGE_61_CROSSING_INSUFFICIENT_TESTER_COMPLETIONS, "reason == INSUFFICIENT_TESTER_VALIDATED_COMPLETIONS (1 completion)");

      TradeCandidate c2;
      Check(BuildFullChain(c2, "p1_b", 1), "fixture: candidate 2 dry-run ACCEPTED");
      RolloutStage61CrossingResult res2 = EvaluateFresh(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO);
      Check(!res2.allow, "allow == false (2 completions)");
      Check(res2.reason == ROLLOUT_STAGE_61_CROSSING_INSUFFICIENT_TESTER_COMPLETIONS, "reason == INSUFFICIENT_TESTER_VALIDATED_COMPLETIONS (2 completions)");
   }

   //=====================================================================
   Print("--- same window, 3rd distinct lineage-complete completion -> ALL preconditions satisfied -> ALLOW ---");
   {
      TradeCandidate c3;
      Check(BuildFullChain(c3, "p1_c", 2), "fixture: candidate 3 dry-run ACCEPTED");
      RolloutStage61CrossingResult res = EvaluateFresh(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO);
      Check(res.allow, "allow == true (3 distinct completions)");
      Check(res.reason == ROLLOUT_STAGE_61_CROSSING_ALLOW, "reason == ALLOW");
   }

   //=====================================================================
   Print("--- §3/P2: same clean 3-completion window, but Safe Mode engaged in-window -> SAFE_MODE_ENGAGED_IN_WINDOW (P1 already passed) ---");
   {
      SafeMode_Trip("test: §6.1 P2 safe mode window check");
      RolloutStage61CrossingResult res = EvaluateFresh(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO);
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_STAGE_61_CROSSING_SAFE_MODE_ENGAGED_IN_WINDOW, "reason == SAFE_MODE_ENGAGED_IN_WINDOW");
      SafeMode_Clear(); // cleanup - do not let this leak into later groups
   }

   //=====================================================================
   // §6 needs a FRESH window here: P2's "ever engaged" semantics (§6.2's
   // own P4c precedent, reused as-is) mean the PREVIOUS group's Safe Mode
   // episode is still "in-window" forever w.r.t. the OLD anchor, even
   // after SafeMode_Clear() above - re-anchoring to a NEW TEST_FIXTURE
   // line moves window_start past that old episode entirely, exactly the
   // same window-isolation technique §6.2's own test file uses via
   // EnterFreshDemoWindowWithRestart().
   //=====================================================================
   Print("--- §6: g_RolloutIntegrityFatalHalt independently rejects, P1/P2 both clean (fresh window) ---");
   EmitTestFixtureWindowBoundary("TESTER");
   {
      TradeCandidate f1, f2, f3;
      Check(BuildFullChain(f1, "halt_a", 10), "fixture: candidate 1 dry-run ACCEPTED (fresh window)");
      Check(BuildFullChain(f2, "halt_b", 11), "fixture: candidate 2 dry-run ACCEPTED (fresh window)");
      Check(BuildFullChain(f3, "halt_c", 12), "fixture: candidate 3 dry-run ACCEPTED (fresh window)");

      g_RolloutIntegrityFatalHalt = true;
      RolloutStage61CrossingResult res = EvaluateFresh(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO);
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_STAGE_61_CROSSING_INTEGRITY_FATAL_HALT, "reason == INTEGRITY_FATAL_HALT");
      g_RolloutIntegrityFatalHalt = false; // cleanup - do not let this leak into later groups
   }

   //=====================================================================
   Print("--- §5: a durable write between the snapshot and the call -> EVIDENCE_SNAPSHOT_CHANGED ---");
   {
      string staleLines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, staleLines);

      EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SYSTEM_STARTED), "unrelated write to grow the file after the snapshot was taken");

      RolloutStage61CrossingResult res = RolloutStage61Crossing_Evaluate(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, staleLines, EXECUTION_ENV_DEMO);
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_STAGE_61_CROSSING_EVIDENCE_SNAPSHOT_CHANGED, "reason == EVIDENCE_SNAPSHOT_CHANGED");
   }

   //=====================================================================
   Print("--- final sanity: the SAME store, evaluated fresh again (no more stale snapshot), still ALLOWs ---");
   {
      RolloutStage61CrossingResult res = EvaluateFresh(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO);
      Check(res.allow, "allow == true");
      Check(res.reason == ROLLOUT_STAGE_61_CROSSING_ALLOW, "reason == ALLOW");
   }

   EventStore_Close();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
