//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/                             |
//| MLQuantAI_RolloutStageEventEmission.mqh                             |
//| C5.2 Commit 1 (QA-frozen FINAL DESIGN FREEZE, Docs/PhaseC_C5_2_     |
//| ControlledExecutionEnvironmentLadderContract.md §4): the durable      |
//| write path for EVENT_TYPE_EXECUTION_ROLLOUT_STAGE_CHANGED. Models      |
//| the pure processor a future TRANSITION_ROLLOUT_STAGE ceremony-command   |
//| handler will call - not itself wired into MLQuantAI.mq5 (the ceremony    |
//| command type/mailbox dispatch is its own, separately authorized future    |
//| step).                                                                      |
//|                                                                               |
//| Policy (frozen, same LIFECYCLE-event precedent every other durable write     |
//| in this codebase already follows - see MLQuantAI_TrainingDatasetManifest-     |
//| EventEmission.mqh for the identical pattern):                                  |
//|   RolloutStageTransition_Evaluate() rejects the attempt (a business-rule         |
//|     decision, e.g. not-adjacent/environment-invalid/criteria-not-frozen)          |
//|     -> REJECTED, no durable write attempted at all, NEVER Safe Mode.                |
//|   The evaluator ALLOWS it but the durable append itself fails                        |
//|     -> Safe Mode DOES trip - a write failure is a real integrity fault,                |
//|        never merely logged and ignored.                                                  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ROLLOUTSTAGEEVENTEMISSION_MQH__
#define __MLQUANTAI_ROLLOUTSTAGEEVENTEMISSION_MQH__

#include "MLQuantAI_EventStore.mqh"
#include "MLQuantAI_SafeModeState.mqh"
#include "../../Core/MLQuantAI_Enums.mqh"
#include "../../Execution/MLQuantAI_RolloutStageTransitionEvaluate.mqh"

enum ENUM_ROLLOUT_STAGE_EMIT_RESULT
{
   ROLLOUT_STAGE_EMIT_NONE,
   ROLLOUT_STAGE_EMIT_RECORDED,   // fresh durable write succeeded
   ROLLOUT_STAGE_EMIT_REJECTED,   // RolloutStageTransition_Evaluate refused - no write attempted, NOT Safe Mode
   ROLLOUT_STAGE_EMIT_FAILED      // the durable append itself failed - Safe Mode already tripped
};

string RolloutStageEmitResultToString(ENUM_ROLLOUT_STAGE_EMIT_RESULT r)
{
   switch(r)
   {
      case ROLLOUT_STAGE_EMIT_RECORDED: return "recorded";
      case ROLLOUT_STAGE_EMIT_REJECTED: return "rejected";
      case ROLLOUT_STAGE_EMIT_FAILED:   return "emit_failed";
   }
   return "none";
}

// authorizedBy/evidenceReference are free-text fields (§4 - same
// discipline as this project's existing ceremony-command operator
// fields). transition_server_time is captured internally via
// TimeCurrent() at the moment of the durable write (C3.8 §5 clock
// discipline) - callers never supply it.
//
// Same caller contract as RolloutStageTransition_Evaluate() (QA's own
// diff-review finding): fromStage must be the caller's freshly-replayed
// current stage (RolloutStageProjection_ReplayCurrent()), never
// operator-supplied - this function does not itself read the durable log
// to verify it. Enforcing that belongs to the future ceremony-command
// handler, not to this pure processor.
ENUM_ROLLOUT_STAGE_EMIT_RESULT RolloutStageTransition_Emit(ENUM_EXECUTION_ROLLOUT_STAGE fromStage, ENUM_EXECUTION_ROLLOUT_STAGE toStage,
                                                             ENUM_EXECUTION_ENVIRONMENT_MODE environmentMode,
                                                             string authorizedBy, string evidenceReference,
                                                             ENUM_ROLLOUT_TRANSITION_RESULT &outEvaluation)
{
   outEvaluation = RolloutStageTransition_Evaluate(fromStage, toStage, environmentMode);
   if(!RolloutTransitionResult_IsAllowed(outEvaluation))
      return ROLLOUT_STAGE_EMIT_REJECTED;

   datetime transitionServerTime = TimeCurrent();

   string extraJson = "";
   extraJson += "\"from_stage\":\""              + EventSerializer_Escape(ExecutionRolloutStageToString(fromStage)) + "\",";
   extraJson += "\"to_stage\":\""                + EventSerializer_Escape(ExecutionRolloutStageToString(toStage)) + "\",";
   extraJson += "\"environment_mode\":\""        + EventSerializer_Escape(ExecutionEnvironmentModeToString(environmentMode)) + "\",";
   extraJson += "\"authorized_by\":\""           + EventSerializer_Escape(authorizedBy) + "\",";
   extraJson += "\"evidence_reference\":\""      + EventSerializer_Escape(evidenceReference) + "\",";
   extraJson += "\"direction\":\""               + EventSerializer_Escape(RolloutTransitionResultToString(outEvaluation)) + "\",";
   extraJson += "\"transition_server_time\":\""  + TimeToString(transitionServerTime, TIME_DATE|TIME_SECONDS) + "\"";

   string message = StringFormat("rollout_stage transition: %s -> %s", ExecutionRolloutStageToString(fromStage), ExecutionRolloutStageToString(toStage));

   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_ROLLOUT_STAGE_CHANGED), message, extraJson))
   {
      SafeMode_Trip(StringFormat("EXECUTION_ROLLOUT_STAGE_CHANGED append failed for %s -> %s", ExecutionRolloutStageToString(fromStage), ExecutionRolloutStageToString(toStage)));
      return ROLLOUT_STAGE_EMIT_FAILED;
   }
   return ROLLOUT_STAGE_EMIT_RECORDED;
}

#endif // __MLQUANTAI_ROLLOUTSTAGEEVENTEMISSION_MQH__
