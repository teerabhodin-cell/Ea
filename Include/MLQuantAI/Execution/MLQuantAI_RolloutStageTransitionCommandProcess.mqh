//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_RolloutStageTransitionCommandProcess.mqh |
//| C5.2 Commit 2 (QA-frozen Design Revision 2, Docs/PhaseC_C5_2_Commit2_ |
//| RuntimeIntegrationDesignContract.md §A/§D): the pure processor the     |
//| TRANSITION_ROLLOUT_STAGE ceremony-command's thin wrapper (MLQuantAI.mq5, |
//| TransitionRolloutStageCommand()) calls - same "thin wrapper + pure       |
//| core" pattern this project uses everywhere (e.g.                          |
//| MLQuantAI_RealizedOutcomeCommandHandler.mqh's RecordRealizedOutcomeCommand_|
//| Process()). Factored out of the wrapper (rather than inlined in              |
//| MLQuantAI.mq5, which cannot be #include'd by a test script) so the exact      |
//| sequence Design Revision 2 froze is independently, automatically              |
//| testable - see Tests/MLQuantAI_Test_C5_2_Commit2_RolloutStageTransition        |
//| CommandProcess.mq5.                                                              |
//|                                                                                     |
//| Frozen sequence (§A, unchanged from the design freeze - this file only                |
//| gives it a name and a home):                                                            |
//|   1. kill switch veto (unconditional, checked first)                                      |
//|   2. current-state cross-validity (QA's revision-2 blocker - refuses BEFORE                |
//|      the target is even evaluated, so a stale/invalid current state can                      |
//|      never be "laundered" through a transition that only checks its target).                   |
//|      §6.1 Rev.4 §1.2 amendment (QA Implementation Authorization 2026-09-17):                      |
//|      branches on isDeclaredEnvironmentCrossingPair(currentStage, targetStage)                      |
//|      FIRST - false (every pair except (TEST_FIXTURE, DEMO_DRY_RUN), including                        |
//|      (DEMO_BOUNDED_AUTOMATION, LIVE_SHADOW)) runs the ORIGINAL blanket check,                           |
//|      byte-for-byte unchanged (Commit-2's own frozen regression test #6); true                            |
//|      (ONLY that one declared pair) runs RolloutStage61Crossing_Evaluate()                                  |
//|      INSTEAD of the blanket check - never both, never neither.                                               |
//|   2.5. §6.2 Evidence-Gate (RolloutGateReadiness_Evaluate, QA Implementation              |
//|      Authorization 2026-09-17) - inserted STRICTLY BEFORE step 3, gated to                    |
//|      ONLY the (DEMO_DRY_RUN -> DEMO_REAL_SUBMIT) pair (§7 Authority Boundary:                    |
//|      the evaluator is called from THIS processor, never from inside Commit-1-                     |
//|      sealed RolloutStageTransition_IsForwardPairImplemented/_Evaluate, whose                          |
//|      signatures stay completely unchanged). Every other pair skips this step                            |
//|      entirely and proceeds straight to step 3, byte-for-byte unaffected.                                    |
//|   3. RolloutStageTransition_Emit() (Commit 1, frozen, unmodified) - §6.1 Rev.4                     |
//|      §1.5 amendment flips RolloutStageTransition_IsForwardPairImplemented(                            |
//|      TEST_FIXTURE, DEMO_DRY_RUN) to true (MLQuantAI_RolloutStageTransitionEvaluate.                      |
//|      mqh), the single point of truth §1.2's whitelist and this Step 3 gate both                            |
//|      agree on.                                                                                                |
//|                                                                                                        |
//| Pure with respect to its OWN inputs: lines[]/environmentMode are supplied                               |
//| by the caller (never re-read here) - the FRESH-read discipline (§A) lives at                              |
//| the call site (the thin wrapper), not in this function, matching Commit 1's                                 |
//| own established style of taking lines[]/environmentMode as explicit                                           |
//| parameters rather than consulting a global registry. The only non-pure                                          |
//| action this function ever takes is the one durable write                                                          |
//| RolloutStageTransition_Emit() itself may perform (Commit 1, frozen,                                                  |
//| unmodified - Safe Mode policy unchanged).                                                                               |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ROLLOUTSTAGETRANSITIONCOMMANDPROCESS_MQH__
#define __MLQUANTAI_ROLLOUTSTAGETRANSITIONCOMMANDPROCESS_MQH__

#include "../Core/MLQuantAI_Enums.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_RolloutStageProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_RolloutStageEventEmission.mqh"
#include "MLQuantAI_RolloutGateReadinessEvaluate.mqh"
#include "MLQuantAI_RolloutStage61CrossingEvaluate.mqh"

enum ENUM_ROLLOUT_STAGE_TRANSITION_CMD_RESULT
{
   ROLLOUT_STAGE_TRANSITION_CMD_NONE,
   ROLLOUT_STAGE_TRANSITION_CMD_TRANSITIONED,             // durable write succeeded (forward or rollback)
   ROLLOUT_STAGE_TRANSITION_CMD_KILL_SWITCH_ACTIVE,        // refused before evaluation - kill switch veto
   ROLLOUT_STAGE_TRANSITION_CMD_CURRENT_STATE_INVALID,     // refused before evaluation - QA's revision-2 blocker
   ROLLOUT_STAGE_TRANSITION_CMD_EVIDENCE_GATE_REJECTED,    // §6.2 only: RolloutGateReadiness_Evaluate refused
   ROLLOUT_STAGE_TRANSITION_CMD_REJECTED,                  // RolloutStageTransition_Evaluate refused the target
   ROLLOUT_STAGE_TRANSITION_CMD_FAILED                     // the durable append itself failed - Safe Mode already tripped
};

string RolloutStageTransitionCmdResultToString(ENUM_ROLLOUT_STAGE_TRANSITION_CMD_RESULT r)
{
   switch(r)
   {
      case ROLLOUT_STAGE_TRANSITION_CMD_TRANSITIONED:            return "transitioned";
      case ROLLOUT_STAGE_TRANSITION_CMD_KILL_SWITCH_ACTIVE:       return "kill_switch_active";
      case ROLLOUT_STAGE_TRANSITION_CMD_CURRENT_STATE_INVALID:    return "current_state_environment_invalid";
      case ROLLOUT_STAGE_TRANSITION_CMD_EVIDENCE_GATE_REJECTED:   return "evidence_gate_rejected";
      case ROLLOUT_STAGE_TRANSITION_CMD_REJECTED:                 return "rejected";
      case ROLLOUT_STAGE_TRANSITION_CMD_FAILED:                   return "emit_durable_write_failed";
   }
   return "none";
}

struct RolloutStageTransitionCommandResult
{
   ENUM_ROLLOUT_STAGE_TRANSITION_CMD_RESULT status;
   ENUM_EXECUTION_ROLLOUT_STAGE              current_stage;  // always populated - the freshly-replayed current stage
   ENUM_ROLLOUT_TRANSITION_RESULT            evaluation;     // populated only once step 3 is reached
   string                                    reason_code;    // ceremony-log-ready reason string
   // §6.2 only: populated when status == ROLLOUT_STAGE_TRANSITION_CMD_EVIDENCE_GATE_REJECTED,
   // "" for every other status/pair - never consulted by any pre-existing pair's own logic.
   ENUM_ROLLOUT_GATE_READINESS_REASON        evidence_gate_reason;
   string                                    evidence_gate_diagnostic;
   // §6.1 Rev.4 §1.2 only: populated when status == ROLLOUT_STAGE_TRANSITION_CMD_CURRENT_STATE_INVALID
   // AND the rejection came from RolloutStage61Crossing_Evaluate() (i.e. the
   // pair was declared per isDeclaredEnvironmentCrossingPair()) - stays at its
   // NONE/"" default for the ORIGINAL blanket-check rejection path and every
   // other status/pair, so a caller can always tell the two CURRENT_STATE_INVALID
   // causes apart without the status itself needing to change (§1.2's own
   // explicit "same rejection status" instruction).
   ENUM_ROLLOUT_STAGE_61_CROSSING_REASON     crossing_gate_reason;
   string                                    crossing_gate_diagnostic;
};

void RolloutStageTransitionCommandResult_Init(RolloutStageTransitionCommandResult &r)
{
   r.status                   = ROLLOUT_STAGE_TRANSITION_CMD_NONE;
   r.current_stage            = ROLLOUT_STAGE_NONE;
   r.evaluation                = ROLLOUT_TRANSITION_NONE;
   r.reason_code                = "";
   r.evidence_gate_reason        = ROLLOUT_GATE_READINESS_NONE;
   r.evidence_gate_diagnostic    = "";
   r.crossing_gate_reason        = ROLLOUT_STAGE_61_CROSSING_NONE;
   r.crossing_gate_diagnostic    = "";
}

void RolloutStageTransitionCommand_Process(ENUM_EXECUTION_ROLLOUT_STAGE targetStage, string authorizedBy, string evidenceReference,
                                             const string &lines[], ENUM_EXECUTION_ENVIRONMENT_MODE environmentMode,
                                             RolloutStageTransitionCommandResult &outResult)
{
   RolloutStageTransitionCommandResult_Init(outResult);

   RolloutStageProjection_ReplayCurrent(lines, outResult.current_stage);

   // Step 1 (§A/§7.1): kill switch veto, unconditional, checked first -
   // never even reaches the current-state check or the evaluator.
   bool killSwitchActive;
   KillSwitchProjection_ReplayActive(lines, environmentMode, killSwitchActive);
   if(killSwitchActive)
   {
      outResult.status      = ROLLOUT_STAGE_TRANSITION_CMD_KILL_SWITCH_ACTIVE;
      outResult.reason_code = RolloutStageTransitionCmdResultToString(outResult.status);
      return;
   }

   // Step 2 (QA's revision-2 blocker): the CURRENT stage must itself pass
   // §3's cross-validity table for the fresh environmentMode BEFORE the
   // target is evaluated at all - closes the "laundering" scenario (an
   // already-stale current state transitioning into a fresh-looking valid
   // target without ever being flagged).
   //
   // §6.1 Rev.4 §1.2 amendment (QA Implementation Authorization
   // 2026-09-17): isDeclaredEnvironmentCrossingPair() is checked FIRST.
   // False (every pair not explicitly declared, including
   // DEMO_BOUNDED_AUTOMATION -> LIVE_SHADOW) runs the ORIGINAL blanket
   // check below, byte-for-byte unchanged - Commit-2's own frozen
   // regression test #6 is untouched. True (ONLY the one declared pair,
   // TEST_FIXTURE -> DEMO_DRY_RUN) runs that pair's own dedicated crossing
   // predicate INSTEAD of the blanket check.
   if(!isDeclaredEnvironmentCrossingPair(outResult.current_stage, targetStage))
   {
      if(!RolloutStage_IsValidForEnvironment(outResult.current_stage, environmentMode))
      {
         outResult.status      = ROLLOUT_STAGE_TRANSITION_CMD_CURRENT_STATE_INVALID;
         outResult.reason_code = RolloutStageTransitionCmdResultToString(outResult.status);
         return;
      }
   }
   else
   {
      RolloutStage61CrossingResult crossing = RolloutStage61Crossing_Evaluate(outResult.current_stage, targetStage, lines, environmentMode);
      if(!crossing.allow)
      {
         // §1.2: same rejection status AND same reason_code string as the
         // blanket check - QA's Diff Review ruling (this checkpoint): the
         // crossing predicate's own reason code lives ONLY in the
         // dedicated crossing_gate_reason/crossing_gate_diagnostic fields
         // below, never appended into reason_code, so the command layer's
         // existing observable reason_code format is not changed for
         // ANY pair, declared or not.
         outResult.status                  = ROLLOUT_STAGE_TRANSITION_CMD_CURRENT_STATE_INVALID;
         outResult.crossing_gate_reason     = crossing.reason;
         outResult.crossing_gate_diagnostic = crossing.diagnostic;
         outResult.reason_code              = RolloutStageTransitionCmdResultToString(outResult.status);
         return;
      }
   }

   // Step 2.5 (§6.2 only, QA Implementation Authorization 2026-09-17):
   // RolloutGateReadiness_Evaluate, gated to ONLY the
   // (DEMO_DRY_RUN -> DEMO_REAL_SUBMIT) pair. Every other pair (§6.0's
   // NONE->TEST_FIXTURE, any rollback, any not-yet-frozen pair) skips
   // this block entirely and falls straight through to step 3 exactly as
   // Commit 2 originally froze it - byte-for-byte unaffected.
   if(outResult.current_stage == ROLLOUT_STAGE_DEMO_DRY_RUN && targetStage == ROLLOUT_STAGE_DEMO_REAL_SUBMIT)
   {
      RolloutGateReadinessResult gate = RolloutGateReadiness_Evaluate(lines);
      if(!gate.allow)
      {
         outResult.status                   = ROLLOUT_STAGE_TRANSITION_CMD_EVIDENCE_GATE_REJECTED;
         outResult.evidence_gate_reason      = gate.reason;
         outResult.evidence_gate_diagnostic  = gate.diagnostic;
         outResult.reason_code               = RolloutStageTransitionCmdResultToString(outResult.status) + ":" +
                                                RolloutGateReadinessReasonToString(gate.reason);
         return;
      }
   }

   // Step 3: Commit 1's own frozen evaluator/emitter, unmodified.
   ENUM_ROLLOUT_TRANSITION_RESULT eval;
   ENUM_ROLLOUT_STAGE_EMIT_RESULT emitResult = RolloutStageTransition_Emit(outResult.current_stage, targetStage, environmentMode,
                                                                             authorizedBy, evidenceReference, eval);
   outResult.evaluation = eval;

   if(emitResult == ROLLOUT_STAGE_EMIT_RECORDED)
   {
      outResult.status      = ROLLOUT_STAGE_TRANSITION_CMD_TRANSITIONED;
      outResult.reason_code = RolloutTransitionResultToString(eval);
   }
   else if(emitResult == ROLLOUT_STAGE_EMIT_REJECTED)
   {
      // RolloutTransitionResultToString() already prefixes every
      // REJECTED_* case with "rejected_" (Commit 1, frozen) - no second
      // prefix here.
      outResult.status      = ROLLOUT_STAGE_TRANSITION_CMD_REJECTED;
      outResult.reason_code = RolloutTransitionResultToString(eval);
   }
   else // ROLLOUT_STAGE_EMIT_FAILED
   {
      outResult.status      = ROLLOUT_STAGE_TRANSITION_CMD_FAILED;
      outResult.reason_code = RolloutStageTransitionCmdResultToString(outResult.status);
   }
}

#endif // __MLQUANTAI_ROLLOUTSTAGETRANSITIONCOMMANDPROCESS_MQH__
