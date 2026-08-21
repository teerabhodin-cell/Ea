//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BrokerSubmissionAdapter.mqh      |
//| Phase C2.2: BrokerSubmission_Submit() - the real OrderSend         |
//| orchestration boundary from                                        |
//| Docs/PhaseC_C2_1_BrokerSubmissionContract.md's lifecycle diagram.  |
//| THIS FILE CALLS THE REAL OrderSend() AND, ON A REAL DEMO ACCOUNT,  |
//| WILL OPEN A REAL POSITION. The automated regression suite          |
//| (Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5) MUST NEVER     |
//| call BrokerSubmission_Submit() - it only exercises                 |
//| BrokerSubmissionGate_Evaluate/BrokerSubmission_BuildTradeRequest/   |
//| BrokerSubmission_ClassifyRetcode directly, none of which touch     |
//| OrderSend. Only the separate, explicitly opt-in real-submit smoke  |
//| test may call this function, run manually by the user.             |
//|                                                                     |
//| Return value convention (matches EventStore_LogTransition/         |
//| EventStore_LogCandidateCreated precedent): true iff every event    |
//| write this call chain attempted succeeded durably - regardless of  |
//| whether the broker accepted, rejected, or a local error occurred;  |
//| outResult.submission_status/reason_code carry the actual business  |
//| outcome. false means a durability failure occurred, OR the attempt |
//| never got past pre-submission gating/construction (no OrderSend    |
//| call was ever made in that case). Same non-rollback discipline as  |
//| every prior emitter: once an event write succeeds it is never      |
//| rolled back, even if a later write in the same call fails.         |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BROKERSUBMISSIONADAPTER_MQH__
#define __MLQUANTAI_BROKERSUBMISSIONADAPTER_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "MLQuantAI_BrokerSubmissionGate.mqh"
#include "MLQuantAI_BrokerSubmissionBuilder.mqh"
#include "MLQuantAI_ExecutionSubmissionContract.mqh"

string ExecutionSubmissionAttempt_ToExtraJson(string executionRequestId, string executionRequestHash,
                                                string correlationId, int submitAttempt)
{
   string s = "";
   s += "\"execution_request_id\":\""   + EventSerializer_Escape(executionRequestId) + "\",";
   s += "\"execution_request_hash\":\"" + EventSerializer_Escape(executionRequestHash) + "\",";
   s += "\"correlation_id\":\""         + EventSerializer_Escape(correlationId) + "\",";
   s += "\"submit_attempt\":"           + IntegerToString(submitAttempt);
   return s;
}

string ExecutionSubmissionResult_ToExtraJson(const ExecutionSubmissionResult &r)
{
   string s = "";
   s += "\"execution_submission_result_schema_version\":\"" + EventSerializer_Escape(r.execution_submission_result_schema_version) + "\",";
   s += "\"execution_request_id\":\""   + EventSerializer_Escape(r.execution_request_id) + "\",";
   s += "\"execution_request_hash\":\"" + EventSerializer_Escape(r.execution_request_hash) + "\",";
   s += "\"correlation_id\":\""         + EventSerializer_Escape(r.correlation_id) + "\",";
   s += "\"submit_attempt\":"           + IntegerToString(r.submit_attempt) + ",";
   s += "\"submission_status\":\""      + SubmissionStatusToString(r.submission_status) + "\",";
   s += "\"order_send_returned\":"      + (r.order_send_returned ? "true" : "false") + ",";
   s += "\"terminal_last_error\":"      + IntegerToString(r.terminal_last_error) + ",";
   s += "\"retcode\":"                  + IntegerToString((long)r.retcode) + ",";
   s += "\"retcode_external\":"         + IntegerToString(r.retcode_external) + ",";
   s += "\"request_id\":"               + IntegerToString(r.request_id) + ",";
   s += "\"order_ticket\":"             + IntegerToString((long)r.order_ticket) + ",";
   s += "\"deal_ticket\":"              + IntegerToString((long)r.deal_ticket) + ",";
   s += "\"requested_price\":"          + CanonicalPrice(r.requested_price) + ",";
   s += "\"observed_submit_price\":"    + CanonicalPrice(r.observed_submit_price) + ",";
   s += "\"submission_timestamp\":"     + IntegerToString((long)r.submission_timestamp) + ",";
   s += "\"reason_code\":\""            + ReasonCodeToString(r.reason_code) + "\"";
   return s;
}

bool BrokerSubmission_Submit(TradeCandidate &candidate, const ExecutionRequest &request, const ExecutionPolicy &policy,
                               ExecutionSubmissionResult &outResult)
{
   ExecutionSubmissionResult_Init(outResult);
   outResult.execution_request_id   = request.execution_request_id;
   outResult.execution_request_hash = request.execution_request_hash;
   outResult.correlation_id         = request.correlation_id;
   outResult.submit_attempt         = request.submit_attempt;

   // Only a CREATED candidate may legally reach SUBMITTED - a structural
   // precondition, not itself part of the frozen retcode/event lifecycle.
   if(candidate.candidate_id != request.candidate_id || candidate.state != CANDIDATE_CREATED)
      return false;

   DryRunExecutionResult gateResult;
   if(!BrokerSubmissionGate_Evaluate(request, policy, gateResult))
      return false; // structural failure inside the gate itself

   if(gateResult.decision != SAFETY_GATE_ACCEPTED)
   {
      outResult.reason_code = gateResult.reason_code;
      return false; // gate rejected - no event, no OrderSend, no state change
   }

   MqlTradeRequest tradeRequest;
   ENUM_REASON_CODE buildRejectReason;
   if(!BrokerSubmission_BuildTradeRequest(request, policy, gateResult.observed_symbol, tradeRequest, buildRejectReason))
   {
      outResult.reason_code = buildRejectReason;
      return false; // construction failed - no event, no OrderSend, no state change
   }

   // Crossed the final gate - audit the intent BEFORE any broker claim.
   // First-ever write to candidate.correlation_id.
   candidate.correlation_id = request.correlation_id;
   string attemptJson = ExecutionSubmissionAttempt_ToExtraJson(request.execution_request_id, request.execution_request_hash,
                                                                  request.correlation_id, request.submit_attempt);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED), "execution submission attempted", attemptJson))
      return false; // could not durably record intent - abort before ever calling OrderSend

   BrokerSubmissionGate_MarkAttempted(request.execution_request_id);

   MqlTradeResult tradeResult;
   ZeroMemory(tradeResult);
   bool sendReturned = OrderSend(tradeRequest, tradeResult);

   outResult.order_send_returned  = sendReturned;
   outResult.requested_price      = tradeRequest.price;
   outResult.submission_timestamp = TimeCurrent();

   if(!sendReturned)
   {
      outResult.submission_status  = SUBMISSION_STATUS_ERROR;
      outResult.terminal_last_error = GetLastError();
      outResult.reason_code         = REASON_ERROR_INTERNAL;

      string errJson = ExecutionSubmissionResult_ToExtraJson(outResult);
      if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_ORDER_SUBMISSION_ERROR), "order send returned false", errJson))
         return false;

      // candidate.state stays CANDIDATE_CREATED - untouched. Nothing was
      // actually submitted; retry-ability is preserved for a later,
      // separately-authorized retry commit.
      return true;
   }

   outResult.retcode              = tradeResult.retcode;
   outResult.retcode_external     = tradeResult.retcode_external;
   outResult.request_id           = tradeResult.request_id;
   outResult.order_ticket         = tradeResult.order;
   outResult.deal_ticket          = tradeResult.deal;
   outResult.observed_submit_price = tradeResult.price;

   // Reached the server - CREATED -> SUBMITTED is always legal here,
   // regardless of what retcode classification below decides next.
   if(!EventStore_LogTransition(candidate, CANDIDATE_SUBMITTED, REASON_SUBMITTED_OK, ""))
      return false; // SafeMode already tripped inside EventStore_LogTransition

   ENUM_REASON_CODE classifyReason;
   bool accepted = BrokerSubmission_ClassifyRetcode(tradeResult.retcode, classifyReason);
   outResult.reason_code = classifyReason;

   if(accepted)
   {
      outResult.submission_status = SUBMISSION_STATUS_SUBMITTED;
      string subJson = ExecutionSubmissionResult_ToExtraJson(outResult);
      if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_ORDER_SUBMITTED), "order submitted", subJson))
         return false; // CANDIDATE_SUBMITTED already durable and NOT rolled back

      // candidate.state stays CANDIDATE_SUBMITTED - no further transition
      // here. Resting state pending a later, separately-authorized
      // OnTradeTransaction reconciliation commit.
      return true;
   }

   outResult.submission_status = SUBMISSION_STATUS_REJECTED;
   string rejJson = ExecutionSubmissionResult_ToExtraJson(outResult);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_ORDER_REJECTED), "order rejected", rejJson))
      return false; // CANDIDATE_SUBMITTED already durable and NOT rolled back

   if(!EventStore_LogTransition(candidate, CANDIDATE_REJECTED_BY_BROKER, classifyReason, ""))
      return false; // ORDER_REJECTED already durable and NOT rolled back; SafeMode already tripped

   return true;
}

#endif // __MLQUANTAI_BROKERSUBMISSIONADAPTER_MQH__
