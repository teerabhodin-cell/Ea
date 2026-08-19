# Phase B8.2 — Commit 2: Persisted-Artifact Projection/Export (FROZEN)

**Status: FROZEN, before any code exists.** Opens after B8.2 Commit 1
PASSED (76/76) and merged. Title: **Deterministic Training Dataset
Projection/Export from Persisted Artifacts Only.**

```
Persisted Event Store
    -> Validated replay / projections
    -> CandidateProjection + FeatureSnapshotProjection + RiskPlanProjection
    -> TrainingDatasetRow set
    -> Canonical manifest + dataset_hash
    -> Read-only export
```

Commit 2 consumes the sealed B5/B6/B7/B8.1/B8.2-Commit-1 contracts
without changing any identity, hash, schema, split, or label
semantics they already define. It is projection/export orchestration
only — not a second feature engine, risk engine, label engine, or
model pipeline.

## A gap found before writing this contract, and how it's resolved

`Docs/PhaseB_B8_2_TrainingDatasetContract.md`'s own pipeline diagram
names `FeatureSnapshotProjection` as an existing source alongside
`CandidateProjection`/`RiskPlanProjection`. It does not exist.
Checked directly (`grep` across `Include/`, zero matches for
`FeatureSnapshotProjection`/`FEATURE_SNAPSHOT_CREATED`): B8.1 sealed
`Candidate_ToFeatureSnapshot` as a pure in-memory function only — no
event emission, no projection, no replay, exactly as
`Docs/PhaseB_B8_1_FeatureSnapshotContract.md` section 5 says
explicitly ("Replay restores a persisted FeatureSnapshot's fields
verbatim... once B8.5/B8.6 add persistence/replay"), but no commit in
the agreed B8 roadmap (B8.1 -> B8.2 -> ... -> B8.6) actually adds it.

Resolved (confirmed): **Commit 2 adds `FEATURE_SNAPSHOT_CREATED`
event emission + `FeatureSnapshotProjection` first**, mirroring B7
Commit 2's own `RISK_PLAN_CREATED`/`RiskPlanProjection` pattern
field-for-field, THEN builds the `TrainingDatasetRow` export
orchestration on top of all three now-real projections. This is a
real prerequisite, not scope creep — "export from persisted artifacts
only" is not achievable for the feature-snapshot lineage fields
without it.

## Part 0 — `FEATURE_SNAPSHOT_CREATED` event + `FeatureSnapshotProjection`

Mirrors `Docs/PhaseB_B7_RiskPlanContract.md`'s B7 Commit 2 addendum
exactly, substituting `FeatureSnapshot` for `RiskPlan` throughout.
Differences from that mirror, called out explicitly:

- **No `allowed` field.** `RiskPlan_EmitRiskPlanCreated`'s guard is
  `p.risk_plan_id == "" || !p.allowed`. `FeatureSnapshot` has no
  `allowed` concept — `FeatureSnapshot_EmitFeatureSnapshotCreated`'s
  guard is simply `p.feature_snapshot_id == ""` (a successfully-built
  `FeatureSnapshot`, per B8.1's own `Candidate_ToFeatureSnapshot`
  returning `true`, always has a non-empty `feature_snapshot_id`).
- **Duplicate-vs-collision key**: `feature_snapshot_id` +
  `feature_snapshot_hash` (identity + content), the same
  `risk_plan_id`/`plan_hash` pattern.
- **Referential integrity on replay**: `candidate_id` must exist in
  `CandidateProjection` (rebuilt from the same file first, same
  dependency direction `RiskPlanProjection` already has), and
  `candidate_hash` must match. `context_hash`/`detector_hash` are
  carried as lineage but not independently re-verified against
  `MARKET_CONTEXT_READY` in Commit 2 (B6.2's dataset export already
  established that MarketContext-level joins are a separate, optional
  concern — `CandidateProjection`'s own `candidate_hash` match is the
  binding integrity check here, consistent with how `RiskPlanProjection`
  itself never re-verifies `context_hash` against `MARKET_CONTEXT_READY`
  either).

### `FeatureSnapshotProjectionRecord`

Every `FeatureSnapshot` field (all 12 Phase B1 feature fields plus all
7 B8.1 lineage/identity/hash fields) plus `source_sequence_number`/
`source_log_event_id` — the full record, not just hashes, since a
downstream dataset builder eventually needs the real feature values,
the same reason `CandidateProjectionRecord` carries `entry_hint`/
`sl_hint`/`tp_hint` and not just `candidate_hash`.

### `EVENT_TYPE_FEATURE_SNAPSHOT_CREATED`

Appended at the very end of `ENUM_EVENT_TYPE` (after
`EVENT_TYPE_RISK_PLAN_CREATED`), same append-only rule as every prior
addition. A `SystemEvent`, not a `LifecycleEvent` — a `FeatureSnapshot`
is a derived artifact tied to a candidate, exactly the same reasoning
`RISK_PLAN_CREATED` already used.

### QA gate for Part 0 (mirrors B7 Commit 2's own gate exactly)

Exactly-once emission; live-session duplicate no-op; a rejected
(empty-id) snapshot emits nothing; replay duplicate (same id + same
hash) no-op; replay collision (same id + different hash) rejected;
orphan candidate reference rejected; candidate_hash mismatch rejected;
malformed line blocks the whole rebuild; restart/multi-session replay
byte-identical; every field on a rebuilt record matches the original.

## Part 1 — `TrainingDatasetRow` export orchestration

### Normative rules (binding, verbatim)

> A training dataset export MUST be derived exclusively from
> persisted, validated artifacts. It MUST NOT recompute feature
> values, risk-plan values, labels, split assignments, or lineage
> references from live market, broker, account, execution, indicator,
> clock, or runtime state.

> If any source artifact, reference, identity, hash, schema version,
> or lineage relationship cannot be validated, the complete export
> MUST fail closed. It MUST produce no partial dataset, manifest, or
> serialized output.

**Clarification on "recompute... split assignments"**: the export
calls `BuildTrainingDatasetRow` (B8.2 Commit 1, sealed) once per
qualifying candidate, which internally calls
`TrainingDatasetSplit_Assign`. This is not the prohibited kind of
recomputation — `TrainingDatasetRow` was never itself persisted as an
event (Commit 1 added no event type for it), so there is nothing to
"replay" for it; calling an already-frozen, deterministic pure
function over already-persisted, already-validated inputs
(`CandidateProjectionRecord`/`FeatureSnapshotProjectionRecord`/
`RiskPlanProjectionRecord`) is exactly what
`CandidateDatasetExport_BuildRow` (B6.2) and
`RiskPlanProjection_RebuildFromFile`'s own record construction already
do. The prohibited case is re-running the *feature engine*, the
*sizing formula* against a possibly-different current account state,
or fabricating a label — none of which this export ever does.

### Per-row lineage validation

```
TrainingDatasetRow
    +-- candidate_id / candidate_hash
    |       -> CandidateProjection record (must exist)
    |
    +-- feature_snapshot_id / feature_snapshot_hash / feature_vector_hash
    |       -> FeatureSnapshotProjection record: same candidate_id + candidate_hash
    |          (already enforced by FeatureSnapshotProjection's OWN
    |          rebuild-time referential-integrity check - the export
    |          orchestration trusts an already-successfully-rebuilt
    |          projection, it does not re-verify hash equality itself)
    |
    +-- risk_plan_id / plan_hash / sizing_rules_version
            -> RiskPlanProjection record: same candidate_id + candidate_hash
               (same trust boundary - RiskPlanProjection's own rebuild
               already verified this)
```

A candidate present in `CandidateProjection` but **missing** a
`FeatureSnapshotProjection` record, or missing an **ALLOWED**
`RiskPlanProjection` record, is not a corruption — it is a normal
lifecycle state (B7/B8.1 don't necessarily run for every candidate;
`BuildTrainingDatasetRow` itself already treats "no ALLOWED plan" as
"no row" rather than an error). Such a candidate is **skipped**, not
a fail-closed condition. Fail-closed triggers only on genuine
corruption: `EventStoreValidator` failure, any of the three
projections' own `RebuildFromFile` failing (malformed line,
orphan reference, hash mismatch, collision), or a mixed-cohort
condition (below).

`label_available=false` rows are the ONLY kind Commit 2 can produce —
it has no label/outcome data source. Every row is built via
`BuildTrainingDatasetRow(candidate, snapshot, plan, false, "", "", "", modelTarget, outRow)`.
Commit 2 must not generate or resolve a label or outcome under any
circumstance — that boundary belongs entirely to Commit 3.

### Mixed-cohort rejection

The exported cohort must be internally uniform on
`feature_schema_version` and `split_policy_version` (both read from
each built row) — if any two qualifying candidates' rows disagree on
either, the whole export fails closed with no partial output.
`model_target` and `label_schema_version` cannot be "mixed" in Commit
2's own output by construction: `model_target` is a single caller-
supplied parameter applied uniformly to the whole export call, and
every row's `label_schema_version` is stamped identically by
`BuildTrainingDatasetRow` itself (Commit 2 never reads a per-candidate
label schema from the store, since none is persisted yet). This check
exists for when `MLQUANTAI_FEATURE_SCHEMA_B8_1_V1` or
`MLQUANTAI_DATASET_SPLIT_POLICY_V1` eventually bump to a `_V2` and an
old store still contains snapshots built under the old constant —
exporting those together with new-constant snapshots into one
manifest would misrepresent the cohort.

### Duplicate identity policy (defensive, within one export run)

While building rows, if a `dataset_row_id` already produced in this
export is encountered again: same `row_hash` -> no-op (skip, don't
duplicate the row); different `row_hash` -> collision, fail the whole
export closed. This should be structurally unreachable given
`CandidateProjection`'s own candidate_id uniqueness, but is checked
defensively anyway — the same "every layer defends against its own
inputs, never assumes an upstream guarantee holds perfectly"
discipline this whole project already follows.

### Row and manifest ordering

```
Row order:    candidate.setup_anchor_bar_time ASC, dataset_row_id ASC
Manifest order: identical to the final row order
```

Never event sequence number, session_id, or export time. Both
`dataset_hash` and any serialized output use this order exclusively.

### `TrainingDatasetManifest` — additive field

`labeled_count` is added to the struct frozen in Commit 1 (additive,
no existing field repurposed) — `row_count - unlabeled_count` is
derivable, but making it explicit avoids every consumer re-deriving
it. In Commit 2's own output `labeled_count` is always `0` (Commit 2
produces no labeled rows) — the field exists now so Commit 3 doesn't
need a struct change later.

`source_store_fingerprint` (frozen as unpopulated in Commit 1) is now
defined and populated: `Ids_Sha256Hex` over every validated line of
the source file, joined by `"\n"`, in original file order (not
canonical row order — a fingerprint of the INPUT, not the output). Two
different stores that happen to produce the same rows must not be
mistaken for the same source; two identical stores must always
fingerprint identically.

### The export function

```cpp
bool TrainingDatasetExport_BuildDataset(string fileName, string modelTarget,
                                          TrainingDatasetRow &rows[], TrainingDatasetManifest &manifest)
```

Algorithm:

1. `ArrayResize(rows, 0)`, `TrainingDatasetManifest_Init(manifest)`. Reject
   (return `false`) if `modelTarget == ""`.
2. Validator-gate the file (`EventStoreValidator_ValidateLines`) —
   fail closed on any structural corruption.
3. `FeatureSnapshotProjection_RebuildFromFile(fileName)` — fail closed
   if it fails (this call's own prerequisite already rebuilds
   `CandidateProjection` on the same file).
4. `RiskPlanProjection_RebuildFromFile(fileName)` — fail closed if it
   fails (same prerequisite chain, redundant but harmless re-rebuild
   of `CandidateProjection` — consistent with how each projection
   layer already independently enforces its own prerequisite rather
   than trusting a sibling layer's prior rebuild).
5. Iterate every `CandidateProjection` record. For each: look up its
   `FeatureSnapshotProjection` record (skip if absent) and its
   `RiskPlanProjection` record (skip if absent or not `allowed`). Call
   `BuildTrainingDatasetRow` with `labelAvailable=false`. Apply the
   duplicate-identity policy above as each row is produced.
6. After all rows are built: verify `feature_schema_version` and
   `split_policy_version` are uniform across every row — fail closed
   (no partial output) if not.
7. Sort rows by the frozen order (step "Row and manifest ordering").
8. Compute `dataset_hash` (`TrainingDatasetManifest_DatasetHash`, B8.2
   Commit 1, unchanged) over the final sorted order.
9. Populate the manifest: `dataset_id` (a fresh
   `Ids_Deterministic("TDSET", fileName + "|" + modelTarget + "|" + dataset_hash)`
   — deterministic, so re-exporting the identical store with the
   identical `modelTarget` always gets the identical `dataset_id`),
   `dataset_hash`, `feature_schema_version`/`split_policy_version`
   (from any row, now known-uniform), `label_schema_version`
   (`MLQUANTAI_LABEL_SCHEMA_B8_2_V1`, uniform by construction),
   `model_target`, `row_count`, `train_count`/`validation_count`/
   `test_count` (tallied from `split`), `labeled_count=0`,
   `unlabeled_count=row_count`, `source_store_fingerprint`.
10. Return `true`. No event append, no broker/order/history call
    anywhere — read-only from start to finish.

### Read-only proof

The event store file's own line count and byte content must be
identical before and after a call to
`TrainingDatasetExport_BuildDataset` — same class of check B6.2's own
`Test_ExportIsReadOnly` already established for
`CandidateDatasetExport_BuildDataset`.

## QA gate for B8.2 Commit 2 (binding on its test suite)

Part 0 (event/projection) — the full mirror of B7 Commit 2's own gate,
restated above.

Part 1 (export):
- A store with N fully-qualified candidates (FeatureSnapshot +
  ALLOWED RiskPlan both present) exports exactly N rows, correctly
  ordered.
- A candidate missing a `FeatureSnapshot`, or missing an ALLOWED
  `RiskPlan`, is silently skipped — not a failure, not a partial row.
- Mixed-cohort rejection: a store containing snapshots built under two
  different `feature_schema_version` values is rejected wholesale.
- Duplicate identity: constructing a scenario where the same
  `dataset_row_id` would be produced twice with the same `row_hash` is
  a no-op; with a different `row_hash` fails the whole export closed.
- Read-only proof: the store's line count and byte content are
  unchanged before/after export.
- Exclusion proof (structural, verified by inspection): the export
  path calls no function that computes a NEW feature value, a NEW
  risk-sizing value, or a NEW label/outcome — only
  `BuildTrainingDatasetRow` (Commit 1, sealed) over already-persisted
  projection records.
- Fail-closed: `EventStoreValidator` failure, any projection's own
  `RebuildFromFile` failure, and the mixed-cohort case all leave
  `rows[]` empty and `manifest` at `Init()` defaults — no partial
  output in any failure path.
- Determinism: re-running the export against the identical file and
  `modelTarget` produces byte-identical `dataset_hash`, `dataset_id`,
  and row set/order, repeatedly.
- Manifest counts (`row_count`/`train_count`/`validation_count`/
  `test_count`/`labeled_count`/`unlabeled_count`) are internally
  consistent (`train+validation+test == row_count`,
  `labeled+unlabeled == row_count`).

## Explicitly out of scope for Commit 2

Any real label/outcome computation or `RealizedOutcome` structure
(Commit 3), any change to `TrainingDatasetRow`'s identity/hash/split
semantics (frozen in Commit 1), any change to
`Candidate_ToFeatureSnapshot`'s own algorithm (frozen in B8.1), any
model/ONNX/training-loop code, any change to an already-sealed
B5/B6/B7 production file.
