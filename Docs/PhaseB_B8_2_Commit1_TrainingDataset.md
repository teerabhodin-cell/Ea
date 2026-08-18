# Phase B8.2 — Commit 1: Training Dataset Row/Manifest Contract

**Status: Implemented, awaiting real compile/test confirmation.**
No test has been run yet — this doc will be updated to PASSED only
after a real MetaEditor compile/test log is reported back.

Implements `Docs/PhaseB_B8_2_TrainingDatasetContract.md`. Opens B8.2
after B8.1 PASSED (66/66) and merged. Scoped to schema, identity,
content hash, deterministic split policy, and a pure row-builder
function only — no event store export/rebuild orchestration (B8.2
Commit 2), no real label/outcome computation from a backtest or
broker fixture (Commit 3), no replay/regression sealing (Commit 4).

## Collision check

Checked before writing anything, the same discipline that caught the
`RiskPlan`/`FeatureSnapshot` collisions:

- `CandidateDatasetRow`/`CandidateDatasetManifest` (B6.2, sealed,
  75/75 PASSED) are a different concept — candidate+context
  provenance export, no `FeatureSnapshot`/`RiskPlan`/label/split at
  all. No collision; `TrainingDatasetRow`/`TrainingDatasetManifest`
  get their own, separately-named structs.
- `EVENT_TYPE_TRADE_OUTCOME_LABELED` (Phase A enum placeholder, never
  wired to anything) is flagged for whichever later commit first
  emits an event for `RealizedOutcome`/label data — not used by
  Commit 1, which has no event emission.
- `MLQUANTAI_LABEL_SCHEMA_VERSION = "TBM_V1"` (Phase A's dormant
  session-manifest placeholder) is not reused. Same precedent B8.1
  already set for `MLQUANTAI_FEATURE_SCHEMA_V1`: mint a new,
  phase-specific constant (`MLQUANTAI_LABEL_SCHEMA_B8_2_V1`) rather
  than reuse a dormant one, so model-registry compatibility questions
  stay unambiguous. Whether the real label semantics frozen in Commit
  3 end up actually being Triple Barrier Method (making `TBM_V1` the
  fitting eventual name) is a decision for that commit, not this one.

## What this commit adds

- **`Core/MLQuantAI_ContractVersions.mqh`** (additive):
  `MLQUANTAI_DATASET_SCHEMA_B8_2_V1`, `MLQUANTAI_LABEL_SCHEMA_B8_2_V1`,
  `MLQUANTAI_DATASET_SPLIT_POLICY_V1`.
- **`Core/MLQuantAI_Ids.mqh`** (additive):
  `Ids_TrainingDatasetRowId(featureSnapshotId, labelSchemaVersion, modelTarget)`.
- **`AI/MLQuantAI_TrainingDatasetRow.mqh`** (new): `TrainingDatasetRow`/
  `TrainingDatasetManifest` structs, `ENUM_DATASET_SPLIT`,
  `TrainingDatasetRow_HashPayload`/`_ComputeHash` (a "full record" hash
  — lineage + label/outcome + split + target together, the same sense
  B8.1's `feature_snapshot_hash` is a full record), `TrainingDatasetManifest_DatasetHash`
  (same style B6.2's `CandidateDatasetExport_DatasetHash` already
  established), `TrainingDatasetSplit_Assign` (deterministic,
  hash-derived, keyed on `candidate_id`).
- **`AI/MLQuantAI_TrainingDatasetBuilder.mqh`** (new):
  `BuildTrainingDatasetRow` — the pure row-builder (fail-closed
  validation, referential-integrity checks against the supplied
  `FeatureSnapshot`/`RiskPlan`, an unallowed `RiskPlan` rejected
  outright, verbatim lineage copy, identity + split + hash computed
  last).
- **`Tests/MLQuantAI_Test_B8_2_Commit1_TrainingDataset.mq5`** (new).

This is the first file in the new `Include/MLQuantAI/AI/` folder
(pre-existing, empty, clearly scaffolded for exactly this purpose —
checked before use). `FeatureSnapshot`/`FeatureSnapshotBuilder`
(B8.1) stay in `Market/` unchanged; only genuinely new B8.2 structs
go into `AI/`.

## Test coverage

Uses the real B5/B7/B8.1 pipeline (`CRT_DetectV1` →
`CRT_ToTradeCandidate` → `Candidate_ToRiskPlan` →
`Candidate_ToFeatureSnapshot`) for every fixture — no fabricated
hashes anywhere. No `EventStore` involved at all.

- **Determinism** — 10,000 repeated calls, same inputs, zero
  `dataset_row_id`/`row_hash`/`split` mismatches.
- **`dataset_row_id` dependencies** — depends only on
  `feature_snapshot_id`/`label_schema_version`/`model_target`; the
  split stays the same across different `model_target`s for the same
  candidate (proving the split is keyed on `candidate_id`, not the
  row identity).
- **`row_hash` inclusion sweep** — every included field, changed
  alone, moves the hash.
- **`row_hash` exclusion whitelist** — `dataset_row_id`/
  `dataset_schema_version` changed alone do NOT move the hash.
- **Referential integrity** — a `FeatureSnapshot` or `RiskPlan` whose
  `candidate_id`/`candidate_hash` doesn't match the candidate's own is
  rejected; an unallowed `RiskPlan` is rejected outright.
- **Fail-closed** — empty `candidate_id`, wrong `state`, empty
  `model_target`, and both directions of an inconsistent
  `labelAvailable`/label-fields combination are all rejected, with
  `outRow` left at `Init()` defaults.
- **`label_available == false` is a valid row** — builds successfully,
  with empty label/outcome fields and full identity/hash.
- **Split determinism + distribution** — the same `candidate_id`
  always gets the same split (1,000 repeated calls); a 2,000-sample
  statistical sanity check confirms the distribution lands close to
  the frozen 70/15/15 target (generous tolerance bands, not an
  exact-count assertion — chosen to comfortably clear normal
  statistical variance at that sample size without ever being flaky).
- **`dataset_hash`** — stable across repeated computation from the
  same row set; moves on reordering or on any single row's `row_hash`
  changing.
- **Input immutability** — `candidate`/`snapshot`/`plan` fields
  spot-checked unchanged before/after the call.
- **Structural checks** (verified by inspection, same class as B8.1's
  own): no `EventStore`/broker/history/tick call anywhere in
  `BuildTrainingDatasetRow`'s call path; no label/outcome data can
  reach `FeatureSnapshot` or its hashes, since
  `Candidate_ToFeatureSnapshot` has no label/outcome parameter at all.

## Explicitly out of scope for this commit

Event store export/rebuild orchestration (Commit 2), any real label/
outcome computation from a backtest or broker fixture (Commit 3), any
leakage/split statistical test suite beyond this commit's own sanity
check (Commit 3), replay/regression sealing (Commit 4), any
`AI_DECISION_CREATED` or `TRADE_OUTCOME_LABELED` event emission, any
change to an already-sealed B5/B6/B7/B8.1 production file.
