//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_DeferredTransactionProcessor.mqh   |
//| C3.6 implementation (per                                          |
//| Docs/PhaseC_C3_6_DeferredTransactionProcessorContract.md, FROZEN). |
//|                                                                    |
//| A read-only RECOMMENDATION read model. Turns already-sealed        |
//| transaction-matching evidence (C3.3) + replayed candidate state   |
//| (StateProjector via ReplayEngine) into a DeferredRecommendation   |
//| record only. RECOMMEND_EXECUTED is a recommendation row, NOT a    |
//| SUBMITTED -> EXECUTED transition. Lifecycle authority is C3.7.    |
//|                                                                    |
//| Strictly additive and read-only over the already-built in-memory  |
//| read models and readiness snapshots: no lifecycle-write API of any  |
//| kind, no candidate-lifecycle transition, no event append, no new  |
//| ENUM_EVENT_TYPE value, no per-tick / per-trade-transaction callback,|
//| no broker terminal query or submission API, no                |
//| *_RebuildFromFile recovery of individual upstream projections at  |
//| runtime, no sealed file touched. Runs once at OnInit, between      |
//| ReplayEngine_Run and BrokerReconciliation_CheckAll, and is stale   |
//| after OnInit.                                                     |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_DEFERREDTRANSACTIONPROCESSOR_MQH__
#define __MLQUANTAI_DEFERREDTRANSACTIONPROCESSOR_MQH__

#include "MLQuantAI_TransactionMatchingReadiness.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_StateProjector.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventStoreHealth.mqh"
#include "../Logging/MLQuantAI_SystemLogger.mqh"

//---------------------------------------------------------------------
// Recommendation vocabulary (contract section 9, FROZEN). Exactly
// three outcomes. A fourth rejection outcome is deliberately absent - it
// must not exist as an enum member, output row, event, or side effect.
//---------------------------------------------------------------------
enum ENUM_RECOMMENDATION
{
   RECOMMEND_NONE,      // eligible path not reached (partial, unmatched, wrong state)
   RECOMMEND_EXECUTED,  // all 7 eligibility clauses hold; a recommendation row only
   RECOMMEND_BLOCKED    // row-level evidence problem after the upstream scan is ready
};

string RecommendationToString(ENUM_RECOMMENDATION r)
{
   switch(r)
   {
      case RECOMMEND_NONE:     return "RECOMMEND_NONE";
      case RECOMMEND_EXECUTED: return "RECOMMEND_EXECUTED";
      case RECOMMEND_BLOCKED:  return "RECOMMEND_BLOCKED";
   }
   return "UNKNOWN";
}

//---------------------------------------------------------------------
// DeferredRecommendationRecord (contract section 10, FROZEN field set).
//---------------------------------------------------------------------
struct DeferredRecommendationRecord
{
   string               action_id;                              // EXECUTED rows only; empty for NONE/BLOCKED
   string               candidate_id;
   string               execution_request_id;
   ulong                order_ticket;
   ulong                deal_tickets[];                         // sorted ascending, for this order_ticket
   ENUM_TX_MATCH_STATUS terminal_match_status;                  // == TX_MATCH_VOLUME_REACHED for EXECUTED rows
   ENUM_CANDIDATE_STATE candidate_state_evidence;               // == CANDIDATE_SUBMITTED for EXECUTED rows
   double               running_filled_volume;                  // consistency evidence (clause 6)
   int                  deal_count;                             // consistency evidence (clause 6)
   double               intended_lot_size;                       // from ExecutionRequestProjection
   ENUM_RECOMMENDATION  recommended_action;                    // NONE | EXECUTED | BLOCKED
   string               reason_code;                            // stable reason for NONE/BLOCKED

   // provenance - execution-request source:
   long                 execution_request_source_sequence_number;
   string               execution_request_source_log_event_id;
   // provenance - per-deal source, aligned 1:1 with sorted deal_tickets[]:
   long                 deal_source_sequence_numbers[];
   string               deal_source_log_event_ids[];
   // candidate lineage (provenance promise, from CandidateProjection):
   string               candidate_root_event_id;
   string               context_event_id;

   // session-scope diagnostic (stale-after-OnInit marker, NOT an action_id input):
   datetime             evaluated_at;
   bool                 stale_after_startup;
};

void DeferredRecommendationRecord_Init(DeferredRecommendationRecord &r)
{
   r.action_id                              = "";
   r.candidate_id                           = "";
   r.execution_request_id                   = "";
   r.order_ticket                           = 0;
   ArrayResize(r.deal_tickets, 0);
   r.terminal_match_status                  = TX_MATCH_UNMATCHED;
   r.candidate_state_evidence               = CANDIDATE_CREATED;
   r.running_filled_volume                  = 0.0;
   r.deal_count                             = 0;
   r.intended_lot_size                      = 0.0;
   r.recommended_action                     = RECOMMEND_NONE;
   r.reason_code                            = "";
   r.execution_request_source_sequence_number = 0;
   r.execution_request_source_log_event_id   = "";
   ArrayResize(r.deal_source_sequence_numbers, 0);
   ArrayResize(r.deal_source_log_event_ids, 0);
   r.candidate_root_event_id                = "";
   r.context_event_id                       = "";
   r.evaluated_at                           = 0;
   r.stale_after_startup                    = true;
}

DeferredRecommendationRecord g_C36_Records[];
int                          g_C36_Count = 0;

void DeferredTransactionProcessor_Reset()
{
   ArrayResize(g_C36_Records, 0);
   g_C36_Count = 0;
}

int DeferredTransactionProcessor_Count() { return g_C36_Count; }

bool DeferredTransactionProcessor_GetAt(int index, DeferredRecommendationRecord &out)
{
   if(index < 0 || index >= g_C36_Count) return false;
   out = g_C36_Records[index];
   return true;
}

bool DeferredTransactionProcessor_TryGet(string candidateId, DeferredRecommendationRecord &out)
{
   for(int i = 0; i < g_C36_Count; i++)
      if(g_C36_Records[i].candidate_id == candidateId)
      {
         out = g_C36_Records[i];
         return true;
      }
   return false;
}

//---------------------------------------------------------------------
// Report (contract section 10 wrapper + section 5/8 scan-level vs
// row-level separation). scan_failed/scan_failure_reason carry
// scan-level failures (zero rows); blocked_count + per-row reason_code
// carry row-level evidence problems. A completed scan with BLOCKED rows
// does NOT trip Safe Mode and does NOT block EA init.
//---------------------------------------------------------------------
struct DeferredTransactionProcessorReport
{
   bool   ok;                     // true unless a scan-level failure occurred
   int    recommendations_total;
   int    executed_count;
   int    none_count;
   int    blocked_count;
   int    duplicate_collapses;   // within-scan duplicate collapses (clause 7 / section 12)
   bool   scan_failed;
   string scan_failure_reason;   // upstream_replay_not_ready | upstream_readiness_not_ready
   string first_error;
   bool   stale_after_startup;
   string source_store_file;     // provenance only (contract section 3)
};

void DeferredTransactionProcessorReport_Init(DeferredTransactionProcessorReport &r)
{
   r.ok                    = true;
   r.recommendations_total = 0;
   r.executed_count        = 0;
   r.none_count            = 0;
   r.blocked_count         = 0;
   r.duplicate_collapses  = 0;
   r.scan_failed           = false;
   r.scan_failure_reason  = "";
   r.first_error           = "";
   r.stale_after_startup   = true;
   r.source_store_file     = "";
}

//---------------------------------------------------------------------
// Internal: candidate_id -> execution_request_id reverse index
// (contract section 6, FROZEN). Built from ExecutionRequestProjection
// ONLY. Lives entirely inside this file - no sealed-projection edit
// (per C3.5 section 11). 0 mappings -> BLOCKED; 1 -> usable;
// >1 -> BLOCKED. No symbol/time/order/correlation fallback.
//---------------------------------------------------------------------
struct C36_RevIdxPair
{
   string candidate_id;
   string execution_request_id;
};

C36_RevIdxPair g_C36_RevIdx[];
int            g_C36_RevIdx_Count = 0;

void C36_RevIdx_Reset()
{
   ArrayResize(g_C36_RevIdx, 0);
   g_C36_RevIdx_Count = 0;
}

void C36_RevIdx_Build()
{
   C36_RevIdx_Reset();
   int n = ExecutionRequestProjection_Count();
   for(int i = 0; i < n; i++)
   {
      ExecutionRequestProjectionRecord rec;
      if(!ExecutionRequestProjection_GetAt(i, rec)) continue;
      if(rec.candidate_id == "") continue;              // no candidate to index
      if(rec.execution_request_id == "") continue;        // not a usable mapping
      int idx = g_C36_RevIdx_Count;
      ArrayResize(g_C36_RevIdx, idx + 1);
      g_C36_RevIdx[idx].candidate_id          = rec.candidate_id;
      g_C36_RevIdx[idx].execution_request_id  = rec.execution_request_id;
      g_C36_RevIdx_Count++;
   }
}

// Returns the single execution_request_id for a candidate if exactly one
// mapping exists; sets outCount to the number of mappings found.
string C36_RevIdx_Resolve(string candidateId, int &outCount)
{
   outCount = 0;
   string single = "";
   for(int i = 0; i < g_C36_RevIdx_Count; i++)
   {
      if(g_C36_RevIdx[i].candidate_id == candidateId)
      {
         outCount++;
         if(outCount == 1) single = g_C36_RevIdx[i].execution_request_id;
      }
   }
   return single;
}

//---------------------------------------------------------------------
// Internal: precompute the set of execution_request_ids implicated in
// AMBIGUOUS orders (advisor correction #5). C3.3 clears
// matched_execution_request_id for AMBIGUOUS orders, so a candidate-
// centric lookup by matched_execution_request_id alone would miss them.
// For each AMBIGUOUS order, inspect its deals and call
// TransactionMatching_ResolveExecutionRequestId(deal); any non-empty
// result means that exec request is implicated in an ambiguous order ->
// the matching candidate must be RECOMMEND_BLOCKED.
//---------------------------------------------------------------------
string g_C36_AmbiguousImplicated[];
int    g_C36_AmbiguousImplicated_Count = 0;

void C36_AmbiguousImplicated_Reset()
{
   ArrayResize(g_C36_AmbiguousImplicated, 0);
   g_C36_AmbiguousImplicated_Count = 0;
}

bool C36_AmbiguousImplicated_Contains(string execReqId)
{
   for(int i = 0; i < g_C36_AmbiguousImplicated_Count; i++)
      if(g_C36_AmbiguousImplicated[i] == execReqId) return true;
   return false;
}

void C36_AmbiguousImplicated_Add(string execReqId)
{
   if(execReqId == "") return;
   if(C36_AmbiguousImplicated_Contains(execReqId)) return; // dedup
   int idx = g_C36_AmbiguousImplicated_Count;
   ArrayResize(g_C36_AmbiguousImplicated, idx + 1);
   g_C36_AmbiguousImplicated[idx] = execReqId;
   g_C36_AmbiguousImplicated_Count++;
}

void C36_AmbiguousImplicated_Build()
{
   C36_AmbiguousImplicated_Reset();
   int orderCount = OrderAggregateRegistry_Count();
   for(int oi = 0; oi < orderCount; oi++)
   {
      OrderAggregateRecord agg;
      if(!OrderAggregateRegistry_GetAt(oi, agg)) continue;
      if(agg.match_status != TX_MATCH_AMBIGUOUS) continue;

      // Inspect every deal under this ambiguous order_ticket.
      int dealCount = TransactionDealRegistry_Count();
      for(int di = 0; di < dealCount; di++)
      {
         TransactionDealRecord deal;
         if(!TransactionDealRegistry_GetAt(di, deal)) continue;
         if(deal.order_ticket != agg.order_ticket) continue;
         string resolved = TransactionMatching_ResolveExecutionRequestId(deal);
         C36_AmbiguousImplicated_Add(resolved);
      }
   }
}

//---------------------------------------------------------------------
// Internal: collect all deals for one order_ticket, sorted ascending by
// deal_ticket, with their provenance fields aligned 1:1. Used to build
// action_id's sorted deal-ticket set and the per-deal provenance arrays.
//---------------------------------------------------------------------
struct C36_OrderDealTuple
{
   ulong  deal_ticket;
   long   source_sequence_number;
   string source_log_event_id;
   double volume;
};

void C36_CollectOrderDeals(ulong orderTicket, C36_OrderDealTuple &outTuples[])
{
   ArrayResize(outTuples, 0);
   int dealCount = TransactionDealRegistry_Count();
   int collected = 0;
   for(int i = 0; i < dealCount; i++)
   {
      TransactionDealRecord deal;
      if(!TransactionDealRegistry_GetAt(i, deal)) continue;
      if(deal.order_ticket != orderTicket) continue;
      ArrayResize(outTuples, collected + 1);
      outTuples[collected].deal_ticket            = deal.deal_ticket;
      outTuples[collected].source_sequence_number = deal.source_sequence_number;
      outTuples[collected].source_log_event_id    = deal.source_log_event_id;
      outTuples[collected].volume                 = deal.volume;
      collected++;
   }
   // Insertion sort by deal_ticket ascending (N is tiny per order).
   int n = ArraySize(outTuples);
   for(int i = 1; i < n; i++)
   {
      C36_OrderDealTuple key = outTuples[i];
      int j = i - 1;
      while(j >= 0 && outTuples[j].deal_ticket > key.deal_ticket)
      {
         outTuples[j + 1] = outTuples[j];
         j--;
      }
      outTuples[j + 1] = key;
   }
}

// Recompute the filled-volume sum in the SAME registry order C3.3 used
// (contract section 7 clause 6, advisor correction #3: NO new epsilon).
// C3.3 accumulates deal.volume per order in registry index order, so a
// recompute iterating the deal registry in the same order is bitwise-
// identical -> an exact == comparison is safe and introduces no epsilon.
double C36_RecomputeFilledVolume(ulong orderTicket)
{
   double sum = 0.0;
   int dealCount = TransactionDealRegistry_Count();
   for(int i = 0; i < dealCount; i++)
   {
      TransactionDealRecord deal;
      if(!TransactionDealRegistry_GetAt(i, deal)) continue;
      if(deal.order_ticket != orderTicket) continue;
      sum += deal.volume;
   }
   return sum;
}

int C36_RecomputeDealCount(ulong orderTicket)
{
   int c = 0;
   int dealCount = TransactionDealRegistry_Count();
   for(int i = 0; i < dealCount; i++)
   {
      TransactionDealRecord deal;
      if(!TransactionDealRegistry_GetAt(i, deal)) continue;
      if(deal.order_ticket != orderTicket) continue;
      c++;
   }
   return c;
}

//---------------------------------------------------------------------
// Deterministic action_id (contract section 11, FROZEN). Derived from
// immutable evidence identity only - never a wall-clock, session ID,
// registry counter, file line number, rebuild order, log text, or
// rebuilt_at. The v1 suffix is a contract-version prefix.
//---------------------------------------------------------------------
string C36_BuildActionId(string candidateId, string execReqId, ulong orderTicket,
                          const C36_OrderDealTuple &sortedDeals[])
{
   string dealPart = "";
   int n = ArraySize(sortedDeals);
   for(int i = 0; i < n; i++)
   {
      if(i > 0) dealPart += ",";
      dealPart += IntegerToString((long)sortedDeals[i].deal_ticket);
   }
   return "C36|EXECUTED|" + candidateId + "|" + execReqId + "|"
          + IntegerToString((long)orderTicket) + "|MATCHED_VOLUME_REACHED|["
          + dealPart + "]|v1";
}

//---------------------------------------------------------------------
// Append a recommendation row to the registry.
//---------------------------------------------------------------------
void C36_AppendRow(const DeferredRecommendationRecord &r)
{
   int idx = g_C36_Count;
   ArrayResize(g_C36_Records, idx + 1);
   g_C36_Records[idx] = r;
   g_C36_Count++;
}

//---------------------------------------------------------------------
// Semantic output ordering (contract section 13, FROZEN). The registry's
// Count()/GetAt() iteration order must be the frozen semantic sort:
// candidate_id ASC -> execution_request_id ASC -> order_ticket ASC ->
// sorted deal-ticket set / action_id ASC. Re-sorts the in-place
// registry after the scan so no caller may rely on file/insertion order.
//---------------------------------------------------------------------
int C36_CompareRows(const DeferredRecommendationRecord &a, const DeferredRecommendationRecord &b)
{
   int c = StringCompare(a.candidate_id, b.candidate_id);
   if(c != 0) return c;
   c = StringCompare(a.execution_request_id, b.execution_request_id);
   if(c != 0) return c;
   if(a.order_ticket < b.order_ticket) return -1;
   if(a.order_ticket > b.order_ticket) return 1;
   return StringCompare(a.action_id, b.action_id);
}

void C36_SortRegistry()
{
   // Insertion sort (N is bounded by candidate count at startup).
   for(int i = 1; i < g_C36_Count; i++)
   {
      DeferredRecommendationRecord key = g_C36_Records[i];
      int j = i - 1;
      while(j >= 0 && C36_CompareRows(g_C36_Records[j], key) > 0)
      {
         g_C36_Records[j + 1] = g_C36_Records[j];
         j--;
      }
      g_C36_Records[j + 1] = key;
   }
}

//---------------------------------------------------------------------
// Within-scan idempotency (contract section 12, FROZEN). A duplicate
// with the SAME action_id + identical payload collapses to ONE row
// (incrementing duplicate_collapses); a collision (same action_id +
// DIFFERENT payload) fails closed to RECOMMEND_BLOCKED.
//---------------------------------------------------------------------
bool C36_ActionIdAlreadyEmitted(string actionId)
{
   for(int i = 0; i < g_C36_Count; i++)
      if(g_C36_Records[i].action_id != "" && g_C36_Records[i].action_id == actionId)
         return true;
   return false;
}

//---------------------------------------------------------------------
// THE entry point (contract section 3, FROZEN OnInit placement).
// Slots between ReplayEngine_Run and BrokerReconciliation_CheckAll.
// Reads from the already-built in-memory read models and readiness
// snapshots only; the fileName argument is provenance/diagnostic only
// and is never opened or reparsed here.
//---------------------------------------------------------------------
DeferredTransactionProcessorReport DeferredTransactionProcessor_StartupScan(string fileName)
{
   DeferredTransactionProcessorReport report;
   DeferredTransactionProcessorReport_Init(report);
   report.source_store_file = fileName;
   report.stale_after_startup = true;

   // Registry resets before every scan (contract section 12: across
   // cold scans the same semantic output is reconstructed once, not a
   // durable already-applied action).
   DeferredTransactionProcessor_Reset();
   C36_RevIdx_Reset();
   C36_AmbiguousImplicated_Reset();

   // --- Scan-level gate A: replay / SafeMode (contract section 5) ---
   // C3.6 cannot receive ReplayReport (OnInit placement takes fileName
   // only). EventStoreHealth_IsSafeMode() is the production-visible
   // proxy: OnInit trips SafeMode when !ReplayReport.ok, and a pre-
   // existing corrupted store also engages it. In every such case the
   // candidate-state universe is untrustworthy -> zero rows.
   if(EventStoreHealth_IsSafeMode())
   {
      report.ok = false;
      report.scan_failed = true;
      report.scan_failure_reason = "upstream_replay_not_ready";
      report.first_error = "upstream_replay_not_ready: SafeMode engaged at scan time - candidate states untrustworthy, zero recommendations emitted";
      LogWarn("DeferredTransactionProcessor: upstream_replay_not_ready - SafeMode engaged, emitting zero recommendations (scan-level, not a row-level BLOCKED).");
      return report;
   }

   // --- Scan-level gate B: upstream readiness (contract section 7) ---
   // C3.6's DIRECT gate is TransactionMatchingReadiness, which
   // transitively proves the staged upstream rebuild chain
   // (BrokerSubmissionAuditProjection -> ExecutionAuditProjection) already
   // succeeded with zero failed lines. C3.6 must NOT call
   // *_RebuildFromFile() to recover individual upstream reports.
   TransactionMatchingReadinessReport rd;
   bool haveReport = TransactionMatchingReadiness_LastReport(rd);

   if(!TransactionMatchingReadiness_IsReady()
      || !haveReport
      || !rd.base.ok
      || rd.base.deals_failed != 0)
   {
      report.ok = false;
      report.scan_failed = true;
      report.scan_failure_reason = "upstream_readiness_not_ready";
      report.first_error = "upstream_readiness_not_ready: TransactionMatching readiness is false or carries failed deals - zero recommendations emitted";
      LogWarn("DeferredTransactionProcessor: upstream_readiness_not_ready - matching read model not ready, emitting zero recommendations (scan-level, not a row-level BLOCKED).");
      return report;
   }

   // --- Build the reverse index + ambiguous-implicated set (sections 6) ---
   C36_RevIdx_Build();
   C36_AmbiguousImplicated_Build();

   // --- Iterate every candidate in CandidateProjection (section 13) ---
   // Output is re-sorted to the frozen semantic order at the end, so the
   // CandidateProjection iteration order does not leak into output.
   int candCount = CandidateProjection_Count();
   for(int ci = 0; ci < candCount; ci++)
   {
      CandidateProjectionRecord cand;
      if(!CandidateProjection_GetAt(ci, cand)) continue;

      DeferredRecommendationRecord row;
      DeferredRecommendationRecord_Init(row);
      row.candidate_id            = cand.candidate_id;
      row.candidate_root_event_id = cand.root_event_id;
      row.context_event_id        = cand.context_event_id;
      row.evaluated_at            = TimeCurrent();
      row.stale_after_startup     = true;

      // Clause 1: candidate.state == CANDIDATE_SUBMITTED (sole source:
      // StateProjector, populated by ReplayEngine_Run - NOT
      // CandidateProjection, which only holds CREATED).
      ENUM_CANDIDATE_STATE state;
      if(!StateProjector_TryGetState(cand.candidate_id, state))
      {
         // Candidate is in CandidateProjection but missing from the
         // replayed state projector - cannot confirm SUBMITTED -> fail
         // soft to NONE (cannot prove EXECUTED). Not a row-level BLOCKED.
         row.recommended_action = RECOMMEND_NONE;
         row.reason_code        = "candidate_state_missing";
         C36_AppendRow(row);
         continue;
      }
      row.candidate_state_evidence = state;

      if(state != CANDIDATE_SUBMITTED)
      {
         // advisor correction #1: non-SUBMITTED candidates emit an
         // explicit RECOMMEND_NONE row (reason candidate_not_submitted),
         // no action_id, no lifecycle effect. Reverse-index checks apply
         // ONLY after confirming SUBMITTED, so a CREATED candidate with
         // no exec request does not become BLOCKED.
         row.recommended_action = RECOMMEND_NONE;
         row.reason_code        = "candidate_not_submitted";
         C36_AppendRow(row);
         continue;
      }

      // --- candidate is SUBMITTED: evaluate the 7 clauses ---

      // Clause 4 (reverse index, section 6): resolve the candidate's
      // execution_request_id. 0 mappings -> BLOCKED; 1 -> usable;
      // >1 -> BLOCKED (collision). No symbol/time/order/correlation
      // fallback.
      int execReqMappingCount = 0;
      string execReqId = C36_RevIdx_Resolve(cand.candidate_id, execReqMappingCount);

      if(execReqMappingCount == 0)
      {
         row.recommended_action = RECOMMEND_BLOCKED;
         row.reason_code        = "no_execution_request_mapping";
         C36_AppendRow(row);
         continue;
      }
      if(execReqMappingCount > 1)
      {
         row.recommended_action = RECOMMEND_BLOCKED;
         row.reason_code        = "multiple_execution_request_mappings";
         C36_AppendRow(row);
         continue;
      }

      row.execution_request_id = execReqId;

      // ExecutionRequestProjectionRecord provenance + intended lot_size.
      ExecutionRequestProjectionRecord execReq;
      if(!ExecutionRequestProjection_TryGet(execReqId, execReq))
      {
         row.recommended_action = RECOMMEND_BLOCKED;
         row.reason_code        = "execution_request_missing";
         C36_AppendRow(row);
         continue;
      }
      row.intended_lot_size                              = execReq.lot_size;
      row.execution_request_source_sequence_number       = execReq.source_sequence_number;
      row.execution_request_source_log_event_id          = execReq.source_log_event_id;

      // Ambiguous-implication check (advisor correction #5): if this
      // candidate's exec request is implicated in any AMBIGUOUS order,
      // the mapping is conflicting -> RECOMMEND_BLOCKED.
      if(C36_AmbiguousImplicated_Contains(execReqId))
      {
         row.recommended_action = RECOMMEND_BLOCKED;
         row.reason_code        = "ambiguous_match_implicated";
         C36_AppendRow(row);
         continue;
      }

      // Clause 2 (advisor correction #4): count OrderAggregateRecords
      // whose matched_execution_request_id == execReqId. 0 -> NONE
      // (no fill yet); 1 -> evaluate; >1 -> BLOCKED (conflicting mapping).
      int matchingOrderCount = 0;
      int matchingOrderIdx = -1;
      int orderCount = OrderAggregateRegistry_Count();
      for(int oi = 0; oi < orderCount; oi++)
      {
         OrderAggregateRecord agg;
         if(!OrderAggregateRegistry_GetAt(oi, agg)) continue;
         if(agg.matched_execution_request_id == execReqId)
         {
            matchingOrderCount++;
            matchingOrderIdx = oi;
         }
      }

      if(matchingOrderCount == 0)
      {
         row.recommended_action = RECOMMEND_NONE;
         row.reason_code        = "no_matched_order";
         C36_AppendRow(row);
         continue;
      }
      if(matchingOrderCount > 1)
      {
         row.recommended_action = RECOMMEND_BLOCKED;
         row.reason_code        = "multiple_orders_matched";
         C36_AppendRow(row);
         continue;
      }

      // Exactly one matching order. Evaluate its match_status.
      OrderAggregateRecord agg;
      if(!OrderAggregateRegistry_GetAt(matchingOrderIdx, agg)) continue;
      row.order_ticket              = agg.order_ticket;
      row.terminal_match_status     = agg.match_status;
      row.running_filled_volume      = agg.running_filled_volume;
      row.deal_count                 = agg.deal_count;

      if(agg.match_status == TX_MATCH_AMBIGUOUS)
      {
         // Defensive: AMBIGUOUS orders have cleared matched_execution_
         // request_id, so they would not have matched the count above;
         // this branch is unreachable in practice but kept fail-closed.
         row.recommended_action = RECOMMEND_BLOCKED;
         row.reason_code        = "ambiguous_match";
         C36_AppendRow(row);
         continue;
      }
      if(agg.match_status == TX_MATCH_UNMATCHED)
      {
         row.recommended_action = RECOMMEND_NONE;
         row.reason_code        = "unmatched";
         C36_AppendRow(row);
         continue;
      }
      if(agg.match_status == TX_MATCH_PARTIAL)
      {
         row.recommended_action = RECOMMEND_NONE;
         row.reason_code        = "partial_fill";
         C36_AppendRow(row);
         continue;
      }
      if(agg.match_status == TX_MATCH_ORDER_TERMINAL)
      {
         row.recommended_action = RECOMMEND_NONE;
         row.reason_code        = "reserved_never_acted";
         C36_AppendRow(row);
         continue;
      }

      // match_status == TX_MATCH_VOLUME_REACHED -> run clauses 4,5,6.
      // Clause 4 (identity round-trip): matched_execution_request_id ==
      // candidate's exec_req_id (true by the lookup that selected this
      // order; re-verified, not inferred).
      if(agg.matched_execution_request_id != execReqId)
      {
         row.recommended_action = RECOMMEND_BLOCKED;
         row.reason_code        = "identity_round_trip_failed";
         C36_AppendRow(row);
         continue;
      }

      // Clause 6 (volume evidence internally consistent, NO new epsilon -
      // advisor correction #3). Recompute the filled-volume sum and deal
      // count in the SAME registry order C3.3 used; compare with exact
      // == (bitwise-identical by construction).
      double recomputedVolume = C36_RecomputeFilledVolume(agg.order_ticket);
      int    recomputedDeals  = C36_RecomputeDealCount(agg.order_ticket);

      if(recomputedDeals != agg.deal_count
         || recomputedVolume != agg.running_filled_volume)
      {
         row.recommended_action = RECOMMEND_BLOCKED;
         row.reason_code        = "inconsistent_volume_evidence";
         C36_AppendRow(row);
         continue;
      }

      // Re-confirm running_filled_volume >= intended lot_size (already
      // implied by MATCHED_VOLUME_REACHED; re-checked as evidence).
      if(agg.running_filled_volume < execReq.lot_size)
      {
         row.recommended_action = RECOMMEND_BLOCKED;
         row.reason_code        = "volume_below_lot_size";
         C36_AppendRow(row);
         continue;
      }

      // All 7 clauses hold -> RECOMMEND_EXECUTED. Build the deterministic
      // action_id and the sorted per-deal provenance arrays.
      C36_OrderDealTuple sortedDeals[];
      C36_CollectOrderDeals(agg.order_ticket, sortedDeals);

      string actionId = C36_BuildActionId(cand.candidate_id, execReqId,
                                          agg.order_ticket, sortedDeals);

      // Within-scan idempotency (contract section 12): same action_id +
      // identical payload collapses to one row (the payload is fixed by
      // the immutable evidence, so a second occurrence is a duplicate);
      // a collision (same action_id + different payload) is structurally
      // impossible here because action_id is a pure function of the same
      // evidence, but fail closed regardless.
      if(C36_ActionIdAlreadyEmitted(actionId))
      {
         report.duplicate_collapses++;
         continue; // collapse to the already-emitted row
      }

      row.action_id           = actionId;
      row.recommended_action  = RECOMMEND_EXECUTED;
      row.reason_code         = "all_eligibility_clauses_hold";

      // Populate the sorted deal_tickets[] + aligned provenance arrays.
      int dn = ArraySize(sortedDeals);
      ArrayResize(row.deal_tickets, dn);
      ArrayResize(row.deal_source_sequence_numbers, dn);
      ArrayResize(row.deal_source_log_event_ids, dn);
      for(int di = 0; di < dn; di++)
      {
         row.deal_tickets[di]                  = sortedDeals[di].deal_ticket;
         row.deal_source_sequence_numbers[di]  = sortedDeals[di].source_sequence_number;
         row.deal_source_log_event_ids[di]     = sortedDeals[di].source_log_event_id;
      }

      C36_AppendRow(row);
   }

   // --- Semantic output ordering (contract section 13, FROZEN) ---
   C36_SortRegistry();

   // --- Populate report counts ---
   report.recommendations_total = g_C36_Count;
   for(int i = 0; i < g_C36_Count; i++)
   {
      switch(g_C36_Records[i].recommended_action)
      {
         case RECOMMEND_NONE:     report.none_count++;     break;
         case RECOMMEND_EXECUTED: report.executed_count++; break;
         case RECOMMEND_BLOCKED:  report.blocked_count++;  break;
      }
   }

   LogInfo(StringFormat("DeferredTransactionProcessor: startup scan complete - %d recommendation(s) "
           "(executed=%d none=%d blocked=%d duplicate_collapses=%d), stale after OnInit until next restart.",
           report.recommendations_total, report.executed_count, report.none_count,
           report.blocked_count, report.duplicate_collapses));

   return report;
}

#endif // __MLQUANTAI_DEFERREDTRANSACTIONPROCESSOR_MQH__
