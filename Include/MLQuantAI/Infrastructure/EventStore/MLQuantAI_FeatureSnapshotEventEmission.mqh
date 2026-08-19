//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_FeatureSnapshotEventEmission.mqh|
//| Phase B8.2 Commit 2 (Part 0): FeatureSnapshot ->                   |
//| FEATURE_SNAPSHOT_CREATED -> EventStore append. Mirrors             |
//| MLQuantAI_RiskPlanEventEmission.mqh's RiskPlan_EmitRiskPlanCreated  |
//| exactly, adapted for a FeatureSnapshot (also a SystemEvent - a      |
//| derived artifact tied to a candidate, not a candidate lifecycle    |
//| transition - see Docs/PhaseB_B8_2_Commit2_ExportContract.md's       |
//| Part 0 for the full reasoning). No broker/order/history/tick call, |
//| no candidate mutation, no referential-integrity check against      |
//| CandidateProjection here (that's                                    |
//| FeatureSnapshotProjection_RebuildFromFile's job, on replay - this   |
//| file only durably writes what it's given).                          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_FEATURESNAPSHOTEVENTEMISSION_MQH__
#define __MLQUANTAI_FEATURESNAPSHOTEVENTEMISSION_MQH__

#include "MLQuantAI_EventStore.mqh"
#include "MLQuantAI_FeatureSnapshotProjection.mqh"

// Every FeatureSnapshot field flattened as top-level JSON keys - same
// convention MARKET_CONTEXT_READY/CANDIDATE_CREATED/RISK_PLAN_CREATED
// already use. Uses the same canonical formatting helpers
// FeatureSnapshot_VectorHashPayload uses (CanonicalDouble/CanonicalPrice)
// for the 8 double feature fields - the hashes themselves are carried
// through verbatim on replay, never recomputed from this JSON.
// is_kill_zone is written as a raw JSON boolean literal (true/false,
// unquoted) - the same convention MarketContext_ToJsonFragment already
// uses for its own is_kill_zone field.
string FeatureSnapshot_ToExtraJson(const FeatureSnapshot &f)
{
   string s = "";
   s += "\"feature_snapshot_id\":\""    + EventSerializer_Escape(f.feature_snapshot_id) + "\",";
   s += "\"candidate_id\":\""            + EventSerializer_Escape(f.candidate_id) + "\",";
   s += "\"candidate_hash\":\""          + EventSerializer_Escape(f.candidate_hash) + "\",";
   s += "\"context_event_id\":\""        + EventSerializer_Escape(f.context_event_id) + "\",";
   s += "\"context_hash\":\""            + EventSerializer_Escape(f.context_hash) + "\",";
   s += "\"detector_hash\":\""           + EventSerializer_Escape(f.detector_hash) + "\",";
   s += "\"atr_m15\":"                   + CanonicalDouble(f.atr_m15) + ",";
   s += "\"adx_m15\":"                   + CanonicalDouble(f.adx_m15) + ",";
   s += "\"ema_slope_m15\":"             + CanonicalDouble(f.ema_slope_m15) + ",";
   s += "\"pdh\":"                       + CanonicalPrice(f.pdh) + ",";
   s += "\"pdl\":"                       + CanonicalPrice(f.pdl) + ",";
   s += "\"asian_range_high\":"          + CanonicalPrice(f.asian_range_high) + ",";
   s += "\"asian_range_low\":"           + CanonicalPrice(f.asian_range_low) + ",";
   s += "\"spread_points_at_anchor\":"   + CanonicalDouble(f.spread_points_at_anchor) + ",";
   s += "\"news_count\":"                + IntegerToString(f.news_count) + ",";
   s += "\"max_news_impact\":"           + IntegerToString(f.max_news_impact) + ",";
   s += "\"nearest_news_minutes\":"      + IntegerToString(f.nearest_news_minutes) + ",";
   s += "\"is_kill_zone\":"              + (f.is_kill_zone ? "true" : "false") + ",";
   s += "\"feature_vector_hash\":\""     + EventSerializer_Escape(f.feature_vector_hash) + "\",";
   s += "\"feature_snapshot_hash\":\""   + EventSerializer_Escape(f.feature_snapshot_hash) + "\",";
   s += "\"feature_schema_version\":\"" + EventSerializer_Escape(f.feature_schema_version) + "\"";
   return s;
}

// The Part 0 boundary function. Returns true only if a
// FEATURE_SNAPSHOT_CREATED event was durably appended THIS call.
// Returns false, with no error and no write attempted, in two
// legitimate non-error cases:
//  - f.feature_snapshot_id == "" - an unfilled/rejected snapshot
//    (Candidate_ToFeatureSnapshot returned false) emits no event, same
//    as a rejected RiskPlan emits no RISK_PLAN_CREATED;
//  - FeatureSnapshotProjection_TryGet(f.feature_snapshot_id, ...)
//    already finds this id - a duplicate call for the same snapshot
//    (this session, or replayed from a prior run) does NOT append a
//    second creation event. Deliberately COARSE, live-session guard
//    (any existing record blocks re-emission, regardless of
//    feature_snapshot_hash) - the finer duplicate-vs-collision
//    distinction belongs to FeatureSnapshotProjection_ApplyLine on
//    replay, not here, mirroring RiskPlan_EmitRiskPlanCreated exactly.
// Returns false (with EventStore_LogSystem's own SafeMode_Trip already
// having fired) if the write itself failed to become durable.
//
// After a successful durable write, also applies the equivalent
// record directly to FeatureSnapshotProjection's live in-memory
// registry - the same StateProjector-live-sync fix B5 Commit 5 /
// RiskPlan_EmitRiskPlanCreated already needed.
bool FeatureSnapshot_EmitFeatureSnapshotCreated(const FeatureSnapshot &f)
{
   if(f.feature_snapshot_id == "") return false;

   FeatureSnapshotProjectionRecord existing;
   if(FeatureSnapshotProjection_TryGet(f.feature_snapshot_id, existing)) return false;

   string extraJson = FeatureSnapshot_ToExtraJson(f);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_FEATURE_SNAPSHOT_CREATED), "feature snapshot created", extraJson))
      return false;

   FeatureSnapshotProjection_ApplyLiveRecord(f);
   return true;
}

#endif // __MLQUANTAI_FEATURESNAPSHOTEVENTEMISSION_MQH__
