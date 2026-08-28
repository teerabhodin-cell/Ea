# C4 recovery / broker-history policy design contract (documentation only)

**Status**: proposed for adoption following C4.0 Contract-Reconciliation
Checkpoint 1 and its required amendments (QA re-review); not effective
until this docs-only contract is reviewed and committed.

**Baseline**: `mlquantai@81a000b583661099d077225be99d030cea65eff5`
(C3 implementation components C3.1-C3.10 merged; the adopted C3.8
contract remains authoritative on its dedicated docs lineage).

**Predecessor**: this contract refines, and does not contradict, the C4
stub in `Docs/PhaseC_C3_5_DeferredAuthorityContract.md` §14 and the
equivalent C4 references in `PhaseC_C3_6_DeferredTransactionProcessorContract.md`
and `PhaseC_C3_7_BoundedLifecycleAuthorityContract.md`. Where this
document is silent, those govern.

---

## 1. Purpose and non-goals

Purpose: define restart-recovery and broker-history evidence policy -
what `HistorySelect()`-derived evidence means, how it relates to C3.2's
live-observed facts, and what (if anything) may act on it. `HistorySelect()`
and its companion getters (`HistoryDealGet*`/`HistoryOrderGet*`) have
never been called anywhere in this codebase before this contract -
verified by inspection at the stated baseline (only "forbidden API"
comments in `BrokerTransactionObservation.mqh` and
`BrokerSubmissionAuditReadiness.mqh` mention them at all).

Non-goals for the scope this contract covers (C4.0 design + C4.1 first
implementation):

```
- no automated order send / resend / retry of a prior submission
- no silent overwrite of any C3.2 BROKER_TRANSACTION_OBSERVED fact
- no candidate-lifecycle transition authority of any kind
- no durable write of any kind (see §7 - C4.0/C4.1 are zero-write)
- no position management / exit handling (reserved for C6)
- no live-rollout environment ladder or execution-loop authority
  (reserved for C5, which is the future consumer of this contract's
  read-only findings - see §5)
```

---

## 2. Evidence model - four distinct record classes

Four record classes exist, and are never conflated with one another:

```
1. C3.2 live submission fact
   BROKER_TRANSACTION_OBSERVED, captured during live OnTradeTransaction.
   Already sealed, already durable. Never touched, modified, or
   superseded by anything in this contract's scope.

2. Recovered order-history fact (new)
   Evidence obtained from a HistorySelect() scan and a subsequent
   HistoryOrderGet* read for one order ticket.

3. Recovered deal-history fact (new)
   Evidence obtained from a HistorySelect() scan and a subsequent
   HistoryDealGet* read for one deal ticket.

4. Derived reconciliation finding (new)
   A deterministic, read-only comparison across (1)-(3). Never itself
   a source fact, never durable, never an authority for anything.
```

Order-history and deal-history facts are kept as separate classes,
never merged at read time: an order and its deals have different
identity and different semantics, and one order can legitimately map
to multiple deals under partial-fill behavior (matching C3.3's own
`MATCHED_PARTIAL`/`MATCHED_VOLUME_REACHED` semantics, unchanged by this
contract).

**Frozen invariant**: a recovered broker-history fact (order or deal)
SHALL NOT modify, delete, replace, merge into, or cause a rewrite of
any C3.2 live-observed fact. A reconciliation finding is derived from
immutable inputs and is not itself a source fact - it carries no write
authority over any of the records it was derived from.

Every recovered record (order or deal) carries, at minimum:

```
provenance_kind              (RECOVERED_ORDER_HISTORY | RECOVERED_DEAL_HISTORY)
history_select_from          (the HistorySelect() window start actually used)
history_select_to            (the HistorySelect() window end actually used)
history_query_server_time    (TimeCurrent() at the moment the query ran)
source_order_ticket          (when applicable to this record's provenance_kind)
source_deal_ticket           (when applicable to this record's provenance_kind)
recovery_session_identity    (distinguishes one recovery scan from another -
                               never conflated with a live OnTradeTransaction
                               observation session)
```

A recovered record is explicitly a **snapshot bounded by its own query
window** - it never carries or implies a claim that the broker's history
is complete "forever," only that this specific `(history_select_from,
history_select_to)` window was queried at `history_query_server_time`.

---

## 3. `HistorySelect()` query policy

Three distinct query-result states must be distinguished - conflating
any two of them is explicitly forbidden:

| Query state | Meaning | Allowed conclusion |
|---|---|---:|
| `HistorySelect()` returns `false` | terminal/history evidence unavailable for this window | never infer absence of broker activity |
| `HistorySelect()` returns `true`, selected result set is empty | no selectable record in this exact window | still never infer *global* absence |
| Window meets the predeclared adequacy rule (below) and is empty | no corroborating record within an *adequate* window | `RECOVERY_NO_CORROBORATING_HISTORY` may be emitted; the local C3.2 fact is still never rewritten |

Additional frozen rules:

```
- the window MUST be constructed as follows, not invented ad hoc per
  call site: it begins at the earliest durable local timestamp
  relevant to the fact under review, minus a fixed overlap allowance,
  and ends at TimeCurrent(). Both bounds are inclusive. A window is
  adequate only when its start is at or before that earliest relevant
  timestamp and HistorySelect() succeeds for the whole interval.
- the overlap allowance is a named configuration constant; its default
  value and any optional operator-supplied override must be specified
  by an adopted C4.1 design addendum before any C4.1 code is written -
  this contract freezes the window-construction rule and the adequacy
  predicate, not the numeric constant. C4.1 is not implementation-
  authorized until that addendum is adopted.
- server-time semantics only (TimeCurrent()-anchored), matching every
  other clock rule already frozen in this project (C3.8 §5 and
  predecessors) - never terminal-local wall-clock time.
- retained-history gaps (broker-side retention limits truncating the
  selectable range) are a form of window inadequacy, not absence -
  see RECOVERY_WINDOW_INSUFFICIENT below.
- read-only, unconditionally: no OrderSend/CTrade call is reachable
  from any C4 code path (see §7).
- no assumption that a prior HistorySelect() call's selection state
  persists across reads - each read explicitly re-selects.
```

`RECOVERY_WINDOW_INSUFFICIENT` (§4) is not limited to the "zero results"
case - it applies whenever the window cannot cover the evidence interval
a local fact requires, the query bounds themselves are invalid, or
history-retention limits mean adequacy cannot be established at all.

---

## 4. Reconciliation finding vocabulary (frozen enum)

```cpp
enum ENUM_RECOVERY_FINDING
{
   RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE,    // local C3.2/EventStore/projection
                                            // evidence could not be read or
                                            // reconstructed - see below
   RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE,  // HistorySelect() itself failed
   RECOVERY_WINDOW_INSUFFICIENT,           // window cannot establish adequacy
                                            // (see §3) - never treated as
                                            // absence
   RECOVERY_NO_CORROBORATING_HISTORY,      // queried an adequate window,
                                            // genuinely nothing found
   RECOVERY_FACT_CORROBORATED,             // reserved: may be emitted only
                                            // after the C4.1 comparison-
                                            // semantics addendum specified
                                            // in §6 is adopted
   RECOVERY_FACT_CONFLICT,                 // reserved: may be emitted only
                                            // after the C4.1 comparison-
                                            // semantics addendum specified
                                            // in §6 is adopted
   RECOVERY_ORPHAN_HISTORY_ORDER,          // a recovered order-history fact
                                            // has no matching C3.2 fact
   RECOVERY_ORPHAN_HISTORY_DEAL,           // a recovered deal-history fact
                                            // has no matching order/fact
   RECOVERY_DUPLICATE_HISTORY_RECORD,      // the same history record (by its
                                            // own ticket - order ticket for an
                                            // order record, deal ticket for a
                                            // deal record) observed twice
   RECOVERY_UNMAPPABLE_HISTORY_RECORD      // a recovered record cannot be
                                            // resolved to any matching key
                                            // under §6 - never guessed at
};
```

`RECOVERY_ORPHAN_HISTORY_ORDER` and `RECOVERY_ORPHAN_HISTORY_DEAL` are
kept as two distinct outcomes (not one generic "orphan") so an operator
can tell immediately which object class fell outside mapping, without
waiting on implementation-time wording choices.

When local evidence cannot be read at all
(`RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE`): no comparison is performed, and
no conclusion about corroboration, conflict, or orphan status is ever
emitted for that record - this outcome is terminal for that
candidate/ticket's finding, not merely a soft warning folded into
another outcome.

`RECOVERY_DUPLICATE_HISTORY_RECORD` applies only when the same
order/deal ticket is present more than once within one normalized
recovered snapshot, after C4 has enumerated the selected history for a
single query. It does not mean that the same record was observed again
in a later recovery scan; separate scans are distinguished by
`recovery_session_identity`, and a ticket recurring across distinct
scans is not, by itself, a duplicate finding.

`RECOVERY_FACT_CORROBORATED` and `RECOVERY_FACT_CONFLICT` are reserved
vocabulary in C4.0. Their emission is prohibited until the separately
adopted C4.1 comparison-semantics addendum required by §6 exists.

---

## 5. Findings are read-only recommendations, never actions

C4 (both the 0-design and the 1-implementation checkpoints this contract
covers) emits a read-only recovery finding plus a recommended posture.
It does not itself block, unblock, transition, retry, resend,
acknowledge, clear Safe Mode, or perform any other state-changing
action - that authority, if it is ever exercised at all, belongs to a
future execution-gate consumer (C5), which reads C4's posture as one
input among others once a real execution loop exists. This mirrors the
same authority-separation discipline already frozen for
`unresolved_beyond_threshold` in C3.8 §4b (strictly diagnostic, never a
trigger by itself).

```cpp
enum ENUM_RECOVERY_POSTURE
{
   RECOVERY_POSTURE_INFORMATIONAL,     // corroborated / no-action-implied
   RECOVERY_POSTURE_DEGRADED,          // evidence gap - flagged, not fatal
   RECOVERY_POSTURE_BLOCK_RECOMMENDED  // conflict/unmappable - recommends a
                                        // future execution gate hold, but is
                                        // not itself capable of enforcing one
};
```

`ENUM_RECOVERY_POSTURE` is a recommendation only, never an authority -
identical in spirit to `ENUM_RECOMMENDATION` (C3.6) never itself
transitioning lifecycle state.

---

## 6. Matching key and conflict rule

To prevent C4.1's implementation from inventing ad hoc matching
semantics, a minimal identity hierarchy is frozen here (field-level
equality beyond this hierarchy is deferred to implementation, but
matching MUST follow this hierarchy - never a silent "best effort"
match outside it):

```
Primary key:
  broker order ticket - only usable when both the local (C3.2-derived)
  side and the recovered side carry a valid, known, positive ticket.

Secondary key:
  execution_request_id / correlation reference - usable only when the
  recovered broker-history record actually carries a trustworthy,
  broker-supplied mapped reference to it (never inferred/guessed).

Deal evidence:
  a recovered deal-history fact is matched to its own order-history
  fact first (by order ticket) - it never directly matches or
  overwrites a C3.2 submission fact on its own.
```

Conflict categories (§4's `RECOVERY_FACT_CONFLICT`), frozen as a
starting taxonomy - not exhaustive field-by-field equality rules, which
remain an implementation-time decision within this taxonomy:

```
ticket mismatch
order-vs-deal volume/status incompatibility
duplicate local identity
duplicate recovered identity
impossible timestamp ordering
unmappable recovered broker record  (-> RECOVERY_UNMAPPABLE_HISTORY_RECORD,
                                        not silently folded into CONFLICT)
```

**Frozen gate on corroboration/conflict emission**: C4.1 SHALL NOT emit
`RECOVERY_FACT_CORROBORATED` or `RECOVERY_FACT_CONFLICT` until the
compared field set and equality rules for the relevant fact class have
been specified in an adopted C4.1 comparison-semantics addendum. Until
that addendum is adopted, a matched identity (§6 primary/secondary key)
may produce only an informational identity-linked finding, never a
corroboration or conflict conclusion - the matching-key hierarchy above
determines *which* records are linked, not *whether* they agree, and
those are frozen as separate, independently-gated decisions.

---

## 7. Ownership map and write authorization

**C4.1 implementation-authorization checklist**: C4.0 (this document)
is a design contract only. C4.1 (its first implementation checkpoint)
is not implementation-authorized until both of the following hold:

```
1. C4.0 itself has been reviewed and adopted; and
2. a separately proposed and adopted C4.1 design addendum has frozen,
   at minimum:
   - the window-construction rule's overlap-allowance constant and any
     operator-supplied override (§3)
   - the recovered order/deal field schema in full
   - the compared-field-set and equality/comparison rules gating
     RECOVERY_FACT_CORROBORATED / RECOVERY_FACT_CONFLICT (§6)
   - the read-only report shape and ordering
```

Until both conditions hold, no C4.1 code - including any call to
`HistorySelect()` or its companion getters - may be written.

**Frozen, non-negotiable**: C4.0 (this contract) authorizes no writes of
any kind. C4.1 (the first implementation checkpoint this contract
authorizes) is read-only end to end and emits only an in-memory report -
no durable event, no file write, no registry mutation persisted beyond
the scan's own lifetime. Any durable recovery-audit event requires a
separately proposed, reviewed, and adopted contract amendment (a future
C4.2 or later) before any code implementing it is written - this keeps
C4.1's own review surface narrow and prevents scope creep into a durable
schema before broker-history semantics, selection-window behavior,
matching, and reconciliation outcomes have been validated against real
evidence first.

```
Permitted (read-only):
  EventStore / all sealed C3 projections (existing read accessors only)
  HistorySelect() + HistoryDealGet*/HistoryOrderGet* getters, only after
    an explicit, successful HistorySelect() call for that query

Permitted (write):
  none - C4.0 and C4.1 are zero-write, without exception

Explicitly excluded:
  OrderSend / CTrade
  Any candidate-lifecycle transition writer (EventStore_LogTransition)
  StateProjector mutation
  Any C3.2 raw-fact write/overwrite API
  SafeMode_Trip() / SafeMode_Clear()
  Any position/exit-lifecycle API (reserved for C6)
  Any durable event append of any kind (reserved for a future,
    separately adopted C4 amendment)
```

---

## 8. Future gates (unchanged, restated for continuity)

```
C4   - THIS document: recovery / broker-history policy. C4.0 design +
       C4.1 read-only first implementation only - no durable write, no
       lifecycle authority, no execution-gate authority.
C5   - controlled execution rollout: environment ladder (TEST FIXTURE ->
       DEMO DRY-RUN -> DEMO REAL-SUBMIT manual approval -> DEMO bounded
       automation -> LIVE shadow -> LIVE manual micro-size -> LIVE
       bounded automation). Future consumer of C4's read-only posture.
C6   - position / exit lifecycle (unchanged scope from prior contracts).
C7   - operational hardening (unchanged scope from prior contracts).
```
