# Phase C1.2 — ExecutionRequest Build + SafetyGate + Dry-Run Emission

**Status: Implemented, awaiting real MetaEditor compile/test confirmation.**
Implements `Docs/PhaseC_C1_1_ExecutionRequestContract.md`'s C1.2
addendum (frozen before code). Opens after C1.1's contract freeze was
confirmed. Still **zero broker mutation** anywhere: no
`OrderSend`/`CTrade`/pending-order API/position-mutating call, no
`CANDIDATE_SUBMITTED` or any other candidate-lifecycle transition, no
use of the dormant `EVENT_TYPE_ORDER_*` event types.

## What this commit adds

- **`Core/MLQuantAI_ContractVersions.mqh`** (additive):
  `MLQUANTAI_EXECUTION_REQUEST_SCHEMA_C1_V1`,
  `MLQUANTAI_EXECUTION_POLICY_SCHEMA_C1_V1`,
  `MLQUANTAI_DRY_RUN_RESULT_SCHEMA_C1_V1`.
- **`Core/MLQuantAI_ReasonCodes.mqh`** (additive): 11 new
  `ENUM_REASON_CODE` values, appended after `REASON_AI_ABSTAIN` -
  `REASON_EXECUTION_SUBMIT_DISABLED`/`_ENVIRONMENT_NOT_PERMITTED`/
  `_MANUAL_APPROVAL_REQUIRED`/`_ACCOUNT_NOT_ALLOWED`/`_SYMBOL_NOT_ALLOWED`/
  `_ORDER_TYPE_NOT_MARKET`/`_VOLUME_POLICY_INVALID`/`_VOLUME_CAP_EXCEEDED`/
  `_EXPOSURE_POLICY_INVALID`/`_EXPOSURE_CAP_EXCEEDED`/
  `_DEVIATION_POLICY_INVALID`/`_LINEAGE_INVALID`. Safe Mode reuses the
  existing `REASON_RISK_CIRCUIT_BREAKER` rather than a duplicate.
- **`Core/MLQuantAI_Enums.mqh`** (additive):
  `EVENT_TYPE_EXECUTION_REQUEST_CREATED`/`EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED`
  (appended after `EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED`, the
  confirmed true tail), `ENUM_EXECUTION_ENVIRONMENT_MODE`
  (`NONE`/`TESTER`/`DEMO`/`LIVE`), `ENUM_SAFETY_GATE_DECISION`
  (`NONE`/`ACCEPTED`/`REJECTED`), each with matching
  `ToString`/`FromString`.
- **`Core/MLQuantAI_Ids.mqh`** (additive):
  `Ids_ExecutionRequestId(candidateId, eligibilityDecisionId,
  aiDecisionId, riskPlanId, executionPolicyVersion)`.
- **`Execution/MLQuantAI_ExecutionRequestContract.mqh`** (new):
  `ExecutionPolicy` (caller-supplied configuration, zero-cap-means-
  reject semantics), `ExecutionRequest` (the frozen, immutable
  execution intent - every lineage/order field copied verbatim from
  `TradeCandidate`/`RiskPlan`/`AIDecision`/`EligibilityDecision`),
  `DryRunExecutionResult` (`SafetyGate_Evaluate`'s verdict, carrying
  `observed_symbol`/`observed_account_login` as audit evidence only -
  never fed into identity/hash). Deliberately NOT a reuse of the
  dormant Phase-A/pre-B `ExecutionResult`/`ExecutionEvent` structs.
- **`Execution/MLQuantAI_ExecutionRequestBuilder.mqh`** (new):
  `ExecutionRequest_Build` - the fail-closed ladder (ELIGIBLE-only gate
  → boundary checks → 4-way lineage cross-check → policy shape →
  build). A `REJECTED` `EligibilityDecision` never produces a request.
- **`Execution/MLQuantAI_SafetyGate.mqh`** (new): `SafetyGate_Evaluate`
  - the frozen, 12-step, first-match-wins gate order from the C1.2
  addendum. `_Symbol`/`AccountInfoInteger(ACCOUNT_LOGIN)` read exactly
  once, at the start of evaluation.
- **`Execution/MLQuantAI_ExecutionRequestEventEmission.mqh`** (new):
  `ExecutionRequest_ToExtraJson`/`DryRunExecutionResult_ToExtraJson`
  and `ExecutionRequest_EmitAndEvaluate` - the C1.2 boundary function.
  Always emits `EXECUTION_REQUEST_CREATED` first, then evaluates the
  Safety Gate, then always emits `EXECUTION_DRY_RUN_COMPLETED`
  (`ACCEPTED` and `REJECTED` both). Never calls
  `EventStore_LogTransition`, never touches `candidate.state` - takes
  no `TradeCandidate` parameter at all, since dry-run has no lifecycle
  authority in C1.
- **`Tests/MLQuantAI_Test_C1_2_ExecutionRequestSafetyGate.mq5`** (new,
  20 test functions).

## Test coverage

- **Build fail-closed**: a `REJECTED` `EligibilityDecision` never
  produces a request (no partial record). An `ELIGIBLE` chain produces
  a request with every field copied verbatim, `submit_attempt == 1`,
  `correlation_id == Ids_CorrelationId(candidate_id, 1)`.
- **Determinism**: 200 repeated builds of identical inputs produce a
  byte-identical `execution_request_id`/`execution_request_hash`. A
  different `execution_policy_version` moves the id. A content-only
  change (e.g. `lot_size`) moves the hash while the id stays fixed.
- **Every gate in the frozen 12-step order, isolated**: `dry_run=false`
  always rejects (`REASON_EXECUTION_SUBMIT_DISABLED`); Safe Mode active
  rejects unconditionally; `environment_mode == NONE` rejects;
  `manual_approval_required == true` always rejects in C1.2; account
  allowlist (not-allowlisted rejects, **empty allowlist rejects too**,
  allowlisted against the real current login passes); symbol allowlist
  (same three cases against `_Symbol`); a pending order type rejects,
  market-only passes; volume/exposure caps (unconfigured `<= 0` rejects
  as policy-invalid, exceeded rejects, within cap passes) - exposure
  defined as `RiskPlan.risk_amount`, not notional value; deviation cap
  (`< 0` rejects as policy-invalid, `0` is a valid explicit
  zero-deviation policy); a tampered/stale `execution_request_hash`
  rejects as lineage-invalid.
- **Emission**: `ACCEPTED` and `REJECTED` paths both write exactly one
  `EXECUTION_REQUEST_CREATED` + one `EXECUTION_DRY_RUN_COMPLETED` line,
  no `ticket`/`retcode`/`fill_price`/`slippage_points` field anywhere
  in either, zero `EVENT_TYPE_ORDER_*` lines, zero `CANDIDATE_SUBMITTED`
  lines, candidate state untouched in both cases.
- **Structural proof**: no `OrderSend`/`CTrade`/`PositionOpen`/
  `PositionClose`/`OrderModify`/any market-or-pending-order-placement
  call anywhere in the three new `.mqh` files.

## Scope guard (kept, per the frozen addendum)

- No resurrection/reuse of the dormant `ExecutionResult`/`ExecutionEvent`.
- No use of the dormant `EVENT_TYPE_ORDER_SUBMITTED`/`_ORDER_FILLED`/
  `_ORDER_REJECTED`/`_POSITION_CLOSED` - reserved for C2.
- No `submit_attempt` auto-increment or retry logic.
- No mutation of `TradeCandidate.correlation_id`.
- `ExecutionPolicy.allowed_order_types` stays reserved/unused - market-
  only is a hard-coded C1 invariant, not policy-driven yet.
- No broker reconciliation query anywhere (`BrokerReconciliation.mqh`
  untouched, not a C1 prerequisite).

## Next step

Awaiting a real MetaEditor compile + run of
`MLQuantAI_Test_C1_2_ExecutionRequestSafetyGate.mq5`. Only a genuine,
clean real log moves this to PASSED and merges to `mlquantai`. C1.3
("Audit event/read model, reconciliation state model, regression/seal,"
per the already-discussed C1 roadmap) does not start without the
user's explicit go-ahead after C1.2 is genuinely PASSED.
