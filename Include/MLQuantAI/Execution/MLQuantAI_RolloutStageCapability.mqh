//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_RolloutStageCapability.mqh         |
//| C5.2 Commit 1 (QA-frozen FINAL DESIGN FREEZE, Docs/PhaseC_C5_2_     |
//| ControlledExecutionEnvironmentLadderContract.md §5/§9): the per-      |
//| stage capability matrix, as pure predicates - one function per        |
//| column of §5's frozen table, plus the composed                         |
//| RolloutStage_PermitsPipelineRun() §9 freezes as the OnTick entry-       |
//| gate predicate's exact required order: kill switch FIRST (§7.1 rule     |
//| 2), then a fresh environment_mode cross-validity check (via              |
//| MLQuantAI_RolloutStageCrossValidity.mqh's single source of truth -        |
//| never re-implemented here), then the stage's own pipeline-run              |
//| capability.                                                                  |
//|                                                                               |
//| A capability not returned true by one of these functions is forbidden        |
//| at that stage, full stop - nothing is "implied" by a stage's name or          |
//| position in the ladder (§5's own frozen reading rule).                         |
//|                                                                                   |
//| Pure: no EventStore read/write, no live MT5 API, no Safe Mode, no                 |
//| OrderSend, no candidate-lifecycle authority. This file only ever                   |
//| PERMITS OR FORBIDS an attempt to reach the already-sealed C2 gate                   |
//| chain (SafetyGate/BrokerSubmissionGate/EnvironmentLockGate/                          |
//| ManualApprovalRegistry) - it never substitutes for, weakens, or                        |
//| shortcuts any of them (this document's governing principle).                            |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ROLLOUTSTAGECAPABILITY_MQH__
#define __MLQUANTAI_ROLLOUTSTAGECAPABILITY_MQH__

#include "../Core/MLQuantAI_Enums.mqh"
#include "MLQuantAI_RolloutStageCrossValidity.mqh"

// §5 column 1 (narrowed to the OUTSIDE-Tester case only - the C5.0/C5.1
// Strategy-Tester-only fixture's own "Tester only" pipeline-run
// capability is entirely separate, unchanged, and gated purely by
// MQLInfoInteger(MQL_TESTER) at the OnTick call site per §9's design
// intent - it never depends on rollout_stage at all). True only for
// ROLLOUT_STAGE_DEMO_DRY_RUN and every rollout_stage after it in the
// ladder order (§2); false for ROLLOUT_STAGE_NONE and
// ROLLOUT_STAGE_TEST_FIXTURE.
bool RolloutStage_PipelineRunPermittedOutsideTester(ENUM_EXECUTION_ROLLOUT_STAGE stage)
{
   switch(stage)
   {
      case ROLLOUT_STAGE_DEMO_DRY_RUN:
      case ROLLOUT_STAGE_DEMO_REAL_SUBMIT:
      case ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION:
      case ROLLOUT_STAGE_LIVE_SHADOW:
      case ROLLOUT_STAGE_LIVE_MANUAL_MICRO_SIZE:
      case ROLLOUT_STAGE_LIVE_BOUNDED_AUTOMATION:
         return true;
   }
   return false; // ROLLOUT_STAGE_NONE, ROLLOUT_STAGE_TEST_FIXTURE
}

// §5 column 3: whether this stage permits the SUBMIT_ORDER ceremony
// command to even be ATTEMPTED - never a claim about what happens once
// attempted (BrokerSubmissionGate/EnvironmentLockGate/
// ManualApprovalRegistry still decide that, exactly as sealed). False
// for DEMO_DRY_RUN and LIVE_SHADOW by frozen design - §5's own reading
// rule: "no submission path is reachable from this stage at all".
bool RolloutStage_SubmitOrderCeremonyReachable(ENUM_EXECUTION_ROLLOUT_STAGE stage)
{
   switch(stage)
   {
      case ROLLOUT_STAGE_DEMO_REAL_SUBMIT:
      case ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION:
      case ROLLOUT_STAGE_LIVE_MANUAL_MICRO_SIZE:
      case ROLLOUT_STAGE_LIVE_BOUNDED_AUTOMATION:
         return true;
   }
   return false;
}

// §5 column 4: true ONLY for the two stages where manual approval is
// mandatory, every single submission, no exception (QA's exact frozen
// wording, restated in §5). False for the bounded-automation stages
// (approval is deliberately NOT required there) and for every stage
// where no submission path exists at all (the question does not arise).
bool RolloutStage_ManualApprovalRequiredPerSubmission(ENUM_EXECUTION_ROLLOUT_STAGE stage)
{
   return stage == ROLLOUT_STAGE_DEMO_REAL_SUBMIT || stage == ROLLOUT_STAGE_LIVE_MANUAL_MICRO_SIZE;
}

// §5 column 5: true ONLY for the two bounded-automation stages. Per
// §5's own note, the MECHANISM that would actually trigger such a
// submission without a human issuing SUBMIT_ORDER by hand is explicitly
// NOT designed by the frozen contract (open item) - this predicate only
// freezes that manual per-submission approval is not required at these
// two stages, nothing more.
bool RolloutStage_AutomaticSubmissionPermitted(ENUM_EXECUTION_ROLLOUT_STAGE stage)
{
   return stage == ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION || stage == ROLLOUT_STAGE_LIVE_BOUNDED_AUTOMATION;
}

// §9's frozen OnTick entry-gate predicate, in the EXACT required order
// (QA's structural-gap finding, C5.2 revision 3):
//   1. kill switch FIRST - unconditional veto regardless of stage/mode.
//   2. a FRESH environment_mode cross-validity check (§3) - a `reject`
//      pairing returns false unconditionally, regardless of what step 3
//      would otherwise permit.
//   3. only if both above pass: the stage's own pipeline-run capability.
// Callers must supply a FRESH killSwitchActive/environmentMode on every
// call (e.g. every tick) - this function does not cache or remember
// either across calls, per §9/§3's own "never a cached/remembered
// value" discipline.
bool RolloutStage_PermitsPipelineRun(ENUM_EXECUTION_ROLLOUT_STAGE stage, bool killSwitchActive, ENUM_EXECUTION_ENVIRONMENT_MODE environmentMode)
{
   if(killSwitchActive)
      return false;

   if(!RolloutStage_IsValidForEnvironment(stage, environmentMode))
      return false;

   return RolloutStage_PipelineRunPermittedOutsideTester(stage);
}

#endif // __MLQUANTAI_ROLLOUTSTAGECAPABILITY_MQH__
