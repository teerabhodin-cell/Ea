//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_ModelArtifact.mqh                        |
//| Phase B8.3: ModelArtifact - immutable, declared model metadata,    |
//| per Docs/PhaseB_B8_3_ModelRegistryContract.md. Two distinct        |
//| hashes: model_artifact_hash is EXTERNAL evidence (the real trained |
//| model file's own hash, supplied by whatever exported it - this    |
//| file never loads or hashes file bytes); model_registry_hash is     |
//| INTERNAL, computed last over the finished struct, for the          |
//| registry's own collision/replay integrity.                          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MODELARTIFACT_MQH__
#define __MLQUANTAI_MODELARTIFACT_MQH__

#include "../Core/MLQuantAI_ContractVersions.mqh"
#include "../Core/MLQuantAI_Ids.mqh"

enum ENUM_MODEL_PROMOTION_STATE
{
   MODEL_PROMOTION_DRAFT,     // registered, not yet validated
   MODEL_PROMOTION_STAGING,   // under validation/backtest - not live-eligible
   MODEL_PROMOTION_PROMOTED,  // approved - the ONLY state that passes compatibility
   MODEL_PROMOTION_RETIRED    // no longer eligible - kept for audit/history
};

string ModelPromotionStateToString(ENUM_MODEL_PROMOTION_STATE s)
{
   switch(s)
   {
      case MODEL_PROMOTION_DRAFT:     return "DRAFT";
      case MODEL_PROMOTION_STAGING:   return "STAGING";
      case MODEL_PROMOTION_PROMOTED:  return "PROMOTED";
      case MODEL_PROMOTION_RETIRED:   return "RETIRED";
      default:                        return "UNKNOWN";
   }
}

ENUM_MODEL_PROMOTION_STATE ModelPromotionStateFromString(string s)
{
   if(s == "DRAFT")    return MODEL_PROMOTION_DRAFT;
   if(s == "STAGING")  return MODEL_PROMOTION_STAGING;
   if(s == "PROMOTED") return MODEL_PROMOTION_PROMOTED;
   if(s == "RETIRED")  return MODEL_PROMOTION_RETIRED;
   return MODEL_PROMOTION_DRAFT;
}

struct ModelArtifact
{
   string model_registry_schema_version; // MLQUANTAI_MODEL_REGISTRY_SCHEMA_B8_3_V1

   string model_registry_id;   // identity - Ids_ModelRegistryId(model_id, model_version)
   string model_id;
   string model_version;

   string model_artifact_hash; // EXTERNAL evidence hash of the real model file
   string model_registry_hash; // INTERNAL full-record content hash - computed last

   string feature_schema_version;
   string training_dataset_id;
   string training_dataset_hash;
   string model_target;

   string input_schema_version;
   string output_schema_version;

   string runtime_framework;
   string runtime_version;

   ENUM_MODEL_PROMOTION_STATE promotion_state;
};

void ModelArtifact_Init(ModelArtifact &a)
{
   a.model_registry_schema_version = MLQUANTAI_MODEL_REGISTRY_SCHEMA_B8_3_V1;

   a.model_registry_id = "";
   a.model_id = "";
   a.model_version = "";

   a.model_artifact_hash = "";
   a.model_registry_hash = "";

   a.feature_schema_version = "";
   a.training_dataset_id = "";
   a.training_dataset_hash = "";
   a.model_target = "";

   a.input_schema_version = "";
   a.output_schema_version = "";

   a.runtime_framework = "";
   a.runtime_version = "";

   a.promotion_state = MODEL_PROMOTION_DRAFT;
}

// Excludes only model_registry_id (identity, not content). Deliberate
// departure from the RiskPlan/TrainingDatasetRow precedent of also
// excluding the struct's own schema-version field - here
// model_registry_schema_version IS included, so a future schema-shape
// bump moves this hash even with every other field unchanged. See
// Docs/PhaseB_B8_3_ModelRegistryContract.md's "two hashes" section.
string ModelArtifact_HashPayload(const ModelArtifact &a)
{
   return a.model_id + "|" +
          a.model_version + "|" +
          a.model_artifact_hash + "|" +
          a.feature_schema_version + "|" +
          a.training_dataset_id + "|" +
          a.training_dataset_hash + "|" +
          a.model_target + "|" +
          a.input_schema_version + "|" +
          a.output_schema_version + "|" +
          a.runtime_framework + "|" +
          a.runtime_version + "|" +
          ModelPromotionStateToString(a.promotion_state) + "|" +
          a.model_registry_schema_version;
}

string ModelArtifact_ComputeHash(const ModelArtifact &a)
{
   return Ids_Sha256Hex(ModelArtifact_HashPayload(a));
}

#endif // __MLQUANTAI_MODELARTIFACT_MQH__
