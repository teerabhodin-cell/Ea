//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_ModelInference.mqh|
//| Phase B8.4 Commit 1 (Tier A): ModelInference_ResolveAndPrepare() +  |
//| ModelInference_ValidateAndBuildResult() - two pure, testable        |
//| halves either side of a real runtime call, per                     |
//| Docs/PhaseB_B8_4_InferenceContract.md. No single "run inference"    |
//| function exists here - Tier A never calls a real runtime, so a      |
//| function that pretended to "run" one would misrepresent what        |
//| actually happens. Neither function loads ONNX, touches a broker/    |
//| history/tick call, appends an event, or mutates its inputs.          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MODELINFERENCE_MQH__
#define __MLQUANTAI_MODELINFERENCE_MQH__

#include "MLQuantAI_ModelRegistryCompatibility.mqh"
#include "../../AI/MLQuantAI_InferenceRequestBuilder.mqh"
#include "../../AI/MLQuantAI_CanonicalFeatureVector.mqh"
#include "../../AI/MLQuantAI_InferenceOutputValidator.mqh"

// Phase 1: resolve the request's declared model against the B8.3
// registry, cross-check the supplied FeatureSnapshot against what the
// request pins, and build the canonical input vector. Returns true
// with outArtifact/outCanonicalVector filled only on success; on
// failure outCanonicalVector is emptied and outReasonCode/outReasonDetail
// explain why.
bool ModelInference_ResolveAndPrepare(const InferenceRequest &request, const FeatureSnapshot &snapshot,
                                        ModelArtifact &outArtifact, float &outCanonicalVector[],
                                        ENUM_INFERENCE_FAIL_REASON &outReasonCode, string &outReasonDetail)
{
   ModelArtifact_Init(outArtifact);
   ArrayResize(outCanonicalVector, 0);
   outReasonCode = INFERENCE_FAIL_NONE;
   outReasonDetail = "";

   if(InferenceRequestBuilder_ValidateInput(request.model_id, request.model_version,
                                              request.feature_snapshot_id, request.feature_snapshot_hash,
                                              request.feature_vector_hash, request.feature_schema_version,
                                              request.model_target, request.input_schema_version,
                                              request.output_schema_version, request.runtime_framework,
                                              request.runtime_version) != "")
   {
      outReasonCode = MODEL_INCOMPATIBLE; // a malformed request never reaches the registry lookup at all
      outReasonDetail = "InferenceRequest has one or more empty mandatory fields";
      return false;
   }

   ModelArtifact resolvedArtifact;
   string registryReason;
   if(!ModelRegistry_FindCompatible(request.model_id, request.model_version,
                                      request.feature_schema_version, request.model_target,
                                      request.input_schema_version, request.output_schema_version,
                                      request.runtime_framework, request.runtime_version,
                                      resolvedArtifact, registryReason))
   {
      if(registryReason == "model artifact not found in registry")
         outReasonCode = MODEL_NOT_FOUND;
      else if(StringFind(registryReason, "promotion_state") >= 0)
         outReasonCode = MODEL_NOT_PROMOTED;
      else
         outReasonCode = MODEL_INCOMPATIBLE;
      outReasonDetail = registryReason;
      return false;
   }

   // Referential consistency against the supplied live FeatureSnapshot
   // - no event-store dependency, the same "validate against the
   // struct you were actually given" rule BuildTrainingDatasetRow
   // already uses for its own candidate/snapshot/plan cross-checks.
   if(snapshot.feature_snapshot_id != request.feature_snapshot_id ||
      snapshot.feature_snapshot_hash != request.feature_snapshot_hash ||
      snapshot.feature_vector_hash != request.feature_vector_hash)
   {
      outReasonCode = INPUT_SCHEMA_MISMATCH;
      outReasonDetail = "the supplied FeatureSnapshot does not match the identity/hash the request pins";
      return false;
   }

   float canonicalVector[];
   ENUM_INFERENCE_FAIL_REASON vectorReasonCode;
   string vectorReasonDetail;
   if(!CanonicalFeatureVector_FromSnapshot(snapshot, request.feature_schema_version,
                                             canonicalVector, vectorReasonCode, vectorReasonDetail))
   {
      outReasonCode = vectorReasonCode;
      outReasonDetail = vectorReasonDetail;
      return false;
   }

   outArtifact = resolvedArtifact;
   ArrayResize(outCanonicalVector, ArraySize(canonicalVector));
   for(int i = 0; i < ArraySize(canonicalVector); i++)
      outCanonicalVector[i] = canonicalVector[i];

   return true;
}

// Phase 2: validate a typed output vector (caller-supplied in Tier A -
// a fixture standing in for whatever a real runtime will eventually
// produce) and assemble the finished InferenceResult. Returns true
// with outResult fully filled only on success; on failure outResult
// is left at InferenceResult_Init() defaults.
bool ModelInference_ValidateAndBuildResult(const InferenceRequest &request, const ModelArtifact &artifact,
                                             const float &rawOutputValues[], InferenceResult &outResult,
                                             ENUM_INFERENCE_FAIL_REASON &outReasonCode, string &outReasonDetail)
{
   InferenceResult_Init(outResult);
   outReasonCode = INFERENCE_FAIL_NONE;
   outReasonDetail = "";

   if(!InferenceOutput_Validate(rawOutputValues, request.output_schema_version, outReasonCode, outReasonDetail))
      return false;

   outResult.model_registry_id  = artifact.model_registry_id;
   outResult.model_registry_hash = artifact.model_registry_hash;
   outResult.model_artifact_hash  = artifact.model_artifact_hash;

   outResult.feature_snapshot_id   = request.feature_snapshot_id;
   outResult.feature_snapshot_hash = request.feature_snapshot_hash;
   outResult.feature_vector_hash   = request.feature_vector_hash;

   outResult.output_schema_version = request.output_schema_version;
   ArrayResize(outResult.output_values, ArraySize(rawOutputValues));
   for(int i = 0; i < ArraySize(rawOutputValues); i++)
      outResult.output_values[i] = rawOutputValues[i];

   outResult.runtime_framework = request.runtime_framework;
   outResult.runtime_version   = request.runtime_version;

   outResult.output_hash = InferenceResult_ComputeOutputHash(outResult);

   return true;
}

#endif // __MLQUANTAI_MODELINFERENCE_MQH__
