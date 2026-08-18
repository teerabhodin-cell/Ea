# Phase B8 / B9 — AI/ML Decision Layer + Execution Eligibility: Roadmap Notes (Not Implemented)

**Status: Planning notes only. No code exists for anything in this
document.** Captured so the architectural direction isn't lost, but
this is INPUT for whoever formally kicks off B8/B9 — not a spec, and
not scoped or frozen the way `Docs/PhaseB_B7_RiskPlanContract.md` was
before B7 code was written. Each of B8/B9 needs its own kickoff/DoD
gate from the user before anything here is built, same as every other
phase in this project.

## The core architectural decision

AI/ML is not cut from MLQuantAI's scope — it moves from "logic
embedded in the deterministic core" to "a versioned, hashable,
auditable decision layer that runs parallel to B7, not ahead of it."

```text
TradeCandidate (sealed, B5)
   ├──→ B7: RiskContext → RiskPlan (deterministic sizing, already PASSED)
   │
   └──→ B8: FeatureSnapshot → AI/ML Meta-Filter → AIDecision
                                      │
RiskPlan ─────────────────────────────┤
                                      ↓
                         B9: Execution Eligibility Policy
                                      ↓
                                Execution (Phase C)
```

**AI runs parallel to B7, not before it** — this was a real correction
made during this planning round (an earlier framing had AI gating
RiskPlan creation, which would let an AI outage/slowdown block B7's
deterministic sizing entirely; the corrected version lets B7 always
produce a `RiskPlan` from `TradeCandidate` alone, with AI's output
joining only at B9's execution-eligibility decision).

## What AI owns vs. does not own

**AI (B8) owns:** score, calibrated probability, `ALLOW`/`REJECT`/
`ABSTAIN`, regime suitability, predicted setup quality/expected
outcome class, structured explanation tags, confidence/uncertainty.

**AI does NOT own, ever:** `entry`/`sl`/`tp`, `lot`/`lot_size`,
`risk_amount`/`risk_money`, `risk_plan_id`, or any mutation of
`TradeCandidate`/`RiskPlan`. Those stay deterministic outputs of
B5/B7 so replay and audit keep a stable baseline regardless of which
model version produced which decision alongside them.

## B8 sub-phase breakdown (as proposed)

| Sub-phase | Contents |
|---|---|
| B8 Commit 1 | AI feature snapshot + dataset contract |
| B8 Commit 2 | Model registry + artifact/version contract |
| B8 Commit 3 | ONNX inference → immutable `AI_DECISION_CREATED` event |
| B8 Commit 4 | AI decision projection + replay + audit/export |

## `AIDecision` — proposed fields

```text
ai_decision_id
candidate_id
candidate_hash
context_hash
detector_hash
risk_plan_id              // optional until B7 Commit 2 exists
plan_hash                 // optional until B7 Commit 2 exists
model_id
model_version
model_artifact_hash
feature_schema_version
feature_vector_hash
threshold_version
inference_runtime_version
score
probability
decision                  // ALLOW | REJECT | ABSTAIN
reason_codes[]
input_hash                 // canonicalized feature vector + lineage refs
output_hash                // model/version/threshold + inference output - NOT wall-clock/telemetry
```

Same identity-vs-content discipline B6.3/B7 already proved out:
`input_hash`/`output_hash` should exclude runtime timestamps and
telemetry that don't change the decision, matching every other hash
in this project's "don't hash something twice, don't hash metadata"
rule.

## The hard replay rule for B8

**Live:** `TradeCandidate` + feature snapshot → ONNX inference →
`AI_DECISION_CREATED` event, persisted.

**Replay:** restore the persisted `AI_DECISION_CREATED` event's
output directly — **never re-run ONNX inference during replay.**
Model artifacts, runtime, hardware behavior, and thresholds can all
change after the fact; re-inferring during replay would make replay
non-deterministic in exactly the way B3.5/B6/B7's own determinism
gates were built to prevent. This is the single most important rule
carried into B8 from everything already sealed.

## Governance rules proposed for B8/B9 (not yet enforced by any code)

- AI only ever sees closed-bar/immutable feature snapshots — never a
  live tick/spread/account read at inference time.
- Every inference is tagged with `model_artifact_hash`,
  `feature_schema_version`, and `threshold_version` — no untagged
  inference.
- A failed inference is `ABSTAIN` (or a policy-defined fail-closed
  outcome) — never a silent `ALLOW`.
- AI output never mutates `TradeCandidate` or `RiskPlan`.
- Retraining always produces a new model artifact/version — an
  existing artifact is never replaced under its old version string
  (same "never redefine a frozen `_V1` in place, bump to `_V2`"
  discipline `Core/MLQuantAI_ContractVersions.mqh` already uses
  everywhere).
- **B9 is the only place `RiskPlan` + `AIDecision` + operational
  policy combine to approve or block execution.** Neither B7 nor B8
  makes an execution decision on its own.

## Why this also serves the ML training-dataset goal

The training row this project has discussed before (candidates +
market context + feature snapshot + AI decision + risk plan +
execution result + realized outcome, joined into one row) is a
natural consequence of this architecture, not a separate effort:
B6.2's dataset export already proved stable ordering, a reproducible
`dataset_hash`, and full lineage back to `MarketContext`/the CRT
detector. A B8/B9-era training row extends the same export pattern —
join `AIDecision` and `RiskPlan` onto the same candidate rows B6.2
already produces, by `candidate_id`.

```text
Candidate + Context + FeatureSnapshot
  + AIDecision (model/version)
  + RiskPlan
  + ExecutionResult
  + RealizedOutcome
       ↓
   Training Row
```

## Phase order, as currently agreed

```text
B7 Commit 1   RiskContext + RiskPlan + deterministic sizing     PASSED (98/98)
B7 Commit 2   RISK_PLAN_CREATED + projection + replay           next
B8 Commit 1   AI feature snapshot + dataset contract             not started
B8 Commit 2   Model registry + artifact/version contract         not started
B8 Commit 3   ONNX inference -> immutable AI decision event      not started
B8 Commit 4   AI decision projection + replay + audit/export     not started
B9            Execution eligibility policy                       not started
C             Broker execution + reconciliation                  not started
```

Per the user's own stated order, **B7 Commit 2 is the next piece of
work**, not B8 — this document exists so the B8/B9 design isn't lost
between now and whenever B8 is formally opened.
