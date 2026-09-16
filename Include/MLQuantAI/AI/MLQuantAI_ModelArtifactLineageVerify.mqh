//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_ModelArtifactLineageVerify.mqh            |
//| B8.6 Commit 1 (QA-frozen, Docs/PhaseB_B8_6_                        |
//| ModelTrainingInferenceIntegrationContract.md §5.7): a read-only,     |
//| pure diagnostic composition over two already-sealed/already-built     |
//| sources - the same "pure composition, never a new authority" pattern   |
//| C3.8 established for BrokerReconciliation/TransactionMatching/           |
//| DeferredTransactionProcessor.                                             |
//|                                                                              |
//| MLQuantAI_ModelArtifact.mqh/MLQuantAI_ModelArtifactBuilder.mqh/                |
//| MLQuantAI_ModelArtifactEventEmission.mqh/MLQuantAI_ModelArtifactProjection.mqh   |
//| (Class 1, untouched) are only ever READ here - this file adds no write,           |
//| no candidate-lifecycle authority, no Safe Mode action, and is NOT wired            |
//| into ModelArtifact_CheckCompatibility()'s existing sealed runtime gate -            |
//| that would require its own separate authorization, not granted by this               |
//| contract. An operator (or a future, separately-authorized promotion-gate               |
//| consumer) runs this diagnostic BEFORE deciding to promote a model, never                 |
//| as part of the sealed compatibility gate itself.                                            |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MODELARTIFACTLINEAGEVERIFY_MQH__
#define __MLQUANTAI_MODELARTIFACTLINEAGEVERIFY_MQH__

#include "MLQuantAI_ModelArtifact.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh"

enum ENUM_LINEAGE_VERIFY_RESULT
{
   LINEAGE_VERIFY_NONE,
   LINEAGE_VERIFY_VERIFIED,     // a TRAINING_DATASET_CREATED record exists for this dataset_id, and its dataset_hash matches
   LINEAGE_VERIFY_NO_RECORD,    // no TRAINING_DATASET_CREATED record exists for artifact.training_dataset_id at all
   LINEAGE_VERIFY_HASH_MISMATCH // a record exists for that dataset_id, but its dataset_hash does NOT match artifact.training_dataset_hash
};

string LineageVerifyResultToString(ENUM_LINEAGE_VERIFY_RESULT r)
{
   switch(r)
   {
      case LINEAGE_VERIFY_VERIFIED:      return "verified";
      case LINEAGE_VERIFY_NO_RECORD:     return "no_record";
      case LINEAGE_VERIFY_HASH_MISMATCH: return "hash_mismatch";
   }
   return "none";
}

// Pure, read-only (CORRECTED per QA's pre-push diff audit - same class of
// fix as TrainingDatasetManifestRecord_CheckIdempotency): scans EVERY
// already-loaded durable line matching artifact.training_dataset_id, never
// stopping at the first match. The original version could report VERIFIED
// off a first-encountered matching-hash line while a LATER, genuinely
// conflicting line for the same dataset_id went uninspected - exactly the
// corruption case this diagnostic exists to catch. A mismatch found
// anywhere is decisive (safe to short-circuit on); a match is never
// conclusive until every line has been checked. No write, no mutation, no
// Safe Mode, no candidate-lifecycle authority.
ENUM_LINEAGE_VERIFY_RESULT ModelArtifactLineage_Verify(const ModelArtifact &artifact, const string &lines[])
{
   bool foundAny = false;
   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != "TRAINING_DATASET_CREATED") continue;
      if(EventSerializer_GetStr(lines[i], "dataset_id") != artifact.training_dataset_id) continue;

      foundAny = true;
      string foundHash = EventSerializer_GetStr(lines[i], "dataset_hash");
      if(foundHash != artifact.training_dataset_hash)
         return LINEAGE_VERIFY_HASH_MISMATCH; // any mismatch, anywhere in the scan, is decisive
   }
   if(!foundAny) return LINEAGE_VERIFY_NO_RECORD;
   return LINEAGE_VERIFY_VERIFIED; // every matching line (at least one) agreed
}

#endif // __MLQUANTAI_MODELARTIFACTLINEAGEVERIFY_MQH__
