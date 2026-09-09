//+------------------------------------------------------------------+
//| MLQuantAI_Test_CRT_V1_Integrity_A1R1.mq5                          |
//| CRT_V1 Integrity Amendment A1-R1 — isolated evidence suite.       |
//| Does NOT modify or duplicate Tests/MLQuantAI_Test_CRT_V1_Rules.mq5|
//| (the sealed Commit 3 suite) — that file's own 57/57 PASS result   |
//| is the FVG-regression evidence (T6) for this amendment; it is not |
//| re-run or re-implemented here.                                    |
//|                                                                    |
//| Exercises the amendment's midpoint gate (CRT_IsZoneGeometrically- |
//| Consistent, called from inside CRT_DetectV1()) through CRT_V1's   |
//| own public detection entry point — CRT_DetectV1() — never by       |
//| asserting `midpoint <= swept_level` in isolation. Every fixture    |
//| here is a full 64-bar MarketContext window that genuinely walks    |
//| through sweep -> close-back-inside -> MSS -> zone resolution, so   |
//| a passing/failing check proves the real integration, not just the |
//| comparison operator.                                                |
//|                                                                    |
//| T1/T2 fixtures reproduce the exact swept_level/entry_hint pairs    |
//| the six historical invalid candidates (I4 frequency scan against  |
//| MLQuantAI_events_W1_Remediation_v1.jsonl) actually produced.        |
//| swept_level for each is not itself a stored field on               |
//| CANDIDATE_CREATED - it is recovered by inverting the frozen,        |
//| unchanged §8 formula (sl_hint = swept_level -+ point, point=0.01   |
//| for XAUUSD digits=2, confirmed directly against a real              |
//| MARKET_CONTEXT_READY record for case 1: pdl=4682.18000 matches      |
//| sl_hint(4682.17)+point exactly). This is an exact algebraic         |
//| inversion of an unchanged frozen formula, not a reconstruction or   |
//| guess of any field that was never durably recorded.                 |
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

void BuildBaseContext(MarketContext &ctx, double pdl, double pdh)
{
   MarketContext_Init(ctx);
   ctx.instrument_id      = "XAUUSD";
   ctx.broker_symbol      = "XAUUSD";
   ctx.trigger_timeframe  = "M5";
   ctx.symbol_spec.digits = 2;
   ctx.symbol_spec.point  = 0.01;
   ctx.pdl = pdl;
   ctx.pdh = pdh;
   ctx.is_kill_zone = false;
   ctx.max_news_impact = 0;
   ctx.nearest_news_minutes = 9999;
}

//=====================================================================
// Fixture builders
//
// Every bar except bar 59 is independent of entryTarget - only bar 59's
// formula-driven edge (low for bullish, high for bearish) is solved
// algebraically so (zoneLow+zoneHigh)/2 == entryTarget EXACTLY, while
// every other CRT_V1 precondition (sweep/reclaim/MSS/no-FVG-anywhere/
// OB-resolves-to-bar-59) is satisfied for ANY entryTarget in the range
// these fixtures use (verified by hand against every case below).
//=====================================================================

// Bullish (BUY): swept_level = pdl. Resolves an Order Block at bar 59
// (the sweep bar itself - a bearish candle, matching CRT_FindOrderBlock's
// "last opposing-color candle" rule for a bullish thesis) whose midpoint
// equals entryTarget exactly.
void BuildBullishFixture(MqlRates &window[], datetime &outAnchor, double pdl, double entryTarget)
{
   datetime t0 = D'2026.01.01 00:00:00';
   ArrayResize(window, 64);
   for(int i = 0; i < 59; i++)
      MakeBar(window[i], t0 + i * PERIOD_SEC_M5, pdl + 500.00, pdl + 500.20, pdl + 499.80, pdl + 500.00, 100, 20);

   double low59 = 2.0 * entryTarget - pdl - 1.60; // solved so (low59+high59)/2 == entryTarget
   MakeBar(window[59], t0 + 59 * PERIOD_SEC_M5, pdl + 1.00, pdl + 1.60, low59,     pdl + 0.50, 100, 20); // sweep+reclaim, bearish (OB candidate)
   MakeBar(window[60], t0 + 60 * PERIOD_SEC_M5, pdl + 0.50, pdl + 1.60, pdl + 0.50, pdl + 1.50, 100, 20);
   MakeBar(window[61], t0 + 61 * PERIOD_SEC_M5, pdl + 1.50, pdl + 2.60, pdl + 1.50, pdl + 2.50, 100, 20);
   MakeBar(window[62], t0 + 62 * PERIOD_SEC_M5, pdl + 2.50, pdl + 3.60, pdl + 1.60, pdl + 3.50, 100, 20);
   MakeBar(window[63], t0 + 63 * PERIOD_SEC_M5, pdl + 4.00, pdl + 4.60, pdl + 2.60, pdl + 4.50, 100, 20); // MSS/anchor
   outAnchor = window[63].time;
}

// Bearish (SELL): swept_level = pdh. Mirror of the bullish builder -
// resolves an Order Block at bar 59 (a bullish candle, matching the
// "opposing color" rule for a bearish thesis) whose midpoint equals
// entryTarget exactly.
void BuildBearishFixture(MqlRates &window[], datetime &outAnchor, double pdh, double entryTarget)
{
   datetime t0 = D'2026.01.01 00:00:00';
   ArrayResize(window, 64);
   for(int i = 0; i < 59; i++)
      MakeBar(window[i], t0 + i * PERIOD_SEC_M5, pdh - 500.00, pdh - 499.80, pdh - 500.20, pdh - 500.00, 100, 20);

   double high59 = 2.0 * entryTarget - pdh + 1.60; // solved so (low59+high59)/2 == entryTarget
   MakeBar(window[59], t0 + 59 * PERIOD_SEC_M5, pdh - 1.00, high59,     pdh - 1.60, pdh - 0.50, 100, 20); // sweep+reclaim, bullish (OB candidate)
   MakeBar(window[60], t0 + 60 * PERIOD_SEC_M5, pdh - 0.50, pdh - 0.50, pdh - 1.60, pdh - 1.50, 100, 20);
   MakeBar(window[61], t0 + 61 * PERIOD_SEC_M5, pdh - 1.50, pdh - 1.50, pdh - 2.60, pdh - 2.50, 100, 20);
   MakeBar(window[62], t0 + 62 * PERIOD_SEC_M5, pdh - 2.50, pdh - 1.60, pdh - 3.60, pdh - 3.50, 100, 20);
   MakeBar(window[63], t0 + 63 * PERIOD_SEC_M5, pdh - 4.00, pdh - 2.60, pdh - 4.60, pdh - 4.50, 100, 20); // MSS/anchor
   outAnchor = window[63].time;
}

//=====================================================================
// Shared sanity + assertion helper for the invalid-geometry cases
// (T1/T2/T3/T4). Proves the failure happens at the new gate - not at
// sweep/close-back-inside/MSS/zone-resolution, which must all still
// succeed - before asserting CRT_DetectV1()'s final detected==false.
//=====================================================================
void AssertBullishInvalid(double pdl, double entryTarget, string label)
{
   Print("--- ", label, " (bullish, swept_level=", DoubleToString(pdl, 2), ", entry=", DoubleToString(entryTarget, 2), ") ---");
   MarketContext ctx; BuildBaseContext(ctx, pdl, pdl + 1000.0);
   datetime anchor;
   BuildBullishFixture(ctx.trigger_tf_recent, anchor, pdl, entryTarget);
   ctx.anchor_bar_time = anchor;

   Check(CRT_IsSweepLow(ctx, 59), "sanity: sweep holds");
   Check(CRT_CloseBackInside(ctx, 59, true), "sanity: close-back-inside holds");
   double structureLevel;
   Check(CRT_ConfirmMSS(ctx, 59, 63, true, structureLevel), "sanity: MSS confirms");
   string zoneKind; double zoneLow, zoneHigh;
   Check(CRT_ResolveZone(ctx, 59, 63, true, zoneKind, zoneLow, zoneHigh), "sanity: a zone is resolved");
   Check(zoneKind == "OB", "sanity: resolved zone kind == OB");
   double mid = (zoneLow + zoneHigh) * 0.5;
   Check(MathAbs(mid - entryTarget) < 0.0001, "sanity: resolved zone midpoint == entryTarget");
   Check(!CRT_IsZoneGeometricallyConsistent(true, pdl, zoneLow, zoneHigh), "sanity: midpoint gate itself rejects this geometry");

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(!r.detected, "detected == false (geometrically invalid despite valid sweep/MSS/zone)");
}

void AssertBearishInvalid(double pdh, double entryTarget, string label)
{
   Print("--- ", label, " (bearish, swept_level=", DoubleToString(pdh, 2), ", entry=", DoubleToString(entryTarget, 2), ") ---");
   MarketContext ctx; BuildBaseContext(ctx, pdh - 1000.0, pdh);
   datetime anchor;
   BuildBearishFixture(ctx.trigger_tf_recent, anchor, pdh, entryTarget);
   ctx.anchor_bar_time = anchor;

   Check(CRT_IsSweepHigh(ctx, 59), "sanity: sweep holds");
   Check(CRT_CloseBackInside(ctx, 59, false), "sanity: close-back-inside holds");
   double structureLevel;
   Check(CRT_ConfirmMSS(ctx, 59, 63, false, structureLevel), "sanity: MSS confirms");
   string zoneKind; double zoneLow, zoneHigh;
   Check(CRT_ResolveZone(ctx, 59, 63, false, zoneKind, zoneLow, zoneHigh), "sanity: a zone is resolved");
   Check(zoneKind == "OB", "sanity: resolved zone kind == OB");
   double mid = (zoneLow + zoneHigh) * 0.5;
   Check(MathAbs(mid - entryTarget) < 0.0001, "sanity: resolved zone midpoint == entryTarget");
   Check(!CRT_IsZoneGeometricallyConsistent(false, pdh, zoneLow, zoneHigh), "sanity: midpoint gate itself rejects this geometry");

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(!r.detected, "detected == false (geometrically invalid despite valid sweep/MSS/zone)");
}

//=====================================================================
// T1 — the four historical BUY-invalid candidates (I4 frequency scan).
// swept_level recovered from each real sl_hint via sl_hint = swept_level
// - point (point=0.01), i.e. swept_level = sl_hint + 0.01.
//=====================================================================
void Test_T1_Case_CND_287d3aba8f797eb6()
{
   // real data: entry_hint=4681.84, sl_hint=4682.17 -> swept_level=4682.18
   AssertBullishInvalid(4682.18, 4681.84, "T1 CND_287d3aba8f797eb6");
}

void Test_T1_Case_CND_5e705b54b2b07b82()
{
   // real data: entry_hint=4681.84, sl_hint=4682.17 -> swept_level=4682.18
   // (identical entry/sl/tp to CND_287d3aba8f797eb6 in the real dataset -
   // I4 confirmed this is a genuine duplicate occurrence, not a scan
   // error; tested separately here for full per-candidate traceability.)
   AssertBullishInvalid(4682.18, 4681.84, "T1 CND_5e705b54b2b07b82");
}

void Test_T1_Case_CND_1e011c5f8ee77942()
{
   // real data: entry_hint=4781.80, sl_hint=4786.32 -> swept_level=4786.33
   AssertBullishInvalid(4786.33, 4781.80, "T1 CND_1e011c5f8ee77942");
}

void Test_T1_Case_CND_f049de864b322c07()
{
   // real data: entry_hint=4076.30, sl_hint=4076.54 -> swept_level=4076.55
   AssertBullishInvalid(4076.55, 4076.30, "T1 CND_f049de864b322c07");
}

//=====================================================================
// T2 — the two historical SELL-invalid candidates (I4 frequency scan).
// swept_level recovered via sl_hint = swept_level + point, i.e.
// swept_level = sl_hint - 0.01.
//=====================================================================
void Test_T2_Case_CND_c59731be5307e260()
{
   // real data: entry_hint=5038.34, sl_hint=5038.07 -> swept_level=5038.06
   AssertBearishInvalid(5038.06, 5038.34, "T2 CND_c59731be5307e260");
}

void Test_T2_Case_CND_802a31ca8d78319e()
{
   // real data: entry_hint=4545.47, sl_hint=4544.43 -> swept_level=4544.42
   AssertBearishInvalid(4544.42, 4545.47, "T2 CND_802a31ca8d78319e");
}

//=====================================================================
// T3/T4 — exact midpoint == swept_level boundary equality.
//=====================================================================
void Test_T3_BullishEquality()
{
   AssertBullishInvalid(100.00, 100.00, "T3 bullish equality (midpoint == swept_level)");
}

void Test_T4_BearishEquality()
{
   AssertBearishInvalid(110.00, 110.00, "T4 bearish equality (midpoint == swept_level)");
}

//=====================================================================
// T5 — zone crosses swept_level, but midpoint is on the valid side.
// Detection MUST still succeed (this is exactly the property that
// distinguishes A1-R1 from the withdrawn whole-zone A1 draft, and the
// property Test_Fixture_Bearish_Valid_OBFallback already proves in the
// sealed suite for one specific real geometry - these two fixtures
// prove it generically, for both directions, with an explicit
// crossing-zone assertion).
//=====================================================================
void Test_T5_BullishCrossingButValid()
{
   double pdl = 100.00;
   double entryTarget = 100.30; // > pdl -> valid, even though the zone crosses pdl
   Print("--- T5 bullish crossing zone, valid midpoint (swept_level=", DoubleToString(pdl, 2), ", entry=", DoubleToString(entryTarget, 2), ") ---");
   MarketContext ctx; BuildBaseContext(ctx, pdl, pdl + 1000.0);
   datetime anchor;
   BuildBullishFixture(ctx.trigger_tf_recent, anchor, pdl, entryTarget);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(r.detected, "detected == true (midpoint valid despite crossing zone)");
   Check(r.side == ORDER_TYPE_BUY, "side == ORDER_TYPE_BUY");
   Check(r.resolved_zone_low < pdl, "zone crosses swept_level: resolved_zone_low < swept_level");
   Check(r.resolved_zone_high > pdl, "zone crosses swept_level: resolved_zone_high > swept_level");
   double mid = (r.resolved_zone_low + r.resolved_zone_high) * 0.5;
   Check(mid > pdl, "resolved zone midpoint is on the valid (bullish) side of swept_level");
}

void Test_T5_BearishCrossingButValid()
{
   double pdh = 110.00;
   double entryTarget = 109.70; // < pdh -> valid, even though the zone crosses pdh
   Print("--- T5 bearish crossing zone, valid midpoint (swept_level=", DoubleToString(pdh, 2), ", entry=", DoubleToString(entryTarget, 2), ") ---");
   MarketContext ctx; BuildBaseContext(ctx, pdh - 1000.0, pdh);
   datetime anchor;
   BuildBearishFixture(ctx.trigger_tf_recent, anchor, pdh, entryTarget);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(r.detected, "detected == true (midpoint valid despite crossing zone)");
   Check(r.side == ORDER_TYPE_SELL, "side == ORDER_TYPE_SELL");
   Check(r.resolved_zone_low < pdh, "zone crosses swept_level: resolved_zone_low < swept_level");
   Check(r.resolved_zone_high > pdh, "zone crosses swept_level: resolved_zone_high > swept_level");
   double mid = (r.resolved_zone_low + r.resolved_zone_high) * 0.5;
   Check(mid < pdh, "resolved zone midpoint is on the valid (bearish) side of swept_level");
}

//=====================================================================
// Entry point
//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: CRT_V1 Integrity Amendment A1-R1 - isolated evidence suite ===");
   Print("NOTE: T6 (FVG regression corpus) is NOT re-tested here - it is");
   Print("covered by Tests/MLQuantAI_Test_CRT_V1_Rules.mq5's own 57/57 PASS");
   Print("result (the sealed suite is not modified or duplicated by this file).");

   Test_T1_Case_CND_287d3aba8f797eb6();
   Test_T1_Case_CND_5e705b54b2b07b82();
   Test_T1_Case_CND_1e011c5f8ee77942();
   Test_T1_Case_CND_f049de864b322c07();

   Test_T2_Case_CND_c59731be5307e260();
   Test_T2_Case_CND_802a31ca8d78319e();

   Test_T3_BullishEquality();
   Test_T4_BearishEquality();

   Test_T5_BullishCrossingButValid();
   Test_T5_BearishCrossingButValid();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
