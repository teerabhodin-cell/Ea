# Phase B8.2 — Commit 3: Outcome/Label Boundary

**Status: PASSED (2026-08-19).** Confirmed on a real compile/test run:
`MLQuantAI_Test_B8_2_Commit3_OutcomeLabel.mq5` 109/109 ALL PASS (18
test functions, Part 0 and all 7 Part 1 groups). No production code
needed any change after the self-review pass already described below.

Implements `Docs/PhaseB_B8_2_Commit3_OutcomeLabelContract.md`. Opens
after B8.2 Commit 2 PASSED (105/105) and merged.

## Scope decisions confirmed before freezing

1. **Synthetic fixtures only.** No live Execution Engine exists yet
   (B9/C are future phases) — `RealizedOutcome` is built and tested
   from data constructed directly in the test file, same as every
   other B8.2 fixture. Real broker/backtest wiring stays out of scope.
2. **`candidate_time` = `setup_anchor_bar_time`.** The only real,
   persisted time anchor in the B8.2 lineage.
3. **`EVENT_TYPE_TRADE_OUTCOME_LABELED` reused, not re-minted** — the
   dormant Phase A enum slot this commit finally wires up.
4. **`MLQUANTAI_LABEL_SCHEMA_B8_2_V1` stays the only label schema
   constant** — Phase A's dormant `MLQUANTAI_LABEL_SCHEMA_VERSION =
   "TBM_V1"` is not reused.
5. **`BuildTrainingDatasetRow` (Commit 1, sealed) is not reopened** —
   `RealizedOutcome_Build` rejects any `labelSchemaVersion` other than
   `MLQUANTAI_LABEL_SCHEMA_B8_2_V1`, since the row builder itself
   unconditionally stamps that constant and takes no caller-supplied
   schema version.

## Part 0 — incomplete-cohort semantics made normative (Commit 2 addendum)

No behavior change — only documents, as a binding table, the
skip-vs-fail-closed policy Commit 2 already implemented, plus two new
manifest counters for observability:

- **`Core/MLQuantAI_ContractVersions.mqh`**: no change (see Part 1).
- **`AI/MLQuantAI_TrainingDatasetRow.mqh`** (additive):
  `TrainingDatasetManifest.candidate_count`/`.incomplete_count`.
- **`Infrastructure/EventStore/MLQuantAI_TrainingDatasetExport.mqh`**
  (extended): `candidate_count` = every `CandidateProjection` record
  considered; `incomplete_count` incremented on each of the two
  existing skip paths (missing `FeatureSnapshot`, missing an ALLOWED
  `RiskPlan`). `rejected_count`/`first_rejection_reason` deliberately
  **not** added — under the current fail-closed design any genuine
  rejection already aborts the whole export, so a successful manifest
  can never report a nonzero count for one.

## Part 1 — `RealizedOutcome`

- **`Core/MLQuantAI_ContractVersions.mqh`** (additive):
  `MLQUANTAI_REALIZED_OUTCOME_SCHEMA_B8_2_V1`.
- **`Core/MLQuantAI_Ids.mqh`** (additive):
  `Ids_RealizedOutcomeId(candidateId, labelSchemaVersion)` — identity
  depends only on candidate + schema, never on the outcome's own
  computed content, same philosophy `Ids_RiskPlanId`/
  `Ids_FeatureSnapshotId` already established.
- **`AI/MLQuantAI_RealizedOutcome.mqh`** (new): `RealizedOutcome`
  struct, `_Init`, `_HashPayload`/`_ComputeHash` — a single full-record
  hash, no two-hash split (unlike `FeatureSnapshot`, since a
  `RealizedOutcome` is inherently 1:1 with one candidate's outcome).
- **`AI/MLQuantAI_RealizedOutcomeBuilder.mqh`** (new):
  `RealizedOutcome_Build` — fail-closed validation ladder (empty
  candidate/label/outcome_reference/outcome_hash, wrong
  `candidate.state`, `labelSchemaVersion` must equal
  `MLQUANTAI_LABEL_SCHEMA_B8_2_V1`, `outcome_time` must be strictly
  after `candidate.setup_anchor_bar_time`), identity computed first,
  content hash computed last.
- **`Infrastructure/EventStore/MLQuantAI_RealizedOutcomeEventEmission.mqh`**
  (new): `RealizedOutcome_EmitTradeOutcomeLabeled` — mirrors
  `FeatureSnapshot_EmitFeatureSnapshotCreated` exactly.
- **`Infrastructure/EventStore/MLQuantAI_RealizedOutcomeProjection.mqh`**
  (new): `RealizedOutcomeProjectionRecord` registry, required-field
  validation, payload-aware collision-vs-duplicate detection,
  referential integrity against `CandidateProjection` (orphan
  `candidate_id` or `candidate_hash` mismatch rejected), **plus a
  temporal-boundary check on replay** (`outcome_time` must be strictly
  after the referenced candidate's own `setup_anchor_bar_time` —
  enforced again here, not just at build time, so a tampered/replayed
  line can't smuggle in a temporally-impossible outcome),
  `EventStoreValidator`-gated atomic rebuild.
- **`Infrastructure/EventStore/MLQuantAI_TrainingDatasetExport.mqh`**
  (extended, not reopened at the signature level): rebuilds
  `RealizedOutcomeProjection` alongside the other three; for each
  qualifying candidate, looks up a `RealizedOutcome` record and passes
  its real `label`/`outcome_reference`/`outcome_hash` to
  `BuildTrainingDatasetRow` when found (`labelAvailable=true`),
  otherwise unchanged from Commit 2 (`labelAvailable=false`).
  `manifest.labeled_count`/`unlabeled_count` are now tallied for real
  from each row's `label_available`, replacing Commit 2's hardcoded
  `labeled_count=0`.

### The leakage-protection invariant

> Adding or changing future outcome evidence may change the training
> row's label/content hash, but MUST NEVER change the candidate-time
> feature vector or its hash.

Holds structurally: `Candidate_ToFeatureSnapshot` (B8.1, sealed) has
no `RealizedOutcome` parameter; the feature-snapshot lookup path in
the export is untouched; `RealizedOutcomeProjection` is looked up
independently, in parallel, never merged into it. Proven empirically
too — `Test_Leakage_FeatureHashUnchangedByOutcome` exports the same
candidate before and after a `RealizedOutcome` exists for it and
asserts `feature_snapshot_hash`/`feature_vector_hash` are byte-identical.

### The split-stability invariant

`TrainingDatasetSplit_Assign` (Commit 1, sealed) and its call site
inside `BuildTrainingDatasetRow` (Commit 1, sealed) are untouched —
split depends only on `candidate_id` + `split_policy_version`, never
on label content. Proven by `Test_SplitStability_UnchangedByLabel`:
the same candidate's `split` is identical whether exported unlabeled
or labeled.

## Test coverage

`Tests/MLQuantAI_Test_B8_2_Commit3_OutcomeLabel.mq5`, 18 test
functions. Uses the real B5/B7/B8.1/B8.2 pipeline for every fixture;
`RealizedOutcome` data is constructed directly in the test file
(synthetic fixtures, per scope decision 1).

- **Part 0**: `candidate_count`/`incomplete_count` correctly tallied
  against a store with 2 fully-qualified + 1 incomplete candidate;
  `candidate_count == row_count + incomplete_count` holds.
- **Group 1 (identity/determinism)**: 1,000 repeated builds, identical
  `realized_outcome_id`/`realized_outcome_hash` every time; identity
  formula matches `Ids_RealizedOutcomeId` directly.
- **Group 2 (temporal boundary)**: strictly-after accepted; equal
  rejected; earlier rejected — at both build time and replay time
  (a tampered `outcome_time` on an otherwise-valid line is rejected).
- **Group 3 (referential integrity)**: empty
  label/outcome_reference/outcome_hash/candidate_id rejected at build;
  wrong `labelSchemaVersion` rejected at build; orphan `candidate_id`
  and `candidate_hash` mismatch rejected on replay.
- **Group 4 (duplicate/collision)**: exactly-one emission; unfilled
  outcome emits nothing; live-session duplicate no-op; replay
  duplicate (same id + same hash) no-op; replay collision (same id +
  different hash) rejected; multi-session/restart replay byte-identical.
- **Group 5 (leakage protection)**: empirical proof (feature hashes
  unchanged before/after a `RealizedOutcome` exists) plus a structural
  exclusion-proof statement.
- **Group 6 (dataset integration)**: unlabeled row still exports;
  labeled row gets real label/outcome fields; `row_hash`/`dataset_hash`
  move when a label is legitimately added while `dataset_row_id` stays
  the same; manifest `labeled_count`/`unlabeled_count` correct.
- **Group 7 (split stability)**: same candidate's `split` is identical
  whether exported unlabeled or labeled — direct regression test.

## Explicitly out of scope for this commit

Any real broker/backtest producer of `RealizedOutcome` (stays out of
scope until B9/C exist); any label methodology decision (what "WIN"/
"LOSS"/a numeric target actually means); any change to
`TrainingDatasetRow`'s own identity/hash/split semantics (Commit 1,
sealed); any change to `Candidate_ToFeatureSnapshot`,
`Candidate_ToRiskPlan`, or `BuildTrainingDatasetRow`'s signatures
(sealed); any model/ONNX/training-loop code; full replay/export
regression across the whole B8.2 arc (Commit 4's job, the sealing
commit).
