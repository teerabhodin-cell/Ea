//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_MarketContext.mqh                     |
//| The immutable snapshot every module reads from. Built once per   |
//| decision cycle by the (Sprint 2+) Feature Engine; every strategy |
//| module, the regime detector, the AI filter and the risk manager  |
//| all see the exact same numbers for that cycle - pass this by     |
//| const reference (const MarketContext &ctx), never by handle/     |
//| pointer, so nothing downstream can mutate what an upstream       |
//| module already decided on.                                       |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MARKETCONTEXT_MQH__
#define __MLQUANTAI_MARKETCONTEXT_MQH__

#include "MLQuantAI_Enums.mqh"
#include "MLQuantAI_AccountSnapshot.mqh"
#include "MLQuantAI_ExternalContext.mqh"
#include "MLQuantAI_VersionRegistry.mqh"

struct MarketContext
{
   string   schema_version;   // MLQUANTAI_CONTEXT_SCHEMA_VERSION at build time
   string   symbol;
   datetime bar_time;

   double   bid;
   double   ask;
   double   spread_points;

   double   atr_m15;
   double   atr_h1;
   double   adx_h1;

   double   ema20_m15;
   double   ema50_h1;
   double   ema200_h4;

   double   swing_high_m15;
   double   swing_low_m15;
   double   prev_day_high;
   double   prev_day_low;
   double   asian_high;
   double   asian_low;

   bool     in_london_killzone;
   bool     in_newyork_killzone;
   bool     high_impact_news_near;

   ENUM_MARKET_REGIME regime;
   string              regime_rules_version;

   AccountSnapshot     account;
   ExternalContext     external;
};

void MarketContext_Init(MarketContext &c)
{
   c.schema_version = MLQUANTAI_CONTEXT_SCHEMA_VERSION;
   c.symbol = "";
   c.bar_time = 0;
   c.bid = 0; c.ask = 0; c.spread_points = 0;
   c.atr_m15 = 0; c.atr_h1 = 0; c.adx_h1 = 0;
   c.ema20_m15 = 0; c.ema50_h1 = 0; c.ema200_h4 = 0;
   c.swing_high_m15 = 0; c.swing_low_m15 = 0;
   c.prev_day_high = 0; c.prev_day_low = 0;
   c.asian_high = 0; c.asian_low = 0;
   c.in_london_killzone = false;
   c.in_newyork_killzone = false;
   c.high_impact_news_near = false;
   c.regime = REGIME_TRANSITION;
   c.regime_rules_version = MLQUANTAI_REGIME_SCHEMA_VERSION;
   AccountSnapshot_Init(c.account);
   ExternalContext_Init(c.external);
}

#endif // __MLQUANTAI_MARKETCONTEXT_MQH__
