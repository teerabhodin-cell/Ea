//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_MarketContext.mqh                   |
//| Phase B B1.2: the FROZEN MarketContext contract - the shape every |
//| detector, the risk manager and (later) the AI filter will read   |
//| from once B2/B3 wire the Data Hub to build it. context_event_id  |
//| is what TradeCandidate.context_event_id references, so every     |
//| candidate can be traced back to the exact snapshot it came from. |
//|                                                                    |
//| HARD RULE - anchor_bar_time MUST come from                       |
//| iTime(broker_symbol, trigger_timeframe, 1): the last CLOSED bar,  |
//| never shift 0 and never TimeCurrent(). Every price/indicator      |
//| field in this struct must be computed from data closed at or     |
//| before anchor_bar_time. A context built off a still-forming bar  |
//| would read different values on every tick it's rebuilt, on a     |
//| live run vs. a tester run, and on a replay vs. the original run  |
//| - breaking the determinism the whole Event Store / replay design |
//| depends on. See Docs/PhaseB_B1_ContractFreeze.md.                 |
//|                                                                    |
//| NOTE - this is a SEPARATE struct from the Step 9                  |
//| Core/MLQuantAI_MarketContext.mqh (Phase A/Step 9's MarketContext, |
//| still used by the live Data Hub/Feature Engine/MLQuantAI.mq5).    |
//| B1 only freezes the new contract; migrating the Data Hub/Feature  |
//| Engine to build THIS struct instead is B2/B3's job, not B1's -    |
//| B1 is explicitly contract-only, no DataHub/FeatureEngine changes. |
//| Until that migration, two "MarketContext" structs exist in two    |
//| different files/namespaces by design; nothing includes both in    |
//| the same translation unit today.                                  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MARKET_MARKETCONTEXT_MQH__
#define __MLQUANTAI_MARKET_MARKETCONTEXT_MQH__

#include "../Core/MLQuantAI_ContractVersions.mqh"
#include "../Core/MLQuantAI_AccountSnapshot.mqh"
#include "MLQuantAI_NewsSnapshot.mqh"
#include "MLQuantAI_SymbolSpec.mqh"

struct MarketContext
{
   string   context_event_id;
   string   context_hash;               // hash of the fields below, EXCLUDING runtime-only metadata (see MarketContext_Hash)
   string   market_context_schema_version;
   string   feature_schema_version;
   string   news_schema_version;

   string   instrument_id;              // canonical, e.g. "XAUUSD" - never a broker-specific alias
   string   broker_symbol;              // actual broker symbol, e.g. "XAUUSDm", "GOLD" - may differ from instrument_id
   string   trigger_timeframe;          // e.g. "M5" - the timeframe anchor_bar_time is measured on
   datetime anchor_bar_time;            // iTime(broker_symbol, trigger_tf, 1) - last CLOSED bar. Never bar 0, never TimeCurrent().

   MqlRates m5_bar;
   MqlRates m15_bar;
   MqlRates h1_bar;
   MqlRates h4_bar;

   double   bid_at_anchor;
   double   ask_at_anchor;
   double   spread_points_at_anchor;

   double   atr_m15;
   double   adx_m15;
   double   ema_slope_m15;

   double   pdh;
   double   pdl;
   double   asian_range_high;
   double   asian_range_low;

   string   session_id;
   bool     is_kill_zone;

   NewsSnapshot news[];
   int      news_count;
   int      max_news_impact;
   int      nearest_news_minutes;

   AccountSnapshot account;
   SymbolSpec      symbol_spec;
};

void MarketContext_Init(MarketContext &c)
{
   c.context_event_id = "";
   c.context_hash = "";
   c.market_context_schema_version = MLQUANTAI_MARKET_CONTEXT_SCHEMA_V1;
   c.feature_schema_version = MLQUANTAI_FEATURE_SCHEMA_V1;
   c.news_schema_version = MLQUANTAI_NEWS_SCHEMA_V1;

   c.instrument_id = "";
   c.broker_symbol = "";
   c.trigger_timeframe = "";
   c.anchor_bar_time = 0;

   ZeroMemory(c.m5_bar);
   ZeroMemory(c.m15_bar);
   ZeroMemory(c.h1_bar);
   ZeroMemory(c.h4_bar);

   c.bid_at_anchor = 0;
   c.ask_at_anchor = 0;
   c.spread_points_at_anchor = 0;

   c.atr_m15 = 0;
   c.adx_m15 = 0;
   c.ema_slope_m15 = 0;

   c.pdh = 0;
   c.pdl = 0;
   c.asian_range_high = 0;
   c.asian_range_low = 0;

   c.session_id = "";
   c.is_kill_zone = false;

   ArrayResize(c.news, 0);
   c.news_count = 0;
   c.max_news_impact = 0;
   c.nearest_news_minutes = 0;

   AccountSnapshot_Init(c.account);
   SymbolSpec_Init(c.symbol_spec);
}

// Hash payload deliberately excludes context_event_id/context_hash
// themselves (they're derived FROM this payload, not part of it) and
// excludes account (runtime-only: balance/equity move between two builds
// of the "same" bar and must not change what the context's identity
// hashes to). Everything else - price/feature/news/symbol_spec fields -
// is what actually defines "this market snapshot".
string MarketContext_HashPayload(const MarketContext &c)
{
   string s = c.instrument_id + "|" + c.broker_symbol + "|" + c.trigger_timeframe + "|" +
              TimeToString(c.anchor_bar_time, TIME_DATE|TIME_SECONDS) + "|" +
              DoubleToString(c.bid_at_anchor, 5) + "|" + DoubleToString(c.ask_at_anchor, 5) + "|" +
              DoubleToString(c.atr_m15, 5) + "|" + DoubleToString(c.adx_m15, 5) + "|" + DoubleToString(c.ema_slope_m15, 5) + "|" +
              DoubleToString(c.pdh, 5) + "|" + DoubleToString(c.pdl, 5) + "|" +
              DoubleToString(c.asian_range_high, 5) + "|" + DoubleToString(c.asian_range_low, 5) + "|" +
              c.session_id + "|" + (c.is_kill_zone ? "1" : "0") + "|" +
              IntegerToString(c.news_count) + "|" + IntegerToString(c.max_news_impact) + "|" + IntegerToString(c.nearest_news_minutes);
   return s;
}

#endif // __MLQUANTAI_MARKET_MARKETCONTEXT_MQH__
