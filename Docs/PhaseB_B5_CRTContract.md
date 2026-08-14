# Phase B — B5: CRT_V1 Detector Contract Freeze (Commit 1)

**Status: DRAFT — pending review before Commit 2 starts.** This is a
documentation-only commit. No `CRT_IsSweepLow`, `CRT_ConfirmMSS`,
`CRT_FindFVG`, `CRT_FindOrderBlock`, or any other detection logic exists
yet — that's Commit 3+, gated on this contract being reviewed first.

CRT_V1 ("Candle Range Theory") is the first live strategy module: sweep a
prior liquidity level, confirm a market structure shift (MSS), retest a
Fair Value Gap or Order Block from the impulse leg, produce a
`TradeCandidate`. B5's whole job is turning a single `MarketContext`
snapshot into zero or one `TradeCandidate`, deterministically, with a
fully auditable reason tree — nothing about risk, sizing, execution, AI,
or regime compatibility. Those stay at their `TradeCandidate_Init()`
defaults; B6/B7's job, not B5's.

## ⚠️ One open design question before Commit 2 can start

B1–B4 froze `MarketContext` (`Market/MLQuantAI_MarketContext.mqh`) as a
**single closed bar's snapshot** — `m5_bar`/`m15_bar`/`h1_bar`/`h4_bar`
are each exactly one `MqlRates`, not a series. A real CRT detector needs
to see a **short window of recent trigger-timeframe bars** to find the
sweep bar, the reaction bar(s), and the MSS confirmation bar — that's
inherently a multi-bar pattern, not a single-bar one.

Two ways to get that window into the detector:

1. **Extend `MarketContext` additively** with a recent-bars field (e.g.
   `MqlRates trigger_tf_recent[]`, the last N closed bars on
   `trigger_timeframe` ending at `anchor_bar_time` inclusive, captured
   once by `FeatureEngine_BuildContext()` the same way `m5_bar` etc.
   already are). CRT_V1 stays a pure function of `ctx` alone; replay
   reconstructs the exact same window from the persisted
   `MARKET_CONTEXT_READY` payload without ever re-querying price history.
2. Let `CRT_*` functions call `CopyRates`/`iTime` themselves at detection
   time.

**Option 2 violates the Pure Function Contract below** (reintroduces a
live-data dependency exactly like the news-source problem B4 exists to
solve — a replayed candidate could disagree with the original if history
depth/availability differs between runs) and violates this table's own
"Detector has no direct runtime/broker-state access" test gate. **Option
1 is the one this contract assumes** — proposed shape:

```
MqlRates trigger_tf_recent[];   // additive field on MarketContext
                                  // last MLQUANTAI_CRT_V1_LOOKBACK_BARS
                                  // closed bars on trigger_timeframe,
                                  // oldest first, last element == the bar
                                  // at anchor_bar_time (shift 1) itself -
                                  // i.e. trigger_tf_recent[N-1] is the
                                  // same bar as ctx.m5_bar when
                                  // trigger_timeframe == M5.
```

This needs an actual code change to `MarketContext.mqh` (additive - every
B1–B4 sealed field is untouched, same discipline as B4's own additions)
plus a `context_hash`/`MARKET_CONTEXT_READY` payload update (append the
window, same "safe before B5 relies on it" justification B4 already used
twice). **Confirm this before Commit 2** — it's the one piece of this
contract that reaches back into an already-sealed file instead of only
adding new B5-owned files.

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

## 4. UTC / lineage timestamp normalization

Same policy B4 already froze for `News_NormalizeTimeUtc` — MQL5 can't
reliably convert an arbitrary historical `datetime` to true UTC, so
"canonical clock" here means the same single clock every closed-bar
computation in this project already uses: broker server time via
`iTime()`. **Every CRT_V1 lineage timestamp used in an ID or hash payload
must be one already inside `MarketContext`** (`anchor_bar_time`, an
`.time` field off `m5_bar`/`m15_bar`/`h1_bar`/`h4_bar`/`trigger_tf_recent[]`)
— never `TimeCurrent()`, never a hand-built `MqlDateTime`, never a value
computed outside the `ctx` that was passed in.

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
`trigger_tf_recent[]` — see the open question above) for:

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

**PROPOSED, PENDING REVIEW** (real strategy parameters, not
architecture — flagging rather than silently deciding):
- minimum FVG gap size (currently proposed: any non-zero gap, no ATR
  multiple floor)
- `entry_hint`/`sl_hint`/`tp_hint` derivation from the resolved zone
  (proposed: `entry_hint` = resolved zone midpoint; `sl_hint` = beyond
  the swept extreme by a frozen buffer; `tp_hint` = a frozen R-multiple)
- `MLQUANTAI_CRT_V1_LOOKBACK_BARS` (the size of `trigger_tf_recent[]`
  above) and `MLQUANTAI_CRT_V1_EXPIRY_AFTER_BARS` (§9) exact values

## 9. Expiry — by bar progression, not wall clock

Reuses the existing, sealed `TradeCandidate_ComputeExpiryTime
(setup_anchor_bar_time, expiry_after_bars, trigger_timeframe)` — no new
expiry primitive. `expiry_after_bars` is a frozen constant,
`MLQUANTAI_CRT_V1_EXPIRY_AFTER_BARS` (Commit 2, value PROPOSED/PENDING
REVIEW — see §8). `CRT_EvaluateExpiry(setup_anchor_bar_time,
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
Input:  const MarketContext &ctx   (extended per the open question above)
        CRT_V1_FrozenParameters    (Commit 2 - #defines or a const struct)

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
[ ] UTC-equivalent inputs produce identical lineage identifiers
[ ] reason_labels are sorted by ascending reason bit
[ ] detector_hash changes only when frozen rule inputs change
[ ] root_event_id is cross-broker stable (same instrument_id/price/bar, any broker_symbol)
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
`MarketContext`'s B1–B4 sealed fields (only the additive window in the
open question above, if confirmed).

## B5 Definition of Done

B5 = SEALED when the detector is a pure function of `MarketContext` +
the frozen CRT_V1 parameters (+ the news-snapshot identity already inside
`ctx`, nothing separately queried) only; replaying the Event Store
reproduces identical candidate lineage without depending on broker
timezone, current session, or any live trading state. Next: **B6
Candidate QA / dataset analysis.**
