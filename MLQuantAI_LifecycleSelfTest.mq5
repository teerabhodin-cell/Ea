//+------------------------------------------------------------------+
//| MLQuantAI_LifecycleSelfTest.mq5                                  |
//| Sprint 1 deliverable: "dummy candidate lifecycle test".           |
//|                                                                    |
//| This is a SCRIPT (not an EA) - drag it onto any chart once, no    |
//| backtest needed, and read the Experts log for the PASS/FAIL       |
//| summary. It proves the state machine + ID generator + append-only |
//| event logger actually work together correctly BEFORE any real     |
//| strategy module exists to depend on them:                         |
//|   - IDs are unique per candidate                                  |
//|   - legal transitions succeed and get logged                      |
//|   - illegal transitions (EXECUTED->CREATED, MERGED->SUBMITTED,    |
//|     any transition out of a terminal state) are BLOCKED and the   |
//|     candidate's state is left untouched                           |
//|   - every legal transition produces one JSONL line in             |
//|     Common\Files\MLQuantAI_LifecycleSelfTest.jsonl                |
//|                                                                    |
//| Install: copy Include/MLQuantAI/ into MQL5/Include/MLQuantAI/,    |
//| copy this file into MQL5/Scripts/, then run it from the Navigator.|
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Core/MLQuantAI_Enums.mqh>
#include <MLQuantAI/Core/MLQuantAI_StateMachine.mqh>
#include <MLQuantAI/Core/MLQuantAI_ReasonCodes.mqh>
#include <MLQuantAI/Core/MLQuantAI_TradeCandidate.mqh>
#include <MLQuantAI/Core/MLQuantAI_Ids.mqh>
#include <MLQuantAI/Logging/MLQuantAI_SystemLogger.mqh>
#include <MLQuantAI/Logging/MLQuantAI_EventLogger.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

TradeCandidate MakeCandidate(string strategyTag, int strategyId)
{
   TradeCandidate c;
   TradeCandidate_Init(c);
   c.candidate_id   = Ids_NewCandidateId(strategyTag);
   c.root_event_id  = Ids_NewRootEventId();
   c.strategy_id    = strategyId;
   c.strategy_name  = StrategyIdToString(strategyId);
   c.signal_time    = TimeCurrent();
   return c;
}

void OnStart()
{
   Print("=== MLQuantAI Lifecycle Self-Test (Sprint 1) ===");

   if(!EventLogger_Open("MLQuantAI_LifecycleSelfTest.jsonl"))
   {
      Print("Could not open the event log file - aborting self-test.");
      return;
   }

   // ---- Happy path: CREATED -> SUBMITTED -> EXECUTED ----
   TradeCandidate cHappy = MakeCandidate("TREND", STRAT_TREND);
   Check(cHappy.state == CANDIDATE_CREATED, "new candidate starts CREATED");

   bool okSubmit = EventLogger_LogTransition(cHappy, CANDIDATE_SUBMITTED, REASON_SUBMITTED_OK);
   Check(okSubmit && cHappy.state == CANDIDATE_SUBMITTED, "CREATED -> SUBMITTED succeeds");

   cHappy.correlation_id = Ids_NewCorrelationId();
   bool okExec = EventLogger_LogTransition(cHappy, CANDIDATE_EXECUTED, REASON_EXECUTED_OK,
                                            "\"note\":\"self-test fill\"");
   Check(okExec && cHappy.state == CANDIDATE_EXECUTED, "SUBMITTED -> EXECUTED succeeds");
   Check(StateMachine_IsTerminal(cHappy.state), "EXECUTED is terminal");

   bool blockedBacktrack = EventLogger_LogTransition(cHappy, CANDIDATE_CREATED, REASON_NONE);
   Check(!blockedBacktrack && cHappy.state == CANDIDATE_EXECUTED,
         "EXECUTED -> CREATED is BLOCKED, state unchanged");

   // ---- Rejected path: CREATED -> REJECTED_BY_RISK ----
   TradeCandidate cRisk = MakeCandidate("CRT", STRAT_CRT);
   bool okReject = EventLogger_LogTransition(cRisk, CANDIDATE_REJECTED_BY_RISK, REASON_RISK_DAILY_LOSS_LIMIT);
   Check(okReject && cRisk.state == CANDIDATE_REJECTED_BY_RISK, "CREATED -> REJECTED_BY_RISK succeeds");

   bool blockedResubmit = EventLogger_LogTransition(cRisk, CANDIDATE_SUBMITTED, REASON_NONE);
   Check(!blockedResubmit && cRisk.state == CANDIDATE_REJECTED_BY_RISK,
         "REJECTED_BY_RISK -> SUBMITTED is BLOCKED, state unchanged");

   // ---- ROUTED_OUT is a leaf: no transition out of it is legal ----
   TradeCandidate cRouted = MakeCandidate("SMC", STRAT_SMC);
   bool okRoute = EventLogger_LogTransition(cRouted, CANDIDATE_ROUTED_OUT, REASON_NONE);
   Check(okRoute && cRouted.state == CANDIDATE_ROUTED_OUT, "CREATED -> ROUTED_OUT succeeds");

   bool blockedRoutedSubmit = EventLogger_LogTransition(cRouted, CANDIDATE_SUBMITTED, REASON_NONE);
   Check(!blockedRoutedSubmit && cRouted.state == CANDIDATE_ROUTED_OUT,
         "ROUTED_OUT -> SUBMITTED is BLOCKED, state unchanged");

   // ---- Explicit spec rule: MERGED -> SUBMITTED must never happen ----
   TradeCandidate cMerged = MakeCandidate("SMC", STRAT_SMC);
   bool okMerge = EventLogger_LogTransition(cMerged, CANDIDATE_MERGED, REASON_MERGED_INTO_OTHER);
   Check(okMerge && cMerged.state == CANDIDATE_MERGED, "CREATED -> MERGED succeeds");

   bool blockedMergedSubmit = EventLogger_LogTransition(cMerged, CANDIDATE_SUBMITTED, REASON_NONE);
   Check(!blockedMergedSubmit && cMerged.state == CANDIDATE_MERGED,
         "MERGED -> SUBMITTED is BLOCKED, state unchanged (explicit spec rule)");

   // ---- IDs must be unique across every candidate created above ----
   bool idsUnique =
      cHappy.candidate_id  != cRisk.candidate_id  &&
      cHappy.candidate_id  != cRouted.candidate_id &&
      cHappy.candidate_id  != cMerged.candidate_id &&
      cRisk.candidate_id   != cRouted.candidate_id &&
      cRisk.candidate_id   != cMerged.candidate_id &&
      cRouted.candidate_id != cMerged.candidate_id;
   Check(idsUnique, "candidate_id is unique per candidate");

   bool rootEventsUnique =
      cHappy.root_event_id != cRisk.root_event_id &&
      cHappy.root_event_id != cRouted.root_event_id &&
      cHappy.root_event_id != cMerged.root_event_id;
   Check(rootEventsUnique, "root_event_id is unique per candidate (none shared an event here)");

   // ---- JSON line sanity check ----
   string sample = EventLogger_JsonLine("CND_X_000001", "EVT_X_000001", "", CANDIDATE_CREATED,
                                         CANDIDATE_SUBMITTED, REASON_SUBMITTED_OK, STRAT_TREND, "");
   Check(StringFind(sample, "\"candidate_id\":\"CND_X_000001\"") >= 0, "JSON line contains candidate_id");
   Check(StringFind(sample, "\"from_state\":\"CREATED\"") >= 0, "JSON line contains from_state");
   Check(StringFind(sample, "\"to_state\":\"SUBMITTED\"") >= 0, "JSON line contains to_state");

   EventLogger_Close();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun)
      Print("ALL PASS - state machine, ID generator and event logger are working correctly.");
   else
      Print("FAILURES ABOVE - do not build Sprint 2 on top of this until every check is PASS.");
   Print("Wrote MLQuantAI_LifecycleSelfTest.jsonl to Common\\Files - open it to see the real lifecycle lines.");
}
