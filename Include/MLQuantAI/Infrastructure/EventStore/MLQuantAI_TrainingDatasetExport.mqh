//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_TrainingDatasetExport.mqh|
//| Phase B8.2 Commit 2 (Part 1): TrainingDatasetExport_BuildDataset - |
//| deterministic projection/export of TrainingDatasetRow from         |
//| persisted artifacts only, per                                       |
//| Docs/PhaseB_B8_2_Commit2_ExportContract.md's Part 1. Pure           |
//| orchestration: rebuilds CandidateProjection/FeatureSnapshotProjection|
//| /RiskPlanProjection (all sealed, unmodified), then calls the sealed |
//| BuildTrainingDatasetRow (B8.2 Commit 1) once per qualifying         |
//| candidate. No feature value, risk-sizing value, or label is ever    |
//| computed here - this file only composes what B5/B6/B7/B8.1/B8.2-    |
//| Commit-1 already computed and persisted.                            |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_TRAININGDATASETEXPORT_MQH__
#define __MLQUANTAI_TRAININGDATASETEXPORT_MQH__

#include "MLQuantAI_FeatureSnapshotProjection.mqh"
#include "MLQuantAI_RiskPlanProjection.mqh"
#include "../../AI/MLQuantAI_TrainingDatasetBuilder.mqh"

// Minimal adapters bridging replay/projection-registry types to the
// live-pipeline types BuildTrainingDatasetRow (B8.2 Commit 1, sealed)
// was written against. Only the fields that function's own validation
// and copy steps actually read are populated - everything else stays
// at Init() defaults. Adapting at this call site (rather than
// reopening Commit 1's sealed signature) is the same "extend, never
// silently reopen a sealed contract" discipline this project has
// followed since B7.
void TrainingDatasetExport_CandidateFromProjection(const CandidateProjectionRecord &rec, TradeCandidate &outCandidate)
{
   TradeCandidate_Init(outCandidate);
   outCandidate.candidate_id   = rec.candidate_id;
   outCandidate.candidate_hash = rec.candidate_hash;
   outCandidate.state           = rec.state; // always CANDIDATE_CREATED - CandidateProjection's own documented invariant
}

void TrainingDatasetExport_SnapshotFromProjection(const FeatureSnapshotProjectionRecord &rec, FeatureSnapshot &outSnapshot)
{
   FeatureSnapshot_Init(outSnapshot);
   outSnapshot.candidate_id           = rec.candidate_id;
   outSnapshot.candidate_hash         = rec.candidate_hash;
   outSnapshot.feature_snapshot_id    = rec.feature_snapshot_id;
   outSnapshot.feature_snapshot_hash  = rec.feature_snapshot_hash;
   outSnapshot.feature_vector_hash    = rec.feature_vector_hash;
   outSnapshot.feature_schema_version = rec.feature_schema_version;
}

// allowed is set unconditionally true: RiskPlan_EmitRiskPlanCreated's
// own guard (if(p.risk_plan_id == "" || !p.allowed) return false;)
// means a rejected plan never becomes a RISK_PLAN_CREATED event in the
// first place - every record RiskPlanProjection ever holds is
// guaranteed to have come from an allowed plan.
void TrainingDatasetExport_PlanFromProjection(const RiskPlanProjectionRecord &rec, RiskPlan &outPlan)
{
   RiskPlan_Init(outPlan);
   outPlan.allowed              = true;
   outPlan.candidate_id          = rec.candidate_id;
   outPlan.candidate_hash        = rec.candidate_hash;
   outPlan.risk_plan_id           = rec.risk_plan_id;
   outPlan.plan_hash               = rec.plan_hash;
   outPlan.sizing_rules_version     = rec.sizing_rules_version;
}

// Linear scan over the (small, "a few hundred setups at most" per
// B6.2's own stated scale) FeatureSnapshotProjection/RiskPlanProjection
// registries - same O(n) / O(n^2)-overall complexity B6.2's own
// insertion sort already accepted at this scale. FeatureSnapshotProjection
// is technically keyed by feature_snapshot_id (a pure function of
// candidate_id alone - Ids_FeatureSnapshotId(candidateId) - so a direct
// computed-key lookup would also work), but this scan-by-candidate_id
// form is used for both lookups uniformly, rather than mixing a direct
// lookup for one and a scan for the other.
bool TrainingDatasetExport_FindSnapshotForCandidate(string candidateId, FeatureSnapshotProjectionRecord &out)
{
   int n = FeatureSnapshotProjection_Count();
   for(int i = 0; i < n; i++)
   {
      FeatureSnapshotProjectionRecord rec;
      FeatureSnapshotProjection_GetAt(i, rec);
      if(rec.candidate_id == candidateId) { out = rec; return true; }
   }
   return false;
}

bool TrainingDatasetExport_FindPlanForCandidate(string candidateId, RiskPlanProjectionRecord &out)
{
   int n = RiskPlanProjection_Count();
   for(int i = 0; i < n; i++)
   {
      RiskPlanProjectionRecord rec;
      RiskPlanProjection_GetAt(i, rec);
      if(rec.candidate_id == candidateId) { out = rec; return true; }
   }
   return false;
}

// Stable sort: candidate.setup_anchor_bar_time ASC, dataset_row_id ASC
// (frozen tie-break, per the Commit 2 contract). Simple insertion
// sort - same scale reasoning as B6.2's own CandidateDatasetExport_SortRows.
void TrainingDatasetExport_SortRows(TrainingDatasetRow &rows[], datetime &anchorTimes[])
{
   int n = ArraySize(rows);
   for(int i = 1; i < n; i++)
   {
      TrainingDatasetRow keyRow = rows[i];
      datetime keyAnchor = anchorTimes[i];
      int j = i - 1;
      while(j >= 0 &&
            (anchorTimes[j] > keyAnchor ||
             (anchorTimes[j] == keyAnchor && rows[j].dataset_row_id > keyRow.dataset_row_id)))
      {
         rows[j+1] = rows[j];
         anchorTimes[j+1] = anchorTimes[j]; // anchorTimes is a parallel array - must shift in lockstep with rows[]
         j--;
      }
      rows[j+1] = keyRow;
      anchorTimes[j+1] = keyAnchor;
   }
}

// The Commit 2 entry point. Returns true with rows[]/manifest fully
// filled only on success. Returns false, with rows[] empty and
// manifest at Init() defaults, on ANY fail-closed condition - no
// partial dataset, manifest, or serialized output, per the Commit 2
// contract's own normative rules.
bool TrainingDatasetExport_BuildDataset(string fileName, string modelTarget, TrainingDatasetRow &rows[], TrainingDatasetManifest &manifest)
{
   ArrayResize(rows, 0);
   TrainingDatasetManifest_Init(manifest);

   if(modelTarget == "") return false;

   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);

   EventStoreValidationReport validation = EventStoreValidator_ValidateLines(lines);
   if(!validation.ok) return false;

   FeatureSnapshotProjectionReport fsReport = FeatureSnapshotProjection_RebuildFromFile(fileName);
   if(!fsReport.ok) return false;

   RiskPlanProjectionReport rpReport = RiskPlanProjection_RebuildFromFile(fileName);
   if(!rpReport.ok) return false;

   // source_store_fingerprint: a hash of the INPUT (every validated
   // line, in original file order), not the output - two different
   // stores must never fingerprint identically, and two identical
   // stores must always fingerprint identically.
   string fingerprintPayload = "";
   for(int i = 0; i < n; i++)
   {
      if(i > 0) fingerprintPayload += "\n";
      fingerprintPayload += lines[i];
   }
   string sourceStoreFingerprint = Ids_Sha256Hex(fingerprintPayload);

   int candCount = CandidateProjection_Count();
   TrainingDatasetRow builtRows[];
   datetime builtAnchors[];
   int builtCount = 0;

   string seenRowIds[];
   string seenRowHashes[];
   int seenCount = 0;

   for(int i = 0; i < candCount; i++)
   {
      CandidateProjectionRecord candRec;
      CandidateProjection_GetAt(i, candRec);

      FeatureSnapshotProjectionRecord fsRec;
      if(!TrainingDatasetExport_FindSnapshotForCandidate(candRec.candidate_id, fsRec))
         continue; // no FeatureSnapshot yet - a normal lifecycle state, not a failure

      RiskPlanProjectionRecord rpRec;
      if(!TrainingDatasetExport_FindPlanForCandidate(candRec.candidate_id, rpRec))
         continue; // no ALLOWED RiskPlan yet - a normal lifecycle state, not a failure

      TradeCandidate candidate;
      TrainingDatasetExport_CandidateFromProjection(candRec, candidate);
      FeatureSnapshot snapshot;
      TrainingDatasetExport_SnapshotFromProjection(fsRec, snapshot);
      RiskPlan plan;
      TrainingDatasetExport_PlanFromProjection(rpRec, plan);

      TrainingDatasetRow row;
      if(!BuildTrainingDatasetRow(candidate, snapshot, plan, false, "", "", "", modelTarget, row))
         continue; // BuildTrainingDatasetRow's own fail-closed validation found something wrong with this candidate specifically - skip it, not the whole export (mirrors "a candidate without an ALLOWED plan gets no row" already being a skip, not a failure)

      // Duplicate-identity policy (defensive - see contract doc).
      bool skipThisRow = false;
      for(int s = 0; s < seenCount; s++)
      {
         if(seenRowIds[s] == row.dataset_row_id)
         {
            if(seenRowHashes[s] == row.row_hash) { skipThisRow = true; break; } // no-op duplicate
            return false; // collision - fail the whole export closed
         }
      }
      if(skipThisRow) continue;

      ArrayResize(seenRowIds, seenCount + 1);
      ArrayResize(seenRowHashes, seenCount + 1);
      seenRowIds[seenCount] = row.dataset_row_id;
      seenRowHashes[seenCount] = row.row_hash;
      seenCount++;

      ArrayResize(builtRows, builtCount + 1);
      ArrayResize(builtAnchors, builtCount + 1);
      builtRows[builtCount] = row;
      builtAnchors[builtCount] = candRec.setup_anchor_bar_time;
      builtCount++;
   }

   // Mixed-cohort rejection: feature_schema_version and
   // split_policy_version must be uniform across the whole exported
   // cohort.
   if(builtCount > 0)
   {
      string firstFeatureSchema = builtRows[0].feature_schema_version;
      string firstSplitPolicy   = builtRows[0].split_policy_version;
      for(int i = 1; i < builtCount; i++)
      {
         if(builtRows[i].feature_schema_version != firstFeatureSchema) return false;
         if(builtRows[i].split_policy_version != firstSplitPolicy) return false;
      }
   }

   TrainingDatasetExport_SortRows(builtRows, builtAnchors);

   ArrayResize(rows, builtCount);
   for(int i = 0; i < builtCount; i++)
      rows[i] = builtRows[i];

   string datasetHash = TrainingDatasetManifest_DatasetHash(rows);

   manifest.dataset_id                 = Ids_TrainingDatasetId(fileName, modelTarget, datasetHash);
   manifest.dataset_hash               = datasetHash;
   manifest.feature_schema_version     = (builtCount > 0) ? rows[0].feature_schema_version : "";
   manifest.label_schema_version       = MLQUANTAI_LABEL_SCHEMA_B8_2_V1;
   manifest.split_policy_version       = (builtCount > 0) ? rows[0].split_policy_version : MLQUANTAI_DATASET_SPLIT_POLICY_V1;
   manifest.model_target               = modelTarget;
   manifest.row_count                  = builtCount;
   manifest.labeled_count               = 0; // Commit 2 never produces a labeled row - see contract doc
   manifest.unlabeled_count              = builtCount;
   manifest.source_store_fingerprint      = sourceStoreFingerprint;

   int trainCount = 0, validationCount = 0, testCount = 0;
   for(int i = 0; i < builtCount; i++)
   {
      if(rows[i].split == DATASET_SPLIT_TRAIN)           trainCount++;
      else if(rows[i].split == DATASET_SPLIT_VALIDATION) validationCount++;
      else                                                 testCount++;
   }
   manifest.train_count      = trainCount;
   manifest.validation_count = validationCount;
   manifest.test_count       = testCount;

   return true;
}

#endif // __MLQUANTAI_TRAININGDATASETEXPORT_MQH__
