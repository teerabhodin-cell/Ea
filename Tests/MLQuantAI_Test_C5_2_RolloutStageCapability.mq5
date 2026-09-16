//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_RolloutStageCapability.mq5                      |
//| C5.2 Commit 1 (QA-frozen FINAL DESIGN FREEZE, Docs/PhaseC_C5_2_     |
//| ControlledExecutionEnvironmentLadderContract.md §5/§9): proves the    |
//| per-stage capability matrix predicates match §5's frozen table          |
//| exactly, and that RolloutStage_PermitsPipelineRun() composes kill        |
//| switch veto -> cross-validity veto -> stage capability in EXACTLY that    |
//| order (QA's structural-gap finding, revision 3). Pure function only -      |
//| running on a real account is safe.                                           |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_RolloutStageCapability.mqh>

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
   Print("=== MLQuantAI_Test_C5_2_RolloutStageCapability.mq5 ===");

   //=====================================================================
   // 1. RolloutStage_PipelineRunPermittedOutsideTester - §5 column 1
   //    (outside-Tester case only).
   //=====================================================================
   Print("--- PipelineRunPermittedOutsideTester: NONE/TEST_FIXTURE = false, everything from DEMO_DRY_RUN onward = true ---");
   Check(RolloutStage_PipelineRunPermittedOutsideTester(ROLLOUT_STAGE_NONE) == false, "NONE -> false");
   Check(RolloutStage_PipelineRunPermittedOutsideTester(ROLLOUT_STAGE_TEST_FIXTURE) == false, "TEST_FIXTURE -> false");
   Check(RolloutStage_PipelineRunPermittedOutsideTester(ROLLOUT_STAGE_DEMO_DRY_RUN) == true, "DEMO_DRY_RUN -> true");
   Check(RolloutStage_PipelineRunPermittedOutsideTester(ROLLOUT_STAGE_DEMO_REAL_SUBMIT) == true, "DEMO_REAL_SUBMIT -> true");
   Check(RolloutStage_PipelineRunPermittedOutsideTester(ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION) == true, "DEMO_BOUNDED_AUTOMATION -> true");
   Check(RolloutStage_PipelineRunPermittedOutsideTester(ROLLOUT_STAGE_LIVE_SHADOW) == true, "LIVE_SHADOW -> true");
   Check(RolloutStage_PipelineRunPermittedOutsideTester(ROLLOUT_STAGE_LIVE_MANUAL_MICRO_SIZE) == true, "LIVE_MANUAL_MICRO_SIZE -> true");
   Check(RolloutStage_PipelineRunPermittedOutsideTester(ROLLOUT_STAGE_LIVE_BOUNDED_AUTOMATION) == true, "LIVE_BOUNDED_AUTOMATION -> true");

   //=====================================================================
   // 2. RolloutStage_SubmitOrderCeremonyReachable - §5 column 3. NO for
   //    DEMO_DRY_RUN and LIVE_SHADOW ("no submission path is reachable
   //    from this stage at all", §5's frozen reading rule).
   //=====================================================================
   Print("--- SubmitOrderCeremonyReachable: only *_REAL_SUBMIT/*_BOUNDED_AUTOMATION/*_MICRO_SIZE stages ---");
   Check(RolloutStage_SubmitOrderCeremonyReachable(ROLLOUT_STAGE_NONE) == false, "NONE -> false");
   Check(RolloutStage_SubmitOrderCeremonyReachable(ROLLOUT_STAGE_TEST_FIXTURE) == false, "TEST_FIXTURE -> false");
   Check(RolloutStage_SubmitOrderCeremonyReachable(ROLLOUT_STAGE_DEMO_DRY_RUN) == false, "DEMO_DRY_RUN -> false (no submission path exists at this stage)");
   Check(RolloutStage_SubmitOrderCeremonyReachable(ROLLOUT_STAGE_DEMO_REAL_SUBMIT) == true, "DEMO_REAL_SUBMIT -> true");
   Check(RolloutStage_SubmitOrderCeremonyReachable(ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION) == true, "DEMO_BOUNDED_AUTOMATION -> true");
   Check(RolloutStage_SubmitOrderCeremonyReachable(ROLLOUT_STAGE_LIVE_SHADOW) == false, "LIVE_SHADOW -> false (no submission path exists at this stage)");
   Check(RolloutStage_SubmitOrderCeremonyReachable(ROLLOUT_STAGE_LIVE_MANUAL_MICRO_SIZE) == true, "LIVE_MANUAL_MICRO_SIZE -> true");
   Check(RolloutStage_SubmitOrderCeremonyReachable(ROLLOUT_STAGE_LIVE_BOUNDED_AUTOMATION) == true, "LIVE_BOUNDED_AUTOMATION -> true");

   //=====================================================================
   // 3. RolloutStage_ManualApprovalRequiredPerSubmission - §5 column 4.
   //    Mandatory ONLY at DEMO_REAL_SUBMIT / LIVE_MANUAL_MICRO_SIZE.
   //=====================================================================
   Print("--- ManualApprovalRequiredPerSubmission: mandatory ONLY at *_REAL_SUBMIT / *_MICRO_SIZE ---");
   Check(RolloutStage_ManualApprovalRequiredPerSubmission(ROLLOUT_STAGE_DEMO_REAL_SUBMIT) == true, "DEMO_REAL_SUBMIT -> true (mandatory)");
   Check(RolloutStage_ManualApprovalRequiredPerSubmission(ROLLOUT_STAGE_LIVE_MANUAL_MICRO_SIZE) == true, "LIVE_MANUAL_MICRO_SIZE -> true (mandatory)");
   Check(RolloutStage_ManualApprovalRequiredPerSubmission(ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION) == false, "DEMO_BOUNDED_AUTOMATION -> false (deliberately not required)");
   Check(RolloutStage_ManualApprovalRequiredPerSubmission(ROLLOUT_STAGE_LIVE_BOUNDED_AUTOMATION) == false, "LIVE_BOUNDED_AUTOMATION -> false (deliberately not required)");
   Check(RolloutStage_ManualApprovalRequiredPerSubmission(ROLLOUT_STAGE_DEMO_DRY_RUN) == false, "DEMO_DRY_RUN -> false (no submission path, question does not arise)");
   Check(RolloutStage_ManualApprovalRequiredPerSubmission(ROLLOUT_STAGE_LIVE_SHADOW) == false, "LIVE_SHADOW -> false (no submission path, question does not arise)");
   Check(RolloutStage_ManualApprovalRequiredPerSubmission(ROLLOUT_STAGE_NONE) == false, "NONE -> false");
   Check(RolloutStage_ManualApprovalRequiredPerSubmission(ROLLOUT_STAGE_TEST_FIXTURE) == false, "TEST_FIXTURE -> false");

   //=====================================================================
   // 4. RolloutStage_AutomaticSubmissionPermitted - §5 column 5. Only the
   //    two bounded-automation stages.
   //=====================================================================
   Print("--- AutomaticSubmissionPermitted: only the two *_BOUNDED_AUTOMATION stages ---");
   Check(RolloutStage_AutomaticSubmissionPermitted(ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION) == true, "DEMO_BOUNDED_AUTOMATION -> true");
   Check(RolloutStage_AutomaticSubmissionPermitted(ROLLOUT_STAGE_LIVE_BOUNDED_AUTOMATION) == true, "LIVE_BOUNDED_AUTOMATION -> true");
   Check(RolloutStage_AutomaticSubmissionPermitted(ROLLOUT_STAGE_DEMO_REAL_SUBMIT) == false, "DEMO_REAL_SUBMIT -> false");
   Check(RolloutStage_AutomaticSubmissionPermitted(ROLLOUT_STAGE_LIVE_MANUAL_MICRO_SIZE) == false, "LIVE_MANUAL_MICRO_SIZE -> false");
   Check(RolloutStage_AutomaticSubmissionPermitted(ROLLOUT_STAGE_DEMO_DRY_RUN) == false, "DEMO_DRY_RUN -> false");
   Check(RolloutStage_AutomaticSubmissionPermitted(ROLLOUT_STAGE_LIVE_SHADOW) == false, "LIVE_SHADOW -> false");

   //=====================================================================
   // 5. RolloutStage_PermitsPipelineRun - the composed §9 OnTick entry-
   //    gate predicate, in the FROZEN required order.
   //=====================================================================
   Print("--- PermitsPipelineRun: step 1, kill switch is an UNCONDITIONAL veto regardless of stage/mode ---");
   Check(RolloutStage_PermitsPipelineRun(ROLLOUT_STAGE_DEMO_REAL_SUBMIT, true, EXECUTION_ENV_DEMO) == false,
         "kill switch active + otherwise-valid stage/mode -> still false (kill switch checked FIRST)");
   Check(RolloutStage_PermitsPipelineRun(ROLLOUT_STAGE_DEMO_DRY_RUN, true, EXECUTION_ENV_DEMO) == false,
         "kill switch active vetoes even the weakest capability stage (DEMO_DRY_RUN)");

   Print("--- PermitsPipelineRun: step 2, cross-validity is checked BEFORE stage capability (QA's structural-gap finding) ---");
   Check(RolloutStage_PermitsPipelineRun(ROLLOUT_STAGE_DEMO_REAL_SUBMIT, false, EXECUTION_ENV_LIVE) == false,
         "kill switch inactive, but stage (DEMO_REAL_SUBMIT) is reject for the REAL environment_mode (LIVE) -> false regardless of stage's own capability - the exact DEMO->LIVE stale-stage gap QA identified");
   Check(RolloutStage_PermitsPipelineRun(ROLLOUT_STAGE_TEST_FIXTURE, false, EXECUTION_ENV_DEMO) == false,
         "TEST_FIXTURE is reject under ENV_DEMO -> false (cross-validity veto, not merely a stage-capability NO)");

   Print("--- PermitsPipelineRun: step 3, stage capability governs once kill switch/cross-validity both pass ---");
   Check(RolloutStage_PermitsPipelineRun(ROLLOUT_STAGE_NONE, false, EXECUTION_ENV_DEMO) == false,
         "NONE is valid under DEMO, but NONE itself grants no pipeline-run capability -> false");
   Check(RolloutStage_PermitsPipelineRun(ROLLOUT_STAGE_TEST_FIXTURE, false, EXECUTION_ENV_TESTER) == false,
         "TEST_FIXTURE is valid under TESTER, but this predicate models the OUTSIDE-Tester gate only (C5.0's own MQL_TESTER check handles the Tester case separately) -> false");
   Check(RolloutStage_PermitsPipelineRun(ROLLOUT_STAGE_DEMO_DRY_RUN, false, EXECUTION_ENV_DEMO) == true,
         "DEMO_DRY_RUN, valid mode, no kill switch -> true (the weakest OUTSIDE-Tester capability stage)");
   Check(RolloutStage_PermitsPipelineRun(ROLLOUT_STAGE_LIVE_BOUNDED_AUTOMATION, false, EXECUTION_ENV_LIVE) == true,
         "LIVE_BOUNDED_AUTOMATION, valid mode, no kill switch -> true (the strongest ladder rung)");

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
