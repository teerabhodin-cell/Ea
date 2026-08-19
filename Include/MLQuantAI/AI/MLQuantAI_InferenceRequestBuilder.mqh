//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_InferenceRequestBuilder.mqh                |
//| Phase B8.4 Commit 1 (Tier A): InferenceRequest_Build() - the pure,  |
//| deterministic builder frozen in                                    |
//| Docs/PhaseB_B8_4_InferenceContract.md. Every field mandatory - no   |
//| "latest," no unpinned identity, no fallback. Never touches a        |
//| broker/history/tick call, never appends an event, never mutates its |
//| inputs.                                                              |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_INFERENCEREQUESTBUILDER_MQH__
#define __MLQUANTAI_INFERENCEREQUESTBUILDER_MQH__

#include "MLQuantAI_InferenceContract.mqh"

string InferenceRequestBuilder_ValidateInput(string modelId, string modelVersion,
                                                string featureSnapshotId, string featureSnapshotHash,
                                                string featureVectorHash, string featureSchemaVersion,
                                                string modelTarget, string inputSchemaVersion, string outputSchemaVersion,
                                                string runtimeFramework, string runtimeVersion)
{
   if(modelId == "")              return "empty model_id";
   if(modelVersion == "")         return "empty model_version";
   if(featureSnapshotId == "")    return "empty feature_snapshot_id";
   if(featureSnapshotHash == "")  return "empty feature_snapshot_hash";
   if(featureVectorHash == "")    return "empty feature_vector_hash";
   if(featureSchemaVersion == "") return "empty feature_schema_version";
   if(modelTarget == "")          return "empty model_target";
   if(inputSchemaVersion == "")   return "empty input_schema_version";
   if(outputSchemaVersion == "")  return "empty output_schema_version";
   if(runtimeFramework == "")     return "empty runtime_framework";
   if(runtimeVersion == "")       return "empty runtime_version";
   return "";
}

bool InferenceRequest_Build(string modelId, string modelVersion,
                              string featureSnapshotId, string featureSnapshotHash,
                              string featureVectorHash, string featureSchemaVersion,
                              string modelTarget, string inputSchemaVersion, string outputSchemaVersion,
                              string runtimeFramework, string runtimeVersion, InferenceRequest &outRequest)
{
   InferenceRequest_Init(outRequest);

   if(InferenceRequestBuilder_ValidateInput(modelId, modelVersion, featureSnapshotId, featureSnapshotHash,
                                              featureVectorHash, featureSchemaVersion, modelTarget,
                                              inputSchemaVersion, outputSchemaVersion, runtimeFramework, runtimeVersion) != "")
      return false;

   outRequest.model_id      = modelId;
   outRequest.model_version = modelVersion;

   outRequest.feature_snapshot_id    = featureSnapshotId;
   outRequest.feature_snapshot_hash  = featureSnapshotHash;
   outRequest.feature_vector_hash    = featureVectorHash;
   outRequest.feature_schema_version = featureSchemaVersion;

   outRequest.model_target          = modelTarget;
   outRequest.input_schema_version  = inputSchemaVersion;
   outRequest.output_schema_version = outputSchemaVersion;

   outRequest.runtime_framework = runtimeFramework;
   outRequest.runtime_version   = runtimeVersion;

   return true;
}

#endif // __MLQUANTAI_INFERENCEREQUESTBUILDER_MQH__
