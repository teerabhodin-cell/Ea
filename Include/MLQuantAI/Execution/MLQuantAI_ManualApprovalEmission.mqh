//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_ManualApprovalEmission.mqh       |
//| C2 manual-approval contract: ManualApproval_NewNonce() and         |
//| ManualApproval_Grant() - the durable write side only. Per          |
//| Docs/PhaseC_C2_ManualApprovalContract.md.                          |
//|                                                                    |
//| ManualApproval_Grant() is a PURE WRITE, mirroring                  |
//| ExecutionRequest_EmitAndEvaluate's own "no partial record" rule    |
//| but with none of its evaluation logic: this file makes no          |
//| decision, checks no lineage, consults no other projection - it     |
//| only rejects a structurally empty grant (matching every other      |
//| *_EventEmission.mqh emitter's "never write a garbage record"       |
//| floor) and otherwise appends one durable                           |
//| EXECUTION_MANUAL_APPROVAL_GRANTED event, verbatim. Whether a given  |
//| grant is currently usable is entirely the deferred                 |
//| ManualApprovalRegistry_HasValidApproval()'s job - not this file's.  |
//|                                                                    |
//| No OrderSend/CTrade/broker call anywhere in this file. No           |
//| candidate-lifecycle transition, no EventStore_LogTransition call.  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MANUALAPPROVALEMISSION_MQH__
#define __MLQUANTAI_MANUALAPPROVALEMISSION_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Core/MLQuantAI_Ids.mqh"
#include "../Core/MLQuantAI_Enums.mqh"
#include "MLQuantAI_ManualApprovalContract.mqh"

int g_ManualApproval_NonceCounter = 0;

// Mirrors Ids_NewRuntimeSessionId()'s own technique (session-local
// counter + GetMicrosecondCount() + MathRand(), all hashed) but with
// its own dedicated counter and an "APPR_" prefix - deliberately NOT a
// reuse of Ids_NewRuntimeSessionId() itself, which is semantically a
// runtime-session identifier, not an approval nonce. Uniqueness is
// guaranteed by g_ManualApproval_NonceCounter (always increments,
// in-process) for calls within one script run; the time/microsecond/
// random components are extra salt against cross-run collisions, same
// division of labor Ids_NewRuntimeSessionId() already documents.
string ManualApproval_NewNonce()
{
   g_ManualApproval_NonceCounter++;
   string key = IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN)) + "|" +
                TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "|" +
                IntegerToString((int)GetMicrosecondCount()) + "|" +
                IntegerToString(g_ManualApproval_NonceCounter) + "|" +
                IntegerToString(MathRand());
   return "APPR_" + StringSubstr(Ids_Sha256Hex(key), 0, 12);
}

string ManualApprovalGrant_ToExtraJson(const ManualApprovalGrant &g)
{
   string s = "";
   s += "\"manual_approval_schema_version\":\"" + EventSerializer_Escape(g.manual_approval_schema_version) + "\",";
   s += "\"execution_request_id\":\""             + EventSerializer_Escape(g.execution_request_id) + "\",";
   s += "\"execution_request_hash\":\""              + EventSerializer_Escape(g.execution_request_hash) + "\",";
   s += "\"execution_policy_version\":\""              + EventSerializer_Escape(g.execution_policy_version) + "\",";
   s += "\"candidate_id\":\""                            + EventSerializer_Escape(g.candidate_id) + "\",";
   s += "\"correlation_id\":\""                            + EventSerializer_Escape(g.correlation_id) + "\",";
   s += "\"approver_identity\":\""                           + EventSerializer_Escape(g.approver_identity) + "\",";
   s += "\"approval_timestamp\":"                              + IntegerToString((long)g.approval_timestamp) + ",";
   s += "\"approval_expiry\":"                                   + IntegerToString((long)g.approval_expiry) + ",";
   s += "\"approval_nonce\":\""                                    + EventSerializer_Escape(g.approval_nonce) + "\"";
   return s;
}

// The C2 manual-approval boundary function - this round's only real
// deliverable. Rejects, with no write attempted, if any of the five
// identity fields, approver_identity, or approval_nonce is empty, or
// if approval_expiry does not come strictly after approval_timestamp -
// the same "never write a garbage record" floor every prior
// *_EventEmission.mqh emitter already enforces. Never validates
// lineage against any other projection (no ExecutionRequestProjection
// lookup, no DryRunResultProjection lookup) - that full five-field
// collision-check is the deferred projection's job at REBUILD time,
// per the contract doc's "Projection apply-time validation" section,
// not this write-time function's.
bool ManualApproval_Grant(const ManualApprovalGrant &grant)
{
   if(grant.execution_request_id == "" || grant.execution_request_hash == "" ||
      grant.execution_policy_version == "" || grant.candidate_id == "" ||
      grant.correlation_id == "" || grant.approver_identity == "" ||
      grant.approval_nonce == "")
      return false;

   if(grant.approval_expiry <= grant.approval_timestamp)
      return false;

   string json = ManualApprovalGrant_ToExtraJson(grant);
   return EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_MANUAL_APPROVAL_GRANTED), "manual approval granted", json);
}

#endif // __MLQUANTAI_MANUALAPPROVALEMISSION_MQH__
