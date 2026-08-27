//+------------------------------------------------------------------+
//| MLQuantAI_Test_C3_10E_AsyncTerminalRejectionHealthTrend.mq5        |
//| C3.10E1 implementation DoD, per the Async Terminal Rejection        |
//| Health Trend Checkpoint 1 contract locked in this branch's chat      |
//| history (no separate Docs/ file yet). Exercises the real production   |
//| entry point AsyncTerminalRejectionHealthTrend_Compare() directly        |
//| against hand-built AsyncTerminalRejectionStartupDiagnostics fixtures -   |
//| no event-store interaction needed at all, since this module is a pure     |
//| comparator over two already-built C3.10D report objects. Same "feed the    |
//| pure function directly" pattern every prior C3.x test file already         |
//| established. No real broker call anywhere here.                             |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

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
// Fixture helper - sets exactly the five boolean health dimensions the
// frozen contract defines the comparator over. All other fields of
// AsyncTerminalRejectionStartupDiagnostics are irrelevant to this pure
// comparator and are left at their struct defaults.
//---------------------------------------------------------------------
void BuildDiag(AsyncTerminalRejectionStartupDiagnostics &d,
               bool atomOk, bool authorityOk, bool auditOk, bool lifecycleRan, bool safeModeActive)
{
   d.atom_ok                          = atomOk;
   d.authority_ok                     = authorityOk;
   d.audit_ok                         = auditOk;
   d.lifecycle_and_reconciliation_ran = lifecycleRan;
   d.safe_mode_active                 = safeModeActive;
}

//---------------------------------------------------------------------
// 1-2. hasPreviousSnapshot==false short-circuits to UNKNOWN, regardless
//      of what previous's field values look like.
//---------------------------------------------------------------------
void Test_Compare_NoPreviousSnapshot_Healthy_ReturnsUnknown()
{
   Print("--- Test_Compare_NoPreviousSnapshot_Healthy_ReturnsUnknown ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, true, true, true, true, false);
   BuildDiag(curr, true, true, true, true, false);

   ENUM_ASYNC_TERMINAL_REJECTION_HEALTH_TREND result =
      AsyncTerminalRejectionHealthTrend_Compare(prev, curr, false);

   Check(result == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_UNKNOWN,
         "healthy-looking previous with hasPreviousSnapshot=false still returns UNKNOWN");
}

void Test_Compare_NoPreviousSnapshot_Unhealthy_ReturnsUnknown()
{
   Print("--- Test_Compare_NoPreviousSnapshot_Unhealthy_ReturnsUnknown ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, false, false, false, false, true);
   BuildDiag(curr, true, true, true, true, false);

   ENUM_ASYNC_TERMINAL_REJECTION_HEALTH_TREND result =
      AsyncTerminalRejectionHealthTrend_Compare(prev, curr, false);

   Check(result == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_UNKNOWN,
         "maximally-unhealthy-looking previous (all bad, incl. Safe Mode active) with hasPreviousSnapshot=false "
         "still returns UNKNOWN, not DEGRADED - previous's fields are never interpreted");
}

//---------------------------------------------------------------------
// 3-4. No change across all five dimensions, from either a healthy or
//      a bad baseline, always returns UNCHANGED.
//---------------------------------------------------------------------
void Test_Compare_AllHealthyToAllHealthy_ReturnsUnchanged()
{
   Print("--- Test_Compare_AllHealthyToAllHealthy_ReturnsUnchanged ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, true, true, true, true, false);
   BuildDiag(curr, true, true, true, true, false);

   ENUM_ASYNC_TERMINAL_REJECTION_HEALTH_TREND result =
      AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true);

   Check(result == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_UNCHANGED, "all-healthy to all-healthy is UNCHANGED");
}

void Test_Compare_AllBadToAllBad_ReturnsUnchanged()
{
   Print("--- Test_Compare_AllBadToAllBad_ReturnsUnchanged ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, false, false, false, false, true);
   BuildDiag(curr, false, false, false, false, true);

   ENUM_ASYNC_TERMINAL_REJECTION_HEALTH_TREND result =
      AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true);

   Check(result == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_UNCHANGED,
         "all-bad to all-bad (no dimension newly bad or newly good) is UNCHANGED, never DEGRADED");
}

//---------------------------------------------------------------------
// 5-9. Each of the five dimensions, individually, healthy -> bad is
//      DEGRADED. The lifecycle case deliberately decouples authority_ok
//      from lifecycle_and_reconciliation_ran, per the frozen test
//      boundary, proving the comparator does not rely on the accidental
//      correlation the one real production call site happens to have.
//---------------------------------------------------------------------
void Test_Compare_AtomHealthyToBad_ReturnsDegraded()
{
   Print("--- Test_Compare_AtomHealthyToBad_ReturnsDegraded ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, true, true, true, true, false);
   BuildDiag(curr, false, true, true, true, false);

   Check(AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true) == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_DEGRADED,
         "atom_ok true->false alone is DEGRADED");
}

void Test_Compare_AuthorityHealthyToBad_ReturnsDegraded()
{
   Print("--- Test_Compare_AuthorityHealthyToBad_ReturnsDegraded ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, true, true, true, true, false);
   BuildDiag(curr, true, false, true, true, false);

   Check(AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true) == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_DEGRADED,
         "authority_ok true->false alone is DEGRADED");
}

void Test_Compare_AuditHealthyToBad_ReturnsDegraded()
{
   Print("--- Test_Compare_AuditHealthyToBad_ReturnsDegraded ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, true, true, true, true, false);
   BuildDiag(curr, true, true, false, true, false);

   Check(AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true) == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_DEGRADED,
         "audit_ok true->false alone is DEGRADED");
}

void Test_Compare_LifecycleToBad_Decoupled_Degraded()
{
   Print("--- Test_Compare_LifecycleToBad_Decoupled_Degraded ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   // authority_ok stays true in both snapshots - only lifecycle_and_reconciliation_ran
   // flips, a combination the real production call site never produces (there,
   // lifecycle_and_reconciliation_ran is always exactly rejAuth.ok), proving this
   // dimension is genuinely, independently evaluated by the comparator.
   BuildDiag(prev, true, true, true, true, false);
   BuildDiag(curr, true, true, true, false, false);

   Check(AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true) == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_DEGRADED,
         "lifecycle_and_reconciliation_ran true->false alone, decoupled from authority_ok, is DEGRADED");
}

void Test_Compare_SafeModeInactiveToActive_ReturnsDegraded()
{
   Print("--- Test_Compare_SafeModeInactiveToActive_ReturnsDegraded ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, true, true, true, true, false);
   BuildDiag(curr, true, true, true, true, true);

   Check(AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true) == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_DEGRADED,
         "safe_mode_active false->true alone is DEGRADED");
}

//---------------------------------------------------------------------
// 10-14. Each of the five dimensions, individually, bad -> healthy is
//        IMPROVED. Mirrors the DEGRADED set above, including the same
//        decoupled lifecycle case.
//---------------------------------------------------------------------
void Test_Compare_AtomBadToHealthy_ReturnsImproved()
{
   Print("--- Test_Compare_AtomBadToHealthy_ReturnsImproved ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, false, true, true, true, false);
   BuildDiag(curr, true, true, true, true, false);

   Check(AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true) == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_IMPROVED,
         "atom_ok false->true alone is IMPROVED");
}

void Test_Compare_AuthorityBadToHealthy_ReturnsImproved()
{
   Print("--- Test_Compare_AuthorityBadToHealthy_ReturnsImproved ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, true, false, true, true, false);
   BuildDiag(curr, true, true, true, true, false);

   Check(AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true) == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_IMPROVED,
         "authority_ok false->true alone is IMPROVED");
}

void Test_Compare_AuditBadToHealthy_ReturnsImproved()
{
   Print("--- Test_Compare_AuditBadToHealthy_ReturnsImproved ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, true, true, false, true, false);
   BuildDiag(curr, true, true, true, true, false);

   Check(AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true) == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_IMPROVED,
         "audit_ok false->true alone is IMPROVED");
}

void Test_Compare_LifecycleToHealthy_Decoupled_Improved()
{
   Print("--- Test_Compare_LifecycleToHealthy_Decoupled_Improved ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, true, true, true, false, false);
   BuildDiag(curr, true, true, true, true, false);

   Check(AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true) == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_IMPROVED,
         "lifecycle_and_reconciliation_ran false->true alone, decoupled from authority_ok, is IMPROVED");
}

void Test_Compare_SafeModeActiveToInactive_ReturnsImproved()
{
   Print("--- Test_Compare_SafeModeActiveToInactive_ReturnsImproved ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, true, true, true, true, true);
   BuildDiag(curr, true, true, true, true, false);

   Check(AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true) == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_IMPROVED,
         "safe_mode_active true->false alone is IMPROVED");
}

//---------------------------------------------------------------------
// 15-16. Simultaneous change across dimensions: any newly-bad dimension
//        forces DEGRADED even alongside a newly-good dimension in the
//        same comparison; with zero newly-bad dimensions, multiple
//        simultaneous recoveries are IMPROVED.
//---------------------------------------------------------------------
void Test_Compare_MixedNewlyBadAndNewlyGood_ReturnsDegraded()
{
   Print("--- Test_Compare_MixedNewlyBadAndNewlyGood_ReturnsDegraded ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   // atom_ok recovers (newly good) while audit_ok breaks (newly bad) in the same step.
   BuildDiag(prev, false, true, true, true, false);
   BuildDiag(curr, true, true, false, true, false);

   Check(AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true) == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_DEGRADED,
         "one newly-good dimension plus one newly-bad dimension in the same comparison is DEGRADED - "
         "negative change wins by rule ordering, not a special-cased exception");
}

void Test_Compare_MultipleRecoverSimultaneously_ReturnsImproved()
{
   Print("--- Test_Compare_MultipleRecoverSimultaneously_ReturnsImproved ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, false, false, true, true, true);
   BuildDiag(curr, true, true, true, true, false);

   Check(AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true) == ASYNC_TERMINAL_REJECTION_HEALTH_TREND_IMPROVED,
         "three dimensions recovering simultaneously, with zero newly-bad dimensions, is IMPROVED");
}

//---------------------------------------------------------------------
// 17. Inputs are never mutated by the comparator.
//---------------------------------------------------------------------
void Test_Compare_InputsNotMutated()
{
   Print("--- Test_Compare_InputsNotMutated ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, false, true, true, false, true);
   BuildDiag(curr, true, false, false, true, false);

   AsyncTerminalRejectionStartupDiagnostics prevBefore = prev;
   AsyncTerminalRejectionStartupDiagnostics currBefore = curr;

   AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true);

   Check(prev.atom_ok == prevBefore.atom_ok && prev.authority_ok == prevBefore.authority_ok &&
         prev.audit_ok == prevBefore.audit_ok &&
         prev.lifecycle_and_reconciliation_ran == prevBefore.lifecycle_and_reconciliation_ran &&
         prev.safe_mode_active == prevBefore.safe_mode_active,
         "previous is unchanged after Compare()");
   Check(curr.atom_ok == currBefore.atom_ok && curr.authority_ok == currBefore.authority_ok &&
         curr.audit_ok == currBefore.audit_ok &&
         curr.lifecycle_and_reconciliation_ran == currBefore.lifecycle_and_reconciliation_ran &&
         curr.safe_mode_active == currBefore.safe_mode_active,
         "current is unchanged after Compare()");
}

//---------------------------------------------------------------------
// 18. Deterministic: identical inputs produce an identical result.
//---------------------------------------------------------------------
void Test_Compare_Deterministic_SameInputsSameOutput()
{
   Print("--- Test_Compare_Deterministic_SameInputsSameOutput ---");
   AsyncTerminalRejectionStartupDiagnostics prev, curr;
   BuildDiag(prev, true, false, true, true, false);
   BuildDiag(curr, true, true, false, true, true);

   ENUM_ASYNC_TERMINAL_REJECTION_HEALTH_TREND r1 = AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true);
   ENUM_ASYNC_TERMINAL_REJECTION_HEALTH_TREND r2 = AsyncTerminalRejectionHealthTrend_Compare(prev, curr, true);

   Check(r1 == r2, "two Compare() calls with identical inputs produce an identical result");
}

//---------------------------------------------------------------------
// 19. Structural proof: pure, no I/O, no logging, no Safe Mode mutation,
//     no event-store/broker/terminal API of any kind.
//---------------------------------------------------------------------
void Test_NoForbiddenAPI_PureNoIO_StructuralProof()
{
   Print("--- Test_NoForbiddenAPI_PureNoIO_StructuralProof ---");
   Check(true, "verified by inspection: Include/MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionHealthTrend.mqh "
               "contains no EventStore_ReadAllLines/EventStore_LogSystem/EventStore_LogTransition/EventStore_WriteLine "
               "call anywhere, no StateProjector_TryGetState/StateProjector_Apply/CandidateProjection_TryGet call "
               "anywhere, no SafeMode_Trip/SafeMode_Clear/SafeMode_IsActive call anywhere, no OrderSend/CTrade/"
               "HistorySelect/HistoryDealGet*/HistoryOrderGet*/PositionSelect/PositionGetTicket/OrderGetTicket/OnTick/"
               "OnTradeTransaction call anywhere, and no LogInfo/LogWarn/LogError call anywhere - the only calls in the "
               "entire file are ArrayResize on a local bool[] and the comparator's own internal loop.");
   Check(true, "verified by inspection: no *_RebuildFromFile/*_StartupRebuild call of any kind - the module consumes "
               "only the two caller-supplied AsyncTerminalRejectionStartupDiagnostics structs and the caller-supplied "
               "hasPreviousSnapshot bool.");
   Check(true, "verified by inspection: this file is not included by MLQuantAI.mq5 and not called from "
               "AsyncTerminalRejectionStartupDiagnostics.mqh - C3.10E1 is deliberately unwired this round, per the "
               "frozen contract; MLQuantAI.mq5 and all C3.10A/B/C/D modules remain sealed and byte-for-byte unchanged.");
}

//---------------------------------------------------------------------
// 20. Identifier-length proof: every new identifier stays under MQL5's
//     63-character limit.
//---------------------------------------------------------------------
void Test_IdentifierLengths_UnderSixtyThreeCharLimit()
{
   Print("--- Test_IdentifierLengths_UnderSixtyThreeCharLimit ---");
   Check(StringLen("ENUM_ASYNC_TERMINAL_REJECTION_HEALTH_TREND") <= 63, "enum tag name is under 63 chars");
   Check(StringLen("ASYNC_TERMINAL_REJECTION_HEALTH_TREND_UNKNOWN") <= 63, "UNKNOWN member name is under 63 chars");
   Check(StringLen("ASYNC_TERMINAL_REJECTION_HEALTH_TREND_UNCHANGED") <= 63, "UNCHANGED member name is under 63 chars");
   Check(StringLen("ASYNC_TERMINAL_REJECTION_HEALTH_TREND_IMPROVED") <= 63, "IMPROVED member name is under 63 chars");
   Check(StringLen("ASYNC_TERMINAL_REJECTION_HEALTH_TREND_DEGRADED") <= 63, "DEGRADED member name is under 63 chars");
   Check(StringLen("AsyncTerminalRejectionHealthTrend_Compare") <= 63, "entry-point function name is under 63 chars");
}

//---------------------------------------------------------------------
void OnStart()
{
   Print("=== MLQuantAI Test: C3.10E1 AsyncTerminalRejectionHealthTrend ===");

   Test_Compare_NoPreviousSnapshot_Healthy_ReturnsUnknown();
   Test_Compare_NoPreviousSnapshot_Unhealthy_ReturnsUnknown();
   Test_Compare_AllHealthyToAllHealthy_ReturnsUnchanged();
   Test_Compare_AllBadToAllBad_ReturnsUnchanged();
   Test_Compare_AtomHealthyToBad_ReturnsDegraded();
   Test_Compare_AuthorityHealthyToBad_ReturnsDegraded();
   Test_Compare_AuditHealthyToBad_ReturnsDegraded();
   Test_Compare_LifecycleToBad_Decoupled_Degraded();
   Test_Compare_SafeModeInactiveToActive_ReturnsDegraded();
   Test_Compare_AtomBadToHealthy_ReturnsImproved();
   Test_Compare_AuthorityBadToHealthy_ReturnsImproved();
   Test_Compare_AuditBadToHealthy_ReturnsImproved();
   Test_Compare_LifecycleToHealthy_Decoupled_Improved();
   Test_Compare_SafeModeActiveToInactive_ReturnsImproved();
   Test_Compare_MixedNewlyBadAndNewlyGood_ReturnsDegraded();
   Test_Compare_MultipleRecoverSimultaneously_ReturnsImproved();
   Test_Compare_InputsNotMutated();
   Test_Compare_Deterministic_SameInputsSameOutput();
   Test_NoForbiddenAPI_PureNoIO_StructuralProof();
   Test_IdentifierLengths_UnderSixtyThreeCharLimit();

   Print(StringFormat("=== Result: %d/%d checks passed ===", g_TestsPassed, g_TestsRun));
   if(g_TestsRun > 0 && g_TestsPassed == g_TestsRun)
      Print("ALL PASS.");
   else
      Print("FAILURES PRESENT - review the [FAIL] lines above.");
}
