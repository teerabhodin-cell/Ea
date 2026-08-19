# Phase B8.4 — Commit 2: Artifact Integrity + Runtime Adapter, Tier B

**Status: Fixed after a real compile failure, awaiting a fresh
compile/test confirmation.**
Implements `Docs/PhaseB_B8_4_Commit2_RuntimeAdapter.md` (frozen before
code). This is the project's first commit that touches a real ONNX
runtime, real binary file I/O, and MQL5's native `matrixf` tensor type
- carried meaningfully higher compile risk than any prior commit, and
that risk was called out explicitly (see below) rather than hidden -
which is exactly where the real compile failure landed.

**The user's first real compile failed with 28 errors**, in two
independent groups:

1. `undeclared identifier 'Ids_Sha256HexBytes'`, everywhere it's used
   (both files) - the compiled `MQL5\Include\MLQuantAI\Core\MLQuantAI_Ids.mqh`
   did not contain the new function. The source-of-truth file in this
   repo is correct and unchanged; this points to the file not having
   been fully overwritten in the MetaEditor include folder. No code
   change needed here - re-copy the file and recompile.
2. The exact flagged-as-unverified area: `OnnxTypeInfo.type` compared
   directly against `ONNX_DATA_TYPE_FLOAT` (implicit-conversion warning,
   silently wrong), and `.shape.dimensions` (`undeclared identifier
   'shape'`, cascading into further errors). **Root cause, confirmed
   against the real struct definition at
   https://www.mql5.com/en/docs/onnx/onnx_structures**: `OnnxTypeInfo.type`
   is `ENUM_ONNX_TYPE` - the parameter *kind* (tensor/map/sequence), not
   the element data type. The element data type and the shape both live
   one level down, in a `.tensor` substruct
   (`OnnxTensorTypeInfo.data_type` / `.dimensions[]`), only filled when
   `.type == ONNX_TYPE_TENSOR`. Fixed: added an explicit
   `.type == ONNX_TYPE_TENSOR` check (a genuine correctness improvement -
   the real struct also supports map/sequence parameters, which this
   contract correctly never expects), then moved the dtype/shape checks
   to `.tensor.data_type` / `.tensor.dimensions[]`.

**Confirmed by the same real compile: `matrixf`'s constructor/indexing
syntax and `OnnxRun`'s positional signature were correct as originally
written** - zero errors were reported anywhere past the `OnnxTypeInfo`
struct-access code, even though that was flagged as equally uncertain
before this attempt.

**A second real compile+run (after both fixes above) got to 54/60
checks passing, then failed all 6 remaining checks with the exact same
real runtime error: `ONNX: parameter is empty` at the `OnnxRun` call.**
Root cause: `OnnxRun` does not auto-size an empty output container -
`matrixf outputMatrix;` (default-constructed, zero-sized) is rejected
outright, unlike an API that fills whatever container you hand it.
Fixed by pre-sizing `outputMatrix` to the exact `[1,1]` shape the I5
tensor-contract check had already confirmed the model declares
(`matrixf outputMatrix(MLQUANTAI_ONNX_BATCH_SIZE, 1);`) - this is also
why I5 running before `OnnxRun` matters structurally, not just as a
rejection gate: the shape used to pre-size the output buffer is a
verified value, never an assumed one. All 6 failures traced to this
one root cause (the accept-path test and the determinism test, which
both call `OnnxRun` for real); every negative-path test that never
reaches `OnnxRun` (wrong name/shape/dtype, hash mismatch, missing
file, garbage bytes) passed cleanly on this same run.

## What was verified against real MQL5 documentation before writing code

- `CryptEncode(ENUM_CRYPT_METHOD, const uchar &data[], const uchar &key[], uchar &result[])`
  - confirmed it takes a `uchar[]` directly, no string round-trip
    required.
- `FileLoad(const string file_name, void &buffer[], int common_flag=0)`
  - confirmed the whole-element truncation hazard (only safe with a
    `uchar[]` buffer, 1 byte/element) and that `FILE_COMMON` reads from
    the shared `Common\Files` folder, matching this project's existing
    fixture convention.
- `OnnxCreateFromBuffer(const uchar &buffer[], ulong flags)` - confirmed
  signature; flags frozen to `0` (neither `ONNX_COMMON_FOLDER` nor
  `ONNX_DEBUG_LOGS` applies to buffer-based loading).
- The full ONNX function list (`OnnxGetInputCount`/`OnnxGetOutputCount`/
  `OnnxGetInputName`/`OnnxGetOutputName`/`OnnxGetInputTypeInfo`/
  `OnnxGetOutputTypeInfo`/`OnnxRun`/`OnnxRelease`) - confirmed each
  exists with the stated one-line purpose.
- All 7 `.onnx` fixture files were run through **real `onnxruntime`
  in Python** (not just `onnx.checker`) before being checked in - this
  caught one real fixture-design bug: a "wrong dtype" fixture built as
  DOUBLE-input-against-FLOAT-weights failed to load at all (invalid
  graph, not a dtype-mismatch-at-inspection-time case as intended).
  Rebuilt as a fully self-consistent all-DOUBLE model, which loads
  correctly and now genuinely exercises the `INPUT_TYPE_MISMATCH`
  reflection path instead of failing earlier than intended. The valid
  fixture's expected output (`0.5094773`) is the real value onnxruntime
  produced for the exact canonical test vector, not a hand-computed
  guess.

## OnnxTypeInfo's real shape (now confirmed, after the real compile failure above)

```cpp
struct OnnxTypeInfo
{
   ENUM_ONNX_TYPE        type;      // ONNX_TYPE_TENSOR / _MAP / _SEQUENCE / ...
   OnnxTensorTypeInfo    tensor;    // filled only when type == ONNX_TYPE_TENSOR
   OnnxMapTypeInfo       map;
   OnnxSequenceTypeInfo  sequence;
};
struct OnnxTensorTypeInfo
{
   const ENUM_ONNX_DATA_TYPE  data_type;    // ONNX_DATA_TYPE_FLOAT etc
   const long                 dimensions[]; // the tensor shape
};
```
Source: https://www.mql5.com/en/docs/onnx/onnx_structures. The code now
checks `.type == ONNX_TYPE_TENSOR` first, then reads `.tensor.data_type`
/ `.tensor.dimensions[]`.

## Naming-discipline check (learned from Commit 1's real failure)

Every new/changed file was grepped for `\b(vector|matrix|vectorf|matrixf)\b`
as a bare identifier (not a type annotation). Confirmed clean: the only
occurrences are `matrixf inputMatrix(...)` / `matrixf outputMatrix;`
(legitimate type declarations) and comments/string literals containing
the word "vector" in prose (e.g. "canonical vector") - never a bare
variable name.

## What this commit adds

- **`Core/MLQuantAI_Ids.mqh`** (additive): `Ids_Sha256HexBytes(const uchar &bytes[])`
  - hashes raw bytes directly via `CryptEncode`, no string round-trip.
- **`Core/MLQuantAI_ContractVersions.mqh`** (additive):
  `MLQUANTAI_ONNX_INPUT_TENSOR_NAME`, `MLQUANTAI_ONNX_OUTPUT_TENSOR_NAME`,
  `MLQUANTAI_ONNX_BATCH_SIZE` - the fixed tensor contract
  `INPUT_SCHEMA_V1`/`OUTPUT_P_SUCCESS_V1` map to (`ModelArtifact` itself
  carries no literal shape fields - these version identifiers needed a
  concrete, frozen shape to check against, which did not exist yet).
- **`Infrastructure/EventStore/MLQuantAI_ModelRuntimeAdapter.mqh`** (new):
  `ModelRuntimeAdapter_LoadAndVerify` (I1-I3: single-read, hash-verify,
  open from the same buffer) and `ModelRuntimeAdapter_ValidateContractAndRun`
  (I5-I6: tensor reflection, `OnnxRun`, hand raw output to the caller -
  Tier A's validator is never called from inside this file). The
  session handle is owned entirely inside this module - Phase 2 always
  releases it before returning, on every exit path.
- **`Tests/Fixtures/MLQuantAI_ONNX_Fixture_*.onnx`** (7 new files, real
  binary ONNX models, generated in Python and independently validated
  against real `onnxruntime`): `Valid`, `Tampered` (one byte flipped),
  `Garbage` (not valid ONNX at all, but a real, self-consistent hash),
  `WrongInputName`, `WrongInputShape` (10 features), `WrongOutputShape`
  ([1,2] instead of [1,1]), `WrongInputDtype` (self-consistent DOUBLE
  model).
- **`Tests/MLQuantAI_Test_B8_4_Commit2_RuntimeAdapter.mq5`** (new, 12
  test functions) - the project's first test suite that is NOT
  runtime-independent, by design.

## A locator design decision made during implementation (within the frozen contract, not a change to it)

`ModelArtifact` (B8.3, sealed) carries no path/locator field - the
frozen Commit 2 contract's diagram implied reading "the artifact" from
"a locator" without specifying where that locator comes from. Resolved
as: **the runtime adapter takes the file path as a plain caller-supplied
parameter**, never a `ModelArtifact` field and never touching the sealed
`MLQuantAI_ModelArtifact.mqh`. This is consistent with (and arguably
strengthens) I3's "locator isolation" principle - the locator isn't
even registry state in this design, so there is nothing on the
persisted, hashed struct for a path to ever leak into.

## Test coverage

12 test functions against real `.onnx` fixture files (must be copied
into `Common\Files` before running, same convention as
`Tests/Fixtures/MLQuantAI_NewsParityFixture_V1.csv`):

- `Ids_Sha256HexBytes` matches the real, independently-computed SHA-256
  of the valid and tampered fixtures.
- **`LoadAndVerify`**: accept path opens a real session; missing
  locator -> `ARTIFACT_LOCATION_NOT_FOUND`; a single tampered byte ->
  `ARTIFACT_HASH_MISMATCH` with no session ever created (I1 gates
  `OnnxCreateFromBuffer`); hash-authentic-but-non-ONNX bytes ->
  `RUNTIME_UNAVAILABLE`, distinct from a hash failure (proves I1 and
  runtime-load are genuinely separate checks).
- **`ValidateContractAndRun`**: accept path's raw output matches the
  value real `onnxruntime` produced in Python (~0.5094773, epsilon
  0.001), and that same raw output is hand off to Tier A's
  `InferenceOutput_Validate` unchanged and accepted (I6, structural +
  behavioral proof in one test); wrong input name, wrong input shape,
  wrong output shape, and wrong input dtype each isolated against a
  real fixture built specifically for that one mismatch.
- **Determinism**: 5 repeated load+verify+run cycles against the same
  artifact produce byte-identical output, explicitly scoped to
  single-machine/single-run (cross-machine/cross-provider determinism
  is Commit 3's job, not claimed here).
- **I2 tamper-after-hash** and **I7 no-fallback/no-event-store**:
  structural proofs by inspection, same style as Commit 1's
  `Test_NoFallback_StructuralProof`.

Not yet compiled/run by the user - do not treat as PASSED or merge
until a real MetaEditor log confirms it.
