# Phase B7 — Commit 3: Full-Chain Integration + Regression Proof

**Status: PASSED (2026-08-18). B7 SEALED.** Confirmed on a real
compile/test run: `MLQuantAI_Test_B7_Commit3_IntegrationRegression.mq5`
40/40 ALL PASS, plus the full manual regression checklist re-run clean
in the same MetaEditor session: `Test_CandidateProjection.mq5` 146/146,
`Test_CandidateDatasetExport.mq5` 76/76, `Test_B6_3_HashContract.mq5`
89/89, `Test_B7_Commit1_RiskPlan.mq5` 98/98,
`Test_B7_Commit2_RiskPlanEvent.mq5` 65/65 — all ALL PASS, zero
regressions. B7 (B7.1 through B7.5) is now sealed in full. B8.1
(`FeatureSnapshot`) is open next, per
`Docs/PhaseB_Architecture_Baseline.md`.

Implements the B7 Commit 3 addendum in
`Docs/PhaseB_B7_RiskPlanContract.md`, per
`Docs/PhaseB_Architecture_Baseline.md`'s confirmed scoping. Adds
**zero new production behavior** — no B5/B6/B7 sealed file touched, no
new sizing rule, lifecycle, re-plan capability, AI dependency, or
execution path. Purely a test-suite commit proving the already-shipped
pieces compose correctly end to end.

## The chain being proven

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

## What's genuinely new here (not re-proven from Commit 2's suite)

`Test_B7_Commit2_RiskPlanEvent.mq5` already builds every fixture
through the real B5 pipeline and already proves `RiskPlanProjection`'s
own restart/multi-session/duplicate/collision/orphan/hash-mismatch
behavior and field-by-field replay fidelity in isolation. This commit
does not repeat any of that. What it adds:

1. **`Test_EndToEndLinkage_SingleCandidate`** — one test that walks
   the whole chain forward from a real `MARKET_CONTEXT_READY` event
   and asserts every hash/ID matches its neighbor in a single
   sequence: the candidate's `context_hash`/`context_event_id` against
   the real `MarketContext`'s own values; the plan's `candidate_id`/
   `candidate_hash` against the real `CandidateProjection` record
   (not just the in-memory `TradeCandidate`); and `risk_plan_id`
   independently re-derived via `Ids_RiskPlanId()` and compared
   against the real emitted plan's own id.
2. **`Test_CrossLayerFailure_BlocksRiskPlanRebuild`** — a corrupted
   `CANDIDATE_CREATED` line (empties `candidate_id`, staying
   syntactically valid JSON so it passes `EventStoreValidator`'s
   generic gate and specifically exercises
   `RiskPlanProjection_RebuildFromFile`'s SECOND gate — its
   `CandidateProjection_RebuildFromFile` prerequisite) must fail the
   `RiskPlanProjection` rebuild too, with `first_error` attributing the
   failure to the candidate registry, and the plan registry left
   untouched. Neither Commit 2 nor B6.1/B6.2/B6.3 tested this
   candidate-layer-failure-propagates-to-plan-layer seam.
3. **`Test_FullChainRestartSimulation_MultiCandidate`** — three full
   chains (context through plan) in one store, rebuilt twice
   (simulating an EA restart), asserting byte-identical state in BOTH
   `CandidateProjection` and `RiskPlanProjection` together. Commit 2's
   own restart test only checked `RiskPlanProjection`, one plan at a
   time.
4. **`Test_MultiCandidateCrossLinking`** — three candidates each with
   their own plan in one store; after rebuild, every plan is checked
   against ALL three candidates (not just its own), explicitly
   asserting it does NOT link to either neighbor. Guards against an
   index/ordering bug a single-candidate test structurally cannot
   catch.

## Definition of Done

- The full chain rebuilds state from the store alone.
- Candidate/projection/plan linkage matches on every hash and ID
  across the chain, for every candidate in a multi-candidate store.
- A restart followed by replay reproduces byte-identical state in
  BOTH `CandidateProjection` and `RiskPlanProjection`.
- Duplicate and collision policy still hold correctly across the
  candidate/plan layer boundary — a candidate-layer failure closes the
  plan-layer rebuild too.
- A corrupted/truncated line anywhere fails the rebuild closed, with
  no partial commit, regardless of which layer's line it corrupts.
- The full B5/B6/B7 regression suite passes — see the manual re-run
  checklist below.

## Manual regression checklist

MQL5 has no cross-script test runner, so "the full B5/B6/B7 regression
suite passes" is confirmed by re-running each of these in the same
MetaEditor session and getting ALL PASS on every one, not by this new
script alone:

- `Test_CandidateProjection.mq5`
- `Test_CandidateDatasetExport.mq5`
- `Test_B6_3_HashContract.mq5`
- `Test_B7_Commit1_RiskPlan.mq5`
- `Test_B7_Commit2_RiskPlanEvent.mq5`
- `Test_B7_Commit3_IntegrationRegression.mq5` (new, this commit)

## What this commit adds

- **`Tests/MLQuantAI_Test_B7_Commit3_IntegrationRegression.mq5`**
  (new): the four tests above, built on the real B5/B7 pipeline
  end to end (`CRT_DetectV1` -> `CRT_ToTradeCandidate` ->
  `CRT_EmitCandidateCreated` -> `Candidate_ToRiskPlan` ->
  `RiskPlan_EmitRiskPlanCreated`), plus real `MARKET_CONTEXT_READY`
  events, mirroring Commit 2's own fixture style (each `.mq5` test
  file in this project is standalone — no shared fixture include).

## Explicitly out of scope for this commit

Any new sizing rule, lifecycle change, re-plan/overwrite capability,
AI dependency, broker/order/execution call, or change to an
already-sealed B5/B6/B7 production file. B8.1 (`FeatureSnapshot`)
opens only after this commit is confirmed PASSED and `B7 SEALED` is
declared, per `Docs/PhaseB_Architecture_Baseline.md`.
