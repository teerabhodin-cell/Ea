//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_TrainingDatasetManifestRecord.mqh         |
//| B8.6 Commit 1 (QA-frozen, Docs/PhaseB_B8_6_                        |
//| ModelTrainingInferenceIntegrationContract.md §5): the durable          |
//| identity/provenance record for one training-dataset export -             |
//| TRAINING-ELIGIBLE population only (§3.0), never the broader export         |
//| population. A DIFFERENT struct from TrainingDatasetManifest (B8.2,          |
//| MLQuantAI_TrainingDatasetRow.mqh, unchanged, untouched) - that one is the     |
//| in-memory row/train/validation/test-count summary; this one is the durable     |
//| dataset_id/dataset_hash identity evidence B8.3's ModelArtifact.training_         |
//| dataset_id/training_dataset_hash can be checked against (see                       |
//| MLQuantAI_ModelArtifactLineageVerify.mqh).                                            |
//|                                                                                          |
//| Pure: no EventStore write here (that's                                                   |
//| Infrastructure/EventStore/MLQuantAI_TrainingDatasetManifestEventEmission.mqh),              |
//| no live MT5 API. dataset_hash itself is NOT computed here - per §5.5, it is                  |
//| the EXISTING, SEALED TrainingDatasetManifest_DatasetHash() (MLQuantAI_                          |
//| TrainingDatasetRow.mqh, unmodified) applied to the caller's own candidate_id-                     |
//| ascending-sorted eligible row array - reused, never reinvented, since that                          |
//| function already hashes each row's row_hash (which already bakes in                                    |
//| DatasetSplitToString(row.split) per its own sealed TrainingDatasetRow_                                    |
//| HashPayload) in exactly the "content, split included" sense §5.5 requires.                                  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_TRAININGDATASETMANIFESTRECORD_MQH__
#define __MLQUANTAI_TRAININGDATASETMANIFESTRECORD_MQH__

#include "../Core/MLQuantAI_Ids.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh"

// Defined locally rather than added to Core/MLQuantAI_ContractVersions.mqh,
// which is not in the B8.6 contract's Class 1/Class 2 list - same
// precedent as MLQUANTAI_DATASET_SPLIT_POLICY_CHRONOLOGICAL_V1.
#define MLQUANTAI_TRAINING_DATASET_MANIFEST_SCHEMA_V1  "TRAINING_DATASET_MANIFEST_B8_6_V1"

struct TrainingDatasetManifestRecord
{
   string   training_dataset_schema_version;
   string   dataset_id;
   string   dataset_hash;
   string   split_policy_version;
   string   label_schema_version;
   string   model_target;
   int      row_count;          // TRAINING-ELIGIBLE population size only (§3.0)
   datetime export_server_time; // TimeCurrent() at export - server-time discipline (C3.8 §5)
};

void TrainingDatasetManifestRecord_Init(TrainingDatasetManifestRecord &r)
{
   r.training_dataset_schema_version = MLQUANTAI_TRAINING_DATASET_MANIFEST_SCHEMA_V1;
   r.dataset_id = "";
   r.dataset_hash = "";
   r.split_policy_version = "";
   r.label_schema_version = "";
   r.model_target = "";
   r.row_count = 0;
   r.export_server_time = 0;
}

// §5.4 (frozen): sorts its OWN copy of candidateIds ascending internally -
// the caller does not need to pre-sort, removing any ambiguity about whose
// job that is. Deterministic regardless of input order.
string TrainingDatasetManifestRecord_ComputeDatasetId(const string &candidateIds[], string splitPolicyVersion,
                                                          string labelSchemaVersion, string modelTarget)
{
   int n = ArraySize(candidateIds);
   string sorted[];
   ArrayResize(sorted, n);
   for(int i = 0; i < n; i++) sorted[i] = candidateIds[i];

   // simple insertion sort - export-population scale, not tick-scale,
   // same "simple, obviously correct" tradeoff as
   // DatasetSplitChronological_SortIndices.
   for(int i = 1; i < n; i++)
   {
      string key = sorted[i];
      int j = i - 1;
      while(j >= 0 && sorted[j] > key)
      {
         sorted[j + 1] = sorted[j];
         j--;
      }
      sorted[j + 1] = key;
   }

   string payload = "";
   for(int i = 0; i < n; i++)
   {
      if(i > 0) payload += "|";
      payload += sorted[i];
   }
   payload += "||" + splitPolicyVersion + "|" + labelSchemaVersion + "|" + modelTarget;
   return Ids_Sha256Hex(payload);
}

enum ENUM_TRAINING_DATASET_IDEMPOTENCY
{
   TRAINING_DATASET_IDEMPOTENCY_NONE_FOUND,
   TRAINING_DATASET_IDEMPOTENCY_DUPLICATE_SAME_HASH,
   TRAINING_DATASET_IDEMPOTENCY_COLLISION_DIFFERENT_HASH
};

// §5.6 (frozen, CORRECTED per QA's pre-push diff audit): scans EVERY
// already-loaded durable line matching dataset_id, never stopping at the
// first match. The original version returned as soon as it found ONE
// matching line, so a durable log with two TRAINING_DATASET_CREATED lines
// sharing one dataset_id - the very corruption case this function exists
// to catch - could be silently reported as DUPLICATE_SAME_HASH whenever
// the first-encountered line happened to match, never inspecting a later,
// genuinely conflicting line. Fixed: a mismatch found ANYWHERE is a
// collision (safe to short-circuit on, since collision is already the
// "worst" of the three outcomes - no later line could soften it), but a
// match is never treated as conclusive until every line has been checked.
// Pure - no write, no Safe Mode (that policy decision belongs to the
// emission layer, MLQuantAI_TrainingDatasetManifestEventEmission.mqh, not
// here).
ENUM_TRAINING_DATASET_IDEMPOTENCY TrainingDatasetManifestRecord_CheckIdempotency(const TrainingDatasetManifestRecord &rec, const string &lines[])
{
   bool foundAny = false;
   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != "TRAINING_DATASET_CREATED") continue;
      if(EventSerializer_GetStr(lines[i], "dataset_id") != rec.dataset_id) continue;

      foundAny = true;
      string existingHash = EventSerializer_GetStr(lines[i], "dataset_hash");
      if(existingHash != rec.dataset_hash)
         return TRAINING_DATASET_IDEMPOTENCY_COLLISION_DIFFERENT_HASH; // any mismatch, anywhere in the scan, is decisive
   }
   if(!foundAny) return TRAINING_DATASET_IDEMPOTENCY_NONE_FOUND;
   return TRAINING_DATASET_IDEMPOTENCY_DUPLICATE_SAME_HASH; // every matching line (at least one) agreed
}

#endif // __MLQUANTAI_TRAININGDATASETMANIFESTRECORD_MQH__
