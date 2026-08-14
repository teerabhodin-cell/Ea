//+------------------------------------------------------------------+
//| MLQuantAI_Test_CandidateDatasetExport.mq5                         |
//| Phase B B6.2 DoD: canonical dataset export - row projection,      |
//| deterministic export, manifest, and end-to-end lineage. Uses the  |
//| real B5 pipeline + real MARKET_CONTEXT_READY events (same pattern  |
//| B6.1's own hardening suite established) - only                     |
//| MLQuantAI_CandidateDatasetExport.mqh is exercised, B5/B6.1 are not |
//| modified.                                                          |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CandidateDatasetExport.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_CandidateDatasetExport.jsonl"

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
   ctx.news_decision_hash     = "test_news_decision_" + suffix;
   ctx.news_snapshot_identity = "test_news_identity_" + suffix;
}

void FillFillerBars(MqlRates &window[], datetime t0)
{
   for(int i = 0; i < 59; i++)
      MakeBar(window[i], t0 + i * PERIOD_SEC_M5, 105.00, 105.20, 104.80, 105.00, 100, 20);
}

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

bool BuildAndEmitCandidate(TradeCandidate &c, string suffix, int dayOffset, bool logContext = true)
{
   MarketContext ctx; BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.01.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   if(logContext)
      EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx));

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;
   return CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits);
}

int FindRowIndex(const CandidateDatasetRow &rows[], string candidateId)
{
   for(int i = 0; i < ArraySize(rows); i++)
      if(rows[i].candidate_id == candidateId) return i;
   return -1;
}

//=====================================================================
void Test_RowProjection()
{
   Print("--- row projection: candidate + context join produces complete provenance ---");
   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   EventStore_Open(TEST_EVENT_STORE_FILE);
   TradeCandidate a;
   Check(BuildAndEmitCandidate(a, "ROWPROJ", 1, true), "sanity: candidate built+emitted with context");
   EventStore_Close();

   CandidateDatasetRow rows[];
   CandidateDatasetManifest manifest;
   Check(CandidateDatasetExport_BuildDataset(TEST_EVENT_STORE_FILE, rows, manifest), "dataset builds successfully");
   Check(ArraySize(rows) == 1, "exactly one row");

   int idx = FindRowIndex(rows, a.candidate_id);
   Check(idx >= 0, "the candidate's row is present");
   CandidateDatasetRow row = rows[idx];

   Check(row.candidate_id == a.candidate_id, "row.candidate_id matches");
   Check(row.root_event_id == a.root_event_id, "row.root_event_id matches");
   Check(row.candidate_hash == a.candidate_hash, "row.candidate_hash matches");
   Check(row.detector_hash == a.detector_hash, "row.detector_hash matches");
   Check(row.context_event_id == a.context_event_id, "row.context_event_id matches");
   Check(row.context_hash == a.context_hash, "row.context_hash matches");
   Check(row.side == a.side, "row.side matches");
   Check(row.setup_anchor_bar_time == a.setup_anchor_bar_time, "row.setup_anchor_bar_time matches");
   Check(row.expiry_time == a.expiry_time, "row.expiry_time matches");
   Check(row.entry_hint == a.entry_hint && row.sl_hint == a.sl_hint && row.tp_hint == a.tp_hint, "row entry/sl/tp hints match");
   Check(row.trigger_reason_mask == a.trigger_reason_mask, "row.trigger_reason_mask matches");
   Check(row.strategy_id == a.strategy_id, "row.strategy_id matches");
   Check(row.strategy_name == a.strategy_name, "row.strategy_name matches (derived from strategy_id)");
   Check(row.candidate_state == "CREATED", "row.candidate_state == CREATED");

   Check(row.context_joined, "row.context_joined == true");
   Check(row.instrument_id == "XAUUSD", "row.instrument_id joined correctly from MARKET_CONTEXT_READY");
   Check(row.trigger_timeframe == "M5", "row.trigger_timeframe joined correctly");
   Check(row.news_decision_hash == "test_news_decision_ROWPROJ", "row.news_decision_hash joined correctly");
   Check(row.news_snapshot_identity == "test_news_identity_ROWPROJ", "row.news_snapshot_identity joined correctly");

   Check(row.resolved_zone_kind == "", "resolved_zone_kind is NOT AVAILABLE (documented gap) - exports empty");
   Check(row.swept_level == 0 && row.mss_confirmation_price == 0, "swept_level/mss_confirmation_price are NOT AVAILABLE - export zero");
   Check(row.strategy_version == "", "strategy_version is NOT AVAILABLE - exports empty");

   Check(row.has_liquidity_sweep && row.has_mss && row.has_fvg && !row.has_order_block,
         "derived has_* flags match the fixture's known reason mask (FVG resolution)");

   Check(manifest.dataset_schema_version == MLQUANTAI_DATASET_SCHEMA_V1, "manifest schema version set");
   Check(manifest.row_count == 1, "manifest row_count == 1");
   Check(manifest.rejected_count == 0, "manifest rejected_count == 0 for a clean store");
   Check(manifest.dataset_hash != "", "manifest dataset_hash is non-empty");
}

void Test_NoDuplicateCandidateIds()
{
   Print("--- no duplicate candidate_id in export ---");
   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   EventStore_Open(TEST_EVENT_STORE_FILE);
   TradeCandidate a, b, c;
   BuildAndEmitCandidate(a, "DUPA", 10, true);
   BuildAndEmitCandidate(b, "DUPB", 11, true);
   BuildAndEmitCandidate(c, "DUPC", 12, true);
   EventStore_Close();

   CandidateDatasetRow rows[];
   CandidateDatasetManifest manifest;
   Check(CandidateDatasetExport_BuildDataset(TEST_EVENT_STORE_FILE, rows, manifest), "dataset builds successfully");
   Check(ArraySize(rows) == 3, "exactly 3 rows");

   bool anyDup = false;
   for(int i = 0; i < ArraySize(rows); i++)
      for(int j = i + 1; j < ArraySize(rows); j++)
         if(rows[i].candidate_id == rows[j].candidate_id) anyDup = true;
   Check(!anyDup, "no two rows share a candidate_id");
}

void Test_StableOrdering()
{
   Print("--- stable ordering: setup_anchor_bar_time ASC, candidate_id ASC tiebreak ---");
   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   EventStore_Open(TEST_EVENT_STORE_FILE);
   // Emit deliberately OUT of chronological order: dayOffset 30 (latest
   // anchor) first, then 20, then 10 (earliest anchor) last.
   TradeCandidate late, mid, early;
   BuildAndEmitCandidate(late, "ORDERLATE", 30, true);
   BuildAndEmitCandidate(mid, "ORDERMID", 20, true);
   BuildAndEmitCandidate(early, "ORDEREARLY", 10, true);
   EventStore_Close();

   CandidateDatasetRow rows[];
   CandidateDatasetManifest manifest;
   Check(CandidateDatasetExport_BuildDataset(TEST_EVENT_STORE_FILE, rows, manifest), "dataset builds successfully");
   Check(ArraySize(rows) == 3, "exactly 3 rows");

   Check(rows[0].candidate_id == early.candidate_id, "row 0 is the earliest anchor (emitted last)");
   Check(rows[1].candidate_id == mid.candidate_id, "row 1 is the middle anchor");
   Check(rows[2].candidate_id == late.candidate_id, "row 2 is the latest anchor (emitted first)");
   Check(rows[0].setup_anchor_bar_time < rows[1].setup_anchor_bar_time &&
         rows[1].setup_anchor_bar_time < rows[2].setup_anchor_bar_time,
         "setup_anchor_bar_time is strictly ascending across the sorted rows");
}

void Test_DeterministicExport()
{
   Print("--- deterministic export: same store -> byte-identical JSONL, same hashes ---");
   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   EventStore_Open(TEST_EVENT_STORE_FILE);
   TradeCandidate a, b;
   BuildAndEmitCandidate(a, "DETA", 40, true);
   BuildAndEmitCandidate(b, "DETB", 41, true);
   EventStore_Close();

   CandidateDatasetRow rows1[];
   CandidateDatasetManifest manifest1;
   CandidateDatasetExport_BuildDataset(TEST_EVENT_STORE_FILE, rows1, manifest1);
   string jsonl1 = CandidateDatasetExport_RowsToJsonLines(rows1);

   CandidateDatasetRow rows2[];
   CandidateDatasetManifest manifest2;
   CandidateDatasetExport_BuildDataset(TEST_EVENT_STORE_FILE, rows2, manifest2);
   string jsonl2 = CandidateDatasetExport_RowsToJsonLines(rows2);

   Check(jsonl1 == jsonl2, "two exports of the identical store produce byte-identical JSONL text");
   Check(manifest1.dataset_hash == manifest2.dataset_hash, "both exports produce the identical dataset_hash");
   Check(manifest1.dataset_hash != "", "dataset_hash is non-empty");

   for(int i = 0; i < ArraySize(rows1); i++)
      Check(rows1[i].row_hash == rows2[i].row_hash, "row " + IntegerToString(i) + "'s row_hash is identical across both exports");

   // export_time is metadata only - must never affect dataset_hash.
   manifest1.export_time = manifest1.export_time + 999999; // simulate a very different wall-clock export moment
   string recomputedHash = CandidateDatasetExport_DatasetHash(rows1);
   Check(recomputedHash == manifest1.dataset_hash, "dataset_hash is unaffected by export_time - content-only");
}

void Test_HashChangesWithContent()
{
   Print("--- dataset_hash changes when row content changes ---");
   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   EventStore_Open(TEST_EVENT_STORE_FILE);
   TradeCandidate a;
   BuildAndEmitCandidate(a, "HASHCHANGE", 50, true);
   EventStore_Close();

   CandidateDatasetRow rows[];
   CandidateDatasetManifest manifest;
   CandidateDatasetExport_BuildDataset(TEST_EVENT_STORE_FILE, rows, manifest);
   string originalHash = manifest.dataset_hash;

   rows[0].instrument_id = "TAMPERED";
   rows[0].row_hash = CandidateDatasetExport_RowHash(rows[0]);
   string tamperedHash = CandidateDatasetExport_DatasetHash(rows);
   Check(tamperedHash != originalHash, "tampering a joined field moves both the row_hash and the dataset_hash");
}

void Test_OrphanBlocksWholeExport()
{
   Print("--- an orphan candidate (no MARKET_CONTEXT_READY) blocks the WHOLE export, consistent with B6.1's atomicity ---");
   string orphanFile = "MLQuantAI_Test_CandidateDatasetExport_Orphan.jsonl";
   FileDelete(orphanFile, FILE_COMMON);
   EventStore_Open(orphanFile);
   TradeCandidate good, orphan;
   BuildAndEmitCandidate(good, "EXPGOOD", 60, true);
   BuildAndEmitCandidate(orphan, "EXPORPHAN", 61, false); // no context logged
   EventStore_Close();

   CandidateDatasetRow rows[];
   CandidateDatasetManifest manifest;
   bool ok = CandidateDatasetExport_BuildDataset(orphanFile, rows, manifest);
   Check(!ok, "the export fails entirely - it does not silently produce a 1-row dataset excluding the orphan");
   Check(ArraySize(rows) == 0, "rows[] stays empty on a failed export");
}

void Test_ReadOnly_NoStoreMutation()
{
   Print("--- export is read-only: no event append, no line count change ---");
   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   EventStore_Open(TEST_EVENT_STORE_FILE);
   TradeCandidate a;
   BuildAndEmitCandidate(a, "READONLY", 70, true);
   EventStore_Close();

   string linesBefore[];
   int countBefore = EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesBefore);

   CandidateDatasetRow rows[];
   CandidateDatasetManifest manifest;
   CandidateDatasetExport_BuildDataset(TEST_EVENT_STORE_FILE, rows, manifest);
   CandidateDatasetExport_RowsToJsonLines(rows); // also exercise serialization - still must not touch the store

   string linesAfter[];
   int countAfter = EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);

   Check(countBefore == countAfter, "the event store's line count is unchanged after building and serializing a dataset");
   bool linesIdentical = true;
   for(int i = 0; i < countBefore; i++)
      if(linesBefore[i] != linesAfter[i]) linesIdentical = false;
   Check(linesIdentical, "every line in the store is byte-identical before and after export");
}

void Test_EndToEndLineage()
{
   Print("--- end-to-end lineage: MARKET_CONTEXT_READY -> CANDIDATE_CREATED -> registry -> dataset row ---");
   string lineageFile = "MLQuantAI_Test_CandidateDatasetExport_Lineage.jsonl";
   FileDelete(lineageFile, FILE_COMMON);
   EventStore_Open(lineageFile);

   MarketContext ctx; BuildBaseContext(ctx, "LINEAGE");
   datetime t0 = D'2026.01.01 00:00:00' + 80 * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;
   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx));

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(r.detected, "sanity: detector fires");

   TradeCandidate c;
   Check(CRT_ToTradeCandidate(ctx, r, c), "sanity: candidate mapped");
   Check(CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits), "sanity: candidate emitted");
   EventStore_Close();

   // Step 1: registry rebuild finds the candidate (B6.1's own contract).
   CandidateProjectionRecord rec;
   CandidateDatasetRow rows[];
   CandidateDatasetManifest manifest;
   Check(CandidateDatasetExport_BuildDataset(lineageFile, rows, manifest), "dataset builds successfully");
   Check(CandidateProjection_TryGet(c.candidate_id, rec), "the candidate is present in the rebuilt registry (Step: CANDIDATE_CREATED -> registry)");

   // Step 2: the dataset row exists and its identity/lineage hashes
   // trace back exactly to what the detector/mapping/registry computed.
   int idx = FindRowIndex(rows, c.candidate_id);
   Check(idx >= 0, "the candidate has a dataset row (Step: registry -> dataset row)");
   CandidateDatasetRow row = rows[idx];

   Check(row.context_hash == ctx.context_hash, "row.context_hash traces back to the original MarketContext (Step: MARKET_CONTEXT_READY -> row)");
   Check(row.detector_hash == r.detector_hash, "row.detector_hash traces back to the original CRTDetectionResult (Step: detector -> row)");
   Check(row.candidate_hash == c.candidate_hash, "row.candidate_hash traces back to the original TradeCandidate (Step: CANDIDATE_CREATED -> row)");
   Check(row.candidate_hash == rec.candidate_hash, "row.candidate_hash matches the registry record's own candidate_hash (Step: registry -> row, no drift)");
   Check(row.instrument_id == ctx.instrument_id, "row.instrument_id traces back to the original MarketContext");
   Check(row.news_decision_hash == ctx.news_decision_hash, "row.news_decision_hash traces back to the original MarketContext");

   // Step 3: the row's own row_hash is reproducible from its content alone.
   string recomputedRowHash = CandidateDatasetExport_RowHash(row);
   Check(recomputedRowHash == row.row_hash, "row_hash is reproducible from the row's own content");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B B6.2 - Candidate Dataset Export ===");

   Test_RowProjection();
   Test_NoDuplicateCandidateIds();
   Test_StableOrdering();
   Test_DeterministicExport();
   Test_HashChangesWithContent();
   Test_OrphanBlocksWholeExport();
   Test_ReadOnly_NoStoreMutation();
   Test_EndToEndLineage();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
