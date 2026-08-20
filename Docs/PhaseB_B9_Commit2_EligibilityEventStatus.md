# Phase B9 — Commit 2: `EXECUTION_ELIGIBILITY_DECIDED` Event + `CANDIDATE_REJECTED_BY_RISK` Lifecycle Wiring + `EligibilityDecisionProjection`

**Status: PASSED (84/84, real MetaEditor run, 2026-08-20).**
Implements the Commit 2 addendum in
`Docs/PhaseB_B9_ExecutionEligibilityContract.md` (frozen before code).
Opens after B9 Commit 1 PASSED (120/120, real MetaEditor run,
2026-08-20). Adds durable event emission and replay for the
`EligibilityDecision` Commit 1 already knows how to build in memory -
still no broker/order/execution action of any kind on the `ELIGIBLE`
path.

## What this commit adds

- **`Core/MLQuantAI_Enums.mqh`** (additive): `EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED`
  appended after `EVENT_TYPE_AI_DECISION_CREATED` (the confirmed true
  tail of `ENUM_EVENT_TYPE`) + matching
  `EventTypeToString`/`EventTypeFromString` cases. `CANDIDATE_REJECTED_BY_RISK`
  itself is not a new value - it is the existing, already-sealed
  `ENUM_CANDIDATE_STATE` transition target, reached via the existing,
  sealed `EventStore_LogTransition`.
- **`Execution/MLQuantAI_EligibilityEventEmission.mqh`** (new):
  `EligibilityDecision_ToExtraJson` (every `EligibilityDecision` field +
  all 8 real `AccountSnapshot` fields, prefixed `account_`, + `safe_mode_active`
  - the raw evidence that lets replay independently recompute and
  verify `eligibility_context_hash`, since `EligibilityContext` has no
  upstream event of its own) and
  `EligibilityDecision_EmitDecisionAndWireLifecycle` - the Commit 2
  boundary function. Always writes `EXECUTION_ELIGIBILITY_DECIDED`
  first (`ELIGIBLE` and `REJECTED` both - audit evidence either way);
  only when `decision == REJECTED`, and only strictly after that write
  is already durable, additionally calls
  `EventStore_LogTransition(candidate, CANDIDATE_REJECTED_BY_RISK, d.reason_code, extraJson)`.
  `ELIGIBLE` never emits a lifecycle transition and never touches
  submission/order/broker in any way. Frozen non-rollback rule: if the
  decision write succeeds but the lifecycle write then fails, the
  function returns `false` but the already-durable
  `EXECUTION_ELIGIBILITY_DECIDED` line is never rewritten or deleted
  (the store is append-only) - a `false` return on the `REJECTED` path
  means "decision durably recorded, lifecycle state may not reflect it
  yet," never "nothing happened."
- **`Execution/MLQuantAI_EligibilityDecisionProjection.mqh`** (new): a
  read-only `EligibilityDecisionProjectionRecord` registry mirroring
  `AIDecisionProjection`'s structure/hardening discipline. First
  projection in the project with **three** independent upstream chains
  to verify on rebuild: `RiskPlanProjection`, `AIDecisionProjection`
  (which itself transitively rebuilds `FeatureSnapshotProjection` +
  `ModelArtifactProjection`), and `FeatureSnapshotProjection` again
  explicitly (defense in depth, reached a second way via the
  AIDecision record's own `feature_snapshot_id`). Also reconstructs an
  `EligibilityContext` from each record's persisted raw account/safe-mode
  evidence and recomputes `EligibilityContext_ComputeHash()`, requiring
  an exact match against the persisted `eligibility_context_hash` -
  this is what makes the raw evidence protective rather than
  write-only: any tampered field moves the hash and fails the line
  closed. `EligibilityDecisionProjection_RebuildFromFile` gates on
  `EventStoreValidator`, then `RiskPlanProjection_RebuildFromFile`,
  `AIDecisionProjection_RebuildFromFile`, and
  `FeatureSnapshotProjection_RebuildFromFile`, in that order, before
  ever touching this registry - if any upstream rebuild fails, this
  registry is left completely untouched.
- **`Tests/MLQuantAI_Test_B9_Commit2_EligibilityEvent.mq5`** (new, 10
  test functions).

## Test coverage

- **`ELIGIBLE` path**: exactly one `EXECUTION_ELIGIBILITY_DECIDED` line
  written, zero `CANDIDATE_REJECTED_BY_RISK` lines, candidate stays at
  `CANDIDATE_CREATED` live and on replay (via the real, sealed
  `ReplayEngine_Run` + `StateProjector_TryGetState`).
- **`REJECTED` path**: `EXECUTION_ELIGIBILITY_DECIDED` then exactly one
  terminal `CANDIDATE_REJECTED_BY_RISK`, verified strictly in that
  store order; the persisted lifecycle line's own `reason` matches the
  paired `EligibilityDecision.reason_code` exactly; candidate reaches
  `CANDIDATE_REJECTED_BY_RISK` live and on replay.
- **Duplicate vs. collision on replay**: identical `eligibility_decision_id`
  + identical `eligibility_decision_hash` re-emitted under a fresh
  session -> rebuild succeeds, registry stays at exactly one record
  (no-op). Identical `eligibility_decision_id` + a `reason_code`-mutated,
  differently-hashed decision -> rebuild fails entirely, `first_error`
  names the collision (not a duplicate no-op).
- **Context-evidence tamper, each of the 8 hash-protected fields
  independently**: `account_balance`/`account_equity`/`account_margin_level`/
  `account_open_positions_count`/`account_open_risk_percent`/
  `account_daily_pnl_percent`/`account_drawdown_from_peak_percent`/
  `safe_mode_active` - tampering any one moves the recomputed context
  hash and fails the rebuild closed, attributed to context-hash
  reconstruction. `account_context_schema_version` is deliberately
  excluded from this loop, since Commit 1's own frozen
  `EligibilityContext_HashPayload` never includes it - it is persisted
  as audit evidence only.
- **Orphan references, each independently**: an `EXECUTION_ELIGIBILITY_DECIDED`
  line whose `risk_plan_id` (or `ai_decision_id`) does not resolve
  against the already-rebuilt upstream registry fails the whole
  rebuild, `first_error` names the orphan.
- **Cross-layer failure propagation**: corrupting the real
  `FEATURE_SNAPSHOT_CREATED` line's own `feature_snapshot_id` blocks
  eligibility rebuild too, `first_error` attributed to the AI decision
  registry prerequisite (which itself depends on the snapshot layer) -
  proving the three-chain gate is a real dependency, not decorative.
- **Malformed line**: a truncated/garbage line anywhere in the store
  blocks the whole rebuild; the registry is left completely untouched.
- **Structural proof**: no `OrderSend`/`CTrade`/`AccountInfo*`/
  `PositionsTotal`/`SafeMode_IsActive`/ONNX call anywhere in the
  emission or projection path - replay never recomputes a fresh
  account/safe-mode value, it only verifies persisted evidence.

## Scope guard (kept, per the frozen addendum)

- No resurrection of the dormant `RiskDecision` struct.
- No use of `TradeCandidate_Transition` (`EventStore_LogTransition`
  only, matching every other B-phase lifecycle write).
- No change to `CandidateProjection`'s own scope (still
  `CANDIDATE_CREATED`-only, by design).
- No execution/submission wiring on the `ELIGIBLE` path.
- No fresh account/safe-mode computation anywhere in the replay path -
  only verification of persisted evidence.

## Result

Real MetaEditor run: **84/84 checks passed, ALL PASS.** B9 Commit 2 is
PASSED and merged to `mlquantai`.

## Next step

B9 Commit 3 ("full-chain regression + seal," per the already-discussed
B9 roadmap) does not start until the user gives an explicit go-ahead.
