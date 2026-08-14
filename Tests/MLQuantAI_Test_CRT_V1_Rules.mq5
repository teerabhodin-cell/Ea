//+------------------------------------------------------------------+
//| MLQuantAI_Test_CRT_V1_Rules.mq5                                   |
//| Phase B B5 Commit 3 DoD: the pure CRT_V1 detection rules -        |
//| CRT_IsSweepLow/High, CRT_CloseBackInside, CRT_ConfirmMSS,          |
//| CRT_FindFVG, CRT_FindOrderBlock, CRT_ResolveZone, CRT_EvaluateExpiry|
//| and the CRT_DetectV1() orchestrator - against every fixture in     |
//| the QA-approved Commit 3 gate list. Hand-built MqlRates windows     |
//| only, no live/broker dependency (pure-function tests throughout).  |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_Rules.mqh>

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

//=====================================================================
// Base context + filler-bar helpers
//=====================================================================
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
}

// Fills window[0..58] with neutral filler bars that never touch pdl/pdh
// (100.00/110.00) - always safely inside [104.80, 105.20].
void FillFillerBars(MqlRates &window[], datetime t0)
{
   for(int i = 0; i < 59; i++)
      MakeBar(window[i], t0 + i * PERIOD_SEC_M5, 105.00, 105.20, 104.80, 105.00, 100, 20);
}

//=====================================================================
// Fixture builders - each returns a 64-bar window (indices 59-63 carry
// the scenario, 0-58 are neutral filler) and the anchor bar's time.
//=====================================================================

// Valid bullish: sweep-low + close-back-inside + MSS + FVG (bar 59 is
// ALSO a valid Order Block candidate - see the dedicated FVG-priority
// test below, which proves FVG wins even when OB would also qualify).
void Fixture_Bullish_Valid(MqlRates &window[], datetime &outAnchor)
{
   datetime t0 = D'2026.01.01 00:00:00';
   ArrayResize(window, 64);
   FillFillerBars(window, t0);
   MakeBar(window[59], t0 + 59 * PERIOD_SEC_M5, 100.80, 100.90, 99.50,  100.50, 100, 20); // sweep+reclaim (bearish candle)
   MakeBar(window[60], t0 + 60 * PERIOD_SEC_M5, 100.50, 101.50, 100.40, 101.40, 100, 20);
   MakeBar(window[61], t0 + 61 * PERIOD_SEC_M5, 101.40, 102.50, 101.30, 102.40, 100, 20);
   MakeBar(window[62], t0 + 62 * PERIOD_SEC_M5, 102.40, 103.50, 102.30, 103.40, 100, 20);
   MakeBar(window[63], t0 + 63 * PERIOD_SEC_M5, 103.40, 104.60, 103.30, 104.50, 100, 20); // MSS/anchor: close 104.50 > structure 103.50
   outAnchor = window[63].time;
}

// Valid bearish: sweep-high + close-back-inside + MSS + OB fallback (no
// qualifying FVG anywhere in the impulse leg - deliberately overlapping
// ranges, including one EXACT-ZERO-gap boundary case at i=61).
void Fixture_Bearish_Valid_OBFallback(MqlRates &window[], datetime &outAnchor)
{
   datetime t0 = D'2026.01.01 00:00:00';
   ArrayResize(window, 64);
   FillFillerBars(window, t0);
   MakeBar(window[59], t0 + 59 * PERIOD_SEC_M5, 109.00, 110.50, 108.90, 109.50, 100, 20); // sweep+reclaim (bullish candle - OB candidate)
   MakeBar(window[60], t0 + 60 * PERIOD_SEC_M5, 109.50, 109.60, 107.50, 108.00, 100, 20);
   MakeBar(window[61], t0 + 61 * PERIOD_SEC_M5, 108.00, 109.00, 106.50, 107.00, 100, 20);
   MakeBar(window[62], t0 + 62 * PERIOD_SEC_M5, 107.00, 108.00, 105.50, 106.00, 100, 20);
   MakeBar(window[63], t0 + 63 * PERIOD_SEC_M5, 106.00, 106.50, 104.00, 104.50, 100, 20); // MSS/anchor: close 104.50 < structure 105.50
   outAnchor = window[63].time;
}

// No sweep at all - every bar (including 59-63) stays inside [pdl, pdh].
void Fixture_NoSweep(MqlRates &window[], datetime &outAnchor)
{
   datetime t0 = D'2026.01.01 00:00:00';
   ArrayResize(window, 64);
   FillFillerBars(window, t0);
   for(int i = 59; i < 64; i++)
      MakeBar(window[i], t0 + i * PERIOD_SEC_M5, 105.00, 105.20, 104.80, 105.00, 100, 20);
   outAnchor = window[63].time;
}

// Sweep-low happens, but the sweep bar closes back BELOW pdl (never
// reclaims) - close-back-inside must fail, and detection must fail with
// it, even though the rest of the window is untouched from the valid
// bullish fixture.
void Fixture_Bullish_SweepNoCloseBackInside(MqlRates &window[], datetime &outAnchor)
{
   Fixture_Bullish_Valid(window, outAnchor);
   MakeBar(window[59], window[59].time, 100.80, 100.90, 99.50, 99.80, 100, 20); // close 99.80 stays BELOW pdl 100.00
}

// Sweep + close-back-inside happen, but the rally into the anchor bar
// never breaks the pre-sweep structure high - MSS must fail.
void Fixture_Bullish_CloseBackInsideNoMSS(MqlRates &window[], datetime &outAnchor)
{
   Fixture_Bullish_Valid(window, outAnchor);
   MakeBar(window[63], window[63].time, 102.90, 103.20, 101.80, 102.00, 100, 20); // close 102.00 stays BELOW structure 103.50
}

// Sweep + close-back-inside + MSS all confirm, but neither a qualifying
// FVG nor a qualifying Order Block exists anywhere in the impulse leg -
// every candle from the sweep bar through the bar before MSS is
// same-color as the move (bullish), and no 3-candle gap ever opens.
void Fixture_Bullish_MSSNoZone(MqlRates &window[], datetime &outAnchor)
{
   datetime t0 = D'2026.01.01 00:00:00';
   ArrayResize(window, 64);
   FillFillerBars(window, t0);
   MakeBar(window[59], t0 + 59 * PERIOD_SEC_M5, 99.80,  100.90, 99.50,  100.50, 100, 20); // sweep+reclaim, BULLISH candle (no OB candidate)
   MakeBar(window[60], t0 + 60 * PERIOD_SEC_M5, 100.50, 101.40, 100.30, 101.30, 100, 20);
   MakeBar(window[61], t0 + 61 * PERIOD_SEC_M5, 101.30, 102.20, 100.80, 102.10, 100, 20); // low 100.80 <= bar59.high 100.90 -> no FVG at i=59
   MakeBar(window[62], t0 + 62 * PERIOD_SEC_M5, 102.10, 103.00, 101.30, 102.90, 100, 20); // low 101.30 <= bar60.high 101.40 -> no FVG at i=60
   MakeBar(window[63], t0 + 63 * PERIOD_SEC_M5, 102.90, 104.50, 102.00, 104.20, 100, 20); // low 102.00 <= bar61.high 102.20 -> no FVG at i=61; close 104.20 > structure 103.00
   outAnchor = window[63].time;
}

//=====================================================================
// Fixture tests (contract's Commit 3 gate list)
//=====================================================================
void Test_Fixture_Bullish_Valid()
{
   Print("--- Fixture: valid bullish (sweep-low + close-back-inside + MSS + FVG) ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);

   Check(r.detected, "detected == true");
   Check(r.side == ORDER_TYPE_BUY, "side == ORDER_TYPE_BUY");
   Check(r.swept_level == ctx.pdl, "swept_level == ctx.pdl");
   Check(r.resolved_zone_kind == "FVG", "resolved_zone_kind == FVG");
   Check(r.resolved_zone_low == 100.90 && r.resolved_zone_high == 101.30, "resolved zone == the earliest-formed qualifying FVG");
   Check(r.reason_mask == (CRT_REASON_BIT_SWEEP_LOW | CRT_REASON_BIT_CLOSE_BACK_INSIDE | CRT_REASON_BIT_MSS_CONFIRMED | CRT_REASON_BIT_FVG_FOUND),
         "reason_mask == exactly SWEEP_LOW|CLOSE_BACK_INSIDE|MSS_CONFIRMED|FVG_FOUND");
   Check(r.detector_hash != "", "detector_hash is non-empty");

   ulong sweepBits = r.reason_mask & (CRT_REASON_BIT_SWEEP_LOW | CRT_REASON_BIT_SWEEP_HIGH);
   Check(sweepBits == CRT_REASON_BIT_SWEEP_LOW, "exactly one sweep reason bit is set");
   ulong zoneBits = r.reason_mask & (CRT_REASON_BIT_FVG_FOUND | CRT_REASON_BIT_OB_FOUND);
   Check(zoneBits == CRT_REASON_BIT_FVG_FOUND, "exactly one zone reason bit is set");

   // FVG-priority proof: bar 59 (the sweep bar) is ALSO a valid Order
   // Block candidate (bearish candle) - confirm CRT_FindOrderBlock alone
   // would have found it, yet CRT_ResolveZone still picked the FVG.
   double obLow, obHigh;
   bool obWouldQualify = CRT_FindOrderBlock(ctx, 59, 63, true, obLow, obHigh);
   Check(obWouldQualify, "a qualifying Order Block ALSO exists in this window (bar 59 is bearish)");
   Check(r.resolved_zone_kind == "FVG", "FVG_PRIORITY_THEN_OB_FALLBACK picks FVG even when OB also qualifies");
}

void Test_Fixture_Bearish_Valid_OBFallback()
{
   Print("--- Fixture: valid bearish (sweep-high + close-back-inside + MSS + OB fallback) ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_Bearish_Valid_OBFallback(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);

   Check(r.detected, "detected == true");
   Check(r.side == ORDER_TYPE_SELL, "side == ORDER_TYPE_SELL");
   Check(r.swept_level == ctx.pdh, "swept_level == ctx.pdh");
   Check(r.resolved_zone_kind == "OB", "resolved_zone_kind == OB (no qualifying FVG exists)");
   Check(r.resolved_zone_low == 108.90 && r.resolved_zone_high == 110.50, "resolved zone == the sweep bar's own range");
   Check(r.reason_mask == (CRT_REASON_BIT_SWEEP_HIGH | CRT_REASON_BIT_CLOSE_BACK_INSIDE | CRT_REASON_BIT_MSS_CONFIRMED | CRT_REASON_BIT_OB_FOUND),
         "reason_mask == exactly SWEEP_HIGH|CLOSE_BACK_INSIDE|MSS_CONFIRMED|OB_FOUND");

   ulong sweepBits = r.reason_mask & (CRT_REASON_BIT_SWEEP_LOW | CRT_REASON_BIT_SWEEP_HIGH);
   Check(sweepBits == CRT_REASON_BIT_SWEEP_HIGH, "exactly one sweep reason bit is set");
   ulong zoneBits = r.reason_mask & (CRT_REASON_BIT_FVG_FOUND | CRT_REASON_BIT_OB_FOUND);
   Check(zoneBits == CRT_REASON_BIT_OB_FOUND, "exactly one zone reason bit is set");

   double fvgLow, fvgHigh;
   bool fvgFound = CRT_FindFVG(ctx, 59, 63, false, fvgLow, fvgHigh);
   Check(!fvgFound, "no qualifying FVG exists anywhere in this impulse leg (confirmed directly)");
}

void Test_Fixture_NoSweep()
{
   Print("--- Fixture: no sweep ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_NoSweep(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(!r.detected, "detected == false (no bar ever pierced pdl or pdh)");
   Check(r.reason_mask == 0, "reason_mask stays 0");
}

void Test_Fixture_SweepWithoutCloseBackInside()
{
   Print("--- Fixture: sweep without close-back-inside ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_Bullish_SweepNoCloseBackInside(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   Check(CRT_IsSweepLow(ctx, 59), "sanity: bar 59 still sweeps pdl");
   Check(!CRT_CloseBackInside(ctx, 59, true), "sanity: bar 59 no longer closes back above pdl");

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(!r.detected, "detected == false (swept but never reclaimed)");
}

void Test_Fixture_CloseBackInsideWithoutMSS()
{
   Print("--- Fixture: close-back-inside without MSS ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_Bullish_CloseBackInsideNoMSS(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   Check(CRT_IsSweepLow(ctx, 59), "sanity: sweep still holds");
   Check(CRT_CloseBackInside(ctx, 59, true), "sanity: close-back-inside still holds");
   double structureLevel;
   Check(!CRT_ConfirmMSS(ctx, 59, 63, true, structureLevel), "sanity: MSS does not confirm (anchor close never breaks structure)");

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(!r.detected, "detected == false (reclaimed but structure never broke)");
}

void Test_Fixture_MSSWithoutValidZone()
{
   Print("--- Fixture: MSS without a valid FVG/OB retest ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_Bullish_MSSNoZone(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   Check(CRT_IsSweepLow(ctx, 59), "sanity: sweep holds");
   Check(CRT_CloseBackInside(ctx, 59, true), "sanity: close-back-inside holds");
   double structureLevel;
   Check(CRT_ConfirmMSS(ctx, 59, 63, true, structureLevel), "sanity: MSS confirms");

   double zLow, zHigh;
   Check(!CRT_FindFVG(ctx, 59, 63, true, zLow, zHigh), "no qualifying FVG exists in the impulse leg");
   Check(!CRT_FindOrderBlock(ctx, 59, 63, true, zLow, zHigh), "no qualifying Order Block exists in the impulse leg (every candle is bullish)");

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(!r.detected, "detected == false (MSS confirmed, but no valid retest zone -> fails closed)");
}

void Test_Fixture_ShortHistory()
{
   Print("--- Fixture: short (<64-bar) window ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   MqlRates fullWindow[]; Fixture_Bullish_Valid(fullWindow, anchor); // a window that WOULD detect at full length
   ArrayResize(ctx.trigger_tf_recent, 10);
   for(int i = 0; i < 10; i++)
      ctx.trigger_tf_recent[i] = fullWindow[i + 54]; // last 10 bars of the valid fixture, including the full scenario
   ctx.anchor_bar_time = ctx.trigger_tf_recent[9].time;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(!r.detected, "detected == false (fewer than MLQUANTAI_CRT_V1_LOOKBACK_BARS closed bars -> CRT-ineligible)");
}

void Test_Fixture_DeterministicAcrossRepeatedCalls()
{
   Print("--- Fixture: same input -> byte-identical CRTDetectionResult across repeated calls ---");
   MarketContext ctx; BuildBaseContext(ctx);
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r1, r2;
   CRT_DetectV1(ctx, r1);
   CRT_DetectV1(ctx, r2);

   Check(r1.detected == r2.detected, "detected matches across repeated calls");
   Check(r1.side == r2.side, "side matches");
   Check(r1.swept_level == r2.swept_level, "swept_level matches");
   Check(r1.mss_confirmation_price == r2.mss_confirmation_price, "mss_confirmation_price matches");
   Check(r1.mss_confirmation_bar_time == r2.mss_confirmation_bar_time, "mss_confirmation_bar_time matches");
   Check(r1.resolved_zone_kind == r2.resolved_zone_kind, "resolved_zone_kind matches");
   Check(r1.resolved_zone_high == r2.resolved_zone_high && r1.resolved_zone_low == r2.resolved_zone_low, "resolved zone matches");
   Check(r1.reason_mask == r2.reason_mask, "reason_mask matches");
   Check(r1.detector_hash == r2.detector_hash, "detector_hash matches");
   Check(ArraySize(r1.reason_labels) == ArraySize(r2.reason_labels), "reason_labels[] length matches");
}

//=====================================================================
// Boundary-bar (exact-equality) tests
//=====================================================================
void Test_BoundaryEquality()
{
   Print("--- Boundary: exact-equality touches never count as a sweep/reclaim/gap ---");
   MarketContext ctx; BuildBaseContext(ctx);
   ArrayResize(ctx.trigger_tf_recent, 1);
   MakeBar(ctx.trigger_tf_recent[0], D'2026.01.01 00:00:00', 100.00, 100.00, 100.00, 100.00, 100, 20); // low == pdl exactly
   Check(!CRT_IsSweepLow(ctx, 0), "low == pdl exactly is NOT a sweep (strict <)");

   MakeBar(ctx.trigger_tf_recent[0], D'2026.01.01 00:00:00', 110.00, 110.00, 110.00, 110.00, 100, 20); // high == pdh exactly
   Check(!CRT_IsSweepHigh(ctx, 0), "high == pdh exactly is NOT a sweep (strict >)");

   MakeBar(ctx.trigger_tf_recent[0], D'2026.01.01 00:00:00', 99.00, 100.10, 99.00, 100.00, 100, 20); // close == pdl exactly
   Check(!CRT_CloseBackInside(ctx, 0, true), "close == pdl exactly is NOT close-back-inside (strict >)");

   // FVG gap exactly 0 (candle 3's low == candle 1's high) must not qualify.
   MqlRates gapWindow[3];
   MakeBar(gapWindow[0], D'2026.01.01 00:00:00', 100.0, 101.00, 99.0, 100.5, 100, 20);
   MakeBar(gapWindow[1], D'2026.01.01 00:05:00', 100.5, 102.00, 99.5, 101.5, 100, 20);
   MakeBar(gapWindow[2], D'2026.01.01 00:10:00', 101.5, 103.00, 101.00, 102.5, 100, 20); // low == gapWindow[0].high exactly
   MarketContext gapCtx; BuildBaseContext(gapCtx);
   ArrayResize(gapCtx.trigger_tf_recent, 3);
   gapCtx.trigger_tf_recent[0] = gapWindow[0];
   gapCtx.trigger_tf_recent[1] = gapWindow[1];
   gapCtx.trigger_tf_recent[2] = gapWindow[2];
   double zLow, zHigh;
   Check(!CRT_FindFVG(gapCtx, 0, 2, true, zLow, zHigh), "a gap of exactly 0 does NOT qualify as an FVG (strict > MIN_FVG_GAP)");
}

//=====================================================================
// CRT_EvaluateExpiry / timeframe conversion
//=====================================================================
void Test_EvaluateExpiry()
{
   Print("--- CRT_EvaluateExpiry / CRT_TimeframeTagToPeriod ---");
   Check(CRT_TimeframeTagToPeriod("M5") == PERIOD_M5, "M5 tag maps to PERIOD_M5");
   Check(CRT_TimeframeTagToPeriod("M15") == PERIOD_M15, "M15 tag maps to PERIOD_M15");
   Check(CRT_TimeframeTagToPeriod("H1") == PERIOD_H1, "H1 tag maps to PERIOD_H1");

   datetime anchor = D'2026.01.01 00:00:00';
   int expiryAfterBars = MLQUANTAI_CRT_V1_EXPIRY_AFTER_BARS; // frozen at 12
   ENUM_TIMEFRAMES tf = PERIOD_M5;
   datetime expiryTime = anchor + (datetime)(expiryAfterBars * PeriodSeconds(tf));

   Check(!CRT_EvaluateExpiry(anchor, expiryAfterBars, tf, expiryTime - 300), "one bar before expiry -> not yet expired");
   Check(CRT_EvaluateExpiry(anchor, expiryAfterBars, tf, expiryTime), "exactly at expiry bar progression -> expired");
   Check(CRT_EvaluateExpiry(anchor, expiryAfterBars, tf, expiryTime + 300), "past expiry -> expired");
}

//=====================================================================
// Individual pure-function sanity (beyond what the fixtures already cover)
//=====================================================================
void Test_MssBarIndex()
{
   Print("--- CRT_MssBarIndex ---");
   MarketContext ctx; BuildBaseContext(ctx);
   ArrayResize(ctx.trigger_tf_recent, 64);
   Check(CRT_MssBarIndex(ctx) == 63, "CRT_MssBarIndex == ArraySize(trigger_tf_recent) - 1");
}

//=====================================================================
// Entry point
//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B B5 Commit 3 - CRT_V1 Detection Rules ===");

   Test_Fixture_Bullish_Valid();
   Test_Fixture_Bearish_Valid_OBFallback();
   Test_Fixture_NoSweep();
   Test_Fixture_SweepWithoutCloseBackInside();
   Test_Fixture_CloseBackInsideWithoutMSS();
   Test_Fixture_MSSWithoutValidZone();
   Test_Fixture_ShortHistory();
   Test_Fixture_DeterministicAcrossRepeatedCalls();
   Test_BoundaryEquality();
   Test_EvaluateExpiry();
   Test_MssBarIndex();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
