//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_AsyncTerminalOrderObservationMatcher.mqh |
//| C3.10A implementation. Read-only diagnostic: scans the durable    |
//| BROKER_TRANSACTION_OBSERVED log for asynchronous, order-object    |
//| terminal outcomes (rejected/cancelled/expired) and matches each   |
//| to a submitted execution request / candidate, via the same        |
//| ticket-based lookup hierarchy C3.3 already establishes.           |
//|                                                                    |
//| Classification is real-demo-evidence-backed, not documentation-   |
//| derived: all three terminal states (ORDER_STATE_REJECTED,         |
//| ORDER_STATE_CANCELED, ORDER_STATE_EXPIRED) were captured on a live |
//| demo account and confirmed to appear exclusively on                |
//| TRADE_TRANSACTION_ORDER_DELETE - never on ORDER_UPDATE, which only |
//| ever carries transient states (PLACED, REQUEST_CANCEL) in the      |
//| captured evidence. TRADE_TRANSACTION_HISTORY_ADD mirrors the same  |
//| terminal state on a second channel and is deliberately ignored,    |
//| not deduped against ORDER_DELETE, per the locked Slice A design.   |
//|                                                                    |
//| Deliberately does NOT: write any event, add any ENUM_EVENT_TYPE,   |
//| drive CANDIDATE_SUBMITTED -> CANDIDATE_REJECTED_BY_BROKER, call any |
//| *_StartupRebuild/*_RebuildFromFile (reads whatever state the       |
//| already-staged SubmissionOutcomeProjection/ExecutionRequestProjection|
//| currently hold), touch OnInit/OnTradeTransaction, or call any       |
//| broker/order/history/position API. Report only.                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ASYNCTERMINALORDEROBSERVATIONMATCHER_MQH__
#define __MLQUANTAI_ASYNCTERMINALORDEROBSERVATIONMATCHER_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh"
#include "MLQuantAI_BrokerSubmissionAuditProjection.mqh"
#include "MLQuantAI_ExecutionAuditProjection.mqh"

//---------------------------------------------------------------------
// ATOM_ValidateSeqToken - validates a raw "seq" token BEFORE any call to
// StringToInteger, whose behavior on an oversized digit string is
// unspecified (same overflow-risk class C3.9's EPCA_GetLongArray already
// guards against). Uses EventSerializer_GetRawNumber - an existing,
// already-sealed parser surface - to obtain the raw token; the
// validation itself is new, local logic, not a new JSON scanner.
//
// seq is always a positive, 1-based sequence number by BaseEvent's own
// contract - unlike an array element, this helper rejects ANY leading
// '-' outright rather than accepting a negative magnitude to range-check:
// a negative seq is malformed by definition.
//---------------------------------------------------------------------
bool ATOM_ValidateSeqToken(string rawToken, long &outSeq)
{
   int len = StringLen(rawToken);
   if(len == 0 || len > 19) return false;  // empty (key missing) or definitely overflowing

   for(int i = 0; i < len; i++)
   {
      ushort ch = StringGetCharacter(rawToken, i);
      if(ch < '0' || ch > '9') return false;  // any non-digit, including a leading '-', is invalid
   }

   if(len == 19)
   {
      // Exactly int64 max's digit count - magnitude must be checked
      // explicitly before trusting StringToInteger. StringCompare is a
      // real, already-used precedent in this codebase
      // (MLQuantAI_DeferredTransactionProcessor.mqh) - safe here because
      // both operands are already proven to be equal-length (19),
      // pure-digit strings, for which ordinal comparison equals magnitude
      // comparison.
      string maxDigits = "9223372036854775807";
      if(StringCompare(rawToken, maxDigits) > 0) return false;
   }

   outSeq = StringToInteger(rawToken);  // now provably safe: pure-digit, <=19 chars, magnitude-bounded
   return true;
}

//---------------------------------------------------------------------
// Result shapes (locked at Checkpoint 1/2).
//---------------------------------------------------------------------
enum ENUM_ATOM_OBSERVED_KIND
{
   ATOM_REJECTED,
   ATOM_CANCELED,
   ATOM_EXPIRED
};

string ATOM_ObservedKindToString(ENUM_ATOM_OBSERVED_KIND k)
{
   switch(k)
   {
      case ATOM_REJECTED: return "REJECTED";
      case ATOM_CANCELED: return "CANCELED";
      case ATOM_EXPIRED:  return "EXPIRED";
   }
   return "UNKNOWN";
}

enum ENUM_ATOM_MATCH_STATUS
{
   ATOM_MATCHED,
   ATOM_UNMATCHED,
   ATOM_AMBIGUOUS
};

string ATOM_MatchStatusToString(ENUM_ATOM_MATCH_STATUS s)
{
   switch(s)
   {
      case ATOM_MATCHED:   return "MATCHED";
      case ATOM_UNMATCHED: return "UNMATCHED";
      case ATOM_AMBIGUOUS: return "AMBIGUOUS";
   }
   return "UNKNOWN";
}

struct AsyncTerminalOrderMatch
{
   ENUM_ATOM_OBSERVED_KIND observed_kind;
   ulong                   order_ticket;
   ENUM_ATOM_MATCH_STATUS  status;
   string                  execution_request_id;  // "" unless MATCHED
   string                  candidate_id;           // "" unless MATCHED
   long                    source_sequence_number; // from the raw line's own "seq"
   string                  source_log_event_id;    // from the raw line's own "log_event_id" - may be "" (not fatal)
};

void AsyncTerminalOrderMatch_Init(AsyncTerminalOrderMatch &m)
{
   m.observed_kind = ATOM_REJECTED;
   m.order_ticket = 0;
   m.status = ATOM_UNMATCHED;
   m.execution_request_id = "";
   m.candidate_id = "";
   m.source_sequence_number = 0;
   m.source_log_event_id = "";
}

struct AsyncTerminalOrderMatchReport
{
   bool  ok;                          // true iff ambiguous_count == 0 (UNMATCHED is normal, not an error)
   int   observed_total;              // every recognized BROKER_TRANSACTION_OBSERVED line, any transaction_type, incl. invalid-seq ones
   int   invalid_observation_lines;   // subset of observed_total: seq missing/malformed/non-positive/overflowing
   int   relevant_total;              // qualifying ORDER_DELETE + terminal order_state + order_ticket>0 lines (== ArraySize(matches))
   int   matched_count;
   int   unmatched_count;
   int   ambiguous_count;
   AsyncTerminalOrderMatch matches[];
};

void AsyncTerminalOrderMatchReport_Init(AsyncTerminalOrderMatchReport &r)
{
   r.ok = true;
   r.observed_total = 0;
   r.invalid_observation_lines = 0;
   r.relevant_total = 0;
   r.matched_count = 0;
   r.unmatched_count = 0;
   r.ambiguous_count = 0;
   ArrayResize(r.matches, 0);
}

//---------------------------------------------------------------------
// Pure core - takes lines[] directly (never opens/reads a file itself),
// same split C3.9/C3.3/EventStoreValidator already establish.
//---------------------------------------------------------------------
AsyncTerminalOrderMatchReport AsyncTerminalOrderMatcher_ScanLines(const string &lines[], int n)
{
   AsyncTerminalOrderMatchReport report;
   AsyncTerminalOrderMatchReport_Init(report);

   int limit = n;
   if(limit < 0) limit = 0;
   int avail = ArraySize(lines);
   if(limit > avail) limit = avail;

   for(int i = 0; i < limit; i++)
   {
      string line = lines[i];
      if(line == "") continue;
      if(EventSerializer_PeekCategory(line) != EVENT_CAT_SYSTEM) continue;
      if(EventSerializer_GetStr(line, "type") != "BROKER_TRANSACTION_OBSERVED") continue;

      report.observed_total++;

      string rawSeq = EventSerializer_GetRawNumber(line, "seq");
      long seq;
      if(!ATOM_ValidateSeqToken(rawSeq, seq) || seq <= 0)
      {
         report.invalid_observation_lines++;
         continue;
      }

      // Relevance filter (section 6, locked): none of these make the line
      // invalid - they just mean it isn't a terminal-order-observation
      // this matcher cares about.
      string transactionType = EventSerializer_GetStr(line, "transaction_type");
      if(transactionType != "TRADE_TRANSACTION_ORDER_DELETE") continue;

      string orderState = EventSerializer_GetStr(line, "order_state");
      ENUM_ATOM_OBSERVED_KIND kind;
      if(orderState == "ORDER_STATE_REJECTED")      kind = ATOM_REJECTED;
      else if(orderState == "ORDER_STATE_CANCELED") kind = ATOM_CANCELED;
      else if(orderState == "ORDER_STATE_EXPIRED")  kind = ATOM_EXPIRED;
      else continue;

      long orderTicketRaw = EventSerializer_GetLong(line, "order_ticket");
      if(orderTicketRaw <= 0) continue;
      ulong orderTicket = (ulong)orderTicketRaw;

      AsyncTerminalOrderMatch m;
      AsyncTerminalOrderMatch_Init(m);
      m.observed_kind           = kind;
      m.order_ticket             = orderTicket;
      m.source_sequence_number   = seq;
      m.source_log_event_id      = EventSerializer_GetStr(line, "log_event_id"); // "" is not fatal

      // Matching hierarchy (section 3, locked): count every SUBMITTED
      // outcome for this ticket - never first-match-wins.
      int submittedMatches = 0;
      string resolvedExecReqId = "";
      for(int j = 0; j < SubmissionOutcomeProjection_Count(); j++)
      {
         SubmissionOutcomeProjectionRecord outcome;
         if(!SubmissionOutcomeProjection_GetAt(j, outcome)) continue;
         if(outcome.submission_status != SUBMISSION_STATUS_SUBMITTED) continue;
         if(outcome.order_ticket != orderTicket) continue;
         submittedMatches++;
         resolvedExecReqId = outcome.execution_request_id;
      }

      if(submittedMatches == 0)
      {
         m.status = ATOM_UNMATCHED;
      }
      else if(submittedMatches > 1)
      {
         m.status = ATOM_AMBIGUOUS;
      }
      else
      {
         ExecutionRequestProjectionRecord execReq;
         if(!ExecutionRequestProjection_TryGet(resolvedExecReqId, execReq))
         {
            m.status = ATOM_AMBIGUOUS; // matched outcome but its own execution request is missing - fail closed
         }
         else if(execReq.candidate_id == "")
         {
            m.status = ATOM_AMBIGUOUS; // unusable link - never propagate an empty candidate_id as meaningful
         }
         else
         {
            m.status                = ATOM_MATCHED;
            m.execution_request_id  = resolvedExecReqId;
            m.candidate_id          = execReq.candidate_id;
         }
      }

      int cc = ArraySize(report.matches);
      ArrayResize(report.matches, cc + 1);
      report.matches[cc] = m;
   }

   // Post-pass duplicate escalation (section 3, locked): if the same
   // order_ticket produced more than one qualifying ORDER_DELETE terminal
   // line in this scan, every match for that ticket becomes AMBIGUOUS -
   // overriding whatever it individually resolved to above.
   int totalMatches = ArraySize(report.matches);
   ulong ticketKeys[]; int ticketCount[]; int keyCount = 0;
   for(int i = 0; i < totalMatches; i++)
   {
      ulong t = report.matches[i].order_ticket;
      int idx = -1;
      for(int k = 0; k < keyCount; k++)
         if(ticketKeys[k] == t) { idx = k; break; }
      if(idx < 0)
      {
         ArrayResize(ticketKeys, keyCount + 1);
         ArrayResize(ticketCount, keyCount + 1);
         ticketKeys[keyCount] = t;
         ticketCount[keyCount] = 0;
         idx = keyCount;
         keyCount++;
      }
      ticketCount[idx]++;
   }
   for(int k = 0; k < keyCount; k++)
   {
      if(ticketCount[k] <= 1) continue;
      for(int i = 0; i < totalMatches; i++)
         if(report.matches[i].order_ticket == ticketKeys[k])
            report.matches[i].status = ATOM_AMBIGUOUS;
   }

   // Counters recomputed from scratch, once, from matches[].status only -
   // never incrementally patched during the escalation pass above, so
   // there is no possibility of drift between the array and the counts.
   report.relevant_total = totalMatches;
   report.matched_count = 0;
   report.unmatched_count = 0;
   report.ambiguous_count = 0;
   for(int i = 0; i < totalMatches; i++)
   {
      if(report.matches[i].status == ATOM_MATCHED)        report.matched_count++;
      else if(report.matches[i].status == ATOM_UNMATCHED) report.unmatched_count++;
      else                                                report.ambiguous_count++;
   }

   report.ok = (report.ambiguous_count == 0);

   return report;
}

// Thin wrapper: EventStore_ReadAllLines(fileName, lines) then _ScanLines.
// Never calls any *_StartupRebuild/*_RebuildFromFile - SubmissionOutcomeProjection
// and ExecutionRequestProjection are read exactly as they currently stand.
AsyncTerminalOrderMatchReport AsyncTerminalOrderMatcher_ScanFile(string fileName)
{
   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);
   return AsyncTerminalOrderMatcher_ScanLines(lines, n);
}

#endif // __MLQUANTAI_ASYNCTERMINALORDEROBSERVATIONMATCHER_MQH__
