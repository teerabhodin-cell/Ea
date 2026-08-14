//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_DataHub.mqh                         |
//| Owns every indicator handle the Feature Engine reads from, and    |
//| the raw price/OHLC access underneath them. Handles are created    |
//| once in DataHub_Init (called from OnInit) and reused - creating   |
//| an indicator handle inside OnTick/OnNewBar leaks a handle per     |
//| call in MQL5.                                                     |
//|                                                                    |
//| Phase B B3: the frozen Market/MLQuantAI_MarketContext.mqh contract|
//| only needs M15 ATR/ADX and one EMA (for a slope) - g_hADX_M15 was |
//| added for that. The H1/ADX_H1/EMA50_H1/EMA200_H4 handles from     |
//| Step 9 are no longer read by FeatureEngine_BuildContext(), but    |
//| are left in place as reusable indicator plumbing for B5's         |
//| strategy detectors (CRT/SMC/Trend), which will likely want H1/H4  |
//| trend context beyond the raw OHLC bars MarketContext carries.     |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_DATAHUB_MQH__
#define __MLQUANTAI_DATAHUB_MQH__

#include "MLQuantAI_SessionEngine.mqh"

input group "=== Data Hub ==="
input int ATR_Period        = 14;
input int ADX_Period        = 14;
input int EMA20_M15_Period  = 20;
input int EMA50_H1_Period   = 50;
input int EMA200_H4_Period  = 200;
input int SwingLookbackBars = 20;

int g_hATR_M15    = INVALID_HANDLE;
int g_hATR_H1     = INVALID_HANDLE;
int g_hADX_M15    = INVALID_HANDLE;
int g_hADX_H1     = INVALID_HANDLE;
int g_hEMA20_M15  = INVALID_HANDLE;
int g_hEMA50_H1   = INVALID_HANDLE;
int g_hEMA200_H4  = INVALID_HANDLE;

bool DataHub_Init(string symbol)
{
   g_hATR_M15   = iATR(symbol, PERIOD_M15, ATR_Period);
   g_hATR_H1    = iATR(symbol, PERIOD_H1, ATR_Period);
   g_hADX_M15   = iADX(symbol, PERIOD_M15, ADX_Period);
   g_hADX_H1    = iADX(symbol, PERIOD_H1, ADX_Period);
   g_hEMA20_M15 = iMA(symbol, PERIOD_M15, EMA20_M15_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMA50_H1  = iMA(symbol, PERIOD_H1, EMA50_H1_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMA200_H4 = iMA(symbol, PERIOD_H4, EMA200_H4_Period, 0, MODE_EMA, PRICE_CLOSE);

   return g_hATR_M15   != INVALID_HANDLE
       && g_hATR_H1    != INVALID_HANDLE
       && g_hADX_M15   != INVALID_HANDLE
       && g_hADX_H1    != INVALID_HANDLE
       && g_hEMA20_M15 != INVALID_HANDLE
       && g_hEMA50_H1  != INVALID_HANDLE
       && g_hEMA200_H4 != INVALID_HANDLE;
}

void DataHub_Deinit()
{
   if(g_hATR_M15   != INVALID_HANDLE) IndicatorRelease(g_hATR_M15);
   if(g_hATR_H1    != INVALID_HANDLE) IndicatorRelease(g_hATR_H1);
   if(g_hADX_M15   != INVALID_HANDLE) IndicatorRelease(g_hADX_M15);
   if(g_hADX_H1    != INVALID_HANDLE) IndicatorRelease(g_hADX_H1);
   if(g_hEMA20_M15 != INVALID_HANDLE) IndicatorRelease(g_hEMA20_M15);
   if(g_hEMA50_H1  != INVALID_HANDLE) IndicatorRelease(g_hEMA50_H1);
   if(g_hEMA200_H4 != INVALID_HANDLE) IndicatorRelease(g_hEMA200_H4);
}

// shift=1 by default (last CLOSED bar), so a feature is stable for the
// whole bar it's computed on rather than shifting mid-bar on shift=0.
double DataHub_IndicatorValue(int handle, int buffer = 0, int shift = 1)
{
   double buf[];
   if(CopyBuffer(handle, buffer, shift, 1, buf) < 1) return 0;
   return buf[0];
}

double DataHub_SwingHigh(string symbol, ENUM_TIMEFRAMES tf, int lookback, int shift = 1)
{
   int idx = iHighest(symbol, tf, MODE_HIGH, lookback, shift);
   return (idx < 0) ? 0 : iHigh(symbol, tf, idx);
}

double DataHub_SwingLow(string symbol, ENUM_TIMEFRAMES tf, int lookback, int shift = 1)
{
   int idx = iLowest(symbol, tf, MODE_LOW, lookback, shift);
   return (idx < 0) ? 0 : iLow(symbol, tf, idx);
}

double DataHub_PrevDayHigh(string symbol) { return iHigh(symbol, PERIOD_D1, 1); }
double DataHub_PrevDayLow(string symbol)  { return iLow(symbol, PERIOD_D1, 1); }

// Scans M15 bars from asOf's broker-server-time day-start up to
// AsiaEndHour (or asOf itself, if the Asian session hasn't finished yet
// as of asOf) for the session's high/low. Deliberately takes asOf as a
// parameter rather than reading TimeCurrent() internally - the Phase B
// B3 rule is anchor_bar_time (a closed bar), never "now", so this
// function returns byte-identical output on every call for the same
// asOf, whether called live, in the Tester, or 1000 times back-to-back
// in the determinism test. Returns false if there isn't enough M15
// history yet to resolve the range (e.g. right after EA start) - callers
// should leave asian_high/low at 0 in that case, not treat 0 as a real
// price.
bool DataHub_AsianRangeAt(string symbol, int asiaEndHour, datetime asOf, double &outHigh, double &outLow)
{
   datetime dayStart   = Session_DayStart(asOf);
   datetime asiaEndT   = dayStart + asiaEndHour * 3600;
   datetime scanEnd     = (asiaEndT < asOf) ? asiaEndT : asOf;

   int startIdx = iBarShift(symbol, PERIOD_M15, dayStart, false); // older time -> higher index
   int endIdx   = iBarShift(symbol, PERIOD_M15, scanEnd, false);  // newer time -> lower index
   if(startIdx < 0 || endIdx < 0 || endIdx > startIdx)
      return false;

   double hi = -1, lo = -1;
   for(int i = endIdx; i <= startIdx; i++)
   {
      double h = iHigh(symbol, PERIOD_M15, i);
      double l = iLow(symbol, PERIOD_M15, i);
      if(hi < 0 || h > hi) hi = h;
      if(lo < 0 || l < lo) lo = l;
   }
   if(hi < 0 || lo < 0) return false;

   outHigh = hi;
   outLow  = lo;
   return true;
}

#endif // __MLQUANTAI_DATAHUB_MQH__
