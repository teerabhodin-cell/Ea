# Phase B8.4 — Commit 1: Inference Contract, Tier A (Runtime-Independent)

**Status: Implemented, awaiting real compile/test confirmation.**
`Tests/MLQuantAI_Test_B8_4_InferenceTierA.mq5` written (18 test
functions), balance/identifier-length checked, and self-reviewed
line-by-line against the real struct/function shapes it calls. One
real bug caught and fixed during self-review before any test run: the
registry-rejection test's "incompatible" case originally reused a
`STAGING` artifact to test a `model_target` mismatch — but
`ModelArtifact_CheckCompatibility` checks `promotion_state` *before*
the 6 field comparisons, so that case would always have surfaced
`MODEL_NOT_PROMOTED`, never reaching the `model_target` check it was
meant to isolate. Fixed by registering a separate, genuinely
`PROMOTED` artifact for that specific test. Not yet compiled/run by
the user — do not treat as PASSED or merge until a real MetaEditor log
confirms it.

Implements `Docs/PhaseB_B8_4_InferenceContract.md`. Opens after B8.3
PASSED (106/106). **Tier A only** — no ONNX session, no model file
I/O, no real runtime call anywhere in this commit.

## Collision check

Checked before writing anything: no `Inference*`/`ONNX*` scaffolding
anywhere. `AIResult` (`Core/MLQuantAI_AIResult.mqh`) confirmed, by
direct inspection, to already be decision-level (`decision: ENUM_AI_DECISION`,
`allow: bool`) — B8.5's future output type, not B8.4's. Left
untouched; a new `InferenceResult` is the right shape for ephemeral,
pre-decision inference output. Canonical feature ordering verified
field-by-field identical to B8.1's own sealed
`FeatureSnapshot_VectorHashPayload` order — reused rather than
reinvented.

## What this commit adds

- **`Core/MLQuantAI_ContractVersions.mqh`** (additive):
  `MLQUANTAI_INFERENCE_REQUEST_SCHEMA_B8_4_V1`,
  `MLQUANTAI_INFERENCE_CONTRACT_B8_4_V1`,
  `MLQUANTAI_INFERENCE_INPUT_LENGTH_B8_1_V1` (= 12),
  `MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1`.
- **`AI/MLQuantAI_InferenceContract.mqh`** (new):
  `ENUM_INFERENCE_FAIL_REASON` (the full ~19-code vocabulary frozen
  now for both Tier A and Tier B), `InferenceRequest` struct (pinned
  `model_id`+`model_version`+feature identity — no "latest," no
  fallback), `InferenceResult` struct (`output_hash` computed only
  from `output_schema_version` + output values, never event metadata/
  time/path).
- **`AI/MLQuantAI_InferenceRequestBuilder.mqh`** (new):
  `InferenceRequest_Build` — all 11 fields mandatory, fail-closed.
- **`AI/MLQuantAI_CanonicalFeatureVector.mqh`** (new):
  `CanonicalFeatureVector_FromSnapshot` — converts a `FeatureSnapshot`
  into the frozen 12-element `float[]` tensor layout (B8.1's own
  order), rejecting an unrecognized schema or any non-finite source
  field before returning anything.
- **`AI/MLQuantAI_InferenceOutputValidator.mqh`** (new):
  `InferenceOutput_Validate` — exactly one output schema frozen
  (`OUTPUT_P_SUCCESS_V1`: length 1, range `[0,1]`) as a concrete proof
  of the validation shape; no threshold/decision interpretation.
- **`Infrastructure/EventStore/MLQuantAI_ModelInference.mqh`** (new):
  `ModelInference_ResolveAndPrepare` (registry compatibility via the
  sealed `ModelRegistry_FindCompatible`, referential consistency
  against the supplied live `FeatureSnapshot`, canonical vector build)
  and `ModelInference_ValidateAndBuildResult` (output validation +
  `InferenceResult` assembly). Two pure, testable halves instead of a
  single "run inference" function that would misrepresent that no
  real runtime call happens in this commit.
- **`Tests/MLQuantAI_Test_B8_4_InferenceTierA.mq5`** (new, 18 test
  functions).

## Scope guard (per the frozen contract, verified by inspection)

No ONNX load/session, no file I/O to read/hash a real model binary, no
threshold/calibration/decision semantics, no event emission, no
mutation of `Candidate`/`RiskPlan`/`FeatureSnapshot`/`ModelArtifact`,
no broker/execution request, no model promotion or artifact
selection/fallback (delegates to the already-sealed
`ModelRegistry_FindCompatible`, which itself never searches for an
alternative).

## Test coverage

`Tests/MLQuantAI_Test_B8_4_InferenceTierA.mq5`, 18 test functions. No
CRT/candidate/riskplan pipeline needed — fixtures build a directly-
populated, internally-consistent `FeatureSnapshot` using B8.1's own
real hash functions (not fabricated hash strings), and a registered
`ModelArtifact` using the real B8.3 pipeline.

- **`ResolveAndPrepare`**: accept path (compatible + `PROMOTED` +
  matching snapshot); registry rejections correctly mapped
  (`MODEL_NOT_FOUND`, `MODEL_NOT_PROMOTED`, `MODEL_INCOMPATIBLE` —
  each isolated with a fixture specifically designed so only the
  intended check can fail); a `FeatureSnapshot` that doesn't match the
  request's pinned identity/hash is rejected.
- **`CanonicalFeatureVector_FromSnapshot`**: exact field order
  verified against B8.1's own sealed order, including the
  `is_kill_zone` bool→float conversion both ways; wrong requested
  schema rejected both directions (requested side and snapshot's own
  side); each of the 8 double-typed source fields, made non-finite
  alone, rejects before any vector is returned; 500 repeated
  conversions are deterministic.
- **`InferenceOutput_Validate`**: accept path; unrecognized schema
  rejected before any shape/range check; wrong length (0 and 2)
  rejected; non-finite rejected; out-of-range rejected both directions
  with inclusive `0.0`/`1.0` boundaries accepted.
- **`ModelInference_ValidateAndBuildResult`**: accept path builds a
  fully-populated `InferenceResult`; reject path leaves it at
  `Init()` defaults; `output_hash` is deterministic across repeated
  builds; `output_hash` is empirically proven to depend only on
  `output_schema_version`+values — two results built from completely
  different model/feature lineage but the identical output value
  produce an identical `output_hash`.
- **No mutation**: `request`/`snapshot`/`artifact` unchanged after
  either orchestration call.
- **No-fallback proof** (structural): neither function loops/searches
  over multiple registry records or touches ONNX/broker/file I/O.

## Explicitly out of scope for this commit (Tier B, later)

A real ONNX (or other runtime) adapter: loading a model file, hashing
its real bytes against `model_artifact_hash`, an actual runtime
session, genuinely running inference. `AI_DECISION_CREATED` or any
`AIDecision` field (B8.5). Any threshold/calibration logic. Any change
to an already-sealed B5/B6/B7/B8.1/B8.2/B8.3 production file.
