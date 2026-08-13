//+------------------------------------------------------------------+
//| MLQuantAI_Test_ReplayIntegrity.mq5                                |
//| Phase A DoD #6: "delete the snapshot, replay the log, get the     |
//| same Candidate/RuntimeState back." There is no separate snapshot  |
//| format in Phase A - this test writes a fresh event stream, closes |
//| the file (simulating the write side going away, e.g. a restart),  |
//| then replays the file from scratch through the StateProjector and |
//| checks the reconstructed state matches exactly what was written.  |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Core/MLQuantAI_Enums.mqh>
#include <MLQuantAI/Core/MLQuantAI_Ids.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStore.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStoreValidator.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh>

#define TEST_FILE "MLQuantAI_Test_ReplayIntegrity.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

TradeCandidate MakeAndLogCandidate(string strategyTag, int strategyId, double price)
{
   TradeCandidate c;
   TradeCandidate_Init(c);
   c.root_event_id = Ids_RootEventId(_Symbol, "M15", "TEST_EVENT_" + strategyTag, price, TimeCurrent(), _Digits);
   c.candidate_id  = Ids_CandidateId(c.root_event_id, strategyTag, "V1");
   c.strategy_id   = strategyId;
   c.strategy_name = StrategyIdToString(strategyId);
   c.signal_time   = TimeCurrent();
   EventStore_LogCandidateCreated(c);
   return c;
}

void OnStart()
{
   Print("=== MLQuantAI Test: Replay Integrity (Phase A) ===");

   // Isolation: start every run from a clean file - otherwise leftover
   // events from a previous run would still be in the file and get
   // replayed too, which doesn't break the specific assertions below
   // (candidate ids are deterministic but include TimeCurrent(), so they
   // won't collide across runs) but does mean the file grows unbounded.
   FileDelete(TEST_FILE, FILE_COMMON);

   // ---- Phase 1: write a fresh, varied event stream ----
   if(!EventStore_Open(TEST_FILE))
   {
      Print("Could not open the event store - aborting.");
      return;
   }
   string writeSessionId = EventStore_SessionId();
   EventStore_LogSystem("SYSTEM_STARTED", "replay integrity test");

   TradeCandidate cExecuted = MakeAndLogCandidate("TREND", STRAT_TREND, 3350.10);
   EventStore_LogTransition(cExecuted, CANDIDATE_SUBMITTED, REASON_SUBMITTED_OK);
   cExecuted.correlation_id = Ids_CorrelationId(cExecuted.candidate_id);
   EventStore_LogTransition(cExecuted, CANDIDATE_EXECUTED, REASON_EXECUTED_OK);

   TradeCandidate cRejected = MakeAndLogCandidate("CRT", STRAT_CRT, 3345.20);
   EventStore_LogTransition(cRejected, CANDIDATE_REJECTED_BY_AI, REASON_AI_LOW_CONFIDENCE);

   TradeCandidate cMerged = MakeAndLogCandidate("SMC", STRAT_SMC, 3345.20);
   EventStore_LogTransition(cMerged, CANDIDATE_MERGED, REASON_MERGED_INTO_OTHER);

   TradeCandidate cExpired = MakeAndLogCandidate("SILVER", STRAT_SILVER_BULLET, 3360.00);
   EventStore_LogTransition(cExpired, CANDIDATE_EXPIRED, REASON_EXPIRED);

   EventStore_LogSystem("SYSTEM_STOPPED", "replay integrity test write phase done");
   EventStore_Close(); // simulates the writer going away (e.g. EA restart)

   // ---- Phase 2: validate the file is internally consistent ----
   EventStoreValidationReport vr = EventStoreValidator_ValidateFile(TEST_FILE);
   Check(vr.ok, "validator reports the freshly-written store is clean");
   Check(vr.sequence_gaps == 0 && vr.sequence_duplicates == 0 && vr.lines_malformed == 0,
         "no gaps/duplicates/malformed lines in a normal write");

   // ---- Phase 3: replay from scratch and compare to what we expect ----
   ReplayReport rr = ReplayEngine_Run(TEST_FILE);
   Check(rr.ok, "replay reports zero inconsistencies");
   Check(rr.lifecycle_events_failed == 0, "replay applied every lifecycle event with none failing");

   ENUM_CANDIDATE_STATE s;
   Check(StateProjector_TryGetState(cExecuted.candidate_id, s) && s == CANDIDATE_EXECUTED,
         "replayed state for the EXECUTED candidate matches original (EXECUTED)");
   Check(StateProjector_TryGetState(cRejected.candidate_id, s) && s == CANDIDATE_REJECTED_BY_AI,
         "replayed state for the REJECTED_BY_AI candidate matches original");
   Check(StateProjector_TryGetState(cMerged.candidate_id, s) && s == CANDIDATE_MERGED,
         "replayed state for the MERGED candidate matches original");
   Check(StateProjector_TryGetState(cExpired.candidate_id, s) && s == CANDIDATE_EXPIRED,
         "replayed state for the EXPIRED candidate matches original");

   Check(g_Proj_RuntimeState.candidates_created == 4, "projected RuntimeState counted 4 candidates created");
   Check(g_Proj_RuntimeState.candidates_executed == 1, "projected RuntimeState counted 1 executed");
   Check(g_Proj_RuntimeState.candidates_rejected == 1, "projected RuntimeState counted 1 rejected");
   Check(g_Proj_RuntimeState.candidates_merged == 1, "projected RuntimeState counted 1 merged");
   Check(g_Proj_RuntimeState.candidates_expired == 1, "projected RuntimeState counted 1 expired");

   // RuntimeState itself (session identity, not just candidate counters)
   // must also come back from SystemEvent replay, not just LifecycleEvents.
   Check(rr.system_events_total == 2 && rr.system_events_applied == 2,
         "both SYSTEM_STARTED and SYSTEM_STOPPED were replayed");
   Check(g_Proj_RuntimeState.runtime_session_id == writeSessionId,
         "replayed RuntimeState.runtime_session_id matches the original write session (from SYSTEM_STARTED)");
   Check(g_Proj_RuntimeState.session_start_time > 0,
         "replayed RuntimeState.session_start_time was reconstructed from SYSTEM_STARTED");

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun)
      Print("ALL PASS. Event log alone reconstructed identical state with no snapshot needed.");
   else
      Print("FAILURES ABOVE - replay is not trustworthy yet, do not build recovery-on-startup on top of this.");
}
