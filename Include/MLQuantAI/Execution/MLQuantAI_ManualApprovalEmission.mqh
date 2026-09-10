//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_ManualApprovalEmission.mqh       |
//| C2 manual-approval contract: ManualApproval_NewNonce() and         |
//| ManualApproval_Grant() - the durable write side only. Per          |
//| Docs/PhaseC_C2_ManualApprovalContract.md.                          |
//|                                                                    |
//| ManualApproval_Grant() is a PURE WRITE, mirroring                  |
//| ExecutionRequest_EmitAndEvaluate's own "no partial record" rule    |
//| but with none of its evaluation logic: this file makes no          |
//| decision, checks no lineage itself - it only rejects a             |
//| structurally empty grant (matching every other                     |
//| *_EventEmission.mqh emitter's "never write a garbage record"       |
//| floor) and otherwise appends one durable                           |
//| EXECUTION_MANUAL_APPROVAL_GRANTED event, verbatim.                  |
//|                                                                    |
//| RA-30.4 (QA-frozen Manual Approval Runtime Projection Consistency): |
//| write-then-update, fail-closed. EventStore_AppendSystem(e) (core,   |
//| unmodified) is called directly instead of via the EventStore_       |
//| LogSystem convenience wrapper, so this file keeps the exact,        |
//| by-reference-populated SystemEvent (real log_event_id/sequence_    |
//| number/ts, assigned by the core append itself) after a successful   |
//| durable write - no re-read of the EventStore file is ever needed.   |
//| On success, that SAME event is re-serialized (EventSerializer_      |
//| ToJson, already public) and fed into                                |
//| MLQuantAI_ManualApprovalProjection.mqh's own, UNMODIFIED             |
//| ManualApprovalProjection_ApplyLineWithLineage() - the exact same     |
//| validate+insert function ManualApproval_StartupRebuild() already     |
//| uses, so there is no second, parallel validation implementation to   |
//| drift from it. If EventStore_AppendSystem fails, the registry is     |
//| never touched (durable truth first, always). Whether a given grant   |
//| is currently usable is still entirely                                |
//| ManualApprovalRegistry_HasValidApproval()'s job - this file only      |
//| ensures the registry it reads from reflects this write immediately,  |
//| same session, no restart required.                                   |
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
#include "MLQuantAI_ManualApprovalProjection.mqh"

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
// *_EventEmission.mqh emitter already enforces.
//
// RA-30.4: after that structural check, this function itself still
// never re-validates lineage against ExecutionRequestProjection/
// DryRunResultProjection - that full five-field collision-check lives
// in exactly one place, ManualApprovalProjection_ApplyLineWithLineage()
// (MLQuantAI_ManualApprovalProjection.mqh, unmodified), which this
// function now calls itself, immediately after a successful durable
// write, instead of leaving it to a future rebuild alone.
bool ManualApproval_Grant(const ManualApprovalGrant &grant)
{
   if(grant.execution_request_id == "" || grant.execution_request_hash == "" ||
      grant.execution_policy_version == "" || grant.candidate_id == "" ||
      grant.correlation_id == "" || grant.approver_identity == "" ||
      grant.approval_nonce == "")
      return false;

   if(grant.approval_expiry <= grant.approval_timestamp)
      return false;

   SystemEvent e;
   SystemEvent_Init(e);
   e.base.event_type = EventTypeToString(EVENT_TYPE_EXECUTION_MANUAL_APPROVAL_GRANTED);
   e.message          = "manual approval granted";
   e.extra_json       = ManualApprovalGrant_ToExtraJson(grant);

   // RA-30.4 fail-closed ordering (QA-frozen): durable write FIRST - the
   // runtime registry is never touched if this fails. EventStore_
   // AppendSystem populates e.base.log_event_id/sequence_number/ts by
   // reference regardless of the outcome, but they are only trustworthy
   // - and only used below - once this returns true.
   if(!EventStore_AppendSystem(e))
      return false;

   // Re-serialize the SAME event that was just durably written (no
   // EventStore re-read) and feed it through the exact, unmodified
   // validate+insert path ManualApproval_StartupRebuild() already uses -
   // zero parallel validation logic to drift from it.
   string line = EventSerializer_ToJson(e);
   string applyReason;
   if(!ManualApprovalProjection_ApplyLineWithLineage(line, applyReason))
   {
      // Durable truth now HAS this approval (the append above already
      // succeeded and cannot be safely rolled back - the store is
      // append-only) but the live registry rejected re-applying its own
      // just-written data. Expected to be effectively unreachable in
      // practice (the data was already validated once by this same
      // function's own checks above), but if it ever happens the
      // registry and the durable file are now inconsistent for this one
      // grant until the next full rebuild (EA restart) reconciles them -
      // distinct, explicit log line so this is never silently folded
      // into an ordinary "grant failed" diagnosis.
      Print("[MLQuantAI][ERROR] RA-30.4: durable manual approval write SUCCEEDED (log_event_id=", e.base.log_event_id,
            ") but runtime registry apply FAILED: ", applyReason,
            " - durable/runtime are now inconsistent for this grant until the next EA restart rebuilds the registry. Human reconciliation required.");
      return false;
   }

   return true;
}

#endif // __MLQUANTAI_MANUALAPPROVALEMISSION_MQH__
