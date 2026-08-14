//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_FeatureSnapshot.mqh                 |
//| Phase B B1: contract stub only. FeatureSnapshot is the eventual   |
//| feature-store row a labeled dataset / AI filter (Phase C) reads  |
//| from - narrower than the full MarketContext (which also carries  |
//| raw bars, symbol_spec, account state), just the derived numbers  |
//| a model would actually train on, addressed by context_event_id.  |
//|                                                                    |
//| Not wired to anything yet: no Feature Engine builds this struct   |
//| in B1 (that's out of scope per the B1 contract-freeze pass - see  |
//| MLQuantAI_MarketContext.mqh's header). It exists now so the shape |
//| is frozen and versioned ahead of B3, the same reasoning as        |
//| MarketContext/TradeCandidate/NewsSnapshot being frozen before any |
//| detector reads them. Extend additively (new fields, never repurpo|
//| sed ones) and bump feature_schema_version to a new _V2 constant   |
//| in MLQuantAI_ContractVersions.mqh if the meaning of an existing   |
//| field ever needs to change.                                       |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_FEATURESNAPSHOT_MQH__
#define __MLQUANTAI_FEATURESNAPSHOT_MQH__

#include "../Core/MLQuantAI_ContractVersions.mqh"

struct FeatureSnapshot
{
   string   feature_schema_version;   // MLQUANTAI_FEATURE_SCHEMA_V1
   string   context_event_id;         // which MarketContext this was derived from

   double   atr_m15;
   double   adx_m15;
   double   ema_slope_m15;
   double   pdh;
   double   pdl;
   double   asian_range_high;
   double   asian_range_low;
   double   spread_points_at_anchor;

   int      news_count;
   int      max_news_impact;
   int      nearest_news_minutes;
   bool     is_kill_zone;
};

void FeatureSnapshot_Init(FeatureSnapshot &f)
{
   f.feature_schema_version = MLQUANTAI_FEATURE_SCHEMA_V1;
   f.context_event_id = "";
   f.atr_m15 = 0;
   f.adx_m15 = 0;
   f.ema_slope_m15 = 0;
   f.pdh = 0;
   f.pdl = 0;
   f.asian_range_high = 0;
   f.asian_range_low = 0;
   f.spread_points_at_anchor = 0;
   f.news_count = 0;
   f.max_news_impact = 0;
   f.nearest_news_minutes = 0;
   f.is_kill_zone = false;
}

#endif // __MLQUANTAI_FEATURESNAPSHOT_MQH__
