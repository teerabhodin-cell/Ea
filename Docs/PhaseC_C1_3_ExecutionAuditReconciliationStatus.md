# Phase C1.3 — Audit Projections + Integrity Checks + Reconciliation Read Model

**Status: Implemented, awaiting real MetaEditor compile/test confirmation.**
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

## Next step

Awaiting a real MetaEditor compile + run of
`MLQuantAI_Test_C1_3_ExecutionAuditReconciliation.mq5`, plus the manual
regression re-run of `Test_B9_ExecutionEligibility.mq5`,
`Test_B9_Commit2_EligibilityEvent.mq5`,
`Test_B9_Commit3_IntegrationRegression.mq5`, and
`Test_C1_2_ExecutionRequestSafetyGate.mq5` in the same session. Only a
genuine, clean real log for all five moves this to PASSED and seals
C1: contract (C1.1) + build/gate/emission (C1.2) + audit
projection/reconciliation (C1.3). C2 (real broker submit) stays
explicitly held pending separate, explicit user authorization.
