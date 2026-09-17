//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BrokerFactCorrelationVerify.mqh   |
//| §6.2 Evidence-Gate Design Contract Rev.8 (QA-frozen DESIGN FREEZE,  |
//| Docs/PhaseC_C5_2_Section6_2_EvidenceGateDesignContract.md §2/P2): the |
//| canonical, ONE-AND-ONLY resolver for "does this BROKER_TRANSACTION_    |
//| OBSERVED fact trace to a known ExecutionRequest/candidate lineage" -    |
//| covers EVERY transaction_type, not just TRADE_TRANSACTION_DEAL_ADD        |
//| (frozen criterion preserved in full, no scope-narrowing amendment),        |
//| decided PER RAW LINE, never per aggregate.                                   |
//|                                                                                 |
//| Single canonical source: queries the durable                                    |
//| SubmissionOutcomeProjectionRecord set directly (MLQuantAI_                       |
//| BrokerSubmissionAuditProjection.mqh, Class 1, unmodified) - never                  |
//| OrderAggregateRecord (MLQuantAI_TransactionMatchingProjection.mqh, Class 1,          |
//| unmodified), which is only a derived convenience view over the same                  |
//| underlying records computed for a different purpose. Ticket parameters are            |
//| ulong throughout - MT5 ticket identifiers are broker-assigned 64-bit values             |
//| with no frozen upper bound; no cast to a narrower type occurs anywhere in                |
//| this file.                                                                                  |
//|                                                                                                |
//| Does not modify MLQuantAI_TransactionMatchingProjection.mqh, MLQuantAI_                        |
//| BrokerSubmissionAuditProjection.mqh, or MLQuantAI_ExecutionAuditProjection.mqh                   |
//| (all Class 1, untouched) - read-only, calls into their already-sealed,                             |
//| already-populated registries only. Callers MUST have already run                                     |
//| BrokerSubmissionAuditProjection_RebuildFromFile(fileName) (which itself stages                          |
//| ExecutionAuditProjection_RebuildFromFile beneath it) before calling anything                              |
//| in this file - this file never triggers a rebuild itself, to stay a pure                                    |
//| reader over whatever the caller already staged (matching every other                                         |
//| verify/evaluate function in this checkpoint's own style).                                                        |
//|                                                                                                                      |
//| Pure: no EventStore read/write, no live MT5 API, no Safe Mode, no OrderSend,                                         |
//| no candidate-lifecycle authority.                                                                                      |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BROKERFACTCORRELATIONVERIFY_MQH__
#define __MLQUANTAI_BROKERFACTCORRELATIONVERIFY_MQH__

#include "MLQuantAI_BrokerSubmissionAuditProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh"

enum ENUM_BROKER_FACT_KEY_KIND
{
   BROKER_FACT_KEY_DEAL_TICKET,
   BROKER_FACT_KEY_ORDER_TICKET
};

enum ENUM_BROKER_FACT_RESOLUTION_RESULT
{
   BROKER_FACT_RESOLVED_ONE,        // exactly one match - proceed
   BROKER_FACT_UNCORRELATED,        // zero matches
   BROKER_FACT_AMBIGUOUS            // more than one match
};

// The canonical resolver. correlatingKeyValue/keyKind select deal_ticket
// or order_ticket; only SubmissionOutcomeProjectionRecord entries whose
// submission_status == SUBMISSION_STATUS_SUBMITTED are ever a valid match
// target - a rejected/errored/ambiguous submission was never acknowledged
// by the trade server, mirroring TransactionMatching_
// ResolveExecutionRequestId's own frozen precedent (Class 1, unmodified,
// not called from here - this is an independent, tri-state-capable
// resolution over the SAME canonical records, not a wrapper around it).
//
// `lines[]` is accepted to match this function's frozen signature (§2/P2)
// even though resolution itself is decided entirely from the already-
// staged SubmissionOutcomeProjectionRecord registry, not by re-scanning
// lines[] directly - the registry, not the raw array, is the source of
// truth this function reads.
ENUM_BROKER_FACT_RESOLUTION_RESULT BrokerFact_ResolveExecutionRequestId(const string &lines[], ulong correlatingKeyValue,
                                                                          ENUM_BROKER_FACT_KEY_KIND keyKind, string &outExecutionRequestId)
{
   outExecutionRequestId = "";
   string matchedId = "";
   bool   foundAny  = false;
   bool   ambiguous = false;

   for(int i = 0; i < SubmissionOutcomeProjection_Count(); i++)
   {
      SubmissionOutcomeProjectionRecord rec;
      if(!SubmissionOutcomeProjection_GetAt(i, rec)) continue;
      if(rec.submission_status != SUBMISSION_STATUS_SUBMITTED) continue;

      bool keyMatches = (keyKind == BROKER_FACT_KEY_DEAL_TICKET) ? (rec.deal_ticket == correlatingKeyValue)
                                                                    : (rec.order_ticket == correlatingKeyValue);
      if(!keyMatches) continue;

      if(!foundAny)
      {
         matchedId = rec.execution_request_id;
         foundAny  = true;
      }
      else if(rec.execution_request_id != matchedId)
      {
         ambiguous = true;
      }
   }

   if(!foundAny)  return BROKER_FACT_UNCORRELATED;
   if(ambiguous)  return BROKER_FACT_AMBIGUOUS;

   outExecutionRequestId = matchedId;
   return BROKER_FACT_RESOLVED_ONE;
}

enum ENUM_P2_VERIFY_RESULT
{
   P2_VERIFY_OK,
   P2_VERIFY_UNCORRELATED,          // uncorrelated_broker_fact
   P2_VERIFY_AMBIGUOUS              // uncorrelated_broker_fact_ambiguous
};

struct BrokerFactCorrelationVerifyResult
{
   ENUM_P2_VERIFY_RESULT status;
   long                  failing_sequence_number; // populated only on failure, for operator diagnosis
};

void BrokerFactCorrelationVerifyResult_Init(BrokerFactCorrelationVerifyResult &r)
{
   r.status = P2_VERIFY_OK;
   r.failing_sequence_number = 0;
}

// The per-line driver. Iterates every in-window (index > windowStartIndex)
// BROKER_TRANSACTION_OBSERVED line, of any transaction_type, and applies
// the frozen Tier 1/Tier 2 rule to each:
//   Tier 1 (transaction_type == TRADE_TRANSACTION_DEAL_ADD): deal_ticket
//     first, then (only if UNCORRELATED) order_ticket as fallback -
//     mirrors TransactionMatching_ResolveExecutionRequestId's own
//     documented precedence.
//   Tier 2 (every other transaction_type): order_ticket only. No
//     request_id-based path is ever used - result.request_id is an
//     MT5-session-scoped async identifier with no durable mapping back to
//     execution_request_id, and an absent/sentinel (zero) order_ticket is
//     itself BROKER_FACT_UNCORRELATED by definition, no separate
//     mechanism.
// A resolved id must ALSO pass mandatory lineage confirmation
// (ExecutionRequestProjection_TryGet) - an orphaned/corrupt attempt record
// that resolves to nothing real is treated as unresolved (0-match
// treatment), never as "resolved because a record with that id exists".
// Stops at the FIRST failing line (matches every other "first_error"
// projection report in this codebase) - carries that line's own sequence
// number for diagnosis.
BrokerFactCorrelationVerifyResult BrokerFactCorrelation_VerifyWindow(const string &lines[], int windowStartIndex)
{
   BrokerFactCorrelationVerifyResult result;
   BrokerFactCorrelationVerifyResult_Init(result);

   string observedType = EventTypeToString(EVENT_TYPE_BROKER_TRANSACTION_OBSERVED);

   for(int i = windowStartIndex + 1; i < ArraySize(lines); i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != observedType) continue;

      string execRequestId = "";
      ENUM_BROKER_FACT_RESOLUTION_RESULT res;

      if(EventSerializer_GetStr(lines[i], "transaction_type") == "TRADE_TRANSACTION_DEAL_ADD")
      {
         ulong dealTicket = (ulong)EventSerializer_GetLong(lines[i], "deal_ticket");
         res = BrokerFact_ResolveExecutionRequestId(lines, dealTicket, BROKER_FACT_KEY_DEAL_TICKET, execRequestId);
         if(res == BROKER_FACT_UNCORRELATED)
         {
            ulong orderTicket = (ulong)EventSerializer_GetLong(lines[i], "order_ticket");
            res = BrokerFact_ResolveExecutionRequestId(lines, orderTicket, BROKER_FACT_KEY_ORDER_TICKET, execRequestId);
         }
      }
      else
      {
         ulong orderTicket = (ulong)EventSerializer_GetLong(lines[i], "order_ticket");
         if(orderTicket == 0)
            res = BROKER_FACT_UNCORRELATED;
         else
            res = BrokerFact_ResolveExecutionRequestId(lines, orderTicket, BROKER_FACT_KEY_ORDER_TICKET, execRequestId);
      }

      if(res == BROKER_FACT_UNCORRELATED)
      {
         result.status = P2_VERIFY_UNCORRELATED;
         result.failing_sequence_number = EventSerializer_GetLong(lines[i], "seq");
         return result;
      }
      if(res == BROKER_FACT_AMBIGUOUS)
      {
         result.status = P2_VERIFY_AMBIGUOUS;
         result.failing_sequence_number = EventSerializer_GetLong(lines[i], "seq");
         return result;
      }

      // Mandatory lineage confirmation (§2/P2, frozen) - a resolved id
      // that does not itself lead to a real candidate is unresolved, not
      // "resolved because a record exists".
      ExecutionRequestProjectionRecord execRec;
      if(!ExecutionRequestProjection_TryGet(execRequestId, execRec))
      {
         result.status = P2_VERIFY_UNCORRELATED;
         result.failing_sequence_number = EventSerializer_GetLong(lines[i], "seq");
         return result;
      }
   }

   return result; // P2_VERIFY_OK
}

#endif // __MLQUANTAI_BROKERFACTCORRELATIONVERIFY_MQH__
