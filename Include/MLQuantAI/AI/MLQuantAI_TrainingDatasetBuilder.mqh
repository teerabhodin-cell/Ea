//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_TrainingDatasetBuilder.mqh                |
//| Phase B8.2 Commit 1: BuildTrainingDatasetRow() - the pure,          |
//| deterministic row-builder frozen in                                 |
//| Docs/PhaseB_B8_2_TrainingDatasetContract.md section 5. Copies      |
//| already-computed lineage references verbatim - never recomputes a  |
//| feature/sizing value, never touches a broker/history/tick call,     |
//| never appends an event, never mutates its inputs. No real label/    |
//| outcome computation happens here - the caller supplies              |
//| label/outcome data (or none, via labelAvailable=false) and this     |
//| function only validates + wires it into the row's lineage.          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_TRAININGDATASETBUILDER_MQH__
#define __MLQUANTAI_TRAININGDATASETBUILDER_MQH__

#include "MLQuantAI_TrainingDatasetRow.mqh"
#include "../Market/MLQuantAI_FeatureSnapshot.mqh"
#include "../Core/MLQuantAI_RiskPlan.mqh"
#include "../Core/MLQuantAI_TradeCandidate.mqh"

// Fail-closed input validation - contract section 5 step 1. Returns ""
// on success, a reason string on failure, mirroring
// RiskSizing_ValidateInput/FeatureSnapshotBuilder_ValidateInput's own
// shape.
string TrainingDatasetBuilder_ValidateInput(const TradeCandidate &candidate, const FeatureSnapshot &snapshot,
                                              const RiskPlan &plan, bool labelAvailable, string label,
                                              string outcomeReference, string outcomeHash, string modelTarget)
{
   if(candidate.candidate_id == "") return "empty candidate_id";
   if(candidate.state != CANDIDATE_CREATED) return "candidate.state is not CANDIDATE_CREATED";

   if(snapshot.candidate_id != candidate.candidate_id)
      return "snapshot.candidate_id does not match the supplied candidate";
   if(snapshot.candidate_hash != candidate.candidate_hash)
      return "snapshot.candidate_hash does not match the supplied candidate - tamper/mismatch";

   if(!plan.allowed)
      return "plan is not allowed - a candidate without an ALLOWED RiskPlan gets no training row";
   if(plan.candidate_id != candidate.candidate_id)
      return "plan.candidate_id does not match the supplied candidate";
   if(plan.candidate_hash != candidate.candidate_hash)
      return "plan.candidate_hash does not match the supplied candidate - tamper/mismatch";

   if(modelTarget == "") return "empty model_target";

   if(!labelAvailable)
   {
      if(label != "" || outcomeReference != "" || outcomeHash != "")
         return "labelAvailable is false but label/outcome_reference/outcome_hash is non-empty - inconsistent input";
   }
   else
   {
      if(label == "" || outcomeReference == "" || outcomeHash == "")
         return "labelAvailable is true but label/outcome_reference/outcome_hash is not fully populated";
   }

   return "";
}

// The B8.2 Commit 1 entry point. Returns true with outRow fully
// filled only on success. Returns false, with outRow left at
// TrainingDatasetRow_Init() defaults, on any fail-closed condition -
// no partial output, matching every other B5/B6/B7/B8 mapping
// function's own rule.
bool BuildTrainingDatasetRow(const TradeCandidate &candidate, const FeatureSnapshot &snapshot, const RiskPlan &plan,
                              bool labelAvailable, string label, string outcomeReference, string outcomeHash,
                              string modelTarget, TrainingDatasetRow &outRow)
{
   TrainingDatasetRow_Init(outRow);

   if(TrainingDatasetBuilder_ValidateInput(candidate, snapshot, plan, labelAvailable, label, outcomeReference, outcomeHash, modelTarget) != "")
      return false;

   // Step 2: lineage references, copied verbatim, never recomputed.
   outRow.candidate_id   = candidate.candidate_id;
   outRow.candidate_hash = candidate.candidate_hash;

   outRow.feature_snapshot_id    = snapshot.feature_snapshot_id;
   outRow.feature_snapshot_hash  = snapshot.feature_snapshot_hash;
   outRow.feature_vector_hash    = snapshot.feature_vector_hash;
   outRow.feature_schema_version = snapshot.feature_schema_version;

   outRow.risk_plan_id        = plan.risk_plan_id;
   outRow.plan_hash            = plan.plan_hash;
   outRow.sizing_rules_version = plan.sizing_rules_version;

   // Step 3: label/outcome, copied verbatim (already validated above).
   outRow.label_available   = labelAvailable;
   outRow.label              = label;
   outRow.outcome_reference  = outcomeReference;
   outRow.outcome_hash        = outcomeHash;

   // Step 4: schema/policy stamps.
   outRow.label_schema_version = MLQUANTAI_LABEL_SCHEMA_B8_2_V1;
   outRow.dataset_schema_version = MLQUANTAI_DATASET_SCHEMA_B8_2_V1;
   outRow.split_policy_version   = MLQUANTAI_DATASET_SPLIT_POLICY_V1;
   outRow.model_target             = modelTarget;

   // Step 5: identity.
   outRow.dataset_row_id = Ids_TrainingDatasetRowId(snapshot.feature_snapshot_id, outRow.label_schema_version, modelTarget);

   // Step 6: split - keyed on candidate_id, not dataset_row_id (see
   // contract section 4).
   outRow.split = TrainingDatasetSplit_Assign(candidate.candidate_id, outRow.split_policy_version);

   // Step 7: row_hash computed LAST, over the finished struct - same
   // "hash the finished object" convention every other hash in this
   // project follows.
   outRow.row_hash = TrainingDatasetRow_ComputeHash(outRow);

   return true;
}

#endif // __MLQUANTAI_TRAININGDATASETBUILDER_MQH__
