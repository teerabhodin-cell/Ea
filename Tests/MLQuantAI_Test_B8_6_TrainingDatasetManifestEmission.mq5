//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_6_TrainingDatasetManifestEmission.mq5             |
//| B8.6 Commit 1 (QA-frozen): proves Component C - dataset_id             |
//| determinism, dataset_hash's reuse of the ALREADY-SEALED                  |
//| TrainingDatasetManifest_DatasetHash() (confirming it already includes     |
//| split assignment, per §5.5's final frozen requirement), idempotency        |
//| (none/duplicate/collision), the durable TRAINING_DATASET_CREATED emitter,   |
//| its frozen Safe Mode policy (collision -> NO Safe Mode; durable write        |
//| failure -> Safe Mode), and ModelArtifactLineage_Verify(). No OrderSend,       |
//| no live wiring - running on a real account is safe.                            |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_TrainingDatasetManifestEventEmission.mqh>
#include <MLQuantAI/AI/MLQuantAI_ModelArtifactLineageVerify.mqh>
#include <MLQuantAI/AI/MLQuantAI_TrainingDatasetRow.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_B8_6_TrainingDatasetManifestEmission.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void MakeRecord(TrainingDatasetManifestRecord &rec, string datasetId, string datasetHash, string splitPolicyVersion)
{
   TrainingDatasetManifestRecord_Init(rec);
   rec.dataset_id = datasetId;
   rec.dataset_hash = datasetHash;
   rec.split_policy_version = splitPolicyVersion;
   rec.label_schema_version = "LABEL_B8_2_V1";
   rec.model_target = "TEST_TARGET_V1";
   rec.row_count = 10;
   rec.export_server_time = D'2026.01.01 00:00:00';
}

void MakeRow(TrainingDatasetRow &row, string candidateId, ENUM_DATASET_SPLIT split)
{
   TrainingDatasetRow_Init(row);
   row.candidate_id = candidateId;
   row.candidate_hash = "hash_" + candidateId;
   row.label_available = true;
   row.label_schema_version = "LABEL_B8_2_V1";
   row.label = "TP_HIT";
   row.split = split;
   row.split_policy_version = "SPLIT_TEST_V1";
   row.row_hash = TrainingDatasetRow_ComputeHash(row);
}

void OnStart()
{
   Print("=== MLQuantAI_Test_B8_6_TrainingDatasetManifestEmission.mq5 ===");

   //=====================================================================
   // 1. dataset_id determinism: same candidate set (any input order) +
   //    same policy fields -> same id. Different set/policy -> different id.
   //=====================================================================
   Print("--- dataset_id determinism ---");
   {
      string idsA[3] = {"CND_a", "CND_b", "CND_c"};
      string idsAReordered[3] = {"CND_c", "CND_a", "CND_b"}; // same set, different input order
      string idsB[3] = {"CND_a", "CND_b", "CND_d"};          // genuinely different set

      string id1 = TrainingDatasetManifestRecord_ComputeDatasetId(idsA, "SPLIT_70_15_15_V1", "LABEL_B8_2_V1", "TARGET_V1");
      string id2 = TrainingDatasetManifestRecord_ComputeDatasetId(idsAReordered, "SPLIT_70_15_15_V1", "LABEL_B8_2_V1", "TARGET_V1");
      string id3 = TrainingDatasetManifestRecord_ComputeDatasetId(idsB, "SPLIT_70_15_15_V1", "LABEL_B8_2_V1", "TARGET_V1");
      string id4 = TrainingDatasetManifestRecord_ComputeDatasetId(idsA, "SPLIT_CHRONOLOGICAL_V1", "LABEL_B8_2_V1", "TARGET_V1");

      Check(id1 == id2, "input order does not affect dataset_id (internal sort makes it order-independent)");
      Check(id1 != id3, "a genuinely different candidate set produces a different dataset_id");
      Check(id1 != id4, "a different split_policy_version produces a different dataset_id");
   }

   //=====================================================================
   // 2. dataset_hash: confirm the REUSED, sealed TrainingDatasetManifest_
   //    DatasetHash() already includes split assignment (§5.5's final
   //    requirement) - same row content, different split -> different hash.
   //=====================================================================
   Print("--- dataset_hash (reused sealed function) already includes split assignment ---");
   {
      TrainingDatasetRow rowsTrainSplit[1];
      MakeRow(rowsTrainSplit[0], "CND_x", DATASET_SPLIT_TRAIN);

      TrainingDatasetRow rowsTestSplit[1];
      MakeRow(rowsTestSplit[0], "CND_x", DATASET_SPLIT_TEST); // identical content, different split

      string hashTrain = TrainingDatasetManifest_DatasetHash(rowsTrainSplit);
      string hashTest   = TrainingDatasetManifest_DatasetHash(rowsTestSplit);

      Check(hashTrain != hashTest, "identical row content under two different split assignments produces two different dataset_hash values");
   }

   //=====================================================================
   // 3. Idempotency (pure function): none / duplicate-same-hash /
   //    collision-different-hash.
   //=====================================================================
   Print("--- TrainingDatasetManifestRecord_CheckIdempotency ---");
   {
      TrainingDatasetManifestRecord rec;
      MakeRecord(rec, "DS_id1", "DS_hash1", "SPLIT_70_15_15_V1");

      string emptyLines[];
      Check(TrainingDatasetManifestRecord_CheckIdempotency(rec, emptyLines) == TRAINING_DATASET_IDEMPOTENCY_NONE_FOUND,
            "no existing lines -> NONE_FOUND");

      string sameHashLine[1];
      sameHashLine[0] = "{\"type\":\"TRAINING_DATASET_CREATED\",\"dataset_id\":\"DS_id1\",\"dataset_hash\":\"DS_hash1\"}";
      Check(TrainingDatasetManifestRecord_CheckIdempotency(rec, sameHashLine) == TRAINING_DATASET_IDEMPOTENCY_DUPLICATE_SAME_HASH,
            "same dataset_id + same dataset_hash -> DUPLICATE_SAME_HASH");

      string diffHashLine[1];
      diffHashLine[0] = "{\"type\":\"TRAINING_DATASET_CREATED\",\"dataset_id\":\"DS_id1\",\"dataset_hash\":\"DS_hash_DIFFERENT\"}";
      Check(TrainingDatasetManifestRecord_CheckIdempotency(rec, diffHashLine) == TRAINING_DATASET_IDEMPOTENCY_COLLISION_DIFFERENT_HASH,
            "same dataset_id + different dataset_hash -> COLLISION_DIFFERENT_HASH");

      // Regression (QA's pre-push diff audit): the FIRST matching line
      // agrees with rec.dataset_hash, but a LATER line for the SAME
      // dataset_id conflicts. The original implementation returned on the
      // first match and never inspected the second line, wrongly reporting
      // DUPLICATE_SAME_HASH. Must be COLLISION_DIFFERENT_HASH regardless of
      // which matching line comes first.
      string firstMatchThenConflict[2];
      firstMatchThenConflict[0] = "{\"type\":\"TRAINING_DATASET_CREATED\",\"dataset_id\":\"DS_id1\",\"dataset_hash\":\"DS_hash1\"}";  // matches rec's hash
      firstMatchThenConflict[1] = "{\"type\":\"TRAINING_DATASET_CREATED\",\"dataset_id\":\"DS_id1\",\"dataset_hash\":\"DS_hash_CONFLICT\"}"; // same id, conflicting hash, appears SECOND
      Check(TrainingDatasetManifestRecord_CheckIdempotency(rec, firstMatchThenConflict) == TRAINING_DATASET_IDEMPOTENCY_COLLISION_DIFFERENT_HASH,
            "first-matching-hash line followed by a later conflicting-hash line for the SAME dataset_id -> still COLLISION_DIFFERENT_HASH (never masked by scan order)");
   }

   //=====================================================================
   // Emission tests - need a real EventStore file.
   //=====================================================================
   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   SafeMode_Clear();
   Check(EventStore_Open(TEST_EVENT_STORE_FILE), "setup: event store opens");

   //=====================================================================
   // 4. Fresh emission -> RECORDED, one durable line, findable afterward.
   //=====================================================================
   Print("--- fresh emission -> RECORDED ---");
   {
      TrainingDatasetManifestRecord rec;
      MakeRecord(rec, "DS_fresh", "HASH_fresh", "SPLIT_70_15_15_V1");

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
      ENUM_TRAINING_DATASET_EMIT_RESULT result = TrainingDatasetManifest_EmitTrainingDatasetCreated(rec, lines);
      Check(result == TRAINING_DATASET_EMIT_RECORDED, "status == RECORDED");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      ENUM_TRAINING_DATASET_IDEMPOTENCY idem = TrainingDatasetManifestRecord_CheckIdempotency(rec, linesAfter);
      Check(idem == TRAINING_DATASET_IDEMPOTENCY_DUPLICATE_SAME_HASH, "the just-written record now reads back as a duplicate-same-hash");
   }

   //=====================================================================
   // 5. Duplicate identical emission -> ALREADY_RECORDED, no second line,
   //    no Safe Mode.
   //=====================================================================
   Print("--- duplicate identical emission -> ALREADY_RECORDED, no second line ---");
   {
      TrainingDatasetManifestRecord rec;
      MakeRecord(rec, "DS_fresh", "HASH_fresh", "SPLIT_70_15_15_V1"); // identical to test 4

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
      int countBefore = ArraySize(lines);
      ENUM_TRAINING_DATASET_EMIT_RESULT result = TrainingDatasetManifest_EmitTrainingDatasetCreated(rec, lines);
      Check(result == TRAINING_DATASET_EMIT_ALREADY_RECORDED, "status == ALREADY_RECORDED");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == countBefore, "no new durable line appended");
      Check(!SafeMode_IsActive(), "duplicate-same-hash never trips Safe Mode");
   }

   //=====================================================================
   // 6. Collision (same dataset_id, different dataset_hash) -> REJECTED,
   //    NEVER Safe Mode, no overwrite.
   //=====================================================================
   Print("--- collision (same dataset_id, different hash) -> REJECTED_COLLISION, NO Safe Mode ---");
   {
      TrainingDatasetManifestRecord rec;
      MakeRecord(rec, "DS_fresh", "HASH_CONFLICTING", "SPLIT_70_15_15_V1"); // same id, different hash

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
      int countBefore = ArraySize(lines);
      Check(!SafeMode_IsActive(), "sanity: Safe Mode not active before the collision attempt");
      ENUM_TRAINING_DATASET_EMIT_RESULT result = TrainingDatasetManifest_EmitTrainingDatasetCreated(rec, lines);
      Check(result == TRAINING_DATASET_EMIT_REJECTED_COLLISION, "status == REJECTED_COLLISION");
      Check(!SafeMode_IsActive(), "collision NEVER trips Safe Mode (QA's final frozen verdict on §5.6)");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == countBefore, "no new durable line appended, original record never overwritten");
   }

   //=====================================================================
   // 7. Durable write failure (EventStore closed) -> FAILED, Safe Mode
   //    DOES trip.
   //=====================================================================
   Print("--- durable write failure (EventStore closed) -> FAILED, Safe Mode trips ---");
   {
      TrainingDatasetManifestRecord rec;
      MakeRecord(rec, "DS_neverwritten", "HASH_neverwritten", "SPLIT_70_15_15_V1");

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines); // read while still open
      EventStore_Close();

      Check(!SafeMode_IsActive(), "sanity: Safe Mode not active before the write-failure attempt");
      ENUM_TRAINING_DATASET_EMIT_RESULT result = TrainingDatasetManifest_EmitTrainingDatasetCreated(rec, lines);
      Check(result == TRAINING_DATASET_EMIT_FAILED, "status == FAILED");
      Check(SafeMode_IsActive(), "durable write failure DOES trip Safe Mode (unchanged from every other LIFECYCLE-event precedent)");

      SafeMode_Clear();
      Check(EventStore_Open(TEST_EVENT_STORE_FILE), "cleanup: event store reopens");
   }

   //=====================================================================
   // 8. ModelArtifactLineage_Verify: VERIFIED / NO_RECORD / HASH_MISMATCH.
   //=====================================================================
   Print("--- ModelArtifactLineage_Verify ---");
   {
      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines); // contains the "DS_fresh"/"HASH_fresh" record from test 4

      ModelArtifact verifiedArtifact;
      ModelArtifact_Init(verifiedArtifact);
      verifiedArtifact.training_dataset_id = "DS_fresh";
      verifiedArtifact.training_dataset_hash = "HASH_fresh";
      Check(ModelArtifactLineage_Verify(verifiedArtifact, lines) == LINEAGE_VERIFY_VERIFIED, "matching dataset_id + dataset_hash -> VERIFIED");

      ModelArtifact noRecordArtifact;
      ModelArtifact_Init(noRecordArtifact);
      noRecordArtifact.training_dataset_id = "DS_never_existed";
      noRecordArtifact.training_dataset_hash = "irrelevant";
      Check(ModelArtifactLineage_Verify(noRecordArtifact, lines) == LINEAGE_VERIFY_NO_RECORD, "unknown dataset_id -> NO_RECORD");

      ModelArtifact mismatchArtifact;
      ModelArtifact_Init(mismatchArtifact);
      mismatchArtifact.training_dataset_id = "DS_fresh";
      mismatchArtifact.training_dataset_hash = "HASH_WRONG";
      Check(ModelArtifactLineage_Verify(mismatchArtifact, lines) == LINEAGE_VERIFY_HASH_MISMATCH, "known dataset_id, wrong declared hash -> HASH_MISMATCH");

      // Regression (QA's pre-push diff audit, same class of fix as
      // TrainingDatasetManifestRecord_CheckIdempotency): the real, first
      // matching line ("DS_fresh"/"HASH_fresh" from test 4) agrees with the
      // artifact's declared hash, but a LATER, fabricated line for the SAME
      // dataset_id conflicts. Must be HASH_MISMATCH regardless of which
      // matching line comes first - never VERIFIED just because the first
      // encountered match happened to agree.
      string linesWithLaterConflict[];
      ArrayResize(linesWithLaterConflict, ArraySize(lines) + 1);
      for(int i = 0; i < ArraySize(lines); i++) linesWithLaterConflict[i] = lines[i];
      linesWithLaterConflict[ArraySize(lines)] = "{\"type\":\"TRAINING_DATASET_CREATED\",\"dataset_id\":\"DS_fresh\",\"dataset_hash\":\"HASH_LATER_CONFLICT\"}";

      ModelArtifact firstMatchThenConflictArtifact;
      ModelArtifact_Init(firstMatchThenConflictArtifact);
      firstMatchThenConflictArtifact.training_dataset_id = "DS_fresh";
      firstMatchThenConflictArtifact.training_dataset_hash = "HASH_fresh"; // agrees with the FIRST matching (real) line
      Check(ModelArtifactLineage_Verify(firstMatchThenConflictArtifact, linesWithLaterConflict) == LINEAGE_VERIFY_HASH_MISMATCH,
            "first-matching-hash line followed by a later conflicting-hash line for the SAME dataset_id -> still HASH_MISMATCH (never masked by scan order)");
   }

   EventStore_Close();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
