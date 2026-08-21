//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_ManualApprovalProjection.mqh     |
//| C2 manual-approval contract, gate integration round: the          |
//| projection (read side) over EXECUTION_MANUAL_APPROVAL_GRANTED      |
//| events, plus the pure ManualApprovalRegistry_HasValidApproval()    |
//| query. Per Docs/PhaseC_C2_ManualApprovalContract.md's "Projection  |
//| apply-time validation" and "Registry query" sections.               |
//|                                                                    |
//| Strictly additive and read-only: no OrderSend/broker query/broker  |
//| mutation anywhere in this file, no candidate-lifecycle transition, |
//| no event append. No sealed file touched. Same "design tension,     |
//| resolved" precedent as MLQuantAI_BrokerSubmissionAuditProjection.mqh|
//| - C1.3's own ExecutionAuditProjection_RebuildFromFile() is staged,  |
//| unmodified, as a black-box gate across the WHOLE file first (it     |
//| already transitively stages every layer beneath it) - this file    |
//| never re-parses EXECUTION_REQUEST_CREATED/EXECUTION_DRY_RUN_        |
//| COMPLETED itself.                                                   |
//|                                                                    |
//| Consumption boundary (frozen, per the user's explicit instruction):|
//| this file exposes ONLY a pure read, HasValidApproval() - it never  |
//| marks an approval "consumed" or "used". SubmissionAttemptRegistry_ |
//| HasAttempt() (already frozen, C2.3) remains the sole, authoritative|
//| consumption boundary - never duplicated here.                      |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MANUALAPPROVALPROJECTION_MQH__
#define __MLQUANTAI_MANUALAPPROVALPROJECTION_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Core/MLQuantAI_Enums.mqh"
#include "MLQuantAI_ExecutionAuditProjection.mqh"

#define MLQUANTAI_MANUALAPPROVALPROJ_MAX_LINE_LENGTH 65536

//---------------------------------------------------------------------
// ManualApprovalProjectionRecord - 0..N records per execution_request_id,
// never deduped (a legitimate second approval - e.g. after the first
// expired - is real audit history, not a duplicate). Keyed by the
// event's own source_sequence_number/source_log_event_id, same shape
// SubmissionAttemptProjectionRecord already established.
//---------------------------------------------------------------------
struct ManualApprovalProjectionRecord
{
   string manual_approval_schema_version;

   string execution_request_id;
   string execution_request_hash;
   string execution_policy_version;
   string candidate_id;
   string correlation_id;

   string   approver_identity;
   datetime approval_timestamp;
   datetime approval_expiry;
   string   approval_nonce;

   long   source_sequence_number;
   string source_log_event_id;
};

void ManualApprovalProjectionRecord_Init(ManualApprovalProjectionRecord &r)
{
   r.manual_approval_schema_version = "";
   r.execution_request_id = "";
   r.execution_request_hash = "";
   r.execution_policy_version = "";
   r.candidate_id = "";
   r.correlation_id = "";
   r.approver_identity = "";
   r.approval_timestamp = 0;
   r.approval_expiry = 0;
   r.approval_nonce = "";
   r.source_sequence_number = 0;
   r.source_log_event_id = "";
}

ManualApprovalProjectionRecord g_ManualApprovalProj_Records[];
int                            g_ManualApprovalProj_Count = 0;

void ManualApprovalProjection_Reset()
{
   ArrayResize(g_ManualApprovalProj_Records, 0);
   g_ManualApprovalProj_Count = 0;
}

int ManualApprovalProjection_Count() { return g_ManualApprovalProj_Count; }

bool ManualApprovalProjection_GetAt(int index, ManualApprovalProjectionRecord &out)
{
   if(index < 0 || index >= g_ManualApprovalProj_Count) return false;
   out = g_ManualApprovalProj_Records[index];
   return true;
}

void ManualApprovalProjection_AppendRecord(const ManualApprovalProjectionRecord &rec)
{
   int idx = g_ManualApprovalProj_Count;
   ArrayResize(g_ManualApprovalProj_Records, idx + 1);
   g_ManualApprovalProj_Records[idx] = rec;
   g_ManualApprovalProj_Count++;
}

int ManualApprovalProjection_FindByLogEventId(string logEventId)
{
   for(int i = 0; i < g_ManualApprovalProj_Count; i++)
      if(g_ManualApprovalProj_Records[i].source_log_event_id == logEventId)
         return i;
   return -1;
}

// Nonce collision search, scoped to a DIFFERENT log_event_id than the
// one being applied - an identical log_event_id replay is handled
// separately (the ordinary idempotent-duplicate case, unaffected by
// this rule). Returns the index of the first colliding record, or -1.
int ManualApprovalProjection_FindByNonceExcludingLogEventId(string nonce, string excludeLogEventId)
{
   for(int i = 0; i < g_ManualApprovalProj_Count; i++)
      if(g_ManualApprovalProj_Records[i].approval_nonce == nonce &&
         g_ManualApprovalProj_Records[i].source_log_event_id != excludeLogEventId)
         return i;
   return -1;
}

//---------------------------------------------------------------------
// Line application - the full, frozen validation chain from the
// contract doc's "Projection apply-time validation" section.
//---------------------------------------------------------------------
bool ManualApprovalProjection_ApplyLineWithLineage(string line, string &outReason)
{
   if(StringLen(line) > MLQUANTAI_MANUALAPPROVALPROJ_MAX_LINE_LENGTH)
   {
      outReason = "line exceeds the defensive length bound - rejected before parsing";
      return false;
   }

   SystemEvent e;
   if(!EventSerializer_ParseSystem(line, e))
   {
      outReason = "not a parsable event line";
      return false;
   }

   string schemaVersion  = EventSerializer_GetStr(line, "manual_approval_schema_version");
   string requestId      = EventSerializer_GetStr(line, "execution_request_id");
   string requestHash    = EventSerializer_GetStr(line, "execution_request_hash");
   string policyVersion  = EventSerializer_GetStr(line, "execution_policy_version");
   string candidateId    = EventSerializer_GetStr(line, "candidate_id");
   string correlationId  = EventSerializer_GetStr(line, "correlation_id");
   string approverId      = EventSerializer_GetStr(line, "approver_identity");
   string nonce            = EventSerializer_GetStr(line, "approval_nonce");

   if(requestId == "" || requestHash == "" || policyVersion == "" || candidateId == "" || correlationId == "")
   {
      outReason = "missing a required identity field (execution_request_id/hash/policy_version/candidate_id/correlation_id)";
      return false;
   }
   if(approverId == "")
   {
      outReason = "approver_identity is empty - an anonymous approval is not a real approval";
      return false;
   }
   if(nonce == "")
   {
      outReason = "approval_nonce is empty - structurally invalid payload";
      return false;
   }
   if(!EventSerializer_HasKey(line, "approval_timestamp") || !EventSerializer_HasKey(line, "approval_expiry"))
   {
      outReason = "missing approval_timestamp/approval_expiry";
      return false;
   }
   datetime timestamp = (datetime)EventSerializer_GetLong(line, "approval_timestamp");
   datetime expiry     = (datetime)EventSerializer_GetLong(line, "approval_expiry");
   if(expiry <= timestamp)
   {
      outReason = "approval_expiry does not come strictly after approval_timestamp - structurally invalid payload";
      return false;
   }

   // Idempotent replay: an exact duplicate of an already-applied line
   // (same log_event_id) is a no-op, never a second record - identical
   // rule to every prior projection in this codebase. A DIFFERENT
   // payload claiming the same log_event_id is corruption, rejected
   // closed.
   int dupIdx = ManualApprovalProjection_FindByLogEventId(e.base.log_event_id);
   if(dupIdx >= 0)
   {
      ManualApprovalProjectionRecord existing = g_ManualApprovalProj_Records[dupIdx];
      if(existing.execution_request_id == requestId && existing.execution_request_hash == requestHash &&
         existing.execution_policy_version == policyVersion && existing.candidate_id == candidateId &&
         existing.correlation_id == correlationId && existing.approver_identity == approverId &&
         existing.approval_timestamp == timestamp && existing.approval_expiry == expiry &&
         existing.approval_nonce == nonce && existing.source_sequence_number == e.base.sequence_number)
      {
         outReason = "duplicate approval event replay - identical log_event_id already applied, not re-applied";
         return true;
      }
      outReason = StringFormat("log_event_id collision: '%s' already registered with a DIFFERENT approval payload - rejected as a conflict, not a duplicate",
                                e.base.log_event_id);
      return false;
   }

   ExecutionRequestProjectionRecord reqRec;
   if(!ExecutionRequestProjection_TryGet(requestId, reqRec))
   {
      outReason = "orphan approval: execution_request_id '" + requestId + "' has no matching EXECUTION_REQUEST_CREATED event in this store - rejected";
      return false;
   }
   if(reqRec.execution_request_hash != requestHash || reqRec.execution_policy_version != policyVersion ||
      reqRec.candidate_id != candidateId || reqRec.correlation_id != correlationId)
   {
      outReason = "approval's identity fields do not ALL match the referenced ExecutionRequestProjection record's own values - "
                  "tampered, corrupted, or a coincidental id collision with a different request lineage";
      return false;
   }

   bool hasAcceptedDryRun = false;
   for(int i = 0; i < DryRunResultProjection_Count(); i++)
   {
      DryRunResultProjectionRecord dr;
      DryRunResultProjection_GetAt(i, dr);
      if(dr.execution_request_id == requestId && dr.execution_request_hash == requestHash && dr.decision == SAFETY_GATE_ACCEPTED)
      {
         hasAcceptedDryRun = true;
         break;
      }
   }
   if(!hasAcceptedDryRun)
   {
      outReason = "orphan approval: no SAFETY_GATE_ACCEPTED DryRunResultProjection record exists for this exact "
                  "execution_request_id/hash - approving a request that was never dry-run-accepted would be a real bug - rejected";
      return false;
   }

   // Nonce collision across DIFFERENT log_event_ids - two physically
   // distinct grant events sharing the same nonce is itself a
   // payload-conflict replay signal, fails the whole rebuild closed,
   // even if every other field differs.
   int nonceCollisionIdx = ManualApprovalProjection_FindByNonceExcludingLogEventId(nonce, e.base.log_event_id);
   if(nonceCollisionIdx >= 0)
   {
      outReason = StringFormat("approval_nonce '%s' collides with an already-applied record under a DIFFERENT log_event_id - "
                                "a replay-conflict signal, rejected closed", nonce);
      return false;
   }

   ManualApprovalProjectionRecord rec;
   ManualApprovalProjectionRecord_Init(rec);
   rec.manual_approval_schema_version = schemaVersion;
   rec.execution_request_id = requestId;
   rec.execution_request_hash = requestHash;
   rec.execution_policy_version = policyVersion;
   rec.candidate_id = candidateId;
   rec.correlation_id = correlationId;
   rec.approver_identity = approverId;
   rec.approval_timestamp = timestamp;
   rec.approval_expiry = expiry;
   rec.approval_nonce = nonce;
   rec.source_sequence_number = e.base.sequence_number;
   rec.source_log_event_id = e.base.log_event_id;

   ManualApprovalProjection_AppendRecord(rec);
   outReason = "applied - new manual approval registered";
   return true;
}

//---------------------------------------------------------------------
// Combined rebuild - stages C1.3's own ExecutionAuditProjection_
// RebuildFromFile (unmodified black-box gate, whole file, first), same
// precedent MLQuantAI_BrokerSubmissionAuditProjection.mqh already
// established, then this file's own single pass over
// EXECUTION_MANUAL_APPROVAL_GRANTED lines.
//---------------------------------------------------------------------
struct ManualApprovalProjectionReport
{
   bool   ok;
   int    lines_total;
   int    approval_lines_applied;
   int    lines_skipped;
   int    lines_failed;
   string first_error;
};

void ManualApprovalProjectionReport_Init(ManualApprovalProjectionReport &r)
{
   r.ok = true;
   r.lines_total = 0;
   r.approval_lines_applied = 0;
   r.lines_skipped = 0;
   r.lines_failed = 0;
   r.first_error = "";
}

ManualApprovalProjectionReport ManualApprovalProjection_RebuildFromFile(string fileName)
{
   ManualApprovalProjectionReport report;
   ManualApprovalProjectionReport_Init(report);

   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);
   report.lines_total = n;

   ExecutionAuditProjectionReport execReport = ExecutionAuditProjection_RebuildFromFile(fileName);
   if(!execReport.ok)
   {
      report.ok = false;
      report.first_error = "execution audit registry (C1.3) failed to rebuild from the same store - rebuild refused, registry left unchanged: " + execReport.first_error;
      return report;
   }

   ManualApprovalProjection_Reset();

   string grantType = EventTypeToString(EVENT_TYPE_EXECUTION_MANUAL_APPROVAL_GRANTED);

   for(int i = 0; i < n; i++)
   {
      if(!EventSerializer_HasKey(lines[i], "type"))
      {
         report.lines_skipped++;
         continue;
      }
      string lineType = EventSerializer_GetStr(lines[i], "type");
      if(lineType != grantType)
      {
         report.lines_skipped++;
         continue;
      }

      string reason;
      int beforeCount = ManualApprovalProjection_Count();
      bool applied = ManualApprovalProjection_ApplyLineWithLineage(lines[i], reason);
      bool countIncreased = ManualApprovalProjection_Count() > beforeCount;
      if(applied && countIncreased)
         report.approval_lines_applied++;

      if(!applied)
      {
         report.ok = false;
         report.lines_failed++;
         if(report.first_error == "")
            report.first_error = StringFormat("line %d: %s", i, reason);
         continue;
      }
      if(!countIncreased)
         report.lines_skipped++; // applied but a no-op - e.g. a duplicate log_event_id replay
   }

   return report;
}

//---------------------------------------------------------------------
// ManualApprovalRegistry_HasValidApproval - the frozen, consumer-
// facing query interface. Pure: asOf is caller-supplied, never read
// internally via TimeCurrent(). Never checks SubmissionAttemptRegistry
// itself - see this file's own header, "consumption boundary".
//---------------------------------------------------------------------
bool ManualApprovalRegistry_HasValidApproval(string executionRequestId, string executionRequestHash,
                                               string executionPolicyVersion, string candidateId,
                                               string correlationId, datetime asOf)
{
   for(int i = 0; i < g_ManualApprovalProj_Count; i++)
   {
      ManualApprovalProjectionRecord rec = g_ManualApprovalProj_Records[i];
      if(rec.execution_request_id == executionRequestId &&
         rec.execution_request_hash == executionRequestHash &&
         rec.execution_policy_version == executionPolicyVersion &&
         rec.candidate_id == candidateId &&
         rec.correlation_id == correlationId &&
         rec.approval_expiry > asOf)
         return true;
   }
   return false;
}

#endif // __MLQUANTAI_MANUALAPPROVALPROJECTION_MQH__
