# Changelog

All notable changes to MLQuantAI. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
`MLQUANTAI_EA_VERSION` in `Include/MLQuantAI/Core/MLQuantAI_VersionRegistry.mqh`.

## [Unreleased] - Phase B8.5: FULLY SEALED (2026-08-20)

**254/254, all real MetaEditor runs**: Commit 1 (threshold-policy pure
mapping) 72/72, Commit 2 (`AI_DECISION_CREATED` event +
`AIDecisionProjection`) 123/123, Commit 3 (full-chain integration +
regression) 59/59. Commit 3's own manual regression re-run - required
by its Definition of Done, not a separate step - also confirmed clean
in the same MetaEditor session: `Test_B8_1_FeatureSnapshot.mq5` 66/66,
`Test_B8_3_ModelRegistry.mq5` 106/106, `Test_B8_5_AIDecision.mq5`
72/72, `Test_B8_5_Commit2_AIDecisionEvent.mq5` 123/123 - no regression
anywhere in the B8.1/B8.3/B8.5 chain. Full evidence in
`Docs/PhaseB_B8_5_Commit3_IntegrationRegressionStatus.md`.

B8.5 is the first layer with authority to interpret `p_success` as
`ALLOW`/`REJECT`/`ABSTAIN` (still unreachable this policy version),
still without execution authority - B9 remains the sole place
`RiskPlan` + `AIDecision` + operational policy combine into
`ELIGIBLE`/`REJECTED`. The old, informal "B8.6: persist/replay/audit"
scoping language used in a few early B8.1/B8.4 contract docs is fully
superseded by B8.5 Commit 2/Commit 3 - no separate B8.6 phase remains;
see `Docs/PhaseB_Architecture_Baseline.md`'s note. B9 opens next.

## [Unreleased] - Phase B8.5 Commit 3: Full-Chain Integration + Regression Proof, Seal (PASSED 59/59, seal pending)

Opens after Commit 2 PASSED (123/123, real MetaEditor run). Implements
`Docs/PhaseB_B8_5_AIDecisionContract.md`'s Commit 3 addendum (frozen
before code, mirrors B7 Commit 3 / B8.2 Commit 4). See
`Docs/PhaseB_B8_5_Commit3_IntegrationRegressionStatus.md`. Real
MetaEditor run: **59/59 checks passed, ALL PASS.** Adds **zero new
production behavior** - pure test-suite commit. Per this commit's own
Definition of Done, B8.5 is not yet declared SEALED until a manual
re-run of `Test_B8_1_FeatureSnapshot.mq5`/`Test_B8_3_ModelRegistry.mq5`/
`Test_B8_5_AIDecision.mq5`/`Test_B8_5_Commit2_AIDecisionEvent.mq5` in
the same MetaEditor session also confirms clean.

### Added
- `Tests/MLQuantAI_Test_B8_5_Commit3_IntegrationRegression.mq5` (new,
  6 test functions): end-to-end linkage across all four layers
  (candidate/snapshot/model artifact/decision); cross-layer failure
  propagation for BOTH independent upstream chains (candidate/snapshot
  side, and the model side independently); full-chain multi-decision
  restart/crash simulation across all four projections; multi-candidate,
  multi-model cross-linking (shared and distinct models in one store).

On a clean pass (this commit + a manual re-run of
`Test_B8_1_FeatureSnapshot.mq5`/`Test_B8_3_ModelRegistry.mq5`/
`Test_B8_5_AIDecision.mq5`/`Test_B8_5_Commit2_AIDecisionEvent.mq5`),
B8.5 will be declared SEALED.

## [Unreleased] - Phase B8.5 Commit 2: AI_DECISION_CREATED Event + AIDecisionProjection (PASSED 2026-08-20)

Opens after Commit 1 PASSED (72/72, real MetaEditor run). Implements
`Docs/PhaseB_B8_5_AIDecisionContract.md`'s Commit 2 addendum (frozen
before code, after a collision check against
`AI_DECISION_CREATED`/`AIDecisionProjection`/`AIDecisionRegistry`/
`ai_decision_id`/`ai_decision_hash`/`AIDecision_Emit`/
`EVENT_TYPE_AI_DECISION`/`AI_DECISION`/`ENUM_EVENT_TYPE`/
`EVENT_TYPE_CANDIDATE_REJECTED_BY_AI`/`AIResult` - no ownership
collisions found). See
`Docs/PhaseB_B8_5_Commit2_AIDecisionEventStatus.md`. Real MetaEditor
run 1: compiled clean, 122/123 checks passed, 1 real failure -
root-caused to a test-file bug (an exact `==` check on a float-sourced,
`CanonicalDouble`-round-tripped `p_success`, stricter than that
formatter's own documented 8-decimal precision contract), fixed. Real
MetaEditor run 2, after the fix: **123/123 checks passed, ALL PASS.**
B8.5 Commit 2 is PASSED and merged to `mlquantai`.

Persistence + projection + replay only: no execution behavior for any
`decision_outcome` (`ALLOW`/`REJECT`/`ABSTAIN` are all audit evidence
only), no candidate-lifecycle state transition, no B9 logic.

### Added
- `Core/MLQuantAI_Enums.mqh` (additive): `EVENT_TYPE_AI_DECISION_CREATED`
  appended after `EVENT_TYPE_MODEL_ARTIFACT_REGISTERED` (the true
  tail), plus `EventTypeToString`/`EventTypeFromString` cases and
  `AiDecisionOutcomeFromString` (the missing inverse of Commit 1's
  `AiDecisionOutcomeToString`).
- `AI/MLQuantAI_AIDecisionEventEmission.mqh` (new):
  `AIDecision_ToExtraJson` + `AIDecision_EmitAIDecisionCreated` - the
  only outcome-based gate is `ai_decision_id == ""` (a failed build);
  `ALLOW`/`REJECT`/`ABSTAIN` all emit identically.
- `Infrastructure/EventStore/MLQuantAI_AIDecisionProjection.mqh` (new):
  `AIDecisionProjectionRecord` + live-sync/replay/rebuild, mirroring
  `FeatureSnapshotProjection.mqh`. `AIDecisionProjection_RebuildFromFile`
  independently verifies referential integrity against BOTH
  `FeatureSnapshotProjection` and `ModelArtifactProjection` - the first
  projection in this project with two independent upstream lineage
  chains to check.
- `Tests/MLQuantAI_Test_B8_5_Commit2_AIDecisionEvent.mq5` (new, 15 test
  functions, using the real B5/B8.1/B8.3/B8.4/B8.5-Commit-1 pipeline
  for every fixture).

### Fixed (caught by the user's real MetaEditor run - NOT by self-review)
- `Tests/MLQuantAI_Test_B8_5_Commit2_AIDecisionEvent.mq5`: real run 1
  was 122/123 (1 fail: `p_success matches` in
  `Test_ReplayFieldsMatchOriginal`). Root cause: `p_success` is
  float-sourced (already known lossy, per Commit 1's own fix) AND
  persisted through `CanonicalDouble`'s deliberately lossy 8-decimal
  JSON round trip (`DoubleToString(x, 8)` -> `StringToDouble` on
  replay) - the same documented precision contract the `RiskPlan`
  Commit 2 test suite already calls out for arithmetic-derived doubles.
  An exact `==` check was stricter than that contract promises. Fixed
  with an epsilon comparison. Production code
  (`AIDecision_EmitAIDecisionCreated`/`AIDecision_ToExtraJson`/
  `AIDecisionProjection_ApplyLine`) was not touched. See
  `Docs/PhaseB_B8_5_Commit2_AIDecisionEventStatus.md` for full detail.

## [Unreleased] - Phase B8.5 Commit 1: AIDecision + Threshold-Policy Pure Mapping (PASSED 2026-08-20)

Opens after B8.4 SEALED (210/210 automated + manual restart checklist
PASSED). Implements `Docs/PhaseB_B8_5_AIDecisionContract.md` (frozen
before code). See `Docs/PhaseB_B8_5_AIDecisionStatus.md`. Real
MetaEditor run 1: compiled clean, 69/72 checks passed, 3 real
failures - root-caused to a float-to-double widening precision bug in
the TEST FILE (not in `AIDecision_Build`), fixed (see Fixed section
below). Real MetaEditor run 2, after the fix: **72/72 checks passed,
ALL PASS.** B8.5 Commit 1 is PASSED and merged to `mlquantai`.

Pure mapping only: no `AI_DECISION_CREATED`, no event store, no
ONNX/runtime call, no broker/account/tick call, no mutation of any
input.

### Added
- `Core/MLQuantAI_Enums.mqh` (additive): `ENUM_AI_DECISION_OUTCOME`
  (`NONE`/`ALLOW`/`REJECT`/`ABSTAIN`) + `AiDecisionOutcomeToString` -
  a new enum, not a reuse of Phase A's `ENUM_AI_DECISION`
  (`REDUCE_RISK` doesn't fit B8.5's scope).
- `Core/MLQuantAI_ReasonCodes.mqh` (additive): `REASON_AI_ABSTAIN`,
  appended at the true tail of `ENUM_REASON_CODE`.
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_AI_DECISION_SCHEMA_B8_5_V1`.
- `Core/MLQuantAI_Ids.mqh` (additive): `Ids_AIDecisionId(candidateId, modelRegistryId, decisionPolicyVersion)`.
- `AI/MLQuantAI_AIDecisionContract.mqh` (new): `AIDecisionPolicy` +
  `AIDecision` structs, `AIDecision_Init`/`AIDecision_HashPayload`/
  `AIDecision_ComputeHash`.
- `AI/MLQuantAI_AIDecisionBuilder.mqh` (new): `AIDecision_Build` - the
  fail-closed ladder frozen in the contract, taking both
  `InferenceResult` and `FeatureSnapshot` as inputs (the former alone
  carries no `candidate_id`/`candidate_hash`).
- `Tests/MLQuantAI_Test_B8_5_AIDecision.mq5` (new, 13 test functions).

### Fixed (caught by the user's real MetaEditor run - NOT by self-review)
- `Tests/MLQuantAI_Test_B8_5_AIDecision.mq5`: real run 1 was 69/72
  (3 fails). Root cause: `InferenceResult.output_values` is `float[]`;
  `AIDecision.p_success`/`AIDecisionPolicy.allow_threshold` are
  `double` - a `float` literal widened to `double` is not bit-identical
  to an independently-typed `double` literal that merely looks like the
  same decimal number (IEEE 754 widening). Fixed
  `Test_AcceptPath_Allow_AboveThreshold`'s exact-equality check to an
  epsilon comparison, and fixed
  `Test_AcceptPath_Allow_AtThresholdBoundary` to derive
  `allow_threshold` from the same originating float value
  (`(double)0.70f`) instead of an independent double literal, so the
  boundary test genuinely exercises `AIDecision_Build`'s inclusive
  `>=` at true equality. Production code (`AIDecision_Build` and the
  rest of `AI/MLQuantAI_AIDecisionContract.mqh`/
  `AI/MLQuantAI_AIDecisionBuilder.mqh`) was not touched - the defect
  was confined to the test file. See
  `Docs/PhaseB_B8_5_AIDecisionStatus.md` for full detail.

## [Unreleased] - Phase B8.4: FULLY SEALED (2026-08-20)

Automated proof complete across all three commits — Commit 1 (Tier A)
111/111, Commit 2 (Tier B) 61/61, Commit 3 (determinism/handle-lifetime)
38/38, total **210/210**. The manual terminal-restart checklist (see
`Docs/PhaseB_B8_4_Commit3_RuntimeDeterminism.md`) also PASSED for
real: Run A (pre-restart) and Run B (~4 minutes later, after the user
actually closed and reopened the MT5 terminal) reproduced identical
pass counts, the identical `"ONNX: CPU selected"` provider line, and
identical real-`onnxruntime`-matched output values on every comparison
point. Full evidence for both runs in
`Docs/PhaseB_B8_4_Commit3_RuntimeDeterminismStatus.md`'s "Manual
verification" section. B8.4 is sealed as **same-runtime,
same-CPU-provider** scope — cross-machine/cross-provider determinism
is still not claimed. B8.5 (AIDecision) opens next.

## [Unreleased] - Phase B8.4 Commit 3: Runtime Determinism and Handle-Lifetime Seal, Same Runtime Only (PASSED 2026-08-20)

Opens after B8.4 Commit 2 PASSED (61/61). Implements
`Docs/PhaseB_B8_4_Commit3_RuntimeDeterminism.md` (frozen before code).
See `Docs/PhaseB_B8_4_Commit3_RuntimeDeterminismStatus.md`. Confirmed
on a real MetaEditor run: `MLQuantAI_Test_B8_4_Commit3_RuntimeDeterminism.mq5`
38/38 ALL PASS. Merged to `mlquantai`.

Zero new production functions or constants - every test exercises
Commit 2's already-sealed `ModelRuntimeAdapter_LoadAndVerify` /
`ModelRuntimeAdapter_ValidateContractAndRun` / `Ids_Sha256HexBytes`
exactly as they are, against new fixtures/scenarios only. Scoped
explicitly to what this environment can prove: same machine, same
tested CPU provider - no cross-machine/cross-provider claim.

### Added
- `Tests/Fixtures/MLQuantAI_ONNX_Fixture_Valid_Relocated_V1.onnx` (new):
  byte-identical copy of the sealed `..._Valid_V1.onnx` (same SHA-256),
  proving artifact relocation without touching the artifact's identity.
- `Tests/MLQuantAI_Test_B8_4_Commit3_RuntimeDeterminism.mq5` (new, 6
  test functions): artifact relocation; input-perturbation sensitivity
  (two real, independently-`onnxruntime`-computed outputs - `0.5094773`
  vs `0.4129363` - on the same fixture, framed as model-fixture-specific,
  not a universal claim); released-handle reuse (deterministic
  fail-closed, no crash); one-call handle lifetime (no cross-cycle
  leak); no mutation; no side effects (structural, referencing Commit
  2's own proof rather than duplicating it).

### Scope note
- This commit does NOT claim bitwise cross-machine equivalence,
  cross-provider equivalence, or automated terminal-restart proof - a
  manual verification checklist for terminal-restart determinism is
  documented separately and is not part of the automated pass/fail
  count.

## [Unreleased] - Phase B8.4 Commit 2: Artifact Integrity + Runtime Adapter, Tier B (PASSED 2026-08-20)

Opens after B8.4 Commit 1 PASSED (111/111). Implements
`Docs/PhaseB_B8_4_Commit2_RuntimeAdapter.md` (frozen before code). See
`Docs/PhaseB_B8_4_Commit2_RuntimeAdapterStatus.md` for the full record,
including all three real compile/run iterations. Confirmed on the
user's third real run: `MLQuantAI_Test_B8_4_Commit2_RuntimeAdapter.mq5`
61/61 ALL PASS, including a real `OnnxRun` execution producing
`0.5094773` - matching the value independently computed via real
`onnxruntime` in Python. Merged to `mlquantai`.

The project's first commit touching a real ONNX runtime, real binary
file I/O, and MQL5's native `matrixf` tensor type. Every new/changed
file was grepped for the `vector`/`matrix`/`vectorf`/`matrixf`
bare-identifier collision that caused Commit 1's real 121-error compile
failure - confirmed clean (only legitimate type declarations and prose
in comments/strings).

### Added
- `Core/MLQuantAI_Ids.mqh` (additive): `Ids_Sha256HexBytes(const uchar &bytes[])`
  - hashes raw bytes directly via `CryptEncode`, deliberately not built
    on `Ids_Sha256Hex` (that function's `string` -> UTF-8 round-trip is
    lossy/incorrect for arbitrary binary artifact bytes).
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_ONNX_INPUT_TENSOR_NAME`, `MLQUANTAI_ONNX_OUTPUT_TENSOR_NAME`,
  `MLQUANTAI_ONNX_BATCH_SIZE`.
- `Infrastructure/EventStore/MLQuantAI_ModelRuntimeAdapter.mqh` (new):
  `ModelRuntimeAdapter_LoadAndVerify` (I1-I3: single-read, hash-verify
  against `model_artifact_hash`, open an ONNX session from the exact
  same verified buffer - never a path reload) and
  `ModelRuntimeAdapter_ValidateContractAndRun` (I5-I6: real tensor
  reflection against the frozen input/output contract, `OnnxRun`, raw
  output handed to the caller - Tier A's `InferenceOutput_Validate`
  stays the single validator, never duplicated here). Session handle
  owned entirely inside the module, always released before returning.
- `Tests/Fixtures/MLQuantAI_ONNX_Fixture_*.onnx` (7 new real binary
  ONNX models, generated in Python, independently executed against real
  `onnxruntime` before being checked in - not just structurally
  validated): `Valid`, `Tampered`, `Garbage`, `WrongInputName`,
  `WrongInputShape`, `WrongOutputShape`, `WrongInputDtype`.
- `Tests/MLQuantAI_Test_B8_4_Commit2_RuntimeAdapter.mq5` (new, 12 test
  functions) - the project's first non-runtime-independent test suite.

### Fixed (caught during fixture generation, before any MQL5 code was written)
- The first "wrong input dtype" fixture mixed a DOUBLE input against
  FLOAT weights in a `Gemm` node - an invalid ONNX graph that fails to
  load at all in real `onnxruntime`, not a dtype-mismatch-at-inspection
  case as intended. Rebuilt as a fully self-consistent all-DOUBLE model,
  which loads correctly and genuinely exercises the intended
  `INPUT_TYPE_MISMATCH` reflection path.

### Fixed (caught by the user's real MetaEditor compile - 28 errors)
- `OnnxTypeInfo.type` was compared directly against `ONNX_DATA_TYPE_FLOAT`
  (implicit-conversion warning, silently comparing the wrong enum), and
  `.shape.dimensions` doesn't exist on the real struct
  (`undeclared identifier 'shape'`, cascading into further errors).
  Root cause, confirmed against https://www.mql5.com/en/docs/onnx/onnx_structures:
  `OnnxTypeInfo.type` is the parameter *kind* (`ENUM_ONNX_TYPE` -
  tensor/map/sequence), not the element data type; the data type and
  shape both live one level down in a `.tensor` substruct
  (`OnnxTensorTypeInfo.data_type` / `.dimensions[]`). Fixed by adding an
  explicit `.type == ONNX_TYPE_TENSOR` check (a genuine correctness
  improvement, not just a translation) before reading
  `.tensor.data_type` / `.tensor.dimensions[]`. `matrixf`'s
  constructor/indexing syntax and `OnnxRun`'s positional signature were
  confirmed correct by the same compile attempt - zero errors past the
  `OnnxTypeInfo` struct-access code.
- The remaining ~14 `undeclared identifier 'Ids_Sha256HexBytes'` errors
  were not a code bug: the source-of-truth `Core/MLQuantAI_Ids.mqh` in
  this repo already had the function correctly defined. Points to the
  compiled `MQL5\Include\MLQuantAI\Core\MLQuantAI_Ids.mqh` not having
  been fully overwritten with the updated file - no code change made.

### Fixed (caught by the user's real MetaEditor run, after both compile fixes above - 54/60 checks passing, all 6 remaining failures same root cause)
- `OnnxRun` does not auto-size an empty output container -
  `matrixf outputMatrix;` (default-constructed, zero-sized) failed for
  real with `ONNX: parameter is empty`. Fixed by pre-sizing
  `outputMatrix` to the exact `[1,1]` shape the I5 tensor-contract check
  had already confirmed the model declares
  (`matrixf outputMatrix(MLQUANTAI_ONNX_BATCH_SIZE, 1);`). All 6
  failures (the accept-path test and the determinism test, the only two
  that reach a real `OnnxRun` call) traced to this one root cause; every
  negative-path test that never reaches `OnnxRun` passed cleanly.

### Design decision made during implementation (within the frozen contract)
- `ModelArtifact` carries no locator/path field (by design, per B8.3).
  The runtime adapter takes the artifact file path as a plain
  caller-supplied parameter, never a `ModelArtifact` field - consistent
  with (and arguably strengthening) I3's locator-isolation principle,
  and requires zero changes to the sealed `MLQuantAI_ModelArtifact.mqh`.

## [Unreleased] - Phase B8.4 Commit 1: Inference Contract, Tier A (PASSED 2026-08-19)

Opens after B8.3 PASSED (106/106). Implements
`Docs/PhaseB_B8_4_InferenceContract.md` (frozen before code). See
`Docs/PhaseB_B8_4_InferenceTierA.md`. The user's first real compile
failed (121 errors, see Fixed section below); after the fix, confirmed
on a real MetaEditor run: `MLQuantAI_Test_B8_4_InferenceTierA.mq5`
111/111 ALL PASS. Merged to `mlquantai`.

Tier A only - no ONNX session, no model file I/O, no real runtime
call. Collision check clean; `AIResult` confirmed decision-level
(B8.5's future output type), left untouched. Canonical feature
ordering reuses B8.1's own sealed `FeatureSnapshot_VectorHashPayload`
order rather than reinventing one.

### Added
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_INFERENCE_REQUEST_SCHEMA_B8_4_V1`,
  `MLQUANTAI_INFERENCE_CONTRACT_B8_4_V1`,
  `MLQUANTAI_INFERENCE_INPUT_LENGTH_B8_1_V1`,
  `MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1`.
- `AI/MLQuantAI_InferenceContract.mqh` (new): `ENUM_INFERENCE_FAIL_REASON`
  (full ~19-code vocabulary frozen for both Tier A and Tier B),
  `InferenceRequest` (pinned identity, no "latest," no fallback),
  `InferenceResult` (`output_hash` excludes event metadata/time/path).
- `AI/MLQuantAI_InferenceRequestBuilder.mqh` (new):
  `InferenceRequest_Build` - all fields mandatory, fail-closed.
- `AI/MLQuantAI_CanonicalFeatureVector.mqh` (new):
  `CanonicalFeatureVector_FromSnapshot` - the frozen 12-element
  `float[]` tensor layout, B8.1's own order.
- `AI/MLQuantAI_InferenceOutputValidator.mqh` (new):
  `InferenceOutput_Validate` - one frozen output schema
  (`OUTPUT_P_SUCCESS_V1`) as a concrete proof of the shape.
- `Infrastructure/EventStore/MLQuantAI_ModelInference.mqh` (new):
  `ModelInference_ResolveAndPrepare` + `ModelInference_ValidateAndBuildResult`
  - two pure, testable halves either side of a real runtime call,
  instead of a single "run inference" function that would misrepresent
  that no real runtime call happens in this commit.
- `Tests/MLQuantAI_Test_B8_4_InferenceTierA.mq5` (new, 18 test
  functions).

### Fixed (caught during self-review, before any test run)
- The registry-rejection test's "incompatible" case originally reused
  a `STAGING` artifact to test a `model_target` mismatch, but
  `ModelArtifact_CheckCompatibility` checks `promotion_state` before
  the 6 field comparisons - that case would always have surfaced
  `MODEL_NOT_PROMOTED` instead. Fixed by registering a separate,
  genuinely `PROMOTED` artifact for that specific test.

### Fixed (caught by the user's real MetaEditor compile - NOT by self-review)
- `vector` is a reserved/built-in MQL5 type (native matrix/vector
  math; the compiler's own error suggestions listed built-in
  `vector`/`matrix` overloads). `Tests/MLQuantAI_Test_B8_4_InferenceTierA.mq5`
  used the bare identifier `vector` as an ordinary local variable name
  in six test functions, causing a cascading 121-error compile
  failure. Production `.mqh` files were unaffected - they already used
  `outVector`/`canonicalVector`, never bare `vector`. Fixed by
  renaming every bare `vector` local in the test file to
  `canonicalVec` (word-boundary-safe rename; the distinctly named
  `vector2` fixture was correctly left untouched), then restoring the
  original wording in the string-literal test labels the mechanical
  rename had also altered. Re-verified: balance/identifier-length
  check clean, full re-read confirms no argument-order regressions and
  the STAGING-vs-PROMOTED isolation fix above is still intact, and a
  repo-wide grep confirms no other `vector`/`matrix`/`vectorf`/`matrixf`
  identifier collisions anywhere in `Include/MLQuantAI` or the test
  file (only harmless mentions inside comments).

## [Unreleased] - Phase B8.3: Model Registry / Artifact Contract (PASSED 2026-08-19)

Opens after B8.2 SEALED (394/394). Implements
`Docs/PhaseB_B8_3_ModelRegistryContract.md` (frozen before code). See
`Docs/PhaseB_B8_3_ModelRegistry.md`. Confirmed on a real compile/test
run: `MLQuantAI_Test_B8_3_ModelRegistry.mq5` 106/106 ALL PASS.

Registry/compatibility contract only - no ONNX loading, no inference,
no scoring. Collision check clean; explicitly supersedes
`Docs/PhaseB8_B9_Roadmap_Notes.md`'s informal proposal to place
artifact identity/lineage fields directly on `AIDecision` - those now
live on this independent `ModelArtifact` registry.

### Added
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_MODEL_REGISTRY_SCHEMA_B8_3_V1`.
- `Core/MLQuantAI_Ids.mqh` (additive): `Ids_ModelRegistryId(modelId, modelVersion)`.
- `Core/MLQuantAI_Enums.mqh` (additive): `EVENT_TYPE_MODEL_ARTIFACT_REGISTERED`.
- `AI/MLQuantAI_ModelArtifact.mqh` (new): `ModelArtifact` struct with
  two distinct hashes (`model_artifact_hash` = external binary
  evidence, `model_registry_hash` = internal full-record integrity,
  deliberately including its own schema version in the payload - a
  confirmed departure from the RiskPlan/TrainingDatasetRow precedent),
  `ENUM_MODEL_PROMOTION_STATE`.
- `AI/MLQuantAI_ModelArtifactBuilder.mqh` (new): `ModelArtifact_Build`
  (all fields mandatory, fail-closed) and
  `ModelArtifact_CheckCompatibility` (exact-match-only, fail-closed,
  no search/fallback/substitution).
- `Infrastructure/EventStore/MLQuantAI_ModelArtifactEventEmission.mqh`
  (new): mirrors `RealizedOutcome_EmitTradeOutcomeLabeled`.
- `Infrastructure/EventStore/MLQuantAI_ModelArtifactProjection.mqh`
  (new): registry with no `CandidateProjection` prerequisite (a
  `ModelArtifact` isn't tied to any candidate) - documented as a
  deliberate scope boundary.
- `Infrastructure/EventStore/MLQuantAI_ModelRegistryCompatibility.mqh`
  (new): `ModelRegistry_FindCompatible` - registry-lookup wrapper,
  looks up exactly one named `model_id`+`model_version`.
- `Tests/MLQuantAI_Test_B8_3_ModelRegistry.mq5` (new, 18 test
  functions).

### Fixed (caught during self-review, before any test run)
- `MLQuantAI_ModelArtifactProjection.mqh` was missing an explicit
  `#include` for `MLQuantAI_EventStoreValidator.mqh` -
  `EventStoreValidator_ValidateLines`/`EventStoreValidationReport`
  would have been undeclared identifiers. Every prior projection got
  this transitively via `CandidateProjection.mqh`'s own include, which
  this file deliberately does not depend on.

## [Unreleased] - Phase B8.2 Commit 4: Full-Chain Integration + Regression Proof (PASSED 2026-08-19) - B8.2 SEALED

Opens after B8.2 Commit 3 PASSED (109/109) and merged. Implements
`Docs/PhaseB_B8_2_Commit4_SealRegression.md` (frozen before code). See
`Docs/PhaseB_B8_2_Commit4_Seal.md`. Confirmed on a real compile/test
run: `MLQuantAI_Test_B8_2_Commit4_SealRegression.mq5` 104/104 ALL PASS,
plus the full manual regression checklist (Commit 1: 76/76, Commit 2:
105/105, Commit 3: 109/109) re-run clean in the same session, zero
regressions.

**B8.2 Training Dataset + Outcome Boundary is now SEALED. Total:
76 + 105 + 109 + 104 = 394/394.** No further change to any B8.2
production file is permitted going forward.

Adds zero new production behavior - purely a test-suite commit proving
the already-shipped B8.2 pieces (Commits 1-3) compose correctly end to
end, the same role B7 Commit 3 played for B7. Proves 4 critical gates
compositionally (not just per-layer, as Commits 1-3 already did):
outcome never reaches back into AI input; incomplete candidates are a
skip while corrupted artifacts fail the whole export closed; a
collision at any single layer blocks the export itself; export is
atomic (valid store -> full output, corrupted store -> zero output +
`Init()` manifest). Also clarifies `LABELED_ONLY`: checked the
codebase first (zero matches) - since this commit adds no new
production code, it is proven as a pure client-side filter over
already-shipped fields (`label_available`, `manifest.labeled_count`),
built in test code only.

### Added
- `Tests/MLQuantAI_Test_B8_2_Commit4_SealRegression.mq5` (new, 8 test
  functions): `Test_FullChain_EndToEndLinkage`,
  `Test_CrossLayerFailure_CorruptedCandidateBlocksWholeChain`,
  `Test_IncompleteAndCorrupt_AreNotTheSame`,
  `Test_Leakage_MultiCandidateCohort`,
  `Test_CollisionAnywhereBlocksExport`,
  `Test_ExportAtomicity_ValidVsCorrupted`,
  `Test_LabeledOnlyView_IsPureDerivedFilter`,
  `Test_FullChainRestartSimulation_MultiCandidate`.

## [Unreleased] - Phase B8.2 Commit 3: Outcome/Label Boundary (PASSED 2026-08-19)

Opens after B8.2 Commit 2 PASSED (105/105) and merged. Implements
`Docs/PhaseB_B8_2_Commit3_OutcomeLabelContract.md` (frozen before
code). See `Docs/PhaseB_B8_2_Commit3_OutcomeLabel.md`. Confirmed on a
real compile/test run: `MLQuantAI_Test_B8_2_Commit3_OutcomeLabel.mq5`
109/109 ALL PASS.

Freezing this contract required resolving three open design questions
first (all confirmed): RealizedOutcome is built/tested from synthetic
fixtures only (no live Execution Engine exists - B9/C are future
phases); `candidate_time` = `setup_anchor_bar_time` (the only real
time anchor in the B8.2 lineage); the manifest gets only
`candidate_count`/`incomplete_count`, not permanently-dead
`rejected_count`/`first_rejection_reason` fields.

### Added
- Part 0 (Commit 2 addendum, no behavior change): `TrainingDatasetManifest.candidate_count`/
  `.incomplete_count` (additive), populated by
  `TrainingDatasetExport_BuildDataset`'s existing skip paths.
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_REALIZED_OUTCOME_SCHEMA_B8_2_V1`.
- `Core/MLQuantAI_Ids.mqh` (additive):
  `Ids_RealizedOutcomeId(candidateId, labelSchemaVersion)`.
- `AI/MLQuantAI_RealizedOutcome.mqh` (new): `RealizedOutcome` struct -
  a single full-record hash, no two-hash split (unlike `FeatureSnapshot`).
- `AI/MLQuantAI_RealizedOutcomeBuilder.mqh` (new):
  `RealizedOutcome_Build` - fail-closed validation including a strict
  temporal boundary (`outcome_time` must be after
  `candidate.setup_anchor_bar_time`) and a fixed label schema version.
- `Infrastructure/EventStore/MLQuantAI_RealizedOutcomeEventEmission.mqh`
  (new): `RealizedOutcome_EmitTradeOutcomeLabeled` - reuses the dormant
  Phase A `EVENT_TYPE_TRADE_OUTCOME_LABELED` enum slot.
- `Infrastructure/EventStore/MLQuantAI_RealizedOutcomeProjection.mqh`
  (new): registry with referential integrity AND a replay-time
  temporal-boundary re-check against `CandidateProjection`.
- `Infrastructure/EventStore/MLQuantAI_TrainingDatasetExport.mqh`
  (extended, signature unchanged): looks up a `RealizedOutcome` per
  candidate and passes real label fields to `BuildTrainingDatasetRow`
  when found; `labeled_count`/`unlabeled_count` now tallied for real.
- `Tests/MLQuantAI_Test_B8_2_Commit3_OutcomeLabel.mq5` (new, 18 test
  functions): the 7 groups from the frozen contract, including an
  empirical leakage-protection proof (feature hashes unchanged
  before/after a `RealizedOutcome` exists for a candidate) and a
  split-stability regression test.

## [Unreleased] - Phase B8.2 Commit 2: FeatureSnapshot Persistence + Deterministic Training Dataset Export (PASSED 2026-08-19)

Opens after B8.2 Commit 1 PASSED (76/76) and merged. Implements
`Docs/PhaseB_B8_2_Commit2_ExportContract.md` (frozen before code). See
`Docs/PhaseB_B8_2_Commit2_Export.md`. Confirmed on a real compile/test
run: `MLQuantAI_Test_B8_2_Commit2_Export.mq5` 105/105 ALL PASS
(Commit 1's own suite re-confirmed 76/76 on the same run, unaffected).

Expanded from the original proposal after a collision check found the
proposed export pipeline assumed a `FeatureSnapshotProjection` that
never existed - B8.1 shipped `FeatureSnapshot` with zero event
emission, and no B8 roadmap commit had added one. User-confirmed
resolution: add the missing persistence layer first (Part 0, mirroring
B7 Commit 2's own `RiskPlan` event/projection pattern), then build the
export orchestration on top (Part 1).

### Added
- `Core/MLQuantAI_Enums.mqh` (additive): `EVENT_TYPE_FEATURE_SNAPSHOT_CREATED`
  + `EventTypeToString`/`EventTypeFromString` cases.
- `Infrastructure/EventStore/MLQuantAI_FeatureSnapshotEventEmission.mqh`
  (new): `FeatureSnapshot_EmitFeatureSnapshotCreated` - mirrors
  `RiskPlan_EmitRiskPlanCreated`, guard is `feature_snapshot_id == ""`
  (no `allowed` field on `FeatureSnapshot`).
- `Infrastructure/EventStore/MLQuantAI_FeatureSnapshotProjection.mqh`
  (new): `FeatureSnapshotProjectionRecord` registry, required-field/
  numerical-integrity validation, payload-aware collision-vs-duplicate
  detection, referential-integrity check against `CandidateProjection`,
  `EventStoreValidator`-gated atomic rebuild.
- `Core/MLQuantAI_Ids.mqh` (additive): `Ids_TrainingDatasetId(fileName, modelTarget, datasetHash)`.
- `AI/MLQuantAI_TrainingDatasetRow.mqh` (additive):
  `TrainingDatasetManifest.labeled_count` field.
- `Infrastructure/EventStore/MLQuantAI_TrainingDatasetExport.mqh`
  (new): `TrainingDatasetExport_BuildDataset` - deterministic, read-only
  export joining `CandidateProjection`/`FeatureSnapshotProjection`/
  `RiskPlanProjection`, calling the sealed `BuildTrainingDatasetRow`
  (Commit 1) once per qualifying candidate. Skips candidates missing a
  `FeatureSnapshot`/ALLOWED `RiskPlan` (normal lifecycle state); fails
  closed only on `EventStoreValidator`/projection-rebuild failure or a
  mixed-cohort condition; rows ordered by `setup_anchor_bar_time ASC,
  dataset_row_id ASC`; `source_store_fingerprint` hashes every
  validated input line in original order.
- `Tests/MLQuantAI_Test_B8_2_Commit2_Export.mq5` (new, 19 test
  functions covering both Part 0 and Part 1, including the user's own
  explicitly-requested matrix: mixed-cohort rejection, duplicate-identity
  policy, read-only proof, exclusion proof).

### Fixed (caught during self-review, before any test run)
- `is_kill_zone` would have silently read back `false` always -
  `EventSerializer_GetStr`'s needle requires a quoted value, but
  `is_kill_zone` is emitted as an unquoted JSON boolean literal. Fixed
  with a local `FeatureSnapshotProjection_GetBoolLiteral` helper.
- `TrainingDatasetExport_SortRows`'s insertion sort never actually
  shifted the parallel `anchorTimes[]` array in lockstep with `rows[]`
  despite a comment claiming it did - would have desynced row order.
  Fixed, which required dropping `const` from the `anchorTimes` parameter.

## [Unreleased] - Phase B8.2 Commit 1: Training Dataset Row/Manifest Contract (PASSED 2026-08-19)

Opens Phase B8.2 ("training dataset contract") after B8.1 PASSED
(66/66) and merged. Implements
`Docs/PhaseB_B8_2_TrainingDatasetContract.md` (frozen before code).
Scoped to schema/identity/hash/split/pure-builder only - no event
store export orchestration, no real label/outcome computation. See
`Docs/PhaseB_B8_2_Commit1_TrainingDataset.md`.

A collision check (same discipline that caught B7's `RiskPlan` and
B8.1's `FeatureSnapshot`) confirmed `CandidateDatasetRow`/
`CandidateDatasetManifest` (B6.2, sealed) are a different concept - no
collision, separately named. `MLQUANTAI_LABEL_SCHEMA_VERSION =
"TBM_V1"` (a dormant Phase A placeholder) is not reused - mints
`MLQUANTAI_LABEL_SCHEMA_B8_2_V1` instead, same precedent B8.1 set for
`MLQUANTAI_FEATURE_SCHEMA_V1`.

### Added
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_DATASET_SCHEMA_B8_2_V1`, `MLQUANTAI_LABEL_SCHEMA_B8_2_V1`,
  `MLQUANTAI_DATASET_SPLIT_POLICY_V1`.
- `Core/MLQuantAI_Ids.mqh` (additive):
  `Ids_TrainingDatasetRowId(featureSnapshotId, labelSchemaVersion, modelTarget)`.
- `AI/MLQuantAI_TrainingDatasetRow.mqh` (new, first file in the
  pre-existing empty `AI/` folder): `TrainingDatasetRow`/
  `TrainingDatasetManifest` structs, `ENUM_DATASET_SPLIT`,
  `TrainingDatasetRow_HashPayload`/`_ComputeHash` (a full-record hash -
  lineage + label/outcome + split + target), `TrainingDatasetManifest_DatasetHash`
  (same style B6.2's `CandidateDatasetExport_DatasetHash` already
  established), `TrainingDatasetSplit_Assign` (deterministic,
  hash-derived, keyed on `candidate_id` so the same setup always lands
  in the same split even if re-labeled later under a different
  schema/target).
- `AI/MLQuantAI_TrainingDatasetBuilder.mqh` (new):
  `BuildTrainingDatasetRow` - fail-closed validation, referential-
  integrity checks against the supplied `FeatureSnapshot`/`RiskPlan`
  (an unallowed `RiskPlan` rejected outright - no training row without
  one), verbatim lineage copy, identity + split + hash computed last.
- `Tests/MLQuantAI_Test_B8_2_Commit1_TrainingDataset.mq5` (new):
  determinism (10,000 iterations), `dataset_row_id` dependency checks,
  `row_hash` inclusion/exclusion sweeps, referential integrity,
  fail-closed validation (including both directions of an inconsistent
  `labelAvailable`/label-fields combination), `label_available == false`
  as a valid first-class row, split determinism + a 2,000-sample
  statistical distribution sanity check, `dataset_hash`
  stability/reordering/tamper checks, input immutability, and
  structural no-event-store/no-label-leakage checks.

### Status
Confirmed on a real compile/test run:
`MLQuantAI_Test_B8_2_Commit1_TrainingDataset.mq5` 76/76 ALL PASS. The
2,000-sample split-distribution check landed at TRAIN=70.5%/
VALIDATION=14.3%/TEST=15.2% against the frozen 70/15/15 target. No
production code needed any change.

## [Unreleased] - Phase B8.1: FeatureSnapshot Identity/Lineage/Hash (PASSED 2026-08-19)

Opens Phase B8 ("AI/ML intelligence layer") after B7 SEALED (203/203,
full B5/B6/B7 regression suite 474/474, zero regressions). Implements
`Docs/PhaseB_B8_1_FeatureSnapshotContract.md` (frozen before code, then
revised once more before code per review - see that doc's revision
note). See `Docs/PhaseB_B8_1_FeatureSnapshot.md`.

A real naming collision was found and resolved before writing any
code, the same discipline that caught the B7 `RiskPlan` collision:
`Market/MLQuantAI_FeatureSnapshot.mqh` already existed from Phase B1 -
sealed, unwired, fixed named feature fields, no identity/hash/
candidate-lineage at all. Resolved by extending the existing struct
additively.

### Added
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_FEATURE_SCHEMA_B8_1_V1` - distinct from Phase B1's dormant
  `MLQUANTAI_FEATURE_SCHEMA_V1`, which `FeatureSnapshot_Init()` still
  stamps unchanged (keeps `Test_PhaseBContracts.mq5`'s sealed
  assertion true); `Candidate_ToFeatureSnapshot` overwrites it on
  success.
- `Core/MLQuantAI_Ids.mqh` (additive): `Ids_FeatureSnapshotId(candidateId)`
  - single-argument, since B8.1 has no feature-computation methodology
  choice yet to depend on.
- `Market/MLQuantAI_FeatureSnapshot.mqh` (additive): 7 new fields
  (`feature_snapshot_id`, `candidate_id`, `candidate_hash`,
  `context_hash`, `detector_hash`, `feature_vector_hash`,
  `feature_snapshot_hash`) alongside the unchanged Phase B1 ones;
  `FeatureSnapshot_VectorHashPayload`/`_ComputeVectorHash` (pure
  ML-input content, no lineage) and `FeatureSnapshot_HashPayload`/
  `_ComputeHash` (full record - identity+lineage+content) - a
  two-hash split `RiskPlan` never needed, since a feature vector can
  genuinely be "the same" across two different candidates in a way a
  `RiskPlan` never is.
- `Market/MLQuantAI_FeatureSnapshotBuilder.mqh` (new):
  `Candidate_ToFeatureSnapshot` - the pure candidate-time copy
  function (fail-closed validation, referential-integrity check
  against the supplied `MarketContext`, verbatim copy of every feature
  and lineage field, identity + both hashes computed last).
- `Tests/MLQuantAI_Test_B8_1_FeatureSnapshot.mq5` (new): determinism
  (10,000 iterations), `feature_snapshot_id` identity, `feature_vector_hash`
  inclusion sweep, lineage-only mutation sweep (proves the two-hash
  split - lineage changes move `feature_snapshot_hash` but never
  `feature_vector_hash`), verbatim-lineage-copy checks, cross-candidate
  identity distinctness, referential-integrity rejection, fail-closed
  validation (empty `candidate_id`, wrong `state`, `+Inf` via real
  multiplication overflow), input immutability, and structural
  no-event-store/no-future-field checks.

### Fixed
- `Tests/MLQuantAI_Test_B8_1_FeatureSnapshot.mq5`: originally included
  only `MLQuantAI_CRT_V1_Rules.mqh`, which doesn't transitively provide
  `CRT_ToTradeCandidate` (that lives in the separate
  `MLQuantAI_CRT_V1_ToTradeCandidate.mqh`). Fixed by including that
  file directly. Caught during self-review, before any user test run -
  no production code involved.

### Status
Confirmed on a real compile/test run:
`MLQuantAI_Test_B8_1_FeatureSnapshot.mq5` 66/66 ALL PASS. The only
other obstacles before a clean run were file-placement/sync issues on
the test machine (stale copies of `MLQuantAI_Ids.mqh` surviving
multiple individual file replacements) - resolved by sending a full
zip of `Include/MLQuantAI/` + `Tests/` to extract-and-replace in one
step. No further production code changes were needed.

## [Unreleased] - Phase B7 Commit 3: Full-Chain Integration + Regression Proof (PASSED 2026-08-18) - B7 SEALED

Implements the B7 Commit 3 addendum in
`Docs/PhaseB_B7_RiskPlanContract.md`, per the confirmed
`Docs/PhaseB_Architecture_Baseline.md` scoping. Adds zero new
production behavior - purely a test-suite commit proving the full
`MARKET_CONTEXT_READY` -> `CANDIDATE_CREATED` -> `CandidateProjection`
-> `Candidate_ToRiskPlan` -> `RISK_PLAN_CREATED` -> `RiskPlanProjection`
-> restart/replay chain composes correctly end to end. See
`Docs/PhaseB_B7_Commit3_IntegrationRegression.md`.

### Added
- `Tests/MLQuantAI_Test_B7_Commit3_IntegrationRegression.mq5` (new):
  end-to-end hash/ID linkage across all three layers in one assertion
  sequence; cross-layer failure propagation (a corrupted
  `CANDIDATE_CREATED` line also fails `RiskPlanProjection`'s rebuild,
  via its `CandidateProjection_RebuildFromFile` prerequisite);
  full-chain restart simulation across a 3-candidate store, both
  `CandidateProjection` and `RiskPlanProjection` compared
  byte-identical across two rebuilds; multi-candidate cross-linking
  (every plan checked against every candidate, not just its own).

### Status
Confirmed on a real compile/test run:
`MLQuantAI_Test_B7_Commit3_IntegrationRegression.mq5` 40/40 ALL PASS,
plus the full manual regression checklist re-run clean in the same
MetaEditor session: `Test_CandidateProjection.mq5` 146/146,
`Test_CandidateDatasetExport.mq5` 76/76, `Test_B6_3_HashContract.mq5`
89/89, `Test_B7_Commit1_RiskPlan.mq5` 98/98,
`Test_B7_Commit2_RiskPlanEvent.mq5` 65/65 - all ALL PASS, zero
regressions.

**B7 SEALED.** B7.1 through B7.5 are all PASSED and merged. B8.1
(`FeatureSnapshot`) opens next, per
`Docs/PhaseB_Architecture_Baseline.md`.

## [Unreleased] - Phase B7 Commit 2: RISK_PLAN_CREATED Event + RiskPlanProjection (PASSED 2026-08-18)

Implements B7.4 (`RISK_PLAN_CREATED` event emission) and B7.5
(`RiskPlanProjection` replay/recovery), per
`Docs/PhaseB_B7_RiskPlanContract.md`'s B7 Commit 2 addendum. Mirrors
`CANDIDATE_CREATED`/`CandidateProjection` (B5 Commit 5 / B6.1)
structurally and behaviorally, adapted for a `SystemEvent` since a
`RiskPlan` is a derived artifact tied to a candidate (like
`MarketContext`), not a candidate lifecycle transition. See
`Docs/PhaseB_B7_Commit2_RiskPlanEvent.md`.

### Added
- `Core/MLQuantAI_Enums.mqh` (additive): `EVENT_TYPE_RISK_PLAN_CREATED`
  appended at the end of `ENUM_EVENT_TYPE` (not inserted mid-enum),
  with matching `EventTypeToString`/`EventTypeFromString` cases.
- `Infrastructure/EventStore/MLQuantAI_RiskPlanEventEmission.mqh`
  (new): `RiskPlan_ToExtraJson` (every B7 `RiskPlan` field flattened as
  top-level JSON keys via the existing `CanonicalPrice`/
  `CanonicalDouble`/`CanonicalPercent` helpers), `RiskPlan_EmitRiskPlanCreated`
  (fail-closed on an unfilled/rejected plan; coarse live-session
  duplicate guard via `RiskPlanProjection_TryGet`; live-registry sync
  via `RiskPlanProjection_ApplyLiveRecord` after a successful durable
  write - the same live-sync fix B5 Commit 5 needed for
  `StateProjector`).
- `Infrastructure/EventStore/MLQuantAI_RiskPlanProjection.mqh` (new):
  `RiskPlanProjectionRecord`, the live in-memory registry,
  `RiskPlanProjection_ApplyLine` (line-length bound, type gate, parse,
  required-field/numerical-integrity validation, payload-aware
  collision-vs-duplicate detection on `risk_plan_id`/`plan_hash`),
  `RiskPlanProjection_ApplyLineWithCandidates` (orphan-candidate and
  candidate-hash-mismatch rejection against `CandidateProjection`),
  `RiskPlanProjection_RebuildFromFile` (`EventStoreValidator`-gated,
  then `CandidateProjection_RebuildFromFile` on the same file as a
  referential-integrity prerequisite, then its own rebuild - any stage
  failing leaves the registry untouched).
- `Tests/MLQuantAI_Test_B7_Commit2_RiskPlanEvent.mq5` (new): exactly-
  once emission, live-session duplicate no-op, rejected-plan-emits-
  nothing, replay duplicate (same `risk_plan_id`+`plan_hash`) no-op,
  replay collision (same `risk_plan_id`, different `plan_hash`)
  rejection, replay orphan-candidate rejection, replay candidate-hash-
  mismatch rejection, malformed-line-blocks-whole-rebuild, restart/
  crash-simulation record fidelity across repeated rebuilds, multi-
  session rebuild, and full field-by-field replay fidelity against the
  original in-memory `RiskPlan` (including `plan_hash` itself).

### Notes
- Three bugs were found and fixed in the test file during self-review,
  before any user compile/test run - no production code changed. See
  "Bugs found and fixed during self-review" in
  `Docs/PhaseB_B7_Commit2_RiskPlanEvent.md`.
- First real run: 63/65. Two more test-fixture bugs found and fixed
  (still no production code changed): a malformed-line-rebuild test
  wrongly assumed the registry would be empty rather than "left
  completely untouched" (the actual documented contract) after a
  failed rebuild; a field-fidelity test used exact `==` on
  arithmetic-derived doubles against their canonically-rounded
  (8-decimal) round-tripped values, which is stricter than
  `CanonicalDouble`'s own precision guarantee - fixed with an epsilon
  comparison. See `Docs/PhaseB_B7_Commit2_RiskPlanEvent.md`.

### Status
Confirmed on a real compile/test run:
`MLQuantAI_Test_B7_Commit2_RiskPlanEvent.mq5` 65/65 ALL PASS.

## [Unreleased] - Phase B7 Commit 1: RiskContext / RiskPlan / Candidate_ToRiskPlan (PASSED 2026-08-18)

Opens Phase B7 ("deterministic RiskPlan sizing") after B6 closed in
full (B6.1 146/146, B6.2 75/75, B6.3 89/89, all PASSED and merged).
Implements B7.1 (RiskContext) + B7.2 (RiskPlan schema/identity) + B7.3
(`Candidate_ToRiskPlan`, pure sizing) together, per
`Docs/PhaseB_B7_RiskPlanContract.md` (frozen before any code was
written). B7.4 (event emission) and B7.5 (replay/recovery) are not
part of this commit.

A real naming collision was found and resolved before writing any
code: `Core/MLQuantAI_RiskPlan.mqh` already existed from Phase A
(`decision`/`allowed`/`lot`/`risk_money`/`risk_percent`/
`reject_reason`), unused but sealed, and `Core/MLQuantAI_RiskDecision.mqh`
(Phase B1) had already flagged "B7 reconciles how the two relate when
the Risk Manager is built." Resolved by extending the existing struct
additively rather than declaring a second, differently-shaped
`RiskPlan` - every Phase A field kept unchanged, new B7 fields added
alongside, `Candidate_ToRiskPlan` fills both groups from the same
computation. See `Docs/PhaseB_B7_Commit1_RiskPlan.md`.

### Added
- `Core/MLQuantAI_CanonicalFormat.mqh` (new): `CanonicalPrice`/
  `CanonicalDouble`/`CanonicalPercent` - fixed-literal-precision
  formatting for every B7 hash payload double, never `Digits()`/
  `_Digits`.
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_RISK_CONTEXT_SCHEMA_V1`, `MLQUANTAI_RISK_PLAN_SCHEMA_V1`,
  `MLQUANTAI_RISK_SIZING_RULES_V1`.
- `Core/MLQuantAI_Ids.mqh` (additive): `Ids_RiskPlanId(candidateId,
  sizingRulesVersion)`.
- `Core/MLQuantAI_RiskContext.mqh` (new): `RiskContext` struct
  (embeds `AccountSnapshot`/`SymbolSpec` verbatim, snapshot-only),
  `RiskContext_Init`, `RiskContext_HashPayload`/`_ComputeHash`.
- `Core/MLQuantAI_RiskPlan.mqh` (additive): 12 new fields alongside
  the unchanged Phase A ones, `RiskPlan_HashPayload`/`_ComputeHash`.
- `Core/MLQuantAI_RiskSizing.mqh` (new): `Candidate_ToRiskPlan` - the
  frozen fixed-fractional-risk sizing formula (stop distance via
  `tick_size`, risk amount from `balance * target_risk_percent`, raw
  lot via `tick_value`, floor to `volume_step`, reject below
  `volume_min`, clamp above `volume_max`).
- `Tests/MLQuantAI_Test_B7_Commit1_RiskPlan.mq5` (new): sizing formula
  exact-number correctness, `risk_plan_id`/`plan_hash`
  identity-vs-content independence, `risk_context_hash`/`plan_hash`
  inclusion/exclusion mutation sweeps, fail-closed validation
  (non-finite price via real +Inf multiplication overflow -
  0.0/0.0 traps as a hard runtime error in MQL5, unlike Python/C -
  fixed after the first real test run caught it, zero/negative
  prices, wrong-side SL/TP
  ordering, non-positive symbol/account fields), volume normalization
  edge cases (below-min rejects, above-max clamps), a 10,000-iteration
  determinism loop, and input-immutability checks.

### Fixed
- `Tests/MLQuantAI_Test_B7_Commit1_RiskPlan.mq5`: the fail-closed
  "invalid number" test tried to construct a NaN entry_hint via
  `0.0/0.0`, assuming MQL5 follows IEEE754 silently the way Python/C
  do. It doesn't - MQL5 traps `0.0/0.0` as a hard "zero divide"
  runtime error and halts the script, caught on the first real
  compile/test run (the log stopped mid-suite at that exact line).
  Fixed by constructing `+Inf` via a real multiplication overflow
  (`1.0e307 * 1.0e307`) instead, which does not trap - both are
  "not a valid number" as far as `RiskSizing_ValidateInput`'s
  `MathIsValidNumber` check is concerned, so the fix still exercises
  the same code path. No production code needed any change.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_B7_Commit1_RiskPlan.mq5
98/98 ALL PASS. Two clarifications added to the contract doc and code
comments per QA review: risk_context_hash is a rules/spec snapshot
hash (not a full sizing-input hash - equal risk_context_hash values
do not guarantee equal plan_hash, since account.balance/equity
legitimately move plan_hash without moving risk_context_hash); lot/
risk_money (Phase A fields) are compatibility shadow fields, not the
canonical source of truth - risk_amount/lot_size are.

## [Unreleased] - Phase B B6.3: Hash Contract Spec (PASSED 2026-08-15)

Scoped down from the original B6.3 proposal after a gap review with the
user: most of the proposed work items (reject malformed/orphan/
collision lines, block export on a corrupt store, deterministic
byte-identical export, full row-lineage traceability) were confirmed
already built and already passed in B6.1 (146/146) and B6.2 (75/75) -
re-implementing them would have been duplicate work. See
Docs/PhaseB_B6_3_HashContractSpec.md's "What's already covered"
section for the full mapping.

The 3 genuinely new deliverables:

1. **A consolidated Hash Contract Spec** (Docs/PhaseB_B6_3_HashContractSpec.md) -
   the exact payload/inclusion/exclusion rules for `context_hash`,
   `detector_hash`, and `candidate_hash`, previously only scattered
   across code comments in 3 different files. Corrects one loose claim
   made during drafting: `digits` in `detector_hash`/`candidate_hash`
   is not an independently "excluded" field - it's a formatting
   multiplier on the included price fields, so changing it alone DOES
   move the hash (different DoubleToString precision = different
   string). Fixed before it became a test that would have asserted
   something false.
2. **Exhaustive inclusion/exclusion mutation-sweep tests** for
   `context_hash` and `detector_hash`, matching the rigor
   `candidate_hash` already had in Test_CandidateProjection.mq5.
3. **A structured rejection-reason classification**, additive on top
   of `CandidateProjection`'s existing free-text reason strings (which
   are completely unchanged): `ENUM_CANDPROJ_REASON_CATEGORY` +
   `CandidateProjection_ClassifyReason()` + a new
   `CandidateProjectionReport.first_error_code` field.

### Added
- `Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh`
  (additive): `ENUM_CANDPROJ_REASON_CATEGORY` (18 categories -
  NONE/APPLIED/SKIPPED_NOT_RELEVANT/SKIPPED_DUPLICATE/MALFORMED_LINE/
  NOT_GENESIS_SHAPE/EMPTY_CANDIDATE_ID/SCHEMA_VERSION/
  MISSING_REQUIRED_FIELD/INVALID_SIDE/TIME_INTEGRITY/
  NUMERICAL_INTEGRITY/REASON_CONSISTENCY/COLLISION/ORPHAN_CONTEXT/
  CONTEXT_HASH_MISMATCH/STORE_VALIDATION_FAILED/UNKNOWN),
  `CandidateProjection_ClassifyReason(reasonText)` (a pure classifier
  over the reason strings this file's own rejection sites produce -
  never used to change control flow, only to give callers a stable
  machine-readable category instead of parsing prose),
  `CandidateProjectionReport.first_error_code` (classified from the
  RAW per-line reason, before the `"line %d: "` prefix
  `RebuildFromFile` adds - so the prefix-anchored `"missing "` check
  still matches correctly). `first_error`/`outReason` string behavior
  is completely unchanged.
- `Docs/PhaseB_B6_3_HashContractSpec.md` (new).
- `Tests/MLQuantAI_Test_B6_3_HashContract.mq5` (new): `context_hash`
  inclusion sweep (21 fields) + exclusion whitelist (11 fields);
  `detector_hash` inclusion sweep (11 params) + a dedicated test
  proving `digits` is NOT independently excluded (moves the hash via
  reformatting, not directly); `CandidateProjection_ClassifyReason`
  tested both directly against the real pure validator functions
  (schema/required-fields/side/time/numerical/reason-consistency) and
  end-to-end through `ApplyLine`/`ApplyLineWithContext`/
  `RebuildFromFile` for every category (including collision, orphan,
  context-hash-mismatch, and store-level validation failure); a
  dedicated test confirming `report.first_error_code` and
  `report.first_error` stay consistent on the same real rejection.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_B6_3_HashContract.mq5
89/89 ALL PASS.

## [Unreleased] - Phase B B6.2: Canonical Dataset Export (PASSED 2026-08-15)

Closes the 2 remaining gates named at B6.1's approval: dataset export
determinism, and an end-to-end audit path from MARKET_CONTEXT_READY
through to a dataset row. Strictly additive, strictly read-only: reuses
B6.1's sealed `CandidateProjection_RebuildFromFile` for the candidate
set, reads the same store's lines a second time only to join each
candidate against its own MARKET_CONTEXT_READY event - no B5
Strategies/ file touched, no CRT detector call, no event appended, no
existing line rewritten. See Docs/PhaseB_B6_2_DatasetExport.md.

4 of the 9 dataset columns B6.1 flagged as missing (`instrument_id`/
`trigger_timeframe`/`news_decision_hash`/`news_snapshot_identity`) are
resolved by joining against already-persisted MARKET_CONTEXT_READY
fields - not by reopening sealed B5 code. The remaining 5
(`swept_level`/`mss_confirmation_price`/`resolved_zone_kind`/
`resolved_zone_low`/`resolved_zone_high`), plus a 10th discovered during
this commit (`strategy_version`), stay documented NOT AVAILABLE - no
join can produce data nothing was ever persisted. `strategy_name` (not
on the original gap list) is derived via the existing pure
`StrategyIdToString(strategy_id)`.

`row_hash` deliberately does not re-hash every field `candidate_hash`
already covers - it rolls `candidate_hash` up as one value and adds
only the export layer's own contribution (joined context fields,
`candidate_state`). `dataset_hash` hashes every row's `row_hash` in
final sorted order. `manifest.export_time` is populated last and
deliberately excluded from `dataset_hash` - only row content
determines it.

Export stays all-or-nothing, consistent with B6.1's already-approved
RebuildFromFile atomicity: any corrupt/orphaned/out-of-sequence line
anywhere blocks the WHOLE export (`ok == false`, `rows[]` empty), never
a silently-partial dataset. Flagged explicitly: this means
`manifest.rejected_count` is always 0 on any export that returns
`true` - the B6.2 spec's own wording could be read as implying a
different, selective per-row quarantine model, which was deliberately
not built here to stay consistent with the already-approved atomicity
contract.

### Added
- `Infrastructure/EventStore/MLQuantAI_CandidateDatasetExport.mqh`
  (new): `CandidateDatasetRow`, `CandidateDatasetManifest`,
  `CandidateDatasetExport_BuildDataset` (entry point), plus context-join,
  sort, row/dataset hash, and JSONL serialization helpers.
- `Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh`
  (additive): `CandidateProjection_GetAt(index, &out)` - bounds-checked
  full-registry accessor for the export layer's iteration. B6.1's
  sealed/tested behavior otherwise untouched.
- `Tests/MLQuantAI_Test_CandidateDatasetExport.mq5` (new): row
  projection (including all NOT-AVAILABLE fields and derived has_*
  flags), no-duplicate-ids, stable ordering, deterministic export
  (byte-identical JSONL + identical hashes across two builds of the
  same store), hash-changes-with-content, orphan-blocks-whole-export,
  read-only (store byte-identical before/after export), and a full
  end-to-end lineage test tracing MARKET_CONTEXT_READY -> CANDIDATE_CREATED
  -> registry -> dataset row.

### Fixed
- `Tests/MLQuantAI_Test_CandidateDatasetExport.mq5`: `Test_StableOrdering`
  reused `dayOffset = 10` (already used by `Test_NoDuplicateCandidateIds`'s
  `"DUPA"`) for its `"ORDEREARLY"` candidate. Since `candidate_id`/
  `root_event_id` depend only on `(symbol, timeframe, eventType,
  swept_level, mss_confirmation_bar_time)` - never on the test's
  `suffix` - and the fixture always draws identical price data, this
  produced an identical `candidate_id` across two different test
  functions. `StateProjector` (the live idempotency guard
  `CRT_EmitCandidateCreated` uses) is a process-global never reset
  between test functions within one script run - deliberate, sealed B5
  Commit 5 behavior - so the second emission silently returned `false`
  (no write, no error), leaving only 2 of 3 expected candidates in the
  store. No production code (`CandidateDatasetExport.mqh`,
  `CandidateProjection.mqh`, B5 `Strategies/`) needed any change.
  Fixed by using a globally-unique `dayOffset` and wrapping every
  `BuildAndEmitCandidate` call in the file in a `Check(...)` sanity
  assertion so a future collision fails loudly instead of silently.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_CandidateDatasetExport.mq5
75/75 ALL PASS.

## [Unreleased] - Phase B B6.1: Candidate Projection / Registry (hardened, PASSED 2026-08-15)

Opens B6 ("Candidate Dataset QA & Analytics"). Strictly additive,
strictly read-only: no B5 Strategies/ file touched, no live market/
broker/account call - the registry is built purely from persisted
CANDIDATE_CREATED lines via EventStore_ReadAllLines. See
Docs/PhaseB_B6_1_CandidateProjection.md, including a flagged (not
silently resolved) gap: several B6.2 canonical-dataset columns
(swept_level/resolved_zone_*/instrument_id/trigger_timeframe/
news_decision_hash/news_snapshot_identity) aren't in any persisted
CANDIDATE_CREATED event yet - deferred to B6.2's own kickoff decision.

Hardened after a QA review of the initial 104/104 pass, which proved
B6.1's mechanics but not adversarial robustness. The most important
fix: candidate_id reuse with a DIFFERENT candidate_hash is now rejected
as a collision/conflict, never silently treated as an idempotent
duplicate - the original version would have hidden exactly that class
of corruption. See Docs/PhaseB_B6_1_CandidateProjection.md's "Hardening
pass" section for the full gate-by-gate list (schema/time/numerical/
enum/reason-mask/resource-limit integrity, referential integrity against
MARKET_CONTEXT_READY, ordering/atomicity via EventStoreValidator-gated
rebuilds, restart/crash simulation, multi-session, a candidate_hash
mutation sweep, and a 25-candidate scale test). B6 as a whole remains
IN REVIEW / NOT CLOSED - dataset export (B6.2), the integrity validator
(B6.3), and full-phase regression are still outstanding.

### Added
- `Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh` (new):
  `CandidateProjectionRecord`, `CandidateProjection_ApplyLine` (now with
  full schema/time/numerical/enum/reason-mask/resource-limit validation
  and payload-aware collision detection), `CandidateProjection_TryGet`,
  `CandidateProjection_CollectContextHashes`/`_ApplyLineWithContext`
  (referential integrity against MARKET_CONTEXT_READY),
  `CandidateProjection_RebuildFromFile` (now EventStoreValidator-gated -
  ordering/atomicity), `CandidateProjectionReport`.
- `Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh`:
  `EventSerializer_GetStringArray` - a generic `"key":["a","b"]` reader,
  promoted from a pattern previously hand-duplicated in three test files.
- `Tests/MLQuantAI_Test_CandidateProjection.mq5` (rewritten, real
  MARKET_CONTEXT_READY events now persisted per candidate): the original
  6 B6.1 gates plus collision, schema, time, numerical, enum, trigger-
  reasons, resource-limit, referential-integrity, ordering, atomicity,
  restart/crash, multi-session, 25-candidate-scale, and a full
  candidate_hash mutation sweep (decision-bearing fields move it,
  excluded fields don't).

### Fixed
- `CandidateProjection_ApplyLine`: two real bugs found during hardening
  test runs, both only reachable once real `MARKET_CONTEXT_READY` events
  shared a store with candidates for the first time. (1) Every non-
  `CANDIDATE_CREATED` line was misreported as "not a parsable lifecycle
  event line" (a false failure) instead of being skipped, because the
  type check ran after an `EventSerializer_ParseLifecycle()` call that
  requires a `candidate_id` key SystemEvents don't have. (2) The first
  fix over-corrected: a line with no `type` key at all (true garbage)
  was then waved through as "irrelevant, skip" instead of failing
  closed. Fixed by checking `type` via a category-agnostic string lookup
  *and* requiring the key to be present, before ever attempting the
  LifecycleEvent parse.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_CandidateProjection.mq5
146/146 PASS.

## [Unreleased] - Phase B B5 Commit 5: CANDIDATE_CREATED Event Emission (PASSED 2026-08-14, B5 = ALL COMMITS SEALED)

Implements the final Commit 5 boundary: `TradeCandidate ->
CANDIDATE_CREATED -> EventStore append`. Reuses Phase A's sealed
`EventStore_LogCandidateCreated()`/`StateProjector_TryGetState()`
machinery rather than inventing a new event-store primitive or
idempotency mechanism. See Docs/PhaseB_B5_Commit5.md, including a real
live-session idempotency gap this commit found and closed
(`StateProjector` is only populated by replay, never by
`EventStore_LogCandidateCreated()` itself - fixed by having
`CRT_EmitCandidateCreated()` apply the genesis event to `StateProjector`
immediately after each durable write).

### Added
- `Strategies/MLQuantAI_CRT_V1_EventEmission.mqh` (new):
  `CRT_EmitCandidateCreated`, `CRT_CandidateCreatedExtraJson`,
  `CRT_StringArrayToJson`.
- `Infrastructure/EventStore/MLQuantAI_EventStore.mqh`:
  `EventStore_LogCandidateCreated` gained an additive `extraJson=""`
  parameter (every existing Phase A caller unaffected).
- `Tests/MLQuantAI_Test_CRT_V1_CandidateCreatedEvent.mq5` (new): full
  Commit 5 required-test checklist - exactly-one-event-per-detection,
  required fields carried through, ordered trigger_reasons[] preserved,
  duplicate-candidate_id no-op, non-detection emits nothing, replay
  reconstruction via ReplayEngine_Run/StateProjector, replayed-fields-
  match-original, replay idempotency.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_CRT_V1_CandidateCreatedEvent.mq5
43/43 PASS. B5 Commits 1-5 are all SEALED; final B5 integration/replay QA
remains before the whole phase seals.

## [Unreleased] - Phase B B5 Commit 4: CRT_ToTradeCandidate (pure mapping) (PASSED 2026-08-14)

Implements the Commit 4 boundary: `bool CRT_ToTradeCandidate(ctx, crt,
outCandidate)` - copy/map only from Commit 3's `CRTDetectionResult`,
never recompute detector truth. Returns false (candidate left at
`TradeCandidate_Init()` defaults) on `crt.detected == false`; no Event
Store write, no state-machine call, no `CANDIDATE_CREATED` event either
way - that's Commit 5. See Docs/PhaseB_B5_Commit4.md.

### Added
- `Strategies/MLQuantAI_CRT_V1_ToTradeCandidate.mqh` (new):
  `CRT_ToTradeCandidate`, `CRT_CandidateHash`/`CRT_CandidateHashPayload`.
- `Core/MLQuantAI_TradeCandidate.mqh`: `detector_hash` (copied verbatim
  from `CRTDetectionResult.detector_hash`, never recomputed) and
  `candidate_hash` (new - a canonical hash over the candidate's own
  deterministic content, computed last, deliberately excluding
  account/spread/broker state/wall-clock and every B6/B7-owned mutable
  field) - both additive.
- `Tests/MLQuantAI_Test_CRT_V1_ToTradeCandidate.mq5` (new): full mapping
  correctness (both directions), the non-detection guard, the
  `detector_hash`/`candidate_hash` invariants, a 1000-repeat
  `candidate_hash` determinism loop, account-mutation independence,
  detector-input-not-mutated, and the `candidate_id`-differs-across-
  rules-versions acceptance gate.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_CRT_V1_ToTradeCandidate.mq5
79/79 PASS.

## [Unreleased] - Phase B B5 Commit 3: Pure CRT_V1 Detection Rules (PASSED 2026-08-14)

Implements the detection logic Docs/PhaseB_B5_CRTContract.md (Commit 1,
FROZEN) explicitly deferred to this commit: CRT_IsSweepLow/CRT_IsSweepHigh,
CRT_CloseBackInside, CRT_ConfirmMSS, CRT_FindFVG, CRT_FindOrderBlock,
CRT_ResolveZone (FVG_PRIORITY_THEN_OB_FALLBACK), CRT_EvaluateExpiry, and
the CRT_DetectV1() orchestrator. No TradeCandidate construction or event
emission - that's Commit 4. See Docs/PhaseB_B5_Commit3.md for the
implementation-level decisions this commit had to freeze that Commit 1's
contract deliberately left open (swept level = ctx.pdh/ctx.pdl, MSS
checked against the anchor bar only, pre-sweep structure lookback, the
new non-gating CRT_REASON_BIT_NEWS_RISK threshold).

### Added
- `Strategies/MLQuantAI_CRT_V1_Rules.mqh` (new): the pure detection rule
  functions plus `CRT_DetectV1(ctx, result)`, the orchestrator that turns
  a single `MarketContext` into zero or one `CRTDetectionResult`.
- `Tests/MLQuantAI_Test_CRT_V1_Rules.mq5` (new): all 11 QA-approved
  Commit 3 fixture gates (valid bullish/bearish, no-sweep,
  sweep-without-reclaim, reclaim-without-MSS, MSS-without-valid-zone,
  short-history, determinism, exactly-one-sweep/zone-bit) plus boundary
  equality and `CRT_EvaluateExpiry` tests - all hand-built `MqlRates`
  fixtures, no live/broker dependency.
- `Docs/PhaseB_B5_Commit3.md`: full write-up of every algorithmic
  decision this commit made, framed for review since the contract left
  them to Commit 3's discretion.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_CRT_V1_Rules.mq5
57/57 PASS. Fixed during review: CRT_TimeframeTagToPeriod originally used
StringToEnum(), unavailable in this MQL5 build - replaced with an
explicit if-chain (commit 4cc4199).

## [Unreleased] - Phase B B5 Commit 2: Context Window + CRT_V1 Domain Models (PASSED 2026-08-14)

Implements what Docs/PhaseB_B5_CRTContract.md (Commit 1, FROZEN after 3
QA review rounds) froze. No detection rule logic - no CRT_IsSweepLow/
CRT_ConfirmMSS/CRT_FindFVG/CRT_FindOrderBlock - that's Commit 3.
Confirmed on a real compile/test run: MLQuantAI_Test_CRTContextWindow.mq5
31/31, Test_DataHubDeterminism.mq5 (regression) 44/44, Test_NewsParity.mq5
(regression) 46/46 - 121/121 total.

### Added
- `Market/MLQuantAI_MarketContext.mqh`: `trigger_tf_recent[]` (additive)
  - last `MLQUANTAI_CRT_V1_LOOKBACK_BARS` closed bars on
  `trigger_timeframe`, oldest first, folded into both
  `MarketContext_HashPayload()` and `MarketContext_ToJsonFragment()`.
  `MarketContext_RatesArrayToJson`/`_RatesArrayFromJson`/`_RatesFromJson`
  - the array counterpart to the existing single-bar
  `MarketContext_RatesToJson`, self-contained (no EventSerializer
  dependency), same convention `NewsSnapshot.mqh` already uses.
- `Market/MLQuantAI_FeatureEngine.mqh`: `FeatureEngine_BuildContext()`
  captures `trigger_tf_recent[]` via one `CopyRates(..., 1,
  MLQUANTAI_CRT_V1_LOOKBACK_BARS, ctx.trigger_tf_recent)` call - a plain
  array, so `CopyRates` already fills it oldest-first with no manual
  reversal.
- `Core/MLQuantAI_ContractVersions.mqh`: `MLQUANTAI_CRT_V1_RULES_VERSION
  = "CRT_V1"`.
- `Strategies/MLQuantAI_CRT_V1_Contract.mqh` (new file, new `Strategies/`
  directory): every B5-frozen parameter as `#define`s, the 8
  `CRT_REASON_BIT_*` bit constants, `CRT_ReasonBitLabel`/
  `CRT_ReasonLabelsFromMask` (ascending-bit-order label vocabulary),
  `CRTDetectionResult` + `_Init`, `CRT_DetectorHash` (frozen payload/
  field order/numeric formatting, a pure function of its arguments).
- `Tests/MLQuantAI_Test_CRTContextWindow.mq5`: real-pipeline window
  rules (size, ordering, anchor equality, no forming-bar, determinism
  across rebuilds), pure-function hash-sensitivity and JSON round-trip
  tests, a persisted-payload replay test, and CRT_V1 domain-model tests
  (reason label ordering, detector_hash sensitivity, Init defaults).
- `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`: 2 new payload-
  completeness checks for `trigger_tf_recent[]`.

## [Unreleased] - Phase B B4 seal hardening

Two DoD gates from the original B4 pass weren't genuinely runtime-tested:
`Test_Seal_ReplayNeverCallsSources` only asserted `Check(true, "enforced
by construction")`, and additive schema evolution was never exercised at
all. See `Docs/PhaseB_B4_NewsParity.md`.

### Added
- `Market/MLQuantAI_NewsSource.mqh` / `Market/MLQuantAI_NewsCanonicalizer.mqh`:
  `forecast`/`actual`/`previous` additive fields on `RawNewsEvent`/
  `NormalizedNewsEvent` (both "" by default, not CSV columns - the frozen
  7-column format is unchanged). Folded into `News_SnapshotIdentity()`'s
  payload; deliberately excluded from `News_DecisionHash()` and from
  `NewsSnapshot`/`News_ToSnapshot()` itself.
- `Market/MLQuantAI_NewsEngine.mqh`: `g_NewsEngine_BuildCallCount` -
  increments once per `NewsEngine_Build()` call, turning "replay never
  touches a source" from an architectural claim into something a test can
  mechanically check.
- `Tests/MLQuantAI_Test_NewsReplayIsolation.mq5`: builds a `MarketContext`
  via the pure canonicalizer pipeline only (no `INewsSource` touched),
  persists `MARKET_CONTEXT_READY`, closes the store, re-opens a fresh
  handle, and asserts the replayed `news_decision_hash`/
  `news_snapshot_identity`/`context_hash`/`NewsSnapshot[]` match exactly
  what was computed before persisting - and that `g_NewsEngine_
  BuildCallCount` never moved across the whole sequence.
- `Tests/MLQuantAI_Test_NewsSchemaEvolution.mq5`: additive `forecast`/
  `actual`/`previous` metadata moves `news_snapshot_identity` but never
  `news_decision_hash`/`context_hash`; `normalized_event_key` stays
  stable regardless; the frozen V1 CSV fixture still loads/normalizes
  correctly (new fields read back empty, not misaligned/garbage) after
  the schema grew.

### Removed
- `Tests/MLQuantAI_Test_NewsParity.mq5`: `Test_Seal_ReplayNeverCallsSources`
  - superseded by `Test_NewsReplayIsolation.mq5`'s runtime-verified check.

## [Unreleased] - Phase B B4: News Parity Layer

One Raw -> Normalize -> Dedup -> Sort/Select pipeline shared by the live
MT5 Economic Calendar and a deterministic Tester-only CSV source, so
neither source can drift into its own interpretation of "the same news
event". See `Docs/PhaseB_B4_NewsParity.md`. Still no CRT/`TradeCandidate`/
execution code touched.

### Added
- `Market/MLQuantAI_NewsSource.mqh`: `RawNewsEvent` struct + `INewsSource`
  interface (`ReadRawEvents`/`SourceKind`) - the only shape either source
  is allowed to produce; no normalization at this layer.
- `Market/MLQuantAI_NewsCanonicalizer.mqh`: the pipeline. `NormalizedNewsEvent`,
  `News_NormalizeTitle`/`News_NormalizeImpact`/`News_NormalizeTimeUtc`,
  `News_MakeCanonicalEventKey`, `News_ComputeMinutesToEvent` (truncates
  toward zero both signs), `News_Deduplicate` (priority -> revision_timestamp
  -> lexical source_kind tie-break, fails loudly on an unresolved conflict),
  `News_SortAndSelect` (frozen 24h/24h/top-10 window), `News_DecisionHash`
  (decision-relevant fields only, source-independent) and
  `News_SnapshotIdentity` (full lineage, deliberately source-dependent -
  the B5 audit trail).
- `Market/MLQuantAI_NewsCoverageValidator.mqh`: `News_ValidateCoverage` -
  hard fail-closed gate (not advisory) on a source's raw data not fully
  covering a requested range.
- `Market/MLQuantAI_CsvStaticNewsSource.mqh`: `CsvStaticNewsSource` -
  frozen 7-column CSV format (`Common\Files`), fails closed on missing
  file/bad schema version/any malformed row - never skips a bad row.
- `Market/MLQuantAI_LiveCalendarNewsSource.mqh`: `LiveCalendarNewsSource` -
  wraps `CalendarValueHistory`/`CalendarEventById`/`CalendarCountryById`,
  routes through the same canonicalizer, fails closed (no silent fallback)
  on a calendar read failure.
- `Market/MLQuantAI_NewsEngine.mqh`: `NewsEngine_Build(anchorTime)` -
  the orchestrator; routes to CSV (Tester) or Live (else) by
  `MQL_TESTER`, runs the full pipeline, returns `NewsEngineResult`
  (`snapshots[]`, `news_count`/`max_news_impact`/`nearest_news_minutes`,
  `news_decision_hash`, `news_snapshot_identity`), logs one journal line
  per build. `NewsEngine_InitCsvSource`/`_DeinitCsvSource` load + hard-gate
  CSV coverage once from `OnInit`. Legacy `News_HighImpactNear*` (a
  separate live real-time gate check) kept unchanged.
- `Market/MLQuantAI_MarketContext.mqh`: `news_decision_hash`/
  `news_snapshot_identity` fields (additive). `MarketContext_HashPayload()`'s
  news contribution changed from a per-element `NewsSnapshot_HashFragment`
  loop (included `source_kind`) to the single `news_decision_hash` field -
  a deliberate algorithm change, justified in-file, since no candidate
  dataset yet depends on a historical `context_hash` value.
- `Market/MLQuantAI_NewsSnapshot.mqh`: `normalized_event_key`/`revision_id`/
  `revision_timestamp`/`source_priority` fields (additive lineage).
- `MLQuantAI.mq5`: `OnInit` now hard-gates on `NewsEngine_InitCsvSource()`
  in Tester mode - `INIT_FAILED` on a coverage/schema/file problem, not a
  warning.
- `Tests/MLQuantAI_Test_NewsParity.mq5` + `Tests/Fixtures/
  MLQuantAI_NewsParityFixture_V1.csv`: core parity (live vs. CSV agree on
  `news_decision_hash`, differ on `news_snapshot_identity`), canonicalization
  (case/whitespace/truncation/tie-break/order-independence), selection/
  coverage against the real fixture (>10 events caps to a deterministic
  top 10, dedup winner, fail-closed coverage gap and malformed CSV), and
  seal criteria (metadata-only changes don't move `news_decision_hash`,
  replay never touches a source, B5 lineage fields reach
  `MARKET_CONTEXT_READY`'s JSON payload).
- `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`: `Test_NewsSnapshotCanonicalization`
  renamed/migrated to `Test_NewsDecisionHash_DrivesContextHash` (asserts
  `MarketContext_HashPayload` tracks `news_decision_hash`, not raw `news[]`
  content) plus 2 new payload-completeness checks for the new hash fields.

### Removed
- `Market/MLQuantAI_NewsEngine.mqh`: `News_CsvImpactToInt`, `News_BuildSnapshots_Live`,
  `News_BuildSnapshots_Csv`, `News_BuildSnapshots` - superseded by
  `NewsEngine_Build()`'s shared pipeline; confirmed unused elsewhere.

## [Unreleased] - Phase B B3.5: Data Hub Determinism Seal

Hardens B3's `context_hash` to actually satisfy the 5 seal criteria
(in-session determinism, cross-session determinism, account-exclusion,
full hash coverage, regression) - see `Docs/PhaseB_B3_5_DeterminismSeal.md`.

### Added
- `Market/MLQuantAI_NewsSnapshot.mqh`: `NewsSnapshot_Canonicalize()`
  (sorts by `release_time` then `calendar_event_id`) and
  `NewsSnapshot_HashFragment()`. `FeatureEngine_BuildContext()` now
  canonicalizes `ctx.news` before computing aggregates or the hash, so
  `context_hash` no longer depends on calendar/CSV source ordering.
- `Market/MLQuantAI_MarketContext.mqh`: `MarketContext_HashPayload()`
  extended to include `m5_bar`/`m15_bar`/`h1_bar`/`h4_bar` (time, OHLC,
  tick_volume, historical spread, via the new
  `MarketContext_RatesHashFragment()`) and the full canonically-ordered
  `NewsSnapshot[]` content - previously only `news_count`/
  `max_news_impact`/`nearest_news_minutes` were hashed, not the news
  identity itself. `MarketContext_RatesToJson()` gained `tick_volume` to
  match what's now hashed.
- `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`: `Test_AccountExclusion_
  RealPipeline()` (mutates `.account` on a real built context, asserts
  the hash is unchanged), `Test_NewsSnapshotCanonicalization()`
  (self-contained, proves source-order independence after
  canonicalizing), `Test_CrossSessionFixture()` (persists a
  anchor+hash fixture across script runs to prove the SAME anchor bar
  hashes the same after a "restart").

## [Unreleased] - Phase B B3: Data Hub / Feature Engine Migration + Determinism

Migrates the live Data Hub/Feature Engine/`MLQuantAI.mq5` to the B1-frozen
`Market/MLQuantAI_MarketContext.mqh` contract, closed-bar only. See
`Docs/PhaseB_B3_DataHubDeterminism.md`. Still no CRT/strategy code, no AI,
no execution wiring.

### Added
- `Market/MLQuantAI_FeatureEngine.mqh`: `FeatureEngine_BuildContext()`
  replaces Step 9's `FeatureEngine_Build()` - builds the new
  `MarketContext`, resolves the symbol via B2's `SymbolSpec_BuildResolved()`,
  and reads every field from the closed trigger bar
  (`InpTriggerTimeframe`, default M5) backward, never bar 0/`TimeCurrent()`/
  a live tick. `FeatureEngine_CurrentAnchorBarTime()` exposes the same
  anchor `MLQuantAI.mq5`'s `OnTick()` uses for new-bar detection.
- `Market/MLQuantAI_DataHub.mqh`: `g_hADX_M15` handle;
  `DataHub_AsianRangeAt(symbol, asiaEndHour, asOf, ...)` replaces
  `DataHub_AsianRange()` (read `TimeCurrent()` internally).
- `Market/MLQuantAI_SessionEngine.mqh`: `Session_Id(t)` - one label for
  `MarketContext.session_id`.
- `Market/MLQuantAI_NewsEngine.mqh`: `News_BuildSnapshots()`/`_Live`/`_Csv`
  - a full `NewsSnapshot[]` anchored at an explicit `asOf`, replacing a
  live `TimeCurrent()`-anchored bool for context-building purposes.
  `News_HighImpactNear()` stays as a separate live gate-check utility.
- `Market/MLQuantAI_MarketContext.mqh`: `MarketContext_ComputeHash()` and
  `MarketContext_ToJsonFragment()` (the full `MARKET_CONTEXT_READY`
  payload, including the embedded `NewsSnapshot[]`). The frozen struct's
  fields are unchanged.
- `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`: rebuilds the same anchor
  bar 1,000 times and asserts `context_hash` never changes, plus
  payload-completeness and closed-bar-semantics checks.

### Removed
- `Core/MLQuantAI_MarketContext.mqh` (Step 9's `MarketContext` struct) -
  deleted once nothing referenced it after the migration.

## [Unreleased] - Phase B B2: Symbol Resolution

Contract + resolver only - no DataHub/FeatureEngine/MLQuantAI.mq5 wiring
in this pass (that migration is B3's job).

### Added
- `Core/MLQuantAI_ContractVersions.mqh`: `MLQUANTAI_SYMBOL_SPEC_SCHEMA_V1`.
- `Market/MLQuantAI_SymbolSpec.mqh` extended **additively**: canonical
  `instrument_id` vs. resolved `broker_symbol`, `tick_size`, `tick_value`,
  `currency_margin`, `trade_mode`. Every Step 9 field is unchanged - the
  legacy `SymbolSpec_Build()` still behaves exactly as before, since
  `FeatureEngine_Init()` already calls it directly.
- `Market/MLQuantAI_SymbolResolver.mqh`: `SymbolResolver_LooksLikeAlias`
  (prefix-decoration match + a small built-in XAUUSD alias table for
  brokers using unrelated names like "GOLD" + `InpExtraSymbolAliases` for
  anything broker-specific - deliberately NOT a loose substring/contains
  check), `SymbolResolver_Resolve`/`_ResolveWith` (fails closed on an
  unknown or non-matching symbol), and `SymbolSpec_BuildResolved`/
  `_BuildResolvedWith` - the new B2 entry point B3's DataHub and B5's
  detectors should use instead of the legacy `SymbolSpec_Build()`.
- `Tests/MLQuantAI_Test_SymbolResolver.mq5`: alias-matching (prefix,
  built-in, extra, and rejection of loose/wrong matches), override vs.
  auto-detect resolution, fail-closed behavior on an invalid symbol, and
  full `SymbolSpec` snapshot population.

## [Unreleased] - Phase B B1: Contract Freeze

Contracts only - no DataHub/FeatureEngine/CRT/execution code was written
or changed in this pass. See `Docs/PhaseB_B1_ContractFreeze.md`.

### Added
- `Core/MLQuantAI_ContractVersions.mqh`: Phase B schema version constants
  (`MLQUANTAI_MARKET_CONTEXT_SCHEMA_V1`, `MLQUANTAI_FEATURE_SCHEMA_V1`,
  `MLQUANTAI_CANDIDATE_SCHEMA_V1`, `MLQUANTAI_NEWS_SCHEMA_V1`,
  `MLQUANTAI_RISK_SCHEMA_V1`) - separate from Phase A's
  `MLQuantAI_VersionRegistry.mqh`, which stays untouched.
- `Market/MLQuantAI_MarketContext.mqh`: the new, frozen `MarketContext`
  contract - canonical `instrument_id` vs. `broker_symbol`, closed-bar-only
  `anchor_bar_time`, per-timeframe `MqlRates` bars, an embedded
  `NewsSnapshot[]`, and a `context_hash` that deliberately excludes
  runtime-only account state. Coexists with the Step 9
  `Core/MLQuantAI_MarketContext.mqh` (still what the live Data Hub/Feature
  Engine build) until B2/B3 migrates them to this contract.
- `Market/MLQuantAI_NewsSnapshot.mqh`: one calendar event, replayable via
  JSON (`NewsSnapshot_ToJson`/`FromJson`/array round-trip helpers),
  self-contained from Phase A's `EventSerializer` on purpose.
- `Market/MLQuantAI_FeatureSnapshot.mqh`: contract stub for the eventual
  Feature Store row (not wired to anything - B3+).
- `Core/MLQuantAI_RiskDecision.mqh`: audit record for a future Risk
  Manager (B7) to log for every candidate, approved or rejected - keeps
  rejected setups explainable instead of just dropped (no survivorship
  bias). Distinct from the existing `MLQuantAI_RiskPlan.mqh` (Phase A's
  sizing-output struct).
- `Core/MLQuantAI_TradeCandidate.mqh` extended **additively**:
  `candidate_schema_version`, `context_event_id`/`context_hash`
  (candidate <-> context lineage), `side` (`ENUM_ORDER_TYPE`),
  `setup_anchor_bar_time` + `expiry_after_bars` (closed-bar expiry, via
  the new `TradeCandidate_ComputeExpiryTime` helper - never
  `TimeCurrent() + N minutes`), `entry_hint`/`sl_hint`/`tp_hint`,
  `trigger_reason_mask` + `trigger_reasons[]`. Every Phase A field is
  unchanged - Phase A's sealed tests and `MLQuantAI.mq5`'s Step 8.5 smoke
  test still compile against the same struct untouched.
- `Core/MLQuantAI_Ids.mqh`: `Ids_ContextEventId(symbol, timeframeTag,
  barTime)` - deterministic id for one `MarketContext` snapshot, so a
  `TradeCandidate.context_event_id` can reference the exact context it
  was built from.
- `Tests/MLQuantAI_Test_PhaseBContracts.mq5`: struct-shape, closed-bar
  semantics, hash-excludes-runtime-metadata, and NewsSnapshot
  serialize/deserialize round-trip coverage for all of the above.

## [0.1.0] - Phase A

### Added
- Core contracts: `MarketContext`, `TradeCandidate`, `AIResult`,
  `RiskPlan`, `ExecutionResult`, `RuntimeState`, `AccountSnapshot`,
  `ExternalContext` - each carrying its own schema/version field.
- `ENUM_CANDIDATE_STATE` lifecycle state machine
  (`StateMachine_CanTransition`), enforcing the full CREATED/SUBMITTED
  branching tree and rejecting every illegal transition (including the
  explicit "EXECUTED -> CREATED never happens" / "MERGED -> SUBMITTED
  never happens" rules).
- `ENUM_REASON_CODE`, `ENUM_AI_DECISION`, `ENUM_RISK_DECISION`,
  `ENUM_EVENT_TYPE`, `ENUM_EVENT_STORE_HEALTH`.
- Deterministic ID generation (`Ids_RootEventId`, `Ids_CandidateId`,
  `Ids_CorrelationId`) via SHA-256 (`CryptEncode`) over the identifying
  fields - no `MathRand()`/`GetTickCount()` involved, so the same market
  event always hashes to the same IDs on any run. `Ids_NewRuntimeSessionId`
  stays intentionally non-deterministic (identifies one specific run).
- Append-only JSONL Event Store (`EventStore.mqh`): write-before-commit
  ordering (in-memory candidate state only advances after the event is
  confirmed durably written and flushed), `EventStoreValidator`
  (sequence contiguity per session, schema version, truncation
  detection), `EventStoreHealth` (Safe Mode - blocks new candidates only,
  never force-closes positions), `ReplayEngine` + `StateProjector`
  (reconstructs candidate state and `RuntimeState` from the log alone,
  independently re-validating every transition against the state
  machine).
- `MLQuantAI_BrokerReconciliation.mqh`: compares replayed EXECUTED
  candidates against real MT5 position state
  (`PositionsTotal`/`POSITION_COMMENT`).
- `MLQuantAI.mq5`: the first real EA - opens/validates/replays the Event
  Store and runs broker reconciliation in `OnInit`, logs
  `SYSTEM_STARTED`/`SYSTEM_STOPPED` with the full version registry. No
  strategies, no AI, no order logic yet.
- `Tests/`: `MLQuantAI_Test_DummyLifecycle`, `MLQuantAI_Test_ReplayIntegrity`,
  `MLQuantAI_Test_EventStoreRecovery`, `MLQuantAI_Test_BrokerReconciliation`
  (simulated broker state), `MLQuantAI_Test_StateMachine`,
  `MLQuantAI_Test_DeterministicId`.

### Fixed (found via review + real test runs, not just self-review)
- `EventStore_LogTransition`/`LogCandidateCreated` used to mutate
  in-memory candidate state *before* confirming the event write was
  durable - fixed so a failed write leaves the candidate untouched and
  trips Safe Mode instead.
- `ReplayEngine` used to skip every `SystemEvent` line, so
  `RuntimeState.runtime_session_id`/`session_start_time`/`safe_mode` never
  actually got reconstructed by replay - added `StateProjector_ApplySystem`.
- `EventSerializer_GetStr` stopped at the first quote character including
  an *escaped* one inside a value, silently truncating strings like
  `broker said \"invalid stops\"` - rewritten as a char-by-char scan that
  respects escape sequences.
- `schema_version` was declared in `VersionRegistry` but never actually
  written into serialized events - added, and the Validator now flags a
  missing/mismatched version as corruption.
- The three `EventSerializer_Parse*` functions never read the `"ts"`
  field back out of a line, so every replayed event had `ts=0` regardless
  of what was written - caught by `MLQuantAI_Test_ReplayIntegrity`
  actually failing (15/16) on a real run.

### Not built yet
Strategies (CRT/SMC/Trend Pullback/Breakout/Silver Bullet/Mean
Reversion), Regime Router, Candidate Pool/Dedup/Arbitration, Global Risk
Manager, Execution Engine, Trade Manager, real MT5 Data Hub/Feature
Engine/Session Engine/News Engine, XGBoost/ONNX AI Meta-Filter, External
Context data (DXY/US10Y/VIX/News/Sentiment). All Phase B+.
