//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_ModelRegistryCompatibility.mqh|
//| Phase B8.3: ModelRegistry_FindCompatible() - a thin registry-lookup |
//| wrapper around the pure ModelArtifact_CheckCompatibility(), per     |
//| Docs/PhaseB_B8_3_ModelRegistryContract.md. Looks up exactly one     |
//| named model_id/model_version pair in ModelArtifactProjection's own  |
//| registry - never searches for, selects, or falls back to another   |
//| artifact. No ModelRegistry struct is introduced; this operates      |
//| directly on ModelArtifactProjection's global registry state, the    |
//| same free-function-over-global-registry shape every prior           |
//| projection in this codebase already uses.                           |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MODELREGISTRYCOMPATIBILITY_MQH__
#define __MLQUANTAI_MODELREGISTRYCOMPATIBILITY_MQH__

#include "MLQuantAI_ModelArtifactProjection.mqh"
#include "../../AI/MLQuantAI_ModelArtifactBuilder.mqh"

// Adapts a ModelArtifactProjectionRecord (replay/registry type) into a
// ModelArtifact (the type ModelArtifact_CheckCompatibility, B8.3's own
// sealed pure function, was written against) - same minimal-adapter
// discipline B8.2 Commit 2 already established for its own projection
// -> live-type bridges. Every field is copied 1:1; the two types share
// the same field set by construction.
void ModelRegistry_ArtifactFromProjection(const ModelArtifactProjectionRecord &rec, ModelArtifact &outArtifact)
{
   ModelArtifact_Init(outArtifact);
   outArtifact.model_registry_schema_version = rec.model_registry_schema_version;
   outArtifact.model_registry_id              = rec.model_registry_id;
   outArtifact.model_id                        = rec.model_id;
   outArtifact.model_version                    = rec.model_version;
   outArtifact.model_artifact_hash               = rec.model_artifact_hash;
   outArtifact.model_registry_hash                = rec.model_registry_hash;
   outArtifact.feature_schema_version              = rec.feature_schema_version;
   outArtifact.training_dataset_id                  = rec.training_dataset_id;
   outArtifact.training_dataset_hash                 = rec.training_dataset_hash;
   outArtifact.model_target                           = rec.model_target;
   outArtifact.input_schema_version                    = rec.input_schema_version;
   outArtifact.output_schema_version                    = rec.output_schema_version;
   outArtifact.runtime_framework                         = rec.runtime_framework;
   outArtifact.runtime_version                            = rec.runtime_version;
   outArtifact.promotion_state                             = rec.promotion_state;
}

// Looks up model_id/model_version in the (already-rebuilt, by the
// caller) ModelArtifactProjection registry, then delegates to
// ModelArtifact_CheckCompatibility. Returns false with
// outReason = "model artifact not found in registry" if no such
// model_registry_id exists - a distinct, unambiguous reason from any
// ModelArtifact_CheckCompatibility rejection, so a caller can tell
// "doesn't exist" apart from "exists but incompatible".
bool ModelRegistry_FindCompatible(string modelId, string modelVersion,
                                    string requestedFeatureSchemaVersion, string requestedModelTarget,
                                    string requestedInputSchemaVersion, string requestedOutputSchemaVersion,
                                    string requestedRuntimeFramework, string requestedRuntimeVersion,
                                    ModelArtifact &outArtifact, string &outReason)
{
   ModelArtifact_Init(outArtifact);
   outReason = "";

   string modelRegistryId = Ids_ModelRegistryId(modelId, modelVersion);

   ModelArtifactProjectionRecord rec;
   if(!ModelArtifactProjection_TryGet(modelRegistryId, rec))
   {
      outReason = "model artifact not found in registry";
      return false;
   }

   ModelArtifact candidate;
   ModelRegistry_ArtifactFromProjection(rec, candidate);

   if(!ModelArtifact_CheckCompatibility(candidate, requestedFeatureSchemaVersion, requestedModelTarget,
                                          requestedInputSchemaVersion, requestedOutputSchemaVersion,
                                          requestedRuntimeFramework, requestedRuntimeVersion, outReason))
      return false;

   outArtifact = candidate;
   return true;
}

#endif // __MLQUANTAI_MODELREGISTRYCOMPATIBILITY_MQH__
