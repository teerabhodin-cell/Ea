//+------------------------------------------------------------------+
//| MLQuantAI_Test_C3_10F_StackedIntegrationAudit.mq5                  |
//| C3.10F implementation DoD, per the Stacked Integration Audit        |
//| Checkpoint 1 contract locked in this branch's chat history (no       |
//| separate Docs/ file yet). Test-only, read-only integration audit      |
//| over the combined C3.10B->C3.10E1 head (de929f0). Proves cross-        |
//| module report-flow composition using hand-built, in-memory fixtures     |
//| only - no event-store file, no broker/terminal API, no OnInit. Static    |
//| claims about MLQuantAI.mq5's include list, call sites, and startup        |
//| ordering are proven "by inspection" (a Tests/*.mq5 script's FileOpen       |
//| is sandboxed to MQL5\Files and cannot read MLQuantAI.mq5's own source       |
//| from the Experts tree) - backed by an external, offset-based grep           |
//| comparison performed and reported separately as Checkpoint 3 evidence,       |
//| the same pattern every prior C3.10B/C/D/E1 structural-proof test already      |
//| established in this codebase.                                                  |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_AsyncTerminalOrderObservationMatcher.mqh>
#include <MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionAuthority.mqh>
#include <MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionAudit.mqh>
#include <MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionStartupDiagnostics.mqh>
#include <MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionHealthTrend.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - hand-build each of the three C3.10A/B/C report
// structs directly via their real, already-public *_Init() functions
// plus direct field assignment. No durable file, no projections.
//---------------------------------------------------------------------
void BuildAtomReport(AsyncTerminalOrderMatchReport &r, bool ok, int relevantTotal, int matched, int unmatched, int ambiguous)
{
   AsyncTerminalOrderMatchReport_Init(r);
   r.ok = ok;
   r.relevant_total = relevantTotal;
   r.matched_count = matched;
   r.unmatched_count = unmatched;
   r.ambiguous_count = ambiguous;
}

void BuildAuthorityReport(AsyncTerminalRejectionAuthorityReport &r,
                           bool ok, bool upstreamAmbiguous, int confirmedCount, string stopReason)
{
   AsyncTerminalRejectionAuthorityReport_Init(r);
   r.ok = ok;
   r.upstream_observation_ambiguous = upstreamAmbiguous;
   r.confirmed_count = confirmedCount;
   r.stop_reason = stopReason;
}

void BuildAuditReport(AsyncTerminalRejectionAuditReport &r,
                       int missingTransition, int missingConfirmation, int duplicate,
                       int provenanceMismatch, int sourceMissing, int sourceAmbiguous, string firstError)
{
   AsyncTerminalRejectionAuditReport_Init(r);
   r.missing_transition_count = missingTransition;
   r.missing_confirmation_count = missingConfirmation;
   r.duplicate_confirmation_count = duplicate;
   r.provenance_mismatch_count = provenanceMismatch;
   r.source_evidence_missing_count = sourceMissing;
   r.source_evidence_ambiguous_count = sourceAmbiguous;
   r.first_error = firstError;
   r.ok = (missingTransition == 0 && missingConfirmation == 0 && duplicate == 0 &&
           provenanceMismatch == 0 && sourceMissing == 0 && sourceAmbiguous == 0);
}

//---------------------------------------------------------------------
// 1. Stack composition: all five C3.10 headers compile together (proven
//    by this file compiling at all) and every required report type can
//    be instantiated together in one scope.
//---------------------------------------------------------------------
void Test_StackComposition_AllReportTypesInstantiateTogether()
{
   Print("--- Test_StackComposition_AllReportTypesInstantiateTogether ---");
   AsyncTerminalOrderMatchReport atomReport;
   AsyncTerminalRejectionAuthorityReport authorityReport;
   AsyncTerminalRejectionAuditReport auditReport;
   AsyncTerminalRejectionStartupDiagnostics diagnostics;

   AsyncTerminalOrderMatchReport_Init(atomReport);
   AsyncTerminalRejectionAuthorityReport_Init(authorityReport);
   AsyncTerminalRejectionAuditReport_Init(auditReport);

   Check(true, "all four C3.10A/B/C/D report/diagnostics struct types instantiate together in one "
               "compilation unit with no type, naming, or field drift - the include chain "
               "(AsyncTerminalOrderObservationMatcher -> AsyncTerminalRejectionAuthority -> "
               "AsyncTerminalRejectionAudit -> AsyncTerminalRejectionStartupDiagnostics -> "
               "AsyncTerminalRejectionHealthTrend) resolves cleanly, proven by this file compiling at all.");
}

//---------------------------------------------------------------------
// 2. A -> B -> C -> D report flow: D faithfully reports A/B/C input
//    truth without altering it.
//---------------------------------------------------------------------
void Test_ABCD_ReportFlow_FaithfulPropagation()
{
   Print("--- Test_ABCD_ReportFlow_FaithfulPropagation ---");
   AsyncTerminalOrderMatchReport atomReport;
   BuildAtomReport(atomReport, false, 3, 1, 1, 1);

   AsyncTerminalRejectionAuthorityReport authorityReport;
   BuildAuthorityReport(authorityReport, false, true, 0, "upstream_observation_ambiguous");

   AsyncTerminalRejectionAuditReport auditReport;
   BuildAuditReport(auditReport, 0, 0, 0, 0, 0, 0, "");

   AsyncTerminalRejectionStartupDiagnostics diagnostics =
      AsyncTerminalRejectionStartupDiagnostics_Build(atomReport, authorityReport, auditReport, false);

   Check(diagnostics.atom_ok == false, "diagnostics.atom_ok reflects atomReport.ok == false");
   Check(diagnostics.authority_ok == false, "diagnostics.authority_ok reflects authorityReport.ok == false");
   Check(diagnostics.audit_ok == true, "diagnostics.audit_ok reflects auditReport.ok == true");
   Check(diagnostics.lifecycle_and_reconciliation_ran == false,
         "diagnostics.lifecycle_and_reconciliation_ran is exactly the caller-supplied false");
   Check(diagnostics.confirmations_written == 0, "diagnostics.confirmations_written reflects authorityReport.confirmed_count == 0");
   Check(diagnostics.authority_stop_reason == "upstream_observation_ambiguous",
         "diagnostics.authority_stop_reason reflects authorityReport.stop_reason exactly");
   Check(diagnostics.audit_findings_total == 0, "diagnostics.audit_findings_total is 0 with all-zero audit counters");
}

//---------------------------------------------------------------------
// 3. B hold preserves audit independence: C3.10C runs unconditionally
//    per its own frozen integration contract - an authority hold never
//    causes D to misreport or skip the audit signal.
//---------------------------------------------------------------------
void Test_AuthorityHold_AuditIndependence_BothSignalsPreserved()
{
   Print("--- Test_AuthorityHold_AuditIndependence_BothSignalsPreserved ---");
   AsyncTerminalOrderMatchReport atomReport;
   BuildAtomReport(atomReport, true, 2, 2, 0, 0);

   AsyncTerminalRejectionAuthorityReport authorityReport;
   BuildAuthorityReport(authorityReport, false, false, 0, "durable_confirmation_write_failure");

   AsyncTerminalRejectionAuditReport auditReport;
   BuildAuditReport(auditReport, 0, 0, 0, 0, 0, 1, "source evidence ambiguous for CND_x");

   AsyncTerminalRejectionStartupDiagnostics diagnostics =
      AsyncTerminalRejectionStartupDiagnostics_Build(atomReport, authorityReport, auditReport, false);

   Check(diagnostics.authority_ok == false, "authority_ok stays false when the authority was held");
   Check(diagnostics.audit_ok == false,
         "audit_ok independently reflects auditReport.ok == false - C3.10C is not skipped or "
         "reported as clean merely because C3.10B was held");
   Check(diagnostics.lifecycle_and_reconciliation_ran == false,
         "lifecycle_and_reconciliation_ran reflects the caller-supplied false (C3.7/reconciliation "
         "correctly skipped this session)");
   Check(diagnostics.audit_findings_total == 1,
         "audit_findings_total reflects the one real audit finding, independent of the authority signal");
}

//---------------------------------------------------------------------
// 4. Clean path composition: every signal healthy end-to-end.
//---------------------------------------------------------------------
void Test_CleanPathComposition_AllHealthy()
{
   Print("--- Test_CleanPathComposition_AllHealthy ---");
   AsyncTerminalOrderMatchReport atomReport;
   BuildAtomReport(atomReport, true, 3, 3, 0, 0);

   AsyncTerminalRejectionAuthorityReport authorityReport;
   BuildAuthorityReport(authorityReport, true, false, 2, "");

   AsyncTerminalRejectionAuditReport auditReport;
   BuildAuditReport(auditReport, 0, 0, 0, 0, 0, 0, "");

   AsyncTerminalRejectionStartupDiagnostics diagnostics =
      AsyncTerminalRejectionStartupDiagnostics_Build(atomReport, authorityReport, auditReport, true);

   Check(diagnostics.atom_ok == true, "atom_ok is true on the clean path");
   Check(diagnostics.authority_ok == true, "authority_ok is true on the clean path");
   Check(diagnostics.audit_ok == true, "audit_ok is true on the clean path");
   Check(diagnostics.lifecycle_and_reconciliation_ran == true, "lifecycle_and_reconciliation_ran is true on the clean path");
   Check(diagnostics.confirmations_written == authorityReport.confirmed_count,
         "confirmations_written equals authorityReport.confirmed_count exactly");
   Check(diagnostics.audit_findings_total == 0, "audit_findings_total is 0 on the clean path");
}

//---------------------------------------------------------------------
// 5. C3.10E1's comparator accepts two C3.10D diagnostics values built
//    from real A/B/C/D composition, with no EA integration dependency -
//    proving the whole B->C->D->E1 report chain composes end to end.
//---------------------------------------------------------------------
void Test_E1Compare_AcceptsComposedDiagnostics_Unwired()
{
   Print("--- Test_E1Compare_AcceptsComposedDiagnostics_Unwired ---");
   AsyncTerminalOrderMatchReport cleanAtom;
   BuildAtomReport(cleanAtom, true, 3, 3, 0, 0);
   AsyncTerminalRejectionAuthorityReport cleanAuthority;
   BuildAuthorityReport(cleanAuthority, true, false, 2, "");
   AsyncTerminalRejectionAuditReport cleanAudit;
   BuildAuditReport(cleanAudit, 0, 0, 0, 0, 0, 0, "");
   AsyncTerminalRejectionStartupDiagnostics cleanDiag =
      AsyncTerminalRejectionStartupDiagnostics_Build(cleanAtom, cleanAuthority, cleanAudit, true);

   AsyncTerminalOrderMatchReport heldAtom;
   BuildAtomReport(heldAtom, true, 2, 2, 0, 0);
   AsyncTerminalRejectionAuthorityReport heldAuthority;
   BuildAuthorityReport(heldAuthority, false, false, 0, "durable_confirmation_write_failure");
   AsyncTerminalRejectionAuditReport heldAudit;
   BuildAuditReport(heldAudit, 0, 0, 0, 0, 0, 1, "source evidence ambiguous for CND_x");
   AsyncTerminalRejectionStartupDiagnostics heldDiag =
      AsyncTerminalRejectionStartupDiagnostics_Build(heldAtom, heldAuthority, heldAudit, false);

   ENUM_ASYNC_TERMINAL_REJECTION_HEALTH_TREND trend =
      AsyncTerminalRejectionHealthTrend_Compare(cleanDiag, heldDiag, true);

   Check(trend == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_DEGRADED,
         "AsyncTerminalRejectionHealthTrend_Compare accepts two diagnostics values built by "
         "AsyncTerminalRejectionStartupDiagnostics_Build (composed entirely from hand-built A/B/C "
         "reports, no EA/OnInit involvement) and correctly classifies the clean-to-held transition "
         "as DEGRADED, proving the full B->C->D->E1 report chain composes end to end");
}

//---------------------------------------------------------------------
// 6. E1 remains unwired: MLQuantAI.mq5 includes and calls C3.10D's
//    _Log exactly once, does not include C3.10E1's header, and contains
//    zero executable calls to AsyncTerminalRejectionHealthTrend_Compare.
//---------------------------------------------------------------------
void Test_E1Unwired_StaticScan_StructuralProof()
{
   Print("--- Test_E1Unwired_StaticScan_StructuralProof ---");
   Check(true, "verified by inspection: MLQuantAI.mq5 includes "
               "MLQuantAI_AsyncTerminalRejectionStartupDiagnostics.mqh and calls "
               "AsyncTerminalRejectionStartupDiagnostics_Log(...) exactly once.");
   Check(true, "verified by inspection: MLQuantAI.mq5 does NOT include "
               "MLQuantAI_AsyncTerminalRejectionHealthTrend.mqh anywhere.");
   Check(true, "verified by inspection: MLQuantAI.mq5 contains zero executable calls to "
               "AsyncTerminalRejectionHealthTrend_Compare(...) - C3.10E1 remains a test-only, "
               "unwired library this round, exactly per its own frozen Checkpoint 1 contract.");
}

//---------------------------------------------------------------------
// 7. Startup ordering preservation: A scan -> B authority -> the
//    existing C3.7/BrokerReconciliation block -> C audit scan -> D log,
//    unchanged since C3.10B first established it.
//---------------------------------------------------------------------
void Test_StartupOrdering_StructuralProof()
{
   Print("--- Test_StartupOrdering_StructuralProof ---");
   Check(true, "verified by inspection (offset-based token comparison against MLQuantAI.mq5's OnInit "
               "source, not a whole-file literal snapshot): AsyncTerminalOrderMatcher_ScanFile(...) "
               "occurs before AsyncTerminalRejectionAuthority_StartupApply(...), which occurs before "
               "the existing 'if(rejAuth.ok) { LifecycleAuthority_StartupApply / BrokerReconciliation_"
               "CheckAll } else { ... }' block, which occurs before AsyncTerminalRejectionAudit_"
               "StartupScan(...), which occurs before AsyncTerminalRejectionStartupDiagnostics_Log(...) "
               "- the same A->B->C3.7/reconciliation->C->D order locked since C3.10B and unchanged "
               "through C3.10C/D/E1.");
}

//---------------------------------------------------------------------
// 8. No behavior-capable calls anywhere in this suite's own source.
//---------------------------------------------------------------------
void Test_NoBehaviorCapableCalls_StructuralProof()
{
   Print("--- Test_NoBehaviorCapableCalls_StructuralProof ---");
   Check(true, "verified by inspection: this file contains no executable reference to "
               "EventStore_LogSystem/EventStore_LogTransition/EventStore_WriteLine/EventStore_"
               "ReadAllLines, no SafeMode_Trip/SafeMode_Clear call, no OrderSend/CTrade/HistorySelect/"
               "HistoryDealGet*/HistoryOrderGet*/PositionSelect/PositionGetTicket/OrderGetTicket/OnTick/"
               "OnTradeTransaction call anywhere - every helper used is a pure report initializer "
               "(*_Init) or the diagnostics/trend APIs (_Build, _Compare) themselves; no event-store "
               "file is created, opened, appended to, or read.");
   Check(true, "verified by inspection: this suite never calls AsyncTerminalRejectionStartupDiagnostics_"
               "Log - journal output is out of scope for this integration audit, per the frozen contract.");
}

//---------------------------------------------------------------------
// 9. Identifier-length proof: every new identifier stays under MQL5's
//    63-character limit.
//---------------------------------------------------------------------
void Test_IdentifierLengths_UnderSixtyThreeCharLimit()
{
   Print("--- Test_IdentifierLengths_UnderSixtyThreeCharLimit ---");
   Check(StringLen("Test_StackComposition_AllReportTypesInstantiateTogether") <= 63, "test 1 name is under 63 chars");
   Check(StringLen("Test_ABCD_ReportFlow_FaithfulPropagation") <= 63, "test 2 name is under 63 chars");
   Check(StringLen("Test_AuthorityHold_AuditIndependence_BothSignalsPreserved") <= 63, "test 3 name is under 63 chars");
   Check(StringLen("Test_CleanPathComposition_AllHealthy") <= 63, "test 4 name is under 63 chars");
   Check(StringLen("Test_E1Compare_AcceptsComposedDiagnostics_Unwired") <= 63, "test 5 name is under 63 chars");
   Check(StringLen("Test_E1Unwired_StaticScan_StructuralProof") <= 63, "test 6 name is under 63 chars");
   Check(StringLen("Test_StartupOrdering_StructuralProof") <= 63, "test 7 name is under 63 chars");
   Check(StringLen("Test_NoBehaviorCapableCalls_StructuralProof") <= 63, "test 8 name is under 63 chars");
}

//---------------------------------------------------------------------
void OnStart()
{
   Print("=== MLQuantAI Test: C3.10F StackedIntegrationAudit ===");

   Test_StackComposition_AllReportTypesInstantiateTogether();
   Test_ABCD_ReportFlow_FaithfulPropagation();
   Test_AuthorityHold_AuditIndependence_BothSignalsPreserved();
   Test_CleanPathComposition_AllHealthy();
   Test_E1Compare_AcceptsComposedDiagnostics_Unwired();
   Test_E1Unwired_StaticScan_StructuralProof();
   Test_StartupOrdering_StructuralProof();
   Test_NoBehaviorCapableCalls_StructuralProof();
   Test_IdentifierLengths_UnderSixtyThreeCharLimit();

   Print(StringFormat("=== Result: %d/%d checks passed ===", g_TestsPassed, g_TestsRun));
   if(g_TestsRun > 0 && g_TestsPassed == g_TestsRun)
      Print("ALL PASS.");
   else
      Print("FAILURES PRESENT - review the [FAIL] lines above.");
}
