//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_RolloutStageTransitionEvaluate.mqh |
//| C5.2 Commit 1 (QA-frozen FINAL DESIGN FREEZE, Docs/PhaseC_C5_2_     |
//| ControlledExecutionEnvironmentLadderContract.md §4/§6/§8): the        |
//| pure decision core for one TRANSITION_ROLLOUT_STAGE ceremony           |
//| command attempt - models the "transition readiness gate" a future       |
//| ceremony-command handler will call, without itself being wired into      |
//| MLQuantAI.mq5 (the actual ceremony command type/dispatch is its own       |
//| separately authorized future step).                                        |
//|                                                                               |
//| Frozen rules implemented here (§4):                                          |
//|   1. Forward transitions move exactly ONE stage at a time (§2's ladder        |
//|      order, via ExecutionRolloutStageLadderIndex).                             |
//|   2. A forward transition's target must ALSO pass §3's cross-validity           |
//|      table for the (fresh, caller-supplied) environment_mode - a                 |
//|      `reject` cell is refused before any transition is ever durably                |
//|      recorded, regardless of direction (§3's "any attempt... is refused",           |
//|      not "any forward attempt").                                                      |
//|   3. A regression (§4 rule 3/§8, rollback) is always permitted immediately,             |
//|      evidence-free, multi-step-at-once permitted.                                        |
//|   4. Acceptance criteria are checked PER TRANSITION PAIR, never as one lump                |
//|      bucket (§6). §6.0 (NONE->TEST_FIXTURE, trivial), §6.1 (TEST_FIXTURE->                    |
//|      DEMO_DRY_RUN, §6.1 Rev.4 DESIGN FREEZE) and §6.2 (DEMO_DRY_RUN->                            |
//|      DEMO_REAL_SUBMIT, §6.2 Evidence-Gate Rev.8 DESIGN FREEZE) - all under                          |
//|      the same QA Implementation Authorization, 2026-09-17 - now have an                               |
//|      implemented evaluator - see MLQuantAI_RolloutStage61CrossingEvaluate.mqh                            |
//|      and MLQuantAI_RolloutGateReadinessEvaluate.mqh respectively, both called                              |
//|      one layer above this pure decision core.                                                                |
//|      §6.3-§6.6 remain refused fail-closed - not yet frozen at all.                                              |
//|      "Criteria not yet defined" is never treated as "criteria satisfied"                                         |
//|      (§6's own frozen structural rule).                                                                            |
//|                                                                                                              |
//| Pure: no EventStore write, no live MT5 API, no Safe Mode, no OrderSend, no                                    |
//| candidate-lifecycle authority. This file only ever decides ALLOW/REJECT for                                    |
//| a proposed rollout_stage transition - the durable write itself is a                                              |
//| separate concern (MLQuantAI_RolloutStageEventEmission.mqh).                                                        |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ROLLOUTSTAGETRANSITIONEVALUATE_MQH__
#define __MLQUANTAI_ROLLOUTSTAGETRANSITIONEVALUATE_MQH__

#include "../Core/MLQuantAI_Enums.mqh"
#include "MLQuantAI_RolloutStageCrossValidity.mqh"

enum ENUM_ROLLOUT_TRANSITION_RESULT
{
   ROLLOUT_TRANSITION_NONE,
   ROLLOUT_TRANSITION_ALLOWED_FORWARD,
   ROLLOUT_TRANSITION_ALLOWED_ROLLBACK,
   ROLLOUT_TRANSITION_REJECTED_SAME_STAGE,
   ROLLOUT_TRANSITION_REJECTED_NOT_ADJACENT,
   ROLLOUT_TRANSITION_REJECTED_ENVIRONMENT_INVALID,
   ROLLOUT_TRANSITION_REJECTED_CRITERIA_NOT_FROZEN
};

string RolloutTransitionResultToString(ENUM_ROLLOUT_TRANSITION_RESULT r)
{
   switch(r)
   {
      case ROLLOUT_TRANSITION_ALLOWED_FORWARD:              return "allowed_forward";
      case ROLLOUT_TRANSITION_ALLOWED_ROLLBACK:              return "allowed_rollback";
      case ROLLOUT_TRANSITION_REJECTED_SAME_STAGE:            return "rejected_same_stage";
      case ROLLOUT_TRANSITION_REJECTED_NOT_ADJACENT:           return "rejected_not_adjacent";
      case ROLLOUT_TRANSITION_REJECTED_ENVIRONMENT_INVALID:     return "rejected_environment_invalid";
      case ROLLOUT_TRANSITION_REJECTED_CRITERIA_NOT_FROZEN:      return "rejected_criteria_not_frozen";
   }
   return "none";
}

bool RolloutTransitionResult_IsAllowed(ENUM_ROLLOUT_TRANSITION_RESULT r)
{
   return r == ROLLOUT_TRANSITION_ALLOWED_FORWARD || r == ROLLOUT_TRANSITION_ALLOWED_ROLLBACK;
}

// §6's frozen per-transition structure: only pairs with BOTH a frozen
// criteria set AND an implemented evaluator return true here.
//
// §6.2 (DEMO_DRY_RUN -> DEMO_REAL_SUBMIT), Class 2 additive amendment,
// QA Implementation Authorization (2026-09-17): the evidence-checking
// mechanism this file's own header once called "future, separately
// authorized work" now exists - MLQuantAI_RolloutGateReadinessEvaluate.mqh,
// §6.2 Evidence-Gate Design Contract Rev.8 (QA-frozen DESIGN FREEZE). This
// function's own signature/every other pair's behavior is completely
// unchanged - only this one previously-false case flips to true. The
// actual RolloutGateReadiness_Evaluate() call happens one layer up, in
// MLQuantAI_RolloutStageTransitionCommandProcess.mqh (§7 Authority
// Boundary - never inside this pure decision core, which takes no
// lines[] parameter and performs no EventStore read by design).
//
// §6.1 (TEST_FIXTURE -> DEMO_DRY_RUN), Class 2 additive amendment, QA
// Implementation Authorization (2026-09-17), §6.1 Rev.4 §1.5 (closing
// Rev.3's remaining gap): a SECOND previously-false case flips to true,
// same shape as §6.2's own precedent above - every other pair's behavior
// (including DEMO_BOUNDED_AUTOMATION -> LIVE_SHADOW, which STAYS false -
// §6.4 does not exist) is byte-for-byte unchanged. §1.2's whitelist
// (isDeclaredEnvironmentCrossingPair(), MLQuantAI_RolloutStage61CrossingEvaluate.mqh)
// and this one new `true` case are driven by the SAME single declared
// pair - never two independently-maintained lists that could drift apart
// (§1.5's own frozen invariant). The actual RolloutStage61Crossing_Evaluate()
// call happens one layer up, in Step 2 of
// MLQuantAI_RolloutStageTransitionCommandProcess.mqh - never inside this
// pure decision core, exactly mirroring §6.2's own boundary.
bool RolloutStageTransition_IsForwardPairImplemented(ENUM_EXECUTION_ROLLOUT_STAGE fromStage, ENUM_EXECUTION_ROLLOUT_STAGE toStage)
{
   if(fromStage == ROLLOUT_STAGE_NONE && toStage == ROLLOUT_STAGE_TEST_FIXTURE)
      return true; // §6.0 - trivial, no acceptance evidence required

   if(fromStage == ROLLOUT_STAGE_TEST_FIXTURE && toStage == ROLLOUT_STAGE_DEMO_DRY_RUN)
      return true; // §6.1 - crossing/evidence predicate now implemented, see RolloutStage61Crossing_Evaluate()

   if(fromStage == ROLLOUT_STAGE_DEMO_DRY_RUN && toStage == ROLLOUT_STAGE_DEMO_REAL_SUBMIT)
      return true; // §6.2 - evidence gate now implemented, see RolloutGateReadiness_Evaluate()

   return false; // §6.3-§6.6 - fail-closed until each has its own implemented evaluator
}

// CALLER CONTRACT (frozen intent, NOT self-enforced by this pure
// function - QA's own diff-review finding): fromStage MUST be the
// CURRENT durably-recorded rollout_stage - i.e. the caller is required
// to have just replayed it via RolloutStageProjection_ReplayCurrent()
// (or equivalent) and pass THAT result here, never an arbitrary,
// remembered, or operator-typed value. This function takes no `lines[]`
// parameter and performs no EventStore read, by design (see this file's
// header, "pure decision core") - it cannot verify fromStage against the
// durable log itself. That verification is the responsibility of the
// future TRANSITION_ROLLOUT_STAGE ceremony-command handler (the thin
// wrapper this pure core exists for), which must always replay-then-call
// in that order, never accept a caller-supplied fromStage directly from
// a script/operator. No such wrapper exists yet in this commit - no
// caller currently has the opportunity to violate this contract - this
// note exists so the eventual wrapper implementer cannot miss it.
ENUM_ROLLOUT_TRANSITION_RESULT RolloutStageTransition_Evaluate(ENUM_EXECUTION_ROLLOUT_STAGE fromStage, ENUM_EXECUTION_ROLLOUT_STAGE toStage, ENUM_EXECUTION_ENVIRONMENT_MODE environmentMode)
{
   if(toStage == fromStage)
      return ROLLOUT_TRANSITION_REJECTED_SAME_STAGE;

   int fromIdx = ExecutionRolloutStageLadderIndex(fromStage);
   int toIdx   = ExecutionRolloutStageLadderIndex(toStage);

   if(toIdx < fromIdx)
   {
      // Regression/rollback (§4 rule 3, §8): always permitted immediately,
      // evidence-free, multi-step-at-once permitted - but the target still
      // must pass §3's cross-validity table (§3's "any attempt" wording is
      // not scoped to forward transitions only).
      if(!RolloutStage_IsValidForEnvironment(toStage, environmentMode))
         return ROLLOUT_TRANSITION_REJECTED_ENVIRONMENT_INVALID;
      return ROLLOUT_TRANSITION_ALLOWED_ROLLBACK;
   }

   // Forward: must move exactly one stage at a time (§4 rule 1).
   if(toIdx != fromIdx + 1)
      return ROLLOUT_TRANSITION_REJECTED_NOT_ADJACENT;

   if(!RolloutStage_IsValidForEnvironment(toStage, environmentMode))
      return ROLLOUT_TRANSITION_REJECTED_ENVIRONMENT_INVALID;

   if(!RolloutStageTransition_IsForwardPairImplemented(fromStage, toStage))
      return ROLLOUT_TRANSITION_REJECTED_CRITERIA_NOT_FROZEN;

   return ROLLOUT_TRANSITION_ALLOWED_FORWARD;
}

#endif // __MLQUANTAI_ROLLOUTSTAGETRANSITIONEVALUATE_MQH__
