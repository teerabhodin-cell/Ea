# Phase B8.5 — Commit 3: Full-Chain Integration + Regression Proof, Seal

**Status: Implemented, awaiting real compile/test confirmation.**
Implements `Docs/PhaseB_B8_5_AIDecisionContract.md`'s Commit 3 addendum
(frozen before code). Opens after Commit 2 PASSED (123/123, real
MetaEditor run). Adds **zero new production behavior** - no B5/B8.1/
B8.3/B8.5-Commit-1/B8.5-Commit-2 sealed file touched. Pure test-suite
commit.

## What this commit adds

- **`Tests/MLQuantAI_Test_B8_5_Commit3_IntegrationRegression.mq5`**
  (new, 6 test functions):
  - `Test_EndToEndLinkage_SingleDecision` - walks the whole chain
    forward from a real `MARKET_CONTEXT_READY` event and asserts every
    hash/ID matches its neighbor across all four layers (candidate,
    snapshot, model artifact, decision) in one assertion sequence.
  - `Test_CrossLayerFailure_CandidateCorrupt_BlocksAIDecision` - a
    corrupted `CANDIDATE_CREATED` line propagates two levels up
    (`CandidateProjection` -> `FeatureSnapshotProjection` ->
    `AIDecisionProjection`), failing the whole rebuild closed.
  - `Test_CrossLayerFailure_SnapshotCorrupt_BlocksAIDecision` - a
    corrupted `FEATURE_SNAPSHOT_CREATED` line fails
    `AIDecisionProjection`'s rebuild directly.
  - `Test_CrossLayerFailure_ModelCorruption_BlocksAIDecisionRebuild` -
    a corrupted `MODEL_ARTIFACT_REGISTERED` line fails
    `AIDecisionProjection`'s rebuild via the INDEPENDENT model-side
    prerequisite, with the candidate/snapshot side of the same store
    left completely valid and untouched - the one point genuinely
    harder than B7 Commit 3's single-parent case.
  - `Test_FullChainRestartSimulation_MultiDecision` - repeated rebuilds
    of a 3-decision store reconstruct byte-identical state in ALL FOUR
    projections (`CandidateProjection`, `FeatureSnapshotProjection`,
    `ModelArtifactProjection`, `AIDecisionProjection`).
  - `Test_MultiCandidateMultiModelCrossLinking` - 3 candidates, 2
    sharing one `ModelArtifact` and 1 using its own; every decision
    links to exactly its own snapshot and its own model, never a
    neighbor's.

## Not re-proven here

Everything `Test_B8_5_AIDecision.mq5` (Commit 1: fail-closed ladder,
determinism, identity/hash sensitivity, no-mutation) and
`Test_B8_5_Commit2_AIDecisionEvent.mq5` (Commit 2: exactly-one-emission,
duplicate/collision, single-field orphan/mismatch isolation for both
upstream chains, malformed-line, single-decision restart/multi-session,
field-fidelity, `ALLOW`/`REJECT` audit-evidence-only) already prove.

Not yet compiled/run by the user - do not treat as PASSED or merge, and
do not declare B8.5 SEALED, until a real MetaEditor log confirms this
commit AND a manual re-run of `Test_B8_1_FeatureSnapshot.mq5`,
`Test_B8_3_ModelRegistry.mq5`, `Test_B8_5_AIDecision.mq5`, and
`Test_B8_5_Commit2_AIDecisionEvent.mq5` in the same session all still
pass clean.
