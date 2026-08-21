//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_ExecutionSubmissionContract.mqh  |
//| Phase C2.2: ExecutionSubmissionResult - the frozen shape from     |
//| Docs/PhaseC_C2_1_BrokerSubmissionContract.md. Deliberately NOT a  |
//| reuse of the dormant Phase-A/pre-B ExecutionResult (no lineage    |
//| fields, conflates submit-acknowledgement with fill truth) or of   |
//| C1.2's DryRunExecutionResult (a dry-run verdict, never a broker    |
//| fact). No fill_price/slippage_points field anywhere - those are   |
//| transaction-derived facts owned exclusively by the later, not-yet-|
//| authorized OnTradeTransaction reconciliation commit.               |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EXECUTIONSUBMISSIONCONTRACT_MQH__
#define __MLQUANTAI_EXECUTIONSUBMISSIONCONTRACT_MQH__

#include "../Core/MLQuantAI_ContractVersions.mqh"
#include "../Core/MLQuantAI_Enums.mqh"
#include "../Core/MLQuantAI_ReasonCodes.mqh"

struct ExecutionSubmissionResult
{
   string execution_submission_result_schema_version; // MLQUANTAI_EXECUTION_SUBMISSION_RESULT_SCHEMA_C2_V1

   string execution_request_id;   // verbatim - links back to the request
   string execution_request_hash; // verbatim
   string correlation_id;         // verbatim - the same value written to candidate.correlation_id
   int    submit_attempt;         // always 1 in C2 - no retry logic

   ENUM_SUBMISSION_STATUS submission_status;
   bool   order_send_returned;  // OrderSend()'s own bool return
   int    terminal_last_error;  // GetLastError() when order_send_returned == false
   uint   retcode;              // result.retcode
   int    retcode_external;     // result.retcode_external
   long   request_id;           // result.request_id - SESSION-SCOPED ONLY, never a durable identity/lookup key
   ulong  order_ticket;         // result.order
   ulong  deal_ticket;          // result.deal
   double requested_price;         // the price actually sent in the request
   double observed_submit_price;   // result.price (server-reported) - NOT a fill guarantee
   datetime submission_timestamp;  // TimeCurrent() at the OrderSend() call

   ENUM_REASON_CODE reason_code;
};

void ExecutionSubmissionResult_Init(ExecutionSubmissionResult &r)
{
   r.execution_submission_result_schema_version = MLQUANTAI_EXECUTION_SUBMISSION_RESULT_SCHEMA_C2_V1;

   r.execution_request_id = "";
   r.execution_request_hash = "";
   r.correlation_id = "";
   r.submit_attempt = 0;

   r.submission_status = SUBMISSION_STATUS_NONE;
   r.order_send_returned = false;
   r.terminal_last_error = 0;
   r.retcode = 0;
   r.retcode_external = 0;
   r.request_id = 0;
   r.order_ticket = 0;
   r.deal_ticket = 0;
   r.requested_price = 0;
   r.observed_submit_price = 0;
   r.submission_timestamp = 0;

   r.reason_code = REASON_NONE;
}

#endif // __MLQUANTAI_EXECUTIONSUBMISSIONCONTRACT_MQH__
