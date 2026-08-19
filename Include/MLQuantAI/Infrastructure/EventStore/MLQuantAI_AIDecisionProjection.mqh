//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_AIDecisionProjection.mqh|
//| Phase B8.5 Commit 2: a read-only AIDecision registry projected      |
//| from persisted AI_DECISION_CREATED lines, mirroring                 |
//| MLQuantAI_FeatureSnapshotProjection.mqh's exact structure and        |
//| hardening discipline (schema/required-field/numerical validation,    |
//| payload-aware collision-vs-duplicate detection, referential          |
//| integrity, EventStoreValidator-gated atomic rebuild). See            |
//| Docs/PhaseB_B8_5_AIDecisionContract.md's Commit 2 addendum for the    |
//| full contract this file implements.                                   |
//|                                                                    |
//| Strictly additive and read-only: no B5/B6/B7/B8.1/B8.2/B8.3/B8.4     |
//| sealed file touched, no live market/broker/account call, no ONNX      |
//| call, no event append here (that's                                    |
//| MLQuantAI_AIDecisionEventEmission.mqh). Unlike every prior projection |
//| in this project, AIDecision has TWO independent upstream lineage      |
//| chains to verify on replay - feature_snapshot_id/hash/vector_hash     |
//| (against FeatureSnapshotProjection) and model_registry_id/hash/       |
//| model_artifact_hash (against ModelArtifactProjection) - both are      |
//| rebuilt from the same file and checked, independently, before any     |
//| AI_DECISION_CREATED line is accepted.                                  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_AIDECISIONPROJECTION_MQH__
#define __MLQUANTAI_AIDECISIONPROJECTION_MQH__

#include "MLQuantAI_EventStore.mqh"
#include "MLQuantAI_EventStoreValidator.mqh"
#include "MLQuantAI_FeatureSnapshotProjection.mqh"
#include "MLQuantAI_ModelArtifactProjection.mqh"
#include "../../AI/MLQuantAI_AIDecisionContract.mqh"

#define MLQUANTAI_AIDECISIONPROJ_MAX_LINE_LENGTH 65536

struct AIDecisionProjectionRecord
{
   string ai_decision_schema_version;

   string ai_decision_id;
   string ai_decision_hash;

   string candidate_id;
   string candidate_hash;

   string feature_snapshot_id;
   string feature_snapshot_hash;
   string feature_vector_hash;

   string model_registry_id;
   string model_registry_hash;
   string model_artifact_hash;

   string inference_output_hash;
   string output_schema_version;
   string inference_contract_version;

   string decision_policy_version;
   string threshold_version;
   double allow_threshold;

   double p_success;

   ENUM_AI_DECISION_OUTCOME decision_outcome;
   ENUM_REASON_CODE         decision_reason_code;

   long   source_sequence_number; // audit trail: which event this record came from
   string source_log_event_id;
};

void AIDecisionProjectionRecord_Init(AIDecisionProjectionRecord &r)
{
   r.ai_decision_schema_version = "";

   r.ai_decision_id = "";
   r.ai_decision_hash = "";

   r.candidate_id = "";
   r.candidate_hash = "";

   r.feature_snapshot_id = "";
   r.feature_snapshot_hash = "";
   r.feature_vector_hash = "";

   r.model_registry_id = "";
   r.model_registry_hash = "";
   r.model_artifact_hash = "";

   r.inference_output_hash = "";
   r.output_schema_version = "";
   r.inference_contract_version = "";

   r.decision_policy_version = "";
   r.threshold_version = "";
   r.allow_threshold = 0.0;

   r.p_success = 0.0;

   r.decision_outcome = AI_DECISION_OUTCOME_NONE;
   r.decision_reason_code = REASON_NONE;

   r.source_sequence_number = 0;
   r.source_log_event_id = "";
}

AIDecisionProjectionRecord g_AIDecisionProj_Records[];
int                        g_AIDecisionProj_Count = 0;

void AIDecisionProjection_Reset()
{
   ArrayResize(g_AIDecisionProj_Records, 0);
   g_AIDecisionProj_Count = 0;
}

int AIDecisionProjection_Count() { return g_AIDecisionProj_Count; }

int AIDecisionProjection_FindIndex(string aiDecisionId)
{
   for(int i = 0; i < g_AIDecisionProj_Count; i++)
      if(g_AIDecisionProj_Records[i].ai_decision_id == aiDecisionId)
         return i;
   return -1;
}

bool AIDecisionProjection_TryGet(string aiDecisionId, AIDecisionProjectionRecord &out)
{
   int idx = AIDecisionProjection_FindIndex(aiDecisionId);
   if(idx < 0) return false;
   out = g_AIDecisionProj_Records[idx];
   return true;
}

bool AIDecisionProjection_GetAt(int index, AIDecisionProjectionRecord &out)
{
   if(index < 0 || index >= g_AIDecisionProj_Count) return false;
   out = g_AIDecisionProj_Records[index];
   return true;
}

void AIDecisionProjection_AppendRecord(const AIDecisionProjectionRecord &rec)
{
   int idx = g_AIDecisionProj_Count;
   ArrayResize(g_AIDecisionProj_Records, idx + 1);
   g_AIDecisionProj_Records[idx] = rec;
   g_AIDecisionProj_Count++;
}

// Live-session sync path - called directly by
// AIDecision_EmitAIDecisionCreated right after a durable write, from
// the in-memory AIDecision struct itself (no JSON round-trip needed,
// unlike the replay path below). Does NOT re-check for an existing
// record - the emitter's own AIDecisionProjection_TryGet guard already
// ensured this ai_decision_id is new before writing.
void AIDecisionProjection_ApplyLiveRecord(const AIDecision &d)
{
   AIDecisionProjectionRecord rec;
   AIDecisionProjectionRecord_Init(rec);
   rec.ai_decision_schema_version = d.ai_decision_schema_version;
   rec.ai_decision_id              = d.ai_decision_id;
   rec.ai_decision_hash             = d.ai_decision_hash;
   rec.candidate_id                  = d.candidate_id;
   rec.candidate_hash                 = d.candidate_hash;
   rec.feature_snapshot_id             = d.feature_snapshot_id;
   rec.feature_snapshot_hash            = d.feature_snapshot_hash;
   rec.feature_vector_hash               = d.feature_vector_hash;
   rec.model_registry_id                  = d.model_registry_id;
   rec.model_registry_hash                 = d.model_registry_hash;
   rec.model_artifact_hash                  = d.model_artifact_hash;
   rec.inference_output_hash                 = d.inference_output_hash;
   rec.output_schema_version                  = d.output_schema_version;
   rec.inference_contract_version              = d.inference_contract_version;
   rec.decision_policy_version                  = d.decision_policy_version;
   rec.threshold_version                         = d.threshold_version;
   rec.allow_threshold                            = d.allow_threshold;
   rec.p_success                                   = d.p_success;
   rec.decision_outcome                             = d.decision_outcome;
   rec.decision_reason_code                          = d.decision_reason_code;
   // source_sequence_number/source_log_event_id stay at Init() defaults
   // (0/"") for a live-applied record - the durable append already
   // happened via EventStore_LogSystem, which owns the real
   // seq/log_event_id assignment.
   AIDecisionProjection_AppendRecord(rec);
}

//---------------------------------------------------------------------
// Validation helpers - mirrors FeatureSnapshotProjection's own ladder.
//---------------------------------------------------------------------
string AIDecisionProjection_ValidateRequiredFields(string aiDecisionId, string aiDecisionHash, string candidateId,
                                                     string candidateHash, string featureSnapshotId, string featureSnapshotHash,
                                                     string featureVectorHash, string modelRegistryId, string modelRegistryHash,
                                                     string modelArtifactHash, string inferenceOutputHash, string outputSchemaVersion,
                                                     string inferenceContractVersion, string decisionPolicyVersion,
                                                     string thresholdVersion, string aiDecisionSchemaVersion)
{
   if(aiDecisionId == "")               return "missing ai_decision_id";
   if(aiDecisionHash == "")              return "missing ai_decision_hash";
   if(candidateId == "")                  return "missing candidate_id";
   if(candidateHash == "")                 return "missing candidate_hash";
   if(featureSnapshotId == "")              return "missing feature_snapshot_id";
   if(featureSnapshotHash == "")             return "missing feature_snapshot_hash";
   if(featureVectorHash == "")                return "missing feature_vector_hash";
   if(modelRegistryId == "")                   return "missing model_registry_id";
   if(modelRegistryHash == "")                  return "missing model_registry_hash";
   if(modelArtifactHash == "")                   return "missing model_artifact_hash";
   if(inferenceOutputHash == "")                  return "missing inference_output_hash";
   if(outputSchemaVersion == "")                   return "missing output_schema_version";
   if(inferenceContractVersion == "")                return "missing inference_contract_version";
   if(decisionPolicyVersion == "")                    return "missing decision_policy_version";
   if(thresholdVersion == "")                           return "missing threshold_version";
   if(aiDecisionSchemaVersion == "")                     return "missing ai_decision_schema_version";
   return "";
}

string AIDecisionProjection_ValidateNumericalIntegrity(double allowThreshold, double pSuccess)
{
   if(!MathIsValidNumber(allowThreshold) || allowThreshold < 0.0 || allowThreshold > 1.0)
      return "allow_threshold is not finite or not in [0,1]";
   if(!MathIsValidNumber(pSuccess) || pSuccess < 0.0 || pSuccess > 1.0)
      return "p_success is not finite or not in [0,1]";
   return "";
}

//---------------------------------------------------------------------
// Applies one raw persisted line to the registry - the replay path.
// Structural/schema validation only; the two referential-integrity
// checks (FeatureSnapshotProjection, ModelArtifactProjection) live in
// AIDecisionProjection_ApplyLineWithLineage below, which wraps this.
//---------------------------------------------------------------------
bool AIDecisionProjection_ApplyLine(string line, string &outReason)
{
   if(StringLen(line) > MLQUANTAI_AIDECISIONPROJ_MAX_LINE_LENGTH)
   {
      outReason = "line exceeds the defensive length bound - rejected before parsing";
      return false;
   }

   if(EventSerializer_HasKey(line, "type") &&
      EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_AI_DECISION_CREATED))
   {
      outReason = "not an AI_DECISION_CREATED event - skipped, not relevant to this projection";
      return true;
   }

   SystemEvent e;
   if(!EventSerializer_ParseSystem(line, e))
   {
      outReason = "not a parsable event line";
      return false;
   }

   string aiDecisionSchemaVersion = EventSerializer_GetStr(line, "ai_decision_schema_version");
   string aiDecisionId             = EventSerializer_GetStr(line, "ai_decision_id");
   string aiDecisionHash            = EventSerializer_GetStr(line, "ai_decision_hash");
   string candidateId                = EventSerializer_GetStr(line, "candidate_id");
   string candidateHash               = EventSerializer_GetStr(line, "candidate_hash");
   string featureSnapshotId             = EventSerializer_GetStr(line, "feature_snapshot_id");
   string featureSnapshotHash            = EventSerializer_GetStr(line, "feature_snapshot_hash");
   string featureVectorHash               = EventSerializer_GetStr(line, "feature_vector_hash");
   string modelRegistryId                   = EventSerializer_GetStr(line, "model_registry_id");
   string modelRegistryHash                   = EventSerializer_GetStr(line, "model_registry_hash");
   string modelArtifactHash                     = EventSerializer_GetStr(line, "model_artifact_hash");
   string inferenceOutputHash                     = EventSerializer_GetStr(line, "inference_output_hash");
   string outputSchemaVersion                       = EventSerializer_GetStr(line, "output_schema_version");
   string inferenceContractVersion                    = EventSerializer_GetStr(line, "inference_contract_version");
   string decisionPolicyVersion                         = EventSerializer_GetStr(line, "decision_policy_version");
   string thresholdVersion                                = EventSerializer_GetStr(line, "threshold_version");

   string fieldsErr = AIDecisionProjection_ValidateRequiredFields(aiDecisionId, aiDecisionHash, candidateId, candidateHash,
                                                                     featureSnapshotId, featureSnapshotHash, featureVectorHash,
                                                                     modelRegistryId, modelRegistryHash, modelArtifactHash,
                                                                     inferenceOutputHash, outputSchemaVersion,
                                                                     inferenceContractVersion, decisionPolicyVersion,
                                                                     thresholdVersion, aiDecisionSchemaVersion);
   if(fieldsErr != "") { outReason = fieldsErr; return false; }

   double allowThreshold = EventSerializer_GetDouble(line, "allow_threshold");
   double pSuccess          = EventSerializer_GetDouble(line, "p_success");

   string numErr = AIDecisionProjection_ValidateNumericalIntegrity(allowThreshold, pSuccess);
   if(numErr != "") { outReason = numErr; return false; }

   string decisionOutcomeStr    = EventSerializer_GetStr(line, "decision_outcome");
   string decisionReasonCodeStr = EventSerializer_GetStr(line, "decision_reason_code");
   if(decisionOutcomeStr == "")    { outReason = "missing decision_outcome"; return false; }
   if(decisionReasonCodeStr == "") { outReason = "missing decision_reason_code"; return false; }

   int existingIdx = AIDecisionProjection_FindIndex(aiDecisionId);
   if(existingIdx >= 0)
   {
      if(g_AIDecisionProj_Records[existingIdx].ai_decision_hash == aiDecisionHash)
      {
         outReason = "duplicate ai_decision_id - already registered with an identical ai_decision_hash, not re-applied";
         return true;
      }
      outReason = StringFormat("ai_decision_id collision: '%s' already registered with ai_decision_hash '%s', "
                                "this line carries a DIFFERENT ai_decision_hash '%s' - rejected as a conflict, not a duplicate",
                                aiDecisionId, g_AIDecisionProj_Records[existingIdx].ai_decision_hash, aiDecisionHash);
      return false;
   }

   AIDecisionProjectionRecord rec;
   AIDecisionProjectionRecord_Init(rec);
   rec.ai_decision_schema_version = aiDecisionSchemaVersion;
   rec.ai_decision_id              = aiDecisionId;
   rec.ai_decision_hash             = aiDecisionHash;
   rec.candidate_id                  = candidateId;
   rec.candidate_hash                 = candidateHash;
   rec.feature_snapshot_id             = featureSnapshotId;
   rec.feature_snapshot_hash            = featureSnapshotHash;
   rec.feature_vector_hash               = featureVectorHash;
   rec.model_registry_id                  = modelRegistryId;
   rec.model_registry_hash                 = modelRegistryHash;
   rec.model_artifact_hash                  = modelArtifactHash;
   rec.inference_output_hash                 = inferenceOutputHash;
   rec.output_schema_version                  = outputSchemaVersion;
   rec.inference_contract_version              = inferenceContractVersion;
   rec.decision_policy_version                  = decisionPolicyVersion;
   rec.threshold_version                         = thresholdVersion;
   rec.allow_threshold                            = allowThreshold;
   rec.p_success                                   = pSuccess;
   rec.decision_outcome                             = AiDecisionOutcomeFromString(decisionOutcomeStr);
   rec.decision_reason_code                          = ReasonCodeFromString(decisionReasonCodeStr);
   rec.source_sequence_number                         = e.base.sequence_number;
   rec.source_log_event_id                             = e.base.log_event_id;

   AIDecisionProjection_AppendRecord(rec);
   outReason = "applied - new AI decision registered";
   return true;
}

// Referential-integrity-aware variant used by RebuildFromFile: rejects
// an AI_DECISION_CREATED line whose feature-snapshot lineage doesn't
// resolve in FeatureSnapshotProjection, or whose model-registry lineage
// doesn't resolve in ModelArtifactProjection - both already rebuilt
// from the SAME file - BEFORE ever calling AIDecisionProjection_ApplyLine,
// so a referentially-broken decision never reaches the registry
// regardless of how well-formed it otherwise looks. Every other line
// type is passed straight through to ApplyLine unchanged.
bool AIDecisionProjection_ApplyLineWithLineage(string line, string &outReason)
{
   if(EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_AI_DECISION_CREATED))
      return AIDecisionProjection_ApplyLine(line, outReason);

   string featureSnapshotId     = EventSerializer_GetStr(line, "feature_snapshot_id");
   string featureSnapshotHash    = EventSerializer_GetStr(line, "feature_snapshot_hash");
   string featureVectorHash       = EventSerializer_GetStr(line, "feature_vector_hash");
   string candidateId               = EventSerializer_GetStr(line, "candidate_id");
   string candidateHash              = EventSerializer_GetStr(line, "candidate_hash");

   FeatureSnapshotProjectionRecord snapRecord;
   if(!FeatureSnapshotProjection_TryGet(featureSnapshotId, snapRecord))
   {
      outReason = "orphan AI decision: feature_snapshot_id '" + featureSnapshotId + "' has no matching FEATURE_SNAPSHOT_CREATED event in this store - rejected";
      return false;
   }
   if(snapRecord.feature_snapshot_hash != featureSnapshotHash ||
      snapRecord.feature_vector_hash != featureVectorHash ||
      snapRecord.candidate_id != candidateId ||
      snapRecord.candidate_hash != candidateHash)
   {
      outReason = "feature-snapshot lineage mismatch: AI decision's feature_snapshot_hash/feature_vector_hash/candidate_id/candidate_hash "
                  "does not match the referenced FeatureSnapshotProjection record - rejected";
      return false;
   }

   string modelRegistryId     = EventSerializer_GetStr(line, "model_registry_id");
   string modelRegistryHash    = EventSerializer_GetStr(line, "model_registry_hash");
   string modelArtifactHash     = EventSerializer_GetStr(line, "model_artifact_hash");

   ModelArtifactProjectionRecord modelRecord;
   if(!ModelArtifactProjection_TryGet(modelRegistryId, modelRecord))
   {
      outReason = "orphan AI decision: model_registry_id '" + modelRegistryId + "' has no matching MODEL_ARTIFACT_REGISTERED event in this store - rejected";
      return false;
   }
   if(modelRecord.model_registry_hash != modelRegistryHash || modelRecord.model_artifact_hash != modelArtifactHash)
   {
      outReason = "model-registry lineage mismatch: AI decision's model_registry_hash/model_artifact_hash "
                  "does not match the referenced ModelArtifactProjection record - rejected";
      return false;
   }

   return AIDecisionProjection_ApplyLine(line, outReason);
}

//---------------------------------------------------------------------
// A from-scratch rebuild. Gated on EventStoreValidator first, THEN on
// BOTH FeatureSnapshotProjection and ModelArtifactProjection being
// successfully rebuilt from the SAME file (two independent upstream
// chains - see this file's header) - if any of the three fails, THIS
// registry is left completely untouched.
//---------------------------------------------------------------------
struct AIDecisionProjectionReport
{
   bool   ok;
   int    lines_total;
   int    lines_applied;  // genuinely new decisions registered
   int    lines_skipped;  // non-AI_DECISION_CREATED lines, or idempotent duplicates
   int    lines_failed;   // malformed/corrupt/invalid/orphaned AI_DECISION_CREATED-typed lines
   string first_error;
};

void AIDecisionProjectionReport_Init(AIDecisionProjectionReport &r)
{
   r.ok = true;
   r.lines_total = 0;
   r.lines_applied = 0;
   r.lines_skipped = 0;
   r.lines_failed = 0;
   r.first_error = "";
}

AIDecisionProjectionReport AIDecisionProjection_RebuildFromFile(string fileName)
{
   AIDecisionProjectionReport report;
   AIDecisionProjectionReport_Init(report);

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

   FeatureSnapshotProjectionReport snapReport = FeatureSnapshotProjection_RebuildFromFile(fileName);
   if(!snapReport.ok)
   {
      report.ok = false;
      report.first_error = "feature snapshot registry failed to rebuild from the same store - rebuild refused, registry left unchanged: " + snapReport.first_error;
      return report;
   }

   ModelArtifactProjectionReport modelReport = ModelArtifactProjection_RebuildFromFile(fileName);
   if(!modelReport.ok)
   {
      report.ok = false;
      report.first_error = "model artifact registry failed to rebuild from the same store - rebuild refused, registry left unchanged: " + modelReport.first_error;
      return report;
   }

   AIDecisionProjection_Reset();

   for(int i = 0; i < n; i++)
   {
      int beforeCount = AIDecisionProjection_Count();
      string reason;
      bool applied = AIDecisionProjection_ApplyLineWithLineage(lines[i], reason);
      if(!applied)
      {
         report.ok = false;
         report.lines_failed++;
         if(report.first_error == "")
            report.first_error = StringFormat("line %d: %s", i, reason);
         continue;
      }
      if(AIDecisionProjection_Count() > beforeCount)
         report.lines_applied++;
      else
         report.lines_skipped++;
   }
   return report;
}

#endif // __MLQUANTAI_AIDECISIONPROJECTION_MQH__
