//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_SymbolSpec.mqh                      |
//| Broker's contract terms for one symbol, captured once and reused |
//| - digits/point/contract size/volume limits/stop level all come   |
//| from SymbolInfo* calls that never change mid-session, so there's |
//| no reason to re-query them on every bar the way price is.        |
//|                                                                    |
//| Phase B B2 extended this struct ADDITIVELY, same discipline as    |
//| B1's TradeCandidate extension: every Phase A/Step 9 field (down   |
//| to currency_profit) is unchanged, because FeatureEngine_Init()    |
//| already calls SymbolSpec_Build(symbol, ...) directly and must     |
//| keep compiling untouched until B3 migrates it. The new fields     |
//| (instrument_id/broker_symbol/tick_size/tick_value/trade_mode/     |
//| currency_margin) are filled by the new SymbolSpec_BuildResolved() |
//| in MLQuantAI_SymbolResolver.mqh, not by the old SymbolSpec_Build. |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_SYMBOLSPEC_MQH__
#define __MLQUANTAI_SYMBOLSPEC_MQH__

#include "../Core/MLQuantAI_VersionRegistry.mqh"
#include "../Core/MLQuantAI_ContractVersions.mqh"

struct SymbolSpec
{
   string   context_schema_version; // MLQUANTAI_CONTEXT_SCHEMA_VERSION
   string   symbol;
   int      digits;
   double   point;
   double   contract_size;
   double   volume_min;
   double   volume_max;
   double   volume_step;
   int      stops_level_points;
   int      freeze_level_points;
   string   currency_base;
   string   currency_profit;

   // --- Phase B B2: additive resolved-symbol contract ---
   string   symbol_spec_schema_version; // MLQUANTAI_SYMBOL_SPEC_SCHEMA_V1
   string   instrument_id;              // canonical, e.g. "XAUUSD" - stable across brokers
   string   broker_symbol;              // resolved broker-specific symbol, e.g. "XAUUSDm" - same as .symbol once resolved
   double   tick_size;
   double   tick_value;
   string   currency_margin;
   ENUM_SYMBOL_TRADE_MODE trade_mode;
};

void SymbolSpec_Init(SymbolSpec &s)
{
   s.context_schema_version = MLQUANTAI_CONTEXT_SCHEMA_VERSION;
   s.symbol = "";
   s.digits = 0;
   s.point = 0;
   s.contract_size = 0;
   s.volume_min = 0;
   s.volume_max = 0;
   s.volume_step = 0;
   s.stops_level_points = 0;
   s.freeze_level_points = 0;
   s.currency_base = "";
   s.currency_profit = "";

   s.symbol_spec_schema_version = MLQUANTAI_SYMBOL_SPEC_SCHEMA_V1;
   s.instrument_id = "";
   s.broker_symbol = "";
   s.tick_size = 0;
   s.tick_value = 0;
   s.currency_margin = "";
   s.trade_mode = SYMBOL_TRADE_MODE_DISABLED;
}

// Returns false (spec left at Init() defaults) if the symbol isn't known
// to the terminal - callers should treat that as "not ready", same as a
// MarketContext with bid/ask still at 0.
//
// UNCHANGED since Step 9: takes whatever symbol string the caller
// already decided on, with NO instrument_id/broker_symbol resolution or
// alias validation - callers that need that (any new B2+ code) should
// use SymbolSpec_BuildResolved() in MLQuantAI_SymbolResolver.mqh instead.
bool SymbolSpec_Build(string symbol, SymbolSpec &out)
{
   SymbolSpec_Init(out);
   if(!SymbolSelect(symbol, true))
      return false;

   out.symbol              = symbol;
   out.digits              = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   out.point               = SymbolInfoDouble(symbol, SYMBOL_POINT);
   out.contract_size       = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   out.volume_min           = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   out.volume_max           = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   out.volume_step          = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   out.stops_level_points   = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   out.freeze_level_points  = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   out.currency_base        = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
   out.currency_profit      = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
   return true;
}

#endif // __MLQUANTAI_SYMBOLSPEC_MQH__
