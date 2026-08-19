//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_RealizedOutcomeEventEmission.mqh|
//| Phase B8.2 Commit 3: RealizedOutcome ->                             |
//| TRADE_OUTCOME_LABELED -> EventStore append. Mirrors                 |
//| MLQuantAI_FeatureSnapshotEventEmission.mqh's own emitter exactly,   |
//| adapted for a RealizedOutcome (also a SystemEvent - a derived        |
//| artifact tied to a candidate, not a candidate lifecycle transition  |
//| - see Docs/PhaseB_B8_2_Commit3_OutcomeLabelContract.md's Part 1).   |
//| Reuses EVENT_TYPE_TRADE_OUTCOME_LABELED, a dormant Phase A enum      |
//| value that nothing produced until now. No broker/order/history/tick |
//| call, no candidate mutation, no referential-integrity check against |
//| CandidateProjection here (that's                                    |
//| RealizedOutcomeProjection_RebuildFromFile's job, on replay - this    |
//| file only durably writes what it's given).                          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_REALIZEDOUTCOMEEVENTEMISSION_MQH__
#define __MLQUANTAI_REALIZEDOUTCOMEEVENTEMISSION_MQH__

#include "MLQuantAI_EventStore.mqh"
#include "MLQuantAI_RealizedOutcomeProjection.mqh"

// Every RealizedOutcome field flattened as top-level JSON keys - same
// convention every prior SystemEvent (RISK_PLAN_CREATED,
// FEATURE_SNAPSHOT_CREATED) already uses. outcome_time uses the same
// TimeToString(..., TIME_DATE|TIME_SECONDS) convention
// setup_anchor_bar_time already uses in CANDIDATE_CREATED.
string RealizedOutcome_ToExtraJson(const RealizedOutcome &o)
{
   string s = "";
   s += "\"realized_outcome_id\":\""   + EventSerializer_Escape(o.realized_outcome_id) + "\",";
   s += "\"candidate_id\":\""           + EventSerializer_Escape(o.candidate_id) + "\",";
   s += "\"candidate_hash\":\""          + EventSerializer_Escape(o.candidate_hash) + "\",";
   s += "\"label_schema_version\":\""     + EventSerializer_Escape(o.label_schema_version) + "\",";
   s += "\"label\":\""                     + EventSerializer_Escape(o.label) + "\",";
   s += "\"outcome_reference\":\""          + EventSerializer_Escape(o.outcome_reference) + "\",";
   s += "\"outcome_hash\":\""                + EventSerializer_Escape(o.outcome_hash) + "\",";
   s += "\"outcome_time\":\""                 + TimeToString(o.outcome_time, TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"realized_outcome_hash\":\""         + EventSerializer_Escape(o.realized_outcome_hash) + "\",";
   s += "\"realized_outcome_schema_version\":\"" + EventSerializer_Escape(o.realized_outcome_schema_version) + "\"";
   return s;
}

// The Commit 3 boundary function. Returns true only if a
// TRADE_OUTCOME_LABELED event was durably appended THIS call. Returns
// false, with no error and no write attempted, in two legitimate
// non-error cases:
//  - o.realized_outcome_id == "" - an unfilled/rejected outcome
//    (RealizedOutcome_Build returned false) emits no event, same as a
//    rejected RiskPlan emits no RISK_PLAN_CREATED;
//  - RealizedOutcomeProjection_TryGet(o.realized_outcome_id, ...)
//    already finds this id - a duplicate call for the same outcome
//    (this session, or replayed from a prior run) does NOT append a
//    second creation event. Deliberately COARSE, live-session guard
//    (any existing record blocks re-emission, regardless of
//    realized_outcome_hash) - the finer duplicate-vs-collision
//    distinction belongs to RealizedOutcomeProjection_ApplyLine on
//    replay, not here, mirroring FeatureSnapshot_EmitFeatureSnapshotCreated
//    exactly.
// Returns false (with EventStore_LogSystem's own SafeMode_Trip already
// having fired) if the write itself failed to become durable.
//
// After a successful durable write, also applies the equivalent
// record directly to RealizedOutcomeProjection's live in-memory
// registry - the same StateProjector-live-sync fix every prior B7/B8.2
// emitter already needed.
bool RealizedOutcome_EmitTradeOutcomeLabeled(const RealizedOutcome &o)
{
   if(o.realized_outcome_id == "") return false;

   RealizedOutcomeProjectionRecord existing;
   if(RealizedOutcomeProjection_TryGet(o.realized_outcome_id, existing)) return false;

   string extraJson = RealizedOutcome_ToExtraJson(o);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_TRADE_OUTCOME_LABELED), "trade outcome labeled", extraJson))
      return false;

   RealizedOutcomeProjection_ApplyLiveRecord(o);
   return true;
}

#endif // __MLQUANTAI_REALIZEDOUTCOMEEVENTEMISSION_MQH__
