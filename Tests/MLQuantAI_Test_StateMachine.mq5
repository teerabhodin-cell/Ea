//+------------------------------------------------------------------+
//| MLQuantAI_Test_StateMachine.mq5                                  |
//| Phase A Step 8 requires a standalone StateMachineTest (previously |
//| this coverage only existed embedded inside                        |
//| MLQuantAI_Test_DummyLifecycle.mq5). Pure unit test of              |
//| StateMachine_CanTransition() directly - no Event Store, no file    |
//| I/O, just the transition table itself. Covers every pair the      |
//| plan lists explicitly plus the full CREATED/SUBMITTED branch and  |
//| every terminal state's "nothing gets out" guarantee.               |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Core/MLQuantAI_StateMachine.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void CheckTransition(ENUM_CANDIDATE_STATE from, ENUM_CANDIDATE_STATE to, bool expected)
{
   bool actual = StateMachine_CanTransition(from, to);
   Check(actual == expected, StringFormat("%s -> %s == %s",
         CandidateStateToString(from), CandidateStateToString(to), expected ? "true" : "false"));
}

void OnStart()
{
   Print("=== MLQuantAI Test: State Machine (Phase A) ===");

   // ---- Explicit pairs from the plan ----
   CheckTransition(CANDIDATE_CREATED,          CANDIDATE_SUBMITTED, true);
   CheckTransition(CANDIDATE_SUBMITTED,        CANDIDATE_EXECUTED,  true);
   CheckTransition(CANDIDATE_EXECUTED,         CANDIDATE_CREATED,   false);
   CheckTransition(CANDIDATE_MERGED,           CANDIDATE_SUBMITTED, false);
   CheckTransition(CANDIDATE_REJECTED_BY_RISK, CANDIDATE_EXECUTED,  false);
   CheckTransition(CANDIDATE_EXPIRED,          CANDIDATE_SUBMITTED, false);

   // ---- Every legal branch out of CREATED ----
   CheckTransition(CANDIDATE_CREATED, CANDIDATE_ROUTED_OUT,             true);
   CheckTransition(CANDIDATE_CREATED, CANDIDATE_MERGED,                 true);
   CheckTransition(CANDIDATE_CREATED, CANDIDATE_REJECTED_BY_ARBITRATOR, true);
   CheckTransition(CANDIDATE_CREATED, CANDIDATE_REJECTED_BY_AI,         true);
   CheckTransition(CANDIDATE_CREATED, CANDIDATE_REJECTED_BY_RISK,       true);
   CheckTransition(CANDIDATE_CREATED, CANDIDATE_EXPIRED,                true);
   CheckTransition(CANDIDATE_CREATED, CANDIDATE_SUBMITTED,              true);
   // CREATED must never jump straight to a SUBMITTED-only child
   CheckTransition(CANDIDATE_CREATED, CANDIDATE_EXECUTED,               false);
   CheckTransition(CANDIDATE_CREATED, CANDIDATE_REJECTED_BY_BROKER,     false);
   CheckTransition(CANDIDATE_CREATED, CANDIDATE_ERROR,                  false);

   // ---- Every legal branch out of SUBMITTED ----
   CheckTransition(CANDIDATE_SUBMITTED, CANDIDATE_EXECUTED,          true);
   CheckTransition(CANDIDATE_SUBMITTED, CANDIDATE_REJECTED_BY_BROKER, true);
   CheckTransition(CANDIDATE_SUBMITTED, CANDIDATE_ERROR,              true);
   // SUBMITTED must never jump to a CREATED-only child
   CheckTransition(CANDIDATE_SUBMITTED, CANDIDATE_ROUTED_OUT, false);
   CheckTransition(CANDIDATE_SUBMITTED, CANDIDATE_MERGED,     false);
   CheckTransition(CANDIDATE_SUBMITTED, CANDIDATE_EXPIRED,    false);
   CheckTransition(CANDIDATE_SUBMITTED, CANDIDATE_CREATED,    false);

   // ---- Every terminal state: NOTHING gets out, not even to itself ----
   ENUM_CANDIDATE_STATE terminals[9] = {
      CANDIDATE_ROUTED_OUT, CANDIDATE_MERGED, CANDIDATE_REJECTED_BY_ARBITRATOR,
      CANDIDATE_REJECTED_BY_AI, CANDIDATE_REJECTED_BY_RISK, CANDIDATE_EXPIRED,
      CANDIDATE_EXECUTED, CANDIDATE_REJECTED_BY_BROKER, CANDIDATE_ERROR
   };
   ENUM_CANDIDATE_STATE targets[3] = { CANDIDATE_CREATED, CANDIDATE_SUBMITTED, CANDIDATE_EXECUTED };

   for(int i = 0; i < 9; i++)
   {
      Check(StateMachine_IsTerminal(terminals[i]), CandidateStateToString(terminals[i]) + " is terminal");
      for(int j = 0; j < 3; j++)
         CheckTransition(terminals[i], targets[j], false);
   }

   // ---- CREATED and SUBMITTED are the only non-terminal states ----
   Check(!StateMachine_IsTerminal(CANDIDATE_CREATED),   "CREATED is NOT terminal");
   Check(!StateMachine_IsTerminal(CANDIDATE_SUBMITTED), "SUBMITTED is NOT terminal");

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   Print(g_TestsPassed == g_TestsRun ? "ALL PASS." : "FAILURES ABOVE.");
}
