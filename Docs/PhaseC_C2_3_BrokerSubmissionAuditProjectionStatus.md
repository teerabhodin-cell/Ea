# Phase C2.3 — Broker Submission Audit Projection + Durable Idempotency Registry

**Status: PASSED (104/104, real MetaEditor run, 2026-08-22).**

Implements the `## C2.3 addendum — Audit Projections + Reconciliation +
Regression/Seal` section of
`Docs/PhaseC_C2_1_BrokerSubmissionContract.md` (frozen before code).
Opens after C2.2 PASSED (145/145, amended twice, merged to
`mlquantai`) and the user's explicit approval of C2.3's scope: durable
submission evidence / restart-safe idempotency only, EventStore-only,
explicitly forbidding `OrderSend`, `OnTradeTransaction`, broker
history/position/order queries, retry/modify/close, and any candidate-
lifecycle mutation from this commit.

## What this commit adds

- **`Execution/MLQuantAI_BrokerSubmissionAuditProjection.mqh`** (new,
  strictly additive, no sealed file edited):
  - `SubmissionAttemptProjection` / `SubmissionOutcomeProjection` — 0..N
    records per `execution_request_id`, never deduped, keyed by the
    event's own durable `source_sequence_number`/`source_log_event_id`.
    `BrokerSubmissionAuditProjection_RebuildFromFile()` stages C1.3's
    own sealed, **unmodified** `ExecutionAuditProjection_RebuildFromFile()`
    as a black-box gate across the whole file first, then runs ONE new,
    genuinely interleaved pass over this commit's own sibling pair
    (`EXECUTION_SUBMISSION_ATTEMPTED` and the outcome quartet
    `ORDER_SUBMISSION_ERROR`/`ORDER_SUBMITTED`/`ORDER_REJECTED`/
    `EXECUTION_SUBMISSION_UNKNOWN`) — an outcome line's
    `execution_request_id` must already have a matching attempt applied
    earlier in *this same pass*, or the whole rebuild fails closed as an
    orphan/ordering violation, exactly the rule C1.3 already froze for
    its own sibling pair. An attempt line's own reference back to the
    already-staged `ExecutionRequestProjection`/`DryRunResultProjection`
    is an orphan-only check: must exist, with a matching hash, and at
    least one `SAFETY_GATE_ACCEPTED` dry-run record for that exact
    request — never a relative-ordering check against C1's own events.
  - Outcome invariants enforced per status (mirroring
    `DryRunResultProjection`'s own decision/reason_code invariant):
    `ERROR` requires `order_send_returned == false`; `SUBMITTED`/
    `REJECTED`/`UNKNOWN` all require `order_send_returned == true`;
    `SUBMITTED`'s `reason_code` must be `REASON_SUBMITTED_OK` exactly;
    `REJECTED`'s must be one of `{REASON_BROKER_REJECT,
    REASON_INVALID_STOPS, REASON_INSUFFICIENT_MARGIN, REASON_REQUOTE}`;
    `UNKNOWN`'s must be `REASON_EXECUTION_SUBMISSION_AMBIGUOUS`. A
    mismatch between a line's own `type` and its `submission_status`
    payload field is corruption, rejected.
  - `SubmissionAttemptRegistry_HasAttempt(executionRequestId)` /
    `SubmissionAttemptRegistry_IsUnresolved(executionRequestId)` — the
    frozen, consumer-facing durable idempotency interface. `HasAttempt`
    is true for any durably-recorded attempt, resolved or not.
    `IsUnresolved` is true only when an attempt exists with **zero**
    conclusive outcome records (`ERROR`/`SUBMITTED`/`REJECTED`/`UNKNOWN`
    all count as conclusive — the doc's "no matching outcome yet" edge
    case). A request never attempted at all reads `HasAttempt=false`,
    `IsUnresolved=false` — "never attempted" is not "unresolved". This
    is the only interface any future consumer (the C2.2 integration
    follow-up patch) may call — no parsing/replay logic duplicated
    outside this file.
  - `BrokerSubmissionReconciliation_Build()` / `..._Count()` /
    `..._GetAt()` / `..._FindRowIndex()` — one row per distinct
    `execution_request_id` with ≥1 applied attempt, `latest_status`
    reusing `ENUM_SUBMISSION_STATUS` verbatim (`SUBMISSION_STATUS_NONE`
    stands for `NO_OUTCOME`, never produced by any real outcome line, so
    no collision with a genuine outcome row), computed from the
    **latest** (highest `source_sequence_number`) matching outcome
    record. A request with zero attempts never appears here — it
    belongs to C1.3's own `ExecutionReconciliationReport` instead.

## Scope guard (frozen, carried forward)

No `OrderSend`/`CTrade`/`OnTradeTransaction`/`HistorySelect`/
`PositionSelect`/`OrderSelect` call anywhere in this file — read-only
over the event store, end to end. No candidate-lifecycle transition, no
event append. `MLQuantAI_ExecutionAuditProjection.mqh`,
`MLQuantAI_SafetyGate.mqh`, `MLQuantAI_BrokerSubmissionGate.mqh`,
`MLQuantAI_BrokerSubmissionBuilder.mqh`,
`MLQuantAI_BrokerSubmissionAdapter.mqh` — all untouched.

## Test suite

**`Tests/MLQuantAI_Test_C2_3_BrokerSubmissionAuditProjection.mq5`**
(new): every fixture drives the real B5/B7/B8.5/B9/C1/C2.2 pipeline —
no fabricated hashes anywhere. Covers: full-chain rebuild +
reconciliation for all four outcome statuses (SUBMITTED/ERROR/UNKNOWN/
REJECTED); the restart-then-resend-blocked scenario (an attempt with no
outcome is `HasAttempt=true`/`IsUnresolved=true` purely from a cold
rebuild, zero in-memory state carried over); 0..N attempts never
deduped; a replayed duplicate attempt event is idempotent (re-applying
the identical line is a no-op, not a second record); a `log_event_id`
collision carrying a *different* payload fails the whole rebuild
closed, never treated as a duplicate no-op; orphan execution_request_id,
execution_request_hash mismatch, and missing-`SAFETY_GATE_ACCEPTED`
rejections on the attempt side; an outcome-before-its-own-attempt
ordering violation; a `type`/`submission_status` mismatch; a `SUBMITTED`
outcome carrying a non-`SUBMITTED_OK` reason_code; a zero-attempt
request never appearing in the reconciliation report; and a structural,
by-inspection proof of zero broker-API calls and zero duplicated
parsing logic.

## Fixed (found via the user's real MetaEditor compile, not self-review)

One test function name,
`Test_Outcome_Unknown_IsConclusive_ButHasAttemptStillBlocksResend` (64
characters), exceeded MQL5's 63-character identifier limit — the same
class of error this project already hit once in Phase B B4. Renamed to
`Test_Outcome_Unknown_ConclusiveButHasAttemptBlocksResend` (56
characters) at both the definition and its call site. No behavior
change.

## Definition of Done

- [x] `MLQuantAI_BrokerSubmissionAuditProjection.mqh` compiles with
      zero errors/warnings (real MetaEditor).
- [x] `Tests/MLQuantAI_Test_C2_3_BrokerSubmissionAuditProjection.mq5`
      compiles with zero errors/warnings after the identifier-length
      fix (real MetaEditor).
- [x] Real MetaEditor run — 104/104 ALL PASS (2026-08-22).
- [ ] C2.2 integration follow-up patch (wiring `BrokerSubmissionGate`
      to `SubmissionAttemptRegistry_HasAttempt`/`_IsUnresolved`) — not
      yet started; required before real-submit capability is
      considered safe to exercise via the opt-in smoke test.
- [ ] Full B9 + C1 + C2 regression re-run — deferred to the "C2 FULLY
      SEALED" checkpoint, matching the precedent C1 itself set.
- [ ] `OnTradeTransaction`-based reconciliation (matching real broker
      facts to `execution_request_id`) — out of scope, deferred,
      requires fresh, separate authorization.
