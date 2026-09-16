//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/                             |
//| MLQuantAI_KillSwitchEventEmission.mqh                               |
//| C5.2 Commit 1 (QA-frozen FINAL DESIGN FREEZE, Docs/PhaseC_C5_2_     |
//| ControlledExecutionEnvironmentLadderContract.md §7/§7.1/§7.2): the    |
//| durable write path for EVENT_TYPE_KILL_SWITCH_ENGAGED/_CLEARED.        |
//| Models the pure processor a future ENGAGE_KILL_SWITCH/CLEAR_KILL_       |
//| SWITCH ceremony-command handler will call - not itself wired into        |
//| MLQuantAI.mq5 (ceremony command type/mailbox dispatch is its own,         |
//| separately authorized future step).                                        |
//|                                                                               |
//| Engage (§7 Effect): durably records KILL_SWITCH_ENGAGED FIRST - this is       |
//| the primary, unconditional-veto fact (RolloutStage_PermitsPipelineRun         |
//| checks it before anything else, so the safety guarantee never depends          |
//| on step 2 below succeeding). THEN, if the current rollout_stage is not          |
//| already ROLLOUT_STAGE_NONE, also durably records the "strongest rollback"        |
//| (§7 Effect / §8) via the SAME EXECUTION_ROLLOUT_STAGE_CHANGED event type           |
//| RolloutStageTransition_Emit already writes - a kill switch is not a               |
//| separate rollback mechanism, it triggers the existing one.                          |
//|                                                                                        |
//| Clear (§7.2): durably records KILL_SWITCH_CLEARED ONLY. Never touches                  |
//| rollout_stage - clearing alone restores no automation capability; a fresh,               |
//| separate forward TRANSITION_ROLLOUT_STAGE starting from ROLLOUT_STAGE_NONE                 |
//| is a distinct, later ceremony command, out of this file's scope entirely.                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_KILLSWITCHEVENTEMISSION_MQH__
#define __MLQUANTAI_KILLSWITCHEVENTEMISSION_MQH__

#include "MLQuantAI_EventStore.mqh"
#include "MLQuantAI_SafeModeState.mqh"
#include "MLQuantAI_RolloutStageEventEmission.mqh"
#include "../../Core/MLQuantAI_Enums.mqh"

enum ENUM_KILL_SWITCH_EMIT_RESULT
{
   KILL_SWITCH_EMIT_NONE,
   KILL_SWITCH_EMIT_ENGAGED,
   KILL_SWITCH_EMIT_CLEARED,
   KILL_SWITCH_EMIT_FAILED
};

string KillSwitchEmitResultToString(ENUM_KILL_SWITCH_EMIT_RESULT r)
{
   switch(r)
   {
      case KILL_SWITCH_EMIT_ENGAGED: return "engaged";
      case KILL_SWITCH_EMIT_CLEARED: return "cleared";
      case KILL_SWITCH_EMIT_FAILED:  return "emit_failed";
   }
   return "none";
}

// currentStage is the caller's already-replayed current rollout_stage for
// this environmentMode (§4 rule 4's replay) - supplied explicitly rather
// than re-derived here, keeping this function pure/testable.
ENUM_KILL_SWITCH_EMIT_RESULT KillSwitch_Engage(ENUM_EXECUTION_ENVIRONMENT_MODE environmentMode, string authorizedBy, ENUM_EXECUTION_ROLLOUT_STAGE currentStage)
{
   datetime engagedServerTime = TimeCurrent();
   string extraJson = "";
   extraJson += "\"environment_mode\":\""   + EventSerializer_Escape(ExecutionEnvironmentModeToString(environmentMode)) + "\",";
   extraJson += "\"authorized_by\":\""      + EventSerializer_Escape(authorizedBy) + "\",";
   extraJson += "\"engaged_server_time\":\""+ TimeToString(engagedServerTime, TIME_DATE|TIME_SECONDS) + "\"";

   string message = StringFormat("kill switch engaged for environment_mode=%s", ExecutionEnvironmentModeToString(environmentMode));

   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_KILL_SWITCH_ENGAGED), message, extraJson))
   {
      SafeMode_Trip(StringFormat("KILL_SWITCH_ENGAGED append failed for environment_mode=%s", ExecutionEnvironmentModeToString(environmentMode)));
      return KILL_SWITCH_EMIT_FAILED;
   }

   if(currentStage != ROLLOUT_STAGE_NONE)
   {
      ENUM_ROLLOUT_TRANSITION_RESULT eval;
      ENUM_ROLLOUT_STAGE_EMIT_RESULT rollbackResult = RolloutStageTransition_Emit(currentStage, ROLLOUT_STAGE_NONE, environmentMode,
                                                                                    authorizedBy, "kill_switch_engaged", eval);
      if(rollbackResult == ROLLOUT_STAGE_EMIT_FAILED)
         return KILL_SWITCH_EMIT_FAILED; // SafeMode already tripped inside RolloutStageTransition_Emit
      // ROLLOUT_STAGE_EMIT_REJECTED is not structurally reachable here -
      // ROLLOUT_STAGE_NONE passes §3's cross-validity table under every
      // environment_mode, and a regression is always ALLOWED_ROLLBACK
      // (§4 rule 3) - but a rejection, if it ever occurred, would still
      // leave KILL_SWITCH_ENGAGED durably recorded and the veto in force.
   }

   return KILL_SWITCH_EMIT_ENGAGED;
}

ENUM_KILL_SWITCH_EMIT_RESULT KillSwitch_Clear(ENUM_EXECUTION_ENVIRONMENT_MODE environmentMode, string authorizedBy)
{
   datetime clearedServerTime = TimeCurrent();
   string extraJson = "";
   extraJson += "\"environment_mode\":\""   + EventSerializer_Escape(ExecutionEnvironmentModeToString(environmentMode)) + "\",";
   extraJson += "\"authorized_by\":\""      + EventSerializer_Escape(authorizedBy) + "\",";
   extraJson += "\"cleared_server_time\":\""+ TimeToString(clearedServerTime, TIME_DATE|TIME_SECONDS) + "\"";

   string message = StringFormat("kill switch cleared for environment_mode=%s", ExecutionEnvironmentModeToString(environmentMode));

   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_KILL_SWITCH_CLEARED), message, extraJson))
   {
      SafeMode_Trip(StringFormat("KILL_SWITCH_CLEARED append failed for environment_mode=%s", ExecutionEnvironmentModeToString(environmentMode)));
      return KILL_SWITCH_EMIT_FAILED;
   }
   return KILL_SWITCH_EMIT_CLEARED;
}

#endif // __MLQUANTAI_KILLSWITCHEVENTEMISSION_MQH__
