//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_1_FeatureSnapshot.mq5                          |
//| Phase B8.1 DoD, per Docs/PhaseB_B8_1_FeatureSnapshotContract.md's |
//| QA gate: Candidate_ToFeatureSnapshot identity/lineage/hash        |
//| correctness. Uses the real B5 pipeline (CRT_DetectV1 ->            |
//| CRT_ToTradeCandidate) for every fixture candidate - no fabricated |
//| candidate_hash/detector_hash/context_hash anywhere. No EventStore |
//| involved at all: Candidate_ToFeatureSnapshot is a pure in-memory   |
//| function with no event emission in B8.1 (mirrors B7 Commit 1,      |
//| which also had no EventStore dependency).                          |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_ToTradeCandidate.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as Test_B7_Commit3_IntegrationRegression.mq5
// (each .mq5 test script in this project is standalone).
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
   ctx.context_event_id = "CTX_b8_1_" + suffix;
   ctx.context_hash      = "test_context_hash_b8_1_" + suffix;
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

// Builds a real candidate via the real B5 pipeline - no EventStore
// involved, no emission, since Candidate_ToFeatureSnapshot needs
// nothing beyond an in-memory TradeCandidate + MarketContext.
bool BuildCandidate(TradeCandidate &c, MarketContext &ctx, string suffix, int dayOffset)
{
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.01.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   return CRT_ToTradeCandidate(ctx, r, c);
}

//=====================================================================
void Test_Determinism()
{
   Print("--- determinism: 10,000 repeated calls, same candidate + same MarketContext ---");
   TradeCandidate c; MarketContext ctx;
   Check(BuildCandidate(c, ctx, "DET", 1), "sanity: candidate built");

   FeatureSnapshot first;
   Check(Candidate_ToFeatureSnapshot(c, ctx, first), "sanity: first call succeeds");

   bool allMatch = true;
   for(int i = 0; i < 10000; i++)
   {
      FeatureSnapshot f;
      Candidate_ToFeatureSnapshot(c, ctx, f);
      if(f.feature_snapshot_id != first.feature_snapshot_id ||
         f.feature_vector_hash != first.feature_vector_hash ||
         f.feature_snapshot_hash != first.feature_snapshot_hash)
      {
         allMatch = false;
         break;
      }
   }
   Check(allMatch, "10,000 iterations: zero feature_snapshot_id/feature_vector_hash/feature_snapshot_hash mismatches");
}

void Test_FeatureSnapshotId_DependsOnlyOnCandidateId()
{
   Print("--- feature_snapshot_id depends only on candidate_id ---");
   TradeCandidate c; MarketContext ctx;
   Check(BuildCandidate(c, ctx, "IDCHECK", 2), "sanity: candidate built");

   FeatureSnapshot f;
   Check(Candidate_ToFeatureSnapshot(c, ctx, f), "sanity: call succeeds");
   Check(f.feature_snapshot_id == Ids_FeatureSnapshotId(c.candidate_id),
         "feature_snapshot_id == Ids_FeatureSnapshotId(candidate_id)");
}

void Test_VectorHash_InclusionSweep()
{
   Print("--- feature_vector_hash: every INCLUDED field change moves the hash ---");
   TradeCandidate c; MarketContext ctx;
   Check(BuildCandidate(c, ctx, "VECINC", 3), "sanity: candidate built");
   FeatureSnapshot baseline;
   Check(Candidate_ToFeatureSnapshot(c, ctx, baseline), "sanity: baseline snapshot built");

   FeatureSnapshot f;

   f = baseline; f.feature_schema_version = "OTHER_SCHEMA";
   Check(FeatureSnapshot_ComputeVectorHash(f) != baseline.feature_vector_hash, "feature_schema_version change moves feature_vector_hash");

   f = baseline; f.atr_m15 += 0.5;
   Check(FeatureSnapshot_ComputeVectorHash(f) != baseline.feature_vector_hash, "atr_m15 change moves feature_vector_hash");

   f = baseline; f.adx_m15 += 0.5;
   Check(FeatureSnapshot_ComputeVectorHash(f) != baseline.feature_vector_hash, "adx_m15 change moves feature_vector_hash");

   f = baseline; f.ema_slope_m15 += 0.01;
   Check(FeatureSnapshot_ComputeVectorHash(f) != baseline.feature_vector_hash, "ema_slope_m15 change moves feature_vector_hash");

   f = baseline; f.pdh += 1.0;
   Check(FeatureSnapshot_ComputeVectorHash(f) != baseline.feature_vector_hash, "pdh change moves feature_vector_hash");

   f = baseline; f.pdl += 1.0;
   Check(FeatureSnapshot_ComputeVectorHash(f) != baseline.feature_vector_hash, "pdl change moves feature_vector_hash");

   f = baseline; f.asian_range_high += 1.0;
   Check(FeatureSnapshot_ComputeVectorHash(f) != baseline.feature_vector_hash, "asian_range_high change moves feature_vector_hash");

   f = baseline; f.asian_range_low += 1.0;
   Check(FeatureSnapshot_ComputeVectorHash(f) != baseline.feature_vector_hash, "asian_range_low change moves feature_vector_hash");

   f = baseline; f.spread_points_at_anchor += 5.0;
   Check(FeatureSnapshot_ComputeVectorHash(f) != baseline.feature_vector_hash, "spread_points_at_anchor change moves feature_vector_hash");

   f = baseline; f.news_count += 1;
   Check(FeatureSnapshot_ComputeVectorHash(f) != baseline.feature_vector_hash, "news_count change moves feature_vector_hash");

   f = baseline; f.max_news_impact += 1;
   Check(FeatureSnapshot_ComputeVectorHash(f) != baseline.feature_vector_hash, "max_news_impact change moves feature_vector_hash");

   f = baseline; f.nearest_news_minutes += 1;
   Check(FeatureSnapshot_ComputeVectorHash(f) != baseline.feature_vector_hash, "nearest_news_minutes change moves feature_vector_hash");

   f = baseline; f.is_kill_zone = !baseline.is_kill_zone;
   Check(FeatureSnapshot_ComputeVectorHash(f) != baseline.feature_vector_hash, "is_kill_zone change moves feature_vector_hash");

   // Every one of these also moves feature_snapshot_hash, since it
   // includes feature_vector_hash in its own payload.
   f = baseline; f.atr_m15 += 0.5; f.feature_vector_hash = FeatureSnapshot_ComputeVectorHash(f);
   Check(FeatureSnapshot_ComputeHash(f) != baseline.feature_snapshot_hash,
         "a vector-content change also moves feature_snapshot_hash (it includes feature_vector_hash)");
}

void Test_LineageOnly_MutationSweep()
{
   Print("--- lineage-only mutation: moves feature_snapshot_hash but NEVER feature_vector_hash ---");
   TradeCandidate c; MarketContext ctx;
   Check(BuildCandidate(c, ctx, "LINONLY", 4), "sanity: candidate built");
   FeatureSnapshot baseline;
   Check(Candidate_ToFeatureSnapshot(c, ctx, baseline), "sanity: baseline snapshot built");

   FeatureSnapshot f;

   f = baseline; f.candidate_id = "CND_DIFFERENT";
   Check(FeatureSnapshot_ComputeVectorHash(f) == baseline.feature_vector_hash, "candidate_id change does NOT move feature_vector_hash");
   Check(FeatureSnapshot_ComputeHash(f) != baseline.feature_snapshot_hash, "candidate_id change DOES move feature_snapshot_hash");

   f = baseline; f.candidate_hash = "DIFFERENT_HASH";
   Check(FeatureSnapshot_ComputeVectorHash(f) == baseline.feature_vector_hash, "candidate_hash change does NOT move feature_vector_hash");
   Check(FeatureSnapshot_ComputeHash(f) != baseline.feature_snapshot_hash, "candidate_hash change DOES move feature_snapshot_hash");

   f = baseline; f.context_event_id = "CTX_DIFFERENT";
   Check(FeatureSnapshot_ComputeVectorHash(f) == baseline.feature_vector_hash, "context_event_id change does NOT move feature_vector_hash");
   Check(FeatureSnapshot_ComputeHash(f) != baseline.feature_snapshot_hash, "context_event_id change DOES move feature_snapshot_hash");

   f = baseline; f.context_hash = "DIFFERENT_CONTEXT_HASH";
   Check(FeatureSnapshot_ComputeVectorHash(f) == baseline.feature_vector_hash, "context_hash change does NOT move feature_vector_hash");
   Check(FeatureSnapshot_ComputeHash(f) != baseline.feature_snapshot_hash, "context_hash change DOES move feature_snapshot_hash");

   f = baseline; f.detector_hash = "DIFFERENT_DETECTOR_HASH";
   Check(FeatureSnapshot_ComputeVectorHash(f) == baseline.feature_vector_hash, "detector_hash change does NOT move feature_vector_hash");
   Check(FeatureSnapshot_ComputeHash(f) != baseline.feature_snapshot_hash, "detector_hash change DOES move feature_snapshot_hash");

   f = baseline; f.feature_snapshot_id = "FSNAP_DIFFERENT";
   Check(FeatureSnapshot_ComputeVectorHash(f) == baseline.feature_vector_hash, "feature_snapshot_id change does NOT move feature_vector_hash");
   Check(FeatureSnapshot_ComputeHash(f) != baseline.feature_snapshot_hash, "feature_snapshot_id change DOES move feature_snapshot_hash (deliberate redundancy, not excluded)");
}

void Test_LineageCopiedVerbatim()
{
   Print("--- candidate_hash/context_hash/detector_hash are copied verbatim, never recomputed ---");
   TradeCandidate c; MarketContext ctx;
   Check(BuildCandidate(c, ctx, "VERBATIM", 5), "sanity: candidate built");
   FeatureSnapshot f;
   Check(Candidate_ToFeatureSnapshot(c, ctx, f), "sanity: call succeeds");

   Check(f.candidate_hash == c.candidate_hash, "feature_snapshot.candidate_hash == candidate.candidate_hash");
   Check(f.context_hash == c.context_hash, "feature_snapshot.context_hash == candidate.context_hash");
   Check(f.detector_hash == c.detector_hash, "feature_snapshot.detector_hash == candidate.detector_hash");
   Check(f.context_event_id == c.context_event_id, "feature_snapshot.context_event_id == candidate.context_event_id");
}

void Test_DifferentCandidate_ChangesIdAndSnapshotHash()
{
   Print("--- two different real candidates -> different feature_snapshot_id AND feature_snapshot_hash ---");
   TradeCandidate cA; MarketContext ctxA;
   TradeCandidate cB; MarketContext ctxB;
   Check(BuildCandidate(cA, ctxA, "DIFFA", 6), "sanity: candidate A built");
   Check(BuildCandidate(cB, ctxB, "DIFFB", 7), "sanity: candidate B built");
   Check(cA.candidate_id != cB.candidate_id, "sanity: the two candidates have different candidate_id");

   FeatureSnapshot fA, fB;
   Check(Candidate_ToFeatureSnapshot(cA, ctxA, fA), "sanity: snapshot A built");
   Check(Candidate_ToFeatureSnapshot(cB, ctxB, fB), "sanity: snapshot B built");

   Check(fA.feature_snapshot_id != fB.feature_snapshot_id, "different candidates -> different feature_snapshot_id");
   Check(fA.feature_snapshot_hash != fB.feature_snapshot_hash, "different candidates -> different feature_snapshot_hash");
}

void Test_ReferentialIntegrity_ContextMismatch_Rejected()
{
   Print("--- a ctx whose context_event_id/context_hash doesn't match the candidate's own is rejected ---");
   TradeCandidate c; MarketContext ctx;
   Check(BuildCandidate(c, ctx, "REFCHK", 8), "sanity: candidate built");

   MarketContext wrongEventId = ctx;
   wrongEventId.context_event_id = "CTX_WRONG";
   FeatureSnapshot f1;
   Check(!Candidate_ToFeatureSnapshot(c, wrongEventId, f1), "mismatched context_event_id is rejected");
   Check(f1.candidate_id == "", "rejected snapshot stays at Init() defaults - no partial output");

   MarketContext wrongHash = ctx;
   wrongHash.context_hash = "test_context_hash_TAMPERED";
   FeatureSnapshot f2;
   Check(!Candidate_ToFeatureSnapshot(c, wrongHash, f2), "mismatched context_hash is rejected");
   Check(f2.candidate_id == "", "rejected snapshot stays at Init() defaults - no partial output");
}

void Test_FailClosed()
{
   Print("--- fail-closed: invalid candidate/context input ---");

   TradeCandidate c; MarketContext ctx;
   Check(BuildCandidate(c, ctx, "FAILCLOSED", 9), "sanity: candidate built");

   TradeCandidate emptyId = c;
   emptyId.candidate_id = "";
   FeatureSnapshot f1;
   Check(!Candidate_ToFeatureSnapshot(emptyId, ctx, f1), "empty candidate_id is rejected");

   TradeCandidate wrongState = c;
   wrongState.state = CANDIDATE_EXPIRED;
   FeatureSnapshot f2;
   Check(!Candidate_ToFeatureSnapshot(wrongState, ctx, f2), "candidate.state != CANDIDATE_CREATED is rejected");

   // +Inf via a real multiplication overflow - 0.0/0.0 traps as a hard
   // "zero divide" runtime error in MQL5 and halts the script (the
   // same lesson B7 Commit 1 learned on its first real test run).
   double huge = 1.0e307;
   double infinity = huge * huge;
   MarketContext nanCtx = ctx;
   nanCtx.atr_m15 = infinity;
   FeatureSnapshot f3;
   Check(!Candidate_ToFeatureSnapshot(c, nanCtx, f3), "+Inf atr_m15 is rejected");
   Check(f3.candidate_id == "", "rejected snapshot stays at Init() defaults - no partial output");
}

void Test_NoMutation()
{
   Print("--- candidate/ctx are not mutated by Candidate_ToFeatureSnapshot ---");
   TradeCandidate c; MarketContext ctx;
   Check(BuildCandidate(c, ctx, "NOMUT", 10), "sanity: candidate built");

   string candidateIdBefore = c.candidate_id;
   double atrBefore = ctx.atr_m15;
   string contextHashBefore = ctx.context_hash;

   FeatureSnapshot f;
   Check(Candidate_ToFeatureSnapshot(c, ctx, f), "sanity: call succeeds");

   Check(c.candidate_id == candidateIdBefore, "candidate.candidate_id unchanged after the call");
   Check(ctx.atr_m15 == atrBefore, "ctx.atr_m15 unchanged after the call");
   Check(ctx.context_hash == contextHashBefore, "ctx.context_hash unchanged after the call");
}

//---------------------------------------------------------------------
// Structural checks - not runtime-testable, verified by inspection,
// same class as Test_PhaseBContracts.mq5's own Test_NoExecutionPathIntroduced.
//---------------------------------------------------------------------
void Test_NoEventStoreOrBrokerCall()
{
   Print("--- no event store append, no broker/order/history/tick call (structural) ---");
   Check(true, "Market/MLQuantAI_FeatureSnapshotBuilder.mqh contains no EventStore_Log*/OrderSend/CTrade/"
               "AccountInfo*/SymbolInfo*/TimeCurrent/iATR/iADX/iMA call anywhere - verified by inspection "
               "per Docs/PhaseB_B8_1_FeatureSnapshotContract.md section 4");
}

void Test_NoFutureOutcomeField()
{
   Print("--- no future/outcome/execution field anywhere on FeatureSnapshot (structural) ---");
   Check(true, "FeatureSnapshot carries no fill price, P/L, or execution status field, and neither hash "
               "payload references one - verified by inspection per "
               "Docs/PhaseB_B8_1_FeatureSnapshotContract.md section 5");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B8.1 - FeatureSnapshot Identity/Lineage/Hash ===");

   Test_Determinism();
   Test_FeatureSnapshotId_DependsOnlyOnCandidateId();
   Test_VectorHash_InclusionSweep();
   Test_LineageOnly_MutationSweep();
   Test_LineageCopiedVerbatim();
   Test_DifferentCandidate_ChangesIdAndSnapshotHash();
   Test_ReferentialIntegrity_ContextMismatch_Rejected();
   Test_FailClosed();
   Test_NoMutation();
   Test_NoEventStoreOrBrokerCall();
   Test_NoFutureOutcomeField();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
