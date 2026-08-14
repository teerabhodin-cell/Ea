//+------------------------------------------------------------------+
//| MLQuantAI.mq5                                                     |
//| Phase A skeleton EA. No strategies, no AI, no order execution -   |
//| this exists to prove the Core Engine (Event Store, State Machine, |
//| Replay, Safe Mode, Broker Reconciliation) works inside a REAL EA  |
//| lifecycle (OnInit/OnTick/OnDeinit), not just inside standalone    |
//| test Scripts. Step 0's Definition of Done: "compile EA เปล่าได้,  |
//| EA version แสดงบน chart/log ได้, ไม่มี strategy หรือ AI logic."   |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property version   "1.00"
#property description "MLQuantAI Phase A skeleton - Event Store + Replay + Safe Mode + Broker Reconciliation only."

#include <MLQuantAI/Core/MLQuantAI_VersionRegistry.mqh>
#include <MLQuantAI/Core/MLQuantAI_Enums.mqh>
#include <MLQuantAI/Logging/MLQuantAI_SystemLogger.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStore.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStoreHealth.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh>
#include <MLQuantAI/Infrastructure/MLQuantAI_BrokerReconciliation.mqh>

input group "=== System ==="
input bool   DebugMode                   = false;
input string EventStoreFileNameOverride  = ""; // blank = auto date-stamped "MLQuantAI_events_YYYY-MM-DD.jsonl"
input bool   RunLifecycleSmokeTest       = true; // Step 8.5: prove a candidate written by THIS EA replays correctly across restarts. Turn off once Phase B strategies produce real candidates.

string g_EventStoreFileName = "";

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
   LogInfo("Phase A skeleton: no strategies, no AI, no order execution in this build.");

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
   Comment("");
}

void OnTick()
{
   // Phase A: no strategies, no AI, no order logic - nothing to do per
   // tick yet. OnTick exists only so this is a valid, runnable EA (and
   // can be attached to a chart / run in Strategy Tester at all).
}
