//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_ModelArtifactProjection.mqh|
//| Phase B8.3: a read-only ModelArtifact registry projected from       |
//| persisted MODEL_ARTIFACT_REGISTERED lines, mirroring                |
//| MLQuantAI_RealizedOutcomeProjection.mqh's structure and hardening   |
//| discipline (required-field validation, payload-aware collision-vs- |
//| duplicate detection, EventStoreValidator-gated atomic rebuild). See |
//| Docs/PhaseB_B8_3_ModelRegistryContract.md for the full contract     |
//| this file implements.                                               |
//|                                                                    |
//| Strictly additive and read-only: no B5/B6/B7/B8.1/B8.2 sealed file |
//| touched, no live market/broker/account call, no ONNX/file-hash      |
//| call, no event append here (that's                                  |
//| MLQuantAI_ModelArtifactEventEmission.mqh). Unlike                    |
//| FeatureSnapshotProjection/RealizedOutcomeProjection, this projection|
//| has NO CandidateProjection prerequisite - a ModelArtifact is not     |
//| tied to any candidate at all, and its training-dataset lineage      |
//| fields have no in-store event to referentially verify against       |
//| (B8.2's TrainingDatasetManifest is an export file, never itself an   |
//| event) - a known, deliberate scope boundary, not an oversight. See  |
//| the contract doc's "Known, deliberate limitation" section.          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MODELARTIFACTPROJECTION_MQH__
#define __MLQUANTAI_MODELARTIFACTPROJECTION_MQH__

#include "MLQuantAI_EventStore.mqh"
#include "MLQuantAI_EventStoreValidator.mqh"
#include "../../AI/MLQuantAI_ModelArtifact.mqh"

#define MLQUANTAI_MODELARTIFACTPROJ_MAX_LINE_LENGTH 65536

struct ModelArtifactProjectionRecord
{
   string model_registry_schema_version;

   string model_registry_id;
   string model_id;
   string model_version;

   string model_artifact_hash;
   string model_registry_hash;

   string feature_schema_version;
   string training_dataset_id;
   string training_dataset_hash;
   string model_target;

   string input_schema_version;
   string output_schema_version;

   string runtime_framework;
   string runtime_version;

   ENUM_MODEL_PROMOTION_STATE promotion_state;

   long   source_sequence_number; // audit trail: which event this record came from
   string source_log_event_id;
};

void ModelArtifactProjectionRecord_Init(ModelArtifactProjectionRecord &r)
{
   r.model_registry_schema_version = "";

   r.model_registry_id = "";
   r.model_id = "";
   r.model_version = "";

   r.model_artifact_hash = "";
   r.model_registry_hash = "";

   r.feature_schema_version = "";
   r.training_dataset_id = "";
   r.training_dataset_hash = "";
   r.model_target = "";

   r.input_schema_version = "";
   r.output_schema_version = "";

   r.runtime_framework = "";
   r.runtime_version = "";

   r.promotion_state = MODEL_PROMOTION_DRAFT;

   r.source_sequence_number = 0;
   r.source_log_event_id = "";
}

ModelArtifactProjectionRecord g_ModelArtifactProj_Records[];
int                           g_ModelArtifactProj_Count = 0;

void ModelArtifactProjection_Reset()
{
   ArrayResize(g_ModelArtifactProj_Records, 0);
   g_ModelArtifactProj_Count = 0;
}

int ModelArtifactProjection_Count() { return g_ModelArtifactProj_Count; }

int ModelArtifactProjection_FindIndex(string modelRegistryId)
{
   for(int i = 0; i < g_ModelArtifactProj_Count; i++)
      if(g_ModelArtifactProj_Records[i].model_registry_id == modelRegistryId)
         return i;
   return -1;
}

bool ModelArtifactProjection_TryGet(string modelRegistryId, ModelArtifactProjectionRecord &out)
{
   int idx = ModelArtifactProjection_FindIndex(modelRegistryId);
   if(idx < 0) return false;
   out = g_ModelArtifactProj_Records[idx];
   return true;
}

bool ModelArtifactProjection_GetAt(int index, ModelArtifactProjectionRecord &out)
{
   if(index < 0 || index >= g_ModelArtifactProj_Count) return false;
   out = g_ModelArtifactProj_Records[index];
   return true;
}

void ModelArtifactProjection_AppendRecord(const ModelArtifactProjectionRecord &rec)
{
   int idx = g_ModelArtifactProj_Count;
   ArrayResize(g_ModelArtifactProj_Records, idx + 1);
   g_ModelArtifactProj_Records[idx] = rec;
   g_ModelArtifactProj_Count++;
}

// Live-session sync path - called directly by
// ModelArtifact_EmitModelArtifactRegistered right after a durable
// write, from the in-memory ModelArtifact struct itself. Does NOT
// re-check for an existing record - the emitter's own
// ModelArtifactProjection_TryGet guard already ensured this
// model_registry_id is new before writing.
void ModelArtifactProjection_ApplyLiveRecord(const ModelArtifact &a)
{
   ModelArtifactProjectionRecord rec;
   ModelArtifactProjectionRecord_Init(rec);
   rec.model_registry_schema_version = a.model_registry_schema_version;
   rec.model_registry_id              = a.model_registry_id;
   rec.model_id                        = a.model_id;
   rec.model_version                    = a.model_version;
   rec.model_artifact_hash               = a.model_artifact_hash;
   rec.model_registry_hash                = a.model_registry_hash;
   rec.feature_schema_version              = a.feature_schema_version;
   rec.training_dataset_id                  = a.training_dataset_id;
   rec.training_dataset_hash                 = a.training_dataset_hash;
   rec.model_target                           = a.model_target;
   rec.input_schema_version                    = a.input_schema_version;
   rec.output_schema_version                    = a.output_schema_version;
   rec.runtime_framework                         = a.runtime_framework;
   rec.runtime_version                            = a.runtime_version;
   rec.promotion_state                             = a.promotion_state;
   // source_sequence_number/source_log_event_id stay at Init()
   // defaults (0/"") for a live-applied record - the durable append
   // already happened via EventStore_LogSystem, which owns the real
   // seq/log_event_id assignment.
   ModelArtifactProjection_AppendRecord(rec);
}

//---------------------------------------------------------------------
// Validation helpers - mirrors RealizedOutcomeProjection's own ladder.
//---------------------------------------------------------------------
string ModelArtifactProjection_ValidateRequiredFields(string modelRegistryId, string modelId, string modelVersion,
                                                         string modelArtifactHash, string featureSchemaVersion,
                                                         string trainingDatasetId, string trainingDatasetHash,
                                                         string modelTarget, string inputSchemaVersion,
                                                         string outputSchemaVersion, string runtimeFramework,
                                                         string runtimeVersion)
{
   if(modelRegistryId == "")      return "missing model_registry_id";
   if(modelId == "")              return "missing model_id";
   if(modelVersion == "")         return "missing model_version";
   if(modelArtifactHash == "")    return "missing model_artifact_hash";
   if(featureSchemaVersion == "") return "missing feature_schema_version";
   if(trainingDatasetId == "")    return "missing training_dataset_id";
   if(trainingDatasetHash == "")  return "missing training_dataset_hash";
   if(modelTarget == "")          return "missing model_target";
   if(inputSchemaVersion == "")   return "missing input_schema_version";
   if(outputSchemaVersion == "")  return "missing output_schema_version";
   if(runtimeFramework == "")     return "missing runtime_framework";
   if(runtimeVersion == "")       return "missing runtime_version";
   return "";
}

//---------------------------------------------------------------------
// Applies one raw persisted line to the registry - the replay path.
// No referential-integrity step against another projection (see file
// header) - this is the whole rebuild, not just an ApplyLine layer
// under a WithCandidates-style wrapper.
//---------------------------------------------------------------------
bool ModelArtifactProjection_ApplyLine(string line, string &outReason)
{
   if(StringLen(line) > MLQUANTAI_MODELARTIFACTPROJ_MAX_LINE_LENGTH)
   {
      outReason = "line exceeds the defensive length bound - rejected before parsing";
      return false;
   }

   if(EventSerializer_HasKey(line, "type") &&
      EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_MODEL_ARTIFACT_REGISTERED))
   {
      outReason = "not a MODEL_ARTIFACT_REGISTERED event - skipped, not relevant to this projection";
      return true;
   }

   SystemEvent e;
   if(!EventSerializer_ParseSystem(line, e))
   {
      outReason = "not a parsable event line";
      return false;
   }

   string modelRegistryId       = EventSerializer_GetStr(line, "model_registry_id");
   string modelId                 = EventSerializer_GetStr(line, "model_id");
   string modelVersion              = EventSerializer_GetStr(line, "model_version");
   string modelArtifactHash           = EventSerializer_GetStr(line, "model_artifact_hash");
   string featureSchemaVersion          = EventSerializer_GetStr(line, "feature_schema_version");
   string trainingDatasetId               = EventSerializer_GetStr(line, "training_dataset_id");
   string trainingDatasetHash               = EventSerializer_GetStr(line, "training_dataset_hash");
   string modelTarget                         = EventSerializer_GetStr(line, "model_target");
   string inputSchemaVersion                    = EventSerializer_GetStr(line, "input_schema_version");
   string outputSchemaVersion                     = EventSerializer_GetStr(line, "output_schema_version");
   string runtimeFramework                          = EventSerializer_GetStr(line, "runtime_framework");
   string runtimeVersion                              = EventSerializer_GetStr(line, "runtime_version");
   string promotionStateStr                             = EventSerializer_GetStr(line, "promotion_state");
   string modelRegistryHash                               = EventSerializer_GetStr(line, "model_registry_hash");
   string schemaVersion                                     = EventSerializer_GetStr(line, "model_registry_schema_version");

   string fieldsErr = ModelArtifactProjection_ValidateRequiredFields(modelRegistryId, modelId, modelVersion,
                                                                        modelArtifactHash, featureSchemaVersion,
                                                                        trainingDatasetId, trainingDatasetHash,
                                                                        modelTarget, inputSchemaVersion,
                                                                        outputSchemaVersion, runtimeFramework, runtimeVersion);
   if(fieldsErr != "") { outReason = fieldsErr; return false; }
   if(modelRegistryHash == "") { outReason = "missing model_registry_hash"; return false; }
   if(promotionStateStr == "") { outReason = "missing promotion_state"; return false; }

   int existingIdx = ModelArtifactProjection_FindIndex(modelRegistryId);
   if(existingIdx >= 0)
   {
      if(g_ModelArtifactProj_Records[existingIdx].model_registry_hash == modelRegistryHash)
      {
         outReason = "duplicate model_registry_id - already registered with an identical model_registry_hash, not re-applied";
         return true;
      }
      outReason = StringFormat("model_registry_id collision: '%s' already registered with model_registry_hash '%s', "
                                "this line carries a DIFFERENT model_registry_hash '%s' - rejected as a conflict, not a duplicate",
                                modelRegistryId, g_ModelArtifactProj_Records[existingIdx].model_registry_hash, modelRegistryHash);
      return false;
   }

   ModelArtifactProjectionRecord rec;
   ModelArtifactProjectionRecord_Init(rec);
   rec.model_registry_schema_version = schemaVersion;
   rec.model_registry_id              = modelRegistryId;
   rec.model_id                        = modelId;
   rec.model_version                    = modelVersion;
   rec.model_artifact_hash               = modelArtifactHash;
   rec.model_registry_hash                = modelRegistryHash;
   rec.feature_schema_version              = featureSchemaVersion;
   rec.training_dataset_id                  = trainingDatasetId;
   rec.training_dataset_hash                 = trainingDatasetHash;
   rec.model_target                           = modelTarget;
   rec.input_schema_version                    = inputSchemaVersion;
   rec.output_schema_version                    = outputSchemaVersion;
   rec.runtime_framework                         = runtimeFramework;
   rec.runtime_version                            = runtimeVersion;
   rec.promotion_state                             = ModelPromotionStateFromString(promotionStateStr);
   rec.source_sequence_number                        = e.base.sequence_number;
   rec.source_log_event_id                             = e.base.log_event_id;

   ModelArtifactProjection_AppendRecord(rec);
   outReason = "applied - new model artifact registered";
   return true;
}

//---------------------------------------------------------------------
// A from-scratch rebuild. Gated on EventStoreValidator only - no
// second-projection prerequisite (see file header for why).
//---------------------------------------------------------------------
struct ModelArtifactProjectionReport
{
   bool   ok;
   int    lines_total;
   int    lines_applied;  // genuinely new artifacts registered
   int    lines_skipped;  // non-MODEL_ARTIFACT_REGISTERED lines, or idempotent duplicates
   int    lines_failed;   // malformed/corrupt/invalid MODEL_ARTIFACT_REGISTERED-typed lines
   string first_error;
};

void ModelArtifactProjectionReport_Init(ModelArtifactProjectionReport &r)
{
   r.ok = true;
   r.lines_total = 0;
   r.lines_applied = 0;
   r.lines_skipped = 0;
   r.lines_failed = 0;
   r.first_error = "";
}

ModelArtifactProjectionReport ModelArtifactProjection_RebuildFromFile(string fileName)
{
   ModelArtifactProjectionReport report;
   ModelArtifactProjectionReport_Init(report);

   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);
   report.lines_total = n;

   EventStoreValidationReport validation = EventStoreValidator_ValidateLines(lines);
   if(!validation.ok)
   {
      report.ok = false;
      report.first_error = "event store failed validation - rebuild refused, registry left unchanged: " + validation.first_error;
      return report;
   }

   ModelArtifactProjection_Reset();

   for(int i = 0; i < n; i++)
   {
      int beforeCount = ModelArtifactProjection_Count();
      string reason;
      bool applied = ModelArtifactProjection_ApplyLine(lines[i], reason);
      if(!applied)
      {
         report.ok = false;
         report.lines_failed++;
         if(report.first_error == "")
            report.first_error = StringFormat("line %d: %s", i, reason);
         continue;
      }
      if(ModelArtifactProjection_Count() > beforeCount)
         report.lines_applied++;
      else
         report.lines_skipped++;
   }
   return report;
}

#endif // __MLQUANTAI_MODELARTIFACTPROJECTION_MQH__
