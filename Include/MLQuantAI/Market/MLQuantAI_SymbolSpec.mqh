//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_SymbolSpec.mqh                      |
//| Broker's contract terms for one symbol, captured once and reused |
//| - digits/point/contract size/volume limits/stop level all come   |
//| from SymbolInfo* calls that never change mid-session, so there's |
//| no reason to re-query them on every bar the way price is.        |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_SYMBOLSPEC_MQH__
#define __MLQUANTAI_SYMBOLSPEC_MQH__

#include "../Core/MLQuantAI_VersionRegistry.mqh"

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
}

// Returns false (spec left at Init() defaults) if the symbol isn't known
// to the terminal - callers should treat that as "not ready", same as a
// MarketContext with bid/ask still at 0.
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
