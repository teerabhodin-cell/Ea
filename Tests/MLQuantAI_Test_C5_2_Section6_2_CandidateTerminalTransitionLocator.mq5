//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Section6_2_CandidateTerminalTransitionLocator.mq5|
//| §6.2 Evidence-Gate Design Contract Rev.8 §2/P3: pure unit coverage of |
//| CandidateTerminalTransition_FindLineIndex() - the tri-state (FOUND_ONE/|
//| NOT_LOCATED/AMBIGUOUS) locator that returns a matching line's own ARRAY  |
//| INDEX, never a durable sequence_number (QA-ratified rename/semantics,     |
//| this checkpoint's Diff Review round). No EventStore file needed - lines[]  |
//| is entirely hand-built. No OrderSend/CTrade anywhere in this file.          |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CandidateTerminalTransitionLocator.mqh>

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
   Print("=== MLQuantAI_Test_C5_2_Section6_2_CandidateTerminalTransitionLocator.mq5 ===");

   //=====================================================================
   Print("--- candidate never appears at all -> NOT_LOCATED ---");
   {
      string lines[]; ArrayResize(lines, 0);
      int idx;
      ENUM_TERMINAL_TRANSITION_LOCATE_RESULT r = CandidateTerminalTransition_FindLineIndex(lines, "CAND_X", idx);
      Check(r == TERMINAL_TRANSITION_NOT_LOCATED, "result == NOT_LOCATED");
      Check(idx == -1, "outLineIndex == -1 on NOT_LOCATED");
   }

   //=====================================================================
   Print("--- candidate exists but never reaches a terminal state -> NOT_LOCATED ---");
   {
      string lines[2];
      lines[0] = "{\"candidate_id\":\"CAND_X\",\"to_state\":\"CREATED\"}";
      lines[1] = "{\"candidate_id\":\"CAND_X\",\"to_state\":\"SUBMITTED\"}"; // non-terminal
      int idx;
      ENUM_TERMINAL_TRANSITION_LOCATE_RESULT r = CandidateTerminalTransition_FindLineIndex(lines, "CAND_X", idx);
      Check(r == TERMINAL_TRANSITION_NOT_LOCATED, "result == NOT_LOCATED - SUBMITTED is not terminal");
      Check(idx == -1, "outLineIndex == -1");
   }

   //=====================================================================
   Print("--- exactly one terminal transition -> FOUND_ONE at its own array index ---");
   {
      string lines[3];
      lines[0] = "{\"candidate_id\":\"CAND_X\",\"to_state\":\"CREATED\"}";
      lines[1] = "{\"candidate_id\":\"CAND_X\",\"to_state\":\"SUBMITTED\"}";
      lines[2] = "{\"candidate_id\":\"CAND_X\",\"to_state\":\"EXECUTED\"}";
      int idx;
      ENUM_TERMINAL_TRANSITION_LOCATE_RESULT r = CandidateTerminalTransition_FindLineIndex(lines, "CAND_X", idx);
      Check(r == TERMINAL_TRANSITION_FOUND_ONE, "result == FOUND_ONE");
      Check(idx == 2, "outLineIndex == 2 (the array index, matching this snapshot's own position)");
   }

   //=====================================================================
   Print("--- a DIFFERENT candidate_id's terminal line must not match ---");
   {
      string lines[2];
      lines[0] = "{\"candidate_id\":\"CAND_OTHER\",\"to_state\":\"EXECUTED\"}";
      lines[1] = "{\"candidate_id\":\"CAND_X\",\"to_state\":\"SUBMITTED\"}";
      int idx;
      ENUM_TERMINAL_TRANSITION_LOCATE_RESULT r = CandidateTerminalTransition_FindLineIndex(lines, "CAND_X", idx);
      Check(r == TERMINAL_TRANSITION_NOT_LOCATED, "result == NOT_LOCATED - CAND_X itself never reaches terminal, CAND_OTHER's line is irrelevant");
   }

   //=====================================================================
   Print("--- more than one terminal transition for the SAME candidate_id -> AMBIGUOUS, never first/latest ---");
   {
      string lines[3];
      lines[0] = "{\"candidate_id\":\"CAND_X\",\"to_state\":\"REJECTED_BY_BROKER\"}"; // anomaly: two terminal lines
      lines[1] = "{\"candidate_id\":\"CAND_Y\",\"to_state\":\"EXECUTED\"}";
      lines[2] = "{\"candidate_id\":\"CAND_X\",\"to_state\":\"ERROR\"}";
      int idx;
      ENUM_TERMINAL_TRANSITION_LOCATE_RESULT r = CandidateTerminalTransition_FindLineIndex(lines, "CAND_X", idx);
      Check(r == TERMINAL_TRANSITION_AMBIGUOUS, "result == AMBIGUOUS");
      Check(idx == -1, "outLineIndex == -1 on AMBIGUOUS - never defaults to the first or the latest match");
   }

   //=====================================================================
   Print("--- a line missing 'to_state' or 'candidate_id' entirely is structurally skipped, not misread ---");
   {
      string lines[3];
      lines[0] = "{\"candidate_id\":\"CAND_X\"}";               // no to_state at all
      lines[1] = "{\"to_state\":\"EXECUTED\"}";                  // no candidate_id at all
      lines[2] = "{\"candidate_id\":\"CAND_X\",\"to_state\":\"EXECUTED\"}"; // the one real match
      int idx;
      ENUM_TERMINAL_TRANSITION_LOCATE_RESULT r = CandidateTerminalTransition_FindLineIndex(lines, "CAND_X", idx);
      Check(r == TERMINAL_TRANSITION_FOUND_ONE, "result == FOUND_ONE - the two structurally incomplete lines are skipped, not counted");
      Check(idx == 2, "outLineIndex == 2");
   }

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
