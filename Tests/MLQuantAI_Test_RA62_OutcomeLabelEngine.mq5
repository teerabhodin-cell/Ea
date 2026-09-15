//+------------------------------------------------------------------+
//| MLQuantAI_Test_RA62_OutcomeLabelEngine.mq5                        |
//| RA-62 (QA-frozen Outcome Label Methodology V1): proves             |
//| OutcomeLabelEngine_Classify() implements the frozen TP/SL/timeout   |
//| algorithm exactly - deterministic, same-bar SL-first tie-break with |
//| explicit flag, distinct TIMEOUT class, BUY/SELL price-basis          |
//| handling, and bit-identical reproducibility. Pure fabricated-input   |
//| tests only - no CopyRates/iHigh/iLow/broker/terminal call anywhere   |
//| in this file, no OrderSend, no position ever opened. Running this    |
//| script on a real account is safe.                                    |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/AI/MLQuantAI_OutcomeLabelEngine.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - plain MqlRates arrays, oldest-first, bid-series.
//---------------------------------------------------------------------
void MakeBar(MqlRates &r, datetime t, double open, double high, double low, double close)
{
   ZeroMemory(r);
   r.time = t; r.open = open; r.high = high; r.low = low; r.close = close;
   r.tick_volume = 100; r.spread = 20;
}

#define TEST_BASE_TIME D'2026.01.01 00:00:00'
#define TEST_BAR_SEC    300 // M5

//=====================================================================
// BUY: TP hit, SL untouched
//=====================================================================
void Test_BUY_TpHit_NoSlTouch()
{
   Print("--- BUY: TP touched on bar 3, SL never touched - resolves TP_HIT ---");
   MqlRates bars[]; ArrayResize(bars, 5);
   MakeBar(bars[0], TEST_BASE_TIME + 0*TEST_BAR_SEC, 100.0, 100.5, 99.5, 100.2);
   MakeBar(bars[1], TEST_BASE_TIME + 1*TEST_BAR_SEC, 100.2, 100.8, 100.0, 100.6);
   MakeBar(bars[2], TEST_BASE_TIME + 2*TEST_BAR_SEC, 100.6, 101.0, 100.4, 100.9);
   MakeBar(bars[3], TEST_BASE_TIME + 3*TEST_BAR_SEC, 100.9, 102.5, 100.8, 102.0); // TP=102.0 touched here
   MakeBar(bars[4], TEST_BASE_TIME + 4*TEST_BAR_SEC, 102.0, 102.2, 101.8, 102.1);

   OutcomeLabelResult result; string err;
   Check(OutcomeLabelEngine_Classify(ORDER_TYPE_BUY, 95.0, 102.0, bars, 5, 100, 0.0, result, err),
         "sanity: classify completes");
   Check(result.label == OUTCOME_LABEL_TP_HIT, "label == TP_HIT");
   Check(!result.same_bar_tiebreak_applied, "no tie-break flagged");
   Check(result.resolution_bar_index == 3, "resolution_bar_index == 3");
   Check(result.resolution_time == bars[3].time, "resolution_time matches bars[3].time");
   Check(result.bars_scanned == 4, "bars_scanned == 4 (stopped at index 3)");
}

//=====================================================================
// BUY: SL hit, TP untouched
//=====================================================================
void Test_BUY_SlHit_NoTpTouch()
{
   Print("--- BUY: SL touched on bar 2, TP never touched - resolves SL_HIT ---");
   MqlRates bars[]; ArrayResize(bars, 4);
   MakeBar(bars[0], TEST_BASE_TIME + 0*TEST_BAR_SEC, 100.0, 100.3, 99.8, 100.1);
   MakeBar(bars[1], TEST_BASE_TIME + 1*TEST_BAR_SEC, 100.1, 100.2, 99.0, 99.2);
   MakeBar(bars[2], TEST_BASE_TIME + 2*TEST_BAR_SEC, 99.2, 99.3, 94.5, 95.0); // SL=95.0 touched here
   MakeBar(bars[3], TEST_BASE_TIME + 3*TEST_BAR_SEC, 95.0, 95.5, 94.8, 95.2);

   OutcomeLabelResult result; string err;
   Check(OutcomeLabelEngine_Classify(ORDER_TYPE_BUY, 95.0, 110.0, bars, 4, 100, 0.0, result, err),
         "sanity: classify completes");
   Check(result.label == OUTCOME_LABEL_SL_HIT, "label == SL_HIT");
   Check(!result.same_bar_tiebreak_applied, "no tie-break flagged");
   Check(result.resolution_bar_index == 2, "resolution_bar_index == 2");
   Check(result.bars_scanned == 3, "bars_scanned == 3 (stopped at index 2)");
}

//=====================================================================
// BUY: same-bar collision - both TP and SL inside one bar's range
//=====================================================================
void Test_BUY_SameBarCollision_ResolvesSlFirst()
{
   Print("--- BUY: single bar's range touches BOTH sl=95.0 and tp=105.0 - RA-62 frozen tie-break: SL-first ---");
   MqlRates bars[]; ArrayResize(bars, 2);
   MakeBar(bars[0], TEST_BASE_TIME + 0*TEST_BAR_SEC, 100.0, 100.3, 99.8, 100.1);
   MakeBar(bars[1], TEST_BASE_TIME + 1*TEST_BAR_SEC, 100.0, 106.0, 94.0, 100.0); // range spans both sl and tp

   OutcomeLabelResult result; string err;
   Check(OutcomeLabelEngine_Classify(ORDER_TYPE_BUY, 95.0, 105.0, bars, 2, 100, 0.0, result, err),
         "sanity: classify completes");
   Check(result.label == OUTCOME_LABEL_SL_HIT, "label == SL_HIT (frozen SL-first tie-break)");
   Check(result.same_bar_tiebreak_applied, "same_bar_tiebreak_applied == true - never a silent 'certain loss'");
   Check(result.resolution_bar_index == 1, "resolution_bar_index == 1");
}

//=====================================================================
// BUY: timeout - neither TP nor SL touched within the scan window
//=====================================================================
void Test_BUY_Timeout_DistinctThirdClass()
{
   Print("--- BUY: neither sl nor tp ever touched within maxLookforwardBars - resolves TIMEOUT, never a directional guess ---");
   MqlRates bars[]; ArrayResize(bars, 5);
   for(int i = 0; i < 5; i++)
      MakeBar(bars[i], TEST_BASE_TIME + i*TEST_BAR_SEC, 100.0, 100.3, 99.8, 100.1); // stays well inside [sl=90, tp=110]

   OutcomeLabelResult result; string err;
   Check(OutcomeLabelEngine_Classify(ORDER_TYPE_BUY, 90.0, 110.0, bars, 5, 3, 0.0, result, err),
         "sanity: classify completes");
   Check(result.label == OUTCOME_LABEL_TIMEOUT, "label == TIMEOUT");
   Check(!result.same_bar_tiebreak_applied, "tie-break flag false for TIMEOUT");
   Check(result.resolution_bar_index == -1, "resolution_bar_index == -1 for TIMEOUT");
   Check(result.resolution_time == 0, "resolution_time == 0 for TIMEOUT");
   Check(result.bars_scanned == 3, "bars_scanned == maxLookforwardBars (3), not barsCount (5) - scan window respected");
}

//=====================================================================
// SELL: TP hit and SL hit, using the frozen spreadApproximation param
//=====================================================================
void Test_SELL_TpHit_WithSpreadApproximation()
{
   Print("--- SELL: tp touched using bid-series low minus spreadApproximation, per RA-62's frozen V1 disclosed approximation ---");
   MqlRates bars[]; ArrayResize(bars, 2);
   MakeBar(bars[0], TEST_BASE_TIME + 0*TEST_BAR_SEC, 100.0, 100.3, 99.8, 100.1);
   MakeBar(bars[1], TEST_BASE_TIME + 1*TEST_BAR_SEC, 99.8, 100.0, 95.01, 95.5); // bid low=95.01; tp=95.0 -> needs spread to touch

   OutcomeLabelResult result; string err;
   // Without spread approximation, 95.01 does NOT touch tp=95.0 (95.01 > 95.0).
   Check(OutcomeLabelEngine_Classify(ORDER_TYPE_SELL, 105.0, 95.0, bars, 2, 100, 0.0, result, err),
         "sanity: classify completes (zero spread)");
   Check(result.label == OUTCOME_LABEL_TIMEOUT, "zero spreadApproximation: tp NOT reached (95.01 > 95.0) -> TIMEOUT");

   OutcomeLabelResult result2; string err2;
   Check(OutcomeLabelEngine_Classify(ORDER_TYPE_SELL, 105.0, 95.0, bars, 2, 100, 0.02, result2, err2),
         "sanity: classify completes (0.02 spread)");
   Check(result2.label == OUTCOME_LABEL_TP_HIT, "with spreadApproximation=0.02: (95.01-0.02)=94.99 <= tp=95.0 -> TP_HIT");
   Check(result2.resolution_bar_index == 1, "resolution_bar_index == 1");
}

void Test_SELL_SlHit_WithSpreadApproximation()
{
   Print("--- SELL: sl touched using bid-series high plus spreadApproximation ---");
   MqlRates bars[]; ArrayResize(bars, 2);
   MakeBar(bars[0], TEST_BASE_TIME + 0*TEST_BAR_SEC, 100.0, 100.3, 99.8, 100.1);
   MakeBar(bars[1], TEST_BASE_TIME + 1*TEST_BAR_SEC, 100.0, 104.99, 99.5, 100.0); // bid high=104.99; sl=105.0

   OutcomeLabelResult result; string err;
   Check(OutcomeLabelEngine_Classify(ORDER_TYPE_SELL, 105.0, 90.0, bars, 2, 100, 0.0, result, err),
         "sanity: classify completes (zero spread)");
   Check(result.label == OUTCOME_LABEL_TIMEOUT, "zero spreadApproximation: sl NOT reached (104.99 < 105.0) -> TIMEOUT");

   OutcomeLabelResult result2; string err2;
   Check(OutcomeLabelEngine_Classify(ORDER_TYPE_SELL, 105.0, 90.0, bars, 2, 100, 0.02, result2, err2),
         "sanity: classify completes (0.02 spread)");
   Check(result2.label == OUTCOME_LABEL_SL_HIT, "with spreadApproximation=0.02: (104.99+0.02)=105.01 >= sl=105.0 -> SL_HIT");
}

void Test_SELL_SameBarCollision_ResolvesSlFirst()
{
   Print("--- SELL: single bar touches both tp and sl (with spread applied) - resolves SL-first, same as BUY ---");
   MqlRates bars[]; ArrayResize(bars, 1);
   MakeBar(bars[0], TEST_BASE_TIME, 100.0, 106.0, 94.0, 100.0); // wide range covers both sides

   OutcomeLabelResult result; string err;
   Check(OutcomeLabelEngine_Classify(ORDER_TYPE_SELL, 105.0, 95.0, bars, 1, 100, 0.0, result, err),
         "sanity: classify completes");
   Check(result.label == OUTCOME_LABEL_SL_HIT, "label == SL_HIT (frozen SL-first tie-break, SELL side)");
   Check(result.same_bar_tiebreak_applied, "same_bar_tiebreak_applied == true");
}

//=====================================================================
// Determinism / reproducibility (RA-62 acceptance criterion 10)
//=====================================================================
void Test_Determinism_SameInputsSameOutput()
{
   Print("--- Re-running the exact same inputs twice produces a bit-identical result (RA-62 AC-10) ---");
   MqlRates bars[]; ArrayResize(bars, 6);
   MakeBar(bars[0], TEST_BASE_TIME + 0*TEST_BAR_SEC, 100.0, 100.5, 99.5, 100.2);
   MakeBar(bars[1], TEST_BASE_TIME + 1*TEST_BAR_SEC, 100.2, 100.8, 100.0, 100.6);
   MakeBar(bars[2], TEST_BASE_TIME + 2*TEST_BAR_SEC, 100.6, 101.0, 100.4, 100.9);
   MakeBar(bars[3], TEST_BASE_TIME + 3*TEST_BAR_SEC, 100.9, 102.5, 100.8, 102.0);
   MakeBar(bars[4], TEST_BASE_TIME + 4*TEST_BAR_SEC, 102.0, 102.2, 101.8, 102.1);
   MakeBar(bars[5], TEST_BASE_TIME + 5*TEST_BAR_SEC, 102.1, 102.4, 101.9, 102.2);

   OutcomeLabelResult r1; string e1;
   OutcomeLabelResult r2; string e2;
   OutcomeLabelEngine_Classify(ORDER_TYPE_BUY, 95.0, 102.0, bars, 6, 100, 0.0, r1, e1);
   OutcomeLabelEngine_Classify(ORDER_TYPE_BUY, 95.0, 102.0, bars, 6, 100, 0.0, r2, e2);

   Check(r1.label == r2.label, "label identical across two runs");
   Check(r1.same_bar_tiebreak_applied == r2.same_bar_tiebreak_applied, "tie-break flag identical");
   Check(r1.resolution_bar_index == r2.resolution_bar_index, "resolution_bar_index identical");
   Check(r1.resolution_time == r2.resolution_time, "resolution_time identical");
   Check(r1.bars_scanned == r2.bars_scanned, "bars_scanned identical");
}

//=====================================================================
// Boundary: maxLookforwardBars smaller than barsCount is respected
//=====================================================================
void Test_ScanWindow_RespectsMaxLookforwardOverBarsCount()
{
   Print("--- scan never looks past min(barsCount, maxLookforwardBars), even if a later bar in the array would have resolved it ---");
   MqlRates bars[]; ArrayResize(bars, 5);
   MakeBar(bars[0], TEST_BASE_TIME + 0*TEST_BAR_SEC, 100.0, 100.3, 99.8, 100.1);
   MakeBar(bars[1], TEST_BASE_TIME + 1*TEST_BAR_SEC, 100.1, 100.3, 99.8, 100.1);
   MakeBar(bars[2], TEST_BASE_TIME + 2*TEST_BAR_SEC, 100.1, 100.3, 99.8, 100.1); // last scanned bar (maxLookforwardBars=3)
   MakeBar(bars[3], TEST_BASE_TIME + 3*TEST_BAR_SEC, 100.1, 110.0, 99.8, 105.0); // would hit TP - never reached
   MakeBar(bars[4], TEST_BASE_TIME + 4*TEST_BAR_SEC, 105.0, 105.3, 104.8, 105.1);

   OutcomeLabelResult result; string err;
   Check(OutcomeLabelEngine_Classify(ORDER_TYPE_BUY, 90.0, 105.0, bars, 5, 3, 0.0, result, err),
         "sanity: classify completes");
   Check(result.label == OUTCOME_LABEL_TIMEOUT, "TIMEOUT - the TP-hitting bar at index 3 is outside the 3-bar scan window");
   Check(result.bars_scanned == 3, "bars_scanned == 3, not 5");
}

//=====================================================================
// Structural validation failures
//=====================================================================
void Test_InvalidSide_Rejects()
{
   Print("--- side outside {BUY, SELL} fails closed ---");
   MqlRates bars[]; ArrayResize(bars, 1);
   MakeBar(bars[0], TEST_BASE_TIME, 100.0, 100.3, 99.8, 100.1);
   OutcomeLabelResult result; string err;
   Check(!OutcomeLabelEngine_Classify(ORDER_TYPE_BUY_LIMIT, 95.0, 105.0, bars, 1, 100, 0.0, result, err),
         "returns false for a non-market side");
   Check(err != "", "outErrorReason is non-empty");
   Check(result.label == OUTCOME_LABEL_NONE, "outResult left at init defaults on failure");
}

void Test_NonPositiveSlTp_Rejects()
{
   Print("--- non-positive plannedSl/plannedTp fails closed ---");
   MqlRates bars[]; ArrayResize(bars, 1);
   MakeBar(bars[0], TEST_BASE_TIME, 100.0, 100.3, 99.8, 100.1);
   OutcomeLabelResult result; string err;
   Check(!OutcomeLabelEngine_Classify(ORDER_TYPE_BUY, 0.0, 105.0, bars, 1, 100, 0.0, result, err),
         "returns false for plannedSl <= 0");
   Check(!OutcomeLabelEngine_Classify(ORDER_TYPE_BUY, 95.0, -1.0, bars, 1, 100, 0.0, result, err),
         "returns false for plannedTp < 0");
}

void Test_NonPositiveMaxLookforward_Rejects()
{
   Print("--- maxLookforwardBars <= 0 fails closed ---");
   MqlRates bars[]; ArrayResize(bars, 1);
   MakeBar(bars[0], TEST_BASE_TIME, 100.0, 100.3, 99.8, 100.1);
   OutcomeLabelResult result; string err;
   Check(!OutcomeLabelEngine_Classify(ORDER_TYPE_BUY, 95.0, 105.0, bars, 1, 0, 0.0, result, err),
         "returns false for maxLookforwardBars == 0");
}

void Test_NegativeSpreadApproximation_Rejects()
{
   Print("--- negative spreadApproximation fails closed ---");
   MqlRates bars[]; ArrayResize(bars, 1);
   MakeBar(bars[0], TEST_BASE_TIME, 100.0, 100.3, 99.8, 100.1);
   OutcomeLabelResult result; string err;
   Check(!OutcomeLabelEngine_Classify(ORDER_TYPE_SELL, 105.0, 95.0, bars, 1, 100, -0.01, result, err),
         "returns false for spreadApproximation < 0");
}

void Test_ZeroBars_ResolvesTimeoutImmediately()
{
   Print("--- barsCount == 0 is not a structural failure - resolves TIMEOUT with bars_scanned == 0 (no data available yet is a valid, honest state) ---");
   MqlRates bars[]; ArrayResize(bars, 0);
   OutcomeLabelResult result; string err;
   Check(OutcomeLabelEngine_Classify(ORDER_TYPE_BUY, 95.0, 105.0, bars, 0, 100, 0.0, result, err),
         "sanity: classify completes (does not fail closed on zero bars)");
   Check(result.label == OUTCOME_LABEL_TIMEOUT, "label == TIMEOUT");
   Check(result.bars_scanned == 0, "bars_scanned == 0");
}

//=====================================================================
// RA-62 frozen policy constants themselves
//=====================================================================
void Test_FrozenPolicyConstants_ExactValues()
{
   Print("--- RA-62 frozen policy constants match exactly what QA froze - 576/864/1440 ---");
   Check(MLQUANTAI_OUTCOME_LABEL_FEATURE_LOOKBACK_BARS_V1 == 576, "FEATURE_LOOKBACK_BARS_V1 == 576");
   Check(MLQUANTAI_OUTCOME_LABEL_MAX_LOOKFORWARD_BARS_V1 == 864, "MAX_LOOKFORWARD_BARS_V1 == 864");
   Check(MLQUANTAI_OUTCOME_LABEL_EMBARGO_BARS_V1 == 1440, "EMBARGO_BARS_V1 == 1440");
   Check(MLQUANTAI_OUTCOME_LABEL_EMBARGO_BARS_V1 == MLQUANTAI_OUTCOME_LABEL_FEATURE_LOOKBACK_BARS_V1 + MLQUANTAI_OUTCOME_LABEL_MAX_LOOKFORWARD_BARS_V1,
         "EMBARGO_BARS_V1 == FEATURE_LOOKBACK_BARS_V1 + MAX_LOOKFORWARD_BARS_V1 (576+864=1440), never silently recomputed differently");
}

void OnStart()
{
   Print("=== MLQuantAI_Test_RA62_OutcomeLabelEngine.mq5 ===");

   Test_BUY_TpHit_NoSlTouch();
   Test_BUY_SlHit_NoTpTouch();
   Test_BUY_SameBarCollision_ResolvesSlFirst();
   Test_BUY_Timeout_DistinctThirdClass();
   Test_SELL_TpHit_WithSpreadApproximation();
   Test_SELL_SlHit_WithSpreadApproximation();
   Test_SELL_SameBarCollision_ResolvesSlFirst();
   Test_Determinism_SameInputsSameOutput();
   Test_ScanWindow_RespectsMaxLookforwardOverBarsCount();
   Test_InvalidSide_Rejects();
   Test_NonPositiveSlTp_Rejects();
   Test_NonPositiveMaxLookforward_Rejects();
   Test_NegativeSpreadApproximation_Rejects();
   Test_ZeroBars_ResolvesTimeoutImmediately();
   Test_FrozenPolicyConstants_ExactValues();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
