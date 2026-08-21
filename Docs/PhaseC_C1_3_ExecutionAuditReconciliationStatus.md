# Phase C1.3 — Audit Projections + Integrity Checks + Reconciliation Read Model

**Status: PASSED (87/87, real MetaEditor run, 2026-08-21). C1 FULLY SEALED.**
Implements `Docs/PhaseC_C1_1_ExecutionRequestContract.md`'s C1.3
addendum (frozen before code). Opens after C1.2 PASSED (128/128, real
MetaEditor run, 2026-08-21). Strictly read-only over the event data
C1.2 already durably writes - no broker query, no broker mutation, no
candidate-lifecycle transition, no retry mechanism, no C2 event type.

## What this commit adds

- **`Execution/MLQuantAI_ExecutionAuditProjection.mqh`** (new):
  `ExecutionRequestProjection` (1 record per `execution_request_id`,
  same duplicate-vs-collision rule every prior projection uses) and
  `DryRunResultProjection` (0..N records per request, keyed by the
  event's own durable `source_sequence_number` - never deduped by
  `execution_request_id` alone, since a legitimate re-evaluation after
  runtime context changes, e.g. Safe Mode cleared, is real audit
  history, not a duplicate), plus `ExecutionReconciliation_BuildReport`
  (`PAIRED`/`UNPAIRED` per request, computed only after both
  projections rebuild cleanly).

Two corrections to this project's own established projection
precedent, made before any code existed (documented in full in the
C1.3 addendum):

1. **`ORPHAN_RESULT` is a rebuild-failure category, not a third
   reconciliation status.** A completion referencing a request not yet
   seen fails the whole rebuild closed (same rule every prior "orphan
   reference" case in this project uses) - it can never survive to the
   reconciliation-report stage.
2. **Rebuild is a single, sequential, interleaved pass over the file -
   not two independent full-file passes**, unlike every prior
   `*Projection.mqh` in this project. A naive two-pass design (rebuild
   requests from the whole file, then check completions) would
   silently fail to catch a completion appearing before its own
   request in file order, since the request projection would already
   have seen the entire file by the time completions are checked. The
   single interleaved pass makes event ordering a genuinely tested
   invariant.

## Referential integrity implemented

- `ExecutionRequestProjection`: reconstructs and verifies
  `execution_request_hash` from the persisted payload (self-contained,
  no "raw evidence" gap the way `EligibilityContext` had), reconstructs
  and verifies `execution_request_id` via `Ids_ExecutionRequestId` from
  its own persisted lineage fields (a stronger check than prior
  projections used, since they lacked all raw ID components), verifies
  `risk_plan_id`/`plan_hash` against `RiskPlanProjection`,
  `ai_decision_id`/`ai_decision_hash` against `AIDecisionProjection`,
  `eligibility_decision_id`/`eligibility_decision_hash` against
  `EligibilityDecisionProjection` (transitively covering
  `FeatureSnapshotProjection`/`ModelArtifactProjection`) - AND that
  record's own `decision` must be `ELIGIBILITY_DECISION_ELIGIBLE`,
  verifies `correlation_id == Ids_CorrelationId(candidate_id,
  submit_attempt)` and `submit_attempt == 1`.
- `DryRunResultProjection`: the referenced `execution_request_id` must
  already be applied *at that point in the single interleaved scan*;
  `execution_request_hash` must match the request record's own hash;
  outcome invariant (`ACCEPTED` requires `REASON_NONE`, `REJECTED`
  requires a non-`NONE` reason); a defensive tamper check rejects any
  line carrying a `ticket`/`retcode`/`fill_price`/`slippage_points`
  key, since real C1 emission never writes these.

## Test coverage

- **Full-chain rebuild**: proves referential integrity across all
  seven layers (candidate → snapshot → model artifact → AI decision →
  risk plan → eligibility decision → execution request), reconciliation
  reports `PAIRED`.
- **Multiple re-evaluations preserved, never deduped**: the same
  immutable request evaluated twice (Safe/dry-run state differing
  between calls) produces two distinct `DryRunResultProjection`
  records with different `source_sequence_number` identities - the
  request itself stays a single record (duplicate no-op on its second
  `EXECUTION_REQUEST_CREATED` line).
- **Duplicate vs. collision**: identical request re-emitted under a
  fresh session → no-op. Same `execution_request_id` with a
  content-mutated (different hash) request → rebuild fails entirely,
  `first_error` names the collision.
- **Orphan reference**: an `EXECUTION_REQUEST_CREATED` line whose
  `risk_plan_id` doesn't resolve fails the whole rebuild.
- **Ordering violation**: physically swapping a real request/completion
  pair's file positions so the completion precedes its own request -
  fails the whole rebuild, proving the single-pass design actually
  enforces ordering (a naive two-pass rebuild would have missed this).
- **Outcome invariant violation**: an `ACCEPTED` completion tampered to
  carry a non-`NONE` `reason_code` fails the rebuild.
- **Broker-field injection**: a fake `ticket` key spliced into a real
  completion line fails the rebuild.
- **`UNPAIRED` reconciliation**: a request durably written with its
  completion write deliberately skipped (the C1.2 non-rollback edge
  case) reports `UNPAIRED`, correctly flagging the exact
  `execution_request_id` - not treated as corruption.
- **Structural proof**: no broker/order/account-mutating call anywhere
  in the projection/reconciliation path.

## Scope guard (kept, per the frozen addendum)

```
No broker query (BrokerReconciliation.mqh untouched, not a dependency)
No broker mutation
No candidate lifecycle transition
No retry mechanism
No C2 event type
```

## Result

Real MetaEditor run: **87/87 checks passed, ALL PASS** for
`MLQuantAI_Test_C1_3_ExecutionAuditReconciliation.mq5` (one real bug
found and fixed along the way - see below). Manual regression re-run
in the same MetaEditor session, all real, all ALL PASS:
`Test_B9_ExecutionEligibility.mq5` 120/120,
`Test_B9_Commit2_EligibilityEvent.mq5` 84/84,
`Test_B9_Commit3_IntegrationRegression.mq5` 79/79,
`Test_C1_2_ExecutionRequestSafetyGate.mq5` 128/128.

C1.3 is PASSED and merged to `mlquantai`.

### Real issues found via the user's actual MetaEditor runs (not self-review)

1. **Compile error**: `ExecutionRequestProjection_ApplyLine` passed its
   own `ExecutionRequestProjectionRecord` (a different struct, despite
   sharing field names) to `ExecutionRequest_ComputeHash`, which
   requires the real `ExecutionRequest` type. Fixed by reconstructing
   a real `ExecutionRequest` from the same persisted fields purely for
   the hash recompute.
2. **Test-construction bug** (not a production-code bug): the
   ordering-violation test's simple line swap also broke
   `EventStoreValidator`'s own separate, more general strict-monotonic-
   `seq` gate ("backwards seq" corruption), which fires before this
   file's own per-line orphan/ordering check ever runs - so
   `first_error` came from the wrong layer and the assertion checking
   for "orphan"/"ordering" in the message failed. Fixed by renumbering
   every line's own `seq` field to match its new physical position
   after the swap, so the file passes the validator cleanly and the
   project's own single-interleaved-pass ordering logic is what
   actually catches and rejects it - the invariant this test was
   always meant to isolate.

## C1 FULLY SEALED

**C1.2 (128/128) + C1.3 (87/87) = 215/215, all real MetaEditor runs**,
plus a full manual regression re-run of the entire B9 chain
(120/120 + 84/84 + 79/79 = 283/283) in the same session confirming no
regression anywhere in B9. Combined with C1.1's frozen contract (no
code), C1 (ExecutionRequest + Safety Gate + Dry-Run, contract through
audit/reconciliation) is fully sealed - zero broker mutation anywhere
across all of C1. C2 (real broker submit) stays explicitly held
pending separate, explicit user authorization.
