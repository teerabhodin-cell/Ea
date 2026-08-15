# Phase B — B6.3: Hash Contract Spec

**Status: Implemented, awaiting real compile/test confirmation.**

Scoped down from the original B6.3 proposal after a gap review: most of
the proposed work items (reject malformed/orphan/collision lines, block
export on a corrupt store, deterministic byte-identical export, full
row-lineage traceability) are **already built and already passed**
in B6.1 (146/146) and B6.2 (75/75) — see "What's already covered"
below. This document plus the two additions in
Docs/CHANGELOG.md's B6.3 entry are the genuinely new work: (1) this
spec, consolidating three hash contracts that previously only existed
as scattered code comments across three files; (2) exhaustive
inclusion/exclusion mutation-sweep tests for `context_hash` and
`detector_hash`, matching the rigor `candidate_hash` already has; (3) a
structured rejection-reason classification, additive to
`CandidateProjection`.

This is a reference document, not new behavior. Every rule below
already exists in code — this just puts all three in one place so
dev/test/QA share the same vocabulary, per the B6.3 request. If any
rule below and its cited source ever disagree, the **source code is
authoritative** — update this doc, not the other way around.

## Why three hashes, not one

- **`context_hash`** — identifies one `MarketContext` snapshot: "did
  this exact market situation happen." Computed once, by
  `FeatureEngine_BuildContext`, before any detector runs.
- **`detector_hash`** — identifies one `CRTDetectionResult`: "did the
  same detection inputs produce the same detector output," independent
  of which context or which candidate wraps it. A given `context_hash`
  could in principle feed multiple strategies' detectors; each gets its
  own `detector_hash`.
- **`candidate_hash`** — identifies one `TradeCandidate`'s own
  deterministic, decision-bearing content: "would replaying this exact
  candidate-creation path produce the identical candidate again."
  Rolls up `context_hash` and `detector_hash` as single values rather
  than re-hashing their contents (see "Don't hash the same thing
  twice" below).

## 1. `context_hash`

**Computed by:** `MarketContext_ComputeHash` →
`Ids_Sha256Hex(MarketContext_HashPayload(c))`
(`Market/MLQuantAI_MarketContext.mqh`).

**Moves the hash (INCLUDED in the payload):**

| Field | Note |
|---|---|
| `instrument_id` | |
| `broker_symbol` | |
| `trigger_timeframe` | |
| `anchor_bar_time` | formatted `TIME_DATE\|TIME_SECONDS` |
| `m5_bar` / `m15_bar` / `h1_bar` / `h4_bar` | each via `MarketContext_RatesHashFragment`: `time\|open\|high\|low\|close\|tick_volume\|spread` |
| `trigger_tf_recent[]` | via `MarketContext_RatesArrayHashFragment` — same per-bar fragment, **in array order** (oldest first); order is part of the window's identity |
| `bid_at_anchor`, `ask_at_anchor`, `spread_points_at_anchor` | |
| `atr_m15`, `adx_m15`, `ema_slope_m15` | |
| `pdh`, `pdl` | |
| `asian_range_high`, `asian_range_low` | |
| `session_id` | |
| `is_kill_zone` | `"1"`/`"0"` |
| `news_decision_hash` | see below — the news payload's ONLY contribution |

**Does NOT move the hash (EXCLUDED, with reason):**

| Field | Why excluded |
|---|---|
| `context_event_id`, `context_hash` | derived FROM this payload, not part of it — hashing them would be circular |
| `market_context_schema_version`, `feature_schema_version`, `news_schema_version` | schema identity, not content — a schema bump is a version-negotiation concern, not a content change |
| `account.balance`, `account.equity` | runtime-only; two builds of "the same" bar taken a second apart would otherwise never match |
| `symbol_spec.*` | broker/instrument metadata, not part of what happened at this bar |
| `news[]` (raw array), `news_count`, `max_news_impact`, `nearest_news_minutes` | **redundant with `news_decision_hash`**, not independent signal — see below |
| `news_snapshot_identity` | full news lineage/provenance hash, kept for audit trail but deliberately NOT part of the context's own identity (a re-fetch of the same calendar with different provenance metadata is still "the same news decision") |

**News is hashed exactly once.** `news_decision_hash` (computed
upstream by the News Engine, Phase B B4) already canonicalizes every
news field that could change a trading decision. Folding the raw
`news[]` array/`news_count`/`max_news_impact`/`nearest_news_minutes`
into `context_hash` directly, on top of `news_decision_hash`, would
double-count the same information — the "don't hash the same thing
twice" rule this whole project follows.

## 2. `detector_hash`

**Computed by:** `CRT_DetectorHash(...)` →
`Ids_Sha256Hex(payload)` (`Strategies/MLQuantAI_CRT_V1_Contract.mqh`).
CRT_V1-specific today; a second strategy would define its own detector
hash function with its own payload, not reuse this one.

**Moves the hash (INCLUDED, positional — not `|`-joined field names,
so order below IS the payload order):**

1. `instrumentId`
2. `triggerTimeframe`
3. `setupAnchorBarTime` (== `mssConfirmationBarTime`, contract section 0)
4. `side` (`"BUY"`/`"SELL"`)
5. `sweptLevel`
6. `mssConfirmationPrice`
7. `mssConfirmationBarTime`
8. `resolvedZoneKind` (`"FVG"`/`"OB"`/`""`)
9. `resolvedZoneHigh`
10. `resolvedZoneLow`
11. `reasonMask`

All prices formatted via `DoubleToString(value, digits)` — `digits`
comes from the calling context's `symbol_spec.digits`, never a fixed
literal decimal count, so the hash stays correct across instruments.

**Does NOT move the hash on its own (EXCLUDED, with reason):**

| Field | Why excluded |
|---|---|
| `reason_labels[]` | the human-readable label array is a pure derivation of `reason_mask` (via `CRT_ReasonLabelsFromMask`) — hashing both would be redundant |
| `detected` | implicit — `detector_hash` is only ever computed on the path where `result.detected == true` |

**`digits` is not independently excluded — it's a formatting multiplier
on the INCLUDED price fields, not a value with its own identity in the
payload.** There is no dedicated `digits` slot in the payload string;
`digits` only controls how many decimal places `DoubleToString` renders
`sweptLevel`/`mssConfirmationPrice`/`resolvedZoneHigh`/`resolvedZoneLow`
to. Changing `digits` alone, with the identical underlying `double`
values, DOES move the hash (`DoubleToString(99.50, 2)` = `"99.50"` vs.
`DoubleToString(99.50, 4)` = `"99.5000"` — different strings). Treat
`digits` as governing precision of the price fields above, not as an
independently-tested inclusion/exclusion row. `candidate_hash`'s own
`digits` parameter (passed to `CRT_CandidateHash(c, digits)`) has the
identical relationship to `entry_hint`/`sl_hint`/`tp_hint` — same
caveat applies there, not repeated in section 3 below.
`context_hash`'s price fields, by contrast, format at a fixed literal
5 decimal places inside `MarketContext_HashPayload` itself (not
parameterized by `symbol_spec.digits`), so this caveat does not apply
to `context_hash`.

**Explicitly out of scope for `detector_hash` (contract section 7,
verbatim):** it does not hash
`MLQUANTAI_CRT_V1_LOOKBACK_BARS`/`EXPIRY_AFTER_BARS`/the FVG
threshold/the zone policy — those are rule-VERSION concerns, and
validity across rule-version changes is `candidate_id`'s job (via
`MLQUANTAI_CRT_V1_RULES_VERSION`), not `detector_hash`'s. A CRT_V2 with
different frozen parameters producing the identical detection output
on the identical bars is expected to get the identical `detector_hash`
— version identity lives in `candidate_id`/`strategy_version`, not
here.

## 3. `candidate_hash`

**Computed by:** `CRT_CandidateHash(c, digits)` →
`Ids_Sha256Hex(CRT_CandidateHashPayload(c, digits))`
(`Strategies/MLQuantAI_CRT_V1_ToTradeCandidate.mqh`). Computed LAST,
after every other field on the finished `TradeCandidate` is filled.

**Moves the hash (INCLUDED, `|`-joined, this exact order):**

1. `candidate_id`
2. `root_event_id`
3. `strategy_id`
4. `strategy_name`
5. `strategy_version`
6. `side` (`"BUY"`/`"SELL"`)
7. `context_event_id`
8. `context_hash` — rolled up as a single value, see below
9. `setup_anchor_bar_time`
10. `expiry_after_bars`
11. `entry_hint`
12. `sl_hint`
13. `tp_hint`
14. `trigger_reason_mask`
15. `detector_hash` — rolled up as a single value, see below
16. `candidate_schema_version`

Exhaustively test-verified: `Tests/MLQuantAI_Test_CandidateProjection.mq5`'s
`Test_HashIntegrity_DecisionFieldsChangeHash` mutates each of the 16
fields above independently and confirms every one moves the hash.

**Does NOT move the hash (EXCLUDED, explicit whitelist):**

| Field | Why excluded |
|---|---|
| `score`, `confidence`, `compatible_regime`, `regime_rules_version` | B6/B7-owned, don't exist yet at candidate-creation time |
| `state`, `last_reason` | lifecycle-owned, mutate after creation by design |
| `correlation_id`, `parent_candidate_ids` | set later, at submission/arbitration time |
| `entry`, `sl`, `tp`, `rr`, `atr`, `stop_distance` | risk-adjusted values — B6/B7's job per the CRT contract's Non-goals section, distinct from `entry_hint`/`sl_hint`/`tp_hint` which ARE hashed |
| `signal_time` | pure derivation of `setup_anchor_bar_time` (already hashed) |
| `expiry_time` | pure derivation of `setup_anchor_bar_time` + `expiry_after_bars` + `trigger_timeframe` (already hashed) |
| `in_killzone`, `news_risk`, `has_liquidity_sweep`, `has_mss`, `has_fvg`, `has_order_block` | pure derivations of `trigger_reason_mask` (already hashed) — hashing both the mask and its own derived booleans would be redundant |
| `trigger_reasons[]` | the human-readable label array is a pure derivation of `trigger_reason_mask` (already hashed), same reasoning as `detector_hash`'s `reason_labels[]` |

Exhaustively test-verified: `Test_HashExclusion_NonDecisionFieldsDoNotChangeHash`
mutates every field in this table independently and confirms none of
them move the hash.

**"Don't hash the same thing twice", applied three times over:**
`candidate_hash` includes `context_hash` and `detector_hash` as two
single rolled-up values rather than re-hashing every field those two
hashes already cover (context's bars/session/news, detector's swept
level/zone/reason mask). This is the same principle `context_hash`
itself uses for `news_decision_hash` (folds the whole news decision in
as one value, doesn't re-hash `news[]`), and the same principle B6.2's
`row_hash` uses for `candidate_hash` (rolls it up as one value, doesn't
re-hash the 16 fields above a second time at the export layer). Each
hash in this chain owns exactly the layer that produced it, once.

## What's already covered (not re-scoped into B6.3)

Confirmed already built, already tested, no new B6.3 work needed:

- Reject malformed/empty-`candidate_id`/unknown-schema lines,
  collision-vs-duplicate distinction, orphan/`context_hash`-mismatch
  referential integrity, time/numerical/reason-mask validation —
  `CandidateProjection_ApplyLine` and its `Validate*` helpers
  (B6.1, 146/146 PASS).
- Atomic replay (any bad line blocks the whole rebuild, registry stays
  at last-known-good, no partial/ghost state) —
  `CandidateProjection_RebuildFromFile`'s validator-gate (B6.1).
- Deterministic, byte-identical export; stable ordering; `dataset_hash`
  excluded from `export_time`; orphan blocks the whole export; full
  row-to-source lineage traceability (`context_hash`/`detector_hash`/
  `candidate_hash` all confirmed to trace back to their originals) —
  `CandidateDatasetExport_BuildDataset` (B6.2, 75/75 PASS).

## What B6.3 actually adds

1. This spec document.
2. `Tests/MLQuantAI_Test_B6_3_HashContract.mq5` — exhaustive
   inclusion/exclusion mutation sweeps for `context_hash` and
   `detector_hash`, matching `candidate_hash`'s existing rigor (which
   B6.1 already had). Also includes a structured rejection-reason
   classification check (see next item).
3. `CandidateProjection.mqh` (additive): `ENUM_CANDPROJ_REJECT_REASON`
   + `CandidateProjection_ClassifyReason()` + a new
   `CandidateProjectionReport.first_error_code` field. The validator's
   rejection reasons were previously only free-text strings (matched
   by fragile substring search in tests); this adds a structured
   category on top — `first_error` (the string) is completely
   unchanged, this is a pure addition. See CHANGELOG.md's B6.3 entry
   for the full category list.
