//+------------------------------------------------------------------+
//| MLQuantAI.mq5                                                     |
//| Phase A: Core Engine (Event Store, State Machine, Replay, Safe    |
//| Mode, Broker Reconciliation) proven inside a REAL EA lifecycle,   |
//| not just standalone test Scripts - CLOSED.                        |
//| Phase B B3: Data Hub + Feature Engine build an immutable           |
//| MarketContext (the B1-frozen contract) from real MT5 price/        |
//| indicators/session/news/account on every new CLOSED trigger bar    |
//| (InpTriggerTimeframe, default M5) and log MARKET_CONTEXT_READY.    |
//| Still no strategies, no AI, no order execution - that's B5+.       |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property version   "1.00"
#property description "MLQuantAI - Event Store + Replay + Safe Mode + Broker Reconciliation + Market Context (Phase B B3)."

#include <MLQuantAI/Core/MLQuantAI_VersionRegistry.mqh>
#include <MLQuantAI/Core/MLQuantAI_Enums.mqh>
#include <MLQuantAI/Logging/MLQuantAI_SystemLogger.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStore.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStoreHealth.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh>
#include <MLQuantAI/Infrastructure/MLQuantAI_BrokerReconciliation.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureEngine.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAuditReadiness.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ManualApprovalReadiness.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerTransactionObservation.mqh>
#include <MLQuantAI/Execution/MLQuantAI_TransactionMatchingReadiness.mqh>
#include <MLQuantAI/Execution/MLQuantAI_DeferredTransactionProcessor.mqh>
#include <MLQuantAI/Execution/MLQuantAI_AsyncTerminalOrderObservationMatcher.mqh>
#include <MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionAuthority.mqh>
#include <MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionAudit.mqh>
#include <MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionStartupDiagnostics.mqh>
#include <MLQuantAI/Execution/MLQuantAI_LifecycleAuthorityProcessor.mqh>
#include <MLQuantAI/Execution/MLQuantAI_RecoveryReconciliationStartup.mqh>
#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_Contract.mqh>
#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_ToTradeCandidate.mqh>
#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_FeatureSnapshotEventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ModelArtifactEventEmission.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RiskPlanEventEmission.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_SafetyGate.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EnvironmentIdentitySnapshot.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionDiscoveryGuard.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionLineageObservation.mqh>
#include <MLQuantAI/AI/MLQuantAI_ModelArtifactBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionAuditProjection.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ManualApprovalEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAdapter.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionGate.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EntryCompatibilityGate.mqh>
// RA-31 (QA-frozen Single-Writer Command/Response Protocol): the EA is
// now the sole EventStore writer for the ceremony - these two headers
// bring in the command mailbox transport and the durable command state
// machine. See both files' own headers for the full contract.
#include <MLQuantAI/Execution/MLQuantAI_CeremonyCommandMailbox.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CeremonyCommandEventEmission.mqh>

input group "=== System ==="
input bool   DebugMode                   = false;
input string EventStoreFileNameOverride  = ""; // blank = auto date-stamped "MLQuantAI_events_YYYY-MM-DD.jsonl"
input bool   RunLifecycleSmokeTest       = true; // Step 8.5: prove a candidate written by THIS EA replays correctly across restarts. Turn off once Phase B strategies produce real candidates.

input group "C4.4 Recovery coverage attestation"
input ENUM_C44_COVERAGE_SOURCE_MODE InpC44CoverageSourceMode = C44_COVERAGE_SOURCE_NONE; // NONE preserves today's exact shipped behavior (adequacy always UNASSESSED)
input string   InpC44CoverageCsvFileName        = ""; // CSV mode only - Common\Files filename; blank = not configured (Load() fails closed)
input string   InpC44CoverageBrokerIdentity     = ""; // PARAMETER mode only
input string   InpC44CoverageAccountIdentity    = ""; // PARAMETER mode only
input string   InpC44CoverageServerTimeBasis    = ""; // PARAMETER mode only
input datetime InpC44CoverageFrom               = 0;  // PARAMETER mode only
input datetime InpC44CoverageTo                 = 0;  // PARAMETER mode only
input datetime InpC44CoverageValidUntil         = 0;  // PARAMETER mode only
input string   InpC44CoverageIssuerIdentity     = ""; // PARAMETER mode only
input string   InpC44CoverageEvidenceReference  = ""; // PARAMETER mode only
input string   InpC44CoverageIntegrityIdentifier = ""; // PARAMETER mode only

input group "C5.0 TEST FIXTURE candidate pipeline (Strategy Tester only)"
input double InpC5TargetRiskPercent       = 1.0;  // RiskContext.target_risk_percent, e.g. 1.0 == 1%
input string InpC5SizingRulesVersion      = "C5_0_FIXTURE_SIZING_V1";
input double InpC5StubPSuccess            = 1.0;  // synthetic InferenceResult.output_values[0], in [0,1] - controls ALLOW/REJECT deterministically
input string InpC5AIDecisionPolicyVersion = "C5_0_FIXTURE_AI_POLICY_V1";
input string InpC5AIThresholdVersion      = "C5_0_FIXTURE_AI_THRESHOLD_V1";
input double InpC5AIAllowThreshold        = 0.5;  // in [0,1]
input string InpC5EligibilityPolicyVersion = "C5_0_FIXTURE_ELIGIBILITY_POLICY_V1";
input double InpC5MaxDailyLossPercent     = 0.0;  // 0 = gate disabled
input double InpC5MaxDrawdownPercent      = 0.0;  // 0 = gate disabled
input double InpC5MaxTotalExposurePercent = 0.0;  // 0 = gate disabled
input int    InpC5MaxOpenPositions        = 0;    // 0 = gate disabled
input double InpC5MinMarginLevel          = 0.0;  // 0 = gate disabled
input string InpC5ExecutionPolicyVersion  = "C5_0_FIXTURE_EXECUTION_POLICY_V1";
input double InpC5MaxVolume               = 10.0; // ExecutionPolicy.max_volume, must be > 0 to reach SafetyGate ACCEPTED (C5.1: 0.01 was tighter than any risk-sized lot could ever pass; 10.0 matches the C2.2 smoke-test precedent)
input double InpC5MaxPlannedRiskAmount    = 1000.0; // ExecutionPolicy.max_planned_risk_amount, must be > 0 to reach SafetyGate ACCEPTED
input double InpC5MaxDeviationPoints      = 0.0;  // ExecutionPolicy.max_deviation_points, >= 0 required

input group "C6.1 Environment Identity Verification (advisory/diagnostic only - no authority)"
input string InpC6AccountAllowlist = ""; // comma-separated ACCOUNT_LOGIN values; empty = unconfigured, fails closed (diagnostic only)
input string InpC6ServerAllowlist  = ""; // comma-separated ACCOUNT_SERVER values; empty = unconfigured, fails closed (diagnostic only)
input string InpC6SymbolAllowlist  = ""; // comma-separated symbols; empty = unconfigured, fails closed (diagnostic only)

string   g_EventStoreFileName = "";
datetime g_LastContextBarTime = 0;
double   g_RA31_EABindingNonce = 0.0; // RA-31 re-scope of RA-29.1: this EA instance's current, live nonce - CeremonyCommand_TryClaim() validates every command's expected_ea_binding_nonce against this

string BuildDefaultEventStoreFileName()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   return StringFormat("MLQuantAI_events_%04d-%02d-%02d.jsonl", tm.year, tm.mon, tm.day);
}

// Deterministic per-CALENDAR-DAY id (not per-tick) so repeated restarts on
// the same day find the SAME candidate_id instead of creating a new one
// each time - that's what lets OnInit tell "already logged today, replay
// found it correctly" apart from "never logged, create it now".
// TimeCurrent() - (TimeCurrent()%86400) is an approximate day boundary
// (doesn't account for the broker's exact midnight), which is fine here -
// this only needs to stay stable across restarts within the same session
// of testing, not be calendar-exact.
string BuildSmokeTestCandidateId(string &outRootEventId)
{
   datetime approxDayStart = TimeCurrent() - (TimeCurrent() % 86400);
   outRootEventId = Ids_RootEventId(_Symbol, "SMOKE", "RUNTIME_LIFECYCLE_SMOKE_TEST", 0.0, approxDayStart, 0);
   return Ids_CandidateId(outRootEventId, "SMOKE", "V1");
}

// Synthetic MarketContext for the Step 8.5 smoke-test candidate below -
// namespaced instrument_id/trigger_timeframe "SMOKE" so its identity
// space can never collide with (or be mistaken for) a real MarketContext
// built by FeatureEngine_BuildContext. Durably logged as its own
// MARKET_CONTEXT_READY line BEFORE the candidate is created, so
// CandidateProjection's own orphan check (context_event_id must match a
// real MARKET_CONTEXT_READY line in the SAME store) is satisfied - this
// candidate is written by the live EA itself into the same event store
// file every real candidate uses, so it must satisfy the exact same
// projection contract, not a relaxed one.
void BuildSmokeTestContext(MarketContext &ctx, datetime approxDayStart)
{
   MarketContext_Init(ctx);
   ctx.instrument_id     = "SMOKE";
   ctx.broker_symbol     = _Symbol;
   ctx.trigger_timeframe = "SMOKE";
   ctx.anchor_bar_time   = approxDayStart;
   ctx.context_event_id  = Ids_ContextEventId(ctx.instrument_id, ctx.trigger_timeframe, ctx.anchor_bar_time);
   ctx.context_hash      = MarketContext_ComputeHash(ctx);
}

// A deterministic, synthetic reason mask satisfying CandidateProjection_
// ValidateReasonConsistency's own internal-consistency rules (Infrastructure/
// EventStore/MLQuantAI_CandidateProjection.mqh) - required for ANY
// CANDIDATE_CREATED line to validate at all, regardless of which
// strategy produced it, since that check runs against the same shared
// CRT_V1 reason-bit vocabulary unconditionally. This candidate is NOT a
// real CRT_V1 detection - strategy_id=-1/strategy_name=
// "RuntimeLifecycleSmokeTest" below already mark it synthetic to every
// other consumer (dataset export, training data, etc.) - this mask is
// chosen only because it's the minimal bit combination the vocabulary's
// own XOR/required-bit rules accept as internally consistent, not to
// imitate any specific real setup.
#define SMOKE_TEST_REASON_MASK (CRT_REASON_BIT_SWEEP_LOW | CRT_REASON_BIT_CLOSE_BACK_INSIDE | CRT_REASON_BIT_MSS_CONFIRMED | CRT_REASON_BIT_FVG_FOUND)

string SmokeTestStringArrayToJson(const string &arr[])
{
   string s = "[";
   for(int i = 0; i < ArraySize(arr); i++)
   {
      if(i > 0) s += ",";
      s += "\"" + EventSerializer_Escape(arr[i]) + "\"";
   }
   s += "]";
   return s;
}

// The extra_json fragment CandidateProjection_ApplyLine actually requires
// for ANY CANDIDATE_CREATED line to be accepted (schema version, context
// lineage, side, time/numerical integrity, and reason-mask consistency) -
// none of these are native LifecycleEvent fields, same "extra_json is
// the only place these live" convention CRT_CandidateCreatedExtraJson
// already uses (Strategies/MLQuantAI_CRT_V1_EventEmission.mqh) for real
// candidates.
string SmokeTestCandidateCreatedExtraJson(const TradeCandidate &c)
{
   string reasons[];
   CRT_ReasonLabelsFromMask(c.trigger_reason_mask, reasons);

   string s = "";
   s += "\"candidate_schema_version\":\"" + EventSerializer_Escape(c.candidate_schema_version) + "\",";
   s += "\"context_event_id\":\""          + EventSerializer_Escape(c.context_event_id) + "\",";
   s += "\"context_hash\":\""              + EventSerializer_Escape(c.context_hash) + "\",";
   s += "\"candidate_hash\":\""            + EventSerializer_Escape(c.candidate_hash) + "\",";
   s += "\"detector_hash\":\""             + EventSerializer_Escape(c.detector_hash) + "\",";
   s += "\"side\":\""                      + (c.side == ORDER_TYPE_BUY ? "BUY" : "SELL") + "\",";
   s += "\"setup_anchor_bar_time\":\""     + TimeToString(c.setup_anchor_bar_time, TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"expiry_after_bars\":"           + IntegerToString(c.expiry_after_bars) + ",";
   s += "\"expiry_time\":\""               + TimeToString(c.expiry_time, TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"entry_hint\":"                  + DoubleToString(c.entry_hint, 5) + ",";
   s += "\"sl_hint\":"                     + DoubleToString(c.sl_hint, 5) + ",";
   s += "\"tp_hint\":"                     + DoubleToString(c.tp_hint, 5) + ",";
   s += "\"trigger_reason_mask\":"         + IntegerToString((long)c.trigger_reason_mask) + ",";
   s += "\"trigger_reasons\":"             + SmokeTestStringArrayToJson(reasons);
   return s;
}

// Step 8.5 Runtime Lifecycle Smoke Test - proves a candidate created by
// THIS ACTUAL EA (not a standalone test script) gets correctly replayed
// on the next restart. No order is ever opened; the candidate always ends
// REJECTED_BY_BROKER (simulating a broker-side reject after submission).
// NOT REJECTED_BY_RISK, which the state machine only allows directly from
// CREATED, never from SUBMITTED; an earlier version of this function used
// CREATED -> SUBMITTED -> REJECTED_BY_RISK and the state machine correctly
// blocked it as illegal - working exactly as designed, catching a mistake
// in this test rather than in the state machine itself. REJECTED_BY_BROKER
// also deliberately avoids ever landing on CANDIDATE_EXECUTED, which would
// make BrokerReconciliation_CheckAll() falsely report a mismatch every
// restart, since no real MT5 position backs this synthetic candidate.
// Idempotent per calendar day: if today's smoke-test candidate already
// exists (found via replay), this only reports its replayed state instead
// of creating a duplicate - StateProjector would correctly flag a second
// CREATED genesis for the same candidate_id as corruption, so this guard
// is required, not just tidy.
//
// TEST-ONLY FIX: this candidate now emits its own synthetic
// MARKET_CONTEXT_READY line first, and supplies every field
// CandidateProjection_ApplyLine requires (schema version, context
// lineage, side/time/numerical integrity, reason-mask consistency) -
// previously this called EventStore_LogCandidateCreated(smoke) with NO
// extra_json at all, so this candidate was never actually schema-
// conformant with CandidateProjection since B6.1 introduced these
// checks. This fix only changes what THIS smoke test itself writes -
// no production candidate-creation path, no CandidateProjection
// validation rule, is touched. It does NOT retroactively repair any
// already-orphaned/invalid line already sitting in a pre-existing event
// store file written before this fix existed - only file rotation
// (a fresh date-stamped file, the default naming convention) or explicit
// manual cleanup addresses that.
void RunRuntimeLifecycleSmokeTest()
{
   string rootEventId;
   string smokeId = BuildSmokeTestCandidateId(rootEventId);

   ENUM_CANDIDATE_STATE existingState;
   if(StateProjector_TryGetState(smokeId, existingState))
   {
      LogInfo(StringFormat("Step 8.5 smoke test: today's candidate (%s) already exists and replayed correctly -> state=%s",
              smokeId, CandidateStateToString(existingState)));
      return;
   }

   datetime approxDayStart = TimeCurrent() - (TimeCurrent() % 86400);
   MarketContext smokeCtx;
   BuildSmokeTestContext(smokeCtx, approxDayStart);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY),
                              "synthetic market context for the Step 8.5 lifecycle smoke test - not a real MarketContext",
                              MarketContext_ToJsonFragment(smokeCtx)))
   {
      LogWarn("Step 8.5 smoke test: failed to log MARKET_CONTEXT_READY");
      return;
   }

   TradeCandidate smoke;
   TradeCandidate_Init(smoke);
   smoke.candidate_id  = smokeId;
   smoke.root_event_id = rootEventId;
   smoke.strategy_id   = -1; // not a real strategy - synthetic smoke-test candidate
   smoke.strategy_name = "RuntimeLifecycleSmokeTest";
   smoke.signal_time   = TimeCurrent();

   smoke.context_event_id = smokeCtx.context_event_id;
   smoke.context_hash      = smokeCtx.context_hash;
   smoke.candidate_hash    = "SMOKE_CANDIDATE_HASH_" + smokeId; // synthetic - no real detector output to fingerprint
   smoke.detector_hash     = "SMOKE_DETECTOR_HASH_V1";           // synthetic - no real detector ever ran

   smoke.side                  = ORDER_TYPE_BUY;
   smoke.setup_anchor_bar_time = approxDayStart;
   smoke.expiry_after_bars     = 1;
   smoke.expiry_time           = TradeCandidate_ComputeExpiryTime(smoke.setup_anchor_bar_time, smoke.expiry_after_bars, PERIOD_M1);
   smoke.entry_hint            = 1.5; // arbitrary but deterministic synthetic price hints - never a real quote
   smoke.sl_hint                = 1.0;
   smoke.tp_hint                = 2.0;
   smoke.trigger_reason_mask   = SMOKE_TEST_REASON_MASK;

   string createdExtraJson = SmokeTestCandidateCreatedExtraJson(smoke);
   if(!EventStore_LogCandidateCreated(smoke, createdExtraJson)) { LogWarn("Step 8.5 smoke test: failed to log CREATED"); return; }
   if(!EventStore_LogTransition(smoke, CANDIDATE_SUBMITTED, REASON_SUBMITTED_OK)) { LogWarn("Step 8.5 smoke test: failed to log SUBMITTED"); return; }
   smoke.correlation_id = Ids_CorrelationId(smoke.candidate_id);
   if(!EventStore_LogTransition(smoke, CANDIDATE_REJECTED_BY_BROKER, REASON_BROKER_REJECT)) { LogWarn("Step 8.5 smoke test: failed to log REJECTED_BY_BROKER"); return; }

   LogInfo(StringFormat("Step 8.5 smoke test: created today's candidate (%s), logged CREATED -> SUBMITTED -> REJECTED_BY_BROKER. "
                         "Restart the EA to confirm replay reconstructs this exact state.", smokeId));
}

int OnInit()
{
   g_SysLog_Debug = DebugMode;

   g_EventStoreFileName = (EventStoreFileNameOverride != "") ? EventStoreFileNameOverride : BuildDefaultEventStoreFileName();

   LogInfo(StringFormat("%s v%s starting - event store file: %s", MLQUANTAI_EA_NAME, MLQUANTAI_EA_VERSION, g_EventStoreFileName));
   LogInfo("Phase B B3: Data Hub + Feature Engine active (closed-bar MarketContext). Still no strategies, no AI, no order execution.");

   // C6.1 Environment Identity Verification: pure, read-only observation
   // of environment/identity/authority runtime facts, logged for operator
   // diagnostic visibility only. Authority: NONE - never gates, never
   // suppresses, never caches for later use by any sealed gate. See
   // Include/MLQuantAI/Execution/MLQuantAI_EnvironmentIdentitySnapshot.mqh.
   EnvironmentIdentitySnapshot c6EnvIdentitySnapshot;
   EnvironmentIdentitySnapshot_Build(InpC6AccountAllowlist, InpC6ServerAllowlist, InpC6SymbolAllowlist, c6EnvIdentitySnapshot);
   EnvironmentIdentitySnapshot_Log(c6EnvIdentitySnapshot, InpC6AccountAllowlist, InpC6ServerAllowlist, InpC6SymbolAllowlist);

   if(!FeatureEngine_Init(_Symbol))
   {
      LogError("FeatureEngine_Init failed (symbol resolution or indicator handle creation) - EA will not run.");
      return INIT_FAILED;
   }
   LogInfo(StringFormat("FeatureEngine resolved instrument_id=%s broker_symbol=%s trigger_timeframe=%s",
           g_FeatureEngine_InstrumentId, g_FeatureEngine_BrokerSymbol, FeatureEngine_TimeframeTag(InpTriggerTimeframe)));

   // Phase B B4 hard gate: NewsEngine_Build() (the pipeline that
   // populates MarketContext.news[]) needs its CsvStaticNewsSource loaded
   // AND its coverage validated against the full backtest range BEFORE
   // the first bar - a coverage gap must block startup, not silently run
   // with an incomplete news dataset. Unlike the legacy
   // News_ValidateCsvCoverage below (advisory-only, and only feeds the
   // separate News_HighImpactNear() live-gate utility), this is a hard
   // INIT_FAILED.
   if(UseNewsFilter && MQLInfoInteger(MQL_TESTER))
   {
      datetime seriesStart = (datetime)SeriesInfoInteger(_Symbol, PERIOD_M15, SERIES_FIRSTDATE);
      datetime rangeEnd     = TimeCurrent();
      if(seriesStart > 0)
      {
         string newsSourceErr;
         if(!NewsEngine_InitCsvSource(seriesStart, rangeEnd, newsSourceErr))
         {
            LogError("NewsEngine_InitCsvSource failed - refusing to start with an incomplete/invalid news dataset "
                     "while UseNewsFilter=true (Phase B B4 hard gate): " + newsSourceErr);
            return INIT_FAILED;
         }
      }

      // Legacy 3-column CSV fallback - a separate concern, feeds only the
      // still-live News_HighImpactNear() gate-check utility. Advisory only.
      News_LoadCsv(NewsCsvFileName);
      if(seriesStart > 0)
         News_ValidateCsvCoverage(seriesStart, rangeEnd);
   }

   // Validate whatever's already in the file BEFORE this session appends
   // anything to it - a corrupted history must not be silently built on
   // top of. This file is deliberately never deleted here (unlike the
   // Tests/ scripts, which reset their fixture file each run for
   // isolation) - a real EA appends across restarts, per the spec's
   // "ห้าม delete event เก่า" rule.
   bool fileExists = FileIsExist(g_EventStoreFileName, FILE_COMMON);
   EventStoreValidationReport preCheck;
   EventStoreValidationReport_Init(preCheck);
   if(fileExists)
   {
      preCheck = EventStoreHealth_CheckFile(g_EventStoreFileName);
      LogInfo(StringFormat("pre-existing event store: %d lines, health=%s",
              preCheck.lines_total, EventStoreHealthToString(EventStoreHealth_Grade(preCheck))));
   }
   else
   {
      LogInfo("no pre-existing event store file - starting fresh.");
   }

   if(!EventStore_Open(g_EventStoreFileName))
   {
      LogError("failed to open event store - EA will not run.");
      return INIT_FAILED;
   }

   // RA-29.1 (QA-frozen contract, Docs-external): Ceremony EventStore
   // Binding Integrity. Publishes a fresh per-OnInit nonce under a
   // GlobalVariableTemp name that encodes this session's actual
   // EventStore filename, so a ceremony script can prove - before it
   // builds any Candidate/lineage - that it targets the same file THIS
   // EA instance currently has open, not a stale binding left behind by
   // an earlier EA instance/session. Must run strictly after
   // EventStore_Open() succeeds and strictly before this EA becomes
   // observer-ready (i.e. before OnInit can return INIT_SUCCEEDED), so a
   // publish failure is a hard startup failure, never a warning - a
   // ceremony must never be able to proceed against an EA that could not
   // prove its own binding. This build's GlobalVariableTemp() is
   // single-argument only and CREATES the variable as temporary - it does
   // not just flip a flag on one that already exists - so publishing a
   // temp variable with a specific value is: delete any leftover first
   // (best-effort), GlobalVariableTemp() creates it fresh as temporary,
   // then GlobalVariableSet() assigns the value onto that already-temp
   // variable. Both calls must succeed. (Found empirically, real EA run
   // on 2026.09.10: the reverse order - Set() then Temp() - fails every
   // time, because Temp() then finds a variable with that name already
   // exists.)
   //
   // RA-29.1 amendment (QA-authorized after CONDITIONAL PASS review): the
   // original nonce (TimeLocal()*100000 + GetTickCount()%100000) had no
   // uniqueness invariant - RA-29.1's own regression test proved by
   // construction, and once empirically, that two OnInit calls could
   // produce an IDENTICAL nonce, which defeats stale-instance rejection.
   // Replaced with a persistent, monotonically-increasing counter scoped
   // per EventStore filename: every OnInit reads the counter's current
   // value (0 if it has never existed) and writes back current+1, using
   // that strictly-larger value as the nonce. Two OnInit calls for the
   // same filename can therefore never produce the same nonce - this is
   // now a deterministic invariant, not a probabilistic one. Unlike the
   // binding variable itself, the counter is deliberately an ORDINARY
   // (non-temp) global variable - it must persist so the sequence keeps
   // strictly advancing across EA restarts within the same terminal
   // session (a restart is exactly the "stale previous instance" case
   // RA-29.1 exists to guard against).
   {
      string ra29BindingName = "MLQuantAI_EABinding__" + g_EventStoreFileName;
      string ra29CounterName = "MLQuantAI_EABindingCounter__" + g_EventStoreFileName;
      double ra29Counter     = GlobalVariableCheck(ra29CounterName) ? GlobalVariableGet(ra29CounterName) : 0.0;
      double ra29Nonce       = ra29Counter + 1.0;
      bool   ra29Published   = (GlobalVariableSet(ra29CounterName, ra29Nonce) != 0);
      GlobalVariableDel(ra29BindingName); // best-effort: clear any leftover before (re)creating fresh
      ra29Published = ra29Published && GlobalVariableTemp(ra29BindingName) && (GlobalVariableSet(ra29BindingName, ra29Nonce) != 0);
      if(!ra29Published)
      {
         LogError(StringFormat("RA-29.1: failed to publish EA binding ('%s') - EA will not run "
                                "(a ceremony must never proceed unable to verify which EventStore this EA has open).",
                                ra29BindingName));
         GlobalVariableDel(ra29BindingName); // best-effort: never leave a half-published, non-temp binding behind
         EventStore_Close();
         return INIT_FAILED;
      }
      LogInfo(StringFormat("RA-29.1 binding published: file=%s nonce=%.0f "
                            "(copy this EXACT value into a ceremony script's I_ExpectedEABindingNonce input)",
                            g_EventStoreFileName, ra29Nonce));
      g_RA31_EABindingNonce = ra29Nonce; // RA-31: OnTick's command claim logic validates against this
   }

   // EventStoreHealth_CheckFile() above only auto-logs SYSTEM_EVENT_STORE_
   // CORRUPTED when a write handle is ALREADY open at check time, which
   // wasn't true yet (store opens right after) - log it explicitly now.
   if(fileExists && !preCheck.ok)
      EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SYSTEM_EVENT_STORE_CORRUPTED), preCheck.first_error);

   // C2.2/C2.3 startup-rebuild integration patch: rebuilds the durable
   // submission-attempt audit registry from the same event store,
   // exactly once, right after the health/validation above and before
   // anything downstream could ever consult it. Stages C1.3's own
   // ExecutionAuditProjection_RebuildFromFile (unmodified) as its own
   // first internal step - no separate call needed here. Publishes
   // readiness ONLY on a clean rebuild; BrokerSubmissionGate_Evaluate
   // rejects every request with REASON_EXECUTION_AUDIT_NOT_READY until
   // this succeeds. Strictly read-only over the event store - no
   // OrderSend/CTrade/broker query/candidate mutation/event append/
   // OnTradeTransaction anywhere in this call chain. No strategy in
   // this codebase calls BrokerSubmissionGate_Evaluate yet (Phase B/C
   // execution wiring into OnTick is a separate, later concern), but
   // this ensures the registry is trustworthy before one safely could.
   BrokerSubmissionAuditProjectionReport auditReport = BrokerSubmissionAudit_StartupRebuild(g_EventStoreFileName);
   if(!auditReport.ok)
      LogWarn("C2 broker submission stays disabled this session - startup audit rebuild failed: " + auditReport.first_error);

   // C2 manual-approval contract, gate integration round: the second,
   // independent startup-rebuild call this OnInit makes, same pattern
   // as the one directly above - rebuilds the manual-approval registry
   // from the same event store, publishes readiness ONLY on a clean
   // rebuild. BrokerSubmissionEnvironmentLock_Evaluate's own manual-
   // approval check rejects every request with
   // REASON_EXECUTION_AUDIT_NOT_READY until this succeeds. Strictly
   // read-only - no OrderSend/CTrade/broker query/candidate mutation/
   // event append/OnTradeTransaction anywhere in this call chain. See
   // Docs/PhaseC_C2_ManualApprovalContract.md.
   ManualApprovalProjectionReport approvalReport = ManualApproval_StartupRebuild(g_EventStoreFileName);
   if(!approvalReport.ok)
      LogWarn("C2 manual-approval gate stays disabled this session - startup approval rebuild failed: " + approvalReport.first_error);

   // RA-31 (QA-frozen Single-Writer Command/Response Protocol): rebuild
   // the candidate-content projection (needed to reconstruct a
   // TradeCandidate for SUBMIT_ORDER - see SubmitOrderCommand() below)
   // and the durable ceremony-command registry, then apply RA-31.2
   // condition C's restart rule: any command left at CEREMONY_IN_
   // PROGRESS when the EA last stopped is force-failed now, never
   // resumed (the builder chain mints fresh IDs on every call - resuming
   // mid-build risks the same duplicate-genesis SafeMode trip RA-26 hit).
   CandidateProjection_Reset();
   CandidateProjection_RebuildFromFile(g_EventStoreFileName);
   CeremonyCommandRegistry_RebuildFromFile(g_EventStoreFileName);
   int ra31InterruptedCount = CeremonyCommandRegistry_FailInterruptedCommands();
   if(ra31InterruptedCount > 0)
      LogWarn(StringFormat("RA-31: %d ceremony command(s) were interrupted mid-build by the previous stop - "
                            "marked COMMAND_FAILED(interrupted_by_restart), never auto-resumed.", ra31InterruptedCount));
   if(CeremonyCommandRegistry_HasUnresolvedSubmission())
      LogWarn("RA-31: an unresolved SUBMIT_ORDER attempt exists (L1 written, outcome unknown) - "
              "every new SUBMIT_ORDER command will be rejected until this is reconciled (RA-31.2 condition B).");

   // C6.2/C6.3 Wave 1 (frozen chat-history contracts, no separate Docs/
   // file yet): reset the in-session Layer A discovery registry, then
   // run the read-only Layer B "discover the past" observation pass.
   // Placed here because ExecutionRequestProjection/DryRunResultProjection
   // (via BrokerSubmissionAudit_StartupRebuild above) and
   // ManualApprovalProjection/SubmissionAttemptProjection (via the two
   // StartupRebuild calls above) are all guaranteed populated by this
   // point. Log-only - no authority, no EventStore write, never fails
   // EA initialization.
   ExecutionDiscoverySession_Reset();
   ExecutionLineageObservation_LogAll();

   // C3.4 startup-readiness (Docs/PhaseC_C3_TransactionReconciliationContract.md,
   // sections 25-27, frozen): rebuilds the C3.3 deferred-matching read
   // model once, at startup only. Unlike the two calls directly above,
   // this carries NO lifecycle authority yet - a failed rebuild here is
   // diagnostic-only (LogWarn), never a Safe Mode condition, and never
   // gates EA initialization. Strictly read-only - no OrderSend/CTrade/
   // broker query/candidate mutation/event append/OnTradeTransaction
   // anywhere in this call chain.
   TransactionMatching_StartupRebuild(g_EventStoreFileName);

   // C4.4 recovery-coverage runtime wiring (frozen this checkpoint): one
   // read-only RecoveryReconciliation_ScanLive() call, using whichever
   // ICoverageAttestationSource the operator selected via
   // InpC44CoverageSourceMode (default NONE - reproduces today's exact
   // shipped behavior). Placed here because this is the earliest point
   // both OrderAggregateRegistry (just rebuilt above) and
   // ExecutionRequestProjection (rebuilt by BrokerSubmissionAudit_
   // StartupRebuild earlier in this function) - the only two registries
   // ScanLive reads - are guaranteed ready; C4's own contract (§5/§8) is
   // read-only/no execution-gate authority, so a scan or source failure
   // here is diagnostic-only (see RecoveryReconciliation_StartupScan's
   // own LogWarn/LogInfo calls) and can never fail EA initialization or
   // trip Safe Mode.
   RecoveryReconciliationReport c44RecoveryCoverageReport = RecoveryReconciliation_StartupScan(
      InpC44CoverageSourceMode,
      InpC44CoverageCsvFileName,
      InpC44CoverageBrokerIdentity, InpC44CoverageAccountIdentity, InpC44CoverageServerTimeBasis,
      InpC44CoverageFrom, InpC44CoverageTo, InpC44CoverageValidUntil,
      InpC44CoverageIssuerIdentity, InpC44CoverageEvidenceReference, InpC44CoverageIntegrityIdentifier);

   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SYSTEM_STARTED),
                         StringFormat("%s v%s", MLQUANTAI_EA_NAME, MLQUANTAI_EA_VERSION),
                         VersionRegistry_AsJsonFragment());

   // Replay everything written so far - including this session's own
   // SYSTEM_STARTED line just above - and reconcile against real MT5
   // state. With no Execution Engine yet, no EA in this codebase ever
   // opens a real position, so today this always reconciles trivially
   // (0 replayed EXECUTED candidates); the comparison itself is real.
   ReplayReport rr = ReplayEngine_Run(g_EventStoreFileName);
   LogInfo(StringFormat("replay: %d lifecycle events applied, %d failed, %d system events applied",
           rr.lifecycle_events_applied, rr.lifecycle_events_failed, rr.system_events_applied));
   if(!rr.ok)
      EventStoreHealth_TripSafeMode(StringFormat("replay found an inconsistency: %s", rr.first_error));

   // C3.6 deferred-transaction-processor (per
   // Docs/PhaseC_C3_6_DeferredTransactionProcessorContract.md, FROZEN):
   // a read-only RECOMMENDATION read model. Turns the already-sealed
   // C3.3 transaction-matching evidence + this replay's candidate
   // states into DeferredRecommendationRecord rows only. Runs AFTER
   // ReplayEngine_Run (candidate state SUBMITTED comes from the
   // StateProjector replay just populated, NOT CandidateProjection) and
   // BEFORE BrokerReconciliation_CheckAll (which acts on already-EXECUTED
   // candidates - C3.6 emits no transition, so there is nothing new for
   // reconciliation to see yet). RECOMMEND_EXECUTED is a recommendation
   // row, NOT a SUBMITTED -> EXECUTED transition; lifecycle authority is
   // C3.7. Strictly read-only - no lifecycle-write API, no candidate
   // mutation, no event append, no per-tick / per-trade-transaction
   // callback, no broker terminal query or submission API, no
   // *_RebuildFromFile recovery of individual upstream projections. If
   // replay failed (SafeMode engaged above) or the matching read model
   // is not ready, the scan emits zero recommendations (scan-level, not
   // a row-level BLOCKED) and does NOT trip SafeMode or block EA init.
   DeferredTransactionProcessor_StartupScan(g_EventStoreFileName);

   // C3.10B async terminal rejection authority (Checkpoint 2, locked):
   // the SOLE component authorized to turn a C3.10A ATOM_MATCHED async
   // terminal-order observation into a durable
   // EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED SystemEvent followed by
   // a CANDIDATE_SUBMITTED -> CANDIDATE_REJECTED_BY_BROKER transition.
   // Slots between C3.6 (above) and C3.7 (below). AsyncTerminalOrder
   // ObservationMatcher (C3.10A) is a pure function with no global
   // registry, so it is scanned here directly rather than through a
   // *_StartupScan-populated registry. On ok=false, skips both C3.7 and
   // BrokerReconciliation_CheckAll this session - transitioning/
   // reconciling against a provably-uncertain rejection-confirmation
   // state would be worse than skipping it, same rationale as C3.7's
   // own cascade to BrokerReconciliation below.
   AsyncTerminalOrderMatchReport atomReport = AsyncTerminalOrderMatcher_ScanFile(g_EventStoreFileName);
   AsyncTerminalRejectionAuthorityReport rejAuth = AsyncTerminalRejectionAuthority_StartupApply(g_EventStoreFileName, atomReport);

   // C3.7 lifecycle authority processor (per
   // Docs/PhaseC_C3_7_BoundedLifecycleAuthorityContract.md, FROZEN): the
   // SOLE component authorized to turn a C3.6 RECOMMEND_EXECUTED row into
   // a real CANDIDATE_SUBMITTED -> CANDIDATE_EXECUTED transition, via the
   // existing sealed EventStore_LogTransition(). Re-verifies live state
   // fresh from StateProjector immediately before every transition -
   // never trusts C3.6's own scan-time snapshot. On a successful durable
   // write, synchronously applies the REAL recovered durable event to
   // StateProjector (never a fabricated one) so BrokerReconciliation_
   // CheckAll below sees this session's own fresh EXECUTED candidates,
   // not just prior-session ones. On any transition-layer failure
   // (durable write, evidence recovery, or StateProjector_Apply), the
   // scan stops immediately and BrokerReconciliation_CheckAll is
   // skipped entirely this session - reconciling against a
   // provably-diverged read model would be worse than skipping it.
   LifecycleAuthorityReport lar;
   BrokerReconciliationReport brr;
   if(rejAuth.ok)
   {
      lar = LifecycleAuthority_StartupApply(g_EventStoreFileName);
      if(lar.ok)
      {
         brr = BrokerReconciliation_CheckAll();
      }
      else
      {
         BrokerReconciliationReport_Init(brr);
         LogWarn(StringFormat("C3.7 lifecycle authority: skipping BrokerReconciliation_CheckAll this session - "
                 "scan stopped early (%s): %s", lar.stop_reason, lar.first_error));
      }
   }
   else
   {
      LifecycleAuthorityReport_Init(lar);
      BrokerReconciliationReport_Init(brr);
      LogWarn(StringFormat("C3.10B async terminal rejection authority: skipping C3.7/BrokerReconciliation_CheckAll "
              "this session - scan stopped early (%s): %s", rejAuth.stop_reason, rejAuth.first_error));
   }

   // C3.10C async terminal rejection audit (Checkpoint 1, locked):
   // strictly read-only, non-blocking startup audit - a post-condition
   // observer only. Runs unconditionally after the C3.10B/C3.7/
   // BrokerReconciliation block above, never altering its outcome.
   // Reuses the SAME atomReport instance C3.10B already consumed -
   // never re-scans the file. ok==false never fails EA initialization
   // on its own - only LogError with the full counter summary.
   AsyncTerminalRejectionAuditReport c310cReport =
      AsyncTerminalRejectionAudit_StartupScan(
         g_EventStoreFileName,
         atomReport);

   if(!c310cReport.ok)
     {
      LogError(StringFormat(
         "C3.10C async terminal rejection audit failed: %s "
         "(confirmations=%d verified=%d missing_transition=%d "
         "missing_confirmation=%d duplicate_confirmation=%d "
         "provenance_mismatch=%d source_missing=%d source_ambiguous=%d)",
         c310cReport.first_error,
         c310cReport.confirmations_total,
         c310cReport.verified_total,
         c310cReport.missing_transition_count,
         c310cReport.missing_confirmation_count,
         c310cReport.duplicate_confirmation_count,
         c310cReport.provenance_mismatch_count,
         c310cReport.source_evidence_missing_count,
         c310cReport.source_evidence_ambiguous_count));
     }

   // C3.10D operator-facing startup diagnostics (Checkpoint 1, locked):
   // log-only, read-only summary of the C3.10A/B/C pipeline - never
   // decides whether C3.7/BrokerReconciliation ran, only records the
   // already-determined rejAuth.ok signal. Runs unconditionally after
   // the C3.10C block above, never alters any prior control flow, never
   // fails EA initialization on its own.
   AsyncTerminalRejectionStartupDiagnostics_Log(
      atomReport,
      rejAuth,
      c310cReport,
      rejAuth.ok);

   // Step 8.5: prove a candidate this exact EA wrote gets replayed
   // correctly on the next restart - not just candidates written by the
   // standalone Tests/ scripts. Runs AFTER replay/reconciliation above so
   // it can see (via StateProjector_TryGetState) whether today's
   // smoke-test candidate already exists from a previous run this session.
   if(RunLifecycleSmokeTest)
      RunRuntimeLifecycleSmokeTest();

   Comment(StringFormat("%s v%s | Safe Mode: %s | candidates created (all-time): %d",
           MLQUANTAI_EA_NAME, MLQUANTAI_EA_VERSION,
           EventStoreHealth_IsSafeMode() ? ("ENGAGED - " + EventStoreHealth_Reason()) : "clear",
           g_Proj_RuntimeState.candidates_created));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| RA-31 (QA-frozen Single-Writer Command/Response Protocol)         |
//|                                                                    |
//| Everything below is the EA-side half of the three ceremony        |
//| commands (RUN_C22_CEREMONY_FIXTURE / GRANT_MANUAL_APPROVAL /       |
//| SUBMIT_ORDER) that used to be three separate EventStore writers    |
//| (Tests/MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5's own            |
//| EventStore_Open()+BuildAcceptedRequest()+BrokerSubmission_Submit(),|
//| and the standalone MLQuantAI_ManualScript_GrantApproval.mq5) -     |
//| RA-30.1 proved those could never durably open the canonical file   |
//| concurrently with this EA (150/150 FileOpen failures, err=5004),   |
//| so both scripts are now thin command issuers only; every actual    |
//| EventStore append happens here, through this EA's own,             |
//| never-closed handle.                                               |
//|                                                                    |
//| RunC22CeremonyFixtureCommand's fixture geometry (base price, bar   |
//| literals, risk-context constants) is copied VERBATIM from that     |
//| script's BuildBaseContext/Fixture_Bullish_Valid/FillFillerBars/    |
//| BuildValidRiskContext/BuildAcceptedRequest - every literal must     |
//| stay byte-identical to preserve the exact candidate_hash/           |
//| execution_request_hash chain QA has already verified against real  |
//| runs (RA-19 through RA-30). Do not "clean up" these numbers.       |
//+------------------------------------------------------------------+
#define MLQUANTAI_CEREMONY_FIXTURE_BASE_PRICE 105.00
#define MLQUANTAI_CEREMONY_PERIOD_SEC_M5 300

void CeremonyFixture_MakeBar(MqlRates &r, datetime t, double open, double high, double low, double close, long tickVolume, int spread)
{
   ZeroMemory(r);
   r.time = t; r.open = open; r.high = high; r.low = low; r.close = close;
   r.tick_volume = tickVolume; r.spread = spread;
}

void CeremonyFixture_BuildBaseContext(MarketContext &ctx, double delta)
{
   MarketContext_Init(ctx);
   ctx.instrument_id      = "XAUUSD";
   ctx.broker_symbol      = "XAUUSD";
   ctx.trigger_timeframe  = "M5";
   ctx.symbol_spec.digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   ctx.symbol_spec.point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   ctx.pdl = 1.000 + delta;
   ctx.pdh = 110.00 + delta;
   ctx.is_kill_zone = false;
   ctx.max_news_impact = 0;
   ctx.nearest_news_minutes = 9999;
   ctx.atr_m15 = 1.2345;
   ctx.adx_m15 = 25.5;
   ctx.ema_slope_m15 = 0.05;
   ctx.asian_range_high = 105.50 + delta;
   ctx.asian_range_low  = 104.50 + delta;
   ctx.spread_points_at_anchor = 20.0;
   ctx.news_count = 3;
   ctx.context_event_id = "CTX_smoke_c22";
   ctx.context_hash      = "test_context_hash_smoke_c22";
}

void CeremonyFixture_FillFillerBars(MqlRates &window[], datetime t0, double delta)
{
   for(int i = 0; i < 59; i++)
      CeremonyFixture_MakeBar(window[i], t0 + i * MLQUANTAI_CEREMONY_PERIOD_SEC_M5, 105.00+delta, 105.20+delta, 104.80+delta, 105.00+delta, 100, 20);
}

void CeremonyFixture_Bullish_Valid(MqlRates &window[], datetime &outAnchor, datetime t0, double delta)
{
   ArrayResize(window, 64);
   CeremonyFixture_FillFillerBars(window, t0, delta);
   CeremonyFixture_MakeBar(window[59], t0 + 59 * MLQUANTAI_CEREMONY_PERIOD_SEC_M5, 100.80+delta, 100.90+delta,   0.500+delta, 100.50+delta, 100, 20);
   CeremonyFixture_MakeBar(window[60], t0 + 60 * MLQUANTAI_CEREMONY_PERIOD_SEC_M5, 100.50+delta, 101.50+delta, 100.40+delta, 101.40+delta, 100, 20);
   CeremonyFixture_MakeBar(window[61], t0 + 61 * MLQUANTAI_CEREMONY_PERIOD_SEC_M5, 101.40+delta, 102.50+delta, 101.30+delta, 102.40+delta, 100, 20);
   CeremonyFixture_MakeBar(window[62], t0 + 62 * MLQUANTAI_CEREMONY_PERIOD_SEC_M5, 102.40+delta, 103.50+delta, 102.30+delta, 103.40+delta, 100, 20);
   CeremonyFixture_MakeBar(window[63], t0 + 63 * MLQUANTAI_CEREMONY_PERIOD_SEC_M5, 103.40+delta, 104.60+delta, 103.30+delta, 104.50+delta, 100, 20);
   outAnchor = window[63].time;
}

void CeremonyFixture_BuildValidRiskContext(RiskContext &ctx)
{
   RiskContext_Init(ctx);
   ctx.symbol_spec.instrument_id = "XAUUSD";
   ctx.symbol_spec.broker_symbol = "XAUUSD_smoke";
   ctx.symbol_spec.tick_size     = 0.01;
   ctx.symbol_spec.tick_value    = 1.0;
   ctx.symbol_spec.contract_size = 100;
   ctx.symbol_spec.volume_min    = 0.01;
   ctx.symbol_spec.volume_max    = 100.0;
   ctx.symbol_spec.volume_step   = 0.01;
   ctx.symbol_spec.digits        = 2;

   ctx.account.balance = 10000.0;
   ctx.account.equity  = 10000.0;

   ctx.target_risk_percent  = 5.0;
   ctx.sizing_method        = "FIXED_PERCENT_RISK";
   ctx.sizing_rules_version = MLQUANTAI_RISK_SIZING_RULES_V1;

   ctx.risk_context_hash = RiskContext_ComputeHash(ctx);
}

// RUN_C22_CEREMONY_FIXTURE: builds the full candidate -> ... -> execution
// request chain (same call sequence as the old script's
// BuildAcceptedRequest, verbatim), stops at CEREMONY_READY (dry-run
// accepted) - never touches BrokerSubmission_Submit()/OrderSend(). A
// separate SUBMIT_ORDER command, gated on its own EMP-01 authorization,
// is required to go further.
void RunC22CeremonyFixtureCommand(CeremonyCommand &cmd)
{
   EventStore_LogCeremonyCommandState(cmd.command_id, cmd.command_type,
                                       CEREMONY_STATE_COMMAND_RECEIVED, CEREMONY_STATE_CEREMONY_IN_PROGRESS,
                                       "building", "");

   double liveBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double referencePrice = (cmd.ceremony_reference_price > 0.0) ? cmd.ceremony_reference_price : liveBid;
   double delta = referencePrice - MLQUANTAI_CEREMONY_FIXTURE_BASE_PRICE;

   LogInfo(StringFormat("RA-31 RUN_C22_CEREMONY_FIXTURE: command_id=%s live_bid=%s reference_price=%s delta=%s",
                          cmd.command_id, DoubleToString(liveBid, 8), DoubleToString(referencePrice, 8), DoubleToString(delta, 8)));

   MarketContext ctx;
   CeremonyFixture_BuildBaseContext(ctx, delta);
   datetime t0 = D'2026.03.01 00:00:00';
   datetime anchor;
   CeremonyFixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0, delta);
   ctx.anchor_bar_time = anchor;

   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx)))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "market_context_log_failed", ""); return; }

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "crt_not_detected", ""); return; }

   TradeCandidate c;
   if(!CRT_ToTradeCandidate(ctx, r, c))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "crt_to_trade_candidate_failed", ""); return; }
   if(!CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "candidate_created_log_failed", ""); return; }

   FeatureSnapshot snapshot;
   if(!Candidate_ToFeatureSnapshot(c, ctx, snapshot))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "feature_snapshot_build_failed", ""); return; }
   if(!FeatureSnapshot_EmitFeatureSnapshotCreated(snapshot))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "feature_snapshot_log_failed", ""); return; }

   ModelArtifact artifact;
   if(!ModelArtifact_Build("MODEL_smoke", "v1", "hash_artifact_smoke",
                             "FEATURES_B8_1_V1", "TDSET_dummy_smoke", "hash_tdset_smoke",
                             "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                             "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, artifact))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "model_artifact_build_failed", ""); return; }
   if(!ModelArtifact_EmitModelArtifactRegistered(artifact))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "model_artifact_log_failed", ""); return; }

   InferenceResult inference;
   InferenceResult_Init(inference);
   inference.model_registry_id     = artifact.model_registry_id;
   inference.model_registry_hash   = artifact.model_registry_hash;
   inference.model_artifact_hash   = artifact.model_artifact_hash;
   inference.feature_snapshot_id   = snapshot.feature_snapshot_id;
   inference.feature_snapshot_hash = snapshot.feature_snapshot_hash;
   inference.feature_vector_hash   = snapshot.feature_vector_hash;
   inference.output_schema_version = MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1;
   ArrayResize(inference.output_values, 1);
   inference.output_values[0] = 0.90f;
   inference.runtime_framework = "ONNXRuntime";
   inference.runtime_version   = "1.16.0";
   inference.output_hash = InferenceResult_ComputeOutputHash(inference);

   AIDecisionPolicy aiPolicy;
   AIDecisionPolicy_Init(aiPolicy);
   aiPolicy.decision_policy_version = "AIPOLICY_C1_V1";
   aiPolicy.threshold_version       = "THRESH_C1_V1";
   aiPolicy.allow_threshold         = 0.70;
   AIDecision decision; string aiReasonDetail;
   if(!AIDecision_Build(inference, snapshot, aiPolicy, decision, aiReasonDetail))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "ai_decision_build_failed", aiReasonDetail); return; }
   if(!AIDecision_EmitAIDecisionCreated(decision))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "ai_decision_log_failed", ""); return; }

   RiskContext riskCtx;
   CeremonyFixture_BuildValidRiskContext(riskCtx);
   RiskPlan plan;
   if(!Candidate_ToRiskPlan(c, riskCtx, plan))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "risk_plan_build_failed", ""); return; }
   if(!RiskPlan_EmitRiskPlanCreated(plan))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "risk_plan_log_failed", ""); return; }

   EligibilityContext eligContext;
   EligibilityContext_Init(eligContext);
   eligContext.account.balance = 10000.0;
   eligContext.account.equity = 10000.0;
   eligContext.account.margin_level = 500.0;
   eligContext.account.open_positions_count = 0;
   eligContext.account.open_risk_percent = 0.0;
   eligContext.account.daily_pnl_percent = 0.0;
   eligContext.account.drawdown_from_peak_percent = 0.0;
   eligContext.safe_mode_active = false;
   eligContext.eligibility_context_hash = EligibilityContext_ComputeHash(eligContext);

   EligibilityPolicy eligPolicy;
   EligibilityPolicy_Init(eligPolicy);
   eligPolicy.eligibility_policy_version = "ELIGPOLICY_C1_V1";
   eligPolicy.max_daily_loss_percent = 5.0;
   eligPolicy.max_drawdown_percent = 10.0;
   eligPolicy.max_total_exposure_percent = 20.0;
   eligPolicy.max_open_positions = 5;
   eligPolicy.min_margin_level = 200.0;

   EligibilityDecision eligDecision; string eligReasonDetail;
   if(!EligibilityDecision_Build(plan, decision, snapshot, eligContext, eligPolicy, eligDecision, eligReasonDetail))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "eligibility_decision_build_failed", eligReasonDetail); return; }
   if(eligDecision.decision != ELIGIBILITY_DECISION_ELIGIBLE)
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "eligibility_not_eligible", eligReasonDetail); return; }
   if(!EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, eligContext, c))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "eligibility_log_failed", ""); return; }

   ExecutionPolicy policy;
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C2_SMOKE_V1";
   policy.environment_mode = EXECUTION_ENV_DEMO;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;

   ExecutionRequest req; string rd;
   if(!ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "execution_request_build_failed", rd); return; }

   DryRunExecutionResult dryRunResult;
   bool emitOk = ExecutionRequest_EmitAndEvaluate(req, policy, dryRunResult);
   if(!emitOk || dryRunResult.decision != SAFETY_GATE_ACCEPTED)
   {
      CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "execution_request_not_accepted",
                            ReasonCodeToString(dryRunResult.reason_code));
      return;
   }

   cmd.result_candidate_id           = c.candidate_id;
   cmd.result_execution_request_id   = req.execution_request_id;
   cmd.result_execution_request_hash = req.execution_request_hash;
   cmd.result_correlation_id         = req.correlation_id;
   CeremonyCommand_Complete(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, CEREMONY_STATE_CEREMONY_READY, "dry_run_accepted", req.execution_request_id);

   LogInfo(StringFormat("RA-31 RUN_C22_CEREMONY_FIXTURE ready: command_id=%s candidate_id=%s execution_request_id=%s execution_request_hash=%s correlation_id=%s",
                          cmd.command_id, c.candidate_id, req.execution_request_id, req.execution_request_hash, req.correlation_id));
}

// GRANT_MANUAL_APPROVAL: replaces the standalone
// MLQuantAI_ManualScript_GrantApproval.mq5's own EventStore_Open()+
// ManualApproval_Grant() call. Unlike that script (which required the
// operator to manually retype execution_request_hash/policy_version/
// candidate_id/correlation_id - exactly the kind of field-swap mistake
// QA caught repeatedly during RA-19/RA-21), this handler looks all four
// up from the durable ExecutionRequestProjection via target_execution_
// request_id alone, removing that entire class of operator error.
void GrantManualApprovalCommand(CeremonyCommand &cmd)
{
   EventStore_LogCeremonyCommandState(cmd.command_id, cmd.command_type,
                                       CEREMONY_STATE_COMMAND_RECEIVED, CEREMONY_STATE_CEREMONY_IN_PROGRESS,
                                       "processing", cmd.target_execution_request_id);

   ExecutionRequestProjectionRecord rec;
   if(!ExecutionRequestProjection_TryGet(cmd.target_execution_request_id, rec))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "execution_request_not_found", ""); return; }
   if(cmd.approver_identity == "")
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "approver_identity_missing", ""); return; }

   int validityMinutes = (cmd.approval_validity_minutes > 0) ? cmd.approval_validity_minutes : 15;

   ManualApprovalGrant grant;
   ManualApprovalGrant_Init(grant);
   grant.execution_request_id     = rec.execution_request_id;
   grant.execution_request_hash   = rec.execution_request_hash;
   grant.execution_policy_version = rec.execution_policy_version;
   grant.candidate_id             = rec.candidate_id;
   grant.correlation_id           = rec.correlation_id;
   grant.approver_identity        = cmd.approver_identity;
   grant.approval_timestamp       = TimeCurrent();
   grant.approval_expiry          = grant.approval_timestamp + validityMinutes * 60;
   grant.approval_nonce           = ManualApproval_NewNonce();

   if(!ManualApproval_Grant(grant))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "manual_approval_grant_write_failed", ""); return; }

   cmd.result_execution_request_id   = rec.execution_request_id;
   cmd.result_execution_request_hash = rec.execution_request_hash;
   cmd.result_candidate_id           = rec.candidate_id;
   cmd.result_correlation_id         = rec.correlation_id;
   CeremonyCommand_Complete(cmd, CEREMONY_STATE_CEREMONY_IN_PROGRESS, CEREMONY_STATE_APPROVAL_RECORDED, "granted", rec.execution_request_id);

   LogInfo(StringFormat("RA-31 GRANT_MANUAL_APPROVAL recorded: command_id=%s execution_request_id=%s approver=%s expiry=%s",
                          cmd.command_id, rec.execution_request_id, cmd.approver_identity, TimeToString(grant.approval_expiry, TIME_DATE|TIME_SECONDS)));
}

// SUBMIT_ORDER: the ONLY command type authorized to reach
// BrokerSubmission_Submit()/OrderSend() - still requires QA's separate
// EMP-01 authorization before an operator is allowed to issue it (a
// control this EA does not itself enforce; QA gates it operationally,
// same as every EMP-01 round before RA-31).
//
// RA-31.2 condition B (frozen): if ANY previously-issued SUBMIT_ORDER is
// stuck at SUBMISSION_IN_PROGRESS (L1 durably written, broker outcome
// unknown - e.g. this EA crashed between OrderSend() and durably writing
// L2), every NEW SUBMIT_ORDER is refused, regardless of which execution_
// request_id it targets, until that is reconciled. This is deliberately
// a DIFFERENT, coarser check than the existing SubmissionAttemptRegistry_
// IsUnresolved(executionRequestId) (BrokerSubmissionAuditProjection.mqh,
// unchanged, still consulted inside BrokerSubmissionGate_Evaluate as
// before) - that one protects "never submit this SAME request twice";
// this one protects "never start ANY new submission while a DIFFERENT
// one's broker outcome is still unknown". Both stay in force together.
void SubmitOrderCommand(CeremonyCommand &cmd)
{
   if(CeremonyCommandRegistry_HasUnresolvedSubmission())
   {
      CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED, "unresolved_submission_attempt_exists",
                            "RA-31.2 condition B: a previous SUBMIT_ORDER is stuck at SUBMISSION_IN_PROGRESS - "
                            "resolve via reconciliation before any new submission is allowed.");
      return;
   }

   ExecutionRequestProjectionRecord rec;
   if(!ExecutionRequestProjection_TryGet(cmd.target_execution_request_id, rec))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED, "execution_request_not_found", ""); return; }

   CandidateProjectionRecord candRec;
   if(!CandidateProjection_TryGet(rec.candidate_id, candRec))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED, "candidate_projection_not_found", ""); return; }

   ENUM_CANDIDATE_STATE liveState;
   if(!StateProjector_TryGetState(rec.candidate_id, liveState))
   { CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED, "candidate_state_not_found", ""); return; }

   // Minimal, correct-enough TradeCandidate reconstruction: the only
   // fields BrokerSubmission_Submit()/BrokerSubmission_RecordAttempt()/
   // ProcessSendResult() actually read or mutate on the candidate struct
   // are state (structural gate) and candidate_id/root_event_id/
   // correlation_id/strategy_id (copied verbatim onto the LIFECYCLE event
   // EventStore_LogTransition() writes) - verified against
   // MLQuantAI_EventStore.mqh's own EventStore_LogTransition(). Every
   // price/side/hint field BrokerSubmission_Submit's own gate chain
   // consults comes from ExecutionRequest (rec), not TradeCandidate.
   TradeCandidate candidate;
   TradeCandidate_Init(candidate);
   candidate.candidate_id   = rec.candidate_id;
   candidate.root_event_id  = candRec.root_event_id;
   candidate.correlation_id = rec.correlation_id;
   candidate.strategy_id    = candRec.strategy_id;
   candidate.state          = liveState;

   ExecutionRequest req;
   ExecutionRequest_Init(req);
   req.execution_request_id       = rec.execution_request_id;
   req.execution_request_hash     = rec.execution_request_hash;
   req.candidate_id               = rec.candidate_id;
   req.candidate_hash             = candRec.candidate_hash;
   req.risk_plan_id               = rec.risk_plan_id;
   req.plan_hash                  = rec.plan_hash;
   req.ai_decision_id             = rec.ai_decision_id;
   req.ai_decision_hash           = rec.ai_decision_hash;
   req.eligibility_decision_id    = rec.eligibility_decision_id;
   req.eligibility_decision_hash  = rec.eligibility_decision_hash;
   req.execution_policy_version   = rec.execution_policy_version;
   req.correlation_id             = rec.correlation_id;
   req.submit_attempt             = rec.submit_attempt;
   req.side                       = rec.side;
   req.planned_entry              = rec.planned_entry;
   req.planned_sl                 = rec.planned_sl;
   req.planned_tp                 = rec.planned_tp;
   req.lot_size                   = rec.lot_size;
   req.risk_amount                = rec.risk_amount;

   // Policy fields match Tests/MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5's
   // BuildAcceptedRequest() EXACTLY (including dry_run=true and
   // manual_approval_required=false, which look counter-intuitive for a
   // real-submit path but are what every previously-successful real
   // OrderSend in this project - tickets 3798882166 and 3799401055 - both
   // ran with; neither field is verified here to be inert, so this
   // handler does not risk deviating from the one policy shape already
   // proven to reach a real broker fill).
   ExecutionPolicy policy;
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = rec.execution_policy_version;
   policy.environment_mode = EXECUTION_ENV_DEMO;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;

   EnvironmentLockPolicy lockPolicy;
   EnvironmentLockPolicy_Init(lockPolicy);
   lockPolicy.environment_lock_policy_version = "ENVLOCK_C2_SMOKE_V1";
   lockPolicy.trade_server_allowlist = AccountInfoString(ACCOUNT_SERVER);

   // Durable pre-commit marker BEFORE calling BrokerSubmission_Submit() -
   // this is what RA-31.2 condition B's global gate (above, and on the
   // next OnInit restart-scan) actually watches for.
   if(!EventStore_LogCeremonyCommandState(cmd.command_id, cmd.command_type,
                                           CEREMONY_STATE_COMMAND_RECEIVED, CEREMONY_STATE_SUBMISSION_IN_PROGRESS,
                                           "submitting", rec.execution_request_id))
   {
      CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED, "submission_in_progress_log_failed", "");
      return;
   }
   cmd.mailbox_status = CEREMONY_MAILBOX_STATUS_CLAIMED; // stays CLAIMED (not yet terminal) while this call runs
   CeremonyCommandMailbox_Write(cmd);

   ExecutionSubmissionResult result;
   bool submitOk = BrokerSubmission_Submit(candidate, req, policy, lockPolicy, result);

   if(!result.order_send_returned)
   {
      // Never reached OrderSend() - a pre-submission gate rejected it.
      // Nothing was sent to the broker, so it is safe to fail this
      // command outright (not "unresolved").
      CeremonyCommand_Fail(cmd, CEREMONY_STATE_SUBMISSION_IN_PROGRESS, ReasonCodeToString(result.reason_code),
                            "rejected before OrderSend() was ever called");
      return;
   }

   if(!submitOk)
   {
      // OrderSend() WAS called but this durability layer's own L2 write
      // failed - genuinely unresolved (RA-31.2 condition B's whole
      // reason to exist). Deliberately do NOT call CeremonyCommand_
      // Complete()/Fail() here - the command stays at SUBMISSION_IN_
      // PROGRESS, globally blocking new SUBMIT_ORDER commands until a
      // human reconciles this (see OnInit's CeremonyCommandRegistry_
      // HasUnresolvedSubmission() warning).
      LogError(StringFormat("RA-31 SUBMIT_ORDER: OrderSend() was called (order_send_returned=true) but L2 durability "
                             "write failed - command_id=%s execution_request_id=%s stays SUBMISSION_IN_PROGRESS "
                             "(UNRESOLVED). A real order may be open at the broker. Human reconciliation required "
                             "before any further submission.", cmd.command_id, rec.execution_request_id));
      cmd.mailbox_status = CEREMONY_MAILBOX_STATUS_FAILED;
      cmd.result_reason_code = "l2_durability_write_failed_unresolved";
      cmd.result_message = "OrderSend was called but the result could not be durably recorded - do not retry, this requires human reconciliation.";
      CeremonyCommandMailbox_Write(cmd); // mailbox reflects FAILED so the script stops waiting, but the DURABLE command state intentionally stays SUBMISSION_IN_PROGRESS (see above) - the mailbox is not truth (RA-31.2 condition 2)
      return;
   }

   cmd.result_execution_request_id = rec.execution_request_id;
   cmd.result_order_ticket = (long)result.order_ticket;
   cmd.result_deal_ticket  = (long)result.deal_ticket;
   cmd.result_retcode      = (int)result.retcode;
   CeremonyCommand_Complete(cmd, CEREMONY_STATE_SUBMISSION_IN_PROGRESS, CEREMONY_STATE_SUBMISSION_COMPLETE,
                             ReasonCodeToString(result.reason_code), rec.execution_request_id);

   LogInfo(StringFormat("RA-31 SUBMIT_ORDER complete: command_id=%s execution_request_id=%s order_ticket=%d deal_ticket=%d retcode=%d",
                          cmd.command_id, rec.execution_request_id, (int)result.order_ticket, (int)result.deal_ticket, (int)result.retcode));
}

// The one function OnTick() calls every tick (see call site above).
void RA31_ProcessCeremonyCommand()
{
   CeremonyCommand cmd;
   if(!CeremonyCommand_TryClaim(g_EventStoreFileName, g_RA31_EABindingNonce, cmd))
      return;

   switch(cmd.command_type)
   {
      case CEREMONY_COMMAND_TYPE_RUN_C22_CEREMONY_FIXTURE: RunC22CeremonyFixtureCommand(cmd); break;
      case CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL:    GrantManualApprovalCommand(cmd);   break;
      case CEREMONY_COMMAND_TYPE_SUBMIT_ORDER:             SubmitOrderCommand(cmd);           break;
      default:
         CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED, "unhandled_command_type", "");
         break;
   }
}

void OnDeinit(const int reason)
{
   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SYSTEM_STOPPED), "EA deinit, reason=" + IntegerToString(reason));
   EventStore_Close();
   FeatureEngine_Deinit();
   Comment("");
}

// C3.2 (per Docs/PhaseC_C3_TransactionReconciliationContract.md,
// sections 10-19, frozen): broker-observation only, NOT reconciliation,
// NOT fill handling, NOT execution authorization. Deliberately minimal
// per the frozen callback shape - the entirety of this handler's logic
// lives in BrokerTransactionObservation_RecordAndGuard (Execution/
// MLQuantAI_BrokerTransactionObservation.mqh), which builds the raw
// envelope, attempts exactly one durable append, and trips Safe Mode on
// failure instead of retrying. No history/position/order query, no
// candidate-lifecycle transition, no broker mutation - anywhere in this
// call chain.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   BrokerTransactionObservation_RecordAndGuard(trans, request, result);
}

void OnTick()
{
   // RA-31 (QA-frozen Single-Writer Command/Response Protocol): poll the
   // ceremony command mailbox every tick, BEFORE the bar-close gate below
   // - a ceremony command must not wait up to one whole trigger-timeframe
   // bar to even be noticed. Cheap when idle (one small file read).
   RA31_ProcessCeremonyCommand();

   // Phase B B3: build one immutable MarketContext per new CLOSED trigger
   // bar and log MARKET_CONTEXT_READY - this is the start of the
   // candidate dataset the whole project is built around. Still no
   // strategies reading it yet (B5+), no AI, no order logic.
   //
   // FeatureEngine_CurrentAnchorBarTime() is iTime(broker_symbol,
   // InpTriggerTimeframe, 1) - the last CLOSED bar. Deliberately NOT
   // shift 0 (a still-forming bar) - see Docs/PhaseB_B3_DataHubDeterminism.md.
   datetime anchor = FeatureEngine_CurrentAnchorBarTime();
   if(anchor == 0 || anchor == g_LastContextBarTime) return; // not a new closed trigger bar yet
   g_LastContextBarTime = anchor;

   MarketContext ctx = FeatureEngine_BuildContext();
   if(!FeatureEngine_IsReady(ctx))
   {
      LogDebug("MarketContext not ready yet (insufficient history) - skipping this bar.");
      return;
   }

   FeatureEngine_LogContextReady(ctx);

   // C5.0 TEST FIXTURE candidate pipeline: the first end-to-end wiring of
   // the already-built, already-tested candidate -> risk -> AI -> eligibility
   // -> execution-request -> safety-gate chain, Strategy Tester only. Stub
   // AI inference (no ONNX model exists yet) - real InferenceResult contract
   // shape, synthetic model identity, referentially matched to the real
   // FeatureSnapshot it's built from. As of C6.2/C6.3 Wave 1, the
   // execution_request_id is discovered (Layer A/B) before any content is
   // built, and - only when genuinely missing from both - durably emitted
   // via ExecutionDiscovery_EmitAndRegister() (EXECUTION_REQUEST_CREATED +
   // EXECUTION_DRY_RUN_COMPLETED). Still stops there: never calls
   // BrokerSubmission_Submit()/OrderSend() anywhere - diagnostic dry-run
   // only, no execution/broker authority, per the C5.0 design freeze
   // (which bounded broker reachability, not durability).
   if(!MQLInfoInteger(MQL_TESTER)) return;

   CRTDetectionResult crtResult;
   CRT_DetectV1(ctx, crtResult);
   if(!crtResult.detected) return; // no log - expected most bars, not a failure

   TradeCandidate c5Candidate;
   if(!CRT_ToTradeCandidate(ctx, crtResult, c5Candidate))
   {
      LogWarn("C5.0 TEST FIXTURE stopped: CRT_TO_TRADE_CANDIDATE_FAILED");
      return;
   }

   // C6.2/C6.3 Wave 1 discover-before-emit gate (frozen chat-history
   // contracts, no separate Docs/ file yet): derive execution_request_id
   // via the PURE Ids_* identity chain - candidate_id plus fixed
   // policy-version strings only, matching exactly what
   // EligibilityBuilder/AIDecisionBuilder/RiskSizing/ExecutionRequestBuilder
   // themselves compute internally (verified against their real source).
   // No live balance read, no FeatureSnapshot/RiskPlan/AIDecision/
   // EligibilityDecision/ExecutionRequest content build happens before
   // this check - if the identity is already known (either layer), the
   // rest of this pipeline never runs at all this tick.
   string c5EligibilityDecisionId = Ids_EligibilityDecisionId(c5Candidate.candidate_id, InpC5EligibilityPolicyVersion);
   string c5AIDecisionId          = Ids_AIDecisionId(c5Candidate.candidate_id, "STUB_NO_MODEL_V1", InpC5AIDecisionPolicyVersion);
   string c5RiskPlanId            = Ids_RiskPlanId(c5Candidate.candidate_id, InpC5SizingRulesVersion);
   string c5ExecutionRequestId    = Ids_ExecutionRequestId(c5Candidate.candidate_id, c5EligibilityDecisionId,
                                                             c5AIDecisionId, c5RiskPlanId, InpC5ExecutionPolicyVersion);

   ExecutionDiscoveryResult c5Discovery;
   ExecutionDiscovery_Resolve(c5ExecutionRequestId, c5Discovery);
   if(c5Discovery.resolution == EXEC_DISCOVERY_FOUND_SESSION)
   {
      LogInfo("C5.0 TEST FIXTURE: execution_request_id=" + c5ExecutionRequestId +
              " already emitted this session (Layer A) - observing, not re-emitting.");
      return;
   }
   if(c5Discovery.resolution == EXEC_DISCOVERY_FOUND_DURABLE)
   {
      LogInfo("C5.0 TEST FIXTURE: execution_request_id=" + c5ExecutionRequestId +
              " already durable (Layer B) - observing, not re-emitting.");
      return;
   }

   // C6-W1-REMEDIATION-01 (frozen chat-history authorization, no separate
   // Docs/ file yet): missing from both layers - now cross the emission
   // boundary for real, durable lineage top to bottom. Every *_Emit*
   // call below is sealed, existing infrastructure (same functions every
   // Tests/*.mq5 fixture in this project already calls) - this fixture
   // simply never called them before. Each one self-dedupes via its own
   // live-sync ProjectionRecord guard, independent of the discovery
   // guard above.
   CRT_EmitCandidateCreated(c5Candidate, ctx.symbol_spec.digits);

   FeatureSnapshot c5Snapshot;
   if(!Candidate_ToFeatureSnapshot(c5Candidate, ctx, c5Snapshot))
   {
      LogWarn("C5.0 TEST FIXTURE stopped: FEATURE_SNAPSHOT_BUILD_FAILED candidate_id=" + c5Candidate.candidate_id);
      return;
   }
   FeatureSnapshot_EmitFeatureSnapshotCreated(c5Snapshot);

   RiskContext c5RiskCtx;
   RiskContext_Init(c5RiskCtx);
   c5RiskCtx.account              = ctx.account;
   c5RiskCtx.symbol_spec          = ctx.symbol_spec;
   c5RiskCtx.target_risk_percent  = InpC5TargetRiskPercent;
   c5RiskCtx.sizing_method        = "FIXED_PERCENT_RISK";
   c5RiskCtx.sizing_rules_version = InpC5SizingRulesVersion;
   c5RiskCtx.risk_context_hash    = RiskContext_ComputeHash(c5RiskCtx);

   RiskPlan c5RiskPlan;
   if(!Candidate_ToRiskPlan(c5Candidate, c5RiskCtx, c5RiskPlan))
   {
      LogWarn("C5.0 TEST FIXTURE stopped: RISK_PLAN_BUILD_FAILED candidate_id=" + c5Candidate.candidate_id);
      return;
   }
   RiskPlan_EmitRiskPlanCreated(c5RiskPlan);

   // Built BEFORE c5StubInference (reordered per INV-C6-W1-RST-001
   // iteration 2): c5StubInference.model_registry_hash/model_artifact_hash
   // must reference this struct's own real, already-registered fields -
   // never a separately hardcoded literal - or AIDecisionProjection's
   // model-registry lineage check (which compares the AI decision's
   // declared hash against the actual ModelArtifactProjection record)
   // rejects it on any restart rebuild.
   ModelArtifact c5StubModel;
   ModelArtifact_Init(c5StubModel);
   c5StubModel.model_registry_id  = "STUB_NO_MODEL_V1";
   c5StubModel.model_id           = "STUB_NO_MODEL_V1";
   c5StubModel.model_version      = "STUB";
   c5StubModel.model_artifact_hash = "STUB_NO_MODEL_V1";
   c5StubModel.feature_schema_version = c5Snapshot.feature_schema_version; // reuse the real value this exact snapshot already carries - not invented
   c5StubModel.training_dataset_id    = "STUB_NO_MODEL_V1"; // no training dataset - this is the no-model stub, same identity literal as model_id/model_artifact_hash
   c5StubModel.training_dataset_hash  = "STUB_NO_MODEL_V1";
   c5StubModel.model_target           = "STUB_NO_MODEL_V1";
   c5StubModel.input_schema_version   = "STUB_V1";
   c5StubModel.output_schema_version  = "STUB_V1";
   c5StubModel.runtime_framework      = "NONE";
   c5StubModel.runtime_version        = "STUB";
   c5StubModel.promotion_state        = MODEL_PROMOTION_DRAFT;
   c5StubModel.model_registry_hash    = ModelArtifact_ComputeHash(c5StubModel);
   ModelArtifact_EmitModelArtifactRegistered(c5StubModel);

   InferenceResult c5StubInference;
   InferenceResult_Init(c5StubInference);
   c5StubInference.model_registry_id     = c5StubModel.model_registry_id;
   c5StubInference.model_registry_hash   = c5StubModel.model_registry_hash;  // canonical hash just registered above - not a separate literal
   c5StubInference.model_artifact_hash   = c5StubModel.model_artifact_hash;
   c5StubInference.feature_snapshot_id   = c5Snapshot.feature_snapshot_id;
   c5StubInference.feature_snapshot_hash = c5Snapshot.feature_snapshot_hash;
   c5StubInference.feature_vector_hash   = c5Snapshot.feature_vector_hash;
   c5StubInference.output_schema_version = c5StubModel.output_schema_version;
   ArrayResize(c5StubInference.output_values, 1);
   c5StubInference.output_values[0] = (float)InpC5StubPSuccess;
   c5StubInference.output_hash      = InferenceResult_ComputeOutputHash(c5StubInference);
   c5StubInference.runtime_framework = c5StubModel.runtime_framework;
   c5StubInference.runtime_version   = c5StubModel.runtime_version;

   AIDecisionPolicy c5AIPolicy;
   AIDecisionPolicy_Init(c5AIPolicy);
   c5AIPolicy.decision_policy_version = InpC5AIDecisionPolicyVersion;
   c5AIPolicy.threshold_version       = InpC5AIThresholdVersion;
   c5AIPolicy.allow_threshold         = InpC5AIAllowThreshold;

   AIDecision c5AIDecision; string c5AIReason;
   if(!AIDecision_Build(c5StubInference, c5Snapshot, c5AIPolicy, c5AIDecision, c5AIReason))
   {
      LogWarn("C5.0 TEST FIXTURE stopped: AI_DECISION_BUILD_FAILED candidate_id=" + c5Candidate.candidate_id + " reason=" + c5AIReason);
      return;
   }
   AIDecision_EmitAIDecisionCreated(c5AIDecision);

   EligibilityContext c5EligCtx;
   EligibilityContext_Init(c5EligCtx);
   c5EligCtx.account               = ctx.account;
   c5EligCtx.safe_mode_active      = SafeMode_IsActive();
   c5EligCtx.eligibility_context_hash = EligibilityContext_ComputeHash(c5EligCtx);

   EligibilityPolicy c5EligPolicy;
   EligibilityPolicy_Init(c5EligPolicy);
   c5EligPolicy.eligibility_policy_version = InpC5EligibilityPolicyVersion;
   c5EligPolicy.max_daily_loss_percent     = InpC5MaxDailyLossPercent;
   c5EligPolicy.max_drawdown_percent       = InpC5MaxDrawdownPercent;
   c5EligPolicy.max_total_exposure_percent = InpC5MaxTotalExposurePercent;
   c5EligPolicy.max_open_positions         = InpC5MaxOpenPositions;
   c5EligPolicy.min_margin_level           = InpC5MinMarginLevel;

   EligibilityDecision c5EligDecision; string c5EligReason;
   if(!EligibilityDecision_Build(c5RiskPlan, c5AIDecision, c5Snapshot, c5EligCtx, c5EligPolicy, c5EligDecision, c5EligReason))
   {
      LogWarn("C5.0 TEST FIXTURE stopped: ELIGIBILITY_DECISION_BUILD_FAILED candidate_id=" + c5Candidate.candidate_id + " reason=" + c5EligReason);
      return;
   }
   // REJECTED durably transitions the candidate to CANDIDATE_REJECTED_BY_RISK
   // (sealed, inside this call) - no extra branch needed here:
   // ExecutionRequestBuilder's own eligibility.decision != ELIGIBLE guard
   // (verified against source) already stops this fixture at the existing
   // EXECUTION_REQUEST_BUILD_FAILED path below, exactly as it does today.
   EligibilityDecision_EmitDecisionAndWireLifecycle(c5EligDecision, c5EligCtx, c5Candidate);

   ExecutionPolicy c5ExecPolicy;
   ExecutionPolicy_Init(c5ExecPolicy);
   c5ExecPolicy.execution_policy_version = InpC5ExecutionPolicyVersion;
   c5ExecPolicy.environment_mode         = EXECUTION_ENV_TESTER;
   c5ExecPolicy.dry_run                  = true;
   c5ExecPolicy.manual_approval_required = false;
   c5ExecPolicy.account_allowlist        = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   c5ExecPolicy.symbol_allowlist         = _Symbol;
   c5ExecPolicy.max_volume               = InpC5MaxVolume;
   c5ExecPolicy.max_planned_risk_amount  = InpC5MaxPlannedRiskAmount;
   c5ExecPolicy.max_deviation_points     = InpC5MaxDeviationPoints;

   ExecutionRequest c5ExecRequest; string c5ExecReason;
   if(!ExecutionRequest_Build(c5Candidate, c5EligDecision, c5AIDecision, c5RiskPlan, c5ExecPolicy, c5ExecRequest, c5ExecReason))
   {
      LogWarn("C5.0 TEST FIXTURE stopped: EXECUTION_REQUEST_BUILD_FAILED candidate_id=" + c5Candidate.candidate_id + " reason=" + c5ExecReason);
      return;
   }

   // Integrity check: the discovery guard's pure Ids_* derivation above
   // (computed before any of this pipeline ran) must match the identity
   // the real builder chain just produced. A mismatch means the pure
   // derivation has drifted from ExecutionRequestBuilder's real logic -
   // fail closed rather than emit under a possibly-wrong identity.
   if(c5ExecRequest.execution_request_id != c5ExecutionRequestId)
   {
      LogError("C5.0 TEST FIXTURE: execution_request_id mismatch - pre-derived (" + c5ExecutionRequestId +
               ") != built (" + c5ExecRequest.execution_request_id + ") for candidate_id=" + c5Candidate.candidate_id +
               " - discovery guard's pure Ids_* derivation has drifted from the real builder chain. Aborting, not emitting.");
      return;
   }

   DryRunExecutionResult c5GateResult;
   bool c5EmitOk = ExecutionDiscovery_EmitAndRegister(c5ExecRequest, c5ExecPolicy, c5GateResult);
   if(!c5EmitOk)
   {
      LogWarn("C5.0 TEST FIXTURE: ExecutionDiscovery_EmitAndRegister returned false for execution_request_id=" +
              c5ExecRequest.execution_request_id + " candidate_id=" + c5Candidate.candidate_id +
              " - request may still be durably recorded (see ExecutionRequestEventEmission.mqh's own "
              "failure-mode rule); Layer A registration already applied regardless.");
      return;
   }

   LogInfo("C5.0 TEST FIXTURE: candidate_id=" + c5Candidate.candidate_id +
           " execution_request_id=" + c5ExecRequest.execution_request_id +
           " decision=" + (c5GateResult.decision == SAFETY_GATE_ACCEPTED ? "ACCEPTED" : "REJECTED") +
           " reason=" + ReasonCodeToString(c5GateResult.reason_code));
}
