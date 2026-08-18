# Phase B7 — Commit 1: RiskContext / RiskPlan / Candidate_ToRiskPlan

**Status: Implemented, awaiting real compile/test confirmation.**
Statically checked (brace/paren balance, 63-char identifier limit). No
real MetaEditor compile/test run exists yet — do not treat as PASSED
until real evidence is provided.

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

## Explicitly out of scope for this commit

`RISK_PLAN_CREATED` event emission (B7.4), `RiskPlanProjection`/
replay/recovery (B7.5), any broker/order/execution call, any AI
scoring, any change to CRT_V1's own entry/exit decision.
