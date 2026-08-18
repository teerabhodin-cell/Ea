# Phase B7 — Commit 2: RISK_PLAN_CREATED Event + RiskPlanProjection

**Status: Implemented, awaiting real compile/test confirmation.**
First real run: 63/65 (2 test-fixture bugs found and fixed, see
"Bugs found on the first real test run" below) — no production code
changed. This doc will be updated to PASSED once a clean re-run is
reported back.

Implements B7.4 (`RISK_PLAN_CREATED` event emission) and B7.5
(`RiskPlanProjection` replay/recovery), per
`Docs/PhaseB_B7_RiskPlanContract.md`'s B7 Commit 2 addendum. Mirrors
`CANDIDATE_CREATED`/`CandidateProjection` (B5 Commit 5 / B6.1)
structurally and behaviorally as closely as the different event kind
allows.

## Why `RISK_PLAN_CREATED` is a `SystemEvent`, not a `LifecycleEvent`

A `RiskPlan` is a derived artifact tied to a candidate — like
`MarketContext` — not a candidate lifecycle state transition. It
follows the `MARKET_CONTEXT_READY` pattern (`EventStore_LogSystem` +
flattened top-level JSON fields), not the `CANDIDATE_CREATED`
(`LifecycleEvent`) pattern.

`EVENT_TYPE_RISK_PLAN_CREATED` is appended at the very end of
`ENUM_EVENT_TYPE` (after `EVENT_TYPE_TRADE_OUTCOME_LABELED`), not
inserted mid-enum. The persisted format only ever stores/compares the
STRING form of the event type (never the raw ordinal), so insertion
would have been technically safe — appending at the end keeps that
guarantee trivially true without relying on it.

## What this commit adds

- **`Core/MLQuantAI_Enums.mqh`** (additive): `EVENT_TYPE_RISK_PLAN_CREATED`
  appended at the end of `ENUM_EVENT_TYPE`, with matching
  `EventTypeToString`/`EventTypeFromString` cases.
- **`Infrastructure/EventStore/MLQuantAI_RiskPlanEventEmission.mqh`**
  (new): `RiskPlan_ToExtraJson` (every B7 `RiskPlan` field flattened as
  top-level JSON keys via `CanonicalPrice`/`CanonicalDouble`/
  `CanonicalPercent` — the same canonical helpers `RiskPlan_HashPayload`
  uses; `plan_hash` itself is carried through verbatim on replay, never
  recomputed from this JSON). Only the B7 field group is persisted —
  the Phase A shadow fields (`decision`/`allowed`/`reject_reason`/
  `risk_schema_version`/`lot`/`risk_money`) are not separately written,
  since a `RISK_PLAN_CREATED` event only ever exists for an allowed
  plan and `lot`/`risk_money` duplicate `lot_size`/`risk_amount`.
  `RiskPlan_EmitRiskPlanCreated(const RiskPlan &p)`: returns false with
  no write attempted for an unfilled/rejected plan (`risk_plan_id == ""
  || !allowed`) or a live-session duplicate (`RiskPlanProjection_TryGet`
  already finds this `risk_plan_id` — a deliberately coarse guard, any
  existing record blocks re-emission regardless of `plan_hash`; the
  finer duplicate-vs-collision distinction belongs to replay only).
  After a successful durable write, calls
  `RiskPlanProjection_ApplyLiveRecord(p)` to keep the live registry in
  sync without requiring a replay first — the same live-sync fix B5
  Commit 5 needed for `StateProjector`.
- **`Infrastructure/EventStore/MLQuantAI_RiskPlanProjection.mqh`**
  (new): `RiskPlanProjectionRecord` (every B7 `RiskPlan` field plus
  `source_sequence_number`/`source_log_event_id`), the live in-memory
  registry (`RiskPlanProjection_Reset/_Count/_FindIndex/_TryGet/_GetAt/
  _AppendRecord`), `RiskPlanProjection_ApplyLiveRecord` (direct
  struct-to-registry apply, no JSON parsing, used by the emission
  live-sync call), the replay-path validation ladder
  (`RiskPlanProjection_ApplyLine`: line-length bound → type gate →
  `EventSerializer_ParseSystem` → required-field check → numerical
  integrity → payload-aware collision-vs-duplicate detection),
  `RiskPlanProjection_ApplyLineWithCandidates` (referential-integrity
  wrapper: orphan-candidate and candidate-hash-mismatch rejection
  against `CandidateProjection`, before ever reaching `ApplyLine`), and
  `RiskPlanProjection_RebuildFromFile` (`EventStoreValidator`-gated →
  `CandidateProjection_RebuildFromFile` on the same file as a
  referential-integrity prerequisite → own registry rebuild; any
  failure at any stage leaves the registry completely untouched).
- **`Tests/MLQuantAI_Test_B7_Commit2_RiskPlanEvent.mq5`** (new).

## Test coverage

Uses the real B5/B7 pipeline throughout (`CRT_DetectV1` →
`CRT_ToTradeCandidate` → `CRT_EmitCandidateCreated` →
`Candidate_ToRiskPlan` → `RiskPlan_EmitRiskPlanCreated`) plus real
`MARKET_CONTEXT_READY` events, so referential-integrity checks have
genuine data to check against — no fabricated/hand-written event
lines except where a test deliberately tampers a real persisted line.

- **Exactly-once emission** — a valid `RiskPlan` produces exactly one
  `RISK_PLAN_CREATED` line.
- **Live-session duplicate no-op** — re-emitting the identical plan in
  the same session returns false and writes no second event.
- **Rejected plan emits nothing** — an unfilled/`!allowed` `RiskPlan`
  (from `RiskPlan_Init`) is rejected before any store interaction.
- **Replay duplicate (same `risk_plan_id` + same `plan_hash`)** —
  no-op, registry ends with exactly one record.
- **Replay collision (same `risk_plan_id` + different `plan_hash`)** —
  whole rebuild fails, `first_error` mentions "collision".
- **Replay orphan candidate** — a `RISK_PLAN_CREATED` referencing an
  unknown `candidate_id` fails the whole rebuild, `first_error`
  mentions "orphan".
- **Replay candidate-hash mismatch** — a `RISK_PLAN_CREATED` whose
  `candidate_hash` doesn't match the real candidate's own hash fails
  the whole rebuild, `first_error` mentions "mismatch".
- **Malformed line blocks the whole rebuild** — a truncated line
  anywhere in the file fails the entire rebuild; the registry stays
  empty, not even the one good record survives.
- **Restart/crash simulation** — repeated rebuilds of the same store
  reconstruct byte-identical records (`plan_hash`/`lot_size` compared
  across two independent rebuilds).
- **Multi-session** — a store spanning two separate `EventStore_Open`/
  `Close` sessions rebuilds both plans correctly.
- **Replay field fidelity** — every field on a rebuilt record is
  compared against the original in-memory `RiskPlan`, including
  `plan_hash` itself (no drift between emission and replay).

## Bugs found and fixed during self-review, before any user test run

All three were caught by re-reading the test file, not from a reported
compile/test failure — no production code needed any change:

1. **Append-after-`EventStore_Close()`** in the candidate-hash-mismatch
   test — it originally called `EventStore_Close()` before
   `RiskPlan_EmitRiskPlanCreated(plan)`. `EventStore_AppendSystem`
   silently returns false when the store handle is invalid (no error,
   no auto-reopen), so this would have broken the test outright. Fixed
   by moving the emission call to happen while the store is still
   open, before `Close()`.
2. **Raw byte-identical line copy tripping the sequence validator
   before reaching application-level logic** — found in both the
   duplicate-no-op and collision-rejection replay tests. Both
   originally built their second line by copying the already-persisted
   line via direct `FileOpen`/`FileWriteString` calls, which carries
   the SAME `seq` number as the original. `EventStoreValidator_ValidateLines`
   rejects the whole file for a duplicate/backward sequence number
   within a session BEFORE `RiskPlanProjection`'s own duplicate-vs-
   collision detection ever runs, so both tests' assertions would have
   failed for the wrong reason. Fixed in both by resetting
   `RiskPlanProjection`'s live registry and reopening the `EventStore`
   under a genuinely fresh session (a valid, non-colliding `seq`/
   `session_id`) before re-emitting — simulating two independent
   sessions/processes rather than a corrupted single line, which is
   what each test actually means to prove, and additionally exercises
   the full end-to-end `RebuildFromFile` pipeline rather than an
   isolated `ApplyLine` call.

## Bugs found on the first real test run (63/65)

Both are test-fixture bugs; no production code changed.

1. **`Test_MalformedLine_BlocksWholeRebuild`** assumed the registry
   would be *empty* after a rebuild fails on a truncated line. It
   isn't necessarily: `RiskPlan_EmitRiskPlanCreated`'s own live-sync
   (`RiskPlanProjection_ApplyLiveRecord`) already put one record into
   this SAME global registry the moment it was called earlier in the
   test, before the rebuild was ever attempted. The actual documented
   contract (`RiskPlanProjection_RebuildFromFile`'s own header
   comment) is "left completely untouched" on failure, not "empty" —
   a stronger, more meaningful invariant than the test originally
   checked. Fixed by capturing the count before the rebuild and
   asserting it is unchanged afterward, whatever it was.
2. **`Test_ReplayFieldsMatchOriginal`** compared `stop_distance_points`,
   `rr_ratio`, `risk_amount`, and `lot_size` (all derived via
   division/multiplication) with exact `==` against the raw in-memory
   `RiskPlan` double. `stop_distance_points` failed: the value carries
   floating-point noise below `CanonicalDouble`'s 8-decimal persisted
   precision, so the round trip through the canonical JSON string is
   correctly lossy at that precision — `plan_hash` matching (which
   passed) already proves canonical fidelity exactly, since `plan_hash`
   is itself computed from the same canonical string. An exact `==`
   against the unrounded double was stricter than the canonical
   contract promises. Fixed with a `DoubleClose` helper (tolerance
   `1e-6`, comfortably above the ~5e-9 worst-case 8-decimal rounding
   bound and far below any real field-mapping bug's magnitude) for the
   four arithmetic-derived fields; pass-through fields (`planned_entry`/
   `sl`/`tp`, `risk_percent`) keep exact `==` since they carry no
   arithmetic noise.

## Explicitly out of scope for this commit

Any AI/ML scoring (B8), any execution-eligibility policy (B9), any
broker/order call, any change to `Candidate_ToRiskPlan`'s sizing
formula itself (sealed in Commit 1). Both are documented as planning-
only in `Docs/PhaseB8_B9_Roadmap_Notes.md` and run parallel to, not
gating, B7.
