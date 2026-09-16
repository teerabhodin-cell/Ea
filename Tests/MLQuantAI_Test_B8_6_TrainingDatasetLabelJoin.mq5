//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_6_TrainingDatasetLabelJoin.mq5                    |
//| B8.6 Commit 1 (QA-frozen): proves the new                            |
//| RealizedOutcomeProjection_TryGetByCandidateId() accessor and           |
//| TrainingDatasetLabelJoin_Apply() correctly implement the frozen §3       |
//| auto-join - found -> label_available=true + label + provenance set,       |
//| not found -> label_available=false untouched otherwise, wrong               |
//| label_schema_version -> treated as not found (never a false match),          |
//| idempotent re-application. Uses the registry's own already-public              |
//| direct-construction accessors (RealizedOutcomeProjection_Reset/                  |
//| _AppendRecord) to fabricate RealizedOutcome state - no EventStore round-           |
//| trip needed since this test only exercises the join's own matching/set-             |
//| field logic, not RealizedOutcomeProjection's own line-parsing (which has              |
//| its own dedicated test suite already). No OrderSend, no EventStore, no                 |
//| live wiring exercised - running on a real account is safe.                              |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/AI/MLQuantAI_TrainingDatasetLabelJoin.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void MakeRealizedOutcome(string candidateId, string labelSchemaVersion, string label, string realizedOutcomeId)
{
   RealizedOutcomeProjectionRecord rec;
   RealizedOutcomeProjectionRecord_Init(rec);
   rec.realized_outcome_id = realizedOutcomeId;
   rec.candidate_id = candidateId;
   rec.candidate_hash = "hash_" + candidateId;
   rec.label_schema_version = labelSchemaVersion;
   rec.label = label;
   rec.outcome_reference = "REF_" + candidateId;
   rec.outcome_hash = "OUTHASH_" + candidateId;
   rec.outcome_time = D'2026.01.01 00:00:00';
   rec.realized_outcome_hash = "ROHASH_" + candidateId;
   RealizedOutcomeProjection_AppendRecord(rec);
}

void MakeRow(TrainingDatasetRow &row, string candidateId)
{
   TrainingDatasetRow_Init(row);
   row.candidate_id = candidateId;
   row.candidate_hash = "hash_" + candidateId;
}

void OnStart()
{
   Print("=== MLQuantAI_Test_B8_6_TrainingDatasetLabelJoin.mq5 ===");

   //=====================================================================
   // 1. Direct accessor: found (matching candidate_id + schema version).
   //=====================================================================
   Print("--- RealizedOutcomeProjection_TryGetByCandidateId: found ---");
   RealizedOutcomeProjection_Reset();
   MakeRealizedOutcome("CND_a1", MLQUANTAI_LABEL_SCHEMA_B8_2_V1, "TP_HIT", "RO_a1");
   {
      RealizedOutcomeProjectionRecord rec;
      bool found = RealizedOutcomeProjection_TryGetByCandidateId("CND_a1", MLQUANTAI_LABEL_SCHEMA_B8_2_V1, rec);
      Check(found, "found for matching candidate_id + schema version");
      Check(rec.realized_outcome_id == "RO_a1", "returned the correct record");
      Check(rec.label == "TP_HIT", "label read correctly");
   }

   //=====================================================================
   // 2. Direct accessor: not found (unknown candidate_id).
   //=====================================================================
   Print("--- RealizedOutcomeProjection_TryGetByCandidateId: unknown candidate_id -> not found ---");
   {
      RealizedOutcomeProjectionRecord rec;
      bool found = RealizedOutcomeProjection_TryGetByCandidateId("CND_unknown", MLQUANTAI_LABEL_SCHEMA_B8_2_V1, rec);
      Check(!found, "not found for an unknown candidate_id");
   }

   //=====================================================================
   // 3. Direct accessor: candidate_id exists, but under a DIFFERENT
   //    label_schema_version -> not found (never a false match).
   //=====================================================================
   Print("--- RealizedOutcomeProjection_TryGetByCandidateId: wrong schema version -> not found ---");
   {
      RealizedOutcomeProjectionRecord rec;
      bool found = RealizedOutcomeProjection_TryGetByCandidateId("CND_a1", "SOME_FUTURE_SCHEMA_V2", rec);
      Check(!found, "not found when the schema version doesn't match, even though candidate_id does");
   }

   //=====================================================================
   // 4. Join: eligible RealizedOutcome exists -> row gets labeled.
   //=====================================================================
   Print("--- TrainingDatasetLabelJoin_Apply: eligible outcome exists -> row labeled ---");
   RealizedOutcomeProjection_Reset();
   MakeRealizedOutcome("CND_b1", MLQUANTAI_LABEL_SCHEMA_B8_2_V1, "SL_HIT", "RO_b1");
   {
      TrainingDatasetRow row;
      MakeRow(row, "CND_b1");
      Check(!row.label_available, "sanity: row starts unlabeled");

      TrainingDatasetLabelJoin_Apply(row);

      Check(row.label_available, "label_available == true after join");
      Check(row.label == "SL_HIT", "label set to the RealizedOutcome's own label");
      Check(row.label_source_realized_outcome_id == "RO_b1", "label_source_realized_outcome_id set to the matched record's id");
   }

   //=====================================================================
   // 5. Join: TIMEOUT is eligible too (RA-62's third class - never
   //    excluded, per QA's frozen decision 1).
   //=====================================================================
   Print("--- TrainingDatasetLabelJoin_Apply: TIMEOUT label is eligible ---");
   RealizedOutcomeProjection_Reset();
   MakeRealizedOutcome("CND_c1", MLQUANTAI_LABEL_SCHEMA_B8_2_V1, "TIMEOUT", "RO_c1");
   {
      TrainingDatasetRow row;
      MakeRow(row, "CND_c1");
      TrainingDatasetLabelJoin_Apply(row);
      Check(row.label_available, "TIMEOUT-labeled outcome makes the row eligible too");
      Check(row.label == "TIMEOUT", "label == TIMEOUT, never excluded or substituted");
   }

   //=====================================================================
   // 6. Join: no RealizedOutcome exists for this candidate -> row stays
   //    unlabeled, never an error, never fabricated.
   //=====================================================================
   Print("--- TrainingDatasetLabelJoin_Apply: no RealizedOutcome exists -> row stays unlabeled ---");
   RealizedOutcomeProjection_Reset();
   {
      TrainingDatasetRow row;
      MakeRow(row, "CND_no_outcome_yet");
      TrainingDatasetLabelJoin_Apply(row);

      Check(!row.label_available, "label_available stays false");
      Check(row.label == "", "label left at its sealed default, never fabricated");
      Check(row.label_source_realized_outcome_id == "", "label_source_realized_outcome_id left empty");
   }

   //=====================================================================
   // 7. Idempotency: calling the join twice on the same row (e.g. a
   //    re-export) produces the identical result both times.
   //=====================================================================
   Print("--- TrainingDatasetLabelJoin_Apply: idempotent re-application ---");
   RealizedOutcomeProjection_Reset();
   MakeRealizedOutcome("CND_d1", MLQUANTAI_LABEL_SCHEMA_B8_2_V1, "TP_HIT", "RO_d1");
   {
      TrainingDatasetRow row;
      MakeRow(row, "CND_d1");
      TrainingDatasetLabelJoin_Apply(row);
      string firstLabel = row.label;
      string firstSourceId = row.label_source_realized_outcome_id;

      TrainingDatasetLabelJoin_Apply(row); // second call, same row

      Check(row.label_available, "still labeled after the second call");
      Check(row.label == firstLabel, "label unchanged across repeated application");
      Check(row.label_source_realized_outcome_id == firstSourceId, "provenance unchanged across repeated application");
   }

   //=====================================================================
   // 8. Join never touches any OTHER field on the row (candidate_hash,
   //    feature_snapshot_id, split, etc.) - only the three label-related
   //    fields.
   //=====================================================================
   Print("--- TrainingDatasetLabelJoin_Apply: touches ONLY the three label fields ---");
   RealizedOutcomeProjection_Reset();
   MakeRealizedOutcome("CND_e1", MLQUANTAI_LABEL_SCHEMA_B8_2_V1, "SL_HIT", "RO_e1");
   {
      TrainingDatasetRow row;
      MakeRow(row, "CND_e1");
      row.feature_snapshot_id = "FS_untouched";
      row.risk_plan_id = "RP_untouched";
      row.split = DATASET_SPLIT_VALIDATION;
      row.split_policy_version = "SPLIT_UNTOUCHED_V1";

      TrainingDatasetLabelJoin_Apply(row);

      Check(row.feature_snapshot_id == "FS_untouched", "feature_snapshot_id untouched");
      Check(row.risk_plan_id == "RP_untouched", "risk_plan_id untouched");
      Check(row.split == DATASET_SPLIT_VALIDATION, "split untouched");
      Check(row.split_policy_version == "SPLIT_UNTOUCHED_V1", "split_policy_version untouched");
   }

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
