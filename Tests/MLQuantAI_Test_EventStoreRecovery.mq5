//+------------------------------------------------------------------+
//| MLQuantAI_Test_EventStoreRecovery.mq5                            |
//| Phase A DoD #8 + #9: simulate partial write / duplicate sequence /|
//| gap, and confirm a corrupted store trips SAFE MODE (blocking new  |
//| candidates) rather than being silently accepted.                  |
//|                                                                    |
//| Builds one valid base store, then hand-corrupts three separate    |
//| copies of it (truncated last line, duplicated sequence, missing   |
//| sequence) using raw file I/O - deliberately bypassing the Event   |
//| Store's own append API, since the whole point is to simulate      |
//| damage the API itself would never produce (e.g. a crash mid-      |
//| write, or disk corruption).                                       |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Core/MLQuantAI_Enums.mqh>
#include <MLQuantAI/Core/MLQuantAI_Ids.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStore.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStoreHealth.mqh>

#define BASE_FILE       "MLQuantAI_Test_Recovery_Base.jsonl"
#define TRUNCATED_FILE  "MLQuantAI_Test_Recovery_Truncated.jsonl"
#define DUPLICATE_FILE  "MLQuantAI_Test_Recovery_Duplicate.jsonl"
#define GAP_FILE        "MLQuantAI_Test_Recovery_Gap.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void WriteLinesRaw(string fileName, string &lines[])
{
   int h = FileOpen(fileName, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) { Print("WriteLinesRaw: failed to open ", fileName); return; }
   for(int i = 0; i < ArraySize(lines); i++)
      FileWriteString(h, lines[i] + "\r\n");
   FileClose(h);
}

void OnStart()
{
   Print("=== MLQuantAI Test: Event Store Recovery / Safe Mode (Phase A) ===");

   // ---- Build one small, valid base store (5 lines) ----
   if(!EventStore_Open(BASE_FILE))
   {
      Print("Could not open the base event store - aborting.");
      return;
   }
   EventStore_LogSystem("SYSTEM_STARTED", "recovery test base");     // seq 1

   TradeCandidate c;
   TradeCandidate_Init(c);
   c.root_event_id = Ids_RootEventId(_Symbol, "M15", "RECOVERY_TEST", 3350.00, TimeCurrent(), _Digits);
   c.candidate_id  = Ids_CandidateId(c.root_event_id, "TREND", "V1");
   c.strategy_id   = STRAT_TREND;
   EventStore_LogCandidateCreated(c);                                // seq 2
   EventStore_LogTransition(c, CANDIDATE_SUBMITTED, REASON_SUBMITTED_OK); // seq 3
   c.correlation_id = Ids_CorrelationId(c.candidate_id);
   EventStore_LogTransition(c, CANDIDATE_EXECUTED, REASON_EXECUTED_OK);  // seq 4

   EventStore_LogSystem("SYSTEM_STOPPED", "recovery test base");     // seq 5
   EventStore_Close();

   string baseLines[];
   int n = EventStore_ReadAllLines(BASE_FILE, baseLines);
   Check(n == 5, "base store has the 5 expected lines before corrupting it");

   // ---- Sanity: the clean base store passes validation ----
   EventStoreHealth_ClearSafeMode();
   EventStoreValidationReport baseReport = EventStoreHealth_CheckFile(BASE_FILE);
   Check(baseReport.ok, "clean base store passes validation");
   Check(!EventStoreHealth_IsSafeMode(), "Safe Mode NOT engaged for a clean store");
   EventStoreHealth_ClearSafeMode();

   // ---- Scenario A: truncated last line (simulated partial write) ----
   {
      string lines[];
      ArrayResize(lines, n);
      for(int i = 0; i < n; i++) lines[i] = baseLines[i];
      string last = lines[n-1];
      int cutLen = MathMax(1, StringLen(last) - 20);
      lines[n-1] = StringSubstr(last, 0, cutLen); // no longer ends with '}'
      WriteLinesRaw(TRUNCATED_FILE, lines);

      EventStoreHealth_ClearSafeMode();
      EventStoreValidationReport r = EventStoreHealth_CheckFile(TRUNCATED_FILE);
      Check(!r.ok, "truncated store fails validation");
      Check(r.lines_malformed > 0, "truncated store is flagged as malformed");
      Check(EventStoreHealth_IsSafeMode(), "SAFE MODE engaged after a truncated store");
      Check(!EventStoreHealth_AllowNewCandidates(), "new candidates are blocked while in Safe Mode");
   }

   // ---- Scenario B: duplicate sequence number (re-append an existing line) ----
   {
      string lines[];
      ArrayResize(lines, n+1);
      for(int i = 0; i < n; i++) lines[i] = baseLines[i];
      lines[n] = baseLines[1]; // re-append the candidate-created line (seq 2) as a duplicate
      WriteLinesRaw(DUPLICATE_FILE, lines);

      EventStoreHealth_ClearSafeMode();
      EventStoreValidationReport r = EventStoreHealth_CheckFile(DUPLICATE_FILE);
      Check(!r.ok, "store with a duplicated sequence number fails validation");
      Check(r.sequence_duplicates > 0, "duplicate sequence is specifically flagged");
      Check(EventStoreHealth_IsSafeMode(), "SAFE MODE engaged after a duplicate sequence");
   }

   // ---- Scenario C: missing sequence number (drop a line from the middle) ----
   {
      string lines[];
      ArrayResize(lines, n-1);
      int w = 0;
      for(int i = 0; i < n; i++)
      {
         if(i == 2) continue; // drop the "SUBMITTED" line (seq 3), leaving a gap 2 -> 4
         lines[w] = baseLines[i];
         w++;
      }
      WriteLinesRaw(GAP_FILE, lines);

      EventStoreHealth_ClearSafeMode();
      EventStoreValidationReport r = EventStoreHealth_CheckFile(GAP_FILE);
      Check(!r.ok, "store with a missing sequence number fails validation");
      Check(r.sequence_gaps > 0, "sequence gap is specifically flagged");
      Check(EventStoreHealth_IsSafeMode(), "SAFE MODE engaged after a sequence gap");
   }

   // ---- Safe Mode can be manually cleared once the operator has dealt with it ----
   EventStoreHealth_ClearSafeMode();
   Check(!EventStoreHealth_IsSafeMode() && EventStoreHealth_AllowNewCandidates(),
         "Safe Mode clears and new candidates are allowed again after ClearSafeMode()");

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun)
      Print("ALL PASS. Corruption is detected and Safe Mode engages correctly in all three scenarios.");
   else
      Print("FAILURES ABOVE - corruption detection is not reliable yet.");
}
