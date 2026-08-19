//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_2_Commit4_SealRegression.mq5                    |
//| Phase B8.2 Commit 4 DoD, per                                        |
//| Docs/PhaseB_B8_2_Commit4_SealRegression.md: proves the full          |
//| MARKET_CONTEXT_READY -> CANDIDATE_CREATED -> CandidateProjection    |
//| -> Candidate_ToRiskPlan -> RISK_PLAN_CREATED -> RiskPlanProjection  |
//| -> Candidate_ToFeatureSnapshot -> FEATURE_SNAPSHOT_CREATED ->        |
//| FeatureSnapshotProjection -> RealizedOutcome_Build ->                |
//| TRADE_OUTCOME_LABELED -> RealizedOutcomeProjection ->                |
//| TrainingDatasetExport_BuildDataset chain composes correctly end to  |
//| end. Adds ZERO new production behavior - no B5/B6/B7/B8.1/B8.2      |
//| sealed file touched. Does NOT re-prove anything already covered by  |
//| Commits 1-3's own suites in isolation - see                          |
//| Docs/PhaseB_B8_2_Commit4_SealRegression.md for exactly what is       |
//| genuinely new here: end-to-end linkage, cross-layer failure          |
//| propagation, incomplete-vs-corrupt, leakage across a cohort,         |
//| collision-anywhere-blocks-export, export atomicity, the LABELED_ONLY |
//| pure-filter proof, and full-chain multi-candidate restart.           |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RiskPlanEventEmission.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_FeatureSnapshotEventEmission.mqh>
#include <MLQuantAI/AI/MLQuantAI_RealizedOutcomeBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RealizedOutcomeEventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_TrainingDatasetExport.mqh>

#define MODEL_TARGET_TEST "SETUP_QUALITY_V1"
#define OUTCOME_TIME_OFFSET_SEC (2 * 86400)

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as the Commit 2/3 test files.
//---------------------------------------------------------------------
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
   ctx.atr_m15 = 1.2345;
   ctx.adx_m15 = 25.5;
   ctx.ema_slope_m15 = 0.05;
   ctx.asian_range_high = 105.50;
   ctx.asian_range_low  = 104.50;
   ctx.spread_points_at_anchor = 20.0;
   ctx.news_count = 3;
   ctx.context_event_id = "CTX_b8_2c4_" + suffix;
   ctx.context_hash      = "test_context_hash_b8_2c4_" + suffix;
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

void BuildValidRiskContext(RiskContext &ctx, string suffix)
{
   RiskContext_Init(ctx);
   ctx.symbol_spec.instrument_id = "XAUUSD";
   ctx.symbol_spec.broker_symbol = "XAUUSD" + suffix;
   ctx.symbol_spec.tick_size     = 0.01;
   ctx.symbol_spec.tick_value    = 1.0;
   ctx.symbol_spec.contract_size = 100;
   ctx.symbol_spec.volume_min    = 0.01;
   ctx.symbol_spec.volume_max    = 100.0;
   ctx.symbol_spec.volume_step   = 0.01;
   ctx.symbol_spec.digits        = 2;

   ctx.account.balance = 10000.0;
   ctx.account.equity  = 10000.0;

   ctx.target_risk_percent  = 1.0;
   ctx.sizing_method        = "FIXED_PERCENT_RISK";
   ctx.sizing_rules_version = MLQUANTAI_RISK_SIZING_RULES_V1;

   ctx.risk_context_hash = RiskContext_ComputeHash(ctx);
}

string TamperStringField(string line, string key, string newValue)
{
   string needle = "\"" + key + "\":\"";
   int p = StringFind(line, needle);
   if(p < 0) return line;
   int start = p + StringLen(needle);
   int n = StringLen(line);
   int end = start;
   while(end < n && StringGetCharacter(line, end) != '"') end++;
   return StringSubstr(line, 0, start) + newValue + StringSubstr(line, end);
}

void ResetProjections()
{
   CandidateProjection_Reset();
   RiskPlanProjection_Reset();
   FeatureSnapshotProjection_Reset();
   RealizedOutcomeProjection_Reset();
}

// Builds and emits the full real chain for one candidate:
// MARKET_CONTEXT_READY, CANDIDATE_CREATED, RISK_PLAN_CREATED,
// FEATURE_SNAPSHOT_CREATED. Exposes ctx (unlike the Commit 3 test
// file's own helper) since this file's whole point is cross-checking
// each layer's persisted state against the real inputs that produced
// it. The store must already be open (EventStore_Open) before calling.
bool BuildFullChain(MarketContext &ctx, TradeCandidate &c, RiskPlan &plan, FeatureSnapshot &snapshot, string suffix, int dayOffset)
{
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.01.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx)))
      return false;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;
   if(!CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits)) return false;

   RiskContext riskCtx;
   BuildValidRiskContext(riskCtx, suffix);
   if(!Candidate_ToRiskPlan(c, riskCtx, plan)) return false;
   if(!RiskPlan_EmitRiskPlanCreated(plan)) return false;

   if(!Candidate_ToFeatureSnapshot(c, ctx, snapshot)) return false;
   return FeatureSnapshot_EmitFeatureSnapshotCreated(snapshot);
}

// Context + CANDIDATE_CREATED only - deliberately incomplete, no
// RiskPlan/FeatureSnapshot follows it.
bool BuildIncompleteCandidate(TradeCandidate &c, string suffix, int dayOffset)
{
   MarketContext ctx;
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.01.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx)))
      return false;
   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;
   return CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits);
}

bool BuildAndEmitOutcome(const TradeCandidate &c, datetime anchor, string label, string outcomeRef, string outcomeHash, RealizedOutcome &outOutcome)
{
   datetime outcomeTime = anchor + OUTCOME_TIME_OFFSET_SEC;
   if(!RealizedOutcome_Build(c, label, outcomeRef, outcomeHash, outcomeTime, MLQUANTAI_LABEL_SCHEMA_B8_2_V1, outOutcome))
      return false;
   return RealizedOutcome_EmitTradeOutcomeLabeled(outOutcome);
}

// Finds the row belonging to a given candidate_id in an exported
// rows[] array - convenience for the multi-candidate tests below.
bool FindRowForCandidate(const TrainingDatasetRow &rows[], string candidateId, TrainingDatasetRow &out)
{
   for(int i = 0; i < ArraySize(rows); i++)
      if(rows[i].candidate_id == candidateId) { out = rows[i]; return true; }
   return false;
}

//=====================================================================
void Test_FullChain_EndToEndLinkage()
{
   Print("--- end-to-end: context -> candidate -> plan -> snapshot -> outcome -> row hash/ID linkage matches at every hop ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C4_E2E.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx; TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildFullChain(ctx, c, plan, snapshot, "E2E", 300), "sanity: full chain built and emitted");
   RealizedOutcome outcome;
   Check(BuildAndEmitOutcome(c, ctx.anchor_bar_time, "WIN", "BACKTEST_RUN_E2E", "evidence_hash_e2e", outcome), "sanity: outcome built and emitted");
   EventStore_Close();

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows, manifest), "full chain rebuilds and exports from the store alone");
   Check(ArraySize(rows) == 1, "sanity: exactly 1 row exported");
   TrainingDatasetRow row = rows[0];

   CandidateProjectionRecord candRec;
   Check(CandidateProjection_TryGet(row.candidate_id, candRec), "row's candidate is present in the rebuilt CandidateProjection");
   Check(candRec.candidate_hash == row.candidate_hash, "row's candidate_hash matches the rebuilt CandidateProjection record");
   Check(candRec.context_hash == ctx.context_hash, "candidate's persisted context_hash matches the real MarketContext's own context_hash");
   Check(candRec.context_event_id == ctx.context_event_id, "candidate's persisted context_event_id matches the real MarketContext's own id");

   FeatureSnapshotProjectionRecord fsRec;
   Check(FeatureSnapshotProjection_TryGet(row.feature_snapshot_id, fsRec), "row's snapshot is present in the rebuilt FeatureSnapshotProjection");
   Check(fsRec.feature_snapshot_hash == row.feature_snapshot_hash, "row's feature_snapshot_hash matches the rebuilt FeatureSnapshotProjection record");
   Check(fsRec.feature_vector_hash == row.feature_vector_hash, "row's feature_vector_hash matches the rebuilt FeatureSnapshotProjection record");
   Check(fsRec.candidate_id == row.candidate_id, "snapshot and row agree on candidate_id");

   RiskPlanProjectionRecord rpRec;
   Check(RiskPlanProjection_TryGet(row.risk_plan_id, rpRec), "row's plan is present in the rebuilt RiskPlanProjection");
   Check(rpRec.plan_hash == row.plan_hash, "row's plan_hash matches the rebuilt RiskPlanProjection record");
   Check(rpRec.candidate_id == row.candidate_id, "plan and row agree on candidate_id");

   Check(row.label_available, "row is labeled");
   Check(row.label == "WIN" && row.outcome_reference == "BACKTEST_RUN_E2E" && row.outcome_hash == "evidence_hash_e2e",
         "row's label/outcome fields match the real RealizedOutcome's own values");

   Check(row.dataset_row_id == Ids_TrainingDatasetRowId(row.feature_snapshot_id, row.label_schema_version, MODEL_TARGET_TEST),
         "dataset_row_id is deterministically derived from this exact feature_snapshot_id + label_schema_version + model_target");
}

void Test_CrossLayerFailure_CorruptedCandidateBlocksWholeChain()
{
   Print("--- cross-layer: a corrupted CANDIDATE_CREATED line blocks EVERY layer built on top of it, including the export ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C4_CandLayerFailure.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx; TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildFullChain(ctx, c, plan, snapshot, "CANDFAIL", 310), "sanity: full chain built and emitted");
   RealizedOutcome outcome;
   Check(BuildAndEmitOutcome(c, ctx.anchor_bar_time, "WIN", "REF", "HASH", outcome), "sanity: outcome built and emitted");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string candidateLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"CANDIDATE_CREATED\"") >= 0) candidateLine = lines[i];
   Check(candidateLine != "", "sanity: the real CANDIDATE_CREATED line was found");

   string tampered = TamperStringField(candidateLine, "candidate_id", "");
   Check(tampered != candidateLine, "sanity: candidate_id was actually tampered");
   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
      FileWriteString(h, ((lines[i] == candidateLine) ? tampered : lines[i]) + "\r\n");
   FileClose(h);

   CandidateProjectionReport candReport = CandidateProjection_RebuildFromFile(file);
   Check(!candReport.ok, "CandidateProjection rebuild fails on its own corrupted line");

   RiskPlanProjectionReport rpReport = RiskPlanProjection_RebuildFromFile(file);
   Check(!rpReport.ok, "RiskPlanProjection rebuild fails too - candidate-layer failure propagates");

   FeatureSnapshotProjectionReport fsReport = FeatureSnapshotProjection_RebuildFromFile(file);
   Check(!fsReport.ok, "FeatureSnapshotProjection rebuild fails too - candidate-layer failure propagates");

   RealizedOutcomeProjectionReport roReport = RealizedOutcomeProjection_RebuildFromFile(file);
   Check(!roReport.ok, "RealizedOutcomeProjection rebuild fails too - candidate-layer failure propagates");

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(!TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows, manifest),
         "TrainingDatasetExport_BuildDataset fails too - the failure propagates all the way to the export");
   Check(ArraySize(rows) == 0, "no partial rows output");
   Check(manifest.dataset_hash == "", "manifest stays at Init() defaults");
}

void Test_IncompleteAndCorrupt_AreNotTheSame()
{
   Print("--- gate 2: an incomplete candidate is a SKIP, a corrupted artifact is a FAIL-CLOSED - genuinely different outcomes ---");

   // Store A: one fully-qualified candidate + one genuinely incomplete
   // candidate (no RiskPlan/FeatureSnapshot) - the export must succeed,
   // skipping the incomplete one.
   ResetProjections();
   string fileA = "MLQuantAI_Test_B8_2C4_IncompleteA.jsonl";
   FileDelete(fileA, FILE_COMMON);
   EventStore_Open(fileA);
   MarketContext ctxFull; TradeCandidate cFull; RiskPlan planFull; FeatureSnapshot snapFull;
   Check(BuildFullChain(ctxFull, cFull, planFull, snapFull, "ICFULL", 320), "sanity: fully-qualified candidate built and emitted");
   TradeCandidate cIncomplete;
   Check(BuildIncompleteCandidate(cIncomplete, "ICINCOMPLETE", 321), "sanity: incomplete candidate built and emitted");
   EventStore_Close();

   TrainingDatasetRow rowsA[]; TrainingDatasetManifest manifestA;
   Check(TrainingDatasetExport_BuildDataset(fileA, MODEL_TARGET_TEST, rowsA, manifestA), "store A (incomplete, not corrupt) exports successfully");
   Check(manifestA.row_count == 1, "store A: exactly 1 row (the fully-qualified candidate)");
   Check(manifestA.incomplete_count == 1, "store A: exactly 1 incomplete candidate skipped");
   Check(manifestA.candidate_count == 2, "store A: candidate_count == 2 (both candidates considered)");

   // Store B: one fully-qualified candidate whose RISK_PLAN_CREATED
   // line is corrupted (missing plan_hash) - a genuine artifact-exists-
   // but-fails-validation corruption, not a missing artifact. The whole
   // export must fail closed.
   ResetProjections();
   string fileB = "MLQuantAI_Test_B8_2C4_CorruptB.jsonl";
   FileDelete(fileB, FILE_COMMON);
   EventStore_Open(fileB);
   MarketContext ctxCorrupt; TradeCandidate cCorrupt; RiskPlan planCorrupt; FeatureSnapshot snapCorrupt;
   Check(BuildFullChain(ctxCorrupt, cCorrupt, planCorrupt, snapCorrupt, "CORRUPTB", 322), "sanity: candidate for store B built and emitted");
   EventStore_Close();

   string linesB[]; int nB = EventStore_ReadAllLines(fileB, linesB);
   string planLine = "";
   for(int i = 0; i < nB; i++)
      if(StringFind(linesB[i], "\"type\":\"RISK_PLAN_CREATED\"") >= 0) planLine = linesB[i];
   Check(planLine != "", "sanity: the real RISK_PLAN_CREATED line was found");
   string tamperedPlanLine = TamperStringField(planLine, "plan_hash", "");
   Check(tamperedPlanLine != planLine, "sanity: plan_hash was actually tampered to empty");
   FileDelete(fileB, FILE_COMMON);
   int hB = FileOpen(fileB, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < nB; i++)
      FileWriteString(hB, ((linesB[i] == planLine) ? tamperedPlanLine : linesB[i]) + "\r\n");
   FileClose(hB);

   TrainingDatasetRow rowsB[]; TrainingDatasetManifest manifestB;
   Check(!TrainingDatasetExport_BuildDataset(fileB, MODEL_TARGET_TEST, rowsB, manifestB), "store B (corrupt, not incomplete) fails the WHOLE export closed");
   Check(ArraySize(rowsB) == 0, "store B: no partial rows output");
   Check(manifestB.dataset_hash == "" && manifestB.row_count == 0, "store B: manifest stays at Init() defaults");
}

void Test_Leakage_MultiCandidateCohort()
{
   Print("--- gate 1: adding a RealizedOutcome to ONE candidate never changes ANY candidate's feature hashes in the cohort ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C4_LeakageCohort.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx1, ctx2, ctx3; TradeCandidate c1, c2, c3; RiskPlan p1, p2, p3; FeatureSnapshot s1, s2, s3;
   Check(BuildFullChain(ctx1, c1, p1, s1, "LEAKA", 330), "sanity: candidate A built and emitted");
   Check(BuildFullChain(ctx2, c2, p2, s2, "LEAKB", 331), "sanity: candidate B built and emitted");
   Check(BuildFullChain(ctx3, c3, p3, s3, "LEAKC", 332), "sanity: candidate C built and emitted");
   EventStore_Close();

   TrainingDatasetRow rowsBefore[]; TrainingDatasetManifest manifestBefore;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rowsBefore, manifestBefore), "export (all unlabeled) succeeds");
   Check(ArraySize(rowsBefore) == 3, "sanity: 3 rows exported, all unlabeled");
   Check(manifestBefore.labeled_count == 0, "sanity: 0 labeled before any RealizedOutcome exists");

   TrainingDatasetRow rowB_before;
   Check(FindRowForCandidate(rowsBefore, c2.candidate_id, rowB_before), "sanity: candidate B's row found");

   // Only candidate B gets a RealizedOutcome.
   EventStore_Open(file);
   RealizedOutcome outcomeB;
   Check(BuildAndEmitOutcome(c2, ctx2.anchor_bar_time, "WIN", "REF", "HASH", outcomeB), "outcome for candidate B built and emitted after the fact");
   EventStore_Close();

   TrainingDatasetRow rowsAfter[]; TrainingDatasetManifest manifestAfter;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rowsAfter, manifestAfter), "export (B now labeled) succeeds");
   Check(manifestAfter.labeled_count == 1 && manifestAfter.unlabeled_count == 2, "sanity: exactly 1 labeled (B), 2 unlabeled (A, C)");

   TrainingDatasetRow rowA_after, rowB_after, rowC_after;
   Check(FindRowForCandidate(rowsAfter, c1.candidate_id, rowA_after), "candidate A's row still found");
   Check(FindRowForCandidate(rowsAfter, c2.candidate_id, rowB_after), "candidate B's row still found");
   Check(FindRowForCandidate(rowsAfter, c3.candidate_id, rowC_after), "candidate C's row still found");

   TrainingDatasetRow rowA_before, rowC_before;
   FindRowForCandidate(rowsBefore, c1.candidate_id, rowA_before);
   FindRowForCandidate(rowsBefore, c3.candidate_id, rowC_before);

   Check(rowA_after.feature_snapshot_hash == rowA_before.feature_snapshot_hash && rowA_after.feature_vector_hash == rowA_before.feature_vector_hash,
         "candidate A (never labeled): feature hashes unchanged across both exports");
   Check(rowB_after.feature_snapshot_hash == rowB_before.feature_snapshot_hash && rowB_after.feature_vector_hash == rowB_before.feature_vector_hash,
         "candidate B (NOW labeled): feature hashes STILL unchanged - no leakage even for the labeled candidate itself");
   Check(rowC_after.feature_snapshot_hash == rowC_before.feature_snapshot_hash && rowC_after.feature_vector_hash == rowC_before.feature_vector_hash,
         "candidate C (never labeled): feature hashes unchanged across both exports");
   Check(rowB_after.label_available && !rowA_after.label_available && !rowC_after.label_available,
         "only candidate B's row is labeled - A and C remain unlabeled");
}

void Test_CollisionAnywhereBlocksExport()
{
   Print("--- gate 3: a FeatureSnapshot collision anywhere in the store blocks TrainingDatasetExport_BuildDataset itself, not just its own projection ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C4_CollisionBlocks.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx1, ctx2; TradeCandidate c1, c2; RiskPlan p1, p2; FeatureSnapshot s1, s2;
   Check(BuildFullChain(ctx1, c1, p1, s1, "COLLA", 340), "sanity: candidate A built and emitted");
   Check(BuildFullChain(ctx2, c2, p2, s2, "COLLB", 341), "sanity: candidate B built and emitted");
   EventStore_Close();

   FeatureSnapshot colliding = s2;
   colliding.atr_m15 += 5.0;
   colliding.feature_vector_hash = FeatureSnapshot_ComputeVectorHash(colliding);
   colliding.feature_snapshot_hash = FeatureSnapshot_ComputeHash(colliding);
   Check(colliding.feature_snapshot_id == s2.feature_snapshot_id, "sanity: feature_snapshot_id unaffected by atr_m15");
   Check(colliding.feature_snapshot_hash != s2.feature_snapshot_hash, "sanity: feature_snapshot_hash DOES move with atr_m15");

   FeatureSnapshotProjection_Reset(); // clears only the live-session emission guard
   EventStore_Open(file);
   Check(FeatureSnapshot_EmitFeatureSnapshotCreated(colliding), "sanity: the colliding snapshot emits under a fresh session, appended to the same store");
   EventStore_Close();

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(!TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows, manifest),
         "export fails closed - a FeatureSnapshot collision anywhere in the store blocks the WHOLE export");
   Check(ArraySize(rows) == 0, "no partial rows output on a collision anywhere in the store");
   Check(manifest.dataset_hash == "", "manifest stays at Init() defaults");
}

void Test_ExportAtomicity_ValidVsCorrupted()
{
   Print("--- gate 4: a valid store exports full output; a corrupted store exports zero output + Init() manifest ---");

   ResetProjections();
   string fileValid = "MLQuantAI_Test_B8_2C4_AtomicValid.jsonl";
   FileDelete(fileValid, FILE_COMMON);
   EventStore_Open(fileValid);
   MarketContext ctx1, ctx2; TradeCandidate c1, c2; RiskPlan p1, p2; FeatureSnapshot s1, s2;
   Check(BuildFullChain(ctx1, c1, p1, s1, "ATOMICA", 350), "sanity: candidate A built and emitted");
   Check(BuildFullChain(ctx2, c2, p2, s2, "ATOMICB", 351), "sanity: candidate B built and emitted");
   RealizedOutcome outcomeA;
   Check(BuildAndEmitOutcome(c1, ctx1.anchor_bar_time, "WIN", "REF", "HASH", outcomeA), "sanity: outcome for A built and emitted");
   EventStore_Close();

   TrainingDatasetRow rowsValid[]; TrainingDatasetManifest manifestValid;
   Check(TrainingDatasetExport_BuildDataset(fileValid, MODEL_TARGET_TEST, rowsValid, manifestValid), "valid store: export succeeds");
   Check(ArraySize(rowsValid) == 2, "valid store: full output - 2 rows");
   Check(manifestValid.dataset_hash != "" && manifestValid.row_count == 2, "valid store: manifest fully populated");

   ResetProjections();
   string fileCorrupt = "MLQuantAI_Test_B8_2C4_AtomicCorrupt.jsonl";
   FileDelete(fileCorrupt, FILE_COMMON);
   EventStore_Open(fileCorrupt);
   MarketContext ctx3, ctx4; TradeCandidate c3, c4; RiskPlan p3, p4; FeatureSnapshot s3, s4;
   Check(BuildFullChain(ctx3, c3, p3, s3, "ATOMICC", 352), "sanity: candidate C built and emitted");
   Check(BuildFullChain(ctx4, c4, p4, s4, "ATOMICD", 353), "sanity: candidate D built and emitted");
   EventStore_Close();

   int h = FileOpen(fileCorrupt, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, "{\"schema_version\":\"EVENTS_V1\",\"type\":\"CANDIDATE_CREATED\",truncated_garbage");
   FileClose(h);

   TrainingDatasetRow rowsCorrupt[]; TrainingDatasetManifest manifestCorrupt;
   Check(!TrainingDatasetExport_BuildDataset(fileCorrupt, MODEL_TARGET_TEST, rowsCorrupt, manifestCorrupt), "corrupted store: export fails closed");
   Check(ArraySize(rowsCorrupt) == 0, "corrupted store: zero output");
   Check(manifestCorrupt.dataset_hash == "" && manifestCorrupt.row_count == 0 && manifestCorrupt.candidate_count == 0,
         "corrupted store: manifest at Init() defaults - never a partial result");
}

void Test_LabeledOnlyView_IsPureDerivedFilter()
{
   Print("--- LABELED_ONLY: a pure client-side filter over the exported dataset - never mutates the source rows[]/manifest ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C4_LabeledOnly.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx1, ctx2, ctx3; TradeCandidate c1, c2, c3; RiskPlan p1, p2, p3; FeatureSnapshot s1, s2, s3;
   Check(BuildFullChain(ctx1, c1, p1, s1, "LOA", 360), "sanity: candidate A built and emitted");
   Check(BuildFullChain(ctx2, c2, p2, s2, "LOB", 361), "sanity: candidate B built and emitted");
   Check(BuildFullChain(ctx3, c3, p3, s3, "LOC", 362), "sanity: candidate C built and emitted");
   RealizedOutcome outcomeA, outcomeC;
   Check(BuildAndEmitOutcome(c1, ctx1.anchor_bar_time, "WIN", "REF_A", "HASH_A", outcomeA), "sanity: outcome for A built and emitted");
   Check(BuildAndEmitOutcome(c3, ctx3.anchor_bar_time, "LOSS", "REF_C", "HASH_C", outcomeC), "sanity: outcome for C built and emitted");
   EventStore_Close();

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows, manifest), "export succeeds");
   Check(ArraySize(rows) == 3, "sanity: 3 rows exported");
   Check(manifest.labeled_count == 2 && manifest.unlabeled_count == 1, "sanity: 2 labeled (A, C), 1 unlabeled (B)");

   int originalRowCount = ArraySize(rows);
   string originalDatasetHash = manifest.dataset_hash;
   string originalRowIds[]; ArrayResize(originalRowIds, originalRowCount);
   string originalRowHashes[]; ArrayResize(originalRowHashes, originalRowCount);
   for(int i = 0; i < originalRowCount; i++)
   {
      originalRowIds[i]   = rows[i].dataset_row_id;
      originalRowHashes[i] = rows[i].row_hash;
   }

   // The LABELED_ONLY view - a pure filter, built here in test code
   // only. No new Include/ production function exists for this (per
   // Docs/PhaseB_B8_2_Commit4_SealRegression.md's clarification) -
   // the already-shipped label_available field is sufficient.
   TrainingDatasetRow labeledOnly[];
   int labeledOnlyCount = 0;
   for(int i = 0; i < ArraySize(rows); i++)
   {
      if(!rows[i].label_available) continue;
      ArrayResize(labeledOnly, labeledOnlyCount + 1);
      labeledOnly[labeledOnlyCount] = rows[i];
      labeledOnlyCount++;
   }
   Check(labeledOnlyCount == manifest.labeled_count, "LABELED_ONLY count equals manifest.labeled_count");
   bool allLabeled = true;
   for(int i = 0; i < labeledOnlyCount; i++)
      if(!labeledOnly[i].label_available) { allLabeled = false; break; }
   Check(allLabeled, "every LABELED_ONLY row genuinely has label_available == true");

   Check(ArraySize(rows) == originalRowCount, "rows[] size is UNCHANGED after building the LABELED_ONLY view");
   Check(manifest.dataset_hash == originalDatasetHash, "manifest.dataset_hash is UNCHANGED after building the LABELED_ONLY view");
   bool allRowsUnchanged = true;
   for(int i = 0; i < originalRowCount; i++)
      if(rows[i].dataset_row_id != originalRowIds[i] || rows[i].row_hash != originalRowHashes[i]) { allRowsUnchanged = false; break; }
   Check(allRowsUnchanged, "every source row's dataset_row_id/row_hash is UNCHANGED after building the LABELED_ONLY view");

   TrainingDatasetRow rowsAgain[]; TrainingDatasetManifest manifestAgain;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rowsAgain, manifestAgain), "re-export from the same store succeeds");
   Check(manifestAgain.dataset_hash == originalDatasetHash,
         "re-export's dataset_hash is unaffected by the earlier LABELED_ONLY filter - no observable side effect on the store");
}

void Test_FullChainRestartSimulation_MultiCandidate()
{
   Print("--- full-chain restart: repeated exports of a mixed labeled/unlabeled/incomplete store reconstruct byte-identical output ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C4_MultiRestart.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx1, ctx2; TradeCandidate c1, c2; RiskPlan p1, p2; FeatureSnapshot s1, s2;
   Check(BuildFullChain(ctx1, c1, p1, s1, "RESTARTA", 370), "sanity: candidate A built and emitted");
   Check(BuildFullChain(ctx2, c2, p2, s2, "RESTARTB", 371), "sanity: candidate B built and emitted");
   RealizedOutcome outcomeA;
   Check(BuildAndEmitOutcome(c1, ctx1.anchor_bar_time, "WIN", "REF", "HASH", outcomeA), "sanity: outcome for A built and emitted");
   TradeCandidate cIncomplete;
   Check(BuildIncompleteCandidate(cIncomplete, "RESTARTC", 372), "sanity: incomplete candidate built and emitted");
   EventStore_Close();

   TrainingDatasetRow rows1[]; TrainingDatasetManifest manifest1;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows1, manifest1), "first export (simulated first run) succeeds");
   Check(manifest1.row_count == 2 && manifest1.incomplete_count == 1 && manifest1.labeled_count == 1,
         "sanity: 2 rows, 1 incomplete, 1 labeled");

   TrainingDatasetRow rows2[]; TrainingDatasetManifest manifest2;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows2, manifest2), "second export (simulated restart) succeeds");

   Check(manifest1.dataset_hash == manifest2.dataset_hash, "dataset_hash is byte-identical across both exports");
   Check(manifest1.dataset_id == manifest2.dataset_id, "dataset_id is byte-identical across both exports");
   Check(manifest1.row_count == manifest2.row_count && manifest1.incomplete_count == manifest2.incomplete_count &&
         manifest1.labeled_count == manifest2.labeled_count && manifest1.unlabeled_count == manifest2.unlabeled_count,
         "manifest counts are byte-identical across both exports");
   Check(ArraySize(rows1) == ArraySize(rows2), "row count is identical across both exports");
   bool allRowsIdentical = true;
   for(int i = 0; i < ArraySize(rows1); i++)
      if(rows1[i].dataset_row_id != rows2[i].dataset_row_id || rows1[i].row_hash != rows2[i].row_hash ||
         rows1[i].label_available != rows2[i].label_available)
      { allRowsIdentical = false; break; }
   Check(allRowsIdentical, "every row (id/hash/label_available) is byte-identical across both exports, in the same order");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B8.2 Commit 4 - Full-Chain Integration + Regression Proof (B8.2 SEAL) ===");

   Test_FullChain_EndToEndLinkage();
   Test_CrossLayerFailure_CorruptedCandidateBlocksWholeChain();
   Test_IncompleteAndCorrupt_AreNotTheSame();
   Test_Leakage_MultiCandidateCohort();
   Test_CollisionAnywhereBlocksExport();
   Test_ExportAtomicity_ValidVsCorrupted();
   Test_LabeledOnlyView_IsPureDerivedFilter();
   Test_FullChainRestartSimulation_MultiCandidate();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");

   Print("=== Manual regression checklist (per the B8.2 Commit 4 seal contract) - re-run each of these in the same MetaEditor session and confirm ALL PASS: ===");
   Print("  MLQuantAI_Test_B8_2_Commit1_TrainingDataset.mq5");
   Print("  MLQuantAI_Test_B8_2_Commit2_Export.mq5");
   Print("  MLQuantAI_Test_B8_2_Commit3_OutcomeLabel.mq5");
}
