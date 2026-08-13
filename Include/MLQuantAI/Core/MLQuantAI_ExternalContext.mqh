//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_ExternalContext.mqh                   |
//| Schema for data outside MT5's own price feed: DXY/US10Y/VIX for   |
//| now, news/sentiment later. No hub populates this in Phase A/early |
//| Phase B (per the Alternative Data Plan, that's V2+) - the struct  |
//| exists now so MarketContext's shape is stable going forward, but  |
//| every has_* flag stays false and every value stays 0 until a real |
//| hub fills them in. Every consumer MUST check has_* before trusting|
//| a value - a 0 means "no data", never "the value is 0".            |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EXTERNALCONTEXT_MQH__
#define __MLQUANTAI_EXTERNALCONTEXT_MQH__

struct ExternalContext
{
   bool     has_dxy;
   double   dxy_value;
   int      dxy_age_seconds;

   bool     has_us10y;
   double   us10y_value;
   int      us10y_age_seconds;

   bool     has_vix;
   double   vix_value;
   int      vix_age_seconds;
};

void ExternalContext_Init(ExternalContext &d)
{
   d.has_dxy = false;    d.dxy_value = 0;    d.dxy_age_seconds = 0;
   d.has_us10y = false;  d.us10y_value = 0;  d.us10y_age_seconds = 0;
   d.has_vix = false;    d.vix_value = 0;    d.vix_age_seconds = 0;
}

#endif // __MLQUANTAI_EXTERNALCONTEXT_MQH__
