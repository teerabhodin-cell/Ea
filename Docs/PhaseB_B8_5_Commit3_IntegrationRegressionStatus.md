# Phase B8.5 — Commit 3: Full-Chain Integration + Regression Proof, Seal

**Status: PASSED (59/59, real MetaEditor run, 2026-08-20). Manual
4-suite regression re-run also confirmed clean in the same session.
B8.5 is SEALED.**
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

## Real run - 59/59 ALL PASS (2026-08-20 18:07:39)

Compiled clean, real MetaEditor run: **59/59 checks passed, ALL PASS**,
across every group (end-to-end linkage, all three cross-layer failure
propagation tests, full-chain restart, multi-candidate/multi-model
cross-linking).

## Manual regression re-run - ALL PASS, same MetaEditor session
(2026-08-20 18:07-18:13)

- `Test_B8_1_FeatureSnapshot.mq5`: 66/66 ALL PASS.
- `Test_B8_3_ModelRegistry.mq5`: 106/106 ALL PASS.
- `Test_B8_5_AIDecision.mq5` (Commit 1): 72/72 ALL PASS.
- `Test_B8_5_Commit2_AIDecisionEvent.mq5` (Commit 2): 123/123 ALL PASS.

Combined with this commit's own 59/59, the full B8.5 seal gate is
satisfied: **72 + 123 + 59 = 254/254.** No regression anywhere in the
B8.1/B8.3/B8.5 chain. Merged to `mlquantai`.

# B8.5 — SEALED

**AIDecision + threshold-policy mapping (Commit 1, 72/72) + durable
event/projection/replay (Commit 2, 123/123) + full-chain integration
proof (Commit 3, 59/59) = 254/254, all real MetaEditor runs.** B8.5 is
the first layer with authority to interpret `p_success` as
`ALLOW`/`REJECT`/`ABSTAIN` (still unreachable this policy version),
still without execution authority — B9 remains the sole place
`RiskPlan` + `AIDecision` + operational policy combine into
`ELIGIBLE`/`REJECTED`. The old, informal "B8.6: persist/replay/audit"
scoping language (see `Docs/PhaseB_Architecture_Baseline.md`'s note) is
fully superseded — no separate B8.6 phase remains. B9 is next.
