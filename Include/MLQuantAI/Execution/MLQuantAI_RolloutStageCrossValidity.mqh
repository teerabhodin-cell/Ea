//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_RolloutStageCrossValidity.mqh      |
//| C5.2 Commit 1 (QA-frozen FINAL DESIGN FREEZE, Docs/PhaseC_C5_2_     |
//| ControlledExecutionEnvironmentLadderContract.md §3): the exhaustive  |
//| rollout_stage x environment_mode cross-validity table, as ONE pure,   |
//| single-source-of-truth predicate. Every runtime enforcement point      |
//| the frozen contract names (OnInit replay, §4 rule 5; OnTick entry,      |
//| §9; transition-time, §3's own "frozen consequence of a reject cell")     |
//| must consult THIS SAME function - never a second, independently-          |
//| written interpretation of the table.                                        |
//|                                                                               |
//| Pure: no EventStore read/write, no live MT5 API, no Safe Mode, no            |
//| candidate-lifecycle authority. A `reject` result is a fail-closed             |
//| structural fault (per §3) - callers must treat false exactly like             |
//| ROLLOUT_STAGE_NONE for every capability decision (§5), never as a              |
//| soft warning.                                                                   |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ROLLOUTSTAGECROSSVALIDITY_MQH__
#define __MLQUANTAI_ROLLOUTSTAGECROSSVALIDITY_MQH__

#include "../Core/MLQuantAI_Enums.mqh"

// §3's frozen 8x4 table, restated verbatim as code. ROLLOUT_STAGE_NONE
// is the only value valid under every environment_mode (it carries no
// capability of its own - see MLQuantAI_RolloutStageCapability.mqh).
// Every other rollout_stage has exactly one valid environment_mode;
// every other pairing is `reject`.
bool RolloutStage_IsValidForEnvironment(ENUM_EXECUTION_ROLLOUT_STAGE stage, ENUM_EXECUTION_ENVIRONMENT_MODE mode)
{
   if(stage == ROLLOUT_STAGE_NONE)
      return true; // valid under EXECUTION_ENV_NONE/_TESTER/_DEMO/_LIVE alike

   switch(stage)
   {
      case ROLLOUT_STAGE_TEST_FIXTURE:
         return mode == EXECUTION_ENV_TESTER;

      case ROLLOUT_STAGE_DEMO_DRY_RUN:
      case ROLLOUT_STAGE_DEMO_REAL_SUBMIT:
      case ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION:
         return mode == EXECUTION_ENV_DEMO;

      case ROLLOUT_STAGE_LIVE_SHADOW:
      case ROLLOUT_STAGE_LIVE_MANUAL_MICRO_SIZE:
      case ROLLOUT_STAGE_LIVE_BOUNDED_AUTOMATION:
         return mode == EXECUTION_ENV_LIVE;
   }

   return false; // unreachable for a well-formed ENUM_EXECUTION_ROLLOUT_STAGE value - fail closed regardless
}

#endif // __MLQUANTAI_ROLLOUTSTAGECROSSVALIDITY_MQH__
