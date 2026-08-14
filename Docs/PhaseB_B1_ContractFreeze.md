# Phase B — B1: Contract Freeze

Status: frozen (`phase-b-b1-contracts-v1`). Contracts only — no DataHub,
FeatureEngine, CRT detector, or execution code was written or changed in
this pass.

## What this pass froze

- `Include/MLQuantAI/Core/MLQuantAI_ContractVersions.mqh` — new Phase B
  schema version constants (`MLQUANTAI_MARKET_CONTEXT_SCHEMA_V1`,
  `MLQUANTAI_FEATURE_SCHEMA_V1`, `MLQUANTAI_CANDIDATE_SCHEMA_V1`,
  `MLQUANTAI_NEWS_SCHEMA_V1`, `MLQUANTAI_RISK_SCHEMA_V1`).
- `Include/MLQuantAI/Market/MLQuantAI_MarketContext.mqh` — the new,
  expanded `MarketContext` contract (context lineage, canonical
  `instrument_id` vs. `broker_symbol`, per-timeframe `MqlRates` bars, an
  embedded `NewsSnapshot[]`, and a `context_hash`).
- `Include/MLQuantAI/Market/MLQuantAI_NewsSnapshot.mqh` — one calendar
  event captured at context-build time, replayable without re-querying
  the calendar.
- `Include/MLQuantAI/Market/MLQuantAI_FeatureSnapshot.mqh` — a forward
  contract stub for the eventual feature-store row (not wired to
  anything yet; for B3+).
- `Include/MLQuantAI/Core/MLQuantAI_TradeCandidate.mqh` — extended
  **additively**: every Phase A field (`candidate_id` .. `last_reason`)
  is unchanged, because Phase A's sealed tests and `MLQuantAI.mq5`'s Step
  8.5 smoke test already depend on them. New B1 fields (context lineage,
  `side`, closed-bar `setup_anchor_bar_time` + `expiry_after_bars`,
  `entry_hint`/`sl_hint`/`tp_hint`, `trigger_reason_mask` +
  `trigger_reasons[]`) sit alongside the old ones.
- `Include/MLQuantAI/Core/MLQuantAI_RiskDecision.mqh` — the audit record
  a future Risk Manager (B7) will log for every candidate it evaluates,
  approved or rejected — distinct from the existing `MLQuantAI_RiskPlan.mqh`
  (Phase A's sizing-output struct for a candidate that already passed).
- `Tests/MLQuantAI_Test_PhaseBContracts.mq5` — struct-shape and
  determinism checks for all of the above.

## Hard rules this contract encodes

- **`anchor_bar_time` (and `setup_anchor_bar_time`) must come from
  `iTime(broker_symbol, trigger_timeframe, 1)`** — the last CLOSED bar.
  Never bar 0. Never `TimeCurrent()`.
- **No feature, price, or news field may be computed from a still-forming
  bar or a live tick.** Everything in `MarketContext` must be resolvable
  purely from data closed at or before `anchor_bar_time`, so the same bar
  produces the same context on live, on tester, and on replay.
- **News must be embedded as data, not re-queried on replay.**
  `MarketContext.news[]` (a `NewsSnapshot[]`) is what gets logged to
  `MARKET_CONTEXT_READY`; replay reads that array back, it does not call
  the live Economic Calendar or re-read the Tester CSV again. Live-news-
  on-replay is forbidden for the same reason bar 0 is forbidden — it
  makes replay non-deterministic.
- **`TradeCandidate.expiry_time` is derived, not assigned.** It is
  computed from `setup_anchor_bar_time + expiry_after_bars` bars on the
  candidate's trigger timeframe — never `TimeCurrent() + N minutes`.
- **Schema versions are frozen labels.** Changing what a `_V1` constant
  means requires a new `_V2` constant in
  `MLQuantAI_ContractVersions.mqh`, plus a migration/replay-compatibility
  note — never silently redefining a version already in use, the same
  rule `MLQuantAI_VersionRegistry.mqh` already runs on for Phase A.

## What is explicitly out of scope for B1

- The Data Hub / Feature Engine / `MLQuantAI.mq5` still build and log the
  Phase A/Step 9 `MarketContext` (`Core/MLQuantAI_MarketContext.mqh`).
  Migrating them to build the new `Market/MLQuantAI_MarketContext.mqh`
  contract is **B2/B3**, not B1.
- No `LIFECYCLE_V2` state machine (`APPROVED_BY_RISK`, `PENDING_BROKER`)
  was added in this pass — B1's concrete deliverable list (contract
  structs + `MLQuantAI_Test_PhaseBContracts.mq5`) does not include it.
  It remains a known, explicitly deferred item for whichever step wires
  the Risk Manager / Execution Engine (B7/B8), not silently dropped.
- No CRT/detector code, no `ExecutionRequest` struct, no risk/execution
  wiring.
