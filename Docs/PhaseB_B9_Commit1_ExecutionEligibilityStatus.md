# Phase B9 — Commit 1: Execution Eligibility Pure Mapping

**Status: Implemented, awaiting real compile/test confirmation.**
Implements `Docs/PhaseB_B9_ExecutionEligibilityContract.md` (frozen
before code). Opens after B8.5 SEALED (254/254, all real MetaEditor
runs). Pure mapping only - no event store, no state-machine transition,
no live account/tick/broker/`SafeMode` call, no mutation of any input.

## What this commit adds

- **`Core/MLQuantAI_Enums.mqh`** (additive): `ENUM_ELIGIBILITY_DECISION`
  (`NONE`/`ELIGIBLE`/`REJECTED`, a new enum - deliberately not a reuse
  of `ENUM_RISK_DECISION` (B7's sizing-success axis) or
  `ENUM_AI_DECISION_OUTCOME` (B8.5's AI-only axis)) +
  `EligibilityDecisionToString`/`EligibilityDecisionFromString`.
- **`Core/MLQuantAI_ContractVersions.mqh`** (additive):
  `MLQUANTAI_ELIGIBILITY_CONTEXT_SCHEMA_B9_V1`,
  `MLQUANTAI_ELIGIBILITY_DECISION_SCHEMA_B9_V1`.
- **`Core/MLQuantAI_Ids.mqh`** (additive):
  `Ids_EligibilityDecisionId(candidateId, eligibilityPolicyVersion)` -
  identity deliberately independent of every content field, matching
  every prior `Ids_*Id` philosophy.
- **`Execution/MLQuantAI_EligibilityContract.mqh`** (new):
  `EligibilityContext` (live-state snapshot, embeds `AccountSnapshot`
  verbatim, no separate identity - only a content hash, matching
  `InferenceResult`'s own precedent, since the same candidate can be
  legitimately re-evaluated multiple times with genuinely different
  account state each time), `EligibilityPolicy` (explicit, versioned
  thresholds, `0` = gate disabled), and `EligibilityDecision` (the
  frozen output record), with
  `EligibilityContext_Init`/`_HashPayload`/`_ComputeHash` and
  `EligibilityDecision_Init`/`_HashPayload`/`_ComputeHash`.
- **`Execution/MLQuantAI_EligibilityBuilder.mqh`** (new):
  `EligibilityDecision_Build` - the fail-closed ladder frozen in the
  contract (RiskPlan/AIDecision boundary checks -> 3-way lineage
  cross-check -> policy shape -> `EligibilityContext` integrity ->
  decide in the frozen precedence order -> identity/hash). Takes
  `RiskPlan`, `AIDecision`, `FeatureSnapshot`, `EligibilityContext`,
  and `EligibilityPolicy` as inputs (never a raw `TradeCandidate`).
- **`Tests/MLQuantAI_Test_B9_ExecutionEligibility.mq5`** (new, 22 test
  functions).

## Test coverage

- **Accept path**: healthy context + AI `ALLOW` + every gate
  disabled-or-passing -> `ELIGIBLE`/`REASON_NONE`, every field verified
  copied verbatim from its real source.
- **AI veto**: `AIDecision.decision_outcome == REJECT` ->
  `REJECTED`/`REASON_AI_REJECT` even with a healthy operational state;
  `== ABSTAIN` (hand-constructed, since B8.5 v1 policy never produces
  it) -> `REJECTED`/`REASON_AI_ABSTAIN`, verified distinct from
  `REASON_AI_REJECT`.
- **Each of the 6 reachable operational gates** (`DAILY_LOSS_LIMIT`,
  `MAX_DRAWDOWN`, `MAX_TOTAL_EXPOSURE`, `MAX_OPEN_POSITIONS`, `MARGIN`,
  `CIRCUIT_BREAKER`), isolated individually: tripped with the gate
  enabled -> `REJECTED` with the matching reason; the identical
  tripping account state with that one gate at `0` (disabled) -> does
  NOT trigger.
- `margin_level == 0` (no margin used) with `min_margin_level > 0`
  enabled -> does NOT trigger `REASON_RISK_MARGIN` (the `> 0` guard
  documented in the contract).
- **Precedence**: an input engineered to trip both an AI veto and an
  operational gate simultaneously -> the AI reason wins, per the
  frozen order.
- **Fail-closed**: empty `risk_plan_id`; empty `ai_decision_id`; each
  of the 3-way lineage mismatches isolated individually
  (`RiskPlan`/`AIDecision`, `AIDecision`/`FeatureSnapshot`,
  `FeatureSnapshot`/`RiskPlan`); empty `eligibility_policy_version`;
  each of the 5 policy thresholds out-of-range isolated individually;
  `eligibility_context_hash` empty or stale (not recomputed after a
  content mutation); a hand-constructed non-finite `account` field
  (defensive boundary check).
- **Determinism**: 1,000 repeated builds of the identical inputs
  produce byte-identical `eligibility_decision_id`/
  `eligibility_decision_hash` every time.
- **Identity sensitivity**: a different `eligibility_policy_version`
  moves `eligibility_decision_id`.
- **Hash sensitivity, identity held fixed**: changing
  `safe_mode_active` alone moves `eligibility_decision_hash` while
  `eligibility_decision_id` stays byte-identical.
- **No mutation**: `plan`/`decision`/`snapshot`/`context`/`policy`
  unchanged before and after `EligibilityDecision_Build`, on both the
  eligible and a rejected path.
- **No side effects (structural)**: no `EventStore_Log*`/broker/
  account/tick/`SafeMode_IsActive` call anywhere in
  `EligibilityDecision_Build`.

Not yet compiled/run by the user - do not treat as PASSED or merge
until a real MetaEditor log confirms it.
