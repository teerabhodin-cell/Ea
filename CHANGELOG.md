# Changelog

All notable changes to MLQuantAI. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
`MLQUANTAI_EA_VERSION` in `Include/MLQuantAI/Core/MLQuantAI_VersionRegistry.mqh`.

## [Unreleased] - Phase B B5 Commit 2: Context Window + CRT_V1 Domain Models

Implements what Docs/PhaseB_B5_CRTContract.md (Commit 1, FROZEN after 3
QA review rounds) froze. No detection rule logic - no CRT_IsSweepLow/
CRT_ConfirmMSS/CRT_FindFVG/CRT_FindOrderBlock - that's Commit 3.

### Added
- `Market/MLQuantAI_MarketContext.mqh`: `trigger_tf_recent[]` (additive)
  - last `MLQUANTAI_CRT_V1_LOOKBACK_BARS` closed bars on
  `trigger_timeframe`, oldest first, folded into both
  `MarketContext_HashPayload()` and `MarketContext_ToJsonFragment()`.
  `MarketContext_RatesArrayToJson`/`_RatesArrayFromJson`/`_RatesFromJson`
  - the array counterpart to the existing single-bar
  `MarketContext_RatesToJson`, self-contained (no EventSerializer
  dependency), same convention `NewsSnapshot.mqh` already uses.
- `Market/MLQuantAI_FeatureEngine.mqh`: `FeatureEngine_BuildContext()`
  captures `trigger_tf_recent[]` via one `CopyRates(..., 1,
  MLQUANTAI_CRT_V1_LOOKBACK_BARS, ctx.trigger_tf_recent)` call - a plain
  array, so `CopyRates` already fills it oldest-first with no manual
  reversal.
- `Core/MLQuantAI_ContractVersions.mqh`: `MLQUANTAI_CRT_V1_RULES_VERSION
  = "CRT_V1"`.
- `Strategies/MLQuantAI_CRT_V1_Contract.mqh` (new file, new `Strategies/`
  directory): every B5-frozen parameter as `#define`s, the 8
  `CRT_REASON_BIT_*` bit constants, `CRT_ReasonBitLabel`/
  `CRT_ReasonLabelsFromMask` (ascending-bit-order label vocabulary),
  `CRTDetectionResult` + `_Init`, `CRT_DetectorHash` (frozen payload/
  field order/numeric formatting, a pure function of its arguments).
- `Tests/MLQuantAI_Test_CRTContextWindow.mq5`: real-pipeline window
  rules (size, ordering, anchor equality, no forming-bar, determinism
  across rebuilds), pure-function hash-sensitivity and JSON round-trip
  tests, a persisted-payload replay test, and CRT_V1 domain-model tests
  (reason label ordering, detector_hash sensitivity, Init defaults).
- `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`: 2 new payload-
  completeness checks for `trigger_tf_recent[]`.

## [Unreleased] - Phase B B4 seal hardening

Two DoD gates from the original B4 pass weren't genuinely runtime-tested:
`Test_Seal_ReplayNeverCallsSources` only asserted `Check(true, "enforced
by construction")`, and additive schema evolution was never exercised at
all. See `Docs/PhaseB_B4_NewsParity.md`.

### Added
- `Market/MLQuantAI_NewsSource.mqh` / `Market/MLQuantAI_NewsCanonicalizer.mqh`:
  `forecast`/`actual`/`previous` additive fields on `RawNewsEvent`/
  `NormalizedNewsEvent` (both "" by default, not CSV columns - the frozen
  7-column format is unchanged). Folded into `News_SnapshotIdentity()`'s
  payload; deliberately excluded from `News_DecisionHash()` and from
  `NewsSnapshot`/`News_ToSnapshot()` itself.
- `Market/MLQuantAI_NewsEngine.mqh`: `g_NewsEngine_BuildCallCount` -
  increments once per `NewsEngine_Build()` call, turning "replay never
  touches a source" from an architectural claim into something a test can
  mechanically check.
- `Tests/MLQuantAI_Test_NewsReplayIsolation.mq5`: builds a `MarketContext`
  via the pure canonicalizer pipeline only (no `INewsSource` touched),
  persists `MARKET_CONTEXT_READY`, closes the store, re-opens a fresh
  handle, and asserts the replayed `news_decision_hash`/
  `news_snapshot_identity`/`context_hash`/`NewsSnapshot[]` match exactly
  what was computed before persisting - and that `g_NewsEngine_
  BuildCallCount` never moved across the whole sequence.
- `Tests/MLQuantAI_Test_NewsSchemaEvolution.mq5`: additive `forecast`/
  `actual`/`previous` metadata moves `news_snapshot_identity` but never
  `news_decision_hash`/`context_hash`; `normalized_event_key` stays
  stable regardless; the frozen V1 CSV fixture still loads/normalizes
  correctly (new fields read back empty, not misaligned/garbage) after
  the schema grew.

### Removed
- `Tests/MLQuantAI_Test_NewsParity.mq5`: `Test_Seal_ReplayNeverCallsSources`
  - superseded by `Test_NewsReplayIsolation.mq5`'s runtime-verified check.

## [Unreleased] - Phase B B4: News Parity Layer

One Raw -> Normalize -> Dedup -> Sort/Select pipeline shared by the live
MT5 Economic Calendar and a deterministic Tester-only CSV source, so
neither source can drift into its own interpretation of "the same news
event". See `Docs/PhaseB_B4_NewsParity.md`. Still no CRT/`TradeCandidate`/
execution code touched.

### Added
- `Market/MLQuantAI_NewsSource.mqh`: `RawNewsEvent` struct + `INewsSource`
  interface (`ReadRawEvents`/`SourceKind`) - the only shape either source
  is allowed to produce; no normalization at this layer.
- `Market/MLQuantAI_NewsCanonicalizer.mqh`: the pipeline. `NormalizedNewsEvent`,
  `News_NormalizeTitle`/`News_NormalizeImpact`/`News_NormalizeTimeUtc`,
  `News_MakeCanonicalEventKey`, `News_ComputeMinutesToEvent` (truncates
  toward zero both signs), `News_Deduplicate` (priority -> revision_timestamp
  -> lexical source_kind tie-break, fails loudly on an unresolved conflict),
  `News_SortAndSelect` (frozen 24h/24h/top-10 window), `News_DecisionHash`
  (decision-relevant fields only, source-independent) and
  `News_SnapshotIdentity` (full lineage, deliberately source-dependent -
  the B5 audit trail).
- `Market/MLQuantAI_NewsCoverageValidator.mqh`: `News_ValidateCoverage` -
  hard fail-closed gate (not advisory) on a source's raw data not fully
  covering a requested range.
- `Market/MLQuantAI_CsvStaticNewsSource.mqh`: `CsvStaticNewsSource` -
  frozen 7-column CSV format (`Common\Files`), fails closed on missing
  file/bad schema version/any malformed row - never skips a bad row.
- `Market/MLQuantAI_LiveCalendarNewsSource.mqh`: `LiveCalendarNewsSource` -
  wraps `CalendarValueHistory`/`CalendarEventById`/`CalendarCountryById`,
  routes through the same canonicalizer, fails closed (no silent fallback)
  on a calendar read failure.
- `Market/MLQuantAI_NewsEngine.mqh`: `NewsEngine_Build(anchorTime)` -
  the orchestrator; routes to CSV (Tester) or Live (else) by
  `MQL_TESTER`, runs the full pipeline, returns `NewsEngineResult`
  (`snapshots[]`, `news_count`/`max_news_impact`/`nearest_news_minutes`,
  `news_decision_hash`, `news_snapshot_identity`), logs one journal line
  per build. `NewsEngine_InitCsvSource`/`_DeinitCsvSource` load + hard-gate
  CSV coverage once from `OnInit`. Legacy `News_HighImpactNear*` (a
  separate live real-time gate check) kept unchanged.
- `Market/MLQuantAI_MarketContext.mqh`: `news_decision_hash`/
  `news_snapshot_identity` fields (additive). `MarketContext_HashPayload()`'s
  news contribution changed from a per-element `NewsSnapshot_HashFragment`
  loop (included `source_kind`) to the single `news_decision_hash` field -
  a deliberate algorithm change, justified in-file, since no candidate
  dataset yet depends on a historical `context_hash` value.
- `Market/MLQuantAI_NewsSnapshot.mqh`: `normalized_event_key`/`revision_id`/
  `revision_timestamp`/`source_priority` fields (additive lineage).
- `MLQuantAI.mq5`: `OnInit` now hard-gates on `NewsEngine_InitCsvSource()`
  in Tester mode - `INIT_FAILED` on a coverage/schema/file problem, not a
  warning.
- `Tests/MLQuantAI_Test_NewsParity.mq5` + `Tests/Fixtures/
  MLQuantAI_NewsParityFixture_V1.csv`: core parity (live vs. CSV agree on
  `news_decision_hash`, differ on `news_snapshot_identity`), canonicalization
  (case/whitespace/truncation/tie-break/order-independence), selection/
  coverage against the real fixture (>10 events caps to a deterministic
  top 10, dedup winner, fail-closed coverage gap and malformed CSV), and
  seal criteria (metadata-only changes don't move `news_decision_hash`,
  replay never touches a source, B5 lineage fields reach
  `MARKET_CONTEXT_READY`'s JSON payload).
- `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`: `Test_NewsSnapshotCanonicalization`
  renamed/migrated to `Test_NewsDecisionHash_DrivesContextHash` (asserts
  `MarketContext_HashPayload` tracks `news_decision_hash`, not raw `news[]`
  content) plus 2 new payload-completeness checks for the new hash fields.

### Removed
- `Market/MLQuantAI_NewsEngine.mqh`: `News_CsvImpactToInt`, `News_BuildSnapshots_Live`,
  `News_BuildSnapshots_Csv`, `News_BuildSnapshots` - superseded by
  `NewsEngine_Build()`'s shared pipeline; confirmed unused elsewhere.

## [Unreleased] - Phase B B3.5: Data Hub Determinism Seal

Hardens B3's `context_hash` to actually satisfy the 5 seal criteria
(in-session determinism, cross-session determinism, account-exclusion,
full hash coverage, regression) - see `Docs/PhaseB_B3_5_DeterminismSeal.md`.

### Added
- `Market/MLQuantAI_NewsSnapshot.mqh`: `NewsSnapshot_Canonicalize()`
  (sorts by `release_time` then `calendar_event_id`) and
  `NewsSnapshot_HashFragment()`. `FeatureEngine_BuildContext()` now
  canonicalizes `ctx.news` before computing aggregates or the hash, so
  `context_hash` no longer depends on calendar/CSV source ordering.
- `Market/MLQuantAI_MarketContext.mqh`: `MarketContext_HashPayload()`
  extended to include `m5_bar`/`m15_bar`/`h1_bar`/`h4_bar` (time, OHLC,
  tick_volume, historical spread, via the new
  `MarketContext_RatesHashFragment()`) and the full canonically-ordered
  `NewsSnapshot[]` content - previously only `news_count`/
  `max_news_impact`/`nearest_news_minutes` were hashed, not the news
  identity itself. `MarketContext_RatesToJson()` gained `tick_volume` to
  match what's now hashed.
- `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`: `Test_AccountExclusion_
  RealPipeline()` (mutates `.account` on a real built context, asserts
  the hash is unchanged), `Test_NewsSnapshotCanonicalization()`
  (self-contained, proves source-order independence after
  canonicalizing), `Test_CrossSessionFixture()` (persists a
  anchor+hash fixture across script runs to prove the SAME anchor bar
  hashes the same after a "restart").

## [Unreleased] - Phase B B3: Data Hub / Feature Engine Migration + Determinism

Migrates the live Data Hub/Feature Engine/`MLQuantAI.mq5` to the B1-frozen
`Market/MLQuantAI_MarketContext.mqh` contract, closed-bar only. See
`Docs/PhaseB_B3_DataHubDeterminism.md`. Still no CRT/strategy code, no AI,
no execution wiring.

### Added
- `Market/MLQuantAI_FeatureEngine.mqh`: `FeatureEngine_BuildContext()`
  replaces Step 9's `FeatureEngine_Build()` - builds the new
  `MarketContext`, resolves the symbol via B2's `SymbolSpec_BuildResolved()`,
  and reads every field from the closed trigger bar
  (`InpTriggerTimeframe`, default M5) backward, never bar 0/`TimeCurrent()`/
  a live tick. `FeatureEngine_CurrentAnchorBarTime()` exposes the same
  anchor `MLQuantAI.mq5`'s `OnTick()` uses for new-bar detection.
- `Market/MLQuantAI_DataHub.mqh`: `g_hADX_M15` handle;
  `DataHub_AsianRangeAt(symbol, asiaEndHour, asOf, ...)` replaces
  `DataHub_AsianRange()` (read `TimeCurrent()` internally).
- `Market/MLQuantAI_SessionEngine.mqh`: `Session_Id(t)` - one label for
  `MarketContext.session_id`.
- `Market/MLQuantAI_NewsEngine.mqh`: `News_BuildSnapshots()`/`_Live`/`_Csv`
  - a full `NewsSnapshot[]` anchored at an explicit `asOf`, replacing a
  live `TimeCurrent()`-anchored bool for context-building purposes.
  `News_HighImpactNear()` stays as a separate live gate-check utility.
- `Market/MLQuantAI_MarketContext.mqh`: `MarketContext_ComputeHash()` and
  `MarketContext_ToJsonFragment()` (the full `MARKET_CONTEXT_READY`
  payload, including the embedded `NewsSnapshot[]`). The frozen struct's
  fields are unchanged.
- `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`: rebuilds the same anchor
  bar 1,000 times and asserts `context_hash` never changes, plus
  payload-completeness and closed-bar-semantics checks.

### Removed
- `Core/MLQuantAI_MarketContext.mqh` (Step 9's `MarketContext` struct) -
  deleted once nothing referenced it after the migration.

## [Unreleased] - Phase B B2: Symbol Resolution

Contract + resolver only - no DataHub/FeatureEngine/MLQuantAI.mq5 wiring
in this pass (that migration is B3's job).

### Added
- `Core/MLQuantAI_ContractVersions.mqh`: `MLQUANTAI_SYMBOL_SPEC_SCHEMA_V1`.
- `Market/MLQuantAI_SymbolSpec.mqh` extended **additively**: canonical
  `instrument_id` vs. resolved `broker_symbol`, `tick_size`, `tick_value`,
  `currency_margin`, `trade_mode`. Every Step 9 field is unchanged - the
  legacy `SymbolSpec_Build()` still behaves exactly as before, since
  `FeatureEngine_Init()` already calls it directly.
- `Market/MLQuantAI_SymbolResolver.mqh`: `SymbolResolver_LooksLikeAlias`
  (prefix-decoration match + a small built-in XAUUSD alias table for
  brokers using unrelated names like "GOLD" + `InpExtraSymbolAliases` for
  anything broker-specific - deliberately NOT a loose substring/contains
  check), `SymbolResolver_Resolve`/`_ResolveWith` (fails closed on an
  unknown or non-matching symbol), and `SymbolSpec_BuildResolved`/
  `_BuildResolvedWith` - the new B2 entry point B3's DataHub and B5's
  detectors should use instead of the legacy `SymbolSpec_Build()`.
- `Tests/MLQuantAI_Test_SymbolResolver.mq5`: alias-matching (prefix,
  built-in, extra, and rejection of loose/wrong matches), override vs.
  auto-detect resolution, fail-closed behavior on an invalid symbol, and
  full `SymbolSpec` snapshot population.

## [Unreleased] - Phase B B1: Contract Freeze

Contracts only - no DataHub/FeatureEngine/CRT/execution code was written
or changed in this pass. See `Docs/PhaseB_B1_ContractFreeze.md`.

### Added
- `Core/MLQuantAI_ContractVersions.mqh`: Phase B schema version constants
  (`MLQUANTAI_MARKET_CONTEXT_SCHEMA_V1`, `MLQUANTAI_FEATURE_SCHEMA_V1`,
  `MLQUANTAI_CANDIDATE_SCHEMA_V1`, `MLQUANTAI_NEWS_SCHEMA_V1`,
  `MLQUANTAI_RISK_SCHEMA_V1`) - separate from Phase A's
  `MLQuantAI_VersionRegistry.mqh`, which stays untouched.
- `Market/MLQuantAI_MarketContext.mqh`: the new, frozen `MarketContext`
  contract - canonical `instrument_id` vs. `broker_symbol`, closed-bar-only
  `anchor_bar_time`, per-timeframe `MqlRates` bars, an embedded
  `NewsSnapshot[]`, and a `context_hash` that deliberately excludes
  runtime-only account state. Coexists with the Step 9
  `Core/MLQuantAI_MarketContext.mqh` (still what the live Data Hub/Feature
  Engine build) until B2/B3 migrates them to this contract.
- `Market/MLQuantAI_NewsSnapshot.mqh`: one calendar event, replayable via
  JSON (`NewsSnapshot_ToJson`/`FromJson`/array round-trip helpers),
  self-contained from Phase A's `EventSerializer` on purpose.
- `Market/MLQuantAI_FeatureSnapshot.mqh`: contract stub for the eventual
  Feature Store row (not wired to anything - B3+).
- `Core/MLQuantAI_RiskDecision.mqh`: audit record for a future Risk
  Manager (B7) to log for every candidate, approved or rejected - keeps
  rejected setups explainable instead of just dropped (no survivorship
  bias). Distinct from the existing `MLQuantAI_RiskPlan.mqh` (Phase A's
  sizing-output struct).
- `Core/MLQuantAI_TradeCandidate.mqh` extended **additively**:
  `candidate_schema_version`, `context_event_id`/`context_hash`
  (candidate <-> context lineage), `side` (`ENUM_ORDER_TYPE`),
  `setup_anchor_bar_time` + `expiry_after_bars` (closed-bar expiry, via
  the new `TradeCandidate_ComputeExpiryTime` helper - never
  `TimeCurrent() + N minutes`), `entry_hint`/`sl_hint`/`tp_hint`,
  `trigger_reason_mask` + `trigger_reasons[]`. Every Phase A field is
  unchanged - Phase A's sealed tests and `MLQuantAI.mq5`'s Step 8.5 smoke
  test still compile against the same struct untouched.
- `Core/MLQuantAI_Ids.mqh`: `Ids_ContextEventId(symbol, timeframeTag,
  barTime)` - deterministic id for one `MarketContext` snapshot, so a
  `TradeCandidate.context_event_id` can reference the exact context it
  was built from.
- `Tests/MLQuantAI_Test_PhaseBContracts.mq5`: struct-shape, closed-bar
  semantics, hash-excludes-runtime-metadata, and NewsSnapshot
  serialize/deserialize round-trip coverage for all of the above.

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
