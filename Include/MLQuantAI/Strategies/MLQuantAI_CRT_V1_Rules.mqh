//+------------------------------------------------------------------+
//| MLQuantAI - Strategies/MLQuantAI_CRT_V1_Rules.mqh                 |
//| Phase B B5 Commit 3: the actual CRT_V1 detection rules - sweep,   |
//| close-back-inside, MSS confirmation, FVG/OB retest resolution,    |
//| expiry evaluation, and the CRT_DetectV1() orchestrator that turns |
//| a single MarketContext into zero or one CRTDetectionResult.       |
//|                                                                    |
//| Every function here reads ONLY: const MarketContext &ctx, pure    |
//| scalar values computed by other CRT_* calls in this file, and the |
//| frozen CRT_V1 parameters from MLQuantAI_CRT_V1_Contract.mqh - per |
//| Docs/PhaseB_B5_CRTContract.md section 10's Pure Function Contract.|
//| No CopyRates/iTime/SymbolInfo*/AccountInfo*/TimeCurrent()/         |
//| MathRand() anywhere below.                                        |
//|                                                                    |
//| Implementation-level decisions this commit had to freeze that the |
//| Commit 1 contract left to Commit 3 (documented in full in          |
//| Docs/PhaseB_B5_Commit3.md - flagged here briefly for anyone        |
//| reading only this file):                                          |
//|  - "the swept level" (contract section 5's payload comment says    |
//|    "the prior swing/PDH/PDL price that was pierced") is resolved   |
//|    to ctx.pdh/ctx.pdl specifically - both are already-frozen ctx   |
//|    fields, so this needs no new unfrozen "swing detection"         |
//|    primitive. A rolling-swing variant would be CRT_V2.             |
//|  - MSS is checked against exactly ONE bar: the anchor bar itself   |
//|    (the last element of trigger_tf_recent[]) - CRT_DetectV1() asks |
//|    "did MSS confirm on THIS closed bar", matching how the EA main  |
//|    loop calls FeatureEngine_BuildContext() + a detector once per   |
//|    newly closed trigger-timeframe bar.                             |
//|  - the pre-sweep structure level (the high/low MSS must break) is  |
//|    the max/min over bars from the sweep bar through the bar just   |
//|    before the anchor - not a separate frozen lookback constant,    |
//|    since it's bounded naturally by the sweep-to-anchor distance.   |
//|  - CRT_REASON_BIT_NEWS_RISK (informational/audit-only per contract |
//|    section 2 - B5 never gates on it) uses a new                    |
//|    MLQUANTAI_CRT_V1_NEWS_RISK_WINDOW_MINUTES constant below.       |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CRT_V1_RULES_MQH__
#define __MLQUANTAI_CRT_V1_RULES_MQH__

#include "MLQuantAI_CRT_V1_Contract.mqh"
#include "../Market/MLQuantAI_MarketContext.mqh"
#include "../Core/MLQuantAI_TradeCandidate.mqh" // TradeCandidate_ComputeExpiryTime - reused, not reinvented (contract section 9)

// Informational-only threshold (contract section 2: bits 6-7 are
// audit-only, B5 never gates a candidate's creation on them) - "near"
// for CRT_REASON_BIT_NEWS_RISK. Not part of the contract's frozen
// section 8/9 parameter table (those govern candidate CREATION, this
// only governs one audit bit's value) but the same discipline applies:
// changing it is a CRT_V2 concern if it's ever promoted to something
// B6/B7 actually gates on.
#define MLQUANTAI_CRT_V1_NEWS_RISK_WINDOW_MINUTES 30

// The one bar every CRT_V1 check is ultimately about: "did MSS confirm
// on the current closed bar". Trivially derived from ctx, exists only so
// every function below shares one definition instead of repeating
// ArraySize(ctx.trigger_tf_recent) - 1.
int CRT_MssBarIndex(const MarketContext &ctx)
{
   return ArraySize(ctx.trigger_tf_recent) - 1;
}

//---------------------------------------------------------------------
// Sweep detection (contract section 5's "swept level" = ctx.pdl/ctx.pdh)
//---------------------------------------------------------------------
bool CRT_IsSweepLow(const MarketContext &ctx, int barIndex)
{
   if(barIndex < 0 || barIndex >= ArraySize(ctx.trigger_tf_recent)) return false;
   return ctx.trigger_tf_recent[barIndex].low < ctx.pdl; // strictly below - an exact touch does not count as a sweep
}

bool CRT_IsSweepHigh(const MarketContext &ctx, int barIndex)
{
   if(barIndex < 0 || barIndex >= ArraySize(ctx.trigger_tf_recent)) return false;
   return ctx.trigger_tf_recent[barIndex].high > ctx.pdh; // strictly above - an exact touch does not count as a sweep
}

// Most recent bar before the anchor bar that swept - scans backward so
// the closest sweep to "now" wins if more than one qualifying bar exists
// in the window. Returns -1 if none found anywhere in trigger_tf_recent[].
int CRT_FindSweepLowBarIndex(const MarketContext &ctx)
{
   int mssBarIndex = CRT_MssBarIndex(ctx);
   for(int i = mssBarIndex - 1; i >= 0; i--)
      if(CRT_IsSweepLow(ctx, i)) return i;
   return -1;
}

int CRT_FindSweepHighBarIndex(const MarketContext &ctx)
{
   int mssBarIndex = CRT_MssBarIndex(ctx);
   for(int i = mssBarIndex - 1; i >= 0; i--)
      if(CRT_IsSweepHigh(ctx, i)) return i;
   return -1;
}

//---------------------------------------------------------------------
// Close-back-inside: the sweep bar itself closes back inside the level
// it pierced - a single-candle wick-and-reclaim, the simplest reading of
// "closed back inside the swept range" that stays a pure per-bar check.
//---------------------------------------------------------------------
bool CRT_CloseBackInside(const MarketContext &ctx, int sweepBarIndex, bool bullish)
{
   if(sweepBarIndex < 0 || sweepBarIndex >= ArraySize(ctx.trigger_tf_recent)) return false;
   double c = ctx.trigger_tf_recent[sweepBarIndex].close;
   return bullish ? (c > ctx.pdl) : (c < ctx.pdh); // strict - an exact-level close does not count as "back inside"
}

//---------------------------------------------------------------------
// MSS confirmation: the anchor bar's close must break the structure
// high/low formed from the sweep bar through the bar just before the
// anchor. outStructureLevel is exposed for test/debug visibility, not
// used by any caller for control flow.
//---------------------------------------------------------------------
bool CRT_ConfirmMSS(const MarketContext &ctx, int sweepBarIndex, int mssBarIndex, bool bullish, double &outStructureLevel)
{
   outStructureLevel = 0;
   if(sweepBarIndex < 0 || sweepBarIndex >= mssBarIndex) return false;
   if(mssBarIndex < 0 || mssBarIndex >= ArraySize(ctx.trigger_tf_recent)) return false;

   double level = bullish ? ctx.trigger_tf_recent[sweepBarIndex].high : ctx.trigger_tf_recent[sweepBarIndex].low;
   for(int i = sweepBarIndex + 1; i < mssBarIndex; i++)
   {
      if(bullish) level = MathMax(level, ctx.trigger_tf_recent[i].high);
      else        level = MathMin(level, ctx.trigger_tf_recent[i].low);
   }
   outStructureLevel = level;

   double anchorClose = ctx.trigger_tf_recent[mssBarIndex].close;
   return bullish ? (anchorClose > level) : (anchorClose < level); // strict break, not a touch
}

//---------------------------------------------------------------------
// FVG: a qualifying 3-candle gap in the impulse leg (sweep bar through
// the bar just before MSS confirms), earliest-formed (closest to the
// sweep) wins - contract section 8's "prefer the FVG closest to the
// swept price". Gap must be strictly greater than MLQUANTAI_CRT_V1_
// MIN_FVG_GAP (frozen at 0.0 - any non-zero 3-candle gap qualifies).
//---------------------------------------------------------------------
bool CRT_FindFVG(const MarketContext &ctx, int sweepBarIndex, int mssBarIndex, bool bullish, double &outZoneLow, double &outZoneHigh)
{
   outZoneLow = 0;
   outZoneHigh = 0;
   for(int i = sweepBarIndex; i <= mssBarIndex - 2; i++)
   {
      MqlRates c1 = ctx.trigger_tf_recent[i];
      MqlRates c3 = ctx.trigger_tf_recent[i + 2];
      if(bullish)
      {
         double gap = c3.low - c1.high;
         if(gap > MLQUANTAI_CRT_V1_MIN_FVG_GAP)
         {
            outZoneLow = c1.high;
            outZoneHigh = c3.low;
            return true;
         }
      }
      else
      {
         double gap = c1.low - c3.high;
         if(gap > MLQUANTAI_CRT_V1_MIN_FVG_GAP)
         {
            outZoneLow = c3.high;
            outZoneHigh = c1.low;
            return true;
         }
      }
   }
   return false;
}

//---------------------------------------------------------------------
// Order Block fallback: the last opposing-color candle before the MSS
// (displacement) candle, scanned backward through the impulse leg -
// contract section 8's "the last opposing-color candle immediately
// before the impulse leg's displacement candle". The MSS-confirming bar
// itself IS the displacement candle for CRT_V1 (see CRT_MssBarIndex).
//---------------------------------------------------------------------
bool CRT_FindOrderBlock(const MarketContext &ctx, int sweepBarIndex, int mssBarIndex, bool bullish, double &outZoneLow, double &outZoneHigh)
{
   outZoneLow = 0;
   outZoneHigh = 0;
   for(int i = mssBarIndex - 1; i >= sweepBarIndex; i--)
   {
      MqlRates c = ctx.trigger_tf_recent[i];
      bool isBearishCandle = c.close < c.open;
      bool isBullishCandle = c.close > c.open;
      if(bullish && isBearishCandle)
      {
         outZoneLow = c.low;
         outZoneHigh = c.high;
         return true;
      }
      if(!bullish && isBullishCandle)
      {
         outZoneLow = c.low;
         outZoneHigh = c.high;
         return true;
      }
   }
   return false;
}

//---------------------------------------------------------------------
// FVG_PRIORITY_THEN_OB_FALLBACK (contract section 7A's frozen policy
// name - deliberately not "FVG_OR_OB", see that section for why).
// Always resolves to exactly one zone kind or fails closed - never both.
//---------------------------------------------------------------------
bool CRT_ResolveZone(const MarketContext &ctx, int sweepBarIndex, int mssBarIndex, bool bullish, string &outKind, double &outZoneLow, double &outZoneHigh)
{
   if(CRT_FindFVG(ctx, sweepBarIndex, mssBarIndex, bullish, outZoneLow, outZoneHigh))
   {
      outKind = "FVG";
      return true;
   }
   if(CRT_FindOrderBlock(ctx, sweepBarIndex, mssBarIndex, bullish, outZoneLow, outZoneHigh))
   {
      outKind = "OB";
      return true;
   }
   outKind = "";
   outZoneLow = 0;
   outZoneHigh = 0;
   return false;
}

//---------------------------------------------------------------------
// Expiry (contract section 9): reuses the existing, sealed
// TradeCandidate_ComputeExpiryTime - no new expiry primitive, just a
// boolean "has this candidate expired as of currentClosedBarTime" wrapper,
// a pure function of its four inputs only, never TimeCurrent().
//---------------------------------------------------------------------
// Pure string->enum mapping (the inverse of FeatureEngine_TimeframeTag) -
// no broker call, so it stays legal inside a CRT_* pure-function chain.
// MQL5 has no generic StringToEnum() available in this build, so this is
// an explicit table covering every standard ENUM_TIMEFRAMES value -
// EnumToString(PERIOD_x) with the "PERIOD_" prefix stripped, the exact
// inverse of FeatureEngine_TimeframeTag().
ENUM_TIMEFRAMES CRT_TimeframeTagToPeriod(string tag)
{
   if(tag == "M1")  return PERIOD_M1;
   if(tag == "M2")  return PERIOD_M2;
   if(tag == "M3")  return PERIOD_M3;
   if(tag == "M4")  return PERIOD_M4;
   if(tag == "M5")  return PERIOD_M5;
   if(tag == "M6")  return PERIOD_M6;
   if(tag == "M10") return PERIOD_M10;
   if(tag == "M12") return PERIOD_M12;
   if(tag == "M15") return PERIOD_M15;
   if(tag == "M20") return PERIOD_M20;
   if(tag == "M30") return PERIOD_M30;
   if(tag == "H1")  return PERIOD_H1;
   if(tag == "H2")  return PERIOD_H2;
   if(tag == "H3")  return PERIOD_H3;
   if(tag == "H4")  return PERIOD_H4;
   if(tag == "H6")  return PERIOD_H6;
   if(tag == "H8")  return PERIOD_H8;
   if(tag == "H12") return PERIOD_H12;
   if(tag == "D1")  return PERIOD_D1;
   if(tag == "W1")  return PERIOD_W1;
   if(tag == "MN1") return PERIOD_MN1;
   return PERIOD_CURRENT;
}

bool CRT_EvaluateExpiry(datetime setupAnchorBarTime, int expiryAfterBars, ENUM_TIMEFRAMES triggerTimeframe, datetime currentClosedBarTime)
{
   datetime expiryTime = TradeCandidate_ComputeExpiryTime(setupAnchorBarTime, expiryAfterBars, triggerTimeframe);
   return currentClosedBarTime >= expiryTime;
}

//---------------------------------------------------------------------
// CRT_DetectV1: the orchestrator. Turns a single MarketContext into zero
// or one CRTDetectionResult. Tries bullish first, then bearish - since
// each direction's sweep/MSS/zone checks are independent pure scans,
// this ordering is itself deterministic and guarantees the section 2
// bit-0/bit-1 XOR invariant (at most one direction can ever win).
//---------------------------------------------------------------------
void CRT_DetectV1(const MarketContext &ctx, CRTDetectionResult &result)
{
   CRTDetectionResult_Init(result);

   int n = ArraySize(ctx.trigger_tf_recent);
   if(n < MLQUANTAI_CRT_V1_LOOKBACK_BARS)
      return; // short window - CRT-ineligible for this bar, per contract's window rules

   int mssBarIndex = CRT_MssBarIndex(ctx);

   for(int dirPass = 0; dirPass < 2; dirPass++)
   {
      bool bullish = (dirPass == 0);

      int sweepIdx = bullish ? CRT_FindSweepLowBarIndex(ctx) : CRT_FindSweepHighBarIndex(ctx);
      if(sweepIdx < 0) continue;

      if(!CRT_CloseBackInside(ctx, sweepIdx, bullish)) continue;

      double structureLevel;
      if(!CRT_ConfirmMSS(ctx, sweepIdx, mssBarIndex, bullish, structureLevel)) continue;

      string zoneKind;
      double zoneLow, zoneHigh;
      if(!CRT_ResolveZone(ctx, sweepIdx, mssBarIndex, bullish, zoneKind, zoneLow, zoneHigh)) continue;

      result.detected = true;
      result.side = bullish ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      result.swept_level = bullish ? ctx.pdl : ctx.pdh;
      result.mss_confirmation_price = ctx.trigger_tf_recent[mssBarIndex].close;
      result.mss_confirmation_bar_time = ctx.trigger_tf_recent[mssBarIndex].time;
      result.resolved_zone_kind = zoneKind;
      result.resolved_zone_high = zoneHigh;
      result.resolved_zone_low = zoneLow;

      ulong mask = 0;
      mask |= bullish ? CRT_REASON_BIT_SWEEP_LOW : CRT_REASON_BIT_SWEEP_HIGH;
      mask |= CRT_REASON_BIT_CLOSE_BACK_INSIDE;
      mask |= CRT_REASON_BIT_MSS_CONFIRMED;
      mask |= (zoneKind == "FVG") ? CRT_REASON_BIT_FVG_FOUND : CRT_REASON_BIT_OB_FOUND;
      if(ctx.is_kill_zone)
         mask |= CRT_REASON_BIT_KILLZONE;
      if(ctx.max_news_impact >= 3 && MathAbs(ctx.nearest_news_minutes) <= MLQUANTAI_CRT_V1_NEWS_RISK_WINDOW_MINUTES)
         mask |= CRT_REASON_BIT_NEWS_RISK;
      result.reason_mask = mask;
      CRT_ReasonLabelsFromMask(mask, result.reason_labels);

      result.detector_hash = CRT_DetectorHash(ctx.instrument_id, ctx.trigger_timeframe,
                                               result.mss_confirmation_bar_time, result.side,
                                               result.swept_level, result.mss_confirmation_price,
                                               result.mss_confirmation_bar_time, result.resolved_zone_kind,
                                               result.resolved_zone_high, result.resolved_zone_low,
                                               result.reason_mask, ctx.symbol_spec.digits);
      return;
   }
   // Neither direction produced a valid detection - result stays at
   // CRTDetectionResult_Init()'s defaults (detected == false).
}

#endif // __MLQUANTAI_CRT_V1_RULES_MQH__
