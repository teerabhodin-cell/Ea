# Phase B — B5 Commit 2: Context Window + CRT_V1 Domain Models

**Status: PASSED (2026-08-14).** Confirmed on a real compile/test run:
`MLQuantAI_Test_CRTContextWindow.mq5` 31/31, `Test_DataHubDeterminism.mq5`
(regression) 44/44, `Test_NewsParity.mq5` (regression) 46/46 — 121/121
total. Commit 3 is now open.
Implements what `Docs/PhaseB_B5_CRTContract.md` (Commit 1, FROZEN) froze.
No detection rule logic — no `CRT_IsSweepLow`, `CRT_ConfirmMSS`,
`CRT_FindFVG`, `CRT_FindOrderBlock` — that was deliberately out of scope
for this commit.

## What this commit adds

- **`Market/MLQuantAI_MarketContext.mqh`** (additive extension to a
  sealed B1–B4 file): `trigger_tf_recent[]` — a `MqlRates[]` field
  holding the last `MLQUANTAI_CRT_V1_LOOKBACK_BARS` closed bars on
  `trigger_timeframe`, oldest first, last element == `anchor_bar_time`.
  Folded into `MarketContext_HashPayload()` (so `context_hash` covers it)
  and `MarketContext_ToJsonFragment()` (so `MARKET_CONTEXT_READY` embeds
  it for replay). New `MarketContext_RatesArrayToJson`/
  `MarketContext_RatesArrayFromJson`/`MarketContext_RatesFromJson` — the
  array-of-`MqlRates` counterpart to the existing single-bar
  `MarketContext_RatesToJson`, self-contained the same way
  `NewsSnapshot.mqh` deliberately doesn't depend on
  `Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh`.
- **`Market/MLQuantAI_FeatureEngine.mqh`**: `FeatureEngine_BuildContext()`
  captures `trigger_tf_recent[]` via one `CopyRates(brokerSymbol,
  InpTriggerTimeframe, 1, MLQUANTAI_CRT_V1_LOOKBACK_BARS,
  ctx.trigger_tf_recent)` call — a plain (non-`AS_SERIES`) array, so
  `CopyRates` already fills it oldest-first with no manual reversal
  needed. A short/failed copy leaves the array short or empty; this
  function does not treat that as a build failure (the context is still
  built and logged) — `CRT_V1` (Commit 3+) is what treats a short window
  as detection-ineligible for that bar.
- **`Core/MLQuantAI_ContractVersions.mqh`**: `MLQUANTAI_CRT_V1_RULES_VERSION
  = "CRT_V1"` — feeds `candidate_id` (Commit 4), distinct from
  `MLQUANTAI_CANDIDATE_SCHEMA_V1` the same way `TradeCandidate.
  regime_rules_version` is distinct from `candidate_schema_version`.
- **`Strategies/MLQuantAI_CRT_V1_Contract.mqh`** (new file, new
  `Strategies/` directory): every frozen parameter from the contract's
  §8/§9 as `#define`s (`MLQUANTAI_CRT_V1_LOOKBACK_BARS=64`,
  `_EXPIRY_AFTER_BARS=12`, `_MIN_FVG_GAP=0.0`, `_TP_R_MULTIPLE=2.0`,
  `_ZONE_POLICY="FVG_PRIORITY_THEN_OB_FALLBACK"`); the 8
  `CRT_REASON_BIT_*` constants (§2); `CRT_ReasonBitLabel`/
  `CRT_ReasonLabelsFromMask` (§3's frozen label vocabulary, ascending bit
  order); `CRTDetectionResult` + `CRTDetectionResult_Init` (§12's output
  shape); `CRT_DetectorHash` (§7's frozen payload/field order/numeric
  formatting, as a pure function taking the detection's output values as
  arguments — no `MarketContext` dependency itself, so it's trivially
  testable without a live chart).

## Why `Market/` depends on `Strategies/`

`FeatureEngine.mqh` (generically B1–B4-owned) includes
`Strategies/MLQuantAI_CRT_V1_Contract.mqh` for exactly one constant,
`MLQUANTAI_CRT_V1_LOOKBACK_BARS` — because the window's *size* is
inherently a CRT_V1 parameter even though *capturing* it has to happen
at `MarketContext` build time for CRT_V1 to stay a pure function of
`ctx` alone (contract §10). Flagged explicitly in-file; not a pattern to
repeat casually for unrelated strategy parameters.

## Test coverage (`Tests/MLQuantAI_Test_CRTContextWindow.mq5`)

- **Real pipeline** (`FeatureEngine_BuildContext()` on the actual chart):
  window never exceeds `LOOKBACK_BARS`, strictly ascending oldest→newest,
  last element == `anchor_bar_time`, never includes the forming/shift-0
  bar, reaches the full frozen size when history is available,
  `context_hash` and the raw window content are both identical across
  repeated rebuilds of the same anchor bar.
- **Pure-function** (hand-built `MqlRates`, no live/broker dependency):
  `context_hash` changes when window content differs and stays stable
  when it's identical; `MarketContext_RatesArrayToJson`/`FromJson`
  round-trips every field exactly; a hand-built context with a 3-bar
  window persists to `MARKET_CONTEXT_READY` and replays identically from
  a fresh event-store handle (`context_hash` and the window itself both
  verified, not just key presence).
- **CRT_V1 domain models**: `CRT_ReasonLabelsFromMask` produces labels in
  ascending bit order with the frozen vocabulary (including the 0-bit and
  all-8-bits edge cases); `CRT_DetectorHash` is deterministic for
  identical inputs and changes when any single input changes (side,
  resolved zone kind); `CRTDetectionResult_Init` defaults.

`Tests/MLQuantAI_Test_DataHubDeterminism.mq5` (B3/B3.5/B4 regression)
gained two payload-completeness checks: `trigger_tf_recent[]` is
populated and its last element matches `anchor_bar_time`, and
`MARKET_CONTEXT_READY`'s JSON carries the `trigger_tf_recent` key.

## Commit 2 seal criteria — CONFIRMED PASSED

- `MLQuantAI_Test_CRTContextWindow.mq5` = 31/31 PASS
- `MLQuantAI_Test_DataHubDeterminism.mq5` (regression) = 44/44 PASS
- `MLQuantAI_Test_NewsParity.mq5` (regression) = 46/46 PASS
- No `CRT_IsSweepLow`/`CRT_ConfirmMSS`/`CRT_FindFVG`/`CRT_FindOrderBlock`
  or any other detection rule logic anywhere in this commit — confirmed

`_NewsReplayIsolation.mq5` / `_NewsSchemaEvolution.mq5` were not
re-run this round (unaffected by this commit's diff); worth reconfirming
before the full B5 seal, not a Commit 2/3 gate.

## Known backlog item (non-blocking, before full B5 seal)

`Test_DataHubDeterminism`'s cross-session determinism check
(`Seal #2`) compares a persisted fixture context against a fresh
rebuild for the *same anchor bar*. On a real run it can `SKIP` if the
M5 trigger bar has rolled over between the fixture's creation and the
test run — expected behavior, not a failure, and already covered by
the pure in-run determinism proof (1000 rebuilds, 0 mismatches) plus
this commit's own replay-from-persisted-payload test. Before B5's
final seal, consider changing that check to persist a fixed/frozen
fixture payload instead of depending on the live current bar, so it
never needs a same-bar re-run window to exercise cross-session parity.

Commit 3 (pure CRT_V1 detection rules + fixtures) is now open.
