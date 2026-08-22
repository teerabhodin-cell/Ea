# C3 transaction-reconciliation contract (documentation only - collision check)

Per the user's explicit instruction: this is "C3.1 / transaction-
reconciliation collision check + documentation-only contract draft."
**No code, no `OnTradeTransaction` handler, no
`HistoryDealGet*`/`HistoryOrderGet*`/`HistorySelect`/`PositionSelect`/
any broker-state query anywhere.** Every claim about MQL5 platform
behavior below was verified directly against the real MQL5 reference
via `WebFetch` this round (not recalled from memory) - cited inline.
Where the reference does not document a behavior, this doc says so
explicitly rather than assuming one.

Implementation (`C3.2`, the actual handler + `History*` calls) is
**separate approval**, per the user's frozen sequence - this doc is the
prerequisite freeze, not a green light to build it.

**Update**: sections 10-14 below freeze the `C3.2` sub-contract itself
(defensive rules, callback shape, trust boundary, event schema, deferred-
processor split, and required test-design additions), per the user's
explicit follow-up authorization after reviewing a read-only "C3
implementation collision-check." That authorization covers **contract
amendment and test design only** - the actual `OnTradeTransaction`
handler, any `History*`/`PositionSelect` call, any new `ENUM_EVENT_TYPE`
value actually added to a `.mqh` file, any candidate-lifecycle
transition, and any broker mutation remain separate, not-yet-approved
steps. See the updated scope guard at the bottom of this document.

## 0. What already exists today (the surface C3 must integrate with)

- `outTradeRequest.comment = req.correlation_id` and
  `outTradeRequest.magic = MLQUANTAI_MAGIC_NUMBER` - both already set,
  verbatim, by `BrokerSubmissionBuilder.mqh` (C2.2) for every real
  submission. C3 does not need to add any new tagging - the join key
  already exists on every order this EA has ever sent.
- `BrokerReconciliation_HasMatchingPosition()` (Phase A,
  `Infrastructure/MLQuantAI_BrokerReconciliation.mqh`) already
  establishes the precedent this contract continues: match by
  `StringFind(PositionGetString(POSITION_COMMENT), correlationId) >= 0`
  - a **substring** search, not exact equality - because the comment's
    exact round-trip fidelity through the broker/server is not
    guaranteed (see section 2).
- `ENUM_CANDIDATE_STATE` already declares `CANDIDATE_SUBMITTED`,
  `CANDIDATE_EXECUTED`, and `CANDIDATE_REJECTED_BY_BROKER` (Phase A,
  dormant - no code path produces them yet). `ENUM_EVENT_TYPE` already
  declares `EVENT_TYPE_ORDER_FILLED` and `EVENT_TYPE_CANDIDATE_EXECUTED`
  (Phase A, dormant) - reserved, per `Core/MLQuantAI_Enums.mqh`'s own
  comment, "for C2's real broker facts." C2.2 already claimed
  `EVENT_TYPE_ORDER_SUBMITTED`/`EVENT_TYPE_ORDER_REJECTED` for its own,
  different meaning - see section 6's collision.

## 1. Matching hierarchy (frozen priority order)

Every fact `OnTradeTransaction`/a later reconciliation pass observes
must be attributed back to exactly one `ExecutionRequest`/`TradeCandidate`,
or not attributed at all (section 7). Priority, highest first:

1. **`magic` number** (`MLQUANTAI_MAGIC_NUMBER`, fixed constant) - the
   first, cheapest filter. Any transaction/deal/position with a
   different magic is not this EA's and is discarded immediately,
   before any string comparison.
2. **`comment` containing the `correlation_id`** (substring match, per
   the existing `BrokerReconciliation_HasMatchingPosition` precedent -
   see section 2 for why not exact-equality). This is the PRIMARY
   identity join - `correlation_id` is unique per submission attempt
   (`Ids_CorrelationId(candidate_id, submit_attempt)`, C1), so a match
   here is a match to exactly one `ExecutionRequest`.
3. **`symbol`** - must equal the `ExecutionRequest`'s own symbol at
   build time (`_Symbol` observed at gate time, C1.2/C2.2). A
   magic+comment match on the wrong symbol is a corruption signal
   (section 7), never silently accepted.
4. **Order/deal/position ticket** - NOT an identity key at all, only a
   **grouping** key once a magic+comment+symbol match has already
   established which `ExecutionRequest` a given `order` ticket belongs
   to. Every subsequent `MqlTradeTransaction` referencing that same
   `order` (and later, the `deal`/`position` tickets it produces) is
   then grouped under that same `ExecutionRequest` without re-checking
   comment/magic on every single transaction - see section 4 for why.
5. **Account login / `ACCOUNT_SERVER`** - not part of the join itself
   (a reconciliation pass only ever runs against whatever account/server
   the terminal is currently logged into), but MUST be recorded on every
   reconciliation-side record as audit evidence, same "observed, never
   fed into identity" precedent `DryRunExecutionResult.observed_account_login`
   already established (C1.2).
6. **Volume/time tolerances** - volume must match `ExecutionRequest.lot_size`
   exactly for a single, non-partial fill; see section 4 for the
   partial-fill case (aggregation, not tolerance). Time is NOT
   tolerance-matched at all - the `ExecutionRequest`'s own
   `submission_timestamp` (already recorded by C2.2's
   `ExecutionSubmissionResult`) is the anchor; any `OnTradeTransaction`
   fact for the same `order` ticket arriving after that timestamp is
   valid by definition (the order didn't exist before it was sent), so
   no separate time-window check is needed once the ticket-grouping in
   priority 4 already holds.

A record with a magic+comment match but a symbol mismatch, or a
volume that doesn't reconcile per section 4's rule, is NOT a lower-
confidence match to fall back on - see section 7 ("no transition on
unmatched/ambiguous facts").

## 2. Comment rewriting/truncation - verified, and what is NOT verified

Verified directly against the real MQL5 reference this round:
- `MqlTradeRequest.comment` is documented only as "Order comment" -
  the reference does **not** document any length limit, nor any
  guarantee that the broker/trade server returns the comment
  unmodified (`mql5.com/en/docs/constants/structures/mqltraderequest`).
- `POSITION_COMMENT` (`PositionGetString`) is documented with no stated
  length limit and no stated relationship to the original order's
  comment (`mql5.com/en/docs/trading/positiongetstring`).

**Because neither is documented, this contract does NOT assume
byte-exact round-tripping is guaranteed.** This is why priority 2 in
section 1 is a **substring match** (`StringFind(...) >= 0`), matching
the precedent `BrokerReconciliation_HasMatchingPosition` already set,
not `==`. `correlation_id` itself (format `CORR_` + 16 hex chars, from
`Ids_Deterministic`) contains no characters a broker would need to
strip for validity, which further reduces (but per the above, does not
formally eliminate) truncation risk. If C3's implementation phase finds
in real testing that a specific broker truncates or rewrites the
comment in a way that breaks even a substring match, that is a new,
separate finding requiring its own resolution - this contract commits
only to "substring match, never exact-equality" as the defensive
default, not to a guarantee that no broker can ever break it.

## 3. Netting vs. hedging semantics (verified)

Verified: `ACCOUNT_MARGIN_MODE` (`AccountInfoInteger`) has three
values (`mql5.com/en/docs/constants/environment_state/accountinformation`):
`ACCOUNT_MARGIN_MODE_RETAIL_NETTING` ("only one position can exist for
one symbol"), `ACCOUNT_MARGIN_MODE_RETAIL_HEDGING` ("individual
positions are possible ... multiple positions can exist for one
symbol"), `ACCOUNT_MARGIN_MODE_EXCHANGE`.

**Consequence for this contract**: in netting mode, a fill from THIS
EA's own order can merge into (or be merged by) whatever position
already exists on that symbol - the resulting `position` ticket is
**not** a reliable 1:1 key back to one `ExecutionRequest`, because the
same position ticket can persist across multiple, unrelated
`ExecutionRequest`s on the same symbol (this EA's own repeated
candidates, or even a manually-opened position on the same account).
This is exactly why section 1 puts `order`/`deal` ticket identity
ahead of `position` ticket, and why `comment`+`magic` (attached to the
**order**, and copied onto the **deal**, not reliably onto a
netted **position**) is the real join key, never the position ticket
alone. In hedging mode this risk is structurally absent (each accepted
order/deal produces its own distinct position), but the matching rule
in section 1 does not special-case account mode - it is written to be
correct under netting, the strictly harder case, and therefore correct
under hedging too.

Environment-lock's own item 6 (`BrokerSubmissionGate_Evaluate`'s
`environment_mode == EXECUTION_ENV_DEMO` requirement, C2.2) already
means C3 will only ever observe this on a demo account during Phase C
- but the matching RULE itself must still be netting-safe, since which
mode a given demo account uses is a broker/account configuration
choice, not something this project controls or has verified today.

## 4. Partial-fill aggregation and terminal criterion

A single accepted order can produce more than one `deal` (partial
fills at different prices/times) before the order is fully filled,
cancelled, or expired. C3's read model (section 8) must therefore
track, per `order` ticket:

- **Running filled volume** = sum of every `deal`'s volume grouped
  under that order (per section 1 priority 4's ticket-grouping rule),
  never a single-deal snapshot.
- **Terminal criterion**: the order is DONE-filling when either (a)
  running filled volume reaches the `ExecutionRequest.lot_size` sent
  (allowing for the platform's own volume-step rounding already
  enforced upstream by `SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)`/
  `SYMBOL_VOLUME_STEP`, C2's environment-lock and B7's risk-sizing), or
  (b) the order itself transitions to a terminal `ORDER_STATE` (filled/
  cancelled/rejected/expired - the exact `ORDER_STATE`/transaction-type
  combination that signals this is implementation detail for C3.2, not
  frozen here). Only a terminal order/full-fill may drive
  `CANDIDATE_EXECUTED` (section 6) - a candidate never transitions on
  an in-progress partial fill.
- A partial fill that never reaches full volume and never reaches a
  terminal order state (e.g., the EA restarts before the order
  resolves) leaves the candidate at `CANDIDATE_SUBMITTED` indefinitely,
  by design - see section 7: no transition without a conclusive fact,
  and section 5 for what restart itself means for this state.

## 5. Callback duplication/ordering/restart behavior (verified)

Verified directly from the real MQL5 reference
(`mql5.com/en/docs/event_handlers/ontradetransaction`):
- **No ordering guarantee across transactions**: "Priority of these
  transactions' arrival at the terminal is not guaranteed. Thus, you
  should not expect that one group of transactions will arrive after
  another."
- **No 1:1 request-to-event guarantee**: "Each request can lead to
  several trade events. You cannot rely on the statement 'One request
  - one Trade event.'"
- The reference does **not** document whether a missed/unprocessed
  transaction is replayed to the EA after a terminal/EA restart. This
  contract does **not** assume replay-on-restart is guaranteed.

**Consequences, frozen for C3.2's future implementation**:
- Every transaction-derived fact must be durably recorded (own event
  type, section 6) using the SAME idempotent-replay discipline C2.3's
  `SubmissionAttemptProjection`/`SubmissionOutcomeProjection` already
  established: a transaction's own natural key (e.g., `deal` ticket for
  a fill fact) determines whether a re-observation is a no-op replay or
  a genuine new fact - never re-derived from arrival order, since
  arrival order is explicitly not guaranteed.
- Because restart-replay is NOT guaranteed by the platform, C3.2 cannot
  rely on `OnTradeTransaction` alone to eventually reconcile state
  after a missed callback (e.g., EA was offline when a deal happened).
  A genuine reconciliation pass (comparing durable state against
  `History*`/`PositionSelect` queries) is therefore a SEPARATE,
  necessary mechanism, not an optional extra - this is precisely why
  `Infrastructure/MLQuantAI_BrokerReconciliation.mqh` already exists as
  a distinct, `OnInit`-time mechanism from any transaction callback,
  and C3.2 should extend that reconciliation pass rather than assume
  `OnTradeTransaction` callbacks alone are a complete picture.
- No test of C3.2's future handler can synthesize a real
  `OnTradeTransaction` callback (the platform does not expose a way to
  fabricate one under a test harness) - see section 9 for what CAN be
  tested without one.

## 6. Ownership of `ORDER_FILLED`/`ORDER_REJECTED`/`CANDIDATE_EXECUTED` - collision found, now resolved and frozen by the user

Per section 0, `EVENT_TYPE_ORDER_FILLED` and `EVENT_TYPE_CANDIDATE_EXECUTED`
are dormant and reserved for exactly this purpose - no collision there.

**The collision, found by this collision-check**:
`EVENT_TYPE_ORDER_REJECTED` is **already claimed** by C2.2 for a
DIFFERENT, narrower meaning: an explicit-rejection retcode returned
**synchronously, from `OrderSend()` itself** (see
`Core/MLQuantAI_Enums.mqh`'s C2.2 comment: "the dormant
`EVENT_TYPE_ORDER_SUBMITTED`/`_ORDER_REJECTED` ... are reused as-is for
the post-`OrderSend` accepted/explicit-rejection cases"). A LATE
rejection/cancellation - an order that was synchronously accepted by
`OrderSend()` (so C2.2 already logged `ORDER_SUBMITTED`) but is later
cancelled, rejected, or expires asynchronously, observed only via
`OnTradeTransaction` - is a **semantically different fact** (it can
only happen strictly after C2.2's own `ORDER_SUBMITTED`, never before,
and it means something different: "the trade server accepted the order
but it never became a position," not "the order was refused outright").
Reusing `EVENT_TYPE_ORDER_REJECTED` for this late case would collide
two meanings under one name and break C2.3's own audit-projection
invariants (which currently treat `ORDER_REJECTED` as mutually
exclusive with, and always preceding, any `ORDER_SUBMITTED` for the
same request - see `SubmissionOutcomeProjection_ApplyLineWithLineage`'s
outcome-invariant checks, C2.3).

**Resolution, frozen by the user's explicit instruction - a separate
namespace, not a shared one**:

| Event type | Scope | Fired by |
|---|---|---|
| `EVENT_TYPE_ORDER_REJECTED` | Synchronous submit-response rejection ONLY - unchanged, still exactly C2.2's own meaning | `BrokerSubmission_ProcessSendResult`/`BrokerSubmission_Submit` (C2.2), at `OrderSend()` return time |
| `EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED` (new, frozen name - not yet added to `ENUM_EVENT_TYPE`, C3.2's job) | Asynchronous, `OnTradeTransaction`-derived rejection/cancellation/expiry ONLY - can only ever fire strictly after a matching `EVENT_TYPE_ORDER_SUBMITTED` for the same `execution_request_id` | C3.2's future handler, never C2.2 |

The two names are permanently mutually exclusive by construction: an
`ORDER_REJECTED` line can never be followed by a
`TRANSACTION_REJECTION_CONFIRMED` line for the same request (rejected
orders never reach the trade server, so no transaction stream exists
for them to begin with), and a `TRANSACTION_REJECTION_CONFIRMED` line
can never exist without an earlier `ORDER_SUBMITTED` for the same
request. C3.2's future projection must treat a `TRANSACTION_REJECTION_
CONFIRMED` line with no preceding `ORDER_SUBMITTED` the same way C2.3
already treats an outcome with no preceding attempt - an
ordering/orphan violation, rejected closed (section 7).

Per the user's explicit instruction, a `TRANSACTION_REJECTION_CONFIRMED`
fact must NEVER drive `CANDIDATE_SUBMITTED -> CANDIDATE_REJECTED_BY_BROKER`
until it is matched to its owning `ExecutionRequest` deterministically
via section 1's full matching hierarchy - an unmatched or ambiguous
transaction-derived rejection fact is recorded only as a diagnostic/
reconciliation finding (section 8), never a lifecycle mutation. This
sharpens, and is now the frozen version of, section 7's general rule
as applied specifically to the rejection case.

`EVENT_TYPE_CANDIDATE_EXECUTED`'s ownership is cleaner: it is the
candidate-lifecycle counterpart (via `EventStore_LogTransition`, not
`EventStore_LogSystem`) to a CONFIRMED, terminal, full fill (section 4)
- `CANDIDATE_SUBMITTED -> CANDIDATE_EXECUTED`. A late
rejection/cancellation is the candidate-lifecycle counterpart
`CANDIDATE_SUBMITTED -> CANDIDATE_REJECTED_BY_BROKER` (also already
declared, dormant, Phase A) - symmetrical to the fill case, driven only
by a deterministically-matched `TRANSACTION_REJECTION_CONFIRMED` fact,
per the paragraph above. Adding `EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED`
to `ENUM_EVENT_TYPE` itself is still C3.2's job, not this document's -
this section freezes the NAME and its scope, not the code.

## 7. No transition on unmatched/ambiguous facts

Same fail-closed discipline every C1/C2 gate and C2.3's projection
already follow: a transaction-derived fact that does NOT cleanly
satisfy section 1's full matching hierarchy (wrong magic, comment
substring not found, symbol mismatch, or - per section 4 - a fill
whose aggregated volume does not cleanly reconcile to
`ExecutionRequest.lot_size`) must NEVER be force-fitted to the
"closest" `ExecutionRequest`, and must NEVER drive any
`EventStore_LogTransition` call. It is recorded (once C3.2 exists) as
its own unmatched/ambiguous fact, visible for audit, with the
candidate's lifecycle state left exactly where it was. This mirrors
C2.3's own orphan/mismatch rules
(`SubmissionAttemptProjection_ApplyLineWithLineage`'s hash-mismatch and
orphan checks) and the manual-approval contract's own "fails the whole
rebuild closed" precedent for a comparable class of problem
(`Docs/PhaseC_C2_ManualApprovalContract.md`) - never silent, never a
best-effort guess.

## 8. Reconciliation state/read model and event replay rules (frozen shape, deferred implementation)

Mirrors the shape every prior C2/C3-adjacent projection already
established (`SubmissionAttemptProjection`/`SubmissionOutcomeProjection`,
C2.3): a durable, replay-from-file read model, never a live
`OnTradeTransaction`-only cache, because per section 5 a missed
callback must still be recoverable from a real reconciliation pass. At
minimum, when C3.2 designs the concrete records:
- One durable fact per confirmed deal/fill (grouped under its `order`
  ticket per section 1), keyed by `deal` ticket (the natural
  idempotency key for replay, same role `log_event_id` plays for
  C2.3's own outcome records).
- One durable fact per confirmed late-rejection/cancellation (section
  6), keyed similarly.
- A derived, per-`execution_request_id` reconciliation row (mirroring
  `BrokerSubmissionReconciliationRow`, C2.3) exposing latest known
  fill/terminal status - read-only, never itself the trigger for a
  lifecycle transition (the transition is driven by the transaction
  facts directly, the reconciliation row is a query convenience, same
  division of responsibility C2.3 already established between
  `SubmissionOutcomeProjection` and `BrokerSubmissionReconciliation_Build`).
- Rebuild must stage every earlier-phase projection
  (`ExecutionAuditProjection_RebuildFromFile`,
  `BrokerSubmissionAuditProjection_RebuildFromFile`) as an unmodified
  black-box gate first, same precedent every layer since C1.3 has
  followed - C3.2 never re-parses an earlier phase's own event types.

## 9. Required testing without any broker-mutating run

Per section 5, no real `OnTradeTransaction` callback can be
synthesized under a test harness - so C3.2's future test suite (not
written here) must be structured the same way C2.2/C2.3's own suites
already are: build a real, in-memory `MqlTradeTransaction`-shaped
FIXTURE (a plain struct literal a test constructs directly, exactly
the way `MLQuantAI_Test_BrokerReconciliation.mq5` already tests
`BrokerReconciliation_HasMatchingPosition`'s matching CONTRACT against
a mock/fixture position list rather than real `PositionsTotal()` state,
per that file's own header comment) and feed it directly to whatever
pure function does the section 1 matching/section 4 aggregation logic.
This proves the CONTRACT (matching hierarchy, aggregation, terminal
criterion, fail-closed-on-ambiguity) without ever touching `OrderSend`,
`History*`, or `PositionSelect`. A SEPARATE, later, explicitly-approved
demo-account exercise (the frozen sequence's own item 6, "controlled
demo smoke protocol," itself gated on items 3-5 first) is what would
ever validate this against a REAL, live `OnTradeTransaction` callback -
never this contract's own test suite.

## 10. C3.2 defensive rule: `HistorySelect` visibility is never assumed

The collision-check left one open, unverified platform question: whether
a deal/order that just fired inside `OnTradeTransaction` is guaranteed
immediately queryable via `HistorySelect`/`HistoryDealGetTicket`/
`HistoryOrderGetTicket` in that same callback. `HistorySelect`'s own
reference page documents that it populates a program-local history list
that `HistoryDealGetTicket`/`HistoryOrderGetTicket` then read
(`mql5.com/en/docs/trading/historyselect`,
`mql5.com/en/docs/trading/historydealgetticket`) - selection is
documented as a precondition for ticket-by-index access, but same-
callback visibility timing for a just-arrived fact is not documented
either way.

**Frozen, per the user's explicit instruction: this is resolved as a
design constraint, not an empirical prerequisite.** C3.2's future
handler must be written to never depend on the answer:

```
OnTradeTransaction must never assume a just-arrived DEAL_ADD /
ORDER_* transaction is immediately queryable through HistorySelect.

If HistorySelect or a ticket lookup fails:
  -> persist only the transaction envelope available in `trans`
  -> do not infer missing broker facts
  -> do not transition candidate
  -> mark/publish deferred reconciliation need
```

This turns the open timing question into a test/operational
observation for later, never a precondition for implementing a safe
handler - a `HistorySelect`/ticket-lookup failure is simply one more
case section 7's "no transition on unmatched/ambiguous facts" rule
already covers, applied to a lookup failure rather than a matching
failure.

## 11. C3.2 callback durability: the handler must stay small and non-blocking

Per section 5's already-frozen queue-overwrite risk (MQL5 documents a
1,024-item transaction queue whose old items may be overwritten when the
handler is slow -
`mql5.com/en/docs/basis/function/events`), `OnTradeTransaction` itself
must do the minimum possible work before returning:

```
callback
-> validate minimal trans envelope
-> append immutable transaction-observed event
-> return
```

No history scan, no projection rebuild, no aggregation loop (section 4's
running-fill-volume logic), no broker mutation, and no candidate-
lifecycle transition may run inside the callback itself. All of that is
explicitly deferred to section 14's separate processor, which runs
outside the callback's own execution context.

## 12. C3.2 trust boundary: `trans` is the only primary evidence

Freezes, from the collision-check's own findings:

- For every transaction type, `trans` (the `MqlTradeTransaction`
  parameter) is the primary and only reliably-populated callback
  evidence.
- `request` and `result` (`MqlTradeRequest`/`MqlTradeResult`) must be
  read only when `trans.type == TRADE_TRANSACTION_REQUEST` - both
  reference pages document these two parameters as populated "for
  `TRADE_TRANSACTION_REQUEST` type transaction only"
  (`mql5.com/en/docs/constants/structures/mqltradetransaction`,
  `mql5.com/en/docs/constants/structures/mqltraderesult`). For every
  other transaction type they must not be read or trusted at all.
- `MqlTradeResult` does not carry a position ticket at submit time -
  position linkage is only ever transaction/history-derived, later, via
  `trans.position` on a subsequent transaction
  (`mql5.com/en/docs/constants/structures/mqltraderesult`). This is why
  `ExecutionSubmissionResult` (`order_ticket`/`deal_ticket` only, no
  `position` field) stays unchanged - it cannot correctly carry a
  position ticket at the point it is populated, so C3.2 must not add one
  there; position tracking belongs in the new envelope event (section 13)
  or the deferred processor's own state (section 14), never retrofitted
  onto `ExecutionSubmissionResult`.

## 13. C3.2 event schema: a raw transaction-envelope fact, not an execution claim

Freezes the shape (name and field list only - adding the value to
`ENUM_EVENT_TYPE` and actually emitting it remains implementation, not
authorized by this document):

```
EVENT_TYPE_BROKER_TRANSACTION_OBSERVED
```

It is a durable envelope of what `trans` itself said, nothing inferred
and nothing claimed about execution outcome. Fields:

```
source sequence / event identity
transaction type
deal ticket
order ticket
position ticket
position_by ticket
symbol
order/deal type
order state
price
volume
SL / TP
transaction timestamp
request_id only if TRADE_TRANSACTION_REQUEST
```

Per section 12's trust boundary, `request`/`result`-derived detail
(including `request_id`) must be **absent or explicitly `not_applicable`**
for every transaction type other than `TRADE_TRANSACTION_REQUEST` - never
a zero/default value that a later reader could misread as an observed
fact. This event is intentionally NOT `EVENT_TYPE_ORDER_FILLED`,
`EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED`, or
`EVENT_TYPE_CANDIDATE_EXECUTED` - it carries no matching-hierarchy
verdict and drives no lifecycle transition by itself; section 6's
already-frozen event names remain owned exclusively by section 14's
deferred processor, once it has produced a deterministic match.

## 14. C3.2 deferred processor: matching stays out of the callback

A later read-model/worker (implementation detail, not frozen here)
consumes durable `EVENT_TYPE_BROKER_TRANSACTION_OBSERVED` envelopes plus
existing event-store evidence and, when needed, a `History*` lookup,
under a separate, explicitly-approved policy, to:

```
match -> transaction-derived event -> lifecycle transition
unmatched / delayed / insufficient -> diagnostic + reconciliation queue
```

This is the same split already frozen in sections 6-8 (matching
hierarchy, fail-closed-on-ambiguity, the reconciliation read model) -
sections 10-13 add only the callback-side envelope-capture rules that
feed it. **No raw `OnTradeTransaction` callback may ever directly emit
`EVENT_TYPE_ORDER_FILLED`, `EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED`,
or drive `CANDIDATE_EXECUTED`/any other `EventStore_LogTransition` call**
- those remain exclusively the deferred processor's own output, per
section 11's callback-durability rule.

## 15. C3.2 test-design additions (design only, no test file written by this document)

Extends section 9's already-frozen "fixture-fed `MqlTradeTransaction`
struct, no real callback" approach with the specific scenarios sections
10-14 introduce. C3.2's future test suite must additionally prove, via
fixtures, never a real broker call:

- A `HistorySelect`/ticket-lookup failure (simulated by the fixture,
  since no test harness can force a real lookup to fail) results in the
  envelope-only persist path of section 10, never an inferred fact and
  never a candidate transition.
- The envelope-building function used by section 13 leaves
  `request`/`result`-derived fields absent/`not_applicable` for every
  fixture transaction type other than `TRADE_TRANSACTION_REQUEST`, and
  populates them only for that one type - a direct test of section 12's
  trust boundary.
- The deferred processor (section 14) never calls
  `EventStore_LogTransition` from an unmatched or ambiguous fixture
  envelope - reusing section 7's already-frozen fail-closed assertion
  style, applied to the new envelope shape.
- No test may assert anything about `OnTradeTransaction`'s own queue-
  overwrite behavior (section 11) - that is a platform-level guarantee
  outside what a test harness can observe, not something this project's
  suite can verify directly.

## 16. Minor documentation correction

The collision-check found the `ENUM_TRADE_TRANSACTION_TYPE` reference
page documents **eleven** values (`ORDER_ADD`, `ORDER_UPDATE`,
`ORDER_DELETE`, `DEAL_ADD`, `DEAL_UPDATE`, `DEAL_DELETE`, `HISTORY_ADD`,
`HISTORY_UPDATE`, `HISTORY_DELETE`, `POSITION`, `REQUEST`), not ten as
the earlier CHANGELOG summary entry for this contract stated. Corrected
in `CHANGELOG.md` alongside this update. Documentation-only - does not
alter section 1's frozen matching semantics, which never depended on the
exact count.

## Scope guard (frozen, matches the user's explicit prohibition for this document)

```
No OnTradeTransaction handler anywhere - documentation only.
No HistoryDealGet*/HistoryOrderGet*/HistorySelect/PositionSelect or any
    broker-state query anywhere.
No OrderSend/CTrade/modify/close/pending-order API anywhere.
No candidate-lifecycle transition, no event append, no new struct/enum
    value actually added to any .mqh file by this document.
No sealed file touched.
Sections 10-16 freeze the C3.2 sub-contract's defensive rules, callback
    shape, trust boundary, event-envelope schema, deferred-processor
    split, and test-design additions - contract amendment and test
    design only, per the user's explicit follow-up authorization.
Still NOT authorized by this document: implementing OnTradeTransaction,
    calling HistorySelect/HistoryDealGet*/HistoryOrderGet*, adding
    EVENT_TYPE_BROKER_TRANSACTION_OBSERVED or any other new value to
    ENUM_EVENT_TYPE, any candidate-lifecycle transition or broker-side
    query/mutation, and the controlled demo smoke protocol. Each remains
    its own, separate, explicitly-approved future step.
```
