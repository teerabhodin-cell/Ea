//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/                             |
//| MLQuantAI_RolloutStageObservationWindow.mqh                        |
//| §6.2 Evidence-Gate Design Contract Rev.8 (QA-frozen DESIGN FREEZE,  |
//| Docs/PhaseC_C5_2_Section6_2_EvidenceGateDesignContract.md §1): the   |
//| observation-window boundary finder. "Latest wins" scan for the      |
//| LAST EXECUTION_ROLLOUT_STAGE_CHANGED line whose to_stage equals the   |
//| stage the caller is asking about - same append-only, single-writer,   |
//| "file order is chronological order" discipline as                      |
//| RolloutStageProjection_ReplayCurrent (MLQuantAI_RolloutStageProjection.  |
//| mqh, C5.2 Commit 1, unmodified, reused here as precedent only, not       |
//| called).                                                                   |
//|                                                                              |
//| Window = every line strictly AFTER the returned index. Not found ->          |
//| outLineIndex is left at -1 and this returns false - callers (§6) must         |
//| treat that as an immediate REJECT (window_not_found), never as an              |
//| empty-but-valid window.                                                         |
//|                                                                                    |
//| Pure: no EventStore read/write, no live MT5 API, no Safe Mode, no                 |
//| OrderSend, no candidate-lifecycle authority.                                       |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ROLLOUTSTAGEOBSERVATIONWINDOW_MQH__
#define __MLQUANTAI_ROLLOUTSTAGEOBSERVATIONWINDOW_MQH__

#include "../../Core/MLQuantAI_Enums.mqh"
#include "MLQuantAI_EventSerializer.mqh"

// Returns true and sets outLineIndex to the index (within lines[]) of the
// LATEST EXECUTION_ROLLOUT_STAGE_CHANGED line whose own to_stage equals
// `stage`. Returns false (outLineIndex == -1) if no such line exists at
// all - §6.2's own frozen rule is that this is a hard REJECT, never an
// empty-but-usable window.
bool RolloutStageObservationWindow_FindStart(const string &lines[], ENUM_EXECUTION_ROLLOUT_STAGE stage, int &outLineIndex)
{
   outLineIndex = -1;
   bool found = false;
   string targetType = EventTypeToString(EVENT_TYPE_EXECUTION_ROLLOUT_STAGE_CHANGED);
   string targetStageStr = ExecutionRolloutStageToString(stage);

   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != targetType) continue;
      if(EventSerializer_GetStr(lines[i], "to_stage") != targetStageStr) continue;
      outLineIndex = i;
      found = true;
   }
   return found;
}

#endif // __MLQUANTAI_ROLLOUTSTAGEOBSERVATIONWINDOW_MQH__
