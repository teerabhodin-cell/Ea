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

**Revision note (same day, before any code written):** this freeze
was reviewed once and three points were revised in response — a
B8.1-specific schema version value (not a second field, the existing
`feature_schema_version` field just gets a new, more specific
constant), an added `detector_hash` lineage field, and a two-hash
split (`feature_vector_hash` for pure ML-input content,
`feature_snapshot_hash` for the full identity+lineage+content record).
Revising a frozen doc before any implementing code exists is the same
allowance already used once during B7's own kickoff (the RiskPlan
draft was revised before Commit 1 code was written) — a genuine
in-place edit after code exists would instead require a new frozen
revision (`B8.1_V2`), never a silent edit.

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
exactly as it is, unchanged, in meaning. No generic `feature_values`
map is introduced — B8.1 keeps the codebase's established convention
of fixed, named, typed fields (`CandidateProjectionRecord`,
`RiskPlan`, `RiskContext` all do the same). New fields are added
alongside for B8.1's identity/lineage/hash needs.
`Candidate_ToFeatureSnapshot` (this contract's own algorithmic
contribution, mirroring how `Candidate_ToRiskPlan` was B7's own
contribution) fills both field groups from one computation.

**Schema version: `feature_schema_version` stays the only schema
field on the struct — no second field — but a snapshot actually
produced by `Candidate_ToFeatureSnapshot` carries a new, B8.1-specific
constant, not the old generic one.** The field's ROLE was always
"schema version marker"; what changes here is which constant a real,
populated `FeatureSnapshot` actually carries. Reasoning: this field
must let a future model registry (B8.3) answer "was this model trained
against the same canonical ML input contract this inference is
running against" — a materially different question than "which
indicator-field shape does this stub struct have," which is all the
dormant Phase B1 constant ever meant. A single reused generic string
across a dormant stub and a live ML contract would make that
compatibility question ambiguous going forward.

```cpp
// Core/MLQuantAI_ContractVersions.mqh (additive)
#define MLQUANTAI_FEATURE_SCHEMA_B8_1_V1   "FEATURES_B8_1_V1"
```

`MLQUANTAI_FEATURE_SCHEMA_V1` ("FEATURES_V1") is untouched and keeps
its existing role as `FeatureSnapshot_Init()`'s default — **not**
changed to the new constant. Here's why this matters and isn't just a
cosmetic choice: `Tests/MLQuantAI_Test_PhaseBContracts.mq5` (a sealed
Phase B1 test) already asserts `FeatureSnapshot_Init()` stamps
`MLQUANTAI_FEATURE_SCHEMA_V1`. Changing `Init()`'s default would
regress that sealed test. Instead, `Candidate_ToFeatureSnapshot`
itself overwrites `feature_schema_version` with
`MLQUANTAI_FEATURE_SCHEMA_B8_1_V1` on a successful build (see section
4, step 3) — the exact same `Init()`-defaults-generic /
populate-function-sets-the-real-value split `RiskPlan_Init()` (defaults
`decision = RISK_DECISION_NONE`) vs. `Candidate_ToRiskPlan()` (sets
`RISK_DECISION_ALLOW` on success) already established. No sealed file
is touched.

## 1. `FeatureSnapshot` — final struct

```cpp
struct FeatureSnapshot
{
   // Phase B1 fields - UNCHANGED, same meaning
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
   string   context_hash;          // copied verbatim from the candidate's own context_hash
   string   detector_hash;         // copied verbatim from the candidate's own detector_hash - full provenance depth, not just one hop
   string   feature_vector_hash;   // pure ML-input content hash - see section 3
   string   feature_snapshot_hash; // full record hash (identity+lineage+content) - see section 3
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
shadow-field decision) for zero new information — if a future need
arises to validate a temporal cutoff, that's a validator-side
candidate/context anchor comparison, not a new stored field.

`context_event_id` is unchanged from Phase B1 (still present, still
excluded from `feature_vector_hash` — see section 3).

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

## 3. Two hashes: `feature_vector_hash` (pure content) and `feature_snapshot_hash` (full record)

Unlike `RiskPlan` (one hash, `plan_hash`, covering lineage + content
together), `FeatureSnapshot` splits this into two, because an ML
feature vector has a use case `RiskPlan` never needed: recognizing
"the same feature vector" independent of which candidate produced it
(dataset dedup, inference-cache hits, leakage checks between train/test
splits — a `RiskPlan`'s sizing output was never meaningfully
"the same" across two different candidates, so B7 never needed this
split).

### 3a. `feature_vector_hash` — pure ML-input content, no lineage

```cpp
string FeatureSnapshot_VectorHashPayload(const FeatureSnapshot &f)
{
   string s = "";
   s += f.feature_schema_version + "|";
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

string FeatureSnapshot_ComputeVectorHash(const FeatureSnapshot &f)
{
   return Ids_Sha256Hex(FeatureSnapshot_VectorHashPayload(f));
}
```

**INCLUDED** (13 fields): `feature_schema_version` — deliberately
included here (unlike `risk_plan_schema_version`'s exclusion from
`plan_hash`) so that the SAME raw numeric values under a DIFFERENT
schema shape hash differently, which is exactly what a model-registry
compatibility check needs — plus all 12 Phase B1 feature fields
(`atr_m15` through `is_kill_zone`).

**EXCLUDED**: every lineage/identity field —
`feature_snapshot_id`/`candidate_id`/`candidate_hash`/`context_hash`/
`detector_hash`/`context_event_id`. None of these describe the ML
input vector's content; they describe where it came from, which is
`feature_snapshot_hash`'s job.

### 3b. `feature_snapshot_hash` — full record: identity + lineage + content

```cpp
string FeatureSnapshot_HashPayload(const FeatureSnapshot &f)
{
   string s = "";
   s += f.feature_snapshot_id + "|";
   s += f.candidate_id + "|";
   s += f.candidate_hash + "|";
   s += f.context_event_id + "|";
   s += f.context_hash + "|";
   s += f.detector_hash + "|";
   s += f.feature_schema_version + "|";
   s += f.feature_vector_hash;
   return s;
}

string FeatureSnapshot_ComputeHash(const FeatureSnapshot &f)
{
   return Ids_Sha256Hex(FeatureSnapshot_HashPayload(f));
}
```

**INCLUDED** (8 fields, in this exact order): `feature_snapshot_id`,
`candidate_id`, `candidate_hash`, `context_event_id`, `context_hash`,
`detector_hash`, `feature_schema_version`, `feature_vector_hash`.
`feature_snapshot_id` is included even though it's fully derivable
from `candidate_id` alone (`Ids_FeatureSnapshotId(candidate_id)`) —
a deliberate, harmless redundancy (unlike `RiskPlan`'s `lot`/
`risk_money`, this doesn't create a second, independently-settable
source of truth; `feature_snapshot_id` can never disagree with what
`candidate_id` implies, so there is no drift risk to guard against).
Composing this hash by concatenating `feature_vector_hash` itself
(rather than re-listing all 12 raw feature values) keeps the two
hashes' payloads from duplicating the same raw numbers twice.

**EXCLUDED**: nothing — this is the "full record" hash, it is meant
to change if literally anything on the struct changes.

Both hashes are computed LAST, over the finished struct, in the order
`feature_vector_hash` then `feature_snapshot_hash` (the latter depends
on the former's value) — same "hash the finished object" convention
every other hash in this project follows.

Canonical numeric formatting reuses `Core/MLQuantAI_CanonicalFormat.mqh`
exactly as B7 does — `CanonicalPrice` for actual price levels (`pdh`/
`pdl`/`asian_range_high`/`asian_range_low`, 5 decimals, matching how
`context_hash`'s own payload formats these same fields), `CanonicalDouble`
for the non-price doubles (8 decimals). No `Digits()`/`_Digits` in
this path, same hard rule as every other hash in this project.

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
   `feature_schema_version = MLQUANTAI_FEATURE_SCHEMA_B8_1_V1` —
   **overwriting** `FeatureSnapshot_Init()`'s generic
   `MLQUANTAI_FEATURE_SCHEMA_V1` default with the B8.1-specific
   constant. This is the one field `Init()` sets one way and this
   function sets another, deliberately (see the schema-version
   section above).
4. Set `candidate_id = candidate.candidate_id`, `candidate_hash =
   candidate.candidate_hash`, `context_hash = candidate.context_hash`,
   `detector_hash = candidate.detector_hash` — all four copied
   verbatim, never recomputed.
5. Compute `feature_snapshot_id = Ids_FeatureSnapshotId(candidate.candidate_id)`.
6. Compute `feature_vector_hash` (section 3a), then
   `feature_snapshot_hash` (section 3b, depends on `feature_vector_hash`).
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
- No future/outcome/execution field of any kind belongs on this
  struct or in either hash's payload — no fill price, no P/L, no
  execution status. `FeatureSnapshot` is strictly an input-side
  artifact.
- AI has no authority to mutate `TradeCandidate`, `RiskPlan`, or any
  B5/B7 sealed file — unchanged from `Docs/PhaseB_Architecture_Baseline.md`,
  restated here because B8.1 is the first B8 code to actually touch
  the repo.

## 6. QA gate for B8.1 (binding on its test suite)

- Same candidate + same `MarketContext` -> identical
  `feature_snapshot_id`, `feature_vector_hash`, AND
  `feature_snapshot_hash`, called repeatedly (10,000 iterations,
  mirroring B7 Commit 1's determinism loop) -> zero mismatches.
- `feature_snapshot_id` depends only on `candidate_id`.
- `feature_vector_hash` inclusion sweep: `feature_schema_version` and
  each of the 12 feature fields, changed alone, moves
  `feature_vector_hash` (and therefore `feature_snapshot_hash` too,
  since the latter includes the former).
- Lineage-only mutation sweep: changing any of `candidate_id`,
  `candidate_hash`, `context_event_id`, `context_hash`,
  `detector_hash` alone moves `feature_snapshot_hash` but does **NOT**
  move `feature_vector_hash` — the core property the two-hash split
  exists to prove.
- `candidate_hash`, `context_hash`, `detector_hash` are copied
  verbatim from the candidate, never recomputed independently inside
  `Candidate_ToFeatureSnapshot`.
- A different `candidate_id` (all else equal) changes both
  `feature_snapshot_id` and `feature_snapshot_hash`.
- Referential integrity: a `ctx` whose `context_event_id` or
  `context_hash` doesn't match the candidate's own is rejected.
- Fail-closed: empty `candidate_id`, wrong `state`, and a NaN/Inf
  feature field (via the same `+Inf`-via-multiplication-overflow
  technique B7 Commit 1 had to use — MQL5 traps `0.0/0.0`) are all
  rejected, with `outSnapshot` left at `Init()` defaults (no partial
  output).
- `candidate`/`ctx` parameters byte-identical before and after the
  call (no mutation).
- No event store line appended, no broker/order/history/tick call
  anywhere in the call path.
- No future/outcome/execution field exists anywhere on the struct or
  in either hash payload (a structural/inspection check, same class
  as B1's own `Test_NoExecutionPathIntroduced`).

## Explicitly out of scope for B8.1

Any dataset/training export (B8.2), model registry/artifact
versioning (B8.3), inference contract (B8.4), `AI_DECISION_CREATED`
event emission (B8.5), AI projection/replay/audit (B8.6), any
ONNX/model file, any change to an already-sealed B5/B6/B7 production
file, any real feature engineering beyond what `MarketContext` already
computes. Each later B8 sub-phase gets its own frozen addendum when it
opens.
