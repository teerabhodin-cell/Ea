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
bare names) are reused as-is for the post-`OrderSend` accepted/
ambiguous and explicit-rejection cases respectively.
`EVENT_TYPE_ORDER_FILLED` stays untouched, reserved for the later,
separately-authorized `OnTradeTransaction` reconciliation commit -
C2.2 never emits it.

## Reason codes — no new values needed

Phase A's own dormant "execution" `ENUM_REASON_CODE` block
(`Core/MLQuantAI_ReasonCodes.mqh`) already anticipated exactly this
moment and is reused verbatim: `REASON_SUBMITTED_OK` (accepted),
`REASON_BROKER_REJECT` (generic explicit rejection),
`REASON_INVALID_STOPS`/`REASON_INSUFFICIENT_MARGIN`/`REASON_REQUOTE`
(specific rejection retcodes, where `result.retcode` maps cleanly),
`REASON_ERROR_INTERNAL` (local/API failure). No collision, no
duplication - this vocabulary was frozen and dormant since Phase A
waiting for exactly this use.

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
   SUBMISSION_STATUS_SUBMITTED   // accepted or ambiguous - awaiting reconciliation
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
