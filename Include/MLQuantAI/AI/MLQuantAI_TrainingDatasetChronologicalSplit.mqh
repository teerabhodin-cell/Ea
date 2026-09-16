//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_TrainingDatasetChronologicalSplit.mqh    |
//| B8.6 Commit 1 (QA-frozen, Docs/PhaseB_B8_6_                        |
//| ModelTrainingInferenceIntegrationContract.md §4): SPLIT_            |
//| CHRONOLOGICAL_V1, a NEW, additive split policy alongside the         |
//| existing, sealed SPLIT_70_15_15_V1 (MLQuantAI_TrainingDatasetRow.mqh's|
//| TrainingDatasetSplit_Assign, per-row hash-based) - that function and  |
//| every other symbol in MLQuantAI_TrainingDatasetRow.mqh is UNTOUCHED    |
//| by this file; MLQUANTAI_DATASET_SPLIT_POLICY_V1 (legacy) is never       |
//| reinterpreted or modified.                                               |
//|                                                                            |
//| Implementation-time signature choice (authorized under the contract's     |
//| §9 naming carve-out): the frozen design sketched this function taking     |
//| TrainingDatasetRow[] directly, but that struct carries no anchor-bar-      |
//| time field, and TrainingDatasetRow.mqh's Class 2 amendment authorized      |
//| by the contract is scoped EXACTLY to one named field                       |
//| (label_source_realized_outcome_id) - not this. So this function takes       |
//| plain parallel arrays (candidateId/anchorTime) instead, supplied by the      |
//| caller (the future export orchestration, which already has anchor-bar-       |
//| time via CandidateProjection, a sealed read accessor) - the frozen            |
//| algorithm, tie-break, and rounding rules are unchanged; only the input         |
//| shape differs from the sketch.                                                  |
//|                                                                                    |
//| Pure: no file I/O, no EventStore call, no live MT5 API, no candidate-              |
//| lifecycle authority. Fully unit-testable with fabricated arrays.                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_TRAININGDATASETCHRONOLOGICALSPLIT_MQH__
#define __MLQUANTAI_TRAININGDATASETCHRONOLOGICALSPLIT_MQH__

#include "MLQuantAI_TrainingDatasetRow.mqh"

// New, additive policy version - a sibling to (never a replacement of)
// MLQUANTAI_DATASET_SPLIT_POLICY_V1 (Core/MLQuantAI_ContractVersions.mqh,
// untouched). Defined locally rather than added to ContractVersions.mqh,
// since that file is not in the contract's Class 1/Class 2 list - this
// avoids any ambiguity about touching an unlisted file, matching this
// project's existing precedent of file-local constants (e.g.
// MLQUANTAI_CANDPROJ_MAX_LINE_LENGTH in CandidateProjection.mqh).
#define MLQUANTAI_DATASET_SPLIT_POLICY_CHRONOLOGICAL_V1  "SPLIT_CHRONOLOGICAL_V1"

// §4.4 (frozen): a small population never blocks the split - it is
// reported as an honest, non-fatal finding instead of silently proceeding
// or silently failing.
struct DatasetSplitChronologicalReport
{
   bool population_too_small; // true iff row_count < 20, OR validation_count == 0, OR test_count == 0
   int  row_count;
   int  train_count;
   int  validation_count;
   int  test_count;
};

void DatasetSplitChronologicalReport_Init(DatasetSplitChronologicalReport &r)
{
   r.population_too_small = false;
   r.row_count = 0;
   r.train_count = 0;
   r.validation_count = 0;
   r.test_count = 0;
}

// §4.3 (frozen rounding rule): the remainder always absorbs into TEST,
// never TRAIN - so TRAIN's share never silently inflates run over run.
void DatasetSplitChronological_ComputeCounts(int rowCount, int &outTrainCount, int &outValidationCount, int &outTestCount)
{
   outTrainCount      = (int)MathFloor(rowCount * 0.70);
   outValidationCount = (int)MathFloor(rowCount * 0.15);
   outTestCount       = rowCount - outTrainCount - outValidationCount;
}

// §4.2 step 1-2 (frozen): a stable, deterministic ascending sort of row
// indices by (anchorTimes[i], candidateIds[i]) - time primary, candidate_id
// the tie-break. Plain insertion sort over an index array - dataset sizes
// here are candidate-population-scale, not tick-scale, so O(n^2) is the
// same "simple, obviously correct" tradeoff this project's other small
// in-memory sorts already make; never touches the caller's own arrays.
void DatasetSplitChronological_SortIndices(const string &candidateIds[], const datetime &anchorTimes[], int &outOrder[])
{
   int n = ArraySize(candidateIds);
   ArrayResize(outOrder, n);
   for(int i = 0; i < n; i++) outOrder[i] = i;

   for(int i = 1; i < n; i++)
   {
      int key = outOrder[i];
      int j = i - 1;
      while(j >= 0 &&
            (anchorTimes[outOrder[j]] > anchorTimes[key] ||
             (anchorTimes[outOrder[j]] == anchorTimes[key] && candidateIds[outOrder[j]] > candidateIds[key])))
      {
         outOrder[j + 1] = outOrder[j];
         j--;
      }
      outOrder[j + 1] = key;
   }
}

// The full frozen algorithm (§4.2-§4.4). outSplits is sized/indexed
// IDENTICALLY to the input arrays (candidateIds[i]/anchorTimes[i] ->
// outSplits[i]) - the internal chronological sort (via
// DatasetSplitChronological_SortIndices) is a working order only, per
// §4.2 step 4's frozen "never reorders the emitted rows" rule.
void TrainingDatasetSplit_AssignChronological(const string &candidateIds[], const datetime &anchorTimes[],
                                                 ENUM_DATASET_SPLIT &outSplits[], DatasetSplitChronologicalReport &outReport)
{
   DatasetSplitChronologicalReport_Init(outReport);

   int n = ArraySize(candidateIds);
   ArrayResize(outSplits, n);
   for(int i = 0; i < n; i++) outSplits[i] = DATASET_SPLIT_TRAIN; // safe default, overwritten below for every real row

   if(n == 0)
   {
      outReport.population_too_small = true;
      return;
   }

   int order[];
   DatasetSplitChronological_SortIndices(candidateIds, anchorTimes, order);

   int trainCount, validationCount, testCount;
   DatasetSplitChronological_ComputeCounts(n, trainCount, validationCount, testCount);

   for(int rank = 0; rank < n; rank++)
   {
      int originalIndex = order[rank];
      if(rank < trainCount)                          outSplits[originalIndex] = DATASET_SPLIT_TRAIN;
      else if(rank < trainCount + validationCount)    outSplits[originalIndex] = DATASET_SPLIT_VALIDATION;
      else                                            outSplits[originalIndex] = DATASET_SPLIT_TEST;
   }

   outReport.row_count = n;
   outReport.train_count = trainCount;
   outReport.validation_count = validationCount;
   outReport.test_count = testCount;
   outReport.population_too_small = (n < 20 || validationCount == 0 || testCount == 0);
}

#endif // __MLQUANTAI_TRAININGDATASETCHRONOLOGICALSPLIT_MQH__
