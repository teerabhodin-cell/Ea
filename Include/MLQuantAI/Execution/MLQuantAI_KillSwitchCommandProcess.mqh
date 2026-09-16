//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_KillSwitchCommandProcess.mqh       |
//| C5.2 Commit 2 (QA-frozen Design Revision 2, Docs/PhaseC_C5_2_Commit2_ |
//| RuntimeIntegrationDesignContract.md §A/§D): the pure processors the     |
//| ENGAGE_KILL_SWITCH/CLEAR_KILL_SWITCH ceremony-commands' thin wrappers     |
//| (MLQuantAI.mq5, EngageKillSwitchCommand()/ClearKillSwitchCommand()) call -  |
//| same "thin wrapper + pure core" pattern as MLQuantAI_RolloutStageTransition-|
//| CommandProcess.mqh.                                                            |
//|                                                                                   |
//| Neither processor is ever vetoed by the kill switch's own active state (§A's      |
//| corrected wording, Design Revision 2): CLEAR must always be reachable while         |
//| active (it IS the recovery path, §7.2), ENGAGE is idempotent-in-spirit. Neither      |
//| performs the current-state cross-validity check either - both operate on              |
//| environment_mode directly and consume no rollout_stage input.                            |
//|                                                                                              |
//| Pure with respect to their OWN inputs: lines[]/environmentMode are supplied by                 |
//| the caller (never re-read here), matching MLQuantAI_RolloutStageTransitionCommand-               |
//| Process.mqh's own convention. The only non-pure action either function ever                        |
//| takes is the one durable write KillSwitch_Engage()/KillSwitch_Clear() (Commit 1,                       |
//| frozen, unmodified) itself may perform.                                                                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_KILLSWITCHCOMMANDPROCESS_MQH__
#define __MLQUANTAI_KILLSWITCHCOMMANDPROCESS_MQH__

#include "../Core/MLQuantAI_Enums.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_RolloutStageProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_KillSwitchEventEmission.mqh"

enum ENUM_KILL_SWITCH_CMD_RESULT
{
   KILL_SWITCH_CMD_NONE,
   KILL_SWITCH_CMD_ENGAGED,
   KILL_SWITCH_CMD_CLEARED,
   KILL_SWITCH_CMD_FAILED   // the durable append itself failed - Safe Mode already tripped
};

string KillSwitchCmdResultToString(ENUM_KILL_SWITCH_CMD_RESULT r)
{
   switch(r)
   {
      case KILL_SWITCH_CMD_ENGAGED: return "engaged";
      case KILL_SWITCH_CMD_CLEARED: return "cleared";
      case KILL_SWITCH_CMD_FAILED:  return "emit_durable_write_failed";
   }
   return "none";
}

struct KillSwitchCommandResult
{
   ENUM_KILL_SWITCH_CMD_RESULT status;
   string                      reason_code; // ceremony-log-ready reason string
};

void KillSwitchCommandResult_Init(KillSwitchCommandResult &r)
{
   r.status      = KILL_SWITCH_CMD_NONE;
   r.reason_code = "";
}

// currentStage: the caller's freshly-replayed current rollout_stage for
// this environmentMode (RolloutStageProjection_ReplayCurrent()) - supplied
// explicitly, never re-derived here, matching MLQuantAI_RolloutStageTransition
// CommandProcess.mqh's own convention.
void KillSwitchEngageCommand_Process(string authorizedBy, ENUM_EXECUTION_ROLLOUT_STAGE currentStage,
                                       ENUM_EXECUTION_ENVIRONMENT_MODE environmentMode, KillSwitchCommandResult &outResult)
{
   KillSwitchCommandResult_Init(outResult);

   ENUM_KILL_SWITCH_EMIT_RESULT emitResult = KillSwitch_Engage(environmentMode, authorizedBy, currentStage);
   if(emitResult == KILL_SWITCH_EMIT_ENGAGED)
   {
      outResult.status      = KILL_SWITCH_CMD_ENGAGED;
      outResult.reason_code = KillSwitchCmdResultToString(outResult.status);
   }
   else // KILL_SWITCH_EMIT_FAILED
   {
      outResult.status      = KILL_SWITCH_CMD_FAILED;
      outResult.reason_code = KillSwitchCmdResultToString(outResult.status);
   }
}

void KillSwitchClearCommand_Process(string authorizedBy, ENUM_EXECUTION_ENVIRONMENT_MODE environmentMode, KillSwitchCommandResult &outResult)
{
   KillSwitchCommandResult_Init(outResult);

   ENUM_KILL_SWITCH_EMIT_RESULT emitResult = KillSwitch_Clear(environmentMode, authorizedBy);
   if(emitResult == KILL_SWITCH_EMIT_CLEARED)
   {
      outResult.status      = KILL_SWITCH_CMD_CLEARED;
      outResult.reason_code = KillSwitchCmdResultToString(outResult.status);
   }
   else // KILL_SWITCH_EMIT_FAILED
   {
      outResult.status      = KILL_SWITCH_CMD_FAILED;
      outResult.reason_code = KillSwitchCmdResultToString(outResult.status);
   }
}

#endif // __MLQUANTAI_KILLSWITCHCOMMANDPROCESS_MQH__
