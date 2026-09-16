//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/                             |
//| MLQuantAI_RolloutStageProjection.mqh                                |
//| C5.2 Commit 1 (QA-frozen FINAL DESIGN FREEZE, Docs/PhaseC_C5_2_     |
//| ControlledExecutionEnvironmentLadderContract.md §4/§7.1): pure,      |
//| read-only replay over already-loaded durable EventStore lines -       |
//| models what a future OnInit wiring commit WOULD call (§4 rule 5,       |
//| §7.1), without itself being wired into MLQuantAI.mq5's real OnInit()    |
//| - that wiring remains its own, separately authorized future step, per   |
//| the frozen contract's §11/"No OnInit wiring of any kind".                |
//|                                                                             |
//| "Latest wins" throughout, same precedent StateProjector/SafeMode           |
//| replay already use in this codebase: the EventStore is append-only,        |
//| single-writer, so scanning `lines` in file order and overwriting the        |
//| working answer on every further match naturally yields the                   |
//| chronologically latest event, with no need to separately parse/compare        |
//| sequence_number.                                                                |
//|                                                                                    |
//| Pure: no EventStore write, no live MT5 API, no Safe Mode, no OrderSend,           |
//| no candidate-lifecycle authority.                                                  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ROLLOUTSTAGEPROJECTION_MQH__
#define __MLQUANTAI_ROLLOUTSTAGEPROJECTION_MQH__

// MLQuantAI_Enums.mqh must come before MLQuantAI_EventSerializer.mqh -
// same empirically-found ordering requirement documented in
// MLQuantAI_CeremonyCommandMailbox.mqh's own header.
#include "../../Core/MLQuantAI_Enums.mqh"
#include "MLQuantAI_EventSerializer.mqh"
#include "../../Execution/MLQuantAI_RolloutStageCrossValidity.mqh"

// §4 rule 4 (frozen): the durable event log is the sole source of truth
// for "what is the CURRENT rollout_stage". No rollout_stage is ever
// assumed/defaulted to anything other than ROLLOUT_STAGE_NONE when no
// EXECUTION_ROLLOUT_STAGE_CHANGED event exists yet - fails closed.
// Returns true iff at least one such event was found (outStage is always
// set either way).
bool RolloutStageProjection_ReplayCurrent(const string &lines[], ENUM_EXECUTION_ROLLOUT_STAGE &outStage)
{
   outStage = ROLLOUT_STAGE_NONE;
   bool found = false;
   string targetType = EventTypeToString(EVENT_TYPE_EXECUTION_ROLLOUT_STAGE_CHANGED);

   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != targetType) continue;
      outStage = ExecutionRolloutStageFromString(EventSerializer_GetStr(lines[i], "to_stage"));
      found = true;
   }
   return found;
}

// §7.1 (frozen): KILL_SWITCH_ACTIVE is its own durable fact, scoped to
// one environment_mode (never implicitly "all" - §7's Scope section).
// Whichever of EVENT_TYPE_KILL_SWITCH_ENGAGED / _CLEARED is more recent,
// for THIS SPECIFIC environmentMode, wins - "latest event is truth",
// same precedent as every other durable-state projection in this
// codebase. Absence of any matching event means "never engaged for this
// environment_mode" (outActive = false), consistent with the kill switch
// never being auto-engaged.
bool KillSwitchProjection_ReplayActive(const string &lines[], ENUM_EXECUTION_ENVIRONMENT_MODE environmentMode, bool &outActive)
{
   outActive = false;
   bool found = false;
   string engagedType = EventTypeToString(EVENT_TYPE_KILL_SWITCH_ENGAGED);
   string clearedType = EventTypeToString(EVENT_TYPE_KILL_SWITCH_CLEARED);
   string modeStr = ExecutionEnvironmentModeToString(environmentMode);

   for(int i = 0; i < ArraySize(lines); i++)
   {
      string t = EventSerializer_GetStr(lines[i], "type");
      if(t != engagedType && t != clearedType) continue;
      if(EventSerializer_GetStr(lines[i], "environment_mode") != modeStr) continue;
      outActive = (t == engagedType);
      found = true;
   }
   return found;
}

//---------------------------------------------------------------------
// §4 rule 5 / §7.1 (frozen): the composed "OnInit-equivalent" session
// state a future wiring commit's real OnInit would establish. The raw
// replayed_stage is NEVER silently overwritten by an invalid cross-
// validity result - only environment_valid flags whether that stage may
// currently be used for a capability decision (§5). This mirrors C5.2
// revision 3's exact frozen pseudocode:
//   g_CurrentRolloutStage = ReplayLatest(...)                 -> replayed_stage
//   g_RolloutStageEnvironmentValid = IsValidForEnvironment(...) -> environment_valid
//   kill_switch_active                                          -> kill_switch_active
//---------------------------------------------------------------------
struct RolloutStageSessionState
{
   ENUM_EXECUTION_ROLLOUT_STAGE replayed_stage;
   bool                         environment_valid;
   bool                         kill_switch_active;
};

void RolloutStageSessionState_Init(RolloutStageSessionState &s)
{
   s.replayed_stage    = ROLLOUT_STAGE_NONE;
   s.environment_valid = true;  // ROLLOUT_STAGE_NONE is valid under every environment_mode (§3)
   s.kill_switch_active = false;
}

void RolloutStageReplay_EstablishSessionState(const string &lines[], ENUM_EXECUTION_ENVIRONMENT_MODE environmentMode, RolloutStageSessionState &outState)
{
   RolloutStageSessionState_Init(outState);
   RolloutStageProjection_ReplayCurrent(lines, outState.replayed_stage);
   outState.environment_valid = RolloutStage_IsValidForEnvironment(outState.replayed_stage, environmentMode);
   KillSwitchProjection_ReplayActive(lines, environmentMode, outState.kill_switch_active);
}

#endif // __MLQUANTAI_ROLLOUTSTAGEPROJECTION_MQH__
