//+------------------------------------------------------------------+
//| MLQuantAI_Test_NewsSchemaEvolution.mq5                           |
//| Phase B B4 seal hardening: proves the pipeline tolerates a news   |
//| event carrying fields the ORIGINAL schema never defined -         |
//| forecast/actual/previous, added additively to RawNewsEvent/       |
//| NormalizedNewsEvent (MLQuantAI_NewsSource.mqh /                   |
//| MLQuantAI_NewsCanonicalizer.mqh) and folded into                  |
//| news_snapshot_identity but NOT news_decision_hash/NewsSnapshot -   |
//| the exact scenario news_schema_version exists to eventually       |
//| support. No CRT/TradeCandidate/execution code exercised here.      |
//|                                                                    |
//| REQUIRES: Tests/Fixtures/MLQuantAI_NewsParityFixture_V1.csv copied|
//| into this terminal's Common\Files folder before running (only the |
//| "V1 payload still parses" check reads it).                        |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Market/MLQuantAI_FeatureEngine.mqh>

#define FIXTURE_FILE "MLQuantAI_NewsParityFixture_V1.csv"
#define FIXTURE_ANCHOR D'2026.08.14 12:00:00'

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

// A "V1-shaped" event: everything a source could always report, with the
// new forecast/actual/previous fields left at their Init() default ("").
void MakeV1Raw(RawNewsEvent &out)
{
   RawNewsEvent_Init(out);
   out.provider_event_id  = "EVT_SCHEMA_V1";
   out.currency             = "USD";
   out.impact_raw            = "HIGH";
   out.title                  = "Non-Farm Payrolls";
   out.release_time            = FIXTURE_ANCHOR + 30 * 60;
   out.source_kind               = "CSV_STATIC";
   out.source_version             = "SCHEMA_TEST_V1";
   out.source_priority             = MLQUANTAI_CSV_NEWS_SOURCE_DEFAULT_PRIORITY;
   out.revision_id                  = "REV_1";
   out.revision_timestamp             = FIXTURE_ANCHOR - 3600;
   // forecast/actual/previous intentionally left at "" - this IS "V1 data".
}

// The same underlying event, but from a "V2" source that also reports
// consensus/actual data - every decision-relevant and lineage-relevant
// field identical to MakeV1Raw() except forecast/actual/previous.
void MakeV2Raw(RawNewsEvent &out)
{
   MakeV1Raw(out);
   out.forecast = "180K";
   out.actual   = "190K";
   out.previous = "175K";
}

void Test_SchemaEvolution_V2Metadata_MovesIdentity_NotDecision()
{
   Print("--- Schema evolution: V2 additive metadata (forecast/actual/previous) moves news_snapshot_identity only ---");

   RawNewsEvent v1Raw, v2Raw;
   MakeV1Raw(v1Raw);
   MakeV2Raw(v2Raw);

   NormalizedNewsEvent v1Norm, v2Norm;
   News_NormalizedEvent_From_Raw(v1Raw, FIXTURE_ANCHOR, v1Norm);
   News_NormalizedEvent_From_Raw(v2Raw, FIXTURE_ANCHOR, v2Norm);

   Check(v1Norm.forecast == "" && v1Norm.actual == "" && v1Norm.previous == "",
         "the V1 event normalizes with forecast/actual/previous still empty");
   Check(v2Norm.forecast == "180K" && v2Norm.actual == "190K" && v2Norm.previous == "175K",
         "the V2 event's forecast/actual/previous survive raw->normalized unchanged");

   NormalizedNewsEvent v1Arr[1]; v1Arr[0] = v1Norm;
   NormalizedNewsEvent v2Arr[1]; v2Arr[0] = v2Norm;

   Check(News_DecisionHash(v1Arr) == News_DecisionHash(v2Arr),
         "news_decision_hash is IDENTICAL between the V1 and V2 forms - forecast/actual/previous never reach it");
   Check(News_SnapshotIdentity(v1Arr) != News_SnapshotIdentity(v2Arr),
         "news_snapshot_identity DIFFERS between the V1 and V2 forms - the audit trail sees the new consensus data");
}

void Test_SchemaEvolution_ContextHashUnaffectedByV2Metadata()
{
   Print("--- Schema evolution: MarketContext.context_hash is unaffected by V2-only metadata ---");

   RawNewsEvent v1Raw, v2Raw;
   MakeV1Raw(v1Raw);
   MakeV2Raw(v2Raw);

   NormalizedNewsEvent v1Norm, v2Norm;
   News_NormalizedEvent_From_Raw(v1Raw, FIXTURE_ANCHOR, v1Norm);
   News_NormalizedEvent_From_Raw(v2Raw, FIXTURE_ANCHOR, v2Norm);

   NormalizedNewsEvent v1Arr[1]; v1Arr[0] = v1Norm;
   NormalizedNewsEvent v2Arr[1]; v2Arr[0] = v2Norm;

   MarketContext ctxV1, ctxV2;
   MarketContext_Init(ctxV1);
   MarketContext_Init(ctxV2);
   ctxV1.instrument_id = "XAUUSD"; ctxV2.instrument_id = "XAUUSD";
   ctxV1.broker_symbol = "XAUUSD"; ctxV2.broker_symbol = "XAUUSD";
   ctxV1.trigger_timeframe = "M5"; ctxV2.trigger_timeframe = "M5";
   ctxV1.anchor_bar_time = FIXTURE_ANCHOR; ctxV2.anchor_bar_time = FIXTURE_ANCHOR;

   // Same underlying decision-relevant content -> same news_decision_hash,
   // even though the two contexts embed structurally different news[]
   // (V2's snapshot_identity differs, and NewsSnapshot itself never
   // carries forecast/actual/previous at all - see News_ToSnapshot()).
   ctxV1.news_decision_hash = News_DecisionHash(v1Arr);
   ctxV2.news_decision_hash = News_DecisionHash(v2Arr);
   Check(ctxV1.news_decision_hash == ctxV2.news_decision_hash, "precondition: V1/V2 news_decision_hash agree");

   NewsSnapshot snapV1[]; News_ToSnapshotArray(v1Arr, snapV1);
   NewsSnapshot snapV2[]; News_ToSnapshotArray(v2Arr, snapV2);
   ArrayResize(ctxV1.news, ArraySize(snapV1)); for(int i = 0; i < ArraySize(snapV1); i++) ctxV1.news[i] = snapV1[i];
   ArrayResize(ctxV2.news, ArraySize(snapV2)); for(int i = 0; i < ArraySize(snapV2); i++) ctxV2.news[i] = snapV2[i];

   Check(MarketContext_HashPayload(ctxV1) == MarketContext_HashPayload(ctxV2),
         "context_hash payload is identical for the V1-sourced and V2-sourced context, "
         "even though the underlying raw data carried different amounts of metadata");
}

void Test_SchemaEvolution_NormalizedEventKeyStableAcrossVersions()
{
   Print("--- Schema evolution: normalized_event_key is stable regardless of V1/V2 metadata ---");

   RawNewsEvent v1Raw, v2Raw;
   MakeV1Raw(v1Raw);
   MakeV2Raw(v2Raw);

   NormalizedNewsEvent v1Norm, v2Norm;
   News_NormalizedEvent_From_Raw(v1Raw, FIXTURE_ANCHOR, v1Norm);
   News_NormalizedEvent_From_Raw(v2Raw, FIXTURE_ANCHOR, v2Norm);

   Check(v1Norm.normalized_event_key == v2Norm.normalized_event_key,
         "the same underlying event produces the SAME normalized_event_key whether or not the source reports forecast/actual/previous - "
         "identity is currency/title/release_time only, never the new fields");
}

void Test_SchemaEvolution_V1PayloadStillParses()
{
   Print("--- Schema evolution: the frozen V1 CSV fixture still loads/normalizes correctly after V2 fields exist ---");

   CsvStaticNewsSource src(FIXTURE_FILE);
   string err;
   if(!src.Load(err))
   {
      Check(false, "the frozen V1 CSV fixture failed to load - " + err +
                    " (is Tests/Fixtures/MLQuantAI_NewsParityFixture_V1.csv copied into Common\\Files?)");
      return;
   }
   Check(true, "the frozen 7-column V1 CSV fixture still loads successfully - adding forecast/actual/previous "
               "to RawNewsEvent/NormalizedNewsEvent did not touch the CSV format");

   RawNewsEvent rawArr[];
   bool readOk = src.ReadRawEvents("USD", FIXTURE_ANCHOR, MLQUANTAI_NEWS_LOOKBACK_MINUTES, MLQUANTAI_NEWS_LOOKAHEAD_MINUTES, rawArr, err);
   Check(readOk && ArraySize(rawArr) > 0, "V1 CSV rows still read successfully through ReadRawEvents");
   if(!readOk || ArraySize(rawArr) == 0) return;

   bool allRawEmpty = true;
   for(int i = 0; i < ArraySize(rawArr); i++)
      if(rawArr[i].forecast != "" || rawArr[i].actual != "" || rawArr[i].previous != "") allRawEmpty = false;
   Check(allRawEmpty, "V1 CSV rows (no forecast/actual/previous columns) read back with those fields empty, not garbage/misaligned");

   NormalizedNewsEvent normalized[];
   News_NormalizeAll(rawArr, FIXTURE_ANCHOR, normalized);
   Check(ArraySize(normalized) == ArraySize(rawArr), "every V1 raw row normalizes without error alongside the new V2 fields existing");

   bool allNormEmpty = true;
   for(int i = 0; i < ArraySize(normalized); i++)
      if(normalized[i].forecast != "" || normalized[i].actual != "" || normalized[i].previous != "") allNormEmpty = false;
   Check(allNormEmpty, "normalized V1 events carry empty forecast/actual/previous straight through, matching the raw rows");

   NormalizedNewsEvent deduped[];
   string dedupErr;
   bool dedupOk = News_Deduplicate(normalized, deduped, dedupErr);
   Check(dedupOk, "V1 rows still dedup without error - " + dedupErr);
   if(dedupOk)
   {
      News_SortAndSelect(deduped, MLQUANTAI_NEWS_MAX_EVENTS);
      string decisionHash = News_DecisionHash(deduped);
      string identityHash = News_SnapshotIdentity(deduped);
      Check(decisionHash != "" && identityHash != "", "V1-only data still produces non-empty decision/identity hashes end to end");
   }
}

void OnStart()
{
   Print("=== MLQuantAI Test: Phase B B4 News Schema Evolution ===");

   Test_SchemaEvolution_V2Metadata_MovesIdentity_NotDecision();
   Test_SchemaEvolution_ContextHashUnaffectedByV2Metadata();
   Test_SchemaEvolution_NormalizedEventKeyStableAcrossVersions();
   Test_SchemaEvolution_V1PayloadStillParses();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   Print(g_TestsPassed == g_TestsRun ? "ALL PASS." : "FAILURES ABOVE.");
}
