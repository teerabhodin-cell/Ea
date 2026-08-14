//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_FeatureEngine.mqh                   |
//| Assembles DataHub + SessionEngine + NewsEngine + SymbolSpec +     |
//| account state into one immutable MarketContext per new bar. Every |
//| strategy module (Phase B Step 10+), the Regime Detector and the   |
//| AI filter all read the SAME MarketContext for a given bar - build |
//| it once here, pass it around by const reference, never let a      |
//| downstream module recompute its own version of the same numbers.  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_FEATUREENGINE_MQH__
#define __MLQUANTAI_FEATUREENGINE_MQH__

#include "MLQuantAI_DataHub.mqh"
#include "MLQuantAI_SessionEngine.mqh"
#include "MLQuantAI_NewsEngine.mqh"
#include "MLQuantAI_SymbolSpec.mqh"
#include "../Core/MLQuantAI_MarketContext.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"

SymbolSpec g_FeatureEngine_SymbolSpec;

bool FeatureEngine_Init(string symbol)
{
   SymbolSpec_Build(symbol, g_FeatureEngine_SymbolSpec); // best-effort; DataHub_Init's return value is the hard gate
   return DataHub_Init(symbol);
}

void FeatureEngine_Deinit()
{
   DataHub_Deinit();
}

void FeatureEngine_BuildAccountSnapshot(AccountSnapshot &a)
{
   AccountSnapshot_Init(a);
   a.balance              = AccountInfoDouble(ACCOUNT_BALANCE);
   a.equity                = AccountInfoDouble(ACCOUNT_EQUITY);
   a.margin_level          = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   a.open_positions_count = PositionsTotal();
   // open_risk_percent / daily_pnl_percent / drawdown_from_peak_percent
   // stay at 0 - there is no Global Risk Manager tracking these yet
   // (that's Step 11); this snapshot only reports what MT5 itself knows.
}

// Builds one MarketContext snapshot for "right now". Returns a context
// with bid/ask still 0 if there's no current tick available yet (e.g.
// symbol not subscribed) - callers MUST check FeatureEngine_IsReady()
// before trusting anything else in it, same convention as
// ExternalContext's has_* flags: zero fields mean "not ready", not
// "the value really is zero".
MarketContext FeatureEngine_Build(string symbol)
{
   MarketContext ctx;
   MarketContext_Init(ctx);

   MqlTick tick;
   if(!SymbolInfoTick(symbol, tick))
      return ctx;

   ctx.symbol        = symbol;
   ctx.bar_time      = iTime(symbol, PERIOD_M15, 0);
   ctx.bid           = tick.bid;
   ctx.ask           = tick.ask;
   ctx.spread_points = (_Point > 0) ? (tick.ask - tick.bid) / _Point : 0;

   ctx.atr_m15 = DataHub_IndicatorValue(g_hATR_M15);
   ctx.atr_h1  = DataHub_IndicatorValue(g_hATR_H1);
   ctx.adx_h1  = DataHub_IndicatorValue(g_hADX_H1);

   ctx.ema20_m15 = DataHub_IndicatorValue(g_hEMA20_M15);
   ctx.ema50_h1  = DataHub_IndicatorValue(g_hEMA50_H1);
   ctx.ema200_h4 = DataHub_IndicatorValue(g_hEMA200_H4);

   ctx.swing_high_m15 = DataHub_SwingHigh(symbol, PERIOD_M15, SwingLookbackBars);
   ctx.swing_low_m15  = DataHub_SwingLow(symbol, PERIOD_M15, SwingLookbackBars);
   ctx.prev_day_high  = DataHub_PrevDayHigh(symbol);
   ctx.prev_day_low   = DataHub_PrevDayLow(symbol);

   double asianHigh = 0, asianLow = 0;
   if(DataHub_AsianRange(symbol, AsiaEndHour, asianHigh, asianLow))
   {
      ctx.asian_high = asianHigh;
      ctx.asian_low  = asianLow;
   }

   ctx.in_london_killzone   = Session_IsLondonKZ(TimeCurrent());
   ctx.in_newyork_killzone  = Session_IsNewYorkKZ(TimeCurrent());
   ctx.high_impact_news_near = UseNewsFilter ? News_HighImpactNear(NewsCurrency, NewsMinutesBefore, NewsMinutesAfter) : false;

   // No Regime Detector yet (that's Step 14) - every context is
   // REGIME_TRANSITION until it exists. Real strategy modules (Step 10+)
   // must not treat this as a meaningful signal.
   ctx.regime = REGIME_TRANSITION;

   FeatureEngine_BuildAccountSnapshot(ctx.account);
   // ctx.external stays at ExternalContext_Init's defaults - no
   // Alternative Data Hub until Phase D.

   return ctx;
}

bool FeatureEngine_IsReady(const MarketContext &ctx)
{
   return ctx.bid > 0 && ctx.ask > 0;
}

// Logs MARKET_CONTEXT_READY with the key numbers as extra_json, so the
// event log itself is enough to audit what the Feature Engine saw for a
// given bar without needing to reproduce the computation later.
void FeatureEngine_LogContextReady(const MarketContext &ctx)
{
   string extra = StringFormat(
      "\"bar_time\":\"%s\",\"bid\":%s,\"ask\":%s,\"spread_points\":%s,"
      "\"atr_m15\":%s,\"atr_h1\":%s,\"adx_h1\":%s,\"regime\":\"%s\","
      "\"in_london_kz\":%s,\"in_newyork_kz\":%s,\"news_near\":%s",
      TimeToString(ctx.bar_time, TIME_DATE|TIME_MINUTES),
      DoubleToString(ctx.bid, (int)SymbolInfoInteger(ctx.symbol, SYMBOL_DIGITS)),
      DoubleToString(ctx.ask, (int)SymbolInfoInteger(ctx.symbol, SYMBOL_DIGITS)),
      DoubleToString(ctx.spread_points, 1),
      DoubleToString(ctx.atr_m15, 5), DoubleToString(ctx.atr_h1, 5), DoubleToString(ctx.adx_h1, 2),
      RegimeToString(ctx.regime),
      ctx.in_london_killzone ? "true" : "false",
      ctx.in_newyork_killzone ? "true" : "false",
      ctx.high_impact_news_near ? "true" : "false");

   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", extra);
}

#endif // __MLQUANTAI_FEATUREENGINE_MQH__
