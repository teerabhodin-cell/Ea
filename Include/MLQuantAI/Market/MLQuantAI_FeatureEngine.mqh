//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_FeatureEngine.mqh                   |
//| Phase B B3: builds the FROZEN Market/MLQuantAI_MarketContext.mqh  |
//| contract from real MT5 data, closed-bar only. Replaces Step 9's   |
//| FeatureEngine_Build(), which built the old Core/MarketContext.mqh |
//| struct off bar 0 / live tick values - non-deterministic and       |
//| explicitly forbidden by the B1 contract's own rules.              |
//|                                                                    |
//| HARD RULE, enforced throughout this file: anchor_bar_time =       |
//| iTime(broker_symbol, InpTriggerTimeframe, 1) - the last CLOSED    |
//| bar. Every other field is derived from that same closed bar or    |
//| earlier - never shift 0, never TimeCurrent(), never a live tick.  |
//| See Docs/PhaseB_B3_DataHubDeterminism.md.                          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_FEATUREENGINE_MQH__
#define __MLQUANTAI_FEATUREENGINE_MQH__

#include "MLQuantAI_DataHub.mqh"
#include "MLQuantAI_SessionEngine.mqh"
#include "MLQuantAI_NewsEngine.mqh"
#include "MLQuantAI_SymbolResolver.mqh"
#include "MLQuantAI_MarketContext.mqh"
#include "../Core/MLQuantAI_Ids.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"

input group "=== Feature Engine (Phase B B3) ==="
input ENUM_TIMEFRAMES InpTriggerTimeframe = PERIOD_M5; // the ONE timeframe anchor_bar_time is measured on

string g_FeatureEngine_InstrumentId = "";
string g_FeatureEngine_BrokerSymbol = "";
SymbolSpec g_FeatureEngine_SymbolSpec;

// "M5" from PERIOD_M5, generically for whatever InpTriggerTimeframe is
// set to - EnumToString gives "PERIOD_M5"; this just strips the prefix
// so MarketContext.trigger_timeframe reads the same short tag the rest
// of the project already uses elsewhere (e.g. Ids_ContextEventId's
// timeframeTag parameter).
string FeatureEngine_TimeframeTag(ENUM_TIMEFRAMES tf)
{
   string s = EnumToString(tf);
   if(StringFind(s, "PERIOD_") == 0)
      return StringSubstr(s, 7);
   return s;
}

// Resolves instrument_id/broker_symbol (fails closed - see
// MLQuantAI_SymbolResolver.mqh) and initializes the Data Hub's indicator
// handles against the RESOLVED broker symbol, not necessarily the
// chart's raw _Symbol.
bool FeatureEngine_Init(string chartSymbol)
{
   string err;
   if(!SymbolSpec_BuildResolved(chartSymbol, g_FeatureEngine_SymbolSpec, err))
   {
      LogError("FeatureEngine_Init: symbol resolution failed - " + err);
      return false;
   }
   g_FeatureEngine_InstrumentId = g_FeatureEngine_SymbolSpec.instrument_id;
   g_FeatureEngine_BrokerSymbol = g_FeatureEngine_SymbolSpec.broker_symbol;

   return DataHub_Init(g_FeatureEngine_BrokerSymbol);
}

void FeatureEngine_Deinit()
{
   DataHub_Deinit();
   NewsEngine_DeinitCsvSource();
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
   // (that's B7); this snapshot only reports what MT5 itself knows.
}

// The anchor_bar_time THIS session's FeatureEngine_BuildContext() would
// use right now - exposed so MLQuantAI.mq5's OnTick can detect "is this
// a new closed trigger bar yet" using the EXACT same value the builder
// itself computes, instead of duplicating the iTime(...,1) call and
// risking the two drifting apart.
datetime FeatureEngine_CurrentAnchorBarTime()
{
   if(g_FeatureEngine_BrokerSymbol == "") return 0;
   return iTime(g_FeatureEngine_BrokerSymbol, InpTriggerTimeframe, 1);
}

// Builds one immutable MarketContext for the current closed trigger bar.
// Returns a context with anchor_bar_time == 0 if there isn't enough
// history yet (e.g. right after EA start) or FeatureEngine_Init() never
// succeeded - callers MUST check FeatureEngine_IsReady() before trusting
// anything else in it.
//
// Every field here is a pure function of (broker_symbol, anchor bar) -
// CopyRates/indicator buffers/calendar lookups all read HISTORICAL data
// closed at or before anchor_bar_time. Calling this function repeatedly
// without the underlying bar changing (e.g. Tests/MLQuantAI_Test_
// DataHubDeterminism.mq5's 1000-iteration loop) must produce a
// byte-identical context_hash every time - if it doesn't, something in
// here regressed back to reading live/"now" state.
MarketContext FeatureEngine_BuildContext()
{
   MarketContext ctx;
   MarketContext_Init(ctx);

   string brokerSymbol = g_FeatureEngine_BrokerSymbol;
   if(brokerSymbol == "") return ctx; // FeatureEngine_Init never succeeded

   datetime anchor = iTime(brokerSymbol, InpTriggerTimeframe, 1); // last CLOSED bar - the only legal anchor source
   if(anchor == 0) return ctx; // not enough history yet

   ctx.instrument_id    = g_FeatureEngine_InstrumentId;
   ctx.broker_symbol     = brokerSymbol;
   ctx.trigger_timeframe  = FeatureEngine_TimeframeTag(InpTriggerTimeframe);
   ctx.anchor_bar_time     = anchor;

   MqlRates rates[];
   if(CopyRates(brokerSymbol, PERIOD_M5,  1, 1, rates) == 1) ctx.m5_bar  = rates[0];
   if(CopyRates(brokerSymbol, PERIOD_M15, 1, 1, rates) == 1) ctx.m15_bar = rates[0];
   if(CopyRates(brokerSymbol, PERIOD_H1,  1, 1, rates) == 1) ctx.h1_bar  = rates[0];
   if(CopyRates(brokerSymbol, PERIOD_H4,  1, 1, rates) == 1) ctx.h4_bar  = rates[0];

   // bid/ask/spread "at anchor" come from the trigger bar's own recorded
   // close + spread (MqlRates.spread IS the historical spread MT5 stored
   // for that bar) - never SymbolInfoTick()/SymbolInfoDouble(..., BID),
   // which reflect right now and would make this non-deterministic.
   MqlRates triggerBar[];
   if(CopyRates(brokerSymbol, InpTriggerTimeframe, 1, 1, triggerBar) == 1)
   {
      double point = (g_FeatureEngine_SymbolSpec.point > 0) ? g_FeatureEngine_SymbolSpec.point : SymbolInfoDouble(brokerSymbol, SYMBOL_POINT);
      ctx.bid_at_anchor           = triggerBar[0].close;
      ctx.spread_points_at_anchor = (double)triggerBar[0].spread;
      ctx.ask_at_anchor           = ctx.bid_at_anchor + triggerBar[0].spread * point;
   }

   ctx.atr_m15 = DataHub_IndicatorValue(g_hATR_M15);
   ctx.adx_m15 = DataHub_IndicatorValue(g_hADX_M15);
   double emaAtAnchor   = DataHub_IndicatorValue(g_hEMA20_M15, 0, 1);
   double emaOneBarBack = DataHub_IndicatorValue(g_hEMA20_M15, 0, 2);
   ctx.ema_slope_m15 = emaAtAnchor - emaOneBarBack; // one-bar EMA20 M15 slope, price units; positive = rising

   ctx.pdh = DataHub_PrevDayHigh(brokerSymbol);
   ctx.pdl = DataHub_PrevDayLow(brokerSymbol);

   double asianHigh = 0, asianLow = 0;
   if(DataHub_AsianRangeAt(brokerSymbol, AsiaEndHour, anchor, asianHigh, asianLow))
   {
      ctx.asian_range_high = asianHigh;
      ctx.asian_range_low  = asianLow;
   }

   ctx.session_id   = Session_Id(anchor);
   ctx.is_kill_zone = Session_IsLondonKZ(anchor) || Session_IsNewYorkKZ(anchor);

   if(UseNewsFilter)
   {
      // Phase B B4: NewsEngine_Build() runs the full Raw -> Normalize ->
      // Dedup -> Sort/Select pipeline (Market/MLQuantAI_NewsCanonicalizer.mqh)
      // and already returns ctx.news[] in final canonical order, plus the
      // decision/identity hashes - nothing here recomputes normalization
      // or aggregates by hand anymore.
      NewsEngineResult newsResult = NewsEngine_Build(anchor);
      if(newsResult.ok)
      {
         int n = ArraySize(newsResult.snapshots);
         ArrayResize(ctx.news, n);
         for(int i = 0; i < n; i++)
            ctx.news[i] = newsResult.snapshots[i];
         ctx.news_count              = newsResult.news_count;
         ctx.max_news_impact         = newsResult.max_news_impact;
         ctx.nearest_news_minutes    = newsResult.nearest_news_minutes;
         ctx.news_decision_hash      = newsResult.news_decision_hash;
         ctx.news_snapshot_identity  = newsResult.news_snapshot_identity;
      }
      else
      {
         // News source failure is NOT silently treated as "no news" -
         // this context is still built (so the bar isn't lost from the
         // dataset entirely), but stays at MarketContext_Init's news
         // defaults, and the failure is already logged by
         // NewsEngine_Build() itself via LogError.
         LogWarn(StringFormat("FeatureEngine_BuildContext: news unavailable for anchor %s - %s",
                 TimeToString(anchor, TIME_DATE|TIME_SECONDS), newsResult.error));
      }
   }

   FeatureEngine_BuildAccountSnapshot(ctx.account); // runtime-only, excluded from context_hash by design
   ctx.symbol_spec = g_FeatureEngine_SymbolSpec;

   ctx.context_event_id = Ids_ContextEventId(ctx.instrument_id, ctx.trigger_timeframe, ctx.anchor_bar_time);
   ctx.context_hash      = MarketContext_ComputeHash(ctx);

   return ctx;
}

bool FeatureEngine_IsReady(const MarketContext &ctx)
{
   return ctx.anchor_bar_time != 0;
}

// Logs MARKET_CONTEXT_READY with the FULL context (including the
// embedded NewsSnapshot[]) as extra_json, so replay can reconstruct
// exactly what the Feature Engine saw for this anchor bar without ever
// re-querying MT5 price history or the Economic Calendar again.
void FeatureEngine_LogContextReady(const MarketContext &ctx)
{
   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx));
}

#endif // __MLQUANTAI_FEATUREENGINE_MQH__
