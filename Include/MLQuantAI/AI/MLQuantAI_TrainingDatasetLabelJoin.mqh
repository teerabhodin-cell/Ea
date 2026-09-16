//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_TrainingDatasetLabelJoin.mqh              |
//| B8.6 Commit 1 (QA-frozen, Docs/PhaseB_B8_6_                        |
//| ModelTrainingInferenceIntegrationContract.md §3): Component A - the |
//| RealizedOutcome (RA-62) -> TrainingDatasetRow.label auto-join. Owns  |
//| ONLY the join decision itself - does not build a TrainingDatasetRow   |
//| (that remains BuildTrainingDatasetRow's own sealed, untouched job),    |
//| does not touch RealizedOutcomeProjection.mqh/TrainingDatasetRow.mqh     |
//| beyond the two already-authorized additive amendments made alongside     |
//| this file (the new TryGetByCandidateId accessor and the new                |
//| label_source_realized_outcome_id field, both committed separately in       |
//| those files, not here).                                                       |
//|                                                                                  |
//| Offline/export-time only (§3.2, frozen) - this function has no live MT5          |
//| API call and no reason to ever be called from OnTick; it is meant to be           |
//| invoked by the training-dataset EXPORT orchestration (existing, sealed,            |
//| untouched MLQuantAI_TrainingDatasetExport.mqh), once per already-built              |
//| TrainingDatasetRow, before that row is written to the exported artifact.             |
//|                                                                                         |
//| Pure with respect to eligibility (§3.1): a RealizedOutcome record found for            |
//| (candidate_id, MLQUANTAI_LABEL_SCHEMA_B8_2_V1) is eligible by construction -            |
//| RA-62's own sealed OutcomeLabelEngine only ever emits label in                          |
//| {TP_HIT, SL_HIT, TIMEOUT} for that schema version, so existence under the                |
//| correct schema version already IS the eligibility check - no separate label-              |
//| value allowlist is re-implemented here.                                                     |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_TRAININGDATASETLABELJOIN_MQH__
#define __MLQUANTAI_TRAININGDATASETLABELJOIN_MQH__

#include "MLQuantAI_TrainingDatasetRow.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_RealizedOutcomeProjection.mqh"
#include "../Core/MLQuantAI_ContractVersions.mqh"

// §3.2 (frozen): mutates ONLY the three label-related fields on an
// already-built row - candidate_id (already set by BuildTrainingDatasetRow)
// is read, never written. Idempotent: calling this twice on the same row
// produces the same result both times, since it only ever reads the
// (unmutated-by-this-function) RealizedOutcomeProjection registry.
void TrainingDatasetLabelJoin_Apply(TrainingDatasetRow &row)
{
   RealizedOutcomeProjectionRecord outcome;
   if(!RealizedOutcomeProjection_TryGetByCandidateId(row.candidate_id, MLQUANTAI_LABEL_SCHEMA_B8_2_V1, outcome))
   {
      // §3.2 step 3 (frozen): not found - label_available stays false,
      // label left at whatever BuildTrainingDatasetRow's own sealed
      // default already is (never fabricated, never an error).
      row.label_available = false;
      return;
   }

   // §3.2 step 2 (frozen): found and eligible by construction (see file
   // header) - set exactly these three fields, nothing else on the row.
   row.label_available = true;
   row.label = outcome.label;
   row.label_source_realized_outcome_id = outcome.realized_outcome_id;
}

#endif // __MLQUANTAI_TRAININGDATASETLABELJOIN_MQH__
