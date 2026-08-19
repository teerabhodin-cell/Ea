# Phase B8.2 — Commit 4: Full-Chain Integration + Regression Proof — B8.2 SEAL

**Status: Implemented, awaiting real compile/test confirmation.**
`Tests/MLQuantAI_Test_B8_2_Commit4_SealRegression.mq5` written (8 test
functions), balance/identifier-length checked, and self-reviewed
line-by-line against the real struct/function shapes it calls and
against the proven techniques already used successfully in Commits
2/3. Not yet compiled/run by the user — do not treat as PASSED, do not
declare B8.2 SEALED, and do not merge until a real MetaEditor log
confirms it (plus the manual regression re-run of Commits 1–3's own
suites in the same session).

Implements `Docs/PhaseB_B8_2_Commit4_SealRegression.md`. Opens after
B8.2 Commit 3 PASSED (109/109) and merged. Pre-seal total: 76 + 105 +
109 = **290/290**.

Adds **zero new production behavior** — no B5/B6/B7/B8.1/B8.2 sealed
file touched. Purely a test-suite commit proving the already-shipped
B8.2 pieces (Commits 1–3) compose correctly end to end, the same role
B7 Commit 3 played for B7.

## The chain being proven

```
MARKET_CONTEXT_READY
    -> CANDIDATE_CREATED -> CandidateProjection
    -> Candidate_ToRiskPlan -> RISK_PLAN_CREATED -> RiskPlanProjection
    -> Candidate_ToFeatureSnapshot -> FEATURE_SNAPSHOT_CREATED -> FeatureSnapshotProjection
    -> RealizedOutcome_Build -> TRADE_OUTCOME_LABELED -> RealizedOutcomeProjection
    -> TrainingDatasetExport_BuildDataset -> TrainingDatasetRow[] + TrainingDatasetManifest
    -> Restart / Replay -> identical lineage + state + hashes
```

## The four critical gates — each proven compositionally, not just per-layer

1. **Outcome never reaches back into AI input** —
   `Test_Leakage_MultiCandidateCohort`: three candidates exported
   together, a `RealizedOutcome` added to only one of them, confirms
   every candidate's `feature_snapshot_hash`/`feature_vector_hash` —
   including the newly-labeled one's own — are byte-identical to a
   control export taken before any `RealizedOutcome` existed.
2. **Incomplete ≠ Corrupt** — `Test_IncompleteAndCorrupt_AreNotTheSame`:
   store A (one fully-qualified + one genuinely incomplete candidate)
   exports successfully, skipping the incomplete one
   (`incomplete_count=1`); store B (a fully-qualified candidate whose
   `RISK_PLAN_CREATED` line has its `plan_hash` tampered to empty —
   an artifact that *exists* but fails validation, not a missing one)
   fails the *whole* export closed. Both conditions proven in one test
   for direct contrast.
3. **Collision fails closed at every layer** —
   `Test_CollisionAnywhereBlocksExport`: a `FeatureSnapshot` collision
   (same `feature_snapshot_id`, different `feature_snapshot_hash`,
   same technique already proven in Commit 2's own collision test)
   blocks `TrainingDatasetExport_BuildDataset` itself, not just
   `FeatureSnapshotProjection`'s own rebuild in isolation.
4. **Export is atomic** — `Test_ExportAtomicity_ValidVsCorrupted`: a
   valid multi-candidate store produces full `rows[]`/`manifest`; an
   otherwise-identical corrupted store (a truncated line appended)
   produces zero rows and a `manifest` at `Init()` defaults, checked
   side by side in one test.

## `LABELED_ONLY` — clarified, no new production code

Checked before writing this contract: no `LABELED_ONLY`/filter
concept exists anywhere in the codebase (zero matches). Since this
commit adds zero new production behavior, no new `Include/` filter
function is added. `Test_LabeledOnlyView_IsPureDerivedFilter` proves
the invariant directly: filtering an exported `rows[]` array down to
`label_available == true` entries — done entirely in test code —
never mutates the original `rows[]`/`manifest`, the filtered count
always equals `manifest.labeled_count`, and re-running the export from
the same store afterward is unaffected (byte-identical `dataset_hash`).
A real production `LABELED_ONLY` query/export function, if wanted, is
new scope for a future commit — not this seal.

## What's genuinely new here (not re-proven from Commits 1–3's own suites)

- **`Test_FullChain_EndToEndLinkage`** — walks the whole chain from a
  real `MARKET_CONTEXT_READY` event to an exported `TrainingDatasetRow`,
  cross-checking every hash/ID against the real `CandidateProjection`/
  `FeatureSnapshotProjection`/`RiskPlanProjection` records (not just
  the in-memory structs), plus an independent re-derivation of
  `dataset_row_id` via `Ids_TrainingDatasetRowId()`.
- **`Test_CrossLayerFailure_CorruptedCandidateBlocksWholeChain`** — a
  corrupted `CANDIDATE_CREATED` line is shown to fail
  `CandidateProjection`, `RiskPlanProjection`, `FeatureSnapshotProjection`,
  `RealizedOutcomeProjection`, AND `TrainingDatasetExport_BuildDataset`
  in sequence — one corruption at the base of the chain propagating
  through every layer built on top of it.
- **`Test_FullChainRestartSimulation_MultiCandidate`** — a
  multi-candidate store mixing labeled, unlabeled, and incomplete
  candidates, exported twice (simulating a restart), asserting
  byte-identical `rows[]`/`manifest` including `dataset_hash`/
  `dataset_id` — the first restart test to include `RealizedOutcome`
  in the mix (Commit 2's own determinism test predates it).

## Test coverage

`Tests/MLQuantAI_Test_B8_2_Commit4_SealRegression.mq5`, 8 test
functions, using the real B5/B7/B8.1/B8.2 pipeline throughout:
`Test_FullChain_EndToEndLinkage`,
`Test_CrossLayerFailure_CorruptedCandidateBlocksWholeChain`,
`Test_IncompleteAndCorrupt_AreNotTheSame`,
`Test_Leakage_MultiCandidateCohort`,
`Test_CollisionAnywhereBlocksExport`,
`Test_ExportAtomicity_ValidVsCorrupted`,
`Test_LabeledOnlyView_IsPureDerivedFilter`,
`Test_FullChainRestartSimulation_MultiCandidate`.

## On PASS: status table update

```
B5    Candidate Provenance                    SEALED
B6    Candidate Projection / Dataset Lineage  SEALED
B7    Deterministic RiskPlan                  SEALED
B8.1  Immutable FeatureSnapshot               SEALED
B8.2  Training Dataset                        SEALED
B8.3  Model Registry / Artifact Contract      NEXT
```

`Docs/PhaseB_Architecture_Baseline.md` will get a dated update entry
recording B8.2 SEALED once this commit's real evidence confirms it —
not done yet.

## Explicitly out of scope for this commit

Any new production function, event, struct field, or schema version
(including a real `LABELED_ONLY` export function); any model/ONNX/
training-loop code; B8.3 (Model Registry / Artifact Contract); any
change to an already-sealed B5/B6/B7/B8.1/B8.2 production file.
