# Phase B8.4 — Commit 2: Artifact Integrity + Runtime Adapter, Tier B (FROZEN)

**Status: FROZEN, before any code exists.** Opens after B8.4 Commit 1
(Tier A) PASSED (111/111). Title: **the real ONNX runtime adapter —
proves the model bytes that were verified are the exact model bytes
that were executed, then hands raw output to Tier A's already-sealed
validator.**

```
B8.3: "Is this artifact registered and compatible with this request?"
B8.4 Commit 1 (Tier A): "Given a verified artifact, what does the
                          contract require of input/output shape?"
B8.4 Commit 2 (Tier B): "Is the artifact byte-identical to what the
                          registry approved, and does the real runtime
                          agree with the declared tensor contract?"
B8.4 Commit 3 (later):  "Is execution deterministic, and how does it
                          fail?"
B8.5: "How is this output turned into an AIDecision?"
```

## Collision check (before writing anything)

- No `Onnx*` call anywhere in the repo (confirmed by search) — this is
  the first commit that touches a real runtime.
- No `FileOpen`/`FileLoad`/binary file-read of a model artifact
  anywhere in the repo.
- **`ENUM_INFERENCE_FAIL_REASON` already has every reason code this
  commit needs, frozen in Commit 1 and explicitly marked Tier-B-only:**
  `ARTIFACT_LOCATION_NOT_FOUND`, `ARTIFACT_READ_FAILED`,
  `ARTIFACT_HASH_MISMATCH`, `RUNTIME_UNAVAILABLE`,
  `RUNTIME_VERSION_MISMATCH`, `INFERENCE_FAILED`. `INPUT_SHAPE_MISMATCH`,
  `INPUT_TYPE_MISMATCH`, and `OUTPUT_TYPE_MISMATCH` were frozen in
  Commit 1 as "reserved — unreachable under Tier A" and become reachable
  here. **This commit adds zero new reason codes** — confirmation that
  Commit 1's vocabulary was frozen wide enough on the first pass.
  Tensor **name** mismatch (input/output name doesn't match what the
  artifact declares) is bucketed under `INPUT_SCHEMA_MISMATCH` /
  `OUTPUT_SCHEMA_MISMATCH` respectively — name is part of the schema
  contract, not a new dimension.
- `Ids_Sha256Hex(string)` (`Core/MLQuantAI_Ids.mqh`) confirmed, by
  direct inspection, to take a `string` and go through
  `StringToCharArray(text, data, 0, -1, CP_UTF8)` before hashing — this
  is correct for the canonical text payloads every B7/B8 hash uses so
  far, but a lossy/incorrect path for raw binary artifact bytes (not
  every byte sequence is valid UTF-8; the round-trip can alter bytes).
  **Left untouched** — a new sibling function is added instead (below).

## Real MQL5 API this contract binds to (verified against docs, not assumed)

```cpp
long CryptEncode(ENUM_CRYPT_METHOD method, const uchar &data[],
                  const uchar &key[], uchar &result[]);
// Already used by Ids_Sha256Hex. Accepts a uchar[] directly - no string
// round-trip required. CRYPT_HASH_SHA256 always produces a 32-byte
// (256-bit) digest, by definition of the algorithm.

long FileLoad(const string file_name, void &buffer[], int common_flag=0);
// Reads the ENTIRE binary file into an array in one call. Returns
// elements read, or -1 on error. CRITICAL CONSTRAINT: FileLoad reads
// only whole elements of the array's element size - e.g. a `double[]`
// (8 bytes/element) silently drops trailing bytes that don't fill a
// full element. This is a truncation hazard for arbitrary file sizes.
// The buffer array MUST be uchar[] (1 byte/element) - the only element
// size for which this truncation can never occur, for any file size.

long OnnxCreateFromBuffer(const uchar &buffer[], ulong flags);
// Returns a session handle, or INVALID_HANDLE on failure. flags is
// from ENUM_ONNX_FLAGS (ONNX_COMMON_FOLDER, ONNX_DEBUG_LOGS) - neither
// applies to buffer-based loading, so this contract freezes flags = 0.

bool OnnxRun(long onnx_handle, ulong flags, /* typed inputs/outputs */);
// Takes MQL5's own typed tensor containers (matrixf/vectorf in the
// reference example) as variadic arguments, not generic buffers.
```

**Naming-discipline note, learned the hard way in Commit 1:** this
commit is the first one to *legitimately* declare variables of type
`matrixf`/`vectorf` (MQL5's native ONNX tensor containers). That makes
the exact mistake that caused Commit 1's 121-error compile failure —
naming a local variable literally `vector`, `matrix`, `vectorf`, or
`matrixf` — *more* likely here, not less, because those words are now
genuinely in scope as type names. Every new file in this commit must be
grepped for `\b(vector|matrix|vectorf|matrixf)\b` as a variable/parameter
identifier (not a type annotation) before it's ever sent for compile.

## Hard invariants (frozen)

**I1 — Raw-byte identity.** `model_artifact_hash` = `Ids_Sha256HexBytes`
of the raw artifact bytes, computed directly via `CryptEncode` on the
`uchar[]` buffer — never through a string round-trip.

**I2 — Single-read execution.** The exact `uchar[]` buffer that was
hashed and compared against `model_artifact_hash` is the exact buffer
passed to `OnnxCreateFromBuffer`. One `FileLoad` call produces one
buffer; that buffer is never re-read, re-fetched, or reconstructed
between the hash check and the runtime call.

**I3 — No path reload.** After I1/I2 succeed, the adapter must never
call `OnnxCreate(path)` or reopen the artifact by its locator. The
locator is used exactly once, to produce the one buffer I1/I2 operate
on.

**I4 — Exact registry compatibility.** Unchanged from B8.3/Commit 1:
`feature_schema_version`, `model_target`, `input_schema_version`,
`output_schema_version`, `runtime_framework`, `runtime_version` must
all match the resolved, `PROMOTED` `ModelArtifact`.

**I5 — Exact tensor contract.** Before `OnnxRun`, inspect the loaded
session via `OnnxGetInputCount`/`OnnxGetOutputCount`/`OnnxGetInputName`/
`OnnxGetOutputName`/`OnnxGetInputTypeInfo`/`OnnxGetOutputTypeInfo` and
compare, for every input and every output: name, rank, dimensions,
data type. Any mismatch fails closed before `OnnxSetInputShape`/
`OnnxSetOutputShape`/`OnnxRun` are ever called.

**I6 — Tier A remains single owner.** The adapter passes `OnnxRun`'s
raw output directly into the already-sealed
`ModelInference_ValidateAndBuildResult` (Commit 1). No second
range/finite/shape validator is written in this commit.

**I7 — No decision authority.** No threshold, no BUY/SELL, no
ALLOW/REJECT, no `AI_DECISION_CREATED`, no event emission, no mutation
of `Candidate`/`RiskPlan`/`FeatureSnapshot`/`ModelArtifact`, no
broker/execution call — identical scope guard to Commit 1, now also
covering the real runtime call itself.

## What this commit adds

- **`Core/MLQuantAI_Ids.mqh`** (additive): `Ids_Sha256HexBytes(const
  uchar &bytes[])` — same `CryptEncode(CRYPT_HASH_SHA256, ...)` call
  `Ids_Sha256Hex` already uses, operating directly on the byte array.
- **`Infrastructure/EventStore/MLQuantAI_ModelRuntimeAdapter.mqh`**
  (new): the Tier B orchestration — locator resolution (from the
  already-resolved, compatible `ModelArtifact`) -> `FileLoad` into one
  `uchar[]` -> `Ids_Sha256HexBytes` -> compare to `model_artifact_hash`
  (I1/I2/I3) -> `OnnxCreateFromBuffer` on that same buffer -> tensor
  reflection and comparison against the artifact's declared contract
  (I5) -> `OnnxRun` -> raw output handed to Commit 1's
  `ModelInference_ValidateAndBuildResult` (I6) -> `OnnxRelease`.
  Deterministic fail-closed at every step, using only the reason codes
  already frozen in Commit 1.
- **`Tests/MLQuantAI_Test_B8_4_Commit2_RuntimeAdapter.mq5`** (new):
  real `.onnx` fixture file(s) checked into `Tests/Fixtures/`, exercised
  against the actual MQL5 ONNX runtime — this is the project's first
  test suite that is NOT runtime-independent, by design.

## Test matrix (frozen)

- Same artifact bytes, repeated execution -> same verified artifact,
  same `output_hash` for the same input.
- A single tampered byte in the artifact file -> `ARTIFACT_HASH_MISMATCH`,
  no `OnnxCreateFromBuffer` call ever made.
- Missing artifact at the locator -> `ARTIFACT_LOCATION_NOT_FOUND`.
- Locator present but unreadable/corrupt -> `ARTIFACT_READ_FAILED`.
- A different (but validly-hashed-to-itself) artifact placed at the
  same locator -> `ARTIFACT_HASH_MISMATCH` against the registry's
  declared `model_artifact_hash`.
- Wrong `runtime_framework` / wrong `runtime_version` -> rejected
  (`RUNTIME_VERSION_MISMATCH` / `RUNTIME_UNAVAILABLE` as applicable).
- Wrong input/output name, rank, shape, or data type (each isolated
  individually against a real fixture model) -> rejected before
  `OnnxRun`.
- Runtime returns NaN/Inf, or a value outside `[0,1]` -> rejected by
  Commit 1's `InferenceOutput_Validate` (proves I6: no duplicate
  validation logic was written here).
- Same input + same verified artifact -> deterministic `InferenceResult`
  (within a single machine/run — cross-machine/cross-CPU/cross-provider
  bit-identical output is explicitly NOT claimed here; that's Commit
  3's job).
- **Tamper-after-hash structural proof**: construct the adapter so the
  verified buffer and the executed buffer are provably the same
  variable across the whole call (single `uchar[]` declared once, never
  reassigned from a second read) — verified by inspection per I2, not
  by a runtime race simulation.
- No `EventStore_Log*`/`OrderSend`/`CTrade`/`AccountInfo*`/
  `SymbolInfo*` call anywhere in the adapter (I7, structural proof,
  same style as Commit 1's `Test_NoFallback_StructuralProof`).

## Explicitly out of scope for this commit (Commit 3, later)

Cross-machine/cross-CPU/cross-execution-provider determinism claims.
Any threshold/calibration logic. `AI_DECISION_CREATED` or any
`AIDecision` field (B8.5). Any change to an already-sealed
B5/B6/B7/B8.1/B8.2/B8.3/B8.4-Commit-1 production file.
