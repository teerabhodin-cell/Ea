//+------------------------------------------------------------------+
//| MLQuantAI_Test_BrokerReconciliation.mq5                          |
//| Phase A DoD #10: "replay state compared against MT5 broker        |
//| state."                                                             |
//|                                                                    |
//| IMPORTANT SCOPE NOTE: Phase A has no Execution Engine yet (that's |
//| Phase B/Sprint 3) - nothing in this codebase submits real orders  |
//| tagged with a correlation_id, so there is no real MT5 position to |
//| reconcile against today. This test instead proves the             |
//| RECONCILIATION CONTRACT is correct using a simulated broker state |
//| (a plain array standing in for "what MT5's position list would    |
//| return"), so the matching logic is validated now and can be       |
//| pointed at PositionsTotal()/PositionGetString(POSITION_COMMENT)   |
//| directly once the Execution Engine exists and tags real orders    |
//| with correlation_id in the position comment (the standard MT5     |
//| pattern for carrying an external reference through to a fill).    |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Core/MLQuantAI_Enums.mqh>
#include <MLQuantAI/Core/MLQuantAI_Ids.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStore.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh>

#define TEST_FILE "MLQuantAI_Test_BrokerReconciliation.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

// Stands in for one MT5 position. In Phase B, the Execution Engine's
// order comment is expected to BE the correlation_id (or contain it),
// exactly mirroring how this mock is shaped.
struct MockBrokerPosition
{
   ulong    ticket;
   string   comment; // real broker position comment - expected to carry correlation_id
   double   volume;
};

// The actual reconciliation logic under test: does a broker position
// exist whose comment carries this correlation_id? This exact function
// signature is what Phase B's OnTradeTransaction reconciliation should
// call, just backed by PositionsTotal()/PositionGetTicket()/
// PositionGetString(POSITION_COMMENT) instead of a mock array.
bool Reconcile_HasMatchingPosition(string correlationId, const MockBrokerPosition &positions[])
{
   if(correlationId == "") return false;
   for(int i = 0; i < ArraySize(positions); i++)
      if(StringFind(positions[i].comment, correlationId) >= 0)
         return true;
   return false;
}

void OnStart()
{
   Print("=== MLQuantAI Test: Broker Reconciliation contract (Phase A, simulated broker state) ===");

   FileDelete(TEST_FILE, FILE_COMMON); // isolation: start every run from a clean file

   // ---- Build a small replayed state: one EXECUTED candidate, one REJECTED ----
   if(!EventStore_Open(TEST_FILE))
   {
      Print("Could not open the event store - aborting.");
      return;
   }

   TradeCandidate cExecuted;
   TradeCandidate_Init(cExecuted);
   cExecuted.root_event_id = Ids_RootEventId(_Symbol, "M15", "RECON_TEST", 3350.00, TimeCurrent(), _Digits);
   cExecuted.candidate_id  = Ids_CandidateId(cExecuted.root_event_id, "TREND", "V1");
   cExecuted.strategy_id   = STRAT_TREND;
   EventStore_LogCandidateCreated(cExecuted);
   EventStore_LogTransition(cExecuted, CANDIDATE_SUBMITTED, REASON_SUBMITTED_OK);
   cExecuted.correlation_id = Ids_CorrelationId(cExecuted.candidate_id);
   EventStore_LogTransition(cExecuted, CANDIDATE_EXECUTED, REASON_EXECUTED_OK);

   TradeCandidate cRejected;
   TradeCandidate_Init(cRejected);
   cRejected.root_event_id = Ids_RootEventId(_Symbol, "M15", "RECON_TEST_2", 3355.00, TimeCurrent(), _Digits);
   cRejected.candidate_id  = Ids_CandidateId(cRejected.root_event_id, "CRT", "V1");
   cRejected.strategy_id   = STRAT_CRT;
   EventStore_LogCandidateCreated(cRejected);
   EventStore_LogTransition(cRejected, CANDIDATE_REJECTED_BY_RISK, REASON_RISK_DAILY_LOSS_LIMIT);

   EventStore_Close();

   ReplayReport rr = ReplayEngine_Run(TEST_FILE);
   Check(rr.ok, "replay of the reconciliation test store is clean");

   // ---- Simulated broker state: only the EXECUTED candidate has a real position ----
   MockBrokerPosition positions[1];
   positions[0].ticket  = 900001;
   positions[0].comment = "MLQuantAI|" + cExecuted.correlation_id;
   positions[0].volume  = 0.10;

   // ---- The actual contract under test ----
   Check(Reconcile_HasMatchingPosition(cExecuted.correlation_id, positions),
         "EXECUTED candidate's correlation_id matches a simulated broker position");

   // REJECTED candidate was never submitted - it must NOT have a
   // correlation_id at all (empty), and reconciliation must correctly
   // report "no position" rather than a false match.
   Check(cRejected.correlation_id == "", "REJECTED candidate never got a correlation_id (never submitted)");
   Check(!Reconcile_HasMatchingPosition(cRejected.correlation_id, positions),
         "REJECTED candidate correctly has no matching broker position");

   // A candidate that reached EXECUTED but whose correlation_id has NO
   // matching broker position is exactly the discrepancy Phase B's real
   // reconciliation needs to catch (e.g. order was filled in our records
   // but the position was somehow closed/missing broker-side) - prove the
   // contract flags that case as a mismatch, not a false positive.
   string ghostCorrelationId = Ids_CorrelationId("CND_GHOST_DOES_NOT_EXIST");
   Check(!Reconcile_HasMatchingPosition(ghostCorrelationId, positions),
         "a correlation_id with no real position is correctly reported as unmatched");

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun)
      Print("ALL PASS (contract-level, simulated broker state). Wire Reconcile_HasMatchingPosition's ");
   else
      Print("FAILURES ABOVE.");
   Print("data source to PositionsTotal()/PositionGetString(POSITION_COMMENT) once Phase B's Execution Engine exists.");
}
