# Phase B — B5: CRT_V1 Detector Contract Freeze (Commit 1)

**Status: FROZEN.** This is a documentation-only commit. No
`CRT_IsSweepLow`, `CRT_ConfirmMSS`, `CRT_FindFVG`, `CRT_FindOrderBlock`,
or any other detection logic exists yet — that's Commit 3+. Every
decision below (including the `MarketContext` window extension and the
four previously-open parameters) is locked; changing any of them later
means a new `CRT_V2`, never redefining `CRT_V1` in place — same
discipline every other frozen contract in this project runs on.

CRT_V1 ("Candle Range Theory") is the first live strategy module: sweep a
prior liquidity level, confirm a market structure shift (MSS), retest a
Fair Value Gap or Order Block from the impulse leg, produce a
`TradeCandidate`. B5's whole job is turning a single `MarketContext`
snapshot into zero or one `TradeCandidate`, deterministically, with a
fully auditable reason tree — nothing about risk, sizing, execution, AI,
or regime compatibility. Those stay at their `TradeCandidate_Init()`
defaults; B6/B7's job, not B5's.

## `MarketContext` trigger-bar window (frozen extension)

B1–B4 froze `MarketContext` (`Market/MLQuantAI_MarketContext.mqh`) as a
**single closed bar's snapshot** — `m5_bar`/`m15_bar`/`h1_bar`/`h4_bar`
are each exactly one `MqlRates`, not a series. A real CRT detector needs
to see a **short window of recent trigger-timeframe bars** to find the
sweep bar, the reaction bar(s), and the MSS confirmation bar — that's
inherently a multi-bar pattern, not a single-bar one.

Letting `CRT_*` functions call `CopyRates`/`iTime` themselves at
detection time was rejected: it reintroduces a live-data dependency
exactly like the news-source problem B4 exists to solve (a replayed
candidate could disagree with the original if history depth/availability
differs between runs), and violates this same contract's own §10 Pure
Function Contract and the "no direct runtime/broker-state access" test
gate. **Frozen instead:** `MarketContext` gets one additive field,
populated exactly like `m5_bar` etc. already are:

```cpp
MqlRates trigger_tf_recent[];   // additive field on MarketContext
```

Rules (all frozen, all part of Commit 2's implementation, not
CRT-detection-rule logic):

- Captured exactly once, by `FeatureEngine_BuildContext()` — the same
  place `m5_bar`/`m15_bar`/`h1_bar`/`h4_bar` are already captured.
- Contains exactly `MLQUANTAI_CRT_V1_LOOKBACK_BARS` closed bars on
  `trigger_timeframe` (see the frozen parameter table below).
- Ordered oldest → newest. The last element's `.time` equals
  `ctx.anchor_bar_time` — i.e. `trigger_tf_recent[N-1]` is the same bar
  as `ctx.m5_bar` whenever `trigger_timeframe == M5`.
- Never includes the forming/current bar (shift 0) — same closed-bar-only
  rule every other `MarketContext` field already follows.
- Included in `MarketContext_ToJsonFragment()`'s `MARKET_CONTEXT_READY`
  serialization and in `MarketContext_HashPayload()`'s `context_hash`
  payload (same "safe to extend before B5 relies on it" justification B4
  already used twice for `news_decision_hash`/`news_snapshot_identity`).
- If fewer than `MLQUANTAI_CRT_V1_LOOKBACK_BARS` closed bars exist
  (not enough history yet — e.g. right after EA start, or early in a
  Tester run), `FeatureEngine_BuildContext()` still builds the context
  (nothing else about `MarketContext` requires CRT-readiness), but
  `trigger_tf_recent[]` is short. `CRT_*` treats a short window as
  CRT-ineligible for that bar — `CRTDetectionResult.detected = false`,
  never a partial/best-effort detection over incomplete history.
- **`CRT_*` code must never call `CopyRates`/`iTime`/any price-history
  API directly** — every bar it ever looks at comes from
  `trigger_tf_recent[]` (or `m5_bar`/`m15_bar`/`h1_bar`/`h4_bar`/`pdh`/
  `pdl`/`asian_range_high`/`asian_range_low`, all already frozen).

## 1. Direction — canonical field and semantics

`TradeCandidate.side` (`ENUM_ORDER_TYPE`: `ORDER_TYPE_BUY` |
`ORDER_TYPE_SELL`) is canonical for B5+, per B1's own comment on that
field. `TradeCandidate.direction` (`ENUM_SIGNAL_DIRECTION`) stays filled
in parallel for Phase A backward compatibility — CRT_V1 always sets both
consistently:

```
side == ORDER_TYPE_BUY  <=>  direction == SIGNAL_BUY   <=> bullish CRT setup (swept a low, bullish MSS)
side == ORDER_TYPE_SELL <=>  direction == SIGNAL_SELL  <=> bearish CRT setup (swept a high, bearish MSS)
```

No candidate is ever created with `direction == SIGNAL_NONE` — a
non-detection produces no `TradeCandidate` at all (see §12), it never
produces a "candidate" with a null direction.

## 2. `trigger_reason_mask` bit mapping (`ulong`, frozen bit indices)

```
bit 0 (0x01)  CRT_REASON_BIT_SWEEP_LOW        swept a prior low (bullish precondition)
bit 1 (0x02)  CRT_REASON_BIT_SWEEP_HIGH       swept a prior high (bearish precondition)
bit 2 (0x04)  CRT_REASON_BIT_CLOSE_BACK_INSIDE  closed back inside the swept range
bit 3 (0x08)  CRT_REASON_BIT_MSS_CONFIRMED    market structure shift confirmed
bit 4 (0x10)  CRT_REASON_BIT_FVG_FOUND        a qualifying Fair Value Gap resolved the setup
bit 5 (0x20)  CRT_REASON_BIT_OB_FOUND         a qualifying Order Block resolved the setup
bit 6 (0x40)  CRT_REASON_BIT_KILLZONE         anchor bar fell inside a kill zone session window
bit 7 (0x80)  CRT_REASON_BIT_NEWS_RISK        high-impact news was near the anchor bar
```

Bits 0–5 (exactly one of {0,1}, bit 2, bit 3, exactly one of {4,5}) are
**always all set together** on any `TradeCandidate` this module produces
— they're the definition of "a CRT setup exists", not independent
signals. Bits 6–7 are informational/audit-only: **B5 never gates on
them** (no kill-zone-only or news-free requirement to create a
candidate) — that's what makes them safe to compute from `ctx.is_kill_zone`
/`ctx.news_count`/`ctx.max_news_impact` (already frozen B3/B4 fields) and
attach to the reason tree for B6/B7 to actually act on later.

## 3. `trigger_reasons[]` — ascending bit-order, frozen label vocabulary

Populated in ascending bit-index order (bit 0 first), one label per set
bit only (never a label for an unset bit):

```
0 -> "liquidity_sweep_low"
1 -> "liquidity_sweep_high"
2 -> "close_back_inside"
3 -> "mss_confirmed"
4 -> "fvg_found"
5 -> "order_block_found"
6 -> "in_killzone"
7 -> "news_risk_near"
```

## 4. Canonical `MarketContext` timestamp provenance (not a UTC contract)

**Corrected from an earlier draft that called this "UTC normalization" —
the mechanism was never true UTC, and that heading overclaimed
cross-broker guarantees the mechanism can't actually deliver.**

`iTime()` returns broker SERVER time, not UTC. MQL5 has no reliable way
to convert an arbitrary historical `datetime` to true UTC (no API exposes
a broker's historical GMT offset, and that offset moves with DST) — this
is the exact same limitation B4's `News_NormalizeTimeUtc` already
documents. Building a real UTC-conversion layer now would mean inventing
an unreliable historical-offset mechanism this project has already
concluded doesn't exist in MQL5 — rejected for the same reason B4
rejected it.

**What's actually frozen:** every CRT_V1 lineage timestamp used in an ID
or hash payload must be one already inside `MarketContext`
(`anchor_bar_time`, an `.time` field off `m5_bar`/`m15_bar`/`h1_bar`/
`h4_bar`/`trigger_tf_recent[]`) — never `TimeCurrent()`, never a
hand-built `MqlDateTime`, never a value computed outside the `ctx` that
was passed in. This guarantees **deterministic replay identity**: the
same `MarketContext` always derives the same `root_event_id`/
`candidate_id`/`detector_hash`, on any run, forever.

**What this does NOT guarantee, and no longer claims to:** identical IDs
across two different broker connections whose servers run different UTC
offsets for the same real-world moment. A broker on GMT+2 and a broker on
GMT+3 will report different `iTime()` values for "the same" real-world
bar close, so their `root_event_id`s for what a human would call the same
event will differ. This is an inherited characteristic of
`Ids_RootEventId`/`Ids_ContextEventId` since Phase A (both already hash a
raw broker-server `datetime`) — not new to B5, and not something this
contract can fix without reopening Phase A's sealed ID generation
semantics, which is out of scope here.

## 5. `root_event_id` canonical payload

Reuses the existing, Phase-A-sealed `Ids_RootEventId(symbol,
timeframeTag, eventType, price, barTime, digits)`
(`Core/MLQuantAI_Ids.mqh`, unchanged) — no new ID primitive. CRT_V1's
frozen arguments:

```
symbol       = ctx.instrument_id          (canonical id, NOT broker_symbol -
                                             same underlying event roots the
                                             same regardless of which broker's
                                             alias built the context)
timeframeTag = ctx.trigger_timeframe
eventType    = "CRT_SWEEP_LOW"  if side == ORDER_TYPE_BUY
               "CRT_SWEEP_HIGH" if side == ORDER_TYPE_SELL
price        = the swept level (the prior swing/PDH/PDL price that was pierced)
barTime      = setup_anchor_bar_time (the bar MSS was confirmed on)
digits       = ctx.symbol_spec.digits
```

## 6. `candidate_id` canonical derivation payload

Reuses the existing, sealed `Ids_CandidateId(rootEventId, strategyTag,
strategyVersion)`. Frozen arguments:

```
strategyTag     = StrategyIdToString(STRAT_CRT) = "CRT"   (Core/MLQuantAI_Enums.mqh, unchanged)
strategyVersion = MLQUANTAI_CRT_V1_RULES_VERSION = "CRT_V1"  (new constant, Commit 2,
                                                                Core/MLQuantAI_ContractVersions.mqh -
                                                                bump to a new _V2 string, never
                                                                redefine _V1 in place, if the frozen
                                                                parameters below ever change)
```

`candidate.strategy_id = STRAT_CRT`, `.strategy_name = "CRT"`,
`.strategy_version = MLQUANTAI_CRT_V1_RULES_VERSION`.

## 7. `detector_hash` — payload, field order, numeric formatting

New hash, not yet in `Ids.mqh` — same style as B4's `News_DecisionHash`
(`Ids_Sha256Hex` over a frozen, `|`-joined field order). Distinct from
`candidate_id` (namespaced by `root_event_id` + strategy) and from
`context_hash` (the whole `MarketContext`'s identity, B4-owned) — this
one exists so "did the same detection inputs produce the same detector
output" can be checked independently of both.

```
payload =
  ctx.instrument_id + "|" +
  ctx.trigger_timeframe + "|" +
  TimeToString(setup_anchor_bar_time, TIME_DATE|TIME_SECONDS) + "|" +
  (side == ORDER_TYPE_BUY ? "BUY" : "SELL") + "|" +
  DoubleToString(swept_level, ctx.symbol_spec.digits) + "|" +
  DoubleToString(mss_confirmation_price, ctx.symbol_spec.digits) + "|" +
  TimeToString(mss_confirmation_bar_time, TIME_DATE|TIME_SECONDS) + "|" +
  resolved_zone_kind + "|" +                    -- "FVG" | "OB"
  DoubleToString(resolved_zone_high, ctx.symbol_spec.digits) + "|" +
  DoubleToString(resolved_zone_low, ctx.symbol_spec.digits) + "|" +
  IntegerToString((long)trigger_reason_mask)

detector_hash = Ids_Sha256Hex(payload)
```

Numeric formatting rule (matches `MarketContext_HashPayload`/
`News_DecisionHash` precedent): every price is formatted via
`DoubleToString(value, ctx.symbol_spec.digits)` — never a fixed literal
decimal count — so `detector_hash` stays correct across instruments with
different digit counts, not just XAUUSD.

## 8. `FVG_OR_OB` resolution semantics

After MSS confirmation, scan the impulse leg (the bars from the sweep bar
through the MSS confirmation bar, inclusive, all sourced from
`trigger_tf_recent[]`) for:

- a qualifying 3-candle **Fair Value Gap** in the direction of the move
  (candle 1's high/low vs. candle 3's low/high leaving a gap candle 2
  doesn't fill)
- a qualifying **Order Block** — the last opposing-color candle
  immediately before the impulse leg's displacement candle

**Resolution priority (frozen):** prefer the FVG closest to the swept
price (the earliest-formed FVG in the impulse leg) if one qualifies; fall
back to the Order Block only if no qualifying FVG exists in the impulse
leg. If **neither** exists, detection fails closed — no candidate is
created (this is the "MSS but no valid FVG/OB retest" fixture in Commit
3's list). `resolved_zone_kind` records which one won.

**Frozen parameters** (strategy policy, not architecture — conservative
defaults chosen specifically to unblock implementation; these are the
values `CRT_V1_RULES_VERSION = "CRT_V1"` means from here on, and changing
any of them later is a `CRT_V2`, never an in-place edit, since
`detector_hash` and `candidate_id` are both derived from data these
parameters shape):

```cpp
#define MLQUANTAI_CRT_V1_LOOKBACK_BARS      64   // size of trigger_tf_recent[]
#define MLQUANTAI_CRT_V1_EXPIRY_AFTER_BARS  12   // TradeCandidate_ComputeExpiryTime's expiry_after_bars
// minimum FVG gap: strictly greater than 0.0 (any non-zero 3-candle gap qualifies, no ATR-multiple floor)
```

`entry_hint`/`sl_hint`/`tp_hint` derivation from the resolved zone
(`resolved_zone_high`/`resolved_zone_low`, `swept_level`,
`ctx.symbol_spec.point`):

```cpp
entry_hint = (resolved_zone_low + resolved_zone_high) / 2.0

// bullish (side == ORDER_TYPE_BUY):
sl_hint = swept_level - 1 * ctx.symbol_spec.point
tp_hint = entry_hint + 2.0 * (entry_hint - sl_hint)

// bearish (side == ORDER_TYPE_SELL):
sl_hint = swept_level + 1 * ctx.symbol_spec.point
tp_hint = entry_hint - 2.0 * (sl_hint - entry_hint)
```

i.e. a fixed 1-point buffer beyond the swept extreme for `sl_hint`, and a
frozen 2.0R target for `tp_hint` (R = `|entry_hint - sl_hint|`) — both
pure functions of already-computed CRT_V1 values and `ctx.symbol_spec`,
no new inputs.

## 9. Expiry — by bar progression, not wall clock

Reuses the existing, sealed `TradeCandidate_ComputeExpiryTime
(setup_anchor_bar_time, expiry_after_bars, trigger_timeframe)` — no new
expiry primitive. `expiry_after_bars = MLQUANTAI_CRT_V1_EXPIRY_AFTER_BARS`
(§8, frozen at 12). `CRT_EvaluateExpiry(setup_anchor_bar_time,
expiry_after_bars, trigger_timeframe, currentClosedBarTime)` (Commit 3)
is a pure function of those four values — never `TimeCurrent()`.

## 10. Pure Function Contract

- Every `CRT_*` function's signature takes only: `const MarketContext
  &ctx`, previously-computed pure values from other `CRT_*` calls, and
  the frozen `CRT_V1_FrozenParameters` (Commit 2). No broker calls
  (`CopyRates`/`iTime`/`SymbolInfo*`/`CalendarValueHistory`), no
  `TimeCurrent()`, no `AccountInfo*`, no `MathRand()`/`GetTickCount()`.
- No `CRT_*` function reads `ctx.account` — runtime-only, excluded from
  `context_hash` by B1's own design; reading it here would make the
  detector's output implicitly depend on state `context_hash` doesn't
  cover.
- Given the same `MarketContext` (byte-identical `context_hash`) and the
  same frozen parameters, every `CRT_*` function and the final
  `TradeCandidate` are byte-identical on every call, forever — the same
  determinism seal B3/B3.5 already proved for `MarketContext` itself,
  extended to the detector built on top of it.
- CRT_V1 needs no state beyond the single `ctx` passed in — no
  cross-call memory, no static/global mutable detector state.

## 11. Hard prohibition list (this entire phase)

No `CTrade`, `OrderSend`, `PositionOpen`/`PositionClose`, no
`AccountInfo*` reads inside any `CRT_*` function, no `RiskPlan`/Risk
Manager types, no gating a candidate's creation on `is_kill_zone` or news
risk (informational bits only, per §2), no `TimeCurrent()` anywhere in a
`CRT_*` function or an ID/hash payload, no `MathRand()`/`GetTickCount()`,
no direct file I/O, no `CopyRates`/`iTime`/`SymbolInfo*`/calendar calls
inside `CRT_*` (everything must already be in `ctx`). Same standing rule
this whole project has run on since Phase A: no order/execution code
until the Execution Engine phase actually arrives.

## 12. B5 input/output schema

```
Input:  const MarketContext &ctx   (extended with trigger_tf_recent[], see above)
        CRT_V1_FrozenParameters    (Commit 2 - #defines, values frozen in §8/§9)

Output: CRTDetectionResult          (Commit 2 struct)
          detected            bool
          side                ENUM_ORDER_TYPE
          swept_level         double
          mss_confirmation_price     double
          mss_confirmation_bar_time  datetime
          resolved_zone_kind  string ("FVG" | "OB")
          resolved_zone_high  double
          resolved_zone_low   double
          reason_mask         ulong
          reason_labels[]     string[]
          detector_hash       string

        -> CRT_ToTradeCandidate(ctx, result) -> TradeCandidate   (Commit 4, pure mapping)
             fills: side, direction, root_event_id, candidate_id,
             context_event_id, context_hash, setup_anchor_bar_time,
             expiry_after_bars, entry_hint/sl_hint/tp_hint,
             trigger_reason_mask, trigger_reasons[], strategy_id/name/version,
             candidate_schema_version, has_liquidity_sweep/has_mss/has_fvg/
             has_order_block (mapped straight from the reason bits)
             leaves at TradeCandidate_Init() defaults: score, confidence,
             compatible_regime, regime_rules_version, state (CANDIDATE_CREATED),
             last_reason (REASON_NONE) - B6/B7's job, not B5's.
```

If `result.detected == false`, `CRT_ToTradeCandidate` is never called and
no `TradeCandidate`/`CANDIDATE_CREATED` event is produced for that bar —
a non-detection is silence, not a rejected candidate (there's nothing to
reject; B6/B7 rejection semantics only start once a candidate exists).

## Acceptance criteria (test gates, Commit 6/7)

```
[ ] Detector has no direct runtime/broker-state access
[ ] Same input produces byte-stable output across repeated runs
[ ] Same MarketContext replayed on the same broker connection reproduces
    identical root_event_id/candidate_id/detector_hash (deterministic
    replay identity - see §4 for what this does NOT claim across brokers)
[ ] reason_labels are sorted by ascending reason bit
[ ] detector_hash changes only when frozen rule inputs change
[ ] expiry follows bar progression, not wall clock
[ ] FVG_OR_OB follows frozen resolution semantics
[ ] Event replay reconstructs CANDIDATE_CREATED lineage
[ ] No Risk, AI, Execution, or Position types appear in the detector's dependency graph
```

## Non-goals (explicitly out of scope for B5)

Risk sizing, execution, AI filtering, regime-compatibility gating,
cross-strategy arbitration/deduplication (root_event_id only *enables*
that later), any strategy other than CRT_V1, any timeframe confluence
beyond what's already inside `MarketContext`, any change to
`MarketContext`'s B1–B4 sealed fields (only the additive
`trigger_tf_recent[]` window above), a real UTC-conversion mechanism
(rejected — see §4).

## B5 Definition of Done

B5 = SEALED when the detector is a pure function of `MarketContext` +
the frozen CRT_V1 parameters (+ the news-snapshot identity already inside
`ctx`, nothing separately queried) only; replaying the Event Store
reproduces identical candidate lineage without depending on broker
timezone, current session, or any live trading state. Next: **B6
Candidate QA / dataset analysis.**
