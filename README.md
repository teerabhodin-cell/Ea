# MLQuantAI

Quant trading framework for XAUUSD on MT5. Strategies produce candidates,
AI (later) advises, the risk manager is final authority, and the Event
Store is the historical truth of the whole system.

```
Strategy ≠ sends orders
AI ≠ creates Buy/Sell
Risk Manager = final authority
Event Store = historical truth
Broker / MT5 = live reality
```

## Build order

```
Phase A: Core Engine        <- current phase
Phase B: Trading Engine
Phase C: Learning Engine
Phase D: External Context & Expansion
```

Every phase has a Definition of Done. Do not start the next phase's
strategy/AI work until the current one's DoD passes.

```
No AI before a candidate dataset exists.
No multiple strategies before Core replay works.
No external data before the rule-based baseline runs.
No live money before a forward test passes.
```

## Phase A - Core Engine

Proves that a candidate can be created, appended to an event log, and
have its state fully reconstructed by replaying that log alone - with no
market data, no strategies, and no AI involved yet.

```
Core Contracts (Include/MLQuantAI/Core/)
  Enums, ReasonCodes, VersionRegistry, IDs (deterministic, SHA-256 based),
  AccountSnapshot, ExternalContext, MarketContext, TradeCandidate,
  AIResult, RiskPlan, ExecutionResult, RuntimeState, StateMachine.

Event Store (Include/MLQuantAI/Infrastructure/EventStore/)
  BaseEvent / LifecycleEvent / ExecutionEvent / SystemEvent structs,
  EventSerializer (hand-rolled JSONL, closed-format parser),
  EventStore (append-only, write-before-commit ordering, FileFlush every
  write), EventStoreValidator (sequence/schema/truncation checks),
  EventStoreHealth (Safe Mode), ReplayEngine + StateProjector (folds the
  log back into candidate states and RuntimeState).

Broker Reconciliation (Include/MLQuantAI/Infrastructure/)
  Compares replayed EXECUTED candidates against real MT5 position state
  (PositionsTotal / POSITION_COMMENT carrying correlation_id). Always
  reconciles trivially today since no Execution Engine exists yet to open
  real positions - the comparison logic itself is real and MT5-backed.

MLQuantAI.mq5 (repo root)
  The actual EA: opens/validates/replays the Event Store and runs broker
  reconciliation in OnInit, logs SYSTEM_STARTED/SYSTEM_STOPPED with full
  version info. No strategies, no AI, no order logic - OnTick is a no-op.

Tests/ (standalone MQL5 Scripts, run individually via Navigator)
  MLQuantAI_Test_DummyLifecycle.mq5, MLQuantAI_Test_ReplayIntegrity.mq5,
  MLQuantAI_Test_EventStoreRecovery.mq5,
  MLQuantAI_Test_BrokerReconciliation.mq5 (simulated broker state -
  contract-level, since no Execution Engine exists to produce real fills),
  MLQuantAI_Test_StateMachine.mq5, MLQuantAI_Test_DeterministicId.mq5.
```

### Candidate lifecycle

```
CANDIDATE_CREATED
    +-- CANDIDATE_ROUTED_OUT
    +-- CANDIDATE_MERGED
    +-- CANDIDATE_REJECTED_BY_ARBITRATOR
    +-- CANDIDATE_REJECTED_BY_AI
    +-- CANDIDATE_REJECTED_BY_RISK
    +-- CANDIDATE_EXPIRED
    +-- CANDIDATE_SUBMITTED
             +-- CANDIDATE_EXECUTED
             +-- CANDIDATE_REJECTED_BY_BROKER
             +-- CANDIDATE_ERROR
```

Every arrow above is enforced by `StateMachine_CanTransition()` and
re-checked independently during replay (`StateProjector_Apply()`) - a
transition that was legal at write time is checked again at replay time
against the projector's own tracked state, which is how tampering or an
out-of-order/corrupted line gets caught.

### Safe Mode

Trips when the Event Store fails validation, a durable write fails, or
broker reconciliation finds a mismatch. Blocks new candidates only - it
never force-closes existing positions, since a corrupted log is a
bookkeeping problem, not proof that open positions are unsafe, and any
real position already carries its own broker-side SL/TP independent of
the Event Store.

## Not built yet (Phase B+)

CRT / SMC / Trend Pullback strategy logic, the Regime Router, Candidate
Pool + Deduplication + Arbitration, the Global Risk Manager, the
Execution Engine, the Trade Manager, real MT5 price/indicator/session/
calendar Data Hub, XGBoost/ONNX AI Meta-Filter, and all External Context
(DXY/US10Y/VIX/News/Sentiment) data.

## Install (for testing Phase A)

1. Copy `Include/MLQuantAI/` into `MQL5/Include/MLQuantAI/`.
2. Copy `MLQuantAI.mq5` into `MQL5/Experts/`.
3. Copy everything in `Tests/` into `MQL5/Scripts/`.
4. Compile all of it in MetaEditor.
5. Run each `Tests/MLQuantAI_Test_*` script once (drag onto any chart) and
   check the Experts log for `ALL PASS`.
6. Attach `MLQuantAI.mq5` to a chart (or run it in Strategy Tester) and
   confirm the chart comment shows the version and Safe Mode status, and
   the Experts log shows `SYSTEM_STARTED` with the full version registry.
