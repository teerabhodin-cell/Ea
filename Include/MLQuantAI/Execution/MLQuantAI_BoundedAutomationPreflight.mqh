//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BoundedAutomationPreflight.mqh    |
//| C5.2 §6.3 Design Contract Rev.15 (FROZEN, commit 07a3581),          |
//| D7 / F1c pre-flight parity. R15-B slice.                            |
//|                                                                    |
//| PRE-FLIGHT PARITY (SUBMIT_ORDER only): the exact checks the sealed  |
//| SubmitOrderCommand() makes BEFORE E1 (MLQuantAI.mq5:1225-1243), in  |
//| the same order, from the same input (the command's                  |
//| target_execution_request_id), resolving the candidate the same way  |
//| (rec.candidate_id of the request record found by id - never a       |
//| candidate_id supplied by discovery) (QA Q-B1 (a)):                  |
//|   1. CeremonyCommandRegistry_HasUnresolvedSubmission() == true      |
//|   2. ExecutionRequestProjection_TryGet(target id, rec) fails        |
//|   3. CandidateProjection_TryGet(rec.candidate_id) fails             |
//|   4. StateProjector_TryGetState(rec.candidate_id) fails             |
//| Any of them -> issue nothing this invocation. A SUBMIT the Decision |
//| Engine issues therefore cannot be rejected by these checks, which   |
//| removes the pre-E1 re-issue loop (F1c).                              |
//|                                                                    |
//| Read-only: sealed accessors only. No EventStore write, no mailbox   |
//| write, no registry/projection mutation, no OrderSend, no new        |
//| dispatch path, no new policy. GRANT_MANUAL_APPROVAL never calls it  |
//| (D7 option (i)).                                                     |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BOUNDEDAUTOMATIONPREFLIGHT_MQH__
#define __MLQUANTAI_BOUNDEDAUTOMATIONPREFLIGHT_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_CeremonyCommandEventEmission.mqh"
#include "MLQuantAI_ExecutionAuditProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_StateProjector.mqh"

// Diagnostic sub-reason. At the issuance level every non-PASS value is
// the single outcome NOT_ATTEMPTED_PREFLIGHT.
enum ENUM_BOUNDED_AUTOMATION_PREFLIGHT
{
   BOUNDED_AUTOMATION_PREFLIGHT_PASS,
   BOUNDED_AUTOMATION_PREFLIGHT_UNRESOLVED_SUBMISSION,     // 1 - "unresolved_submission_attempt_exists"
   BOUNDED_AUTOMATION_PREFLIGHT_REQUEST_NOT_FOUND,         // 2 - "execution_request_not_found"
   BOUNDED_AUTOMATION_PREFLIGHT_CANDIDATE_NOT_FOUND,       // 3 - "candidate_projection_not_found"
   BOUNDED_AUTOMATION_PREFLIGHT_CANDIDATE_STATE_NOT_FOUND  // 4 - "candidate_state_not_found"
};

string BoundedAutomationPreflight_ToString(ENUM_BOUNDED_AUTOMATION_PREFLIGHT p)
{
   switch(p)
   {
      case BOUNDED_AUTOMATION_PREFLIGHT_PASS:                      return "PASS";
      case BOUNDED_AUTOMATION_PREFLIGHT_UNRESOLVED_SUBMISSION:     return "UNRESOLVED_SUBMISSION";
      case BOUNDED_AUTOMATION_PREFLIGHT_REQUEST_NOT_FOUND:         return "REQUEST_NOT_FOUND";
      case BOUNDED_AUTOMATION_PREFLIGHT_CANDIDATE_NOT_FOUND:       return "CANDIDATE_NOT_FOUND";
      case BOUNDED_AUTOMATION_PREFLIGHT_CANDIDATE_STATE_NOT_FOUND: return "CANDIDATE_STATE_NOT_FOUND";
   }
   return "UNKNOWN";
}

//---------------------------------------------------------------------
// D7 pre-flight parity for a SUBMIT_ORDER targeting executionRequestId.
// outCandidateId is the rec.candidate_id the checks resolved (diagnostic;
// "" when the request itself was not found or not reached).
//---------------------------------------------------------------------
ENUM_BOUNDED_AUTOMATION_PREFLIGHT BoundedAutomation_PreflightSubmit(string executionRequestId, string &outCandidateId)
{
   outCandidateId = "";

   if(CeremonyCommandRegistry_HasUnresolvedSubmission())
      return BOUNDED_AUTOMATION_PREFLIGHT_UNRESOLVED_SUBMISSION;

   ExecutionRequestProjectionRecord rec;
   if(!ExecutionRequestProjection_TryGet(executionRequestId, rec))
      return BOUNDED_AUTOMATION_PREFLIGHT_REQUEST_NOT_FOUND;
   outCandidateId = rec.candidate_id;

   CandidateProjectionRecord candRec;
   if(!CandidateProjection_TryGet(rec.candidate_id, candRec))
      return BOUNDED_AUTOMATION_PREFLIGHT_CANDIDATE_NOT_FOUND;

   ENUM_CANDIDATE_STATE liveState;
   if(!StateProjector_TryGetState(rec.candidate_id, liveState))
      return BOUNDED_AUTOMATION_PREFLIGHT_CANDIDATE_STATE_NOT_FOUND;

   return BOUNDED_AUTOMATION_PREFLIGHT_PASS;
}

#endif // __MLQUANTAI_BOUNDEDAUTOMATIONPREFLIGHT_MQH__
