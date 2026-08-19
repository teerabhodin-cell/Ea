# Phase B8.4 — Commit 3: Runtime Determinism and Handle-Lifetime Seal (Same Runtime Only)

**Status: Implemented, awaiting real compile/test confirmation.**
Implements `Docs/PhaseB_B8_4_Commit3_RuntimeDeterminism.md` (frozen
before code). This commit adds **zero new production functions or
constants** - every test exercises Commit 2's already-sealed,
already-passing `ModelRuntimeAdapter_LoadAndVerify` /
`ModelRuntimeAdapter_ValidateContractAndRun` / `Ids_Sha256HexBytes`
exactly as they are, against new fixtures/scenarios only. No new ONNX
API call, no new `matrixf` usage - materially lower compile risk than
Commit 2.

## What this commit adds

- **`Tests/Fixtures/MLQuantAI_ONNX_Fixture_Valid_Relocated_V1.onnx`**
  (new): a byte-identical copy of Commit 2's sealed
  `MLQuantAI_ONNX_Fixture_Valid_V1.onnx`, confirmed via `sha256sum`
  before checking in (`443b8efc...30fd` for both files) - proves the
  artifact-relocation claim without touching the artifact's own
  identity/hash.
- **`Tests/MLQuantAI_Test_B8_4_Commit3_RuntimeDeterminism.mq5`** (new,
  6 test functions).

## Test coverage

- **Artifact relocation**: the same bytes at a different locator path
  hash-verify successfully and produce the identical validated output
  as the original locator.
- **Input perturbation (model-fixture-specific sensitivity proof, not
  a universal claim)**: two genuinely different `FeatureSnapshot`
  fixtures produce two genuinely different raw outputs on the real
  fixture model - `0.5094773` and `0.4129363`, **both independently
  computed via real `onnxruntime` in Python** before being hardcoded
  into the test (not hand-derived guesses):
  ```
  vector A -> sigmoid(sum(A)*0.0004 - 0.55) = 0.5094773
  vector B -> sigmoid(sum(B)*0.0004 - 0.55) = 0.4129363
  ```
  Proves no stale tensor/session value leaks between two fresh
  load-verify-run cycles against the same artifact.
- **Released-handle reuse**: calling `ModelRuntimeAdapter_ValidateContractAndRun`
  a second time with a handle already released by its own first
  (successful) call fails deterministically - a stable non-`NONE`
  reason code, empty output, and critically **no crash** (reaching the
  test's final `Check()` calls is itself part of the proof that
  execution continued past the released-handle call).
- **One-call handle lifetime**: across 3 repeated load-verify-run
  cycles, every earlier cycle's handle is confirmed dead once that
  cycle ends - reusing any of the 3 captured handles afterward fails
  the same way the released-handle test proved, with no cross-cycle
  leak.
- **No mutation**: `ModelArtifact`, the canonical vector, and the
  locator string are unchanged before/after the new call patterns.
- **No side effects (structural)**: since no new production code
  exists in this commit, Commit 2's own structural proof (no
  `EventStore_Log*`/broker/`AccountInfo*`/`SymbolInfo*` call, no
  fallback artifact search) already covers every code path these new
  tests exercise - stated explicitly rather than re-asserted as if it
  were new.

## Manual verification (NOT part of the automated 6-function suite)

The terminal-restart checklist in `Docs/PhaseB_B8_4_Commit3_RuntimeDeterminism.md`
still needs to be run once by the user and its result recorded
separately, before B8.4 is declared sealed. This status doc will be
updated with that result once performed.

Not yet compiled/run by the user - do not treat as PASSED or merge
until a real MetaEditor log confirms it.
