# Phase C2.4 — Entry Price Compatibility / Risk Preservation Contract

**Status: FROZEN. QA sign-off given; contract text below (§1–§10) is
authoritative and equivalent in standing to every other frozen contract in
`Docs/`.**
**Implementation authorization: NONE. This freeze covers contract text
only. No `.mqh`/`.mq5` file may be created or modified, no `OrderSend`
path is authorized, and no commit/push under this checkpoint is authorized
until a separate checkpoint — RA-12 (Docs/PhaseC_C2_1_BrokerSubmissionContract.md
amendment, per §7/§10 below) — is opened, resolved, and itself passes QA.**

Origin: checkpoint chain C6.6-RA-08 → RA-09 → RA-10 → RA-11 (audit-only,
read-only investigation; see those checkpoints' evidence for the full trace).
This document formalizes the finding and QA's resulting design decision as a
contract amendment, per the same discipline used for every other frozen
contract in `Docs/`.

---

## 1. Motivation — the gap this amendment closes

Three existing, independently-frozen contracts each make a locally-correct
decision that, combined, leave a real cross-layer gap:

1. **`Docs/PhaseB_B5_CRTContract.md`** (CRT_V1 detection) computes
   `entry_hint` / `sl_hint` / `tp_hint` as pure pattern geometry. It makes
   zero claim about *when* or *at what price* the candidate will actually be
   executed — explicitly out of scope for B5 ("nothing about risk, sizing,
   execution, AI, defaults; B6/B7's job, not B5's").

2. **`Docs/PhaseB_B7_RiskPlanContract.md`** (RiskPlan / lot sizing) copies
   `planned_entry` / `planned_sl` / `planned_tp` verbatim from the candidate
   ("B7 never adjusts CRT's own entry/exit decision") and derives
   `stopDistancePoints`, `rr_ratio`, and — critically — `lot_size` directly
   from `planned_entry`. RiskPlan's sizing is only valid **if the eventual
   fill happens at or near `planned_entry`.**

3. **`Docs/PhaseC_C2_1_BrokerSubmissionContract.md`** (BrokerSubmission /
   order construction) explicitly and deliberately does **not** use
   `planned_entry` for the live order's `price` field — it documents that
   `planned_entry` "may be stale by actual submission" and instead reads a
   fresh `SYMBOL_ASK`/`SYMBOL_BID` at construction time
   (`MLQuantAI_BrokerSubmissionBuilder.mqh::BrokerSubmission_BuildTradeRequest`,
   lines 82–96). `sl` and `tp`, however, stay frozen at `req.planned_sl` /
   `req.planned_tp` — the values RiskPlan sized against.

**No existing invariant anywhere reconciles (2) against (3).** If the live
price at submission has drifted from `planned_entry`, the order that
actually reaches the broker has a *different* realized stop distance than
the one RiskPlan sized `lot_size` for, while `sl`/`tp` stay pinned to the
original plan. The realized entry risk (`lot_size × realized stop distance ×
tick_value`) can silently diverge from the designed `target_risk_percent`.
This is a genuine architecture gap, not an implementation bug in any single
file — each file above does exactly what its own frozen contract says.

`ExecutionPolicy.max_deviation_points` was investigated (RA-11 negative
confirmation across all of `Docs/`) and found to be a **broker round-trip
slippage tolerance** — documented in
`Docs/PhaseC_C1_2_ExecutionRequestSafetyGateStatus.md` as "a real OrderSend
slippage parameter, which only exists once C2 submits." It has no existing
semantic connection to entry-risk tolerance and **must not** be reused or
reinterpreted for that purpose (see AC-05).

---

## 2. QA's decision (frozen at RA-11)

**Option B — price-dependent validity, fail-closed**, verbatim as decided by
QA:

- `planned_entry`, `planned_sl`, `planned_tp`, and `lot_size` on an existing
  `ExecutionRequest` / `RiskPlan` remain **permanently immutable** once
  created. Nothing in this amendment mutates them in place.
- A new gate — the **Entry Compatibility Gate** — is inserted in the
  pipeline **between B9 (Execution Eligibility) and C2 (BrokerSubmission)**.
  It is a new, separately-authorized component. It is **not** added inside
  `BrokerSubmissionBuilder`, and **not** added inside B7/RiskSizing.
- At evaluation time, the gate compares the actual execution reference price
  against `planned_entry`, under a **new, separately-named deviation
  policy** — explicitly not `max_deviation_points`. The reference price is
  **not** implementation-defined; it is a normative invariant of this
  contract:

  ```text
  execution_reference_price =
      SYMBOL_ASK   for req.side == ORDER_TYPE_BUY
      SYMBOL_BID   for req.side == ORDER_TYPE_SELL
  ```

  This mirrors, side-for-side, the same fresh-price read
  `BrokerSubmissionBuilder::BrokerSubmission_BuildTradeRequest` already
  performs (`MLQuantAI_BrokerSubmissionBuilder.mqh` lines 82–96) — the gate
  must not read a different quote, a mid price, or any other derived value.
  No implementation may substitute its own interpretation of "current
  price" for this definition.
- If deviation is within tolerance: the request proceeds to C2/BrokerSubmission
  unchanged.
- If deviation exceeds tolerance: the request is **blocked**
  (`EXECUTION_BLOCKED`) with a new, distinct reason code (provisionally
  `ENTRY_PRICE_DEVIATION_EXCEEDED` — see §6). No `OrderSend` occurs. No
  field on the existing `RiskPlan`/`ExecutionRequest` is mutated. No
  automatic retry occurs.
- Re-attempting the trade after a block requires an entirely **new lineage**
  — a new `RiskPlan` and a new `ExecutionRequest`, each with its own new
  identity/hash, built fresh (presumably against a fresh `TradeCandidate`
  evaluation at current price). The original, blocked request is never
  overwritten or resubmitted.

---

## 3. Non-goals (explicitly out of scope for this amendment)

- This amendment does **not** change CRT_V1 detection (B5) in any way.
- This amendment does **not** change RiskPlan sizing formulas (B7) in any
  way — it does not attempt to re-size `lot_size` against the live price;
  a deviation that fails compatibility is blocked, not re-sized.
- This amendment does **not** change `BrokerSubmissionBuilder`'s existing
  price/sl/tp construction logic (C2.1/C2.2) — that logic is unchanged and
  continues to run only after the Entry Compatibility Gate has already
  passed the request through.
- This amendment does **not** introduce pending/limit order types or any
  `allowed_order_types` semantics — market-only remains the C1 invariant,
  unchanged.
- This amendment does **not** authorize real `OrderSend` — `EMP-01` remains
  blocked under its own, separate authorization chain.

---

## 4. State machine / gate position

```
TradeCandidate (B5, CRT_V1)
        |
        v
RiskPlan (B7 — sizing frozen at planned_entry; IMMUTABLE once created)
        |
        v
ExecutionRequest (C1.1 — planned_entry/sl/tp/lot_size copied verbatim,
                  IMMUTABLE once created)
        |
        v
Execution Eligibility (B9 — existing, unchanged)
        |
        v
   +---------------------------+
   |  Entry Compatibility Gate | <-- NEW (this amendment)
   |  reads fresh reference    |
   |  price; compares against  |
   |  planned_entry under the  |
   |  new deviation policy     |
   +---------------------------+
        |                  |
   within tolerance    exceeds tolerance
        |                  |
        v                  v
BrokerSubmission      EXECUTION_BLOCKED
(C2 — unchanged)      reason=ENTRY_PRICE_DEVIATION_EXCEEDED
        |              no OrderSend, no mutation, no retry.
        v              Re-attempt = brand-new RiskPlan +
   OrderSend               ExecutionRequest lineage, new identity.
   (real fill)
```

---

## 5. Authority separation table (frozen at RA-11)

| Layer | Authority | Does NOT do |
|---|---|---|
| B5 — CRT_V1 | Setup/pattern intent (`entry_hint`/`sl_hint`/`tp_hint`) | Makes no claim about execution timing or price freshness |
| B7 — RiskPlan | Deterministic sizing from `planned_entry`/`sl` at plan time | Never adjusts CRT's own entry/exit decision; never re-sizes later |
| B9 — Execution Eligibility | Final eligibility (existing checks, unchanged) | Does not evaluate price compatibility (that's the new gate) |
| **Entry Compatibility Gate (new)** | **Compares live reference price vs. `planned_entry`; PASS/BLOCK only** | **Never mutates RiskPlan/ExecutionRequest fields; never resizes lot; never retries** |
| C2 — BrokerSubmission | Constructs `MqlTradeRequest` and calls `OrderSend` only after gate PASS | Does not itself evaluate entry-price risk validity (unchanged from today) |
| Broker/Terminal | Actual fill price, actual retcode | N/A |
| Event Store | Immutable fact record of every step above | Never a decision authority |

---

## 6. New reason code (provisional)

`ENTRY_PRICE_DEVIATION_EXCEEDED` (provisional name, pending QA confirmation
alongside the rest of this amendment) — a new `ENUM_REASON_CODE` value,
**distinct** from every existing broker-slippage/rejection reason code
(`REASON_REQUOTE`, `REASON_INVALID_STOPS`, `REASON_BROKER_REJECT`, etc.), so
that an Entry Compatibility Gate block is never conflated in logs, audits,
or event-store queries with an actual broker-side rejection. The exact
enum name/placement is implementation detail deferred to the (not-yet
authorized) implementation checkpoint.

---

## 7. Execution snapshot semantics — QA ruling

**Decision: (b) — bind the exact execution reference price.**

Background (why this question existed): the gate (§4) evaluates
`execution_reference_price` (§2) at gate-evaluation time.
`BrokerSubmissionBuilder::BrokerSubmission_BuildTradeRequest` reads its own
fresh `SYMBOL_ASK`/`SYMBOL_BID` again, independently, at construction
time — moments later, after the gate has already returned PASS. Between
those two reads, the market can move:

```text
t0: gate reads execution_reference_price = 4401  → within tolerance → PASS
t1: builder reads its own fresh price    = 4404  → this is what OrderSend
                                                     actually uses
```

Under a "time-local snapshot only" reading (option (a), rejected), the
gate's PASS verdict was computed against 4401 while the order that reaches
the broker is constructed against 4404 — the exact time-of-check-to-time-
of-use (TOCTOU) gap this amendment exists to close. QA rejected (a) for
exactly this reason: it would leave RA-11's objective unmet.

**Ruling:**

> The Entry Compatibility Gate MUST capture one `execution_reference_price`
> using:
> ```text
> BUY  = SYMBOL_ASK
> SELL = SYMBOL_BID
> ```
> When the gate passes, that exact captured value MUST be the execution
> price consumed by C2 for the same submission attempt.
>
> C2 MUST NOT perform an independent market-price reread that replaces the
> bound `execution_reference_price`.

`execution_reference_price` is therefore an **immutable execution input**
of the submission attempt, not a value the gate computes and discards:

```text
read execution_reference_price
        ↓
evaluate compatibility (§8)
        ↓
PASS
        ↓
bind same value to submission
        ↓
C2 BrokerSubmission (consumes the bound value, does not reread)
        ↓
OrderSend
```

**Consequence — this ruling amends C2.1, which this document has no
authority to do unilaterally.** `Docs/PhaseC_C2_1_BrokerSubmissionContract.md`
is a separately-frozen contract whose current "Order construction" section
specifies `price = fresh SYMBOL_ASK/SYMBOL_BID read by the Builder at
construction time` (`MLQuantAI_BrokerSubmissionBuilder.mqh` lines 82–96).
Implementing the binding above requires reopening C2.1 through its own
amendment checkpoint:

> **RA-12 — C2.1 Execution Price Binding Amendment.** Status: OPEN. Must
> land (its own contract change, its own sign-off) before any
> implementation of the Entry Compatibility Gate can proceed, since the
> gate's PASS output is meaningless under C2.1's current wording — C2
> would still reread the market and silently discard the bound value.
> C2.4 does not, and cannot, override C2.1 by itself.

## 8. Deviation policy — QA ruling

**Decision: (c) — realized-risk-percent divergence, threshold ±10%.**

Rationale (QA's own): the problem RA-11 surfaced is not "how many points
did price move" in isolation — it is that `planned_entry` feeds directly
into `stopDistancePoints` → `lot_size` → realized risk
(see §1 above; `MLQuantAI_RiskSizing.mqh::Candidate_ToRiskPlan`).
The metric that most directly matches what this contract protects is
therefore the realized risk the *existing* `lot_size` would produce at the
bound `execution_reference_price` (§7), compared against the risk RiskPlan
originally designed for.

**Normative definitions:**

```text
planned_stop_distance
    = abs(planned_entry - planned_sl)

realized_stop_distance
    = abs(execution_reference_price - planned_sl)

planned_risk_money
    = lot_size × planned_stop_distance × tick_value

realized_risk_money
    = lot_size × realized_stop_distance × tick_value

risk_divergence_pct
    = abs(realized_risk_money - planned_risk_money) / planned_risk_money × 100
```

**Gate condition:**

```text
PASS  if risk_divergence_pct <= 10%
BLOCK if risk_divergence_pct  > 10%
```

**Directional hard constraint (checked before, and independently of, the
divergence calculation above):**

```text
BUY:  execution_reference_price > planned_sl
SELL: execution_reference_price < planned_sl
```

If the directional constraint fails, the request is `EXECUTION_BLOCKED`
immediately — the divergence percentage is not computed, since the stop
geometry itself is already invalid at that reference price (the position
would already be on the wrong side of its own stop).

**±10% is a new QA policy decision, not a value derived from any existing
source contract.** `≤10%` is treated as still inside the risk envelope
RiskPlan (B7) designed for; `>10%` means the original RiskPlan can no
longer certify this execution. This threshold has **no relationship** to
`max_deviation_points` (§1, AC-05) — that field remains, unchanged, a
broker round-trip slippage parameter consumed only inside
`BrokerSubmissionBuilder`'s `deviation` field; it is never read, reused, or
reinterpreted by the Entry Compatibility Gate.

`tick_value` and `lot_size` above are read the same way RiskPlan/B7 already
does (`MLQuantAI_RiskSizing.mqh`) — this ruling does not introduce a new
source of either value.

---

## 9. Acceptance criteria

AC-01 through AC-09 were frozen at RA-11 (AC-01 updated below to reflect
the §7 ruling — the original RA-11 wording predates that decision).
AC-10 was added at the QA review that closed §7/§8.

- **AC-01**: A request whose bound `execution_reference_price` (§7)
  satisfies the directional constraint and whose realized-risk divergence
  (§8) is `<= 10%` passes the gate and proceeds to BrokerSubmission using
  that exact same bound `execution_reference_price`.
- **AC-02**: A request whose deviation exceeds tolerance is blocked
  (`EXECUTION_BLOCKED`) with **no** `OrderSend` call made.
- **AC-03**: A blocked request is never automatically retried by the gate
  or by any other component.
- **AC-04**: `planned_entry`, `planned_sl`, `planned_tp`, and `lot_size` on
  the existing `RiskPlan`/`ExecutionRequest` are never mutated by this
  gate, under any outcome.
- **AC-05**: `max_deviation_points` is never reinterpreted or reused as an
  entry-risk-tolerance mechanism; the new policy uses its own, separately
  named field(s).
- **AC-06**: A new attempt after a block creates a **new** lineage (new
  `RiskPlan` + new `ExecutionRequest`, new identity/hash per the existing
  identity contract) — it never overwrites or edits the original blocked
  request.
- **AC-07**: Cold rebuild (EventStore replay) of the gate's decision stays
  deterministic given the same recorded inputs.
- **AC-08**: The original (blocked) `RiskPlan` remains fully replayable and
  auditable at its own original planned price — the block does not erase
  or alter its historical record.
- **AC-09**: The block reason code is distinct from, and never conflated
  with, any broker-side slippage/rejection reason code.
- **AC-10**: The price consumed by BrokerSubmission for a passed attempt is
  exactly the `execution_reference_price` evaluated by the Entry
  Compatibility Gate; C2 must not replace it with a later independent
  market-price read. (Closes the TOCTOU gap directly — see §7.)

---

## 10. Freeze status

**FROZEN.** Both open items are ruled: §7 = option (b) (exact
execution-price binding) and §8 = realized-risk-percent divergence at a
±10% threshold with the BUY/SELL directional constraint. QA reviewed the
wording implementing both rulings (§7, §8, AC-01, AC-10) and confirmed it
accurately reflects the ruling given, and has signed off on the document as
a whole — this contract now stands at the same authority level as
`Docs/PhaseC_C2_1_BrokerSubmissionContract.md` and the other frozen
contracts in this project.

**Freezing this document's text does not, by itself, authorize
implementation.** No implementation of the Entry Compatibility Gate may
begin until **RA-12 — C2.1 Execution Price Binding Amendment** (§7) is
opened, resolved, and its own contract change to
`Docs/PhaseC_C2_1_BrokerSubmissionContract.md` is itself frozen. C2.4's §7
ruling requires C2 to consume a bound price instead of rereading the
market; C2.1's current frozen wording says the opposite, and C2.4 has no
authority to override C2.1 by itself. Until RA-12 lands, this contract is
architecturally settled but not yet implementable.

Until RA-12 passes QA: no `.mqh`/`.mq5` file may be created or modified
under this checkpoint's authority, `OrderSend` remains not authorized, and
commit/push of this document itself is not authorized.
