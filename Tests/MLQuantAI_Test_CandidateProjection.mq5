//+------------------------------------------------------------------+
//| MLQuantAI_Test_CandidateProjection.mq5                            |
//| Phase B B6.1 DoD: the candidate projection/registry - a read-only |
//| read model built purely from persisted CANDIDATE_CREATED lines.   |
//| Uses the real B5 pipeline (CRT_DetectV1 -> CRT_ToTradeCandidate -> |
//| CRT_EmitCandidateCreated) to produce genuine candidates, then only |
//| exercises MLQuantAI_CandidateProjection.mqh - B5 is not touched.   |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_CandidateProjection.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
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
// Fixture_Bullish_Valid, parameterized by t0 - see MLQuantAI_Test_CRT_
// V1_CandidateCreatedEvent.mq5's note on why: root_event_id derives from
// mss_confirmation_bar_time, so distinct t0s are what keep unrelated
// test candidates from colliding on the same candidate_id.
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

string FindLineForCandidate(const string &lines[], string candidateId)
{
   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(StringFind(lines[i], "\"candidate_id\":\"" + candidateId + "\"") < 0) continue;
      if(StringFind(lines[i], "\"type\":\"CANDIDATE_CREATED\"") < 0) continue;
      return lines[i];
   }
   return "";
}

void CheckRecordMatchesCandidate(const CandidateProjectionRecord &rec, const TradeCandidate &c, string label)
{
   Check(rec.candidate_id == c.candidate_id, label + ": candidate_id matches");
   Check(rec.root_event_id == c.root_event_id, label + ": root_event_id matches");
   Check(rec.strategy_id == c.strategy_id, label + ": strategy_id matches");
   Check(rec.state == CANDIDATE_CREATED, label + ": state == CANDIDATE_CREATED");
   Check(rec.context_event_id == c.context_event_id, label + ": context_event_id matches");
   Check(rec.context_hash == c.context_hash, label + ": context_hash matches");
   Check(rec.candidate_hash == c.candidate_hash, label + ": candidate_hash matches");
   Check(rec.detector_hash == c.detector_hash, label + ": detector_hash matches");
   Check(rec.side == c.side, label + ": side matches");
   Check(rec.setup_anchor_bar_time == c.setup_anchor_bar_time, label + ": setup_anchor_bar_time matches");
   Check(rec.expiry_time == c.expiry_time, label + ": expiry_time matches");
   Check(rec.entry_hint == c.entry_hint && rec.sl_hint == c.sl_hint && rec.tp_hint == c.tp_hint, label + ": entry/sl/tp hints match");
   Check(rec.trigger_reason_mask == c.trigger_reason_mask, label + ": trigger_reason_mask matches");

   bool reasonsMatch = (ArraySize(rec.trigger_reasons) == ArraySize(c.trigger_reasons));
   if(reasonsMatch)
      for(int i = 0; i < ArraySize(c.trigger_reasons); i++)
         if(rec.trigger_reasons[i] != c.trigger_reasons[i]) reasonsMatch = false;
   Check(reasonsMatch, label + ": trigger_reasons[] preserved exactly, in original order");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B B6.1 - Candidate Projection/Registry ===");

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   if(!EventStore_Open(TEST_EVENT_STORE_FILE))
   {
      Print("Could not open the event store - aborting.");
      return;
   }

   TradeCandidate a, b;
   Check(BuildDetectedCandidate(a, "A", 1), "sanity: candidate A detected");
   Check(CRT_EmitCandidateCreated(a, 2), "sanity: candidate A emitted");
   Check(BuildDetectedCandidate(b, "B", 2), "sanity: candidate B detected");
   Check(CRT_EmitCandidateCreated(b, 2), "sanity: candidate B emitted");

   string lines[];
   EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
   string lineA = FindLineForCandidate(lines, a.candidate_id);
   string lineB = FindLineForCandidate(lines, b.candidate_id);
   Check(lineA != "" && lineB != "", "sanity: both persisted lines found");

   //------------------------------------------------------------------
   Print("--- one event -> one registry record ---");
   CandidateProjection_Reset();
   string reason;
   bool applied = CandidateProjection_ApplyLine(lineA, reason);
   Check(applied, "ApplyLine on candidate A's line returns true");
   Check(CandidateProjection_Count() == 1, "registry has exactly one record");
   CandidateProjectionRecord recA;
   Check(CandidateProjection_TryGet(a.candidate_id, recA), "CandidateLookup finds candidate A");
   CheckRecordMatchesCandidate(recA, a, "candidate A");

   //------------------------------------------------------------------
   Print("--- same event applied twice -> one record ---");
   string reason2;
   bool appliedAgain = CandidateProjection_ApplyLine(lineA, reason2);
   Check(appliedAgain, "re-applying the same line returns true (idempotent no-op, not an error)");
   Check(CandidateProjection_Count() == 1, "registry still has exactly one record");
   Check(StringFind(reason2, "duplicate") >= 0, "the duplicate is explicitly named in the audit reason");

   //------------------------------------------------------------------
   Print("--- two candidates -> two lookupable records ---");
   string reason3;
   Check(CandidateProjection_ApplyLine(lineB, reason3), "ApplyLine on candidate B's line returns true");
   Check(CandidateProjection_Count() == 2, "registry has exactly two records");
   CandidateProjectionRecord recB;
   Check(CandidateProjection_TryGet(a.candidate_id, recA) && CandidateProjection_TryGet(b.candidate_id, recB),
         "both candidates are independently lookupable");
   CheckRecordMatchesCandidate(recA, a, "candidate A (after B added)");
   CheckRecordMatchesCandidate(recB, b, "candidate B");

   //------------------------------------------------------------------
   Print("--- unknown/malformed event fails closed with an audit reason ---");
   string reason4;
   bool badFromTo = CandidateProjection_ApplyLine(
      "{\"seq\":999,\"candidate_id\":\"BOGUS_1\",\"root_event_id\":\"R1\",\"correlation_id\":\"\",\"strategy_id\":1,"
      "\"from_state\":\"SUBMITTED\",\"to_state\":\"CREATED\",\"reason\":\"NONE\",\"type\":\"CANDIDATE_CREATED\"}",
      reason4);
   Check(!badFromTo, "a CANDIDATE_CREATED line with a non-genesis from/to shape fails closed");
   Check(reason4 != "", "the failure carries a non-empty audit reason");
   Check(CandidateProjection_Count() == 2, "registry is unchanged by the rejected line");

   string reason5;
   bool badEmptyId = CandidateProjection_ApplyLine(
      "{\"seq\":998,\"candidate_id\":\"\",\"root_event_id\":\"R2\",\"correlation_id\":\"\",\"strategy_id\":1,"
      "\"from_state\":\"CREATED\",\"to_state\":\"CREATED\",\"reason\":\"NONE\",\"type\":\"CANDIDATE_CREATED\"}",
      reason5);
   Check(!badEmptyId, "a CANDIDATE_CREATED line with an empty candidate_id fails closed");
   Check(reason5 != "", "the failure carries a non-empty audit reason");
   Check(CandidateProjection_Count() == 2, "registry is still unchanged");

   string reason6;
   bool notLifecycle = CandidateProjection_ApplyLine("not even json", reason6);
   Check(!notLifecycle, "an unparsable line fails closed");
   Check(CandidateProjection_Count() == 2, "registry is still unchanged after garbage input");

   // Preserve this incrementally-built registry's content before
   // CandidateProjection_RebuildFromFile resets it out from under us.
   CandidateProjectionRecord incrementalA, incrementalB;
   CandidateProjection_TryGet(a.candidate_id, incrementalA);
   CandidateProjection_TryGet(b.candidate_id, incrementalB);
   int incrementalCount = CandidateProjection_Count();

   //------------------------------------------------------------------
   Print("--- registry rebuilt from replay equals the incrementally-built registry ---");
   EventStore_Close();

   CandidateProjectionReport rr1 = CandidateProjection_RebuildFromFile(TEST_EVENT_STORE_FILE);
   Check(rr1.ok, "rebuild reports zero inconsistencies");
   Check(rr1.lines_applied == 2, "rebuild applied exactly 2 new candidates");
   Check(CandidateProjection_Count() == incrementalCount, "rebuilt registry has the same record count as the incremental one");

   CandidateProjectionRecord rebuiltA, rebuiltB;
   Check(CandidateProjection_TryGet(a.candidate_id, rebuiltA), "rebuilt registry finds candidate A");
   Check(CandidateProjection_TryGet(b.candidate_id, rebuiltB), "rebuilt registry finds candidate B");
   CheckRecordMatchesCandidate(rebuiltA, a, "rebuilt candidate A");
   CheckRecordMatchesCandidate(rebuiltB, b, "rebuilt candidate B");
   Check(rebuiltA.candidate_hash == incrementalA.candidate_hash, "rebuilt vs incremental: candidate A's candidate_hash matches");
   Check(rebuiltB.candidate_hash == incrementalB.candidate_hash, "rebuilt vs incremental: candidate B's candidate_hash matches");

   //------------------------------------------------------------------
   Print("--- replaying the same store twice produces identical registries ---");
   CandidateProjectionReport rr2 = CandidateProjection_RebuildFromFile(TEST_EVENT_STORE_FILE);
   Check(rr2.ok, "second rebuild also reports zero inconsistencies");
   Check(rr2.lines_total == rr1.lines_total && rr2.lines_applied == rr1.lines_applied, "both rebuilds see the same line counts");
   Check(CandidateProjection_Count() == incrementalCount, "second rebuild's registry has the same record count");

   CandidateProjectionRecord replay2A, replay2B;
   CandidateProjection_TryGet(a.candidate_id, replay2A);
   CandidateProjection_TryGet(b.candidate_id, replay2B);
   Check(replay2A.candidate_hash == rebuiltA.candidate_hash && replay2A.detector_hash == rebuiltA.detector_hash,
         "replay #1 and replay #2 agree exactly on candidate A's hashes");
   Check(replay2B.candidate_hash == rebuiltB.candidate_hash && replay2B.detector_hash == rebuiltB.detector_hash,
         "replay #1 and replay #2 agree exactly on candidate B's hashes");

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
