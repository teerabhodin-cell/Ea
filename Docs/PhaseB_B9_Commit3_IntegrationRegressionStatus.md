# Phase B9 — Commit 3: Full-Chain Integration + Regression Proof, Seal

**Status: Implemented, awaiting real MetaEditor compile/test confirmation.**
Implements the Commit 3 addendum in
`Docs/PhaseB_B9_ExecutionEligibilityContract.md` (frozen before code).
Opens after B9 Commit 2 PASSED (84/84, real MetaEditor run,
2026-08-20). Adds **zero new production behavior**: no new eligibility
rule, field, event schema, policy semantics, identity/hash seed, or
projection behavior - purely a test-suite commit proving the already-
shipped B9 Commit 1 + Commit 2 pieces compose correctly end to end.

## What this commit adds

- **`Tests/MLQuantAI_Test_B9_Commit3_IntegrationRegression.mq5`** (new,
  7 test functions). No production file touched.

## Genuinely new coverage (not re-proven from Commit 1/2's own suites)

- **End-to-end linkage in one place**: after a full rebuild, walks
  candidate -> snapshot -> (model -> AI decision) and risk plan ->
  eligibility decision, asserting every hash/ID agrees with its real,
  independently-rebuilt projection record across all five upstream
  layers, plus `eligibility_decision_id`'s deterministic derivation.
- **Cross-layer failure propagation, all three upstream chains
  independently** - harder than B8.5 Commit 3's two-parent case:
  - a corrupted `CANDIDATE_CREATED` line fails `RiskPlanProjection`'s
    own `CandidateProjection` prerequisite, cascading to block
    eligibility rebuild (`first_error` names both "risk plan registry"
    and "candidate registry");
  - independently, a corrupted `RISK_PLAN_CREATED` line fails the risk
    plan registry directly, with the candidate/snapshot/model/AI-decision
    side of the same store completely untouched and valid
    (`first_error` names "risk plan registry" but NOT "candidate
    registry" - a distinct failure path, not a side effect of candidate
    corruption);
  - independently, a corrupted `MODEL_ARTIFACT_REGISTERED` line fails
    `AIDecisionProjection`'s own `ModelArtifactProjection` prerequisite,
    cascading to block eligibility rebuild (`first_error` names both "AI
    decision registry" and "model artifact registry").
- **Full-chain restart/crash simulation**: a multi-candidate store (mixed
  `ELIGIBLE`/`REJECTED` verdicts) rebuilt twice from scratch, asserting
  byte-identical state across all SIX projections
  (`CandidateProjection`/`FeatureSnapshotProjection`/
  `ModelArtifactProjection`/`AIDecisionProjection`/`RiskPlanProjection`/
  `EligibilityDecisionProjection`), plus confirming via `StateProjector`
  after a real replay that `ELIGIBLE` candidates stay at
  `CANDIDATE_CREATED` and the `REJECTED` one reaches
  `CANDIDATE_REJECTED_BY_RISK` - all within one multi-candidate store,
  not one at a time.
- **Multi-candidate cross-linking**: three candidates, proving every
  eligibility decision links to exactly its own risk plan and its own AI
  decision, never a neighbor's.
- **Rejected-without-lifecycle-consequence reconciliation** - the
  non-rollback edge case Commit 2's own contract explicitly deferred. A
  new, test-only helper (`FindRejectedWithoutLifecycleConsequence`, not
  production code) scans a rebuilt `EligibilityDecisionProjection` for
  every `REJECTED` record and cross-checks it against
  `StateProjector_TryGetState` (never `CandidateProjection`). Tested
  against a store built by deliberately skipping the lifecycle-wiring
  half of `EligibilityDecision_EmitDecisionAndWireLifecycle` (never
  allocating a `CANDIDATE_REJECTED_BY_RISK` sequence number in the first
  place, which is what "the write never happened" actually means -
  dropping an already-written line instead would trip
  `EventStoreValidator`'s own gapless-sequence-number requirement for an
  unrelated reason) - correctly flags exactly the affected
  `candidate_id`, and correctly reports zero false positives on a clean
  store where the lifecycle write really did happen.

## Definition of Done

- The full chain rebuilds state from the store alone, across all six
  layers.
- Candidate/snapshot/model/AI-decision/plan/eligibility linkage matches
  on every hash and ID.
- A restart followed by replay reproduces byte-identical state in all
  six projections.
- A candidate-layer OR risk-plan-layer OR model-layer failure closes
  the eligibility-layer rebuild too, proven independently for each of
  the three upstream chains.
- The reconciliation helper correctly flags the simulated failure-mode
  store and reports a clean store as consistent.
- No execution, order, broker, or extra lifecycle transition anywhere in
  this commit's test suite.
- Full B9 regression: `Test_B9_ExecutionEligibility.mq5` and
  `Test_B9_Commit2_EligibilityEvent.mq5` re-run clean alongside the new
  suite in the same MetaEditor session - manual checklist, since MQL5
  has no cross-script test runner.

## Next step

Awaiting a real MetaEditor compile + run of
`MLQuantAI_Test_B9_Commit3_IntegrationRegression.mq5`, plus the manual
regression re-run of `Test_B9_ExecutionEligibility.mq5` and
`Test_B9_Commit2_EligibilityEvent.mq5` in the same session. Only a
genuine, clean real log for all three moves this to PASSED and seals
B9: execution eligibility pure mapping (Commit 1) + durable event/
projection/replay + lifecycle wiring (Commit 2) + full-chain
integration proof (Commit 3) - the last policy authority before Phase C.
