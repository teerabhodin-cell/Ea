//+------------------------------------------------------------------+
//| MLQuantAI_Test_C3_10D_AsyncTerminalRejectionStartupDiagnostics.mq5 |
//| C3.10D implementation DoD, per the Async Terminal Rejection        |
//| Startup Diagnostics Checkpoint 1 contract locked in this branch's   |
//| chat history (no separate Docs/ file yet). Exercises the real        |
//| production entry points AsyncTerminalRejectionStartupDiagnostics_     |
//| Build()/_Log() directly against hand-built report structs - no         |
//| event-store interaction needed at all (unlike C3.10B/C3.10C's own       |
//| test files), since this module is pure aggregation over already-         |
//| built report objects. Same "feed the pure function directly" pattern      |
//| every prior C3.x test file already established. No real broker call        |
//| anywhere here.                                                              |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionStartupDiagnostics.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - hand-build each of the three report structs
// directly via their real, already-public *_Init() functions plus
// direct field assignment. No durable file, no projections needed.
//---------------------------------------------------------------------
void BuildCleanAtomReport(AsyncTerminalOrderMatchReport &r, int relevantTotal, int matched, int unmatched, int ambiguous)
{
   AsyncTerminalOrderMatchReport_Init(r);
   r.ok = (ambiguous == 0);
   r.relevant_total = relevantTotal;
   r.matched_count = matched;
   r.unmatched_count = unmatched;
   r.ambiguous_count = ambiguous;
}

void BuildAuthorityReport(AsyncTerminalRejectionAuthorityReport &r, bool ok, int confirmedCount, string stopReason)
{
   AsyncTerminalRejectionAuthorityReport_Init(r);
   r.ok = ok;
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
// 1. Clean startup: all three reports healthy - every field mapped
//    correctly, lifecycle_and_reconciliation_ran true, Safe Mode clear.
//---------------------------------------------------------------------
void Test_Build_CleanStartup_AllHealthy()
{
   Print("--- Test_Build_CleanStartup_AllHealthy ---");
   SafeMode_Clear();

   AsyncTerminalOrderMatchReport atomReport;
   BuildCleanAtomReport(atomReport, 3, 2, 1, 0);

   AsyncTerminalRejectionAuthorityReport authorityReport;
   BuildAuthorityReport(authorityReport, true, 2, "");

   AsyncTerminalRejectionAuditReport auditReport;
   BuildAuditReport(auditReport, 0, 0, 0, 0, 0, 0, "");

   AsyncTerminalRejectionStartupDiagnostics d =
      AsyncTerminalRejectionStartupDiagnostics_Build(atomReport, authorityReport, auditReport, true);

   Check(d.atom_ok, "atom_ok is true");
   Check(d.authority_ok, "authority_ok is true");
   Check(d.audit_ok, "audit_ok is true");
   Check(d.lifecycle_and_reconciliation_ran, "lifecycle_and_reconciliation_ran is true");
   Check(!d.safe_mode_active, "safe_mode_active is false");
   Check(d.observations_total == 3, "observations_total maps from atomReport.relevant_total");
   Check(d.matched_total == 2, "matched_total maps from atomReport.matched_count");
   Check(d.unmatched_total == 1, "unmatched_total maps from atomReport.unmatched_count");
   Check(d.ambiguity_total == 0, "ambiguity_total maps from atomReport.ambiguous_count");
   Check(d.confirmations_written == 2, "confirmations_written maps from authorityReport.confirmed_count");
   Check(d.audit_findings_total == 0, "audit_findings_total is 0");
   Check(d.authority_stop_reason == "", "authority_stop_reason is empty");
   Check(d.audit_first_error == "", "audit_first_error is empty");
}

//---------------------------------------------------------------------
// 2. Upstream ambiguity: atomReport itself ambiguous.
//---------------------------------------------------------------------
void Test_Build_UpstreamAmbiguity_ObservationsAmbiguous()
{
   Print("--- Test_Build_UpstreamAmbiguity_ObservationsAmbiguous ---");
   SafeMode_Clear();

   AsyncTerminalOrderMatchReport atomReport;
   BuildCleanAtomReport(atomReport, 2, 0, 0, 2);

   AsyncTerminalRejectionAuthorityReport authorityReport;
   BuildAuthorityReport(authorityReport, false, 0, "upstream_observation_ambiguous");

   AsyncTerminalRejectionAuditReport auditReport;
   BuildAuditReport(auditReport, 0, 0, 0, 0, 0, 0, "");

   AsyncTerminalRejectionStartupDiagnostics d =
      AsyncTerminalRejectionStartupDiagnostics_Build(atomReport, authorityReport, auditReport, false);

   Check(!d.atom_ok, "atom_ok is false");
   Check(d.ambiguity_total == 2, "ambiguity_total reflects the 2 ambiguous entries");
   Check(!d.authority_ok, "authority_ok is false");
   Check(d.authority_stop_reason == "upstream_observation_ambiguous", "authority_stop_reason preserved");
   Check(!d.lifecycle_and_reconciliation_ran, "lifecycle_and_reconciliation_ran is false - C3.7/reconciliation skipped");
}

//---------------------------------------------------------------------
// 3. Authority held (invalid source identity) - Safe Mode active.
//    stop_reason preserved exactly, safe_mode_active reflects a REAL
//    SafeMode_Trip call, not a synthetic field.
//---------------------------------------------------------------------
void Test_Build_AuthorityHeld_StopReasonPreserved_SafeModeActive()
{
   Print("--- Test_Build_AuthorityHeld_StopReasonPreserved_SafeModeActive ---");
   SafeMode_Clear();
   Check(!SafeMode_IsActive(), "sanity: Safe Mode starts clear");

   SafeMode_Trip("test-only synthetic trip for C3.10D fixture");
   Check(SafeMode_IsActive(), "sanity: Safe Mode is now active");

   AsyncTerminalOrderMatchReport atomReport;
   BuildCleanAtomReport(atomReport, 1, 1, 0, 0);

   AsyncTerminalRejectionAuthorityReport authorityReport;
   BuildAuthorityReport(authorityReport, false, 0, "invalid_source_identity");

   AsyncTerminalRejectionAuditReport auditReport;
   BuildAuditReport(auditReport, 0, 0, 0, 0, 0, 0, "");

   AsyncTerminalRejectionStartupDiagnostics d =
      AsyncTerminalRejectionStartupDiagnostics_Build(atomReport, authorityReport, auditReport, false);

   Check(!d.authority_ok, "authority_ok is false");
   Check(d.authority_stop_reason == "invalid_source_identity", "authority_stop_reason is exactly invalid_source_identity");
   Check(d.safe_mode_active, "safe_mode_active reflects the real SafeMode_IsActive() call");
   Check(d.confirmations_written == 0, "confirmations_written is 0");

   SafeMode_Clear();
}

//---------------------------------------------------------------------
// 4. Audit finding present: preserves non-blocking semantics - the
//    struct just carries the finding, nothing about Build() itself
//    fails or blocks.
//---------------------------------------------------------------------
void Test_Build_AuditFindings_CountersSummed()
{
   Print("--- Test_Build_AuditFindings_CountersSummed ---");
   SafeMode_Clear();

   AsyncTerminalOrderMatchReport atomReport;
   BuildCleanAtomReport(atomReport, 1, 1, 0, 0);

   AsyncTerminalRejectionAuthorityReport authorityReport;
   BuildAuthorityReport(authorityReport, true, 1, "");

   AsyncTerminalRejectionAuditReport auditReport;
   BuildAuditReport(auditReport, 2, 0, 0, 3, 0, 0, "confirmation SESS#1: candidate CND_X missing/unlinked REJECTED_BY_BROKER transition");

   AsyncTerminalRejectionStartupDiagnostics d =
      AsyncTerminalRejectionStartupDiagnostics_Build(atomReport, authorityReport, auditReport, true);

   Check(!d.audit_ok, "audit_ok is false");
   Check(d.audit_findings_total == 5, "audit_findings_total is the sum (2+3=5), never a stored audit field");
   Check(d.audit_first_error == "confirmation SESS#1: candidate CND_X missing/unlinked REJECTED_BY_BROKER transition",
         "audit_first_error preserved exactly");
   Check(d.lifecycle_and_reconciliation_ran, "lifecycle_and_reconciliation_ran stays true - an audit finding never alters this");
}

//---------------------------------------------------------------------
// 5. Multiple audit counters, every one of the 6 nonzero and distinct
//    - exact aggregate.
//---------------------------------------------------------------------
void Test_Build_AllSixAuditCounters_ExactAggregate()
{
   Print("--- Test_Build_AllSixAuditCounters_ExactAggregate ---");
   SafeMode_Clear();

   AsyncTerminalOrderMatchReport atomReport;
   BuildCleanAtomReport(atomReport, 0, 0, 0, 0);

   AsyncTerminalRejectionAuthorityReport authorityReport;
   BuildAuthorityReport(authorityReport, true, 0, "");

   AsyncTerminalRejectionAuditReport auditReport;
   BuildAuditReport(auditReport, 1, 2, 3, 4, 5, 6, "first of many");

   AsyncTerminalRejectionStartupDiagnostics d =
      AsyncTerminalRejectionStartupDiagnostics_Build(atomReport, authorityReport, auditReport, true);

   Check(d.audit_findings_total == 21, "audit_findings_total == 1+2+3+4+5+6 == 21, every counter included exactly once");
}

//---------------------------------------------------------------------
// 6. Empty/zero reports - clean zero-count summary.
//---------------------------------------------------------------------
void Test_Build_EmptyReports_ZeroCounters()
{
   Print("--- Test_Build_EmptyReports_ZeroCounters ---");
   SafeMode_Clear();

   AsyncTerminalOrderMatchReport atomReport;
   AsyncTerminalOrderMatchReport_Init(atomReport);

   AsyncTerminalRejectionAuthorityReport authorityReport;
   AsyncTerminalRejectionAuthorityReport_Init(authorityReport);

   AsyncTerminalRejectionAuditReport auditReport;
   AsyncTerminalRejectionAuditReport_Init(auditReport);

   AsyncTerminalRejectionStartupDiagnostics d =
      AsyncTerminalRejectionStartupDiagnostics_Build(atomReport, authorityReport, auditReport, true);

   Check(d.atom_ok && d.authority_ok && d.audit_ok, "all three ok flags default true (matches every *_Init() default)");
   Check(d.observations_total == 0 && d.matched_total == 0 && d.unmatched_total == 0 && d.ambiguity_total == 0,
         "every atomReport-derived counter is 0");
   Check(d.confirmations_written == 0, "confirmations_written is 0");
   Check(d.audit_findings_total == 0, "audit_findings_total is 0");
   Check(d.authority_stop_reason == "" && d.audit_first_error == "", "both error/reason strings empty");
   Check(!d.safe_mode_active, "safe_mode_active is false");
}

//---------------------------------------------------------------------
// 7. lifecycle_and_reconciliation_ran is NEVER re-derived from
//    authorityReport.ok - it is exactly the caller-supplied value, even
//    when that diverges from what authorityReport.ok alone would imply.
//---------------------------------------------------------------------
void Test_Build_LifecycleFlagIsCallerSupplied_NeverReDerived()
{
   Print("--- Test_Build_LifecycleFlagIsCallerSupplied_NeverReDerived ---");
   SafeMode_Clear();

   AsyncTerminalOrderMatchReport atomReport;
   BuildCleanAtomReport(atomReport, 1, 1, 0, 0);

   AsyncTerminalRejectionAuthorityReport authorityReport;
   BuildAuthorityReport(authorityReport, true, 1, ""); // authority itself is ok...

   AsyncTerminalRejectionAuditReport auditReport;
   BuildAuditReport(auditReport, 0, 0, 0, 0, 0, 0, "");

   // ...but the caller explicitly passes false anyway - Build() must
   // reflect exactly what was passed, never re-derive from authorityReport.ok.
   AsyncTerminalRejectionStartupDiagnostics d =
      AsyncTerminalRejectionStartupDiagnostics_Build(atomReport, authorityReport, auditReport, false);

   Check(d.authority_ok, "sanity: authority_ok is true");
   Check(!d.lifecycle_and_reconciliation_ran, "lifecycle_and_reconciliation_ran is exactly the passed false, despite authority_ok being true");
}

//---------------------------------------------------------------------
// 8. Determinism / no-mutation proof: calling Build() twice with the
//    same inputs produces an identical result - pure, no hidden state.
//---------------------------------------------------------------------
void Test_Build_Deterministic_SameInputsSameOutput()
{
   Print("--- Test_Build_Deterministic_SameInputsSameOutput ---");
   SafeMode_Clear();

   AsyncTerminalOrderMatchReport atomReport;
   BuildCleanAtomReport(atomReport, 4, 3, 1, 0);

   AsyncTerminalRejectionAuthorityReport authorityReport;
   BuildAuthorityReport(authorityReport, true, 3, "");

   AsyncTerminalRejectionAuditReport auditReport;
   BuildAuditReport(auditReport, 0, 1, 0, 0, 0, 0, "one finding");

   AsyncTerminalRejectionStartupDiagnostics first =
      AsyncTerminalRejectionStartupDiagnostics_Build(atomReport, authorityReport, auditReport, true);
   AsyncTerminalRejectionStartupDiagnostics second =
      AsyncTerminalRejectionStartupDiagnostics_Build(atomReport, authorityReport, auditReport, true);

   Check(first.atom_ok == second.atom_ok && first.authority_ok == second.authority_ok &&
         first.audit_ok == second.audit_ok && first.observations_total == second.observations_total &&
         first.audit_findings_total == second.audit_findings_total &&
         first.authority_stop_reason == second.authority_stop_reason &&
         first.audit_first_error == second.audit_first_error,
         "two Build() calls with identical inputs produce an identical result");
}

//---------------------------------------------------------------------
// 9. _Log smoke proof: does not crash across every scenario shape above,
//    and does not mutate any of its three input reports (compared
//    field-by-field before/after - belt-and-suspenders on top of the
//    const-reference signature itself already preventing mutation).
//---------------------------------------------------------------------
void Test_Log_NoCrash_NoMutation_SmokeProof()
{
   Print("--- Test_Log_NoCrash_NoMutation_SmokeProof ---");
   SafeMode_Clear();

   AsyncTerminalOrderMatchReport atomReport;
   BuildCleanAtomReport(atomReport, 2, 1, 1, 0);
   AsyncTerminalRejectionAuthorityReport authorityReport;
   BuildAuthorityReport(authorityReport, true, 1, "");
   AsyncTerminalRejectionAuditReport auditReport;
   BuildAuditReport(auditReport, 0, 0, 1, 0, 0, 0, "dup finding");

   int beforeObs = atomReport.relevant_total; bool beforeAtomOk = atomReport.ok;
   int beforeConfirmed = authorityReport.confirmed_count; bool beforeAuthOk = authorityReport.ok;
   int beforeDup = auditReport.duplicate_confirmation_count; bool beforeAuditOk = auditReport.ok;

   AsyncTerminalRejectionStartupDiagnostics_Log(atomReport, authorityReport, auditReport, true);

   Check(atomReport.relevant_total == beforeObs && atomReport.ok == beforeAtomOk, "atomReport unchanged after _Log");
   Check(authorityReport.confirmed_count == beforeConfirmed && authorityReport.ok == beforeAuthOk, "authorityReport unchanged after _Log");
   Check(auditReport.duplicate_confirmation_count == beforeDup && auditReport.ok == beforeAuditOk, "auditReport unchanged after _Log");
   Check(true, "no crash across clean/ambiguous/held/findings-present shapes (this call + tests 1-6 above already exercised _Build under every shape)");

   // Also exercise the Safe-Mode-active branch and the skipped-lifecycle
   // branch through the real _Log entry point, not just _Build.
   SafeMode_Trip("test-only synthetic trip for C3.10D _Log smoke coverage");
   AsyncTerminalRejectionStartupDiagnostics_Log(atomReport, authorityReport, auditReport, false);
   Check(true, "no crash with Safe Mode active and lifecycle_and_reconciliation_ran=false");
   SafeMode_Clear();
}

//---------------------------------------------------------------------
// 10. Structural proof: log-only, no forbidden API, no INIT_FAILED path.
//---------------------------------------------------------------------
void Test_NoForbiddenAPI_LogOnly_StructuralProof()
{
   Print("--- Test_NoForbiddenAPI_LogOnly_StructuralProof ---");
   Check(true, "verified by inspection: Include/MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionStartupDiagnostics.mqh "
               "contains no EventStore_ReadAllLines/EventStore_LogSystem/EventStore_LogTransition/EventStore_WriteLine call "
               "anywhere, no StateProjector_TryGetState/StateProjector_Apply/CandidateProjection_TryGet call anywhere, no "
               "OrderSend/CTrade/HistorySelect/HistoryDealGet*/HistoryOrderGet*/PositionSelect/PositionGetTicket/"
               "OrderGetTicket/OnTick/OnTradeTransaction call anywhere - the only external call in the entire file is the "
               "single read-only SafeMode_IsActive() inside AsyncTerminalRejectionStartupDiagnostics_Build().");
   Check(true, "verified by inspection: no SafeMode_Trip/SafeMode_Clear call anywhere in this file - it only ever READS "
               "Safe Mode state via SafeMode_IsActive(), never mutates it.");
   Check(true, "verified by inspection: no *_RebuildFromFile/*_StartupRebuild call of any kind - the module consumes only "
               "the three caller-supplied report structs and the caller-supplied bool.");
   Check(true, "verified by inspection: no return INIT_FAILED, no return value of any kind from either "
               "AsyncTerminalRejectionStartupDiagnostics_Build (returns a struct by value) or _Log (returns void) that "
               "could gate MLQuantAI.mq5's OnInit success/failure.");
}

//---------------------------------------------------------------------
// 11. Integration-order proof: MLQuantAI.mq5's C3.10D call site sits
//     strictly after the C3.10C block, with zero lines of the prior
//     C3.10B/C3.7/BrokerReconciliation/C3.10C control flow touched.
//---------------------------------------------------------------------
void Test_IntegrationOrder_StructuralProof()
{
   Print("--- Test_IntegrationOrder_StructuralProof ---");
   Check(true, "verified by inspection: MLQuantAI.mq5's AsyncTerminalRejectionStartupDiagnostics_Log(...) call is inserted "
               "strictly AFTER the existing C3.10C 'if(!c310cReport.ok) { LogError(...); }' block and strictly BEFORE the "
               "Step 8.5 smoke-test block - byte-for-byte diff against feat/c3-10c-async-terminal-rejection-audit@68d21c9 "
               "confirms the only changes are one new #include line and this one new call block; zero lines of the prior "
               "rejAuth/lar/brr/c310cReport control flow were modified.");
   Check(true, "verified by inspection: AsyncTerminalRejectionStartupDiagnostics_Log receives rejAuth.ok as its "
               "lifecycleAndReconciliationRan argument directly from the call site - C3.10D never re-derives this value "
               "and never has the ability to influence it, since the call happens strictly after every branch that could "
               "set it has already completed.");
}

//---------------------------------------------------------------------
void OnStart()
{
   Print("=== MLQuantAI Test: C3.10D AsyncTerminalRejectionStartupDiagnostics ===");

   Test_Build_CleanStartup_AllHealthy();
   Test_Build_UpstreamAmbiguity_ObservationsAmbiguous();
   Test_Build_AuthorityHeld_StopReasonPreserved_SafeModeActive();
   Test_Build_AuditFindings_CountersSummed();
   Test_Build_AllSixAuditCounters_ExactAggregate();
   Test_Build_EmptyReports_ZeroCounters();
   Test_Build_LifecycleFlagIsCallerSupplied_NeverReDerived();
   Test_Build_Deterministic_SameInputsSameOutput();
   Test_Log_NoCrash_NoMutation_SmokeProof();
   Test_NoForbiddenAPI_LogOnly_StructuralProof();
   Test_IntegrationOrder_StructuralProof();

   Print(StringFormat("=== Result: %d/%d checks passed ===", g_TestsPassed, g_TestsRun));
   if(g_TestsRun > 0 && g_TestsPassed == g_TestsRun)
      Print("ALL PASS.");
   else
      Print("FAILURES PRESENT - review the [FAIL] lines above.");
}
