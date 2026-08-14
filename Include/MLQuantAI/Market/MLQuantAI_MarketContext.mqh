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
//| Phase B B3 migrated the Data Hub/Feature Engine to build THIS      |
//| struct (see Market/MLQuantAI_FeatureEngine.mqh's                   |
//| FeatureEngine_BuildContext()); the old Step 9 struct this coexisted|
//| with (Core/MLQuantAI_MarketContext.mqh) was deleted in the same    |
//| pass once nothing referenced it anymore.                           |
//|                                                                    |
//| Phase B B4 added news_decision_hash/news_snapshot_identity          |
//| additively (see Market/MLQuantAI_NewsCanonicalizer.mqh) AND changed |
//| what MarketContext_HashPayload's news contribution actually is:     |
//| it now folds in news_decision_hash (decision-relevant news content  |
//| only) instead of iterating news[] through NewsSnapshot_HashFragment |
//| (which includes source_kind - provenance). This is a deliberate     |
//| context_hash ALGORITHM change, not a struct/schema change - no real |
//| candidate dataset depends on a specific historical context_hash     |
//| value yet (B5 hasn't started), which is specifically why this is    |
//| the appropriate time to make it, before context_hash is ever relied |
//| on for real replay auditing. See Docs/PhaseB_B4_NewsParity.md.      |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MARKET_MARKETCONTEXT_MQH__
#define __MLQUANTAI_MARKET_MARKETCONTEXT_MQH__

#include "../Core/MLQuantAI_ContractVersions.mqh"
#include "../Core/MLQuantAI_AccountSnapshot.mqh"
#include "../Core/MLQuantAI_Ids.mqh"
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
   string   news_decision_hash;     // Phase B B4: decision-relevant news content only - see MarketContext_HashPayload
   string   news_snapshot_identity; // Phase B B4: full news lineage/provenance hash - audit trail, excluded from context_hash

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
   c.news_decision_hash = "";
   c.news_snapshot_identity = "";

   AccountSnapshot_Init(c.account);
   SymbolSpec_Init(c.symbol_spec);
}

// One closed bar's IDENTITY fields, normalized for hashing: time, OHLC,
// tick_volume, and the HISTORICAL spread MT5 recorded for that bar.
// real_volume is deliberately excluded - most brokers never populate it
// (stays 0), so including it would add noise, not signal.
string MarketContext_RatesHashFragment(const MqlRates &r)
{
   return TimeToString(r.time, TIME_DATE|TIME_SECONDS) + "|" +
          DoubleToString(r.open, 5) + "|" + DoubleToString(r.high, 5) + "|" +
          DoubleToString(r.low, 5) + "|" + DoubleToString(r.close, 5) + "|" +
          IntegerToString((long)r.tick_volume) + "|" + IntegerToString(r.spread);
}

// Hash payload deliberately excludes context_event_id/context_hash
// themselves (they're derived FROM this payload, not part of it) and
// excludes account (runtime-only: balance/equity move between two builds
// of the "same" bar and must not change what the context's identity
// hashes to). Everything else - closed-bar OHLC across all 4 timeframes,
// price/feature/session fields, and news_decision_hash - is what
// actually defines "this market snapshot".
//
// Phase B B4: the news contribution is news_decision_hash (decision-
// relevant news content only - currency/impact/release_time/
// minutes_to_event per selected event, canonically ordered - see
// Market/MLQuantAI_NewsCanonicalizer.mqh's News_DecisionHash()), NOT a
// per-element loop over news[] via NewsSnapshot_HashFragment(). That
// older per-element approach (kept in NewsSnapshot.mqh, still used
// elsewhere) included source_kind - metadata that MUST NOT move
// context_hash on its own, per B4's "metadata-only changes don't change
// context_hash" seal criterion. news_count/max_news_impact/
// nearest_news_minutes are themselves derived from the same selected
// set news_decision_hash covers, so including news_decision_hash alone
// is sufficient - they aren't hashed separately to avoid redundancy.
string MarketContext_HashPayload(const MarketContext &c)
{
   string s = c.instrument_id + "|" + c.broker_symbol + "|" + c.trigger_timeframe + "|" +
              TimeToString(c.anchor_bar_time, TIME_DATE|TIME_SECONDS) + "|" +
              MarketContext_RatesHashFragment(c.m5_bar)  + "|" +
              MarketContext_RatesHashFragment(c.m15_bar) + "|" +
              MarketContext_RatesHashFragment(c.h1_bar)  + "|" +
              MarketContext_RatesHashFragment(c.h4_bar)  + "|" +
              DoubleToString(c.bid_at_anchor, 5) + "|" + DoubleToString(c.ask_at_anchor, 5) + "|" +
              DoubleToString(c.spread_points_at_anchor, 1) + "|" +
              DoubleToString(c.atr_m15, 5) + "|" + DoubleToString(c.adx_m15, 5) + "|" + DoubleToString(c.ema_slope_m15, 5) + "|" +
              DoubleToString(c.pdh, 5) + "|" + DoubleToString(c.pdl, 5) + "|" +
              DoubleToString(c.asian_range_high, 5) + "|" + DoubleToString(c.asian_range_low, 5) + "|" +
              c.session_id + "|" + (c.is_kill_zone ? "1" : "0") + "|" +
              "news_decision:" + c.news_decision_hash;

   return s;
}

// Truncated SHA-256 over MarketContext_HashPayload() - same hashing
// primitive Core/MLQuantAI_Ids.mqh uses for deterministic IDs. Callers
// (FeatureEngine_BuildContext) should set c.context_hash to this AFTER
// every other field is filled in, so the hash reflects the finished
// context. Phase B B3's determinism test rebuilds the same anchor bar
// repeatedly and asserts this never changes.
string MarketContext_ComputeHash(const MarketContext &c)
{
   return Ids_Sha256Hex(MarketContext_HashPayload(c));
}

// Serializes the full context (including the embedded NewsSnapshot[])
// as a JSON fragment (no surrounding braces) for MARKET_CONTEXT_READY's
// extra_json - so replay can see exactly what the Feature Engine built
// for a given anchor bar without ever re-querying MT5 or the calendar.
// Carries the SAME fields MarketContext_RatesHashFragment() hashes
// (time/OHLC/tick_volume/spread) - real_volume is excluded from both
// (most brokers never populate it).
string MarketContext_RatesToJson(const MqlRates &r)
{
   return "{\"time\":\"" + TimeToString(r.time, TIME_DATE|TIME_SECONDS) + "\"," +
          "\"open\":" + DoubleToString(r.open, 5) + "," +
          "\"high\":" + DoubleToString(r.high, 5) + "," +
          "\"low\":"  + DoubleToString(r.low, 5) + "," +
          "\"close\":" + DoubleToString(r.close, 5) + "," +
          "\"tick_volume\":" + IntegerToString(r.tick_volume) + "," +
          "\"spread\":" + IntegerToString(r.spread) + "}";
}

string MarketContext_ToJsonFragment(const MarketContext &c)
{
   string s = "";
   s += "\"context_event_id\":\""              + c.context_event_id + "\",";
   s += "\"context_hash\":\""                   + c.context_hash + "\",";
   s += "\"market_context_schema_version\":\""  + c.market_context_schema_version + "\",";
   s += "\"feature_schema_version\":\""         + c.feature_schema_version + "\",";
   s += "\"news_schema_version\":\""            + c.news_schema_version + "\",";
   s += "\"instrument_id\":\""                  + c.instrument_id + "\",";
   s += "\"broker_symbol\":\""                  + c.broker_symbol + "\",";
   s += "\"trigger_timeframe\":\""               + c.trigger_timeframe + "\",";
   s += "\"anchor_bar_time\":\""                  + TimeToString(c.anchor_bar_time, TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"m5_bar\":"   + MarketContext_RatesToJson(c.m5_bar) + ",";
   s += "\"m15_bar\":"  + MarketContext_RatesToJson(c.m15_bar) + ",";
   s += "\"h1_bar\":"   + MarketContext_RatesToJson(c.h1_bar) + ",";
   s += "\"h4_bar\":"   + MarketContext_RatesToJson(c.h4_bar) + ",";
   s += "\"bid_at_anchor\":"           + DoubleToString(c.bid_at_anchor, 5) + ",";
   s += "\"ask_at_anchor\":"           + DoubleToString(c.ask_at_anchor, 5) + ",";
   s += "\"spread_points_at_anchor\":" + DoubleToString(c.spread_points_at_anchor, 1) + ",";
   s += "\"atr_m15\":"       + DoubleToString(c.atr_m15, 5) + ",";
   s += "\"adx_m15\":"       + DoubleToString(c.adx_m15, 5) + ",";
   s += "\"ema_slope_m15\":" + DoubleToString(c.ema_slope_m15, 5) + ",";
   s += "\"pdh\":" + DoubleToString(c.pdh, 5) + ",";
   s += "\"pdl\":" + DoubleToString(c.pdl, 5) + ",";
   s += "\"asian_range_high\":" + DoubleToString(c.asian_range_high, 5) + ",";
   s += "\"asian_range_low\":"  + DoubleToString(c.asian_range_low, 5) + ",";
   s += "\"session_id\":\"" + c.session_id + "\",";
   s += "\"is_kill_zone\":" + (c.is_kill_zone ? "true" : "false") + ",";
   s += "\"news\":" + NewsSnapshot_ArrayToJson(c.news) + ",";
   s += "\"news_count\":" + IntegerToString(c.news_count) + ",";
   s += "\"max_news_impact\":" + IntegerToString(c.max_news_impact) + ",";
   s += "\"nearest_news_minutes\":" + IntegerToString(c.nearest_news_minutes) + ",";
   s += "\"news_decision_hash\":\"" + c.news_decision_hash + "\",";
   s += "\"news_snapshot_identity\":\"" + c.news_snapshot_identity + "\",";
   // account is excluded from context_hash (runtime-only, see
   // MarketContext_HashPayload) but is still worth logging here for
   // audit - it's just not part of the context's identity.
   s += "\"account_balance\":" + DoubleToString(c.account.balance, 2) + ",";
   s += "\"account_equity\":"  + DoubleToString(c.account.equity, 2) + ",";
   s += "\"symbol_spec_schema_version\":\"" + c.symbol_spec.symbol_spec_schema_version + "\",";
   s += "\"symbol_spec_digits\":" + IntegerToString(c.symbol_spec.digits) + ",";
   s += "\"symbol_spec_tick_size\":" + DoubleToString(c.symbol_spec.tick_size, 5) + ",";
   s += "\"symbol_spec_tick_value\":" + DoubleToString(c.symbol_spec.tick_value, 5);
   return s;
}

#endif // __MLQUANTAI_MARKET_MARKETCONTEXT_MQH__
