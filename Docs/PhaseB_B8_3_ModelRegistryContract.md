# Phase B8.3 — Model Registry / Artifact Contract (FROZEN)

**Status: FROZEN, before any code exists.** Opens after B8.2 SEALED
(394/394). Title: **`ModelArtifact` — immutable, declared model
metadata, and the only sanctioned answer to "is this artifact valid
and compatible?"**

```
TrainingDataset (B8.2, sealed)
    dataset_id / dataset_hash / feature_schema_version / model_target
            |
            v
      ModelArtifact  (this commit - registration)
            |
            v
      ModelArtifactProjection  (this commit - registry/replay)
            |
            v
   ModelArtifact_CheckCompatibility / ModelRegistry_FindCompatible
       COMPATIBLE -> B8.4 (inference - not this commit)
       else       -> FAIL-CLOSED, no fallback
```

B8.3 answers exactly one question: **does a declared model artifact
exist, and is it compatible with a requested inference contract?** It
does not answer model score, threshold, BUY/SELL, lot size, SL/TP, or
execute/don't-execute — those belong to B8.4/B8.5/B9/C, per the locked
architecture:

```
B7    -> RiskPlan
B8.3  -> Artifact compatibility (this commit)
B8.4  -> Inference
B8.5  -> AI Decision
B9    -> Execution Eligibility
C     -> Broker Execution
```

## Collision check (before writing anything)

Full repo search (`Include/`, `Tests/`, `Docs/`):

- No `Model*` struct/enum/function exists anywhere. Only scattered
  `model_target`/`modelTarget` string parameters (B8.2's dataset
  labeling concept — unrelated, untouched).
- No ONNX/inference/scoring code exists — only prose in
  `Docs/PhaseB8_B9_Roadmap_Notes.md`.
- No `artifact_hash`/`promotion_state`/`runtime_framework`/
  `runtime_version`/`input_schema`/`output_schema` anywhere — clean,
  entirely unclaimed vocabulary.
- No dormant `EVENT_TYPE_MODEL_*`/`EVENT_TYPE_ARTIFACT_*` slot in
  `ENUM_EVENT_TYPE` (checked directly) — a new event type must be
  appended at the end, same append-only rule as every prior addition.
- `AIResult` struct (`Core/MLQuantAI_AIResult.mqh`) and
  `MLQUANTAI_AI_MODEL_VERSION = "NONE"` (`Core/MLQuantAI_VersionRegistry.mqh`)
  are Phase A dormant scaffolding for **inference output** (B8.4/B8.5's
  concern), not artifact registration (B8.3's concern). Different
  concept, no collision, left untouched — `MLQUANTAI_AI_MODEL_VERSION`
  is not reused, same precedent `MLQUANTAI_FEATURE_SCHEMA_V1` already
  set.

### Supersession

`Docs/PhaseB8_B9_Roadmap_Notes.md` (informal, pre-dates this contract)
proposed `model_id`/`model_version`/`model_artifact_hash`/
`feature_schema_version`/etc. as fields living directly on `AIDecision`
(B8.5). This contract supersedes that:

> The B8.3 `ModelArtifact` Registry supersedes prior informal roadmap
> proposals that placed artifact identity, compatibility, and
> training-lineage declarations directly on `AIDecision`. B8.5
> `AIDecision` will reference a registered model artifact by lineage;
> it will not independently own or redefine artifact metadata.

## `ModelArtifact` struct

```cpp
struct ModelArtifact
{
   string model_registry_schema_version; // MLQUANTAI_MODEL_REGISTRY_SCHEMA_B8_3_V1

   string model_registry_id;   // identity - Ids_ModelRegistryId(model_id, model_version)
   string model_id;
   string model_version;

   string model_artifact_hash; // EXTERNAL evidence hash of the real .onnx/.bin file -
                                // supplied by the training/export pipeline; B8.3 never
                                // loads or hashes file bytes itself
   string model_registry_hash; // INTERNAL full-record content hash - computed last

   string feature_schema_version;
   string training_dataset_id;
   string training_dataset_hash;
   string model_target;

   string input_schema_version;
   string output_schema_version;

   string runtime_framework;
   string runtime_version;

   ENUM_MODEL_PROMOTION_STATE promotion_state;
};
```

### Two hashes, deliberately distinct roles

- **`model_artifact_hash`** — external, caller-supplied evidence (the
  real trained model file's own hash, e.g. SHA-256 of the `.onnx`
  bytes, computed by whatever pipeline exported it). B8.3 does not
  load or recompute file bytes — this field is trusted input, the same
  role `RealizedOutcome.outcome_hash` already plays for external
  outcome evidence. When B8.4 eventually loads the real file, it can
  verify the loaded bytes' own hash against this field to confirm
  it's loading the artifact the registry actually approved.
- **`model_registry_hash`** — internal, computed last over the
  finished struct, the same "hash the finished object" convention
  every prior B-phase struct follows. Used for the registry's own
  collision/replay/integrity detection, independent of whether the
  underlying binary file is even reachable.

### `model_registry_hash` payload (exact fields, in order)

```
model_id | model_version | model_artifact_hash | feature_schema_version |
training_dataset_id | training_dataset_hash | model_target |
input_schema_version | output_schema_version | runtime_framework |
runtime_version | promotion_state (as string) | model_registry_schema_version
```

Excludes only `model_registry_id` (identity, not content). **Deliberate
departure from the RiskPlan/TrainingDatasetRow precedent**: those
structs exclude their own schema-version field from the content hash
(schema version treated as pure metadata). `model_registry_hash`
explicitly includes `model_registry_schema_version` instead, per this
contract's own confirmed decision — a future schema-version bump
changes the hash even if every other field stays identical, which is
correct for a registry that needs to tell "same declared content under
an old record shape" apart from "same declared content under a new
one." Never event ID, sequence number, session ID, timestamp, or any
filepath/local URI.

### Identity

```cpp
string Ids_ModelRegistryId(string modelId, string modelVersion)
{
   string key = modelId + "|" + modelVersion;
   return Ids_Deterministic("MREG", key);
}
```

Same identity philosophy as every prior B-phase struct: depends only
on **what this is an artifact of** (`model_id` + `model_version`),
never on its own computed content. This is what makes "same identity,
different hash" a genuine collision signal on replay — including the
case where `model_artifact_hash` alone differs under an unchanged
`model_id`/`model_version` (a different binary was registered under a
declared identity that's supposed to be immutable), which is *also* a
collision, since `model_artifact_hash` is itself part of
`model_registry_hash`'s payload.

### `ENUM_MODEL_PROMOTION_STATE`

```cpp
enum ENUM_MODEL_PROMOTION_STATE
{
   MODEL_PROMOTION_DRAFT,     // registered, not yet validated
   MODEL_PROMOTION_STAGING,   // under validation/backtest - not live-eligible
   MODEL_PROMOTION_PROMOTED,  // approved - the ONLY state that passes compatibility
   MODEL_PROMOTION_RETIRED    // no longer eligible - kept for audit/history
};
```

B8.3 stores and round-trips `promotion_state` faithfully, and gates
compatibility on it (`MODEL_PROMOTION_PROMOTED` only — see below), but
does **not** implement any promotion *workflow* (who promotes a model,
when, under what backtest evidence) — that machinery is out of scope
here, same as B7's `RiskPlan` stores `allowed` without owning the risk
policy that decided it.

## `ModelArtifact_Build` — validation ladder (fail-closed)

```cpp
bool ModelArtifact_Build(string modelId, string modelVersion, string modelArtifactHash,
                           string featureSchemaVersion, string trainingDatasetId, string trainingDatasetHash,
                           string modelTarget, string inputSchemaVersion, string outputSchemaVersion,
                           string runtimeFramework, string runtimeVersion,
                           ENUM_MODEL_PROMOTION_STATE promotionState, ModelArtifact &outArtifact)
```

Rejected (`false`, `outArtifact` left at `Init()` defaults) if any of
`modelId`/`modelVersion`/`modelArtifactHash`/`featureSchemaVersion`/
`trainingDatasetId`/`trainingDatasetHash`/`modelTarget`/
`inputSchemaVersion`/`outputSchemaVersion`/`runtimeFramework`/
`runtimeVersion` is empty — every declared field is mandatory, no
optional/partial registration. `promotion_state` has no empty case (a
typed enum), so no validation needed there.

On success: `model_registry_id` computed first (from `model_id`+
`model_version` only), all fields copied verbatim, `model_registry_hash`
computed last over the finished struct.

### Known, deliberate limitation: no referential integrity against `training_dataset_id`/`training_dataset_hash`

Every prior B8.x replay-time projection (`FeatureSnapshotProjection`,
`RealizedOutcomeProjection`) referentially verifies its `candidate_id`/
`candidate_hash` against `CandidateProjection`, because
`CANDIDATE_CREATED` is a real persisted event. `training_dataset_id`/
`training_dataset_hash` have no equivalent — B8.2's
`TrainingDatasetManifest` is an **export output** (a file), never
itself persisted as an event in the store (B8.2 emits no
`TRAINING_DATASET_CREATED`-style event). `ModelArtifactProjection`
therefore cannot verify these two fields against anything in the event
store — they are trusted, caller-declared lineage, the same way
`RealizedOutcome.outcome_reference` is trusted external evidence with
no in-store cross-check. This is a known scope boundary, not an
oversight — closing it would mean B8.2 persisting dataset identity as
an event, which is out of scope for B8.3 and not requested.

## Event emission + projection

`EVENT_TYPE_MODEL_ARTIFACT_REGISTERED` (new, appended at the very end
of `ENUM_EVENT_TYPE`) via `ModelArtifact_EmitModelArtifactRegistered(artifact)`,
mirroring `RealizedOutcome_EmitTradeOutcomeLabeled` exactly:

- Guard: `artifact.model_registry_id == ""` -> `false`, no write.
- Live-session duplicate guard via `ModelArtifactProjection_TryGet`.
- Durable write via `EventStore_LogSystem`, then live-sync into
  `ModelArtifactProjection` via `..._ApplyLiveRecord`.

`ModelArtifactProjection` (new file, `Infrastructure/EventStore/`)
mirrors `RealizedOutcomeProjection` in structure, minus the
`CandidateProjection` referential-integrity step (see limitation
above):

- Required-field validation (all fields mandatory, matching the
  builder's own ladder).
- Duplicate-vs-collision on `model_registry_id` + `model_registry_hash`.
- `EventStoreValidator`-gated atomic rebuild — registry left untouched
  on any failure. No second-projection prerequisite (unlike
  `FeatureSnapshotProjection`/`RealizedOutcomeProjection`, which
  require `CandidateProjection` to rebuild first) — `ModelArtifactProjection`
  is fully self-contained.

## Compatibility functions (real, fail-closed, no ONNX/inference)

```cpp
bool ModelArtifact_CheckCompatibility(
    const ModelArtifact &artifact,
    string requestedFeatureSchemaVersion, string requestedModelTarget,
    string requestedInputSchemaVersion, string requestedOutputSchemaVersion,
    string requestedRuntimeFramework, string requestedRuntimeVersion,
    string &outReason);
```

Ladder (first failing check wins, stable per-field `outReason`):

1. Any `requested*` parameter empty -> reject ("empty requested ...").
2. `artifact.model_registry_id == ""` -> reject (not a valid
   registered artifact - e.g. an `Init()`-default was passed in).
3. `artifact.promotion_state != MODEL_PROMOTION_PROMOTED` -> reject.
4. `artifact.feature_schema_version != requestedFeatureSchemaVersion` -> reject.
5. `artifact.model_target != requestedModelTarget` -> reject.
6. `artifact.input_schema_version != requestedInputSchemaVersion` -> reject.
7. `artifact.output_schema_version != requestedOutputSchemaVersion` -> reject.
8. `artifact.runtime_framework != requestedRuntimeFramework` -> reject.
9. `artifact.runtime_version != requestedRuntimeVersion` -> reject.
10. Otherwise -> accept, `outReason = ""`.

Every comparison is exact string equality — no coercion, no prefix/
substring matching, no case-insensitivity. `training_dataset_id`/
`training_dataset_hash` are lineage/audit fields on the artifact, not
part of the compatibility request (a caller requests a feature/target/
schema/runtime match, never a specific training run).

```cpp
bool ModelRegistry_FindCompatible(
    string modelId, string modelVersion,
    string requestedFeatureSchemaVersion, string requestedModelTarget,
    string requestedInputSchemaVersion, string requestedOutputSchemaVersion,
    string requestedRuntimeFramework, string requestedRuntimeVersion,
    ModelArtifact &outArtifact, string &outReason);
```

A thin registry-lookup wrapper: computes `Ids_ModelRegistryId(modelId, modelVersion)`,
looks it up via `ModelArtifactProjection_TryGet` (not found -> reject,
`outReason = "model artifact not found in registry"`), then delegates
to `ModelArtifact_CheckCompatibility`. No `ModelRegistry` struct is
introduced — this operates directly on `ModelArtifactProjection`'s own
global registry state, the same free-function-over-global-registry
shape every prior projection (`FeatureSnapshotProjection`,
`RiskPlanProjection`, `RealizedOutcomeProjection`) already uses,
rather than introducing a new object-passing convention this codebase
doesn't otherwise have.

**Both functions look up or check exactly one named `model_id`+
`model_version` — neither ever searches the registry for "any
compatible model," never selects an alternative, never falls back to
a different version, and never picks "latest."** A caller who wants a
specific artifact names it; if that exact artifact isn't compatible,
the answer is `false`, full stop.

## Scope guard — B8.3 must not contain

- Any ONNX load, session, or runtime call.
- Any file I/O to read/hash a real model binary (`model_artifact_hash`
  is always caller-supplied).
- Any inference, scoring, or threshold logic.
- Any execution/broker integration.
- Any auto-promotion (nothing transitions `promotion_state` on its
  own — only the caller-supplied value at registration is stored).
- Any silent artifact fallback, substitution, or "closest match"
  resolution.

## QA gate (binding on the test suite)

- **Identity/determinism**: repeated `ModelArtifact_Build` calls, same
  inputs, identical `model_registry_id`/`model_registry_hash` every
  time; `model_registry_id` depends only on `model_id`+`model_version`.
- **Build-time validation**: every one of the 11 mandatory string
  fields empty, one at a time, is rejected; `outArtifact` stays at
  `Init()` defaults on rejection.
- **Hash inclusion/exclusion sweep**: every field in the payload list
  moves `model_registry_hash` when changed alone; `model_registry_id`
  alone does not.
- **Two-hash independence**: `model_artifact_hash` changing alone
  moves `model_registry_hash` (since it's part of the payload) but
  never moves `model_registry_id`.
- **Emission**: exactly-once emission; live-session duplicate no-op;
  an unfilled (`Init()`-default) artifact emits nothing.
- **Replay duplicate/collision**: same id + same hash on replay is a
  no-op; same id + different hash (including a same-id, only-
  `model_artifact_hash`-differs case) is a collision, rebuild fails
  entirely; malformed line blocks the whole rebuild; restart/
  multi-session replay is byte-identical.
- **Compatibility - accept path**: a `PROMOTED` artifact whose 6
  fields exactly match the 6 requested values is accepted.
- **Compatibility - reject path**, one test per dimension: empty
  requested parameter; non-`PROMOTED` `promotion_state` (test all of
  `DRAFT`/`STAGING`/`RETIRED`); each of the 6 fields individually
  mismatched (feature_schema_version, model_target,
  input_schema_version, output_schema_version, runtime_framework,
  runtime_version) rejected with a distinct, stable reason string.
- **No coercion proof**: a case-different or whitespace-padded
  requested value that would "obviously" mean the same thing to a
  human is still rejected — exact match only.
- **`ModelRegistry_FindCompatible`**: an unregistered `model_id`/
  `model_version` pair is rejected with "not found in registry", not
  confused with an incompatibility rejection; a registered-but-
  incompatible pair still goes through `ModelArtifact_CheckCompatibility`'s
  own ladder and reasons.
- **No fallback proof (structural)**: neither function contains a loop,
  search, or "pick best" heuristic over multiple candidates - verified
  by inspection.

## Explicitly out of scope for this commit

Any ONNX/inference/scoring code (B8.4); `AI_DECISION_CREATED` or any
`AIDecision` field (B8.5); any promotion *workflow* (who/when/how a
model transitions `promotion_state`); persisting `TrainingDatasetManifest`
as an event (would close the referential-integrity gap noted above,
but is not requested and not needed for B8.3's own scope); any change
to an already-sealed B5/B6/B7/B8.1/B8.2 production file.
