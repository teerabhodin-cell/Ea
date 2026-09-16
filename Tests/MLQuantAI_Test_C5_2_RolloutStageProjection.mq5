//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_RolloutStageProjection.mq5                      |
//| C5.2 Commit 1 (QA-frozen FINAL DESIGN FREEZE, Docs/PhaseC_C5_2_     |
//| ControlledExecutionEnvironmentLadderContract.md §4/§7.1): proves      |
//| RolloutStageProjection_ReplayCurrent / KillSwitchProjection_            |
//| ReplayActive / RolloutStageReplay_EstablishSessionState implement the    |
//| frozen "latest event wins", fail-closed-default, and OnInit-equivalent    |
//| rules exactly - including that the raw replayed stage is NEVER silently    |
//| rewritten when the cross-validity check fails. Pure function only, no        |
//| real EventStore file, no OrderSend - running on a real account is safe.        |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RolloutStageProjection.mqh>

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
   Print("=== MLQuantAI_Test_C5_2_RolloutStageProjection.mq5 ===");

   //=====================================================================
   // 1. RolloutStageProjection_ReplayCurrent: empty log -> NONE, not found.
   //=====================================================================
   Print("--- ReplayCurrent: empty log -> ROLLOUT_STAGE_NONE, found == false ---");
   {
      string emptyLines[];
      ENUM_EXECUTION_ROLLOUT_STAGE stage;
      bool found = RolloutStageProjection_ReplayCurrent(emptyLines, stage);
      Check(found == false, "found == false for an empty log");
      Check(stage == ROLLOUT_STAGE_NONE, "defaults to ROLLOUT_STAGE_NONE (§4 rule 4 fail-closed default)");
   }

   //=====================================================================
   // 2. Single transition line -> found, correct to_stage.
   //=====================================================================
   Print("--- ReplayCurrent: one transition line -> its to_stage ---");
   {
      string lines[1];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"NONE\",\"to_stage\":\"TEST_FIXTURE\",\"environment_mode\":\"TESTER\"}";
      ENUM_EXECUTION_ROLLOUT_STAGE stage;
      bool found = RolloutStageProjection_ReplayCurrent(lines, stage);
      Check(found == true, "found == true");
      Check(stage == ROLLOUT_STAGE_TEST_FIXTURE, "stage == TEST_FIXTURE");
   }

   //=====================================================================
   // 3. Multiple transition lines - the LATEST (last in file order) wins,
   //    never the first.
   //=====================================================================
   Print("--- ReplayCurrent: multiple lines -> the LAST one in file order wins ---");
   {
      string lines[3];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"NONE\",\"to_stage\":\"TEST_FIXTURE\",\"environment_mode\":\"TESTER\"}";
      lines[1] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"TEST_FIXTURE\",\"to_stage\":\"DEMO_DRY_RUN\",\"environment_mode\":\"DEMO\"}";
      lines[2] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"DEMO_DRY_RUN\",\"to_stage\":\"TEST_FIXTURE\",\"environment_mode\":\"DEMO\"}"; // rollback, appears last
      ENUM_EXECUTION_ROLLOUT_STAGE stage;
      bool found = RolloutStageProjection_ReplayCurrent(lines, stage);
      Check(found == true, "found == true");
      Check(stage == ROLLOUT_STAGE_TEST_FIXTURE, "stage == TEST_FIXTURE (the LAST line's to_stage, not DEMO_DRY_RUN from line 2)");
   }

   //=====================================================================
   // 4. Unrelated event types in the log are ignored.
   //=====================================================================
   Print("--- ReplayCurrent: unrelated event types are ignored ---");
   {
      string lines[3];
      lines[0] = "{\"type\":\"SAFE_MODE_ENGAGED\"}";
      lines[1] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"NONE\",\"to_stage\":\"TEST_FIXTURE\",\"environment_mode\":\"TESTER\"}";
      lines[2] = "{\"type\":\"KILL_SWITCH_ENGAGED\",\"environment_mode\":\"TESTER\"}";
      ENUM_EXECUTION_ROLLOUT_STAGE stage;
      bool found = RolloutStageProjection_ReplayCurrent(lines, stage);
      Check(found == true, "found == true (still finds the one real transition line)");
      Check(stage == ROLLOUT_STAGE_TEST_FIXTURE, "stage == TEST_FIXTURE, unaffected by the surrounding unrelated lines");
   }

   //=====================================================================
   // 5. KillSwitchProjection_ReplayActive: empty log -> not active, not found.
   //=====================================================================
   Print("--- KillSwitchProjection_ReplayActive: empty log -> false, found == false ---");
   {
      string emptyLines[];
      bool active;
      bool found = KillSwitchProjection_ReplayActive(emptyLines, EXECUTION_ENV_DEMO, active);
      Check(found == false, "found == false");
      Check(active == false, "active == false (never auto-engaged)");
   }

   //=====================================================================
   // 6. ENGAGED only -> active.
   //=====================================================================
   Print("--- KillSwitchProjection_ReplayActive: ENGAGED only -> active == true ---");
   {
      string lines[1];
      lines[0] = "{\"type\":\"KILL_SWITCH_ENGAGED\",\"environment_mode\":\"DEMO\"}";
      bool active;
      bool found = KillSwitchProjection_ReplayActive(lines, EXECUTION_ENV_DEMO, active);
      Check(found == true, "found == true");
      Check(active == true, "active == true");
   }

   //=====================================================================
   // 7. ENGAGED then CLEARED (same environment_mode, in that file order) ->
   //    the later CLEARED wins -> not active.
   //=====================================================================
   Print("--- KillSwitchProjection_ReplayActive: ENGAGED then CLEARED -> the later CLEARED wins -> active == false ---");
   {
      string lines[2];
      lines[0] = "{\"type\":\"KILL_SWITCH_ENGAGED\",\"environment_mode\":\"DEMO\"}";
      lines[1] = "{\"type\":\"KILL_SWITCH_CLEARED\",\"environment_mode\":\"DEMO\"}";
      bool active;
      bool found = KillSwitchProjection_ReplayActive(lines, EXECUTION_ENV_DEMO, active);
      Check(found == true, "found == true");
      Check(active == false, "active == false (CLEARED is the later, and therefore authoritative, event)");
   }

   //=====================================================================
   // 8. CLEARED then ENGAGED -> the later ENGAGED wins -> active.
   //=====================================================================
   Print("--- KillSwitchProjection_ReplayActive: CLEARED then ENGAGED -> the later ENGAGED wins -> active == true ---");
   {
      string lines[2];
      lines[0] = "{\"type\":\"KILL_SWITCH_CLEARED\",\"environment_mode\":\"DEMO\"}";
      lines[1] = "{\"type\":\"KILL_SWITCH_ENGAGED\",\"environment_mode\":\"DEMO\"}";
      bool active;
      bool found = KillSwitchProjection_ReplayActive(lines, EXECUTION_ENV_DEMO, active);
      Check(found == true, "found == true");
      Check(active == true, "active == true");
   }

   //=====================================================================
   // 9. Scoping (§7 Scope, frozen): an ENGAGED event for one
   //    environment_mode must NEVER be read as active for a DIFFERENT
   //    environment_mode - never implicitly "all".
   //=====================================================================
   Print("--- KillSwitchProjection_ReplayActive: scoped to ONE environment_mode, never implicitly \"all\" ---");
   {
      string lines[1];
      lines[0] = "{\"type\":\"KILL_SWITCH_ENGAGED\",\"environment_mode\":\"DEMO\"}";
      bool activeDemo;
      bool foundDemo = KillSwitchProjection_ReplayActive(lines, EXECUTION_ENV_DEMO, activeDemo);
      Check(foundDemo == true && activeDemo == true, "queried for DEMO (the engaged mode) -> found, active");

      bool activeLive;
      bool foundLive = KillSwitchProjection_ReplayActive(lines, EXECUTION_ENV_LIVE, activeLive);
      Check(foundLive == false, "queried for LIVE (a DIFFERENT mode) -> not found");
      Check(activeLive == false, "queried for LIVE -> active == false, unaffected by DEMO's kill switch");
   }

   //=====================================================================
   // 10. RolloutStageReplay_EstablishSessionState - the composed "OnInit-
   //     equivalent" function (§4 rule 5's frozen pseudocode).
   //=====================================================================
   Print("--- EstablishSessionState: raw replayed_stage is preserved even when environment_valid == false ---");
   {
      // DEMO_REAL_SUBMIT was durably recorded (valid for DEMO at the
      // time), but the SUPPLIED environmentMode is now LIVE - QA's exact
      // stale-stage scenario from the revision-2 CONDITIONAL APPROVAL.
      string lines[1];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"DEMO_DRY_RUN\",\"to_stage\":\"DEMO_REAL_SUBMIT\",\"environment_mode\":\"DEMO\"}";

      RolloutStageSessionState state;
      RolloutStageReplay_EstablishSessionState(lines, EXECUTION_ENV_LIVE, state);

      Check(state.replayed_stage == ROLLOUT_STAGE_DEMO_REAL_SUBMIT,
            "replayed_stage still reports the REAL durably-replayed value (DEMO_REAL_SUBMIT) - never silently rewritten to NONE");
      Check(state.environment_valid == false,
            "environment_valid == false - the pairing is a `reject` cell for the real, fresh environmentMode (LIVE)");
      Check(state.kill_switch_active == false, "kill_switch_active == false (no kill switch event in this log)");
   }

   Print("--- EstablishSessionState: matching environment_mode -> environment_valid == true ---");
   {
      string lines[1];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"from_stage\":\"DEMO_DRY_RUN\",\"to_stage\":\"DEMO_REAL_SUBMIT\",\"environment_mode\":\"DEMO\"}";

      RolloutStageSessionState state;
      RolloutStageReplay_EstablishSessionState(lines, EXECUTION_ENV_DEMO, state);

      Check(state.replayed_stage == ROLLOUT_STAGE_DEMO_REAL_SUBMIT, "replayed_stage == DEMO_REAL_SUBMIT");
      Check(state.environment_valid == true, "environment_valid == true (matches the real environmentMode, DEMO)");
   }

   Print("--- EstablishSessionState: no prior transition at all -> NONE, environment_valid == true, no kill switch ---");
   {
      string emptyLines[];
      RolloutStageSessionState state;
      RolloutStageReplay_EstablishSessionState(emptyLines, EXECUTION_ENV_LIVE, state);

      Check(state.replayed_stage == ROLLOUT_STAGE_NONE, "replayed_stage defaults to NONE");
      Check(state.environment_valid == true, "environment_valid == true (NONE is valid under every environment_mode)");
      Check(state.kill_switch_active == false, "kill_switch_active == false");
   }

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
