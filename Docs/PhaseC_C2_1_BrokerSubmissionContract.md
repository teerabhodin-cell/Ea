# Phase C2.1 — Broker Submission Contract (frozen, read-only, no code)

**Status: FROZEN, no code yet.** Opens after C1 FULLY SEALED (215/215,
all real MetaEditor runs). This is the first phase in the entire
project that will eventually call a real broker-mutating MT5 API
(`OrderSend`). **C2.1 itself is documentation only** — no `OrderSend`
call, no `OnTradeTransaction` handler, no broker-mutating test run of
any kind is authorized by this commit. C2.2 (implementation) requires
a separate, explicit confirmation naming the resolved permitted
environment, per the user's own gate.

## Non-negotiables carried over from C1 (still true for all of C2)

- Market `TRADE_ACTION_DEAL` orders only — no `OrderModify`, no
  position close, no pending orders, no retry (`submit_attempt` stays
  `1` through all of C2.2 and C2.3).
- Raw `OrderSend(MqlTradeRequest, MqlTradeResult)` — no `CTrade`, no
  Standard Library include, for controlled capture and a minimal
  dependency surface.
- Consumes only an `ACCEPTED` `DryRunExecutionResult` + its paired
  `ExecutionRequest` — never re-derives eligibility or risk.

## A real architectural conflict, found and resolved before any code exists

The lifecycle originally proposed — "local `OrderSend()` failure ->
`CANDIDATE_ERROR` directly" — is **illegal** under the already-sealed
`StateMachine_CanTransition` (`Core/MLQuantAI_StateMachine.mqh`, frozen
since Phase A, never touched by any later phase): `CANDIDATE_CREATED`
may only transition to `{ROUTED_OUT, MERGED, REJECTED_BY_ARBITRATOR,
REJECTED_BY_AI, REJECTED_BY_RISK, EXPIRED, SUBMITTED}` — `ERROR` is
reachable **only** from `SUBMITTED`. Redefining the sealed state
machine is off the table (the same rule every prior phase in this
project has followed without exception).

**Resolution** (turns on what `OrderSend()`'s own return value actually
means, per MQL5's own documented semantics): `OrderSend()` returning
`false` means the request never reached the trade server at all (a
local/client-side dispatch failure — invalid parameters caught before
send, connection failure, etc.). `OrderSend()` returning `true` means
the request **did** reach the server and got some real response
(`result.retcode`), whether accepted, rejected, or ambiguous. This
maps cleanly onto the sealed state machine without bending it:

**Superseded by the second amendment below** (kept for history - the
mandatory step order and the UNKNOWN branch changed):

```
final pre-submit safety re-validation (every C1.2 gate, re-run FRESH -
    not trusted from the earlier ACCEPTED evaluation, which may be
    stale by the time actual submission code runs)
    |
    v
EXECUTION_SUBMISSION_ATTEMPTED   (audit SystemEvent - crossed the
    |                             final gate, no broker claim yet.
    |                             candidate.correlation_id = req.correlation_id
    |                             assigned here, persisted in this
    |                             event's own payload - first-ever
    |                             write to that field, C1 never
    |                             touched it. NO state transition.)
    v
OrderSend(request, result)
    |
    +-- returns FALSE (never reached the server):
    |       -> ORDER_SUBMISSION_ERROR (audit SystemEvent only)
    |       -> candidate.state stays CANDIDATE_CREATED - untouched.
    |          Nothing was actually submitted, so nothing in the
    |          candidate's own lifecycle has progressed. This also
    |          preserves real retry-ability for a later, separately-
    |          authorized retry commit - the candidate is still at a
    |          legitimately non-terminal state.
    |
    +-- returns TRUE (reached the server, got a real retcode):
            -> EventStore_LogTransition(candidate, CANDIDATE_SUBMITTED, ...)
               [legal: CREATED -> SUBMITTED, per the sealed table]
            -> classify result.retcode:
                 - explicit rejection retcode:
                       -> ORDER_REJECTED (audit SystemEvent, full
                          MqlTradeResult captured)
                       -> EventStore_LogTransition(candidate,
                          CANDIDATE_REJECTED_BY_BROKER, ...)
                          [legal: SUBMITTED -> REJECTED_BY_BROKER]
                 - accepted (TRADE_RETCODE_DONE/_DONE_PARTIAL) OR any
                   other/ambiguous retcode not explicitly classified
                   as a rejection:
                       -> ORDER_SUBMITTED (audit SystemEvent, full
                          MqlTradeResult captured)
                       -> candidate.state stays at CANDIDATE_SUBMITTED -
                          no further transition here. SUBMITTED is
                          explicitly non-terminal in the sealed
                          machine; this is its intended resting state
                          pending a LATER, separately-scoped
                          OnTradeTransaction-driven reconciliation
                          commit that alone may drive
                          CANDIDATE_EXECUTED. C2.2 never marks
                          EXECUTED from OrderSend's synchronous return -
                          per MQL5's own documentation, that return
                          value is not final fill truth.
```

This satisfies the user's real requirement — never claim the broker
accepted something merely because a local decision was made to try —
without redefining the sealed state machine: the NEW
`EXECUTION_SUBMISSION_ATTEMPTED` audit event (not a lifecycle
transition at all) is what precisely captures "about to call, no
claim," fully decoupled from the state-machine's own separate,
already-frozen `SUBMITTED` semantics.

## C2.2 second amendment — mandatory sequence + UNKNOWN branch (frozen, supersedes the diagram above)

Found via real user review, two real issues in the already-PASSED,
already-merged first amendment:

1. **A real regression, not a pre-existing gap.** The first
   amendment's `BrokerSubmission_ProcessSendResult` split accidentally
   moved the `EXECUTION_SUBMISSION_ATTEMPTED` durable write to run
   *after* the real `OrderSend()` call, since the wrapper called
   `OrderSend()` first and only handed control to `ProcessSendResult`
   afterward - directly violating the ordering this doc's own diagram
   requires. Fixed by extracting `BrokerSubmission_RecordAttempt()`,
   called by the thin wrapper strictly *before* `OrderSend()`.
2. **`CANDIDATE_SUBMITTED` must mean a genuine acknowledgment, not
   merely "the API call returned true."** The original diagram folded
   every ambiguous retcode (`TRADE_RETCODE_CONNECTION`,
   `TRADE_RETCODE_PLACED`, any unrecognized code) into the same
   `CANDIDATE_SUBMITTED` resting state as a real `TRADE_RETCODE_DONE`
   acceptance. `TRADE_RETCODE_CONNECTION` in particular can appear even
   when the terminal itself never actually reached the trade server -
   transitioning the candidate as if it had is misleading. Fixed with a
   new `SUBMISSION_STATUS_UNKNOWN` (no candidate transition at all,
   exactly like the `OrderSend()==false` case).

The frozen mandatory sequence, replacing the diagram above:

```
1. Final pre-submit gate re-validation + request construction
2. BrokerSubmission_RecordAttempt()
     - durable EXECUTION_SUBMISSION_ATTEMPTED write (no broker fields
       of any kind in its payload - a pre-side-effect audit fact)
     - only on a successful write: candidate.correlation_id assigned
       (first-ever write to that field), in-session idempotency guard
       marked
3. If step 2 fails: STOP. No OrderSend. No candidate mutation. No
   idempotency mark that claims an attempt happened.
4. OrderSend(request, result) - the real, irreversible boundary call
5. Persist the immediate result, per BrokerSubmission_ClassifyRetcode's
   now-three-way split:

   OrderSend() == false (a provable local/pre-dispatch failure -
   GetLastError(), captured immediately, is the MQL5-documented
   mechanism that proves this; the C2.2 implementation always has this
   proof, so this branch is never downgraded to UNKNOWN for
   conservatism - the evidence already exists):
       -> ORDER_SUBMISSION_ERROR (audit SystemEvent, terminal_last_error
          captured)
       -> candidate.state stays CANDIDATE_CREATED - untouched, retry-
          ability preserved

   OrderSend() == true, TRADE_RETCODE_DONE / _DONE_PARTIAL (the ONLY
   genuine positive acknowledgment):
       -> EventStore_LogTransition(candidate, CANDIDATE_SUBMITTED, ...)
          [legal: CREATED -> SUBMITTED]
       -> ORDER_SUBMITTED (audit SystemEvent, full MqlTradeResult
          captured)
       -> candidate.state stays CANDIDATE_SUBMITTED - resting state
          pending a LATER, separately-authorized OnTradeTransaction
          reconciliation commit

   OrderSend() == true, an explicit rejection retcode:
       -> EventStore_LogTransition(candidate, CANDIDATE_SUBMITTED, ...)
          [legal: CREATED -> SUBMITTED - the mandatory waypoint, since
          REJECTED_BY_BROKER is reachable only from SUBMITTED, never
          CREATED, under the sealed state machine]
       -> ORDER_REJECTED (audit SystemEvent, full MqlTradeResult
          captured)
       -> EventStore_LogTransition(candidate, CANDIDATE_REJECTED_BY_BROKER, ...)
          [legal: SUBMITTED -> REJECTED_BY_BROKER]

   OrderSend() == true, TRADE_RETCODE_CONNECTION / TRADE_RETCODE_PLACED
   / any other unlisted or unrecognized retcode (SUBMISSION_STATUS_UNKNOWN -
   neither an explicit acceptance nor an explicit rejection; no real
   acknowledgment happened):
       -> EXECUTION_SUBMISSION_UNKNOWN (audit SystemEvent, full
          MqlTradeResult captured)
       -> candidate.state stays CANDIDATE_CREATED - NO transition,
          exactly like the OrderSend()==false case. No retry logic
          exists in C2.2/C2.3 - any future retry policy must mint a
          new execution_request_id/attempt identity and requires its
          own explicit, separate authorization; it must never silently
          reuse this one.
```

Every `EventStore_LogSystem`/`EventStore_LogTransition` call in this
sequence keeps the same non-rollback discipline every prior emitter in
this project already follows: once a write succeeds, it is never
rolled back, even if a later write in the same call fails.

## Event vocabulary (frozen)

Two new, append-only `ENUM_EVENT_TYPE` members (after
`EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED`, the current true tail):

```
EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED
   = the immutable intended request has crossed the final pre-submit
     gate; no broker claim of any kind yet.
EVENT_TYPE_ORDER_SUBMISSION_ERROR
   = OrderSend() itself returned false, or an unclassifiable local/API
     failure - the request never reached the trade server.
```

The dormant `EVENT_TYPE_ORDER_SUBMITTED`/`EVENT_TYPE_ORDER_REJECTED`
(reserved since B1, confirmed no conflicting semantics beyond their
bare names) are reused as-is for the post-`OrderSend` genuine-
acceptance and explicit-rejection cases respectively.
`EVENT_TYPE_ORDER_FILLED` stays untouched, reserved for the later,
separately-authorized `OnTradeTransaction` reconciliation commit -
C2.2 never emits it.

**C2.2 second amendment:** one more append-only `ENUM_EVENT_TYPE`
member added, after `EVENT_TYPE_ORDER_SUBMISSION_ERROR` (the new true
tail):

```
EVENT_TYPE_EXECUTION_SUBMISSION_UNKNOWN
   = OrderSend() returned true but result.retcode is neither an
     explicit acceptance nor an explicit rejection - no real
     acknowledgment happened. Never folded into EVENT_TYPE_ORDER_SUBMITTED,
     which would falsely imply one. No candidate-lifecycle transition.
```

## Reason codes

Phase A's own dormant "execution" `ENUM_REASON_CODE` block
(`Core/MLQuantAI_ReasonCodes.mqh`) already anticipated most of this
moment and is reused verbatim: `REASON_SUBMITTED_OK` (accepted),
`REASON_BROKER_REJECT` (generic explicit rejection),
`REASON_INVALID_STOPS`/`REASON_INSUFFICIENT_MARGIN`/`REASON_REQUOTE`
(specific rejection retcodes, where `result.retcode` maps cleanly),
`REASON_ERROR_INTERNAL` (local/API failure).

**C2.2 amendment (post-PASSED, real user review):** one new value WAS
needed after all - `REASON_EXECUTION_SUBMISSION_AMBIGUOUS`. The
original "zero new values" claim above missed a real gap:
`OrderSend()` can return `true` while `result.retcode` is
`TRADE_RETCODE_CONNECTION` (the terminal itself detected no connection
to the trade server - not a positive acknowledgment from anyone) or
any other retcode not on the explicit-rejection list. Classifying that
as `REASON_SUBMITTED_OK` would be a false claim. The candidate's state
transition is unaffected by this fix - it still legally transitions to
and stays at `CANDIDATE_SUBMITTED` either way, per the sealed state
machine and this doc's own lifecycle diagram above; only the reason
code attached to that resting state changes, from a false "OK" claim
to an honest "ambiguous, no real acknowledgment" one.

## C2.2 amendment — testable orchestration split

The event-sequencing/state-transition logic around the `OrderSend()`
call (everything from `EXECUTION_SUBMISSION_ATTEMPTED` through the
final classification and lifecycle transition) originally lived
entirely inside the one function nobody may call from the automated
suite, leaving it with zero automated coverage - a real gap, found via
real user review after C2.2's first PASSED run. Split into
`BrokerSubmission_ProcessSendResult()` (pure - takes
`orderSendReturned`/`terminalLastError`/`tradeResult` as
already-computed input parameters, never calls `OrderSend` itself, so
every branch is exercisable by the automated suite with fabricated
inputs and zero risk to a real account) and `BrokerSubmission_Submit()`
(now a thin wrapper: calls the real `OrderSend()`, captures
`GetLastError()` immediately per MQL5's own requirement, then
delegates everything else to `ProcessSendResult`). `Submit()` remains
the only function in this codebase that calls the real `OrderSend()`.

## `ExecutionSubmissionResult` (frozen shape, new struct)

Not a reuse of the dormant `ExecutionResult` (it lacks lineage fields
and conflates submit-acknowledgement with fill truth). Not touched by
`fill_price`/`slippage_points` in C2.2 — those are transaction-derived
facts owned exclusively by the later `OnTradeTransaction` reconciliation
commit.

```cpp
enum ENUM_SUBMISSION_STATUS
{
   SUBMISSION_STATUS_NONE,
   SUBMISSION_STATUS_ERROR,      // OrderSend() returned false
   SUBMISSION_STATUS_REJECTED,   // explicit server rejection retcode
   SUBMISSION_STATUS_SUBMITTED,  // TRADE_RETCODE_DONE/_DONE_PARTIAL only - a genuine positive acknowledgment
   SUBMISSION_STATUS_UNKNOWN     // C2.2 second amendment: neither an explicit acceptance nor an explicit rejection - no candidate transition
};

struct ExecutionSubmissionResult
{
   string execution_submission_result_schema_version;

   string execution_request_id;   // verbatim - links back to the request
   string execution_request_hash; // verbatim
   string correlation_id;         // verbatim - the same value written to candidate.correlation_id
   int    submit_attempt;         // always 1 in C2

   ENUM_SUBMISSION_STATUS submission_status;
   bool                   order_send_returned;   // OrderSend()'s own bool return
   int                    terminal_last_error;    // GetLastError() when order_send_returned == false
   uint                   retcode;                 // result.retcode
   int                    retcode_external;         // result.retcode_external
   long                   request_id;                // result.request_id - SESSION-SCOPED ONLY, see below
   ulong                  order_ticket;                // result.order
   ulong                  deal_ticket;                  // result.deal
   double                 requested_price;               // the price actually sent in the request
   double                 observed_submit_price;          // result.price (server-reported), NOT a fill guarantee
   datetime               submission_timestamp;             // TimeCurrent() at the OrderSend() call

   ENUM_REASON_CODE reason_code;
};
```

`request_id` is captured for correlation/debugging only — MQL5
documents it as restarting per terminal session, distinct from and
never a substitute for `order_ticket`/`deal_ticket`. Never used as a
durable business identity or lookup key.

## Environment authorization (tightened, per user confirmation)

```
Allowed:
  AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO
  (exact match required - not merely "not REAL")

Rejected, all fail-closed:
  ACCOUNT_TRADE_MODE_REAL
  ACCOUNT_TRADE_MODE_CONTEST
  any unrecognized/unexpected account mode value
  ExecutionPolicy.environment_mode == EXECUTION_ENV_LIVE
  a policy/runtime mismatch of any kind
```

`ExecutionPolicy.environment_mode == EXECUTION_ENV_TESTER` (the value
itself stays valid in C1.1's frozen enum) is **not** granted real
submission authority in C2.2 — Strategy Tester's exact interaction
with `ACCOUNT_TRADE_MODE` has not been verified against real MQL5
documentation in this session, and this contract does not assert
unverified platform behavior. Tester submission support stays held
until that is separately proven and explicitly re-authorized. Only a
real `ACCOUNT_TRADE_MODE_DEMO` account may receive an actual
`OrderSend` call in C2.2.

## Order construction (frozen)

`symbol = _Symbol` (re-read fresh immediately before send; reject if
it differs from the symbol the accepted dry-run observed, or if the
fresh bid/ask is invalid/non-positive), `volume = req.lot_size`
(immutable — never silently normalized/widened; a broker-side volume
constraint failure must reject, never mutate), `type = req.side`,
`price = SymbolInfoDouble(_Symbol, side==BUY?SYMBOL_ASK:SYMBOL_BID)`
(fresh market price at submission time — never `req.planned_entry`,
which reflects eligibility-evaluation time and may be stale by actual
submission), `sl = req.planned_sl`, `tp = req.planned_tp` (both
immutable, same rule as volume), `deviation = policy.max_deviation_points`
(immutable), `comment = req.correlation_id` (21 characters, safely
under MT5's comment limit — but a broker/server may still alter
comments, so reconciliation must never depend on the comment alone;
bind `MLQUANTAI_MAGIC_NUMBER` plus ticket/deal/request evidence too),
`magic = MLQUANTAI_MAGIC_NUMBER` (new constant, none exists yet in
this project — checked in every C2-owned reconciliation path, not just
at submission).

## Final pre-submit gate re-validation (frozen)

Immediately before constructing the request, every C1.2 gate is
re-evaluated fresh against current runtime state — never trusted from
the earlier `ACCEPTED` evaluation, which may be stale by the time
submission code actually runs: Safe Mode, the real account-mode check
above, account/symbol allowlist, volume/exposure/deviation caps,
manual approval, `dry_run` (must still be `true` — C2.2 inherits the
exact same fail-closed rule C1.2 already froze), `execution_request_hash`/
lineage integrity, and identity/idempotency (this exact
`execution_request_id` has not already been submitted in this session).

## Scope guard (frozen)

```
C2.1 is documentation only - no OrderSend call anywhere.
No OnTradeTransaction handler exists or is authorized.
No CANDIDATE_EXECUTED / EVENT_TYPE_ORDER_FILLED in C2.2 - reserved for
    a later, separately-scoped and separately-authorized reconciliation
    commit.
No retry logic - submit_attempt stays 1.
No OrderModify / position close / pending orders.
No CTrade / Standard Library include.
No broker-mutating test run of any kind until C2.2 is itself explicitly
    authorized, naming the resolved permitted environment:
      Environment: a real ACCOUNT_TRADE_MODE_DEMO account (Tester held)
      Account mode: DEMO only
      Live/contest: rejected
      Manual approval mechanism: exact durable design (not yet frozen -
        ExecutionPolicy.manual_approval_required already exists from
        C1.2 and unconditionally fails closed since no approval
        mechanism exists yet; C2.2 inherits this unchanged unless a
        real mechanism is separately designed and authorized)
```

## C2.3 addendum — Audit Projections + Reconciliation + Regression/Seal

Opens after C2.2 PASSED (real MetaEditor run, including the second
amendment), merged to `mlquantai`. Strictly additive and read-only over
the durable `EXECUTION_SUBMISSION_ATTEMPTED`/`ORDER_SUBMISSION_ERROR`/
`ORDER_SUBMITTED`/`ORDER_REJECTED`/`EXECUTION_SUBMISSION_UNKNOWN`
events C2.2 already writes - no broker query, no broker mutation, no
candidate-lifecycle transition, no event append here. No
`MLQUANTAI_*_SCHEMA_*` constant is needed: `EXECUTION_SUBMISSION_ATTEMPTED`'s
payload has no schema-version field of its own (see
`ExecutionSubmissionAttempt_ToExtraJson`), and all four outcome events
reuse `execution_submission_result_schema_version` verbatim from
`ExecutionSubmissionResult`.

### Durable idempotency - C2.3's first deliverable (frozen, per user confirmation)

A real gap the user identified: C2.2's `BrokerSubmissionGate`
idempotency check (`BrokerSubmissionGate_HasAlreadyAttempted`) is an
in-session, resettable registry only - it cannot prevent a resubmission
of the same `execution_request_id` across a terminal restart, since
nothing durable backs it. Building a durable version *inside* C2.2
would mean duplicating `EXECUTION_SUBMISSION_ATTEMPTED`-parsing logic
that C2.3's own `SubmissionAttemptProjection` is about to build anyway
- rejected, same "no duplicate parsers" rule this whole addendum
already follows. Agreed sequencing:

```
C2.2 (already fixed, this amendment): RecordAttempt-before-send
    ordering + in-memory guard only. Real-submit stays disabled
    (smoke test input defaults false) regardless.

C2.3 first deliverable: SubmissionAttemptProjection (the canonical,
    single EventStore replay parser for these events) PLUS a frozen
    query interface other layers may consume without knowing any
    parsing internals:

      bool SubmissionAttemptRegistry_HasAttempt(string executionRequestId);
      bool SubmissionAttemptRegistry_IsUnresolved(string executionRequestId);

    Semantics: any durable EXECUTION_SUBMISSION_ATTEMPTED without a
    conclusive, persisted broker-state resolution (i.e. no matching
    ORDER_SUBMITTED/ORDER_REJECTED/ORDER_SUBMISSION_ERROR/
    EXECUTION_SUBMISSION_UNKNOWN yet) -> HasAttempt = true,
    IsUnresolved = true. For initial safety the simplest policy is
    stronger still: ANY historical attempt for a given
    execution_request_id - resolved or not - blocks all automatic
    resubmission of that exact id. A future manual-retry policy, if
    ever authorized, must mint a brand new execution_request_id/attempt
    identity and require its own explicit approval - never silently
    reuse an already-attempted one.

C2.2 integration follow-up patch (separately scoped, after C2.3's
    interface exists): BrokerSubmissionGate consults
    SubmissionAttemptRegistry_HasAttempt/_IsUnresolved as an additional
    check - no parsing/replay logic added to C2.2 itself, just a call
    into C2.3's already-frozen interface. Rejects any request already
    marked attempted/unresolved. Only after this patch lands is a real
    demo-submit capability considered safe to actually exercise via the
    opt-in smoke test.
```

### A real design tension, found and resolved before any code exists

C1.3 froze a hard rule for this project: a projection rebuild must be a
**single, sequential, interleaved pass**, never a naive two-pass design,
because a two-pass rebuild silently fails to catch a completion
appearing before its own request in file order (by the time pass 2
checks completions, pass 1 has already registered every request in the
whole file, regardless of position). Naively re-applying that same
"never stage" rule all the way down to C2.3 would require either
editing the sealed, PASSED `MLQuantAI_ExecutionAuditProjection.mqh`
(C1.3), or duplicating its `ExecutionRequestProjection`/
`DryRunResultProjection` parsing logic wholesale in a new file - both
rejected, the same way editing the sealed `SafetyGate.mqh` was rejected
in C2.2.

**Resolution**: re-read C1.3's own rebuild function
(`ExecutionAuditProjection_RebuildFromFile`) - it already stages ITS
OWN upstream dependency as a black-box gate:
`EligibilityDecisionProjectionReport eligReport =
EligibilityDecisionProjection_RebuildFromFile(fileName);` runs to
completion, across the *whole* file, *before* C1.3's own interleaved
pass ever starts. C1.3 never interleaves down into B9's own event
types - only the two sibling types it introduces itself
(`EXECUTION_REQUEST_CREATED`/`EXECUTION_DRY_RUN_COMPLETED`) get true
interleaving. This is an already-established, working precedent, not a
gap: ordering violations are only ever enforced between the specific
sibling pair a single commit introduces together; a reference to an
older, already-sealed layer is checked for existence (orphan check)
only, never for relative ordering.

C2.3 follows the identical, already-precedented shape: calls C1.3's
own `ExecutionAuditProjection_RebuildFromFile` unmodified, as a
black-box gate, across the whole file, first. `MLQuantAI_ExecutionAuditProjection.mqh`
is never edited. C2.3's own two new sibling types
(`EXECUTION_SUBMISSION_ATTEMPTED` and the outcome quartet
`ORDER_SUBMISSION_ERROR`/`ORDER_SUBMITTED`/`ORDER_REJECTED`/
`EXECUTION_SUBMISSION_UNKNOWN`) are then
processed in ONE new, genuinely interleaved pass in a new file - an
outcome line's `execution_request_id` must already have a matching
attempt applied earlier in *this same new pass*, or it fails the whole
rebuild closed as an orphan/ordering violation, exactly C1.3's own
rule, now applied to the pair C2.3 itself introduces. An attempt line's
reference back to `ExecutionRequestProjection`/`DryRunResultProjection`
(already fully populated by the staged C1.3 gate) is an orphan-only
check - it must exist, with a matching hash, and its `DryRunResultProjection`
must contain at least one `SAFETY_GATE_ACCEPTED` record for that exact
request (never merely "any" record - a submission built from a
`REJECTED` dry-run would be a real, separate bug this check exists to
catch) - never a relative-ordering check against C1's own events.

### New projections (frozen shape)

`SubmissionAttemptProjection` - **0..N records per `execution_request_id`,
never deduped**, same rule `DryRunResultProjection` already established
(a legitimate future retry after a local `OrderSend()` failure, even
though C2.2 itself implements no retry logic, would produce a second
real attempt for the same id - this must not collapse to 1). Keyed by
the event's own durable `source_sequence_number`. `submit_attempt` must
equal `1` (C2.2/C2.3's own frozen invariant - no retry logic exists
yet even though the shape tolerates a future one).

`SubmissionOutcomeProjection` - same 0..N, never-deduped,
`source_sequence_number`-keyed shape. One record per
`ORDER_SUBMISSION_ERROR`/`ORDER_SUBMITTED`/`ORDER_REJECTED`/
`EXECUTION_SUBMISSION_UNKNOWN` line, `submission_status` set from
which of the four the line's own `type` field says (a mismatch between
the line's `type` and its own `submission_status` payload field is
corruption, rejected). Outcome invariants enforced per status,
mirroring `DryRunResultProjection`'s own decision/reason_code
invariant: `ERROR` requires `order_send_returned == false`;
`SUBMITTED`/`REJECTED`/`UNKNOWN` all require `order_send_returned ==
true`; `SUBMITTED`'s `reason_code` must be `REASON_SUBMITTED_OK`
exactly (never a lesser claim); `REJECTED`'s `reason_code` must be one
of `{REASON_BROKER_REJECT, REASON_INVALID_STOPS, REASON_INSUFFICIENT_MARGIN,
REASON_REQUOTE}`; `UNKNOWN`'s `reason_code` must be
`REASON_EXECUTION_SUBMISSION_AMBIGUOUS`; never `REASON_NONE`/`REASON_ERROR_INTERNAL`
on any of the three `orderSendReturned==true` statuses.

### Reconciliation (frozen shape)

`BrokerSubmissionReconciliationReport` - one row per distinct
`execution_request_id` with at least one applied `SubmissionAttemptProjection`
record. Status is computed from the **latest** (highest
`source_sequence_number`) matching `SubmissionOutcomeProjection`
record, if any: `NO_OUTCOME` (an attempt exists with no outcome yet -
the legitimate non-rollback edge case if a session ends exactly
between `EXECUTION_SUBMISSION_ATTEMPTED` and its outcome write, same
class of edge case C1.2's own non-rollback discipline already
documents), `ERRORED`, `REJECTED`, `SUBMITTED`, or `UNKNOWN`. Never a
sixth, softer status - an id with zero attempts at all simply never
appears in this report (it belongs to C1.3's own `ExecutionReconciliationReport`
instead, unaffected and untouched by C2.3).

### Scope guard (frozen)

```
Read-only over the event store - no OrderSend/broker query/broker
    mutation anywhere in this commit.
No edit to any sealed file (MLQuantAI_ExecutionAuditProjection.mqh,
    MLQuantAI_SafetyGate.mqh, MLQuantAI_BrokerSubmissionGate.mqh,
    MLQuantAI_BrokerSubmissionBuilder.mqh,
    MLQuantAI_BrokerSubmissionAdapter.mqh) - strictly additive, a new
    file only.
No OnTradeTransaction handler, no EVENT_TYPE_ORDER_FILLED, no
    CANDIDATE_EXECUTED anywhere - still reserved for a later,
    separately-authorized reconciliation commit.
Full B9 + C1 + C2 regression re-run required before "C2 FULLY SEALED"
    is declared, same discipline the "C1 FULLY SEALED" checkpoint
    already set.
```
