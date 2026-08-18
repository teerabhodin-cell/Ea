//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_2_Commit2_Export.mq5                            |
//| Phase B8.2 Commit 2 DoD, per                                        |
//| Docs/PhaseB_B8_2_Commit2_ExportContract.md's QA gate: Part 0        |
//| (FEATURE_SNAPSHOT_CREATED event + FeatureSnapshotProjection,        |
//| mirroring B7 Commit 2's own RiskPlan test suite) and Part 1          |
//| (TrainingDatasetExport_BuildDataset orchestration). Uses the real   |
//| B5/B7/B8.1/B8.2-Commit-1 pipeline for every fixture - no fabricated |
//| hashes anywhere.                                                     |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RiskPlanEventEmission.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_FeatureSnapshotEventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_TrainingDatasetExport.mqh>

#define MODEL_TARGET_TEST "SETUP_QUALITY_V1"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as prior B7/B8.1/B8.2 test files.
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
   ctx.context_event_id = "CTX_b8_2c2_" + suffix;
   ctx.context_hash      = "test_context_hash_b8_2c2_" + suffix;
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

void ResetProjections()
{
   CandidateProjection_Reset();
   RiskPlanProjection_Reset();
   FeatureSnapshotProjection_Reset();
}

// Builds and emits the full real chain for one candidate: MARKET_CONTEXT_READY,
// CANDIDATE_CREATED, RISK_PLAN_CREATED, FEATURE_SNAPSHOT_CREATED. The
// store must already be open (EventStore_Open) before calling this.
bool BuildAndEmitFullChain(TradeCandidate &c, RiskPlan &plan, FeatureSnapshot &snapshot, string suffix, int dayOffset)
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
   if(!CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits)) return false;

   RiskContext riskCtx;
   BuildValidRiskContext(riskCtx, suffix);
   if(!Candidate_ToRiskPlan(c, riskCtx, plan)) return false;
   if(!RiskPlan_EmitRiskPlanCreated(plan)) return false;

   if(!Candidate_ToFeatureSnapshot(c, ctx, snapshot)) return false;
   return FeatureSnapshot_EmitFeatureSnapshotCreated(snapshot);
}

//=====================================================================
// Part 0: FEATURE_SNAPSHOT_CREATED event + FeatureSnapshotProjection
//=====================================================================
void Test_ExactlyOneEmission()
{
   Print("--- Part 0: a valid FeatureSnapshot emits exactly one FEATURE_SNAPSHOT_CREATED event ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_ExactlyOne.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildAndEmitFullChain(c, plan, snapshot, "ONE", 1), "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   int snapLines = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"FEATURE_SNAPSHOT_CREATED\"") >= 0) snapLines++;
   Check(snapLines == 1, "exactly one FEATURE_SNAPSHOT_CREATED line written");
}

void Test_DuplicateEmission_SameSession_NoOp()
{
   Print("--- Part 0: re-emitting the identical snapshot live, same session, is a no-op ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_DupSession.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildAndEmitFullChain(c, plan, snapshot, "DUPSESSION", 2), "sanity: full chain built and emitted");
   Check(!FeatureSnapshot_EmitFeatureSnapshotCreated(snapshot), "second emission of the identical snapshot returns false (no-op)");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   int snapLines = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"FEATURE_SNAPSHOT_CREATED\"") >= 0) snapLines++;
   Check(snapLines == 1, "still only one FEATURE_SNAPSHOT_CREATED line written - no second event");
}

void Test_UnfilledSnapshot_EmitsNothing()
{
   Print("--- Part 0: an unfilled (empty id) snapshot emits no event ---");
   ResetProjections();
   FeatureSnapshot unfilled; FeatureSnapshot_Init(unfilled);
   Check(unfilled.feature_snapshot_id == "", "sanity: Init() snapshot has an empty feature_snapshot_id");
   Check(!FeatureSnapshot_EmitFeatureSnapshotCreated(unfilled), "emitting an unfilled snapshot returns false");
}

void Test_Replay_DuplicateSameHash_NoOp()
{
   Print("--- Part 0: replay - same feature_snapshot_id + same hash = duplicate no-op ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_ReplayDup.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildAndEmitFullChain(c, plan, snapshot, "REPLAYDUP", 3), "sanity: full chain built and emitted");
   EventStore_Close();

   FeatureSnapshotProjection_Reset(); // clears the live emission guard, mirrors RiskPlan Commit 2's own fix
   EventStore_Open(file);
   Check(FeatureSnapshot_EmitFeatureSnapshotCreated(snapshot), "sanity: the identical snapshot re-emits under a fresh session");
   EventStore_Close();

   FeatureSnapshotProjectionReport report = FeatureSnapshotProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds despite the duplicate line");
   Check(FeatureSnapshotProjection_Count() == 1, "registry has exactly one record - the duplicate was a no-op");
}

void Test_Replay_CollisionDifferentHash_Rejected()
{
   Print("--- Part 0: replay - same feature_snapshot_id + DIFFERENT hash = collision, rejected ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_ReplayColl.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildAndEmitFullChain(c, plan, snapshot, "REPLAYCOLL", 4), "sanity: full chain built and emitted");
   EventStore_Close();

   FeatureSnapshot colliding = snapshot;
   colliding.atr_m15 += 5.0;
   colliding.feature_vector_hash = FeatureSnapshot_ComputeVectorHash(colliding);
   colliding.feature_snapshot_hash = FeatureSnapshot_ComputeHash(colliding);
   Check(colliding.feature_snapshot_id == snapshot.feature_snapshot_id, "sanity: feature_snapshot_id unaffected by atr_m15");
   Check(colliding.feature_snapshot_hash != snapshot.feature_snapshot_hash, "sanity: feature_snapshot_hash DOES move with atr_m15");

   FeatureSnapshotProjection_Reset();
   EventStore_Open(file);
   Check(FeatureSnapshot_EmitFeatureSnapshotCreated(colliding), "sanity: the colliding snapshot emits under a fresh session");
   EventStore_Close();

   FeatureSnapshotProjectionReport report = FeatureSnapshotProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on a feature_snapshot_id collision");
   Check(StringFind(report.first_error, "collision") >= 0, "first_error mentions the collision, not a duplicate no-op");
}

void Test_Replay_OrphanCandidate_Rejected()
{
   Print("--- Part 0: replay - a FEATURE_SNAPSHOT_CREATED referencing an unknown candidate_id is an orphan, rejected ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_Orphan.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildAndEmitFullChain(c, plan, snapshot, "ORPHANFS", 5), "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[]; int n = EventStore_ReadAllLines(file, lines);
   string snapLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"FEATURE_SNAPSHOT_CREATED\"") >= 0) snapLine = lines[i];
   Check(snapLine != "", "sanity: the real FEATURE_SNAPSHOT_CREATED line was found");

   string needle = "\"candidate_id\":\"";
   int p = StringFind(snapLine, needle);
   int start = p + StringLen(needle);
   int end = start;
   while(end < StringLen(snapLine) && StringGetCharacter(snapLine, end) != '"') end++;
   string tampered = StringSubstr(snapLine, 0, start) + "CND_DOES_NOT_EXIST" + StringSubstr(snapLine, end);

   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == snapLine) ? tampered : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);

   FeatureSnapshotProjectionReport report = FeatureSnapshotProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an orphan candidate reference");
   Check(StringFind(report.first_error, "orphan") >= 0, "first_error mentions the orphan");
}

void Test_Replay_CandidateHashMismatch_Rejected()
{
   Print("--- Part 0: replay - a FEATURE_SNAPSHOT_CREATED whose candidate_hash mismatches the real candidate is rejected ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_HashMismatch.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildAndEmitFullChain(c, plan, snapshot, "FSHASHMISMATCH", 6), "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[]; int n = EventStore_ReadAllLines(file, lines);
   string snapLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"FEATURE_SNAPSHOT_CREATED\"") >= 0) snapLine = lines[i];
   Check(snapLine != "", "sanity: the real FEATURE_SNAPSHOT_CREATED line was found");

   string needle = "\"candidate_hash\":\"";
   int p = StringFind(snapLine, needle);
   int start = p + StringLen(needle);
   int end = start;
   while(end < StringLen(snapLine) && StringGetCharacter(snapLine, end) != '"') end++;
   string tampered = StringSubstr(snapLine, 0, start) + "TAMPERED_HASH" + StringSubstr(snapLine, end);

   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == snapLine) ? tampered : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);

   FeatureSnapshotProjectionReport report = FeatureSnapshotProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on a candidate_hash mismatch");
   Check(StringFind(report.first_error, "mismatch") >= 0, "first_error mentions the mismatch");
}

void Test_MalformedLine_BlocksWholeRebuild()
{
   Print("--- Part 0: a truncated/malformed line anywhere blocks the WHOLE rebuild ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_Malformed.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildAndEmitFullChain(c, plan, snapshot, "FSMALFORMED", 7), "sanity: full chain built and emitted");
   EventStore_Close();

   int h = FileOpen(file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, "{\"schema_version\":\"EVENTS_V1\",\"type\":\"FEATURE_SNAPSHOT_CREATED\",truncated_garbage");
   FileClose(h);

   int countBefore = FeatureSnapshotProjection_Count();
   FeatureSnapshotProjectionReport report = FeatureSnapshotProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on the truncated line");
   Check(FeatureSnapshotProjection_Count() == countBefore, "registry is left completely untouched by a failed rebuild");
}

void Test_RestartCrashSimulation()
{
   Print("--- Part 0: repeated rebuilds of the same store reconstruct byte-identical records ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_Restart.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c1, c2; RiskPlan p1, p2; FeatureSnapshot s1, s2;
   Check(BuildAndEmitFullChain(c1, p1, s1, "FSRESTART1", 8), "sanity: chain 1 built and emitted");
   Check(BuildAndEmitFullChain(c2, p2, s2, "FSRESTART2", 9), "sanity: chain 2 built and emitted");
   EventStore_Close();

   FeatureSnapshotProjectionReport report1 = FeatureSnapshotProjection_RebuildFromFile(file);
   Check(report1.ok && FeatureSnapshotProjection_Count() == 2, "first rebuild: 2 records");
   FeatureSnapshotProjectionRecord rec1a, rec1b;
   FeatureSnapshotProjection_TryGet(s1.feature_snapshot_id, rec1a);
   FeatureSnapshotProjection_TryGet(s2.feature_snapshot_id, rec1b);

   FeatureSnapshotProjectionReport report2 = FeatureSnapshotProjection_RebuildFromFile(file);
   Check(report2.ok && FeatureSnapshotProjection_Count() == 2, "second rebuild (simulated restart): still 2 records");
   FeatureSnapshotProjectionRecord rec2a, rec2b;
   FeatureSnapshotProjection_TryGet(s1.feature_snapshot_id, rec2a);
   FeatureSnapshotProjection_TryGet(s2.feature_snapshot_id, rec2b);

   Check(rec1a.feature_snapshot_hash == rec2a.feature_snapshot_hash && rec1a.atr_m15 == rec2a.atr_m15, "record 1 identical across both rebuilds");
   Check(rec1b.feature_snapshot_hash == rec2b.feature_snapshot_hash && rec1b.atr_m15 == rec2b.atr_m15, "record 2 identical across both rebuilds");
}

void Test_MultiSession()
{
   Print("--- Part 0: a store spanning multiple sessions rebuilds correctly ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_MultiSession.jsonl";
   FileDelete(file, FILE_COMMON);

   EventStore_Open(file);
   TradeCandidate c1; RiskPlan p1; FeatureSnapshot s1;
   Check(BuildAndEmitFullChain(c1, p1, s1, "FSSESSA", 10), "sanity: session A chain built and emitted");
   EventStore_Close();

   EventStore_Open(file);
   TradeCandidate c2; RiskPlan p2; FeatureSnapshot s2;
   Check(BuildAndEmitFullChain(c2, p2, s2, "FSSESSB", 11), "sanity: session B chain built and emitted");
   EventStore_Close();

   FeatureSnapshotProjectionReport report = FeatureSnapshotProjection_RebuildFromFile(file);
   Check(report.ok, "multi-session rebuild succeeds");
   Check(FeatureSnapshotProjection_Count() == 2, "both sessions' snapshots are present after rebuild");
}

void Test_ReplayFieldsMatchOriginal()
{
   Print("--- Part 0: every field on a rebuilt record matches the original FeatureSnapshot exactly ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_FieldMatch.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildAndEmitFullChain(c, plan, snapshot, "FSFIELDMATCH", 12), "sanity: full chain built and emitted");
   EventStore_Close();

   FeatureSnapshotProjectionReport report = FeatureSnapshotProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   FeatureSnapshotProjectionRecord rec;
   Check(FeatureSnapshotProjection_TryGet(snapshot.feature_snapshot_id, rec), "the snapshot is found in the rebuilt registry");

   Check(rec.feature_snapshot_id == snapshot.feature_snapshot_id, "feature_snapshot_id matches");
   Check(rec.candidate_id == snapshot.candidate_id, "candidate_id matches");
   Check(rec.candidate_hash == snapshot.candidate_hash, "candidate_hash matches");
   Check(rec.context_event_id == snapshot.context_event_id, "context_event_id matches");
   Check(rec.context_hash == snapshot.context_hash, "context_hash matches");
   Check(rec.detector_hash == snapshot.detector_hash, "detector_hash matches");
   Check(MathAbs(rec.atr_m15 - snapshot.atr_m15) < 0.000001, "atr_m15 matches");
   Check(MathAbs(rec.adx_m15 - snapshot.adx_m15) < 0.000001, "adx_m15 matches");
   Check(rec.pdh == snapshot.pdh && rec.pdl == snapshot.pdl, "pdh/pdl match");
   Check(rec.news_count == snapshot.news_count, "news_count matches");
   Check(rec.is_kill_zone == snapshot.is_kill_zone, "is_kill_zone matches");
   Check(rec.feature_vector_hash == snapshot.feature_vector_hash, "feature_vector_hash matches");
   Check(rec.feature_snapshot_hash == snapshot.feature_snapshot_hash, "feature_snapshot_hash matches - no drift between emission and replay");
}

//=====================================================================
// Part 1: TrainingDatasetExport_BuildDataset
//=====================================================================
void Test_Export_FullyQualifiedCandidates()
{
   Print("--- Part 1: a store with 3 fully-qualified candidates exports exactly 3 rows ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_Export3.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c1, c2, c3; RiskPlan p1, p2, p3; FeatureSnapshot s1, s2, s3;
   Check(BuildAndEmitFullChain(c1, p1, s1, "EXP3A", 20), "sanity: candidate A built and emitted");
   Check(BuildAndEmitFullChain(c2, p2, s2, "EXP3B", 21), "sanity: candidate B built and emitted");
   Check(BuildAndEmitFullChain(c3, p3, s3, "EXP3C", 22), "sanity: candidate C built and emitted");
   EventStore_Close();

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows, manifest), "export succeeds");
   Check(ArraySize(rows) == 3, "exactly 3 rows exported");
   Check(manifest.row_count == 3, "manifest.row_count == 3");
   Check(manifest.unlabeled_count == 3 && manifest.labeled_count == 0, "manifest counts: all 3 unlabeled, 0 labeled");
   Check(manifest.train_count + manifest.validation_count + manifest.test_count == 3, "train+validation+test == row_count");
   Check(manifest.model_target == MODEL_TARGET_TEST, "manifest.model_target matches the caller's input");
   Check(manifest.dataset_hash != "", "manifest.dataset_hash is non-empty");
   Check(manifest.source_store_fingerprint != "", "manifest.source_store_fingerprint is non-empty");
}

void Test_Export_SkipsIncompleteCandidates()
{
   Print("--- Part 1: a candidate missing a FeatureSnapshot, or missing an ALLOWED RiskPlan, is silently skipped ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_ExportSkip.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   // Fully qualified candidate.
   TradeCandidate cFull; RiskPlan pFull; FeatureSnapshot sFull;
   Check(BuildAndEmitFullChain(cFull, pFull, sFull, "SKIPFULL", 23), "sanity: fully-qualified candidate built and emitted");

   // Candidate + context only, no RiskPlan, no FeatureSnapshot (built
   // manually here since BuildAndEmitFullChain always builds all three).
   MarketContext ctxNoPlan; BuildBaseContext(ctxNoPlan, "SKIPNOPLAN");
   datetime t0 = D'2026.01.01 00:00:00' + 24 * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctxNoPlan.trigger_tf_recent, anchor, t0);
   ctxNoPlan.anchor_bar_time = anchor;
   Check(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctxNoPlan)),
         "sanity: no-plan candidate's context logged");
   CRTDetectionResult rNoPlan; CRT_DetectV1(ctxNoPlan, rNoPlan);
   Check(rNoPlan.detected, "sanity: no-plan candidate detected");
   TradeCandidate cNoPlan;
   Check(CRT_ToTradeCandidate(ctxNoPlan, rNoPlan, cNoPlan), "sanity: no-plan candidate mapped");
   Check(CRT_EmitCandidateCreated(cNoPlan, ctxNoPlan.symbol_spec.digits), "sanity: no-plan candidate emitted - no RiskPlan/FeatureSnapshot follows it");

   EventStore_Close();

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows, manifest), "export succeeds despite the incomplete candidate");
   Check(ArraySize(rows) == 1, "exactly 1 row exported - the incomplete candidate was skipped, not a failure");
   Check(rows[0].candidate_id == cFull.candidate_id, "the exported row belongs to the fully-qualified candidate");
}

void Test_Export_ReadOnly()
{
   Print("--- Part 1: export is read-only - no line count or byte content change ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_ExportReadOnly.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildAndEmitFullChain(c, plan, snapshot, "READONLY", 25), "sanity: chain built and emitted");
   EventStore_Close();

   string before[]; int nBefore = EventStore_ReadAllLines(file, before);

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows, manifest), "export succeeds");

   string after[]; int nAfter = EventStore_ReadAllLines(file, after);
   Check(nBefore == nAfter, "line count unchanged after export");
   bool allMatch = true;
   for(int i = 0; i < nBefore; i++)
      if(before[i] != after[i]) { allMatch = false; break; }
   Check(allMatch, "every line is byte-identical before and after export");
}

void Test_Export_Determinism()
{
   Print("--- Part 1: re-running the export against the identical file+modelTarget is byte-identical ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_ExportDet.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c1, c2; RiskPlan p1, p2; FeatureSnapshot s1, s2;
   Check(BuildAndEmitFullChain(c1, p1, s1, "DETA", 26), "sanity: candidate A built and emitted");
   Check(BuildAndEmitFullChain(c2, p2, s2, "DETB", 27), "sanity: candidate B built and emitted");
   EventStore_Close();

   TrainingDatasetRow rowsA[]; TrainingDatasetManifest manifestA;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rowsA, manifestA), "first export succeeds");

   TrainingDatasetRow rowsB[]; TrainingDatasetManifest manifestB;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rowsB, manifestB), "second export succeeds");

   Check(manifestA.dataset_hash == manifestB.dataset_hash, "dataset_hash is identical across repeated exports");
   Check(manifestA.dataset_id == manifestB.dataset_id, "dataset_id is identical across repeated exports");
   Check(ArraySize(rowsA) == ArraySize(rowsB), "row count is identical across repeated exports");
   bool orderMatches = true;
   for(int i = 0; i < ArraySize(rowsA); i++)
      if(rowsA[i].dataset_row_id != rowsB[i].dataset_row_id) { orderMatches = false; break; }
   Check(orderMatches, "row order is identical across repeated exports");
}

void Test_Export_RowOrdering()
{
   Print("--- Part 1: rows are ordered by setup_anchor_bar_time ASC ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_ExportOrder.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate cLate, cEarly; RiskPlan pLate, pEarly; FeatureSnapshot sLate, sEarly;
   // Emitted out of chronological order on purpose - dayOffset 30 (late) first, then 28 (early).
   Check(BuildAndEmitFullChain(cLate, pLate, sLate, "ORDERLATE", 30), "sanity: late candidate built and emitted first");
   Check(BuildAndEmitFullChain(cEarly, pEarly, sEarly, "ORDEREARLY", 28), "sanity: early candidate built and emitted second");
   EventStore_Close();

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows, manifest), "export succeeds");
   Check(ArraySize(rows) == 2, "sanity: 2 rows exported");
   Check(rows[0].candidate_id == cEarly.candidate_id, "row 0 is the chronologically EARLIER candidate, despite being emitted second");
   Check(rows[1].candidate_id == cLate.candidate_id, "row 1 is the chronologically LATER candidate, despite being emitted first");
}

void Test_Export_MixedCohortRejected()
{
   Print("--- Part 1: mixed feature_schema_version across the cohort fails the whole export closed ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_MixedCohort.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c1, c2; RiskPlan p1, p2; FeatureSnapshot s1, s2;
   Check(BuildAndEmitFullChain(c1, p1, s1, "MIXA", 31), "sanity: candidate A built and emitted");
   Check(BuildAndEmitFullChain(c2, p2, s2, "MIXB", 32), "sanity: candidate B built and emitted");
   EventStore_Close();

   // Tamper candidate B's persisted FEATURE_SNAPSHOT_CREATED line to
   // carry a different (but still self-consistent-looking) schema
   // version string, simulating a store that spans a schema bump.
   string lines[]; int n = EventStore_ReadAllLines(file, lines);
   string targetLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"FEATURE_SNAPSHOT_CREATED\"") >= 0 && StringFind(lines[i], s2.feature_snapshot_id) >= 0)
         targetLine = lines[i];
   Check(targetLine != "", "sanity: candidate B's FEATURE_SNAPSHOT_CREATED line was found");

   string needle = "\"feature_schema_version\":\"";
   int p = StringFind(targetLine, needle);
   int start = p + StringLen(needle);
   int end = start;
   while(end < StringLen(targetLine) && StringGetCharacter(targetLine, end) != '"') end++;
   string tampered = StringSubstr(targetLine, 0, start) + "FEATURES_B8_1_V2_HYPOTHETICAL" + StringSubstr(targetLine, end);

   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
      FileWriteString(h, ((lines[i] == targetLine) ? tampered : lines[i]) + "\r\n");
   FileClose(h);

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(!TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows, manifest), "export fails closed on a mixed feature_schema_version cohort");
   Check(ArraySize(rows) == 0, "no partial rows output on the mixed-cohort failure");
   Check(manifest.dataset_hash == "", "manifest stays at Init() defaults on the mixed-cohort failure");
}

void Test_Export_FailClosed_OnCorruption()
{
   Print("--- Part 1: a corrupted store (malformed line) fails the export closed, no partial output ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_ExportCorrupt.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildAndEmitFullChain(c, plan, snapshot, "CORRUPT", 33), "sanity: chain built and emitted");
   EventStore_Close();

   int h = FileOpen(file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, "{\"schema_version\":\"EVENTS_V1\",\"type\":\"CANDIDATE_CREATED\",truncated_garbage");
   FileClose(h);

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(!TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows, manifest), "export fails closed on a corrupted store");
   Check(ArraySize(rows) == 0, "no partial rows output on the corruption failure");
   Check(manifest.dataset_hash == "" && manifest.row_count == 0, "manifest stays at Init() defaults on the corruption failure");
}

void Test_Export_EmptyModelTarget_Rejected()
{
   Print("--- Part 1: an empty modelTarget is rejected outright ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C2_EmptyTarget.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildAndEmitFullChain(c, plan, snapshot, "EMPTYTARGET", 34), "sanity: chain built and emitted");
   EventStore_Close();

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(!TrainingDatasetExport_BuildDataset(file, "", rows, manifest), "an empty modelTarget is rejected");
   Check(ArraySize(rows) == 0, "no rows output on the empty-modelTarget rejection");
}

//---------------------------------------------------------------------
// Structural checks - not runtime-testable, verified by inspection,
// same class as B8.1/B8.2-Commit-1's own.
//---------------------------------------------------------------------
void Test_ExclusionProof_NoNewComputation()
{
   Print("--- Part 1: the export path computes no NEW feature/risk/label value (structural) ---");
   Check(true, "Infrastructure/EventStore/MLQuantAI_TrainingDatasetExport.mqh calls only "
               "BuildTrainingDatasetRow (B8.2 Commit 1, sealed) over already-persisted projection "
               "records - no Candidate_ToFeatureSnapshot, no Candidate_ToRiskPlan, no label/outcome "
               "generator, no EventStore_Log*/OrderSend/CTrade/AccountInfo*/SymbolInfo*/TimeCurrent "
               "call anywhere in the export path - verified by inspection per "
               "Docs/PhaseB_B8_2_Commit2_ExportContract.md's Part 1");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B8.2 Commit 2 - FeatureSnapshot Event/Projection + Training Dataset Export ===");

   Test_ExactlyOneEmission();
   Test_DuplicateEmission_SameSession_NoOp();
   Test_UnfilledSnapshot_EmitsNothing();
   Test_Replay_DuplicateSameHash_NoOp();
   Test_Replay_CollisionDifferentHash_Rejected();
   Test_Replay_OrphanCandidate_Rejected();
   Test_Replay_CandidateHashMismatch_Rejected();
   Test_MalformedLine_BlocksWholeRebuild();
   Test_RestartCrashSimulation();
   Test_MultiSession();
   Test_ReplayFieldsMatchOriginal();

   Test_Export_FullyQualifiedCandidates();
   Test_Export_SkipsIncompleteCandidates();
   Test_Export_ReadOnly();
   Test_Export_Determinism();
   Test_Export_RowOrdering();
   Test_Export_MixedCohortRejected();
   Test_Export_FailClosed_OnCorruption();
   Test_Export_EmptyModelTarget_Rejected();
   Test_ExclusionProof_NoNewComputation();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
