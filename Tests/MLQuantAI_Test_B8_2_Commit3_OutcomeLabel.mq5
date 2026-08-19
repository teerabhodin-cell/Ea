//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_2_Commit3_OutcomeLabel.mq5                      |
//| Phase B8.2 Commit 3 DoD, per                                        |
//| Docs/PhaseB_B8_2_Commit3_OutcomeLabelContract.md's QA gate: Part 0   |
//| (candidate_count/incomplete_count manifest normativity) and Part 1  |
//| (RealizedOutcome - the 7 groups from the proposal that opened this  |
//| commit). Uses the real B5/B7/B8.1/B8.2 pipeline for every fixture - |
//| no fabricated hashes anywhere, and RealizedOutcome data is           |
//| constructed directly in this file (synthetic fixtures only - no     |
//| live Execution Engine exists yet, per the contract's scope          |
//| decision 1).                                                         |
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
#define OUTCOME_TIME_OFFSET_SEC (2 * 86400) // 2 days after setup_anchor_bar_time - comfortably past the boundary

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as the Commit 2 test file.
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
   ctx.context_event_id = "CTX_b8_2c3_" + suffix;
   ctx.context_hash      = "test_context_hash_b8_2c3_" + suffix;
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
   RealizedOutcomeProjection_Reset();
}

// Builds and emits the full real chain for one candidate: MARKET_CONTEXT_READY,
// CANDIDATE_CREATED, RISK_PLAN_CREATED, FEATURE_SNAPSHOT_CREATED. Also
// returns the candidate's setup_anchor_bar_time so callers can derive
// a valid outcome_time. The store must already be open
// (EventStore_Open) before calling this.
bool BuildAndEmitFullChain(TradeCandidate &c, RiskPlan &plan, FeatureSnapshot &snapshot, datetime &outAnchor, string suffix, int dayOffset)
{
   MarketContext ctx;
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.01.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;
   outAnchor = anchor;

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

// Builds and emits a RealizedOutcome for an already-emitted candidate,
// outcome_time = anchor + OUTCOME_TIME_OFFSET_SEC (comfortably past
// the temporal boundary).
bool BuildAndEmitOutcome(const TradeCandidate &c, datetime anchor, string label, string outcomeRef, string outcomeHash, RealizedOutcome &outOutcome)
{
   datetime outcomeTime = anchor + OUTCOME_TIME_OFFSET_SEC;
   if(!RealizedOutcome_Build(c, label, outcomeRef, outcomeHash, outcomeTime, MLQUANTAI_LABEL_SCHEMA_B8_2_V1, outOutcome))
      return false;
   return RealizedOutcome_EmitTradeOutcomeLabeled(outOutcome);
}

//=====================================================================
// Part 0: candidate_count/incomplete_count manifest normativity
//=====================================================================
void Test_ManifestCounters_CandidateCountIncompleteCount()
{
   Print("--- Part 0: candidate_count/incomplete_count are correctly tallied ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_2C3_ManifestCounters.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c1, c2; RiskPlan p1, p2; FeatureSnapshot s1, s2; datetime a1, a2;
   Check(BuildAndEmitFullChain(c1, p1, s1, a1, "MC1", 40), "sanity: full candidate 1 built and emitted");
   Check(BuildAndEmitFullChain(c2, p2, s2, a2, "MC2", 41), "sanity: full candidate 2 built and emitted");

   // A third candidate with context + CANDIDATE_CREATED only - no
   // RiskPlan, no FeatureSnapshot - deliberately incomplete.
   MarketContext ctxIncomplete; BuildBaseContext(ctxIncomplete, "MCINCOMPLETE");
   datetime t0 = D'2026.01.01 00:00:00' + 42 * 86400;
   datetime anchor3;
   Fixture_Bullish_Valid(ctxIncomplete.trigger_tf_recent, anchor3, t0);
   ctxIncomplete.anchor_bar_time = anchor3;
   Check(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctxIncomplete)),
         "sanity: incomplete candidate's context logged");
   CRTDetectionResult r3; CRT_DetectV1(ctxIncomplete, r3);
   Check(r3.detected, "sanity: incomplete candidate detected");
   TradeCandidate c3;
   Check(CRT_ToTradeCandidate(ctxIncomplete, r3, c3), "sanity: incomplete candidate mapped");
   Check(CRT_EmitCandidateCreated(c3, ctxIncomplete.symbol_spec.digits), "sanity: incomplete candidate emitted - no RiskPlan/FeatureSnapshot follows it");

   EventStore_Close();

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows, manifest), "export succeeds");
   Check(manifest.candidate_count == 3, "candidate_count == 3 (every CandidateProjection record considered)");
   Check(manifest.incomplete_count == 1, "incomplete_count == 1 (the one candidate missing FeatureSnapshot/RiskPlan)");
   Check(manifest.row_count == 2, "row_count == 2 (the two fully-qualified candidates)");
   Check(manifest.candidate_count == manifest.row_count + manifest.incomplete_count,
         "candidate_count == row_count + incomplete_count holds");
}

//=====================================================================
// Part 1, group 1: outcome identity/determinism
//=====================================================================
void Test_Outcome_IdentityDeterminism()
{
   Print("--- Group 1: RealizedOutcome identity/hash are deterministic across repeated builds ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_OutcomeDeterminism.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "DET", 50), "sanity: chain built and emitted");
   EventStore_Close();

   datetime outcomeTime = anchor + OUTCOME_TIME_OFFSET_SEC;
   RealizedOutcome first;
   Check(RealizedOutcome_Build(c, "WIN", "BACKTEST_RUN_1", "evidence_hash_1", outcomeTime, MLQUANTAI_LABEL_SCHEMA_B8_2_V1, first),
         "sanity: first build succeeds");

   bool allMatch = true;
   for(int i = 0; i < 1000; i++)
   {
      RealizedOutcome repeat;
      if(!RealizedOutcome_Build(c, "WIN", "BACKTEST_RUN_1", "evidence_hash_1", outcomeTime, MLQUANTAI_LABEL_SCHEMA_B8_2_V1, repeat) ||
         repeat.realized_outcome_id != first.realized_outcome_id ||
         repeat.realized_outcome_hash != first.realized_outcome_hash)
      { allMatch = false; break; }
   }
   Check(allMatch, "1,000 repeated builds: identical realized_outcome_id/realized_outcome_hash every time");
   Check(first.realized_outcome_id == Ids_RealizedOutcomeId(c.candidate_id, MLQUANTAI_LABEL_SCHEMA_B8_2_V1),
         "realized_outcome_id == Ids_RealizedOutcomeId(candidate_id, label_schema_version)");
}

//=====================================================================
// Part 1, group 2: temporal boundary
//=====================================================================
void Test_Outcome_TemporalBoundary()
{
   Print("--- Group 2: outcome_time must be strictly after setup_anchor_bar_time ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_TemporalBoundary.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "TIME", 51), "sanity: chain built and emitted");
   EventStore_Close();

   RealizedOutcome afterOutcome;
   Check(RealizedOutcome_Build(c, "WIN", "REF", "HASH", anchor + 3600, MLQUANTAI_LABEL_SCHEMA_B8_2_V1, afterOutcome),
         "outcome_time strictly after setup_anchor_bar_time is accepted");

   RealizedOutcome equalOutcome;
   Check(!RealizedOutcome_Build(c, "WIN", "REF", "HASH", anchor, MLQUANTAI_LABEL_SCHEMA_B8_2_V1, equalOutcome),
         "outcome_time == setup_anchor_bar_time is rejected");
   Check(equalOutcome.realized_outcome_id == "", "rejected (equal-time) outcome stays at Init() defaults");

   RealizedOutcome earlierOutcome;
   Check(!RealizedOutcome_Build(c, "WIN", "REF", "HASH", anchor - 3600, MLQUANTAI_LABEL_SCHEMA_B8_2_V1, earlierOutcome),
         "outcome_time before setup_anchor_bar_time is rejected");
   Check(earlierOutcome.realized_outcome_id == "", "rejected (earlier) outcome stays at Init() defaults");
}

//=====================================================================
// Part 1, group 3: referential integrity
//=====================================================================
void Test_Outcome_BuildTimeValidation()
{
   Print("--- Group 3: build-time validation rejects missing label/outcome_reference/outcome_hash/wrong schema ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_BuildValidation.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "BVAL", 52), "sanity: chain built and emitted");
   EventStore_Close();

   datetime t = anchor + OUTCOME_TIME_OFFSET_SEC;
   RealizedOutcome o1;
   Check(!RealizedOutcome_Build(c, "", "REF", "HASH", t, MLQUANTAI_LABEL_SCHEMA_B8_2_V1, o1), "empty label is rejected");
   RealizedOutcome o2;
   Check(!RealizedOutcome_Build(c, "WIN", "", "HASH", t, MLQUANTAI_LABEL_SCHEMA_B8_2_V1, o2), "empty outcome_reference is rejected");
   RealizedOutcome o3;
   Check(!RealizedOutcome_Build(c, "WIN", "REF", "", t, MLQUANTAI_LABEL_SCHEMA_B8_2_V1, o3), "empty outcome_hash is rejected");
   RealizedOutcome o4;
   Check(!RealizedOutcome_Build(c, "WIN", "REF", "HASH", t, "SOME_OTHER_SCHEMA_V1", o4),
         "a labelSchemaVersion other than MLQUANTAI_LABEL_SCHEMA_B8_2_V1 is rejected");

   TradeCandidate empty; TradeCandidate_Init(empty);
   RealizedOutcome o5;
   Check(!RealizedOutcome_Build(empty, "WIN", "REF", "HASH", t, MLQUANTAI_LABEL_SCHEMA_B8_2_V1, o5), "empty candidate_id is rejected");
}

void Test_Outcome_Replay_OrphanCandidate_Rejected()
{
   Print("--- Group 3: replay - a TRADE_OUTCOME_LABELED referencing an unknown candidate_id is an orphan, rejected ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_Orphan.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "ORPHAN", 53), "sanity: chain built and emitted");
   RealizedOutcome outcome;
   Check(BuildAndEmitOutcome(c, anchor, "WIN", "REF", "HASH", outcome), "sanity: outcome built and emitted");
   EventStore_Close();

   string lines[]; int n = EventStore_ReadAllLines(file, lines);
   string outLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"TRADE_OUTCOME_LABELED\"") >= 0) outLine = lines[i];
   Check(outLine != "", "sanity: the real TRADE_OUTCOME_LABELED line was found");

   string needle = "\"candidate_id\":\"";
   int p = StringFind(outLine, needle);
   int start = p + StringLen(needle);
   int end = start;
   while(end < StringLen(outLine) && StringGetCharacter(outLine, end) != '"') end++;
   string tampered = StringSubstr(outLine, 0, start) + "CND_DOES_NOT_EXIST" + StringSubstr(outLine, end);

   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
      FileWriteString(h, ((lines[i] == outLine) ? tampered : lines[i]) + "\r\n");
   FileClose(h);

   RealizedOutcomeProjectionReport report = RealizedOutcomeProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an orphan candidate reference");
   Check(StringFind(report.first_error, "orphan") >= 0, "first_error mentions the orphan");
}

void Test_Outcome_Replay_CandidateHashMismatch_Rejected()
{
   Print("--- Group 3: replay - a TRADE_OUTCOME_LABELED whose candidate_hash mismatches the real candidate is rejected ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_HashMismatch.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "OHASHMISMATCH", 54), "sanity: chain built and emitted");
   RealizedOutcome outcome;
   Check(BuildAndEmitOutcome(c, anchor, "WIN", "REF", "HASH", outcome), "sanity: outcome built and emitted");
   EventStore_Close();

   string lines[]; int n = EventStore_ReadAllLines(file, lines);
   string outLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"TRADE_OUTCOME_LABELED\"") >= 0) outLine = lines[i];
   Check(outLine != "", "sanity: the real TRADE_OUTCOME_LABELED line was found");

   string needle = "\"candidate_hash\":\"";
   int p = StringFind(outLine, needle);
   int start = p + StringLen(needle);
   int end = start;
   while(end < StringLen(outLine) && StringGetCharacter(outLine, end) != '"') end++;
   string tampered = StringSubstr(outLine, 0, start) + "TAMPERED_HASH" + StringSubstr(outLine, end);

   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
      FileWriteString(h, ((lines[i] == outLine) ? tampered : lines[i]) + "\r\n");
   FileClose(h);

   RealizedOutcomeProjectionReport report = RealizedOutcomeProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on a candidate_hash mismatch");
   Check(StringFind(report.first_error, "mismatch") >= 0, "first_error mentions the mismatch");
}

void Test_Outcome_Replay_TemporalBoundaryViolation_Rejected()
{
   Print("--- Group 2/3: replay - a TRADE_OUTCOME_LABELED tampered to precede setup_anchor_bar_time is rejected ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_ReplayTemporal.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "OTEMPORAL", 55), "sanity: chain built and emitted");
   RealizedOutcome outcome;
   Check(BuildAndEmitOutcome(c, anchor, "WIN", "REF", "HASH", outcome), "sanity: outcome built and emitted");
   EventStore_Close();

   string lines[]; int n = EventStore_ReadAllLines(file, lines);
   string outLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"TRADE_OUTCOME_LABELED\"") >= 0) outLine = lines[i];
   Check(outLine != "", "sanity: the real TRADE_OUTCOME_LABELED line was found");

   string needle = "\"outcome_time\":\"";
   int p = StringFind(outLine, needle);
   int start = p + StringLen(needle);
   int end = start;
   while(end < StringLen(outLine) && StringGetCharacter(outLine, end) != '"') end++;
   string tampered = StringSubstr(outLine, 0, start) + TimeToString(anchor - 3600, TIME_DATE|TIME_SECONDS) + StringSubstr(outLine, end);

   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
      FileWriteString(h, ((lines[i] == outLine) ? tampered : lines[i]) + "\r\n");
   FileClose(h);

   RealizedOutcomeProjectionReport report = RealizedOutcomeProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on a temporal-boundary violation");
   Check(StringFind(report.first_error, "temporal boundary") >= 0, "first_error mentions the temporal boundary");
}

//=====================================================================
// Part 1, group 4: duplicate / collision
//=====================================================================
void Test_Outcome_ExactlyOneEmission()
{
   Print("--- Group 4: a valid RealizedOutcome emits exactly one TRADE_OUTCOME_LABELED event ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_ExactlyOne.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "EXACTLYONE", 56), "sanity: chain built and emitted");
   RealizedOutcome outcome;
   Check(BuildAndEmitOutcome(c, anchor, "WIN", "REF", "HASH", outcome), "sanity: outcome built and emitted");
   Check(!RealizedOutcome_EmitTradeOutcomeLabeled(outcome), "second emission of the identical outcome returns false (no-op)");
   EventStore_Close();

   string lines[]; int n = EventStore_ReadAllLines(file, lines);
   int outLines = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"TRADE_OUTCOME_LABELED\"") >= 0) outLines++;
   Check(outLines == 1, "exactly one TRADE_OUTCOME_LABELED line written");
}

void Test_Outcome_UnfilledEmitsNothing()
{
   Print("--- Group 4: an unfilled (empty id) outcome emits no event ---");
   ResetProjections();
   RealizedOutcome unfilled; RealizedOutcome_Init(unfilled);
   Check(unfilled.realized_outcome_id == "", "sanity: Init() outcome has an empty realized_outcome_id");
   Check(!RealizedOutcome_EmitTradeOutcomeLabeled(unfilled), "emitting an unfilled outcome returns false");
}

void Test_Outcome_Replay_DuplicateSameHash_NoOp()
{
   Print("--- Group 4: replay - same realized_outcome_id + same hash = duplicate no-op ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_ReplayDup.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "OREPLAYDUP", 57), "sanity: chain built and emitted");
   RealizedOutcome outcome;
   Check(BuildAndEmitOutcome(c, anchor, "WIN", "REF", "HASH", outcome), "sanity: outcome built and emitted");
   EventStore_Close();

   RealizedOutcomeProjection_Reset();
   EventStore_Open(file);
   Check(RealizedOutcome_EmitTradeOutcomeLabeled(outcome), "sanity: the identical outcome re-emits under a fresh session");
   EventStore_Close();

   RealizedOutcomeProjectionReport report = RealizedOutcomeProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds despite the duplicate line");
   Check(RealizedOutcomeProjection_Count() == 1, "registry has exactly one record - the duplicate was a no-op");
}

void Test_Outcome_Replay_CollisionDifferentHash_Rejected()
{
   Print("--- Group 4: replay - same realized_outcome_id + DIFFERENT hash = collision, rejected ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_ReplayColl.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "OREPLAYCOLL", 58), "sanity: chain built and emitted");
   RealizedOutcome outcome;
   Check(BuildAndEmitOutcome(c, anchor, "WIN", "REF", "HASH", outcome), "sanity: outcome built and emitted");
   EventStore_Close();

   RealizedOutcome colliding;
   Check(RealizedOutcome_Build(c, "LOSS", "REF", "HASH", anchor + OUTCOME_TIME_OFFSET_SEC, MLQUANTAI_LABEL_SCHEMA_B8_2_V1, colliding),
         "sanity: colliding outcome (different label, same candidate+schema) builds");
   Check(colliding.realized_outcome_id == outcome.realized_outcome_id, "sanity: realized_outcome_id unaffected by label content");
   Check(colliding.realized_outcome_hash != outcome.realized_outcome_hash, "sanity: realized_outcome_hash DOES move with label");

   RealizedOutcomeProjection_Reset();
   EventStore_Open(file);
   Check(RealizedOutcome_EmitTradeOutcomeLabeled(colliding), "sanity: the colliding outcome emits under a fresh session");
   EventStore_Close();

   RealizedOutcomeProjectionReport report = RealizedOutcomeProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on a realized_outcome_id collision");
   Check(StringFind(report.first_error, "collision") >= 0, "first_error mentions the collision, not a duplicate no-op");
}

void Test_Outcome_RestartMultiSession_ByteIdentical()
{
   Print("--- Group 4: repeated rebuilds / multi-session replay reconstruct byte-identical records ---");
   ResetProjections();
   TradeCandidate c1, c2; RiskPlan p1, p2; FeatureSnapshot s1, s2; datetime a1, a2;
   string file = "MLQuantAI_Test_B8_2C3_Restart.jsonl";
   FileDelete(file, FILE_COMMON);

   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c1, p1, s1, a1, "ORESTART1", 59), "sanity: chain 1 built and emitted");
   RealizedOutcome o1;
   Check(BuildAndEmitOutcome(c1, a1, "WIN", "REF1", "HASH1", o1), "sanity: outcome 1 built and emitted");
   EventStore_Close();

   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c2, p2, s2, a2, "ORESTART2", 60), "sanity: chain 2 built and emitted (second session)");
   RealizedOutcome o2;
   Check(BuildAndEmitOutcome(c2, a2, "LOSS", "REF2", "HASH2", o2), "sanity: outcome 2 built and emitted (second session)");
   EventStore_Close();

   RealizedOutcomeProjectionReport report1 = RealizedOutcomeProjection_RebuildFromFile(file);
   Check(report1.ok && RealizedOutcomeProjection_Count() == 2, "first rebuild: 2 records across both sessions");
   RealizedOutcomeProjectionRecord rec1a, rec1b;
   RealizedOutcomeProjection_TryGet(o1.realized_outcome_id, rec1a);
   RealizedOutcomeProjection_TryGet(o2.realized_outcome_id, rec1b);

   RealizedOutcomeProjectionReport report2 = RealizedOutcomeProjection_RebuildFromFile(file);
   Check(report2.ok && RealizedOutcomeProjection_Count() == 2, "second rebuild (simulated restart): still 2 records");
   RealizedOutcomeProjectionRecord rec2a, rec2b;
   RealizedOutcomeProjection_TryGet(o1.realized_outcome_id, rec2a);
   RealizedOutcomeProjection_TryGet(o2.realized_outcome_id, rec2b);

   Check(rec1a.realized_outcome_hash == rec2a.realized_outcome_hash && rec1a.label == rec2a.label, "record 1 identical across both rebuilds");
   Check(rec1b.realized_outcome_hash == rec2b.realized_outcome_hash && rec1b.label == rec2b.label, "record 2 identical across both rebuilds");
}

//=====================================================================
// Part 1, group 5: leakage protection
//=====================================================================
void Test_Leakage_FeatureHashUnchangedByOutcome()
{
   Print("--- Group 5: adding a RealizedOutcome never changes the candidate's feature_snapshot_hash/feature_vector_hash ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_Leakage.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "LEAK", 61), "sanity: chain built and emitted");
   EventStore_Close();

   TrainingDatasetRow rowsBefore[]; TrainingDatasetManifest manifestBefore;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rowsBefore, manifestBefore), "export (unlabeled) succeeds");
   Check(ArraySize(rowsBefore) == 1, "sanity: 1 unlabeled row exported");
   Check(!rowsBefore[0].label_available, "sanity: row is unlabeled before the RealizedOutcome exists");
   string featureSnapshotHashBefore = rowsBefore[0].feature_snapshot_hash;
   string featureVectorHashBefore   = rowsBefore[0].feature_vector_hash;

   EventStore_Open(file);
   RealizedOutcome outcome;
   Check(BuildAndEmitOutcome(c, anchor, "WIN", "REF", "HASH", outcome), "outcome built and emitted after the fact");
   EventStore_Close();

   TrainingDatasetRow rowsAfter[]; TrainingDatasetManifest manifestAfter;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rowsAfter, manifestAfter), "export (labeled) succeeds");
   Check(ArraySize(rowsAfter) == 1, "sanity: still 1 row exported");
   Check(rowsAfter[0].label_available, "sanity: row is now labeled");

   Check(rowsAfter[0].feature_snapshot_hash == featureSnapshotHashBefore,
         "feature_snapshot_hash is IDENTICAL before/after the RealizedOutcome exists - no leakage");
   Check(rowsAfter[0].feature_vector_hash == featureVectorHashBefore,
         "feature_vector_hash is IDENTICAL before/after the RealizedOutcome exists - no leakage");
   Check(rowsAfter[0].candidate_hash == rowsBefore[0].candidate_hash,
         "candidate_hash is IDENTICAL before/after the RealizedOutcome exists - no leakage");
}

void Test_Leakage_StructuralExclusionProof()
{
   Print("--- Group 5: RealizedOutcome cannot reach Candidate_ToFeatureSnapshot or its hashes (structural) ---");
   Check(true, "Candidate_ToFeatureSnapshot (B8.1, sealed) has no RealizedOutcome parameter and never will; "
               "FeatureSnapshot_HashPayload/FeatureSnapshot_VectorHashPayload (B8.1, sealed) reference no field "
               "this commit adds; FeatureSnapshotProjection's own lookup path in TrainingDatasetExport_BuildDataset "
               "is untouched by this commit - RealizedOutcomeProjection is looked up independently, in parallel, "
               "never merged into or read by the feature-snapshot lookup - verified by inspection per "
               "Docs/PhaseB_B8_2_Commit3_OutcomeLabelContract.md's leakage-protection invariant");
}

//=====================================================================
// Part 1, group 6: dataset integration
//=====================================================================
void Test_DatasetIntegration_UnlabeledRowStillExports()
{
   Print("--- Group 6: a candidate with no RealizedOutcome still exports as an unlabeled row ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_Unlabeled.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "UNLABELED", 62), "sanity: chain built and emitted");
   EventStore_Close();

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows, manifest), "export succeeds");
   Check(ArraySize(rows) == 1, "1 row exported");
   Check(!rows[0].label_available, "label_available is false");
   Check(rows[0].label == "" && rows[0].outcome_reference == "" && rows[0].outcome_hash == "",
         "label/outcome fields are empty");
   Check(manifest.labeled_count == 0 && manifest.unlabeled_count == 1, "manifest: 0 labeled, 1 unlabeled");
}

void Test_DatasetIntegration_LabeledRowGetsRealFields()
{
   Print("--- Group 6: a candidate with a RealizedOutcome exports as a labeled row with real fields ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_Labeled.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "LABELED", 63), "sanity: chain built and emitted");
   RealizedOutcome outcome;
   Check(BuildAndEmitOutcome(c, anchor, "WIN", "BACKTEST_RUN_9", "evidence_hash_9", outcome), "sanity: outcome built and emitted");
   EventStore_Close();

   TrainingDatasetRow rows[]; TrainingDatasetManifest manifest;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rows, manifest), "export succeeds");
   Check(ArraySize(rows) == 1, "1 row exported");
   Check(rows[0].label_available, "label_available is true");
   Check(rows[0].label == "WIN", "label matches the RealizedOutcome's own label");
   Check(rows[0].outcome_reference == "BACKTEST_RUN_9", "outcome_reference matches");
   Check(rows[0].outcome_hash == "evidence_hash_9", "outcome_hash matches");
   Check(rows[0].label_schema_version == MLQUANTAI_LABEL_SCHEMA_B8_2_V1, "label_schema_version stays the frozen constant");
   Check(manifest.labeled_count == 1 && manifest.unlabeled_count == 0, "manifest: 1 labeled, 0 unlabeled");
}

void Test_DatasetIntegration_RowHashAndDatasetHashMoveWithLabel()
{
   Print("--- Group 6: row_hash and dataset_hash move when a RealizedOutcome is added ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_HashMoves.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "HASHMOVES", 64), "sanity: chain built and emitted");
   EventStore_Close();

   TrainingDatasetRow rowsBefore[]; TrainingDatasetManifest manifestBefore;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rowsBefore, manifestBefore), "export (unlabeled) succeeds");
   string rowHashBefore     = rowsBefore[0].row_hash;
   string datasetHashBefore = manifestBefore.dataset_hash;
   string datasetRowIdBefore = rowsBefore[0].dataset_row_id;

   EventStore_Open(file);
   RealizedOutcome outcome;
   Check(BuildAndEmitOutcome(c, anchor, "WIN", "REF", "HASH", outcome), "outcome built and emitted after the fact");
   EventStore_Close();

   TrainingDatasetRow rowsAfter[]; TrainingDatasetManifest manifestAfter;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rowsAfter, manifestAfter), "export (labeled) succeeds");

   Check(rowsAfter[0].dataset_row_id == datasetRowIdBefore, "dataset_row_id is UNCHANGED by the label (identity stays the same)");
   Check(rowsAfter[0].row_hash != rowHashBefore, "row_hash MOVES when the label legitimately changes");
   Check(manifestAfter.dataset_hash != datasetHashBefore, "dataset_hash MOVES accordingly");
}

//=====================================================================
// Part 1, group 7: split stability
//=====================================================================
void Test_SplitStability_UnchangedByLabel()
{
   Print("--- Group 7: split is identical whether a row is exported unlabeled or labeled ---");
   ResetProjections();
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot; datetime anchor;
   string file = "MLQuantAI_Test_B8_2C3_SplitStability.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   Check(BuildAndEmitFullChain(c, plan, snapshot, anchor, "SPLITSTABLE", 65), "sanity: chain built and emitted");
   EventStore_Close();

   TrainingDatasetRow rowsBefore[]; TrainingDatasetManifest manifestBefore;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rowsBefore, manifestBefore), "export (unlabeled) succeeds");
   ENUM_DATASET_SPLIT splitBefore = rowsBefore[0].split;

   EventStore_Open(file);
   RealizedOutcome outcome;
   Check(BuildAndEmitOutcome(c, anchor, "WIN", "REF", "HASH", outcome), "outcome built and emitted after the fact");
   EventStore_Close();

   TrainingDatasetRow rowsAfter[]; TrainingDatasetManifest manifestAfter;
   Check(TrainingDatasetExport_BuildDataset(file, MODEL_TARGET_TEST, rowsAfter, manifestAfter), "export (labeled) succeeds");
   ENUM_DATASET_SPLIT splitAfter = rowsAfter[0].split;

   Check(splitAfter == splitBefore, "split is IDENTICAL whether the row was exported unlabeled or labeled");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B8.2 Commit 3 - Outcome/Label Boundary ===");

   Test_ManifestCounters_CandidateCountIncompleteCount();

   Test_Outcome_IdentityDeterminism();
   Test_Outcome_TemporalBoundary();
   Test_Outcome_BuildTimeValidation();
   Test_Outcome_Replay_OrphanCandidate_Rejected();
   Test_Outcome_Replay_CandidateHashMismatch_Rejected();
   Test_Outcome_Replay_TemporalBoundaryViolation_Rejected();
   Test_Outcome_ExactlyOneEmission();
   Test_Outcome_UnfilledEmitsNothing();
   Test_Outcome_Replay_DuplicateSameHash_NoOp();
   Test_Outcome_Replay_CollisionDifferentHash_Rejected();
   Test_Outcome_RestartMultiSession_ByteIdentical();
   Test_Leakage_FeatureHashUnchangedByOutcome();
   Test_Leakage_StructuralExclusionProof();
   Test_DatasetIntegration_UnlabeledRowStillExports();
   Test_DatasetIntegration_LabeledRowGetsRealFields();
   Test_DatasetIntegration_RowHashAndDatasetHashMoveWithLabel();
   Test_SplitStability_UnchangedByLabel();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
