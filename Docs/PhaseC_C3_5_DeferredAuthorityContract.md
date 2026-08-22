# C3.5 deferred-transaction-authority design contract (documentation only)

**Status**: DESIGN ONLY, frozen. No code, no `.mqh`/`.mq5` file, no
`EventStore_LogTransition` integration, no `BrokerReconciliation.mqh`
change, no `History*`/`Position*`/`Order*` API, no `OrderSend`/`CTrade`,
no candidate-lifecycle transition, and no event-schema change is
authorized by this document. Each of those remains its own, separately
approved future step (C3.6 implementation, C3.7 lifecycle authority,
C3.8 reconciliation integration, C4 recovery/history policy).

**Baseline**: `mlquantai@8321448` (C1–C3.4 sealed; the Step 8.5 smoke-test
orphan-candidate fixture fix merged 626/626). At this baseline C3.3's
transaction-matching projection and C3.4's startup-readiness snapshot
both exist, but **no component has authority to change candidate state
from a broker fact**.

---

## 1. Motivation and the authority gap this contract closes

`OrderSend()` returning `true` with `TRADE_RETCODE_DONE` means the trade
server acknowledged the order — it does **not** mean the deal filled
([MQL5 docs: OrderSend](https://www.mql5.com/en/docs/trading/ordersend),
[MQL5: MqlTradeResult](https://www.mql5.com/en/docs/constants/structures/mqltraderesult)).
A single submitted order can also generate multiple
`OnTradeTransaction` events across its lifecycle — order placement, deal
execution, and order state transitions arrive as separate facts
([MQL5 docs: OnTradeTransaction](https://www.mql5.com/en/docs/event_handlers/ontradetransaction),
[MQL5 book: experts_ontradetransaction](https://www.mql5.com/en/book/automation/experts/experts_ontradetransaction)).

The sealed state machine (`Core/MLQuantAI_StateMachine.mqh`) already
permits `CANDIDATE_SUBMITTED → {CANDIDATE_EXECUTED,
CANDIDATE_REJECTED_BY_BROKER, CANDIDATE_ERROR}`. But, excluding the
synthetic Step 8.5 smoke path and test fixtures, the only normal
broker-submission path that emits lifecycle transitions from real
OrderSend-side outcomes is `BrokerSubmissionAdapter`
(`Execution/MLQuantAI_BrokerSubmissionAdapter.mqh`); it emits
`CANDIDATE_SUBMITTED` on `OrderSend()==true`+`DONE` and
`CANDIDATE_REJECTED_BY_BROKER` on an explicit rejection retcode — both
**immediate OrderSend-side** outcomes, not durable broker-fill
evidence, and never `EXECUTED` from broker-fill evidence.

**Finding, frozen**: no production broker-fill evidence consumer
currently emits `CANDIDATE_EXECUTED`. Excluding the synthetic Step 8.5
smoke path and test fixtures, the normal submission path only moves
candidates to `SUBMITTED` or immediate `REJECTED_BY_BROKER` from
`BrokerSubmissionAdapter`. `CANDIDATE_EXECUTED` is a legal-but-unused
state. `BrokerReconciliation_CheckAll()` only **reads** candidates
already in `EXECUTED`; it never produces the transition. This is the
authority gap: there is no owner that may turn a matched broker-fill
fact into a `SUBMITTED → EXECUTED` lifecycle decision.

This contract freezes **who** that owner is and **under what conditions**
it may act, before any code is written.

---

## 2. Scope guard (frozen)

```
Docs only. No new .mqh/.mq5 file. No edit to any sealed file
(CandidateProjection, TransactionMatchingProjection,
BrokerSubmissionAuditProjection, ExecutionAuditProjection,
StateMachine, BrokerReconciliation.mqh). No new ENUM_EVENT_TYPE value.
No EventStore_LogTransition call. No OnTick/OnTradeTransaction change.
No History*/Position*/Order* API. No OrderSend/CTrade. No
candidate-lifecycle transition. No event-schema/struct-field addition.
```

This document freezes a design contract and a handoff boundary to C3.6
only. Implementing the processor, its tests, its startup wiring, or any
lifecycle transition is explicitly deferred and requires separate
authorization.

---

## 3. Existing authority map (frozen, as of 8321448)

```
OnTradeTransaction (C3.2, sealed)
  = raw broker-fact capture only. Writes BROKER_TRANSACTION_OBSERVED
  envelope facts. Never interprets, never transitions, never queries
  broker state mutably.

TransactionMatchingProjection (C3.3, sealed)
  = durable deal/order matching DIAGNOSTIC projection. Evidence only.
  No lifecycle authority, no write of any kind.

TransactionMatching_StartupRebuild (C3.4, sealed)
  = thin OnInit-only readiness wrapper over C3.3's sealed
  RebuildFromFile. Snapshot is explicitly stale after OnInit (contract
  §26). No session/incremental update.

BrokerSubmissionAdapter (C2.2, sealed)
  = the only production caller of EventStore_LogTransition today.
  Immediate OrderSend-side outcomes only (SUBMITTED / REJECTED_BY_BROKER
  from retcode classification). No durable fill authority.

BrokerReconciliation_CheckAll (sealed)
  = live terminal-state consistency check for candidates already in
  CANDIDATE_EXECUTED only. Reads PositionsTotal()/PositionGetString at
  OnInit. Never produces the EXECUTED transition.

DeferredTransactionProcessor (NOT YET BUILT — this contract defines it)
  = the future SOLE owner permitted to propose/process broker-fact-
  derived candidate lifecycle actions. In C3.6 it produces read-only
  recommendations only; in C3.7 (separately authorized) it may emit
  durable lifecycle transitions under its own frozen policy.
```

**Frozen consequence**: no projection, no readiness wrapper, no callback,
and no reconciliation component other than the future
`DeferredTransactionProcessor` is permitted to call
`EventStore_LogTransition` off of a matched transaction fact. The
existing `BrokerSubmissionAdapter` authority (immediate OrderSend-side
outcomes) is unchanged and not narrowed by this document.

---

## 4. Evidence chain the future processor will consume (frozen shape)

The deferred processor's inputs are existing sealed read models only. The
deterministic linkage from a broker deal to a candidate is:

```
deal_ticket (C3.2 raw fact)
  -> TransactionMatching_ResolveExecutionRequestId (C3.3, sealed):
     matches the deal against SubmissionOutcomeProjection records whose
     submission_status == SUBMISSION_STATUS_SUBMITTED only. Priority A:
     deal_ticket; priority B: order_ticket. Returns "" if neither
     matches -> UNMATCHED/AMBIGUOUS, no candidate resolvable.
  -> execution_request_id
  -> ExecutionRequestProjection (C1.3, sealed): execution_request_id
     maps to candidate_id (struct fields execution_request_id +
     candidate_id). Carries execution_request_hash for tamper detection.
  -> candidate_id
  -> CandidateProjection (sealed): candidate.state, correlation_id, etc.
```

The `OrderAggregateRecord` (C3.3) exposes, per unique `order_ticket`:
`running_filled_volume`, `deal_count`, `matched_execution_request_id`
(`""` unless a single SUBMITTED outcome resolved), and `match_status` ∈
`{UNMATCHED, AMBIGUOUS, MATCHED_PARTIAL, MATCHED_VOLUME_REACHED,
MATCHED_ORDER_TERMINAL}`.

**Frozen constraint**: `TX_MATCH_ORDER_TERMINAL` is **reserved and never
assigned** by C3.3 (the `ORDER_STATE` terminal criterion is not frozen —
Phase C contract §21). Therefore the future processor may treat
**only** `MATCHED_VOLUME_REACHED` as a "fill complete" signal. It must
not act on, infer, or await order-terminal evidence until a later
contract explicitly freezes terminal-order semantics. This is a hard
input boundary, not a tuning parameter.

---

## 5. Future EXECUTED eligibility predicate (frozen, design-only)

The future processor (C3.7) may emit `SUBMITTED → EXECUTED` **only** when
every clause holds simultaneously:

```
candidate.state == CANDIDATE_SUBMITTED
AND the candidate's execution_request_id resolved to exactly one
    OrderAggregateRecord (unique mapping, no collision)
AND that OrderAggregateRecord.match_status == MATCHED_VOLUME_REACHED
AND matched_execution_request_id == candidate's execution_request_id
    (identity round-trips, not a fallback match)
AND no conflicting deal/order mapping exists for the same
    execution_request_id
AND the resolved order/volume evidence is internally consistent
    (volume reached against the execution request's intended lot_size;
    deal_count and running_filled_volume agree)
AND no action for this candidate+terminal-action has already been
    applied (idempotency, see section 9)
AND upstream projections all report readiness `.ok` with zero failed
    lines (C1.3 ExecutionAuditProjection, C2.3
    BrokerSubmissionAuditProjection, CandidateProjection, and the
    C3.4 TransactionMatching startup-readiness snapshot on which this
    scan's input depends)
```

If any clause fails, the result is no recommendation (section 6), never a
partial or speculative transition.

---

## 6. No-action predicates (frozen)

The following produce **no** recommendation and **no** lifecycle action,
unconditionally:

```
UNMATCHED              -> no candidate resolvable (matched_execution_request_id == "")
AMBIGUOUS              -> multiple/uncertain mapping, fail closed
MATCHED_PARTIAL        -> volume not yet reached, stays SUBMITTED
MATCHED_ORDER_TERMINAL -> reserved; never acted on (section 4)
candidate.state != SUBMITTED (CREATED/terminal) -> no action
candidate.state == EXECUTED/REJECTED_BY_BROKER/ERROR -> already terminal, no action
missing or failed upstream projection -> fail closed, no recommendation
duplicate or conflicting execution_request_id mapping -> fail closed
action_id already applied -> idempotent no-op (section 9)
```

No absence of evidence (no fill yet, delay, timeout, no live position,
stale snapshot) may ever be interpreted as a rejection. See section 7.

---

## 7. Rejection predicate separation (frozen)

Deferred rejection (`SUBMITTED → REJECTED_BY_BROKER` from broker evidence)
is **not safely derivable from current C3.3 inputs**. C3.3's matching is
fill/deal evidence, not terminal broker-rejection evidence; C2.2 already
handles immediate explicit `OrderSend` rejection retcodes.

**Frozen**: under the inputs available at this baseline, the future
processor may emit `RECOMMEND_REJECTED` as a **reserved, non-emittable**
status. No deferred rejection may be produced from: no fill, delay,
timeout, `UNMATCHED`, `AMBIGUOUS`, absence of a live position, or a stale
read-model snapshot. A deferred rejection authority, if ever needed,
requires a later terminal-order and/or recovery contract (C4) that
freezes a durable, sealed rejection-evidence source first.

---

## 8. Partial-fill semantics (frozen)

`MATCHED_PARTIAL` means the order has at least one matching deal but
volume has not yet reached the execution request's intended lot_size.

**Frozen**: a partial fill keeps the candidate at `CANDIDATE_SUBMITTED`
and produces recommendation `NONE`. No new intermediate state is
authorized by this document. Volume-reached finalization (the transition
from partial to complete) must reuse **exactly** C3.3's existing
`MATCHED_VOLUME_REACHED` comparison semantics — C3.6 must not introduce a
separate canonical volume tolerance/epsilon unless a later contract
freezes one. Deal-ticket duplicate/collision handling follows C3.3's
already-sealed idempotency and ambiguity rules unchanged.

---

## 9. Idempotency and action identity (frozen, design-only)

The future processor's recommendation/action identity must be
**deterministic and replay-stable**: a cold rebuild from the same event
store must produce the same set of `action_id`s with the same
recommendations, in the same order.

**Frozen**: `action_id` must be derived from immutable evidence identity,
not from a wall-clock or a transient registry counter. The identity
inputs are:

```
candidate_id
execution_request_id
action_type (RECOMMEND_EXECUTED / BLOCKED / NONE)
order_ticket
terminal match_status (MATCHED_VOLUME_REACHED)
deterministic, sorted source deal-ticket / source log-event-id set
  (where the current read-model API exposes them; see section 11)
```

A duplicate run/replay that observes the same evidence must yield the
**same** `action_id` and must not produce a second recommendation. This
mirrors the idempotency precedent already established by C2.3's
`BrokerSubmissionAuditProjection` (exact-duplicate line replay = no-op;
hash collision with differing payload = fail-closed rebuild) and its
`SubmissionAttemptRegistry_HasAttempt` / `IsUnresolved` /
`attempt_count` semantics.

---

## 10. Trigger model and staleness (frozen)

C3.4's read model is an `OnInit`-only startup snapshot, explicitly stale
after `OnInit` (Phase C contract §26). This contract reaffirms:

```
No periodic full-file rebuild inside OnTick.
No incremental update triggered from OnTradeTransaction itself.
```

Both remain explicitly rejected for the same reasons as before: a
full-file scan on a timer is hidden, undocumented runtime behavior that
does not scale as the event store grows, and a correct incremental
matching update needs its own incremental-state and idempotency contract
that does not yet exist.

**Frozen recommendation for C3.6**: the processor starts as **Option A —
an `OnInit`-only, read-only recommendation scan** that runs after the C3.4
startup rebuild, reads the already-built C3.3 read model, and emits a
deterministic `DeferredActionRecord`/report only. It writes no lifecycle
event and mutates no projection. This proves the eligibility logic
deterministically without creating any live authority. Options B
(operator-triggered diagnostic scan) and C (a future C3.6+ incremental
processor event queue) are explicitly deferred and require separate
authorization.

---

## 11. C3.6 handoff boundary (frozen)

The C3.6 implementation round is authorized only to:

```
Add Execution/MLQuantAI_DeferredTransactionProcessor.mqh (new file).
Add Tests/MLQuantAI_Test_C3_6_DeferredTransactionProcessor.mq5 (new file).
Read only from sealed projections: CandidateProjection,
  ExecutionAuditProjection, BrokerSubmissionAuditProjection,
  TransactionMatchingProjection.
Produce a read-only DeferredActionRecord / test-only report.
```

The expected `DeferredActionRecord` shape (design-only, exact field set
frozen at C3.6 contract time, not here):

```
deterministic action_id
candidate_id
execution_request_id
source order_ticket / deal-ticket evidence
recommended_action (NONE / RECOMMEND_EXECUTED / BLOCKED)
reason code
evidence sequence / source log-event references (where the current
  read-model API exposes them; if not, C3.6 may add read-only accessors
  or report fields to the NEW processor file only — never to a sealed
  projection)
evaluated_at / session-scope metadata (stale-after-OnInit marker)
```

**Frozen prohibition**: C3.6 must not append any lifecycle event, must not
call `EventStore_LogTransition`, must not mutate any sealed projection's
state, and must not introduce a new `ENUM_EVENT_TYPE` value. The
`RECOMMEND_REJECTED` status is reserved and non-emittable under current
inputs (section 7).

If the current sealed read-model APIs do not expose enough source
deal-ticket / source log-event-id references to build a fully
deterministic `action_id`, C3.6 may add **read-only accessors or report
fields inside the new processor file only** — never edit a sealed
projection's struct or its `RebuildFromFile`. Any such gap is recorded in
the C3.6 contract, not silently worked around.

---

## 12. C3.6 required test matrix (design-only, no test file authorized here)

At minimum, the future C3.6 suite must prove:

```
1. full match + SUBMITTED candidate -> RECOMMEND_EXECUTED
2. partial fill -> no terminal recommendation (NONE)
3. unmatched -> no recommendation
4. ambiguous -> BLOCKED, observable
5. candidate no longer SUBMITTED (CREATED/terminal) -> no action
6. outcome maps to wrong/multiple candidates -> fail closed (BLOCKED)
7. duplicate rerun -> same action_id, no second recommendation
8. cold rebuild from same store -> identical result set and order
9. missing upstream projection readiness -> fail closed, no recommendation
10. no OrderSend/CTrade/History*/Position*/Order* API in the new file
11. no EventStore_LogTransition / event append in the new file
12. MATCHED_ORDER_TERMINAL input -> no action (reserved, section 4)
```

Validation gate for C3.6 merge (frozen): new C3.6 suite + C3.3 suite +
C3.4 suite + full C2 regression baseline + `MLQuantAI.mq5` compile 0
errors / 0 warnings + static prohibited-API scan of the new file. After
C3.6 merge, no candidate transition and no action event exist.

---

## 13. Fixture-debt boundary (frozen)

Phase 0 fixture debt is a **separate open gate** that must be
opened/decided before any C3.6 implementation branch starts. This
docs-only C3.5 merge does not complete that gate and does not defer it
silently — it records the boundary and ordering only.

```
MLQuantAI_events_2026-08-21.jsonl (the pre-fix daily store containing
  the historical orphan line) remains READ-ONLY historical evidence. It
  is not a repair target and is never renamed, deleted, truncated, or
  modified.
A separate test-data-only fixture-remediation decision (Phase 0.3) must
  be opened and decided before the first C3.6 implementation commit:
  - keep the corrupted store as a NEGATIVE fixture with a test asserting
    the system reports the failure correctly; AND
  - build a clean canonical POSITIVE fixture for startup-chain
    integration tests (C1.3 -> C2.3 -> C3.3 -> C3.4).
Neither overwrites or edits the original event log.
```

C3.5 does not authorize fixture remediation; it freezes that Phase 0.3
is a prerequisite gate sitting between this docs-only merge and any C3.6
implementation work.

---

## 14. Future gates (deferred, not authorized here)

```
C3.7 - bounded lifecycle authority: contract-first freeze of event type
       (new vs reuse EventStore_LogTransition), idempotency key bound to
       candidate + terminal action + immutable broker evidence identity,
       replay behavior (no duplicate transition on restart), action audit
       trail, conflict policy, fail-closed behavior, and Safe Mode policy
       (ambiguity alone is not an auto Safe Mode trigger unless a new
       integrity-violation category is frozen). Authorized only after C3.6
       evidence is clean.
C3.8 - reconciliation integration: preserve the three-way ownership
       separation; add submitted-candidate visibility (matching status +
       recommendation + age/unresolved diagnostic); absence of a live
       position is never a broker rejection; restart-scenario fixture
       coverage (before deal observation, after partial fill, after
       full-fill observation before action, after action emission,
       duplicate/reordered raw facts, current-day vs archived store).
C4   - recovery / broker-history policy: decide recovery authority
       (recommended: EventStore authoritative, history diagnostic-only).
       HistorySelect produces a history snapshot before deals/orders can
       be read and has its own cache/selection semantics
       ([MQL5 book: experts_history_select](https://www.mql5.com/en/book/automation/experts/experts_history_select),
       [MQL5: HistorySelect](https://www.mql5.com/en/articles/211));
       it must not be opened without a separately frozen contract.
       No silent overwrite of C3.2 raw facts; recovered-fact provenance;
       no lifecycle authority until recovered-fact semantics are sealed.
C5   - controlled execution rollout: environment ladder
       (TEST FIXTURE -> DEMO DRY-RUN -> DEMO REAL-SUBMIT manual approval
       -> DEMO bounded automation -> LIVE shadow -> LIVE manual micro-size
       -> LIVE bounded automation); non-negotiable live controls
       (environment lock, manual approval idempotency, volume/daily-loss/
       exposure caps, single symbol/strategy, kill switch, slippage/
       retcode/timeout/duplicate policy, audit export, rollback).
C6   - position/exit lifecycle: SL/TP, partial close, stop-out/TP/manual
       closure detection, P&L attribution. A position is the sum of one or
       more deals and a deal is the result of order execution; a position
       ticket must never be used as an identity substitute for deal/order
       matching
       ([MQL5: HistoryDealGetTicket](https://www.mql5.com/en/docs/trading/historydealgetticket),
       [MQL5: MqlTradeRequest](https://www.mql5.com/en/docs/constants/structures/mqltraderequest)).
C7   - operational hardening: monitoring dashboard, data governance/
       retention, incident runbooks (Safe Mode, event-store validation
       failure, ambiguous ticket collision, broker timeout/uncertain
       submit, mid-transaction restart, orphan/schema-invalid historical
       data, wrong environment lock).
```

---

## 15. Acceptance criteria for this docs-only merge (frozen)

```
1. This document added under Docs/.
2. A CHANGELOG entry marked DESIGN ONLY / docs-only.
3. Diff is exactly two files: this doc + CHANGELOG.md.
4. No .mqh/.mq5 source file changed.
5. No sealed file touched.
6. No new ENUM_EVENT_TYPE value.
7. advisor final review confirms the authority boundary, the eligibility
   predicate, the rejection-predicate separation, the partial-fill
   semantics, the trigger model, and the idempotency boundary are each
   frozen and internally consistent with the sealed C1–C3.4 codebase.
8. Explicit user merge authorization (no auto-merge).
```

---

## Hard safety rules carried forward (frozen, unchanged)

```
No lifecycle transition from UNMATCHED, AMBIGUOUS, or PARTIAL evidence.
OrderSend success is never proof of fill.
No position-ticket identity inference for deal/order matching.
No silent history backfill.
No full-file periodic OnTick rebuild.
No raw callback becoming business authority.
No merge without contract, scope allowlist, tests, compile clean, and
  post-merge verification.
```
