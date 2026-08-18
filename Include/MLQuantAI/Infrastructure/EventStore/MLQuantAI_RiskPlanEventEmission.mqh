//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_RiskPlanEventEmission.mqh|
//| Phase B7 Commit 2 (B7.4): RiskPlan -> RISK_PLAN_CREATED ->        |
//| EventStore append. Mirrors Strategies/MLQuantAI_CRT_V1_EventEmission|
//| .mqh's CRT_EmitCandidateCreated exactly, adapted for a SystemEvent |
//| (RiskPlan is a derived artifact tied to a candidate, not a         |
//| candidate lifecycle transition - see                               |
//| Docs/PhaseB_B7_RiskPlanContract.md's B7 Commit 2 addendum for the   |
//| full reasoning). No broker/order/history/tick call, no candidate    |
//| mutation, no referential-integrity check against CandidateProjection|
//| here (that's RiskPlanProjection_RebuildFromFile's job, on replay -  |
//| this file only durably writes what it's given, same "trust the      |
//| caller, verify independently on replay" split B5/B6.1 already use). |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_RISKPLANEVENTEMISSION_MQH__
#define __MLQUANTAI_RISKPLANEVENTEMISSION_MQH__

#include "MLQuantAI_EventStore.mqh"
#include "MLQuantAI_RiskPlanProjection.mqh"

// Every RiskPlan field flattened as top-level JSON keys (not nested
// under an "extra_json" key) - same convention MARKET_CONTEXT_READY
// and CANDIDATE_CREATED's own extra_json already use, read back later
// via plain EventSerializer_GetStr/GetDouble/GetLong on the raw line.
// Uses the same canonical formatting helpers RiskPlan_HashPayload
// uses (CanonicalPrice/CanonicalDouble/CanonicalPercent) rather than
// inventing a separate display-precision convention - plan_hash itself
// is carried through verbatim on replay, never recomputed from this
// JSON, so this choice only affects how faithfully a human/downstream
// reader sees the decimal values, not hash correctness.
//
// Only the B7 field group is persisted - decision/allowed/reject_reason/
// lot/risk_money/risk_schema_version (the Phase A shadow fields) are
// NOT separately written: a RISK_PLAN_CREATED event only ever exists
// for an ALLOWED plan (see RiskPlan_EmitRiskPlanCreated's own guard
// below), and lot==lot_size/risk_money==risk_amount are already
// covered by their B7 names. Same "don't persist a field twice"
// discipline CandidateProjectionRecord already applies.
string RiskPlan_ToExtraJson(const RiskPlan &p)
{
   string s = "";
   s += "\"risk_plan_id\":\""        + EventSerializer_Escape(p.risk_plan_id) + "\",";
   s += "\"candidate_id\":\""         + EventSerializer_Escape(p.candidate_id) + "\",";
   s += "\"candidate_hash\":\""       + EventSerializer_Escape(p.candidate_hash) + "\",";
   s += "\"risk_context_hash\":\""    + EventSerializer_Escape(p.risk_context_hash) + "\",";
   s += "\"planned_entry\":"          + CanonicalPrice(p.planned_entry) + ",";
   s += "\"planned_sl\":"             + CanonicalPrice(p.planned_sl) + ",";
   s += "\"planned_tp\":"             + CanonicalPrice(p.planned_tp) + ",";
   s += "\"stop_distance_points\":"   + CanonicalDouble(p.stop_distance_points) + ",";
   s += "\"rr_ratio\":"               + CanonicalDouble(p.rr_ratio) + ",";
   s += "\"risk_percent\":"           + CanonicalPercent(p.risk_percent) + ",";
   s += "\"risk_amount\":"            + CanonicalDouble(p.risk_amount) + ",";
   s += "\"lot_size\":"               + CanonicalDouble(p.lot_size) + ",";
   s += "\"sizing_method\":\""        + EventSerializer_Escape(p.sizing_method) + "\",";
   s += "\"sizing_rules_version\":\"" + EventSerializer_Escape(p.sizing_rules_version) + "\",";
   s += "\"plan_hash\":\""            + EventSerializer_Escape(p.plan_hash) + "\",";
   s += "\"risk_plan_schema_version\":\"" + EventSerializer_Escape(p.risk_plan_schema_version) + "\"";
   return s;
}

// The B7.4 boundary function. Returns true only if a RISK_PLAN_CREATED
// event was durably appended THIS call. Returns false, with no error
// and no write attempted, in two legitimate non-error cases:
//  - p.risk_plan_id == "" or !p.allowed - a rejected/unfilled plan
//    (Candidate_ToRiskPlan returned false) emits no event, same as a
//    non-detection candidate emits no CANDIDATE_CREATED;
//  - RiskPlanProjection_TryGet(p.risk_plan_id, ...) already finds this
//    risk_plan_id - a duplicate call for the same plan (this session,
//    or replayed from a prior run) does NOT append a second creation
//    event. This is a deliberately COARSE, live-session guard (any
//    existing record blocks re-emission, regardless of plan_hash) -
//    the finer duplicate-vs-collision distinction belongs to
//    RiskPlanProjection_ApplyLine on replay, not here, exactly
//    mirroring CRT_EmitCandidateCreated's own StateProjector guard.
// Returns false (with EventStore_LogSystem's own SafeMode_Trip already
// having fired) if the write itself failed to become durable.
//
// After a successful durable write, also applies the equivalent
// record directly to RiskPlanProjection's live in-memory registry -
// the same StateProjector-live-sync fix B5 Commit 5 needed: without
// this, two RiskPlan_EmitRiskPlanCreated calls for the same
// risk_plan_id inside the same live session - before any replay has
// ever run - would both see RiskPlanProjection_TryGet() return false
// and both durably append a RISK_PLAN_CREATED event.
bool RiskPlan_EmitRiskPlanCreated(const RiskPlan &p)
{
   if(p.risk_plan_id == "" || !p.allowed) return false;

   RiskPlanProjectionRecord existing;
   if(RiskPlanProjection_TryGet(p.risk_plan_id, existing)) return false;

   string extraJson = RiskPlan_ToExtraJson(p);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_RISK_PLAN_CREATED), "risk plan created", extraJson))
      return false;

   RiskPlanProjection_ApplyLiveRecord(p);
   return true;
}

#endif // __MLQUANTAI_RISKPLANEVENTEMISSION_MQH__
