# Phase B — B6.1: Candidate Projection / Registry

**Status: hardened, awaiting a real compile/test run before PASSED.**
The original 104/104 pass proved B6.1's registry/projection mechanics in
isolation - it did not prove B6 end-to-end, and it did not adversarially
attack the projection. This revision adds the hardening pass below
before B6 sign-off; see "Hardening pass" further down for the full
gate-by-gate list. B6 as a whole remains IN REVIEW / NOT CLOSED - dataset
export (B6.2), the dataset integrity validator (B6.3), and full-phase
regression are all still outstanding.
Opens B6 ("Candidate Dataset QA & Analytics") per the B6 kickoff spec.
B6 is not a phase for making the system "trade better" — it's the phase
that answers, with evidence, whether CRT_V1 produces candidates that are
reliable, replayable, analyzable, and good enough to design a risk
contract on top of (B7). B6.1 is the first, smallest piece: prove a
read-only candidate registry can be built — and rebuilt, and rebuilt
again — purely from what's already durably on the Event Store.

## What this commit adds

- **`Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh`**
  (new): `CandidateProjectionRecord`, `CandidateProjection_ApplyLine`,
  `CandidateProjection_TryGet` (the spec's `CandidateLookup`),
  `CandidateProjection_RebuildFromFile`, `CandidateProjectionReport`.
- **`Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh`**:
  `EventSerializer_GetStringArray` — a generic `"key":["a","b"]` reader,
  promoted from what had been the same ~15-line bracket-depth pattern
  hand-duplicated in three separate test files. B6.1's projection is the
  first *production* (non-test) code that needs to read
  `trigger_reasons[]` back out of a persisted line, which is the right
  moment to stop copy-pasting it.
- **`Tests/MLQuantAI_Test_CandidateProjection.mq5`** (new).

## Strictly additive, strictly read-only

No B5 `Strategies/` file is touched or modified. `CandidateProjection`
only ever reads persisted lines back (via `EventStore_ReadAllLines`, the
same primitive `ReplayEngine`/the Validator already use) — it never
calls `CRT_DetectV1`/`CRT_ToTradeCandidate`/`CRT_EmitCandidateCreated`,
never touches `CopyRates`/`iTime`/`AccountInfo*`/`TimeCurrent()`, and
never appends anything to the Event Store. This matches B6's own stated
rule set precisely: no CRT rule changes, no execution/risk/AI
dependency, everything derived from what's already durable.

## Registry record shape — and a real gap flagged for B6.2

`CandidateProjectionRecord` carries every field a persisted
`CANDIDATE_CREATED` line actually has today: the native `LifecycleEvent`
fields (`candidate_id`/`root_event_id`/`correlation_id`/`strategy_id`)
plus everything Commit 5's `CRT_CandidateCreatedExtraJson` added
(`context_event_id`/`context_hash`/`candidate_hash`/`detector_hash`/
`candidate_schema_version`/`side`/`setup_anchor_bar_time`/
`expiry_after_bars`/`expiry_time`/`entry_hint`/`sl_hint`/`tp_hint`/
`trigger_reason_mask`/`trigger_reasons[]`).

**B6.2's canonical dataset column list (from the B6 kickoff spec) asks
for more than this**: `instrument_id`, `trigger_timeframe`,
`swept_level`, `mss_confirmation_price`, `resolved_zone_kind`,
`resolved_zone_low`, `resolved_zone_high`, `news_decision_hash`,
`news_snapshot_identity` are not in `CandidateProjectionRecord` because
**no persisted `CANDIDATE_CREATED` event carries them yet**:

- `swept_level`/`mss_confirmation_price`/`resolved_zone_kind`/
  `resolved_zone_low`/`resolved_zone_high` only ever live on
  `CRTDetectionResult` — Commit 4's `CRT_ToTradeCandidate` deliberately
  did not copy them onto `TradeCandidate` (contract section 12's fill
  list doesn't list them either), and `CRTDetectionResult` itself is
  never persisted.
- `instrument_id`/`trigger_timeframe`/`news_decision_hash`/
  `news_snapshot_identity` live on `MarketContext`, not `TradeCandidate`
  — but `TradeCandidate.context_event_id`/`context_hash` already exist
  specifically "so every candidate can be traced back to the exact
  snapshot it came from" (`MarketContext.mqh`'s own stated B1 design
  intent), which is a join key, not a duplication.

**This is deliberately left as an open decision for B6.2's kickoff, not
silently resolved here**: either (a) extend Commit 5's `extra_json`
additively with these fields (a small, low-risk fix to already-sealed
Commit 5 code), or (b) have B6.2's export join
`CANDIDATE_CREATED`/`context_event_id` against the corresponding
`MARKET_CONTEXT_READY` event, which already carries all four
`MarketContext`-owned fields. B6.1 itself doesn't need either — none of
its six test gates depend on these columns — so resolving it now would
be scope creep into B6.2's own commit.

## Fail-closed behavior

`CandidateProjection_ApplyLine` returns `false` (rejecting the line,
registry unchanged) only for genuine corruption: an unparsable line, a
`CANDIDATE_CREATED`-typed line whose `from_state`/`to_state` isn't the
`CREATED`/`CREATED` genesis shape, or an empty `candidate_id`. It
returns `true` (a no-op, not an error) for lines that are legitimately
irrelevant to this projection (any non-`CANDIDATE_CREATED` event) or
already-seen (`candidate_id` already registered) — the same "duplicate
genesis is a no-op, not a crash" philosophy `StateProjector_Apply`
already uses one layer up.

## Test coverage (`Tests/MLQuantAI_Test_CandidateProjection.mq5`)

Uses the real B5 pipeline (`CRT_DetectV1` → `CRT_ToTradeCandidate` →
`CRT_EmitCandidateCreated`) to produce two genuine candidates, then
exercises only `CandidateProjection`:

- One event → one registry record.
- Same event applied twice → still one record (idempotent, reason names
  it explicitly as a duplicate).
- Two candidates → two independently lookupable records.
- Three genuinely malformed/corrupt lines (bad from/to shape, empty
  `candidate_id`, unparsable garbage) all fail closed with a non-empty
  audit reason, and none of them grow the registry.
- Registry rebuilt from `CandidateProjection_RebuildFromFile` equals the
  incrementally-built registry (record-for-record, hash-for-hash).
- Replaying the same store twice produces identical registries (line
  counts and every hash match exactly across both rebuild passes).
- Every field — including `candidate_hash`/`detector_hash` and
  `trigger_reasons[]`'s exact order — is checked against the original
  `TradeCandidate`, not just presence.

## B6.1 seal criteria

- `MLQuantAI_Test_CandidateProjection.mq5` = ALL PASS
- `MLQuantAI_Test_CRT_V1_CandidateCreatedEvent.mq5` (regression —
  nothing here should be affected) = ALL PASS
- No B5 `Strategies/` file touched; no live market/broker/account call
  anywhere in `MLQuantAI_CandidateProjection.mqh`

## Hardening pass (post-104/104 QA review)

The original version only checked structural well-formedness before
registering a record (parsable, genesis shape, non-empty
`candidate_id`) and treated **any** repeat `candidate_id` as an
idempotent duplicate. That would have silently hidden a genuine
deterministic-ID collision — two different candidates somehow sharing
one `candidate_id` — behind a "nothing to see here" no-op. This pass
closes that and every other gap the QA hardening table named.

### What changed in `CandidateProjection.mqh`

- **Collision vs. duplicate** (the most important fix): `ApplyLine` now
  compares the incoming line's `candidate_hash` against an already-
  registered record's. Identical → idempotent no-op, unchanged.
  Different → **rejected as a conflict**, registry unchanged, and the
  reason string explicitly says "collision"/"conflict", never
  "duplicate" — a corrupted or colliding record can never be swallowed
  silently.
- **Schema-version gating**: empty or any `candidate_schema_version`
  other than the one this build knows (`MLQUANTAI_CANDIDATE_SCHEMA_V1`)
  is rejected.
- **Required-field presence**: `root_event_id`/`context_event_id`/
  `context_hash`/`candidate_hash`/`detector_hash` must all be non-empty.
- **Side integrity**: `side` must be exactly `"BUY"` or `"SELL"` — the
  original version's ternary silently mapped anything-not-`"BUY"` to
  SELL, which would have hidden a corrupted side value. Now rejected
  outright, never coerced.
- **Time integrity**: `setup_anchor_bar_time`/`expiry_time` must be
  positive, `expiry_after_bars` must be positive, and `expiry_time` must
  be strictly after `setup_anchor_bar_time`.
- **Numerical integrity**: `entry_hint`/`sl_hint`/`tp_hint` must all be
  finite (`MathIsValidNumber`) and positive, and must satisfy the
  side-specific SL/TP ordering CRT_V1's own frozen formulas guarantee
  (`sl < entry < tp` for BUY, `sl > entry > tp` for SELL).
- **Reason-mask/reason-labels consistency** (CRT_V1-specific — see the
  flagged dependency note at the top of the file): the frozen bit-0/
  bit-1 and bit-4/bit-5 XOR invariant (contract section 2) must hold,
  `CLOSE_BACK_INSIDE`/`MSS_CONFIRMED` must both be set, no bit outside
  0–7 may be set, and `trigger_reasons[]` must be byte-for-byte what
  `CRT_ReasonLabelsFromMask` would canonically produce for that mask —
  same content, same order, no duplicates, no unknown labels. A mismatch
  is rejected, never silently re-canonicalized.
- **Resource limits**: a line over 64KB is rejected before parsing even
  starts; a `trigger_reasons[]` array with more than the 8 possible
  entries is rejected.
- **Referential integrity** (new functions, not folded into `ApplyLine`
  itself — see the file's own note on why): `CandidateProjection_
  CollectContextHashes` scans a file for every `MARKET_CONTEXT_READY`
  event's `context_event_id`→`context_hash` pair;
  `CandidateProjection_ApplyLineWithContext` rejects a candidate whose
  `context_event_id` has no match (orphan) or whose `context_hash`
  doesn't match the referenced context event (tampered/mismatched
  lineage) — **before** `ApplyLine` is ever called, so a referentially
  broken candidate never reaches the registry no matter how well-formed
  it otherwise looks.
- **Ordering/atomicity**: `CandidateProjection_RebuildFromFile` now runs
  `EventStoreValidator_ValidateLines` (Phase-A-sealed, reused rather than
  reinvented) **first**. If the file has any malformed line, truncated
  line, or out-of-order/duplicate/gapped sequence number in any session,
  the entire rebuild is refused and **the current registry is left
  completely untouched — not even `Reset()`**. A corrupt store can never
  produce a silently-partial dataset; one bad line anywhere blocks the
  whole file, not just that line.

### Test coverage added

`Tests/MLQuantAI_Test_CandidateProjection.mq5` now also builds a real
`MARKET_CONTEXT_READY` event per candidate (the same call
`FeatureEngine_BuildContext` itself makes) — necessary for referential
integrity to have real data to check, and a genuine step toward the
end-to-end shape B6's sign-off gate wants. New coverage:

- **Collision**: a tampered `candidate_hash` on an otherwise-identical
  `candidate_id` is rejected as a conflict, with the original record
  left untouched.
- **Schema**: unknown and empty `candidate_schema_version` both rejected.
- **Time**: inverted expiry and zero `expiry_after_bars` both rejected.
- **Numerical**: negative/zero `entry_hint`, and a BUY SL/TP ordering
  violation, both rejected.
- **Enum**: `side="SIDEWAYS"` rejected, not coerced to SELL.
- **Trigger reasons**: an all-8-bits mask (violates both XOR invariants)
  and a `trigger_reasons[]` array that doesn't match its mask are both
  rejected.
- **Resource limits**: a 20-element `trigger_reasons[]` array against an
  otherwise-valid 4-bit mask is rejected.
- **Referential integrity**: an orphan candidate (context never logged)
  and a context-hash-mismatched candidate (context logged, but the
  candidate's own `context_hash` tampered) are both rejected/quarantined
  via a dedicated two-file test.
- **Ordering**: a synthetic file with a duplicate sequence number blocks
  the whole rebuild; the registry is left exactly as it was before the
  attempt.
- **Atomicity**: a clean 2-candidate file rebuilds successfully, then a
  single truncated line appended to the end blocks the *entire* rebuild
  — the registry still shows the last known-good state, not a partial
  3rd entry or an empty reset.
- **Restart/crash simulation**: 2 real candidates, then a simulated
  crash (a truncated line appended, mimicking a process dying mid-
  `FileWriteString`) — rebuild correctly refuses; after the truncated
  tail is stripped (what a real recovery step does), a clean rebuild
  reconstructs exactly the 2 real candidates with **no ghost third**.
- **Multi-session**: two `EventStore_Open`/`Close` cycles in one store
  (two genuinely different `session_id`s) — both candidates present,
  correct per-session sequence validation, no cross-contamination.
- **Replay at scale**: 25 candidates in one store — rebuild applies all
  25, every hash matches, and a second rebuild is identical to the
  first.
- **Hash integrity** (`CRT_CandidateHash` mutation sweep — B5 code,
  tested here for the first time this exhaustively): every
  decision-bearing field in `CRT_CandidateHashPayload` (`candidate_id`,
  `root_event_id`, `strategy_id`/`name`/`version`, `side`,
  `context_event_id`/`context_hash`, `setup_anchor_bar_time`,
  `expiry_after_bars`, `entry_hint`/`sl_hint`/`tp_hint`,
  `trigger_reason_mask`, `detector_hash`, `candidate_schema_version`)
  independently moves the hash when mutated.
- **Hash exclusion** (the explicit whitelist the QA table asked for):
  `score`/`confidence`/`compatible_regime`/`regime_rules_version`/
  `state`/`last_reason`/`correlation_id`/`parent_candidate_ids`/`entry`/
  `sl`/`tp`/`rr`/`atr`/`stop_distance`/`signal_time`/`expiry_time`/
  `in_killzone`/`news_risk`/`has_liquidity_sweep`, and the
  `trigger_reasons[]` array's own content (only `trigger_reason_mask` is
  hashed, not the label array) — none of these move `candidate_hash`
  when mutated.

### What this hardening pass does NOT cover (still outstanding for B6 sign-off)

Per the B6 sign-off gate:

1. **Dataset export determinism** (B6.2 — not started): byte-identical
   export/hash for the same store, stable row/column ordering. This
   commit does not build an exporter.
2. **`CandidateDatasetValidator`** (B6.3 — not started): the descriptive
   PASS/WARN/FAIL dataset-level report (distribution, coverage gaps,
   warn-level checks like one-sided BUY/SELL or low sample counts) is a
   separate artifact from this commit's hard fail-closed ingestion gate.
   Some semantic checks now overlap (e.g. the FVG/OB and sweep-low/high
   XOR checks exist both here and in B6.3's planned hard-FAIL list) —
   deliberate defense in depth, not a substitute for B6.3's own dataset-
   wide sweep.
3. **Full regression**: Phase A through B6 all green, run together, has
   not been executed as one pass.
4. **Static audit**: confirming B6 introduces no risk/execution/AI/
   broker-interaction code — true by construction (no such calls exist
   anywhere in `MLQuantAI_CandidateProjection.mqh`, confirmed by source
   inspection), but not yet a written, standalone audit artifact.

Once this hardening suite is confirmed PASSED on a real compile/run,
B6.2 (canonical dataset export) opens — starting with the extra_json-
vs-join decision flagged above.
