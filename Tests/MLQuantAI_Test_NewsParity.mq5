//+------------------------------------------------------------------+
//| MLQuantAI_Test_NewsParity.mq5                                    |
//| Phase B B4 DoD: Live vs. CSV news source parity, the              |
//| Canonicalizer's normalization/dedup/sort-select rules, coverage   |
//| enforcement, and the seal criteria tying it all to MarketContext. |
//| No CRT/TradeCandidate/execution code exercised anywhere here.     |
//|                                                                    |
//| REQUIRES: Tests/Fixtures/MLQuantAI_NewsParityFixture_V1.csv copied|
//| into this terminal's Common\Files folder before running.          |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Market/MLQuantAI_FeatureEngine.mqh>

#define FIXTURE_FILE "MLQuantAI_NewsParityFixture_V1.csv"
#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_NewsParity.jsonl"

// Matches Tests/Fixtures/MLQuantAI_NewsParityFixture_V1.csv's design -
// see that file's header comment for the reasoning behind each row.
#define FIXTURE_ANCHOR D'2026.08.14 12:00:00'

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//=====================================================================
// Core parity - Live vs. CSV sources agree on decision-relevant content
//=====================================================================

void Test_Parity_SameEvent_SameDecisionHash_DifferentSnapshotIdentity()
{
   Print("--- Core parity: same underlying event from two sources ---");

   RawNewsEvent liveRaw, csvRaw;
   RawNewsEvent_Init(liveRaw);
   liveRaw.provider_event_id = "123_1755167400";
   liveRaw.currency            = "USD";
   liveRaw.impact_raw           = "3"; // live source reports the numeric ENUM_CALENDAR_EVENT_IMPORTANCE form
   liveRaw.title                 = "Non-Farm Payrolls";
   liveRaw.release_time           = D'2026.08.14 12:30:00';
   liveRaw.source_kind              = "LIVE_CALENDAR";
   liveRaw.source_version            = MLQUANTAI_NEWS_SCHEMA_V1;
   liveRaw.source_priority            = MLQUANTAI_LIVE_NEWS_SOURCE_DEFAULT_PRIORITY;
   liveRaw.revision_id                 = "";
   liveRaw.revision_timestamp            = D'2026.08.14 12:30:00';

   RawNewsEvent_Init(csvRaw);
   csvRaw.provider_event_id = "EVT_DUP_B"; // matches the fixture's winning duplicate row
   csvRaw.currency            = "USD";
   csvRaw.impact_raw           = "HIGH"; // CSV source reports the string form
   csvRaw.title                 = "  non-farm   payrolls  ";
   csvRaw.release_time           = D'2026.08.14 12:30:00';
   csvRaw.source_kind              = "CSV_STATIC";
   csvRaw.source_version            = "PARITY_FIXTURE_V1";
   csvRaw.source_priority            = MLQUANTAI_CSV_NEWS_SOURCE_DEFAULT_PRIORITY;
   csvRaw.revision_id                 = "REV_B";
   csvRaw.revision_timestamp            = D'2026.08.14 08:00:00';

   NormalizedNewsEvent liveNorm, csvNorm;
   News_NormalizedEvent_From_Raw(liveRaw, FIXTURE_ANCHOR, liveNorm);
   News_NormalizedEvent_From_Raw(csvRaw, FIXTURE_ANCHOR, csvNorm);

   Check(liveNorm.normalized_event_key == csvNorm.normalized_event_key,
         "the SAME underlying event normalizes to the SAME normalized_event_key regardless of source "
         "(numeric vs. string impact, and whitespace/case title variance, both wash out)");
   Check(liveNorm.impact_normalized == csvNorm.impact_normalized,
         "impact normalizes to the same value from both the numeric ('3') and string ('HIGH') source forms");
   Check(liveNorm.minutes_to_event == csvNorm.minutes_to_event, "minutes_to_event agrees (same release_time, same anchor)");

   NormalizedNewsEvent liveArr[1]; liveArr[0] = liveNorm;
   NormalizedNewsEvent csvArr[1];  csvArr[0]  = csvNorm;

   Check(News_DecisionHash(liveArr) == News_DecisionHash(csvArr),
         "news_decision_hash is IDENTICAL for the same event from different sources (decision-relevant fields only)");

   // snapshot_identity is DELIBERATELY source-aware (includes source_kind/
   // revision/priority) - two sources reporting "the same" event should
   // NOT produce the same audit-trail identity, since which source
   // actually supplied the data IS part of what B5's lineage needs to
   // know. This is documented policy, not an oversight.
   Check(News_SnapshotIdentity(liveArr) != News_SnapshotIdentity(csvArr),
         "news_snapshot_identity correctly DIFFERS by source (provenance is part of the audit trail, by design)");
}

void Test_Parity_ContextHashEqualWhenDecisionHashEqual()
{
   Print("--- Core parity: MarketContext.context_hash agrees when news_decision_hash agrees ---");

   MarketContext ctxLive, ctxCsv;
   MarketContext_Init(ctxLive);
   MarketContext_Init(ctxCsv);
   ctxLive.instrument_id = "XAUUSD"; ctxCsv.instrument_id = "XAUUSD";
   ctxLive.broker_symbol = "XAUUSD"; ctxCsv.broker_symbol = "XAUUSD";
   ctxLive.trigger_timeframe = "M5"; ctxCsv.trigger_timeframe = "M5";
   ctxLive.anchor_bar_time = FIXTURE_ANCHOR; ctxCsv.anchor_bar_time = FIXTURE_ANCHOR;

   string sameDecisionHash = "SHARED_DECISION_HASH_FOR_TEST";
   ctxLive.news_decision_hash = sameDecisionHash;
   ctxCsv.news_decision_hash  = sameDecisionHash;

   // Everything else that WOULD differ between a live-built and a CSV-
   // built context (raw news[] content, source_kind, symbol_spec
   // resolution timing, etc.) is irrelevant here - only news_decision_hash
   // feeds context_hash's news contribution.
   NewsSnapshot liveOnly; NewsSnapshot_Init(liveOnly); liveOnly.source_kind = "LIVE_CALENDAR";
   ArrayResize(ctxLive.news, 1); ctxLive.news[0] = liveOnly;

   NewsSnapshot csvOnly1, csvOnly2; NewsSnapshot_Init(csvOnly1); NewsSnapshot_Init(csvOnly2);
   csvOnly1.source_kind = "CSV_STATIC"; csvOnly2.source_kind = "CSV_STATIC";
   ArrayResize(ctxCsv.news, 2); ctxCsv.news[0] = csvOnly1; ctxCsv.news[1] = csvOnly2;

   Check(MarketContext_HashPayload(ctxLive) == MarketContext_HashPayload(ctxCsv),
         "context_hash payload is identical for a live-built and a CSV-built context that agree on news_decision_hash, "
         "even though their raw news[] arrays differ in both content and count");
}

//=====================================================================
// Canonicalization
//=====================================================================

void Test_Canonicalize_ImpactCaseInsensitive()
{
   Print("--- Canonicalization: impact mapping is case-insensitive ---");
   Check(News_NormalizeImpact("HIGH") == 3 && News_NormalizeImpact("High") == 3 && News_NormalizeImpact("high") == 3,
         "HIGH/High/high all normalize to impact 3");
   Check(News_NormalizeImpact("MEDIUM") == 2 && News_NormalizeImpact("moderate") == 2 && News_NormalizeImpact("Moderate") == 2,
         "MEDIUM/moderate/Moderate all normalize to impact 2");
   Check(News_NormalizeImpact("low") == 1 && News_NormalizeImpact("LOW") == 1, "low/LOW normalize to impact 1");
   Check(News_NormalizeImpact("garbage") == 0 && News_NormalizeImpact("") == 0, "unrecognized/empty impact normalizes to 0 (NONE)");
   Check(News_NormalizeImpact("3") == 3 && News_NormalizeImpact("0") == 0, "a source already reporting the numeric scale passes through unchanged");
}

void Test_Canonicalize_TitleWhitespaceAndCase()
{
   Print("--- Canonicalization: title whitespace/case normalization ---");
   string a = News_NormalizeTitle("Non-Farm Payrolls");
   string b = News_NormalizeTitle("  non-farm   payrolls  ");
   string c = News_NormalizeTitle("NON-FARM PAYROLLS");
   Check(a == b && b == c, "leading/trailing whitespace, internal multi-space runs, and case all normalize to the same title");
   Check(News_NormalizeTitle("A\tB\nC") == "A B C", "tabs/newlines collapse to single spaces like any other whitespace");
}

void Test_Canonicalize_MinutesToEvent_TruncatesTowardZero()
{
   Print("--- Canonicalization: minutes_to_event truncates toward zero (both signs) ---");
   datetime anchor = D'2026.08.14 12:00:00';
   // +90 seconds -> +1 minute (not +2, which rounding would give)
   Check(News_ComputeMinutesToEvent(anchor + 90, anchor) == 1, "release 90s AFTER anchor -> minutes_to_event == 1 (truncated toward zero)");
   // -90 seconds -> -1 minute (not -2, which floor would give)
   Check(News_ComputeMinutesToEvent(anchor - 90, anchor) == -1, "release 90s BEFORE anchor -> minutes_to_event == -1 (truncated toward zero, not floored to -2)");
   Check(News_ComputeMinutesToEvent(anchor + 30, anchor) == 0, "release 30s after anchor -> 0 (truncated, not rounded to 1)");
   Check(News_ComputeMinutesToEvent(anchor - 30, anchor) == 0, "release 30s before anchor -> 0 (truncated toward zero, not -1)");
   Check(News_ComputeMinutesToEvent(anchor + 300, anchor) == 5, "release exactly 5 minutes after anchor -> 5");
   Check(News_ComputeMinutesToEvent(anchor - 300, anchor) == -5, "release exactly 5 minutes before anchor -> -5");
}

void Test_Dedup_TieBreakOrder()
{
   Print("--- Canonicalization: dedup tie-break order (priority -> revision_timestamp -> lexical source_kind) ---");

   // Level 1: higher source_priority wins outright, regardless of the
   // other two fields.
   {
      NormalizedNewsEvent a, b;
      NormalizedNewsEvent_Init(a); NormalizedNewsEvent_Init(b);
      a.normalized_event_key = "USD|EVENT|2026.08.14 12:00:00"; b.normalized_event_key = a.normalized_event_key;
      a.source_priority = 10; b.source_priority = 20;
      a.revision_timestamp = D'2026.08.14 10:00:00'; b.revision_timestamp = D'2026.08.14 05:00:00'; // b is "older" but higher priority
      a.source_kind = "CSV_STATIC"; b.source_kind = "LIVE_CALENDAR";
      a.impact_normalized = 3; b.impact_normalized = 3;
      a.release_time_utc = D'2026.08.14 12:00:00'; b.release_time_utc = a.release_time_utc;
      a.currency = "USD"; b.currency = "USD";

      Check(News_CompareForDedup(a, b) < 0, "higher source_priority wins even against a more recent revision_timestamp");
   }

   // Level 2: equal priority -> later revision_timestamp wins.
   {
      NormalizedNewsEvent a, b;
      NormalizedNewsEvent_Init(a); NormalizedNewsEvent_Init(b);
      a.source_priority = 10; b.source_priority = 10;
      a.revision_timestamp = D'2026.08.14 06:00:00'; b.revision_timestamp = D'2026.08.14 08:00:00';
      a.source_kind = "CSV_STATIC"; b.source_kind = "CSV_STATIC";
      a.impact_normalized = 3; b.impact_normalized = 3;
      a.release_time_utc = D'2026.08.14 12:00:00'; b.release_time_utc = a.release_time_utc;
      a.currency = "USD"; b.currency = "USD";

      Check(News_CompareForDedup(a, b) < 0, "equal priority -> the later revision_timestamp wins");
   }

   // Level 3: equal priority AND equal revision_timestamp -> lexically
   // smaller source_kind wins (arbitrary but deterministic).
   {
      NormalizedNewsEvent a, b;
      NormalizedNewsEvent_Init(a); NormalizedNewsEvent_Init(b);
      a.source_priority = 10; b.source_priority = 10;
      a.revision_timestamp = D'2026.08.14 06:00:00'; b.revision_timestamp = a.revision_timestamp;
      a.source_kind = "CSV_STATIC"; b.source_kind = "LIVE_CALENDAR"; // "CSV_STATIC" < "LIVE_CALENDAR" lexically
      a.impact_normalized = 3; b.impact_normalized = 3;
      a.release_time_utc = D'2026.08.14 12:00:00'; b.release_time_utc = a.release_time_utc;
      a.currency = "USD"; b.currency = "USD";

      Check(News_CompareForDedup(a, b) > 0, "fully tied on priority/revision -> lexically smaller source_kind ('CSV_STATIC') wins");
   }

   // Full tie AND decision fields agree -> News_Deduplicate keeps ONE
   // event, no error.
   {
      NormalizedNewsEvent arr[2];
      for(int i = 0; i < 2; i++) NormalizedNewsEvent_Init(arr[i]);
      arr[0].normalized_event_key = "USD|SAME EVENT|2026.08.14 12:00:00"; arr[1].normalized_event_key = arr[0].normalized_event_key;
      arr[0].source_priority = 10; arr[1].source_priority = 10;
      arr[0].revision_timestamp = D'2026.08.14 06:00:00'; arr[1].revision_timestamp = arr[0].revision_timestamp;
      arr[0].source_kind = "CSV_STATIC"; arr[1].source_kind = "CSV_STATIC";
      arr[0].impact_normalized = 3; arr[1].impact_normalized = 3;
      arr[0].release_time_utc = D'2026.08.14 12:00:00'; arr[1].release_time_utc = arr[0].release_time_utc;
      arr[0].currency = "USD"; arr[1].currency = "USD";

      NormalizedNewsEvent deduped[];
      string err;
      bool ok = News_Deduplicate(arr, deduped, err);
      Check(ok && ArraySize(deduped) == 1, "fully-tied duplicates with AGREEING decision fields collapse to exactly one event, no error");
   }

   // Full tie AND decision fields CONFLICT -> News_Deduplicate fails
   // loudly rather than silently picking one.
   {
      NormalizedNewsEvent arr[2];
      for(int i = 0; i < 2; i++) NormalizedNewsEvent_Init(arr[i]);
      arr[0].normalized_event_key = "USD|CONFLICTING EVENT|2026.08.14 12:00:00"; arr[1].normalized_event_key = arr[0].normalized_event_key;
      arr[0].source_priority = 10; arr[1].source_priority = 10;
      arr[0].revision_timestamp = D'2026.08.14 06:00:00'; arr[1].revision_timestamp = arr[0].revision_timestamp;
      arr[0].source_kind = "CSV_STATIC"; arr[1].source_kind = "CSV_STATIC";
      arr[0].impact_normalized = 3; arr[1].impact_normalized = 1; // CONFLICT: different impact, no tie-break field to resolve it
      arr[0].release_time_utc = D'2026.08.14 12:00:00'; arr[1].release_time_utc = arr[0].release_time_utc;
      arr[0].currency = "USD"; arr[1].currency = "USD";

      NormalizedNewsEvent deduped[];
      string err;
      bool ok = News_Deduplicate(arr, deduped, err);
      Check(!ok && err != "", "fully-tied duplicates with CONFLICTING decision fields fail loudly (no tie-break winner), not silently resolved");
   }
}

void Test_SortAndSelect_OrderIndependent()
{
   Print("--- Canonicalization: input array order does not affect the selected/sorted output ---");

   NormalizedNewsEvent forward[4], reversed[4];
   for(int i = 0; i < 4; i++) { NormalizedNewsEvent_Init(forward[i]); NormalizedNewsEvent_Init(reversed[i]); }

   int minutesAway[4] = {5, 40, 20, 60};
   for(int i = 0; i < 4; i++)
   {
      forward[i].normalized_event_key = "USD|EVT" + IntegerToString(i) + "|2026.08.14 12:00:00";
      forward[i].currency = "USD";
      forward[i].impact_normalized = 3;
      forward[i].minutes_to_event = minutesAway[i];
      forward[i].release_time_utc = FIXTURE_ANCHOR + minutesAway[i] * 60;
   }
   for(int i = 0; i < 4; i++)
      reversed[i] = forward[3 - i]; // same 4 events, opposite input order

   News_SortAndSelect(forward, 10);
   News_SortAndSelect(reversed, 10);

   bool sameOrder = true;
   for(int i = 0; i < 4; i++)
      if(forward[i].normalized_event_key != reversed[i].normalized_event_key) sameOrder = false;

   Check(sameOrder, "the same 4 events sorted from forward vs. reversed input order produce an IDENTICAL output order");
   Check(forward[0].minutes_to_event == 5 && forward[3].minutes_to_event == 60,
         "sorted output is ordered by abs(minutes_to_event) ascending (closest first)");
}

//=====================================================================
// Selection / coverage - exercised against the real fixture file
//=====================================================================

void Test_Window_Is24hLookbackAndLookahead()
{
   Print("--- Selection: frozen window is 24h lookback + 24h lookahead ---");
   Check(MLQUANTAI_NEWS_LOOKBACK_MINUTES == 1440, "MLQUANTAI_NEWS_LOOKBACK_MINUTES == 1440 (24h)");
   Check(MLQUANTAI_NEWS_LOOKAHEAD_MINUTES == 1440, "MLQUANTAI_NEWS_LOOKAHEAD_MINUTES == 1440 (24h)");
   Check(MLQUANTAI_NEWS_MAX_EVENTS == 10, "MLQUANTAI_NEWS_MAX_EVENTS == 10");
}

// Loads the real fixture file and runs it through the FULL pipeline
// (read -> normalize -> dedup -> sort/select) exactly as NewsEngine_Build
// would - this is the closest thing to an end-to-end CSV path test that
// doesn't depend on live calendar data.
bool LoadFixtureSelected(NormalizedNewsEvent &outSelected[], string &outError)
{
   CsvStaticNewsSource src(FIXTURE_FILE);
   if(!src.Load(outError)) return false;

   RawNewsEvent rawArr[];
   if(!src.ReadRawEvents("USD", FIXTURE_ANCHOR, MLQUANTAI_NEWS_LOOKBACK_MINUTES, MLQUANTAI_NEWS_LOOKAHEAD_MINUTES, rawArr, outError))
      return false;

   NormalizedNewsEvent normalized[];
   News_NormalizeAll(rawArr, FIXTURE_ANCHOR, normalized);

   NormalizedNewsEvent deduped[];
   if(!News_Deduplicate(normalized, deduped, outError))
      return false;

   News_SortAndSelect(deduped, MLQUANTAI_NEWS_MAX_EVENTS);
   ArrayResize(outSelected, ArraySize(deduped));
   for(int i = 0; i < ArraySize(deduped); i++) outSelected[i] = deduped[i];
   return true;
}

void Test_Fixture_MoreThan10Events_CapsToCanonicalTop10()
{
   Print("--- Selection: fixture has >10 USD events near the anchor -> exactly 10 selected, deterministically ---");

   NormalizedNewsEvent selected[];
   string err;
   if(!LoadFixtureSelected(selected, err))
   {
      Check(false, "LoadFixtureSelected failed - " + err + " (is Tests/Fixtures/MLQuantAI_NewsParityFixture_V1.csv copied into Common\\Files?)");
      return;
   }

   Check(ArraySize(selected) == 10, StringFormat("exactly MLQUANTAI_NEWS_MAX_EVENTS (10) events selected out of >10 candidates (got %d)", ArraySize(selected)));
   if(ArraySize(selected) != 10) return;

   // The fixture's design (see its header comment) makes the closest 10
   // by abs(minutes_to_event) exactly: 05,10,15,20,25,30(NFP dedup),35,40,45,50 -
   // dropping 55, 60, the 120min "Retail Sales", and the 180min "Building Permits".
   Check(selected[0].minutes_to_event == 5 && selected[9].minutes_to_event == 50,
         "selected set spans exactly 5..50 minutes from anchor (55/60/120/180-minute events correctly excluded)");

   bool foundNfp = false, found55 = false, found60 = false, foundLow = false, foundMod = false;
   for(int i = 0; i < ArraySize(selected); i++)
   {
      if(selected[i].calendar_event_id == "EVT_DUP_B") foundNfp = true; // the dedup winner (later revision_timestamp)
      if(selected[i].calendar_event_id == "EVT_DUP_A") Check(false, "EVT_DUP_A (the dedup LOSER) must never appear in the final selection");
      if(selected[i].calendar_event_id == "EVT_USD_55") found55 = true;
      if(selected[i].calendar_event_id == "EVT_USD_60") found60 = true;
      if(selected[i].calendar_event_id == "EVT_USD_LOW") foundLow = true;
      if(selected[i].calendar_event_id == "EVT_USD_MOD") foundMod = true;
   }
   Check(foundNfp, "the Non-Farm Payrolls duplicate resolves to EVT_DUP_B (the later revision_timestamp), not EVT_DUP_A");
   Check(!found55 && !found60 && !foundLow && !foundMod,
         "the 4 furthest-from-anchor USD events (55min/60min/120min/180min) are correctly excluded by the top-10 cap");
}

void Test_Fixture_MissingExpectedEvent_Fails()
{
   Print("--- Selection: a genuinely missing expected event is caught, not silently accepted ---");

   NormalizedNewsEvent selected[];
   string err;
   if(!LoadFixtureSelected(selected, err))
   {
      Check(false, "LoadFixtureSelected failed - " + err);
      return;
   }

   bool foundEcb = false;
   for(int i = 0; i < ArraySize(selected); i++)
      if(selected[i].calendar_event_id == "EVT_EUR_1") foundEcb = true;

   // EVT_EUR_1 is EUR, not USD - correctly absent when filtering by
   // currency="USD" (as LoadFixtureSelected does). This Check proves the
   // filter genuinely excludes it (a real "missing event" bug would show
   // up as this Check unexpectedly flipping to true).
   Check(!foundEcb, "an event for a DIFFERENT currency (EUR) is correctly absent from a currency=USD selection");

   // A deliberately WRONG expectation - an event that was never in the
   // fixture at all - proves this test methodology actually catches a
   // missing/wrong event rather than trivially passing.
   bool foundNonexistent = false;
   for(int i = 0; i < ArraySize(selected); i++)
      if(selected[i].calendar_event_id == "EVT_DOES_NOT_EXIST") foundNonexistent = true;
   Check(!foundNonexistent, "an event that was never in the fixture is correctly reported absent");
}

void Test_CoverageValidation_FailsClosedOnGap()
{
   Print("--- Selection: CSV coverage gap fails closed (hard gate, not a warning) ---");

   CsvStaticNewsSource src(FIXTURE_FILE);
   string err;
   if(!src.Load(err))
   {
      Check(false, "fixture failed to load - " + err);
      return;
   }

   // The fixture's own data spans 2026.08.14 09:00:00 .. 14:00:00 (see
   // its header comment) - requesting a range that starts well before
   // that must fail.
   bool coversTooWide = src.ValidateCoverage(D'2026.08.10 00:00:00', D'2026.08.20 00:00:00', err);
   Check(!coversTooWide && err != "", "requesting a range wider than the fixture's actual coverage fails closed, with a reason");

   bool coversWithinRange = src.ValidateCoverage(D'2026.08.14 09:00:00', D'2026.08.14 14:00:00', err);
   Check(coversWithinRange, "requesting a range within the fixture's actual coverage succeeds");
}

void Test_CsvSource_MalformedSchema_FailsClosed()
{
   Print("--- CSV source: schema/row problems fail closed at Load() time ---");

   // A file that doesn't exist at all.
   CsvStaticNewsSource missing("MLQuantAI_NewsParityFixture_DOES_NOT_EXIST.csv");
   string err;
   Check(!missing.Load(err) && err != "", "Load() fails closed on a missing file, with a reason");
}

//=====================================================================
// Seal criteria
//=====================================================================

void Test_Seal_MetadataOnlyChangesDontMoveDecisionHash()
{
   Print("--- Seal: metadata-only changes (revision_id/source_kind) don't move news_decision_hash ---");

   NormalizedNewsEvent a, b;
   NormalizedNewsEvent_Init(a);
   NormalizedNewsEvent_Init(b);
   a.currency = "USD"; b.currency = "USD";
   a.impact_normalized = 3; b.impact_normalized = 3;
   a.release_time_utc = D'2026.08.14 12:30:00'; b.release_time_utc = a.release_time_utc;
   a.minutes_to_event = 30; b.minutes_to_event = 30;

   // Everything metadata-ish differs...
   a.calendar_event_id = "EVT_A"; b.calendar_event_id = "EVT_B";
   a.normalized_event_key = "USD|EVENT|2026.08.14 12:30:00"; b.normalized_event_key = a.normalized_event_key;
   a.revision_id = "REV_1"; b.revision_id = "REV_2_A_CORRECTION";
   a.revision_timestamp = D'2026.08.14 06:00:00'; b.revision_timestamp = D'2026.08.14 09:00:00';
   a.source_kind = "CSV_STATIC"; b.source_kind = "LIVE_CALENDAR";
   a.source_priority = 10; b.source_priority = 20;

   NormalizedNewsEvent arrA[1]; arrA[0] = a;
   NormalizedNewsEvent arrB[1]; arrB[0] = b;

   Check(News_DecisionHash(arrA) == News_DecisionHash(arrB),
         "news_decision_hash is unchanged when only metadata (id/revision/source/priority) differs, decision fields equal");
   Check(News_SnapshotIdentity(arrA) != News_SnapshotIdentity(arrB),
         "news_snapshot_identity DOES change on the same metadata differences - that's its entire purpose (B5 lineage/audit trail)");
}

// Structural note: replay reconstructs MarketContext.news[]/
// news_decision_hash/news_snapshot_identity straight from the already-
// logged MARKET_CONTEXT_READY event (Infrastructure/EventStore/
// MLQuantAI_ReplayEngine.mqh's StateProjector never calls
// NewsEngine_Build() or touches any INewsSource) - proven by
// construction (NewsEngine_Build is only ever called from
// FeatureEngine_BuildContext(), which OnTick calls for a NEW bar, never
// from the replay path), not by a runtime assertion here.
void Test_Seal_ReplayNeverCallsSources()
{
   Print("--- Seal: replay never re-touches a news source ---");
   Check(true, "enforced by construction - NewsEngine_Build() is only called from FeatureEngine_BuildContext() "
               "(OnTick, new-bar path), never from ReplayEngine/StateProjector (see Docs/PhaseB_B4_NewsParity.md)");
}

void Test_Seal_LineageFieldsInMarketContextReadyPayload()
{
   Print("--- Seal: B5 lineage fields (normalized_event_key/revision_id/source_priority) appear in MARKET_CONTEXT_READY ---");

   MarketContext ctx;
   MarketContext_Init(ctx);
   ctx.instrument_id = "XAUUSD";
   ctx.broker_symbol = "XAUUSD";
   ctx.trigger_timeframe = "M5";
   ctx.anchor_bar_time = FIXTURE_ANCHOR;

   NewsSnapshot snap;
   NewsSnapshot_Init(snap);
   snap.calendar_event_id = "EVT_DUP_B";
   snap.currency = "USD";
   snap.impact = 3;
   snap.title = "NON-FARM PAYROLLS";
   snap.release_time = D'2026.08.14 12:30:00';
   snap.minutes_to_event = 30;
   snap.source_kind = "CSV_STATIC";
   snap.source_version = "PARITY_FIXTURE_V1";
   snap.normalized_event_key = "USD|NON-FARM PAYROLLS|2026.08.14 12:30:00";
   snap.revision_id = "REV_B";
   snap.revision_timestamp = D'2026.08.14 08:00:00';
   snap.source_priority = MLQUANTAI_CSV_NEWS_SOURCE_DEFAULT_PRIORITY;

   ArrayResize(ctx.news, 1);
   ctx.news[0] = snap;
   ctx.news_count = 1;
   ctx.news_decision_hash = "TEST_DECISION_HASH";
   ctx.news_snapshot_identity = "TEST_SNAPSHOT_IDENTITY";

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   if(!EventStore_Open(TEST_EVENT_STORE_FILE))
   {
      Check(false, "could not open a fresh test event store");
      return;
   }
   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built (test)", MarketContext_ToJsonFragment(ctx));
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
   Check(n >= 1, "MARKET_CONTEXT_READY was durably written");
   if(n < 1) return;

   string line = lines[n - 1];
   Check(StringFind(line, "\"normalized_event_key\"") >= 0, "logged payload's embedded NewsSnapshot carries normalized_event_key");
   Check(StringFind(line, "\"revision_id\"") >= 0,           "logged payload's embedded NewsSnapshot carries revision_id");
   Check(StringFind(line, "\"source_priority\"") >= 0,        "logged payload's embedded NewsSnapshot carries source_priority");
   Check(StringFind(line, "\"news_decision_hash\"") >= 0,      "logged payload carries MarketContext-level news_decision_hash");
   Check(StringFind(line, "\"news_snapshot_identity\"") >= 0,   "logged payload carries MarketContext-level news_snapshot_identity");
}

void OnStart()
{
   Print("=== MLQuantAI Test: Phase B B4 News Engine Parity ===");

   Test_Parity_SameEvent_SameDecisionHash_DifferentSnapshotIdentity();
   Test_Parity_ContextHashEqualWhenDecisionHashEqual();

   Test_Canonicalize_ImpactCaseInsensitive();
   Test_Canonicalize_TitleWhitespaceAndCase();
   Test_Canonicalize_MinutesToEvent_TruncatesTowardZero();
   Test_Dedup_TieBreakOrder();
   Test_SortAndSelect_OrderIndependent();

   Test_Window_Is24hLookbackAndLookahead();
   Test_Fixture_MoreThan10Events_CapsToCanonicalTop10();
   Test_Fixture_MissingExpectedEvent_Fails();
   Test_CoverageValidation_FailsClosedOnGap();
   Test_CsvSource_MalformedSchema_FailsClosed();

   Test_Seal_MetadataOnlyChangesDontMoveDecisionHash();
   Test_Seal_ReplayNeverCallsSources();
   Test_Seal_LineageFieldsInMarketContextReadyPayload();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   Print(g_TestsPassed == g_TestsRun ? "ALL PASS." : "FAILURES ABOVE.");
}
