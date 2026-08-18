//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_TrainingDatasetRow.mqh                   |
//| Phase B8.2 Commit 1: TrainingDatasetRow/TrainingDatasetManifest -  |
//| the supervised-training artifact, per                              |
//| Docs/PhaseB_B8_2_TrainingDatasetContract.md. A row references       |
//| its FeatureSnapshot/RiskPlan by identity/hash - it never copies the |
//| actual feature values or sizing outputs onto itself. No event      |
//| store rebuild/export orchestration here (that's Commit 2) - this   |
//| file only defines the shape, identity, content hash, and the       |
//| deterministic split policy.                                        |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_TRAININGDATASETROW_MQH__
#define __MLQUANTAI_TRAININGDATASETROW_MQH__

#include "../Core/MLQuantAI_ContractVersions.mqh"
#include "../Core/MLQuantAI_Ids.mqh"

enum ENUM_DATASET_SPLIT
{
   DATASET_SPLIT_TRAIN,
   DATASET_SPLIT_VALIDATION,
   DATASET_SPLIT_TEST
};

string DatasetSplitToString(ENUM_DATASET_SPLIT s)
{
   switch(s)
   {
      case DATASET_SPLIT_TRAIN:      return "TRAIN";
      case DATASET_SPLIT_VALIDATION: return "VALIDATION";
      case DATASET_SPLIT_TEST:       return "TEST";
      default:                       return "UNKNOWN";
   }
}

struct TrainingDatasetRow
{
   string dataset_schema_version;

   string dataset_row_id;    // identity

   string candidate_id;
   string candidate_hash;

   string feature_snapshot_id;
   string feature_snapshot_hash;
   string feature_vector_hash;
   string feature_schema_version;

   string risk_plan_id;
   string plan_hash;
   string sizing_rules_version;

   bool   label_available;
   string label_schema_version;
   string label;              // "" when label_available == false
   string outcome_reference;  // "" when label_available == false
   string outcome_hash;       // "" when label_available == false

   ENUM_DATASET_SPLIT split;
   string split_policy_version;
   string model_target;

   string row_hash;    // content integrity - computed last
};

void TrainingDatasetRow_Init(TrainingDatasetRow &r)
{
   r.dataset_schema_version = MLQUANTAI_DATASET_SCHEMA_B8_2_V1;

   r.dataset_row_id = "";

   r.candidate_id = "";
   r.candidate_hash = "";

   r.feature_snapshot_id = "";
   r.feature_snapshot_hash = "";
   r.feature_vector_hash = "";
   r.feature_schema_version = "";

   r.risk_plan_id = "";
   r.plan_hash = "";
   r.sizing_rules_version = "";

   r.label_available = false;
   r.label_schema_version = "";
   r.label = "";
   r.outcome_reference = "";
   r.outcome_hash = "";

   r.split = DATASET_SPLIT_TRAIN;
   r.split_policy_version = "";
   r.model_target = "";

   r.row_hash = "";
}

// A "full record" hash - lineage, label/outcome, split, and target
// together, the same sense B8.1's feature_snapshot_hash is a full
// record. There is no separate "pure content" hash the way
// FeatureSnapshot needed one, since the row itself IS the
// lineage-plus-label record.
string TrainingDatasetRow_HashPayload(const TrainingDatasetRow &row)
{
   string s = "";
   s += row.candidate_id + "|";
   s += row.candidate_hash + "|";
   s += row.feature_snapshot_id + "|";
   s += row.feature_snapshot_hash + "|";
   s += row.feature_vector_hash + "|";
   s += row.feature_schema_version + "|";
   s += row.risk_plan_id + "|";
   s += row.plan_hash + "|";
   s += row.sizing_rules_version + "|";
   s += (row.label_available ? "1" : "0") + "|";
   s += row.label_schema_version + "|";
   s += row.label + "|";
   s += row.outcome_reference + "|";
   s += row.outcome_hash + "|";
   s += DatasetSplitToString(row.split) + "|";
   s += row.split_policy_version + "|";
   s += row.model_target;
   return s;
}

string TrainingDatasetRow_ComputeHash(const TrainingDatasetRow &row)
{
   return Ids_Sha256Hex(TrainingDatasetRow_HashPayload(row));
}

// dataset_hash: Ids_Sha256Hex over every row_hash, joined in final
// (sorted) order - same style B6.2's CandidateDatasetExport_DatasetHash
// already established, so a reordering, insertion, deletion, or
// single-field change anywhere moves this one value.
string TrainingDatasetManifest_DatasetHash(const TrainingDatasetRow &rows[])
{
   string payload = "";
   for(int i = 0; i < ArraySize(rows); i++)
   {
      if(i > 0) payload += "|";
      payload += rows[i].row_hash;
   }
   return Ids_Sha256Hex(payload);
}

// Decodes exactly 8 hex characters into a ulong in [0, 2^32-1].
// MQL5's StringToInteger is not relied on for hex parsing - this
// small manual decode is guaranteed correct regardless of build.
ulong DatasetSplit_HexToUlong(string hex8)
{
   ulong v = 0;
   for(int i = 0; i < 8 && i < StringLen(hex8); i++)
   {
      ushort c = StringGetCharacter(hex8, i);
      int digit = 0;
      if(c >= '0' && c <= '9')      digit = c - '0';
      else if(c >= 'a' && c <= 'f') digit = c - 'a' + 10;
      else if(c >= 'A' && c <= 'F') digit = c - 'A' + 10;
      v = v * 16 + (ulong)digit;
   }
   return v;
}

// Deterministic, hash-derived split - keyed on candidate_id (not
// dataset_row_id), so the same underlying setup always lands in the
// same split even if it's labeled again later under a different
// label_schema_version or model_target. 70/15/15 is a plain default,
// versioned via splitPolicyVersion so changing the ratio later is a
// new constant, never a silent edit of what a version already means.
ENUM_DATASET_SPLIT TrainingDatasetSplit_Assign(string candidateId, string splitPolicyVersion)
{
   string h = Ids_Sha256Hex(candidateId + "|" + splitPolicyVersion);
   ulong bucket = DatasetSplit_HexToUlong(StringSubstr(h, 0, 8)) % 100; // 0..99
   if(bucket < 70) return DATASET_SPLIT_TRAIN;
   if(bucket < 85) return DATASET_SPLIT_VALIDATION;
   return DATASET_SPLIT_TEST;
}

struct TrainingDatasetManifest
{
   string dataset_schema_version;
   string dataset_id;
   string dataset_hash;
   string feature_schema_version;
   string label_schema_version;
   string split_policy_version;
   string model_target;
   int    row_count;
   int    train_count;
   int    validation_count;
   int    test_count;
   int    unlabeled_count;
   string source_store_fingerprint; // NOT populated by Commit 1 - see contract doc section 6
};

void TrainingDatasetManifest_Init(TrainingDatasetManifest &m)
{
   m.dataset_schema_version = MLQUANTAI_DATASET_SCHEMA_B8_2_V1;
   m.dataset_id = "";
   m.dataset_hash = "";
   m.feature_schema_version = "";
   m.label_schema_version = "";
   m.split_policy_version = "";
   m.model_target = "";
   m.row_count = 0;
   m.train_count = 0;
   m.validation_count = 0;
   m.test_count = 0;
   m.unlabeled_count = 0;
   m.source_store_fingerprint = "";
}

#endif // __MLQUANTAI_TRAININGDATASETROW_MQH__
