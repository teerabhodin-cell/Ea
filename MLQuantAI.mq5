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
#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_Contract.mqh>

input group "=== System ==="
input bool   DebugMode                   = false;
input string EventStoreFileNameOverride  = ""; // blank = auto date-stamped "MLQuantAI_events_YYYY-MM-DD.jsonl"
input bool   RunLifecycleSmokeTest       = true; // Step 8.5: prove a candidate written by THIS EA replays correctly across restarts. Turn off once Phase B strategies produce real candidates.

string   g_EventStoreFileName = "";
datetime g_LastContextBarTime = 0;

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

   // C3.4 startup-readiness (Docs/PhaseC_C3_TransactionReconciliationContract.md,
   // sections 25-27, frozen): rebuilds the C3.3 deferred-matching read
   // model once, at startup only. Unlike the two calls directly above,
   // this carries NO lifecycle authority yet - a failed rebuild here is
   // diagnostic-only (LogWarn), never a Safe Mode condition, and never
   // gates EA initialization. Strictly read-only - no OrderSend/CTrade/
   // broker query/candidate mutation/event append/OnTradeTransaction
   // anywhere in this call chain.
   TransactionMatching_StartupRebuild(g_EventStoreFileName);

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
}
