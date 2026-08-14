# Phase B — B5 Commit 4: `CRT_ToTradeCandidate` (pure mapping)

**Status: PASSED (2026-08-14).** Confirmed on a real compile/test run:
`MLQuantAI_Test_CRT_V1_ToTradeCandidate.mq5` 79/79. Commit 5 (event
emission + Event Store replay verification) is now open.
Implements the Commit 4 boundary (contract section 12's I/O schema,
sharpened by a QA-approved boundary spec issued at Commit 4 kickoff): the
pure mapping from Commit 3's `CRTDetectionResult` to a `TradeCandidate`
(`Core/MLQuantAI_TradeCandidate.mqh`, sealed since B1). Still no event
emission — `CANDIDATE_CREATED` is Commit 5.

```cpp
bool CRT_ToTradeCandidate(const MarketContext &ctx, const CRTDetectionResult &crt, TradeCandidate &outCandidate);
```

`crt.detected == false` → returns `false`, `outCandidate` stays at
`TradeCandidate_Init()` defaults, no Event Store write, no state-machine
call. `crt.detected == true` → returns `true`, a fully initialized
deterministic `TradeCandidate` (`state = CANDIDATE_CREATED` in the
object only — no event until Commit 5).

## What this commit adds

- **`Strategies/MLQuantAI_CRT_V1_ToTradeCandidate.mqh`** (new):
  `CRT_ToTradeCandidate` plus `CRT_CandidateHash`/`CRT_CandidateHashPayload`.
- **`Core/MLQuantAI_TradeCandidate.mqh`** (additive extension to the
  sealed B1 struct): two new fields, `detector_hash` and
  `candidate_hash` — see below.

## Immutable detector truth — copy/map only, never recompute

Every value `CRT_ToTradeCandidate` reads off `crt` (`side`,
`swept_level`, `mss_confirmation_price`, `mss_confirmation_bar_time`,
`resolved_zone_kind`, `resolved_zone_high`, `resolved_zone_low`,
`reason_mask`, `reason_labels[]`, `detector_hash`) is used as-is — never
re-derived from `ctx` a second time. The hard invariant this enforces:

```cpp
candidate.detector_hash        == crt.detector_hash;
candidate.trigger_reason_mask  == crt.reason_mask;
candidate.trigger_reasons[]    == crt.reason_labels[];
```

`detector_hash` did not previously exist on `TradeCandidate` — added
additively (Commit 4) specifically to carry this invariant. It is
assigned by direct copy (`out.detector_hash = result.detector_hash;`),
never passed through a hash function again.

## `TradeCandidate.candidate_hash` — new, distinct from `candidate_id`/`context_hash`/`detector_hash`

Also added additively. `candidate_id` namespaces *which rule version
produced this candidate* (contract section 6); `detector_hash`
identifies *this detection's own output* (contract section 7);
`context_hash` identifies *the market snapshot the detection ran
against* (B1/B4). None of the three cover "does this exact
`TradeCandidate` object — including its derived hints and reason tree —
match what was built before". `candidate_hash` closes that gap: a
canonical `Ids_Sha256Hex` hash (same primitive as every other ID/hash in
this project) over a frozen, `|`-joined payload, computed **last**, after
every other field is filled (same "hash the finished object" convention
`MarketContext_ComputeHash` already uses):

```cpp
candidate_id | root_event_id | strategy_id | strategy_name | strategy_version |
"BUY"/"SELL" | context_event_id | context_hash |
TimeToString(setup_anchor_bar_time) | expiry_after_bars |
DoubleToString(entry_hint, digits) | DoubleToString(sl_hint, digits) | DoubleToString(tp_hint, digits) |
trigger_reason_mask | detector_hash | candidate_schema_version
```

Deliberately excludes, per this commit's own kickoff spec ("ห้าม include
account, spread, broker state, wall-clock หรือ mutable fields"):

- account/spread/broker runtime state — never read by this function at all.
- every B6/B7-owned mutable field (`score`/`confidence`/
  `compatible_regime`/`regime_rules_version`/`state`/`last_reason`/
  `correlation_id`/`parent_candidate_ids`/`entry`/`sl`/`tp`/`rr`/`atr`/
  `stop_distance`) — none of them exist yet at creation time.
- `signal_time`/`expiry_time` — both pure derivations of
  `setup_anchor_bar_time` + `expiry_after_bars` + `trigger_timeframe`,
  already covered by hashing those inputs directly (same reasoning
  `MarketContext_HashPayload` uses to fold `news_count`/
  `max_news_impact`/`nearest_news_minutes` into `news_decision_hash`
  alone instead of hashing all four).

## Frozen mapping rules (entry/sl/tp hints)

Exactly the kickoff spec's frozen formulas — stop reference is always
`crt.swept_level`, never `resolved_zone_low`/`resolved_zone_high`
(moving it would be a `CRT_V2` semantic change):

```cpp
entry_hint = (resolved_zone_high + resolved_zone_low) * 0.5;
// BUY:  sl_hint = swept_level - point;  tp_hint = entry_hint + 2.0 * (entry_hint - sl_hint);
// SELL: sl_hint = swept_level + point;  tp_hint = entry_hint - 2.0 * (sl_hint - entry_hint);
```

(Uses the frozen `MLQUANTAI_CRT_V1_TP_R_MULTIPLE` constant rather than a
re-typed `2.0` literal — same value, one canonical source.)

## Identity / flags — unchanged from the original section 12 mapping

`root_event_id` via `Ids_RootEventId` (event type `CRT_SWEEP_LOW`/
`CRT_SWEEP_HIGH`, per contract section 5); `candidate_id` via
`Ids_CandidateId(root_event_id, "CRT", MLQUANTAI_CRT_V1_RULES_VERSION)`
(section 6); `has_liquidity_sweep`/`has_mss`/`has_fvg`/`has_order_block`
derive solely from `reason_mask`, plus `in_killzone`/`news_risk` from
bits 6/7 (the same "mapped straight from the reason bits" rule extended
to two fields the contract's original fill list didn't name but which
exist on `TradeCandidate` for exactly this purpose).

`signal_time` (`= setup_anchor_bar_time`) and `expiry_time` (via the
existing, sealed `TradeCandidate_ComputeExpiryTime`) are also filled —
the latter's own doc comment already mandates this computation, so
leaving it at `Init()`'s `0` would violate that field's *existing*
contract, not just be incomplete.

## Test coverage (`Tests/MLQuantAI_Test_CRT_V1_ToTradeCandidate.mq5`)

Detection-rule correctness itself is Commit 3's job
(`MLQuantAI_Test_CRT_V1_Rules.mq5`) — this suite exercises only the
mapping, against the Commit 4 kickoff's full required-test list:

- `detected == false` → returns `false`, candidate stays at `Init()`
  defaults (including the new `detector_hash`/`candidate_hash` fields).
- BUY → `ORDER_TYPE_BUY` + `SIGNAL_BUY`; SELL → `ORDER_TYPE_SELL` +
  `SIGNAL_SELL`, on real bullish/bearish fixtures.
- `entry_hint`/`sl_hint`/`tp_hint` match the frozen formulas exactly, both
  directions.
- `root_event_id` uses `Ids_RootEventId`; `candidate_id` uses
  `Ids_CandidateId` — both checked by direct re-derivation and comparison.
- `candidate.detector_hash == crt.detector_hash`.
- `has_*`/`in_killzone`/`news_risk` all derive solely from `reason_mask`.
- Same `ctx` + `crt` → identical `candidate_hash`, including a 1000-
  repeat loop (0 mismatches) — the same "rebuild N times, assert 0
  mismatches" pattern `Test_DataHubDeterminism.mq5` already uses for
  `context_hash`.
- Account balance/equity/margin_level mutations leave `root_event_id`/
  `candidate_id`/`candidate_hash` unchanged.
- `CRT_ToTradeCandidate` does not mutate its `CRTDetectionResult` input
  (checked field-by-field before/after the call, not just relying on the
  `const` qualifier).
- `candidate_id` differs across two different rules-version strings for
  the same `root_event_id`/detector output (contract section 7's
  acceptance-criteria gate).
- No runtime/account/tick/risk/AI/execution/queue/EventStore/
  StateMachine dependency — confirmed by source inspection (grep for
  `CopyRates`/`iTime`/`SymbolInfo*`/`AccountInfo*`/`CTrade`/`OrderSend`/
  `EventStore`/`StateMachine_Transition`/`TimeCurrent`/`MathRand`/
  `GetTickCount` inside `MLQuantAI_CRT_V1_ToTradeCandidate.mqh` — zero
  matches outside comments) plus the account-mutation test above as
  empirical evidence for the account-independence claim specifically.

## Commit 4 seal criteria — CONFIRMED PASSED

- `MLQuantAI_Test_CRT_V1_ToTradeCandidate.mq5` = 79/79 PASS
- No event emission, no risk/execution/AI code anywhere in this commit — confirmed

`MLQuantAI_Test_CRT_V1_Rules.mq5` was not re-run this round (unaffected
by this commit's diff); worth reconfirming before the full B5 seal.

Commit 5 is now open — the one remaining boundary per the kickoff spec:

```text
TradeCandidate -> CANDIDATE_CREATED -> EventStore append
```
