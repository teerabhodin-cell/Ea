# Phase B — B3: Data Hub / Feature Engine Migration + Determinism

Status: Data Hub and Feature Engine migrated to the B1-frozen
`Market/MLQuantAI_MarketContext.mqh` contract. Still no CRT/strategy code,
no AI, no `OrderSend`/`CTrade` - that's B5+.

## What changed

- `Market/MLQuantAI_FeatureEngine.mqh` was rewritten: `FeatureEngine_Build()`
  (built the old, deleted `Core/MLQuantAI_MarketContext.mqh` struct off bar
  0 and a live tick) is replaced by `FeatureEngine_BuildContext()`, which
  builds the new `MarketContext` contract, resolves the symbol via B2's
  `SymbolSpec_BuildResolved()`, and reads everything from the closed
  trigger bar (`InpTriggerTimeframe`, default `M5`) backward.
- `Core/MLQuantAI_MarketContext.mqh` (Step 9's struct) was **deleted** -
  nothing referenced it once the migration was done.
- `Market/MLQuantAI_DataHub.mqh`: added an `M15` ADX handle
  (`g_hADX_M15` - the frozen contract wants `adx_m15`, not `adx_h1`);
  `DataHub_AsianRange()` (read `TimeCurrent()` internally) was replaced
  by `DataHub_AsianRangeAt(symbol, asiaEndHour, asOf, ...)`, which takes
  the anchor time as a parameter instead.
- `Market/MLQuantAI_SessionEngine.mqh`: added `Session_Id(t)` - one
  string label (`ASIA` / `LONDON_KZ` / `NEWYORK_KZ` /
  `LONDON_NEWYORK_OVERLAP` / `OFF_SESSION`) for `MarketContext.session_id`.
  `Session_IsLondonKZ`/`Session_IsNewYorkKZ` already took an explicit
  `datetime t` parameter - Step 9's bug was FeatureEngine passing
  `TimeCurrent()` into them, not the functions themselves.
- `Market/MLQuantAI_NewsEngine.mqh`: added `News_BuildSnapshots()` /
  `_Live` / `_Csv`, which return a full `NewsSnapshot[]` anchored at an
  explicit `asOf` instead of a bool checked against `TimeCurrent()`.
  `News_HighImpactNear()` is kept as a separate, still-live "gate check
  right now" utility - explicitly NOT what builds `MarketContext.news[]`.
- `Market/MLQuantAI_MarketContext.mqh`: added `MarketContext_ComputeHash()`
  (SHA-256 over `MarketContext_HashPayload()`) and
  `MarketContext_ToJsonFragment()` (the full serialized payload logged
  into `MARKET_CONTEXT_READY`). The frozen struct's fields are unchanged.
- `MLQuantAI.mq5`: `OnTick()` now detects a new bar via
  `FeatureEngine_CurrentAnchorBarTime()` (`iTime(broker_symbol,
  InpTriggerTimeframe, 1)`) instead of `iTime(_Symbol, PERIOD_M15, 0)`.
- `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`: rebuilds the same
  anchor bar 1,000 times and asserts `context_hash` never changes, plus
  payload-completeness and closed-bar-semantics checks.

## Why bid/ask/spread "at anchor" don't use a live tick

`MarketContext.bid_at_anchor`/`ask_at_anchor`/`spread_points_at_anchor`
come from the trigger bar's own `MqlRates.close` and `MqlRates.spread` -
MT5 records a historical spread per bar, so this is fully deterministic
and available for any closed bar, live or in the Tester. A live
`SymbolInfoTick()`/`SymbolInfoDouble(..., SYMBOL_BID)` read would change
every time this function is called, which is exactly the bug B1's rules
forbid.

## Why the H1/H4 indicator handles are still in `DataHub_Init`

The frozen `MarketContext` contract only carries `atr_m15`/`adx_m15`/
`ema_slope_m15` plus raw `h1_bar`/`h4_bar` OHLC (no H1/H4 indicator
values). `g_hATR_H1`/`g_hADX_H1`/`g_hEMA50_H1`/`g_hEMA200_H4` are no
longer read by `FeatureEngine_BuildContext()`, but were left in place as
ready-to-use indicator plumbing for B5's strategy detectors (CRT/SMC/
Trend), which will likely want H1/H4 trend context beyond the raw bars.

## Known limitation carried into B4

`News_BuildSnapshots_Csv()` synthesizes `calendar_event_id`/`title` for
CSV rows (the CSV format has no event id or title column) - deterministic
(same row always produces the same synthesized id), but less descriptive
than the live path. "News Engine parity" between live and CSV sources is
explicitly **B4**'s job, not B3's.

## What is explicitly out of scope for B3

No CRT/SMC/Trend detector code, no AI, no `RiskDecision`/`RiskPlan`
wiring, no `OrderSend`/`CTrade`/execution logic.
