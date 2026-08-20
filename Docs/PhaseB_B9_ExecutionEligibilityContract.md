# Phase B9 — Execution Eligibility Policy: Contract (FROZEN)

**Status: FROZEN, before any code exists.** Opens after B8.5 SEALED
(254/254, all real MetaEditor runs). Title: **the single place
`RiskPlan` (B7, sealed) + `AIDecision` (B8.5, sealed) + operational
constraints combine into `ELIGIBLE`/`REJECTED` — B9 is the last stop
before Phase C (broker execution).**

```
B7:  "Given a candidate, what deterministic size/plan does it get?"
B8.5: "Under a versioned threshold policy, does the model's output mean ALLOW or REJECT?"
B9:   "Given the plan, the AI verdict, and live operational state, is this candidate eligible to execute right now?"
C:    "Submit, respond, fill/reject, reconcile."
```

```
RiskPlan (B7, sealed)
    + AIDecision (B8.5, sealed)
    + FeatureSnapshot (B8.1, sealed - re-validated lineage only, not re-scored)
    + EligibilityContext (new - live operational state, captured once)
    + explicit, versioned EligibilityPolicy (thresholds)
        |
        v
   EligibilityDecision
        |
        v
(Commit 2, not this doc's Commit 1 scope: event emission, projection/replay,
 CANDIDATE_REJECTED_BY_RISK transition wiring)
```

B9 never rewrites B5/B7/B8 history — it only reads already-persisted
records and emits its own eligibility verdict. B9 never touches
`entry`/`sl`/`tp`/`lot_size`/`risk_amount` or any `RiskPlan`/`AIDecision`
field. B9 never talks to a broker — that stays Phase C's job
exclusively.

## Collision check (before writing anything — full findings, confirmed by the user)

- **`ENUM_RISK_DECISION`** (`RiskPlan.decision`, real B7 field — not
  dormant, `Candidate_ToRiskPlan()` actively writes `NONE`/`ALLOW` on
  the real success path; `BLOCK` is reachable only in tests today).
  **Not reused.** A different axis entirely — B7's sizing-success
  verdict, not B9's execution-eligibility verdict. `ENUM_ELIGIBILITY_DECISION`
  is a new, separate enum (below).
- **`RiskPlan`'s Phase A shadow fields** (`decision`, `allowed`, `lot`,
  `risk_money`, `reject_reason`, `risk_schema_version`) — explicitly
  excluded from `plan_hash` already (`RiskPlan_HashPayload`'s own
  documented exclusion). B9 does not write into any of these; B9's own
  verdict lives entirely on its own new `EligibilityDecision` struct.
- **`RiskDecision`** (`Core/MLQuantAI_RiskDecision.mqh`, Phase B1,
  contract-only, confirmed still fully dormant — referenced nowhere
  except its own file, a doc-comment in `RiskPlan.mqh`, and a
  shape-only test). Its own header explicitly frames itself as "what
  the (B7+) Global Risk Manager will record for EVERY candidate it
  evaluates" — exactly B9's job description, written before `RiskPlan`
  (B7) or `AIDecision` (B8.5) existed. **Not reused as-is** — same fate
  as `AIResult` at B8.5's own freeze: structurally outdated (`decision`
  is a raw string not a typed enum; `news_state_at_decision`/
  `account_state_at_decision` are opaque unstructured strings predating
  `FeatureSnapshot`/`AccountSnapshot`; no `candidate_hash`; no
  `risk_plan_id`/`plan_hash`/`ai_decision_id`/`ai_decision_hash`
  lineage at all; no identity/hash pair of its own). `RiskDecision.mqh`
  stays untouched/dormant. `EligibilityDecision` (below) is a new,
  properly lineage-bearing struct.
- **Candidate lifecycle state machine** (`Core/MLQuantAI_StateMachine.mqh`):
  `CANDIDATE_SUBMITTED`/`CANDIDATE_EXECUTED`/`CANDIDATE_REJECTED_BY_RISK`
  already exist with a complete, sealed transition table, but
  `TradeCandidate_Transition()` has zero real call sites anywhere
  outside its own definition and test files — confirmed dormant/unwired.
  B9 is the first real, intended trigger for `CANDIDATE_REJECTED_BY_RISK`
  (only reachable pre-`SUBMITTED`, per the transition table — matches
  B9's own pre-broker position exactly). **Not wired in Commit 1** —
  transition wiring is Commit 2 scope.
- **`SafeMode_IsActive()`/`SafeMode_AllowNewCandidates()`**
  (`Infrastructure/EventStore/MLQuantAI_SafeModeState.mqh`) — real, live
  accessors, already tripped by real event-store/reconciliation/replay
  failures, currently read by nothing except status logging and tests.
  **Reused directly** — `EligibilityContext.safe_mode_active` is
  captured from `SafeMode_IsActive()` by the caller before
  `EligibilityDecision_Build` is invoked (the builder itself never
  calls it - see the scope guard below).
- **`AIResult`** (Phase A, re-confirmed dormant yet again — no event, no
  real reader anywhere). B9 reads the real, sealed `AIDecision.decision_outcome`,
  never `AIResult.allow`/`.decision`.
- **`ENUM_REASON_CODE`'s existing dormant `REASON_RISK_*` block**
  (`Core/MLQuantAI_ReasonCodes.mqh`): `REASON_RISK_DAILY_LOSS_LIMIT`,
  `REASON_RISK_MAX_DRAWDOWN`, `REASON_RISK_MAX_TOTAL_EXPOSURE`,
  `REASON_RISK_MAX_PER_TRADE`, `REASON_RISK_MARGIN`,
  `REASON_RISK_SPREAD_TOO_WIDE`, `REASON_RISK_NEWS_BLOCK`,
  `REASON_RISK_MAX_OPEN_POSITIONS`, `REASON_RISK_CIRCUIT_BREAKER`.
  **Reused** for `reason_code` — this commit makes
  `DAILY_LOSS_LIMIT`/`MAX_DRAWDOWN`/`MAX_TOTAL_EXPOSURE`/
  `MAX_OPEN_POSITIONS`/`MARGIN`/`CIRCUIT_BREAKER` reachable for the
  first time. `MAX_PER_TRADE`/`SPREAD_TOO_WIDE`/`NEWS_BLOCK` stay
  reserved/unreachable this commit — see "Explicitly out of scope."
  `REASON_AI_REJECT`/`REASON_AI_ABSTAIN` (both already exist from
  B8.5) are also reused, mapped from the two distinct
  `AIDecision.decision_outcome` values that block eligibility — kept
  as two separate reason codes, never collapsed into one, since
  `REJECT` and `ABSTAIN` are different semantics B8.5 itself already
  froze as distinct.
- **`MarketContext`/`FeatureSnapshot`'s spread/news/kill-zone fields**
  (`spread_points_at_anchor`, `is_kill_zone`, `max_news_impact`,
  `nearest_news_minutes`) — real, live-populated, already read by
  `CRT_V1_Rules.mqh` today to gate signal generation at detection time
  (B5). **Not re-evaluated by B9 Commit 1** — spread/news/kill-zone are
  detector-time/context-time rules that already live in B5. Re-checking
  them in B9 would create a second, competing gate for the same
  concern. `FeatureSnapshot` is still an `EligibilityDecision_Build`
  input, but strictly for lineage cross-check (below), never for a
  policy-threshold comparison in this commit.
- **`AccountSnapshot`** (Phase A, `Core/MLQuantAI_AccountSnapshot.mqh`,
  embedded verbatim in B7's `RiskContext` already) — `balance`,
  `equity`, `margin_level`, `open_positions_count` are genuinely live,
  populated today by `FeatureEngine_BuildAccountSnapshot()` via real
  `AccountInfoDouble()`/`PositionsTotal()` calls. `open_risk_percent`/
  `daily_pnl_percent`/`drawdown_from_peak_percent` stay hard-coded at
  `0` — that function's own comment says so explicitly: *"there is no
  Global Risk Manager tracking these yet (that's B7)"* — B7 turned out
  to be pure deterministic sizing, never that tracker; B9 is now that
  concern's real owner, but **this commit does not build that
  tracker** — it accepts these three fields as inputs exactly as
  currently populated (confirmed with the user). Building the actual
  running-P&L/drawdown/exposure tracker is separate, later work.

## `ENUM_ELIGIBILITY_DECISION` (new, frozen)

```cpp
enum ENUM_ELIGIBILITY_DECISION
{
   ELIGIBILITY_DECISION_NONE,     // Init()/unfilled only - never a real decision's value
   ELIGIBILITY_DECISION_ELIGIBLE,
   ELIGIBILITY_DECISION_REJECTED
};
```

## `EligibilityContext` struct (new, frozen)

A live-state snapshot, captured once by the caller before invoking the
builder — mirrors `RiskContext`'s own embed-a-Phase-A-struct-verbatim
pattern, with one deliberate departure explained below.

```cpp
struct EligibilityContext
{
   string          eligibility_context_schema_version; // MLQUANTAI_ELIGIBILITY_CONTEXT_SCHEMA_B9_V1
   string          eligibility_context_hash;            // content hash - see below. NO separate identity field.

   AccountSnapshot account;          // Phase A struct, embedded verbatim
   bool            safe_mode_active; // captured from SafeMode_IsActive() by the CALLER, not the builder
};
```

**No `eligibility_context_id`.** Every other identity-bearing struct in
this project (`FeatureSnapshot`, `RiskPlan`, `AIDecision`, `ModelArtifact`)
holds the invariant "same identity implies same content is the normal
case; same identity with different content is a collision/drift signal."
`EligibilityContext` cannot honor that invariant: the same `candidate_id`
can legitimately be re-evaluated multiple times (e.g. rejected on a
daily-loss check, re-checked later once P&L recovers), each time with
genuinely different, equally-valid `account` state — a per-candidate id
would make "same id, different content" the *normal* case for this
struct, breaking the collision-detection idiom every projection in this
project relies on. `EligibilityContext` therefore carries only a content
hash (matching `InferenceResult`'s own precedent — B8.4's ephemeral
input to `AIDecision_Build` has no independent identity or projection
either, only its `output_hash`, consumed once and copied verbatim
forward). `EligibilityContext` is never independently projected/replayed
in this commit or planned for one in Commit 2 — it is always inlined
1:1 with the one `EligibilityDecision` that consumed it.

**`eligibility_context_hash` deliberately includes `account`** — a
departure from `RiskContext_HashPayload`'s own precedent (which
excludes `account` because `RiskContext`'s hash answers "is this the
same sizing rule set", never "will this produce the same plan").
`EligibilityContext`'s entire purpose is the opposite: it exists to
be direct audit evidence of "what was the live account/safe-mode state
at the moment this eligibility verdict was made" — excluding `account`
would defeat the struct's only reason to exist. This is an explicit,
justified design choice, not an oversight — the same kind of
called-out departure `ModelArtifact`'s own hash-inclusion choice was
in `Docs/PhaseB_B8_3_ModelRegistryContract.md`.

```cpp
void EligibilityContext_Init(EligibilityContext &c)
{
   c.eligibility_context_schema_version = MLQUANTAI_ELIGIBILITY_CONTEXT_SCHEMA_B9_V1;
   c.eligibility_context_hash = "";
   AccountSnapshot_Init(c.account);
   c.safe_mode_active = false;
}

string EligibilityContext_HashPayload(const EligibilityContext &c)
{
   return CanonicalDouble(c.account.balance) + "|" +
          CanonicalDouble(c.account.equity) + "|" +
          CanonicalDouble(c.account.margin_level) + "|" +
          IntegerToString(c.account.open_positions_count) + "|" +
          CanonicalDouble(c.account.open_risk_percent) + "|" +
          CanonicalDouble(c.account.daily_pnl_percent) + "|" +
          CanonicalDouble(c.account.drawdown_from_peak_percent) + "|" +
          (c.safe_mode_active ? "true" : "false");
}

string EligibilityContext_ComputeHash(const EligibilityContext &c)
{
   return Ids_Sha256Hex(EligibilityContext_HashPayload(c));
}
```

(`eligibility_context_schema_version` excluded from its own hash,
matching the project's default precedent.)

## `EligibilityPolicy` struct (new, frozen)

The minimal, explicit, versioned policy input `EligibilityDecision_Build`
requires — no implicit default anywhere, mirrors `AIDecisionPolicy`'s
own shape.

```cpp
struct EligibilityPolicy
{
   string eligibility_policy_version;  // mandatory, non-empty

   double max_daily_loss_percent;      // [0, 100]. 0 = gate disabled.
   double max_drawdown_percent;        // [0, 100]. 0 = gate disabled.
   double max_total_exposure_percent;  // [0, 100]. 0 = gate disabled.
   int    max_open_positions;          // [0, INT_MAX]. 0 = gate disabled.
   double min_margin_level;            // [0, +inf). 0 = gate disabled.
};
```

**Zero means "this gate is disabled," not "reject everything."**
Required because `account.daily_pnl_percent`/`.drawdown_from_peak_percent`/
`.open_risk_percent` are still hard-coded `0` today (see the collision
check above) — treating `0` as a real, enforced threshold would reject
every candidate the moment any of those three gates is turned on, which
is never the intent. This means B9 v1 does **not** claim to have a real
running P&L/drawdown/exposure tracker in place — it only claims to
correctly enforce whatever values are actually populated, whenever a
future commit starts populating them for real. `max_open_positions`/
`min_margin_level` gates are meaningfully enforceable today, since
`open_positions_count`/`margin_level` are already real, live-populated
values.

## `EligibilityDecision` struct (new, frozen)

```cpp
struct EligibilityDecision
{
   string eligibility_decision_schema_version; // MLQUANTAI_ELIGIBILITY_DECISION_SCHEMA_B9_V1

   string eligibility_decision_id;   // identity - Ids_EligibilityDecisionId(candidate_id, eligibility_policy_version)
   string eligibility_decision_hash; // content integrity - see "Identity and hash" below

   string candidate_id;   // copied verbatim from RiskPlan (cross-checked against AIDecision/FeatureSnapshot)
   string candidate_hash; // copied verbatim from RiskPlan (cross-checked against AIDecision/FeatureSnapshot)

   string risk_plan_id; // copied verbatim from RiskPlan
   string plan_hash;    // copied verbatim from RiskPlan

   string ai_decision_id;   // copied verbatim from AIDecision
   string ai_decision_hash; // copied verbatim from AIDecision

   string eligibility_context_hash;   // copied verbatim from EligibilityContext
   string eligibility_policy_version; // from the supplied EligibilityPolicy

   ENUM_ELIGIBILITY_DECISION decision;
   ENUM_REASON_CODE          reason_code;
};
```

No `feature_snapshot_id`/`feature_snapshot_hash` duplicated here —
`AIDecision.feature_snapshot_id`/`.feature_snapshot_hash` (reachable via
`ai_decision_id`) already carries that lineage; `FeatureSnapshot` is an
input to the builder only to re-verify `AIDecision`'s claimed lineage
against a real, fresh copy, not to be re-persisted a third time. No
`AccountSnapshot` field values duplicated here either — the caller who
wants to know the exact account state a decision was made under reads
`EligibilityContext` itself (which Commit 2's event payload, if it
persists one inline with `AI_DECISION`... i.e. the future
`EXECUTION_ELIGIBILITY_DECIDED` event, will carry alongside this
struct's own fields) — this struct's own `eligibility_context_hash`
only proves *which* context, never re-states its content.

```cpp
void EligibilityDecision_Init(EligibilityDecision &d)
{
   d.eligibility_decision_schema_version = MLQUANTAI_ELIGIBILITY_DECISION_SCHEMA_B9_V1;
   d.eligibility_decision_id = "";
   d.eligibility_decision_hash = "";
   d.candidate_id = "";
   d.candidate_hash = "";
   d.risk_plan_id = "";
   d.plan_hash = "";
   d.ai_decision_id = "";
   d.ai_decision_hash = "";
   d.eligibility_context_hash = "";
   d.eligibility_policy_version = "";
   d.decision = ELIGIBILITY_DECISION_NONE;
   d.reason_code = REASON_NONE;
}
```

## `EligibilityDecision_Build` (new, frozen signature)

```cpp
bool EligibilityDecision_Build(const RiskPlan &plan, const AIDecision &decision, const FeatureSnapshot &snapshot,
                                 const EligibilityContext &context, const EligibilityPolicy &policy,
                                 EligibilityDecision &outDecision, string &outReasonDetail);
```

Does not take a raw `TradeCandidate` — mirrors `AIDecision_Build`'s own
"trust the already-verified structs you were given, cross-check their
claimed lineage against each other" posture (`AIDecision_Build` itself
never took a raw `InferenceRequest`).

**No live read anywhere in this function** — no `AccountInfoDouble`,
no `PositionsTotal`, no `SafeMode_IsActive`, no `TimeCurrent`, no
`EventStore_Log*`, no `OrderSend`/`CTrade`. Everything it needs is
already captured verbatim in `context`/`policy`/the three input structs,
exactly as B7/B8's own pure-mapping functions require.

Fail-closed ladder:

1. `plan.risk_plan_id == ""` -> fail, no `EligibilityDecision` produced.
   Defensive boundary only — in the real live flow, `EligibilityDecision_Build`
   is only ever called with a `RiskPlan` found via
   `RiskPlanProjection_TryGet`, which by construction is always
   `allowed`. This catches a hand-constructed/corrupted `RiskPlan`
   passed in directly.
2. `decision.ai_decision_id == ""` -> fail. Same defensive posture for
   a hand-constructed/corrupted `AIDecision`.
3. Lineage cross-check, all three must agree:
   - `plan.candidate_id != decision.candidate_id` OR
     `plan.candidate_hash != decision.candidate_hash` -> fail.
   - `decision.feature_snapshot_id != snapshot.feature_snapshot_id` OR
     `decision.feature_snapshot_hash != snapshot.feature_snapshot_hash` OR
     `decision.feature_vector_hash != snapshot.feature_vector_hash` ->
     fail (verifies the `FeatureSnapshot` passed in is really the one
     `AIDecision` was built from — mirrors `AIDecision_Build`'s own
     cross-check of `InferenceResult` against `FeatureSnapshot`).
   - `snapshot.candidate_id != plan.candidate_id` OR
     `snapshot.candidate_hash != plan.candidate_hash` -> fail (closes
     the loop across all three structs).
4. `policy.eligibility_policy_version == ""` -> fail.
5. Any of `policy.max_daily_loss_percent`/`.max_drawdown_percent`/
   `.max_total_exposure_percent` not finite or outside `[0, 100]` ->
   fail. `policy.max_open_positions < 0` -> fail.
   `policy.min_margin_level` not finite or `< 0` -> fail.
6. `context.eligibility_context_hash == ""` or
   `context.eligibility_context_hash != EligibilityContext_ComputeHash(context)`
   -> fail (defensive re-check, same posture as step 1/2 — catches a
   hand-constructed/corrupted `EligibilityContext`).
7. Any of `context.account.balance`/`.equity`/`.margin_level`/
   `.open_risk_percent`/`.daily_pnl_percent`/`.drawdown_from_peak_percent`
   not finite -> fail.
8. Otherwise, copy every lineage field verbatim (per the struct above),
   then decide, in this exact precedence order — first match wins:

   1. `decision.decision_outcome == AI_DECISION_OUTCOME_REJECT` ->
      `ELIGIBILITY_DECISION_REJECTED`, `REASON_AI_REJECT`.
   2. `decision.decision_outcome == AI_DECISION_OUTCOME_ABSTAIN` ->
      `ELIGIBILITY_DECISION_REJECTED`, `REASON_AI_ABSTAIN`.
   3. `policy.max_daily_loss_percent > 0` AND
      `context.account.daily_pnl_percent <= -policy.max_daily_loss_percent`
      -> `REJECTED`, `REASON_RISK_DAILY_LOSS_LIMIT`.
   4. `policy.max_drawdown_percent > 0` AND
      `context.account.drawdown_from_peak_percent >= policy.max_drawdown_percent`
      -> `REJECTED`, `REASON_RISK_MAX_DRAWDOWN`.
   5. `policy.max_total_exposure_percent > 0` AND
      `context.account.open_risk_percent >= policy.max_total_exposure_percent`
      -> `REJECTED`, `REASON_RISK_MAX_TOTAL_EXPOSURE`.
   6. `policy.max_open_positions > 0` AND
      `context.account.open_positions_count >= policy.max_open_positions`
      -> `REJECTED`, `REASON_RISK_MAX_OPEN_POSITIONS`.
   7. `policy.min_margin_level > 0` AND `context.account.margin_level > 0`
      AND `context.account.margin_level < policy.min_margin_level` ->
      `REJECTED`, `REASON_RISK_MARGIN`. (`margin_level > 0` guards the
      documented "0 = no margin used" convention on `AccountSnapshot`
      itself from falsely tripping this gate when no exposure exists.)
   8. `context.safe_mode_active == true` -> `REJECTED`,
      `REASON_RISK_CIRCUIT_BREAKER`.
   9. Otherwise -> `ELIGIBILITY_DECISION_ELIGIBLE`, `REASON_NONE`.

   **Why AI comes before every operational gate**: the model's veto is
   a deterministic, explicit, already-audited decision
   (`AIDecision`, sealed at B8.5) - evaluating it first keeps precedence
   itself deterministic and auditable. Changing this ordering later
   (e.g. to operational-constraints-first) requires a new
   `eligibility_policy_version`, never a silent behavior change under
   an existing version.
9. Compute `eligibility_decision_id`/`eligibility_decision_hash`
   (below), return `true`.

On any failure, `outDecision` is left at `EligibilityDecision_Init()`
defaults (`ELIGIBILITY_DECISION_NONE`, empty strings) — no partial
record, no event, no mutation of `plan`/`decision`/`snapshot`/`context`/
`policy`.

## Identity and hash

```cpp
string Ids_EligibilityDecisionId(string candidateId, string eligibilityPolicyVersion)
{
   string key = candidateId + "|" + eligibilityPolicyVersion;
   return Ids_Deterministic("ELIGDEC", key);
}
```

Deliberately independent of every content field (`decision`,
`reason_code`, `eligibility_context_hash`, `risk_plan_id`/`plan_hash`,
`ai_decision_id`/`ai_decision_hash`) — identical to every prior
`Ids_*Id` philosophy in this project: same `candidate_id` + same
`eligibility_policy_version`, re-decided later, must produce the exact
same `eligibility_decision_id` — a different `eligibility_decision_hash`
under that same id is a genuine re-evaluation/drift signal to audit,
never silently absorbed.

`eligibility_decision_hash` payload — every decision-bearing field,
**excluding** `eligibility_decision_id` (identity, not content) and
`eligibility_decision_schema_version` (the struct's own top-level
schema stamp), matching the `RiskPlan`/`TrainingDatasetRow`/`AIDecision`
default:

```
candidate_id | candidate_hash |
risk_plan_id | plan_hash |
ai_decision_id | ai_decision_hash |
eligibility_context_hash | eligibility_policy_version |
decision | reason_code
```

```
same eligibility_decision_id + same eligibility_decision_hash    -> duplicate, no-op (Commit 2)
same eligibility_decision_id + different eligibility_decision_hash -> genuine re-evaluation, not a collision by construction here (unlike every prior struct) - see the note below
```

**One deliberate departure from every prior struct's collision
semantics**: because the same `candidate_id` can be legitimately
re-evaluated multiple times (account state changes between checks),
`eligibility_decision_id` alone is not expected to be globally unique
the way `feature_snapshot_id`/`risk_plan_id`/`ai_decision_id` are. Commit
2's own addendum will define the real replay/projection semantics for
this (most likely: keep every distinct `eligibility_decision_hash` under
the same id as its own valid record, an ordered history rather than a
single latest-wins slot) — **not frozen in this document**, since Commit
1 does not persist or replay anything yet.

## Scope guard (Commit 1: pure mapping only)

No event emission (Commit 2), no projection/replay (Commit 2), no
`CANDIDATE_REJECTED_BY_RISK` or any other state-machine transition
(Commit 2), no live account/tick/broker/`SafeMode_IsActive()` call
inside `EligibilityDecision_Build` itself (caller captures
`EligibilityContext` before calling), no spread/news/kill-zone
re-evaluation (B5's job, not re-derived here), no
`daily_pnl_percent`/`drawdown_from_peak_percent`/`open_risk_percent`
tracker (separate, later work — this commit only consumes whatever
value is already populated), no mutation of
`RiskPlan`/`AIDecision`/`FeatureSnapshot`/`TradeCandidate`, no
execution eligibility consumed by anything yet, no broker/order call
anywhere.

## Expected commits (as proposed, not all frozen in this doc)

```
B9 Commit 1  EligibilityContext + EligibilityPolicy + EligibilityDecision pure mapping   <- this contract
B9 Commit 2  EXECUTION_ELIGIBILITY_DECIDED event + projection/replay +
             CANDIDATE_REJECTED_BY_RISK transition wiring                                 <- own contract addendum, later
B9 Commit 3  Full-chain integration + regression proof, seal                              <- own contract addendum, later
```

## Test matrix (Commit 1, frozen)

- Accept path: valid `RiskPlan` + matching `AIDecision` (`ALLOW`) +
  matching `FeatureSnapshot` + `EligibilityContext` with every gate
  either disabled or within policy + valid `EligibilityPolicy` ->
  `ELIGIBLE`/`REASON_NONE`, every field copied verbatim and matches its
  source exactly.
- `AIDecision.decision_outcome == REJECT` -> `REJECTED`/`REASON_AI_REJECT`,
  even when every operational gate would otherwise pass.
- `AIDecision.decision_outcome == ABSTAIN` (hand-constructed, since
  B8.5 v1 policy never produces it) -> `REJECTED`/`REASON_AI_ABSTAIN`,
  distinct from the `REJECT` case.
- Each of the 6 reachable operational gates
  (`DAILY_LOSS_LIMIT`/`MAX_DRAWDOWN`/`MAX_TOTAL_EXPOSURE`/
  `MAX_OPEN_POSITIONS`/`MARGIN`/`CIRCUIT_BREAKER`), isolated
  individually: value at/beyond the threshold with the gate enabled ->
  `REJECTED` with the matching reason; the same value with the gate at
  `0` (disabled) -> does not trigger that gate.
- Precedence: an input engineered to trip both an AI veto and an
  operational gate simultaneously -> the AI reason wins, per the frozen
  order.
- `margin_level == 0` (no margin used) with `min_margin_level > 0`
  enabled -> does NOT trigger `REASON_RISK_MARGIN` (the `> 0` guard
  holds).
- Fail-closed: empty `risk_plan_id`; empty `ai_decision_id`; each of
  the 3-way lineage mismatches isolated individually; empty
  `eligibility_policy_version`; each policy threshold non-finite/out-of-range
  isolated individually; `eligibility_context_hash` empty or not
  matching a fresh recompute; each `account.*` field non-finite in
  isolation.
- `Ids_EligibilityDecisionId` determinism: same `candidate_id` +
  `eligibility_policy_version` -> same id, every time, regardless of
  `EligibilityContext`/`AIDecision` content.
- `eligibility_decision_hash` determinism: same full payload -> same
  hash, byte-identical, repeated builds.
- `eligibility_decision_hash` sensitivity: changing `decision`,
  `reason_code`, `eligibility_context_hash`, `ai_decision_hash`, or
  `plan_hash` alone (all else equal) each moves the hash - proves the
  "same identity, different hash is a real drift/re-evaluation signal"
  property holds.
- No mutation: `plan`/`decision`/`snapshot`/`context`/`policy`
  unchanged before/after `EligibilityDecision_Build`, on both the
  eligible and every rejected path.
- No side effects (structural): no `EventStore_Log*`/`OrderSend`/
  `CTrade`/`AccountInfo*`/`PositionsTotal`/`SafeMode_IsActive`/
  `TimeCurrent` call anywhere in `EligibilityDecision_Build` - verified
  by inspection.

# Addendum — B9 Commit 2: `EXECUTION_ELIGIBILITY_DECIDED` event + `CANDIDATE_REJECTED_BY_RISK` wiring + `EligibilityDecisionProjection`

**Status: FROZEN, before any code exists.** Written the moment Commit 1
was confirmed PASSED (120/120, real MetaEditor run) and Commit 2 was
confirmed to proceed, after a collision check against
`EXECUTION_ELIGIBILITY_DECIDED`/`EligibilityDecisionProjection`/
`EligibilityDecisionRegistry`/`EligibilityDecision_Emit`/
`eligibility_decision_id`/`eligibility_decision_hash`/
`CANDIDATE_REJECTED_BY_RISK`/`TradeCandidate_Transition`/
`REASON_RISK_*`/`REASON_AI_REJECT`/`REASON_AI_ABSTAIN`/
`LifecycleEvent` (full findings below).

**Correction to the frozen field list carried in from planning:** the
payload does **not** include an `eligibility_context_id` — the real,
already-PASSED (120/120) Commit 1 `EligibilityContext` struct has no
identity field, only `eligibility_context_schema_version` +
`eligibility_context_hash` (deliberate - see Commit 1's own "Identity
and hash" section on why a per-candidate identity would collide with
the "same candidate legitimately re-evaluated multiple times" case).
Since Commit 1 is sealed, Commit 2 works with the real shipped struct
as-is.

## Collision check findings

- **`ENUM_EVENT_TYPE`**: current true tail is
  `EVENT_TYPE_AI_DECISION_CREATED` (B8.5 Commit 2). No
  `EXECUTION_ELIGIBILITY_DECIDED` or similar value exists.
  `EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED` is appended after it, same
  append-only rule.
- **`CANDIDATE_REJECTED_BY_RISK`/`TradeCandidate_Transition`**: the
  state machine already allows `CANDIDATE_CREATED -> CANDIDATE_REJECTED_BY_RISK`
  (a terminal state, no transitions out). A real, general-purpose
  transition-logging function already exists and is exactly what this
  commit needs -
  `EventStore_LogTransition(TradeCandidate &c, ENUM_CANDIDATE_STATE to, ENUM_REASON_CODE reason, string extraJson="")`
  (`Infrastructure/EventStore/MLQuantAI_EventStore.mqh`) - validates via
  `StateMachine_CanTransition`, durably appends, commits `c.state` only
  after the durable write succeeds (fail-closed), auto-derives the
  event type via `EventTypeForCandidateState(to)`. **`TradeCandidate_Transition`
  has zero real call sites anywhere and is NOT used** - this commit
  calls `EventStore_LogTransition` directly, exactly like every prior
  real test that has driven `CANDIDATE_REJECTED_BY_RISK`
  (`Tests/MLQuantAI_Test_DummyLifecycle.mq5`).
- **`REASON_RISK_*`/`REASON_AI_REJECT`/`REASON_AI_ABSTAIN`**: already
  fully wired into Commit 1's `EligibilityDecision_Build` (which reason
  code maps to which gate is already frozen there). This commit adds no
  new reason code - the lifecycle transition's `reason` parameter is
  always `EligibilityDecision.reason_code`, copied verbatim, never
  re-derived.
- **`LifecycleEvent`** (not "`CandidateLifecycleEvent`" - that name
  does not exist in the codebase;
  `Infrastructure/EventStore/MLQuantAI_LifecycleEvent.mqh` is the real
  file/struct name).
- **`RiskDecision`**: re-confirmed still fully dormant, untouched - no
  new reference anywhere in this commit.
- **`CandidateProjection` (B6.1) vs `StateProjector`**: `CandidateProjection`
  deliberately tracks `CANDIDATE_CREATED` only - its own record struct's
  `state` field is hard-coded to `CANDIDATE_CREATED` and its own code
  comment says "B6 never applies later transitions." **It is not
  extended or touched by this commit.** The already-sealed, separate
  `StateProjector` (`Infrastructure/EventStore/MLQuantAI_StateProjector.mqh`,
  B5-era) is the real, already-working full-lifecycle-state tracker -
  `StateProjector_TryGetState(candidateId, &outState)` already exists
  and is already proven to round-trip `CANDIDATE_REJECTED_BY_RISK`
  correctly on replay (`Tests/MLQuantAI_Test_ReplayIntegrity.mq5`).
  This commit's cross-session/replay idempotency check for the
  lifecycle transition uses `StateProjector_TryGetState`, never
  `CandidateProjection`.
- **Two distinct event families in one commit** (the first time any B
  phase has needed this): `EXECUTION_ELIGIBILITY_DECIDED` is a
  `SystemEvent` (`EventStore_LogSystem`/`EventSerializer_ParseSystem`) -
  same family as `RISK_PLAN_CREATED`/`FEATURE_SNAPSHOT_CREATED`/
  `MODEL_ARTIFACT_REGISTERED`/`AI_DECISION_CREATED`, since an
  `EligibilityDecision` is a derived audit artifact tied to a
  candidate, not itself a candidate-lifecycle transition.
  `CANDIDATE_REJECTED_BY_RISK` is a real `LifecycleEvent`
  (`EventStore_LogTransition`/`EventSerializer_ParseLifecycle`) - a
  genuine state transition. Both are real, both already have sealed
  infrastructure; this commit is the first to emit one of each kind
  from the same decision.
- **No independently-persisted upstream event for `EligibilityContext`**:
  unlike `RiskPlan`/`AIDecision`/`FeatureSnapshot` (each with its own
  real `_CREATED`/`_REGISTERED` event elsewhere in the store that a
  projection can independently rebuild and cross-check against),
  `EligibilityContext`'s account/safe-mode state has no upstream event
  of its own - it is captured live by the caller immediately before
  `EligibilityDecision_Build`. A hash-only payload would be
  write-only/unverifiable on replay, breaking this project's own
  "every hash in a persisted event must be independently
  reconstructable or directly verifiable" discipline every prior layer
  follows. **Resolution (confirmed by the user): `EXECUTION_ELIGIBILITY_DECIDED`'s
  own payload persists the raw `EligibilityContext.account.*` fields
  and `safe_mode_active` verbatim**, so replay can recompute
  `EligibilityContext_ComputeHash()` from the persisted raw fields and
  verify it against the persisted `eligibility_context_hash` - the only
  viable option given no separate reconstructable context event exists.

## Event design

Two event families, by design, in a fixed order:

```
EligibilityDecision
    |
    v
EXECUTION_ELIGIBILITY_DECIDED         <- SystemEvent, always written first
    |
    v (only if decision == REJECTED)
CANDIDATE_REJECTED_BY_RISK            <- LifecycleEvent, consequence only
```

- `EXECUTION_ELIGIBILITY_DECIDED` is written for **every** successfully
  built `EligibilityDecision` - `ELIGIBLE` and `REJECTED` both, audit
  evidence either way, exactly like B8.5 Commit 2's own
  `ALLOW`/`REJECT`/`ABSTAIN`-emit-identically precedent. The only gate
  is a failed build (`eligibility_decision_id == ""`).
- `CANDIDATE_REJECTED_BY_RISK` is emitted **only** when
  `decision == ELIGIBILITY_DECISION_REJECTED`, strictly after the
  `EXECUTION_ELIGIBILITY_DECIDED` write already succeeded - never
  before it, never for `ELIGIBLE`.
- `ELIGIBLE` never emits a lifecycle transition and never submits
  anything - the candidate stays at `CANDIDATE_CREATED`. No
  `CANDIDATE_SUBMITTED`, no order request, no broker call anywhere in
  this commit - that is Phase C's job, out of scope here entirely.

## `EXECUTION_ELIGIBILITY_DECIDED`'s `extra_json` - every `EligibilityDecision` field, plus raw `EligibilityContext` evidence

```
eligibility_decision_schema_version, eligibility_decision_id, eligibility_decision_hash,
candidate_id, candidate_hash,
risk_plan_id, plan_hash,
ai_decision_id, ai_decision_hash,
eligibility_context_schema_version, eligibility_context_hash,
eligibility_policy_version, decision, reason_code,

account_balance, account_equity, account_margin_level,
account_open_positions_count, account_open_risk_percent,
account_daily_pnl_percent, account_drawdown_from_peak_percent,
account_context_schema_version,
safe_mode_active
```

All 8 real `AccountSnapshot` fields are persisted verbatim (not a
selective subset, including `context_schema_version` even though it is
excluded from `EligibilityContext_HashPayload` itself - the full raw
struct is audit evidence regardless of which fields feed the hash),
prefixed `account_` to avoid any key collision with
`EligibilityDecision`'s own fields. `decision`/`reason_code` follow the
project's standard enum-as-quoted-string convention
(`EligibilityDecisionToString`/`ReasonCodeToString`).
`account_id`/`currency`-style fields do **not** exist on the real
`AccountSnapshot` struct and are not persisted (nothing to persist).

## Live emission: `EligibilityDecision_EmitDecisionAndWireLifecycle` (new)

```cpp
bool EligibilityDecision_EmitDecisionAndWireLifecycle(const EligibilityDecision &d, const EligibilityContext &context, TradeCandidate &candidate);
```

1. Returns `false` (no write attempted) if `d.eligibility_decision_id == ""`
   (a failed `EligibilityDecision_Build`) - same "no partial record"
   rule every prior emitter follows.
2. Checks `EligibilityDecisionProjection_TryGet(d.eligibility_decision_id, existing)` -
   the same coarse, live, in-session guard every prior emitter uses.
3. Builds `extra_json` via `EligibilityDecision_ToExtraJson(d, context)`,
   appends via
   `EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED), "execution eligibility decided", extraJson)`.
   Returns `false` if this write fails.
4. Applies the equivalent record to `EligibilityDecisionProjection`'s
   live in-memory registry (same live-sync fix every prior emitter
   needs).
5. If `d.decision != ELIGIBILITY_DECISION_REJECTED`, returns `true` -
   done, no lifecycle transition.
6. If `d.decision == ELIGIBILITY_DECISION_REJECTED`, calls
   `EventStore_LogTransition(candidate, CANDIDATE_REJECTED_BY_RISK, d.reason_code, extraJson)`
   (the same `extra_json` payload, so the lifecycle line itself also
   carries the full decision/evidence for anyone reading only that
   line). Returns whatever that call returns.

**Failure-mode rule (explicit, confirmed by the user): no cross-event
rollback.** If step 3 (the `EXECUTION_ELIGIBILITY_DECIDED` write)
succeeds but step 6 (the `CANDIDATE_REJECTED_BY_RISK` write) fails, the
function returns `false` to the caller, but the already-durable
`EXECUTION_ELIGIBILITY_DECIDED` line is **never** rolled back, rewritten,
or deleted - this project's event store is append-only, and erasing a
durably-written line to "undo" a partial multi-event operation would
destroy the audit trail worse than leaving an inconsistency for
reconciliation to find. The caller must treat a `false` return as "the
eligibility decision is durably recorded, but the candidate's lifecycle
state may not reflect it yet" and must not claim B9 completed the
candidate's lifecycle transition on that path. `EventStore_LogTransition`
itself already trips Safe Mode on its own durable-write failure (its
existing, sealed behavior - unchanged here). Reconciling "does every
`REJECTED` `EXECUTION_ELIGIBILITY_DECIDED` have exactly one matching
terminal `CANDIDATE_REJECTED_BY_RISK`" is deferred to Commit 3's
integration/replay proof (a real fault-injection test for step 6's
write failing independently of step 3 succeeding is included in this
commit's suite only if MQL5 offers a reliable way to force that
specific failure in isolation; otherwise this recovery semantic is
documented here and re-verified structurally in Commit 3).

## Replay/projection: `EligibilityDecisionProjection` (new)

`EligibilityDecisionProjectionRecord`: every `EligibilityDecision`
field, plus the same raw `AccountSnapshot`/`safe_mode_active` evidence
the event payload carries (so a rebuilt record can prove its own
`eligibility_context_hash` independently, not merely repeat it), plus
`source_sequence_number`/`source_log_event_id`.

`EligibilityDecisionProjection_RebuildFromFile(fileName)`:

1. `EventStoreValidator_ValidateLines` - whole-file gate, same as every
   prior projection.
2. `RiskPlanProjection_RebuildFromFile(fileName)` - independent
   rebuild, needed for the direct `RiskPlan` lineage cross-check below.
3. `AIDecisionProjection_RebuildFromFile(fileName)` - independent
   rebuild (which itself transitively rebuilds `FeatureSnapshotProjection`
   and `ModelArtifactProjection` as its own prerequisites).
4. `FeatureSnapshotProjection_RebuildFromFile(fileName)` - rebuilt
   again, explicitly and independently at this layer too (defense in
   depth, matching this project's established "structural, not just
   behavioral" re-verification precedent - not strictly required by
   step 3's own internal behavior, but proves the chain of custody at
   this layer directly rather than only trusting `AIDecisionProjection`'s
   own prior verification).
5. If any of steps 1-4 fail, this rebuild fails closed, registry
   untouched.
6. Reset `EligibilityDecisionProjection`'s own registry, apply every
   line via `EligibilityDecisionProjection_ApplyLineWithLineage`.

`EligibilityDecisionProjection_ApplyLineWithLineage` (for each
`EXECUTION_ELIGIBILITY_DECIDED` line):

1. Line-length defensive bound, two-part type-gate, `EventSerializer_ParseSystem`,
   required-field presence, numerical integrity - same ladder every
   prior projection uses.
2. **Reconstruct `EligibilityContext` from the persisted raw evidence**
   (`account_*` fields + `safe_mode_active`) and recompute
   `EligibilityContext_ComputeHash()` - **require an exact match**
   against the line's own `eligibility_context_hash`. Any mismatch
   (including a tampered single `account_*` field) is rejected as a
   context-integrity failure - this is the mechanism that makes the
   persisted raw evidence actually protective, not just informational:
   tampering any evidence field changes the recomputed hash and fails
   closed.
3. **Referential integrity against `RiskPlanProjection`**: the
   referenced `risk_plan_id` must exist, and its `plan_hash`/
   `candidate_id`/`candidate_hash` must match the line's own values.
   Missing -> orphan, rejected. Mismatch -> rejected.
4. **Referential integrity against `AIDecisionProjection`**: the
   referenced `ai_decision_id` must exist, and its `ai_decision_hash`/
   `candidate_id`/`candidate_hash` must match the line's own values.
   Missing -> orphan, rejected. Mismatch -> rejected.
5. **Referential integrity against `FeatureSnapshotProjection`,
   reached via the `AIDecisionProjection` record found in step 4**: the
   `AIDecisionProjection` record's own `feature_snapshot_id` must exist
   in `FeatureSnapshotProjection`, and that record's `candidate_id`/
   `candidate_hash` must match the line's own `candidate_id`/
   `candidate_hash` too - confirming the full chain of custody
   (candidate -> snapshot -> AI decision -> eligibility decision) agrees
   on candidate identity at every hop, not just trusting
   `AIDecisionProjection`'s own already-completed internal check.
6. **Collision-vs-duplicate**: `eligibility_decision_id` already
   registered with an IDENTICAL `eligibility_decision_hash` ->
   duplicate, idempotent no-op. DIFFERENT hash -> collision, rejected,
   whole rebuild fails closed.

## Lifecycle cross-session idempotency

- **Live session**: `EventStore_LogTransition` + `StateMachine_CanTransition`
  already prevent a second transition attempt once the in-memory
  `TradeCandidate.state` is `CANDIDATE_REJECTED_BY_RISK` (a terminal
  state) - free from the existing, sealed state machine.
- **Cross-session/replay**: before calling
  `EventStore_LogTransition` for a candidate whose `EligibilityDecision`
  was just rebuilt as `REJECTED`, the caller checks
  `StateProjector_TryGetState(candidate_id, &state)` first - if it
  already reports `CANDIDATE_REJECTED_BY_RISK`, the transition is
  skipped as an idempotent no-op, never attempted a second time. This
  commit does not change `StateProjector` itself - only calls its
  already-sealed `_TryGetState` accessor.
- The lifecycle transition's `reason` must always equal
  `EligibilityDecision.reason_code` exactly - never re-derived,
  verified by a replay-time check that the persisted `LifecycleEvent`
  line's `reason` matches the paired `EXECUTION_ELIGIBILITY_DECIDED`
  line's own `reason_code`.

## QA gate for B9 Commit 2 (binding on its test suite)

- `ELIGIBLE`: exactly one `EXECUTION_ELIGIBILITY_DECIDED` event; no
  lifecycle event; candidate stays at `CANDIDATE_CREATED`.
- `REJECTED`: `EXECUTION_ELIGIBILITY_DECIDED` then exactly one terminal
  `CANDIDATE_REJECTED_BY_RISK` `LifecycleEvent`, in that order.
- Event ordering: a `CANDIDATE_REJECTED_BY_RISK` line can never precede
  its paired `EXECUTION_ELIGIBILITY_DECIDED` line in the store (checked
  by sequence number).
- The raw `account_*`/`safe_mode_active` payload reconstructs the exact
  same `eligibility_context_hash` on replay.
- Tampering any single raw evidence field (each isolated individually)
  causes context-hash validation failure, rejected, whole rebuild fails
  closed.
- Missing/mismatched `RiskPlan`/`AIDecision`/`FeatureSnapshot` lineage
  (each isolated individually, including the two-hop `FeatureSnapshot`
  check reached via `AIDecisionProjection`) -> fail-closed, orphan or
  mismatch.
- `eligibility_decision_id` collision (different hash) -> whole rebuild
  fails closed. Same id + same hash -> duplicate no-op.
- A truncated/malformed line anywhere blocks the entire rebuild.
- Lifecycle `reason` mismatch against the paired decision's
  `reason_code` -> rejected/flagged as a deterministic inconsistency
  (not silently accepted).
- After a valid `REJECTED` flow, `StateProjector_TryGetState` reports
  `CANDIDATE_REJECTED_BY_RISK` on replay.
- After a valid `ELIGIBLE` flow, the candidate's state is unchanged
  (`CANDIDATE_CREATED`) both live and on replay.
- Cross-session idempotency: replaying a `REJECTED` decision twice
  produces exactly one `CANDIDATE_REJECTED_BY_RISK` transition, never
  two.
- No broker/order/ONNX/live-account read anywhere in the emission or
  projection path - verified by inspection. Replay never recomputes
  fresh account/safe-mode values; it only ever reads the persisted
  payload evidence.

## Scope guard (Commit 2)

Does not resurrect `RiskDecision`. Does not use `TradeCandidate_Transition`
(calls `EventStore_LogTransition` directly). Does not extend or change
`CandidateProjection`'s scope (still `CANDIDATE_CREATED`-only, by
design). Does not wire any execution/order/submission behavior on an
`ELIGIBLE` verdict - no `CANDIDATE_SUBMITTED`, no broker call anywhere.
Does not recompute fresh account/safe-mode values during replay - replay
uses only the persisted payload evidence. No change to any
already-sealed B5/B6/B7/B8/B9-Commit-1 production file.

# Addendum — B9 Commit 3: full-chain integration + regression proof, seal

**Status: FROZEN, before any code exists.** Written the moment Commit 2
was confirmed PASSED (84/84, real MetaEditor run) and Commit 3 was
confirmed to proceed. Mirrors B7 Commit 3 and B8.5 Commit 3 most
closely - both already sealed the same way. This commit adds **zero new
production behavior**: no new eligibility rule, no new field, no new
event schema, no new policy semantics, no new identity/hash seed, no
new projection behavior, no execution/order/broker call, no change to
any already-sealed B5/B6/B7/B8/B9-Commit-1/B9-Commit-2 production file.
It is purely a test-suite commit proving the already-shipped pieces
compose correctly end to end, plus the integration seams Commit 1's and
Commit 2's own suites did not individually exercise.

## The chain being proven

```
MARKET_CONTEXT_READY
    -> CANDIDATE_CREATED -> CandidateProjection
    -> FEATURE_SNAPSHOT_CREATED -> FeatureSnapshotProjection  -----\
    -> MODEL_ARTIFACT_REGISTERED -> ModelArtifactProjection   -----|--> AI_DECISION_CREATED -> AIDecisionProjection --\
    -> RISK_PLAN_CREATED -> RiskPlanProjection                 ----------------------------------------------------- |--> EligibilityDecision_Build
                                                                                                                       |
                                                                                                    EXECUTION_ELIGIBILITY_DECIDED -> EligibilityDecisionProjection
                                                                                                                       |
                                                                                            REJECTED only: CANDIDATE_REJECTED_BY_RISK -> StateProjector
    -> Restart / Replay
    -> identical lineage + state, across all five upstream layers
```

Unlike B8.5's chain (two independent upstream parents converging at
`AIDecision`), `EligibilityDecision` has **three** independent upstream
chains to verify on rebuild - `RiskPlanProjection`,
`AIDecisionProjection` (itself transitively dependent on
`FeatureSnapshotProjection` + `ModelArtifactProjection`), and
`FeatureSnapshotProjection` again explicitly - already proven
structurally real in Commit 2's own `EligibilityDecisionProjection_RebuildFromFile`
gating order. Commit 3's genuinely-new coverage below is shaped by that
wider fan-in, plus the one behavior Commit 2 explicitly deferred: the
non-rollback "decision durably recorded, lifecycle state may not
reflect it yet" edge case.

## What Commit 1's and Commit 2's own suites already cover (not re-proven here)

`Test_B9_ExecutionEligibility.mq5` already proves `EligibilityDecision_Build`'s
fail-closed ladder, frozen precedence order, determinism, and
identity/hash sensitivity, in isolation from any event store.
`Test_B9_Commit2_EligibilityEvent.mq5` already builds every fixture
through the real B5/B7/B8.1/B8.3/B8.5/B9-Commit-1 pipeline, already
proves the dual-emitter ordering and exactly-once-per-outcome behavior,
already proves duplicate-vs-collision replay semantics, already proves
each of the 8 raw context-evidence fields is independently
hash-protected, already proves orphan `risk_plan_id`/`ai_decision_id`
references fail closed, and already proves one cross-layer failure path
(a corrupted `FEATURE_SNAPSHOT_CREATED` line blocking eligibility
rebuild via the AIDecision registry prerequisite). Commit 3 does not
repeat any of that.

## What's genuinely new in Commit 3

1. **Explicit end-to-end linkage assertion in one place.** A single
   test that, after a full rebuild, walks the whole chain forward from
   a real `MARKET_CONTEXT_READY` event and asserts every hash/ID
   matches its neighbor across all five layers: candidate ->
   snapshot -> (model artifact -> AI decision) and (risk plan) ->
   eligibility decision, confirming `EligibilityDecision.candidate_hash`/
   `plan_hash`/`ai_decision_hash` all agree with their real, independently
   rebuilt projection records - not just that each pairwise check
   individually passes (already proven), but that the full chain of
   custody holds in one assertion sequence.
2. **Cross-layer failure propagation, all three upstream chains
   independently** - the point genuinely harder than B8.5 Commit 3's
   two-parent case: (a) a corrupted/colliding `CANDIDATE_CREATED` line
   must cause `RiskPlanProjection_RebuildFromFile` to fail closed
   (proven via the RiskPlan gate, the first of Commit 2's three
   prerequisite checks); (b) a corrupted/colliding `RISK_PLAN_CREATED`
   line must independently cause the RiskPlan gate itself to fail
   closed, with no reliance on the AIDecision or FeatureSnapshot chains
   also failing; (c) a corrupted/colliding `MODEL_ARTIFACT_REGISTERED`
   line must cause `AIDecisionProjection_RebuildFromFile` to fail closed
   via its own `ModelArtifactProjection` prerequisite (Commit 2 only
   proved the `FeatureSnapshot` side of this pair). All three
   propagation paths proven separately - a bug that only wires up some
   of the three prerequisite checks must be caught by this commit.
3. **Full-chain restart/crash simulation** - reopening the store fresh
   (simulating an EA process restart) and rebuilding all of
   `CandidateProjection`, `FeatureSnapshotProjection`,
   `ModelArtifactProjection`, `AIDecisionProjection`,
   `RiskPlanProjection`, and `EligibilityDecisionProjection` from
   scratch twice, asserting all six layers' state is byte-identical
   across both rebuilds, for a store holding multiple candidates/
   decisions together (not one at a time as Commit 2's own tests did).
4. **Multi-candidate cross-linking check** - several candidates, each
   with their own snapshot/plan/AI decision, decided against a mix of
   shared and distinct policies/verdicts, proving the three-chain shape
   doesn't let an eligibility decision accidentally pick up a
   neighboring candidate's plan or AI decision; after a full rebuild,
   every `EligibilityDecision` must link to exactly its own upstream
   records, never a neighboring one.
5. **Rejected-without-lifecycle-consequence reconciliation** - the
   non-rollback edge case Commit 2's own contract explicitly deferred:
   a store where an `EXECUTION_ELIGIBILITY_DECIDED` line with
   `decision == REJECTED` exists but its paired `CANDIDATE_REJECTED_BY_RISK`
   line does not (simulating the write-succeeds-then-lifecycle-write-fails
   failure mode). A new, test-only reconciliation helper scans a
   rebuilt `EligibilityDecisionProjection` for every `REJECTED` record,
   cross-checks each against `StateProjector_TryGetState` for that
   `candidate_id`, and reports any `REJECTED` decision whose candidate
   is NOT at `CANDIDATE_REJECTED_BY_RISK` as an inconsistency needing
   reconciliation - deterministic detection, not automatic recovery
   (recovery/reconciliation policy itself stays out of scope, per
   Commit 2's own frozen rule that the store is never rewritten).
6. **`ELIGIBLE` leaves no lifecycle trace, confirmed after full-chain
   restart** - re-proving Commit 2's own single-session assertion, but
   after a real restart/replay of a multi-candidate store, and
   confirmed via `StateProjector` (not `CandidateProjection`, which by
   design only ever tracks `CANDIDATE_CREATED`).

## Definition of Done

- The full chain rebuilds state from the store alone (no in-memory
  carry-over assumed), across all six layers
  (`CandidateProjection`/`FeatureSnapshotProjection`/
  `ModelArtifactProjection`/`AIDecisionProjection`/`RiskPlanProjection`/
  `EligibilityDecisionProjection`).
- Candidate/snapshot/model/decision/plan/eligibility linkage matches on
  every hash and ID across all five layers feeding into
  `EligibilityDecision`, for every decision in a multi-candidate store.
- A restart followed by replay reproduces byte-identical state in all
  six projections.
- Duplicate and collision policy still hold correctly across every
  layer boundary - a candidate-layer OR snapshot-layer OR model-layer
  OR plan-layer failure closes the eligibility-layer rebuild too,
  proven independently for each of the three upstream chains.
- A corrupted/truncated line anywhere fails the rebuild closed, with no
  partial commit, regardless of which layer's line it corrupts.
- The rejected-without-lifecycle-consequence reconciliation helper
  correctly flags the simulated failure-mode store and correctly
  reports a clean store as consistent (no false positives).
- No execution, order, broker, account, or extra candidate-lifecycle-state
  transition results from either `ELIGIBLE` or `REJECTED` anywhere in
  this commit's test suite.
- The full B9 regression suite passes: `Test_B9_ExecutionEligibility.mq5`
  and `Test_B9_Commit2_EligibilityEvent.mq5` plus the new
  `Test_B9_Commit3_IntegrationRegression.mq5` all re-run clean in the
  same MetaEditor session - this is a manual re-run checklist for
  whoever confirms this commit, not something one script can automate,
  since MQL5 has no cross-script test runner.

## Explicitly out of scope for this commit

Any new eligibility rule, threshold semantics, event schema change,
identity/hash seed change, projection behavior change, policy semantics
change, any actual reconciliation/recovery ACTION for the
rejected-without-lifecycle-consequence case (detection only, per
Commit 2's own frozen non-rollback rule), any Phase C execution/
submission/broker logic, any change to an already-sealed production
file. If self-review during this commit surfaces an actual
product-level gap (not just a test-coverage gap), that gets flagged to
the user before any production file is touched - same discipline as
every commit before this one.

On a clean pass, this commit closes B9: **execution eligibility pure
mapping (Commit 1) + durable event/projection/replay + risk-reject
lifecycle wiring (Commit 2) + full-chain integration proof (Commit 3)**,
sealed as the last policy authority before Phase C - the sole place
`RiskPlan` + `AIDecision` + operational constraints combine into
`ELIGIBLE`/`REJECTED`, still without any broker/execution authority of
its own.
