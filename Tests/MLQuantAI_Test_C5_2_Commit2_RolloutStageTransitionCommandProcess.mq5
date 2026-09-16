//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Commit2_RolloutStageTransitionCommandProcess.mq5|
//| C5.2 Commit 2 (QA-frozen Design Revision 2, Docs/PhaseC_C5_2_Commit2_ |
//| RuntimeIntegrationDesignContract.md §A/§D/§E test #6): proves           |
//| RolloutStageTransitionCommand_Process() implements the frozen sequence   |
//| exactly - kill switch veto FIRST, then the current-state cross-validity   |
//| check (QA's revision-2 blocker), then Commit 1's own evaluator/emitter.     |
//| Test #6's exact scenario (DEMO_BOUNDED_AUTOMATION recorded under DEMO,       |
//| queried under real LIVE, target LIVE_SHADOW itself valid) is covered          |
//| directly. Uses a real EventStore file - no OrderSend anywhere in this file,    |
//| running on a real account is safe.                                              |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_RolloutStageTransitionCommandProcess.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_C5_2_Commit2_RolloutStageTransitionCommandProcess.jsonl"

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
   Print("=== MLQuantAI_Test_C5_2_Commit2_RolloutStageTransitionCommandProcess.mq5 ===");

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   SafeMode_Clear();
   Check(EventStore_Open(TEST_EVENT_STORE_FILE), "setup: event store opens");

   //=====================================================================
   // 1. Kill switch active -> KILL_SWITCH_ACTIVE, refused BEFORE the
   //    current-state check or the evaluator - no durable write.
   //=====================================================================
   Print("--- kill switch active -> KILL_SWITCH_ACTIVE, no durable write, current_stage still reported ---");
   {
      string lines[2];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"NONE\",\"to_stage\":\"TEST_FIXTURE\",\"environment_mode\":\"TESTER\"}";
      lines[1] = "{\"type\":\"KILL_SWITCH_ENGAGED\",\"environment_mode\":\"TESTER\"}";

      RolloutStageTransitionCommandResult result;
      RolloutStageTransitionCommand_Process(ROLLOUT_STAGE_DEMO_DRY_RUN, "qa_operator", "", lines, EXECUTION_ENV_TESTER, result);
      Check(result.status == ROLLOUT_STAGE_TRANSITION_CMD_KILL_SWITCH_ACTIVE, "status == KILL_SWITCH_ACTIVE");
      Check(result.reason_code == "kill_switch_active", "reason_code == kill_switch_active");
      Check(result.current_stage == ROLLOUT_STAGE_TEST_FIXTURE, "current_stage still correctly reported (TEST_FIXTURE) even though refused");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == 0, "no durable line appended - kill switch veto happens before any write");
   }

   //=====================================================================
   // 2. Current-state cross-validity (QA's revision-2 blocker / test #6's
   //    exact scenario): current stage DEMO_BOUNDED_AUTOMATION recorded
   //    under DEMO, queried under the REAL environment_mode LIVE, target
   //    LIVE_SHADOW (itself perfectly valid under LIVE) -> refused
   //    BEFORE the evaluator is ever reached, no durable write, even
   //    though the target alone would have evaluated cleanly.
   //=====================================================================
   Print("--- test #6: current state (DEMO_BOUNDED_AUTOMATION) invalid for real environment_mode (LIVE) -> CURRENT_STATE_INVALID, no durable write, regardless of a valid target ---");
   {
      string lines[1];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"DEMO_REAL_SUBMIT\",\"to_stage\":\"DEMO_BOUNDED_AUTOMATION\",\"environment_mode\":\"DEMO\"}";

      RolloutStageTransitionCommandResult result;
      RolloutStageTransitionCommand_Process(ROLLOUT_STAGE_LIVE_SHADOW, "qa_operator", "evidence_ref", lines, EXECUTION_ENV_LIVE, result);
      Check(result.status == ROLLOUT_STAGE_TRANSITION_CMD_CURRENT_STATE_INVALID, "status == CURRENT_STATE_INVALID");
      Check(result.reason_code == "current_state_environment_invalid", "reason_code == current_state_environment_invalid");
      Check(result.current_stage == ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION, "current_stage correctly reports the real replayed value (DEMO_BOUNDED_AUTOMATION)");
      Check(result.evaluation == ROLLOUT_TRANSITION_NONE, "evaluation is NEVER populated - RolloutStageTransition_Evaluate is never reached");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == 0, "NO new EXECUTION_ROLLOUT_STAGE_CHANGED line appended - the laundering scenario is closed");
   }

   //=====================================================================
   // 3. Sanity: the SAME target (LIVE_SHADOW under LIVE) DOES succeed when
   //    the current state is itself valid - proves the block above is
   //    specific to the current-state check, not a blanket rejection of
   //    this target/environment pairing.
   //=====================================================================
   Print("--- sanity: LIVE_SHADOW target under LIVE succeeds when current stage IS valid (LIVE_MANUAL_MICRO_SIZE, a valid rollback source) ---");
   {
      string lines[1];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"LIVE_SHADOW\",\"to_stage\":\"LIVE_MANUAL_MICRO_SIZE\",\"environment_mode\":\"LIVE\"}";

      RolloutStageTransitionCommandResult result;
      RolloutStageTransitionCommand_Process(ROLLOUT_STAGE_LIVE_SHADOW, "qa_operator", "evidence_ref", lines, EXECUTION_ENV_LIVE, result);
      Check(result.status == ROLLOUT_STAGE_TRANSITION_CMD_TRANSITIONED, "status == TRANSITIONED (rollback, evidence-free)");
      Check(result.evaluation == ROLLOUT_TRANSITION_ALLOWED_ROLLBACK, "evaluation == ALLOWED_ROLLBACK");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == 1, "exactly one new durable line appended");
   }

   //=====================================================================
   // 4. Forward transition, §6.0 pair, valid current state -> TRANSITIONED.
   //=====================================================================
   Print("--- §6.0 NONE -> TEST_FIXTURE under ENV_TESTER, valid current state -> TRANSITIONED ---");
   {
      string emptyLines[]; // no prior transition -> current stage defaults to NONE, valid under every environment_mode
      RolloutStageTransitionCommandResult result;
      RolloutStageTransitionCommand_Process(ROLLOUT_STAGE_TEST_FIXTURE, "qa_operator", "ci_smoke_test", emptyLines, EXECUTION_ENV_TESTER, result);
      Check(result.status == ROLLOUT_STAGE_TRANSITION_CMD_TRANSITIONED, "status == TRANSITIONED");
      Check(result.current_stage == ROLLOUT_STAGE_NONE, "current_stage == NONE (default)");
      Check(result.evaluation == ROLLOUT_TRANSITION_ALLOWED_FORWARD, "evaluation == ALLOWED_FORWARD");
   }

   //=====================================================================
   // 5. Rejected forward transition (§6.2, criteria not frozen) - valid
   //    current state, valid target environment, still refused by Commit
   //    1's own evaluator - no durable write.
   //=====================================================================
   Print("--- §6.2 pair (criteria not frozen) -> REJECTED, no durable write ---");
   {
      string linesBefore[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesBefore);
      int countBefore = ArraySize(linesBefore);

      string lines[1];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"TEST_FIXTURE\",\"to_stage\":\"DEMO_DRY_RUN\",\"environment_mode\":\"DEMO\"}";
      RolloutStageTransitionCommandResult result;
      RolloutStageTransitionCommand_Process(ROLLOUT_STAGE_DEMO_REAL_SUBMIT, "qa_operator", "", lines, EXECUTION_ENV_DEMO, result);
      Check(result.status == ROLLOUT_STAGE_TRANSITION_CMD_REJECTED, "status == REJECTED");
      Check(result.evaluation == ROLLOUT_TRANSITION_REJECTED_CRITERIA_NOT_FROZEN, "evaluation == REJECTED_CRITERIA_NOT_FROZEN");
      Check(result.reason_code == "rejected_criteria_not_frozen", "reason_code == rejected_criteria_not_frozen (no double 'rejected_' prefix)");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == countBefore, "no new durable line appended for a rejected attempt");
   }

   //=====================================================================
   // 6. Durable write failure (EventStore closed) -> FAILED, Safe Mode trips.
   //=====================================================================
   Print("--- durable write failure -> FAILED, Safe Mode trips ---");
   {
      EventStore_Close();
      Check(!SafeMode_IsActive(), "sanity: Safe Mode not active before the write-failure attempt");

      string emptyLines[];
      RolloutStageTransitionCommandResult result;
      RolloutStageTransitionCommand_Process(ROLLOUT_STAGE_TEST_FIXTURE, "qa_operator", "", emptyLines, EXECUTION_ENV_TESTER, result);
      Check(result.evaluation == ROLLOUT_TRANSITION_ALLOWED_FORWARD, "sanity: this attempt WAS evaluated as ALLOWED_FORWARD");
      Check(result.status == ROLLOUT_STAGE_TRANSITION_CMD_FAILED, "status == FAILED (the durable append itself failed, store closed)");
      Check(SafeMode_IsActive(), "an ALLOWED transition whose durable write fails DOES trip Safe Mode");

      SafeMode_Clear();
      Check(EventStore_Open(TEST_EVENT_STORE_FILE), "cleanup: event store reopens");
   }

   EventStore_Close();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
