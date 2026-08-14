# Phase B — B6.1: Candidate Projection / Registry

**Status: implemented, awaiting a real compile/test run before PASSED.**
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

Once confirmed on a real compile/run, B6.2 (canonical dataset export)
opens — starting with the extra_json-vs-join decision flagged above.
