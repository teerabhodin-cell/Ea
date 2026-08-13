# Changelog

All notable changes to MLQuantAI. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
`MLQUANTAI_EA_VERSION` in `Include/MLQuantAI/Core/MLQuantAI_VersionRegistry.mqh`.

## [0.1.0] - Phase A

### Added
- Core contracts: `MarketContext`, `TradeCandidate`, `AIResult`,
  `RiskPlan`, `ExecutionResult`, `RuntimeState`, `AccountSnapshot`,
  `ExternalContext` - each carrying its own schema/version field.
- `ENUM_CANDIDATE_STATE` lifecycle state machine
  (`StateMachine_CanTransition`), enforcing the full CREATED/SUBMITTED
  branching tree and rejecting every illegal transition (including the
  explicit "EXECUTED -> CREATED never happens" / "MERGED -> SUBMITTED
  never happens" rules).
- `ENUM_REASON_CODE`, `ENUM_AI_DECISION`, `ENUM_RISK_DECISION`,
  `ENUM_EVENT_TYPE`, `ENUM_EVENT_STORE_HEALTH`.
- Deterministic ID generation (`Ids_RootEventId`, `Ids_CandidateId`,
  `Ids_CorrelationId`) via SHA-256 (`CryptEncode`) over the identifying
  fields - no `MathRand()`/`GetTickCount()` involved, so the same market
  event always hashes to the same IDs on any run. `Ids_NewRuntimeSessionId`
  stays intentionally non-deterministic (identifies one specific run).
- Append-only JSONL Event Store (`EventStore.mqh`): write-before-commit
  ordering (in-memory candidate state only advances after the event is
  confirmed durably written and flushed), `EventStoreValidator`
  (sequence contiguity per session, schema version, truncation
  detection), `EventStoreHealth` (Safe Mode - blocks new candidates only,
  never force-closes positions), `ReplayEngine` + `StateProjector`
  (reconstructs candidate state and `RuntimeState` from the log alone,
  independently re-validating every transition against the state
  machine).
- `MLQuantAI_BrokerReconciliation.mqh`: compares replayed EXECUTED
  candidates against real MT5 position state
  (`PositionsTotal`/`POSITION_COMMENT`).
- `MLQuantAI.mq5`: the first real EA - opens/validates/replays the Event
  Store and runs broker reconciliation in `OnInit`, logs
  `SYSTEM_STARTED`/`SYSTEM_STOPPED` with the full version registry. No
  strategies, no AI, no order logic yet.
- `Tests/`: `MLQuantAI_Test_DummyLifecycle`, `MLQuantAI_Test_ReplayIntegrity`,
  `MLQuantAI_Test_EventStoreRecovery`, `MLQuantAI_Test_BrokerReconciliation`
  (simulated broker state), `MLQuantAI_Test_StateMachine`,
  `MLQuantAI_Test_DeterministicId`.

### Fixed (found via review + real test runs, not just self-review)
- `EventStore_LogTransition`/`LogCandidateCreated` used to mutate
  in-memory candidate state *before* confirming the event write was
  durable - fixed so a failed write leaves the candidate untouched and
  trips Safe Mode instead.
- `ReplayEngine` used to skip every `SystemEvent` line, so
  `RuntimeState.runtime_session_id`/`session_start_time`/`safe_mode` never
  actually got reconstructed by replay - added `StateProjector_ApplySystem`.
- `EventSerializer_GetStr` stopped at the first quote character including
  an *escaped* one inside a value, silently truncating strings like
  `broker said \"invalid stops\"` - rewritten as a char-by-char scan that
  respects escape sequences.
- `schema_version` was declared in `VersionRegistry` but never actually
  written into serialized events - added, and the Validator now flags a
  missing/mismatched version as corruption.
- The three `EventSerializer_Parse*` functions never read the `"ts"`
  field back out of a line, so every replayed event had `ts=0` regardless
  of what was written - caught by `MLQuantAI_Test_ReplayIntegrity`
  actually failing (15/16) on a real run.

### Not built yet
Strategies (CRT/SMC/Trend Pullback/Breakout/Silver Bullet/Mean
Reversion), Regime Router, Candidate Pool/Dedup/Arbitration, Global Risk
Manager, Execution Engine, Trade Manager, real MT5 Data Hub/Feature
Engine/Session Engine/News Engine, XGBoost/ONNX AI Meta-Filter, External
Context data (DXY/US10Y/VIX/News/Sentiment). All Phase B+.
