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
//|                                                                    |
//| Phase B8.1 (additive): identity/lineage/hash fields added for the |
//| AI feature-vector contract - candidate_id/candidate_hash/         |
//| context_hash/detector_hash (full provenance, copied verbatim,     |
//| never recomputed here), feature_snapshot_id (identity),           |
//| feature_vector_hash (pure ML-input content, no lineage),          |
//| feature_snapshot_hash (full record). All 12 Phase B1 feature      |
//| fields above are UNCHANGED in meaning. See                        |
//| Docs/PhaseB_B8_1_FeatureSnapshotContract.md for the full contract |
//| this file implements, including why FeatureSnapshot_Init() still  |
//| stamps the old MLQUANTAI_FEATURE_SCHEMA_V1 default (unchanged, so |
//| Test_PhaseBContracts.mq5's sealed assertion stays true) while a   |
//| snapshot actually built by Candidate_ToFeatureSnapshot            |
//| (Market/MLQuantAI_FeatureSnapshotBuilder.mqh) carries the new     |
//| MLQUANTAI_FEATURE_SCHEMA_B8_1_V1 constant instead.                |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_FEATURESNAPSHOT_MQH__
#define __MLQUANTAI_FEATURESNAPSHOT_MQH__

#include "../Core/MLQuantAI_ContractVersions.mqh"
#include "../Core/MLQuantAI_CanonicalFormat.mqh"
#include "../Core/MLQuantAI_Ids.mqh"

struct FeatureSnapshot
{
   // Phase B1 fields - UNCHANGED, same meaning
   string   feature_schema_version;   // MLQUANTAI_FEATURE_SCHEMA_V1 (Init default) or MLQUANTAI_FEATURE_SCHEMA_B8_1_V1 (after Candidate_ToFeatureSnapshot)
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

   // Phase B8.1 fields (additive) - identity/lineage/content-integrity
   string   feature_snapshot_id;   // identity: Ids_FeatureSnapshotId(candidate_id)
   string   candidate_id;          // which candidate this snapshot backs
   string   candidate_hash;        // copied verbatim from the candidate
   string   context_hash;          // copied verbatim from the candidate's own context_hash
   string   detector_hash;         // copied verbatim from the candidate's own detector_hash
   string   feature_vector_hash;   // pure ML-input content hash (no lineage) - section 3a
   string   feature_snapshot_hash; // full record hash (identity+lineage+content) - section 3b
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

   f.feature_snapshot_id = "";
   f.candidate_id = "";
   f.candidate_hash = "";
   f.context_hash = "";
   f.detector_hash = "";
   f.feature_vector_hash = "";
   f.feature_snapshot_hash = "";
}

// Pure ML-input content - no lineage/identity field anywhere in this
// payload. feature_schema_version IS included (unlike
// risk_plan_schema_version's exclusion from plan_hash) so the same raw
// numeric values under a different schema shape hash differently - a
// model-registry compatibility question, not a struct-shape one.
string FeatureSnapshot_VectorHashPayload(const FeatureSnapshot &f)
{
   string s = "";
   s += f.feature_schema_version + "|";
   s += CanonicalDouble(f.atr_m15) + "|";
   s += CanonicalDouble(f.adx_m15) + "|";
   s += CanonicalDouble(f.ema_slope_m15) + "|";
   s += CanonicalPrice(f.pdh) + "|";
   s += CanonicalPrice(f.pdl) + "|";
   s += CanonicalPrice(f.asian_range_high) + "|";
   s += CanonicalPrice(f.asian_range_low) + "|";
   s += CanonicalDouble(f.spread_points_at_anchor) + "|";
   s += IntegerToString(f.news_count) + "|";
   s += IntegerToString(f.max_news_impact) + "|";
   s += IntegerToString(f.nearest_news_minutes) + "|";
   s += (f.is_kill_zone ? "1" : "0");
   return s;
}

string FeatureSnapshot_ComputeVectorHash(const FeatureSnapshot &f)
{
   return Ids_Sha256Hex(FeatureSnapshot_VectorHashPayload(f));
}

// Full record - every lineage field plus feature_vector_hash itself
// (not the raw values again, so the two payloads never duplicate the
// same numbers twice). feature_snapshot_id is included even though
// it's fully derivable from candidate_id alone - harmless redundancy,
// not a second independently-settable source of truth (unlike
// RiskPlan's lot/risk_money), since feature_snapshot_id can never
// disagree with what candidate_id implies.
string FeatureSnapshot_HashPayload(const FeatureSnapshot &f)
{
   string s = "";
   s += f.feature_snapshot_id + "|";
   s += f.candidate_id + "|";
   s += f.candidate_hash + "|";
   s += f.context_event_id + "|";
   s += f.context_hash + "|";
   s += f.detector_hash + "|";
   s += f.feature_schema_version + "|";
   s += f.feature_vector_hash;
   return s;
}

string FeatureSnapshot_ComputeHash(const FeatureSnapshot &f)
{
   return Ids_Sha256Hex(FeatureSnapshot_HashPayload(f));
}

#endif // __MLQUANTAI_FEATURESNAPSHOT_MQH__
