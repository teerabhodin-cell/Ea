//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_ModelArtifactEventEmission.mqh|
//| Phase B8.3: ModelArtifact -> MODEL_ARTIFACT_REGISTERED ->            |
//| EventStore append. Mirrors                                          |
//| MLQuantAI_RealizedOutcomeEventEmission.mqh's own emitter exactly,   |
//| adapted for a ModelArtifact (also a SystemEvent - tied to a         |
//| registered model, not a candidate lifecycle transition or even      |
//| candidate-tied at all - see                                         |
//| Docs/PhaseB_B8_3_ModelRegistryContract.md). No ONNX/file-hash call, |
//| no broker/order/history/tick call, no candidate mutation - this     |
//| file only durably writes what it's given.                           |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MODELARTIFACTEVENTEMISSION_MQH__
#define __MLQUANTAI_MODELARTIFACTEVENTEMISSION_MQH__

#include "MLQuantAI_EventStore.mqh"
#include "MLQuantAI_ModelArtifactProjection.mqh"

// Every ModelArtifact field flattened as top-level JSON keys - same
// convention every prior SystemEvent (RISK_PLAN_CREATED,
// FEATURE_SNAPSHOT_CREATED, TRADE_OUTCOME_LABELED) already uses.
// promotion_state is written as a quoted string via
// ModelPromotionStateToString - no raw-literal-boolean gotcha the way
// FeatureSnapshot's is_kill_zone needed, since EventSerializer_GetStr
// already handles a quoted enum-as-string round-trip correctly.
string ModelArtifact_ToExtraJson(const ModelArtifact &a)
{
   string s = "";
   s += "\"model_registry_id\":\""    + EventSerializer_Escape(a.model_registry_id) + "\",";
   s += "\"model_id\":\""              + EventSerializer_Escape(a.model_id) + "\",";
   s += "\"model_version\":\""          + EventSerializer_Escape(a.model_version) + "\",";
   s += "\"model_artifact_hash\":\""     + EventSerializer_Escape(a.model_artifact_hash) + "\",";
   s += "\"feature_schema_version\":\""   + EventSerializer_Escape(a.feature_schema_version) + "\",";
   s += "\"training_dataset_id\":\""       + EventSerializer_Escape(a.training_dataset_id) + "\",";
   s += "\"training_dataset_hash\":\""      + EventSerializer_Escape(a.training_dataset_hash) + "\",";
   s += "\"model_target\":\""                + EventSerializer_Escape(a.model_target) + "\",";
   s += "\"input_schema_version\":\""         + EventSerializer_Escape(a.input_schema_version) + "\",";
   s += "\"output_schema_version\":\""         + EventSerializer_Escape(a.output_schema_version) + "\",";
   s += "\"runtime_framework\":\""              + EventSerializer_Escape(a.runtime_framework) + "\",";
   s += "\"runtime_version\":\""                 + EventSerializer_Escape(a.runtime_version) + "\",";
   s += "\"promotion_state\":\""                  + ModelPromotionStateToString(a.promotion_state) + "\",";
   s += "\"model_registry_hash\":\""               + EventSerializer_Escape(a.model_registry_hash) + "\",";
   s += "\"model_registry_schema_version\":\""      + EventSerializer_Escape(a.model_registry_schema_version) + "\"";
   return s;
}

// The B8.3 boundary function. Returns true only if a
// MODEL_ARTIFACT_REGISTERED event was durably appended THIS call.
// Returns false, with no error and no write attempted, in two
// legitimate non-error cases:
//  - a.model_registry_id == "" - an unfilled/rejected artifact
//    (ModelArtifact_Build returned false) emits no event;
//  - ModelArtifactProjection_TryGet(a.model_registry_id, ...) already
//    finds this id - a duplicate call for the same artifact (this
//    session, or replayed from a prior run) does NOT append a second
//    registration event. Deliberately COARSE, live-session guard,
//    mirroring every prior B7/B8.2/B8.3 emitter exactly.
// Returns false (with EventStore_LogSystem's own SafeMode_Trip already
// having fired) if the write itself failed to become durable.
bool ModelArtifact_EmitModelArtifactRegistered(const ModelArtifact &a)
{
   if(a.model_registry_id == "") return false;

   ModelArtifactProjectionRecord existing;
   if(ModelArtifactProjection_TryGet(a.model_registry_id, existing)) return false;

   string extraJson = ModelArtifact_ToExtraJson(a);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MODEL_ARTIFACT_REGISTERED), "model artifact registered", extraJson))
      return false;

   ModelArtifactProjection_ApplyLiveRecord(a);
   return true;
}

#endif // __MLQUANTAI_MODELARTIFACTEVENTEMISSION_MQH__
