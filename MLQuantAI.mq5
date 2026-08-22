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

   TradeCandidate smoke;
   TradeCandidate_Init(smoke);
   smoke.candidate_id  = smokeId;
   smoke.root_event_id = rootEventId;
   smoke.strategy_id   = -1; // not a real strategy - synthetic smoke-test candidate
   smoke.strategy_name = "RuntimeLifecycleSmokeTest";
   smoke.signal_time   = TimeCurrent();

   if(!EventStore_LogCandidateCreated(smoke)) { LogWarn("Step 8.5 smoke test: failed to log CREATED"); return; }
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

   BrokerReconciliationReport brr = BrokerReconciliation_CheckAll();

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
