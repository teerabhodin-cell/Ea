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

---

## 9. C4.1 Design Addendum (PROPOSED - not yet adopted)

**Status**: proposed following C4.1 Contract-Reconciliation Checkpoint 1
(QA re-review, second pass); docs-only, non-authoritative. This
addendum does not itself authorize any C4.1 code. It exists to satisfy
the gates §3, §6, and §7 (above) require before any `HistorySelect()`
call, comparison logic, or report struct may be written. Every
identifier, `#define`, and `struct` shown in this section is **planned
pseudocode**, not implemented source: the future C4.2 implementation
SHALL expose these identifiers and shapes; this addendum does not
create any of them in source code, and no header, macro, input
declaration, report struct, or test exists as a result of this
section.

### 9.1 Deliberate boundary: execution-completion semantics vs. recovery-evidence corroboration

C3.3's `running_filled_volume >= execReq.lot_size` rule (`TX_MATCH_VOLUME_REACHED`)
answers a different question than C4.1 asks. C3.3 asks whether the
*local* projection regards a requested quantity as reached. C4.1 asks
whether *locally recorded* recovery facts equal *broker-history*
evidence. These are not the same question and C4.1 SHALL NOT reuse
C3.3's threshold rule for corroboration. A broker-recovered deal-volume
total of `1.25` against a local `running_filled_volume` of `1.00` is a
`RECOVERY_FACT_CONFLICT`, in full, even though `1.00` may already
satisfy C3.3's own volume-reached threshold for unrelated local
purposes. The two rules are frozen as independent and are never merged.

### 9.2 Recovery-anchor time and window construction

```
Scan-time snapshot:
  history_query_server_time is captured exactly once per reconciliation
  scan (one TimeCurrent() call). Every recovered fact emitted from that
  same scan carries that identical captured value - never a fresh
  TimeCurrent() call per record.

Window:
  query_from = recovery_anchor_time - effective_overlap_minutes
  query_to   = the single captured history_query_server_time for this scan
  Both endpoints are inclusive (restates §3's existing inclusive-bounds rule).

Effective overlap:
  effective_overlap_minutes = the future implementation's operator
  override, when validly supplied; otherwise the planned
  MLQUANTAI_C4_RECOVERY_OVERLAP_MINUTES_DEFAULT identifier's frozen
  value of 60, for v1.

Invalid override:
  An explicitly supplied override value <= 0 is invalid. It SHALL NOT be
  silently replaced with the 60-minute default or any other fallback.
  This is a whole-scan failure, evaluated once, before any per-row
  finding is computed: the report is fail-closed with zero rows -
  report.ok = false, first_error identifies the invalid-override
  condition, and no ENUM_RECOVERY_FINDING value (including
  RECOVERY_NO_CORROBORATING_HISTORY) is emitted for any individual
  fact as a result of this failure - mirroring the existing
  unresolvedThresholdSeconds < 0 precedent (C3.8.1).
```

The future C4.2 implementation SHALL expose the following identifier
and frozen value; this addendum does not create the identifier in
source code:

```cpp
// planned identifier - not yet implemented
#define MLQUANTAI_C4_RECOVERY_OVERLAP_MINUTES_DEFAULT 60
```

`recovery_anchor_time` itself (the local timestamp a given fact's
window is anchored to) is not fixed by this addendum - it is whichever
local fact's own durable timestamp is under review, per §3's existing
"earliest durable local timestamp relevant to the fact" rule. This
addendum only freezes how the window is *built* from that anchor, not
which anchor a given comparison uses.

### 9.3 Knownness discipline

```
A zero numeric value (0, 0.0, empty string) is never an implicit
"unknown" sentinel. Every broker-derived comparable field that may be
unavailable from a given history record carries its own explicit
"<field>_known" boolean. A field is compared only when its knownness
flag is true on both sides of a comparison; an unknown field never
participates in a CORROBORATED or CONFLICT determination by silently
defaulting to a zero/empty value.

Local-side knownness:
  A local comparable value is known only when its source fact exists,
  its schema version is supported, and the contract-defined field was
  actually recorded on that fact. Absence of the local fact itself, or
  absence of a required local field on an otherwise-existing fact,
  produces RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE (§9.7) for that
  comparison - it is never defaulted to a zero/empty value and treated
  as "known."
```

### 9.4 Recovered fact schemas

The future C4.2 implementation SHALL expose the following identifiers;
this addendum does not create them in source code:

```cpp
// planned identifiers - not yet implemented
#define MLQUANTAI_RECOVERED_ORDER_HISTORY_SCHEMA_C4_V1 \
   "RECOVERED_ORDER_HISTORY_C4_V1"
#define MLQUANTAI_RECOVERED_DEAL_HISTORY_SCHEMA_C4_V1 \
   "RECOVERED_DEAL_HISTORY_C4_V1"
#define MLQUANTAI_RECOVERY_RECONCILIATION_SCHEMA_C4_V1 \
   "RECOVERY_RECONCILIATION_C4_V1"
```

The future C4.2 implementation SHALL expose recovered-fact structs of
the following planned shape; this addendum freezes the observable
schema semantics, not concrete MQL source:

```cpp
// planned shape - not yet implemented
struct RecoveredOrderHistoryFact
{
   string   schema_version;              // MLQUANTAI_RECOVERED_ORDER_HISTORY_SCHEMA_C4_V1
   string   provenance_kind;              // "RECOVERED_ORDER_HISTORY"
   datetime history_select_from;
   datetime history_select_to;
   datetime history_query_server_time;    // one capture per scan, see §9.2
   string   recovery_session_identity;
   ulong    source_order_ticket;
   bool     source_order_ticket_known;
   string   symbol;
   bool     symbol_known;
   string   order_type;
   bool     order_type_known;
   string   order_state;
   bool     order_state_known;
   double   volume_initial;
   bool     volume_initial_known;
   double   volume_current;
   bool     volume_current_known;
   double   price_open;
   bool     price_open_known;
   double   price_sl;
   bool     price_sl_known;
   double   price_tp;
   bool     price_tp_known;
};

struct RecoveredDealHistoryFact
{
   string   schema_version;              // MLQUANTAI_RECOVERED_DEAL_HISTORY_SCHEMA_C4_V1
   string   provenance_kind;              // "RECOVERED_DEAL_HISTORY"
   datetime history_select_from;
   datetime history_select_to;
   datetime history_query_server_time;
   string   recovery_session_identity;
   ulong    source_deal_ticket;
   bool     source_deal_ticket_known;
   ulong    source_order_ticket;          // parent order, per §9.8
   bool     source_order_ticket_known;
   string   symbol;
   bool     symbol_known;
   string   deal_type;
   bool     deal_type_known;
   double   price;
   bool     price_known;
   double   volume;
   bool     volume_known;
};
```

A recovered-fact struct without its declared `schema_version` field, or
without a knownness flag for every comparable field, does not satisfy
this addendum - both are frozen as part of the observable shape, not
left to implementation-time discretion.

### 9.5 Compared field sets, equality rules, and aggregate eligibility

```
No numeric or string tolerance/epsilon is introduced in v1. Every
compared field - symbol, order_type, price, volume - is exact equality
only. This is a deliberate absence: no rounding-tolerance convention
exists anywhere in this codebase to justify inventing one here, and
introducing one silently would weaken corroboration without a
documented reason.

Order vs. local:      symbol, order_type, volume_initial - exact equality
Partial-fill volume:   sum(recovered deal volumes for one
                        source_order_ticket, all volume_known=true)
                        == local running_filled_volume - EXACT equality
                        (not C3.3's >= threshold rule - see §9.1)

No standalone deal-vs-local comparison exists in C4.1 v1. C4.1 defines
no durable local deal-level identity and no comparable local deal
fields - only local order-level facts and the aggregate deal-volume
total are ever compared (see §9.6's ORDER and AGGREGATE_DEAL_VOLUME
comparison units). A recovered deal's symbol/deal_type/price/volume are
carried on RecoveredDealHistoryFact for provenance, aggregation, and
orphan/duplicate detection only - they are never compared directly
against a local fact of their own.

Aggregate eligibility:
  If any recovered deal that maps to the same source_order_ticket has
  volume_known=false, the aggregate volume for that order_ticket group
  is indeterminate - it SHALL NOT be computed by silently summing only
  the known-volume deals. An indeterminate aggregate cannot produce
  RECOVERY_FACT_CORROBORATED or RECOVERY_FACT_CONFLICT for that group
  (see §9.7's finding table).

Duplicate recovered evidence is a terminal normalization failure for
the affected identity group:

  If two or more recovered order facts share the same known
  source_order_ticket, no recovered order fact in that ticket group is
  eligible for corroboration/conflict comparison in that scan.

  If two or more recovered deal facts share the same known
  source_deal_ticket, no deal in that duplicate-ticket group is
  eligible for aggregate-volume corroboration/conflict comparison in
  that scan.

  The implementation SHALL emit RECOVERY_DUPLICATE_HISTORY_RECORD with
  BLOCK_RECOMMENDED posture for the affected group and SHALL NOT
  select, retain, sum, or treat any arbitrary duplicate copy as
  canonical.

  The duplicate finding takes precedence over subsequent
  aggregate-volume, CORROBORATED, or CONFLICT evaluation for the
  affected group (see §9.7's precedence rule).
```

### 9.6 Comparison units and row cardinality

```
C4.1 v1 emits findings by comparison unit, not by arbitrary source
enumeration order.

- ORDER unit:
  One eligible recovered order-history fact paired with one uniquely
  mapped local order fact. At most one order-level finding row is
  emitted per known source_order_ticket.

- DEAL unit:
  A recovered deal is not independently compared to a local fact unless
  a future adopted schema defines a durable local deal-level identity
  and comparable local deal fields. C4.1 v1 defines no such local
  deal-level mapping (see §9.5).

- AGGREGATE_DEAL_VOLUME unit:
  At most one aggregate-volume finding row is emitted per known
  source_order_ticket. It compares the sum of all eligible,
  non-duplicate, known-volume recovered deals for that ticket with the
  mapped local fact's running_filled_volume.

A RecoveryReconciliationRow SHALL identify its comparison unit
explicitly via a planned `comparison_scope` field whose frozen v1
values are `ORDER` and `AGGREGATE_DEAL_VOLUME` (see §9.9).

A recovered source_deal_ticket may be included for provenance in an
individual duplicate/orphan-deal finding, but it does not create a
standalone deal-versus-local corroboration/conflict row in C4.1 v1.

Diagnostic row cardinality:

  The one-row-per-ticket cardinality above governs only a *successful*
  ORDER or AGGREGATE_DEAL_VOLUME comparison outcome (RECOVERY_FACT_
  CORROBORATED, RECOVERY_FACT_CONFLICT, or RECOVERY_NO_CORROBORATING_
  HISTORY). The four terminal diagnostic findings below have their own
  frozen, independent cardinality rule, since they are not comparisons
  against a uniquely resolved local fact:

  - RECOVERY_UNMAPPABLE_HISTORY_RECORD:
    one row per recovered record whose source_order_ticket is
    unavailable or ambiguous. The row carries the recovered record's
    known source_deal_ticket where present; otherwise its known
    source_order_ticket where present.

  - RECOVERY_ORPHAN_HISTORY_ORDER:
    one row per recovered order-history record whose known
    source_order_ticket maps to zero eligible local facts.

  - RECOVERY_ORPHAN_HISTORY_DEAL:
    one row per recovered deal-history record that cannot attach to
    its required recovered order-history group under §9.8.

  - RECOVERY_DUPLICATE_HISTORY_RECORD:
    exactly one row per duplicate identity group: source_order_ticket
    for duplicate recovered order records; and source_deal_ticket for
    duplicate recovered deal records.

  These diagnostic rows use comparison_scope `ORDER` for order-record
  diagnostics and `AGGREGATE_DEAL_VOLUME` for deal-record diagnostics.
  They are not additionally constrained by the one-row-per-ticket
  cardinality of a successful ORDER or AGGREGATE_DEAL_VOLUME
  comparison - a single order_ticket group may legitimately produce
  multiple diagnostic rows (e.g. two distinct orphan deals attached to
  the same order ticket each get their own row), while at most one
  successful-comparison row (rows 8-10 of §9.7's table) is ever emitted
  for that same group.

  A diagnostic record/group that produces one of the four terminal
  diagnostic findings above is excluded from all later comparison-unit
  (ORDER/AGGREGATE_DEAL_VOLUME) evaluation for that record/group -
  matching §9.7's precedence rule, which already stops evaluation at
  the first qualifying finding.
```

### 9.7 Finding taxonomy, precedence, and posture

Every v1 `ENUM_RECOVERY_FINDING` value is given an explicit trigger and
posture below. This addendum does not add, remove, or rename enum
values - it only freezes how the 10 values apply to C4.1's specific
comparisons. Verified by direct inspection against this same document's
adopted §4 enum declaration (lines 151-181): all 10 names, in the same
order, with the same comments, are reproduced in the table below
exactly - no discrepancy exists between §4 and this table.

**Orphan vs. unmappable distinction (frozen)**, resolving an overlap in
an earlier draft of this table where an ambiguous condition could
satisfy both rows:

```
RECOVERY_UNMAPPABLE_HISTORY_RECORD:
  source_order_ticket is unknown/unavailable; OR
  the known ticket maps to more than one eligible local fact.

RECOVERY_ORPHAN_HISTORY_ORDER:
  source_order_ticket is known; and
  it maps to zero eligible local facts.

RECOVERY_ORPHAN_HISTORY_DEAL:
  source_order_ticket is known; and
  the recovered deal cannot be attached to a recovered order-history
  record for that ticket in the same normalized scan, while the
  applicable local order aggregate is otherwise resolvable.
```

| # | Finding | Comparison unit | Trigger | Posture |
|---|---|---|---|---|
| 1 | `RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE` | ORDER / AGGREGATE_DEAL_VOLUME | The required `HistorySelect()` query itself failed (returned `false`) for the relevant window | `DEGRADED` |
| 2 | `RECOVERY_WINDOW_INSUFFICIENT` | ORDER / AGGREGATE_DEAL_VOLUME | Window adequacy (§3/§9.2) cannot be proven - invalid bounds, coverage gap, or retention-limit truncation | `DEGRADED` |
| 3 | `RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE` | ORDER / AGGREGATE_DEAL_VOLUME | A required local fact or local field is unavailable (§9.3's local-side knownness rule) | `DEGRADED` |
| 4 | `RECOVERY_UNMAPPABLE_HISTORY_RECORD` | recovered-evidence-driven, no row-owning unit yet resolved | `source_order_ticket_known=false`, OR the known ticket resolves ambiguously to more than one eligible local fact | `BLOCK_RECOMMENDED` |
| 5 | `RECOVERY_DUPLICATE_HISTORY_RECORD` | ORDER (duplicate order tickets) / AGGREGATE_DEAL_VOLUME (duplicate deal tickets) | More than one recovered order or deal record shares the same known ticket within one scan's normalized snapshot (§9.5) | `BLOCK_RECOMMENDED` |
| 6 | `RECOVERY_ORPHAN_HISTORY_ORDER` | recovered-evidence-driven, ORDER | `source_order_ticket_known=true`, a valid key exists, and it maps to zero eligible local facts | `BLOCK_RECOMMENDED` |
| 7 | `RECOVERY_ORPHAN_HISTORY_DEAL` | recovered-deal-driven, AGGREGATE_DEAL_VOLUME | `source_order_ticket` is known but the deal cannot be attached to a recovered order-history record for that ticket in the same scan, while the local order aggregate is otherwise resolvable | `BLOCK_RECOMMENDED` |
| 8 | `RECOVERY_NO_CORROBORATING_HISTORY` | local-fact-driven, ORDER / AGGREGATE_DEAL_VOLUME | Local fact exists and mapping would resolve uniquely, window is adequate, local evidence is available, but no recovered evidence exists to compare - OR every applicable compared field is unknown on the recovered side (all-unknown), OR the aggregate-volume group is indeterminate per §9.5 | `DEGRADED` |
| 9 | `RECOVERY_FACT_CONFLICT` | ORDER / AGGREGATE_DEAL_VOLUME | Mapping resolved uniquely, all applicable compared fields are known on both sides, and one or more are unequal | `BLOCK_RECOMMENDED` |
| 10 | `RECOVERY_FACT_CORROBORATED` | ORDER / AGGREGATE_DEAL_VOLUME | Mapping resolved uniquely, all applicable compared fields are known on both sides, window is adequate, and every applicable field is exactly equal | `INFORMATIONAL` |

**Precedence rule (frozen)**: for a given comparison unit (§9.6),
findings are evaluated in the numbered order above; the first condition
that applies is the finding emitted, and evaluation stops - a
comparison unit is never assigned more than one finding. The
invalid-override condition in §9.2 is evaluated once, before this
per-unit table runs at all, and short-circuits the entire scan; it is
never itself one of the 10 per-row findings above.

**Reconciliation population (frozen)**: C4.1 v1 SHALL evaluate both
directions, and no single discrepancy SHALL produce more than one row:

```
Local-fact-driven evaluation:
  Every eligible local fact within the proven recovery scope is
  evaluated for a uniquely mapped recovered order-history fact. If none
  exists after a successful query and proven adequate window, emit
  RECOVERY_NO_CORROBORATING_HISTORY for that local fact's known broker
  order ticket. A local-fact-driven missing-evidence result owns
  RECOVERY_NO_CORROBORATING_HISTORY.

Recovered-evidence-driven evaluation:
  Every normalized recovered order-history fact is evaluated for a
  unique eligible local fact. A known ticket with zero eligible local
  matches emits RECOVERY_ORPHAN_HISTORY_ORDER; an unknown ticket or
  multiple eligible local matches emits
  RECOVERY_UNMAPPABLE_HISTORY_RECORD. A recovered-evidence-driven
  unmatched record owns an orphan or unmappable finding.

Recovered-deal-driven evaluation:
  Every normalized recovered deal is attached to its recovered order
  group by known source_order_ticket. Failure of that attachment under
  the stated preconditions emits RECOVERY_ORPHAN_HISTORY_DEAL.

These three directions apply to distinct directional facts (a local
fact with no recovered match; a recovered order with no local match; a
recovered deal that cannot attach to its order) and SHALL NOT both be
emitted for the same discrepancy - each finding in the §9.7 table is
owned by exactly one of the three directions above, never by more than
one, and an implementation SHALL NOT emit a duplicate row from the
other direction for the same comparison unit.
```

**Two mapping decisions, adopted as part of this addendum** (both
reviewed and approved; the second carries an added limiting condition):

```
1. Ambiguous multi-match (a known source_order_ticket resolves to more
   than one eligible local fact) is classified as RECOVERY_UNMAPPABLE_
   HISTORY_RECORD, distinct from RECOVERY_ORPHAN_HISTORY_ORDER (which
   requires zero matches, not multiple) - see the orphan-vs-unmappable
   distinction above. Reasoning: §6's "never a silent best-effort
   match" rule means a non-unique resolution is not a resolution at
   all - it is exactly the "cannot be resolved to any matching key"
   case UNMAPPABLE covers.

2. A recovered record whose every applicable compared field is unknown
   (e.g. all deal_type/price/volume fields unavailable) is classified
   as RECOVERY_NO_CORROBORATING_HISTORY, not RECOVERY_HISTORY_EVIDENCE_
   UNAVAILABLE (reserved specifically for HistorySelect() itself
   failing, per row 1 above). This classification applies only after a
   successful query and a proven adequate window: if window adequacy is
   not proven, RECOVERY_WINDOW_INSUFFICIENT wins by precedence (row 2);
   if required local-side evidence is unavailable,
   RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE wins by precedence (row 3). This
   ordering is already enforced by the numbered precedence rule above -
   stated here explicitly so RECOVERY_NO_CORROBORATING_HISTORY never
   masks a stronger diagnostic.
```

`RECOVERY_FACT_CORROBORATED`/`RECOVERY_FACT_CONFLICT` remain gated by
C4.0 §6's existing rule: neither may be emitted until this addendum
(satisfying that gate) is itself adopted.

### 9.8 Identity mapping restriction (v1: `source_order_ticket`-only)

```
C4.1 v1 identity mapping is source_order_ticket-only. A recovered order
or deal may be reconciled only where its source_order_ticket is known
and maps uniquely to a local fact's recorded broker order ticket.
source_deal_ticket identifies a recovered deal record but is not an
alternate local-fact mapping key - a deal is always matched to its own
order-history fact first, by source_order_ticket, per §9.4/§9.5, never
directly to a local fact on its own.

No secondary matching key is authorized in C4.1 v1. No correlation ID,
magic number, symbol, order/deal type, volume, price, time, or any
field-similarity fallback may establish identity. A future secondary
key requires a separately adopted schema, provenance, uniqueness, and
comparison-rule amendment - it is not authorized by this document.
```

### 9.9 Report shape, ordering, and `ok` computation

The future C4.2 implementation SHALL expose report/row structs of the
following planned shape; this addendum does not create them in source
code:

```cpp
// planned shape - not yet implemented
struct RecoveryReconciliationRow
{
   string                 candidate_id;      // when resolvable; else empty
   ulong                  order_ticket;
   bool                   order_ticket_known;
   ulong                  deal_ticket;
   bool                   deal_ticket_known;
   string                 comparison_scope;   // "ORDER" | "AGGREGATE_DEAL_VOLUME" - see §9.6
   ENUM_RECOVERY_FINDING  finding;
   ENUM_RECOVERY_POSTURE  posture;
   string                 source_record_discriminator; // ordering tiebreaker only - see below; NOT an id/hash/durable trace
   string                 detail;             // human-readable, never parsed
};

struct RecoveryReconciliationReport
{
   string                    schema_version;  // MLQUANTAI_RECOVERY_RECONCILIATION_SCHEMA_C4_V1
   bool                      ok;
   int                       local_facts_scanned;
   int                       recovered_orders_scanned;
   int                       recovered_deals_scanned;
   RecoveryReconciliationRow rows[];
   string                    first_error;
};
```

```
source_record_discriminator:

  A deterministic, non-durable provenance discriminator for ordering
  diagnostic rows only. It is derived solely from frozen recovered-fact
  fields, in canonical field order, and is not a hash or a durable
  identity - it authorizes no persistence and is used only as an
  in-memory deterministic ordering tiebreaker (§9.10/§9.11's zero-write,
  no-row-hash decisions are unaffected).

  For recovered order diagnostics, the discriminator is the canonical
  serialization of: schema_version, provenance_kind,
  history_select_from, history_select_to, history_query_server_time,
  recovery_session_identity, source_order_ticket_known,
  source_order_ticket, symbol_known, symbol, order_type_known,
  order_type, order_state_known, order_state.

  For recovered deal diagnostics, it is the canonical serialization of:
  schema_version, provenance_kind, history_select_from,
  history_select_to, history_query_server_time,
  recovery_session_identity, source_deal_ticket_known,
  source_deal_ticket, source_order_ticket_known, source_order_ticket,
  symbol_known, symbol, deal_type_known, deal_type, price_known, price,
  volume_known, volume.

  A row not produced by one of the four terminal diagnostic findings
  (§9.6's diagnostic-row-cardinality rule) carries an empty
  source_record_discriminator - it is needed only where sort keys 1-5
  can collide, which happens only among diagnostic rows lacking a known
  ticket or candidate_id.

Canonical duplicate collapse:

  Two recovered records are the same normalized evidence item when
  their applicable canonical serialization (as defined above) is
  byte-for-byte identical. C4.1 v1 intentionally does not preserve raw
  API occurrence multiplicity for such identical records, because no
  separately frozen durable broker occurrence identity exists for that
  purpose.

  The implementation SHALL normalize identical records to one
  canonical evidence item before diagnostic and comparison-row
  construction. This collapse is distinct from
  RECOVERY_DUPLICATE_HISTORY_RECORD, which applies when two records
  share a known broker ticket but are not the same canonical
  normalized evidence item.

  No API enumeration position, array index, or discovery order may be
  used as an occurrence discriminator.
```

```
Sort order (final, deterministic):
  1. order_ticket ascending, among rows where order_ticket_known=true -
     these sort before all rows where order_ticket_known=false.
  2. deal_ticket ascending, among rows where deal_ticket_known=true -
     these sort before all rows where deal_ticket_known=false, applied
     as the tiebreaker within equal order_ticket groups.
  3. comparison_scope ascending in its frozen canonical order: ORDER
     before AGGREGATE_DEAL_VOLUME, applied as the tiebreaker within
     equal order_ticket/deal_ticket groups.
  4. candidate_id ascending.
  5. finding enum ordinal ascending (§4's declared enum order), as a
     final defensive tiebreaker.
  6. source_record_discriminator ascending, as the final tiebreaker for
     diagnostic rows that remain identical on all of keys 1-5.
  A ticket value of 0 is never itself evidence that a row is
  unticketed - only the paired *_known flag decides sort-group
  membership. No two emitted rows may remain indistinguishable after
  all six keys, because identical recovered records are normalized and
  collapsed before row construction under the canonical-duplicate-
  collapse rule above.

first_error selection:
  Taken from the first row, in the final sorted order above, whose
  posture is RECOVERY_POSTURE_DEGRADED or RECOVERY_POSTURE_BLOCK_
  RECOMMENDED (i.e. makes report.ok=false per the rule below). Never
  taken from discovery order, API enumeration order, or any
  intermediate detection-witness position - matching the C3.8.1
  earliest-qualifying-tuple precedent, not the detection-witness bug
  corrected there.

Posture-to-ok rule (frozen disposition model):
  Each finding's posture is exactly one of RECOVERY_POSTURE_
  INFORMATIONAL, RECOVERY_POSTURE_DEGRADED, or RECOVERY_POSTURE_
  BLOCK_RECOMMENDED, per the §9.7 table (RECOVERY_FACT_CORROBORATED is
  always INFORMATIONAL; RECOVERY_FACT_CONFLICT is always
  BLOCK_RECOMMENDED; every other v1 finding has its own frozen posture
  in that same table - none is left undefined).

  report.ok = true only when ALL of:
    - invocation/configuration is valid (including a valid effective
      overlap per §9.2 - an invalid override fails the scan before any
      row exists, per §9.2/§9.7's precedence rule);
    - all required history-query steps succeeded;
    - window adequacy is proven where required (§3); and
    - no final sorted row carries posture RECOVERY_POSTURE_DEGRADED or
      RECOVERY_POSTURE_BLOCK_RECOMMENDED.

  A report with zero rows is NOT automatically ok=true - its status
  still depends on whether the expected/local fact set was itself
  empty and whether adequate evidence coverage was proven for that
  empty result; an empty row set produced by a failed or unproven scan
  is not informational.
```

### 9.10 Boundary (restated, unchanged from C4.0 §5/§7)

```
The C4.1 report remains: read-only, non-durable, non-authoritative.
No EventStore append. No StateProjector mutation. No lifecycle
transition. No SafeMode action. No trade action (OrderSend/CTrade).
```

### 9.11 Deferred items

```
Row identity hash:
  A RecoveryReconciliationRow identity hash (analogous to
  Ids_ExecutionRequestId) is explicitly NOT minted in C4.1. Findings
  are non-durable per C4.0 §2; a hash is deferred to whichever future,
  separately adopted amendment first proposes any durable trace of a
  recovery finding.

Operator override input:
  The concrete input declaration (name, EA/script placement, validity
  wiring) for the overlap-minutes override is left to the
  implementation-authorizing checkpoint (C4.2) that actually writes
  code. This addendum freezes only the override's semantics (§9.2),
  not its declaration.

Standalone deal-vs-local comparison:
  Deferred, per §9.5/§9.6, to a future amendment that would need to
  define a durable local deal-level identity and comparable local deal
  fields before any DEAL comparison unit could exist.
```

### 9.12 C4.2 gate (restated)

Per §7's existing checklist, C4.1's own code (including any
`HistorySelect()`/`HistoryDealGet*`/`HistoryOrderGet*` call) remains
unauthorized until this addendum itself is adopted. Once adopted, the
next gate is C4.2: read-only broker-history acquisition and report
implementation, still zero-write per §7, exercising exactly the
schemas, window rule, comparison units, equality rules, and report
shape frozen above - not a re-opening of any decision this section
freezes.

---

## 10. C4.2.1 Recovery-Anchor Provenance Addendum (PROPOSED)

**Status**: proposed following C4.2 Contract-Reconciliation
Implementation Checkpoint 1 research, which found that C4.2 cannot
construct the §9.2-required per-fact recovery window without a durable
local anchor timestamp, and that `ExecutionRequestProjectionRecord`
(the only local-fact source C4.2's design is authorized to depend on)
carries no such field. Docs-only, non-authoritative. This addendum does
not itself authorize any code change - it exists to satisfy that gate
before `ExecutionRequestProjectionRecord`, its apply function, or any
C4.2 file may be touched.

```
Purpose:
  Surface an already-durable execution-request creation timestamp into
  the execution-request read model solely as recovery-window
  provenance for C4.2.

Authoritative event:
  EVENT_TYPE_EXECUTION_REQUEST_CREATED only.

Authoritative source field:
  the parsed SystemEvent.base.ts from the existing base-envelope "ts"
  field - already durably written by EventStore_AppendSystem via
  TimeCurrent() at emission time, and already parsed back by
  EventSerializer_ParseSystem on every rebuild. This addendum
  introduces no new event, no new clock, no new wire field. For events
  emitted by the supported EventStore writer path,
  EVENT_TYPE_EXECUTION_REQUEST_CREATED carries the base-envelope "ts"
  field; it is merely never copied from the already-parsed SystemEvent
  into the projection's own record today. This addendum makes no claim
  that every retained historical/imported event line satisfies the
  supported-writer invariant - see the unsupported/corrupt timestamp
  rule below.

Projection fields:
  datetime recovery_anchor_time;
  bool     recovery_anchor_time_known;

Set rule (first-known-timestamp, frozen):
  For one execution_request_id, the projection may set
  recovery_anchor_time only when recovery_anchor_time_known is
  currently false AND the currently replayed supported
  EXECUTION_REQUEST_CREATED event has a non-zero parsed base.ts.

  When replay processes an EVENT_TYPE_EXECUTION_REQUEST_CREATED line that
  has successfully parsed as a SystemEvent:
  - If recovery_anchor_time_known is false and e.base.ts != 0:
    set recovery_anchor_time=e.base.ts and
    recovery_anchor_time_known=true.
  - If recovery_anchor_time_known is false and e.base.ts == 0:
    retain recovery_anchor_time=0 and
    recovery_anchor_time_known=false.
  - If recovery_anchor_time_known is true:
    make no change regardless of e.base.ts.
  - A line that cannot parse as a SystemEvent continues to follow the
    projection's pre-existing parse/error behavior; C4.2.1 does not alter
    that behavior.

No-overwrite rule (frozen, both directions):
  Once recovery_anchor_time_known becomes true for an execution-request
  record, it is immutable for the remainder of the rebuild and across
  subsequent replayed events. Specifically:
  - A later event with base.ts == 0 does NOT clear an already-known
    anchor.
  - A later event with a different non-zero base.ts does NOT overwrite
    an already-known anchor and must not create a new recovery-anchor
    value - the first known value stands.
  - No later replayed event, duplicate request event, broker
    observation, order aggregate, deal record, runtime clock, or
    terminal clock may replace an already-known stored value.
  - If the first encountered request event for that execution_request_id
    has unknown time (base.ts == 0) and a later duplicate has a
    non-zero time, that later non-zero time becomes the first known
    anchor - "first known", not "first encountered", is what the
    no-overwrite rule protects.

Unsupported/corrupt timestamp:
  A missing, empty, malformed, unparsable, or zero-valued "ts" is
  handled as unknown recovery-anchor provenance
  (recovery_anchor_time = 0, recovery_anchor_time_known = false). This
  condition does not reject the projection rebuild. It preserves
  honest unknownness for legacy, imported, manually edited, corrupted,
  or otherwise unsupported event lines. This is a defensive
  compatibility path - C4.2.1 makes no claim that all retained
  historical/imported event lines satisfy the supported-writer
  invariant.

C4.2 use:
  LocalOrderRecoveryFact copies these two fields unchanged. C4.2 uses
  the anchor only to construct the §9.2 window:
  [recovery_anchor_time - effective_overlap_minutes, scan_server_time].
  It does not use the anchor to infer identity, symbol, volume, fill
  state, lifecycle authority, or trading authority - it remains pure
  provenance, exactly as C4.0 §2's "distinguishes one recovery scan
  from another" provenance fields already are.

Compatibility (frozen, zero-impact):
  No event format change.
  No EventStore write-path change.
  No serializer change.
  No hash input/output change - execution_request_hash is computed
    from a separate ExecutionRequest struct, never from
    ExecutionRequestProjectionRecord; the new fields never enter any
    hashed payload.
  No execution_request_id change.
  No C4 schema constant or version bump required - this is a read-model
    addition over an already-durable field, not a wire-format change.
```

### 10.1 Required implementation tests (obligation only - not created by this addendum)

| Test obligation | Expected behavior |
|---|---|
| Valid timestamp | `recovery_anchor_time_known=true`; stored time exactly equals the parsed event's `base.ts` |
| Invalid/empty timestamp | knownness false; stored time `0`; rebuild still succeeds |
| Replay repeatability | Two rebuilds from identical input yield the same anchor and knownness |
| Known then later known/different | First known value remains unchanged |
| Known then later unknown | Known value remains unchanged |
| Unknown then later known | Later first-known timestamp is accepted |
| Unknown then later unknown | Anchor stays `0`, knownness stays false |
| Existing fields unchanged | `candidate_id`, `side`, `lot_size`, `execution_request_hash`, `execution_request_id` are unchanged by provenance surfacing |
| C4.2 propagation | The local DTO copies the anchor unchanged; the constructed query window's start obeys `anchor - effective_overlap` |
| Safety | No new event append, serializer mutation, lifecycle/SafeMode/trade behavior, or EventStore state change results from this addendum |

### 10.2 Gate restated

`ExecutionRequestProjectionRecord`, its `_Init` function, and
`ExecutionRequestProjection_ApplyLine` remain unmodified until this
addendum is reviewed and adopted. C4.2's own implementation
authorization (paused per §9.12) remains separately gated behind both
this addendum's adoption and a revised code/test authorization for the
C4.2 allowlist itself - adopting this addendum alone does not
reinstate C4.2's implementation authorization.

## 11. C4.3 Recovery Window-Adequacy Evidence Contract (ADOPTED; v1 implemented)

This section's contract text was adopted via PR #11 (merge commit
`1f63800037a439066273473e42a4dbc77c8da71b`). No code, test, or schema
in the merged C4.2 implementation was changed by adopting this text.

A first implementation checkpoint (v1) was separately authorized,
built, and merged: PR #12 (implementation commit `beb60db`,
integration merge commit `5ab1cf0`) delivers the
`RecoveryCoverageAttestation` schema (§11.3), the
`ICoverageAttestationSource` boundary (§11.5),
`ParameterCoverageAttestationSource` as v1's only implemented concrete
source, the two pure evaluator functions (§11.6), and the full 25-case
test matrix (§11.10): 57/57 checks passed, with the C4.2 suite
unaffected (143/143 regression checks passed, matching the sealed
baseline). `CsvStaticCoverageAttestationSource`, though authorized by
§11.5, was deferred out of v1's implementation scope to a separate
C4.3.1 checkpoint and does not exist yet.

Before this v1 merge, `RecoveryReconciliation_ScanLive`'s original
four-argument signature never set `RECOVERY_WINDOW_ADEQUACY_PROVEN`:
no retention-proof mechanism existed. That signature is preserved
unchanged through a `NullCoverageAttestationSource` wrapper and still
never sets `PROVEN`. The new five-argument overload added by C4.3 v1
can resolve `PROVEN` when a usable attestation is supplied and covers a
given local fact's required window (§11.7/§11.8); this was the gap
C4.3 v1 closed. No `MLQuantAI.mq5` call site constructs or configures
an attestation source yet; runtime wiring is reserved for a future
checkpoint.

### 11.1 Purpose and non-goals

Purpose: define a deterministic, fail-closed contract by which a
locally supplied, non-live coverage attestation may be compared
against the broker-history query window actually used for a given
local fact, producing a tri-state adequacy verdict
(`UNASSESSED`/`PROVEN`/`INSUFFICIENT`) for that fact's ORDER/DEAL
comparison units.

Non-goals, explicitly out of scope for this contract:
  It does not claim that MQL5 `HistorySelect()` returning `true` proves
    broker-side history completeness or retention. `HistorySelect()`
    success proves only that the selection request itself succeeded,
    including for a legitimately empty result - never a retention or
    completeness certificate.
  It does not add any live broker-retention query, live calendar-style
    fetch, or network call of any kind. All coverage evidence is
    supplied, never fetched, by design (see §11.5).
  It does not modify the frozen §9.4 provenance-field schema, the
    §9.9 canonical duplicate-collapse rule, or the existing
    `ENUM_RECOVERY_FINDING` taxonomy.
  It does not add symbol-scoped coverage. Per C4.2 v1 Option B, the
    local symbol is architecturally always unknown, so the ORDER
    comparison unit already always resolves to
    `RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE`; symbol-scoped attestation
    would have no comparison unit to inform in v1 and is deferred
    (§11.11).
  It does not make any cryptographic integrity claim about a supplied
    attestation. The `integrity_identifier` field (§11.3) is a
    schema-recognition marker only, not a signature or hash guarantee.

### 11.2 Definitions

Required window: the broker-history query window that was actually
  used to evaluate one specific local fact, i.e. the per-fact window
  derived from that fact's own recovery anchor and the effective
  overlap (per §9.2/§10), not a scan-wide aggregate. Adequacy is
  always evaluated per local fact, never once per scan (§11.7).

Attestation: a locally supplied, static
  `RecoveryCoverageAttestation` record (§11.3) asserting that a named
  broker/account/time-basis combination's history is retained and
  queryable across a stated `[coverage_from, coverage_to]` interval,
  valid through a stated `valid_until` time.

Attestation usability: an attestation is usable for a given scan only
  if it classifies as `RECOVERY_COVERAGE_EVIDENCE_VALID` under
  `RecoveryCoverage_ClassifyEvidence` (§11.8) - present, well-formed,
  matching broker/account/time-basis identity exactly, and not stale
  as of the caller-supplied evaluation time.

Tri-state semantics:
  `RECOVERY_WINDOW_ADEQUACY_UNASSESSED` remains the fail-closed
    default. It is returned whenever usable coverage evidence is
    absent, invalid, mismatched, or stale, or whenever the underlying
    `HistorySelect()` query itself did not succeed - never inferred as
    a pass.
  `RECOVERY_WINDOW_ADEQUACY_PROVEN` is returned only when a usable
    attestation's `[coverage_from, coverage_to]` interval fully
    contains the fact's required window AND the underlying history
    query for that fact succeeded.
  `RECOVERY_WINDOW_ADEQUACY_INSUFFICIENT` is returned when a usable
    attestation exists but its interval does not fully contain the
    required window, regardless of whether the history query
    succeeded (§11.8 step 3 is evaluated before step 4).

### 11.3 Attestation schema

```cpp
struct RecoveryCoverageAttestation
{
   string   broker_identity;
   string   account_identity;
   string   server_time_basis;
   datetime coverage_from;
   datetime coverage_to;
   datetime valid_until;
   string   issuer_identity;
   string   evidence_reference;
   string   integrity_identifier;
};
```

`broker_identity`/`account_identity`/`server_time_basis` identify the
scope the attestation applies to. `coverage_from`/`coverage_to` state
the interval the issuer asserts is retained and queryable.
`valid_until` states the time after which the attestation must no
longer be trusted. `issuer_identity` and `evidence_reference` are
free-form provenance/audit fields, not compared by the evaluator.
`integrity_identifier` is a fixed schema-recognition marker (§11.4).

### 11.4 Identity, time-basis, and integrity-marker comparison rules

All identity and time-basis comparisons performed by
`RecoveryCoverage_ClassifyEvidence` (§11.8) are byte-for-byte exact
string comparisons. No case-folding, whitespace-trimming, alias
resolution, locale-aware conversion, or default-value substitution is
permitted at any step. An empty `broker_identity`,
`account_identity`, or `server_time_basis` field on either the scan
side or the attestation side fails classification at Tier 1 (treated
as a mismatch, never as a wildcard or "unspecified" match).

`integrity_identifier` must equal exactly the literal string
`"RECOVERY_COVERAGE_ATTESTATION_C4_V1"`. Any other value, including a
case-variant or trimmed variant, classifies the attestation as
`RECOVERY_COVERAGE_EVIDENCE_INVALID`. This marker is a
schema-recognition check only - it identifies that the record was
constructed against this contract's schema version. It is explicitly
NOT a cryptographic integrity guarantee; verifying that an
attestation has not been tampered with or forged is out of scope for
C4.3 v1 and is deferred to a hypothetical future trust/credential
contract (§11.11).

### 11.5 ICoverageAttestationSource boundary

```cpp
class ICoverageAttestationSource
{
public:
   virtual bool TryGet(
      string broker_identity,
      string account_identity,
      RecoveryCoverageAttestation &out_attestation,
      string &out_reason
   ) = 0;
};
```

No `ICoverageAttestationSource` implementation may perform a network
call, live broker query, terminal-history query, or any external live
fetch in C4.3 v1. Implementations may read only operator/system-supplied
static inputs, including configured parameters or a locally supplied
static file, and must not mutate state.

Authorized v1 implementations: `CsvStaticCoverageAttestationSource`
(reads a locally supplied static file) and
`ParameterCoverageAttestationSource` (reads configured EA input
parameters). Explicitly forbidden in v1: `LiveBrokerCoverageAttestationSource`
or any other implementation that performs a live or network fetch -
this is a hard boundary, not a default.

This mirrors the Phase B `INewsSource`/`CsvStaticNewsSource`/
`LiveCalendarNewsSource` precedent, restricted here to only the
static side of that split.

| Responsibility | Component |
|---|---|
| Broker-history query execution | `IHistorySource` (frozen, C4.2) |
| Coverage-attestation retrieval | `ICoverageAttestationSource` (new, C4.3) |
| Deterministic adequacy computation | `RecoveryCoverage_Evaluate` / `RecoveryCoverage_ClassifyEvidence` (new, pure) |
| Sequencing, single attestation fetch per scan, per-fact evaluation calls | `RecoveryReconciliation_ScanLive` (existing orchestrator, extended) |

### 11.6 Pure evaluator functions

```cpp
enum ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS
{
   RECOVERY_COVERAGE_EVIDENCE_ABSENT = 0,
   RECOVERY_COVERAGE_EVIDENCE_VALID,
   RECOVERY_COVERAGE_EVIDENCE_INVALID,
   RECOVERY_COVERAGE_EVIDENCE_STALE,
   RECOVERY_COVERAGE_EVIDENCE_BROKER_MISMATCH,
   RECOVERY_COVERAGE_EVIDENCE_ACCOUNT_MISMATCH,
   RECOVERY_COVERAGE_EVIDENCE_TIME_BASIS_MISMATCH
};

ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS RecoveryCoverage_ClassifyEvidence(
   bool     attestation_present,
   const RecoveryCoverageAttestation &attestation,
   string   scan_broker_identity,
   string   scan_account_identity,
   string   scan_server_time_basis,
   datetime evaluation_time
);

ENUM_RECOVERY_WINDOW_ADEQUACY RecoveryCoverage_Evaluate(
   datetime required_from,
   datetime required_to,
   datetime evaluation_time,
   bool     history_select_succeeded,
   const RecoveryCoverageAttestation &attestation,
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS evidence_status
);
```

Both functions are pure. Neither may call `TimeCurrent()`,
`TimeLocal()`, `GetTickCount()`, `MathRand()`, or read any global or
static state. `evaluation_time` is always supplied by the caller
(the orchestrator's single §9.2/§10 capture point), never read
internally. `RecoveryCoverage_Evaluate` takes `evidence_status` as an
input rather than re-deriving it or taking a redundant
`attestation_present` flag - evidence classification and adequacy
evaluation are two separate pure steps, each independently testable.

### 11.7 Per-local-fact evaluation rule and orchestrator sequencing

`RecoveryCoverage_Evaluate` is called once per local fact, using that
fact's own required window (§11.2) - never once per scan against an
aggregate window. Two local facts in the same scan, evaluated against
the same attestation, may legitimately receive different verdicts.

Worked example: a scan holds two local facts, Order A (recovery
anchor 09:00) and Order B (recovery anchor 06:00), both evaluated
against the same supplied attestation with
`coverage_from=07:00, coverage_to=12:00`. Order A's required window
(anchor 09:00 minus overlap, forward) falls entirely inside
`[07:00, 12:00]` and its history query succeeded, so Order A resolves
to `PROVEN`. Order B's required window extends back to before 07:00,
outside the attestation's covered interval, so Order B resolves to
`INSUFFICIENT` - in the same scan, against the same attestation.

Orchestrator sequencing (extends the existing `ScanLive` orchestrator,
does not replace it):
  1. Capture `scan_server_time` once, at the existing C4.2/§9.2 capture
     point (after local-registry validation, per the fail-closed-boundary
     fix already merged in C4.2).
  2. Fetch the coverage attestation once per scan (not once per fact)
     via the configured `ICoverageAttestationSource`, and classify it
     once via `RecoveryCoverage_ClassifyEvidence` using
     `scan_server_time` as `evaluation_time`.
  3. For each local fact, using its own required window and its own
     `history_select_succeeded` outcome, call `RecoveryCoverage_Evaluate`
     with the single shared attestation and the single shared
     evidence-classification result.

### 11.8 Evidence classification decision table

`RecoveryCoverage_ClassifyEvidence` evaluates the following conditions
in the stated order. The first matching non-`VALID` status wins - no
later condition in the table may overwrite a classification already
made by an earlier one.

| Order | Condition | Result |
|---|---|---|
| 1 | `attestation_present == false` | `ABSENT` |
| 2 | Malformed interval (e.g. `coverage_from > coverage_to`) or `integrity_identifier` is not exactly `"RECOVERY_COVERAGE_ATTESTATION_C4_V1"` | `INVALID` |
| 3 | `broker_identity` empty or not byte-exact equal to `scan_broker_identity` | `BROKER_MISMATCH` |
| 4 | `account_identity` empty or not byte-exact equal to `scan_account_identity` | `ACCOUNT_MISMATCH` |
| 5 | `server_time_basis` empty or not byte-exact equal to `scan_server_time_basis` | `TIME_BASIS_MISMATCH` |
| 6 | `valid_until == 0` or `evaluation_time > valid_until` | `STALE` |
| 7 | none of the above | `VALID` |

`RecoveryCoverage_Evaluate`'s decision order (frozen):

```
1. Required window (required_from/required_to) unavailable or invalid
   -> INSUFFICIENT
2. evidence_status != RECOVERY_COVERAGE_EVIDENCE_VALID
   -> UNASSESSED
3. attestation.coverage_from > required_from OR
   attestation.coverage_to   < required_to
   -> INSUFFICIENT
   (checked BEFORE step 4, regardless of history_select_succeeded)
4. history_select_succeeded == false
   -> UNASSESSED
5. otherwise
   -> PROVEN
```

### 11.9 Compatibility and non-mutation guarantees

C4.3 MUST NOT change:
  The 10 `ENUM_RECOVERY_FINDING` values, their order, or their
    severity/posture mapping.
  `RecoveryReconciliation_BuildReport`'s existing gate structure,
    beyond supplying real (non-`UNASSESSED`) adequacy values where the
    contract in this section allows it.
  `IHistorySource`'s existing getter-knownness discipline.
  The §9.9 canonical full-serialization duplicate-collapse rule or the
    §9.4 frozen provenance-field schema.
  C4.2.1's recovery-anchor semantics (§10).
  Any EventStore, serializer, lifecycle, SafeMode, or trade-execution
    behavior.

C4.3 MAY additively add: the `RecoveryCoverageAttestation` DTO, the
`ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS` enum, the
`ICoverageAttestationSource` seam and its authorized static
implementations, the two pure evaluator functions, and new
diagnostic-only fields or detail text on the existing report -
without adding any new `ENUM_RECOVERY_FINDING` value.

### 11.10 Required test matrix (obligation only - not created by this addendum)

The following 25 cases are the minimum obligation for a future C4.3
implementation checkpoint; none are created by this docs-only
addendum.

| # | Case |
|---|---|
| 1 | No attestation supplied -> `ABSENT` -> `UNASSESSED` |
| 2 | Attestation fully covers required window, query succeeded -> `PROVEN` |
| 3 | Attestation covers required window exactly at both boundaries -> `PROVEN` |
| 4 | Attestation partially covers required window (missing tail) -> `INSUFFICIENT` |
| 5 | Attestation partially covers required window (missing head) -> `INSUFFICIENT` |
| 6 | Attestation fully covers required window but query failed -> `UNASSESSED` |
| 7 | Attestation does not cover required window AND query failed -> `INSUFFICIENT` (step 3 precedes step 4) |
| 8 | `integrity_identifier` absent/empty -> `INVALID` -> `UNASSESSED` |
| 9 | `integrity_identifier` wrong literal value -> `INVALID` -> `UNASSESSED` |
| 10 | `integrity_identifier` case-variant of correct literal -> `INVALID` -> `UNASSESSED` |
| 11 | `broker_identity` empty on attestation -> `BROKER_MISMATCH` -> `UNASSESSED` |
| 12 | `broker_identity` mismatched (non-empty, different) -> `BROKER_MISMATCH` -> `UNASSESSED` |
| 13 | `broker_identity` differs only by case/whitespace -> still `BROKER_MISMATCH` (no folding/trimming) |
| 14 | `account_identity` empty -> `ACCOUNT_MISMATCH` -> `UNASSESSED` |
| 15 | `account_identity` mismatched -> `ACCOUNT_MISMATCH` -> `UNASSESSED` |
| 16 | `server_time_basis` empty -> `TIME_BASIS_MISMATCH` -> `UNASSESSED` |
| 17 | `server_time_basis` mismatched -> `TIME_BASIS_MISMATCH` -> `UNASSESSED` |
| 18 | `valid_until == 0` -> `STALE` -> `UNASSESSED` |
| 19 | `evaluation_time > valid_until` -> `STALE` -> `UNASSESSED` |
| 20 | `evaluation_time == valid_until` -> not stale, proceeds to coverage check |
| 21 | Required window unavailable/invalid for the fact -> `INSUFFICIENT` regardless of evidence status |
| 22 | Determinism: identical inputs to `RecoveryCoverage_ClassifyEvidence` and `RecoveryCoverage_Evaluate` yield identical outputs across repeated calls |
| 23 | Per-scan/per-fact independence: the §11.7 worked example (Order A `PROVEN`, Order B `INSUFFICIENT`, same scan, same attestation) |
| 24 | Coverage-gap-precedes-query-failure ordering proof: attestation both fails to cover the window and the query failed, result is `INSUFFICIENT`, never `UNASSESSED` |
| 25 | Structural proof: neither `RecoveryCoverage_ClassifyEvidence` nor `RecoveryCoverage_Evaluate` contains a call to `TimeCurrent()`, `TimeLocal()`, `GetTickCount()`, `MathRand()`, terminal/history APIs, file I/O, network APIs, EventStore write APIs, registry/projection mutation APIs, SafeMode APIs, or trade APIs; neither function reads global or static state |

### 11.11 Explicit future exclusions (out of scope for C4.3 v1)

  Symbol-scoped coverage attestation. Per C4.2 v1 Option B the local
    symbol is architecturally always unknown, so there is no
    comparison unit for symbol-scoped evidence to inform yet.
  Any live or network-fetching `ICoverageAttestationSource`
    implementation.
  Terminal-only retention inference (e.g. treating the oldest visible
    ticket as a completeness boundary) - rejected as unreliable and
    unimplementable safely (evidence Model B, rejected during C4.3
    research).
  A scan-level adequacy aggregate beyond diagnostic-only counts -
    adequacy remains strictly per local fact (§11.7).
  Cryptographic integrity/authenticity verification of a supplied
    attestation - deferred to a hypothetical future C4.4-style
    trust/credential contract.
