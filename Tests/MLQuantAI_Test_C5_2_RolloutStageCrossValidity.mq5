//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_RolloutStageCrossValidity.mq5                   |
//| C5.2 Commit 1 (QA-frozen FINAL DESIGN FREEZE, Docs/PhaseC_C5_2_     |
//| ControlledExecutionEnvironmentLadderContract.md §3): proves           |
//| RolloutStage_IsValidForEnvironment() implements the frozen exhaustive   |
//| 8x4 rollout_stage x environment_mode table exactly - all 32 cells,       |
//| explicit, no shortcuts. Pure function only, no EventStore, no OrderSend -   |
//| running on a real account is safe.                                            |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_RolloutStageCrossValidity.mqh>

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
   Print("=== MLQuantAI_Test_C5_2_RolloutStageCrossValidity.mq5 ===");

   //=====================================================================
   // ROLLOUT_STAGE_NONE - VALID under every environment_mode (§3).
   //=====================================================================
   Print("--- ROLLOUT_STAGE_NONE: valid under all 4 environment_mode values ---");
   Check(RolloutStage_IsValidForEnvironment(ROLLOUT_STAGE_NONE, EXECUTION_ENV_NONE)   == true, "NONE x ENV_NONE -> VALID");
   Check(RolloutStage_IsValidForEnvironment(ROLLOUT_STAGE_NONE, EXECUTION_ENV_TESTER) == true, "NONE x ENV_TESTER -> VALID");
   Check(RolloutStage_IsValidForEnvironment(ROLLOUT_STAGE_NONE, EXECUTION_ENV_DEMO)   == true, "NONE x ENV_DEMO -> VALID");
   Check(RolloutStage_IsValidForEnvironment(ROLLOUT_STAGE_NONE, EXECUTION_ENV_LIVE)   == true, "NONE x ENV_LIVE -> VALID");

   //=====================================================================
   // ROLLOUT_STAGE_TEST_FIXTURE - VALID only under EXECUTION_ENV_TESTER.
   //=====================================================================
   Print("--- ROLLOUT_STAGE_TEST_FIXTURE: valid ONLY under ENV_TESTER ---");
   Check(RolloutStage_IsValidForEnvironment(ROLLOUT_STAGE_TEST_FIXTURE, EXECUTION_ENV_NONE)   == false, "TEST_FIXTURE x ENV_NONE -> reject");
   Check(RolloutStage_IsValidForEnvironment(ROLLOUT_STAGE_TEST_FIXTURE, EXECUTION_ENV_TESTER) == true,  "TEST_FIXTURE x ENV_TESTER -> VALID");
   Check(RolloutStage_IsValidForEnvironment(ROLLOUT_STAGE_TEST_FIXTURE, EXECUTION_ENV_DEMO)   == false, "TEST_FIXTURE x ENV_DEMO -> reject");
   Check(RolloutStage_IsValidForEnvironment(ROLLOUT_STAGE_TEST_FIXTURE, EXECUTION_ENV_LIVE)   == false, "TEST_FIXTURE x ENV_LIVE -> reject");

   //=====================================================================
   // The three DEMO-family stages - VALID only under EXECUTION_ENV_DEMO.
   //=====================================================================
   Print("--- DEMO_DRY_RUN / DEMO_REAL_SUBMIT / DEMO_BOUNDED_AUTOMATION: valid ONLY under ENV_DEMO ---");
   ENUM_EXECUTION_ROLLOUT_STAGE demoStages[3] = {ROLLOUT_STAGE_DEMO_DRY_RUN, ROLLOUT_STAGE_DEMO_REAL_SUBMIT, ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION};
   string demoStageNames[3] = {"DEMO_DRY_RUN", "DEMO_REAL_SUBMIT", "DEMO_BOUNDED_AUTOMATION"};
   for(int i = 0; i < 3; i++)
   {
      Check(RolloutStage_IsValidForEnvironment(demoStages[i], EXECUTION_ENV_NONE)   == false, demoStageNames[i] + " x ENV_NONE -> reject");
      Check(RolloutStage_IsValidForEnvironment(demoStages[i], EXECUTION_ENV_TESTER) == false, demoStageNames[i] + " x ENV_TESTER -> reject");
      Check(RolloutStage_IsValidForEnvironment(demoStages[i], EXECUTION_ENV_DEMO)   == true,  demoStageNames[i] + " x ENV_DEMO -> VALID");
      Check(RolloutStage_IsValidForEnvironment(demoStages[i], EXECUTION_ENV_LIVE)   == false, demoStageNames[i] + " x ENV_LIVE -> reject");
   }

   //=====================================================================
   // The three LIVE-family stages - VALID only under EXECUTION_ENV_LIVE.
   //=====================================================================
   Print("--- LIVE_SHADOW / LIVE_MANUAL_MICRO_SIZE / LIVE_BOUNDED_AUTOMATION: valid ONLY under ENV_LIVE ---");
   ENUM_EXECUTION_ROLLOUT_STAGE liveStages[3] = {ROLLOUT_STAGE_LIVE_SHADOW, ROLLOUT_STAGE_LIVE_MANUAL_MICRO_SIZE, ROLLOUT_STAGE_LIVE_BOUNDED_AUTOMATION};
   string liveStageNames[3] = {"LIVE_SHADOW", "LIVE_MANUAL_MICRO_SIZE", "LIVE_BOUNDED_AUTOMATION"};
   for(int i = 0; i < 3; i++)
   {
      Check(RolloutStage_IsValidForEnvironment(liveStages[i], EXECUTION_ENV_NONE)   == false, liveStageNames[i] + " x ENV_NONE -> reject");
      Check(RolloutStage_IsValidForEnvironment(liveStages[i], EXECUTION_ENV_TESTER) == false, liveStageNames[i] + " x ENV_TESTER -> reject");
      Check(RolloutStage_IsValidForEnvironment(liveStages[i], EXECUTION_ENV_DEMO)   == false, liveStageNames[i] + " x ENV_DEMO -> reject");
      Check(RolloutStage_IsValidForEnvironment(liveStages[i], EXECUTION_ENV_LIVE)   == true,  liveStageNames[i] + " x ENV_LIVE -> VALID");
   }

   //=====================================================================
   // QA's exact scenario from the revision-2 CONDITIONAL APPROVAL: a
   // rollout_stage recorded valid for DEMO must be `reject` once the real
   // environment_mode is LIVE.
   //=====================================================================
   Print("--- QA's DEMO->LIVE stale-stage scenario: DEMO_REAL_SUBMIT is reject under ENV_LIVE ---");
   Check(RolloutStage_IsValidForEnvironment(ROLLOUT_STAGE_DEMO_REAL_SUBMIT, EXECUTION_ENV_LIVE) == false,
         "DEMO_REAL_SUBMIT x ENV_LIVE -> reject (the exact gap QA identified in revision 2)");

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
