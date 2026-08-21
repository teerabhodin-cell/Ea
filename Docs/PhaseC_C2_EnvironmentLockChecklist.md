# C2 environment-lock checklist (frozen before code)

**Status: PASSED (26/26, real MetaEditor run, 2026-08-22).** No sealed
file touched in this commit - only new, additive files plus an
append-only `ENUM_REASON_CODE` addition, so no regression re-run was
required.

Per the user's explicit authorization: a final, read-only, consolidated
re-verification pass before a real `OrderSend()` call would ever be
authorized. This document freezes exactly which of the user's listed
assertions are already covered by an earlier, sealed gate (cited, never
re-implemented) versus genuinely new (five items, listed below) versus
explicitly deferred pending a separate freeze.

Scope guard (frozen, matches the user's own explicit prohibition for
this commit):

```
No smoke-test opt-in enabled anywhere in this commit.
No OrderSend call anywhere in this commit.
No OnTradeTransaction handler anywhere in this commit.
No broker order/deal/position history query anywhere in this commit.
No order modify/close/submit anywhere in this commit.
Pure evaluation only - read-only TerminalInfoInteger/AccountInfoInteger/
    AccountInfoString/SymbolInfoDouble calls, nothing else.
```

## The user's checklist, item by item

| # | User's item | Status | Implementation |
|---|---|---|---|
| 1 | `ACCOUNT_TRADE_MODE_DEMO` only; reject real/contest/unknown | Already covered | `BrokerSubmissionGate_Evaluate`'s real account-mode cross-check (C2.2) |
| 2 | Named account login allowlist | Already covered | `SafetyGate_Evaluate`'s `account_allowlist` (C1.2) |
| 3 | Named trade-server allowlist | **NEW** | `EnvironmentLockPolicy.trade_server_allowlist` vs `AccountInfoString(ACCOUNT_SERVER)` |
| 4 | Exact broker symbol allowlist | Already covered | `SafetyGate_Evaluate`'s `symbol_allowlist` (C1.2) |
| 5 | Safe Mode inactive | Already covered | `SafetyGate_Evaluate`'s Safe Mode check, first gate evaluated (C1.2) |
| 6 | Runtime policy DEMO only; reject TESTER/LIVE mismatch | Already covered | `BrokerSubmissionGate_Evaluate`'s `environment_mode == EXECUTION_ENV_DEMO` requirement (C2.2) |
| 7 | Explicit submit opt-in | Out of scope for this gate | Belongs to `Tests/MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5`'s own `I_Understand_This_May_Open_A_Real_Position` input - a manual smoke-test-script concern, not a general policy field this gate can check |
| 8 | Manual approval bound to request ID/hash, single-use | **DEFERRED** | See "Manual approval binding - explicitly deferred" below |
| 9 | Minimum/maximum volume | Max: already covered; Min: **NEW** | Max: `SafetyGate_Evaluate`'s `max_volume` (C1.2). Min: fresh `SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)` re-check (verified against real MQL5 docs, see below) |
| 10 | Planned-risk cap | Already covered | `SafetyGate_Evaluate`'s `max_planned_risk_amount` (C1.2) |
| 11 | Allowed market order type | Already covered | `SafetyGate_Evaluate`'s BUY/SELL-only check (C1.2) |
| 12 | Fixed magic number | Already covered, not policy-checked | `MLQUANTAI_MAGIC_NUMBER` is a fixed constant `BrokerSubmission_BuildTradeRequest` always stamps (C2.2) - a constant, not a runtime variable to validate |
| 13 | Valid fresh bid/ask | Already covered | `BrokerSubmission_BuildTradeRequest`'s `bid <= 0.0 \|\| ask <= 0.0` check (C2.2) - happens at request-construction time, deliberately not duplicated here |
| 14 | Maximum deviation | Already covered | `SafetyGate_Evaluate`'s `max_deviation_points` policy check (C1.2); the value itself is applied verbatim in `BrokerSubmission_BuildTradeRequest` |
| 15 | EventStore/projection/attempt registry readiness | Already covered | `BrokerSubmissionAuditReadiness_IsReady()`, consulted inside `BrokerSubmissionGate_Evaluate` (C2.2/C2.3 integration) |
| 16 | No prior attempt for the same request ID | Already covered | In-session `BrokerSubmissionGate_HasAlreadyAttempted` + durable `SubmissionAttemptRegistry_HasAttempt`, both inside `BrokerSubmissionGate_Evaluate` (C2.2/C2.3) |
| 17 | EA trading enabled (terminal-level "AutoTrading") | **NEW** | `TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)` |
| 18 | Account trade permission | **NEW** | `AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)` |
| 18b | Expert Advisor trade permission (distinct from general account permission) | **NEW** | `AccountInfoInteger(ACCOUNT_TRADE_EXPERT)` |

## Platform facts verified directly against the real MQL5 reference (fetched, not recalled)

- `ACCOUNT_TRADE_ALLOWED` (`AccountInfoInteger`): "Allowed trade for the
  current account." (`mql5.com/en/docs/constants/environment_state/accountinformation`)
- `ACCOUNT_TRADE_EXPERT` (`AccountInfoInteger`): "Allowed trade for an
  Expert Advisor." Distinct from `ACCOUNT_TRADE_ALLOWED` - an account
  can permit manual trading while denying EA-driven trading (or vice
  versa), so both are checked independently.
- `ACCOUNT_SERVER` (`AccountInfoString`): "Trade server name."
- `TERMINAL_TRADE_ALLOWED` (`TerminalInfoInteger`): "Permission to
  trade" - the terminal-level "AutoTrading" toggle.
- `SYMBOL_VOLUME_MIN` (`SymbolInfoDouble`): already a load-bearing field
  in this codebase (`Market/MLQuantAI_SymbolSpec.mqh`'s `volume_min`,
  enforced once already inside `Core/MLQuantAI_RiskSizing.mqh` at
  signal-time lot-size calculation) - this gate re-reads it fresh at
  submit-time rather than trusting that earlier, possibly-stale read,
  matching the "never trust an earlier evaluation" rule every other C2
  check already follows.

## Manual approval binding - explicitly deferred

The user's item 8 ("manual approval bound to request ID+hash and
single-use") describes a real approval-*mechanism* - not a runtime
assertion this gate can re-verify from already-existing data. No such
mechanism exists anywhere in this codebase today:
`ExecutionPolicy.manual_approval_required` (C1.1/C1.2) is a boolean
flag whose only frozen behavior is "if `true`, `SafetyGate_Evaluate`
rejects unconditionally with `REASON_EXECUTION_MANUAL_APPROVAL_REQUIRED`
- no approval mechanism exists yet" (C1.2's own frozen comment). Building
the actual binding (a token/approval record tied to one specific
`execution_request_id`+`execution_request_hash`, single-use, durably
recorded) is a genuinely new contract decision - identity/durability
shape, expiry, who/what may grant it, how it's revoked - on the same
order of complexity as C2.3's own `SubmissionAttemptRegistry`. Per this
project's "freeze contract before code" discipline, this stays out of
scope for the environment-lock commit and needs its own dedicated
freeze-then-implement round before real-submit authorization can rely
on it.

## New struct (frozen shape)

```cpp
struct EnvironmentLockPolicy
{
   string environment_lock_policy_version;
   string trade_server_allowlist; // comma-separated ACCOUNT_SERVER values; empty = unconfigured, fails closed
};
```

Deliberately NOT an addition to the frozen `ExecutionPolicy` struct
(C1.1) - that file stays untouched, per this project's "no sealed file
edited" discipline. A new, additive struct instead, the same pattern
`MLQuantAI_BrokerSubmissionAuditReadiness.mqh` already established this
phase.

## New function (frozen shape)

```cpp
bool BrokerSubmissionEnvironmentLock_Evaluate(const ExecutionRequest &request, const ExecutionPolicy &policy,
                                                const EnvironmentLockPolicy &lockPolicy, DryRunExecutionResult &outResult);
```

Chains `BrokerSubmissionGate_Evaluate()` first (unmodified, inherits
every earlier gate's verdict unchanged), then evaluates this file's own
five new checks, in this fixed order, only if the inherited verdict is
already `ACCEPTED`: trade-server allowlist → terminal trade permission
→ account trade permission → expert trade permission → minimum-volume
floor. First-match-wins, same discipline every earlier gate already
follows. Reuses `DryRunExecutionResult` as its own output type (no new
result struct needed - this function's job is exactly analogous to
every earlier gate's own "would this be allowed" verdict).

**Split for testability, same reason `BrokerSubmission_ProcessSendResult`
was split from `BrokerSubmission_Submit` in C2.2's own first
amendment**: the five new checks live in a separate,
`BrokerSubmissionGate_Evaluate`-independent function,
`EnvironmentLock_EvaluateNewChecks(request, lockPolicy, outResult)`
(assumes the caller already confirmed an ACCEPTED verdict). A test
terminal on a real, non-DEMO account would always have
`BrokerSubmissionGate_Evaluate` reject on environment before ever
reaching these five checks - the split makes them exercisable
regardless of the compiling terminal's own account mode.
`BrokerSubmissionEnvironmentLock_Evaluate` is the only function in this
file that calls `BrokerSubmissionGate_Evaluate` - the real-world entry
point.

## New reason codes (frozen, append-only)

`REASON_EXECUTION_SERVER_NOT_ALLOWED`,
`REASON_EXECUTION_TERMINAL_TRADE_DISABLED`,
`REASON_EXECUTION_ACCOUNT_TRADE_DISABLED`,
`REASON_EXECUTION_EXPERT_TRADE_DISABLED`,
`REASON_EXECUTION_VOLUME_BELOW_MINIMUM` -
`Core/MLQuantAI_ReasonCodes.mqh`, appended at the tail.

## Scope guard (frozen)

```
No sealed file edited: MLQuantAI_ExecutionRequestContract.mqh,
    MLQuantAI_SafetyGate.mqh, MLQuantAI_BrokerSubmissionGate.mqh,
    MLQuantAI_BrokerSubmissionBuilder.mqh,
    MLQuantAI_BrokerSubmissionAdapter.mqh,
    MLQuantAI_BrokerSubmissionAuditProjection.mqh,
    MLQuantAI_BrokerSubmissionAuditReadiness.mqh - strictly additive,
    two new files only.
No OrderSend/CTrade/broker mutation/OnTradeTransaction/order-position-
    history query anywhere.
No candidate-lifecycle transition, no event append.
No smoke-test input enabled, no smoke-test file touched.
Manual approval binding stays explicitly deferred - see above.
```
