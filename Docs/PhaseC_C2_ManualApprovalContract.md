# C2 manual-approval contract (frozen before code)

Per the user's explicit scope: this document covers the full design -
registry, event schema, standalone approval script, projection, and C2
gate integration - but only the **event schema + emission (write side)
+ standalone script** are implemented as code this round ("dry code" -
no broker mutation, no decision-making). The **projection (read side) +
gate integration** stay deferred, pending the user's explicit
confirmation of this contract.

```
This round (🟢 implemented as code):
    Event schema (ManualApprovalGrant struct)
    ManualApproval_Grant() - durable write only
    Tests/MLQuantAI_ManualScript_GrantApproval.mq5 - standalone, human-run

Deferred (🟡 after this contract is confirmed):
    ManualApprovalProjection - the rebuild/read side
    ManualApprovalRegistry_HasValidApproval() - the query interface
    Readiness wiring (ManualApprovalReadiness_IsReady/_StartupRebuild)
    C2 gate integration (BrokerSubmissionEnvironmentLock_Evaluate)
    MLQuantAI.mq5 OnInit wiring
```

## The real architectural tension, found and resolved before any code exists

`SafetyGate_Evaluate` (C1.2, sealed) already has a `manual_approval_required`
check: `if(policy.manual_approval_required) { REJECTED,
REASON_EXECUTION_MANUAL_APPROVAL_REQUIRED; return true; }` -
unconditional, no exceptions, because "no approval mechanism exists
yet" was true when C1.2 froze. No sealed file may be edited to make
this satisfiable, so `ExecutionPolicy.manual_approval_required` cannot
become the live approval mechanism itself.

**Resolution, confirmed by the user**: manual approval becomes an
entirely separate, C2-owned, always-mandatory gate for the real-submit
path - independent of `manual_approval_required`'s own value. For any
real C2 submission to ever pass C1.2 at all, `manual_approval_required`
must be `false` (unchanged, sealed behavior); the actual approval
requirement is enforced later, downstream, by a durable registry this
contract defines.

| Field / mechanism | Authority | C2 behavior |
|---|---|---|
| `ExecutionPolicy.manual_approval_required` | C1 dry-run policy (sealed) | Must be `false` for any C2 candidate path; `true` remains a C1 fail-closed rejection, unchanged |
| `ManualApprovalRegistry` | C2 real-submit authorization | Mandatory regardless of the C1 field's value |
| `EXECUTION_MANUAL_APPROVAL_GRANTED` | Durable human-authorization fact | Required before C2 broker mutation - written only by a human running the standalone script |

## Consumption boundary (frozen, per the user's explicit instruction)

`ManualApprovalRegistry` exposes **`HasValidApproval()` only** - a pure
read. It never marks an approval "consumed" or "used" itself.
**`SubmissionAttemptRegistry_HasAttempt()`** (already frozen, C2.3) is
the sole, authoritative consumption boundary: once a real attempt has
been durably recorded for an `execution_request_id`, that id can never
be resubmitted, approval or not - single-use falls out of the already-
existing durable idempotency mechanism for free, with no separate
single-use tracking needed in this contract.

## Event schema (frozen shape)

```cpp
struct ManualApprovalGrant
{
   string manual_approval_schema_version; // MLQUANTAI_MANUAL_APPROVAL_SCHEMA_C2_V1

   string execution_request_id;
   string execution_request_hash;
   string execution_policy_version;
   string candidate_id;
   string correlation_id;

   string   approver_identity;   // human-supplied, never empty - who granted this
   datetime approval_timestamp;  // TimeCurrent() when the script ran
   datetime approval_expiry;     // must be strictly after approval_timestamp
   string   approval_nonce;      // ManualApproval_NewNonce() - uniqueness/replay-conflict marker
};
```

Binds to FIVE identity fields, not just id+hash - `execution_policy_version`
and `candidate_id`/`correlation_id` are cross-checked too (per the
user's explicit "collision-check" instruction), so an approval can
never silently apply to a request that merely shares an id/hash by
coincidence but differs in policy lineage or candidate origin.

`EVENT_TYPE_EXECUTION_MANUAL_APPROVAL_GRANTED` (`Core/MLQuantAI_Enums.mqh`,
appended). `MLQUANTAI_MANUAL_APPROVAL_SCHEMA_C2_V1` (`Core/MLQuantAI_ContractVersions.mqh`,
appended).

## Standalone script (frozen shape, this round's own deliverable)

`Tests/MLQuantAI_ManualScript_GrantApproval.mq5` - a human runs this
manually, once, per approval, typing/pasting the target
`execution_request_id`/`execution_request_hash`/`execution_policy_version`/
`candidate_id`/`correlation_id` (observed from wherever the pending
candidate is displayed) plus their own `approver_identity` and a
validity window in minutes. Calls `ManualApproval_Grant()` against the
live event store. Never calls `OrderSend`/`CTrade`/any broker-mutating
API - this script's only side effect is one durable, append-only
event write, identical in kind to every other `*_EventEmission.mqh`
caller in this project.

## Registry query (frozen shape, deferred implementation)

```cpp
bool ManualApprovalRegistry_HasValidApproval(string executionRequestId, string executionRequestHash,
                                               string executionPolicyVersion, string candidateId,
                                               string correlationId, datetime asOf);
```

`asOf` is a caller-supplied parameter (not read internally via
`TimeCurrent()`) - keeps this function pure and deterministically
testable with fabricated clock values, same discipline every other C2
pure-evaluation function already follows. Returns `true` only if at
least one applied `ManualApprovalProjectionRecord` matches all five
identity fields exactly AND `record.approval_expiry > asOf`. Never
checks `SubmissionAttemptRegistry` itself - see "consumption boundary"
above.

## Projection apply-time validation (frozen, deferred implementation)

Mirrors `SubmissionAttemptProjection`'s own established shape: 0..N
records per `execution_request_id`, never deduped (a legitimate second
approval - e.g. after the first expired - is real audit history, not a
duplicate), keyed by the event's own `source_sequence_number`/
`source_log_event_id`. Stages C1.3's own `ExecutionAuditProjection_RebuildFromFile`
as a black-box gate first (unmodified), same precedent
`MLQuantAI_BrokerSubmissionAuditProjection.mqh` already established.

Rejects the whole rebuild closed on:
- Any of the five required fields empty, or `approval_expiry <=
  approval_timestamp` (structurally invalid payload).
- `approver_identity == ""` (an anonymous approval is not a real
  approval).
- Orphan: `execution_request_id` has no matching `ExecutionRequestProjection`
  record (staged from C1.3).
- Mismatch: the referenced `ExecutionRequestProjection` record's own
  `execution_request_hash`/`execution_policy_version`/`candidate_id`/
  `correlation_id` don't ALL match this grant's own claimed values -
  the full five-field collision-check the user asked for, not just
  id+hash.
- No `SAFETY_GATE_ACCEPTED` `DryRunResultProjection` record exists for
  that exact request/hash (same precedent as C2.3's own attempt orphan
  check - approving a request that was never dry-run-accepted would be
  a real bug).
- `log_event_id` collision with a different payload (fails closed, not
  a duplicate no-op) - identical to C2.3's own dedup rule.
- **`approval_nonce` collision across DIFFERENT `log_event_id`s** - two
  physically distinct grant events sharing the same nonce is itself a
  payload-conflict replay signal, fails the whole rebuild closed, even
  if every other field differs. An identical `log_event_id` replay
  (the ordinary idempotent-duplicate case) is unaffected by this rule.

`approval_expiry` in the past is **not** a rebuild failure - an expired
grant is still a structurally valid, real historical fact (a human did
approve it, once, for a window that has since lapsed). Expiry is
enforced only at `HasValidApproval()` query time, against the
caller-supplied `asOf`.

## Readiness (frozen shape, deferred implementation)

Same shape as `MLQuantAI_BrokerSubmissionAuditReadiness.mqh`:
`ManualApprovalReadiness_IsReady()` (fail-closed default `false`),
`ManualApproval_StartupRebuild(fileName)` (rebuilds the projection,
publishes readiness from THIS call's own `report.ok`, re-entrant - a
later failed call revokes a stale `true`). Wired into `MLQuantAI.mq5`'s
`OnInit`, alongside the existing `BrokerSubmissionAudit_StartupRebuild`
call, only once this contract is confirmed.

## C2 gate integration (frozen shape, deferred implementation)

A new check inside `BrokerSubmissionEnvironmentLock_Evaluate`
(`Execution/MLQuantAI_EnvironmentLockGate.mqh`, its third amendment):
evaluated after the existing five checks, mandatory and unconditional
for the real-submit path (independent of
`ExecutionPolicy.manual_approval_required`'s own value, per the
resolution above). Two new reason codes (not yet added -
`REASON_EXECUTION_MANUAL_APPROVAL_REGISTRY_NOT_READY` reuses
`REASON_EXECUTION_AUDIT_NOT_READY` instead, same "durable registry not
yet rebuilt this session" condition already named; only
`REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED` is genuinely new -
"registry consulted, no valid approval found").

## Scope guard (frozen, matches the user's explicit prohibition for this round)

```
No OrderSend/CTrade/smoke-test opt-in anywhere in this commit.
No OnTradeTransaction anywhere in this commit.
No HistoryDealGet*/HistoryOrderGet*/HistorySelect/PositionSelect or any
    broker-state query anywhere in this commit.
No candidate-lifecycle transition driven by broker facts.
No modify/close/pending-order API anywhere in this commit.
No sealed file edited: MLQuantAI_SafetyGate.mqh,
    MLQuantAI_BrokerSubmissionGate.mqh,
    MLQuantAI_EnvironmentLockGate.mqh (this round - gate integration
    deferred), MLQuantAI_BrokerSubmissionAuditProjection.mqh,
    MLQuantAI_BrokerSubmissionAuditReadiness.mqh, MLQuantAI.mq5 (this
    round - OnInit wiring deferred) - strictly additive, new files only.
```
