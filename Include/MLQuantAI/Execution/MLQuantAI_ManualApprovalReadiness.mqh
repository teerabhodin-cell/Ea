//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_ManualApprovalReadiness.mqh      |
//| C2 manual-approval contract, gate integration round: startup-      |
//| rebuild readiness for the manual-approval registry. Mirrors        |
//| MLQuantAI_BrokerSubmissionAuditReadiness.mqh exactly - same         |
//| fail-closed-by-default, re-entrant, LogInfo/LogWarn-only shape.     |
//| Per Docs/PhaseC_C2_ManualApprovalContract.md's "Readiness" section. |
//|                                                                    |
//| Strictly read-only over the event store - no OrderSend/CTrade/     |
//| broker query anywhere in this file, no candidate-lifecycle          |
//| mutation, no event append, no OnTradeTransaction, no retry logic.   |
//| Deliberately NOT a durable EventStore write - readiness is a purely |
//| in-session, observable-via-SystemLogger fact.                       |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MANUALAPPROVALREADINESS_MQH__
#define __MLQUANTAI_MANUALAPPROVALREADINESS_MQH__

#include "MLQuantAI_ManualApprovalProjection.mqh"
#include "../Logging/MLQuantAI_SystemLogger.mqh"

// Fail-closed by default: false until a rebuild THIS session actually
// succeeds. Never manually set true anywhere outside
// ManualApproval_StartupRebuild().
bool g_ManualApproval_Ready = false;

bool ManualApprovalReadiness_IsReady() { return g_ManualApproval_Ready; }

// Test-only: simulates a cold process start.
void ManualApprovalReadiness_Reset() { g_ManualApproval_Ready = false; }

// The ONE startup entry point. Re-entrant and idempotent: readiness is
// set fresh from THIS call's own report.ok every time, never OR'd with
// a stale prior success, so a later failed call correctly REVOKES
// readiness rather than leaving a stale true behind.
ManualApprovalProjectionReport ManualApproval_StartupRebuild(string fileName)
{
   ManualApprovalProjectionReport report = ManualApprovalProjection_RebuildFromFile(fileName);
   g_ManualApproval_Ready = report.ok;

   if(report.ok)
      LogInfo(StringFormat("ManualApproval: startup rebuild OK - %d approval line(s) applied, registry ready.",
              report.approval_lines_applied));
   else
      LogWarn(StringFormat("ManualApproval: startup rebuild FAILED - %s - manual-approval gate stays disabled "
              "(REASON_EXECUTION_AUDIT_NOT_READY) until a future successful rebuild.", report.first_error));

   return report;
}

#endif // __MLQUANTAI_MANUALAPPROVALREADINESS_MQH__
