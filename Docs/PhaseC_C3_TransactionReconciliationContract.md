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

## 6. Ownership of `ORDER_FILLED`/`ORDER_REJECTED`/`CANDIDATE_EXECUTED` - a real collision found and left unresolved here

Per section 0, `EVENT_TYPE_ORDER_FILLED` and `EVENT_TYPE_CANDIDATE_EXECUTED`
are dormant and reserved for exactly this purpose - no collision there.

**A genuine collision, found by this collision-check**:
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

**Left explicitly unresolved here, for C3.2's own separate approval to
decide**: whether the late case gets a brand-new event type (e.g., an
`EVENT_TYPE_ORDER_LATE_CANCELLED`-shaped name, not frozen) or is folded
into `EVENT_TYPE_ORDER_FILLED`'s sibling space some other way. This
doc's job is to surface the collision before implementation, not to
resolve it - resolving it is exactly the kind of design decision this
project's "freeze contract before code" discipline reserves for its
own dedicated round.

`EVENT_TYPE_CANDIDATE_EXECUTED`'s ownership is cleaner: it is the
candidate-lifecycle counterpart (via `EventStore_LogTransition`, not
`EventStore_LogSystem`) to a CONFIRMED, terminal, full fill (section 4)
- `CANDIDATE_SUBMITTED -> CANDIDATE_EXECUTED`. A late
rejection/cancellation is the candidate-lifecycle counterpart
`CANDIDATE_SUBMITTED -> CANDIDATE_REJECTED_BY_BROKER` (also already
declared, dormant, Phase A) - symmetrical to the fill case, and equally
deferred to C3.2.

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

## Scope guard (frozen, matches the user's explicit prohibition for this document)

```
No OnTradeTransaction handler anywhere - documentation only.
No HistoryDealGet*/HistoryOrderGet*/HistorySelect/PositionSelect or any
    broker-state query anywhere.
No OrderSend/CTrade/modify/close/pending-order API anywhere.
No candidate-lifecycle transition, no event append, no new struct/enum
    value actually added to any .mqh file by this document.
No sealed file touched.
Implementation (C3.2: the real handler + History* calls) is separate
    approval, not authorized by this document.
```
