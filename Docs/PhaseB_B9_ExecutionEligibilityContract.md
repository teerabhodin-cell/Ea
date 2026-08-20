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
