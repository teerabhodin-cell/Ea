# Phase B — Architecture Baseline (Confirmed 2026-08-18)

**Status: SEALED as the current baseline architecture.** This doc
consolidates and locks the phase table and governing rules confirmed
by the user on 2026-08-18, replacing the informal proposals in
`Docs/PhaseB_B7_RiskPlanDraft_Notes.md` and
`Docs/PhaseB8_B9_Roadmap_Notes.md` as the single reference. Those two
docs stay in the repo as historical record of how this baseline was
arrived at; this doc is the one to read for "what's frozen right now."

Sealing this baseline does not itself mark any phase PASSED or
complete — it fixes the phase boundaries and the rules each phase must
obey. B7 Commit 2 in particular is still awaiting a confirmed re-test
result as of this doc's creation (see
`Docs/PhaseB_B7_Commit2_RiskPlanEvent.md`); this baseline governs what
comes after that confirmation, not a claim that it already happened.

## The phase table

```
B5  CRT -> TradeCandidate
B6  Candidate Projection / Hash / Lineage
B7  RiskContext -> RiskPlan -> RISK_PLAN_CREATED -> Projection / Replay
B8  AI / ML Intelligence Layer
B9  Execution Eligibility Policy
C   Broker Execution + Reconciliation
```

The candidate layer (B5/B6) already carries `candidate_hash`,
`detector_hash`, and `context_hash`, each traceable back to its
originating detector run and `MARKET_CONTEXT_READY` event. That
provenance chain is the anchor B7 and B8 both attach to — neither
phase invents a second identity/lineage mechanism.

## B7 — Deterministic risk layer (frozen)

- AI has no authority inside B7, in either direction — it neither
  gates candidate creation nor sizing, and B7 never reads an AI
  output.
- `Candidate_ToRiskPlan()` does not mutate `TradeCandidate` or
  `RiskContext` — already true of the shipped Commit 1 implementation
  (`const &` signatures), now stated as a permanent invariant rather
  than an implementation detail.
- A persisted `RiskPlan` is the source of truth. Downstream layers
  (B8/B9/C) must never re-derive or overwrite it from the
  then-current account balance or symbol spec — only a fresh
  `Candidate_ToRiskPlan()` call against a fresh `RiskContext` produces
  a new plan, which gets its own `risk_plan_id`/`plan_hash`.
- `risk_plan_id` is identity (derived from `candidate_id` +
  `sizing_rules_version` only). `plan_hash` is content integrity.
- Same identity + same hash = duplicate, no-op.
- Same identity + different hash = collision, fail-closed (rejects the
  whole replay, never partially applies).
- Only a persisted `RiskPlan` (one that produced a durable
  `RISK_PLAN_CREATED` event) is eligible for any downstream use — an
  in-memory-only plan that was never emitted has no standing.

## B8 — Intelligence layer (frozen)

- AI receives immutable, candidate-time snapshots only — never a live
  query against current market/account state.
- AI does not mutate the candidate, does not set the risk budget, and
  does not touch `lot_size` directly.
- Model artifact, feature schema, threshold, and inference contract
  are all independently versioned.
- Every AI output is persisted as an event. Replay restores the
  recorded result — it never re-runs the model.
- Every score/decision must trace back to its input lineage
  (`candidate_id`/`candidate_hash`, and whatever feature-snapshot
  identity B8.1 defines).

## B9 and C (frozen)

- B9 is the policy authority: it combines `TradeCandidate` +
  `RiskPlan` + `AIDecision` + operational constraints into
  `ELIGIBLE` or `REJECTED`.
- B9 must never rewrite B5/B7 history — it only reads persisted
  records and emits its own eligibility decision.
- C is the broker-facing layer: submit, response, fill/reject, and
  reconciliation. Nothing upstream of C ever talks to a broker
  directly.

## B7 Commit 3 (next, once B7 Commit 2 lands)

Integration/regression proof of the full B5-through-B7 chain — no new
sizing rule, lifecycle, re-plan capability, AI dependency, or
execution behavior:

```
MARKET_CONTEXT_READY
    -> CANDIDATE_CREATED
    -> CandidateProjection
    -> Candidate_ToRiskPlan
    -> RISK_PLAN_CREATED
    -> RiskPlanProjection
    -> Restart / Replay
    -> identical lineage + state
```

Definition of Done:
- The full chain rebuilds state from the store alone.
- Candidate/projection/plan linkage matches on every hash and ID
  across the chain.
- A restart followed by replay reproduces byte-identical state.
- Duplicate and collision policy still hold correctly across the
  candidate/plan layer boundary, not just within each layer alone.
- A corrupted/truncated line anywhere fails the rebuild closed, with
  no partial commit.
- The full B5/B6/B7 regression suite passes.

This addendum will be written into
`Docs/PhaseB_B7_RiskPlanContract.md` itself (matching how the Commit 2
addendum was appended there) once `feat/phase-b7-commit2-risk-plan-event`
is merged to `mlquantai` — writing it on a branch cut before that merge
would only create a document conflict at merge time, since Commit 2's
own addendum to that same file doesn't exist on `mlquantai` yet.

## B8.1 (after B7 is sealed)

`FeatureSnapshot` — the immutable, candidate-time input contract for
B8, first deliverable of the intelligence layer once B7 Commit 3's
regression proof and B7 SEALED are both real. Full field-level
contract to be frozen in its own doc before any B8 code, per this
project's standing "freeze before code" discipline — not written yet.
One open question flagged for that freezing pass: `feature_vector_hash`
should very likely exclude `snapshot_time` from its payload, mirroring
the precedent `risk_context_hash` already set by excluding
`account.balance`/`equity` — a wall-clock/bar-time field moving
shouldn't move a content-integrity hash. To be settled when B8.1 is
actually frozen, not before.
