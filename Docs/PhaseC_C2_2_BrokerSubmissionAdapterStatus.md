# Phase C2.2 — Broker Submission Adapter

**Status: AMENDED, awaiting a real MetaEditor re-run. Original 73/73
PASSED run (2026-08-21) covered gate/build/classification only - a real
user review after that run found a genuine classification bug and a
real test-coverage gap in the merged code (see "C2.2 amendment"
below). Not re-declared PASSED until a fresh real MetaEditor run
confirms the amended suite.**

Implements `Docs/PhaseC_C2_1_BrokerSubmissionContract.md` (frozen
before code). Opens after C2.1 frozen and the user's explicit,
multi-step authorization: "ยืนยัน เริ่ม C2 ได้เลย" (C2 go-ahead),
Strategy Tester/Demo-only scope, raw `OrderSend` over `CTrade`, a real
`ACCOUNT_TRADE_MODE` cross-check required, and — most recently — that
the automated regression suite must never call real `OrderSend`
("แยก unit test (gate/construction logic) ออกจาก real-submit smoke
test").

## What this commit adds

- **`Core/MLQuantAI_VersionRegistry.mqh`**: `MLQUANTAI_MAGIC_NUMBER`
  (`773700`) — the fixed identity every `MqlTradeRequest.magic` this EA
  ever sends carries, now also visible in `VersionRegistry_AsJsonFragment()`
  for audit purposes. Arbitrary but fixed: once a real order has ever
  been sent under this value it must never change.
- **`Core/MLQuantAI_ContractVersions.mqh`**: `MLQUANTAI_EXECUTION_SUBMISSION_RESULT_SCHEMA_C2_V1`.
- **`Core/MLQuantAI_Enums.mqh`**: `EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED`/
  `EVENT_TYPE_ORDER_SUBMISSION_ERROR` (append-only, after
  `EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED`); `ENUM_SUBMISSION_STATUS`
  (`NONE`/`ERROR`/`REJECTED`/`SUBMITTED`) + `ToString`/`FromString`.
- **`Execution/MLQuantAI_ExecutionSubmissionContract.mqh`** (new):
  `ExecutionSubmissionResult` struct + `_Init`, the exact frozen field
  list from the C2.1 contract — no `fill_price`/`slippage_points`
  anywhere (those are `OnTradeTransaction`-owned facts, out of scope).
- **`Execution/MLQuantAI_BrokerSubmissionGate.mqh`** (new):
  `BrokerSubmissionGate_Evaluate()` — every C1.2 gate re-run fresh via
  the sealed, **unmodified** `SafetyGate_Evaluate()`, plus two C2-owned
  checks layered on top only when the inherited gate already
  `ACCEPTED`: (1) `policy.environment_mode == EXECUTION_ENV_DEMO` AND
  the real `AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO`,
  both required (a mismatch either way — including a policy that says
  `EXECUTION_ENV_LIVE`/`EXECUTION_ENV_TESTER` on a real demo account —
  fails closed, per the contract's "policy/runtime mismatch of any
  kind" clause); (2) an in-session idempotency registry
  (`BrokerSubmissionGate_HasAlreadyAttempted`/`_MarkAttempted`/`_Reset`)
  rejecting a repeat `execution_request_id`. Zero new
  `ENUM_REASON_CODE` values — reuses `REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED`
  and `REASON_DUPLICATE_EVENT`, per the frozen contract.
- **`Execution/MLQuantAI_BrokerSubmissionBuilder.mqh`** (new, pure,
  unit-testable, **no `OrderSend` call anywhere**):
  `BrokerSubmission_BuildTradeRequest()` constructs the `MqlTradeRequest`
  per the frozen "Order construction" section (fresh `_Symbol`/bid-ask
  read, reject on symbol drift or invalid price; `volume`/`sl`/`tp`/
  `deviation` immutable from the request/policy; `magic`/`comment` set;
  `type_filling = ORDER_FILLING_IOC`/`type_time = ORDER_TIME_GTC` as a
  minimal, flagged, **not part of the frozen field list** implementation
  default). `BrokerSubmission_ClassifyRetcode()` implements the frozen
  accepted-vs-explicit-rejection split: only `TRADE_RETCODE_DONE`/
  `_DONE_PARTIAL` earn `REASON_SUBMITTED_OK` (a genuine positive
  acknowledgment); every other unlisted/unrecognized retcode (including
  `TRADE_RETCODE_CONNECTION` and `TRADE_RETCODE_PLACED`) still
  classifies as accepted/ambiguous (stays `SUBMITTED`, unchanged), but
  is tagged `REASON_EXECUTION_SUBMISSION_AMBIGUOUS` instead - see the
  "C2.2 amendment" section below; a documented, non-exhaustive list of
  retcodes realistic for a market open-only order (requote, invalid
  stops, no money, reject, market closed, trade disabled, and others)
  map to explicit rejection.
- **`Execution/MLQuantAI_BrokerSubmissionAdapter.mqh`** (new):
  `BrokerSubmission_ProcessSendResult()` — pure orchestration, takes
  `orderSendReturned`/`terminalLastError`/`tradeResult` as
  already-computed input, never calls `OrderSend` itself. Implements
  the frozen lifecycle exactly: `EXECUTION_SUBMISSION_ATTEMPTED` audit
  event (sets `candidate.correlation_id`, first-ever write, no state
  transition) → branch on `orderSendReturned` (`false`:
  `ORDER_SUBMISSION_ERROR` audit event, candidate stays
  `CANDIDATE_CREATED`, untouched; `true`: `CREATED → SUBMITTED`
  transition always first, then classify `tradeResult.retcode` into
  either `ORDER_SUBMITTED` (stays `SUBMITTED`) or `ORDER_REJECTED` +
  `SUBMITTED → REJECTED_BY_BROKER`). Same non-rollback discipline as
  every prior emitter: once an event write succeeds it is never rolled
  back even if a later write in the same call fails.
  `BrokerSubmission_Submit()` — **the only place in this codebase that
  calls the real `OrderSend()`.** Now a thin wrapper: pre-submit gate
  re-validation → build → real `OrderSend()` (capturing
  `GetLastError()` immediately, per MQL5's own requirement) → delegates
  to `ProcessSendResult`.

## Unit test / real-submit smoke test split (per the user's explicit instruction)

- **`Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5`** (new,
  automated regression suite): exercises `BrokerSubmissionGate_Evaluate`,
  `BrokerSubmission_BuildTradeRequest`, `BrokerSubmission_ClassifyRetcode`,
  `ExecutionSubmissionResult` Init/JSON serialization. **Never calls
  `BrokerSubmission_Submit` or `OrderSend`** — it includes
  `MLQuantAI_BrokerSubmissionAdapter.mqh` only to reach the pure JSON
  helpers, and that inclusion never executes the real-submit function.
  Environment-dependent assertions (real account-mode cross-check,
  idempotency-inside-gate) branch on the real
  `AccountInfoInteger(ACCOUNT_TRADE_MODE)` so the check count stays
  fixed regardless of which account type the user's terminal happens to
  be attached to when compiling.
- **`Tests/MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5`** (new, **manual,
  explicitly opt-in, never run automatically**): the only script that
  calls `BrokerSubmission_Submit`/real `OrderSend`. Gated behind an
  `input bool I_Understand_This_May_Open_A_Real_Position = false`
  that must be manually set `true`, plus its own independent
  `ACCOUNT_TRADE_MODE_DEMO` check before even building a request. Uses
  the same synthetic CRT-detection fixture as the unit suite, so its
  `planned_sl`/`planned_tp` sit on a ~100-104 price scale unrelated to
  real `XAUUSD` prices — a broker rejection
  (`TRADE_RETCODE_INVALID_STOPS` or similar) is the expected, safe
  outcome, while still proving the real gate → `OrderSend` → classify →
  event/lifecycle wiring end-to-end. If the broker ever does accept it,
  the script prints an explicit warning that a real position is open
  and must be closed manually — C2 has no close-position scope.

## Scope guard carried forward from C2.1 (unchanged)

No `OnTradeTransaction` handler. No `CANDIDATE_EXECUTED`/
`EVENT_TYPE_ORDER_FILLED`. No retry logic (`submit_attempt` stays `1`).
No `OrderModify`/position close/pending orders. No `CTrade`/Standard
Library include anywhere in this commit.

## Fixed (found via the user's real MetaEditor run, not self-review)

`Test_Build_SymbolMismatchRejects` failed 1/73 on the first real run:
`outTradeRequest.symbol` was not `""` after a rejected build, even
though the function returns before ever assigning `.symbol`. Root
cause: `ZeroMemory()` on `MqlTradeRequest`/`MqlTradeResult` is unsafe —
both structs contain `string` members (`symbol`/`comment`), and MQL5's
`string` type is a reference-counted handle, not raw bytes, so
raw-zeroing its memory does not reliably leave it as `""`. Fixed by
replacing both `ZeroMemory` calls with manual field-by-field zero-init
helpers (`MqlTradeRequest_ZeroInit` in
`MLQuantAI_BrokerSubmissionBuilder.mqh`, `MqlTradeResult_ZeroInit` in
`MLQuantAI_BrokerSubmissionAdapter.mqh`) that explicitly set every
numeric field to `0` and every string field to `""`.

## C2.2 amendment (post-PASSED, found via real user review, not self-review)

The first 73/73 PASSED run only proved gate/build/classification logic
in isolation and confirmed the opt-in smoke test correctly self-aborts
- it never proved anything about the orchestration/event-sequencing
logic around a real `OrderSend()` call, because that logic lived
entirely inside the one function the automated suite may never call.
A real review surfaced two genuine issues in the merged, PASSED code:

1. **Classification bug**: `BrokerSubmission_ClassifyRetcode` defaulted
   *every* unlisted/unrecognized retcode - including
   `TRADE_RETCODE_CONNECTION` - to `REASON_SUBMITTED_OK`. `OrderSend()`
   can return `true` while `result.retcode == TRADE_RETCODE_CONNECTION`
   (the terminal itself detected no connection to the trade server) -
   that is not a positive acknowledgment, and `REASON_SUBMITTED_OK` was
   a false claim. Fixed by adding `REASON_EXECUTION_SUBMISSION_AMBIGUOUS`
   (`Core/MLQuantAI_ReasonCodes.mqh`) and reserving `REASON_SUBMITTED_OK`
   for `TRADE_RETCODE_DONE`/`_DONE_PARTIAL` only. The candidate's state
   transition is unchanged - still legally `CANDIDATE_SUBMITTED` either
   way, per the sealed state machine.
2. **Zero test coverage of the OrderSend-adjacent orchestration**: split
   `BrokerSubmission_Submit` into pure `BrokerSubmission_ProcessSendResult`
   (takes `orderSendReturned`/`tradeResult` as input, fully testable) +
   a thin real-`OrderSend`-only wrapper. Added six new branch-coverage
   tests: `true+DONE`, `true+DONE_PARTIAL`, `true+`explicit-rejection
   retcode, `false+`error, `true+CONNECTION`, `true+`unknown retcode -
   none call real `OrderSend`.

One point in the original review was evaluated and NOT implemented as
proposed: "no `CANDIDATE_SUBMITTED` until a positive acknowledgment"
is illegal under the sealed `StateMachine_CanTransition`
(`REJECTED_BY_BROKER` is reachable only from `SUBMITTED`, never
`CREATED`) and would have reopened the exact conflict C2.1 already
resolved. `SUBMITTED` is a non-terminal "awaiting confirmation" state,
not a success claim - the fix above corrects the *reason code*
attached to that state, not the state transition itself.

## Definition of Done

- [x] Every file above compiles with zero errors/warnings (real
      MetaEditor, confirmed for the pre-amendment version).
- [x] Real MetaEditor run of the pre-amendment suite — 73/73 ALL PASS
      (reproduced twice, same session, 2026-08-21).
- [x] `Tests/MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5` compiles with
      zero errors/warnings (real MetaEditor, confirmed - script ran and
      correctly self-aborted since the confirmation input was left at
      its default `false`). Actually exercising a real `OrderSend` call
      through it remains optional, manual, and entirely the user's
      call - not required for C2.2 to be marked PASSED.
- [ ] Real MetaEditor re-run of the amended suite (73 original checks,
      plus one `Test_Classify_UnlistedRetcodesDefaultToAmbiguousAccept`
      renamed/rewritten in place, plus one new `Test_Classify_OnlyDoneVariantsEarnSubmittedOk`,
      plus six new `Test_ProcessSendResult_*` functions) — exact N/N
      not yet known until a real compile/run confirms it.
- [ ] Full B9 + C1 regression re-run — deferred to the "C2 FULLY
      SEALED" checkpoint after C2.3, matching the precedent C1 itself
      set (the B9 regression re-run happened once, at the "C1 FULLY
      SEALED" declaration after C1.3 - not separately at each of
      C1.2/C1.3's own PASSED declarations).
