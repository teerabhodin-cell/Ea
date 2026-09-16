//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Commit2_KillSwitchCommandProcess.mq5             |
//| C5.2 Commit 2 (QA-frozen Design Revision 2, Docs/PhaseC_C5_2_Commit2_ |
//| RuntimeIntegrationDesignContract.md §A/§D): proves KillSwitchEngageCommand_ |
//| Process()/KillSwitchClearCommand_Process() correctly wrap Commit 1's own    |
//| KillSwitch_Engage()/KillSwitch_Clear(), and that neither is ever vetoed by   |
//| an already-active kill switch (§A's corrected wording - CLEAR must always     |
//| be reachable, ENGAGE is idempotent-in-spirit). Uses a real EventStore file -   |
//| no OrderSend anywhere in this file, running on a real account is safe.          |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_KillSwitchCommandProcess.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_C5_2_Commit2_KillSwitchCommandProcess.jsonl"

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
   Print("=== MLQuantAI_Test_C5_2_Commit2_KillSwitchCommandProcess.mq5 ===");

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   SafeMode_Clear();
   Check(EventStore_Open(TEST_EVENT_STORE_FILE), "setup: event store opens");

   //=====================================================================
   // 1. Engage, currentStage == NONE -> ENGAGED, one durable line.
   //=====================================================================
   Print("--- KillSwitchEngageCommand_Process: currentStage == NONE -> ENGAGED ---");
   {
      KillSwitchCommandResult result;
      KillSwitchEngageCommand_Process("qa_operator", ROLLOUT_STAGE_NONE, EXECUTION_ENV_LIVE, result);
      Check(result.status == KILL_SWITCH_CMD_ENGAGED, "status == ENGAGED");
      Check(result.reason_code == "engaged", "reason_code == engaged");

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
      Check(ArraySize(lines) == 1, "exactly one durable line (KILL_SWITCH_ENGAGED only)");
      bool active;
      KillSwitchProjection_ReplayActive(lines, EXECUTION_ENV_LIVE, active);
      Check(active == true, "replay confirms kill switch active for ENV_LIVE");
   }

   //=====================================================================
   // 2. Engage again while ALREADY active (currentStage now NONE, since
   //    the kill switch was never cleared and no forced-rollback was
   //    needed) -> NOT vetoed by its own active state, succeeds again
   //    (idempotent-in-spirit, §A's corrected wording).
   //=====================================================================
   Print("--- KillSwitchEngageCommand_Process: re-engaging an ALREADY-active kill switch is NOT vetoed ---");
   {
      KillSwitchCommandResult result;
      KillSwitchEngageCommand_Process("qa_operator", ROLLOUT_STAGE_NONE, EXECUTION_ENV_LIVE, result);
      Check(result.status == KILL_SWITCH_CMD_ENGAGED, "status == ENGAGED (never refused just because already active)");

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
      Check(ArraySize(lines) == 2, "a second KILL_SWITCH_ENGAGED durable line is appended");
   }

   //=====================================================================
   // 3. Engage with currentStage != NONE -> ENGAGED + forced rollback (2
   //    new lines), matching Commit 1's own KillSwitch_Engage() behavior.
   //=====================================================================
   Print("--- KillSwitchEngageCommand_Process: currentStage != NONE -> ENGAGED + forced rollback-to-NONE ---");
   {
      string linesBefore[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesBefore);
      int countBefore = ArraySize(linesBefore);

      KillSwitchCommandResult result;
      KillSwitchEngageCommand_Process("qa_operator", ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO, result);
      Check(result.status == KILL_SWITCH_CMD_ENGAGED, "status == ENGAGED");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == countBefore + 2, "exactly TWO new durable lines (KILL_SWITCH_ENGAGED + forced rollback)");

      ENUM_EXECUTION_ROLLOUT_STAGE replayedStage;
      RolloutStageProjection_ReplayCurrent(linesAfter, replayedStage);
      Check(replayedStage == ROLLOUT_STAGE_NONE, "replay confirms the forced rollback landed at ROLLOUT_STAGE_NONE");
   }

   //=====================================================================
   // 4. Clear, while kill switch IS active -> NOT vetoed (§A's corrected
   //    wording - CLEAR must always be reachable, it IS the recovery
   //    path). Never touches rollout_stage.
   //=====================================================================
   Print("--- KillSwitchClearCommand_Process: reachable WHILE the kill switch is active (never vetoed) ---");
   {
      string linesBeforeClear[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesBeforeClear);
      ENUM_EXECUTION_ROLLOUT_STAGE stageBeforeClear;
      RolloutStageProjection_ReplayCurrent(linesBeforeClear, stageBeforeClear);
      int countBefore = ArraySize(linesBeforeClear);

      bool activeBeforeClear;
      KillSwitchProjection_ReplayActive(linesBeforeClear, EXECUTION_ENV_DEMO, activeBeforeClear);
      Check(activeBeforeClear == true, "sanity: kill switch IS active for ENV_DEMO before clearing");

      KillSwitchCommandResult result;
      KillSwitchClearCommand_Process("qa_operator", EXECUTION_ENV_DEMO, result);
      Check(result.status == KILL_SWITCH_CMD_CLEARED, "status == CLEARED (never refused while active)");
      Check(result.reason_code == "cleared", "reason_code == cleared");

      string linesAfterClear[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfterClear);
      Check(ArraySize(linesAfterClear) == countBefore + 1, "exactly ONE new durable line (KILL_SWITCH_CLEARED only - no rollout_stage event)");

      ENUM_EXECUTION_ROLLOUT_STAGE stageAfterClear;
      RolloutStageProjection_ReplayCurrent(linesAfterClear, stageAfterClear);
      Check(stageAfterClear == stageBeforeClear, "rollout_stage is COMPLETELY UNCHANGED by clearing (§7.2)");

      bool activeAfterClear;
      KillSwitchProjection_ReplayActive(linesAfterClear, EXECUTION_ENV_DEMO, activeAfterClear);
      Check(activeAfterClear == false, "kill switch for ENV_DEMO now reads inactive");
   }

   //=====================================================================
   // 5. Durable write failure (EventStore closed) -> FAILED, Safe Mode trips,
   //    for both Engage and Clear.
   //=====================================================================
   Print("--- durable write failure -> FAILED, Safe Mode trips (Engage and Clear) ---");
   {
      EventStore_Close();
      Check(!SafeMode_IsActive(), "sanity: Safe Mode not active before the write-failure attempt");

      KillSwitchCommandResult engageResult;
      KillSwitchEngageCommand_Process("qa_operator", ROLLOUT_STAGE_NONE, EXECUTION_ENV_LIVE, engageResult);
      Check(engageResult.status == KILL_SWITCH_CMD_FAILED, "Engage: status == FAILED when the store is closed");
      Check(SafeMode_IsActive(), "Safe Mode DOES trip");

      SafeMode_Clear();
      KillSwitchCommandResult clearResult;
      KillSwitchClearCommand_Process("qa_operator", EXECUTION_ENV_LIVE, clearResult);
      Check(clearResult.status == KILL_SWITCH_CMD_FAILED, "Clear: status == FAILED when the store is closed");
      Check(SafeMode_IsActive(), "Safe Mode DOES trip");

      SafeMode_Clear();
      Check(EventStore_Open(TEST_EVENT_STORE_FILE), "cleanup: event store reopens");
   }

   EventStore_Close();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
