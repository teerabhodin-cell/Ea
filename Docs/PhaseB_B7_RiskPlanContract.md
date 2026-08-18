# Phase B7 — RiskPlan / Deterministic Position Sizing: Contract (FROZEN)

**Status: FROZEN, before any code exists.** Written per explicit
instruction: freeze the contract before writing `Candidate_ToRiskPlan`.
This document is the B7 analogue of `Docs/PhaseB_B5_CRTContract.md` —
every implementation commit under B7 must conform to it; a genuine rule
change requires a new frozen revision (B7_V2), never a silent in-place
edit, same discipline CRT_V1 already established.

B7 opens only after B6 closed in full: B6.1 (146/146), B6.2 (75/75),
B6.3 (89/89) are all PASSED and merged to `mlquantai`. B7 must not
reopen or modify any B5/B6 sealed file except by strict, additive
extension (e.g. a new `Ids_*` function) — the same rule B6 followed
against B5.

## Scope: B7.1 – B7.5

| Sub-phase | Contents | This document covers |
|---|---|---|
| B7.1 | `RiskContext` — ownership + snapshot contract | Fully specified below |
| B7.2 | `RiskPlan` — schema + plan identity (`risk_plan_id` vs `plan_hash`) | Fully specified below |
| B7.3 | `Candidate_ToRiskPlan` — pure deterministic sizing | Fully specified below (the concrete sizing formula is THIS document's own contribution — the originating proposal specified the wrapper/schema but not an actual formula; frozen here, flagged as this project's decision, not carried over from the proposal) |
| B7.4 | `RISK_PLAN_CREATED` event emission | NOT specified here — scoped when B7.4 opens, mirroring B5 Commit 5's own late binding to Phase A's `EventStore` primitives |
| B7.5 | `RiskPlan` replay/recovery + determinism seal | NOT specified here — scoped when B7.5 opens, mirroring B6.1 |

B7 Commit 1 (the first implementation commit under this contract)
covers B7.1 + B7.2 + B7.3 together — they are one coherent,
independently-testable unit (a struct, its identity/content hash
split, and the pure function that fills it), the same granularity
B5 Commit 4 already used for `CRT_ToTradeCandidate` + its hash.

## Hard prohibitions (unchanged from B6, restated for B7)

No `ExecutionRequest`/`OrderSend`/`CTrade`. No broker position/order/
deal/account/tick/spread reads inside `Candidate_ToRiskPlan` itself —
every value it uses must already be sitting on `TradeCandidate` or
`RiskContext`, both passed in as frozen snapshots. No AI scoring. No
automatic strategy optimization. No CRT rule changes — `RiskPlan`
copies `candidate.entry_hint`/`sl_hint`/`tp_hint` verbatim as the
"planned" prices; it does not re-decide entry/exit levels, only sizes
the trade CRT_V1 already decided on.

## 1. `RiskContext`: ownership + snapshot contract (B7.1)

**`risk_context_hash` is a rules/spec snapshot hash, NOT a full
sizing-input hash — stated explicitly per Commit 1's QA review.**
`account.balance`/`account.equity` genuinely feed the sizing formula
(step 5 below) and genuinely move `plan_hash` through `risk_amount`/
`lot_size`, but they do NOT move `risk_context_hash` itself — see the
EXCLUDED list below. Two `RiskContext` values with the identical
`risk_context_hash` can legitimately produce different `RiskPlan`
outputs if their `account.balance` differs. `risk_context_hash`
answers "is this the same sizing RULE SET" (same symbol constraints,
same risk percent, same method/version) — it does NOT answer "will
this produce the same plan." Only `plan_hash` (section 3) answers
that. Do not read equal `risk_context_hash` values as a promise of
equal sizing output.

**Ownership rule, stated as a hard boundary:** `RiskContext` is built
ONCE, by a caller OUTSIDE `Candidate_ToRiskPlan`, from live
`AccountInfoDouble`/`SymbolInfoDouble` reads — exactly the same
"captured once, reused everywhere downstream" discipline
`AccountSnapshot`/`SymbolSpec` already established in Phase A/B2. Any
`AccountInfoDouble(...)`/`SymbolInfoDouble(...)`/`TimeCurrent(...)`
call found inside `Candidate_ToRiskPlan` itself is a contract
violation — that function must be a pure function of its two
parameters (`TradeCandidate`, `RiskContext`) and nothing else.

**Struct — reuses the two structs that already are this project's
"live state captured once" primitive, rather than re-declaring their
fields:**

```cpp
struct RiskContext
{
   string risk_context_schema_version;
   string risk_context_hash;

   AccountSnapshot account;      // Phase A struct, unchanged, embedded verbatim
   SymbolSpec      symbol_spec;  // Phase B B2 struct, unchanged, embedded verbatim

   double target_risk_percent;   // the account's configured risk-per-trade, e.g. 1.0 == 1%
   string sizing_method;         // e.g. "FIXED_PERCENT_RISK" (B7.3's only method for now)
   string sizing_rules_version;  // frozen version tag, same role MLQUANTAI_CRT_V1_RULES_VERSION plays for CRT
};
```

**`risk_context_hash` payload — INCLUDED** (mirrors
`MarketContext_HashPayload`'s own inclusion/exclusion split exactly):

`symbol_spec.instrument_id`, `symbol_spec.broker_symbol`,
`symbol_spec.tick_size`, `symbol_spec.tick_value`,
`symbol_spec.contract_size`, `symbol_spec.volume_min`,
`symbol_spec.volume_max`, `symbol_spec.volume_step`,
`symbol_spec.digits`, `target_risk_percent`, `sizing_method`,
`sizing_rules_version`.

**`risk_context_hash` payload — EXCLUDED, with reason:**

- `account.balance`, `account.equity`, and every other `AccountSnapshot`
  field — same precedent `MarketContext_HashPayload` already set for
  `account` (runtime-only, must not move an identity/content hash).
  This is what makes the QA-requested gate possible at all: *"balance
  เปลี่ยน → risk_amount/lot_size/plan_hash เปลี่ยน แต่ risk_plan_id ไม่เปลี่ยน"*
  — balance's effect reaches `plan_hash` only indirectly, through the
  `risk_amount`/`lot_size` it produces, never by being hashed directly.
- `symbol_spec.currency_base`/`currency_profit`/`currency_margin`,
  `symbol_spec.trade_mode`, `symbol_spec.stops_level_points`,
  `symbol_spec.freeze_level_points`, `symbol_spec.context_schema_version`,
  `symbol_spec.symbol_spec_schema_version`, `symbol_spec.symbol`,
  `symbol_spec.point` — not sizing-relevant (`tick_size`/`tick_value`
  already fully determine the money-per-point-per-lot relationship;
  `point` is a display/precision concern the canonical formatters
  below make irrelevant to any hash, per the `_Digits` prohibition).
- `risk_context_schema_version`, `risk_context_hash` itself — same
  "derived from, not part of" exclusion every other hash in this
  project already applies to its own identity/schema fields.

## 2. Canonical numeric serialization (applies to every B7 hash)

**Hard rule, binding on all of B7.1–B7.5:** no hash payload may ever
call `DoubleToString(x, Digits())`, `DoubleToString(x, _Digits)`,
`Digits()`, or `_Digits` — those read the ACTIVE CHART's symbol/digits
at call time, not a value carried on the object being hashed, so the
same `RiskContext`/`RiskPlan` content could hash differently depending
on which chart happened to be active when the code ran. This is
distinct from (and stricter than) `detector_hash`/`candidate_hash`'s
existing convention of taking an explicit `digits` PARAMETER sourced
from `symbol_spec.digits` — that parameter is fine (it's a value
carried on the hashed object's own lineage, not a live chart read); the
live built-ins are what's prohibited.

**Canonical formatting helpers (`Core/MLQuantAI_CanonicalFormat.mqh`,
new, this contract's own decision — precisions chosen for this file,
not carried over from any external proposal):**

```cpp
string CanonicalPrice(double x)    // DoubleToString(x, 5) - same fixed
                                     // literal precision context_hash's
                                     // own price fields already use
string CanonicalDouble(double x)   // DoubleToString(x, 8) - generic
                                     // amount/ratio/lot_size; 8 decimal
                                     // places is deliberately more than
                                     // any real lot step needs, so a
                                     // volume_step as fine as 0.001 (or
                                     // finer) never loses precision in
                                     // the hash
string CanonicalPercent(double x)  // DoubleToString(x, 4) - risk_percent/
                                     // target_risk_percent
```

Every double field in `RiskContext_HashPayload`/`RiskPlan_HashPayload`
below uses exactly one of these three — never a raw `DoubleToString`
call with a caller-supplied digit count, never `IntegerToString` on a
value that could carry a fractional component.

## 3. `RiskPlan`: schema + plan identity (B7.2)

**Identity vs. content, exactly as proposed and accepted:**

```cpp
risk_plan_id = Ids_RiskPlanId(candidate_id, sizing_rules_version);
plan_hash    = Ids_Sha256Hex(RiskPlan_HashPayload(plan));
```

`Ids_RiskPlanId` (new, additive to `Core/MLQuantAI_Ids.mqh`, same
`Ids_Deterministic("RPLAN", ...)` pattern `Ids_CandidateId` already
uses):

```cpp
string Ids_RiskPlanId(string candidateId, string sizingRulesVersion)
{
   string key = candidateId + "|" + sizingRulesVersion;
   return Ids_Deterministic("RPLAN", key);
}
```

`risk_plan_id` deliberately does NOT depend on `risk_context_hash`,
`balance`, `equity`, or any computed sizing output — same candidate +
same `sizing_rules_version` always produces the same `risk_plan_id`,
regardless of what the account looked like when it was computed. This
is what lets a later phase (B7.5, or B8's risk-contract auditing)
detect "same identity, different content" as a genuine drift signal
rather than a normal identity change.

### `RiskPlan` already exists (Phase A) — this is an ADDITIVE extension, not a new struct

`Core/MLQuantAI_RiskPlan.mqh` already defines `RiskPlan` (`decision`/
`allowed`/`lot`/`risk_money`/`risk_percent`/`reject_reason`/
`risk_schema_version`) and `Core/MLQuantAI_RiskDecision.mqh`'s own
comment already named this exact moment: *"RiskDecision is the AUDIT
record; RiskPlan is the SIZING output for one that passed. B7
reconciles how the two relate when the Risk Manager is built."*
Neither the original proposal nor its follow-up accounted for this —
both described a struct also named `RiskPlan` with a materially
different shape, which would either fail to compile (duplicate type)
or silently duplicate the concept under one name.

**Resolution: extend the existing sealed struct additively.** Every
existing field stays exactly as it is — same discipline every other
phase in this project has applied to every prior sealed file. New
fields are added alongside them. `Candidate_ToRiskPlan` (B7.3) fills
BOTH the existing fields and the new ones from the same computation,
which is what actually reconciles the two: the pure sizing function's
output IS what belongs in `lot`/`risk_money`/`decision`/`allowed`/
`reject_reason` — there was never a second, competing answer to what
those fields should hold, just a Phase A placeholder waiting for B7 to
exist.

```cpp
struct RiskPlan
{
   // --- Phase A, sealed, UNCHANGED ---
   ENUM_RISK_DECISION  decision;
   bool                allowed;
   double              lot;
   double              risk_money;
   double              risk_percent;
   ENUM_REASON_CODE    reject_reason;
   string              risk_schema_version;

   // --- Phase B7, additive ---
   string risk_plan_schema_version;
   string risk_plan_id;
   string candidate_id;
   string candidate_hash;      // copied verbatim from TradeCandidate - never recomputed
   string risk_context_hash;   // copied verbatim from RiskContext - never recomputed

   double planned_entry;       // copied verbatim from candidate.entry_hint
   double planned_sl;          // copied verbatim from candidate.sl_hint
   double planned_tp;          // copied verbatim from candidate.tp_hint

   double stop_distance_points;
   double rr_ratio;

   double risk_amount;         // same value as risk_money, kept both to leave the old field untouched
   double lot_size;            // same value as lot, kept both to leave the old field untouched

   string sizing_method;       // copied verbatim from RiskContext.sizing_method
   string sizing_rules_version;// copied verbatim from RiskContext.sizing_rules_version

   string plan_hash;
};
```

`risk_money`/`lot` and `risk_amount`/`lot_size` are deliberately kept
as two names for the same value rather than picking one — the old
names stay because Phase A code (however dormant) was written against
them; the new names stay because they match `plan_hash`'s own payload
vocabulary and the B7.3 formula's own working names. A future commit
that finds a real consumer of one or the other can collapse this once
it's no longer a guess.

**`risk_money`/`lot` are compatibility shadow fields, not the
canonical source of truth — stated explicitly per Commit 1's QA
review.** `risk_amount`/`lot_size` are what `Candidate_ToRiskPlan`
actually computes and what `plan_hash` actually hashes;
`risk_money`/`lot` are copies written alongside them purely so Phase
A's original field names keep resolving to the right value if
anything ever reads them. Any future code with a choice of which pair
to read or write should read/write `risk_amount`/`lot_size` — treat
`risk_money`/`lot` as a legacy alias to be collapsed once a real
consumer of one or the other exists, never as a second place to
independently set a value from.

On a **fail-closed** path (B7.3's validation steps below), the
function still returns `false`/leaves `outPlan` at `RiskPlan_Init()`
defaults — it does NOT set `allowed=false`/`decision=RISK_DECISION_BLOCK`
on a half-filled struct with everything else still populated. A
rejected plan is a rejected plan; it doesn't get a `plan_hash` or an
`risk_plan_id` either, matching the "no partial output" rule every
other B5/B6 mapping function already follows.

**`plan_hash` payload — exact field order** (adopts the proposal's
list, corrected per its own follow-up: `lot_size` IS included — an
earlier draft omitted it, which would have let two plans with
different `lot_size` hash identically, exactly the silent-drift risk
the follow-up correctly flagged):

`candidate_id`, `candidate_hash`, `risk_context_hash`, `planned_entry`,
`planned_sl`, `planned_tp`, `stop_distance_points`, `rr_ratio`,
`risk_percent`, `risk_amount`, `lot_size`, `sizing_method`,
`sizing_rules_version`.

**Excluded from `plan_hash`, with reason:** `risk_plan_schema_version`/
`risk_plan_id` (derived-from/identity, not content, same exclusion
every other hash in this project applies to its own identity fields);
`decision`/`allowed`/`reject_reason`/`risk_schema_version`/`lot`/
`risk_money` (the Phase A fields — duplicates of values already in the
payload under their B7 names, hashing both would be redundant, same
"don't hash the same thing twice" rule this project has used
consistently since B2); debug text, labels, timestamps, QA notes,
runtime counters (no such fields exist on this struct at all, so
there's nothing to accidentally include).

## 4. `Candidate_ToRiskPlan`: the sizing formula (B7.3)

**This section is this contract's own decision, not present in the
originating proposal** — the proposal specified the schema and hash
wrapper but not a concrete formula. Frozen here as a standard,
industry-common fixed-fractional-risk sizing method, chosen for being
simple, fully deterministic, and expressible purely from values already
on `TradeCandidate`/`RiskContext` (no new broker calls).

```cpp
bool Candidate_ToRiskPlan(const TradeCandidate &candidate, const RiskContext &ctx, RiskPlan &outPlan);
```

**Steps, in order:**

1. **Validate input.** Fail closed (return `false`, `outPlan` left at
   `RiskPlan_Init()` defaults) on any of:
   - `candidate.candidate_id == ""` or `candidate.state != CANDIDATE_CREATED`
     (a non-candidate has nothing to size).
   - `candidate.entry_hint`/`sl_hint`/`tp_hint` not
     `MathIsValidNumber` (NaN/Inf), or any of them `<= 0`.
   - `ctx.symbol_spec.tick_size <= 0`, `ctx.symbol_spec.tick_value <= 0`,
     or `ctx.symbol_spec.volume_step <= 0` (a broken/unresolved symbol
     spec must never silently produce a lot size).
   - `ctx.target_risk_percent <= 0` or not `MathIsValidNumber`.
   - `ctx.account.balance <= 0` (sizing against a non-positive balance
     is meaningless, not "small").
   - SL/TP ordering doesn't match `candidate.side` — same frozen rule
     `CandidateProjection_ValidateNumericalIntegrity` already enforces:
     BUY needs `sl_hint < entry_hint < tp_hint`; SELL needs
     `sl_hint > entry_hint > tp_hint`.
2. **Copy planned prices verbatim** — `planned_entry`/`planned_sl`/
   `planned_tp` = `candidate.entry_hint`/`sl_hint`/`tp_hint`, unchanged.
   B7 never adjusts CRT's own entry/exit decision.
3. **Stop distance, in points, broker-agnostic:**
   `stop_distance_points = MathAbs(planned_entry - planned_sl) / ctx.symbol_spec.tick_size`.
   Fail closed if this is `<= 0` (only possible if `entry == sl`,
   already excluded by step 1's ordering check, kept here as a second,
   independent guard).
4. **Reward/risk ratio** (price-distance ratio — dividing two price
   distances by the same `tick_size` cancels out, so this needs no
   unit conversion): `rr_ratio = MathAbs(planned_tp - planned_entry) / MathAbs(planned_entry - planned_sl)`.
5. **Risk amount:** `risk_amount = ctx.account.balance * (ctx.target_risk_percent / 100.0)`.
6. **Raw lot size:** `raw_lot = risk_amount / (stop_distance_points * ctx.symbol_spec.tick_value)`
   — `tick_value` is MT5's own `SYMBOL_TRADE_TICK_VALUE`, already the
   monetary value of one tick move for 1.0 lot (contract size and
   currency conversion already folded in by the terminal), so no
   separate contract-size multiplication is needed.
7. **Round DOWN to the nearest `volume_step`** (never round up — that
   would silently risk more than `target_risk_percent` asked for):
   `stepped_lot = MathFloor(raw_lot / ctx.symbol_spec.volume_step) * ctx.symbol_spec.volume_step`.
8. **Clamp/reject against broker limits.** If
   `stepped_lot < ctx.symbol_spec.volume_min`: **fail closed** (return
   `false`) — the candidate's stop distance is too wide for the
   account's configured risk at the broker's minimum lot; silently
   bumping up to `volume_min` would silently exceed the configured
   risk, which this contract treats as a genuine rejection, not a
   roundable edge case. If `stepped_lot > ctx.symbol_spec.volume_max`:
   clamp down to `volume_max` (the opposite direction is safe — it
   only ever reduces risk below the target, never exceeds it) and
   proceed.
9. **Fill the rest of the struct** — both vocabularies at once, same
   values: `risk_percent` = `ctx.target_risk_percent` (B7 field) AND
   Phase A's own `risk_percent` (already the same field name, no
   duplication needed there); `lot_size` = `stepped_lot` AND `lot` =
   `stepped_lot`; `risk_amount` = the computed amount AND `risk_money`
   = the same value; `sizing_method`/`sizing_rules_version` copied from
   `ctx`; `risk_plan_id` via `Ids_RiskPlanId`; `candidate_hash`/
   `risk_context_hash` copied verbatim; Phase A's `decision` =
   `RISK_DECISION_ALLOW`, `allowed` = `true`, `reject_reason` =
   `REASON_NONE`. Compute `plan_hash` LAST, over the finished struct —
   same "hash the finished object" convention every other hash in this
   project follows.
10. Return `true`. No event append, no broker/order/history call, no
    mutation of `candidate` or `ctx` (both passed `const &`). On any
    fail-closed path in steps 1/3/8 above, `outPlan` stays at
    `RiskPlan_Init()` defaults — including Phase A's own defaults
    (`decision = RISK_DECISION_NONE`, `allowed = false`) — the function
    does NOT set `decision = RISK_DECISION_BLOCK` with a reject reason
    on a rejection; a rejected candidate simply gets no plan at all
    from this pure function, matching every other B5/B6 "no partial
    output" mapping rule. (A future Risk Manager phase, per
    `RiskDecision`'s own stated role, is what would record WHY a
    candidate was rejected as an audit trail — not B7.3's job.)

## 5. QA gate for B7.3 (binding on its test suite)

- Same candidate + same `RiskContext` → identical `risk_plan_id` AND
  identical `plan_hash`, called **10,000 times** in a tight loop (this
  count is honored as literally requested — unlike B6's event-store
  tests, `Candidate_ToRiskPlan` is a pure in-memory function with no
  file I/O per call, so 10,000 iterations is cheap, not a scaled-down
  compromise) → **zero mismatches**.
- Different `account.balance` (same everything else) → `risk_amount`/
  `lot_size`/`plan_hash` change; `risk_plan_id` and `risk_context_hash`
  do NOT change.
- Different `symbol_spec.volume_step`/`tick_size`/`tick_value` (same
  everything else) → `lot_size`/`plan_hash`/`risk_context_hash` all
  change (these ARE part of `risk_context_hash`'s payload).
- Different `sizing_rules_version` (same everything else) →
  `risk_plan_id` changes (it's a `risk_plan_id` input) AND
  `risk_context_hash`/`plan_hash` change too.
- `candidate_hash`/`risk_context_hash` on the output always equal the
  exact input values — never recomputed, never drifted.
- `candidate`/`ctx` parameters byte-identical before and after the
  call (no mutation).
- No event store line appended, no `OrderSend`/`CTrade`/position/
  history/tick call anywhere in the call path.
- Every fail-closed case in section 4 step 1/3/8 verified: NaN/Inf,
  non-positive price, wrong-side SL/TP ordering, non-positive
  `tick_size`/`tick_value`/`volume_step`, non-positive `balance`/
  `target_risk_percent`, and a stop distance so wide the rounded lot
  falls below `volume_min`.

## Explicitly out of scope for B7 Commit 1

`RISK_PLAN_CREATED` event emission (B7.4), replay/projection/recovery
(B7.5), any broker-facing execution, any AI scoring, any change to
CRT_V1's own entry/exit decision. B7.4/B7.5 will each get their own
frozen addendum (or a `B7_V2` revision of this document) when they
open, mirroring exactly how B5 Commits 3/4/5 each built on one shared
contract without needing to re-litigate it.

---

# Addendum — B7 Commit 2: `RISK_PLAN_CREATED` event + `RiskPlanProjection` (B7.4 + B7.5)

**Status: FROZEN, before any code exists.** Written the moment B7
Commit 1 was confirmed PASSED (98/98) and Commit 2 was confirmed to
proceed. Mirrors B5 Commit 5 (`CRT_EmitCandidateCreated`) for
emission and B6.1 (`CandidateProjection`) for replay/projection —
both already sealed, both already hardened through a real adversarial
QA pass. This addendum does not re-derive those patterns from
scratch; it maps them onto `RiskPlan`.

## Why `RISK_PLAN_CREATED` is a `SystemEvent`, not a `LifecycleEvent`

`CANDIDATE_CREATED` reuses `LifecycleEvent` because a candidate
genuinely IS a lifecycle state machine (`from_state`/`to_state`,
tracked by `StateProjector`). A `RiskPlan` is not a candidate state
transition — it's a derived artifact tied to one candidate, the same
relationship `MarketContext` has to the candidate that later
references it via `context_event_id`. `RISK_PLAN_CREATED` therefore
follows `MARKET_CONTEXT_READY`'s precedent: a `SystemEvent`
(`EventStore_LogSystem`), with every `RiskPlan` field flattened into
`extra_json` as top-level JSON keys (not nested), read back later via
plain `EventSerializer_GetStr`/`GetDouble`/`GetLong` calls on the raw
line — exactly how `CandidateDatasetExport` already reads
`MARKET_CONTEXT_READY` fields, and exactly how `CandidateProjection`
already reads `CANDIDATE_CREATED`'s `extra_json` fields.

## Event type

`Core/MLQuantAI_Enums.mqh` (additive, Phase A's sealed `ENUM_EVENT_TYPE`
extended the same way B7 Commit 1 extended `RiskPlan`): a new
`EVENT_TYPE_RISK_PLAN_CREATED` value appended after the candidate
lifecycle block, with `EventTypeToString`/`EventTypeFromString` cases
added — never inserted before an existing value (would silently
renumber every later enum constant across a running system's
persisted event history), always appended at the end of its
logical section.

## `RISK_PLAN_CREATED`'s `extra_json` — every `RiskPlan` field, both groups

The full struct as it exists after B7 Commit 1: `risk_plan_id`,
`candidate_id`, `candidate_hash`, `risk_context_hash`,
`planned_entry`/`planned_sl`/`planned_tp`, `stop_distance_points`,
`rr_ratio`, `risk_percent`, `risk_amount`, `lot_size`, `sizing_method`,
`sizing_rules_version`, `plan_hash`, `risk_plan_schema_version`. The
Phase A shadow fields (`lot`, `risk_money`, `decision`, `allowed`,
`reject_reason`, `risk_schema_version`) are NOT separately persisted —
they're always recoverable from the B7 fields already in the event
(`lot == lot_size`, `risk_money == risk_amount`, and a
`RISK_PLAN_CREATED` event only ever exists for an ALLOWED plan in the
first place, so `decision`/`allowed`/`reject_reason` are implied, not
ambiguous). This mirrors B6.1's own precedent: `CandidateProjectionRecord`
doesn't persist fields nothing durably needs a second copy of.

## Live emission: `RiskPlan_EmitRiskPlanCreated` (B7.4)

```cpp
bool RiskPlan_EmitRiskPlanCreated(const RiskPlan &p);
```

Mirrors `CRT_EmitCandidateCreated` exactly:

1. Returns `false` (no write attempted) if `p.risk_plan_id == ""` or
   `!p.allowed` — a rejected/unfilled plan emits no event, same as a
   non-detection candidate emits nothing.
2. Checks `RiskPlanProjection_TryGet(p.risk_plan_id, existing)` — a
   **live, in-session, coarse guard**: if this `risk_plan_id` already
   has ANY record (regardless of `plan_hash`), returns `false`,
   nothing written. This is deliberately the SAME coarseness
   `CRT_EmitCandidateCreated`'s `StateProjector_TryGetState` guard
   uses — the finer duplicate-vs-collision distinction (comparing
   `plan_hash`) is the REPLAY/PROJECTION layer's job
   (`RiskPlanProjection_ApplyLine`), not emission's, exactly
   preserving the division of responsibility B6.1 already established
   for candidates.
3. Builds `extra_json` via `RiskPlan_ToExtraJson(p)`, appends via
   `EventStore_LogSystem(EventTypeToString(EVENT_TYPE_RISK_PLAN_CREATED), "risk plan created", extraJson)`.
4. On a successful durable write, applies the equivalent record
   directly to `RiskPlanProjection`'s live in-memory registry —
   the SAME fix B5 Commit 5 needed for `StateProjector` (without it,
   two same-session emit calls for the same `risk_plan_id`, before any
   replay, would both see an empty registry and both durably write a
   duplicate genesis event).
5. Returns `true`.

No referential-integrity check against `CandidateProjection` happens
at emission time — same "trust the caller, verify independently on
replay" split B5/B6.1 already use (emission just durably writes what
it's given; `RiskPlanProjection_RebuildFromFile`, below, is where
integrity is independently re-derived from the persisted store).

## Replay/projection: `RiskPlanProjection` (B7.5)

`RiskPlanProjectionRecord`: every `RiskPlan` field above, plus
`source_sequence_number`/`source_log_event_id` (audit trail — which
event this record came from, same fields `CandidateProjectionRecord`
already carries).

`RiskPlanProjection_ApplyLine(line, &outReason) -> bool` — mirrors
`CandidateProjection_ApplyLine`'s exact validation ladder:

1. Line-length defensive bound.
2. Type-gate: `EventSerializer_HasKey(line, "type") && GetStr(line, "type") != "RISK_PLAN_CREATED"` →
   skip as irrelevant (the exact two-part gate B6.1's hardening pass
   fixed after finding both failure modes for real — a bare `GetStr`
   check alone misclassifies a line with no `type` key at all as
   "irrelevant" instead of failing closed).
3. `EventSerializer_ParseSystem` (requires `HasKey(line, "seq")`) — a
   line that fails this is "not a parsable event line", rejected.
4. Required-field presence: `risk_plan_id`, `candidate_id`,
   `candidate_hash`, `risk_context_hash`, `plan_hash`,
   `sizing_method`, `sizing_rules_version` all non-empty.
5. Numerical integrity: `planned_entry`/`planned_sl`/`planned_tp`/
   `stop_distance_points`/`rr_ratio`/`risk_percent`/`risk_amount`/
   `lot_size` all `MathIsValidNumber` and non-negative (`rr_ratio`
   can legitimately be very small but never negative or NaN/Inf);
   `stop_distance_points > 0`, `lot_size > 0`.
6. **Referential integrity against `CandidateProjection`** (the new
   piece this addendum adds, requested explicitly): the referenced
   `candidate_id` must exist in `CandidateProjection`'s own registry
   (already rebuilt from the SAME file — see
   `RiskPlanProjection_RebuildFromFile` below), and its
   `candidate_hash` must equal the line's own `candidate_hash`.
   Missing → **orphan candidate**, rejected. Mismatched → **candidate
   hash mismatch**, rejected. Both fail closed, same as B6.1's own
   orphan-context/context-hash-mismatch checks.
7. **Collision-vs-duplicate** (payload-aware, same rule B6.1 already
   proved out for `candidate_id`/`candidate_hash`): `risk_plan_id`
   already registered with an IDENTICAL `plan_hash` → duplicate,
   idempotent no-op, returns `true`. Already registered with a
   DIFFERENT `plan_hash` → **collision**, rejected, returns `false` —
   never silently treated as a duplicate, since that would hide a
   genuine `risk_plan_id` collision or data corruption.

`RiskPlanProjection_RebuildFromFile(fileName) -> RiskPlanProjectionReport`:

1. `EventStoreValidator_ValidateLines` first — any malformed/
   out-of-order/truncated line anywhere in the WHOLE file (not just
   `RISK_PLAN_CREATED` lines) refuses the entire rebuild, registry
   left completely untouched. Same atomicity guarantee B6.1
   established, applied here too.
2. `CandidateProjection_RebuildFromFile(fileName)` — rebuilt from the
   SAME file, as a prerequisite step. If that fails, THIS rebuild also
   fails closed (a `RiskPlan` registry can't be trusted if the
   candidate registry it references can't be trusted). This is a
   deliberate, flagged dependency: `RiskPlanProjection` depends on
   `CandidateProjection` being rebuilt from the same file immediately
   before it, the same dependency direction `CandidateDatasetExport`
   (B6.2) already has on `CandidateProjection`.
3. Reset `RiskPlanProjection`'s own registry, apply every line via
   `RiskPlanProjection_ApplyLine`, referential-integrity-checked
   against the now-current `CandidateProjection` registry.

## QA gate for B7 Commit 2 (binding on its test suite)

- A valid `RiskPlan` emits exactly one `RISK_PLAN_CREATED` event.
- Re-emitting the identical plan (same `risk_plan_id`, same
  `plan_hash`) live, same session, is a no-op (no second event
  written) — the `RiskPlanProjection`-live-sync guard, mirroring B5
  Commit 5's `StateProjector` fix.
- On replay: same `risk_plan_id` + same `plan_hash` → duplicate,
  idempotent no-op. Same `risk_plan_id` + DIFFERENT `plan_hash` →
  collision, rejected, registry unchanged for that record.
- A `RISK_PLAN_CREATED` line referencing a `candidate_id` with no
  matching `CANDIDATE_CREATED` anywhere in the file → orphan,
  rejected, whole rebuild fails closed.
- A `RISK_PLAN_CREATED` line whose `candidate_hash` doesn't match the
  referenced candidate's own `candidate_hash` in the registry →
  mismatch, rejected, whole rebuild fails closed.
- A truncated/malformed line anywhere in the file (even one unrelated
  to any `RiskPlan`) blocks the ENTIRE rebuild — registry left at
  last-known-good state, never partial.
- Replaying the same store repeatedly (restart/crash simulation)
  reconstructs byte-identical `RiskPlanProjectionRecord`s every time.
- A store with candidates from multiple sessions (multiple
  `session_id`s) rebuilds correctly, same as B6.1's multi-session
  test.
- Every field on a rebuilt `RiskPlanProjectionRecord` matches the
  original `RiskPlan` that was emitted, exactly — no drift.
