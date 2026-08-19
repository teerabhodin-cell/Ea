//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_ModelArtifactBuilder.mqh                  |
//| Phase B8.3: ModelArtifact_Build() - the pure, deterministic         |
//| builder, and ModelArtifact_CheckCompatibility() - the pure,         |
//| fail-closed compatibility check, both frozen in                    |
//| Docs/PhaseB_B8_3_ModelRegistryContract.md. Neither function loads   |
//| ONNX, touches a broker/history/tick call, appends an event, or      |
//| mutates its inputs. Neither ever searches for or selects an         |
//| alternative artifact - a caller who names a specific model_id/      |
//| model_version gets an exact accept/reject on exactly that one.      |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MODELARTIFACTBUILDER_MQH__
#define __MLQUANTAI_MODELARTIFACTBUILDER_MQH__

#include "MLQuantAI_ModelArtifact.mqh"

// Fail-closed input validation - contract "ModelArtifact_Build"
// section. Returns "" on success, a reason string on failure,
// mirroring RealizedOutcomeBuilder_ValidateInput's own shape. Every
// declared field is mandatory - no optional/partial registration.
string ModelArtifactBuilder_ValidateInput(string modelId, string modelVersion, string modelArtifactHash,
                                            string featureSchemaVersion, string trainingDatasetId, string trainingDatasetHash,
                                            string modelTarget, string inputSchemaVersion, string outputSchemaVersion,
                                            string runtimeFramework, string runtimeVersion)
{
   if(modelId == "")              return "empty model_id";
   if(modelVersion == "")         return "empty model_version";
   if(modelArtifactHash == "")    return "empty model_artifact_hash";
   if(featureSchemaVersion == "") return "empty feature_schema_version";
   if(trainingDatasetId == "")    return "empty training_dataset_id";
   if(trainingDatasetHash == "")  return "empty training_dataset_hash";
   if(modelTarget == "")          return "empty model_target";
   if(inputSchemaVersion == "")   return "empty input_schema_version";
   if(outputSchemaVersion == "")  return "empty output_schema_version";
   if(runtimeFramework == "")     return "empty runtime_framework";
   if(runtimeVersion == "")       return "empty runtime_version";
   return "";
}

// The B8.3 registration entry point. Returns true with outArtifact
// fully filled only on success. Returns false, with outArtifact left
// at ModelArtifact_Init() defaults, on any fail-closed condition.
bool ModelArtifact_Build(string modelId, string modelVersion, string modelArtifactHash,
                           string featureSchemaVersion, string trainingDatasetId, string trainingDatasetHash,
                           string modelTarget, string inputSchemaVersion, string outputSchemaVersion,
                           string runtimeFramework, string runtimeVersion,
                           ENUM_MODEL_PROMOTION_STATE promotionState, ModelArtifact &outArtifact)
{
   ModelArtifact_Init(outArtifact);

   if(ModelArtifactBuilder_ValidateInput(modelId, modelVersion, modelArtifactHash, featureSchemaVersion,
                                           trainingDatasetId, trainingDatasetHash, modelTarget,
                                           inputSchemaVersion, outputSchemaVersion, runtimeFramework, runtimeVersion) != "")
      return false;

   // Identity computed first - depends only on model_id + model_version.
   outArtifact.model_registry_id = Ids_ModelRegistryId(modelId, modelVersion);

   outArtifact.model_id      = modelId;
   outArtifact.model_version = modelVersion;

   outArtifact.model_artifact_hash = modelArtifactHash;

   outArtifact.feature_schema_version = featureSchemaVersion;
   outArtifact.training_dataset_id    = trainingDatasetId;
   outArtifact.training_dataset_hash  = trainingDatasetHash;
   outArtifact.model_target           = modelTarget;

   outArtifact.input_schema_version  = inputSchemaVersion;
   outArtifact.output_schema_version = outputSchemaVersion;

   outArtifact.runtime_framework = runtimeFramework;
   outArtifact.runtime_version   = runtimeVersion;

   outArtifact.promotion_state = promotionState;

   // Content hash computed last, over the finished struct.
   outArtifact.model_registry_hash = ModelArtifact_ComputeHash(outArtifact);

   return true;
}

// The B8.3 compatibility gate. Exact-match only (no coercion, no
// prefix/substring matching, no case-insensitivity), fail-closed on
// the first mismatch found, with a stable per-check reason. Checks
// exactly the one artifact passed in - never searches for or falls
// back to another.
bool ModelArtifact_CheckCompatibility(const ModelArtifact &artifact,
                                        string requestedFeatureSchemaVersion, string requestedModelTarget,
                                        string requestedInputSchemaVersion, string requestedOutputSchemaVersion,
                                        string requestedRuntimeFramework, string requestedRuntimeVersion,
                                        string &outReason)
{
   outReason = "";

   if(requestedFeatureSchemaVersion == "") { outReason = "empty requested_feature_schema_version"; return false; }
   if(requestedModelTarget == "")          { outReason = "empty requested_model_target"; return false; }
   if(requestedInputSchemaVersion == "")   { outReason = "empty requested_input_schema_version"; return false; }
   if(requestedOutputSchemaVersion == "")  { outReason = "empty requested_output_schema_version"; return false; }
   if(requestedRuntimeFramework == "")     { outReason = "empty requested_runtime_framework"; return false; }
   if(requestedRuntimeVersion == "")       { outReason = "empty requested_runtime_version"; return false; }

   if(artifact.model_registry_id == "") { outReason = "artifact is not a valid registered ModelArtifact"; return false; }

   if(artifact.promotion_state != MODEL_PROMOTION_PROMOTED)
   {
      outReason = "promotion_state is not PROMOTED (" + ModelPromotionStateToString(artifact.promotion_state) + ")";
      return false;
   }

   if(artifact.feature_schema_version != requestedFeatureSchemaVersion)
   { outReason = "feature_schema_version mismatch"; return false; }
   if(artifact.model_target != requestedModelTarget)
   { outReason = "model_target mismatch"; return false; }
   if(artifact.input_schema_version != requestedInputSchemaVersion)
   { outReason = "input_schema_version mismatch"; return false; }
   if(artifact.output_schema_version != requestedOutputSchemaVersion)
   { outReason = "output_schema_version mismatch"; return false; }
   if(artifact.runtime_framework != requestedRuntimeFramework)
   { outReason = "runtime_framework mismatch"; return false; }
   if(artifact.runtime_version != requestedRuntimeVersion)
   { outReason = "runtime_version mismatch"; return false; }

   return true;
}

#endif // __MLQUANTAI_MODELARTIFACTBUILDER_MQH__
