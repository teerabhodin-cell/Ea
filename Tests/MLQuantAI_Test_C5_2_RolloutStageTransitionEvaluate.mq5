//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_RolloutStageTransitionEvaluate.mq5               |
//| C5.2 Commit 1 (QA-frozen FINAL DESIGN FREEZE, Docs/PhaseC_C5_2_     |
//| ControlledExecutionEnvironmentLadderContract.md §4/§6/§8): proves     |
//| RolloutStageTransition_Evaluate() implements the frozen one-step-       |
//| forward rule, the cross-validity check applying to BOTH directions       |
//| (not forward-only), the per-transition fail-closed structure (only        |
//| §6.0 implemented this commit, §6.1-§6.6 including §6.2 all refused),       |
//| and that rollback is always permitted, evidence-free, multi-step-at-        |
//| once. Pure function only - running on a real account is safe.                |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_RolloutStageTransitionEvaluate.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void OnStart()
{
   Print("=== MLQuantAI_Test_C5_2_RolloutStageTransitionEvaluate.mq5 ===");

   //=====================================================================
   // 1. Same-stage "transition" is rejected outright.
   //=====================================================================
   Print("--- same stage -> REJECTED_SAME_STAGE ---");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_DEMO_DRY_RUN, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO) == ROLLOUT_TRANSITION_REJECTED_SAME_STAGE,
         "from == to -> REJECTED_SAME_STAGE");

   //=====================================================================
   // 2. §6.0 (NONE -> TEST_FIXTURE), correct environment_mode -> ALLOWED.
   //=====================================================================
   Print("--- §6.0 NONE -> TEST_FIXTURE under ENV_TESTER -> ALLOWED_FORWARD ---");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_NONE, ROLLOUT_STAGE_TEST_FIXTURE, EXECUTION_ENV_TESTER) == ROLLOUT_TRANSITION_ALLOWED_FORWARD,
         "§6.0 pair, valid environment -> ALLOWED_FORWARD");

   //=====================================================================
   // 3. §6.0 pair, but the WRONG environment_mode -> cross-validity
   //    rejects it before the criteria question is even reached.
   //=====================================================================
   Print("--- §6.0 pair, WRONG environment_mode (DEMO) -> REJECTED_ENVIRONMENT_INVALID ---");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_NONE, ROLLOUT_STAGE_TEST_FIXTURE, EXECUTION_ENV_DEMO) == ROLLOUT_TRANSITION_REJECTED_ENVIRONMENT_INVALID,
         "TEST_FIXTURE is reject under ENV_DEMO -> REJECTED_ENVIRONMENT_INVALID, even though the pair itself (§6.0) is implemented");

   //=====================================================================
   // 4. §6.2 (DEMO_DRY_RUN -> DEMO_REAL_SUBMIT): UPDATED per the §6.2
   //    Evidence-Gate Design Contract Rev.8 implementation (QA
   //    Implementation Authorization, 2026-09-17) - the evaluator
   //    mechanism this test originally asserted as "deferred" now exists
   //    (MLQuantAI_RolloutGateReadinessEvaluate.mqh), so this pure core
   //    now returns ALLOWED_FORWARD for this pair, unconditionally, same
   //    as §6.0. The actual evidence check happens one layer up, in
   //    RolloutStageTransitionCommand_Process (§7 Authority Boundary) -
   //    this pure function was never where that check could live.
   //=====================================================================
   Print("--- §6.2 DEMO_DRY_RUN -> DEMO_REAL_SUBMIT, valid environment -> ALLOWED_FORWARD (evaluator mechanism now implemented) ---");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_DEMO_DRY_RUN, ROLLOUT_STAGE_DEMO_REAL_SUBMIT, EXECUTION_ENV_DEMO) == ROLLOUT_TRANSITION_ALLOWED_FORWARD,
         "§6.2 evaluator mechanism now implemented (RolloutGateReadiness_Evaluate, called one layer up) - this pure core returns ALLOWED_FORWARD for this pair");

   //=====================================================================
   // 5. Every other forward pair (§6.1/§6.3/§6.4/§6.5/§6.6) is refused too.
   //=====================================================================
   Print("--- §6.1/§6.3/§6.4/§6.5/§6.6: every other forward pair refused fail-closed ---");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO) == ROLLOUT_TRANSITION_REJECTED_CRITERIA_NOT_FROZEN,
         "§6.1 (TEST_FIXTURE -> DEMO_DRY_RUN) -> REJECTED_CRITERIA_NOT_FROZEN");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_DEMO_REAL_SUBMIT, ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION, EXECUTION_ENV_DEMO) == ROLLOUT_TRANSITION_REJECTED_CRITERIA_NOT_FROZEN,
         "§6.3 (DEMO_REAL_SUBMIT -> DEMO_BOUNDED_AUTOMATION) -> REJECTED_CRITERIA_NOT_FROZEN");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION, ROLLOUT_STAGE_LIVE_SHADOW, EXECUTION_ENV_LIVE) == ROLLOUT_TRANSITION_REJECTED_CRITERIA_NOT_FROZEN,
         "§6.4 (DEMO_BOUNDED_AUTOMATION -> LIVE_SHADOW) -> REJECTED_CRITERIA_NOT_FROZEN");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_LIVE_SHADOW, ROLLOUT_STAGE_LIVE_MANUAL_MICRO_SIZE, EXECUTION_ENV_LIVE) == ROLLOUT_TRANSITION_REJECTED_CRITERIA_NOT_FROZEN,
         "§6.5 (LIVE_SHADOW -> LIVE_MANUAL_MICRO_SIZE) -> REJECTED_CRITERIA_NOT_FROZEN");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_LIVE_MANUAL_MICRO_SIZE, ROLLOUT_STAGE_LIVE_BOUNDED_AUTOMATION, EXECUTION_ENV_LIVE) == ROLLOUT_TRANSITION_REJECTED_CRITERIA_NOT_FROZEN,
         "§6.6 (LIVE_MANUAL_MICRO_SIZE -> LIVE_BOUNDED_AUTOMATION) -> REJECTED_CRITERIA_NOT_FROZEN");

   //=====================================================================
   // 6. Forward transitions that skip a rung are always rejected as
   //    NOT_ADJACENT, regardless of environment_mode or which pair.
   //=====================================================================
   Print("--- forward, skips a rung -> REJECTED_NOT_ADJACENT ---");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_NONE, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO) == ROLLOUT_TRANSITION_REJECTED_NOT_ADJACENT,
         "NONE -> DEMO_DRY_RUN (skips TEST_FIXTURE) -> REJECTED_NOT_ADJACENT");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_REAL_SUBMIT, EXECUTION_ENV_DEMO) == ROLLOUT_TRANSITION_REJECTED_NOT_ADJACENT,
         "TEST_FIXTURE -> DEMO_REAL_SUBMIT (skips DEMO_DRY_RUN) -> REJECTED_NOT_ADJACENT");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_NONE, ROLLOUT_STAGE_LIVE_BOUNDED_AUTOMATION, EXECUTION_ENV_LIVE) == ROLLOUT_TRANSITION_REJECTED_NOT_ADJACENT,
         "NONE -> LIVE_BOUNDED_AUTOMATION (skips everything) -> REJECTED_NOT_ADJACENT");

   //=====================================================================
   // 7. Rollback (regression) is always permitted, evidence-free,
   //    multi-step-at-once, when the target passes cross-validity.
   //=====================================================================
   Print("--- rollback: multi-step, evidence-free, when target is valid for environment_mode -> ALLOWED_ROLLBACK ---");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO) == ROLLOUT_TRANSITION_ALLOWED_ROLLBACK,
         "DEMO_BOUNDED_AUTOMATION -> DEMO_DRY_RUN (drops 2 rungs, same environment_mode) -> ALLOWED_ROLLBACK, no adjacency requirement");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_LIVE_BOUNDED_AUTOMATION, ROLLOUT_STAGE_NONE, EXECUTION_ENV_LIVE) == ROLLOUT_TRANSITION_ALLOWED_ROLLBACK,
         "LIVE_BOUNDED_AUTOMATION -> NONE (drops every rung at once, under duress) -> ALLOWED_ROLLBACK");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_LIVE_SHADOW, ROLLOUT_STAGE_NONE, EXECUTION_ENV_DEMO) == ROLLOUT_TRANSITION_ALLOWED_ROLLBACK,
         "any_stage -> NONE is ALLOWED_ROLLBACK regardless of the real environment_mode (NONE is valid everywhere - the kill switch's own unconditional escape hatch, §7 Effect)");

   //=====================================================================
   // 8. Rollback target ITSELF must still pass §3 cross-validity - "any
   //    attempt", not "any forward attempt" (§3's own frozen wording).
   //=====================================================================
   Print("--- rollback whose TARGET is itself reject for the real environment_mode -> REJECTED_ENVIRONMENT_INVALID ---");
   Check(RolloutStageTransition_Evaluate(ROLLOUT_STAGE_DEMO_REAL_SUBMIT, ROLLOUT_STAGE_TEST_FIXTURE, EXECUTION_ENV_DEMO) == ROLLOUT_TRANSITION_REJECTED_ENVIRONMENT_INVALID,
         "DEMO_REAL_SUBMIT -> TEST_FIXTURE (a regression) but TEST_FIXTURE is reject under ENV_DEMO -> REJECTED_ENVIRONMENT_INVALID even though it is a rollback direction");

   //=====================================================================
   // 9. RolloutStageTransition_IsForwardPairImplemented - direct spot
   //    checks matching the evaluator's own behavior above.
   //=====================================================================
   Print("--- IsForwardPairImplemented: NONE -> TEST_FIXTURE (§6.0) and DEMO_DRY_RUN -> DEMO_REAL_SUBMIT (§6.2) are true ---");
   Check(RolloutStageTransition_IsForwardPairImplemented(ROLLOUT_STAGE_NONE, ROLLOUT_STAGE_TEST_FIXTURE) == true, "NONE -> TEST_FIXTURE -> true");
   Check(RolloutStageTransition_IsForwardPairImplemented(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN) == false, "TEST_FIXTURE -> DEMO_DRY_RUN -> false (§6.1)");
   Check(RolloutStageTransition_IsForwardPairImplemented(ROLLOUT_STAGE_DEMO_DRY_RUN, ROLLOUT_STAGE_DEMO_REAL_SUBMIT) == true, "DEMO_DRY_RUN -> DEMO_REAL_SUBMIT -> true (§6.2, evaluator mechanism now implemented)");

   //=====================================================================
   // 10. RolloutTransitionResult_IsAllowed - convenience predicate.
   //=====================================================================
   Print("--- RolloutTransitionResult_IsAllowed ---");
   Check(RolloutTransitionResult_IsAllowed(ROLLOUT_TRANSITION_ALLOWED_FORWARD) == true, "ALLOWED_FORWARD -> true");
   Check(RolloutTransitionResult_IsAllowed(ROLLOUT_TRANSITION_ALLOWED_ROLLBACK) == true, "ALLOWED_ROLLBACK -> true");
   Check(RolloutTransitionResult_IsAllowed(ROLLOUT_TRANSITION_REJECTED_NOT_ADJACENT) == false, "REJECTED_NOT_ADJACENT -> false");
   Check(RolloutTransitionResult_IsAllowed(ROLLOUT_TRANSITION_REJECTED_CRITERIA_NOT_FROZEN) == false, "REJECTED_CRITERIA_NOT_FROZEN -> false");

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
