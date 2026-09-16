//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_RolloutStageEventEmission.mq5                    |
//| C5.2 Commit 1 (QA-frozen FINAL DESIGN FREEZE, Docs/PhaseC_C5_2_     |
//| ControlledExecutionEnvironmentLadderContract.md §4/§7/§7.1/§7.2):     |
//| proves the durable write paths - RolloutStageTransition_Emit()          |
//| (RECORDED/REJECTED/FAILED, Safe Mode only on write failure, never on      |
//| a business-rule rejection) and KillSwitch_Engage()/KillSwitch_Clear()      |
//| (engage durably records BOTH its own event AND, per §7 Effect, a forced      |
//| rollback-to-NONE when the current stage is not already NONE; clear touches   |
//| ONLY its own event, never rollout_stage; both are scoped to one               |
//| environment_mode). Uses a real EventStore file - running on a real account     |
//| is safe (no OrderSend anywhere in this file).                                    |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RolloutStageEventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_KillSwitchEventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RolloutStageProjection.mqh>
#include <MLQuantAI/Execution/MLQuantAI_RolloutStageCapability.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_C5_2_RolloutStageEventEmission.jsonl"

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
   Print("=== MLQuantAI_Test_C5_2_RolloutStageEventEmission.mq5 ===");

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   SafeMode_Clear();
   Check(EventStore_Open(TEST_EVENT_STORE_FILE), "setup: event store opens");

   //=====================================================================
   // 1. Allowed forward transition (§6.0, NONE -> TEST_FIXTURE under
   //    ENV_TESTER) -> RECORDED, one durable line, replay confirms it.
   //=====================================================================
   Print("--- RolloutStageTransition_Emit: §6.0 NONE -> TEST_FIXTURE under ENV_TESTER -> RECORDED ---");
   {
      ENUM_ROLLOUT_TRANSITION_RESULT eval;
      ENUM_ROLLOUT_STAGE_EMIT_RESULT result = RolloutStageTransition_Emit(ROLLOUT_STAGE_NONE, ROLLOUT_STAGE_TEST_FIXTURE, EXECUTION_ENV_TESTER,
                                                                            "qa_operator", "ci_smoke_test", eval);
      Check(result == ROLLOUT_STAGE_EMIT_RECORDED, "status == RECORDED");
      Check(eval == ROLLOUT_TRANSITION_ALLOWED_FORWARD, "evaluation == ALLOWED_FORWARD");

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
      ENUM_EXECUTION_ROLLOUT_STAGE replayed;
      bool found = RolloutStageProjection_ReplayCurrent(lines, replayed);
      Check(found == true && replayed == ROLLOUT_STAGE_TEST_FIXTURE, "replay confirms the durable write: current stage == TEST_FIXTURE");
   }

   //=====================================================================
   // 2. Rejected attempt (not adjacent) -> REJECTED, no new durable line,
   //    NO Safe Mode.
   //=====================================================================
   Print("--- RolloutStageTransition_Emit: skips a rung -> REJECTED, no write, no Safe Mode ---");
   {
      string linesBefore[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesBefore);
      int countBefore = ArraySize(linesBefore);

      ENUM_ROLLOUT_TRANSITION_RESULT eval;
      ENUM_ROLLOUT_STAGE_EMIT_RESULT result = RolloutStageTransition_Emit(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_REAL_SUBMIT, EXECUTION_ENV_DEMO,
                                                                            "qa_operator", "", eval);
      Check(result == ROLLOUT_STAGE_EMIT_REJECTED, "status == REJECTED");
      Check(eval == ROLLOUT_TRANSITION_REJECTED_NOT_ADJACENT, "evaluation == REJECTED_NOT_ADJACENT");
      Check(!SafeMode_IsActive(), "a business-rule rejection never trips Safe Mode");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == countBefore, "no new durable line appended for a rejected attempt");
   }

   //=====================================================================
   // 3. Rejected attempt (§6.2, criteria not frozen) -> REJECTED, no write.
   //=====================================================================
   Print("--- RolloutStageTransition_Emit: §6.2 pair -> REJECTED_CRITERIA_NOT_FROZEN, no write ---");
   {
      string linesBefore[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesBefore);
      int countBefore = ArraySize(linesBefore);

      ENUM_ROLLOUT_TRANSITION_RESULT eval;
      ENUM_ROLLOUT_STAGE_EMIT_RESULT result = RolloutStageTransition_Emit(ROLLOUT_STAGE_DEMO_DRY_RUN, ROLLOUT_STAGE_DEMO_REAL_SUBMIT, EXECUTION_ENV_DEMO,
                                                                            "qa_operator", "", eval);
      Check(result == ROLLOUT_STAGE_EMIT_REJECTED, "status == REJECTED");
      Check(eval == ROLLOUT_TRANSITION_REJECTED_CRITERIA_NOT_FROZEN, "evaluation == REJECTED_CRITERIA_NOT_FROZEN");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == countBefore, "no new durable line appended");
   }

   //=====================================================================
   // 4. Durable write failure (EventStore closed) -> FAILED, Safe Mode
   //    DOES trip.
   //=====================================================================
   Print("--- RolloutStageTransition_Emit: durable write failure -> FAILED, Safe Mode trips ---");
   {
      EventStore_Close();
      Check(!SafeMode_IsActive(), "sanity: Safe Mode not active before the write-failure attempt");

      ENUM_ROLLOUT_TRANSITION_RESULT eval;
      ENUM_ROLLOUT_STAGE_EMIT_RESULT result = RolloutStageTransition_Emit(ROLLOUT_STAGE_TEST_FIXTURE, ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO,
                                                                            "qa_operator", "", eval);
      Check(eval == ROLLOUT_TRANSITION_REJECTED_CRITERIA_NOT_FROZEN, "sanity: this pair (§6.1) is itself still not-yet-frozen (unrelated to the write-failure path)");
      Check(result == ROLLOUT_STAGE_EMIT_REJECTED, "an unimplemented pair is REJECTED before any write is attempted, even with the store closed");
      Check(!SafeMode_IsActive(), "REJECTED (business rule) never reaches the write path, so no Safe Mode trip yet");

      // Force a genuine write-failure path: an ALLOWED evaluation (the
      // §6.0 pair, valid environment) whose durable append then fails
      // because the store is closed.
      ENUM_ROLLOUT_TRANSITION_RESULT eval2;
      ENUM_ROLLOUT_STAGE_EMIT_RESULT result2 = RolloutStageTransition_Emit(ROLLOUT_STAGE_NONE, ROLLOUT_STAGE_TEST_FIXTURE, EXECUTION_ENV_TESTER,
                                                                             "qa_operator", "", eval2);
      Check(eval2 == ROLLOUT_TRANSITION_ALLOWED_FORWARD, "sanity: this attempt WAS evaluated as ALLOWED_FORWARD");
      Check(result2 == ROLLOUT_STAGE_EMIT_FAILED, "status == FAILED (the durable append itself failed, store closed)");
      Check(SafeMode_IsActive(), "an ALLOWED transition whose durable write fails DOES trip Safe Mode");

      SafeMode_Clear();
      Check(EventStore_Open(TEST_EVENT_STORE_FILE), "cleanup: event store reopens");
   }

   //=====================================================================
   // 5. KillSwitch_Engage with currentStage == NONE -> only the ENGAGED
   //    event is written, no forced rollback needed/emitted.
   //=====================================================================
   Print("--- KillSwitch_Engage: currentStage == NONE -> ENGAGED only, no forced rollback line ---");
   {
      string linesBefore[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesBefore);
      int countBefore = ArraySize(linesBefore);

      ENUM_KILL_SWITCH_EMIT_RESULT result = KillSwitch_Engage(EXECUTION_ENV_LIVE, "qa_operator", ROLLOUT_STAGE_NONE);
      Check(result == KILL_SWITCH_EMIT_ENGAGED, "status == ENGAGED");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == countBefore + 1, "exactly ONE new durable line (KILL_SWITCH_ENGAGED only - currentStage was already NONE)");

      bool active;
      bool found = KillSwitchProjection_ReplayActive(linesAfter, EXECUTION_ENV_LIVE, active);
      Check(found == true && active == true, "replay confirms kill switch active for ENV_LIVE");
   }

   //=====================================================================
   // 6. KillSwitch_Engage with currentStage != NONE -> BOTH the ENGAGED
   //    event AND a forced rollback-to-NONE EXECUTION_ROLLOUT_STAGE_CHANGED
   //    event are durably written (§7 Effect - "strongest rollback").
   //=====================================================================
   Print("--- KillSwitch_Engage: currentStage != NONE -> ENGAGED + forced rollback-to-NONE (2 new lines) ---");
   {
      string linesBefore[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesBefore);
      int countBefore = ArraySize(linesBefore);

      ENUM_KILL_SWITCH_EMIT_RESULT result = KillSwitch_Engage(EXECUTION_ENV_DEMO, "qa_operator", ROLLOUT_STAGE_DEMO_DRY_RUN);
      Check(result == KILL_SWITCH_EMIT_ENGAGED, "status == ENGAGED");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == countBefore + 2, "exactly TWO new durable lines (KILL_SWITCH_ENGAGED + forced rollback)");

      bool active;
      bool foundActive = KillSwitchProjection_ReplayActive(linesAfter, EXECUTION_ENV_DEMO, active);
      Check(foundActive == true && active == true, "replay confirms kill switch active for ENV_DEMO");

      ENUM_EXECUTION_ROLLOUT_STAGE replayedStage;
      bool foundStage = RolloutStageProjection_ReplayCurrent(linesAfter, replayedStage);
      Check(foundStage == true && replayedStage == ROLLOUT_STAGE_NONE, "replay confirms the forced rollback actually landed at ROLLOUT_STAGE_NONE");
   }

   //=====================================================================
   // 7. Kill switch is scoped to ONE environment_mode - engaging for DEMO
   //    must not report as active when queried for LIVE.
   //=====================================================================
   Print("--- KillSwitch_Engage scoping: DEMO's engage does not affect LIVE ---");
   {
      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines); // contains the DEMO engage from test 6, and the LIVE engage from test 5
      bool activeLive;
      bool foundLive = KillSwitchProjection_ReplayActive(lines, EXECUTION_ENV_LIVE, activeLive);
      Check(foundLive == true && activeLive == true, "LIVE is (separately) active from test 5's own engage - unaffected by test 6's DEMO engage");
   }

   //=====================================================================
   // 8. KillSwitch_Clear touches ONLY its own event - rollout_stage is
   //    left exactly as the forced rollback set it (§7.2 - clearing
   //    alone restores nothing).
   //=====================================================================
   Print("--- KillSwitch_Clear: CLEARED only, rollout_stage completely unaffected ---");
   {
      string linesBeforeClear[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesBeforeClear);
      ENUM_EXECUTION_ROLLOUT_STAGE stageBeforeClear;
      RolloutStageProjection_ReplayCurrent(linesBeforeClear, stageBeforeClear);
      int countBefore = ArraySize(linesBeforeClear);

      ENUM_KILL_SWITCH_EMIT_RESULT result = KillSwitch_Clear(EXECUTION_ENV_DEMO, "qa_operator");
      Check(result == KILL_SWITCH_EMIT_CLEARED, "status == CLEARED");

      string linesAfterClear[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfterClear);
      Check(ArraySize(linesAfterClear) == countBefore + 1, "exactly ONE new durable line (KILL_SWITCH_CLEARED only - no rollout_stage event)");

      ENUM_EXECUTION_ROLLOUT_STAGE stageAfterClear;
      RolloutStageProjection_ReplayCurrent(linesAfterClear, stageAfterClear);
      Check(stageAfterClear == stageBeforeClear, "rollout_stage is COMPLETELY UNCHANGED by clearing (§7.2 - clearing alone restores no capability)");

      bool activeDemoAfterClear;
      KillSwitchProjection_ReplayActive(linesAfterClear, EXECUTION_ENV_DEMO, activeDemoAfterClear);
      Check(activeDemoAfterClear == false, "kill switch for ENV_DEMO now reads inactive (the later CLEARED event wins)");

      bool activeLiveAfterClear;
      KillSwitchProjection_ReplayActive(linesAfterClear, EXECUTION_ENV_LIVE, activeLiveAfterClear);
      Check(activeLiveAfterClear == true, "ENV_LIVE's OWN kill switch (test 5) is untouched by clearing ENV_DEMO's");
   }

   //=====================================================================
   // 9. Durable write failure for KillSwitch_Engage/_Clear -> FAILED,
   //    Safe Mode trips.
   //=====================================================================
   Print("--- KillSwitch_Engage / KillSwitch_Clear: durable write failure -> FAILED, Safe Mode trips ---");
   {
      EventStore_Close();
      Check(!SafeMode_IsActive(), "sanity: Safe Mode not active before the write-failure attempt");

      ENUM_KILL_SWITCH_EMIT_RESULT engageResult = KillSwitch_Engage(EXECUTION_ENV_LIVE, "qa_operator", ROLLOUT_STAGE_NONE);
      Check(engageResult == KILL_SWITCH_EMIT_FAILED, "KillSwitch_Engage: status == FAILED when the store is closed");
      Check(SafeMode_IsActive(), "Safe Mode DOES trip");

      SafeMode_Clear();
      ENUM_KILL_SWITCH_EMIT_RESULT clearResult = KillSwitch_Clear(EXECUTION_ENV_LIVE, "qa_operator");
      Check(clearResult == KILL_SWITCH_EMIT_FAILED, "KillSwitch_Clear: status == FAILED when the store is closed");
      Check(SafeMode_IsActive(), "Safe Mode DOES trip");

      SafeMode_Clear();
      Check(EventStore_Open(TEST_EVENT_STORE_FILE), "cleanup: event store reopens");
   }

   //=====================================================================
   // 10. Non-atomicity resilience (QA's own diff-review finding): Kill
   //     Switch_Engage() writes KILL_SWITCH_ENGAGED, then attempts a
   //     SEPARATE forced-rollback write. If the process crashes/fails
   //     between those two writes, the durable log ends up with ENGAGED
   //     recorded but NO forced-rollback event - this simulates exactly
   //     that outcome directly at the log level (rather than trying to
   //     fault-inject mid-function, which this codebase's EventStore API
   //     has no hook for) and proves capability is STILL denied, because
   //     the kill switch veto is checked FIRST and unconditionally in
   //     RolloutStage_PermitsPipelineRun(), independent of whatever
   //     rollout_stage the (incomplete) log replays to.
   //=====================================================================
   Print("--- Non-atomicity resilience: KILL_SWITCH_ENGAGED durable but forced rollback MISSING (simulated crash between the two writes) -> pipeline capability still denied ---");
   {
      string lines[2];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"DEMO_DRY_RUN\",\"to_stage\":\"DEMO_REAL_SUBMIT\",\"environment_mode\":\"DEMO\"}";
      lines[1] = "{\"type\":\"KILL_SWITCH_ENGAGED\",\"environment_mode\":\"DEMO\"}"; // the forced rollback-to-NONE line KillSwitch_Engage would also write is deliberately absent

      ENUM_EXECUTION_ROLLOUT_STAGE replayedStage;
      RolloutStageProjection_ReplayCurrent(lines, replayedStage);
      Check(replayedStage == ROLLOUT_STAGE_DEMO_REAL_SUBMIT, "replay still shows the STALE pre-kill-switch stage (DEMO_REAL_SUBMIT) - the forced rollback never landed");

      bool killSwitchActive;
      KillSwitchProjection_ReplayActive(lines, EXECUTION_ENV_DEMO, killSwitchActive);
      Check(killSwitchActive == true, "kill switch itself IS correctly reconstructed as active from its own durable event");

      bool permitted = RolloutStage_PermitsPipelineRun(replayedStage, killSwitchActive, EXECUTION_ENV_DEMO);
      Check(permitted == false, "pipeline capability is STILL denied even though rollout_stage shows a stale non-NONE value - the kill switch veto (checked FIRST, unconditionally, before rollout_stage is even consulted) makes the two-write non-atomicity structurally safe by design");
   }

   EventStore_Close();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
