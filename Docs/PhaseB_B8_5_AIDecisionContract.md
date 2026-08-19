# Phase B8.5 — AIDecision Contract (FROZEN)

**Status: FROZEN, before any code exists.** Opens after B8.4 SEALED
(210/210 automated + manual terminal-restart checklist PASSED). Title:
**the first layer that gives a raw, validated `p_success` scalar
semantic meaning — ALLOW/REJECT/ABSTAIN — without ever gaining
execution authority.**

```
B8.3: "Is this artifact registered and compatible?"
B8.4: "Given a verified artifact, what validated raw output did inference produce?"
B8.5: "Under a versioned threshold policy, what does that output mean?"
B9:   "Do Candidate + RiskPlan + AIDecision + operational policy pass execution eligibility?"
```

```
Validated InferenceResult (B8.4, sealed)
    + FeatureSnapshot (B8.1, sealed - candidate lineage InferenceResult itself does not carry)
    + explicit, versioned AIDecisionPolicy (threshold)
        |
        v
   AIDecision
        |
        v
AI_DECISION_CREATED (Commit 2, not this doc's Commit 1 scope)
```

B8.5 is the first layer with authority to interpret `p_success` as
ALLOW/REJECT/ABSTAIN. It is still **not** execution authority: B9 is
the only place `RiskPlan` + `AIDecision` + operational policy combine
into `ELIGIBLE`/`REJECTED`. `AIDecision` never touches `lot_size`,
`entry`/`sl`/`tp`, or `RiskPlan` in any way.

## Collision check (before writing anything — full findings, both confirmed by the user)

- **`ENUM_AI_DECISION`** (Phase A, dormant, `AIResult.decision`'s type):
  `AI_DECISION_NONE`/`_ALLOW`/`_REJECT`/`_REDUCE_RISK`. Not reused —
  `REDUCE_RISK` is a risk-scaling capability B8.5 explicitly does not
  have (B8.5 never touches `RiskPlan`/`lot_size`). A new, B8.5-specific
  enum is minted instead (below); `ENUM_AI_DECISION` and `AIResult`
  stay completely untouched, exactly as already confirmed decision-level-but-different
  during B8.4's own collision check.
- **`ENUM_REASON_CODE`** (`Core/MLQuantAI_ReasonCodes.mqh`) already has
  a dedicated `// AI filter` section: `REASON_AI_LOW_CONFIDENCE`,
  `REASON_AI_HIGH_UNCERTAINTY`, `REASON_AI_REJECT`. **Reused** for
  `decision_reason_code` — this is the project's shared "why" vocabulary,
  already the exact type `TradeCandidate_Transition`'s `reason`
  parameter takes, and the dormant `EVENT_TYPE_CANDIDATE_REJECTED_BY_AI`
  candidate-lifecycle state (Phase A, never triggered by any real code
  path yet, and **not** driven by B8.5 itself — that stays out of
  B8.5's scope, presumably a later B9-era concern) already anticipates
  exactly this reason vocabulary arriving. `REASON_AI_ABSTAIN` is added
  additively (append-only, matches every existing enum's frozen-forward
  discipline in this project). `REASON_AI_LOW_CONFIDENCE`/
  `REASON_AI_HIGH_UNCERTAINTY` are left reserved/unreachable under this
  contract's single-scalar `p_success` threshold policy — they were
  designed for a richer, separate confidence+uncertainty output shape
  B8.4 deliberately never built (`OUTPUT_P_SUCCESS_V1` is one scalar
  only).
- **`InferenceResult` (B8.4, sealed) carries no `candidate_id`/
  `candidate_hash`** — only `feature_snapshot_id`/`feature_snapshot_hash`/
  `feature_vector_hash`. Those two fields live on `FeatureSnapshot`
  (B8.1, sealed) instead, alongside `context_hash`/`detector_hash`
  (both copied verbatim from the candidate there already). This is why
  `AIDecision_Build` takes **both** `InferenceResult` and
  `FeatureSnapshot` as inputs (never `InferenceResult` alone), and
  cross-checks the two agree before trusting the snapshot's lineage —
  the identical "validate against the struct you were actually given"
  pattern `ModelInference_ResolveAndPrepare` (B8.4 Commit 1) already
  established for the same reason.
- **`context_hash`/`detector_hash`/`risk_plan_id`/`plan_hash` are
  deliberately NOT `AIDecision` fields.** `context_hash`/`detector_hash`
  are transitively reachable via `feature_snapshot_id` ->
  `FeatureSnapshotProjection` (matching the established
  don't-duplicate-deep-lineage pattern `TrainingDatasetRow` already
  uses). `risk_plan_id`/`plan_hash` are excluded because `RiskPlan` and
  `AIDecision` must stay parallel, never coupled before B9 — the core
  architectural correction `Docs/PhaseB8_B9_Roadmap_Notes.md` itself
  already made ("AI runs parallel to B7, not before/coupled to it").
- **`MLQUANTAI_AI_MODEL_VERSION = "NONE"`** (Phase A stub, baked into
  `SYSTEM_STARTED`'s version-registry JSON payload) is unrelated and
  untouched. Real model lineage on `AIDecision` comes from
  `InferenceResult.model_registry_id`/`model_registry_hash`/
  `model_artifact_hash`, copied verbatim — never this dormant constant.
- **`AIResult.p_success` (Phase A, `-1` = "no opinion" sentinel) is a
  different value-domain convention than `AIDecision.p_success`**
  (always finite `[0,1]`, no sentinel, guaranteed by B8.4's own
  `InferenceOutput_Validate` for any `InferenceResult` that reached a
  real success path). Different structs, explicitly not to be confused.
- **`Docs/PhaseB8_B9_Roadmap_Notes.md`'s old, informal `AIDecision`
  field-list draft is explicitly superseded** in several material ways,
  now that B8.1-B8.4 are real, sealed contracts rather than planning
  notes:
  - `model_id`/`model_version` (old) -> `model_registry_id`/
    `model_registry_hash` (this contract) — matches B8.3's real,
    sealed composite identity, not two loose strings.
  - `score` + `probability` (old, two fields) -> `p_success` (this
    contract, one field) — matches `OUTPUT_P_SUCCESS_V1`, the one
    output schema B8.4 actually froze.
  - `reason_codes[]` (old, array) -> `decision_reason_code` (this
    contract, singular) — a threshold-only policy only ever produces
    one reason.
  - `input_hash` (old) is dropped — redundant with
    `feature_vector_hash`/`feature_snapshot_hash`, both already carried
    verbatim from `InferenceResult`/`FeatureSnapshot`.
  - `context_hash`/`detector_hash`/`risk_plan_id`/`plan_hash` (old) are
    dropped — see above.
  - **Failed-inference policy is reversed**: the old notes proposed
    "a failed inference is `ABSTAIN`." This contract instead freezes:
    **a B8.4 inference failure (load/hash/runtime/validation) produces
    no `AIDecision` at all** — fail-closed at the B8.4 boundary, never
    reaching B8.5. `ABSTAIN` is reserved exclusively for an explicit,
    versioned policy condition acting on an already-successful
    `InferenceResult` — never a stand-in for an error.
  - No new `ENUM_INFERENCE_FAIL_REASON` code is needed for this — a
    failed B8.4 inference already fails at B8.4's own boundary with its
    own reason code; B8.5 simply never gets called in that case.

## `ENUM_AI_DECISION_OUTCOME` (new, frozen)

```cpp
enum ENUM_AI_DECISION_OUTCOME
{
   AI_DECISION_OUTCOME_NONE,     // Init()/unfilled only - never a real decision's value
   AI_DECISION_OUTCOME_ALLOW,
   AI_DECISION_OUTCOME_REJECT,
   AI_DECISION_OUTCOME_ABSTAIN   // frozen now, unreachable under Commit 1's policy v1 - reserved for a future explicit-abstain policy version
};
```

No `REDUCE_RISK`-equivalent value exists or is planned here.

## `ENUM_REASON_CODE` addition (additive, append-only)

```cpp
   // ... existing values unchanged ...
   REASON_AI_ABSTAIN,   // NEW - appended after the existing AI-filter block
   // ... REASON_COUNT still last ...
```

Policy v1's only reachable mapping:

```
AI_DECISION_OUTCOME_ALLOW   -> REASON_NONE
AI_DECISION_OUTCOME_REJECT  -> REASON_AI_REJECT
AI_DECISION_OUTCOME_ABSTAIN -> REASON_AI_ABSTAIN   (frozen, unreachable this commit)
```

`REASON_AI_LOW_CONFIDENCE`/`REASON_AI_HIGH_UNCERTAINTY` stay reserved,
untouched, unreachable from this contract.

## `AIDecisionPolicy` struct (new)

The minimal, explicit, versioned policy input `AIDecision_Build`
requires — no implicit default anywhere.

```cpp
struct AIDecisionPolicy
{
   string decision_policy_version; // mandatory, non-empty
   string threshold_version;       // mandatory, non-empty
   double allow_threshold;         // must be finite, in [0,1]
};
```

## `AIDecision` struct (new, frozen)

```cpp
struct AIDecision
{
   string ai_decision_schema_version; // MLQUANTAI_AI_DECISION_SCHEMA_B8_5_V1

   string ai_decision_id;   // identity - Ids_AIDecisionId(candidate_id, model_registry_id, decision_policy_version)
   string ai_decision_hash; // content integrity - see "Identity and hash" below

   string candidate_id;     // copied verbatim from the verified FeatureSnapshot
   string candidate_hash;   // copied verbatim from the verified FeatureSnapshot

   string feature_snapshot_id;   // copied verbatim from InferenceResult (cross-checked against snapshot)
   string feature_snapshot_hash; // copied verbatim from InferenceResult (cross-checked against snapshot)
   string feature_vector_hash;   // copied verbatim from InferenceResult (cross-checked against snapshot)

   string model_registry_id;   // copied verbatim from InferenceResult
   string model_registry_hash; // copied verbatim from InferenceResult
   string model_artifact_hash; // copied verbatim from InferenceResult

   string inference_output_hash;      // copied verbatim from InferenceResult.output_hash
   string output_schema_version;      // copied verbatim from InferenceResult
   string inference_contract_version; // copied verbatim from InferenceResult

   string decision_policy_version; // from the supplied AIDecisionPolicy
   string threshold_version;       // from the supplied AIDecisionPolicy
   double allow_threshold;         // from the supplied AIDecisionPolicy - the actual numeric value used, for audit without a policy-registry lookup

   double p_success; // copied verbatim from InferenceResult.output_values[0] - never recomputed

   ENUM_AI_DECISION_OUTCOME decision_outcome;
   ENUM_REASON_CODE         decision_reason_code;
};
```

Nothing here is recomputed from upstream sources — every lineage/hash
field is copied verbatim from `InferenceResult`/`FeatureSnapshot`,
matching B8.3/B8.4's own "trust the struct you verified, never
re-derive" discipline.

## `AIDecision_Build` (new, frozen signature)

```cpp
bool AIDecision_Build(const InferenceResult &inference, const FeatureSnapshot &snapshot,
                        const AIDecisionPolicy &policy, AIDecision &outDecision, string &outReasonDetail);
```

Fail-closed order (mirrors `ModelInference_ResolveAndPrepare`'s own
ladder style):

1. `policy.decision_policy_version == ""` or `policy.threshold_version == ""`
   -> fail, no `AIDecision` produced.
2. `policy.allow_threshold` not finite or outside `[0,1]` -> fail.
3. `inference.feature_snapshot_id != snapshot.feature_snapshot_id` OR
   `inference.feature_snapshot_hash != snapshot.feature_snapshot_hash` OR
   `inference.feature_vector_hash != snapshot.feature_vector_hash`
   -> fail (referential mismatch between the two inputs).
4. `inference.output_values` is not exactly 1 element, or that value is
   not finite, or outside `[0,1]` -> fail. (Defensive - any
   `InferenceResult` that genuinely passed B8.4's own
   `InferenceOutput_Validate` already satisfies this; this catches a
   hand-constructed/corrupted struct handed in directly, the same
   boundary-trust posture `ModelInference_ResolveAndPrepare` takes
   toward its own inputs.)
5. Otherwise: copy every lineage/hash field verbatim (per the struct
   above), set `p_success = inference.output_values[0]`, then:
   - `p_success >= policy.allow_threshold` (inclusive) ->
     `AI_DECISION_OUTCOME_ALLOW`, `REASON_NONE`.
   - else -> `AI_DECISION_OUTCOME_REJECT`, `REASON_AI_REJECT`.
   - `AI_DECISION_OUTCOME_ABSTAIN` is not reachable from this function
     in Commit 1 - no code path produces it yet. It exists in the enum
     now so a future policy version can add an explicit abstain branch
     without redefining the vocabulary.
6. Compute `ai_decision_id`/`ai_decision_hash` (below), return `true`.

On any failure, `outDecision` is left at `AIDecision_Init()` defaults
(`AI_DECISION_OUTCOME_NONE`, empty strings) - no partial record, no
event, no mutation of `inference`/`snapshot`/`policy`.

## Identity and hash

```cpp
string Ids_AIDecisionId(string candidateId, string modelRegistryId, string decisionPolicyVersion)
{
   string key = candidateId + "|" + modelRegistryId + "|" + decisionPolicyVersion;
   return Ids_Deterministic("AIDEC", key);
}
```

Deliberately independent of `p_success`, `allow_threshold`,
`decision_outcome`, and every hash field — identical to the
`Ids_RiskPlanId`/`Ids_FeatureSnapshotId`/`Ids_ModelRegistryId` identity
philosophy already established: **same identity + different content is
always a genuine collision/drift signal**, never an expected outcome.
Same `candidate_id` + same `model_registry_id` + same
`decision_policy_version`, re-decided later, must produce the exact
same `ai_decision_id` — if it produces a different `ai_decision_hash`,
that is a real replay/audit alarm, not routine variation.

`ai_decision_hash` payload — every decision-bearing field, **excluding**
`ai_decision_id` (identity, not content) and `ai_decision_schema_version`
(the struct's own top-level schema stamp). This follows the
`RiskPlan`/`TrainingDatasetRow` default (exclude the struct's own
schema-version field from its content hash), not `ModelArtifact`'s
deliberate departure — no reasoning has come up yet for `AIDecision` to
need the opposite choice, but this is a explicit, callable-out design
pick, not an oversight, exactly the same way `ModelArtifact`'s
departure was called out in `Docs/PhaseB_B8_3_ModelRegistryContract.md`:

```
candidate_id | candidate_hash |
feature_snapshot_id | feature_snapshot_hash | feature_vector_hash |
model_registry_id | model_registry_hash | model_artifact_hash |
inference_output_hash | output_schema_version | inference_contract_version |
decision_policy_version | threshold_version | allow_threshold |
p_success | decision_outcome | decision_reason_code
```

```
same ai_decision_id + same ai_decision_hash    -> duplicate, no-op
same ai_decision_id + different ai_decision_hash -> collision, fail-closed
```

## Scope guard (Commit 1: pure mapping only)

No ONNX load/run, no artifact file access or hash recomputation, no
live account/tick/broker state, no mutation of
`Candidate`/`RiskPlan`/`FeatureSnapshot`/`ModelArtifact`/`InferenceResult`,
no event emission (Commit 2), no projection/replay (Commit 2), no
execution eligibility or order submission, no auto-fallback model, no
adaptive/live threshold, no replacement of B9's authority.

## Expected commits (as proposed, not all frozen in this doc)

```
B8.5 Commit 1  AIDecision + threshold-policy pure mapping   <- this contract
B8.5 Commit 2  AI_DECISION_CREATED + projection/replay       <- own contract addendum, later
B8.5 Commit 3  Full-chain regression + seal                  <- own contract addendum, later
```

## Test matrix (Commit 1, frozen)

- Accept path: valid `InferenceResult` + matching `FeatureSnapshot` +
  valid policy, `p_success >= allow_threshold` -> `ALLOW`/`REASON_NONE`,
  every field copied verbatim and matches its source exactly.
- Accept path, reject branch: same setup, `p_success < allow_threshold`
  -> `REJECT`/`REASON_AI_REJECT`.
- Inclusive boundary: `p_success == allow_threshold` exactly ->
  `ALLOW` (not `REJECT`).
- Empty `decision_policy_version` / empty `threshold_version` -> fail,
  no `AIDecision`.
- `allow_threshold` non-finite, `< 0`, or `> 1` -> fail.
- `feature_snapshot_id`/`feature_snapshot_hash`/`feature_vector_hash`
  mismatch between `inference` and `snapshot` (each isolated
  individually) -> fail, referential mismatch.
- `inference.output_values` wrong length / non-finite / out-of-range
  (hand-constructed, bypassing B8.4) -> fail, defensive boundary check.
- `Ids_AIDecisionId` determinism: same 3 identity inputs -> same id,
  every time.
- `ai_decision_hash` determinism: same full payload -> same hash, byte
  identical, repeated builds.
- `ai_decision_hash` sensitivity: changing `p_success`, `allow_threshold`,
  `decision_outcome`, or `decision_reason_code` alone (all else equal)
  each moves the hash - proves the "same identity, different hash must
  be detectable" collision property actually holds.
- No mutation: `inference`/`snapshot`/`policy` unchanged before/after
  `AIDecision_Build`, on both the accept and every reject path.
- No side effects (structural): no `EventStore_Log*`/`OrderSend`/
  `CTrade`/`AccountInfo*`/`SymbolInfo*`/ONNX call anywhere in
  `AIDecision_Build` - verified by inspection.
