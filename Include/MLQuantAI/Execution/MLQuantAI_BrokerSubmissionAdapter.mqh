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
//| for every branch - and BrokerSubmission_Submit(), now a thin wrapper|
//| that does ONLY the real OrderSend() call and delegates everything   |
//| else.                                                                |
//|                                                                       |
//| C2.2 SECOND amendment (post-PASSED, real user review - a real        |
//| regression this session introduced, not a pre-existing design gap):  |
//| the first amendment's split accidentally moved the                   |
//| EXECUTION_SUBMISSION_ATTEMPTED durable write to AFTER the real        |
//| OrderSend() call (inside ProcessSendResult, which the wrapper calls   |
//| only once OrderSend already returned) - directly violating the        |
//| frozen C2.1 lifecycle, which requires that write to happen BEFORE     |
//| OrderSend is ever called ("crossed the final gate, no broker claim    |
//| yet"). Fixed by extracting BrokerSubmission_RecordAttempt() - does    |
//| the durable write + correlation_id assignment + idempotency mark,     |
//| called by the wrapper BEFORE OrderSend; if it fails, OrderSend is     |
//| NEVER called, no candidate mutation, no idempotency mark. Also adds   |
//| a third classification outcome, SUBMISSION_STATUS_UNKNOWN (see        |
//| MLQuantAI_BrokerSubmissionBuilder.mqh) - the candidate is NEVER        |
//| transitioned for that outcome, exactly like the OrderSend()==false     |
//| case. See Docs/PhaseC_C2_1_BrokerSubmissionContract.md's second        |
//| amendment.                                                             |
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
//|                                                                     |
//| THIRD amendment (C2 manual-approval contract, gate integration      |
//| round): a real wiring gap found while implementing that round -     |
//| this function called BrokerSubmissionGate_Evaluate() directly,       |
//| never BrokerSubmissionEnvironmentLock_Evaluate(), so neither the     |
//| environment-lock round's five checks nor the new manual-approval     |
//| check ever actually gated a real submission. Fixed, per the user's   |
//| explicit authorization: BrokerSubmission_Submit() now takes an       |
//| EnvironmentLockPolicy parameter and calls                            |
//| BrokerSubmissionEnvironmentLock_Evaluate() instead - see              |
//| Docs/PhaseC_C2_ManualApprovalContract.md's "A real wiring gap found  |
//| while implementing this round" section.                              |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BROKERSUBMISSIONADAPTER_MQH__
#define __MLQUANTAI_BROKERSUBMISSIONADAPTER_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "MLQuantAI_BrokerSubmissionGate.mqh"
#include "MLQuantAI_BrokerSubmissionBuilder.mqh"
#include "MLQuantAI_ExecutionSubmissionContract.mqh"
#include "MLQuantAI_EnvironmentLockGate.mqh"

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

// Step 2-4 of the frozen sequence: durable pre-side-effect audit fact,
// written BEFORE OrderSend is ever called. No broker fields (retcode/
// ticket/deal/fill) anywhere in its payload - it cannot claim anything
// about a broker, because nothing has been sent yet. Sets
// candidate.correlation_id (first-ever write to that field) only if the
// write succeeds; marks the in-session idempotency guard only after
// the durable write is confirmed. Returns false on write failure - the
// caller MUST NOT call OrderSend, mutate the candidate, or mark the
// idempotency guard in that case.
bool BrokerSubmission_RecordAttempt(TradeCandidate &candidate, const ExecutionRequest &request)
{
   string attemptJson = ExecutionSubmissionAttempt_ToExtraJson(request.execution_request_id, request.execution_request_hash,
                                                                  request.correlation_id, request.submit_attempt);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED), "execution submission attempted", attemptJson))
      return false; // could not durably record intent - caller must never call OrderSend after this

   candidate.correlation_id = request.correlation_id;
   BrokerSubmissionGate_MarkAttempted(request.execution_request_id);
   return true;
}

// Step 6 of the frozen sequence: pure orchestration, no OrderSend call
// anywhere in this function. Takes the real OrderSend() call's own
// outcome as already-computed input (orderSendReturned/terminalLastError/
// tradeResult), so every branch is exercisable by the automated
// regression suite with fabricated inputs, with zero risk of ever
// touching a real broker. Assumes BrokerSubmission_RecordAttempt already
// succeeded for this exact request (BrokerSubmission_Submit is the only
// real caller and guarantees the ordering).
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
   outResult.order_send_returned    = orderSendReturned;
   outResult.requested_price        = requestedPrice;
   outResult.submission_timestamp   = submissionTimestamp;

   if(!orderSendReturned)
   {
      // A provable local/pre-dispatch failure: MQL5's own OrderSend()
      // reference documents false as "successful basic check of
      // structures" failing - the request never reached the server, a
      // genuinely bounded, local condition, distinct from the true+
      // retcode surface entirely. terminalLastError (GetLastError(),
      // captured immediately after the call, per MQL5's general
      // error-handling convention - not something OrderSend()'s own
      // page walks through, but the standard mechanism for any failed
      // MQL5 call) is a real, persisted diagnostic, not a guess.
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

   ENUM_REASON_CODE classifyReason;
   ENUM_SUBMISSION_STATUS classification = BrokerSubmission_ClassifyRetcode(tradeResult.retcode, classifyReason);
   outResult.reason_code = classifyReason;

   if(classification == SUBMISSION_STATUS_UNKNOWN)
   {
      // Neither an explicit acceptance nor an explicit rejection - no
      // real acknowledgment happened. candidate.state stays
      // CANDIDATE_CREATED, exactly like the OrderSend()==false case -
      // NO CREATED -> SUBMITTED transition here, unlike the original
      // (pre-second-amendment) design.
      outResult.submission_status = SUBMISSION_STATUS_UNKNOWN;
      string unkJson = ExecutionSubmissionResult_ToExtraJson(outResult);
      if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_SUBMISSION_UNKNOWN), "execution submission unknown", unkJson))
         return false;
      return true;
   }

   // Both SUBMITTED and REJECTED require the mandatory SUBMITTED
   // waypoint, per the sealed state machine (REJECTED_BY_BROKER is
   // reachable only from SUBMITTED, never CREATED).
   if(!EventStore_LogTransition(candidate, CANDIDATE_SUBMITTED, REASON_SUBMITTED_OK, ""))
      return false; // SafeMode already tripped inside EventStore_LogTransition

   if(classification == SUBMISSION_STATUS_SUBMITTED)
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
// this codebase that calls the real OrderSend(). The mandatory sequence
// is: final gate re-validation -> build -> RecordAttempt (durable write,
// MUST succeed) -> OrderSend -> ProcessSendResult. If RecordAttempt
// fails, OrderSend is never called.
//
// lockPolicy is new as of the third amendment above - the final gate
// re-validation now runs the FULL BrokerSubmissionEnvironmentLock_Evaluate
// chain (C1/C2 structural checks -> audit readiness -> no-prior-attempt
// -> server/terminal/account/expert/volume checks -> manual-approval
// readiness -> HasValidApproval), not just the earlier BrokerSubmissionGate_Evaluate
// subset.
bool BrokerSubmission_Submit(TradeCandidate &candidate, const ExecutionRequest &request, const ExecutionPolicy &policy,
                               const EnvironmentLockPolicy &lockPolicy, ExecutionSubmissionResult &outResult)
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
   if(!BrokerSubmissionEnvironmentLock_Evaluate(request, policy, lockPolicy, gateResult))
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

   if(!BrokerSubmission_RecordAttempt(candidate, request))
      return false; // durable attempt write failed - OrderSend is NEVER called

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
