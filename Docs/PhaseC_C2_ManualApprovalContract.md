# C2 manual-approval contract (frozen before code)

This document covers the full design: registry, event schema,
standalone approval script, projection, and C2 gate integration. It
was built and confirmed in two rounds:

```
Round 1 (🟢 shipped, PASSED 38/38, merged to mlquantai):
    Event schema (ManualApprovalGrant struct)
    ManualApproval_Grant() - durable write only
    Tests/MLQuantAI_ManualScript_GrantApproval.mq5 - standalone, human-run

Round 2 (🟢 frozen, IMPLEMENTING - this round):
    ManualApprovalProjection - the rebuild/read side
    ManualApprovalRegistry_HasValidApproval() - the query interface
    Readiness wiring (ManualApprovalReadiness_IsReady/_StartupRebuild)
    C2 gate integration (BrokerSubmissionEnvironmentLock_Evaluate, its
        third amendment)
    MLQuantAI.mq5 OnInit wiring
    BrokerSubmission_Submit() wiring fix - see "A real wiring gap
        found while implementing this round" below
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

## C2 gate integration (frozen shape - status: IMPLEMENTING)

A new check inside `BrokerSubmissionEnvironmentLock_Evaluate`
(`Execution/MLQuantAI_EnvironmentLockGate.mqh`, its third amendment):
evaluated after the existing five checks, mandatory and unconditional
for the real-submit path (independent of
`ExecutionPolicy.manual_approval_required`'s own value, per the
resolution above).

**Reason codes** (corrected wording - the user's own fix, replacing an
earlier draft that mislabeled this as "two new reason codes"):

```
- REASON_EXECUTION_AUDIT_NOT_READY
  reused when the approval registry has not rebuilt successfully
  or is not ready.

- REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED
  new append-only reason code for a ready registry with no matching,
  unexpired valid approval.
```

Only `REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED` is genuinely new.

## Approval timing boundary (frozen, per the user's explicit instruction)

Approval must be evaluated against a single captured `asOf` timestamp
per gate evaluation - the gate reads `TimeCurrent()` exactly once, at
the point `HasValidApproval()` is called, and reuses that one value for
the entire check. This prevents a non-deterministic outcome where an
approval could be treated as valid at the start of a check and expired
by the end of the same check.

**Fail-closed on an invalid clock**: if `TimeCurrent() <= 0`, the gate
rejects closed (same reason as "registry not ready" -
`REASON_EXECUTION_AUDIT_NOT_READY` - a clock this codebase cannot trust
is equivalent to a registry it cannot trust). MQL5's own reference
documents `TimeCurrent()` as "the last known server time, time of the
last quote receipt" but does not document its return value for a
terminal that has never connected/received a quote - per this
project's "never trust an undocumented case" discipline, `<= 0` is
treated as that undocumented case, mirroring the same defensive
pattern `BrokerSubmission_BuildTradeRequest` already uses for
`bid <= 0.0 || ask <= 0.0`.

**Valid through `RecordAttempt()`, not just at gate start**: the
`HasValidApproval()` check is placed as the LAST check the gate
performs before returning `SAFETY_GATE_ACCEPTED` - no other check, I/O,
or work happens between a successful `HasValidApproval()` and the
caller's own, immediately-following `BrokerSubmission_RecordAttempt()`
call (see `BrokerSubmission_Submit`'s own sequence: gate evaluation ->
build -> `RecordAttempt` -> `OrderSend`, all synchronous, no yield
point in between). This ordering is what makes "valid at the moment
`HasValidApproval()` runs" equivalent to "valid immediately before
`RecordAttempt()`" - there is no window in this codebase's synchronous
call chain for the two to diverge.

## Approval scope and gate order (frozen, per the user's explicit instruction)

`HasValidApproval()` answers only "does a matching, unexpired approval
exist" - it does NOT itself re-check `SubmissionAttemptRegistry_HasAttempt()`.
That check is not skipped: it is already mandatory and already runs
earlier in the same synchronous evaluation, inherited from
`BrokerSubmissionGate_Evaluate` (C2.2/C2.3's own durable idempotency
check, `REASON_DUPLICATE_EVENT`) - `BrokerSubmissionEnvironmentLock_Evaluate`
chains that function first and only proceeds to its own checks
(including this one) on an inherited `ACCEPTED`. Duplicating the
attempt check inside the approval registry would be redundant, not
extra-safe - the frozen, single source of truth for "has this id
already been attempted" stays `SubmissionAttemptRegistry_HasAttempt()`
alone, per this contract's own "consumption boundary" section above.

The full, orchestrated real-submit gate order, spanning both the
already-sealed layers and this round's new one (recommended by the
user, now frozen):

```
1. C1/C2 existing structural and environment checks   (SafetyGate_Evaluate,
                                                         BrokerSubmissionGate_Evaluate's
                                                         own environment/account-mode check)
2. Submission-audit registry readiness                 (BrokerSubmissionGate_Evaluate,
                                                         REASON_EXECUTION_AUDIT_NOT_READY)
3. No prior submission attempt                          (BrokerSubmissionGate_Evaluate,
                                                         SubmissionAttemptRegistry_HasAttempt,
                                                         REASON_DUPLICATE_EVENT)
4. Manual-approval registry readiness                    (NEW, this round,
                                                         REASON_EXECUTION_AUDIT_NOT_READY)
5. Capture asOf once                                      (NEW, this round)
6. HasValidApproval(all five identity fields, asOf)        (NEW, this round,
                                                         REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED)
7. RecordAttempt                                            (BrokerSubmission_Submit,
                                                         unchanged)
8. OrderSend boundary                                        (BrokerSubmission_Submit,
                                                         unchanged)
```

Steps 1-3 are entirely pre-existing (`BrokerSubmissionGate_Evaluate`,
inherited via the chain) - this round adds only steps 4-6, as the
environment-lock gate's own third amendment, plus the trade-server/
terminal/account/expert/volume checks the environment-lock round
already added between steps 3 and 4 (unchanged, this round does not
reorder them - the new approval check is appended after them, not
interleaved).

## A real wiring gap found while implementing this round, now also in scope

**Finding**: `BrokerSubmission_Submit()` (`MLQuantAI_BrokerSubmissionAdapter.mqh`
- the only function anywhere in this codebase that calls the real
`OrderSend()`) calls `BrokerSubmissionGate_Evaluate()` directly, NOT
`BrokerSubmissionEnvironmentLock_Evaluate()`. This means the five
checks the environment-lock round already froze (trade-server
allowlist, `TERMINAL_TRADE_ALLOWED`, `ACCOUNT_TRADE_ALLOWED`,
`ACCOUNT_TRADE_EXPERT`, minimum volume) have never actually gated a
real submission - and the manual-approval check this round adds to
`BrokerSubmissionEnvironmentLock_Evaluate` would be equally bypassed
if this were left unfixed. This predates this round (it is a gap from
the environment-lock round itself, only surfaced now), and was
confirmed by the user as in scope to fix here rather than deferred.

**Fix, authorized by the user**: `BrokerSubmission_Submit()` is amended
to call `BrokerSubmissionEnvironmentLock_Evaluate()` instead of
`BrokerSubmissionGate_Evaluate()` directly, taking a new
`EnvironmentLockPolicy` parameter. Its two existing call sites
(`Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5`,
`Tests/MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5`) are updated to pass
a policy value. This is the one sealed-adjacent file this round touches
beyond pure addition - `BrokerSubmissionAdapter.mqh` has already been
amended twice before (C2.2's own two prior amendments), following the
same "amend, real-run-confirm, re-merge" discipline each time.

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
    MLQuantAI_BrokerSubmissionAuditProjection.mqh,
    MLQuantAI_BrokerSubmissionAuditReadiness.mqh - untouched.
This round DOES amend (user-authorized, both a third/further amendment
    to files already amended before under this project's established
    discipline): MLQuantAI_EnvironmentLockGate.mqh (its third amendment
    - the new manual-approval check), MLQuantAI_BrokerSubmissionAdapter.mqh
    (wiring BrokerSubmission_Submit to the environment-lock entry point -
    the wiring-gap fix above), MLQuantAI.mq5 (OnInit wiring for
    ManualApproval_StartupRebuild). Everything else in this round
    (ManualApprovalProjection, readiness, registry query) is a new,
    additive file.
```
