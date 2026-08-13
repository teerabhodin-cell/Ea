//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_AlternativeDataSnapshot.mqh           |
//| Schema for DXY/US10Y/VIX context data. V1 does not populate any  |
//| of this (AlternativeDataHub doesn't exist until V2/Sprint 4+) -  |
//| the struct exists now so MarketContext's shape doesn't change    |
//| later, but every has_* flag stays false and every value stays 0  |
//| until a real hub fills them in. Every consumer MUST check has_*  |
//| before trusting a value - never assume a 0 means "DXY is at 0",  |
//| it means "no data".                                              |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ALTERNATIVEDATASNAPSHOT_MQH__
#define __MLQUANTAI_ALTERNATIVEDATASNAPSHOT_MQH__

struct AlternativeDataSnapshot
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

void AlternativeDataSnapshot_Init(AlternativeDataSnapshot &d)
{
   d.has_dxy = false;    d.dxy_value = 0;    d.dxy_age_seconds = 0;
   d.has_us10y = false;  d.us10y_value = 0;  d.us10y_age_seconds = 0;
   d.has_vix = false;    d.vix_value = 0;    d.vix_age_seconds = 0;
}

#endif // __MLQUANTAI_ALTERNATIVEDATASNAPSHOT_MQH__
