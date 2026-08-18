# Phase B8.1 — FeatureSnapshot Identity/Lineage/Hash

**Status: PASSED (2026-08-19).** Confirmed on a real compile/test run:
`MLQuantAI_Test_B8_1_FeatureSnapshot.mq5` 66/66 ALL PASS. No
production code needed any change after the include-graph fix below —
the only other obstacles on the way to a clean run were file-placement/
sync issues on the test machine (multiple stale copies of
`MLQuantAI_Ids.mqh`), resolved by sending a full zip of
`Include/MLQuantAI/` + `Tests/` to extract-and-replace in one step
instead of copying files one at a time.

Implements the frozen `Docs/PhaseB_B8_1_FeatureSnapshotContract.md`.
Opens after B7 SEALED (Commits 1-3, 203/203, full B5/B6/B7 regression
suite 474/474, zero regressions).

## The collision, and how it was resolved

`Market/MLQuantAI_FeatureSnapshot.mqh` already existed from Phase B1:
a real, sealed, but completely unwired struct (no Feature Engine
builds it) with a fixed set of named feature fields (`atr_m15`,
`adx_m15`, `ema_slope_m15`, `pdh`, `pdl`, `asian_range_high`,
`asian_range_low`, `spread_points_at_anchor`, `news_count`,
`max_news_impact`, `nearest_news_minutes`, `is_kill_zone`), keyed only
by `context_event_id` — no identity field, no content hash, no
candidate lineage. Resolved the same way the B7 `RiskPlan` collision
was: extend the existing struct additively. Every Phase B1 field stays
exactly as it is; seven new fields were added for B8.1's
identity/lineage/hash needs. No generic `feature_values` map was
introduced — B8.1 keeps this codebase's convention of fixed, named,
typed fields.

## Revision during the freeze pass

The first frozen draft was revised once, before any code was written,
in response to review:

1. **Schema version.** `feature_schema_version` stays the only schema
   field (no second field added), but a snapshot actually built by
   `Candidate_ToFeatureSnapshot` now carries a new
   `MLQUANTAI_FEATURE_SCHEMA_B8_1_V1` constant, not the dormant Phase
   B1 `MLQUANTAI_FEATURE_SCHEMA_V1`. `FeatureSnapshot_Init()` itself
   is untouched (still stamps the old generic constant) specifically
   to avoid regressing `Tests/MLQuantAI_Test_PhaseBContracts.mq5`'s
   existing sealed assertion — `Candidate_ToFeatureSnapshot` overwrites
   it on success, the same `Init()`-defaults-generic /
   populate-function-sets-the-real-value split `RiskPlan` already uses.
2. **`detector_hash`** added as a fourth copied-verbatim lineage field,
   for full provenance depth without a second lookup.
3. **Two hashes instead of one.** `feature_vector_hash` (pure ML-input
   content — the 12 feature fields + `feature_schema_version`, no
   lineage) and `feature_snapshot_hash` (full record — every lineage
   field + `feature_schema_version` + `feature_vector_hash`).
   `RiskPlan` never needed this split since a `RiskPlan` is never
   meaningfully "the same" across two different candidates; a feature
   vector genuinely can be (dataset dedup, inference-cache hits,
   leakage checks between train/test splits in later B8 phases).

## What this commit adds

- **`Core/MLQuantAI_ContractVersions.mqh`** (additive):
  `MLQUANTAI_FEATURE_SCHEMA_B8_1_V1`.
- **`Core/MLQuantAI_Ids.mqh`** (additive): `Ids_FeatureSnapshotId(candidateId)`
  — single-argument, unlike `Ids_RiskPlanId`, since
  `Candidate_ToFeatureSnapshot` has no methodology choice yet to
  depend on.
- **`Market/MLQuantAI_FeatureSnapshot.mqh`** (additive): 7 new fields
  (`feature_snapshot_id`, `candidate_id`, `candidate_hash`,
  `context_hash`, `detector_hash`, `feature_vector_hash`,
  `feature_snapshot_hash`); `FeatureSnapshot_Init` extended to
  initialize them; `FeatureSnapshot_VectorHashPayload`/
  `_ComputeVectorHash` (pure content); `FeatureSnapshot_HashPayload`/
  `_ComputeHash` (full record).
- **`Market/MLQuantAI_FeatureSnapshotBuilder.mqh`** (new):
  `FeatureSnapshotBuilder_ValidateInput`, `Candidate_ToFeatureSnapshot`
  — the pure copy/identity/hash function (contract section 4): fail-
  closed validation (empty `candidate_id`, wrong `state`, referential
  mismatch against the supplied `MarketContext`, NaN/Inf feature
  fields), verbatim copy of all 12 Phase B1 feature fields plus the 4
  lineage fields, identity + both hashes computed last.
- **`Tests/MLQuantAI_Test_B8_1_FeatureSnapshot.mq5`** (new).

## Test coverage

Uses the real B5 pipeline (`CRT_DetectV1` → `CRT_ToTradeCandidate`) for
every fixture candidate — no fabricated `candidate_hash`/
`detector_hash`/`context_hash` anywhere. No `EventStore` involved at
all: `Candidate_ToFeatureSnapshot` is a pure in-memory function with
no event emission in B8.1, mirroring B7 Commit 1.

- **Determinism** — 10,000 repeated calls, same candidate + same
  `MarketContext`, zero `feature_snapshot_id`/`feature_vector_hash`/
  `feature_snapshot_hash` mismatches.
- **`feature_snapshot_id` identity** — equals
  `Ids_FeatureSnapshotId(candidate_id)` exactly.
- **`feature_vector_hash` inclusion sweep** — `feature_schema_version`
  and each of the 12 feature fields, changed alone, moves the hash
  (and `feature_snapshot_hash` too, via its dependency).
- **Lineage-only mutation sweep** — the core two-hash-split property:
  changing `candidate_id`/`candidate_hash`/`context_event_id`/
  `context_hash`/`detector_hash`/`feature_snapshot_id` alone moves
  `feature_snapshot_hash` but NEVER `feature_vector_hash`.
- **Lineage copied verbatim** — `candidate_hash`/`context_hash`/
  `detector_hash`/`context_event_id` on the snapshot exactly equal the
  candidate's own fields.
- **Different candidate, different identity** — two real candidates
  with different `candidate_id`s get different `feature_snapshot_id`
  AND `feature_snapshot_hash`.
- **Referential integrity** — a `MarketContext` whose
  `context_event_id` or `context_hash` doesn't match the candidate's
  own is rejected.
- **Fail-closed** — empty `candidate_id`, wrong `state`, and a NaN/Inf
  feature field (via `+Inf` from a real multiplication overflow —
  `0.0/0.0` traps as a hard runtime error in MQL5, the same lesson B7
  Commit 1 learned) are all rejected, with `outSnapshot` left at
  `Init()` defaults.
- **Input immutability** — `candidate`/`ctx` fields spot-checked
  unchanged before/after the call.
- **Structural checks** (verified by inspection, same class as B1's
  own `Test_NoExecutionPathIntroduced`): no `EventStore`/broker/
  history/tick call anywhere in `Candidate_ToFeatureSnapshot`'s call
  path; no future/outcome/execution field anywhere on `FeatureSnapshot`
  or in either hash's payload.

## Bugs found and fixed during self-review, before any user test run

**Missing include.** The test file originally included only
`MLQuantAI_CRT_V1_Rules.mqh` (for `CRT_DetectV1`), but
`CRT_ToTradeCandidate` lives in the separate
`MLQuantAI_CRT_V1_ToTradeCandidate.mqh`, which is not included
transitively by `Rules.mqh`. Fixed by including
`MLQuantAI_CRT_V1_ToTradeCandidate.mqh` directly, which itself
includes `Rules.mqh` transitively — no production code involved, a
test-file include-graph mistake caught by re-checking what each
included header actually provides before assuming it.

## Explicitly out of scope for this commit

Any dataset/training export (B8.2), model registry/artifact
versioning (B8.3), inference contract (B8.4), `AI_DECISION_CREATED`
event emission (B8.5), AI projection/replay/audit (B8.6), any
ONNX/model file, any real feature engineering beyond what
`MarketContext` already computes.
