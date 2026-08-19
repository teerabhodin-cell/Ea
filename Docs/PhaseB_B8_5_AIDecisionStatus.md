# Phase B8.5 — Commit 1: AIDecision + Threshold-Policy Pure Mapping

**Status: Implemented, awaiting real compile/test confirmation.**
Implements `Docs/PhaseB_B8_5_AIDecisionContract.md` (frozen before
code). Opens after B8.4 SEALED (210/210 automated + manual
terminal-restart checklist PASSED). Pure mapping only - no
`AI_DECISION_CREATED`, no event store, no ONNX/runtime call, no
broker/account/tick call, no mutation of any input.

## What this commit adds

- **`Core/MLQuantAI_Enums.mqh`** (additive): `ENUM_AI_DECISION_OUTCOME`
  (`NONE`/`ALLOW`/`REJECT`/`ABSTAIN`, a new enum - deliberately not a
  reuse of Phase A's `ENUM_AI_DECISION`, whose `REDUCE_RISK` value
  doesn't fit B8.5's scope) + `AiDecisionOutcomeToString`.
- **`Core/MLQuantAI_ReasonCodes.mqh`** (additive): `REASON_AI_ABSTAIN`
  appended at the true tail of `ENUM_REASON_CODE` (immediately before
  `REASON_COUNT`), plus its `ReasonCodeToString`/`ReasonCodeFromString`
  entries. `REASON_AI_LOW_CONFIDENCE`/`REASON_AI_HIGH_UNCERTAINTY`
  (Phase A, dormant) untouched - still reserved/unreachable, as frozen.
- **`Core/MLQuantAI_ContractVersions.mqh`** (additive):
  `MLQUANTAI_AI_DECISION_SCHEMA_B8_5_V1`.
- **`Core/MLQuantAI_Ids.mqh`** (additive): `Ids_AIDecisionId(candidateId, modelRegistryId, decisionPolicyVersion)`
  - identity deliberately independent of every content field, matching
    `Ids_RiskPlanId`/`Ids_FeatureSnapshotId`/`Ids_ModelRegistryId`'s own
    philosophy.
- **`AI/MLQuantAI_AIDecisionContract.mqh`** (new): `AIDecisionPolicy`
  struct (`decision_policy_version`/`threshold_version`/`allow_threshold`)
  and `AIDecision` struct (full field list per the frozen contract),
  with `AIDecision_Init`/`AIDecision_HashPayload`/`AIDecision_ComputeHash`.
  Hash payload excludes `ai_decision_id` (identity) and
  `ai_decision_schema_version` (own top-level schema stamp, following
  the `RiskPlan`/`TrainingDatasetRow` default rather than
  `ModelArtifact`'s deliberate departure).
- **`AI/MLQuantAI_AIDecisionBuilder.mqh`** (new): `AIDecision_Build` -
  the fail-closed ladder frozen in the contract (policy shape ->
  threshold range -> snapshot referential match -> defensive
  `p_success` re-check -> decide -> identity/hash). Takes both
  `InferenceResult` and `FeatureSnapshot` as inputs, since
  `InferenceResult` alone carries no `candidate_id`/`candidate_hash`.
- **`Tests/MLQuantAI_Test_B8_5_AIDecision.mq5`** (new, 13 test
  functions).

## Test coverage

- **Accept path**: `p_success` above threshold -> `ALLOW`/`REASON_NONE`,
  every field verified copied verbatim from its real source; exact
  boundary (`p_success == allow_threshold`) -> `ALLOW` (inclusive);
  below threshold -> `REJECT`/`REASON_AI_REJECT`.
- **Determinism**: 10,000 repeated builds of the identical inputs
  produce byte-identical `ai_decision_id`/`ai_decision_hash` every
  time.
- **Identity sensitivity**: a different `decision_policy_version` or a
  different `model_registry_id` each move `ai_decision_id`.
- **Hash sensitivity, identity held fixed**: changing `p_success`,
  `allow_threshold`, `model_registry_hash`, or the snapshot's own
  content (`feature_vector_hash`/`feature_snapshot_hash`, via a
  different `atr_m15` on the *same* `candidate_id`) each moves
  `ai_decision_hash` while `ai_decision_id` stays byte-identical -
  proves the "same identity, different hash is a real drift signal"
  property actually holds, not just asserted in prose.
- **Fail-closed**: empty `decision_policy_version`/`threshold_version`;
  `allow_threshold` non-finite or outside `[0,1]` (both directions,
  plus the `0.0`/`1.0` inclusive boundaries accepted); a
  `FeatureSnapshot` that doesn't match the `InferenceResult`'s pinned
  lineage (each of the 3 pinned fields isolated individually);
  `output_values` wrong length, non-finite, or out-of-range (defensive
  check against a hand-constructed `InferenceResult` that bypassed
  B8.4's own validation). Every failure leaves `AIDecision` at
  `Init()` defaults - no partial record.
- **No mutation**: `inference`/`snapshot`/`policy` unchanged before and
  after `AIDecision_Build`, on both the accept path and a reject path.
- **No side effects (structural)**: no `EventStore_Log*`/ONNX/broker/
  account/tick call anywhere in `AIDecision_Build`.

Not yet compiled/run by the user - do not treat as PASSED or merge
until a real MetaEditor log confirms it.
