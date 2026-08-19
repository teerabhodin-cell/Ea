//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_AIDecisionEventEmission.mqh              |
//| Phase B8.5 Commit 2: AIDecision -> AI_DECISION_CREATED ->          |
//| EventStore append. Mirrors                                          |
//| MLQuantAI_FeatureSnapshotEventEmission.mqh's                        |
//| FeatureSnapshot_EmitFeatureSnapshotCreated exactly, adapted for an  |
//| AIDecision (also a SystemEvent - a derived artifact tied to a       |
//| candidate, not a candidate lifecycle transition - see               |
//| Docs/PhaseB_B8_5_AIDecisionContract.md's Commit 2 addendum for the  |
//| full reasoning). No broker/order/history/tick call, no mutation of  |
//| the input, no referential-integrity check against                   |
//| FeatureSnapshotProjection/ModelArtifactProjection here (that's       |
//| AIDecisionProjection_RebuildFromFile's job, on replay - this file    |
//| only durably writes what it's given). Every decision_outcome        |
//| (ALLOW/REJECT/ABSTAIN) is emitted identically - this file never      |
//| branches on outcome to decide whether to emit, and produces no      |
//| execution side effect for any outcome value.                        |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_AIDECISIONEVENTEMISSION_MQH__
#define __MLQUANTAI_AIDECISIONEVENTEMISSION_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_AIDecisionProjection.mqh"

// Every AIDecision field flattened as top-level JSON keys - same
// convention FeatureSnapshot_ToExtraJson/ModelArtifact_ToExtraJson
// already use. decision_outcome/decision_reason_code are written as
// quoted strings via AiDecisionOutcomeToString/ReasonCodeToString
// (mirrors ModelArtifact_ToExtraJson's promotion_state convention).
// allow_threshold/p_success go through CanonicalDouble, same as every
// other double ever placed in extra_json/a hash payload in this
// project.
string AIDecision_ToExtraJson(const AIDecision &d)
{
   string s = "";
   s += "\"ai_decision_schema_version\":\"" + EventSerializer_Escape(d.ai_decision_schema_version) + "\",";
   s += "\"ai_decision_id\":\""              + EventSerializer_Escape(d.ai_decision_id) + "\",";
   s += "\"ai_decision_hash\":\""            + EventSerializer_Escape(d.ai_decision_hash) + "\",";
   s += "\"candidate_id\":\""                 + EventSerializer_Escape(d.candidate_id) + "\",";
   s += "\"candidate_hash\":\""                + EventSerializer_Escape(d.candidate_hash) + "\",";
   s += "\"feature_snapshot_id\":\""            + EventSerializer_Escape(d.feature_snapshot_id) + "\",";
   s += "\"feature_snapshot_hash\":\""           + EventSerializer_Escape(d.feature_snapshot_hash) + "\",";
   s += "\"feature_vector_hash\":\""              + EventSerializer_Escape(d.feature_vector_hash) + "\",";
   s += "\"model_registry_id\":\""                 + EventSerializer_Escape(d.model_registry_id) + "\",";
   s += "\"model_registry_hash\":\""                + EventSerializer_Escape(d.model_registry_hash) + "\",";
   s += "\"model_artifact_hash\":\""                 + EventSerializer_Escape(d.model_artifact_hash) + "\",";
   s += "\"inference_output_hash\":\""                + EventSerializer_Escape(d.inference_output_hash) + "\",";
   s += "\"output_schema_version\":\""                 + EventSerializer_Escape(d.output_schema_version) + "\",";
   s += "\"inference_contract_version\":\""             + EventSerializer_Escape(d.inference_contract_version) + "\",";
   s += "\"decision_policy_version\":\""                 + EventSerializer_Escape(d.decision_policy_version) + "\",";
   s += "\"threshold_version\":\""                        + EventSerializer_Escape(d.threshold_version) + "\",";
   s += "\"allow_threshold\":"                              + CanonicalDouble(d.allow_threshold) + ",";
   s += "\"p_success\":"                                     + CanonicalDouble(d.p_success) + ",";
   s += "\"decision_outcome\":\""                             + AiDecisionOutcomeToString(d.decision_outcome) + "\",";
   s += "\"decision_reason_code\":\""                          + ReasonCodeToString(d.decision_reason_code) + "\"";
   return s;
}

// The Commit 2 boundary function. Returns true only if an
// AI_DECISION_CREATED event was durably appended THIS call.
// Returns false, with no error and no write attempted, in two
// legitimate non-error cases:
//  - d.ai_decision_id == "" - a decision that failed AIDecision_Build
//    (left at Init() defaults, decision_outcome ==
//    AI_DECISION_OUTCOME_NONE) emits no event, same as an unfilled
//    FeatureSnapshot/rejected RiskPlan emits nothing. This is the only
//    outcome-based gate: ALLOW, REJECT, and (once reachable) ABSTAIN
//    are ALL emitted identically, as audit evidence only;
//  - AIDecisionProjection_TryGet(d.ai_decision_id, ...) already finds
//    this id - a duplicate call for the same decision (this session,
//    or replayed from a prior run) does NOT append a second creation
//    event. Deliberately COARSE, live-session guard (any existing
//    record blocks re-emission, regardless of ai_decision_hash) - the
//    finer duplicate-vs-collision distinction belongs to
//    AIDecisionProjection_ApplyLine on replay, not here.
// Returns false (with EventStore_LogSystem's own SafeMode_Trip already
// having fired) if the write itself failed to become durable.
//
// After a successful durable write, also applies the equivalent
// record directly to AIDecisionProjection's live in-memory registry -
// the same live-sync fix every prior emitter in this project needs.
bool AIDecision_EmitAIDecisionCreated(const AIDecision &d)
{
   if(d.ai_decision_id == "") return false;

   AIDecisionProjectionRecord existing;
   if(AIDecisionProjection_TryGet(d.ai_decision_id, existing)) return false;

   string extraJson = AIDecision_ToExtraJson(d);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_AI_DECISION_CREATED), "ai decision created", extraJson))
      return false;

   AIDecisionProjection_ApplyLiveRecord(d);
   return true;
}

#endif // __MLQUANTAI_AIDECISIONEVENTEMISSION_MQH__
