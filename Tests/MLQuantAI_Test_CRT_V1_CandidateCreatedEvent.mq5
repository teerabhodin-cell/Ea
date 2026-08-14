//+------------------------------------------------------------------+
//| MLQuantAI_Test_CRT_V1_CandidateCreatedEvent.mq5                   |
//| Phase B B5 Commit 5 DoD: TradeCandidate -> CANDIDATE_CREATED ->    |
//| EventStore append. Detection (Commit 3) and the ctx->candidate     |
//| mapping (Commit 4) are already sealed and covered elsewhere - this |
//| file only exercises CRT_EmitCandidateCreated() and the persisted   |
//| event it produces, against every Commit 5 test gate.               |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_CRT_V1_CandidateCreatedEvent.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

// Same bracket-depth JSON array extractor as
// MLQuantAI_Test_CRTContextWindow.mq5 / MLQuantAI_Test_NewsReplayIsolation.mq5.
string ExtractJsonArray(string line, string key)
{
   string needle = "\"" + key + "\":[";
   int start = StringFind(line, needle);
   if(start < 0) return "";
   int arrStart = start + StringLen(needle) - 1;
   int depth = 0;
   int n = StringLen(line);
   for(int i = arrStart; i < n; i++)
   {
      ushort ch = StringGetCharacter(line, i);
      if(ch == '[') depth++;
      else if(ch == ']')
      {
         depth--;
         if(depth == 0)
            return StringSubstr(line, arrStart, i - arrStart + 1);
      }
   }
   return "";
}

void MakeBar(MqlRates &r, datetime t, double open, double high, double low, double close, long tickVolume, int spread)
{
   ZeroMemory(r);
   r.time = t; r.open = open; r.high = high; r.low = low; r.close = close;
   r.tick_volume = tickVolume; r.spread = spread;
}

#define PERIOD_SEC_M5 300

void BuildBaseContext(MarketContext &ctx, string suffix)
{
   MarketContext_Init(ctx);
   ctx.instrument_id      = "XAUUSD";
   ctx.broker_symbol      = "XAUUSD";
   ctx.trigger_timeframe  = "M5";
   ctx.symbol_spec.digits = 2;
   ctx.symbol_spec.point  = 0.01;
   ctx.pdl = 100.00;
   ctx.pdh = 110.00;
   ctx.is_kill_zone = false;
   ctx.max_news_impact = 0;
   ctx.nearest_news_minutes = 9999;
   ctx.context_event_id = "CTX_test_" + suffix;
   ctx.context_hash      = "test_context_hash_" + suffix;
}

void FillFillerBars(MqlRates &window[], datetime t0)
{
   for(int i = 0; i < 59; i++)
      MakeBar(window[i], t0 + i * PERIOD_SEC_M5, 105.00, 105.20, 104.80, 105.00, 100, 20);
}

// Same numeric fixture as MLQuantAI_Test_CRT_V1_Rules.mq5's
// Fixture_Bullish_Valid - kept self-contained per this project's
// per-file test convention. Takes an explicit t0 (unlike the original)
// so different tests in this file can produce genuinely different
// root_event_id/candidate_id values - root_event_id is derived from
// mss_confirmation_bar_time (contract section 5), NOT from
// context_event_id/context_hash, so two fixtures sharing the same bar
// times would collide on the same candidate_id even with different
// context lineage - exactly the collision this parameter avoids.
void Fixture_Bullish_Valid(MqlRates &window[], datetime &outAnchor, datetime t0)
{
   ArrayResize(window, 64);
   FillFillerBars(window, t0);
   MakeBar(window[59], t0 + 59 * PERIOD_SEC_M5, 100.80, 100.90, 99.50,  100.50, 100, 20);
   MakeBar(window[60], t0 + 60 * PERIOD_SEC_M5, 100.50, 101.50, 100.40, 101.40, 100, 20);
   MakeBar(window[61], t0 + 61 * PERIOD_SEC_M5, 101.40, 102.50, 101.30, 102.40, 100, 20);
   MakeBar(window[62], t0 + 62 * PERIOD_SEC_M5, 102.40, 103.50, 102.30, 103.40, 100, 20);
   MakeBar(window[63], t0 + 63 * PERIOD_SEC_M5, 103.40, 104.60, 103.30, 104.50, 100, 20);
   outAnchor = window[63].time;
}

// Builds a real, detected TradeCandidate from the bullish fixture -
// shared setup for every test below. dayOffset picks a distinct t0 per
// caller (see the note on Fixture_Bullish_Valid above) so unrelated
// tests never collide on the same candidate_id.
bool BuildDetectedCandidate(TradeCandidate &c, string suffix, int dayOffset)
{
   MarketContext ctx; BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.01.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   return CRT_ToTradeCandidate(ctx, r, c);
}

// Finds every line in the store whose candidate_id matches and whose
// type is CANDIDATE_CREATED - used to count creation events, not just
// any lifecycle event, for a given candidate.
int CountCandidateCreatedLines(const string &lines[], string candidateId)
{
   int count = 0;
   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(StringFind(lines[i], "\"candidate_id\":\"" + candidateId + "\"") < 0) continue;
      if(StringFind(lines[i], "\"type\":\"CANDIDATE_CREATED\"") < 0) continue;
      count++;
   }
   return count;
}

string FindCandidateCreatedLine(const string &lines[], string candidateId)
{
   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(StringFind(lines[i], "\"candidate_id\":\"" + candidateId + "\"") < 0) continue;
      if(StringFind(lines[i], "\"type\":\"CANDIDATE_CREATED\"") < 0) continue;
      return lines[i];
   }
   return "";
}

//=====================================================================
void Test_EmitOnDetection_ExactlyOneEvent()
{
   Print("--- Detected CRT candidate emits exactly one CANDIDATE_CREATED event ---");
   TradeCandidate c;
   Check(BuildDetectedCandidate(c, "A", 1), "sanity: fixture produces a detected candidate");

   bool ok = CRT_EmitCandidateCreated(c, 2);
   Check(ok, "CRT_EmitCandidateCreated returns true on a fresh candidate");

   string lines[];
   EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
   Check(CountCandidateCreatedLines(lines, c.candidate_id) == 1,
         "exactly one CANDIDATE_CREATED line exists for this candidate_id");
}

void Test_EventCarriesRequiredFields()
{
   Print("--- Event carries candidate_id/root_event_id/context_event_id/context_hash/candidate_hash/detector_hash ---");
   TradeCandidate c;
   Check(BuildDetectedCandidate(c, "B", 2), "sanity: fixture produces a detected candidate");
   Check(CRT_EmitCandidateCreated(c, 2), "sanity: event emitted");

   string lines[];
   EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
   string line = FindCandidateCreatedLine(lines, c.candidate_id);
   Check(line != "", "the persisted CANDIDATE_CREATED line was found");

   Check(EventSerializer_GetStr(line, "candidate_id") == c.candidate_id, "persisted candidate_id matches");
   Check(EventSerializer_GetStr(line, "root_event_id") == c.root_event_id, "persisted root_event_id matches");
   Check(EventSerializer_GetStr(line, "context_event_id") == c.context_event_id, "persisted context_event_id matches");
   Check(EventSerializer_GetStr(line, "context_hash") == c.context_hash, "persisted context_hash matches");
   Check(EventSerializer_GetStr(line, "candidate_hash") == c.candidate_hash, "persisted candidate_hash matches");
   Check(EventSerializer_GetStr(line, "detector_hash") == c.detector_hash, "persisted detector_hash matches");
}

void Test_EventPreservesOrderedTriggerReasons()
{
   Print("--- Event payload preserves ordered trigger_reasons[] ---");
   TradeCandidate c;
   Check(BuildDetectedCandidate(c, "C", 3), "sanity: fixture produces a detected candidate");
   Check(CRT_EmitCandidateCreated(c, 2), "sanity: event emitted");

   string lines[];
   EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
   string line = FindCandidateCreatedLine(lines, c.candidate_id);

   string arrJson = ExtractJsonArray(line, "trigger_reasons");
   Check(arrJson != "", "trigger_reasons[] array was found in the persisted line");

   bool allPresent = true;
   int lastPos = -1;
   for(int i = 0; i < ArraySize(c.trigger_reasons); i++)
   {
      int p = StringFind(arrJson, "\"" + c.trigger_reasons[i] + "\"", lastPos + 1);
      if(p < 0) allPresent = false;
      else      lastPos = p;
   }
   Check(allPresent, "every trigger_reasons[] label appears in the persisted array, in original order");
}

void Test_DuplicateCandidateId_NoSecondEvent()
{
   Print("--- Duplicate same candidate_id does not append a second creation event ---");
   TradeCandidate c;
   Check(BuildDetectedCandidate(c, "D", 4), "sanity: fixture produces a detected candidate");

   bool first = CRT_EmitCandidateCreated(c, 2);
   Check(first, "first emit returns true");
   bool second = CRT_EmitCandidateCreated(c, 2);
   Check(!second, "second emit (same candidate_id) returns false - not re-appended");

   string lines[];
   EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
   Check(CountCandidateCreatedLines(lines, c.candidate_id) == 1,
         "still exactly one CANDIDATE_CREATED line for this candidate_id after the duplicate attempt");
}

void Test_NonDetectionEmitsNoEvent()
{
   Print("--- Non-detection emits no event ---");
   string lines1[];
   EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines1);
   int countBefore = ArraySize(lines1);

   TradeCandidate c;
   TradeCandidate_Init(c); // candidate_id == "" - the non-detection shape Commit 4 produces

   bool ok = CRT_EmitCandidateCreated(c, 2);
   Check(!ok, "CRT_EmitCandidateCreated returns false for a non-detection candidate");

   string lines2[];
   EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines2);
   Check(ArraySize(lines2) == countBefore, "the event store gained no new line");
}

void Test_ReplayReconstructsCandidateCreated()
{
   Print("--- Reopening EventStore and replaying reconstructs CANDIDATE_CREATED ---");
   TradeCandidate c;
   Check(BuildDetectedCandidate(c, "E", 5), "sanity: fixture produces a detected candidate");
   Check(CRT_EmitCandidateCreated(c, 2), "sanity: event emitted");

   EventStore_Close(); // simulate a restart - the writer goes away

   ReplayReport rr = ReplayEngine_Run(TEST_EVENT_STORE_FILE);
   Check(rr.ok, "replay reports zero inconsistencies");

   ENUM_CANDIDATE_STATE state;
   Check(StateProjector_TryGetState(c.candidate_id, state) && state == CANDIDATE_CREATED,
         "replayed state for this candidate is CANDIDATE_CREATED");

   // Reopen for subsequent tests in this same run (EventStore_ReadAllLines
   // would otherwise keep re-opening/closing a short-lived handle, which
   // is also fine, but every other test in this file assumes the session
   // handle is open for further CRT_EmitCandidateCreated calls).
   EventStore_Open(TEST_EVENT_STORE_FILE);
}

void Test_ReplayedFieldsMatchOriginal()
{
   Print("--- Replayed candidate fields and hashes exactly equal the original ---");
   TradeCandidate c;
   Check(BuildDetectedCandidate(c, "F", 6), "sanity: fixture produces a detected candidate");
   Check(CRT_EmitCandidateCreated(c, 2), "sanity: event emitted");

   EventStore_Close();

   string lines[];
   EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines); // fresh handle - store not open this session right now
   string line = FindCandidateCreatedLine(lines, c.candidate_id);
   Check(line != "", "the persisted line survives a close/reopen cycle");

   Check(EventSerializer_GetStr(line, "candidate_id")      == c.candidate_id,      "replayed candidate_id == original");
   Check(EventSerializer_GetStr(line, "root_event_id")     == c.root_event_id,     "replayed root_event_id == original");
   Check(EventSerializer_GetStr(line, "context_hash")      == c.context_hash,      "replayed context_hash == original");
   Check(EventSerializer_GetStr(line, "candidate_hash")    == c.candidate_hash,    "replayed candidate_hash == original");
   Check(EventSerializer_GetStr(line, "detector_hash")     == c.detector_hash,     "replayed detector_hash == original");
   Check(EventSerializer_GetInt(line, "trigger_reason_mask") == (int)c.trigger_reason_mask, "replayed trigger_reason_mask == original");
   Check(EventSerializer_GetDouble(line, "entry_hint") == c.entry_hint, "replayed entry_hint == original");
   Check(EventSerializer_GetDouble(line, "sl_hint")    == c.sl_hint,    "replayed sl_hint == original");
   Check(EventSerializer_GetDouble(line, "tp_hint")    == c.tp_hint,    "replayed tp_hint == original");

   EventStore_Open(TEST_EVENT_STORE_FILE);
}

void Test_ReplayIsIdempotent()
{
   Print("--- Replaying the same store repeatedly is idempotent ---");
   TradeCandidate c;
   Check(BuildDetectedCandidate(c, "G", 7), "sanity: fixture produces a detected candidate");
   Check(CRT_EmitCandidateCreated(c, 2), "sanity: event emitted");

   EventStore_Close();

   ReplayReport rr1 = ReplayEngine_Run(TEST_EVENT_STORE_FILE);
   ENUM_CANDIDATE_STATE state1;
   StateProjector_TryGetState(c.candidate_id, state1);

   ReplayReport rr2 = ReplayEngine_Run(TEST_EVENT_STORE_FILE); // ReplayEngine_Run resets the projector internally, always a from-scratch replay
   ENUM_CANDIDATE_STATE state2;
   StateProjector_TryGetState(c.candidate_id, state2);

   Check(rr1.ok && rr2.ok, "both replay passes report zero inconsistencies");
   Check(rr1.lifecycle_events_total == rr2.lifecycle_events_total, "both passes see the same total event count");
   Check(state1 == state2 && state1 == CANDIDATE_CREATED, "both passes reconstruct the identical CANDIDATE_CREATED state");

   EventStore_Open(TEST_EVENT_STORE_FILE);
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B B5 Commit 5 - CANDIDATE_CREATED Event Emission ===");

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON); // isolation: fresh file for every run
   if(!EventStore_Open(TEST_EVENT_STORE_FILE))
   {
      Print("Could not open the event store - aborting.");
      return;
   }

   Test_EmitOnDetection_ExactlyOneEvent();
   Test_EventCarriesRequiredFields();
   Test_EventPreservesOrderedTriggerReasons();
   Test_DuplicateCandidateId_NoSecondEvent();
   Test_NonDetectionEmitsNoEvent();
   Test_ReplayReconstructsCandidateCreated();
   Test_ReplayedFieldsMatchOriginal();
   Test_ReplayIsIdempotent();

   EventStore_Close();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
