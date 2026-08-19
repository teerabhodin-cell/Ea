# Phase B8.3 — Model Registry / Artifact Contract

**Status: PASSED (2026-08-19).** Confirmed on a real compile/test run:
`MLQuantAI_Test_B8_3_ModelRegistry.mq5` 106/106 ALL PASS. No production
code needed any further change after the self-review pass already
described below (one real bug — a missing `MLQuantAI_EventStoreValidator.mqh`
include in `MLQuantAI_ModelArtifactProjection.mqh` — was caught and
fixed before this test run, not after).

Implements `Docs/PhaseB_B8_3_ModelRegistryContract.md`. Opens after
B8.2 SEALED (394/394).

## Collision check and supersession

Checked before writing anything: no `Model*` struct/enum, no ONNX/
inference code, no `artifact_hash`/`promotion_state`/
`runtime_framework`/`runtime_version`/`input_schema`/`output_schema`
anywhere, no dormant `EVENT_TYPE_MODEL_*` slot. `AIResult`/
`MLQUANTAI_AI_MODEL_VERSION` are Phase A scaffolding for a different
concept (inference *output*, B8.4/B8.5) — left untouched.

`Docs/PhaseB8_B9_Roadmap_Notes.md`'s informal proposal to place
artifact identity/lineage fields directly on `AIDecision` is
explicitly superseded: those fields now live on this independent
`ModelArtifact` registry; B8.5's `AIDecision` will reference it by
lineage instead of owning the fields itself.

## What this commit adds

- **`Core/MLQuantAI_ContractVersions.mqh`** (additive):
  `MLQUANTAI_MODEL_REGISTRY_SCHEMA_B8_3_V1`.
- **`Core/MLQuantAI_Ids.mqh`** (additive):
  `Ids_ModelRegistryId(modelId, modelVersion)` — identity independent
  of content, same philosophy as `Ids_RiskPlanId`/`Ids_FeatureSnapshotId`/
  `Ids_RealizedOutcomeId`.
- **`Core/MLQuantAI_Enums.mqh`** (additive): `EVENT_TYPE_MODEL_ARTIFACT_REGISTERED`
  appended at the end of `ENUM_EVENT_TYPE`.
- **`AI/MLQuantAI_ModelArtifact.mqh`** (new): `ModelArtifact` struct,
  `ENUM_MODEL_PROMOTION_STATE` (`DRAFT`/`STAGING`/`PROMOTED`/`RETIRED`),
  `_Init`, `_HashPayload`/`_ComputeHash`. Two distinct hashes:
  `model_artifact_hash` (external evidence — the real trained model
  file's own hash, caller-supplied, never computed by this code) and
  `model_registry_hash` (internal, computed last, full-record). A
  deliberate departure from the RiskPlan/TrainingDatasetRow precedent:
  `model_registry_hash`'s payload *includes* `model_registry_schema_version`
  rather than excluding it — a confirmed, explicit decision (see the
  contract's own reasoning), not an oversight.
- **`AI/MLQuantAI_ModelArtifactBuilder.mqh`** (new):
  `ModelArtifact_Build` (all 11 declared fields mandatory, fail-closed)
  and `ModelArtifact_CheckCompatibility` (exact-match-only, fail-closed,
  no coercion, checks exactly one artifact — never searches for or
  substitutes another).
- **`Infrastructure/EventStore/MLQuantAI_ModelArtifactEventEmission.mqh`**
  (new): `ModelArtifact_EmitModelArtifactRegistered` — mirrors
  `RealizedOutcome_EmitTradeOutcomeLabeled` exactly.
- **`Infrastructure/EventStore/MLQuantAI_ModelArtifactProjection.mqh`**
  (new): registry with required-field validation, payload-aware
  collision-vs-duplicate detection, `EventStoreValidator`-gated atomic
  rebuild. **No `CandidateProjection` prerequisite** — a `ModelArtifact`
  isn't tied to any candidate, and its `training_dataset_id`/
  `training_dataset_hash` lineage fields have no in-store event to
  verify against (B8.2's `TrainingDatasetManifest` is an export file,
  never itself a persisted event) — a documented, deliberate scope
  boundary.
- **`Infrastructure/EventStore/MLQuantAI_ModelRegistryCompatibility.mqh`**
  (new): `ModelRegistry_FindCompatible` — a thin registry-lookup
  wrapper around `ModelArtifact_CheckCompatibility`. Looks up exactly
  one named `model_id`+`model_version`; no `ModelRegistry` struct
  introduced (operates directly on `ModelArtifactProjection`'s own
  global registry state, the same shape every prior projection uses).

## Scope guard (per the frozen contract, verified by inspection)

No ONNX load/session, no file I/O to hash a real model binary, no
inference/score/threshold logic, no execution/broker integration, no
auto-promotion, no silent fallback/substitution/"closest match."

## Test coverage

`Tests/MLQuantAI_Test_B8_3_ModelRegistry.mq5`, 18 test functions. No
CRT/candidate pipeline fixtures needed at all — a `ModelArtifact` is
self-contained.

- **Identity/determinism**: 1,000 repeated builds, identical
  `model_registry_id`/`model_registry_hash`; identity formula matches
  `Ids_ModelRegistryId` directly; a different `model_version` produces
  a different identity.
- **Build-time validation**: each of the 11 mandatory fields, empty
  alone, is rejected; rejected artifact stays at `Init()` defaults.
- **Hash inclusion/exclusion sweep**: all 13 payload fields (including
  the deliberately-included `model_registry_schema_version`) move the
  hash when changed alone; `model_registry_id` does not.
- **Two-hash independence**: same `model_id`/`model_version` with a
  different `model_artifact_hash` — identical `model_registry_id`,
  different `model_registry_hash`.
- **Emission**: exactly-once; an unfilled artifact emits nothing.
- **Replay**: duplicate (same id + same hash) no-op; collision (same
  id + different hash, including a `model_artifact_hash`-only drift)
  rejected; malformed line blocks the whole rebuild; restart/
  multi-session replay is byte-identical.
- **Compatibility accept path**: an exact-match request against a
  `PROMOTED` artifact is accepted.
- **Compatibility reject path**: every empty requested parameter (6);
  every non-`PROMOTED` state (`DRAFT`/`STAGING`/`RETIRED`); each of
  the 6 checked fields individually mismatched, each with a distinct
  stable reason string.
- **No-coercion proof**: a case-different or whitespace-padded
  request is still rejected.
- **`ModelRegistry_FindCompatible`**: an unregistered pair is rejected
  with a distinct "not found in registry" reason, never confused with
  an incompatibility rejection.
- **No-fallback proof** (structural): neither compatibility function
  contains a loop/search/"pick best" heuristic over multiple records.

## Explicitly out of scope for this commit

Any ONNX/inference/scoring code (B8.4); `AI_DECISION_CREATED` or any
`AIDecision` field (B8.5); any promotion *workflow* (who/when/how a
model transitions `promotion_state`); persisting `TrainingDatasetManifest`
as an event; any change to an already-sealed B5/B6/B7/B8.1/B8.2
production file.
