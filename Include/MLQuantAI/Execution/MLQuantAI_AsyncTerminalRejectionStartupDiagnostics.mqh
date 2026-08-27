//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_AsyncTerminalRejectionStartup    |
//| Diagnostics.mqh                                                   |
//| C3.10D implementation (per the Async Terminal Rejection Startup   |
//| Diagnostics Checkpoint 1 contract, locked in this branch's chat    |
//| history - no separate Docs/ file yet).                             |
//|                                                                     |
//| Operator-facing startup diagnostic summary. Turns the already-       |
//| built C3.10A/C3.10B/C3.10C report objects into one readable log       |
//| block. Does not read the event store, does not touch StateProjector  |
//| or CandidateProjection, does not call any broker/terminal API, does   |
//| not append/repair/transition/trip Safe Mode, and never fails EA        |
//| initialization on its own.                                              |
//|                                                                            |
//| Pure/logging boundary (locked, Checkpoint 1): MQL5's Print() (which         |
//| LogInfo/LogWarn/LogError wrap - Logging/MLQuantAI_SystemLogger.mqh)          |
//| writes to the Expert Journal with no corresponding read-back API             |
//| anywhere in the standard library, so "capture log text and assert on          |
//| it" is not a testable strategy from inside a Tests/*.mq5 script. This           |
//| file therefore splits into a PURE aggregation function                          |
//| (_Build - no I/O beyond the one read-only SafeMode_IsActive() call,               |
//| never mutates its inputs, fully unit-testable field-by-field) and a                |
//| thin logging wrapper (_Log - calls _Build then emits the frozen six-line            |
//| block, never asserted on by exact text in any test).                                  |
//|                                                                                          |
//| lifecycle_and_reconciliation_ran is NEVER re-derived from any counter -                   |
//| it is exactly the caller-supplied signal (rejAuth.ok at the real call                      |
//| site in MLQuantAI.mq5), since that is the one value that actually gated                     |
//| the C3.7/BrokerReconciliation control flow.                                                   |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ASYNCTERMINALREJECTIONSTARTUPDIAGNOSTICS_MQH__
#define __MLQUANTAI_ASYNCTERMINALREJECTIONSTARTUPDIAGNOSTICS_MQH__

#include "MLQuantAI_AsyncTerminalOrderObservationMatcher.mqh"
#include "MLQuantAI_AsyncTerminalRejectionAuthority.mqh"
#include "MLQuantAI_AsyncTerminalRejectionAudit.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_SafeModeState.mqh"
#include "../Logging/MLQuantAI_SystemLogger.mqh"

struct AsyncTerminalRejectionStartupDiagnostics
{
   bool   atom_ok;
   bool   authority_ok;
   bool   audit_ok;
   bool   lifecycle_and_reconciliation_ran;
   bool   safe_mode_active;
   int    observations_total;
   int    matched_total;
   int    unmatched_total;
   int    ambiguity_total;
   int    confirmations_written;
   int    audit_findings_total;
   string authority_stop_reason;
   string audit_first_error;
};

//---------------------------------------------------------------------
// PURE - no I/O beyond the one read-only SafeMode_IsActive() call, no
// logging, never mutates atomReport/authorityReport/auditReport. Field
// mapping locked (Checkpoint 1):
//   observations_total = atomReport.relevant_total (same field C3.10B's
//   own AsyncTerminalRejectionAuthorityReport.observations_total uses)
//   audit_findings_total = sum of auditReport's 6 finding counters,
//   computed here only - never written back into auditReport.
//---------------------------------------------------------------------
AsyncTerminalRejectionStartupDiagnostics AsyncTerminalRejectionStartupDiagnostics_Build(
   const AsyncTerminalOrderMatchReport &atomReport,
   const AsyncTerminalRejectionAuthorityReport &authorityReport,
   const AsyncTerminalRejectionAuditReport &auditReport,
   bool lifecycleAndReconciliationRan)
{
   AsyncTerminalRejectionStartupDiagnostics d;

   d.atom_ok                          = atomReport.ok;
   d.authority_ok                     = authorityReport.ok;
   d.audit_ok                         = auditReport.ok;
   d.lifecycle_and_reconciliation_ran = lifecycleAndReconciliationRan;
   d.safe_mode_active                 = SafeMode_IsActive();

   d.observations_total  = atomReport.relevant_total;
   d.matched_total        = atomReport.matched_count;
   d.unmatched_total       = atomReport.unmatched_count;
   d.ambiguity_total        = atomReport.ambiguous_count;

   d.confirmations_written = authorityReport.confirmed_count;
   d.authority_stop_reason = authorityReport.stop_reason;

   d.audit_findings_total = auditReport.missing_transition_count +
                              auditReport.missing_confirmation_count +
                              auditReport.duplicate_confirmation_count +
                              auditReport.provenance_mismatch_count +
                              auditReport.source_evidence_missing_count +
                              auditReport.source_evidence_ambiguous_count;
   d.audit_first_error = auditReport.first_error;

   return d;
}

//---------------------------------------------------------------------
// THE entry point. Slots after the C3.10C call (Checkpoint 2 section 6
// of the C3.10C contract, unchanged) - never alters, re-derives, or
// depends on anything beyond the four inputs handed to it. Frozen
// six-line block (Checkpoint 1): header, C3.10A, C3.10B, C3.10C,
// C3.7/BrokerReconciliation, Safe Mode.
//---------------------------------------------------------------------
void AsyncTerminalRejectionStartupDiagnostics_Log(
   const AsyncTerminalOrderMatchReport &atomReport,
   const AsyncTerminalRejectionAuthorityReport &authorityReport,
   const AsyncTerminalRejectionAuditReport &auditReport,
   bool lifecycleAndReconciliationRan)
{
   AsyncTerminalRejectionStartupDiagnostics d =
      AsyncTerminalRejectionStartupDiagnostics_Build(atomReport, authorityReport, auditReport, lifecycleAndReconciliationRan);

   LogInfo("=== C3.10 async terminal rejection pipeline: startup summary ===");

   if(d.atom_ok)
      LogInfo(StringFormat("  C3.10A observations: %d total (%d matched, %d unmatched, %d ambiguous)",
              d.observations_total, d.matched_total, d.unmatched_total, d.ambiguity_total));
   else
      LogWarn(StringFormat("  C3.10A observations: %d total (%d matched, %d unmatched, %d ambiguous) - AMBIGUITY PRESENT",
              d.observations_total, d.matched_total, d.unmatched_total, d.ambiguity_total));

   if(d.authority_ok)
      LogInfo(StringFormat("  C3.10B authority: ok - %d confirmation(s) written", d.confirmations_written));
   else
      LogWarn(StringFormat("  C3.10B authority: HELD - %d confirmation(s) written - stop_reason=%s",
              d.confirmations_written, d.authority_stop_reason));

   if(d.audit_ok)
      LogInfo("  C3.10C audit: ok - 0 findings");
   else
      LogWarn(StringFormat("  C3.10C audit: FINDINGS PRESENT - %d finding(s) - first_error=%s",
              d.audit_findings_total, d.audit_first_error));

   LogInfo(StringFormat("  C3.7/BrokerReconciliation: %s",
           d.lifecycle_and_reconciliation_ran ? "ran" : "SKIPPED (authority hold)"));

   if(d.safe_mode_active)
      LogWarn("  Safe Mode: ACTIVE");
   else
      LogInfo("  Safe Mode: clear");
}

#endif // __MLQUANTAI_ASYNCTERMINALREJECTIONSTARTUPDIAGNOSTICS_MQH__
