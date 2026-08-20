//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_ExecutionRequestBuilder.mqh       |
//| Phase C1.2: ExecutionRequest_Build() - pure mapping from an        |
//| ELIGIBLE EligibilityDecision + the RiskPlan/AIDecision/TradeCandidate|
//| it was built from, plus an explicit, versioned ExecutionPolicy, to |
//| an immutable ExecutionRequest. Per                                 |
//| Docs/PhaseC_C1_1_ExecutionRequestContract.md's C1.2 addendum. No    |
//| live account/tick/broker/SafeMode call, no event emission, no      |
//| state-machine transition, no mutation of any input, no execution.  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EXECUTIONREQUESTBUILDER_MQH__
#define __MLQUANTAI_EXECUTIONREQUESTBUILDER_MQH__

#include "MLQuantAI_ExecutionRequestContract.mqh"
#include "MLQuantAI_EligibilityContract.mqh"
#include "../Core/MLQuantAI_RiskPlan.mqh"
#include "../Core/MLQuantAI_TradeCandidate.mqh"
#include "../AI/MLQuantAI_AIDecisionContract.mqh"

// Fail-closed ladder (mirrors EligibilityDecision_Build's own style):
// ELIGIBLE-only gate -> boundary checks -> 4-way lineage cross-check ->
// policy shape -> build. On any failure, outRequest is left at
// ExecutionRequest_Init() defaults - no partial record, no event ever
// emitted for a request that failed to build (see
// ExecutionRequest_EmitAndEvaluate for the emission boundary).
bool ExecutionRequest_Build(const TradeCandidate &candidate, const EligibilityDecision &eligibility,
                              const AIDecision &aiDecision, const RiskPlan &plan, const ExecutionPolicy &policy,
                              ExecutionRequest &outRequest, string &outReasonDetail)
{
   ExecutionRequest_Init(outRequest);
   outReasonDetail = "";

   if(eligibility.decision != ELIGIBILITY_DECISION_ELIGIBLE)
   {
      outReasonDetail = "EligibilityDecision.decision is not ELIGIBLE - a REJECTED decision never becomes an ExecutionRequest";
      return false;
   }

   if(eligibility.eligibility_decision_id == "")
   {
      outReasonDetail = "EligibilityDecision.eligibility_decision_id is empty - not a built decision";
      return false;
   }

   if(plan.risk_plan_id == "")
   {
      outReasonDetail = "RiskPlan.risk_plan_id is empty - not an allowed plan";
      return false;
   }

   if(aiDecision.ai_decision_id == "")
   {
      outReasonDetail = "AIDecision.ai_decision_id is empty - not a built decision";
      return false;
   }

   if(candidate.candidate_id == "" || candidate.candidate_hash == "")
   {
      outReasonDetail = "TradeCandidate.candidate_id/candidate_hash is empty";
      return false;
   }

   // 4-way lineage cross-check - candidate/plan/AI-decision/eligibility-
   // decision must all agree on candidate_id/candidate_hash.
   if(candidate.candidate_id != plan.candidate_id || candidate.candidate_hash != plan.candidate_hash)
   {
      outReasonDetail = "TradeCandidate and RiskPlan do not agree on candidate_id/candidate_hash";
      return false;
   }
   if(plan.candidate_id != aiDecision.candidate_id || plan.candidate_hash != aiDecision.candidate_hash)
   {
      outReasonDetail = "RiskPlan and AIDecision do not agree on candidate_id/candidate_hash";
      return false;
   }
   if(aiDecision.candidate_id != eligibility.candidate_id || aiDecision.candidate_hash != eligibility.candidate_hash)
   {
      outReasonDetail = "AIDecision and EligibilityDecision do not agree on candidate_id/candidate_hash";
      return false;
   }

   // Cross-check the EligibilityDecision itself was actually built from
   // THIS RiskPlan/AIDecision, not merely the same candidate.
   if(eligibility.risk_plan_id != plan.risk_plan_id || eligibility.plan_hash != plan.plan_hash)
   {
      outReasonDetail = "EligibilityDecision does not reference this RiskPlan (risk_plan_id/plan_hash mismatch)";
      return false;
   }
   if(eligibility.ai_decision_id != aiDecision.ai_decision_id || eligibility.ai_decision_hash != aiDecision.ai_decision_hash)
   {
      outReasonDetail = "EligibilityDecision does not reference this AIDecision (ai_decision_id/ai_decision_hash mismatch)";
      return false;
   }

   if(policy.execution_policy_version == "")
   {
      outReasonDetail = "ExecutionPolicy.execution_policy_version is empty";
      return false;
   }

   outRequest.candidate_id   = candidate.candidate_id;
   outRequest.candidate_hash = candidate.candidate_hash;

   outRequest.risk_plan_id = plan.risk_plan_id;
   outRequest.plan_hash    = plan.plan_hash;

   outRequest.ai_decision_id   = aiDecision.ai_decision_id;
   outRequest.ai_decision_hash = aiDecision.ai_decision_hash;

   outRequest.eligibility_decision_id   = eligibility.eligibility_decision_id;
   outRequest.eligibility_decision_hash = eligibility.eligibility_decision_hash;

   outRequest.execution_policy_version = policy.execution_policy_version;

   outRequest.submit_attempt = 1; // C1.2: always 1, never auto-incremented
   outRequest.correlation_id = Ids_CorrelationId(candidate.candidate_id, outRequest.submit_attempt);

   outRequest.side          = candidate.side;
   outRequest.planned_entry = plan.planned_entry;
   outRequest.planned_sl    = plan.planned_sl;
   outRequest.planned_tp    = plan.planned_tp;
   outRequest.lot_size      = plan.lot_size;
   outRequest.risk_amount   = plan.risk_amount;

   outRequest.execution_request_id = Ids_ExecutionRequestId(outRequest.candidate_id, outRequest.eligibility_decision_id,
                                                              outRequest.ai_decision_id, outRequest.risk_plan_id,
                                                              outRequest.execution_policy_version);
   outRequest.execution_request_hash = ExecutionRequest_ComputeHash(outRequest);

   return true;
}

#endif // __MLQUANTAI_EXECUTIONREQUESTBUILDER_MQH__
