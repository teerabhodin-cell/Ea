//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_TransactionMatchingReadiness.mqh |
//| C3.4 implementation (per                                          |
//| Docs/PhaseC_C3_TransactionReconciliationContract.md, sections     |
//| 25-27, frozen): the thin startup-rebuild wrapper around the        |
//| sealed C3.3 TransactionMatching_RebuildFromFile(). Mirrors          |
//| MLQuantAI_ManualApprovalReadiness.mqh/MLQuantAI_                    |
//| BrokerSubmissionAuditReadiness.mqh's own established shape, with    |
//| two deliberate, explicitly-frozen deviations: the entry point       |
//| returns bool (section 25's own literal signature), and a failed     |
//| rebuild here does NOT trip Safe Mode and does NOT gate anything -   |
//| C3.3 carries no lifecycle authority (section 23/27), unlike the     |
//| C2.3/manual-approval registries this file's shape is otherwise      |
//| copied from.                                                        |
//|                                                                    |
//| Strictly read-only over the event store - no OrderSend/CTrade/      |
//| broker query anywhere in this file, no candidate-lifecycle          |
//| mutation, no event append, no OnTradeTransaction, no retry logic,   |
//| no OnTick/incremental update (section 26 - startup-only, explicitly |
//| stale thereafter). Deliberately NOT a durable EventStore write -    |
//| readiness is a purely in-session, observable-via-SystemLogger fact. |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_TRANSACTIONMATCHINGREADINESS_MQH__
#define __MLQUANTAI_TRANSACTIONMATCHINGREADINESS_MQH__

#include "MLQuantAI_TransactionMatchingProjection.mqh"
#include "../Logging/MLQuantAI_SystemLogger.mqh"

// Section 28's six new counters, plus the underlying sealed C3.3 report
// and an explicit rebuilt_at staleness marker (section 26 - "this must
// be explicit in the readiness/report metadata a future consumer would
// read, never silently assumed current"). Not a change to C3.3's own
// sealed TransactionMatchingReport - this is a wrapper-level struct.
struct TransactionMatchingReadinessReport
{
   TransactionMatchingReport base;

   int orders_total;
   int orders_unmatched;
   int orders_ambiguous;
   int orders_matched_partial;
   int orders_matched_volume_reached;
   int orders_matched_order_terminal; // frozen at 0 under C3.4 - section 28

   datetime rebuilt_at; // TimeCurrent() at the moment THIS rebuild ran -
                          // never updated except by another explicit
                          // TransactionMatching_StartupRebuild() call.
};

void TransactionMatchingReadinessReport_Init(TransactionMatchingReadinessReport &r)
{
   TransactionMatchingReport_Init(r.base);
   r.orders_total                    = 0;
   r.orders_unmatched                 = 0;
   r.orders_ambiguous                  = 0;
   r.orders_matched_partial             = 0;
   r.orders_matched_volume_reached        = 0;
   r.orders_matched_order_terminal          = 0;
   r.rebuilt_at                              = 0;
}

// Fail-closed by default: false until a rebuild THIS session actually
// succeeds. Never manually set true anywhere outside
// TransactionMatching_StartupRebuild().
bool                               g_TransactionMatching_Ready = false;
TransactionMatchingReadinessReport g_TransactionMatching_LastReport;

bool TransactionMatchingReadiness_IsReady() { return g_TransactionMatching_Ready; }

// Test-only: simulates a cold process start.
void TransactionMatchingReadiness_Reset()
{
   g_TransactionMatching_Ready = false;
   TransactionMatchingReadinessReport_Init(g_TransactionMatching_LastReport);
}

// Diagnostics-only accessor (section 27: "the report is retained ONLY
// for diagnostics ... never treated as authoritative state"). Returns
// false if no rebuild has ever run this session.
bool TransactionMatchingReadiness_LastReport(TransactionMatchingReadinessReport &out)
{
   if(g_TransactionMatching_LastReport.rebuilt_at == 0) return false;
   out = g_TransactionMatching_LastReport;
   return true;
}

// Section 28: tallies every OrderAggregateRecord currently in the
// (already-rebuilt) registry by match_status, exactly once per
// order_ticket. Pure read - no mutation of the registry itself.
void TransactionMatchingReadiness_TallyOrderStatus(TransactionMatchingReadinessReport &r)
{
   r.orders_total = OrderAggregateRegistry_Count();
   for(int i = 0; i < r.orders_total; i++)
   {
      OrderAggregateRecord rec;
      if(!OrderAggregateRegistry_GetAt(i, rec)) continue;
      switch(rec.match_status)
      {
         case TX_MATCH_UNMATCHED:      r.orders_unmatched++; break;
         case TX_MATCH_AMBIGUOUS:      r.orders_ambiguous++; break;
         case TX_MATCH_PARTIAL:        r.orders_matched_partial++; break;
         case TX_MATCH_VOLUME_REACHED: r.orders_matched_volume_reached++; break;
         case TX_MATCH_ORDER_TERMINAL: r.orders_matched_order_terminal++; break;
      }
   }
}

// The ONE startup entry point (section 25's own frozen signature).
// Re-entrant and idempotent: readiness is set fresh from THIS call's
// own report.ok every time, never OR'd with a stale prior success, so a
// later failed call correctly REVOKES readiness rather than leaving a
// stale true behind - same discipline every prior readiness wrapper in
// this project already follows.
//
// Frozen ordering (section 25): call this AFTER BrokerSubmissionAudit_
// StartupRebuild()/ManualApproval_StartupRebuild() have already run
// (TransactionMatching_RebuildFromFile stages the former as its own
// black-box gate), and BEFORE EVENT_TYPE_SYSTEM_STARTED is logged.
//
// On failure (section 27): logs deals_applied/deals_failed/first_error,
// does NOT call SafeMode_Trip, and the caller (MLQuantAI.mq5's OnInit)
// must NOT block EA initialization on this function's return value
// alone - C3.3 carries no lifecycle authority yet.
bool TransactionMatching_StartupRebuild(string fileName)
{
   TransactionMatchingReadinessReport r;
   TransactionMatchingReadinessReport_Init(r);

   r.base       = TransactionMatching_RebuildFromFile(fileName);
   r.rebuilt_at = TimeCurrent();

   if(r.base.ok)
      TransactionMatchingReadiness_TallyOrderStatus(r);

   g_TransactionMatching_LastReport = r;
   g_TransactionMatching_Ready      = r.base.ok;

   if(r.base.ok)
   {
      LogInfo(StringFormat("TransactionMatching: startup rebuild OK - %d deal(s) applied, %d order(s) "
              "(unmatched=%d ambiguous=%d partial=%d volume_reached=%d order_terminal=%d), read model ready "
              "(stale after this point until the next restart).",
              r.base.deals_applied, r.orders_total, r.orders_unmatched, r.orders_ambiguous,
              r.orders_matched_partial, r.orders_matched_volume_reached, r.orders_matched_order_terminal));

      // Section 28: exactly ONE startup WARN for ambiguity, never one
      // per ambiguous ticket - a summary count only.
      if(r.orders_ambiguous > 0)
         LogWarn(StringFormat("TransactionMatching: %d order(s) are AMBIGUOUS (conflicting execution_request_id "
                 "resolutions) - diagnostic only, no candidate transition or Safe Mode action taken.",
                 r.orders_ambiguous));
   }
   else
   {
      LogWarn(StringFormat("TransactionMatching: startup rebuild FAILED - deals_applied=%d deals_failed=%d - %s - "
              "read model stays not-ready this session. Not a Safe Mode condition; EA initialization continues.",
              r.base.deals_applied, r.base.deals_failed, r.base.first_error));
   }

   return g_TransactionMatching_Ready;
}

#endif // __MLQUANTAI_TRANSACTIONMATCHINGREADINESS_MQH__
