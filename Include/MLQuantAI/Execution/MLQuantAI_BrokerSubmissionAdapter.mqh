//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BrokerSubmissionAdapter.mqh      |
//| Phase C2.2: BrokerSubmission_Submit() - the real OrderSend         |
//| orchestration boundary from                                        |
//| Docs/PhaseC_C2_1_BrokerSubmissionContract.md's lifecycle diagram.  |
//| THIS FILE CALLS THE REAL OrderSend() AND, ON A REAL DEMO ACCOUNT,  |
//| WILL OPEN A REAL POSITION.                                          |
//|                                                                     |
//| C2.2 amendment (post-PASSED, real user review): the event-          |
//| sequencing/state-transition orchestration around the OrderSend      |
//| call had ZERO automated test coverage, because it lived entirely    |
//| inside the one function nobody may call from the automated suite.   |
//| Split into BrokerSubmission_ProcessSendResult() - pure, takes        |
//| orderSendReturned/terminalLastError/tradeResult as ALREADY-COMPUTED |
//| INPUT parameters, never calls OrderSend itself, fully unit-testable |
//| for every branch (true+DONE, true+DONE_PARTIAL, explicit rejection  |
//| retcodes, false+error, true+CONNECTION/unknown retcode) - and        |
//| BrokerSubmission_Submit(), now a thin wrapper that does ONLY the     |
//| real OrderSend() call and delegates everything else to               |
//| ProcessSendResult. The automated regression suite                    |
//| (Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5) exercises        |
//| BrokerSubmissionGate_Evaluate/BrokerSubmission_BuildTradeRequest/     |
//| BrokerSubmission_ClassifyRetcode/BrokerSubmission_ProcessSendResult   |
//| directly - none of these touch OrderSend. ONLY BrokerSubmission_     |
//| Submit() itself calls the real OrderSend() - the automated suite     |
//| MUST NEVER call it; only the separate, explicitly opt-in real-       |
//| submit smoke test may, run manually by the user.                     |
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

// MqlTradeResult also contains a string member (comment) - same
// ZeroMemory pitfall as MqlTradeRequest_ZeroInit above, same fix.
void MqlTradeResult_ZeroInit(MqlTradeResult &r)
{
   r.retcode           = 0;
   r.deal              = 0;
   r.order             = 0;
   r.volume            = 0;
   r.price             = 0;
   r.bid               = 0;
   r.ask               = 0;
   r.comment           = "";
   r.request_id        = 0;
   r.retcode_external  = 0;
}

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

// Pure orchestration core - no OrderSend call anywhere in this function.
// Takes the real OrderSend() call's own outcome as already-computed
// input (orderSendReturned/terminalLastError/tradeResult), so every
// branch of the frozen C2.1 lifecycle can be exercised by the
// automated regression suite with fabricated inputs, with zero risk
// of ever touching a real broker. Assumes the caller already ran the
// pre-submit gate + build successfully (candidate/request/tradeResult
// are assumed consistent - BrokerSubmission_Submit is the only real
// caller and guarantees this).
bool BrokerSubmission_ProcessSendResult(TradeCandidate &candidate, const ExecutionRequest &request,
                                          double requestedPrice, bool orderSendReturned, int terminalLastError,
                                          datetime submissionTimestamp, const MqlTradeResult &tradeResult,
                                          ExecutionSubmissionResult &outResult)
{
   ExecutionSubmissionResult_Init(outResult);
   outResult.execution_request_id   = request.execution_request_id;
   outResult.execution_request_hash = request.execution_request_hash;
   outResult.correlation_id         = request.correlation_id;
   outResult.submit_attempt         = request.submit_attempt;

   // Crossed the final gate - audit the intent BEFORE any broker claim.
   // First-ever write to candidate.correlation_id.
   candidate.correlation_id = request.correlation_id;
   string attemptJson = ExecutionSubmissionAttempt_ToExtraJson(request.execution_request_id, request.execution_request_hash,
                                                                  request.correlation_id, request.submit_attempt);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED), "execution submission attempted", attemptJson))
      return false; // could not durably record intent - abort before "sending" is considered to have happened

   BrokerSubmissionGate_MarkAttempted(request.execution_request_id);

   outResult.order_send_returned  = orderSendReturned;
   outResult.requested_price      = requestedPrice;
   outResult.submission_timestamp = submissionTimestamp;

   if(!orderSendReturned)
   {
      outResult.submission_status  = SUBMISSION_STATUS_ERROR;
      outResult.terminal_last_error = terminalLastError;
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

// The thin, real-world wrapper. THIS is the only function anywhere in
// this codebase that calls the real OrderSend(). Everything else is
// delegated to BrokerSubmission_ProcessSendResult.
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

   MqlTradeResult tradeResult;
   MqlTradeResult_ZeroInit(tradeResult);
   bool sendReturned = OrderSend(tradeRequest, tradeResult);
   // GetLastError() must be read immediately after OrderSend(), before
   // any other runtime call could overwrite it - captured here, in the
   // thin wrapper, and handed to ProcessSendResult as a plain value.
   int lastError = sendReturned ? 0 : GetLastError();
   datetime ts = TimeCurrent();

   return BrokerSubmission_ProcessSendResult(candidate, request, tradeRequest.price, sendReturned, lastError, ts, tradeResult, outResult);
}

#endif // __MLQUANTAI_BROKERSUBMISSIONADAPTER_MQH__
