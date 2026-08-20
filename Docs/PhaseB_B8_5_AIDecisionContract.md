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

# Addendum — B8.5 Commit 2: `AI_DECISION_CREATED` event + `AIDecisionProjection`

**Status: FROZEN, before any code exists.** Written the moment Commit 1
was confirmed PASSED (72/72, real MetaEditor run) and Commit 2 was
confirmed to proceed, after a collision check against
`AI_DECISION_CREATED`/`AIDecisionProjection`/`AIDecisionRegistry`/
`ai_decision_id`/`ai_decision_hash`/`AIDecision_Emit`/
`EVENT_TYPE_AI_DECISION`/`AI_DECISION`/`ENUM_EVENT_TYPE`/
`EVENT_TYPE_CANDIDATE_REJECTED_BY_AI`/`AIResult` (full findings below).
Mirrors B8.2 Commit 2 Part 0 (`FeatureSnapshot_EmitFeatureSnapshotCreated`
+ `FeatureSnapshotProjection`) most closely, since `AIDecision` is the
same shape of thing `FeatureSnapshot` is: a derived artifact tied to a
candidate, not a candidate lifecycle transition.

## Collision check findings

- **`ENUM_EVENT_TYPE`**: current true tail is
  `EVENT_TYPE_MODEL_ARTIFACT_REGISTERED` (B8.3), with the append-only
  rule explicitly commented at every addition since B7
  (`RISK_PLAN_CREATED`/`FEATURE_SNAPSHOT_CREATED`/
  `MODEL_ARTIFACT_REGISTERED`). No `AI_DECISION_CREATED` or similar
  value exists. `EVENT_TYPE_AI_DECISION_CREATED` is appended after
  `EVENT_TYPE_MODEL_ARTIFACT_REGISTERED`, same rule.
- **Serializer/deserializer**: `AI_DECISION_CREATED` does not appear in
  `EventTypeToString`/`EventTypeFromString` anywhere - single, new
  ownership, no collision.
- **`EVENT_TYPE_CANDIDATE_REJECTED_BY_AI`** (Phase A, part of
  `ENUM_CANDIDATE_STATE`/`ENUM_EVENT_TYPE`'s candidate-lifecycle block,
  driven by `StateProjector`) is a **different concern entirely**: a
  candidate *state transition* (`CANDIDATE_CREATED -> REJECTED_BY_AI`),
  never triggered by any real code path yet, and explicitly confirmed
  out of B8.5's scope in Commit 1's own collision check (a later,
  presumably B9-era, concern - the state machine transition is not the
  same thing as persisting the `AIDecision` record itself).
  **`AI_DECISION_CREATED` does not touch `ENUM_CANDIDATE_STATE`,
  `StateProjector`, or drive any `CANDIDATE_REJECTED_BY_AI` transition**
  - it is a `SystemEvent` recording a decision artifact, exactly the
    same relationship `FEATURE_SNAPSHOT_CREATED`/`RISK_PLAN_CREATED`
    have to the candidate lifecycle (adjacent, never mutating it).
- **`AIResult`**: re-confirmed still fully dormant - no event
  emission, no projection, no reference from any real code path outside
  its own Phase A stub. `AI_DECISION_CREATED`/`AIDecisionProjection`
  create no second, competing truth source for `AIResult`'s concerns;
  `AIResult` remains untouched by B8.5 in its entirety.

## Why `AI_DECISION_CREATED` is a `SystemEvent`, not a `LifecycleEvent`

Same reasoning as `RISK_PLAN_CREATED`/`FEATURE_SNAPSHOT_CREATED`: an
`AIDecision` is not itself a candidate state transition, it is a
derived artifact tied to one candidate (via `candidate_id`/
`candidate_hash`, copied verbatim from the `FeatureSnapshot` it was
built from). `AI_DECISION_CREATED` is a `SystemEvent`
(`EventStore_LogSystem`), every `AIDecision` field flattened into
`extra_json` as top-level JSON keys, mirroring
`FeatureSnapshot_ToExtraJson`'s exact convention.

## Event type

`Core/MLQuantAI_Enums.mqh` (additive): `EVENT_TYPE_AI_DECISION_CREATED`
appended after `EVENT_TYPE_MODEL_ARTIFACT_REGISTERED` - the current
true tail - with `EventTypeToString`/`EventTypeFromString` cases added.
Also additive: `AiDecisionOutcomeFromString(string)`, the missing
inverse of Commit 1's `AiDecisionOutcomeToString`, needed so
`AIDecisionProjection` can parse `decision_outcome` back from its
persisted string form (the same enum-string round-trip
`ReasonCodeToString`/`ReasonCodeFromString` already provide for
`decision_reason_code`).

## `AI_DECISION_CREATED`'s `extra_json` - every `AIDecision` field

All 18 fields, flattened, `decision_outcome`/`decision_reason_code`
written as quoted strings via `AiDecisionOutcomeToString`/
`ReasonCodeToString` (mirrors `ModelArtifact_ToExtraJson`'s
`promotion_state` convention), `allow_threshold`/`p_success` via
`CanonicalDouble` (mirrors every other double field ever put in a hash
payload/extra_json in this project):

```
ai_decision_schema_version, ai_decision_id, ai_decision_hash,
candidate_id, candidate_hash,
feature_snapshot_id, feature_snapshot_hash, feature_vector_hash,
model_registry_id, model_registry_hash, model_artifact_hash,
inference_output_hash, output_schema_version, inference_contract_version,
decision_policy_version, threshold_version, allow_threshold,
p_success, decision_outcome, decision_reason_code
```

## Live emission: `AIDecision_EmitAIDecisionCreated` (new)

```cpp
bool AIDecision_EmitAIDecisionCreated(const AIDecision &d);
```

Mirrors `FeatureSnapshot_EmitFeatureSnapshotCreated` exactly:

1. Returns `false` (no write attempted) if `d.ai_decision_id == ""` -
   a decision that failed `AIDecision_Build` (left at `Init()`
   defaults, `decision_outcome == AI_DECISION_OUTCOME_NONE`) emits no
   event, same as an unfilled `FeatureSnapshot`/rejected `RiskPlan`
   emits nothing. **This is the only outcome-based gate** - `ALLOW`,
   `REJECT`, and (once reachable in a future policy version) `ABSTAIN`
   are ALL emitted identically, as audit evidence only. Commit 2 never
   branches on `decision_outcome` to decide whether to emit, and never
   produces any execution side effect for any outcome value - the
   event is a durable record of what was decided, nothing more.
2. Checks `AIDecisionProjection_TryGet(d.ai_decision_id, existing)` -
   the same coarse, live, in-session guard every prior emitter uses:
   any existing record for this `ai_decision_id` (regardless of
   `ai_decision_hash`) blocks re-emission this call. The finer
   duplicate-vs-collision distinction is the projection/replay layer's
   job, below.
3. Builds `extra_json` via `AIDecision_ToExtraJson(d)`, appends via
   `EventStore_LogSystem(EventTypeToString(EVENT_TYPE_AI_DECISION_CREATED), "ai decision created", extraJson)`.
4. On a successful durable write, applies the equivalent record
   directly to `AIDecisionProjection`'s live in-memory registry (the
   same live-sync fix every prior emitter needs).
5. Returns `true`.

No referential-integrity check against `FeatureSnapshotProjection`/
`ModelArtifactProjection` happens at emission time - same
trust-the-caller-verify-on-replay split every prior emitter uses.

## Replay/projection: `AIDecisionProjection` (new)

`AIDecisionProjectionRecord`: every `AIDecision` field above, plus
`source_sequence_number`/`source_log_event_id` (audit trail, same
fields every projection record already carries).

**Referential-integrity scope (the one point genuinely stricter than
any prior projection in this codebase, confirmed with the user before
freezing):** `AIDecision` has two independent upstream lineage chains -
`feature_snapshot_id`/`feature_snapshot_hash`/`feature_vector_hash`
(from `FeatureSnapshot`) and `model_registry_id`/`model_registry_hash`/
`model_artifact_hash` (from `ModelArtifact`/`ModelRegistry`). Every
prior projection in this project (`RiskPlanProjection`,
`FeatureSnapshotProjection`) only ever had ONE upstream chain to verify.
`AIDecisionProjection_RebuildFromFile` verifies **both**, independently:

1. `EventStoreValidator_ValidateLines` first - whole-file gate, same as
   every prior projection.
2. `FeatureSnapshotProjection_RebuildFromFile(fileName)` - rebuilt from
   the SAME file (which itself transitively rebuilds
   `CandidateProjection` first). If it fails, this rebuild fails
   closed, registry untouched.
3. `ModelArtifactProjection_RebuildFromFile(fileName)` - rebuilt from
   the SAME file, independently (it has no `CandidateProjection`
   prerequisite of its own - `ModelArtifact` is not candidate-tied).
   If it fails, this rebuild fails closed, registry untouched.
4. Reset `AIDecisionProjection`'s own registry, apply every line via
   `AIDecisionProjection_ApplyLine`, referential-integrity-checked
   against BOTH now-current registries from step 2 and step 3.

`AIDecisionProjection_ApplyLine(line, &outReason) -> bool` - mirrors
`FeatureSnapshotProjection_ApplyLine`'s exact ladder:

1. Line-length defensive bound.
2. Type-gate (two-part: `HasKey("type")` AND value check) - not
   `AI_DECISION_CREATED` -> skip as irrelevant.
3. `EventSerializer_ParseSystem` - fails -> "not a parsable event line".
4. Required-field presence: every string field on `AIDecision` non-empty
   (`ai_decision_id`, `ai_decision_hash`, `candidate_id`,
   `candidate_hash`, `feature_snapshot_id`, `feature_snapshot_hash`,
   `feature_vector_hash`, `model_registry_id`, `model_registry_hash`,
   `model_artifact_hash`, `inference_output_hash`,
   `output_schema_version`, `inference_contract_version`,
   `decision_policy_version`, `threshold_version`,
   `ai_decision_schema_version`).
5. Numerical integrity: `allow_threshold`/`p_success` both
   `MathIsValidNumber` and in `[0,1]` - the same defensive re-check
   `AIDecision_Build` itself applies, now re-verified at the
   persistence boundary too.
6. **Referential integrity against `FeatureSnapshotProjection`**: the
   referenced `feature_snapshot_id` must exist in
   `FeatureSnapshotProjection`'s registry (rebuilt from the same file),
   and its `feature_snapshot_hash`/`feature_vector_hash` must both
   match the line's own values, and its `candidate_id`/`candidate_hash`
   must both match the line's own `candidate_id`/`candidate_hash`.
   Missing -> orphan feature snapshot, rejected. Any mismatch -> lineage
   mismatch, rejected.
7. **Referential integrity against `ModelArtifactProjection`**: the
   referenced `model_registry_id` must exist in
   `ModelArtifactProjection`'s registry (rebuilt from the same file),
   and its `model_registry_hash`/`model_artifact_hash` must both match
   the line's own values. Missing -> orphan model registration,
   rejected. Any mismatch -> lineage mismatch, rejected.
8. **Collision-vs-duplicate** (payload-aware, same rule every prior
   projection uses): `ai_decision_id` already registered with an
   IDENTICAL `ai_decision_hash` -> duplicate, idempotent no-op, returns
   `true`. Already registered with a DIFFERENT `ai_decision_hash` ->
   collision, rejected, returns `false`.

## QA gate for B8.5 Commit 2 (binding on its test suite)

- A valid `AIDecision` (any of `ALLOW`/`REJECT`) emits exactly one
  `AI_DECISION_CREATED` event; re-emitting the identical decision live,
  same session, is a no-op.
- A failed `AIDecision_Build` result (`ai_decision_id == ""`) emits no
  event at all.
- On replay: same `ai_decision_id` + same `ai_decision_hash` ->
  duplicate, idempotent no-op. Same `ai_decision_id` + DIFFERENT
  `ai_decision_hash` -> collision, rejected, registry unchanged for
  that record.
- An `AI_DECISION_CREATED` line referencing a `feature_snapshot_id`
  with no matching `FEATURE_SNAPSHOT_CREATED` anywhere in the file ->
  orphan, rejected, whole rebuild fails closed.
- An `AI_DECISION_CREATED` line whose `feature_snapshot_hash`/
  `feature_vector_hash`/`candidate_id`/`candidate_hash` doesn't match
  the referenced `FeatureSnapshotProjection` record -> lineage
  mismatch, rejected, whole rebuild fails closed (each field isolated
  individually).
- An `AI_DECISION_CREATED` line referencing a `model_registry_id` with
  no matching `MODEL_ARTIFACT_REGISTERED` anywhere in the file ->
  orphan, rejected, whole rebuild fails closed.
- An `AI_DECISION_CREATED` line whose `model_registry_hash`/
  `model_artifact_hash` doesn't match the referenced
  `ModelArtifactProjection` record -> lineage mismatch, rejected, whole
  rebuild fails closed (each field isolated individually).
- A truncated/malformed line anywhere in the file (even one unrelated
  to any `AIDecision`) blocks the ENTIRE rebuild.
- Replaying the same store repeatedly reconstructs byte-identical
  `AIDecisionProjectionRecord`s every time.
- `ALLOW`, `REJECT` decisions both replay correctly and identically -
  no special-casing by `decision_outcome` anywhere in the projection
  path (proving the "audit evidence only, no execution behavior"
  invariant holds structurally, not just by convention).
- Every field on a rebuilt `AIDecisionProjectionRecord` matches the
  original `AIDecision` that was emitted, exactly - no drift.
- No execution/order/broker/account call anywhere in
  `AIDecision_EmitAIDecisionCreated` or `AIDecisionProjection` -
  verified by inspection.

## Explicitly out of scope for this commit

No candidate-lifecycle state transition (`CANDIDATE_REJECTED_BY_AI` or
any `ENUM_CANDIDATE_STATE`/`StateProjector` involvement), no B9
execution-eligibility logic, no consumption of `AIDecisionProjection`
by any other module yet, no `RiskPlan` coupling, no `AIResult` change.

# Addendum — B8.5 Commit 3: full-chain integration + regression proof, seal

**Status: FROZEN, before any code exists.** Written the moment Commit 2
was confirmed PASSED (123/123, real MetaEditor run) and Commit 3 was
confirmed to proceed. Mirrors B7 Commit 3
(`Docs/PhaseB_B7_RiskPlanContract.md`'s own addendum) and B8.2 Commit 4
most closely - both already sealed the same way. This commit adds
**zero new production behavior**: no new threshold semantics, no new
event schema, no new identity/hash seed, no new projection behavior,
no new decision policy, no execution/order/broker call, no change to
any already-sealed B5/B6/B7/B8.1/B8.2/B8.3/B8.4/B8.5-Commit-1/
B8.5-Commit-2 production file. It is purely a test-suite commit proving
the already-shipped pieces compose correctly end to end, plus the
integration seams Commit 1's and Commit 2's own suites did not
individually exercise.

## The chain being proven

```
MARKET_CONTEXT_READY
    -> CANDIDATE_CREATED
    -> CandidateProjection
    -> FEATURE_SNAPSHOT_CREATED  -> FeatureSnapshotProjection  ---\
                                                                    |--> AIDecision_Build -> AI_DECISION_CREATED -> AIDecisionProjection
    MODEL_ARTIFACT_REGISTERED    -> ModelArtifactProjection    ---/
    -> Restart / Replay
    -> identical lineage + state, both upstream chains
```

Unlike B7's chain (one upstream parent: `Candidate` -> `RiskPlan`),
`AIDecision` has **two independent upstream parents** -
`FeatureSnapshot` (itself candidate-derived) and `ModelArtifact`
(not candidate-tied at all) - that converge only at `AIDecision`
itself. Commit 3's genuinely-new coverage below is shaped by that
difference.

## What Commit 1's and Commit 2's own suites already cover (not re-proven here)

`Test_B8_5_AIDecision.mq5` already proves `AIDecision_Build`'s
fail-closed ladder, determinism, identity/hash sensitivity, and
no-mutation/no-side-effects, in isolation from any event store.
`Test_B8_5_Commit2_AIDecisionEvent.mq5` already builds every fixture
through the real B5/B8.1/B8.3/B8.4 pipeline, already proves
`AIDecisionProjection`'s own restart/multi-session/duplicate/collision
behavior, already proves BOTH referential-integrity chains
(`FeatureSnapshotProjection`, `ModelArtifactProjection`) reject an
orphan or a mismatch on every individual field, and already proves
field-by-field replay fidelity and the `ALLOW`/`REJECT`
audit-evidence-only property. Commit 3 does not repeat any of that.

## What's genuinely new in Commit 3

1. **Explicit end-to-end linkage assertion in one place.** A single
   test that, after a full rebuild, walks the whole chain forward from
   a real `MARKET_CONTEXT_READY` event and asserts every hash/ID
   matches its neighbor across all four layers: the candidate's
   `context_hash` matches the real `MarketContext`'s own
   `context_hash`; the snapshot's `candidate_id`/`candidate_hash`
   match the real `CandidateProjection` record; the decision's
   `feature_snapshot_id`/`feature_snapshot_hash`/`feature_vector_hash`
   match the real `FeatureSnapshotProjection` record; the decision's
   `model_registry_id`/`model_registry_hash`/`model_artifact_hash`
   match the real `ModelArtifactProjection` record; the decision's
   `ai_decision_id` is deterministically derived from that same
   `candidate_id` + `model_registry_id` + `decision_policy_version`.
   Commit 2's tests check each hash exists and round-trips correctly
   in isolation; this test checks the chain of custody across all four
   layers in one assertion sequence.
2. **Cross-layer failure propagation, both upstream chains
   independently** - not tested by Commit 2 or B8.1/B8.3 individually,
   and the one point genuinely harder than B7's single-parent case: (a)
   a corrupted/colliding `CANDIDATE_CREATED` or `FEATURE_SNAPSHOT_CREATED`
   line must cause `AIDecisionProjection_RebuildFromFile` to ALSO fail
   closed, since its own documented contract makes
   `FeatureSnapshotProjection_RebuildFromFile` (which itself depends on
   `CandidateProjection_RebuildFromFile`) a hard prerequisite; (b)
   independently, a corrupted/colliding `MODEL_ARTIFACT_REGISTERED`
   line must ALSO cause `AIDecisionProjection_RebuildFromFile` to fail
   closed, since `ModelArtifactProjection_RebuildFromFile` on the same
   file is an equally hard, but entirely independent, prerequisite.
   Both propagation paths are proven separately - a bug that only
   wires up one of the two dependency checks must be caught by this
   commit.
3. **Full-chain restart/crash simulation** - reopening the store fresh
   (simulating an EA process restart) and rebuilding
   `CandidateProjection`, `FeatureSnapshotProjection`,
   `ModelArtifactProjection`, and `AIDecisionProjection` from scratch
   twice, asserting all four layers' state is byte-identical across
   both rebuilds, for a store holding multiple candidates/snapshots/
   models/decisions together (not one at a time as Commit 2's restart
   test did).
4. **Multi-candidate, multi-model cross-linking check** - several
   candidates, each with their own `FeatureSnapshot`, decided against a
   mix of shared and distinct `ModelArtifact`s (proving the
   two-independent-parents shape doesn't let a decision accidentally
   pick up a neighboring candidate's snapshot or a neighboring
   decision's model); after a full rebuild, every `AIDecision` must
   link to exactly its own snapshot and its own model, never a
   neighboring one.

## Definition of Done

- The full chain rebuilds state from the store alone (no in-memory
  carry-over assumed).
- Candidate/snapshot/model/decision linkage matches on every hash and
  ID across all four layers, for every decision in a multi-candidate,
  multi-model store.
- A restart followed by replay reproduces byte-identical state in ALL
  FOUR of `CandidateProjection`, `FeatureSnapshotProjection`,
  `ModelArtifactProjection`, and `AIDecisionProjection`.
- Duplicate and collision policy still hold correctly across every
  layer boundary - a candidate-layer OR snapshot-layer OR model-layer
  failure closes the decision-layer rebuild too, proven independently
  for each of the two upstream chains.
- A corrupted/truncated line anywhere fails the rebuild closed, with no
  partial commit, regardless of which layer's line it corrupts.
- No execution, order, broker, account, or candidate-lifecycle-state
  transition results from either `ALLOW` or `REJECT` anywhere in this
  commit's test suite.
- The full B8.1/B8.3/B8.5 regression suite passes: every existing test
  file directly in the event-store/projection chain this commit proves
  (`Test_B8_1_FeatureSnapshot.mq5`, `Test_B8_3_ModelRegistry.mq5`,
  `Test_B8_5_AIDecision.mq5`, `Test_B8_5_Commit2_AIDecisionEvent.mq5`)
  plus the new `Test_B8_5_Commit3_IntegrationRegression.mq5` all re-run
  clean in the same MetaEditor session - this is a manual re-run
  checklist for whoever confirms this commit, not something one script
  can automate, since MQL5 has no cross-script test runner.

## Explicitly out of scope for this commit

Any new threshold semantics, any event schema change, any identity/hash
seed change, any projection behavior change, any new decision policy,
any B9 execution-eligibility logic, any broker/order/execution call,
any change to an already-sealed production file. If self-review during
this commit surfaces an actual product-level gap (not just a
test-coverage gap), that gets flagged to the user before any production
file is touched - same discipline as every commit before this one.

On a clean pass, this commit closes B8.5: **AIDecision + threshold-policy
mapping (Commit 1) + durable event/projection/replay (Commit 2) +
full-chain integration proof (Commit 3)**, sealed as the first layer
with authority to interpret `p_success` as ALLOW/REJECT/ABSTAIN,
still without execution authority - B9 remains the sole place
`RiskPlan` + `AIDecision` + operational policy combine into
`ELIGIBLE`/`REJECTED`.
