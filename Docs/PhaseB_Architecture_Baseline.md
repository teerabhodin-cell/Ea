# Phase B — Architecture Baseline (Confirmed 2026-08-18)

**Status: SEALED as the current baseline architecture.** This doc
consolidates and locks the phase table and governing rules confirmed
by the user on 2026-08-18, replacing the informal proposals in
`Docs/PhaseB_B7_RiskPlanDraft_Notes.md` and
`Docs/PhaseB8_B9_Roadmap_Notes.md` as the single reference. Those two
docs stay in the repo as historical record of how this baseline was
arrived at; this doc is the one to read for "what's frozen right now."

Sealing this baseline does not itself mark any phase PASSED or
complete — it fixes the phase boundaries and the rules each phase must
obey.

**Update (2026-08-18, same day): B7 is now SEALED.** Commits 1–3
(B7.1 through B7.5, plus the full-chain integration/regression proof)
are all PASSED with real test evidence and merged to `mlquantai` —
Commit 1 98/98, Commit 2 65/65, Commit 3 40/40 plus the full B5/B6/B7
manual regression checklist re-run clean, zero regressions. See
`Docs/PhaseB_B7_RiskPlanContract.md` (now marked SEALED) and
`Docs/PhaseB_B7_Commit3_IntegrationRegression.md` for the full
evidence.

**Update (2026-08-19): B8.1 and B8.2 are now SEALED.** B8.1
(`FeatureSnapshot` identity/lineage/hash) PASSED 66/66 and merged. B8.2
(Training Dataset + Outcome Boundary, Commits 1–4) PASSED in full —
Commit 1 76/76, Commit 2 105/105, Commit 3 109/109, Commit 4 104/104,
total **394/394** — with the full manual regression checklist re-run
clean and zero regressions in the same MetaEditor session as Commit
4's own suite. See `Docs/PhaseB_B8_1_FeatureSnapshot.md` and
`Docs/PhaseB_B8_2_Commit4_Seal.md` for the full evidence.

**Update (2026-08-19, same day): B8.3 is now PASSED.** `ModelArtifact`
Registry / Compatibility Contract — 106/106 ALL PASS, merged to
`mlquantai`. Registry/compatibility only, as scoped: no ONNX loading,
no inference, no scoring. See `Docs/PhaseB_B8_3_ModelRegistry.md` for
the full evidence.

**Update (2026-08-19, same day): B8.4 Commit 1 (Tier A) is now
PASSED.** Inference Contract, runtime-independent half — 111/111 ALL
PASS on a real MetaEditor run, merged to `mlquantai`. The first real
compile attempt failed with 121 errors (a `vector`-reserved-word
identifier collision in the test file only); root-caused, fixed,
re-verified, and confirmed clean on the user's second real compile.
See `Docs/PhaseB_B8_4_InferenceTierA.md` for the full evidence
including that fix. Tier A only: pinned `InferenceRequest` ->
`ModelArtifact` compatibility + `FeatureSnapshot` lineage -> canonical
12-value input vector -> typed output validation -> `InferenceResult`.
No ONNX session, no model file I/O, no real runtime call anywhere in
this commit.

**Update (2026-08-20): B8.4 Commit 2 (Tier B) is now PASSED.** Artifact
Integrity + Runtime Adapter — 61/61 ALL PASS on a real MetaEditor run,
merged to `mlquantai`. The project's first commit touching a real ONNX
runtime, real binary file I/O, and MQL5's native `matrixf` tensor type;
three real compile/run iterations were needed (the exact `OnnxTypeInfo`
struct shape and `OnnxRun`'s output-sizing requirement could not be
verified from public docs before writing code, and both surfaced as
real errors, root-caused and fixed against the real MQL5 API rather
than guessed). See `Docs/PhaseB_B8_4_Commit2_RuntimeAdapterStatus.md`
for the full evidence including all three fixes.

**Update (2026-08-20, same day): B8.4 Commit 3 is now PASSED.** Runtime
Determinism and Handle-Lifetime Seal, **same-runtime scope only** —
38/38 ALL PASS on a real MetaEditor run, merged to `mlquantai`. Adds
zero new production functions/constants — every test exercises Commit
2's already-sealed `ModelRuntimeAdapter_LoadAndVerify` /
`_ValidateContractAndRun` / `Ids_Sha256HexBytes` against new
fixtures/scenarios: artifact relocation, input-perturbation sensitivity
(two real, independently `onnxruntime`-computed outputs on the same
fixture), released-handle reuse (deterministic fail-closed — the ONNX
runtime itself logs "invalid handle passed to OnnxRelease function" on
the real run, confirming no crash), one-call handle lifetime (no
cross-cycle leak). **Explicitly does not claim** bitwise cross-machine
or cross-provider equivalence — only one provider (CPU fallback) has
ever been exercised. See
`Docs/PhaseB_B8_4_Commit3_RuntimeDeterminismStatus.md` for the full
evidence.

**Update (2026-08-20, same day): B8.4 is now FULLY SEALED.** The manual
terminal-restart checklist ran for real: Run A (pre-restart baseline)
and Run B (after the user actually closed and reopened the MT5
terminal, ~4 minutes later) reproduced identical results on every
comparison point — all three automated suites' pass counts unchanged
(111/111, 61/61, 38/38), the identical `"ONNX: CPU selected"` provider
line (same TensorRT/CUDA failure reasons, same hostname), and the
identical real-`onnxruntime`-matched output values. See
`Docs/PhaseB_B8_4_Commit3_RuntimeDeterminismStatus.md`'s "Manual
verification" section for both runs' full evidence. Same-machine,
same-CPU-provider, same-runtime-version determinism survives a real
terminal restart — **cross-machine/cross-provider determinism is still
not claimed**, since only one provider has ever been exercised. Current
status:

```
B5    Candidate Provenance                 SEALED
B6    Candidate Projection / Lineage       SEALED
B7    Deterministic RiskPlan               SEALED
B8.1  Immutable FeatureSnapshot            SEALED
B8.2  Training Dataset + Outcome Boundary  SEALED (394/394)
B8.3  Model Registry + Artifact Contract   SEALED (106/106)
B8.4  Inference + ONNX Runtime Adapter     SEALED (210/210 automated
                                            + manual restart checklist PASSED)
      Commit 1 - Inference Contract, Tier A                       PASSED (111/111)
      Commit 2 - Artifact Integrity + Runtime Adapter, Tier B      PASSED (61/61)
      Commit 3 - Runtime Determinism / Handle-Lifetime (same-runtime)  PASSED (38/38)
B8.5  AIDecision + AI_DECISION_CREATED     SEALED (254/254)
      Commit 1 - threshold-policy pure mapping                     PASSED (72/72)
      Commit 2 - AI_DECISION_CREATED + AIDecisionProjection         PASSED (123/123)
      Commit 3 - full-chain integration + regression proof         PASSED (59/59)
B9    Execution Eligibility Policy         SEALED (283/283)
      Commit 1 - pure eligibility mapping                           PASSED (120/120)
      Commit 2 - EXECUTION_ELIGIBILITY_DECIDED + lifecycle wiring    PASSED (84/84)
      Commit 3 - full-chain integration + regression proof           PASSED (79/79)
C1.1  ExecutionRequest + Safety Gate + Dry-Run  FROZEN (contract only, no code yet)
C1.2  Immutable ExecutionRequest, safety gate, dry-run adapter  NEXT
C1.3  Audit event/read model, reconciliation, regression, seal  (after C1.2)
C2    Broker Submit Adapter                     HELD (pending explicit authorization)
```

B8.5 is SEALED: 254/254 across all three commits, all real MetaEditor
runs, plus a manual re-run of `Test_B8_1_FeatureSnapshot.mq5` (66/66),
`Test_B8_3_ModelRegistry.mq5` (106/106), `Test_B8_5_AIDecision.mq5`
(72/72), and `Test_B8_5_Commit2_AIDecisionEvent.mq5` (123/123) in the
same MetaEditor session, per Commit 3's own Definition of Done - no
regression anywhere in the B8.1/B8.3/B8.5 chain. See
`Docs/PhaseB_B8_5_Commit3_IntegrationRegressionStatus.md` for full
evidence.

B9 is SEALED: 283/283 across all three commits, all real MetaEditor
runs, plus a manual re-run of `Test_B9_ExecutionEligibility.mq5`
(120/120) and `Test_B9_Commit2_EligibilityEvent.mq5` (84/84) in the
same MetaEditor session, per Commit 3's own Definition of Done - no
regression anywhere in the B9 chain. See
`Docs/PhaseB_B9_Commit3_IntegrationRegressionStatus.md` for full
evidence. Phase C (Broker Execution + Reconciliation) is open next.

**Note on the old, informal "B8.6" language**: a few early B8.1/B8.4
contract docs described the still-to-come AI work informally as
"B8.5 (decision semantics) / B8.6 (persist/replay/audit)" in their own
scoping prose. `B8.6` was never a row in this doc's own "phase table"
(below) - B8 has always been tracked as one umbrella phase with B9
directly after it. That informal split is now moot: B8.5 Commit 2
(event emission + `AIDecisionProjection` replay) and Commit 3
(cross-layer integration/audit-trail proof) together deliver
everything that language described. No separate B8.6 phase is planned;
B9 (Execution Eligibility Policy) is next after B8.5 SEALED, exactly as
the phase table below has always shown.

## The phase table

```
B5  CRT -> TradeCandidate
B6  Candidate Projection / Hash / Lineage
B7  RiskContext -> RiskPlan -> RISK_PLAN_CREATED -> Projection / Replay
B8  AI / ML Intelligence Layer
B9  Execution Eligibility Policy
C   Broker Execution + Reconciliation
```

The candidate layer (B5/B6) already carries `candidate_hash`,
`detector_hash`, and `context_hash`, each traceable back to its
originating detector run and `MARKET_CONTEXT_READY` event. That
provenance chain is the anchor B7 and B8 both attach to — neither
phase invents a second identity/lineage mechanism.

## B7 — Deterministic risk layer (frozen)

- AI has no authority inside B7, in either direction — it neither
  gates candidate creation nor sizing, and B7 never reads an AI
  output.
- `Candidate_ToRiskPlan()` does not mutate `TradeCandidate` or
  `RiskContext` — already true of the shipped Commit 1 implementation
  (`const &` signatures), now stated as a permanent invariant rather
  than an implementation detail.
- A persisted `RiskPlan` is the source of truth. Downstream layers
  (B8/B9/C) must never re-derive or overwrite it from the
  then-current account balance or symbol spec — only a fresh
  `Candidate_ToRiskPlan()` call against a fresh `RiskContext` produces
  a new plan, which gets its own `risk_plan_id`/`plan_hash`.
- `risk_plan_id` is identity (derived from `candidate_id` +
  `sizing_rules_version` only). `plan_hash` is content integrity.
- Same identity + same hash = duplicate, no-op.
- Same identity + different hash = collision, fail-closed (rejects the
  whole replay, never partially applies).
- Only a persisted `RiskPlan` (one that produced a durable
  `RISK_PLAN_CREATED` event) is eligible for any downstream use — an
  in-memory-only plan that was never emitted has no standing.

## B8 — Intelligence layer (frozen)

- AI receives immutable, candidate-time snapshots only — never a live
  query against current market/account state.
- AI does not mutate the candidate, does not set the risk budget, and
  does not touch `lot_size` directly.
- Model artifact, feature schema, threshold, and inference contract
  are all independently versioned.
- Every AI output is persisted as an event. Replay restores the
  recorded result — it never re-runs the model.
- Every score/decision must trace back to its input lineage
  (`candidate_id`/`candidate_hash`, and whatever feature-snapshot
  identity B8.1 defines).

## B9 and C (frozen)

- B9 is the policy authority: it combines `TradeCandidate` +
  `RiskPlan` + `AIDecision` + operational constraints into
  `ELIGIBLE` or `REJECTED`.
- B9 must never rewrite B5/B7 history — it only reads persisted
  records and emits its own eligibility decision.
- C is the broker-facing layer: submit, response, fill/reject, and
  reconciliation. Nothing upstream of C ever talks to a broker
  directly.

## B7 Commit 3 (PASSED 2026-08-18, 40/40 — see the update above)

Integration/regression proof of the full B5-through-B7 chain — no new
sizing rule, lifecycle, re-plan capability, AI dependency, or
execution behavior:

```
MARKET_CONTEXT_READY
    -> CANDIDATE_CREATED
    -> CandidateProjection
    -> Candidate_ToRiskPlan
    -> RISK_PLAN_CREATED
    -> RiskPlanProjection
    -> Restart / Replay
    -> identical lineage + state
```

Definition of Done:
- The full chain rebuilds state from the store alone.
- Candidate/projection/plan linkage matches on every hash and ID
  across the chain.
- A restart followed by replay reproduces byte-identical state.
- Duplicate and collision policy still hold correctly across the
  candidate/plan layer boundary, not just within each layer alone.
- A corrupted/truncated line anywhere fails the rebuild closed, with
  no partial commit.
- The full B5/B6/B7 regression suite passes.

This addendum was written into `Docs/PhaseB_B7_RiskPlanContract.md`
itself (matching how the Commit 2 addendum was appended there) once
Commit 2 was merged to `mlquantai`, then confirmed PASSED (40/40) and
merged in turn.

## B8.1 (SEALED — 66/66)

`FeatureSnapshot` — the immutable, candidate-time input contract for
B8. Extended the pre-existing, dormant Phase B1 `FeatureSnapshot`
struct additively with identity/lineage/hash fields
(`feature_snapshot_id`, `candidate_id`, `candidate_hash`,
`context_hash`, `detector_hash`, `feature_vector_hash`,
`feature_snapshot_hash`) rather than reusing Phase A's dormant
`MLQUANTAI_FEATURE_SCHEMA_V1` constant. See
`Docs/PhaseB_B8_1_FeatureSnapshotContract.md` (SEALED) and
`Docs/PhaseB_B8_1_FeatureSnapshot.md` for the full evidence.

## B8.2 (SEALED — 394/394)

Training Dataset Row/Manifest contract, deterministic persisted-artifact
export, and the Outcome/Label boundary — four commits:

- **Commit 1** (76/76): `TrainingDatasetRow`/`TrainingDatasetManifest`
  schema, identity, content hash, deterministic split policy, and the
  pure `BuildTrainingDatasetRow` builder. No event store involvement.
- **Commit 2** (105/105): resolved a real gap found before writing any
  code — `FeatureSnapshotProjection` never existed, so B8.1's
  `FeatureSnapshot` had no persistence layer at all. Added
  `FEATURE_SNAPSHOT_CREATED` emission + `FeatureSnapshotProjection`
  (Part 0, mirroring `RiskPlan`'s own B7 Commit 2 pattern), then built
  `TrainingDatasetExport_BuildDataset` — deterministic, read-only
  export from persisted artifacts only, fail-closed on any corruption
  or mixed-schema cohort (Part 1).
- **Commit 3** (109/109): `RealizedOutcome` — the only sanctioned
  source of a training row's label. Identity independent of outcome
  content (same philosophy as `Ids_RiskPlanId`), a strict temporal
  boundary (`outcome_time` must be after the candidate's own
  `setup_anchor_bar_time`), reuses the dormant Phase A
  `EVENT_TYPE_TRADE_OUTCOME_LABELED` slot. Proved both structurally
  and empirically that a `RealizedOutcome` can never move a
  candidate-time feature hash.
- **Commit 4** (104/104): zero new production behavior — proved the
  full B8.2 chain (context through exported row) composes correctly
  end to end, and proved 4 critical gates compositionally across a
  multi-candidate cohort: outcome-never-touches-AI-input,
  incomplete-vs-corrupt are genuinely different outcomes, a collision
  at any single layer blocks the whole export, and export atomicity
  (valid store -> full output, corrupted store -> zero output +
  `Init()` manifest). Also proved `LABELED_ONLY` as a pure client-side
  filter over already-shipped fields, adding no new production filter
  function.

See `Docs/PhaseB_B8_2_Commit4_Seal.md` for the full evidence and the
final 394/394 tally. **No further change to any B8.2 production file
is permitted** — anything B8.3+ needs goes through its own new
contract/version there, never a retroactive edit to a sealed B8.2 file.

## B8.3 (PASSED — 106/106, see the update above)

Model Registry / Artifact Contract — **registry/compatibility contract
only**, exactly as scoped: no ONNX loading, no inference, no scoring,
no threshold, no BUY/SELL/execution decision of any kind. See
`Docs/PhaseB_B8_3_ModelRegistryContract.md` and
`Docs/PhaseB_B8_3_ModelRegistry.md` for the full contract and evidence.

```
B7    -> RiskPlan
B8.3  -> Artifact compatibility (SEALED - see above)
B8.4  -> Inference (SEALED - see above, 210/210 automated + manual restart checklist PASSED)
          Commit 1 - Tier A (PASSED - see above)
          Commit 2 - Tier B, runtime adapter (PASSED - see above)
          Commit 3 - Runtime determinism / handle-lifetime, same-runtime (PASSED - see above)
B8.5  -> AI Decision (NEXT - not yet frozen)
B9    -> Execution Eligibility
C     -> Broker Execution
```

## B8.4 Commit 1 (PASSED — 111/111, see the update above)

Inference Contract, Tier A (runtime-independent) — pinned
`InferenceRequest` (no "latest," no fallback) -> `ModelArtifact`
compatibility via the sealed `ModelRegistry_FindCompatible` ->
referential check against the supplied `FeatureSnapshot` -> canonical
12-value `float[]` input vector (B8.1's own sealed field order,
reused not reinvented) -> typed output validation (exactly one frozen
schema, `OUTPUT_P_SUCCESS_V1`) -> `InferenceResult` (`output_hash`
depends only on `output_schema_version` + values, never
lineage/time/path). Two pure orchestration halves,
`ModelInference_ResolveAndPrepare` / `ModelInference_ValidateAndBuildResult`,
since no real runtime call happens in Tier A. See
`Docs/PhaseB_B8_4_InferenceContract.md` (frozen contract) and
`Docs/PhaseB_B8_4_InferenceTierA.md` (implementation + evidence,
including the real compile-failure-and-fix) for the full record.

## B8.4 Commit 2 (PASSED — 61/61, see the update above)

Artifact Integrity + Runtime Adapter, Tier B — real ONNX. `Ids_Sha256HexBytes`
(raw-byte SHA-256, no string round-trip) -> `ModelRuntimeAdapter_LoadAndVerify`
(single-read the artifact, hash-verify against `model_artifact_hash`,
open an `OnnxCreateFromBuffer` session from the exact same verified
buffer - never a path reload) -> `ModelRuntimeAdapter_ValidateContractAndRun`
(real tensor reflection against the frozen input/output contract,
`OnnxRun`, raw output handed to Commit 1's `InferenceOutput_Validate`
unchanged - never a second validator). Session handle owned entirely
inside the module, always released before returning. `ModelArtifact`
carries no locator/path field by design (per B8.3) - the runtime
adapter takes the file path as a plain caller-supplied parameter,
strengthening rather than violating I3's locator-isolation principle.
7 real `.onnx` fixtures (generated in Python, independently executed
against real `onnxruntime` before being checked in) exercise hash
mismatch, missing/corrupt/non-ONNX files, and wrong tensor name/shape/dtype,
each isolated to its own fixture. Three real compile/run iterations
were needed - `OnnxTypeInfo`'s exact struct shape and `OnnxRun`'s
output-sizing requirement were the two API surfaces that could not be
verified from public docs before writing code, and both were the
actual root causes hit, not a guess proven wrong by something else. See
`Docs/PhaseB_B8_4_Commit2_RuntimeAdapter.md` (frozen contract) and
`Docs/PhaseB_B8_4_Commit2_RuntimeAdapterStatus.md` (implementation +
evidence, including all three real fixes) for the full record.

## B8.4 Commit 3 (PASSED — 38/38, see the update above)

Runtime Determinism and Handle-Lifetime Seal — **same-runtime scope
only**, explicitly not a cross-machine/cross-provider claim. Adds zero
new production functions/constants: every test exercises Commit 2's
already-sealed `ModelRuntimeAdapter_LoadAndVerify` /
`ModelRuntimeAdapter_ValidateContractAndRun` / `Ids_Sha256HexBytes`
unchanged, against new fixtures/scenarios only — artifact relocation
(byte-identical file at a different locator, confirmed via `sha256sum`
before checking in), input-perturbation sensitivity (two genuinely
different `FeatureSnapshot` fixtures produce two genuinely different
raw outputs, both independently computed via real `onnxruntime` in
Python before being hardcoded, framed as a model-fixture-specific
proof rather than a universal claim), released-handle reuse
(deterministic fail-closed, no crash — the real run shows the ONNX
runtime's own `"invalid handle passed to OnnxRelease function"`
diagnostic, confirming the exact scenario without a crash), one-call
handle lifetime (no cross-cycle leak across 3 repeated cycles). See
`Docs/PhaseB_B8_4_Commit3_RuntimeDeterminism.md` (frozen contract) and
`Docs/PhaseB_B8_4_Commit3_RuntimeDeterminismStatus.md` (implementation
+ evidence) for the full record. **The manual terminal-restart
checklist in the frozen contract is still outstanding** — B8.4's final
seal is pending only that step.

```
TrainingDataset (B8.2, sealed)
    dataset_id / dataset_hash / feature_schema_version / model_target
            |
            v
      Model Artifact
            |
            v
      Model Registry
            |
            v
   Compatibility validation
       COMPATIBLE -> B8.4
       else       -> FAIL-CLOSED (no silent fallback)
```

Minimum fields to freeze, per the confirmed direction:

- **Model identity** (separate from dataset identity): `model_id`,
  `model_version`, `artifact_hash`.
- **Training lineage**: `training_dataset_id`, `training_dataset_hash`,
  `feature_schema_version`, `model_target`.
- **Runtime/compatibility**: `input_schema_version`,
  `output_schema_version`, `runtime_framework`, `runtime_version`,
  `promotion_state`.

Hard rule to freeze verbatim into the B8.3 contract: *A model artifact
whose declared feature schema, model target, input/output schema,
runtime, or training-dataset lineage is incompatible with the
requested inference contract MUST be rejected fail-closed. The system
MUST NOT silently select, downgrade to, or fall back to another model
artifact.*

**As actually frozen and shipped**: `artifact_hash` became two
distinct fields — `model_artifact_hash` (external evidence, the real
trained file's own hash) and `model_registry_hash` (internal,
computed last, full-record integrity) — a refinement made during the
B8.3 freeze itself, not a change from this note. The hard rule above
is implemented verbatim by `ModelArtifact_CheckCompatibility`/
`ModelRegistry_FindCompatible`. See
`Docs/PhaseB_B8_3_ModelRegistryContract.md` for the exact, final field
list and reasoning.

Same collision-check discipline as every prior commit (B7/B8.1/B8.2's
own gap) applies before writing anything: check the codebase for any
dormant Phase A model/registry scaffolding first, resolve any
collision found, then freeze the contract doc before any code.
