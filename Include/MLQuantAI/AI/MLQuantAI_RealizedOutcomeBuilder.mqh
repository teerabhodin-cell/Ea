//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_RealizedOutcomeBuilder.mqh                |
//| Phase B8.2 Commit 3: RealizedOutcome_Build() - the pure,            |
//| deterministic builder frozen in                                    |
//| Docs/PhaseB_B8_2_Commit3_OutcomeLabelContract.md. Validates a       |
//| caller-supplied outcome (label/outcome_reference/outcome_hash/      |
//| outcome_time) against its candidate, then wires it into a           |
//| RealizedOutcome's identity + hash. Never computes label content     |
//| itself, never touches a broker/history/tick call, never appends an  |
//| event, never mutates its inputs.                                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_REALIZEDOUTCOMEBUILDER_MQH__
#define __MLQUANTAI_REALIZEDOUTCOMEBUILDER_MQH__

#include "MLQuantAI_RealizedOutcome.mqh"
#include "../Core/MLQuantAI_TradeCandidate.mqh"

// Fail-closed input validation - contract "RealizedOutcome_Build"
// section. Returns "" on success, a reason string on failure,
// mirroring TrainingDatasetBuilder_ValidateInput/
// FeatureSnapshotBuilder_ValidateInput's own shape.
string RealizedOutcomeBuilder_ValidateInput(const TradeCandidate &candidate, string label, string outcomeReference,
                                              string outcomeHash, datetime outcomeTime, string labelSchemaVersion)
{
   if(candidate.candidate_id == "") return "empty candidate_id";
   if(candidate.state != CANDIDATE_CREATED) return "candidate.state is not CANDIDATE_CREATED";

   // A RealizedOutcome has no "unlabeled" state of its own - unlike
   // TrainingDatasetRow, "unlabeled" is represented by the ABSENCE of
   // a RealizedOutcome for a candidate, not by one with empty fields.
   // A RealizedOutcome that exists at all is, by construction, always
   // fully labeled.
   if(label == "") return "empty label";
   if(outcomeReference == "") return "empty outcome_reference";
   if(outcomeHash == "") return "empty outcome_hash";

   // See Docs/PhaseB_B8_2_Commit3_OutcomeLabelContract.md scope
   // decision 5 - BuildTrainingDatasetRow (B8.2 Commit 1, sealed)
   // unconditionally stamps MLQUANTAI_LABEL_SCHEMA_B8_2_V1 and takes
   // no caller-supplied label schema version at all, so any other
   // value here would silently diverge from what the row builder
   // actually stamps.
   if(labelSchemaVersion != MLQUANTAI_LABEL_SCHEMA_B8_2_V1)
      return "labelSchemaVersion does not equal MLQUANTAI_LABEL_SCHEMA_B8_2_V1";

   // Temporal boundary - strictly after, not "on or after": an
   // outcome timestamped at the exact candidate-time instant is
   // exactly as suspect as one before it.
   if(outcomeTime <= candidate.setup_anchor_bar_time)
      return "outcome_time is not strictly after candidate.setup_anchor_bar_time";

   return "";
}

// The B8.2 Commit 3 entry point. Returns true with outOutcome fully
// filled only on success. Returns false, with outOutcome left at
// RealizedOutcome_Init() defaults, on any fail-closed condition - no
// partial output, matching every other B5/B6/B7/B8 mapping function's
// own rule.
bool RealizedOutcome_Build(const TradeCandidate &candidate, string label, string outcomeReference,
                             string outcomeHash, datetime outcomeTime, string labelSchemaVersion,
                             RealizedOutcome &outOutcome)
{
   RealizedOutcome_Init(outOutcome);

   if(RealizedOutcomeBuilder_ValidateInput(candidate, label, outcomeReference, outcomeHash, outcomeTime, labelSchemaVersion) != "")
      return false;

   // Identity computed first - depends only on candidate_id +
   // label_schema_version, never on this outcome's own content.
   outOutcome.realized_outcome_id = Ids_RealizedOutcomeId(candidate.candidate_id, labelSchemaVersion);

   outOutcome.candidate_id   = candidate.candidate_id;
   outOutcome.candidate_hash = candidate.candidate_hash;

   outOutcome.label_schema_version = labelSchemaVersion;
   outOutcome.label                = label;
   outOutcome.outcome_reference    = outcomeReference;
   outOutcome.outcome_hash         = outcomeHash;
   outOutcome.outcome_time         = outcomeTime;

   // Content hash computed last, over the finished struct - same
   // "hash the finished object" convention every other hash in this
   // project follows.
   outOutcome.realized_outcome_hash = RealizedOutcome_ComputeHash(outOutcome);

   return true;
}

#endif // __MLQUANTAI_REALIZEDOUTCOMEBUILDER_MQH__
