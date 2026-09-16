//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_                  |
//| TrainingDatasetManifestEventEmission.mqh                           |
//| B8.6 Commit 1 (QA-frozen, Docs/PhaseB_B8_6_                        |
//| ModelTrainingInferenceIntegrationContract.md §5.6, final verdict):  |
//| the durable write path for EVENT_TYPE_TRAINING_DATASET_CREATED.      |
//| Offline/operator-triggered export-time only - never a live OnTick     |
//| concern, matching §3.2's "dataset export is offline" framing.          |
//|                                                                          |
//| Idempotency policy, FROZEN (QA's final verdict on §5.6):                 |
//|   same dataset_id + same dataset_hash      -> idempotent no-op            |
//|   same dataset_id + DIFFERENT dataset_hash -> REJECTED/FAILED EXPORT,      |
//|                                                 a structured error,          |
//|                                                 NEVER Safe Mode, NEVER an      |
//|                                                 overwrite (QA: this export      |
//|                                                 path is offline/operator-         |
//|                                                 triggered, architecturally         |
//|                                                 separate from the live EA's          |
//|                                                 trading-safety loop)                  |
//|   no existing record, durable append itself fails -> Safe Mode DOES trip,              |
//|                                                 same LIFECYCLE-event precedent           |
//|                                                 every other durable write in this          |
//|                                                 codebase already follows.                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_TRAININGDATASETMANIFESTEVENTEMISSION_MQH__
#define __MLQUANTAI_TRAININGDATASETMANIFESTEVENTEMISSION_MQH__

#include "MLQuantAI_EventStore.mqh"
#include "MLQuantAI_SafeModeState.mqh"
#include "../../AI/MLQuantAI_TrainingDatasetManifestRecord.mqh"

enum ENUM_TRAINING_DATASET_EMIT_RESULT
{
   TRAINING_DATASET_EMIT_NONE,
   TRAINING_DATASET_EMIT_RECORDED,             // fresh, first-time durable write succeeded
   TRAINING_DATASET_EMIT_ALREADY_RECORDED,     // idempotent no-op - identical content already durable
   TRAINING_DATASET_EMIT_REJECTED_COLLISION,   // same dataset_id, different dataset_hash - rejected export, NOT Safe Mode
   TRAINING_DATASET_EMIT_FAILED                // durable write itself failed - Safe Mode already tripped
};

string TrainingDatasetEmitResultToString(ENUM_TRAINING_DATASET_EMIT_RESULT r)
{
   switch(r)
   {
      case TRAINING_DATASET_EMIT_RECORDED:           return "recorded";
      case TRAINING_DATASET_EMIT_ALREADY_RECORDED:    return "already_recorded";
      case TRAINING_DATASET_EMIT_REJECTED_COLLISION:  return "rejected_collision";
      case TRAINING_DATASET_EMIT_FAILED:              return "emit_failed";
   }
   return "none";
}

// Same extra_json convention every other derived-artifact event already
// uses (escaped strings, unquoted numbers).
string TrainingDatasetManifestRecord_ToExtraJson(const TrainingDatasetManifestRecord &rec)
{
   string s = "";
   s += "\"training_dataset_schema_version\":\"" + EventSerializer_Escape(rec.training_dataset_schema_version) + "\",";
   s += "\"dataset_id\":\""                        + EventSerializer_Escape(rec.dataset_id) + "\",";
   s += "\"dataset_hash\":\""                        + EventSerializer_Escape(rec.dataset_hash) + "\",";
   s += "\"split_policy_version\":\""                  + EventSerializer_Escape(rec.split_policy_version) + "\",";
   s += "\"label_schema_version\":\""                    + EventSerializer_Escape(rec.label_schema_version) + "\",";
   s += "\"model_target\":\""                              + EventSerializer_Escape(rec.model_target) + "\",";
   s += "\"row_count\":"                                    + IntegerToString(rec.row_count) + ",";
   s += "\"export_server_time\":\""                          + TimeToString(rec.export_server_time, TIME_DATE|TIME_SECONDS) + "\"";
   return s;
}

// The entry point. `lines` must already be a fresh read of the current
// durable event store (caller's responsibility, matching every other
// idempotency-checked emitter in this codebase - e.g.
// RecordRealizedOutcomeCommand_Process's own RealizedOutcomeProjection_
// TryGet call).
ENUM_TRAINING_DATASET_EMIT_RESULT TrainingDatasetManifest_EmitTrainingDatasetCreated(const TrainingDatasetManifestRecord &rec, const string &lines[])
{
   ENUM_TRAINING_DATASET_IDEMPOTENCY idem = TrainingDatasetManifestRecord_CheckIdempotency(rec, lines);

   if(idem == TRAINING_DATASET_IDEMPOTENCY_DUPLICATE_SAME_HASH)
      return TRAINING_DATASET_EMIT_ALREADY_RECORDED;

   if(idem == TRAINING_DATASET_IDEMPOTENCY_COLLISION_DIFFERENT_HASH)
      return TRAINING_DATASET_EMIT_REJECTED_COLLISION; // frozen: NEVER Safe Mode for this class

   string extraJson = TrainingDatasetManifestRecord_ToExtraJson(rec);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_TRAINING_DATASET_CREATED), "training dataset created", extraJson))
   {
      SafeMode_Trip(StringFormat("TRAINING_DATASET_CREATED append failed for dataset_id=%s", rec.dataset_id));
      return TRAINING_DATASET_EMIT_FAILED;
   }
   return TRAINING_DATASET_EMIT_RECORDED;
}

#endif // __MLQUANTAI_TRAININGDATASETMANIFESTEVENTEMISSION_MQH__
