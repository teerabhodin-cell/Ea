# Phase B8.4 — Commit 3: Runtime Determinism and Handle-Lifetime Seal (Same Runtime Only)

**Status: PASSED (38/38, real MetaEditor run).**
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
  execution continued past the released-handle call). Confirmed on the
  real run: the ONNX runtime itself logs `"invalid handle passed to
  OnnxRelease function"` when the double-release happens - a real,
  visible diagnostic of the exact scenario being tested, not a crash.
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

## Manual verification (NOT part of the automated 38-check suite)

**COMPLETE — PASSED.** Run A and Run B agree on every comparison
point. B8.4 is fully sealed as of this result (see the architecture
baseline doc's update).

**Run A** (2026-08-20, 02:20:48–02:20:52, pre-restart baseline session
- `MLQuantAI_Test_B8_4_InferenceTierA.mq5`,
`MLQuantAI_Test_B8_4_Commit2_RuntimeAdapter.mq5`, and
`MLQuantAI_Test_B8_4_Commit3_RuntimeDeterminism.mq5` all run back to
back in the same, not-yet-restarted terminal session):

```
Commit 1 (Tier A)        111/111 ALL PASS
Commit 2 (Tier B)         61/61  ALL PASS
Commit 3 (Determinism)    38/38  ALL PASS
Provider identity: TensorRT init fails, CUDA init fails
                    (CUDA failure 801, GPU=-1) -> "ONNX: CPU selected"
                    hostname=DESKTOP-2DS27LU
Output value: raw ONNX output matches the real onnxruntime-computed
              value (~0.5094773) for the valid fixture + canonical
              vector A
```

Each `Check()` in these suites compares a freshly-computed value
(hash, output, etc.) against an external ground truth baked into the
test (the real SHA-256 of each fixture file, the real `onnxruntime`-computed
output value) - not "Run A's own number vs Run B's own number" done by
eye. That means Run B reproducing the identical `ALL PASS` /
`111/111`-`61/61`-`38/38`-style counts and the identical
provider-selection log lines after a real terminal restart is itself
the evidence the checklist
asks for: if same-runtime determinism had broken across the restart,
some `Check()` would flip to `[FAIL]` because the freshly-recomputed
value would stop matching that same fixed ground truth (e.g. a
different provider selected, a different computed hash, a different
output value).

**Run B** (2026-08-20, 02:24:28–02:24:33, ~4 minutes after Run A, run
after the user closed and reopened the MT5 terminal):

```
Commit 1 (Tier A)        111/111 ALL PASS   (unchanged)
Commit 3 (Determinism)    38/38  ALL PASS   (unchanged)
Commit 2 (Tier B)         61/61  ALL PASS   (unchanged)
Provider identity: identical - TensorRT/CUDA fail the same way
                    (CUDA failure 801, GPU=-1), "ONNX: CPU selected",
                    same hostname=DESKTOP-2DS27LU
Output values: identical - ~0.5094773 (vector A) and ~0.4129363
               (vector B), same as Run A
```

**Result: every comparison point the frozen checklist asks for agrees
between Run A and Run B** - `model_artifact_hash` (implicitly, via the
unchanged `ARTIFACT_HASH_MISMATCH`-free accept-path results),
runtime/provider identity, `feature_vector_hash` (implicitly, via the
unchanged canonical-vector and output-matching checks), validated
output values, and `output_hash` (implicitly, via
`Test_OutputHash_Deterministic`/`Test_OutputHash_ExcludesLineageMetadata`
in Commit 1 passing identically in both runs). No `[FAIL]` anywhere in
either run. Same-machine, same-CPU-provider, same-runtime-version
determinism survives a real terminal restart, exactly as scoped -
**no cross-machine/cross-provider claim is made from this result**,
since both runs are the same machine and the same CPU fallback.

Note: the raw literal hash strings are not printed to the log (each
`Check()` compares a freshly-computed value against a fixed ground
truth internally, per the test design explained above) - the
comparison points here are the pass/fail pattern and the printed
provider/output-match lines, which is what actually changes if
determinism breaks across a restart.

