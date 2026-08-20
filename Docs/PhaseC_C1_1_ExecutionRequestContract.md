# Phase C1.1 — ExecutionRequest + Safety Gate + Dry-Run (frozen contract)

**Status: FROZEN, no code yet.** Opens after B9 FULLY SEALED (283/283,
all real MetaEditor runs). Per `Docs/PhaseB_Architecture_Baseline.md`'s
own B9-and-C boundary: *"C is the broker-facing layer: submit,
response, fill/reject, and reconciliation. Nothing upstream of C ever
talks to a broker directly."* Phase C is the first phase in this
project that will eventually call real broker-mutating MT5 APIs — a
materially different risk category from every sealed phase before it.

**C1 non-negotiable, true for every commit in C1 (C1.1/C1.2/C1.3):
C1 must never call a broker-mutating API.** Not `OrderSend`, not any
`CTrade` submit/modify/close method, not any market/pending order
placement call, not any broker-side position/order mutation of any
kind — regardless of any input, flag, or environment value, including
a `dry_run=false` value that should never reach C1 in the first place.
If it does, C1 must reject fail-closed, never silently switch to a
real submit path. C2 (a separate, later, explicitly-authorized phase)
is the only place a broker-mutating call is ever allowed to exist.

## Phase C structure (per the roadmap agreed before this freeze)

```
B9 Execution Eligibility (SEALED)
    -> C1.1 ExecutionRequest + Safety Gate + Dry-Run: collision-check + frozen contract (THIS DOC)
    -> C1.2 Immutable ExecutionRequest, safety gate, dry-run adapter (implementation)
    -> C1.3 Audit event/read model, reconciliation state model, regression/seal
    -> C1 SEALED
    -> C2 Broker Submit Adapter (HELD pending explicit authorization)
```

## Collision check (read-only, against the real repo — no guessing from names)

Full findings (verified by direct file reads, not inference):

- **`ExecutionRequest`, `ExecutionPolicy`, `ExecutionSafetyGate`,
  `ExecutionAttempt`, `ExecutionAudit`, `ExecutionReconciliation`,
  `execution_request_id`, `execution_request_hash`** — do not exist
  anywhere in the repo. Clean names, safe to mint.
- **`CTrade`/`OrderSend`/`HistorySelect`/`HistoryDealGet*`/`OrderGet*`**
  — zero real call sites anywhere in the codebase, including tests.
  Every occurrence of these names is inside a comment or a structural
  "must NOT call this" test assertion.
- **`ExecutionResult`** (`Core/MLQuantAI_ExecutionResult.mqh`) and
  **`ExecutionEvent`** (`Infrastructure/EventStore/MLQuantAI_ExecutionEvent.mqh`)
  are real, dormant, Phase-A/pre-B contract structs — `{success,
  ticket, retcode, requested_price, fill_price, slippage_points,
  reason, execution_schema_version}` and `{base, correlation_id,
  ticket, retcode, requested_price, fill_price, slippage_points, lot}`
  respectively — both assume a real broker response (`ticket`,
  `retcode`, `fill_price`). Zero call sites anywhere.
  **Decision: SUPERSEDED, not reused.** C1 dry-run has no broker
  response of any kind — fabricating a `ticket`/`retcode`/`fill_price`
  on a dry run, even as zeros, risks an audit reader mistaking it for
  a real submission outcome. `ExecutionRequest`/`DryRunExecutionResult`/
  `ExecutionAuditRecord` (below) are new, C1-specific, non-broker-result
  shapes. `ExecutionResult`/`ExecutionEvent` remain untouched and
  available for C2 to evaluate/extend for real broker submit/fill —
  that decision is explicitly deferred to C2, not made here.
- **`correlation_id`** already exists, live, sealed: a field on
  `TradeCandidate` (`Core/MLQuantAI_TradeCandidate.mqh:48`, `""` until
  a real submission), a field on `LifecycleEvent`, and generated via
  `Ids_CorrelationId(candidateId, submitAttempt=1)`
  (`Core/MLQuantAI_Ids.mqh`). `Infrastructure/MLQuantAI_BrokerReconciliation.mqh`
  already searches `PositionGetString(POSITION_COMMENT)` for it. This
  is the broker-facing position-tag identifier — a different concept
  from `execution_request_id` (the audit-record identity, see below).
  Both are carried on `ExecutionRequest`.
- **`SafeMode_IsActive()`/`SafeMode_AllowNewCandidates()`**
  (`Infrastructure/EventStore/MLQuantAI_SafeModeState.mqh`) — real,
  live, sealed. The Safety Gate's system-level check reuses this
  directly; C1 never re-implements or shadows it.
- **`RiskPlan.risk_plan_id/plan_hash/lot_size/risk_amount/
  planned_entry/planned_sl/planned_tp`** — confirmed exact canonical
  field names (`Core/MLQuantAI_RiskPlan.mqh`). `lot`/`risk_money` are
  Phase-A compatibility shadow fields, never used by new code per that
  file's own header.
- **`EligibilityDecision.eligibility_decision_id/eligibility_decision_hash`**
  (`Execution/MLQuantAI_EligibilityContract.mqh`) — confirmed
  `EligibilityDecision_EmitDecisionAndWireLifecycle` never drives any
  lifecycle transition on `ELIGIBLE` (only `REJECTED` ->
  `CANDIDATE_REJECTED_BY_RISK`). Nothing today moves an eligible
  candidate to `CANDIDATE_SUBMITTED` — that gap is what C1/C2 exist to
  fill (C1 stops short of actually filling it — see the state-machine
  section below).
- **`ENUM_CANDIDATE_STATE`/`StateMachine_CanTransition`**
  (`Core/MLQuantAI_StateMachine.mqh`) — `CREATED -> SUBMITTED ->
  {EXECUTED, REJECTED_BY_BROKER, ERROR}` is already fully specified
  and enforced. `EventTypeForCandidateState()`
  (`Core/MLQuantAI_TradeCandidate.mqh`) already maps every one of
  these states to a sealed `ENUM_EVENT_TYPE` member. Zero real
  production call sites drive any of `SUBMITTED`/`EXECUTED`/
  `REJECTED_BY_BROKER`/`ERROR` today (only a synthetic smoke test in
  `MLQuantAI.mq5` does, using `REASON_SUBMITTED_OK`/`REASON_BROKER_REJECT`,
  both already real `ENUM_REASON_CODE` values).
- **`ENUM_EVENT_TYPE`** tail (`Core/MLQuantAI_Enums.mqh`) — confirmed
  `EVENT_TYPE_ORDER_SUBMITTED`/`_ORDER_FILLED`/`_ORDER_REJECTED`/
  `_POSITION_CLOSED`/`_TRADE_OUTCOME_LABELED` already exist, dormant,
  reserved, unclaimed, with their own doc comment: *"schema locked
  now, nothing produces these until Phase B's Execution Engine
  exists."* **Decision: NOT reused by C1.** These five are reserved
  exclusively for C2's real broker facts (`TRADE_OUTCOME_LABELED` in
  particular already belongs to B8.2's realized-outcome labeling and
  must not be touched). C1 mints two new, append-only event types
  instead (see below). Current true tail:
  `EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED` (B9 Commit 2).
- **`ENUM_REASON_CODE`** (`Core/MLQuantAI_ReasonCodes.mqh`) — current
  tail is `REASON_AI_ABSTAIN`, then the `REASON_COUNT` sentinel. A new
  `REASON_EXECUTION_SUBMIT_DISABLED` is appended directly before
  `REASON_COUNT`, matching how `REASON_AI_ABSTAIN` was appended for
  B8.5.
- **`TradeCandidate`** (`Core/MLQuantAI_TradeCandidate.mqh`) — exact
  fields confirmed: `candidate_id`, `candidate_hash`, `correlation_id`
  (`""` until a real submission — C1 must never write to this field),
  `side` (`ENUM_ORDER_TYPE`), `state`.
- **`Ids_Deterministic(prefix, keyParts)`** (`Core/MLQuantAI_Ids.mqh`)
  is the sealed primitive every `Ids_*Id` function uses — join the
  exact upstream identity fields with `|`, hash, prefix. Closest
  precedent: `Ids_CorrelationId(candidateId, submitAttempt=1)`, which
  already solved "same candidate, multiple submit attempts" the same
  shape `execution_request_id` needs.
- **`BrokerReconciliation.mqh`** — real, live, already wired into
  `MLQuantAI.mq5`'s `OnInit`. Read-only MT5 position queries only
  (`PositionsTotal`/`PositionGetTicket`/`PositionSelectByTicket`/
  `PositionGetString`), no mutation. Always reconciles trivially today
  (zero `CANDIDATE_EXECUTED` candidates exist). Not touched by C1 —
  C1 produces no `CANDIDATE_EXECUTED` candidates for it to reconcile
  against.

## Decisions locked for this freeze

### 1. `ExecutionResult`/`ExecutionEvent` — superseded, not reused

New, C1-owned, non-broker-result types only: `ExecutionRequest`,
`DryRunExecutionResult`, `ExecutionAuditRecord`. The dormant Phase-A/
pre-B `ExecutionResult`/`ExecutionEvent` stay exactly as they are,
untouched, available for C2 to evaluate separately.

### 2. `execution_request_id` and `correlation_id` — both carried, different roles

```
execution_request_id
= immutable execution-intent/audit identity
  Ids_ExecutionRequestId(candidate_id, eligibility_decision_id,
                          ai_decision_id, risk_plan_id,
                          execution_policy_version)

correlation_id
= intended broker-side correlation tag (for C2's later use)
  Ids_CorrelationId(candidate_id, submit_attempt)
```

C1 computes and persists both, but:
- never sends `correlation_id` to a broker (C1 talks to no broker at
  all),
- never mutates `TradeCandidate.correlation_id` (stays `""` until a
  real C2 submission),
- never binds a ticket/deal/position to either identifier.

`submit_attempt` is carried on `ExecutionRequest` from the start —
**always `1` in C1**, never auto-incremented, never retried. This
reserves the deterministic-retry shape for C2 without C1 exercising
it.

### 3. Dry-run is purely observational — never `CANDIDATE_SUBMITTED`

```
EligibilityDecision (ELIGIBLE)
    -> ExecutionRequest
    -> SafetyGate
    -> DryRunExecutionResult / ExecutionAuditRecord
    -> candidate remains CANDIDATE_CREATED
```

C1 never emits `CANDIDATE_SUBMITTED`, never emits any dormant
`EVENT_TYPE_ORDER_*`, never calls `StateMachine_Transition`/
`EventStore_LogTransition` for any candidate-state change at all.
`CANDIDATE_SUBMITTED` means a real broker submission attempt happened
— that semantic is reserved for C2, strictly after a request has
actually reached a broker adapter.

C1.3's reconciliation model (reserved vocabulary only, not implemented
in C1.1) works from audit intent/result, never a live broker claim:

```
EXECUTION_AUDIT_DRY_RUN_ACCEPTED
EXECUTION_AUDIT_DRY_RUN_REJECTED
EXECUTION_AUDIT_SUBMISSION_NOT_ATTEMPTED
```

`UNKNOWN`/`FOUND`/`NOT_FOUND` are NOT used in C1 — those are live
broker-reconciliation claims, reserved for C2.

### 4. Event types — new, append-only, C1-specific

```
EVENT_TYPE_EXECUTION_REQUEST_CREATED
   = immutable intent constructed from an ELIGIBLE decision
     (does NOT mean submitted)
EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED
   = result of safety-gate/dry-run evaluation
     (does NOT mean a broker accepted/rejected anything)
```

Both appended after `EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED` (the
current true tail), as `SystemEvent`s (same family as
`RISK_PLAN_CREATED`/`AI_DECISION_CREATED`/`EXECUTION_ELIGIBILITY_DECIDED`
— an execution request/dry-run result is a derived audit artifact tied
to a candidate, not itself a lifecycle transition). The dormant
`EVENT_TYPE_ORDER_SUBMITTED`/`_ORDER_FILLED`/`_ORDER_REJECTED`/
`_POSITION_CLOSED` remain untouched, reserved for C2's real broker
facts. `EVENT_TYPE_TRADE_OUTCOME_LABELED` is B8.2's and is not touched
by C1 or C2.

## Frozen struct shapes

```cpp
enum ENUM_EXECUTION_ENVIRONMENT_MODE
{
   EXECUTION_ENV_NONE,
   EXECUTION_ENV_TESTER,
   EXECUTION_ENV_DEMO,
   EXECUTION_ENV_LIVE
};

enum ENUM_SAFETY_GATE_DECISION
{
   SAFETY_GATE_NONE,
   SAFETY_GATE_ACCEPTED,
   SAFETY_GATE_REJECTED
};

struct ExecutionPolicy
{
   string execution_policy_version;

   ENUM_EXECUTION_ENVIRONMENT_MODE environment_mode; // TESTER | DEMO | LIVE
   bool   dry_run;                 // C1: MUST be true; false is rejected fail-closed, never overridden
   bool   manual_approval_required;

   // Reserved for C2 - shape only, actual allowed values/enforcement
   // frozen separately with explicit user authorization before C2
   // opens. C1 does not enforce these beyond carrying them verbatim.
   string account_allowlist;
   string symbol_allowlist;
   double max_volume;
   double max_exposure;
   double max_deviation_points;
   string allowed_order_types;
};

struct ExecutionRequest
{
   string execution_request_schema_version; // MLQUANTAI_EXECUTION_REQUEST_SCHEMA_C1_V1

   string execution_request_id;   // identity - Ids_ExecutionRequestId(...)
   string execution_request_hash; // content

   // Lineage - every field copied verbatim from its real upstream
   // source, never recomputed here.
   string candidate_id;
   string candidate_hash;
   string risk_plan_id;
   string plan_hash;
   string ai_decision_id;
   string ai_decision_hash;
   string eligibility_decision_id;
   string eligibility_decision_hash;

   string execution_policy_version;

   string correlation_id;   // Ids_CorrelationId(candidate_id, submit_attempt)
   int    submit_attempt;   // C1: always 1, never auto-incremented

   // Order intent - copied verbatim from RiskPlan/TradeCandidate,
   // never recomputed. Immutable once built: a changed intent means a
   // brand new ExecutionRequest with a new identity/hash, never an
   // in-place edit.
   ENUM_ORDER_TYPE side;
   double          planned_entry;
   double          planned_sl;
   double          planned_tp;
   double          lot_size;
};

struct DryRunExecutionResult
{
   string dry_run_result_schema_version; // MLQUANTAI_DRY_RUN_RESULT_SCHEMA_C1_V1

   string execution_request_id;   // verbatim - links back to the request
   string execution_request_hash; // verbatim

   ENUM_SAFETY_GATE_DECISION decision;
   ENUM_REASON_CODE          reason_code;
};
```

`ExecutionAuditRecord` (the persisted, replay-verifiable pairing of an
`ExecutionRequest` + its `DryRunExecutionResult`, analogous to how
B9 Commit 2 persisted raw `EligibilityContext` evidence inside
`EXECUTION_ELIGIBILITY_DECIDED`'s own payload) is specified in detail
in C1.3, not here — C1.1 only reserves that a persisted audit record
exists and that it must carry enough raw evidence for replay to verify
`execution_request_hash` independently, following the same pattern
B9 Commit 2 already proved out. Re-deriving that exact payload shape
before C1.2's real struct code exists would be designing ahead of the
contract it depends on.

## Identity/hash payloads (frozen)

```cpp
string Ids_ExecutionRequestId(string candidateId, string eligibilityDecisionId,
                                string aiDecisionId, string riskPlanId,
                                string executionPolicyVersion)
{
   string key = candidateId + "|" + eligibilityDecisionId + "|" +
                aiDecisionId + "|" + riskPlanId + "|" + executionPolicyVersion;
   return Ids_Deterministic("EXECREQ", key);
}
```

`ExecutionRequest_HashPayload` (content, excludes
`execution_request_schema_version`/`execution_request_id` — identity,
not content, same rule every prior contract in this project follows):

```
candidate_id | candidate_hash | risk_plan_id | plan_hash |
ai_decision_id | ai_decision_hash | eligibility_decision_id |
eligibility_decision_hash | execution_policy_version |
correlation_id | submit_attempt | side | planned_entry |
planned_sl | planned_tp | lot_size
```

## Safety Gate behavior (frozen, non-negotiable)

`SafetyGate_Evaluate(const ExecutionRequest &request, const
ExecutionPolicy &policy, DryRunExecutionResult &outResult)`:

1. Fail-closed on a malformed request: any empty
   `execution_request_id`/`candidate_id`/`risk_plan_id`/`ai_decision_id`/
   `eligibility_decision_id` -> `SAFETY_GATE_REJECTED`.
2. **`policy.dry_run == false` -> `SAFETY_GATE_REJECTED` /
   `REASON_EXECUTION_SUBMIT_DISABLED`, unconditionally.** No fallback,
   no override, no environment-variable escape hatch, no code path
   that produces a fake broker result instead. This is the single most
   important gate in this contract — it is what keeps C1 permanently
   incapable of an accidental live submit even if a caller's policy
   input is wrong.
3. `SafeMode_AllowNewCandidates() == false` -> `SAFETY_GATE_REJECTED` /
   a system-level reason (reuses the existing Safe Mode gate, does not
   reimplement it).
4. Otherwise (both gates above pass) -> `SAFETY_GATE_ACCEPTED` /
   `REASON_NONE`.

Under every branch above, `SafetyGate_Evaluate` never calls
`OrderSend`/`CTrade`/any position-mutating API, never transitions
`candidate.state`, never mutates `ExecutionRequest`/`ExecutionPolicy`.

## Scope guard (frozen for all of C1)

- No `OrderSend`, no `CTrade` submit/modify/close, no market/pending
  order placement, no broker-side position/order mutation of any kind
  — enforced by a structural inspection test, same technique every
  prior phase's "no live reads" proof has used.
- No `CANDIDATE_SUBMITTED` or any other `ENUM_CANDIDATE_STATE`
  transition anywhere in C1.
- No use of the dormant `EVENT_TYPE_ORDER_SUBMITTED`/`_ORDER_FILLED`/
  `_ORDER_REJECTED`/`_POSITION_CLOSED` — reserved for C2.
- No mutation of `TradeCandidate.correlation_id`.
- No `submit_attempt` auto-increment or retry logic of any kind.
- `ExecutionRequest` is immutable once built — no in-place field edit
  anywhere; a changed intent is a new request with a new identity/hash.
- Only an `ELIGIBLE` `EligibilityDecision` may become an
  `ExecutionRequest` — a `REJECTED` decision never reaches this layer
  (it already terminated at `CANDIDATE_REJECTED_BY_RISK` in B9).
- `ExecutionPolicy`'s reserved C2 fields (`account_allowlist`/
  `symbol_allowlist`/`max_volume`/`max_exposure`/
  `max_deviation_points`/`allowed_order_types`) are carried
  verbatim by C1 but not enforced by it — their real allowed values
  and enforcement logic are frozen separately, with explicit user
  authorization, before C2 opens.
- No resurrection/reuse of the dormant `ExecutionResult`/
  `ExecutionEvent` structs.

## C1.2 / C1.3 preview (not frozen in detail here)

- **C1.2**: implements `ExecutionRequest_Build`, `SafetyGate_Evaluate`,
  and the deterministic ID/hash functions above, against real B9
  `EligibilityDecision` (`ELIGIBLE` only) + `RiskPlan` + `AIDecision`
  + `TradeCandidate` inputs. Still zero broker mutation.
- **C1.3**: `EVENT_TYPE_EXECUTION_REQUEST_CREATED`/
  `EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED` emission,
  `ExecutionAuditRecord` persistence/replay/projection (full payload
  shape frozen at that point, once C1.2's real structs exist to
  reference), the `EXECUTION_AUDIT_*` reconciliation-state read model,
  and the full-chain regression/seal proof — same three-commit shape
  every prior B-phase has used.

## Environment policy (reserved, not chosen here)

C1 never needs to choose demo/live because C1 cannot submit regardless
of `environment_mode`. `ExecutionPolicy` reserves the field shape;
C2 freezes the actual allowed values, with the user's explicit
authorization, as a separate, later step.
