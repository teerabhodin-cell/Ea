//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Section6_2_RolloutStageObservationWindow.mq5   |
//| §6.2 Evidence-Gate Design Contract Rev.8 §1: pure unit coverage of  |
//| RolloutStageObservationWindow_FindStart() - "latest wins" scan for   |
//| the LAST EXECUTION_ROLLOUT_STAGE_CHANGED line whose own to_stage        |
//| equals the queried stage. No EventStore file needed - lines[] is        |
//| entirely hand-built. No OrderSend/CTrade anywhere in this file.           |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RolloutStageObservationWindow.mqh>

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
   Print("=== MLQuantAI_Test_C5_2_Section6_2_RolloutStageObservationWindow.mq5 ===");

   //=====================================================================
   Print("--- empty lines[] -> not found ---");
   {
      string lines[]; ArrayResize(lines, 0);
      int idx;
      bool found = RolloutStageObservationWindow_FindStart(lines, ROLLOUT_STAGE_DEMO_DRY_RUN, idx);
      Check(!found, "found == false");
      Check(idx == -1, "outLineIndex == -1");
   }

   //=====================================================================
   Print("--- no matching to_stage anywhere -> not found ---");
   {
      string lines[2];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"to_stage\":\"TEST_FIXTURE\"}";
      lines[1] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"to_stage\":\"DEMO_REAL_SUBMIT\"}";
      int idx;
      bool found = RolloutStageObservationWindow_FindStart(lines, ROLLOUT_STAGE_DEMO_DRY_RUN, idx);
      Check(!found, "found == false - DEMO_DRY_RUN never appears as a to_stage");
      Check(idx == -1, "outLineIndex == -1");
   }

   //=====================================================================
   Print("--- exactly one matching line -> found at its own index ---");
   {
      string lines[3];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"to_stage\":\"TEST_FIXTURE\"}";
      lines[1] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"to_stage\":\"DEMO_DRY_RUN\"}";
      lines[2] = "{\"type\":\"CANDIDATE_CREATED\",\"candidate_id\":\"X\"}";
      int idx;
      bool found = RolloutStageObservationWindow_FindStart(lines, ROLLOUT_STAGE_DEMO_DRY_RUN, idx);
      Check(found, "found == true");
      Check(idx == 1, "outLineIndex == 1");
   }

   //=====================================================================
   Print("--- multiple matching lines -> LATEST one wins, not the first ---");
   {
      string lines[5];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"to_stage\":\"DEMO_DRY_RUN\"}"; // earliest entry - must NOT win
      lines[1] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"to_stage\":\"DEMO_REAL_SUBMIT\"}"; // rollback away
      lines[2] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"to_stage\":\"DEMO_DRY_RUN\"}"; // re-entry
      lines[3] = "{\"type\":\"CANDIDATE_CREATED\",\"candidate_id\":\"X\"}";
      lines[4] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"to_stage\":\"DEMO_DRY_RUN\"}"; // latest - must win
      int idx;
      bool found = RolloutStageObservationWindow_FindStart(lines, ROLLOUT_STAGE_DEMO_DRY_RUN, idx);
      Check(found, "found == true");
      Check(idx == 4, "outLineIndex == 4 (the LATEST matching line), not 0 or 2");
   }

   //=====================================================================
   Print("--- a line with the right to_stage but a DIFFERENT type is ignored ---");
   {
      string lines[2];
      lines[0] = "{\"type\":\"SOME_OTHER_EVENT\",\"to_stage\":\"DEMO_DRY_RUN\"}";
      lines[1] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"to_stage\":\"DEMO_DRY_RUN\"}";
      int idx;
      bool found = RolloutStageObservationWindow_FindStart(lines, ROLLOUT_STAGE_DEMO_DRY_RUN, idx);
      Check(found, "found == true");
      Check(idx == 1, "outLineIndex == 1 - the wrong-type line at index 0 is never matched");
   }

   //=====================================================================
   Print("--- querying a DIFFERENT stage than what's present -> not found, independent of other stages' own lines ---");
   {
      string lines[1];
      lines[0] = "{\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"to_stage\":\"DEMO_DRY_RUN\"}";
      int idx;
      bool found = RolloutStageObservationWindow_FindStart(lines, ROLLOUT_STAGE_DEMO_REAL_SUBMIT, idx);
      Check(!found, "found == false - querying DEMO_REAL_SUBMIT while only a DEMO_DRY_RUN line exists");
      Check(idx == -1, "outLineIndex == -1");
   }

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
