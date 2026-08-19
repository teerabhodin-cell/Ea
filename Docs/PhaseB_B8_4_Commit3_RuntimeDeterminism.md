# Phase B8.4 — Commit 3: Runtime Determinism and Handle-Lifetime Seal — Same Runtime Only (FROZEN)

**Status: FROZEN, before any code exists.** Opens after B8.4 Commit 2
(Tier B) PASSED (61/61). Title: **proves the real runtime adapter is
deterministic and leak-free within the one environment this project
has actual evidence for — same machine, same tested CPU provider — and
draws the line explicitly where evidence stops, rather than extending
a claim past what was tested.**

```
B8.3:            "Is this artifact registered and compatible?"
B8.4 Commit 1:   "Given a verified artifact, what does the contract
                   require of input/output shape?"
B8.4 Commit 2:   "Is the artifact byte-identical to what the registry
                   approved, and does the real runtime agree with the
                   declared tensor contract?"
B8.4 Commit 3:   "Is repeated execution deterministic, and does the
                   handle lifecycle never leak or misbehave, within
                   the one environment actually tested?"
B8.5:            "How is this output turned into an AIDecision?"
```

## Claim allowed (frozen scope)

```
same machine
+ same tested CPU runtime/provider
+ same runtime/framework version
+ same artifact bytes
+ same canonical input vector
    -> deterministic validated output / output_hash
```

## Claims explicitly NOT made by this commit

- Bitwise equivalence across machines.
- Cross-provider equivalence (CPU vs GPU vs TensorRT, etc).
- Cross-GPU/CPU equivalence.
- Deterministic behavior across a runtime/framework version change.
- Automated proof of terminal close/reopen determinism (see "Manual
  verification" below — this is checked, just not by an automated
  `Check()`).

The CPU fallback that happens for real on the user's machine (TensorRT
and CUDA both fail to initialize, per the real Commit 2 logs) is **one
tested provider**, not cross-provider coverage. This commit does not
claim otherwise.

## Collision check (before writing anything)

- No new `ENUM_INFERENCE_FAIL_REASON` codes are needed — every failure
  mode this commit tests (released-handle misuse, artifact-relocation
  edge case) resolves through reason codes already frozen in Commit 1
  and exercised for real in Commit 2.
- **No new production `.mqh` function is needed.** Every test in this
  commit exercises `ModelRuntimeAdapter_LoadAndVerify` /
  `ModelRuntimeAdapter_ValidateContractAndRun` (Commit 2, sealed) and
  `Ids_Sha256HexBytes` (Commit 2, sealed) exactly as they already are —
  this commit is pure additional test coverage against already-shipped,
  already-passing code, not new runtime surface. This is also why it
  carries materially lower compile risk than Commit 2: no new ONNX API
  call, no new `matrixf` usage, nothing unverified.
- One new fixture file: a byte-identical copy of the already-sealed
  `MLQuantAI_ONNX_Fixture_Valid_V1.onnx` under a different filename, to
  prove the artifact-relocation claim without touching the artifact's
  own identity/hash.

## Automated tests (new coverage only — see "References" for what NOT to re-test)

| Test | Required proof |
|---|---|
| **Artifact relocation** | The valid fixture's bytes, placed at a *different* locator path, still hash-match `model_artifact_hash` and produce the identical validated output/`output_hash` as the original locator. |
| **Input perturbation** | A genuinely different canonical vector, run against the same verified artifact, produces a genuinely different raw output — proving no stale tensor/session value leaks between calls. Framed as a **model-fixture-specific sensitivity proof**, not a universal claim that any input change must always change the output (a real model may legitimately be insensitive to some perturbations). |
| **Released-handle reuse** | Calling `ModelRuntimeAdapter_ValidateContractAndRun` with a handle that was already released (by an earlier `ModelRuntimeAdapter_ValidateContractAndRun` call, which always releases before returning) fails deterministically with a stable reason code and an `InferenceResult` left at `Init()` defaults — no crash. |
| **One-call handle lifetime** | Across N repeated full load-verify-run cycles, each cycle's handle is provably dead after that cycle ends (reusing it fails the same way the released-handle test proves) — no handle leaks or becomes usable across cycle boundaries. |
| **No mutation** | The `ModelArtifact`, `FeatureSnapshot`-derived canonical vector, and locator string are unchanged before/after every new test's calls. |
| **No side effects** | The new code paths exercised in this commit's tests still make no `EventStore_Log*`/`OrderSend`/`CTrade`/`AccountInfo*`/`SymbolInfo*` call and perform no fallback artifact search — verified by inspection, same style as Commit 1/2's structural proofs. |

## Manual verification (separate from the automated DoD — not a `Check()`)

```
1. Close the MT5 terminal after run A.
2. Reopen the terminal.
3. Run the identical script/fixture as run B.
4. Compare, by inspection of the printed log:
   - model_artifact_hash matches
   - runtime/provider identity matches (same "ONNX: CPU selected" line)
   - feature_vector_hash matches
   - validated output values match
   - output_hash matches
```

If any line disagrees, terminal-restart determinism is NOT claimed,
and B8.4's final seal states its scope as same-runtime,
same-session-family only until further evidence exists. This checklist
is recorded as a manual result, separately from the automated
pass/fail count — it is real evidence when performed, but it is not
something this test suite can assert on its own.

## References — evidence this commit builds on, not repeats

- **Tier A (Commit 1, 111/111)**: request/registry mismatch handling,
  canonical vector schema/field-order correctness, non-finite input
  rejection, output schema/shape/range validation, immutable inputs,
  no decision/event/broker behavior.
- **Tier B (Commit 2, 61/61)**: locator absence, unreadable artifact,
  binary SHA-256 mismatch (including the single-tampered-byte case),
  ONNX metadata/load/run errors (including the hash-authentic-but-not-ONNX
  case), wrong tensor name/shape/dtype (each isolated to its own real
  fixture), and same-machine fresh-session determinism across 5
  repeated cycles — **this last item already proves "same machine,
  fresh session" determinism; Commit 3 does not repeat it.**

## Exclusions (explicit)

Cross-machine/provider tests. Terminal-restart automation.
Memory-allocation/matrix-creation fault injection (no deterministic way
to simulate this was found — excluded rather than faked). Any test
that duplicates Tier A/B coverage without adding new proof.
Threshold/decision/event logic. Model selection/fallback. Execution
behavior. Any change to an already-sealed
B5/B6/B7/B8.1/B8.2/B8.3/B8.4-Commit-1/B8.4-Commit-2 production file.

## Definition of Done

**Automated:**
- Every new test in the table above passes.
- No crash in the released-handle-reuse test.
- Every failure path returns a stable reason code and an
  `InferenceResult` left at `Init()` defaults — no partial output.
- The same-runtime scope is not overstated anywhere in code comments,
  docs, or test labels — no wording implies cross-machine/cross-provider
  determinism was proven when it was not.

**Manual:**
- The terminal-restart checklist above is actually run once, and its
  result (pass or specific disagreement) is recorded separately from
  the automated pass/fail count, before B8.4 is declared sealed.
