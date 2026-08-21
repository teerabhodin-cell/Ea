//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_ManualApprovalContract.mqh       |
//| C2 manual-approval contract: ManualApprovalGrant - a durable,     |
//| human-granted authorization fact. Per                              |
//| Docs/PhaseC_C2_ManualApprovalContract.md. This round's own          |
//| "dry code" deliverable: the event schema only, no read side, no    |
//| decision-making, no broker interaction anywhere in this file.      |
//|                                                                    |
//| Deliberately NOT an addition to the frozen ExecutionPolicy/         |
//| ExecutionRequest structs (C1.2, sealed) - a new, additive struct    |
//| instead, the same "no sealed file edited" pattern                   |
//| MLQuantAI_EnvironmentLockContract.mqh already established.          |
//|                                                                    |
//| Binds to FIVE identity fields (execution_request_id/hash/           |
//| execution_policy_version/candidate_id/correlation_id), not just     |
//| id+hash - per the user's explicit "collision-check" instruction,    |
//| so an approval can never silently apply to a request that merely   |
//| shares an id/hash by coincidence but differs in policy lineage or   |
//| candidate origin. See the contract doc's "Event schema" section.    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MANUALAPPROVALCONTRACT_MQH__
#define __MLQUANTAI_MANUALAPPROVALCONTRACT_MQH__

#include "../Core/MLQuantAI_ContractVersions.mqh"

// A durable, human-granted authorization fact - written only by the
// standalone MLQuantAI_ManualScript_GrantApproval.mq5 script, never by
// the EA itself. Carries no decision of its own: whether a given grant
// is currently usable (identity match + not expired) is entirely the
// deferred ManualApprovalRegistry_HasValidApproval()'s job, not this
// struct's. Single-use is NOT tracked here at all - see the contract
// doc's "Consumption boundary" section: SubmissionAttemptRegistry_
// HasAttempt() (already frozen, C2.3) is the sole, authoritative
// consumption boundary.
struct ManualApprovalGrant
{
   string manual_approval_schema_version; // MLQUANTAI_MANUAL_APPROVAL_SCHEMA_C2_V1

   string execution_request_id;
   string execution_request_hash;
   string execution_policy_version;
   string candidate_id;
   string correlation_id;

   string   approver_identity;   // human-supplied, never empty - who granted this
   datetime approval_timestamp;  // TimeCurrent() when the script ran
   datetime approval_expiry;     // must be strictly after approval_timestamp
   string   approval_nonce;      // ManualApproval_NewNonce() - uniqueness/replay-conflict marker
};

void ManualApprovalGrant_Init(ManualApprovalGrant &g)
{
   g.manual_approval_schema_version = MLQUANTAI_MANUAL_APPROVAL_SCHEMA_C2_V1;

   g.execution_request_id = "";
   g.execution_request_hash = "";
   g.execution_policy_version = "";
   g.candidate_id = "";
   g.correlation_id = "";

   g.approver_identity = "";
   g.approval_timestamp = 0;
   g.approval_expiry = 0;
   g.approval_nonce = "";
}

#endif // __MLQUANTAI_MANUALAPPROVALCONTRACT_MQH__
