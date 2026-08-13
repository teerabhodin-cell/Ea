//+------------------------------------------------------------------+
//| MLQuantAI_Test_DummyLifecycle.mq5                                |
//| Phase A DoD #5: "create a dummy candidate and get a full          |
//| lifecycle event stream." Exercises the Event Store end to end -    |
//| SYSTEM_STARTED, candidate genesis, every legal transition shape,  |
//| every illegal transition being blocked - and prints a PASS/FAIL   |
//| summary. Run as a SCRIPT (drag onto any chart once), no backtest  |
//| needed.                                                            |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Core/MLQuantAI_Enums.mqh>
#include <MLQuantAI/Core/MLQuantAI_Ids.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStore.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

TradeCandidate MakeAndLogCandidate(string strategyTag, int strategyId, string eventType, double price)
{
   TradeCandidate c;
   TradeCandidate_Init(c);
   c.root_event_id = Ids_RootEventId(_Symbol, "M15", eventType, price, TimeCurrent(), _Digits);
   c.candidate_id  = Ids_CandidateId(c.root_event_id, strategyTag, "V1");
   c.strategy_id   = strategyId;
   c.strategy_name = StrategyIdToString(strategyId);
   c.signal_time   = TimeCurrent();
   EventStore_LogCandidateCreated(c);
   return c;
}

void OnStart()
{
   Print("=== MLQuantAI Test: Dummy Lifecycle (Phase A) ===");

   if(!EventStore_Open("MLQuantAI_Test_DummyLifecycle.jsonl"))
   {
      Print("Could not open the event store - aborting.");
      return;
   }
   EventStore_LogSystem("SYSTEM_STARTED", "dummy lifecycle test start");

   // ---- Deterministic ID check: same inputs -> same ids ----
   string root1 = Ids_RootEventId(_Symbol, "M15", "SWEEP_LOW", 3345.20, D'2026.08.14 09:30', 2);
   string root2 = Ids_RootEventId(_Symbol, "M15", "SWEEP_LOW", 3345.20, D'2026.08.14 09:30', 2);
   Check(root1 == root2 && root1 != "", "Ids_RootEventId is deterministic (same inputs -> same id)");

   string cnd1 = Ids_CandidateId(root1, "CRT", "V1");
   string cnd2 = Ids_CandidateId(root1, "CRT", "V1");
   string cnd3 = Ids_CandidateId(root1, "SMC", "V1");
   Check(cnd1 == cnd2 && cnd1 != cnd3, "Ids_CandidateId is deterministic and strategy-specific");

   // ---- Happy path: CREATED -> SUBMITTED -> EXECUTED ----
   TradeCandidate cHappy = MakeAndLogCandidate("TREND", STRAT_TREND, "PULLBACK", 3350.00);
   Check(cHappy.state == CANDIDATE_CREATED, "new candidate starts CREATED");

   bool okSubmit = EventStore_LogTransition(cHappy, CANDIDATE_SUBMITTED, REASON_SUBMITTED_OK);
   Check(okSubmit && cHappy.state == CANDIDATE_SUBMITTED, "CREATED -> SUBMITTED succeeds");

   cHappy.correlation_id = Ids_CorrelationId(cHappy.candidate_id);
   bool okExec = EventStore_LogTransition(cHappy, CANDIDATE_EXECUTED, REASON_EXECUTED_OK, "\"note\":\"self-test fill\"");
   Check(okExec && cHappy.state == CANDIDATE_EXECUTED, "SUBMITTED -> EXECUTED succeeds");
   Check(StateMachine_IsTerminal(cHappy.state), "EXECUTED is terminal");

   bool blockedBacktrack = EventStore_LogTransition(cHappy, CANDIDATE_CREATED, REASON_NONE);
   Check(!blockedBacktrack && cHappy.state == CANDIDATE_EXECUTED, "EXECUTED -> CREATED is BLOCKED, state unchanged");

   // ---- Rejected path ----
   TradeCandidate cRisk = MakeAndLogCandidate("CRT", STRAT_CRT, "SWEEP_LOW", 3345.20);
   bool okReject = EventStore_LogTransition(cRisk, CANDIDATE_REJECTED_BY_RISK, REASON_RISK_DAILY_LOSS_LIMIT);
   Check(okReject && cRisk.state == CANDIDATE_REJECTED_BY_RISK, "CREATED -> REJECTED_BY_RISK succeeds");

   bool blockedResubmit = EventStore_LogTransition(cRisk, CANDIDATE_SUBMITTED, REASON_NONE);
   Check(!blockedResubmit && cRisk.state == CANDIDATE_REJECTED_BY_RISK, "REJECTED_BY_RISK -> SUBMITTED is BLOCKED");

   // ---- ROUTED_OUT is a leaf ----
   TradeCandidate cRouted = MakeAndLogCandidate("SMC", STRAT_SMC, "SWEEP_LOW", 3345.20);
   bool okRoute = EventStore_LogTransition(cRouted, CANDIDATE_ROUTED_OUT, REASON_NONE);
   Check(okRoute && cRouted.state == CANDIDATE_ROUTED_OUT, "CREATED -> ROUTED_OUT succeeds");
   bool blockedRoutedSubmit = EventStore_LogTransition(cRouted, CANDIDATE_SUBMITTED, REASON_NONE);
   Check(!blockedRoutedSubmit && cRouted.state == CANDIDATE_ROUTED_OUT, "ROUTED_OUT -> SUBMITTED is BLOCKED");

   // ---- Explicit spec rule: MERGED -> SUBMITTED must never happen ----
   TradeCandidate cMerged = MakeAndLogCandidate("SMC", STRAT_SMC, "SWEEP_LOW", 3345.20);
   bool okMerge = EventStore_LogTransition(cMerged, CANDIDATE_MERGED, REASON_MERGED_INTO_OTHER);
   Check(okMerge && cMerged.state == CANDIDATE_MERGED, "CREATED -> MERGED succeeds");
   bool blockedMergedSubmit = EventStore_LogTransition(cMerged, CANDIDATE_SUBMITTED, REASON_NONE);
   Check(!blockedMergedSubmit && cMerged.state == CANDIDATE_MERGED, "MERGED -> SUBMITTED is BLOCKED (explicit spec rule)");

   EventStore_LogSystem("SYSTEM_STOPPED", "dummy lifecycle test end");
   EventStore_Close();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun)
      Print("ALL PASS. Wrote MLQuantAI_Test_DummyLifecycle.jsonl to Common\\Files.");
   else
      Print("FAILURES ABOVE - do not proceed to the next test until every check is PASS.");
}
