# Phase B8.5 — Commit 2: `AI_DECISION_CREATED` Event + `AIDecisionProjection`

**Status: Implemented, awaiting real compile/test confirmation.**
Implements `Docs/PhaseB_B8_5_AIDecisionContract.md`'s Commit 2 addendum
(frozen before code, after a collision check against
`AI_DECISION_CREATED`/`AIDecisionProjection`/`AIDecisionRegistry`/
`ai_decision_id`/`ai_decision_hash`/`AIDecision_Emit`/
`EVENT_TYPE_AI_DECISION`/`AI_DECISION`/`ENUM_EVENT_TYPE`/
`EVENT_TYPE_CANDIDATE_REJECTED_BY_AI`/`AIResult`). Opens after Commit 1
PASSED (72/72, real MetaEditor run). Persistence + projection + replay
only - no execution behavior for any `decision_outcome`.

## What this commit adds

- **`Core/MLQuantAI_Enums.mqh`** (additive): `EVENT_TYPE_AI_DECISION_CREATED`
  appended after `EVENT_TYPE_MODEL_ARTIFACT_REGISTERED` (the current
  true tail), with `EventTypeToString`/`EventTypeFromString` cases.
  Also additive: `AiDecisionOutcomeFromString`, the missing inverse of
  Commit 1's `AiDecisionOutcomeToString`, needed for
  `AIDecisionProjection` to parse `decision_outcome` back from JSON.
- **`AI/MLQuantAI_AIDecisionEventEmission.mqh`** (new):
  `AIDecision_ToExtraJson` (all 18 `AIDecision` fields flattened, same
  convention as `FeatureSnapshot_ToExtraJson`/`ModelArtifact_ToExtraJson`)
  + `AIDecision_EmitAIDecisionCreated` - the Commit 2 boundary function.
  Only outcome-based gate: `ai_decision_id == ""` (a failed
  `AIDecision_Build`) emits nothing. `ALLOW`/`REJECT`/`ABSTAIN` are all
  emitted identically, as audit evidence only - no branching on
  `decision_outcome` anywhere in this file.
- **`Infrastructure/EventStore/MLQuantAI_AIDecisionProjection.mqh`**
  (new): `AIDecisionProjectionRecord` + live-sync/replay/rebuild
  functions, mirroring `FeatureSnapshotProjection.mqh`'s exact
  structure and hardening discipline. The one point genuinely stricter
  than any prior projection in this project: `AIDecisionProjection_RebuildFromFile`
  independently rebuilds and verifies against **two** upstream
  registries - `FeatureSnapshotProjection` (checking
  `feature_snapshot_id`/`feature_snapshot_hash`/`feature_vector_hash`/
  `candidate_id`/`candidate_hash`) and `ModelArtifactProjection`
  (checking `model_registry_id`/`model_registry_hash`/
  `model_artifact_hash`) - every prior projection here only ever had one
  upstream chain to verify.
- **`Tests/MLQuantAI_Test_B8_5_Commit2_AIDecisionEvent.mq5`** (new, 15
  test functions, using the real B5/B8.1/B8.3/B8.4/B8.5-Commit-1
  pipeline for every fixture).

## Test coverage

- Exactly one `AI_DECISION_CREATED` per valid `AIDecision`; re-emitting
  the identical decision live is a no-op; a failed `AIDecision_Build`
  (`ai_decision_id == ""`) emits nothing.
- Replay: same id + same hash -> duplicate no-op; same id + different
  hash -> collision, rejected.
- Referential integrity against `FeatureSnapshotProjection`: orphan
  `feature_snapshot_id`, and `feature_snapshot_hash`/
  `feature_vector_hash`/`candidate_id`/`candidate_hash` mismatches -
  each isolated individually, each rejected, whole rebuild fails
  closed.
- Referential integrity against `ModelArtifactProjection`: orphan
  `model_registry_id`, and `model_registry_hash`/`model_artifact_hash`
  mismatches - each isolated individually, each rejected, whole
  rebuild fails closed.
- A truncated/malformed line anywhere blocks the entire rebuild.
- Restart/crash simulation (repeated rebuilds) and multi-session stores
  reconstruct byte-identical records.
- Every field on a rebuilt record matches the original `AIDecision`
  exactly.
- `ALLOW` and `REJECT` decisions both replay correctly and identically
  in the same store - no special-casing by `decision_outcome` anywhere
  in the emission/projection path, proving the "audit evidence only, no
  execution behavior" invariant holds structurally.
- No execution/order/broker/account call anywhere in
  `AIDecision_EmitAIDecisionCreated`/`AIDecisionProjection` - verified
  by inspection.

Not yet compiled/run by the user - do not treat as PASSED or merge
until a real MetaEditor log confirms it.
