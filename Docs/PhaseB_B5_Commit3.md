# Phase B — B5 Commit 3: Pure CRT_V1 Detection Rules

**Status: implemented, awaiting a real compile/test run before PASSED.**
Implements the detection logic `Docs/PhaseB_B5_CRTContract.md` (Commit 1,
FROZEN) explicitly deferred to this commit: `CRT_IsSweepLow`/
`CRT_IsSweepHigh`, `CRT_CloseBackInside`, `CRT_ConfirmMSS`, `CRT_FindFVG`,
`CRT_FindOrderBlock`, `CRT_ResolveZone` (the frozen
`FVG_PRIORITY_THEN_OB_FALLBACK` policy), `CRT_EvaluateExpiry`, and the
`CRT_DetectV1()` orchestrator. No `TradeCandidate` construction yet —
`CRT_ToTradeCandidate(ctx, result)` is Commit 4, a pure mapping from
`CRTDetectionResult` to `TradeCandidate` (entry/sl/tp hint derivation,
`root_event_id`/`candidate_id`, `has_liquidity_sweep`/etc.).

## Why this doc exists (beyond Commit 2's precedent)

Commit 1's contract froze *what* CRT_V1 must produce (the bit layout, the
zone-resolution priority, the frozen parameters, the ID/hash payloads)
but deliberately left *how* to detect a sweep/MSS/FVG/OB to Commit 3's
implementation — those are algorithmic specifics, not architecture. This
doc records the choices made here so they're visible to review, not
buried in code comments alone. Each one is additive to what Commit 1
froze — none of it reopens Commit 1's Q&A.

## Implementation-level decisions

**1. "Swept level" = `ctx.pdh`/`ctx.pdl` (not a rolling swing-detection
algorithm).** Contract §5's payload comment says "the prior swing/PDH/PDL
price that was pierced" — both readings are explicitly allowed. `pdh`/
`pdl` are already-frozen `MarketContext` fields (B1), so using them needs
no new unfrozen primitive and stays trivially inside §10's Pure Function
Contract. A rolling-swing-point variant (detecting an arbitrary prior
local high/low, not just the daily one) would need its own frozen
lookback/fractal definition — deferred to a `CRT_V2` if ever wanted.

**2. MSS is checked against exactly one bar: the anchor bar.**
`CRT_DetectV1(ctx)` asks "did MSS confirm on THIS closed bar" — the last
element of `trigger_tf_recent[]` is always the candidate MSS
(displacement) bar. This matches how the EA's main loop actually runs:
one `FeatureEngine_BuildContext()` + one detector call per newly closed
trigger-timeframe bar, so `setup_anchor_bar_time` (== `mss_confirmation_
bar_time`, per contract §0) is naturally "now", never a bar found by
scanning backward through history.

**3. Sweep bar = the most recent bar before the anchor whose low/high
pierces `pdl`/`pdh`,** scanned backward across the whole
`trigger_tf_recent[]` window — already bounded by the frozen
`MLQUANTAI_CRT_V1_LOOKBACK_BARS` (64), so no new lookback constant was
needed for this search.

**4. Close-back-inside is a single-candle check**: the sweep bar's own
close must be back on the correct side of the pierced level. This is the
simplest reading of "closed back inside the swept range" that stays a
pure per-bar predicate (`CRT_CloseBackInside(ctx, sweepBarIndex,
bullish)`) — a multi-candle "eventually reclaims within N bars" variant
was considered and rejected as adding an unfrozen `N` for no clear
benefit at V1.

**5. Pre-sweep structure level (what MSS must break)** is the max/min
(high for bullish, low for bearish) over every bar from the sweep bar
through the bar immediately before the anchor. Naturally bounded by the
sweep-to-anchor distance — no separate frozen constant needed.

**6. `CRT_REASON_BIT_NEWS_RISK` threshold** (new, non-gating —
contract §2: bits 6–7 are informational/audit-only, B5 never gates
candidate creation on them): `MLQUANTAI_CRT_V1_NEWS_RISK_WINDOW_MINUTES =
30`, set when `ctx.max_news_impact >= 3` (HIGH) and
`|ctx.nearest_news_minutes| <= 30`. Since B5 never gates on this bit,
getting its exact threshold slightly wrong has no effect on candidate
creation — only on an audit-trail label B6/B7 may act on later.

**7. Function naming**: the zone-resolution function is named
`CRT_ResolveZone`, not `CRT_ResolveFVG_OR_OB` — matching contract §7A's
explicit correction that `FVG_OR_OB` phrasing misleadingly reads as
"either counts as evidence" when CRT_V1 always resolves to exactly one
zone kind.

## What `CRT_DetectV1()` does NOT do (still out of scope)

- Build a `TradeCandidate` (Commit 4).
- Compute `entry_hint`/`sl_hint`/`tp_hint` (contract §8's formulas are
  reused by `CRT_ToTradeCandidate`, Commit 4 — `CRTDetectionResult` only
  carries `swept_level`/`resolved_zone_high`/`resolved_zone_low`, per
  contract §12's schema).
- Emit any event (`CANDIDATE_CREATED` is Commit 4/5).
- Touch risk, execution, AI, or regime-compatibility in any way.

## Test coverage (`Tests/MLQuantAI_Test_CRT_V1_Rules.mq5`)

All hand-built `MqlRates` fixtures, no live/broker dependency. Covers
every fixture in the QA-approved Commit 3 gate list:

- Valid bullish: sweep-low + close-back-inside + MSS + FVG — plus an
  explicit proof that a qualifying Order Block ALSO exists in the same
  window (bar 59 is bearish), confirming `FVG_PRIORITY_THEN_OB_FALLBACK`
  picks the FVG over an available OB, not just when OB is absent.
- Valid bearish: sweep-high + close-back-inside + MSS + OB fallback,
  including one exact-zero-gap boundary bar (proves a touching-but-not-
  overlapping FVG candidate correctly fails to qualify).
- No sweep.
- Sweep without close-back-inside.
- Close-back-inside without MSS.
- MSS confirmed but no valid FVG/OB retest (fails closed).
- Short (<64-bar) window: `detected == false` unconditionally.
- Same fixture: byte-identical `CRTDetectionResult` across repeated
  `CRT_DetectV1()` calls (every field, not just `detected`).
- Exactly one sweep reason bit set / exactly one zone reason bit set
  (verified on both valid fixtures).
- Boundary equality: a low/high/close that exactly touches `pdl`/`pdh`
  never counts as a sweep or a reclaim (strict inequality throughout).
- `CRT_EvaluateExpiry`/`CRT_TimeframeTagToPeriod`: bar-progression expiry
  (before/at/after), tag-to-`ENUM_TIMEFRAMES` conversion for M5/M15/H1.

## Commit 3 seal criteria

- `MLQuantAI_Test_CRT_V1_Rules.mq5` = ALL PASS
- `MLQuantAI_Test_CRTContextWindow.mq5` / `Test_DataHubDeterminism.mq5` /
  `Test_NewsParity.mq5` (regression — nothing here should be affected)
  = ALL PASS
- No `TradeCandidate` construction, no event emission, no risk/execution/
  AI code anywhere in this commit

Once confirmed on a real compile/run, Commit 4 (`CRT_ToTradeCandidate` —
the pure mapping from `CRTDetectionResult` to `TradeCandidate`) opens.
