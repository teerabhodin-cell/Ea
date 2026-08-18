# Phase B7 — Commit 1: RiskContext / RiskPlan / Candidate_ToRiskPlan

**Status: PASSED (2026-08-18).** Confirmed on a real compile/test run:
`MLQuantAI_Test_B7_Commit1_RiskPlan.mq5` 98/98 ALL PASS. One real test
bug was found and fixed on the first run (see "Bugs found and fixed"
below) — no production code needed any change.

Two clarifications added to the contract doc and to the code's own
header comments per QA review of the 98/98 result, both already true
of the shipped design and now stated explicitly rather than left
implicit:
- `risk_context_hash` is a rules/spec snapshot hash, not a full
  sizing-input hash — it deliberately excludes `account.balance`/
  `equity` (same precedent `MarketContext_HashPayload` already set),
  so two `RiskContext` values with the identical `risk_context_hash`
  can legitimately produce different `RiskPlan` outputs. It answers
  "same sizing rule set," never "same plan" — only `plan_hash` answers
  that.
- `lot`/`risk_money` (the Phase A fields) are compatibility shadow
  fields, not the canonical source of truth — `risk_amount`/`lot_size`
  are what `Candidate_ToRiskPlan` actually computes and `plan_hash`
  actually hashes.

Implements B7.1 (RiskContext), B7.2 (RiskPlan schema + identity), and
B7.3 (`Candidate_ToRiskPlan`, the pure sizing function) as one
commit, per `Docs/PhaseB_B7_RiskPlanContract.md` (FROZEN before this
code was written). B7.4 (`RISK_PLAN_CREATED` event emission) and B7.5
(replay/recovery) are explicitly out of scope for this commit.

## The `RiskPlan` collision, and how it was resolved

`Core/MLQuantAI_RiskPlan.mqh` already existed from Phase A (`decision`/
`allowed`/`lot`/`risk_money`/`risk_percent`/`reject_reason`/
`risk_schema_version`), unused by any current code but real and
sealed. `Core/MLQuantAI_RiskDecision.mqh` (Phase B1, contract-only)
had already named this exact moment: *"RiskDecision is the AUDIT
record; RiskPlan is the SIZING output for one that passed. B7
reconciles how the two relate when the Risk Manager is built."*

Resolved by extending the existing struct **additively** — every
Phase A field kept exactly as it was; new B7 fields added alongside.
`Candidate_ToRiskPlan` fills both field groups from the same
computation (`lot == lot_size`, `risk_money == risk_amount`,
`decision = RISK_DECISION_ALLOW`/`allowed = true` on success). See
`Docs/PhaseB_B7_RiskPlanContract.md` section 3 for the full reasoning.

## What this commit adds

- **`Core/MLQuantAI_CanonicalFormat.mqh`** (new): `CanonicalPrice`/
  `CanonicalDouble`/`CanonicalPercent` — fixed-literal-precision
  formatting for every double in a B7 hash payload, never
  `Digits()`/`_Digits`/a caller-supplied digit count.
- **`Core/MLQuantAI_ContractVersions.mqh`** (additive):
  `MLQUANTAI_RISK_CONTEXT_SCHEMA_V1`, `MLQUANTAI_RISK_PLAN_SCHEMA_V1`,
  `MLQUANTAI_RISK_SIZING_RULES_V1`.
- **`Core/MLQuantAI_Ids.mqh`** (additive): `Ids_RiskPlanId(candidateId,
  sizingRulesVersion)` — same `Ids_Deterministic("RPLAN", ...)` pattern
  `Ids_CandidateId` already uses.
- **`Core/MLQuantAI_RiskContext.mqh`** (new): `RiskContext` (embeds
  `AccountSnapshot`/`SymbolSpec` verbatim — snapshot-only, built once
  by a caller outside `Candidate_ToRiskPlan`), `RiskContext_Init`,
  `RiskContext_HashPayload`/`_ComputeHash`.
- **`Core/MLQuantAI_RiskPlan.mqh`** (additive, per the collision
  resolution above): 12 new fields, `RiskPlan_HashPayload`/
  `_ComputeHash`. `RiskPlan_Init` extended to initialize both field
  groups.
- **`Core/MLQuantAI_RiskSizing.mqh`** (new): `RiskSizing_ValidateInput`,
  `Candidate_ToRiskPlan` — the frozen fixed-fractional-risk sizing
  formula (contract section 4): stop distance in points via
  `tick_size`, risk amount from `balance * target_risk_percent`, raw
  lot from `risk_amount / (stop_distance_points * tick_value)`, floor
  to `volume_step`, reject below `volume_min`, clamp above
  `volume_max`.
- **`Tests/MLQuantAI_Test_B7_Commit1_RiskPlan.mq5`** (new).

## Test coverage

- **Sizing formula correctness** — a hand-verified fixture
  (`stop_distance_points=100`, `rr_ratio=3.0`, `risk_amount=100.0`,
  `lot_size=1.0`) confirmed against real floating-point arithmetic
  before being committed to the test (not assumed).
- **`risk_plan_id` vs `plan_hash` independence** — same candidate +
  same `sizing_rules_version` → identical `risk_plan_id` even across
  different `account.balance`; different `sizing_rules_version` →
  different `risk_plan_id` AND `risk_context_hash` AND `plan_hash`.
- **`risk_context_hash` inclusion/exclusion mutation sweep** — 12
  included fields (symbol sizing constraints, `target_risk_percent`,
  `sizing_method`/`sizing_rules_version`), 11 excluded fields
  (`account.*` entirely, non-sizing `symbol_spec` fields, schema
  version).
- **`plan_hash` inclusion/exclusion mutation sweep** — 13 included
  fields, 8 excluded fields (identity fields, and the Phase A
  `decision`/`allowed`/`reject_reason`/`risk_schema_version`/`lot`/
  `risk_money` — the last two deliberately diverged from their B7
  counterparts in the test to prove they're independently excluded,
  not just coincidentally equal).
- **Fail-closed validation** — empty `candidate_id`, wrong `state`,
  a non-finite price (via `+Inf` from a real multiplication overflow -
  `0.0/0.0` was tried first and rejected: MQL5 traps it as a hard
  "zero divide" runtime error and halts the script, unlike Python/C's
  silent NaN, caught on the first real compile/test run), not a fake
  cast), zero price, wrong-side SL/TP ordering (both BUY and SELL),
  non-positive `tick_size`/`tick_value`/`volume_step`/
  `target_risk_percent`/`balance`.
- **Volume normalization edge cases** — a stepped lot below
  `volume_min` is rejected outright (not bumped up); a computed lot
  above `volume_max` is clamped down and still succeeds.
- **Determinism** — 10,000 repeated calls with the same candidate and
  `RiskContext`, zero `risk_plan_id`/`plan_hash` mismatches (honored
  as literally requested — a pure in-memory function with no file I/O
  per call, unlike B6's event-store-backed tests).
- **Input immutability** — `candidate`/`ctx` fields spot-checked
  unchanged before/after the call (on top of the `const &` signature's
  own compile-time guarantee).

## Bugs found and fixed during the first real test run

**The fail-closed "invalid number" test halted the whole script**
on the first real run. It tried to construct a NaN `entry_hint` via
`0.0/0.0`, assuming MQL5 follows IEEE754 silently the way Python/C
do. It doesn't: MQL5 traps `0.0/0.0` as a hard "zero divide" runtime
error and halts the script outright — the log stopped mid-suite at
that exact line. Fixed by constructing `+Inf` via a real
multiplication overflow (`1.0e307 * 1.0e307`) instead, which does not
trap; both NaN and Inf are "not a valid number" as far as
`RiskSizing_ValidateInput`'s `MathIsValidNumber` check is concerned,
so the fix still exercises the same code path. No production code
(`RiskContext.mqh`, `RiskPlan.mqh`, `RiskSizing.mqh`) needed any
change — this was purely a test-fixture bug, the same class of
mistake (assuming a language/platform behavior instead of checking
it) already seen once before in this project (B6.2's `dayOffset`
collision), just a different flavor of it.

## Explicitly out of scope for this commit

`RISK_PLAN_CREATED` event emission (B7.4), `RiskPlanProjection`/
replay/recovery (B7.5), any broker/order/execution call, any AI
scoring, any change to CRT_V1's own entry/exit decision. A detailed
test-first checklist for B7 Commit 2 (event emission + replayable
projection, mirroring the `CANDIDATE_CREATED`/`CandidateProjection`
pattern B5/B6.1 already proved out — exactly-once emission,
duplicate/no-op, collision rejection on same-`risk_plan_id`-different-
`plan_hash`, orphan-candidate-reference rejection, atomic replay) is
the natural next step once this commit is confirmed and merged.
