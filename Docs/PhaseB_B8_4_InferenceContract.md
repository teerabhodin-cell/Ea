# Phase B8.4 — Commit 1: Inference Contract, Tier A (Runtime-Independent) (FROZEN)

**Status: FROZEN, before any code exists.** Opens after B8.3 PASSED
(106/106). Title: **`InferenceRequest`/`InferenceResult` — the pinned,
fail-closed boundary between a compatible registered artifact and
whatever eventually runs it.**

```
B8.3: "Is this artifact registered and compatible with this request?"
B8.4: "Given a verified artifact, what raw/typed output does inference produce?"
B8.5: "How is this output turned into an AIDecision?"
B8.6: "How is the decision persisted, replayed, and audited?"
B9:   "Do Candidate + RiskPlan + AIDecision pass execution policy?"
```

This commit is **Tier A only**: every struct, validation, and
canonical-conversion rule needed for the contract, tested entirely
against caller-supplied fixture data. No ONNX session, no model file
I/O, no real runtime call. Tier B (a real ONNX adapter, exercised
against real model-file fixtures) is explicitly a later commit — see
"Explicitly out of scope" below.

## Collision check (before writing anything)

- No `Inference*`/`ONNX*` struct, enum, or function exists anywhere
  (`Include/`, `Tests/`, `Docs/` — confirmed by direct search).
- **`AIResult`** (`Core/MLQuantAI_AIResult.mqh`) is confirmed, by
  inspection, to already be decision-level, not raw-inference-level:
  its `decision` field is typed `ENUM_AI_DECISION` (`ALLOW`/`REJECT`/
  `REDUCE_RISK`) and it carries `allow: bool` directly — a raw
  inference result has no business knowing about allow/reject at all,
  that's B8.5's exclusive authority. `AIResult` is therefore B8.5's
  future output type, not B8.4's — left completely untouched here. A
  new, separate `InferenceResult` (this commit) is the right shape for
  ephemeral, pre-decision inference output.
- **Canonical feature ordering**: verified field-by-field identical to
  B8.1's own sealed `FeatureSnapshot_VectorHashPayload` order
  (`Market/MLQuantAI_FeatureSnapshot.mqh`) — `atr_m15, adx_m15,
  ema_slope_m15, pdh, pdl, asian_range_high, asian_range_low,
  spread_points_at_anchor, news_count, max_news_impact,
  nearest_news_minutes, is_kill_zone`. B8.4 does not invent a second,
  possibly-divergent ordering — it reuses this exact, already-sealed
  order as the canonical tensor layout for `FEATURES_B8_1_V1`.
- No dormant reason-code enum/constant set collides with the ~19 codes
  this contract freezes below.

## `InferenceRequest` struct

```cpp
struct InferenceRequest
{
   string inference_request_schema_version; // MLQUANTAI_INFERENCE_REQUEST_SCHEMA_B8_4_V1

   string model_id;
   string model_version;

   string feature_snapshot_id;
   string feature_snapshot_hash;
   string feature_vector_hash;
   string feature_schema_version;

   string model_target;
   string input_schema_version;
   string output_schema_version;

   string runtime_framework;
   string runtime_version;
};
```

Every field mandatory (`InferenceRequest_Build`, mirrors every prior
builder's all-fields-required ladder). **No "latest," no unpinned
identity, no fallback**: `model_id`+`model_version` name one exact
registered artifact, `feature_snapshot_id`+`feature_snapshot_hash`+
`feature_vector_hash` name one exact feature vector. There is no
identity field of its own — an `InferenceRequest` is a caller intent,
not a persisted artifact; nothing about it is journaled as an event in
this commit.

## `InferenceResult` struct

```cpp
struct InferenceResult
{
   string inference_contract_version; // MLQUANTAI_INFERENCE_CONTRACT_B8_4_V1

   string model_registry_id;
   string model_registry_hash;
   string model_artifact_hash;

   string feature_snapshot_id;
   string feature_snapshot_hash;
   string feature_vector_hash;

   string output_schema_version;
   float  output_values[];
   string output_hash;

   string runtime_framework;
   string runtime_version;
};
```

`output_hash` = canonical hash of `output_schema_version` + every
`output_values` entry, joined, via `CanonicalDouble((double)v)` on
each — **never** event metadata, sequence number, session ID,
timestamp, or file path/URI. This is an in-memory result struct, not
(yet) a persisted event — B8.4 Commit 1 emits nothing (see scope
guard).

## Canonical input: feature vector conversion

```cpp
#define MLQUANTAI_INFERENCE_INPUT_LENGTH_B8_1_V1 12

bool CanonicalFeatureVector_FromSnapshot(const FeatureSnapshot &snapshot, string requestedFeatureSchemaVersion,
                                           float &outVector[], ENUM_INFERENCE_FAIL_REASON &outReasonCode, string &outReasonDetail);
```

Rejected (`false`, `outVector` resized to 0) if:
- `snapshot.feature_schema_version != requestedFeatureSchemaVersion`
  -> `INPUT_SCHEMA_MISMATCH` (today, the only recognized value is
  `FEATURES_B8_1_V1` — any other requested schema is rejected, since
  no other layout is frozen yet).
- Any of the 12 source fields is non-finite (`!MathIsValidNumber`,
  same guard `FeatureSnapshotProjection_ValidateNumericalIntegrity`
  already uses) -> `INPUT_NONFINITE`.

On success: `outVector` is exactly length
`MLQUANTAI_INFERENCE_INPUT_LENGTH_B8_1_V1` (12), in the frozen order
above, each source value narrowed from `double`/`int`/`bool` to
`float` (MQL5's native 32-bit type) via: doubles narrow directly;
`news_count`/`max_news_impact`/`nearest_news_minutes` narrow via
`(float)(double)intValue`; `is_kill_zone` narrows to `1.0f`/`0.0f`.
No implicit missing-value fill, no reordering, no normalization — the
schema defines none, so none is applied.

## Output validation

Exactly one output schema is frozen in this commit, as a concrete,
testable proof of the contract shape — additional schemas are
additive in later commits, never a redefinition of this one:

```cpp
#define MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1 "OUTPUT_P_SUCCESS_V1"
// length 1, range [0.0, 1.0] inclusive
```

```cpp
bool InferenceOutput_Validate(const float &outputValues[], string outputSchemaVersion,
                                ENUM_INFERENCE_FAIL_REASON &outReasonCode, string &outReasonDetail);
```

Ladder: unrecognized `outputSchemaVersion` -> `OUTPUT_SCHEMA_MISMATCH`;
wrong `ArraySize(outputValues)` for the recognized schema ->
`OUTPUT_SHAPE_MISMATCH`; any non-finite value -> `OUTPUT_NONFINITE`;
(only for a schema that defines one) out-of-range value ->
`OUTPUT_RANGE_INVALID`. **No threshold/decision interpretation** — a
valid `p_success` of `0.03` and one of `0.97` are equally "valid,"
this function only proves the number is a well-formed member of its
declared schema, never that it means ALLOW or REJECT.

## Two-phase orchestration (no "run" that pretends to call a runtime)

Tier A never calls a real inference runtime, so there is no single
"run inference" function that would misrepresent what actually
happens. Two pure, testable halves instead:

```cpp
bool ModelInference_ResolveAndPrepare(
    const InferenceRequest &request, const FeatureSnapshot &snapshot,
    ModelArtifact &outArtifact, float &outCanonicalVector[],
    ENUM_INFERENCE_FAIL_REASON &outReasonCode, string &outReasonDetail);
```

1. All `InferenceRequest` fields non-empty (else a fail-closed reject
   - reused from `InferenceRequest_Build`'s own ladder, called first).
2. `ModelRegistry_FindCompatible` (B8.3, sealed) with `request.model_id`/
   `model_version` and the 6 requested schema/target/runtime fields.
   Its own reason string is mapped to one of three stable codes:
   `"model artifact not found in registry"` -> `MODEL_NOT_FOUND`;
   a reason containing `"promotion_state"` -> `MODEL_NOT_PROMOTED`;
   anything else -> `MODEL_INCOMPATIBLE`.
3. Referential consistency against the supplied live `FeatureSnapshot`
   (no event-store dependency — the same "validate against the struct
   you were actually given" rule `BuildTrainingDatasetRow` already
   uses for its own candidate/snapshot/plan cross-checks): `snapshot.feature_snapshot_id
   == request.feature_snapshot_id`, `.feature_snapshot_hash ==
   request.feature_snapshot_hash`, `.feature_vector_hash ==
   request.feature_vector_hash` — any mismatch -> `INPUT_SCHEMA_MISMATCH`
   (the snapshot presented doesn't match the one the request pins).
4. `CanonicalFeatureVector_FromSnapshot` (above).
5. On success: `outArtifact` = the compatible `ModelArtifact`,
   `outCanonicalVector` = the 12-element `float[]`.

```cpp
bool ModelInference_ValidateAndBuildResult(
    const InferenceRequest &request, const ModelArtifact &artifact,
    const float &rawOutputValues[], InferenceResult &outResult,
    ENUM_INFERENCE_FAIL_REASON &outReasonCode, string &outReasonDetail);
```

1. `InferenceOutput_Validate(rawOutputValues, request.output_schema_version, ...)`.
2. On success: assembles `InferenceResult` from `artifact` (`model_registry_id`/
   `model_registry_hash`/`model_artifact_hash`), `request`
   (`feature_snapshot_id`/`feature_snapshot_hash`/`feature_vector_hash`/
   `output_schema_version`/`runtime_framework`/`runtime_version`), and
   `rawOutputValues` (copied verbatim into `output_values`), then
   computes `output_hash` last.

`rawOutputValues` is **caller-supplied** in this commit — a typed
fixture standing in for whatever a real runtime will eventually
produce. There is no code path in Tier A that loads a model file or
calls an inference API; that gap is Tier B's entire job.

## Fail-closed reason codes (frozen now, for both tiers)

```cpp
enum ENUM_INFERENCE_FAIL_REASON
{
   INFERENCE_FAIL_NONE,           // success - no failure
   MODEL_NOT_FOUND,
   MODEL_NOT_PROMOTED,
   MODEL_INCOMPATIBLE,
   ARTIFACT_LOCATION_NOT_FOUND,   // Tier B only - unused by any Tier A code path
   ARTIFACT_READ_FAILED,          // Tier B only
   ARTIFACT_HASH_MISMATCH,        // Tier B only
   RUNTIME_UNAVAILABLE,           // Tier B only
   RUNTIME_VERSION_MISMATCH,      // Tier B only
   MODEL_LOAD_FAILED,             // Tier B only
   INPUT_SCHEMA_MISMATCH,
   INPUT_SHAPE_MISMATCH,          // reserved - Tier A's one frozen input shape never varies yet
   INPUT_TYPE_MISMATCH,           // reserved - MQL5 typing makes this unreachable in Tier A
   INPUT_NONFINITE,
   INFERENCE_FAILED,              // Tier B only
   OUTPUT_SCHEMA_MISMATCH,
   OUTPUT_SHAPE_MISMATCH,
   OUTPUT_TYPE_MISMATCH,          // reserved - MQL5 typing makes this unreachable in Tier A
   OUTPUT_NONFINITE,
   OUTPUT_RANGE_INVALID
};
```

The full vocabulary is frozen now so Tier B never needs a second
enum or a silent renumbering. Codes marked "Tier B only"/"reserved"
are real, tested members of the type but have no Tier A code path
that produces them yet (no file I/O, no runtime, and MQL5's static
typing already prevents a `float[]` from ever being the wrong
element type) — their QA gate is deferred to the Tier B commit that
actually implements the code path each one guards.

## Scope guard — this commit must not contain

- Any ONNX load, session, or runtime call.
- Any file I/O to read/hash a real model binary.
- Any threshold, calibration, or `ALLOW`/`REJECT`/`ABSTAIN` semantics.
- Any event emission or persistence of any kind.
- Any lifecycle state transition.
- Any mutation of `Candidate`/`RiskPlan`/`FeatureSnapshot`/`ModelArtifact`.
- Any broker/execution request.
- Any model promotion or artifact selection/fallback (this commit
  only ever resolves the exact `model_id`+`model_version` the request
  names, via the already-sealed `ModelRegistry_FindCompatible`).

## QA gate (Tier A, binding on this commit's test suite)

- Exact registry compatibility accepted; every registry/schema/runtime
  mismatch rejected with the correct one of `MODEL_NOT_FOUND`/
  `MODEL_NOT_PROMOTED`/`MODEL_INCOMPATIBLE`.
- A `FeatureSnapshot` whose id/hash/vector_hash doesn't match the
  request is rejected (`INPUT_SCHEMA_MISMATCH`) before any vector is
  built.
- Correct canonical order yields the expected 12-element vector,
  field-by-field, matching `FeatureSnapshot_VectorHashPayload`'s own
  order exactly.
- Every one of the 12 source fields, made non-finite alone, rejects
  with `INPUT_NONFINITE` before any vector is returned.
- Input conversion to `float` is deterministic (repeated calls,
  identical vector).
- A correctly-shaped, in-range fixture output is accepted; wrong
  length, non-finite, and out-of-range are each rejected with the
  correct code.
- An unrecognized `output_schema_version` is rejected
  (`OUTPUT_SCHEMA_MISMATCH`) before any shape/range check runs.
- The same request + the same fixture output, run twice, produce a
  byte-identical `output_hash`.
- `candidate`/`snapshot`/`plan`/`artifact` inputs are never mutated by
  either orchestration function.
- Structural: no `EventStore_Log*`/`OrderSend`/`CTrade`/`AccountInfo*`/
  `SymbolInfo*`/`TimeCurrent`/file-open call anywhere in either
  orchestration function's own file; no loop/search over multiple
  registered artifacts (matches B8.3's own no-fallback proof, since
  this commit's only artifact resolution is a direct delegate to
  `ModelRegistry_FindCompatible`).

## Explicitly out of scope for this commit (Tier B, later)

A real ONNX (or other runtime) adapter: loading a model file, hashing
its real bytes against `model_artifact_hash`, an actual runtime
session, and genuinely running inference. `AI_DECISION_CREATED` or any
`AIDecision` field (B8.5). Any threshold/calibration logic. Any change
to an already-sealed B5/B6/B7/B8.1/B8.2/B8.3 production file.
