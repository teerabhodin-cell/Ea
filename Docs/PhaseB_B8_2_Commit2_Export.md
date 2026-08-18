# Phase B8.2 — Commit 2: FeatureSnapshot Persistence + Deterministic Training Dataset Export

**Status: Implemented, awaiting real compile/test confirmation.**
`Tests/MLQuantAI_Test_B8_2_Commit2_Export.mq5` written (19 test
functions covering both parts below), balance/identifier-length
checked, and self-reviewed line-by-line against the real struct
shapes and function signatures it calls. Not yet compiled/run by the
user — do not treat as PASSED or merge until a real MetaEditor log
confirms it.

Implements `Docs/PhaseB_B8_2_Commit2_ExportContract.md`. Opens after
B8.2 Commit 1 PASSED (76/76) and merged.

## Scope note: why this commit is bigger than originally proposed

The user's original Commit 2 proposal assumed a `FeatureSnapshotProjection`
already existed to read from. Checking the codebase first (the same
discipline that caught the B7/B8.1 struct collisions) found it did
not: B8.1 scoped `FeatureSnapshot` with zero event emission, and no
B8 roadmap commit had added one. Flagged to the user, who chose to
expand this commit to add the missing persistence layer first (Part
0, mirroring B7 Commit 2's own `RiskPlan` event/projection pattern),
then build the export orchestration on top of it (Part 1). Nothing
about B8.1's already-sealed `FeatureSnapshot` struct itself changed.

## Part 0 — `FEATURE_SNAPSHOT_CREATED` event + `FeatureSnapshotProjection`

- **`Core/MLQuantAI_Enums.mqh`** (additive): `EVENT_TYPE_FEATURE_SNAPSHOT_CREATED`
  appended at the end of `ENUM_EVENT_TYPE`, plus `EventTypeToString`/
  `EventTypeFromString` cases.
- **`Infrastructure/EventStore/MLQuantAI_FeatureSnapshotEventEmission.mqh`**
  (new): `FeatureSnapshot_EmitFeatureSnapshotCreated` — mirrors
  `RiskPlan_EmitRiskPlanCreated` exactly. Guard is `feature_snapshot_id == ""`
  (a `FeatureSnapshot` has no `allowed` field the way `RiskPlan` does).
  A live-session duplicate (already in `FeatureSnapshotProjection`) is
  a no-op, not a second event. On a successful durable write, also
  applies the record directly to `FeatureSnapshotProjection`'s live
  in-memory registry (the same live-sync fix B5 Commit 5 needed).
- **`Infrastructure/EventStore/MLQuantAI_FeatureSnapshotProjection.mqh`**
  (new): `FeatureSnapshotProjectionRecord` (all B1 feature fields + all
  B8.1 lineage fields), required-field/numerical-integrity validation,
  payload-aware collision-vs-duplicate detection keyed on
  `feature_snapshot_id`/`feature_snapshot_hash`, referential-integrity
  check against `CandidateProjection` (orphan `candidate_id` or a
  `candidate_hash` mismatch rejects the line), `EventStoreValidator`-gated
  atomic rebuild that leaves the registry untouched on any failure.

Two deliberate differences from `RiskPlanProjection`:
- No `allowed` field — the guard is just `feature_snapshot_id == ""`.
- `is_kill_zone` is read back via a local `FeatureSnapshotProjection_GetBoolLiteral`
  helper, not `EventSerializer_GetStr`, because it's emitted as an
  unquoted JSON boolean literal (matching `MarketContext_ToJsonFragment`'s
  own convention) and `EventSerializer_GetStr`'s needle requires a
  quoted value — using `GetStr(...) == "true"` would have silently
  read back `false` for every record. Caught in self-review before any
  test run.

## Part 1 — `TrainingDatasetExport_BuildDataset`

- **`Core/MLQuantAI_Ids.mqh`** (additive): `Ids_TrainingDatasetId(fileName, modelTarget, datasetHash)`.
- **`AI/MLQuantAI_TrainingDatasetRow.mqh`** (additive):
  `TrainingDatasetManifest.labeled_count` field (always `0` in this
  commit's own output — the contract's own explicit statement that
  this field would be added here).
- **`Infrastructure/EventStore/MLQuantAI_TrainingDatasetExport.mqh`**
  (new): `TrainingDatasetExport_BuildDataset(fileName, modelTarget, rows[], manifest)`
  — deterministic, read-only export joining `CandidateProjection` +
  `FeatureSnapshotProjection` + `RiskPlanProjection`, calling the
  sealed `BuildTrainingDatasetRow` (B8.2 Commit 1) once per qualifying
  candidate via three minimal type-bridging adapters. No feature,
  risk-sizing, or label value is ever computed here — only composition
  of what earlier phases already computed and persisted.

Rules enforced:
- A candidate missing a `FeatureSnapshot` or an ALLOWED `RiskPlan` is
  **skipped** (normal lifecycle state), not a failure.
- Fails closed only on genuine corruption: `EventStoreValidator`
  failure, either projection's own rebuild failure, or a mixed-cohort
  condition (non-uniform `feature_schema_version`/`split_policy_version`
  across the exported cohort).
- Duplicate-identity policy: same `dataset_row_id` + same `row_hash` is
  a no-op skip; same id + different hash fails the whole export closed.
- Row/manifest order: `candidate.setup_anchor_bar_time ASC, dataset_row_id ASC`
  — never event sequence, session, or export time.
- `source_store_fingerprint` = SHA-256 over every validated input line
  in original file order (an input fingerprint, not an output one).
- On any fail-closed condition: `rows[]` stays empty and `manifest`
  stays at `Init()` defaults — no partial output.

## Bugs found and fixed during self-review (before any test run)

- `is_kill_zone` unquoted-boolean read-back (see Part 0 above).
- An initial mistaken belief that no JSON-int-reading helper existed
  (`EventSerializer_GetInt`/`GetLong` were missed by an overly strict
  grep) — corrected to use `EventSerializer_GetInt` directly instead
  of `(int)EventSerializer_GetDouble(...)`.
- `TrainingDatasetExport_SortRows`'s insertion sort had a comment
  claiming the parallel `anchorTimes[]` array would shift in lockstep
  with `rows[]`, but the shift was never actually coded — would have
  desynced the two arrays mid-sort. Fixed by adding the missing shift
  lines, which in turn required dropping the `const` qualifier from
  the `anchorTimes` parameter (MQL5 disallows mutating a `const`
  reference).
- `MLQuantAI_FeatureSnapshotEventEmission.mqh` was initially written
  into `Market/` (matching where `FeatureSnapshot.mqh` itself lives);
  corrected to `Infrastructure/EventStore/`, per the precedent already
  set by `RiskPlanEventEmission.mqh` (whose struct, `RiskPlan.mqh`,
  likewise lives in `Core/` while its emission/projection files live
  in `Infrastructure/EventStore/`).
- `Ids_TrainingDatasetId` was initially defined locally inside the
  export file; moved to `Core/MLQuantAI_Ids.mqh` for consistency with
  every other `Ids_*` function.

## Test coverage

`Tests/MLQuantAI_Test_B8_2_Commit2_Export.mq5`, 19 test functions.
Uses the real B5/B7/B8.1/B8.2-Commit-1 pipeline for every fixture —
no fabricated hashes anywhere.

**Part 0** (mirrors B7 Commit 2's own suite structure): exactly-one
emission, same-session duplicate no-op, unfilled snapshot emits
nothing, replay duplicate-same-hash no-op, replay collision-different-hash
rejected, replay orphan-candidate rejected, replay candidate-hash-mismatch
rejected, a malformed line blocks the whole rebuild, restart/crash
simulation (repeated rebuilds are byte-identical), multi-session
rebuild, every field on a rebuilt record matches the original exactly.

**Part 1** (the user's own explicitly-requested test matrix): a fully-
qualified 3-candidate store exports exactly 3 rows; a candidate
missing a `FeatureSnapshot`/`RiskPlan` is skipped, not a failure;
export is read-only (byte-identical store before/after); re-running
the export is deterministic (same `dataset_hash`/`dataset_id`/row
order); rows are ordered by `setup_anchor_bar_time` ASC regardless of
emission order; a mixed `feature_schema_version` cohort fails the
whole export closed with no partial output; a corrupted store fails
closed with no partial output; an empty `modelTarget` is rejected
outright.

**Structural** (verified by inspection, same class as B8.1/Commit-1's
own): the export path calls only `BuildTrainingDatasetRow` over
already-persisted projection records — no `Candidate_ToFeatureSnapshot`,
no `Candidate_ToRiskPlan`, no label/outcome generator, no
`EventStore_Log*`/`OrderSend`/`CTrade`/`AccountInfo*`/`SymbolInfo*`/
`TimeCurrent` call anywhere in the export path.

## Explicitly out of scope for this commit

Real label/outcome computation from a backtest or broker fixture
(Commit 3), leakage/split statistical test suite beyond Commit 1's own
sanity check (Commit 3), replay/regression sealing (Commit 4), any
`AI_DECISION_CREATED` or `TRADE_OUTCOME_LABELED` event emission, any
model/ONNX/training code, any change to an already-sealed B5/B6/B7/B8.1
production file.
