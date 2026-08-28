# C3.8 reconciliation integration design contract (documentation only)

**Status**: DESIGN ONLY, docs-only, frozen. No `.mqh`/`.mq5` file, no test
file, no `MLQuantAI.mq5` wiring, no new `ENUM_EVENT_TYPE` value, no new
`ENUM_REASON_CODE` value, no new projection struct/API actually added to
any sealed file, no edit to any sealed file (`StateProjector.mqh`,
`TransactionMatchingProjection.mqh`, `DeferredTransactionProcessor.mqh`,
`LifecycleAuthorityProcessor.mqh`, `AsyncTerminalOrderObservationMatcher.mqh`,
`AsyncTerminalRejectionAuthority.mqh`, `BrokerReconciliation.mqh`,
`CandidateProjection.mqh`, `EventStore.mqh`, `EventSerializer.mqh`), no
`OrderSend`/`CTrade`/`History*`/live `Position*` API, no compile, no test
run, no regression. Implementation remains its own, separately
authorized future step (C3.8 Commit 1+).

**Baseline**: `mlquantai@ef6b934` (C1–C3.7, C3.9, C3.10 sealed; C3.10's
six-commit stack — terminal rejection matcher/authority/audit/
diagnostics/health-trend/stacked-audit/acknowledgement — fast-forward
merged, PR #2).

**Predecessor**: this contract refines, and does not contradict, the
frozen roadmap entry in `Docs/PhaseC_C3_5_DeferredAuthorityContract.md`
§14 and the frozen three-way ownership separation in
`Docs/PhaseC_C3_TransactionReconciliationContract.md` §29. Where this
document is silent, those govern.

---

## 1. Purpose and the gap this contract closes

`Docs/PhaseC_C3_TransactionReconciliationContract.md` §29 named a gap and
explicitly left it unresolved:

> This document deliberately leaves `BrokerReconciliation`'s own blind
> spot (zero visibility into `CANDIDATE_SUBMITTED` candidates) unresolved
> - it is named here as a known gap, not fixed here.

C3.9 and C3.10 each closed a narrower, adjacent gap instead of this one:

```
C3.9  - cross-candidate execution-provenance conflict, scoped to
        CANDIDATE_EXECUTED events only.
C3.10 - delayed/asynchronous terminal rejection, cancellation, and
        expiry of an already-submitted order (C3.10A matcher,
        C3.10B authority, C3.10C/D/E1/F diagnostics/wiring proof,
        C3.10E2 human acknowledgement).
```

Neither gives visibility into the **general** case: a `CANDIDATE_SUBMITTED`
candidate that has no terminal evidence of *any* kind yet - no fill, no
rejection, no cancellation, no expiry, nothing. C3.8 is a **pure,
read-only diagnostic composition** over three already-sealed sources -
no new event type, no lifecycle authority, no broker query, no write of
any kind:

```
StateProjector (sealed)                  -> which candidate_ids are
                                             currently at state ==
                                             CANDIDATE_SUBMITTED
TransactionMatchingProjection (C3.3)      -> ENUM_TX_MATCH_STATUS for
                                             that candidate's order_ticket,
                                             if any raw observation exists
DeferredTransactionProcessor (C3.6)       -> current ENUM_RECOMMENDATION
                                             for that candidate, if a scan
                                             has produced one
(durable lifecycle log, scanned directly) -> this candidate's own
                                             CANDIDATE_SUBMITTED line, for
                                             submitted_at/sequence_number
```

**Why the direct log scan for `submitted_at`**: neither sealed source
carries a submission timestamp. `CandidateProjectionRecord.state` is
"always `CANDIDATE_CREATED` in this B6-only projection - B6 never applies
later transitions" (per its own doc comment), and
`StateProjector_TryGetState()` returns only the current
`ENUM_CANDIDATE_STATE`, no timestamp. C3.8 recovers
`submitted_at_server_time`/`submitted_sequence_number` by scanning the
durable lifecycle log for this `candidate_id`'s own
`CANDIDATE_SUBMITTED` line - the same `lines[]`-direct-scan pattern
C3.7's `C37_FindMatchingExecutedLine` and C3.9's
`ExecutionProvenanceConflictAuditor_ScanLines` already establish. This is
diagnostic **read** access to durable history, not authority; it appends
nothing.

---

## 2. Scope guard (frozen)

```
Docs only. This commit changes exactly two files:
  - Docs/PhaseC_C3_8_ReconciliationIntegrationContract.md (this file, new)
  - CHANGELOG.md (docs-only entry, DESIGN ONLY)
No new .mqh/.mq5 file. No test file. No MLQuantAI.mq5 wiring. No edit to
any sealed file. No OrderSend/CTrade/History*/live Position* API
anywhere. No candidate-lifecycle transition, no event append, no new
struct/enum value actually added to any .mqh file by this document -
every struct/enum shape below is a frozen SPEC for the future
implementation commit, not code shipped by this one.
```

---

## 3. Frozen invariant carried forward unchanged

Absence of a live position, and absence of any matching evidence, is
never itself a rejection (per C3.5/C3.6's frozen rejection-separation
rule). C3.8 reports such a candidate as **`unresolved`**, never
`REJECTED`. Only C3.10's rejection-matcher/authority chain is authorized
to determine or apply a rejection outcome; C3.8 must not duplicate,
infer, or shadow one.

---

## 4. Row shape (frozen SPEC - facts separated from policy)

The user's correction is adopted verbatim and is the load-bearing
decision of this contract: `unresolved` is an **evidence-only fact**,
computed strictly from whether any terminal evidence has been observed -
never from whether a recommendation exists. `DeferredTransactionProcessor`
can legitimately produce no recommendation, or `RECOMMEND_NONE`, for
reasons that are policy/evidence-completeness outcomes, not absence of
broker activity (e.g. a clean scan that simply hasn't reached this
row's eligibility clauses yet, or a benign partial-fill state) - folding
that into `unresolved` would mix a policy outcome into a factual
observation status.

```
struct SubmittedCandidateVisibilityRow
{
   string   candidate_id;
   ulong    order_ticket;

   // Recovered by direct log scan (section 1) - not from any projection.
   bool     submitted_at_known;          // false if the CANDIDATE_SUBMITTED
                                          // line could not be recovered (see
                                          // section 6) - do not fabricate 0.
   datetime submitted_at_server_time;    // valid only if submitted_at_known;
                                          // TimeCurrent()-clock, see section 5.
   long     submitted_sequence_number;   // valid only if submitted_at_known.

   ENUM_TX_MATCH_STATUS  match_status;      // real C3.3 status, or the
                                             // distinct NO_MATCH_YET sentinel
                                             // (section 7) - never conflated.
   bool                  match_status_known;// false if TransactionMatching
                                             // has no row for this order_ticket
                                             // at all (see section 7).

   bool                  recommendation_known;  // false if DeferredTransaction-
                                                 // Processor has not produced a
                                                 // row for this candidate yet.
   ENUM_RECOMMENDATION   recommendation;        // valid only if
                                                 // recommendation_known.
                                                 // Contextual visibility ONLY -
                                                 // see section 8.

   bool     terminal_rejection_observed; // true iff C3.10A's matcher has a
                                          // matched rejected/cancelled/expired
                                          // row for this order_ticket - read,
                                          // never re-derived.

   bool     age_known;                   // == submitted_at_known; restated
                                          // separately so a future caller
                                          // never has to infer one from the
                                          // other.
   int      age_seconds;                 // valid only if age_known. Server-
                                          // time age (section 5).

   bool     terminal_evidence_observed;  // == (match_status == TX_MATCH_
                                          //     VOLUME_REACHED) ||
                                          //    terminal_rejection_observed
                                          // Facts only - see section 4a.
   bool     unresolved;                  // == !terminal_evidence_observed
                                          // (frozen, section 4a). NEVER a
                                          // function of `recommendation`.

   // Optional, diagnostic-only, frozen as strictly separate from
   // `unresolved` (section 4b):
   bool     unresolved_beyond_threshold;
};
```

### 4a. `unresolved`, frozen

```
terminal_evidence_observed ==
   (match_status_known && match_status == TX_MATCH_VOLUME_REACHED)
   || terminal_rejection_observed

unresolved == !terminal_evidence_observed
```

`TX_MATCH_PARTIAL`, `TX_MATCH_AMBIGUOUS`, `TX_MATCH_UNMATCHED`, and
`NO_MATCH_YET` (no row at all) are all **not** terminal evidence - each
leaves `unresolved == true`. `TX_MATCH_ORDER_TERMINAL` stays reserved,
never assigned by C3.3 (unchanged); C3.8 must not treat its mere
existence as an enum member as evidence of anything.

Note: because C3.6/C3.7/C3.10B currently run as `OnInit`-only scans (not
per-tick), a row can legitimately show `terminal_evidence_observed ==
true` (e.g. `TX_MATCH_VOLUME_REACHED` just landed, or C3.10A just matched
a rejection) while `state` is still `CANDIDATE_SUBMITTED`, because the
owning authority (C3.7 or C3.10B) has not yet run its next `OnInit` pass
to act on that evidence. This is a real, expected window this diagnostic
must surface transparently, not paper over - it is exactly the kind of
visibility gap this contract exists to close.

### 4b. `unresolved_beyond_threshold`, frozen as strictly diagnostic

```
unresolved            == !terminal_evidence_observed;

unresolved_beyond_threshold ==
   unresolved &&
   age_known &&
   age_seconds >= unresolved_threshold_seconds;
```

**Explicit invariant, frozen**: `unresolved_beyond_threshold == false`
whenever `age_known == false`. The threshold condition may only fire
against `unresolved == true` **and** a valid, known age - never against
an unknown timestamp. Without this invariant stated explicitly, an
unknown-age row could silently fall through to "not beyond threshold"
even though the real fact is a diagnostic-data gap (no recoverable
submission timestamp), not a fresh/recent submission - the two must
never be conflated. (This invariant is already implied by the `&&
age_known` clause in the formula above; it is restated here as its own
named rule so a future implementer cannot drop the clause without also
visibly breaking a stated invariant.)

`unresolved_threshold_seconds` is a caller-supplied parameter to the
future scan function, not a hardcoded or global constant - the
implementation commit freezes its default and callers may override it.
**Explicitly frozen, non-negotiable**: this flag, at any threshold value,
must never cause a candidate-lifecycle transition, a broker action, a
recommendation override, a Safe Mode trip, or (later) a C5 execution
gate, from anywhere inside C3.8 itself. If a future phase (C5+) wants to
*consume* this flag as an input to some other decision, that is that
future phase's own, separately authorized wiring - not something this
contract or its implementation performs.

---

## 5. Clock (frozen)

`TimeCurrent()` only, everywhere in this component - never
`GetTickCount()`, never the terminal's local/UTC wall-clock time. Every
age value is explicitly a **server-time age**, and must be labelled as
such (field docs, log lines, any future UI) rather than left ambiguous
as just "age" - matching the frozen closed-bar/server-time discipline
already used throughout Phase B/C.

---

## 6. Missing/zero/future-dated/unrecoverable submission timestamp (frozen)

If the durable lifecycle log does not contain a recoverable
`CANDIDATE_SUBMITTED` line for a given `candidate_id` (truncated file,
rotated/archived store not supplied to this scan, or any other
recovery failure), or if a recovered timestamp is `0` or strictly in the
future relative to the current `TimeCurrent()` read at scan time:

```
When submitted_at_known == false, age_known == false.

age_seconds is semantically undefined when age_known == false.
Implementations may retain a zero-initialized storage value, but no
consumer, diagnostic formatter, threshold calculation, or control-flow
decision may read, display, compare, serialize, or interpret that
numeric field unless age_known == true.

Unknown age must be rendered as "unknown" (or an equivalent explicit
unknown representation), never as 0 seconds or a zero-duration age.
```

No age is ever fabricated. A `0`-or-future timestamp is treated as
"cannot be recovered", not as "age is 0" - the two are not the same
fact, and folding one into the other would silently manufacture false
freshness for a row whose real submission time is actually unknown or
corrupted. This supersedes the earlier draft's numeric `age_seconds = 0
(placeholder, never read)` phrasing, which risked being misread by a
future implementer as sanctioning `0` as a real, if unused, default
rather than stating the field as genuinely undefined in that case.

---

## 7. `NO_MATCH_YET` sentinel and the observation/match state ladder (frozen)

`ENUM_TX_MATCH_STATUS` (C3.3, sealed) is never extended by this
document - no new enum member is added to it. Instead, `match_status` on
`SubmittedCandidateVisibilityRow` is only meaningful when
`match_status_known == true`; when `TransactionMatchingProjection` has no
record at all for this candidate's `order_ticket`,
`match_status_known = false` and `match_status` is left at its struct
default, never coerced into a real `ENUM_TX_MATCH_STATUS` value. Any
future implementation-side serialization (e.g. for a log line or export
row) that needs a single display token for "no row exists yet" must use
a distinct, out-of-band sentinel string (e.g. `"NO_MATCH_YET"`) that
cannot collide with `TxMatchStatusToString()`'s real output values
(`"UNMATCHED"`, `"AMBIGUOUS"`, `"MATCHED_PARTIAL"`,
`"MATCHED_VOLUME_REACHED"`, `"MATCHED_ORDER_TERMINAL"`) - this is a
presentation-layer distinction, not a change to the sealed enum.

The full observation/match ladder this row must be able to distinguish,
frozen as six mutually exclusive states a caller can derive from the
row's fields:

```
1. no raw broker observation at all       -> match_status_known == false
2. raw observation exists but unmatched   -> match_status == TX_MATCH_UNMATCHED
3. matched, ambiguous                     -> match_status == TX_MATCH_AMBIGUOUS
4. matched, partial-fill                  -> match_status == TX_MATCH_PARTIAL
5. matched, full fill                     -> match_status == TX_MATCH_VOLUME_REACHED
6. terminal rejection/cancel/expiry       -> terminal_rejection_observed == true
                                              (owned entirely by C3.10, read-only here)
```

`recommendation_known`/`recommendation` is an orthogonal seventh axis
(section 8), not a member of this ladder - a row can be, for example,
"matched, partial-fill" **and** "recommendation not yet generated" at
the same time, and the row must be able to express both facts
independently.

---

## 8. `recommendation` stays contextual visibility only (frozen)

`recommendation` (`ENUM_RECOMMENDATION`: `RECOMMEND_NONE` /
`RECOMMEND_EXECUTED` / `RECOMMEND_BLOCKED`, or unknown via
`recommendation_known == false`) is surfaced for an operator's context
only. It must never be read by, or feed into, the computation of
`unresolved` or `unresolved_beyond_threshold` (section 4). This is the
user's explicit correction to the original draft, adopted as frozen
policy: `DeferredTransactionProcessor` can legitimately produce no row,
or a `RECOMMEND_NONE`/`RECOMMEND_BLOCKED` row, for reasons that are
about policy/evidence-completeness (e.g. clauses not yet satisfied, a
structural provenance gap) rather than about whether the broker has
produced any terminal evidence - conflating the two would let a policy
outcome masquerade as a factual observation status.

---

## 9. Source access boundary (frozen)

```
Permitted:
  - StateProjector_TryGetState() (existing, sealed, read-only)
  - TransactionMatchingProjection's existing read accessors (sealed)
  - DeferredTransactionProcessor's existing recommendation read
    accessors (sealed)
  - AsyncTerminalOrderObservationMatcher's existing read accessors
    (C3.10A, sealed) for terminal_rejection_observed
  - Direct scan of an already-loaded durable event-store lines[] array,
    or a caller-supplied file path, for this candidate's own
    CANDIDATE_SUBMITTED line only (section 1) - same pattern as
    C3.7/C3.9's own line-scan helpers

Forbidden, anywhere in this component:
  - PositionsTotal/PositionGetString/PositionSelect or any live position
    query
  - HistorySelect/HistoryDealGet*/HistoryOrderGet* or any broker history
    API
  - OrderSend/CTrade or any order-mutating call
  - Synthesizing, inferring, or upgrading a rejection outcome - that
    remains C3.10's exclusive authority
  - Any candidate-lifecycle transition (EventStore_LogTransition) or
    event append of any kind
```

---

## 10. Archived/rotated store test input contract (frozen)

Per the user's explicit instruction: "archived/rotated store" test
coverage (item 6 of the restart-scenario matrix, section 11) must
specify its input as a **file path supplied by the caller** to the future
scan function - never file discovery, directory search, or any
"find the most recent archive" heuristic. The future implementation
exposes exactly the same shape C3.3/C3.7/C3.9's own file-scoped scan
entry points already use (an explicit `fileName` parameter), reused
here rather than inventing a second archive-discovery mechanism.

---

## 11. Restart-scenario fixture matrix required for implementation acceptance

Carried forward verbatim from `Docs/PhaseC_C3_5_DeferredAuthorityContract.md`
§14's original C3.8 scope - still unbuilt for the fill/general path
(C3.10's own restart coverage is scoped to the rejection path only, per
its C3.10F stacked-integration-audit CHANGELOG entry):

```
1. before any deal observation exists for the candidate
2. after a partial fill only
3. after a full-fill observation, before the deferred processor (C3.7)
   has acted on it
4. after the deferred processor's action has been durably emitted
5. duplicate/reordered raw BROKER_TRANSACTION_OBSERVED facts
6. current-day store vs. an archived/rotated store (section 10's
   explicit-file-path contract)
```

Each fixture must independently assert `submitted_at_known`,
`match_status`/`match_status_known`, `terminal_rejection_observed`,
`terminal_evidence_observed`, `unresolved`, and (for a threshold case)
`unresolved_beyond_threshold` - not just a single pass/fail per fixture.

---

## 12. Explicitly NOT authorized by this contract

```
No OnInit/OnTick wiring of any kind (this stays a read-only library
    function only, exactly as C3.9's ExecutionProvenanceConflictAuditor
    and C3.10A's matcher both did before their own, separate wiring
    steps - if any wiring is ever authorized at all).
No new ENUM_EVENT_TYPE value.
No new ENUM_REASON_CODE value.
No edit to StateProjector.mqh, TransactionMatchingProjection.mqh,
    DeferredTransactionProcessor.mqh, LifecycleAuthorityProcessor.mqh,
    AsyncTerminalOrderObservationMatcher.mqh,
    AsyncTerminalRejectionAuthority.mqh, BrokerReconciliation.mqh,
    CandidateProjection.mqh, EventStore.mqh, EventSerializer.mqh - all
    are read-only callers of these, never editors.
No Safe Mode change of any kind.
No candidate-lifecycle transition, no event append, no durable write of
    any kind - this component is 100% read-only.
No consumer of unresolved_beyond_threshold anywhere - that is a future
    phase's own, separately authorized decision (section 4b).
No .mqh/.mq5 implementation file, no test file, no MLQuantAI.mq5 edit,
    no compile, no test run - all remain a separate, future C3.8
    implementation commit's job, authorized on its own.
```

---

## 13. Future gates (unchanged from C3.5 §14, restated for continuity)

```
C3.8 - reconciliation integration: THIS document (submitted-candidate
       visibility). Implementation is a separately authorized future
       step.
C4   - recovery / broker-history policy (unchanged scope from C3.5 §14).
C5   - controlled execution rollout (unchanged scope from C3.5 §14) -
       the environment-ladder / OnTick-wiring phase discussed in this
       branch's chat history under the working label "C5.0", not
       authorized by this document.
C6   - position/exit lifecycle (unchanged scope from C3.5 §14).
C7   - operational hardening (unchanged scope from C3.5 §14).
```

---

## 14. Ticket and execution-request lineage resolution

**Status**: proposed for adoption following C3.8.1 Contract-
Reconciliation Checkpoint 1; not effective until this docs-only
amendment is reviewed and committed. Intended to supersede the old,
nonbinding "Appendix A.1" notes once adopted.

### Row fields and anomaly enum

```cpp
enum ENUM_LINEAGE_ANOMALY
{
   LINEAGE_ANOMALY_NONE = 0,
   LINEAGE_ANOMALY_NONPOSITIVE_TICKET,
   LINEAGE_ANOMALY_DUPLICATE_TRIPLE,
   LINEAGE_ANOMALY_MULTIPLE_EXECUTION_REQUESTS,
   LINEAGE_ANOMALY_AMBIGUOUS_TICKETS
};
```

```cpp
bool  order_ticket_known;

bool  order_ticket_ambiguous;

ulong order_ticket;
// semantically undefined unless order_ticket_known == true

ENUM_LINEAGE_ANOMALY lineage_anomaly;
```

### Qualifying submitted outcome

A **qualifying submitted outcome**, for `row.candidate_id`, is exactly:

```text
ExecutionRequestProjection.candidate_id == row.candidate_id
AND SubmissionOutcomeProjection.execution_request_id ==
    ExecutionRequestProjection.execution_request_id
AND SubmissionOutcomeProjection.submission_status ==
    SUBMISSION_STATUS_SUBMITTED
```

Resolved by reading two already-sealed registries, read-only: scan
`ExecutionRequestProjection_Count()`/`_GetAt()` filtered by
`candidate_id`, then scan `SubmissionOutcomeProjection_Count()`/
`_GetAt()` filtered by `execution_request_id`, both in ascending index
order. This scan order is the source of determinism for `first_error`
selection, both within one candidate (below) and across the whole
report (this section's final subsection).

### Non-`SUBMITTED` exclusion

`SUBMISSION_STATUS_NONE`, `_ERROR`, `_REJECTED`, and `_UNKNOWN` records
are excluded before the qualifying set is even built - never entered,
never filtered afterward. C3.8.1 forms no opinion on why a candidate
lacks a submitted outcome, only that it lacks one.

### Six resolution outcomes

Evaluated in this exact precedence order; the first matching outcome
wins for that candidate.

| # | Outcome | Condition |
|---|---|---|
| 1 | `NONPOSITIVE_TICKET` | At least one qualifying outcome has `order_ticket <= 0` |
| 2 | `DUPLICATE_TRIPLE` | A positive `(execution_request_id, order_ticket)` pair occurs 2+ times among qualifying outcomes (`candidate_id` is already fixed for the whole scan) |
| 3 | `MULTIPLE_EXECUTION_REQUESTS` | 2+ distinct `execution_request_id` values each have at least one qualifying, positive-ticket (`order_ticket > 0`) outcome |
| 4 | `AMBIGUOUS_TICKETS` | Reachable only once outcome 3 is excluded (exactly one `execution_request_id` has qualifying-positive outcomes); 2+ distinct positive `order_ticket` values exist under that one request |
| 5 | No qualifying submitted outcome (not an anomaly) | No candidate-correlated record with `submission_status == SUBMISSION_STATUS_SUBMITTED` was collected - i.e. **qualifying is empty** |
| 6 | Exactly one clean usable positive ticket | After outcomes 1-4 have been excluded, exactly one correlated `execution_request_id` has exactly one non-duplicated positive ticket |

**Outcome 5, frozen wording:**

```text
No qualifying submitted outcome

No candidate-correlated record with:
  submission_status == SUBMISSION_STATUS_SUBMITTED
was collected.

This is not a lineage anomaly:

  order_ticket_known     = false
  order_ticket_ambiguous = false
  order_ticket           = semantically undefined
  lineage_anomaly         = LINEAGE_ANOMALY_NONE
```

**Outcome 6, frozen wording:**

```text
Exactly one clean usable positive ticket

After outcomes 1-4 have been excluded, exactly one correlated
execution_request_id has exactly one non-duplicated positive ticket.

  order_ticket_known     = true
  order_ticket_ambiguous = false
  order_ticket            = that one ticket value
  lineage_anomaly         = LINEAGE_ANOMALY_NONE
```

### Per-row invariants

```text
order_ticket_known == true
  =>  order_ticket_ambiguous == false
  AND lineage_anomaly == LINEAGE_ANOMALY_NONE

order_ticket_ambiguous == true
  =>  order_ticket_known == false
  AND lineage_anomaly == LINEAGE_ANOMALY_AMBIGUOUS_TICKETS

lineage_anomaly != LINEAGE_ANOMALY_NONE
  =>  order_ticket_known == false
  AND order_ticket_ambiguous ==
        (lineage_anomaly == LINEAGE_ANOMALY_AMBIGUOUS_TICKETS)
```

`lineage_anomaly == LINEAGE_ANOMALY_NONE` does **not** imply
`order_ticket_known == true` - `NONE` also covers outcome 5, a normal
absence, not a resolved ticket.

`order_ticket` carries meaning only when `order_ticket_known == true`;
same undefined-value discipline as `age_seconds` (§6, already frozen).

### Per-row error selection

For a candidate whose outcome is 1-4, `first_error` for that row is
built from the earliest `(i, j)` scan-index pair - `i` over
`ExecutionRequestProjection`, `j` over `SubmissionOutcomeProjection`,
both ascending - whose outcome triggered that specific anomaly
category.

### Report aggregation and first_error ordering

```text
Report aggregation is monotonic for this component:

report.ok begins true for a completed scan.

If any emitted row has:
  lineage_anomaly != LINEAGE_ANOMALY_NONE

then:
  report.ok = false

A row with:
  lineage_anomaly == LINEAGE_ANOMALY_NONE

does not change report.ok.

report.first_error is set once only: it is the deterministic error
from the first emitted anomalous row, in FINAL REPORT-ROW ORDER (per
§16's frozen ordering: known-timestamp rows ascending by
submitted_sequence_number, then unknown-timestamp rows by candidate_id
ascending). Later anomalous rows do not replace it.
```

This ties `first_error` determinism to two nested, both-deterministic
orderings: within a candidate, the `(i, j)` projection-scan order
(above); across candidates, the row emission order (§16). Neither
depends on file iteration order beyond what those two already-frozen
orderings define, and neither depends on wall-clock or session state.

---

## 15. Downstream evidence gating and terminal-evidence rule

**Status**: proposed for adoption following C3.8.1 Contract-
Reconciliation Checkpoint 1; not effective until this docs-only
amendment is reviewed and committed. Intended to supersede the old,
nonbinding "Appendix A.2" notes once adopted.

```text
match_status_known == TransactionMatching_TryGetOrderStatus(order_ticket, out)
                       (called only when order_ticket_known == true;
                        the bool return value, nothing more)

match_status        == out.match_status
                       (semantically undefined unless match_status_known)

terminal_evidence_observed ==
   match_status_known AND match_status == TX_MATCH_VOLUME_REACHED

unresolved == NOT terminal_evidence_observed
```

| Ticket state | Matching result | Terminal evidence | `unresolved` |
|---|---|---:|---:|
| unknown / anomalous | not looked up | false | true |
| known | `TryGetOrderStatus()` returns false | false | true |
| known | `TX_MATCH_UNMATCHED` | false | true |
| known | `TX_MATCH_PARTIAL` | false | true |
| known | `TX_MATCH_VOLUME_REACHED` | true | false |

`TX_MATCH_ORDER_TERMINAL` is reserved and never assigned by C3.3 in the
frozen baseline; C3.8.1 MUST NOT treat it as terminal evidence. A
`false` return from `TransactionMatching_TryGetOrderStatus()` means
matching status is **unknown**, not a non-terminal conclusion and not a
rejection.

`OrderAggregateRecord` (the struct behind this lookup) carries no
timestamp or sequence field of any kind - there is no data to support a
staleness determination, and none is attempted. `match_status` reflects
whatever the matcher's registry currently holds as of its last
`TransactionMatching_StartupRebuild()` in this session; C3.8.1 reports
that value as-is.

`recommendation`/`recommendation_known` (via
`DeferredTransactionProcessor_TryGet(candidate_id, ...)`) remain fully
independent of every ticket-resolution outcome in §14, including every
`lineage_anomaly` value - never suppressed, never gated by ticket state.

---

## 16. Submission identity and row ordering

**Status**: proposed for adoption following C3.8.1 Contract-
Reconciliation Checkpoint 1; not effective until this docs-only
amendment is reviewed and committed. Intended to supersede the old,
nonbinding "Appendix A.3" notes once adopted. Unchanged in substance
from the prior draft round.

```cpp
long submitted_sequence_number;
// semantically undefined unless submitted_at_known
```

```text
submitted_at_known == true   =>  submitted_sequence_number > 0
submitted_at_known == false  =>  submitted_sequence_number is undefined
```

Recovered from the same unique `CANDIDATE_SUBMITTED` durable lifecycle
line the §1 timestamp scan already locates - never a second, separate
scan.

Row ordering, frozen:

```text
1. Rows with submitted_at_known == true, sorted ascending by
   submitted_sequence_number.

2. Rows with submitted_at_known == false, after all of group 1,
   sorted ascending by candidate_id.
```

---

## 17. C3.10A excluded from the C3.8.1 evidence graph

**Status**: proposed for adoption following C3.8.1 Contract-
Reconciliation Checkpoint 1; not effective until this docs-only
amendment is reviewed and committed. New this checkpoint.

`AsyncTerminalOrderMatcher_ScanLines()`/`_ScanFile()` (C3.10A) return an
`AsyncTerminalOrderMatchReport` by value from a fresh scan - there is no
`_Count()`/`_GetAt()` pair and no persistent registry, so there is
nothing already built for C3.8.1 to passively read. Without a stable
public read accessor, C3.10A is not part of C3.8.1's evidence graph.

`terminal_rejection_observed` does not appear as a field on
`SubmittedCandidateVisibilityRow`. `terminal_evidence_observed` is
defined solely by §15's `TX_MATCH_VOLUME_REACHED` rule.

---

## 18. Ownership map and explicit scope exclusions

**Status**: proposed for adoption following C3.8.1 Contract-
Reconciliation Checkpoint 1; not effective until this docs-only
amendment is reviewed and committed. New this checkpoint.

**Permitted sources (read-only):**

| Source | Access | Key |
|---|---|---|
| `StateProjector` | `_Count()`/`_GetAt()` | candidate enumeration |
| `StateProjector` | `_TryGetState()` | optional cross-check only |
| Durable lifecycle log | direct `lines[]` scan via `EventSerializer` | `submitted_at`/`_sequence` recovery |
| `ExecutionRequestProjection` | `_Count()`/`_GetAt()` | filtered by `candidate_id` |
| `SubmissionOutcomeProjection` | `_Count()`/`_GetAt()` | filtered by `execution_request_id` |
| `TransactionMatchingProjection` | `TransactionMatching_TryGetOrderStatus()` | ticket-keyed only |
| `DeferredTransactionProcessor` | `_TryGet()` | candidate-keyed only |
| `SafeModeState` | `SafeMode_IsActive()` | read-only status |

**Explicitly excluded:**

```text
BrokerReconciliation_CheckAll()            - full-scan report, out of scope
BrokerReconciliation_HasMatchingPosition() - live-position query, out of scope
EventStoreValidator_ValidateLines/_ValidateFile - upstream OnInit concern
ReplayEngine_Run()                         - upstream OnInit concern
Any History*/OrderSend/CTrade/PositionSelect/PositionGetTicket call
AsyncTerminalOrderMatcher_ScanLines()/_ScanFile()  (see §17)
SafeMode_Trip()/SafeMode_Clear()
```
