# Phase B8.2 — Commit 4: Full-Chain Integration + Regression Proof (FROZEN) — B8.2 SEAL

**Status: FROZEN, before any code exists.** Opens after B8.2 Commit 3
PASSED (109/109) and merged. Pre-seal total: Commit 1 (76/76) + Commit
2 (105/105) + Commit 3 (109/109) = **290/290**.

Adds **zero new production behavior** — no B5/B6/B7/B8.1/B8.2 sealed
file touched, no new event type, no new struct field, no new sizing/
label/split rule. Purely a test-suite commit proving the already-shipped
B8.2 pieces (Commits 1–3) compose correctly end to end, the same role
B7 Commit 3 played for B7. On PASS, this commit is the seal — see the
status-table update at the bottom.

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

## Four critical gates — no exception, each gets its own dedicated test

These are re-affirmations of invariants each already individually
tested in Commits 1–3, now proven **compositionally**, across the full
multi-layer chain in one store, the same escalation B7 Commit 3 made
over B7 Commit 2's own per-layer tests.

1. **Outcome must never reach back into AI input.** A `RealizedOutcome`
   can move `label`/`row_hash`/`dataset_hash` — it must never move
   `feature_snapshot_hash`, `feature_vector_hash`, or `candidate_hash`.
   (Already proven in Commit 3's `Test_Leakage_FeatureHashUnchangedByOutcome`
   for one candidate; this commit re-proves it across a multi-candidate
   cohort exported together.)
2. **Incomplete ≠ Corrupt.** A candidate missing a `FeatureSnapshot`/
   ALLOWED `RiskPlan` is a skip (`incomplete_count++`), never a
   failure. An artifact that exists but fails lineage/hash/schema
   validation is fail-closed — the whole export produces zero output.
   This commit proves both conditions can coexist correctly: one store
   with a genuinely incomplete candidate exports fine (skip), a
   *different* store with a genuinely corrupted artifact fails the
   *whole* export (not just that candidate).
3. **Collision fails closed at every layer.** Same identity + same
   hash on replay is a no-op; same identity + different hash is a
   collision and the *relevant projection's* rebuild fails entirely.
   Already proven per-layer (Candidate/RiskPlan/FeatureSnapshot/
   RealizedOutcome) in their own commits; this commit does not repeat
   each in isolation again, but does confirm a collision anywhere in
   the chain also blocks `TrainingDatasetExport_BuildDataset` itself
   (since it rebuilds every projection as its own prerequisite).
4. **Export is atomic.** A valid store produces full `rows[]` +
   `manifest`. A corrupted store (anywhere in the chain, not just at
   the `TrainingDatasetRow` layer) produces zero rows and a `manifest`
   at `Init()` defaults — never a partial result.

## `LABELED_ONLY` — a derived view, not a mutation (clarified, not new production code)

The user's proposal requires `LABELED_ONLY` to be *only* a derived
view of the source dataset, never a mutation of it. Checked before
writing this contract: no `LABELED_ONLY`/filter concept exists
anywhere in the codebase today (`grep` across `Include/`/`Tests/`/
`Docs/`, zero matches). Since this commit adds zero new production
behavior, **no new production filter function is added.** The
already-shipped fields are sufficient for any caller to derive a
labeled-only view purely client-side: `TrainingDatasetRow.label_available`
on each row, and `TrainingDatasetManifest.labeled_count` to
cross-check the count. This commit proves the *invariant* the user
asked for — filtering `rows[]` down to `label_available == true`
entries, done entirely in test code (not a new `Include/` function),
does not and cannot mutate the original `rows[]` array or `manifest`
returned by `TrainingDatasetExport_BuildDataset`, and the filtered
count always equals `manifest.labeled_count`. If a real production
`LABELED_ONLY` export/query function is wanted later, that is new
scope for a future commit, not this seal.

## What's genuinely new here (not re-proven from Commits 1–3's own suites)

1. **`Test_FullChain_EndToEndLinkage`** — one test walking the whole
   chain forward from a real `MARKET_CONTEXT_READY` event through to
   an exported `TrainingDatasetRow`, asserting every hash/ID matches
   its neighbor in a single sequence: `row.candidate_id`/
   `candidate_hash` against the real `CandidateProjection` record;
   `row.feature_snapshot_id`/`feature_snapshot_hash`/`feature_vector_hash`
   against the real `FeatureSnapshotProjection` record;
   `row.risk_plan_id`/`plan_hash` against the real `RiskPlanProjection`
   record; `row.label`/`outcome_reference`/`outcome_hash` against the
   real `RealizedOutcomeProjection` record; `row.dataset_row_id`
   independently re-derived via `Ids_TrainingDatasetRowId()` and
   compared against the row's own id.
2. **`Test_CrossLayerFailure_CorruptedCandidateBlocksWholeChain`** — a
   corrupted `CANDIDATE_CREATED` line (empties `candidate_id`, staying
   syntactically valid JSON) must fail `CandidateProjection`'s rebuild,
   which must in turn fail `RiskPlanProjection`, `FeatureSnapshotProjection`,
   `RealizedOutcomeProjection`, AND `TrainingDatasetExport_BuildDataset`
   itself — one corruption at the base of the chain propagates through
   every layer built on top of it.
3. **`Test_IncompleteAndCorrupt_AreNotTheSame`** (gate 2) — two
   separate stores in one test: store A has one fully-qualified
   candidate and one candidate missing only a `FeatureSnapshot` — the
   export succeeds, `row_count=1`, `incomplete_count=1`. Store B has a
   fully-qualified candidate whose `RISK_PLAN_CREATED` line is tampered
   to a hash mismatch — the whole export on store B fails closed,
   `rows[]` empty, `manifest` at `Init()` defaults. Proves the two
   conditions produce genuinely different outcomes, not a shared
   "something's wrong, skip it" fallback.
4. **`Test_Leakage_MultiCandidateCohort`** (gate 1) — three candidates
   exported together, only one of which has a `RealizedOutcome`;
   confirms every candidate's `feature_snapshot_hash`/
   `feature_vector_hash` is identical to a control export taken before
   any `RealizedOutcome` existed for any of them, proving the leakage
   boundary holds across a cohort, not just a single candidate in
   isolation.
5. **`Test_CollisionAnywhereBlocksExport`** (gate 3) — a
   `FEATURE_SNAPSHOT_CREATED` collision (same `feature_snapshot_id`,
   different `feature_snapshot_hash`) is introduced into an otherwise
   valid multi-candidate store; confirms
   `TrainingDatasetExport_BuildDataset` itself fails (not just
   `FeatureSnapshotProjection_RebuildFromFile` in isolation, which
   Commit 2 already proved).
6. **`Test_ExportAtomicity_ValidVsCorrupted`** (gate 4) — a valid
   multi-candidate, multi-layer store produces full `rows[]`/`manifest`;
   the identical store with one malformed line anywhere in the chain
   produces zero rows and an `Init()`-default manifest. Both paths
   checked in one test for direct contrast.
7. **`Test_LabeledOnlyView_IsPureDerivedFilter`** — exports a
   multi-candidate cohort (mixed labeled/unlabeled), filters to
   `label_available == true` in test code, and confirms: the filtered
   count equals `manifest.labeled_count`; the original `rows[]` array
   and `manifest` are unchanged (checked field-by-field) after the
   filter; re-running the export from the same store again produces
   byte-identical `rows[]`/`manifest` to the pre-filter export (proving
   the filter had no observable side effect on the store or the
   registries).
8. **`Test_FullChainRestartSimulation_MultiCandidate`** — a
   multi-candidate, multi-layer store (some labeled, some not, some
   incomplete) rebuilt twice (simulating an EA restart) via a full
   `TrainingDatasetExport_BuildDataset` call each time, asserting
   byte-identical `rows[]`/`manifest` (including `dataset_hash`/
   `dataset_id`) both times.

## Definition of Done

- The full B8.2 chain (context through exported row) rebuilds state
  from the store alone, with every hash/ID matching across all five
  layers (Candidate/RiskPlan/FeatureSnapshot/RealizedOutcome/
  TrainingDatasetRow).
- A corruption at the base of the chain (`CANDIDATE_CREATED`)
  propagates through every layer built on top of it, including the
  export itself.
- Incomplete and corrupt produce genuinely different, correctly
  distinguished outcomes (gate 2).
- A collision at any single layer blocks the whole export, not just
  that layer's own projection (gate 3).
- Export atomicity holds: valid store -> full output; corrupted store
  -> zero output + `Init()` manifest (gate 4).
- The leakage-protection invariant holds across a multi-candidate
  cohort, not just one candidate in isolation (gate 1).
- A `LABELED_ONLY` view, built purely from already-shipped fields in
  test code, is proven to be a pure filter with no mutation of the
  source dataset.
- A restart followed by replay reproduces byte-identical full-chain
  state, including the final exported dataset.
- Zero regressions: the full B8.2 manual regression checklist
  (Commit 1: 76/76, Commit 2: 105/105, Commit 3: 109/109 = 290/290)
  re-runs clean in the same MetaEditor session as this commit's own
  new suite.

## On PASS: status table update

```
B5    Candidate Provenance                    SEALED
B6    Candidate Projection / Dataset Lineage  SEALED
B7    Deterministic RiskPlan                  SEALED
B8.1  Immutable FeatureSnapshot               SEALED
B8.2  Training Dataset                        SEALED
B8.3  Model Registry / Artifact Contract      NEXT
```

`Docs/PhaseB_Architecture_Baseline.md` gets a dated update entry
recording B8.2 SEALED, the same way it already records B7 SEALED.

## Explicitly out of scope for this commit

Any new production function, event, struct field, or schema version
(including a real `LABELED_ONLY` export function — see above); any
model/ONNX/training-loop code; B8.3 (Model Registry / Artifact
Contract) — deliberately not started here; any change to an
already-sealed B5/B6/B7/B8.1/B8.2 production file.
