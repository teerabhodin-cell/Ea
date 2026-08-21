//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BrokerSubmissionAuditReadiness.mqh|
//| C2.2/C2.3 startup-rebuild integration patch, per the user's frozen |
//| scope: OnInit calls BrokerSubmissionAudit_StartupRebuild() ONCE,   |
//| after the existing EventStore health/validation - it stages       |
//| C1.3's own ExecutionAuditProjection_RebuildFromFile (unmodified)   |
//| and C2.3's own BrokerSubmissionAuditProjection_RebuildFromFile     |
//| (which already stages the former itself - no redundant re-parse    |
//| needed), then publishes readiness as a single boolean flag ONLY on |
//| a clean rebuild. Fail-closed by construction: the flag's own       |
//| default is false (global scope init), so even a bug that skips     |
//| calling this function entirely still leaves every future gate      |
//| check rejecting, never silently permitting.                        |
//|                                                                     |
//| Strictly read-only over the event store - no OrderSend/CTrade/     |
//| broker query (HistorySelect/PositionSelect/OrderSelect) anywhere    |
//| in this file, no candidate-lifecycle mutation, no event append,     |
//| no OnTradeTransaction, no retry logic. This is deliberately NOT a   |
//| durable EventStore write - readiness is a purely in-session,        |
//| observable-via-SystemLogger fact (LogInfo/LogWarn only), matching   |
//| the precedent already set by MLQuantAI.mq5's own "pre-existing      |
//| event store: N lines, health=..." startup log line - no new         |
//| ENUM_EVENT_TYPE needed for this.                                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BROKERSUBMISSIONAUDITREADINESS_MQH__
#define __MLQUANTAI_BROKERSUBMISSIONAUDITREADINESS_MQH__

#include "MLQuantAI_BrokerSubmissionAuditProjection.mqh"
#include "../Logging/MLQuantAI_SystemLogger.mqh"

// Fail-closed by default: false until a rebuild THIS session actually
// succeeds. Never manually set true anywhere outside
// BrokerSubmissionAudit_StartupRebuild().
bool g_BrokerSubmissionAudit_Ready = false;

bool BrokerSubmissionAuditReadiness_IsReady() { return g_BrokerSubmissionAudit_Ready; }

// Test-only: simulates a cold process start (the global otherwise only
// ever goes false->true once per real EA session, since nothing else
// in this codebase ever calls this function during normal operation).
void BrokerSubmissionAuditReadiness_Reset() { g_BrokerSubmissionAudit_Ready = false; }

// The ONE startup entry point. Re-entrant and idempotent: safe to call
// more than once (e.g. a future manual "re-sync" action) - readiness is
// set fresh from THIS call's own report.ok every time, never OR'd with
// a stale prior success, so a later failed call correctly REVOKES
// readiness rather than leaving a stale true behind.
BrokerSubmissionAuditProjectionReport BrokerSubmissionAudit_StartupRebuild(string fileName)
{
   BrokerSubmissionAuditProjectionReport report = BrokerSubmissionAuditProjection_RebuildFromFile(fileName);
   g_BrokerSubmissionAudit_Ready = report.ok;

   if(report.ok)
      LogInfo(StringFormat("BrokerSubmissionAudit: startup rebuild OK - %d attempt line(s), %d outcome line(s) applied, registry ready.",
              report.attempt_lines_applied, report.outcome_lines_applied));
   else
      LogWarn(StringFormat("BrokerSubmissionAudit: startup rebuild FAILED - %s - broker submission gate stays disabled "
              "(REASON_EXECUTION_AUDIT_NOT_READY) until a future successful rebuild.", report.first_error));

   return report;
}

#endif // __MLQUANTAI_BROKERSUBMISSIONAUDITREADINESS_MQH__
