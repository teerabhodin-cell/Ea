//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_PositionExitProvenanceResolver.mqh|
//| RA-65 Slice 1 (QA-frozen R3 addendum): the pure reverse-provenance |
//| resolution chain from a closing deal's `position_ticket` back to   |
//| the MLQuantAI candidate/correlation identity that opened it, so a  |
//| future POSITION_CLOSED emitter (RA-65 Slice 2, NOT authorized by   |
//| this file) never has to invent its own join logic.                 |
//|                                                                    |
//| Chain (frozen, reverse of C3.8 §14's forward "qualifying submitted |
//| outcome" resolution - reused, not reinvented):                    |
//|                                                                    |
//|   position_ticket + closingDealTicket (the CURRENT transaction's   |
//|   own trans.deal - required so the current transaction's own       |
//|   durable observation can be told apart from a PRIOR observation    |
//|   of the same position, e.g. the opening deal - see step 1's own    |
//|   comment for the pre-push correction this required)                 |
//|      -> scan durable BROKER_TRANSACTION_OBSERVED lines (C3.2,      |
//|         sealed - carries no candidate/correlation identity by      |
//|         design) for transaction_type == TRADE_TRANSACTION_DEAL_ADD |
//|         AND position_ticket == the ticket under resolution         |
//|      -> order_ticket                                               |
//|      -> scan SubmissionOutcomeProjection (C2.3, sealed) for         |
//|         order_ticket match AND submission_status == SUBMITTED      |
//|      -> execution_request_id                                       |
//|      -> scan ExecutionRequestProjection (C1.3, sealed) for          |
//|         execution_request_id match                                 |
//|      -> candidate_id, correlation_id                                |
//|                                                                     |
//| Each of the three steps is independently 0/1/>1 - QA's frozen rule: |
//| 0 matches = unresolved, exactly 1 = continue, >1 = ambiguous. Both   |
//| unresolved and ambiguous stop the chain and return a distinct,       |
//| non-RESOLVED status - NEVER a "first hit"/"most recent" guess. A     |
//| future caller (Slice 2) must treat every non-RESOLVED status as      |
//| "do not emit POSITION_CLOSED", and must NOT trip Safe Mode for it -   |
//| an unresolved/ambiguous chain means "cannot prove this broker fact   |
//| belongs to MLQuantAI", not "the durable write itself failed".        |
//|                                                                      |
//| Pure with respect to QA's frozen invariant list: this file never     |
//| appends an event, never mutates SubmissionOutcomeProjection/         |
//| ExecutionRequestProjection (read-only accessors only), never calls   |
//| SafeMode_Trip/OrderSend/CTrade/any broker API, and edits no sealed   |
//| file - BROKER_TRANSACTION_OBSERVED lines are read via the same       |
//| already-public EventSerializer_GetStr/GetLong field access every    |
//| other line-scanner in this project (C3.3/C3.7/C3.9) already uses.    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_POSITIONEXITPROVENANCERESOLVER_MQH__
#define __MLQUANTAI_POSITIONEXITPROVENANCERESOLVER_MQH__

#include "MLQuantAI_BrokerSubmissionAuditProjection.mqh"

enum ENUM_POSITION_EXIT_PROVENANCE_STATUS
{
   POSITION_EXIT_PROVENANCE_NONE,
   POSITION_EXIT_PROVENANCE_RESOLVED,
   POSITION_EXIT_PROVENANCE_NO_OBSERVATION,               // step 1: 0 matching BROKER_TRANSACTION_OBSERVED lines
   POSITION_EXIT_PROVENANCE_AMBIGUOUS_OBSERVATION,        // step 1: >1 matching BROKER_TRANSACTION_OBSERVED lines
   POSITION_EXIT_PROVENANCE_NO_SUBMISSION,                // step 2: 0 matching SUBMITTED SubmissionOutcome records
   POSITION_EXIT_PROVENANCE_AMBIGUOUS_SUBMISSION,         // step 2: >1 matching SUBMITTED SubmissionOutcome records
   POSITION_EXIT_PROVENANCE_NO_EXECUTION_REQUEST,         // step 3: 0 matching ExecutionRequestProjection records
   POSITION_EXIT_PROVENANCE_AMBIGUOUS_EXECUTION_REQUEST   // step 3: >1 matching ExecutionRequestProjection records
};

string PositionExitProvenanceStatusToString(ENUM_POSITION_EXIT_PROVENANCE_STATUS s)
{
   switch(s)
   {
      case POSITION_EXIT_PROVENANCE_RESOLVED:                     return "RESOLVED";
      case POSITION_EXIT_PROVENANCE_NO_OBSERVATION:                return "NO_OBSERVATION";
      case POSITION_EXIT_PROVENANCE_AMBIGUOUS_OBSERVATION:         return "AMBIGUOUS_OBSERVATION";
      case POSITION_EXIT_PROVENANCE_NO_SUBMISSION:                 return "NO_SUBMISSION";
      case POSITION_EXIT_PROVENANCE_AMBIGUOUS_SUBMISSION:          return "AMBIGUOUS_SUBMISSION";
      case POSITION_EXIT_PROVENANCE_NO_EXECUTION_REQUEST:          return "NO_EXECUTION_REQUEST";
      case POSITION_EXIT_PROVENANCE_AMBIGUOUS_EXECUTION_REQUEST:   return "AMBIGUOUS_EXECUTION_REQUEST";
   }
   return "NONE";
}

// True only for the single success class - every other status (including
// every future value this enum might ever gain) must be treated by a
// caller as "do not emit", so this is spelled as an explicit equality
// check, never an inverted "!= some failure value" that could silently
// admit a new status added later.
bool PositionExitProvenance_IsResolved(ENUM_POSITION_EXIT_PROVENANCE_STATUS s)
{
   return s == POSITION_EXIT_PROVENANCE_RESOLVED;
}

struct PositionExitProvenanceResult
{
   ENUM_POSITION_EXIT_PROVENANCE_STATUS status;

   ulong  order_ticket;            // valid once status has passed step 1 (i.e. status != NONE/NO_OBSERVATION/AMBIGUOUS_OBSERVATION)
   string execution_request_id;    // valid once status has passed step 2
   string candidate_id;            // valid only if status == RESOLVED
   string correlation_id;          // valid only if status == RESOLVED
};

void PositionExitProvenanceResult_Init(PositionExitProvenanceResult &r)
{
   r.status = POSITION_EXIT_PROVENANCE_NONE;
   r.order_ticket = 0;
   r.execution_request_id = "";
   r.candidate_id = "";
   r.correlation_id = "";
}

// Step 1 (CORRECTED per QA's pre-push diff audit blocker on the original
// commit): a real position's lifecycle durably logs AT LEAST two
// BROKER_TRANSACTION_OBSERVED DEAL_ADD lines sharing one position_ticket -
// the opening deal and the closing deal under resolution right now. The
// original version of this function counted ALL lines matching
// position_ticket with no way to tell them apart, so a completely normal
// single-open/single-close lifecycle always produced >1 matches and was
// always classified AMBIGUOUS_OBSERVATION - a 100% failure rate on the
// ordinary case, not a genuine edge case. Fixed two ways:
//
//  1. closingDealTicket (the CURRENT transaction's own trans.deal) is now
//     an explicit, separate parameter, never conflated with position_ticket.
//     Step 1 first requires PROOF that THIS transaction's own observation
//     is itself durable - a matching line with deal_ticket == closingDealTicket
//     - before doing anything else. Its absence means the current
//     transaction's own BROKER_TRANSACTION_OBSERVED write has not (yet, or
//     ever) landed - e.g. BrokerTransactionObservation_RecordAndGuard()
//     just failed and tripped Safe Mode for THIS transaction - and must
//     never be papered over by resolving from a stale PRIOR observation of
//     the same position_ticket. This directly enforces the frozen ordering
//     invariant ("POSITION_CLOSED only after BROKER_TRANSACTION_OBSERVED of
//     the SAME transaction is durable") inside the resolver itself, not
//     merely by caller convention.
//
//  2. The opening-side match is now computed over DISTINCT order_ticket
//     values among every OTHER matching line (position_ticket match,
//     deal_ticket != closingDealTicket) - not a raw line count. Multiple
//     partial-fill entries under the SAME order (several DEAL_ADD lines,
//     one order_ticket) collapse to one distinct value and resolve cleanly;
//     a position genuinely opened by two or more DIFFERENT orders (real
//     averaging-in across separate orders) still correctly reports
//     AMBIGUOUS_OBSERVATION - QA's frozen "never dedupe to guess a single
//     winner" rule, now applied to the right unit (distinct order identity,
//     not raw line count, which conflated "the same order re-observed" with
//     "two genuinely different orders").
void PositionExitProvenance_ResolveObservation(ulong positionTicket, ulong closingDealTicket, const string &lines[],
                                                  ENUM_POSITION_EXIT_PROVENANCE_STATUS &outStatus, ulong &outOrderTicket)
{
   outStatus = POSITION_EXIT_PROVENANCE_NO_OBSERVATION;
   outOrderTicket = 0;

   if(positionTicket == 0 || closingDealTicket == 0)
   {
      outStatus = POSITION_EXIT_PROVENANCE_NO_OBSERVATION;
      return;
   }

   bool currentTransactionObserved = false;
   ulong distinctOpeningOrderTickets[];

   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != "BROKER_TRANSACTION_OBSERVED") continue;
      if(EventSerializer_GetStr(lines[i], "transaction_type") != "TRADE_TRANSACTION_DEAL_ADD") continue;
      ulong linePositionTicket = (ulong)EventSerializer_GetLong(lines[i], "position_ticket");
      if(linePositionTicket != positionTicket) continue;

      ulong lineDealTicket = (ulong)EventSerializer_GetLong(lines[i], "deal_ticket");
      if(lineDealTicket == closingDealTicket)
      {
         currentTransactionObserved = true;
         continue; // the current closing transaction's own line is proof-of-durability only, never opening evidence
      }

      ulong lineOrderTicket = (ulong)EventSerializer_GetLong(lines[i], "order_ticket");
      bool alreadySeen = false;
      for(int j = 0; j < ArraySize(distinctOpeningOrderTickets); j++)
         if(distinctOpeningOrderTickets[j] == lineOrderTicket) { alreadySeen = true; break; }
      if(!alreadySeen)
      {
         int n = ArraySize(distinctOpeningOrderTickets);
         ArrayResize(distinctOpeningOrderTickets, n + 1);
         distinctOpeningOrderTickets[n] = lineOrderTicket;
      }
   }

   if(!currentTransactionObserved) { outStatus = POSITION_EXIT_PROVENANCE_NO_OBSERVATION; return; } // current transaction's own fact not durable - never resolve from stale prior evidence alone

   int distinctCount = ArraySize(distinctOpeningOrderTickets);
   if(distinctCount == 0) { outStatus = POSITION_EXIT_PROVENANCE_NO_OBSERVATION; return; }
   if(distinctCount > 1)  { outStatus = POSITION_EXIT_PROVENANCE_AMBIGUOUS_OBSERVATION; return; }

   outStatus = POSITION_EXIT_PROVENANCE_RESOLVED; // step-local success only - overall status is decided by the caller
   outOrderTicket = distinctOpeningOrderTickets[0];
}

// Step 2: order_ticket -> execution_request_id, via SubmissionOutcomeProjection
// (C2.3, sealed, read-only accessors only). Only submission_status ==
// SUBMITTED records are eligible - a REJECTED/ERROR/UNKNOWN record for the
// same order_ticket never counts toward this step's uniqueness check, per
// QA's frozen "filter before counting" rule.
void PositionExitProvenance_ResolveSubmission(ulong orderTicket,
                                                 ENUM_POSITION_EXIT_PROVENANCE_STATUS &outStatus, string &outExecutionRequestId)
{
   outStatus = POSITION_EXIT_PROVENANCE_NO_SUBMISSION;
   outExecutionRequestId = "";

   int matchCount = 0;
   string matchedExecutionRequestId = "";
   int total = SubmissionOutcomeProjection_Count();
   for(int i = 0; i < total; i++)
   {
      SubmissionOutcomeProjectionRecord rec;
      if(!SubmissionOutcomeProjection_GetAt(i, rec)) continue;
      if(rec.order_ticket != orderTicket) continue;
      if(rec.submission_status != SUBMISSION_STATUS_SUBMITTED) continue;

      matchCount++;
      matchedExecutionRequestId = rec.execution_request_id;
   }

   if(matchCount == 0) { outStatus = POSITION_EXIT_PROVENANCE_NO_SUBMISSION; return; }
   if(matchCount > 1)  { outStatus = POSITION_EXIT_PROVENANCE_AMBIGUOUS_SUBMISSION; return; }

   outStatus = POSITION_EXIT_PROVENANCE_RESOLVED;
   outExecutionRequestId = matchedExecutionRequestId;
}

// Step 3: execution_request_id -> candidate_id/correlation_id, via
// ExecutionRequestProjection (C1.3, sealed, read-only accessors only).
void PositionExitProvenance_ResolveExecutionRequest(string executionRequestId,
                                                       ENUM_POSITION_EXIT_PROVENANCE_STATUS &outStatus,
                                                       string &outCandidateId, string &outCorrelationId)
{
   outStatus = POSITION_EXIT_PROVENANCE_NO_EXECUTION_REQUEST;
   outCandidateId = "";
   outCorrelationId = "";

   int matchCount = 0;
   string matchedCandidateId = "";
   string matchedCorrelationId = "";
   int total = ExecutionRequestProjection_Count();
   for(int i = 0; i < total; i++)
   {
      ExecutionRequestProjectionRecord rec;
      if(!ExecutionRequestProjection_GetAt(i, rec)) continue;
      if(rec.execution_request_id != executionRequestId) continue;

      matchCount++;
      matchedCandidateId = rec.candidate_id;
      matchedCorrelationId = rec.correlation_id;
   }

   if(matchCount == 0) { outStatus = POSITION_EXIT_PROVENANCE_NO_EXECUTION_REQUEST; return; }
   if(matchCount > 1)  { outStatus = POSITION_EXIT_PROVENANCE_AMBIGUOUS_EXECUTION_REQUEST; return; }

   outStatus = POSITION_EXIT_PROVENANCE_RESOLVED;
   outCandidateId = matchedCandidateId;
   outCorrelationId = matchedCorrelationId;
}

// The full chain, frozen order, short-circuiting at the first non-resolved
// step - never continuing past an unresolved/ambiguous step "just to see".
// closingDealTicket (the current transaction's own trans.deal) is required
// so step 1 can tell "this transaction's own durable observation" apart
// from "a prior observation of the same position" - see the corrected
// PositionExitProvenance_ResolveObservation() above for why this is not
// optional.
void PositionExitProvenance_Resolve(ulong positionTicket, ulong closingDealTicket, const string &lines[], PositionExitProvenanceResult &outResult)
{
   PositionExitProvenanceResult_Init(outResult);

   ENUM_POSITION_EXIT_PROVENANCE_STATUS step1Status;
   ulong orderTicket;
   PositionExitProvenance_ResolveObservation(positionTicket, closingDealTicket, lines, step1Status, orderTicket);
   if(step1Status != POSITION_EXIT_PROVENANCE_RESOLVED)
   {
      outResult.status = step1Status;
      return;
   }
   outResult.order_ticket = orderTicket;

   ENUM_POSITION_EXIT_PROVENANCE_STATUS step2Status;
   string executionRequestId;
   PositionExitProvenance_ResolveSubmission(orderTicket, step2Status, executionRequestId);
   if(step2Status != POSITION_EXIT_PROVENANCE_RESOLVED)
   {
      outResult.status = step2Status;
      return;
   }
   outResult.execution_request_id = executionRequestId;

   ENUM_POSITION_EXIT_PROVENANCE_STATUS step3Status;
   string candidateId, correlationId;
   PositionExitProvenance_ResolveExecutionRequest(executionRequestId, step3Status, candidateId, correlationId);
   outResult.status = step3Status; // RESOLVED or one of the two step-3 failure classes
   if(step3Status == POSITION_EXIT_PROVENANCE_RESOLVED)
   {
      outResult.candidate_id = candidateId;
      outResult.correlation_id = correlationId;
   }
}

#endif // __MLQUANTAI_POSITIONEXITPROVENANCERESOLVER_MQH__
