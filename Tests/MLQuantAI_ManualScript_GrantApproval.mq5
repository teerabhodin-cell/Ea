//+------------------------------------------------------------------+
//| MLQuantAI_ManualScript_GrantApproval.mq5                          |
//| C2 manual-approval contract - the standalone, human-run script     |
//| that is the ONLY writer of EXECUTION_MANUAL_APPROVAL_GRANTED       |
//| events. Per Docs/PhaseC_C2_ManualApprovalContract.md.              |
//|                                                                    |
//| A human runs this manually, once, per approval, after observing   |
//| the pending candidate's execution_request_id/hash/policy_version/  |
//| candidate_id/correlation_id wherever the EA's own logs/event       |
//| store display them. This script never reads the event store       |
//| itself to discover those values - they are typed/pasted in by the |
//| operator, deliberately, as the human act of approval.              |
//|                                                                    |
//| *** NEVER calls OrderSend/CTrade or any broker-mutating API. The   |
//| *** only side effect is one durable, append-only event write -     |
//| *** identical in kind to every other *_EventEmission.mqh caller    |
//| *** in this project. Does not imply, by itself, that anything is   |
//| *** submitted: the deferred C2 gate integration is what actually   |
//| *** consults this grant before any real submission is attempted.  |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

input string I_EventStoreFileName        = ""; // REQUIRED - must exactly match the live EA's own event store file (Common Files); blank aborts
input string I_ExecutionRequestId        = ""; // REQUIRED - execution_request_id of the candidate being approved
input string I_ExecutionRequestHash      = ""; // REQUIRED - execution_request_hash of the candidate being approved
input string I_ExecutionPolicyVersion    = ""; // REQUIRED - execution_policy_version the request was built under
input string I_CandidateId               = ""; // REQUIRED - candidate_id of the candidate being approved
input string I_CorrelationId             = ""; // REQUIRED - correlation_id of the candidate being approved
input string I_ApproverIdentity          = ""; // REQUIRED - who is granting this approval (name/handle) - never blank
input int    I_ValidityWindowMinutes     = 15;  // approval_expiry = approval_timestamp + this many minutes; must be > 0

#include <MLQuantAI/Execution/MLQuantAI_ManualApprovalEmission.mqh>

bool ValidateInputs()
{
   if(I_EventStoreFileName == "")     { Print("ABORTED: I_EventStoreFileName is blank - must exactly match the live EA's own event store file."); return false; }
   if(I_ExecutionRequestId == "")     { Print("ABORTED: I_ExecutionRequestId is blank."); return false; }
   if(I_ExecutionRequestHash == "")   { Print("ABORTED: I_ExecutionRequestHash is blank."); return false; }
   if(I_ExecutionPolicyVersion == "") { Print("ABORTED: I_ExecutionPolicyVersion is blank."); return false; }
   if(I_CandidateId == "")            { Print("ABORTED: I_CandidateId is blank."); return false; }
   if(I_CorrelationId == "")          { Print("ABORTED: I_CorrelationId is blank."); return false; }
   if(I_ApproverIdentity == "")       { Print("ABORTED: I_ApproverIdentity is blank - an anonymous approval is not a real approval."); return false; }
   if(I_ValidityWindowMinutes <= 0)   { Print("ABORTED: I_ValidityWindowMinutes must be > 0."); return false; }
   return true;
}

void OnStart()
{
   Print("=== MLQuantAI C2 manual-approval grant script ===");
   Print("*** This script never calls OrderSend/CTrade. It only appends one durable approval-fact event. ***");

   if(!ValidateInputs())
      return;

   if(!FileIsExist(I_EventStoreFileName, FILE_COMMON))
   {
      Print("ABORTED: event store file '", I_EventStoreFileName, "' does not exist in Common Files - refusing to create a new one for an approval grant.");
      return;
   }

   if(!EventStore_Open(I_EventStoreFileName))
   {
      Print("ABORTED: could not open event store file '", I_EventStoreFileName, "'.");
      return;
   }

   ManualApprovalGrant grant;
   ManualApprovalGrant_Init(grant);
   grant.execution_request_id     = I_ExecutionRequestId;
   grant.execution_request_hash   = I_ExecutionRequestHash;
   grant.execution_policy_version = I_ExecutionPolicyVersion;
   grant.candidate_id             = I_CandidateId;
   grant.correlation_id           = I_CorrelationId;
   grant.approver_identity        = I_ApproverIdentity;
   grant.approval_timestamp       = TimeCurrent();
   grant.approval_expiry          = grant.approval_timestamp + I_ValidityWindowMinutes * 60;
   grant.approval_nonce           = ManualApproval_NewNonce();

   Print("Granting approval: execution_request_id=", grant.execution_request_id,
         " candidate_id=", grant.candidate_id, " approver=", grant.approver_identity,
         " valid until=", TimeToString(grant.approval_expiry, TIME_DATE|TIME_SECONDS),
         " nonce=", grant.approval_nonce);

   bool ok = ManualApproval_Grant(grant);

   EventStore_Close();

   if(ok)
      Print("Approval durably recorded. NOTE: this grant is not yet enforced by any live gate - the C2 gate integration that consults it is still deferred (see Docs/PhaseC_C2_ManualApprovalContract.md).");
   else
      Print("FAILED: approval was NOT recorded - see prior Print/[FAIL]-style lines.");

   Print("=== manual-approval grant script complete ===");
}
