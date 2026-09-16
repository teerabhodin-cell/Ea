//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_6_TrainingDatasetChronologicalSplit.mq5          |
//| B8.6 Commit 1 (QA-frozen): proves                                   |
//| TrainingDatasetSplit_AssignChronological() correctly implements the  |
//| frozen §4 algorithm - chronological ordering (oldest->TRAIN, newest-> |
//| TEST), the deterministic tie-break, the floor-based rounding rule      |
//| (remainder always to TEST, never TRAIN), the small-population           |
//| degenerate case, and that output stays index-aligned to the CALLER's     |
//| original (unsorted) input order, never the internal working sort         |
//| order. No EventStore, no OrderSend - pure function only. Running on a     |
//| real account is safe.                                                      |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/AI/MLQuantAI_TrainingDatasetChronologicalSplit.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void OnStart()
{
   Print("=== MLQuantAI_Test_B8_6_TrainingDatasetChronologicalSplit.mq5 ===");

   //=====================================================================
   // 1. Basic chronological ordering: 20 rows, distinct ascending times,
   //    already-sorted input order. Expect 14 TRAIN / 3 VALIDATION / 3 TEST
   //    (floor(20*0.70)=14, floor(20*0.15)=3, remainder=3).
   //=====================================================================
   Print("--- 20 rows, already time-ordered input -> 14/3/3 TRAIN/VALIDATION/TEST ---");
   {
      string candidateIds[20];
      datetime anchorTimes[20];
      datetime t0 = D'2026.01.01 00:00:00';
      for(int i = 0; i < 20; i++)
      {
         candidateIds[i] = StringFormat("CND_%02d", i);
         anchorTimes[i]  = t0 + i * 300; // ascending, 5-minute apart
      }

      ENUM_DATASET_SPLIT splits[];
      DatasetSplitChronologicalReport report;
      TrainingDatasetSplit_AssignChronological(candidateIds, anchorTimes, splits, report);

      Check(report.row_count == 20, "row_count == 20");
      Check(report.train_count == 14, "train_count == 14");
      Check(report.validation_count == 3, "validation_count == 3");
      Check(report.test_count == 3, "test_count == 3");
      Check(!report.population_too_small, "population_too_small == false for 20 rows with nonzero val/test");

      bool orderingCorrect = true;
      for(int i = 0; i < 14; i++)  if(splits[i] != DATASET_SPLIT_TRAIN)      orderingCorrect = false;
      for(int i = 14; i < 17; i++) if(splits[i] != DATASET_SPLIT_VALIDATION) orderingCorrect = false;
      for(int i = 17; i < 20; i++) if(splits[i] != DATASET_SPLIT_TEST)       orderingCorrect = false;
      Check(orderingCorrect, "oldest 14 -> TRAIN, next 3 -> VALIDATION, newest 3 -> TEST");
   }

   //=====================================================================
   // 2. Output stays index-aligned to the ORIGINAL (unsorted) input order,
   //    never the internal chronological working order.
   //=====================================================================
   Print("--- input given in REVERSE chronological order -> output still maps to original index ---");
   {
      string candidateIds[20];
      datetime anchorTimes[20];
      datetime t0 = D'2026.02.01 00:00:00';
      for(int i = 0; i < 20; i++)
      {
         candidateIds[i] = StringFormat("CND_r%02d", i);
         anchorTimes[i]  = t0 - i * 300; // DESCENDING - index 0 is the NEWEST, index 19 is the OLDEST
      }

      ENUM_DATASET_SPLIT splits[];
      DatasetSplitChronologicalReport report;
      TrainingDatasetSplit_AssignChronological(candidateIds, anchorTimes, splits, report);

      // index 19 (oldest) must be TRAIN; index 0 (newest) must be TEST -
      // exactly reversed from test #1, proving the algorithm follows TIME,
      // not array position.
      Check(splits[19] == DATASET_SPLIT_TRAIN, "the chronologically OLDEST row (at array index 19) is TRAIN");
      Check(splits[0] == DATASET_SPLIT_TEST, "the chronologically NEWEST row (at array index 0) is TEST");
   }

   //=====================================================================
   // 3. Tie-break: equal anchor times sort by candidate_id ascending.
   //=====================================================================
   Print("--- equal anchor times -> tie-break by candidate_id ascending ---");
   {
      string candidateIds[3];
      datetime anchorTimes[3];
      datetime sameTime = D'2026.03.01 00:00:00';
      candidateIds[0] = "CND_charlie"; anchorTimes[0] = sameTime;
      candidateIds[1] = "CND_alpha";   anchorTimes[1] = sameTime;
      candidateIds[2] = "CND_bravo";   anchorTimes[2] = sameTime;
      // all 3 share one instant - chronological rank must be alpha, bravo, charlie

      ENUM_DATASET_SPLIT splits[];
      DatasetSplitChronologicalReport report;
      TrainingDatasetSplit_AssignChronological(candidateIds, anchorTimes, splits, report);

      // n=3: train_count=floor(3*0.70)=2, validation_count=floor(3*0.15)=0, test_count=3-2-0=1
      Check(report.train_count == 2 && report.validation_count == 0 && report.test_count == 1,
            "3-row rounding: train=2, validation=0, test=1 (remainder to TEST)");
      Check(report.population_too_small, "population_too_small == true (validation_count == 0)");
      // rank 0=alpha(TRAIN), rank1=bravo(TRAIN), rank2=charlie(TEST) - alphabetical tie-break
      Check(splits[1] == DATASET_SPLIT_TRAIN, "CND_alpha (index 1) resolves TRAIN (rank 0, tie-break winner)");
      Check(splits[2] == DATASET_SPLIT_TRAIN, "CND_bravo (index 2) resolves TRAIN (rank 1)");
      Check(splits[0] == DATASET_SPLIT_TEST, "CND_charlie (index 0) resolves TEST (rank 2, tie-break loser, remainder)");
   }

   //=====================================================================
   // 4. Small-population degenerate case, non-fatal (§4.4): still emits a
   //    real split, just flags population_too_small.
   //=====================================================================
   Print("--- 5-row population -> still emits a split, flagged population_too_small ---");
   {
      string candidateIds[5];
      datetime anchorTimes[5];
      datetime t0 = D'2026.04.01 00:00:00';
      for(int i = 0; i < 5; i++)
      {
         candidateIds[i] = StringFormat("CND_s%d", i);
         anchorTimes[i]  = t0 + i * 300;
      }

      ENUM_DATASET_SPLIT splits[];
      DatasetSplitChronologicalReport report;
      TrainingDatasetSplit_AssignChronological(candidateIds, anchorTimes, splits, report);

      Check(ArraySize(splits) == 5, "5 splits emitted despite small population");
      Check(report.population_too_small, "population_too_small == true (row_count < 20)");
      // train=floor(5*0.70)=3, validation=floor(5*0.15)=0, test=5-3-0=2
      Check(report.train_count == 3 && report.validation_count == 0 && report.test_count == 2,
            "5-row rounding: train=3, validation=0, test=2");
   }

   //=====================================================================
   // 5. Empty population - no crash, reported honestly.
   //=====================================================================
   Print("--- empty population -> no crash, population_too_small ---");
   {
      string candidateIds[];
      datetime anchorTimes[];
      ArrayResize(candidateIds, 0);
      ArrayResize(anchorTimes, 0);

      ENUM_DATASET_SPLIT splits[];
      DatasetSplitChronologicalReport report;
      TrainingDatasetSplit_AssignChronological(candidateIds, anchorTimes, splits, report);

      Check(report.row_count == 0, "row_count == 0");
      Check(report.population_too_small, "population_too_small == true for empty input");
      Check(ArraySize(splits) == 0, "no splits emitted for empty input");
   }

   //=====================================================================
   // 6. Large, exact-multiple-of-20 population (200 rows) - confirms
   //    counts scale correctly with no rounding remainder surprises.
   //=====================================================================
   Print("--- 200 rows -> 140/30/30 exactly, population_too_small == false ---");
   {
      string candidateIds[200];
      datetime anchorTimes[200];
      datetime t0 = D'2026.05.01 00:00:00';
      for(int i = 0; i < 200; i++)
      {
         candidateIds[i] = StringFormat("CND_L%03d", i);
         anchorTimes[i]  = t0 + i * 300;
      }

      ENUM_DATASET_SPLIT splits[];
      DatasetSplitChronologicalReport report;
      TrainingDatasetSplit_AssignChronological(candidateIds, anchorTimes, splits, report);

      Check(report.train_count == 140 && report.validation_count == 30 && report.test_count == 30,
            "200-row split: exactly 140/30/30");
      Check(!report.population_too_small, "population_too_small == false for 200 rows");
   }

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
