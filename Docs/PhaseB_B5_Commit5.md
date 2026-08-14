# Phase B — B5 Commit 5: `CANDIDATE_CREATED` Event Emission

**Status: implemented, awaiting a real compile/test run before PASSED.**
Implements the final Commit 5 boundary (per the Commit 5 kickoff spec):

```text
TradeCandidate -> CANDIDATE_CREATED -> EventStore append
```

Does not touch the CRT detector (Commit 3, SEALED), the ctx→candidate
mapping (Commit 4, SEALED), `candidate_hash`, `root_event_id`, or any
entry/sl/tp hint — this commit's only job is getting an already-finished
`TradeCandidate` durably onto the Event Store.

## Reused, not reinvented

Phase A already sealed everything this commit needed structurally:
`LifecycleEvent` (`Infrastructure/EventStore/MLQuantAI_LifecycleEvent.mqh`),
`EventStore_LogCandidateCreated()`, and the exact idempotency pattern
(`StateProjector_TryGetState()` before deciding whether to emit) that
`MLQuantAI.mq5`'s own `RunRuntimeLifecycleSmokeTest()` already uses. No
new event-store primitive, no new idempotency mechanism, no new schema
version.

## What this commit adds

- **`Infrastructure/EventStore/MLQuantAI_EventStore.mqh`**
  (additive signature extension to a sealed Phase A function):
  `EventStore_LogCandidateCreated(const TradeCandidate &c, string
  extraJson="")` — the new `extraJson` parameter defaults to `""`, so
  every existing Phase A caller (`MLQuantAI.mq5`'s Step 8.5 smoke test,
  `Test_DummyLifecycle`/`Test_BrokerReconciliation`/
  `Test_EventStoreRecovery`/`Test_ReplayIntegrity`) is unaffected. Same
  "caller-supplied JSON fragment" convention `EventStore_LogTransition`
  already uses for its own `extraJson` parameter.
- **`Strategies/MLQuantAI_CRT_V1_EventEmission.mqh`** (new):
  `CRT_EmitCandidateCreated(const TradeCandidate &c, int digits)` — the
  Commit 5 boundary function — plus `CRT_CandidateCreatedExtraJson`/
  `CRT_StringArrayToJson`.

## The `extra_json` fragment

`LifecycleEvent` has no native field for `context_event_id`/
`context_hash`/`candidate_hash`/`detector_hash`/`trigger_reason_mask`/
`trigger_reasons[]` — those are B5-specific `TradeCandidate` fields, and
extending `LifecycleEvent` itself for one strategy's fields would leak
CRT-specific shape into a generic Phase A record every other strategy
also uses. Instead, `CRT_CandidateCreatedExtraJson()` builds them as a
JSON fragment passed through the existing `extra_json` mechanism —
`candidate_id`/`root_event_id`/`strategy_id` are already native
`LifecycleEvent` fields and are **not** repeated in the fragment.

No separate `event_hash` was introduced. `candidate_hash` (Commit 4)
already is the canonical fingerprint of this exact candidate's
deterministic content, and `BaseEvent.log_event_id` (session_id +
sequence_number, Phase A sealed) already uniquely identifies this
specific append. Hashing the event a second time would be redundant, not
additional signal — the same reasoning `candidate_hash` itself already
uses to skip `signal_time`/`expiry_time`.

## Idempotency — and a real gap this commit had to close

The obvious first design — check `StateProjector_TryGetState()` before
writing, exactly like `RunRuntimeLifecycleSmokeTest()` — has a gap that
smoke test never hits: `StateProjector` is populated **only** by
`ReplayEngine_Run()`/`StateProjector_Apply()`, never by
`EventStore_LogCandidateCreated()` itself. The smoke test only runs once
per `OnInit`, after startup replay has already populated the projector
from prior sessions, so it never calls the check twice in the same live
session without a replay in between. CRT_V1's real usage is different:
the detector runs once per newly closed trigger-timeframe bar, and nothing
prevents two calls for the same still-current bar (e.g. `OnTick` firing
more than once before the bar advances) from both finding
`StateProjector_TryGetState()` empty and both durably writing a
`CANDIDATE_CREATED` — a duplicate genesis event `StateProjector_Apply`
itself would then reject as corruption on the very next replay.

**Fixed**: `CRT_EmitCandidateCreated()` calls `StateProjector_Apply()` on
an equivalent genesis `LifecycleEvent` immediately after a successful
durable write — the same call `ReplayEngine` makes per line, just applied
live instead of only at replay time. This keeps the in-memory guard
correct within a session without requiring an intervening replay, and
costs nothing on the next real replay (`ReplayEngine_Run` always calls
`StateProjector_Reset()` first, so live-applied entries are simply
overwritten by the authoritative from-file replay).

This fix is scoped entirely to the new `Strategies/` file — Phase A's
`EventStore_LogCandidateCreated()` itself is untouched beyond the
additive `extraJson` parameter, so no other caller's behavior changes.

## Test coverage (`Tests/MLQuantAI_Test_CRT_V1_CandidateCreatedEvent.mq5`)

Every Commit 5 test gate from the kickoff spec:

- Detected CRT candidate emits exactly one `CANDIDATE_CREATED` event.
- Event carries `candidate_id`/`root_event_id`/`context_event_id`/
  `context_hash`/`candidate_hash`/`detector_hash`, all checked against
  the persisted JSON line, not just the in-memory struct.
- Event payload preserves ordered `trigger_reasons[]` (checked by
  position, not just set membership).
- Duplicate same `candidate_id` (two `CRT_EmitCandidateCreated` calls,
  same session, no replay in between) does not append a second creation
  event — the exact live-session gap described above.
- Non-detection (`candidate_id == ""`) emits no event and adds no line
  to the store.
- Reopening EventStore (`EventStore_Close()` then `ReplayEngine_Run()`)
  reconstructs `CANDIDATE_CREATED` via `StateProjector_TryGetState()`.
- Replayed fields (`candidate_id`/`root_event_id`/`context_hash`/
  `candidate_hash`/`detector_hash`/`trigger_reason_mask`/`entry_hint`/
  `sl_hint`/`tp_hint`) exactly equal the original, read back from a
  closed-and-reopened store.
- Replaying the same store twice in a row is idempotent (`ReplayEngine_Run`
  always resets the projector first, so this holds by construction —
  verified directly rather than just assumed).
- No risk/execution/AI/broker-state interaction — confirmed by source
  inspection of `MLQuantAI_CRT_V1_EventEmission.mqh` (no `RiskPlan`/AI
  score/`ExecutionRequest`/`OrderSend`/`CTrade`/broker reconciliation/
  position/deal/order reads/candidate state transition beyond
  `CANDIDATE_CREATED` anywhere in the file).

Fixture collision note: every test builds its candidate from a distinct
`t0` (via a `dayOffset` parameter added to the shared fixture builder) —
`root_event_id` derives from `mss_confirmation_bar_time`, not from
`context_event_id`/`context_hash`, so two fixtures sharing the same bar
times would silently collide on the same `candidate_id` across unrelated
tests even with different context lineage. Caught during test authoring,
fixed before this commit shipped.

## Commit 5 seal criteria

- `MLQuantAI_Test_CRT_V1_CandidateCreatedEvent.mq5` = ALL PASS
- `MLQuantAI_Test_CRT_V1_ToTradeCandidate.mq5` (regression — nothing here
  should be affected) = ALL PASS
- No `RiskPlan`/AI score/`ExecutionRequest`/`OrderSend`/`CTrade`/broker
  reconciliation/position/deal/order reads/candidate state transition
  beyond `CANDIDATE_CREATED` anywhere in this commit

Once confirmed on a real compile/run, this closes B5 Commit 5. Per the
kickoff spec, what remains is final B5 integration/replay QA to seal the
whole B5 phase (Commits 1–5 together) before B6.
