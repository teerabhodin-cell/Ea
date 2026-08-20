//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_ExecutionRequestEventEmission.mqh |
//| Phase C1.2: ExecutionRequest -> EVENT_TYPE_EXECUTION_REQUEST_CREATED|
//| -> SafetyGate_Evaluate -> EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED -> |
//| EventStore append. Per                                             |
//| Docs/PhaseC_C1_1_ExecutionRequestContract.md's C1.2 addendum. No    |
//| broker/order/history/tick call anywhere, no candidate.state         |
//| transition of any kind (dry-run is purely observational - the      |
//| candidate stays at CANDIDATE_CREATED throughout C1), no fake        |
//| ticket/retcode/fill_price/slippage_points field anywhere - this is  |
//| not a broker response.                                              |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EXECUTIONREQUESTEVENTEMISSION_MQH__
#define __MLQUANTAI_EXECUTIONREQUESTEVENTEMISSION_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "MLQuantAI_SafetyGate.mqh"

string ExecutionRequest_ToExtraJson(const ExecutionRequest &r)
{
   string s = "";
   s += "\"execution_request_schema_version\":\"" + EventSerializer_Escape(r.execution_request_schema_version) + "\",";
   s += "\"execution_request_id\":\""               + EventSerializer_Escape(r.execution_request_id) + "\",";
   s += "\"execution_request_hash\":\""              + EventSerializer_Escape(r.execution_request_hash) + "\",";
   s += "\"candidate_id\":\""                          + EventSerializer_Escape(r.candidate_id) + "\",";
   s += "\"candidate_hash\":\""                          + EventSerializer_Escape(r.candidate_hash) + "\",";
   s += "\"risk_plan_id\":\""                              + EventSerializer_Escape(r.risk_plan_id) + "\",";
   s += "\"plan_hash\":\""                                   + EventSerializer_Escape(r.plan_hash) + "\",";
   s += "\"ai_decision_id\":\""                                + EventSerializer_Escape(r.ai_decision_id) + "\",";
   s += "\"ai_decision_hash\":\""                                + EventSerializer_Escape(r.ai_decision_hash) + "\",";
   s += "\"eligibility_decision_id\":\""                           + EventSerializer_Escape(r.eligibility_decision_id) + "\",";
   s += "\"eligibility_decision_hash\":\""                           + EventSerializer_Escape(r.eligibility_decision_hash) + "\",";
   s += "\"execution_policy_version\":\""                              + EventSerializer_Escape(r.execution_policy_version) + "\",";
   s += "\"correlation_id\":\""                                          + EventSerializer_Escape(r.correlation_id) + "\",";
   s += "\"submit_attempt\":"                                              + IntegerToString(r.submit_attempt) + ",";
   s += "\"side\":\""                                                       + (r.side == ORDER_TYPE_BUY ? "BUY" : "SELL") + "\",";
   s += "\"planned_entry\":"                                                  + CanonicalPrice(r.planned_entry) + ",";
   s += "\"planned_sl\":"                                                       + CanonicalPrice(r.planned_sl) + ",";
   s += "\"planned_tp\":"                                                        + CanonicalPrice(r.planned_tp) + ",";
   s += "\"lot_size\":"                                                            + CanonicalDouble(r.lot_size) + ",";
   s += "\"risk_amount\":"                                                          + CanonicalDouble(r.risk_amount);
   return s;
}

string DryRunExecutionResult_ToExtraJson(const DryRunExecutionResult &d)
{
   string s = "";
   s += "\"dry_run_result_schema_version\":\"" + EventSerializer_Escape(d.dry_run_result_schema_version) + "\",";
   s += "\"execution_request_id\":\""             + EventSerializer_Escape(d.execution_request_id) + "\",";
   s += "\"execution_request_hash\":\""              + EventSerializer_Escape(d.execution_request_hash) + "\",";
   s += "\"decision\":\""                              + SafetyGateDecisionToString(d.decision) + "\",";
   s += "\"reason_code\":\""                             + ReasonCodeToString(d.reason_code) + "\",";
   s += "\"observed_symbol\":\""                           + EventSerializer_Escape(d.observed_symbol) + "\",";
   s += "\"observed_account_login\":"                        + IntegerToString(d.observed_account_login);
   return s;
}

// The C1.2 boundary function. Emits EVENT_TYPE_EXECUTION_REQUEST_CREATED
// for every valid request (gate: non-empty execution_request_id - a
// failed ExecutionRequest_Build never reaches here at all, per its own
// contract), then evaluates SafetyGate, then emits
// EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED (ACCEPTED and REJECTED both -
// audit evidence either way). Never emits any candidate-lifecycle
// event, never calls EventStore_LogTransition - dry-run never touches
// candidate.state.
//
// Returns false, with no write attempted, if
// request.execution_request_id == "" (a failed ExecutionRequest_Build) -
// same "no partial record" rule every prior emitter follows.
//
// Failure-mode rule (same non-rollback discipline B9 Commit 2
// established): if the EXECUTION_REQUEST_CREATED write succeeds but the
// subsequent EXECUTION_DRY_RUN_COMPLETED write fails, this function
// returns false, but the already-durable EXECUTION_REQUEST_CREATED line
// is NEVER rolled back, rewritten, or deleted - the event store is
// append-only. The caller must treat a false return as "the request is
// durably recorded, but its dry-run result may not be" - never as
// "nothing happened."
bool ExecutionRequest_EmitAndEvaluate(const ExecutionRequest &request, const ExecutionPolicy &policy,
                                        DryRunExecutionResult &outResult)
{
   DryRunExecutionResult_Init(outResult);

   if(request.execution_request_id == "") return false;

   string requestJson = ExecutionRequest_ToExtraJson(request);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_REQUEST_CREATED), "execution request created", requestJson))
      return false;

   if(!SafetyGate_Evaluate(request, policy, outResult))
      return false; // structural failure inside SafetyGate_Evaluate itself - should be unreachable given the gate above, but never silently swallowed

   string resultJson = DryRunExecutionResult_ToExtraJson(outResult);
   return EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED), "execution dry-run completed", resultJson);
}

#endif // __MLQUANTAI_EXECUTIONREQUESTEVENTEMISSION_MQH__
