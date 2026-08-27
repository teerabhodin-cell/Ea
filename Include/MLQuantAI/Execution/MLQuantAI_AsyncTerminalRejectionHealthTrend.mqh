//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_AsyncTerminalRejectionHealthTrend|
//| .mqh                                                               |
//| C3.10E1 implementation (per the Async Terminal Rejection Health    |
//| Trend Checkpoint 1 contract, locked in this branch's chat history   |
//| - no separate Docs/ file yet).                                      |
//|                                                                       |
//| Pure, read-only trend classifier over two already-built                |
//| AsyncTerminalRejectionStartupDiagnostics (C3.10D) snapshots. Does not    |
//| read the event store, does not persist or cache any snapshot, does not    |
//| touch Safe Mode, StateProjector, CandidateProjection, or any broker/       |
//| terminal API, and is not wired into MLQuantAI.mq5 or C3.10D in this         |
//| round - test-only library, deliberately unwired per the frozen contract.     |
//|                                                                                 |
//| hasPreviousSnapshot is the sole signal for "no previous snapshot exists" -      |
//| the previous struct's field values are never interpreted when it is false,      |
//| since a default-constructed AsyncTerminalRejectionStartupDiagnostics (all        |
//| bools false) would otherwise be indistinguishable from a genuine triple-          |
//| failure prior run.                                                                 |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ASYNCTERMINALREJECTIONHEALTHTREND_MQH__
#define __MLQUANTAI_ASYNCTERMINALREJECTIONHEALTHTREND_MQH__

#include "MLQuantAI_AsyncTerminalRejectionStartupDiagnostics.mqh"

enum ENUM_ASYNC_TERMINAL_REJECTION_HEALTH_TREND
{
   ASYNC_TERMINAL_REJECTION_HEALTH_TREND_UNKNOWN = 0,
   ASYNC_TERMINAL_REJECTION_HEALTH_TREND_UNCHANGED,
   ASYNC_TERMINAL_REJECTION_HEALTH_TREND_IMPROVED,
   ASYNC_TERMINAL_REJECTION_HEALTH_TREND_DEGRADED
};

//---------------------------------------------------------------------
// Frozen bad-dimension set (Checkpoint 1), five booleans exactly matching
// AsyncTerminalRejectionStartupDiagnostics' own five boolean fields:
//   bad_atom      = !d.atom_ok
//   bad_authority = !d.authority_ok
//   bad_audit     = !d.audit_ok
//   bad_lifecycle = !d.lifecycle_and_reconciliation_ran
//   bad_safe_mode = d.safe_mode_active
//---------------------------------------------------------------------
void C310E1_BadDimensions(const AsyncTerminalRejectionStartupDiagnostics &d, bool &out[])
{
   ArrayResize(out, 5);
   out[0] = !d.atom_ok;
   out[1] = !d.authority_ok;
   out[2] = !d.audit_ok;
   out[3] = !d.lifecycle_and_reconciliation_ran;
   out[4] = d.safe_mode_active;
}

//---------------------------------------------------------------------
// THE entry point. Pure - no I/O, no logging, never mutates previous/
// current. hasPreviousSnapshot==false short-circuits to UNKNOWN before
// either struct's fields are read. Frozen scoring rule (Checkpoint 1):
// negative change always wins over positive change, by rule ordering,
// not as a special-cased exception.
//---------------------------------------------------------------------
ENUM_ASYNC_TERMINAL_REJECTION_HEALTH_TREND
AsyncTerminalRejectionHealthTrend_Compare(
   const AsyncTerminalRejectionStartupDiagnostics &previous,
   const AsyncTerminalRejectionStartupDiagnostics &current,
   bool hasPreviousSnapshot)
{
   if(!hasPreviousSnapshot)
      return ASYNC_TERMINAL_REJECTION_HEALTH_TREND_UNKNOWN;

   bool prevBad[];
   bool currBad[];
   C310E1_BadDimensions(previous, prevBad);
   C310E1_BadDimensions(current, currBad);

   int newlyBad  = 0;
   int newlyGood = 0;

   for(int i = 0; i < 5; i++)
   {
      if(!prevBad[i] && currBad[i])
         newlyBad++;
      else if(prevBad[i] && !currBad[i])
         newlyGood++;
   }

   if(newlyBad > 0)
      return ASYNC_TERMINAL_REJECTION_HEALTH_TREND_DEGRADED;

   if(newlyGood > 0)
      return ASYNC_TERMINAL_REJECTION_HEALTH_TREND_IMPROVED;

   return ASYNC_TERMINAL_REJECTION_HEALTH_TREND_UNCHANGED;
}

#endif // __MLQUANTAI_ASYNCTERMINALREJECTIONHEALTHTREND_MQH__
