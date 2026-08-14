//+------------------------------------------------------------------+
//| MLQuantAI_Test_CRT_V1_ToTradeCandidate.mq5                        |
//| Phase B B5 Commit 4 DoD: CRT_ToTradeCandidate(ctx, result) - the  |
//| pure CRTDetectionResult -> TradeCandidate mapping. Detection rule |
//| correctness itself (sweep/MSS/FVG/OB edge cases) is Commit 3's    |
//| job, already covered by MLQuantAI_Test_CRT_V1_Rules.mq5 - this    |
//| file only exercises the mapping, on one bullish and one bearish   |
//| already-detected fixture plus the non-detection guard.            |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_ToTradeCandidate.mqh>

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

void BuildBaseContext(MarketContext &ctx)
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
   ctx.context_event_id = "CTX_test_fixture_id";
   ctx.context_hash      = "test_context_hash_value";
}

void FillFillerBars(MqlRates &window[], datetime t0)
{
   for(int i = 0; i < 59; i++)
      MakeBar(window[i], t0 + i * PERIOD_SEC_M5, 105.00, 105.20, 104.80, 105.00, 100, 20);
}

// Same numeric fixture as MLQuantAI_Test_CRT_V1_Rules.mq5's
// Fixture_Bullish_Valid - kept self-contained per this project's
// per-file test convention rather than sharing a helper .mqh.
void Fixture_Bullish_Valid(MqlRates &window[], datetime &outAnchor)
{
   datetime t0 = D'2026.01.01 00:00:00';
   ArrayResize(window, 64);
   FillFillerBars(window, t0);
   MakeBar(window[59], t0 + 59 * PERIOD_SEC_M5, 100.80, 100.90, 99.50,  100.50, 100, 20);
   MakeBar(window[60], t0 + 60 * PERIOD_SEC_M5, 100.50, 101.50, 100.40, 101.40, 100, 20);
   MakeBar(window[61], t0 + 61 * PERIOD_SEC_M5, 101.40, 102.50, 101.30, 102.40, 100, 20);
   MakeBar(window[62], t0 + 62 * PERIOD_SEC_M5, 102.40, 103.50, 102.30, 103.40, 100, 20);
   MakeBar(window[63], t0 + 63 * PERIOD_SEC_M5, 103.40, 104.60, 103.30, 104.50, 100, 20);
   outAnchor = window[63].time;
}

void Fixture_Bearish_Valid_OBFallback(MqlRates &window[], datetime &outAnchor)
{
   datetime t0 = D'2026.01.01 00:00:00';
   ArrayResize(window, 64);
   FillFillerBars(window, t0);
   MakeBar(window[59], t0 + 59 * PERIOD_SEC_M5, 109.00, 110.50, 108.90, 109.50, 100, 20);
   MakeBar(window[60], t0 + 60 * PERIOD_SEC_M5, 109.50, 109.60, 107.50, 108.00, 100, 20);
   MakeBar(window[61], t0 + 61 * PERIOD_SEC_M5, 108.00, 109.00, 106.50, 107.00, 100, 20);
   MakeBar(window[62], t0 + 62 * PERIOD_SEC_M5, 107.00, 108.00, 105.50, 106.00, 100, 20);
   MakeBar(window[63], t0 + 63 * PERIOD_SEC_M5, 106.00, 106.50, 104.00, 104.50, 100, 20);
   outAnchor = window[63].time;
}

//=====================================================================
void Test_Bullish_Mapping()
{
   Print("--- CRT_ToTradeCandidate: valid bullish (FVG) mapping ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(r.detected, "sanity: detector fires on this fixture");

   TradeCandidate c;
   bool ok = CRT_ToTradeCandidate(ctx, r, c);
   Check(ok, "CRT_ToTradeCandidate returns true on a detection");

   Check(c.side == ORDER_TYPE_BUY, "side == ORDER_TYPE_BUY");
   Check(c.direction == SIGNAL_BUY, "direction == SIGNAL_BUY");
   Check(c.root_event_id != "", "root_event_id is non-empty");
   Check(c.candidate_id != "", "candidate_id is non-empty");
   Check(c.candidate_id == Ids_CandidateId(c.root_event_id, "CRT", MLQUANTAI_CRT_V1_RULES_VERSION),
         "candidate_id == Ids_CandidateId(root_event_id, \"CRT\", CRT_V1_RULES_VERSION)");
   Check(c.strategy_id == STRAT_CRT, "strategy_id == STRAT_CRT");
   Check(c.strategy_name == "CRT", "strategy_name == \"CRT\"");
   Check(c.strategy_version == MLQUANTAI_CRT_V1_RULES_VERSION, "strategy_version == MLQUANTAI_CRT_V1_RULES_VERSION");
   Check(c.candidate_schema_version == MLQUANTAI_CANDIDATE_SCHEMA_V1, "candidate_schema_version == MLQUANTAI_CANDIDATE_SCHEMA_V1");

   Check(c.context_event_id == ctx.context_event_id, "context_event_id copied from ctx");
   Check(c.context_hash == ctx.context_hash, "context_hash copied from ctx");

   Check(c.setup_anchor_bar_time == r.mss_confirmation_bar_time, "setup_anchor_bar_time == mss_confirmation_bar_time (contract section 0)");
   Check(c.expiry_after_bars == MLQUANTAI_CRT_V1_EXPIRY_AFTER_BARS, "expiry_after_bars == the frozen 12");

   double expectedEntry = (r.resolved_zone_low + r.resolved_zone_high) / 2.0;
   double expectedSl    = r.swept_level - 1 * ctx.symbol_spec.point;
   double expectedTp    = expectedEntry + MLQUANTAI_CRT_V1_TP_R_MULTIPLE * (expectedEntry - expectedSl);
   Check(c.entry_hint == expectedEntry, "entry_hint == (zone_low + zone_high) / 2.0");
   Check(c.sl_hint == expectedSl, "sl_hint == swept_level - 1 point (bullish)");
   Check(c.tp_hint == expectedTp, "tp_hint == entry_hint + 2.0R (bullish)");

   Check(c.trigger_reason_mask == r.reason_mask, "trigger_reason_mask == result.reason_mask");
   Check(ArraySize(c.trigger_reasons) == ArraySize(r.reason_labels), "trigger_reasons[] length == result.reason_labels[] length");
   bool labelsMatch = true;
   for(int i = 0; i < ArraySize(r.reason_labels); i++)
      if(c.trigger_reasons[i] != r.reason_labels[i]) labelsMatch = false;
   Check(labelsMatch, "trigger_reasons[] content matches result.reason_labels[] exactly, in order");

   Check(c.has_liquidity_sweep, "has_liquidity_sweep == true");
   Check(c.has_mss, "has_mss == true");
   Check(c.has_fvg, "has_fvg == true (this fixture resolves to FVG)");
   Check(!c.has_order_block, "has_order_block == false (this fixture resolves to FVG, not OB)");
   Check(!c.in_killzone, "in_killzone == false (ctx.is_kill_zone was false)");
   Check(!c.news_risk, "news_risk == false (no news configured in this fixture)");

   Check(c.signal_time == c.setup_anchor_bar_time, "signal_time == setup_anchor_bar_time");
   datetime expectedExpiry = TradeCandidate_ComputeExpiryTime(c.setup_anchor_bar_time, c.expiry_after_bars, PERIOD_M5);
   Check(c.expiry_time == expectedExpiry, "expiry_time == TradeCandidate_ComputeExpiryTime(...)");

   // Non-goals (contract): risk-adjusted values, arbitration/regime
   // fields, and lifecycle state all stay at TradeCandidate_Init() defaults.
   Check(c.entry == 0 && c.sl == 0 && c.tp == 0 && c.rr == 0, "entry/sl/tp/rr stay at Init() defaults - risk sizing is B6/B7's job");
   Check(c.atr == 0 && c.stop_distance == 0, "atr/stop_distance stay at Init() defaults");
   Check(c.score == 0 && c.confidence == 0, "score/confidence stay at Init() defaults");
   Check(c.compatible_regime == REGIME_TRANSITION, "compatible_regime stays at Init()'s REGIME_TRANSITION default");
   Check(c.regime_rules_version == "", "regime_rules_version stays empty");
   Check(c.state == CANDIDATE_CREATED, "state == CANDIDATE_CREATED");
   Check(c.last_reason == REASON_NONE, "last_reason == REASON_NONE");
   Check(c.correlation_id == "" && c.parent_candidate_ids == "", "correlation_id/parent_candidate_ids stay empty (set at submission/arbitration time)");

   Check(c.detector_hash == r.detector_hash, "candidate.detector_hash == crt.detector_hash (copied verbatim, never recomputed)");
   Check(c.candidate_hash != "", "candidate_hash is non-empty");
}

void Test_Bearish_Mapping()
{
   Print("--- CRT_ToTradeCandidate: valid bearish (OB fallback) mapping ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_Bearish_Valid_OBFallback(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(r.detected, "sanity: detector fires on this fixture");

   TradeCandidate c;
   bool ok = CRT_ToTradeCandidate(ctx, r, c);
   Check(ok, "CRT_ToTradeCandidate returns true on a detection");

   Check(c.side == ORDER_TYPE_SELL, "side == ORDER_TYPE_SELL");
   Check(c.direction == SIGNAL_SELL, "direction == SIGNAL_SELL");

   double expectedEntry = (r.resolved_zone_low + r.resolved_zone_high) / 2.0;
   double expectedSl    = r.swept_level + 1 * ctx.symbol_spec.point;
   double expectedTp    = expectedEntry - MLQUANTAI_CRT_V1_TP_R_MULTIPLE * (expectedSl - expectedEntry);
   Check(c.entry_hint == expectedEntry, "entry_hint == (zone_low + zone_high) / 2.0");
   Check(c.sl_hint == expectedSl, "sl_hint == swept_level + 1 point (bearish)");
   Check(c.tp_hint == expectedTp, "tp_hint == entry_hint - 2.0R (bearish)");

   Check(c.has_liquidity_sweep, "has_liquidity_sweep == true");
   Check(c.has_mss, "has_mss == true");
   Check(!c.has_fvg, "has_fvg == false (this fixture resolves to OB)");
   Check(c.has_order_block, "has_order_block == true");
   Check(c.detector_hash == r.detector_hash, "candidate.detector_hash == crt.detector_hash (copied verbatim, never recomputed)");
}

void Test_NonDetection_Guard()
{
   Print("--- CRT_ToTradeCandidate: result.detected == false produces an Init()-default candidate ---");
   MarketContext ctx; BuildBaseContext(ctx);
   CRTDetectionResult r;
   CRTDetectionResult_Init(r); // detected == false

   TradeCandidate c;
   bool ok = CRT_ToTradeCandidate(ctx, r, c);

   Check(!ok, "CRT_ToTradeCandidate returns false on a non-detection");
   Check(c.candidate_id == "", "candidate_id stays empty");
   Check(c.root_event_id == "", "root_event_id stays empty");
   Check(c.direction == SIGNAL_NONE, "direction stays SIGNAL_NONE");
   Check(c.strategy_id == -1, "strategy_id stays at Init()'s -1");
   Check(c.trigger_reason_mask == 0, "trigger_reason_mask stays 0");
   Check(ArraySize(c.trigger_reasons) == 0, "trigger_reasons[] stays empty");
   Check(c.context_event_id == "", "context_event_id stays empty (never copied from ctx on a non-detection)");
   Check(c.detector_hash == "", "detector_hash stays empty");
   Check(c.candidate_hash == "", "candidate_hash stays empty");
}

void Test_CandidateId_ChangesWithRulesVersion()
{
   Print("--- candidate_id MUST differ across two different RULES_VERSION strings for the same detector output ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(r.detected, "sanity: detector fires");

   string rootEventId = Ids_RootEventId(ctx.instrument_id, ctx.trigger_timeframe, "CRT_SWEEP_LOW",
                                         r.swept_level, r.mss_confirmation_bar_time, ctx.symbol_spec.digits);
   string idV1 = Ids_CandidateId(rootEventId, "CRT", "CRT_V1");
   string idV2 = Ids_CandidateId(rootEventId, "CRT", "CRT_V2"); // hypothetical future version, same root_event_id/detector output
   Check(idV1 != idV2, "candidate_id differs across rules versions even when root_event_id and detector output are identical");
}

void Test_Determinism()
{
   Print("--- CRT_ToTradeCandidate: byte-identical TradeCandidate across repeated calls ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);

   TradeCandidate c1, c2;
   CRT_ToTradeCandidate(ctx, r, c1);
   CRT_ToTradeCandidate(ctx, r, c2);

   Check(c1.candidate_id == c2.candidate_id, "candidate_id matches across repeated calls");
   Check(c1.root_event_id == c2.root_event_id, "root_event_id matches across repeated calls");
   Check(c1.entry_hint == c2.entry_hint && c1.sl_hint == c2.sl_hint && c1.tp_hint == c2.tp_hint, "entry/sl/tp hints match across repeated calls");
   Check(c1.trigger_reason_mask == c2.trigger_reason_mask, "trigger_reason_mask matches across repeated calls");
   Check(c1.detector_hash == c2.detector_hash, "detector_hash matches across repeated calls");
   Check(c1.candidate_hash == c2.candidate_hash, "candidate_hash matches across repeated calls");
}

void Test_CandidateHash_1000Repeats()
{
   Print("--- candidate_hash: 1000 repeated mappings -> 0 mismatches ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);

   TradeCandidate first;
   CRT_ToTradeCandidate(ctx, r, first);

   int mismatches = 0;
   for(int i = 0; i < 1000; i++)
   {
      TradeCandidate c;
      CRT_ToTradeCandidate(ctx, r, c);
      if(c.candidate_hash != first.candidate_hash) mismatches++;
   }
   Check(mismatches == 0, "1000 rebuilds of the same detection -> 0 candidate_hash mismatches (got " + IntegerToString(mismatches) + ")");
}

void Test_AccountMutation_DoesNotAffectIds()
{
   Print("--- account balance/equity mutations do not affect root_event_id/candidate_id/candidate_hash ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);

   TradeCandidate before;
   CRT_ToTradeCandidate(ctx, r, before);

   ctx.account.balance = 999999.0;
   ctx.account.equity   = 123456.0;
   ctx.account.margin_level = 42.0;

   TradeCandidate after;
   CRT_ToTradeCandidate(ctx, r, after);

   Check(before.root_event_id == after.root_event_id, "root_event_id unaffected by account balance/equity/margin_level mutation");
   Check(before.candidate_id == after.candidate_id, "candidate_id unaffected by account balance/equity/margin_level mutation");
   Check(before.candidate_hash == after.candidate_hash, "candidate_hash unaffected by account balance/equity/margin_level mutation");
}

void Test_DetectorOutputNotMutated()
{
   Print("--- CRT_ToTradeCandidate does not mutate its CRTDetectionResult input ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);

   bool detectedBefore = r.detected;
   ENUM_ORDER_TYPE sideBefore = r.side;
   double sweptBefore = r.swept_level;
   ulong maskBefore = r.reason_mask;
   string hashBefore = r.detector_hash;
   int labelCountBefore = ArraySize(r.reason_labels);

   TradeCandidate c;
   CRT_ToTradeCandidate(ctx, r, c);

   Check(r.detected == detectedBefore, "result.detected unchanged after CRT_ToTradeCandidate");
   Check(r.side == sideBefore, "result.side unchanged after CRT_ToTradeCandidate");
   Check(r.swept_level == sweptBefore, "result.swept_level unchanged after CRT_ToTradeCandidate");
   Check(r.reason_mask == maskBefore, "result.reason_mask unchanged after CRT_ToTradeCandidate");
   Check(r.detector_hash == hashBefore, "result.detector_hash unchanged after CRT_ToTradeCandidate");
   Check(ArraySize(r.reason_labels) == labelCountBefore, "result.reason_labels[] length unchanged after CRT_ToTradeCandidate");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B B5 Commit 4 - CRT_ToTradeCandidate ===");

   Test_Bullish_Mapping();
   Test_Bearish_Mapping();
   Test_NonDetection_Guard();
   Test_CandidateId_ChangesWithRulesVersion();
   Test_Determinism();
   Test_CandidateHash_1000Repeats();
   Test_AccountMutation_DoesNotAffectIds();
   Test_DetectorOutputNotMutated();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
