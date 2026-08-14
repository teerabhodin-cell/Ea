//+------------------------------------------------------------------+
//| MLQuantAI_Test_NewsReplayIsolation.mq5                           |
//| Phase B B4 seal hardening: proves - with a real build, a real     |
//| durable write, a real fresh file read, and a real call-counter    |
//| assertion - that a replayed MARKET_CONTEXT_READY payload alone is |
//| enough to reconstruct news_decision_hash/news_snapshot_identity/  |
//| context_hash and the full NewsSnapshot[] identically, and that    |
//| NewsEngine_Build() (the ONLY function that ever touches an        |
//| INewsSource) is never called anywhere in that sequence.           |
//|                                                                    |
//| This replaces the earlier Test_Seal_ReplayNeverCallsSources, which|
//| only asserted Check(true, "enforced by construction") - an        |
//| architectural claim, not a verified one. No CRT/TradeCandidate/   |
//| execution code exercised anywhere here.                           |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Market/MLQuantAI_FeatureEngine.mqh>

#define REPLAY_EVENT_STORE_FILE "MLQuantAI_Test_NewsReplayIsolation.jsonl"
#define FIXTURE_ANCHOR D'2026.08.14 12:00:00'

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

// Extracts the "[...]" substring for a top-level JSON array field from a
// flat (non-nested-under-the-key) JSON object line - EventSerializer_Get*
// only handles scalar string/number fields, so this is the array-typed
// counterpart, scoped to this test (the "news" field is the only JSON
// array MarketContext_ToJsonFragment ever embeds).
string ExtractJsonArray(string line, string key)
{
   string needle = "\"" + key + "\":[";
   int start = StringFind(line, needle);
   if(start < 0) return "";
   int arrStart = start + StringLen(needle) - 1; // position of the '['

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

void Test_Replay_NewsSurvivesSourceFreeRebuild()
{
   Print("--- Replay isolation: persisted news/hashes reconstruct identically with zero NewsEngine_Build() calls ---");

   int buildCountBefore = g_NewsEngine_BuildCallCount;

   // Build the "original" data using ONLY the pure canonicalizer pipeline -
   // no INewsSource (CsvStaticNewsSource/LiveCalendarNewsSource) and no
   // NewsEngine_Build() call anywhere in this function. That's what makes
   // the call-counter check below meaningful rather than trivially true.
   RawNewsEvent rawArr[2];
   RawNewsEvent_Init(rawArr[0]);
   rawArr[0].provider_event_id  = "EVT_REPLAY_A";
   rawArr[0].currency             = "USD";
   rawArr[0].impact_raw            = "HIGH";
   rawArr[0].title                  = "Fed Rate Decision";
   rawArr[0].release_time            = FIXTURE_ANCHOR + 30 * 60;
   rawArr[0].source_kind               = "CSV_STATIC";
   rawArr[0].source_version             = "TEST_REPLAY_V1";
   rawArr[0].source_priority             = MLQUANTAI_CSV_NEWS_SOURCE_DEFAULT_PRIORITY;
   rawArr[0].revision_id                  = "REV_1";
   rawArr[0].revision_timestamp             = FIXTURE_ANCHOR - 3600;

   RawNewsEvent_Init(rawArr[1]);
   rawArr[1].provider_event_id  = "EVT_REPLAY_B";
   rawArr[1].currency             = "USD";
   rawArr[1].impact_raw            = "LOW";
   rawArr[1].title                  = "Building Permits";
   rawArr[1].release_time            = FIXTURE_ANCHOR - 15 * 60;
   rawArr[1].source_kind               = "CSV_STATIC";
   rawArr[1].source_version             = "TEST_REPLAY_V1";
   rawArr[1].source_priority             = MLQUANTAI_CSV_NEWS_SOURCE_DEFAULT_PRIORITY;
   rawArr[1].revision_id                  = "REV_1";
   rawArr[1].revision_timestamp             = FIXTURE_ANCHOR - 3600;

   NormalizedNewsEvent normalized[];
   News_NormalizeAll(rawArr, FIXTURE_ANCHOR, normalized);

   NormalizedNewsEvent deduped[];
   string dedupErr;
   if(!News_Deduplicate(normalized, deduped, dedupErr))
   {
      Check(false, "News_Deduplicate unexpectedly failed for the replay-isolation fixture - " + dedupErr);
      return;
   }
   News_SortAndSelect(deduped, MLQUANTAI_NEWS_MAX_EVENTS);

   string origDecisionHash = News_DecisionHash(deduped);
   string origIdentityHash = News_SnapshotIdentity(deduped);

   NewsSnapshot origSnapshots[];
   int n = News_ToSnapshotArray(deduped, origSnapshots);
   Check(n == 2, StringFormat("both hand-built raw events survived normalize/dedup/select (got %d)", n));

   MarketContext ctx;
   MarketContext_Init(ctx);
   ctx.instrument_id     = "XAUUSD";
   ctx.broker_symbol      = "XAUUSD";
   ctx.trigger_timeframe   = "M5";
   ctx.anchor_bar_time      = FIXTURE_ANCHOR;

   ctx.m5_bar.time = FIXTURE_ANCHOR;  ctx.m5_bar.open = 2400.10; ctx.m5_bar.high = 2401.20; ctx.m5_bar.low = 2399.50; ctx.m5_bar.close = 2400.80; ctx.m5_bar.tick_volume = 120; ctx.m5_bar.spread = 20;
   ctx.m15_bar.time = FIXTURE_ANCHOR; ctx.m15_bar.open = 2399.90; ctx.m15_bar.high = 2402.00; ctx.m15_bar.low = 2398.70; ctx.m15_bar.close = 2400.80; ctx.m15_bar.tick_volume = 340; ctx.m15_bar.spread = 22;
   ctx.h1_bar.time = FIXTURE_ANCHOR;  ctx.h1_bar.open = 2395.00; ctx.h1_bar.high = 2405.00; ctx.h1_bar.low = 2394.00; ctx.h1_bar.close = 2400.80; ctx.h1_bar.tick_volume = 1200; ctx.h1_bar.spread = 25;
   ctx.h4_bar.time = FIXTURE_ANCHOR;  ctx.h4_bar.open = 2380.00; ctx.h4_bar.high = 2410.00; ctx.h4_bar.low = 2378.00; ctx.h4_bar.close = 2400.80; ctx.h4_bar.tick_volume = 4800; ctx.h4_bar.spread = 30;

   ctx.bid_at_anchor           = 2400.75;
   ctx.ask_at_anchor            = 2400.95;
   ctx.spread_points_at_anchor   = 20.0;
   ctx.atr_m15 = 1.234; ctx.adx_m15 = 27.5; ctx.ema_slope_m15 = 0.045;
   ctx.pdh = 2412.30; ctx.pdl = 2388.10; ctx.asian_range_high = 2405.60; ctx.asian_range_low = 2397.20;
   ctx.session_id = "LONDON"; ctx.is_kill_zone = true;

   ArrayResize(ctx.news, n);
   for(int i = 0; i < n; i++) ctx.news[i] = origSnapshots[i];
   ctx.news_count             = n;
   ctx.news_decision_hash      = origDecisionHash;
   ctx.news_snapshot_identity   = origIdentityHash;

   ctx.context_event_id = Ids_ContextEventId(ctx.instrument_id, ctx.trigger_timeframe, ctx.anchor_bar_time);
   ctx.context_hash      = MarketContext_ComputeHash(ctx);

   FileDelete(REPLAY_EVENT_STORE_FILE, FILE_COMMON);
   if(!EventStore_Open(REPLAY_EVENT_STORE_FILE))
   {
      Check(false, "could not open a fresh scratch event store for the replay-isolation test");
      return;
   }
   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY),
                         "market context built (replay isolation test)", MarketContext_ToJsonFragment(ctx));
   EventStore_Close();

   // "Restart": with the store already closed above, EventStore_ReadAllLines
   // opens its OWN short-lived handle (g_EventStore_Handle is INVALID_HANDLE
   // here) - a genuinely cold read of only what's on disk, mirroring what a
   // real EA restart + a fresh replay pass would see.
   string lines[];
   int lineCount = EventStore_ReadAllLines(REPLAY_EVENT_STORE_FILE, lines);

   Check(lineCount >= 1, "MARKET_CONTEXT_READY was durably written and re-readable from a fresh handle");
   if(lineCount < 1) return;
   string line = lines[lineCount - 1];

   string replayedDecisionHash = EventSerializer_GetStr(line, "news_decision_hash");
   string replayedIdentityHash = EventSerializer_GetStr(line, "news_snapshot_identity");
   string replayedContextHash  = EventSerializer_GetStr(line, "context_hash");

   Check(replayedDecisionHash == origDecisionHash,      "replayed news_decision_hash matches the value computed before persisting");
   Check(replayedIdentityHash == origIdentityHash,      "replayed news_snapshot_identity matches the value computed before persisting");
   Check(replayedContextHash == ctx.context_hash,       "replayed context_hash matches the value computed before persisting");
   Check(replayedDecisionHash != "" && replayedIdentityHash != "" && replayedContextHash != "",
         "none of the replayed hash fields are empty (a truncated/malformed read would show up as this failing)");

   string newsArrayJson = ExtractJsonArray(line, "news");
   NewsSnapshot replayedSnapshots[];
   int replayedCount = NewsSnapshot_ArrayFromJson(newsArrayJson, replayedSnapshots);
   Check(replayedCount == n, StringFormat("replayed news[] has the same element count as the original (expected %d, got %d)", n, replayedCount));

   bool allMatch = (replayedCount == n);
   for(int i = 0; i < MathMin(replayedCount, n); i++)
   {
      if(replayedSnapshots[i].calendar_event_id != origSnapshots[i].calendar_event_id) allMatch = false;
      if(replayedSnapshots[i].normalized_event_key != origSnapshots[i].normalized_event_key) allMatch = false;
      if(replayedSnapshots[i].revision_id != origSnapshots[i].revision_id) allMatch = false;
      if(replayedSnapshots[i].source_priority != origSnapshots[i].source_priority) allMatch = false;
      if(replayedSnapshots[i].minutes_to_event != origSnapshots[i].minutes_to_event) allMatch = false;
      if(replayedSnapshots[i].impact != origSnapshots[i].impact) allMatch = false;
   }
   Check(allMatch, "replayed NewsSnapshot[] round-trips every element's identity/lineage fields exactly through JSON");

   int buildCountAfter = g_NewsEngine_BuildCallCount;
   Check(buildCountAfter == buildCountBefore,
         StringFormat("zero NewsEngine_Build() calls across the entire build+persist+restart+replay sequence (before=%d, after=%d)",
                       buildCountBefore, buildCountAfter));
}

void OnStart()
{
   Print("=== MLQuantAI Test: Phase B B4 News Replay Isolation ===");

   Test_Replay_NewsSurvivesSourceFreeRebuild();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   Print(g_TestsPassed == g_TestsRun ? "ALL PASS." : "FAILURES ABOVE.");
}
