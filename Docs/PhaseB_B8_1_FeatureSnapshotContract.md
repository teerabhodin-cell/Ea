# Phase B8.1 — FeatureSnapshot Identity/Lineage/Hash: Contract (FROZEN)

**Status: FROZEN, before any code exists.** Written per this project's
standing "freeze before code" discipline (established starting B7).
B8.1 opens only after B7 was confirmed SEALED (Commits 1-3, 203/203,
full B5/B6/B7 regression suite 474/474, zero regressions) — see
`Docs/PhaseB_Architecture_Baseline.md`. B8.1 is scoped to schema,
identity, hash policy, and a pure candidate-time copy function only —
no dataset export, no model, no ONNX, no inference, no
`AI_DECISION_CREATED` event. Those are B8.2 through B8.6, each will
get their own frozen addendum when they open, mirroring exactly how
B7 Commits 1-3 each built on one shared, incrementally-extended
contract.

## The collision, and how it was resolved

Before writing this contract, the repo was checked for an existing
`FeatureSnapshot` — the same discipline that caught the B7 `RiskPlan`
collision. `Market/MLQuantAI_FeatureSnapshot.mqh` already exists, from
Phase B1: a real, sealed, but completely unwired struct (no Feature
Engine builds it; the header explicitly says so) with a **fixed set
of named feature fields** (`atr_m15`, `adx_m15`, `ema_slope_m15`,
`pdh`, `pdl`, `asian_range_high`, `asian_range_low`,
`spread_points_at_anchor`, `news_count`, `max_news_impact`,
`nearest_news_minutes`, `is_kill_zone`), keyed only by
`context_event_id` — **no identity field, no content hash, no
candidate lineage at all.** This is a materially different (and much
more primitive) shape than the identity/hash/lineage-bearing
`FeatureSnapshot` an AI feature contract needs.

Resolved the same way the `RiskPlan` collision was: **extend the
existing sealed struct additively.** Every Phase B1 field stays
exactly as it is, unchanged, in meaning and in the existing
`FEATURES_V1` schema version. Five new fields are added alongside for
B8.1's identity/lineage/hash needs. `Candidate_ToFeatureSnapshot`
(this contract's own algorithmic contribution, mirroring how
`Candidate_ToRiskPlan` was B7's own contribution) fills both field
groups from one computation.

One deliberate deviation from the `RiskPlan` precedent: `RiskPlan`
needed a SECOND schema-version constant (`risk_plan_schema_version`,
alongside Phase A's untouched `risk_schema_version`) because Phase A's
constant specifically named that phase's narrow shape. `FeatureSnapshot`'s
existing `feature_schema_version` was never phase-specific in that
way — it was always meant to describe "this struct's current shape"
(the same role `market_context_schema_version` plays for the
ever-growing `MarketContext`, B1 through B7, under one constant). Since
B8.1 only ADDS fields and changes no existing field's meaning, per the
struct's own header rule ("bump `feature_schema_version` to a new
`_V2`... if the meaning of an existing field ever needs to change"),
no second schema constant is introduced — `FEATURES_V1` covers the
extended struct too.

## 1. `FeatureSnapshot` — final struct

```cpp
struct FeatureSnapshot
{
   // Phase B1 fields - UNCHANGED, same meaning, same FEATURES_V1 schema
   string   feature_schema_version;
   string   context_event_id;

   double   atr_m15;
   double   adx_m15;
   double   ema_slope_m15;
   double   pdh;
   double   pdl;
   double   asian_range_high;
   double   asian_range_low;
   double   spread_points_at_anchor;

   int      news_count;
   int      max_news_impact;
   int      nearest_news_minutes;
   bool     is_kill_zone;

   // B8.1 additive fields - identity/lineage/content-integrity
   string   feature_snapshot_id;   // identity - see section 2
   string   candidate_id;          // which candidate this snapshot backs
   string   candidate_hash;        // copied verbatim from the candidate, for tamper/mismatch detection
   string   context_hash;          // copied verbatim from the candidate's own context_hash (same value candidate.context_hash already carries)
   string   feature_vector_hash;   // content hash - see section 3
};
```

No `snapshot_time` field. The original proposal included one; it's
deliberately dropped, not deferred. A `FeatureSnapshot` is defined as
a pure, deterministic function of one candidate — `snapshot_time`
would always equal that candidate's own `setup_anchor_bar_time`,
reachable via `candidate_id` lineage exactly the way `RiskPlan`
reaches candidate timing without storing a redundant time field of
its own. Adding one would violate this project's own "don't persist a
field twice" rule (already applied to `RiskPlan`'s `lot`/`risk_money`
shadow-field decision) for zero new information. This also fully
resolves the open question flagged in `Docs/PhaseB_Architecture_Baseline.md`
("`feature_vector_hash` should probably exclude `snapshot_time`") —
by not having the field, not by excluding it from the hash.

`context_event_id` is unchanged from Phase B1 (still present, still
excluded from the hash — see section 3). `context_hash` is new: it
lets a caller verify tamper/mismatch without a second lookup, the same
role `candidate_hash` already plays on `RiskPlan`.

## 2. Identity: `feature_snapshot_id`

```cpp
string Ids_FeatureSnapshotId(string candidateId)
{
   return Ids_Deterministic("FSNAP", candidateId);
}
```

Single-argument, unlike `Ids_RiskPlanId(candidateId, sizingRulesVersion)`.
`RiskPlan`'s identity depends on `sizing_rules_version` because B7
genuinely has more than one possible sizing methodology. B8.1's
`Candidate_ToFeatureSnapshot` is a pure verbatim copy from an already-
computed `MarketContext` — there is no methodology choice yet, so
there is nothing for identity to depend on beyond `candidate_id`. If a
future B8 phase introduces an actual feature-computation methodology
choice (the real analogue of `sizing_rules_version`), identity gains
that parameter additively then — not speculatively now, per this
project's standing "don't design for hypothetical future requirements"
discipline.

`Core/MLQuantAI_Ids.mqh` gets this function added (additive), next to
`Ids_RiskPlanId`.

## 3. Content integrity: `feature_vector_hash`

```cpp
string FeatureSnapshot_HashPayload(const FeatureSnapshot &f)
{
   string s = "";
   s += f.candidate_id + "|";
   s += f.candidate_hash + "|";
   s += f.context_hash + "|";
   s += CanonicalDouble(f.atr_m15) + "|";
   s += CanonicalDouble(f.adx_m15) + "|";
   s += CanonicalDouble(f.ema_slope_m15) + "|";
   s += CanonicalPrice(f.pdh) + "|";
   s += CanonicalPrice(f.pdl) + "|";
   s += CanonicalPrice(f.asian_range_high) + "|";
   s += CanonicalPrice(f.asian_range_low) + "|";
   s += CanonicalDouble(f.spread_points_at_anchor) + "|";
   s += IntegerToString(f.news_count) + "|";
   s += IntegerToString(f.max_news_impact) + "|";
   s += IntegerToString(f.nearest_news_minutes) + "|";
   s += (f.is_kill_zone ? "1" : "0");
   return s;
}

string FeatureSnapshot_ComputeHash(const FeatureSnapshot &f)
{
   return Ids_Sha256Hex(FeatureSnapshot_HashPayload(f));
}
```

Canonical numeric formatting reuses `Core/MLQuantAI_CanonicalFormat.mqh`
exactly as B7 does — `CanonicalPrice` for actual price levels (`pdh`/
`pdl`/`asian_range_high`/`asian_range_low`, 5 decimals, matching how
`context_hash`'s own payload formats these same fields at
`Digits()`-independent 5-decimal precision), `CanonicalDouble` for the
non-price doubles (8 decimals). No `Digits()`/`_Digits` in this path,
same hard rule as every other hash in this project.

**INCLUDED** (15 fields): `candidate_id`, `candidate_hash`,
`context_hash`, and all 12 Phase B1 feature fields (`atr_m15` through
`is_kill_zone`).

**EXCLUDED**: `feature_snapshot_id` (identity, not content — same
split every other hash in this project makes), `feature_schema_version`
(struct-shape marker, mirrors `market_context_schema_version`'s own
exclusion from `context_hash` and `risk_plan_schema_version`'s
exclusion from `plan_hash`), `context_event_id` (a pointer, not
content — mirrors `context_hash`'s own exclusion of
`context_event_id`, already tested and confirmed in B6.3's suite).

## 4. `Candidate_ToFeatureSnapshot` — the pure copy function

```cpp
bool Candidate_ToFeatureSnapshot(const TradeCandidate &candidate, const MarketContext &ctx, FeatureSnapshot &outSnapshot)
```

Frozen algorithm:

1. **Fail-closed input validation.** Reject (return `false`, leave
   `outSnapshot` at `FeatureSnapshot_Init()` defaults) if any of:
   `candidate.candidate_id == ""`; `candidate.state !=
   CANDIDATE_CREATED`; `candidate.context_event_id != ctx.context_event_id`
   (the `ctx` passed in must be the SAME context this candidate was
   actually built from — a referential-integrity check at the
   function boundary, mirroring `RiskSizing_ValidateInput`'s own
   input-consistency checks); `candidate.context_hash != ctx.context_hash`
   (tamper/mismatch check, same reasoning); any of the 8 double
   feature fields on `ctx` fails `MathIsValidNumber` (NaN/Inf guard,
   same as B7's `RiskSizing_ValidateInput`).
2. Copy all 12 Phase B1 feature fields verbatim from `ctx` — no
   recomputation, no live indicator read, no `TimeCurrent()`,
   `iATR`/`iADX`/`iMA`, or any other broker/history call anywhere in
   this function. `ctx` already carries these as a frozen snapshot
   (built once, at candidate-creation time, by the existing B1-B5
   `FeatureEngine`/`MarketContext` pipeline) — this function only
   copies, it never derives.
3. Set `context_event_id = ctx.context_event_id`,
   `feature_schema_version = MLQUANTAI_FEATURE_SCHEMA_V1` (unchanged
   from `FeatureSnapshot_Init`'s own default).
4. Set `candidate_id = candidate.candidate_id`, `candidate_hash =
   candidate.candidate_hash`, `context_hash = candidate.context_hash`.
5. Compute `feature_snapshot_id = Ids_FeatureSnapshotId(candidate.candidate_id)`.
6. Compute `feature_vector_hash` LAST, over the finished struct — same
   "hash the finished object" convention every other hash in this
   project follows.
7. Return `true`. No event append, no broker/order/history call, no
   mutation of `candidate` or `ctx` (both passed `const &`).

This is deliberately NOT where any real feature engineering happens —
every value already exists on `ctx`; this function's only job is
establishing identity/lineage/hash over what B1-B5 already computed.
Real feature *selection*/*engineering* (which indicators, what
lookback windows, any derived ratios beyond what `MarketContext`
already carries) is explicitly a B8.2+ concern, not this contract's.

## 5. Leakage boundary / determinism (binding on every B8 phase, restated here for B8.1's own scope)

- A `FeatureSnapshot` is a pure function of one `(TradeCandidate,
  MarketContext)` pair, at the bar-time that candidate was created —
  never of "now." Nothing in `Candidate_ToFeatureSnapshot` reads
  current price, current indicator state, or `TimeCurrent()`.
- Replay restores a persisted `FeatureSnapshot`'s fields verbatim; it
  never recomputes them from a fresh `MarketContext` (once B8.5/B8.6
  add persistence/replay — out of scope for B8.1 itself, which has no
  event emission at all yet, mirroring how B7 Commit 1 had no
  `RISK_PLAN_CREATED` emission either).
- AI has no authority to mutate `TradeCandidate`, `RiskPlan`, or any
  B5/B7 sealed file — unchanged from `Docs/PhaseB_Architecture_Baseline.md`,
  restated here because B8.1 is the first B8 code to actually touch
  the repo.

## 6. QA gate for B8.1 (binding on its test suite)

- Same candidate + same `MarketContext` -> identical `feature_snapshot_id`
  AND identical `feature_vector_hash`, called repeatedly -> zero
  mismatches (mirrors B7 Commit 1's 10,000-iteration determinism loop).
- `feature_snapshot_id` depends only on `candidate_id` — a different
  `MarketContext` for the SAME candidate (impossible in practice since
  `context_event_id`/`context_hash` are referential-integrity-checked,
  but exercised via two otherwise-identical candidates with different
  `candidate_id`s) still produces a different `feature_snapshot_id`.
- `feature_vector_hash` inclusion sweep: each of the 15 included
  fields, changed alone, moves the hash.
- `feature_vector_hash` exclusion whitelist: `feature_snapshot_id`,
  `feature_schema_version`, `context_event_id` changed alone do NOT
  move the hash.
- Referential integrity: a `ctx` whose `context_event_id` or
  `context_hash` doesn't match the candidate's own is rejected.
- Fail-closed: empty `candidate_id`, wrong `state`, and a NaN/Inf
  feature field (via the same `+Inf`-via-multiplication-overflow
  technique B7 Commit 1 had to use — MQL5 traps `0.0/0.0`) are all
  rejected, with `outSnapshot` left at `Init()` defaults.
- `candidate`/`ctx` parameters byte-identical before and after the
  call (no mutation).
- No event store line appended, no broker/order/history/tick call
  anywhere in the call path.

## Explicitly out of scope for B8.1

Any dataset/training export (B8.2), model registry/artifact
versioning (B8.3), inference contract (B8.4), `AI_DECISION_CREATED`
event emission (B8.5), AI projection/replay/audit (B8.6), any
ONNX/model file, any change to an already-sealed B5/B6/B7 production
file, any real feature engineering beyond what `MarketContext` already
computes. Each later B8 sub-phase gets its own frozen addendum when it
opens.
