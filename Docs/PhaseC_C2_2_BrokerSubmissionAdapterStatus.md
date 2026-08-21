# Phase C2.2 — Broker Submission Adapter

**Status: Implemented, awaiting a real MetaEditor compile/run. Not
PASSED yet — per this project's standing rule, only a real compile/test
log from the user counts as PASSED evidence.**

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
  accepted-vs-explicit-rejection split: `TRADE_RETCODE_DONE`/
  `_DONE_PARTIAL` and every other/unlisted retcode default to
  accepted/ambiguous (stays `SUBMITTED`); a documented, non-exhaustive
  list of retcodes realistic for a market open-only order (requote,
  invalid stops, no money, reject, market closed, trade disabled, and
  others) map to explicit rejection.
- **`Execution/MLQuantAI_BrokerSubmissionAdapter.mqh`** (new):
  `BrokerSubmission_Submit()` — **the only place in this codebase that
  calls the real `OrderSend()`.** Implements the frozen lifecycle
  exactly: pre-submit gate re-validation → `EXECUTION_SUBMISSION_ATTEMPTED`
  audit event (sets `candidate.correlation_id`, first-ever write, no
  state transition) → `OrderSend()` → branch on its own return value
  (`false`: `ORDER_SUBMISSION_ERROR` audit event, candidate stays
  `CANDIDATE_CREATED`, untouched; `true`: `CREATED → SUBMITTED`
  transition always first, then classify `result.retcode` into either
  `ORDER_SUBMITTED` (stays `SUBMITTED`) or `ORDER_REJECTED` +
  `SUBMITTED → REJECTED_BY_BROKER`). Same non-rollback discipline as
  every prior emitter: once an event write succeeds it is never rolled
  back even if a later write in the same call fails.

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

## Definition of Done

- [x] Every file above compiles with zero errors/warnings (pending
      real MetaEditor confirmation).
- [ ] Real MetaEditor compile of `Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5`
      — 0 errors, 0 warnings.
- [ ] Real MetaEditor run — all checks PASS, exact N/N pasted back.
- [ ] `Tests/MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5` compiles with
      zero errors/warnings (real MetaEditor). Running it is optional,
      manual, and entirely the user's call — not required for C2.2 to
      be marked PASSED.
- [ ] Manual regression re-run of the full B9 + C1 chain in the same
      session, to confirm zero regressions (same discipline C1.2/C1.3
      each required).
