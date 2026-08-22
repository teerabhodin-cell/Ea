//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_TransactionMatchingProjection.mqh|
//| C3.3 implementation (per                                          |
//| Docs/PhaseC_C3_TransactionReconciliationContract.md, sections     |
//| 20-24, frozen): a durable, read-only PROJECTION over the already- |
//| sealed EVENT_TYPE_BROKER_TRANSACTION_OBSERVED lines (C3.2). Pure   |
//| deferred matching/aggregation - NOT reconciliation, NOT fill       |
//| handling, NOT execution authorization.                             |
//|                                                                    |
//| Strictly additive and read-only: no History*/Position*/Order*      |
//| call anywhere, no OnTradeTransaction change, no OrderSend/CTrade,  |
//| no candidate-lifecycle transition (no EventStore_LogTransition     |
//| call), no event append (no EventStore_LogSystem/Append* call), no  |
//| ORDER_FILLED/TRANSACTION_REJECTION_CONFIRMED emission, no          |
//| BrokerReconciliation.mqh touched. No sealed file touched           |
//| (MLQuantAI_BrokerSubmissionAuditProjection.mqh,                    |
//| MLQuantAI_ExecutionAuditProjection.mqh, and every other C1-C2      |
//| sealed file) - both are staged, unmodified, as a black-box gate     |
//| first, same precedent every layer since C1.3 has followed.         |
//|                                                                    |
//| Active scope, this round (section 22): ingests only                |
//| BROKER_TRANSACTION_OBSERVED lines whose own transaction_type       |
//| field equals "TRADE_TRANSACTION_DEAL_ADD" - the only type that     |
//| represents a new fill fact. Every other observed transaction type  |
//| stays raw fact in the store (C3.2's own job), unread here.         |
//|                                                                    |
//| Matching authority, strict this round (section 20): positive       |
//| ticket evidence only - deal_ticket against a durable, SUBMITTED    |
//| SubmissionOutcome first, then order_ticket. No correlation_id/     |
//| magic/symbol fallback - the sealed C3.2 envelope carries neither   |
//| a magic number nor a broker comment to support one.                |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_TRANSACTIONMATCHINGPROJECTION_MQH__
#define __MLQUANTAI_TRANSACTIONMATCHINGPROJECTION_MQH__

#include "MLQuantAI_BrokerSubmissionAuditProjection.mqh"

//---------------------------------------------------------------------
// TransactionDealRecord - one durable record per unique deal_ticket
// observed via a TRADE_TRANSACTION_DEAL_ADD-typed BROKER_TRANSACTION_
// OBSERVED line (section 21). Idempotent by deal_ticket itself - a
// deliberate departure from the log_event_id-keyed dedup every other
// projection in this project uses, required because OnTradeTransaction
// has no documented 1:1 request-to-event guarantee (section 5/22): the
// SAME real fill could be observed via more than one distinct
// BROKER_TRANSACTION_OBSERVED line, each with its own unique
// log_event_id, and must still collapse to one record here.
//---------------------------------------------------------------------
struct TransactionDealRecord
{
   ulong  deal_ticket;
   ulong  order_ticket;
   string symbol;
   string order_type;
   string deal_type;
   string order_state;
   double price;
   double volume;
   double price_sl;
   double price_tp;

   long   source_sequence_number;
   string source_log_event_id;
};

void TransactionDealRecord_Init(TransactionDealRecord &r)
{
   r.deal_ticket  = 0;
   r.order_ticket = 0;
   r.symbol       = "";
   r.order_type   = "";
   r.deal_type    = "";
   r.order_state  = "";
   r.price        = 0.0;
   r.volume       = 0.0;
   r.price_sl     = 0.0;
   r.price_tp     = 0.0;
   r.source_sequence_number = 0;
   r.source_log_event_id    = "";
}

// The "canonical payload" compared for replay-vs-collision (section 22)
// - every content field except deal_ticket itself (already the lookup
// key when this is called) and except the base envelope's own
// sequence_number/log_event_id/ts, which naturally differ per write and
// carry no deal-identity meaning.
bool TransactionDealRecord_SamePayload(const TransactionDealRecord &a, const TransactionDealRecord &b)
{
   return a.order_ticket == b.order_ticket &&
          a.symbol       == b.symbol &&
          a.order_type   == b.order_type &&
          a.deal_type    == b.deal_type &&
          a.order_state  == b.order_state &&
          a.price        == b.price &&
          a.volume       == b.volume &&
          a.price_sl     == b.price_sl &&
          a.price_tp     == b.price_tp;
}

TransactionDealRecord g_TxDeal_Records[];
int                   g_TxDeal_Count = 0;

void TransactionDealRegistry_Reset()
{
   ArrayResize(g_TxDeal_Records, 0);
   g_TxDeal_Count = 0;
}

int TransactionDealRegistry_Count() { return g_TxDeal_Count; }

bool TransactionDealRegistry_GetAt(int index, TransactionDealRecord &out)
{
   if(index < 0 || index >= g_TxDeal_Count) return false;
   out = g_TxDeal_Records[index];
   return true;
}

int TransactionDealRegistry_FindIndex(ulong dealTicket)
{
   for(int i = 0; i < g_TxDeal_Count; i++)
      if(g_TxDeal_Records[i].deal_ticket == dealTicket)
         return i;
   return -1;
}

void TransactionDealRegistry_AppendRecord(const TransactionDealRecord &rec)
{
   int idx = g_TxDeal_Count;
   ArrayResize(g_TxDeal_Records, idx + 1);
   g_TxDeal_Records[idx] = rec;
   g_TxDeal_Count++;
}

//---------------------------------------------------------------------
// OrderAggregateRecord - one derived record per unique order_ticket
// seen across the deal registry above (section 21). Pure read-model
// state, never durably written, never an event, never consulted by any
// gate - same role BrokerSubmissionReconciliationRow (C2.3) already
// plays.
//---------------------------------------------------------------------
enum ENUM_TX_MATCH_STATUS
{
   TX_MATCH_UNMATCHED,
   TX_MATCH_AMBIGUOUS,
   TX_MATCH_PARTIAL,
   TX_MATCH_VOLUME_REACHED,
   TX_MATCH_ORDER_TERMINAL // reserved - never assigned by C3.3 (section 21):
                             // the ORDER_STATE terminal criterion is not
                             // frozen yet, and C3.3 does not read
                             // ORDER_UPDATE/ORDER_DELETE lines at all.
};

string TxMatchStatusToString(ENUM_TX_MATCH_STATUS s)
{
   switch(s)
   {
      case TX_MATCH_UNMATCHED:        return "UNMATCHED";
      case TX_MATCH_AMBIGUOUS:        return "AMBIGUOUS";
      case TX_MATCH_PARTIAL:          return "MATCHED_PARTIAL";
      case TX_MATCH_VOLUME_REACHED:   return "MATCHED_VOLUME_REACHED";
      case TX_MATCH_ORDER_TERMINAL:   return "MATCHED_ORDER_TERMINAL";
   }
   return "UNKNOWN";
}

struct OrderAggregateRecord
{
   ulong  order_ticket;
   double running_filled_volume;
   int    deal_count;
   string matched_execution_request_id; // "" unless UNMATCHED/AMBIGUOUS give way to a single match
   ENUM_TX_MATCH_STATUS match_status;
};

void OrderAggregateRecord_Init(OrderAggregateRecord &r)
{
   r.order_ticket                = 0;
   r.running_filled_volume        = 0.0;
   r.deal_count                   = 0;
   r.matched_execution_request_id = "";
   r.match_status                  = TX_MATCH_UNMATCHED;
}

OrderAggregateRecord g_TxOrder_Records[];
int                  g_TxOrder_Count = 0;

void OrderAggregateRegistry_Reset()
{
   ArrayResize(g_TxOrder_Records, 0);
   g_TxOrder_Count = 0;
}

int OrderAggregateRegistry_Count() { return g_TxOrder_Count; }

bool OrderAggregateRegistry_GetAt(int index, OrderAggregateRecord &out)
{
   if(index < 0 || index >= g_TxOrder_Count) return false;
   out = g_TxOrder_Records[index];
   return true;
}

int OrderAggregateRegistry_FindIndex(ulong orderTicket)
{
   for(int i = 0; i < g_TxOrder_Count; i++)
      if(g_TxOrder_Records[i].order_ticket == orderTicket)
         return i;
   return -1;
}

// Convenience query for future consumers/tests - never used internally
// to influence matching (matching is computed once, at rebuild time).
bool TransactionMatching_TryGetOrderStatus(ulong orderTicket, OrderAggregateRecord &out)
{
   int idx = OrderAggregateRegistry_FindIndex(orderTicket);
   if(idx < 0) return false;
   out = g_TxOrder_Records[idx];
   return true;
}

//---------------------------------------------------------------------
// Matching: for one deal record, try deal_ticket against a durable,
// SUBMITTED SubmissionOutcome first (priority A); only if that yields
// nothing, try order_ticket (priority B). Returns "" if neither
// matches - UNMATCHED for this deal. Only SUBMISSION_STATUS_SUBMITTED
// outcomes are ever a valid match target (section 22) - a rejected/
// errored/ambiguous submission was never acknowledged by the trade
// server, so no real deal could legitimately reference it.
//---------------------------------------------------------------------
string TransactionMatching_ResolveExecutionRequestId(const TransactionDealRecord &deal)
{
   for(int i = 0; i < SubmissionOutcomeProjection_Count(); i++)
   {
      SubmissionOutcomeProjectionRecord outcome;
      if(!SubmissionOutcomeProjection_GetAt(i, outcome)) continue;
      if(outcome.submission_status != SUBMISSION_STATUS_SUBMITTED) continue;
      if(outcome.deal_ticket == deal.deal_ticket)
         return outcome.execution_request_id;
   }
   for(int i = 0; i < SubmissionOutcomeProjection_Count(); i++)
   {
      SubmissionOutcomeProjectionRecord outcome;
      if(!SubmissionOutcomeProjection_GetAt(i, outcome)) continue;
      if(outcome.submission_status != SUBMISSION_STATUS_SUBMITTED) continue;
      if(outcome.order_ticket == deal.order_ticket)
         return outcome.execution_request_id;
   }
   return "";
}

// Phase 2: build the order-ticket aggregation from the now-complete deal
// registry. Pure function of g_TxDeal_Records[]/SubmissionOutcomeProjection/
// ExecutionRequestProjection - deterministic given the same store, same
// order every time (section 24's cold-rebuild-determinism requirement).
void TransactionMatching_BuildOrderAggregates()
{
   OrderAggregateRegistry_Reset();

   for(int i = 0; i < g_TxDeal_Count; i++)
   {
      TransactionDealRecord deal = g_TxDeal_Records[i];

      int orderIdx = OrderAggregateRegistry_FindIndex(deal.order_ticket);
      if(orderIdx < 0)
      {
         OrderAggregateRecord rec;
         OrderAggregateRecord_Init(rec);
         rec.order_ticket = deal.order_ticket;
         orderIdx = g_TxOrder_Count;
         ArrayResize(g_TxOrder_Records, orderIdx + 1);
         g_TxOrder_Records[orderIdx] = rec;
         g_TxOrder_Count++;
      }

      g_TxOrder_Records[orderIdx].running_filled_volume += deal.volume;
      g_TxOrder_Records[orderIdx].deal_count++;

      string resolved = TransactionMatching_ResolveExecutionRequestId(deal);
      if(resolved == "") continue; // this deal contributes no match evidence

      // First non-empty resolution seen for this order_ticket wins as the
      // provisional match; any LATER deal under the same order_ticket
      // resolving to a DIFFERENT execution_request_id flips this order to
      // AMBIGUOUS - once set, nothing in this loop ever reverts it back.
      if(g_TxOrder_Records[orderIdx].matched_execution_request_id == "")
         g_TxOrder_Records[orderIdx].matched_execution_request_id = resolved;
      else if(g_TxOrder_Records[orderIdx].matched_execution_request_id != resolved)
         g_TxOrder_Records[orderIdx].match_status = TX_MATCH_AMBIGUOUS;
   }

   // Second pass: resolve final status for every non-ambiguous order.
   for(int i = 0; i < g_TxOrder_Count; i++)
   {
      if(g_TxOrder_Records[i].match_status == TX_MATCH_AMBIGUOUS)
      {
         g_TxOrder_Records[i].matched_execution_request_id = ""; // never a usable match once ambiguous
         continue;
      }
      if(g_TxOrder_Records[i].matched_execution_request_id == "")
      {
         g_TxOrder_Records[i].match_status = TX_MATCH_UNMATCHED;
         continue;
      }

      ExecutionRequestProjectionRecord execReq;
      if(!ExecutionRequestProjection_TryGet(g_TxOrder_Records[i].matched_execution_request_id, execReq))
      {
         // Matched a real SubmissionOutcome but the referenced
         // ExecutionRequest is missing from an already-staged, already-
         // validated projection - structurally impossible if the
         // upstream gate (BrokerSubmissionAuditProjection_RebuildFromFile,
         // which itself requires a valid ExecutionRequest lineage for
         // every attempt) already passed. Fail closed rather than guess.
         g_TxOrder_Records[i].match_status = TX_MATCH_AMBIGUOUS;
         g_TxOrder_Records[i].matched_execution_request_id = "";
         continue;
      }

      g_TxOrder_Records[i].match_status = (g_TxOrder_Records[i].running_filled_volume >= execReq.lot_size)
                                            ? TX_MATCH_VOLUME_REACHED
                                            : TX_MATCH_PARTIAL;
   }
}

struct TransactionMatchingReport
{
   bool   ok;
   int    lines_total;
   int    observed_lines_seen;
   int    deal_add_lines_seen;
   int    deals_applied;
   int    deals_duplicate_replays;
   int    deals_failed;   // malformed (zero ticket) or collision
   int    orders_total;
   string first_error;
};

void TransactionMatchingReport_Init(TransactionMatchingReport &r)
{
   r.ok = true;
   r.lines_total = 0;
   r.observed_lines_seen = 0;
   r.deal_add_lines_seen = 0;
   r.deals_applied = 0;
   r.deals_duplicate_replays = 0;
   r.deals_failed = 0;
   r.orders_total = 0;
   r.first_error = "";
}

// The C3.3 entry point. Stages BrokerSubmissionAuditProjection_
// RebuildFromFile() FIRST, unmodified, as a black-box gate (it already
// transitively stages C1.3's ExecutionAuditProjection_RebuildFromFile
// beneath it) - this file never re-parses EXECUTION_REQUEST_CREATED/
// EXECUTION_SUBMISSION_ATTEMPTED/ORDER_SUBMITTED itself, only reads the
// already-validated g_SubOutcomeProj_Records[]/g_ExecReqProj_Records[]
// those stages populate. If that upstream gate fails, this rebuild fails
// closed too - no partial matching against an unvalidated submission
// history.
TransactionMatchingReport TransactionMatching_RebuildFromFile(string fileName)
{
   TransactionMatchingReport report;
   TransactionMatchingReport_Init(report);

   BrokerSubmissionAuditProjectionReport subReport = BrokerSubmissionAuditProjection_RebuildFromFile(fileName);
   if(!subReport.ok)
   {
      report.ok = false;
      report.first_error = "upstream BrokerSubmissionAuditProjection rebuild failed: " + subReport.first_error;
      TransactionDealRegistry_Reset();
      OrderAggregateRegistry_Reset();
      return report;
   }

   TransactionDealRegistry_Reset();
   OrderAggregateRegistry_Reset();

   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);
   report.lines_total = n;

   for(int i = 0; i < n; i++)
   {
      string line = lines[i];
      if(line == "") continue;
      if(EventSerializer_GetStr(line, "type") != "BROKER_TRANSACTION_OBSERVED") continue;
      report.observed_lines_seen++;

      // Active scope, this round (section 22): only TRADE_TRANSACTION_
      // DEAL_ADD lines represent a new fill fact. Every other observed
      // transaction type is left unread by C3.3.
      if(EventSerializer_GetStr(line, "transaction_type") != "TRADE_TRANSACTION_DEAL_ADD") continue;
      report.deal_add_lines_seen++;

      ulong dealTicket = (ulong)EventSerializer_GetLong(line, "deal_ticket");
      if(dealTicket == 0)
      {
         report.ok = false;
         report.deals_failed++;
         if(report.first_error == "")
            report.first_error = StringFormat("line %d: malformed DEAL_ADD observation - deal_ticket is zero", i);
         continue;
      }

      TransactionDealRecord rec;
      TransactionDealRecord_Init(rec);
      rec.deal_ticket  = dealTicket;
      rec.order_ticket = (ulong)EventSerializer_GetLong(line, "order_ticket");
      rec.symbol       = EventSerializer_GetStr(line, "symbol");
      rec.order_type   = EventSerializer_GetStr(line, "order_type");
      rec.deal_type    = EventSerializer_GetStr(line, "deal_type");
      rec.order_state  = EventSerializer_GetStr(line, "order_state");
      rec.price        = EventSerializer_GetDouble(line, "price");
      rec.volume       = EventSerializer_GetDouble(line, "volume");
      rec.price_sl     = EventSerializer_GetDouble(line, "price_sl");
      rec.price_tp     = EventSerializer_GetDouble(line, "price_tp");
      rec.source_sequence_number = EventSerializer_GetLong(line, "seq");
      rec.source_log_event_id    = EventSerializer_GetStr(line, "log_event_id");

      int existingIdx = TransactionDealRegistry_FindIndex(dealTicket);
      if(existingIdx >= 0)
      {
         if(TransactionDealRecord_SamePayload(g_TxDeal_Records[existingIdx], rec))
         {
            report.deals_duplicate_replays++; // idempotent replay - not a second record
            continue;
         }
         report.ok = false;
         report.deals_failed++;
         if(report.first_error == "")
            report.first_error = StringFormat("line %d: deal_ticket %s collision - existing record carries a "
                                                "DIFFERENT canonical payload - rejected as corruption, not a duplicate",
                                                i, IntegerToString((long)dealTicket));
         continue;
      }

      TransactionDealRegistry_AppendRecord(rec);
      report.deals_applied++;
   }

   TransactionMatching_BuildOrderAggregates();
   report.orders_total = g_TxOrder_Count;

   return report;
}

#endif // __MLQUANTAI_TRANSACTIONMATCHINGPROJECTION_MQH__
