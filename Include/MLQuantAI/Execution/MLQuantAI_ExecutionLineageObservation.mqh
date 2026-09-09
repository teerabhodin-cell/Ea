//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_ExecutionLineageObservation.mqh  |
//| C6.3 Wave 1 implementation: OnInit-only "discover the past" pass  |
//| (frozen chat-history C6.3 section 6, no separate Docs/ file yet). |
//|                                                                    |
//| Strictly read-only: enumerates the already-rebuilt                 |
//| ExecutionRequestProjection (populated by                            |
//| BrokerSubmissionAudit_StartupRebuild, which transitively stages     |
//| C1.3's ExecutionAuditProjection_RebuildFromFile beneath it) and,     |
//| for each durable request, correlates against DryRunResultProjection, |
//| ManualApprovalProjection, and SubmissionAttemptProjection - log       |
//| observation only, no action, no authority, no EventStore write,       |
//| no candidate-lifecycle transition, no OrderSend/CTrade/                |
//| BrokerSubmission_Submit call anywhere in this file.                     |
//|                                                                    |
//| Caller (MLQuantAI.mq5's OnInit) must call this AFTER both            |
//| BrokerSubmissionAudit_StartupRebuild() and ManualApproval_             |
//| StartupRebuild() have already run this session - this file never       |
//| triggers a rebuild of anything itself.                                  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EXECUTIONLINEAGEOBSERVATION_MQH__
#define __MLQUANTAI_EXECUTIONLINEAGEOBSERVATION_MQH__

#include "MLQuantAI_ExecutionAuditProjection.mqh"
#include "MLQuantAI_ManualApprovalProjection.mqh"
#include "MLQuantAI_BrokerSubmissionAuditProjection.mqh"

// One durable execution_request_id's cross-referenced state, log-only.
void ExecutionLineageObservation_LogOne(const ExecutionRequestProjectionRecord &rec)
{
   int  dryRunCount    = 0;
   bool dryRunAccepted = false;
   for(int i = 0; i < DryRunResultProjection_Count(); i++)
   {
      DryRunResultProjectionRecord d;
      if(!DryRunResultProjection_GetAt(i, d)) continue;
      if(d.execution_request_id != rec.execution_request_id) continue;
      dryRunCount++;
      if(d.decision == SAFETY_GATE_ACCEPTED) dryRunAccepted = true;
   }

   bool hasValidApproval = ManualApprovalRegistry_HasValidApproval(
      rec.execution_request_id, rec.execution_request_hash, rec.execution_policy_version,
      rec.candidate_id, rec.correlation_id, TimeCurrent());

   bool hasAttempt   = SubmissionAttemptRegistry_HasAttempt(rec.execution_request_id);
   bool isUnresolved = hasAttempt && SubmissionAttemptRegistry_IsUnresolved(rec.execution_request_id);

   LogInfo(StringFormat(
      "C6.3 lineage observation: execution_request_id=%s candidate_id=%s "
      "dry_run_records=%d dry_run_accepted=%s valid_approval=%s "
      "submission_attempt=%s submission_unresolved=%s",
      rec.execution_request_id, rec.candidate_id,
      dryRunCount, (dryRunAccepted ? "true" : "false"),
      (hasValidApproval ? "true" : "false"),
      (hasAttempt ? "true" : "false"), (isUnresolved ? "true" : "false")));
}

// The C6.3 section 6 OnInit entry point: "discover the past" - one
// pass over every durable ExecutionRequestProjection record, log-only.
// Never gates EA initialization, never trips Safe Mode - this is pure
// observation, not a new authority.
void ExecutionLineageObservation_LogAll()
{
   int total = ExecutionRequestProjection_Count();
   LogInfo(StringFormat("C6.3 lineage observation: %d durable execution request(s) found at startup", total));
   for(int i = 0; i < total; i++)
   {
      ExecutionRequestProjectionRecord rec;
      if(!ExecutionRequestProjection_GetAt(i, rec)) continue;
      ExecutionLineageObservation_LogOne(rec);
   }
}

#endif // __MLQUANTAI_EXECUTIONLINEAGEOBSERVATION_MQH__
