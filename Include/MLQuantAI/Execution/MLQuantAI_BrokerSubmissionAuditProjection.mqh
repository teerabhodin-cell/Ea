//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BrokerSubmissionAuditProjection  |
//| Phase C2.3: read-only audit projections over the durable          |
//| EXECUTION_SUBMISSION_ATTEMPTED / ORDER_SUBMISSION_ERROR /          |
//| ORDER_SUBMITTED / ORDER_REJECTED / EXECUTION_SUBMISSION_UNKNOWN    |
//| events C2.2 already writes, plus a durable, restart-safe           |
//| idempotency registry and a reconciliation report over both. Per    |
//| Docs/PhaseC_C2_1_BrokerSubmissionContract.md's C2.3 addendum.      |
//|                                                                    |
//| Strictly additive and read-only: no OrderSend/broker query/broker  |
//| mutation anywhere in this file, no candidate-lifecycle transition, |
//| no event append. No sealed file touched                            |
//| (MLQuantAI_ExecutionAuditProjection.mqh, MLQuantAI_SafetyGate.mqh, |
//| MLQuantAI_BrokerSubmissionGate.mqh,                                 |
//| MLQuantAI_BrokerSubmissionBuilder.mqh,                              |
//| MLQuantAI_BrokerSubmissionAdapter.mqh).                             |
//|                                                                    |
//| Same "design tension, resolved" precedent this doc's C2.3 addendum |
//| documents: C1.3's own ExecutionAuditProjection_RebuildFromFile()    |
//| is staged, unmodified, as a black-box gate across the WHOLE file    |
//| first (it already transitively stages every layer beneath it) -    |
//| this file never re-parses EXECUTION_REQUEST_CREATED/                |
//| EXECUTION_DRY_RUN_COMPLETED itself. Only C2.3's own two new sibling |
//| types (EXECUTION_SUBMISSION_ATTEMPTED and the outcome quartet)      |
//| are processed in ONE new, genuinely interleaved pass - an outcome   |
//| line's execution_request_id must already have a matching attempt   |
//| applied earlier in THIS SAME pass, or the whole rebuild fails       |
//| closed as an orphan/ordering violation. An attempt line's own       |
//| reference back to the already-staged ExecutionRequestProjection/    |
//| DryRunResultProjection is an orphan-only check (must exist, with a  |
//| matching hash, and at least one SAFETY_GATE_ACCEPTED dry-run record |
//| for that exact request) - never a relative-ordering check against   |
//| C1's own events.                                                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BROKERSUBMISSIONAUDITPROJECTION_MQH__
#define __MLQUANTAI_BROKERSUBMISSIONAUDITPROJECTION_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Core/MLQuantAI_Enums.mqh"
#include "../Core/MLQuantAI_ReasonCodes.mqh"
#include "MLQuantAI_ExecutionAuditProjection.mqh"

#define MLQUANTAI_BROKERSUBAUDITPROJ_MAX_LINE_LENGTH 65536

//---------------------------------------------------------------------
// SubmissionAttemptProjection - 0..N records per execution_request_id,
// never deduped (a legitimate future retry after a local OrderSend()
// failure would produce a second real attempt for the same id - this
// must not collapse to 1, same rule DryRunResultProjection already
// established in C1.3). Keyed by the event's own durable
// source_sequence_number/source_log_event_id.
//---------------------------------------------------------------------
struct SubmissionAttemptProjectionRecord
{
   string execution_request_id;
   string execution_request_hash;
   string correlation_id;
   int    submit_attempt;

   long   source_sequence_number;
   string source_log_event_id;
};

void SubmissionAttemptProjectionRecord_Init(SubmissionAttemptProjectionRecord &r)
{
   r.execution_request_id = "";
   r.execution_request_hash = "";
   r.correlation_id = "";
   r.submit_attempt = 0;
   r.source_sequence_number = 0;
   r.source_log_event_id = "";
}

SubmissionAttemptProjectionRecord g_SubAttemptProj_Records[];
int                               g_SubAttemptProj_Count = 0;

void SubmissionAttemptProjection_Reset()
{
   ArrayResize(g_SubAttemptProj_Records, 0);
   g_SubAttemptProj_Count = 0;
}

int SubmissionAttemptProjection_Count() { return g_SubAttemptProj_Count; }

bool SubmissionAttemptProjection_GetAt(int index, SubmissionAttemptProjectionRecord &out)
{
   if(index < 0 || index >= g_SubAttemptProj_Count) return false;
   out = g_SubAttemptProj_Records[index];
   return true;
}

void SubmissionAttemptProjection_AppendRecord(const SubmissionAttemptProjectionRecord &rec)
{
   int idx = g_SubAttemptProj_Count;
   ArrayResize(g_SubAttemptProj_Records, idx + 1);
   g_SubAttemptProj_Records[idx] = rec;
   g_SubAttemptProj_Count++;
}

int SubmissionAttemptProjection_FindByLogEventId(string logEventId)
{
   for(int i = 0; i < g_SubAttemptProj_Count; i++)
      if(g_SubAttemptProj_Records[i].source_log_event_id == logEventId)
         return i;
   return -1;
}

bool SubmissionAttemptProjection_HasAnyFor(string executionRequestId, string executionRequestHash)
{
   for(int i = 0; i < g_SubAttemptProj_Count; i++)
      if(g_SubAttemptProj_Records[i].execution_request_id == executionRequestId &&
         g_SubAttemptProj_Records[i].execution_request_hash == executionRequestHash)
         return true;
   return false;
}

//---------------------------------------------------------------------
// SubmissionOutcomeProjection - same 0..N, never-deduped,
// source_sequence_number-keyed shape. One record per
// ORDER_SUBMISSION_ERROR/ORDER_SUBMITTED/ORDER_REJECTED/
// EXECUTION_SUBMISSION_UNKNOWN line.
//---------------------------------------------------------------------
struct SubmissionOutcomeProjectionRecord
{
   string execution_submission_result_schema_version;

   string execution_request_id;
   string execution_request_hash;
   string correlation_id;
   int    submit_attempt;

   ENUM_SUBMISSION_STATUS submission_status;
   bool     order_send_returned;
   int      terminal_last_error;
   uint     retcode;
   int      retcode_external;
   long     request_id;
   ulong    order_ticket;
   ulong    deal_ticket;
   double   requested_price;
   double   observed_submit_price;
   datetime submission_timestamp;

   ENUM_REASON_CODE reason_code;

   long   source_sequence_number;
   string source_log_event_id;
};

void SubmissionOutcomeProjectionRecord_Init(SubmissionOutcomeProjectionRecord &r)
{
   r.execution_submission_result_schema_version = "";
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
   r.source_sequence_number = 0;
   r.source_log_event_id = "";
}

SubmissionOutcomeProjectionRecord g_SubOutcomeProj_Records[];
int                               g_SubOutcomeProj_Count = 0;

void SubmissionOutcomeProjection_Reset()
{
   ArrayResize(g_SubOutcomeProj_Records, 0);
   g_SubOutcomeProj_Count = 0;
}

int SubmissionOutcomeProjection_Count() { return g_SubOutcomeProj_Count; }

bool SubmissionOutcomeProjection_GetAt(int index, SubmissionOutcomeProjectionRecord &out)
{
   if(index < 0 || index >= g_SubOutcomeProj_Count) return false;
   out = g_SubOutcomeProj_Records[index];
   return true;
}

void SubmissionOutcomeProjection_AppendRecord(const SubmissionOutcomeProjectionRecord &rec)
{
   int idx = g_SubOutcomeProj_Count;
   ArrayResize(g_SubOutcomeProj_Records, idx + 1);
   g_SubOutcomeProj_Records[idx] = rec;
   g_SubOutcomeProj_Count++;
}

int SubmissionOutcomeProjection_FindByLogEventId(string logEventId)
{
   for(int i = 0; i < g_SubOutcomeProj_Count; i++)
      if(g_SubOutcomeProj_Records[i].source_log_event_id == logEventId)
         return i;
   return -1;
}

//---------------------------------------------------------------------
// Bare (unquoted) JSON boolean getter - EventSerializer_GetRawNumber()
// already scans up to the next ','/'}' regardless of the token's own
// content, so it works unmodified for "order_send_returned":true/false
// too. No EventSerializer_GetBool() exists (no sealed file edited to
// add one) - this is a local, additive reader over an already-public
// function.
//---------------------------------------------------------------------
bool SubmissionOutcomeProjection_GetBoolField(string json, string key, bool &outVal)
{
   string raw = EventSerializer_GetRawNumber(json, key);
   if(raw == "true")  { outVal = true;  return true; }
   if(raw == "false") { outVal = false; return true; }
   return false;
}

//---------------------------------------------------------------------
// SubmissionAttemptProjection line application.
//---------------------------------------------------------------------
bool SubmissionAttemptProjection_ApplyLineWithLineage(string line, string &outReason)
{
   if(StringLen(line) > MLQUANTAI_BROKERSUBAUDITPROJ_MAX_LINE_LENGTH)
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

   string requestId    = EventSerializer_GetStr(line, "execution_request_id");
   string requestHash  = EventSerializer_GetStr(line, "execution_request_hash");
   string correlationId = EventSerializer_GetStr(line, "correlation_id");

   if(requestId == "" || requestHash == "" || correlationId == "")
   {
      outReason = "missing a required EXECUTION_SUBMISSION_ATTEMPTED field";
      return false;
   }
   if(!EventSerializer_HasKey(line, "submit_attempt"))
   {
      outReason = "missing submit_attempt";
      return false;
   }
   int submitAttempt = EventSerializer_GetInt(line, "submit_attempt");
   if(submitAttempt != 1)
   {
      outReason = "submit_attempt is not 1 - C2 never produces any other value";
      return false;
   }

   // Idempotent replay: an exact duplicate of an already-applied line
   // (same log_event_id) is a no-op, never a second record - this is
   // what makes a replayed duplicate EXECUTION_SUBMISSION_ATTEMPTED line
   // safe to re-run through the rebuild. A DIFFERENT payload claiming
   // the same log_event_id is corruption, rejected closed.
   int dupIdx = SubmissionAttemptProjection_FindByLogEventId(e.base.log_event_id);
   if(dupIdx >= 0)
   {
      SubmissionAttemptProjectionRecord existing = g_SubAttemptProj_Records[dupIdx];
      if(existing.execution_request_id == requestId && existing.execution_request_hash == requestHash &&
         existing.correlation_id == correlationId && existing.submit_attempt == submitAttempt &&
         existing.source_sequence_number == e.base.sequence_number)
      {
         outReason = "duplicate attempt event replay - identical log_event_id already applied, not re-applied";
         return true;
      }
      outReason = StringFormat("log_event_id collision: '%s' already registered with a DIFFERENT attempt payload - rejected as a conflict, not a duplicate",
                                e.base.log_event_id);
      return false;
   }

   ExecutionRequestProjectionRecord reqRec;
   if(!ExecutionRequestProjection_TryGet(requestId, reqRec))
   {
      outReason = "orphan submission attempt: execution_request_id '" + requestId + "' has no matching EXECUTION_REQUEST_CREATED event in this store - rejected";
      return false;
   }
   if(reqRec.execution_request_hash != requestHash)
   {
      outReason = "submission attempt's execution_request_hash does not match the referenced ExecutionRequestProjection record's own hash - tampered or corrupted";
      return false;
   }
   if(reqRec.correlation_id != correlationId)
   {
      outReason = "submission attempt's correlation_id does not match the referenced ExecutionRequestProjection record's own correlation_id - tampered or corrupted";
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
      outReason = "orphan submission attempt: no SAFETY_GATE_ACCEPTED DryRunResultProjection record exists for this exact "
                  "execution_request_id/hash - a submission attempt built from a non-accepted (or missing) dry-run would be a real bug - rejected";
      return false;
   }

   SubmissionAttemptProjectionRecord rec;
   SubmissionAttemptProjectionRecord_Init(rec);
   rec.execution_request_id = requestId;
   rec.execution_request_hash = requestHash;
   rec.correlation_id = correlationId;
   rec.submit_attempt = submitAttempt;
   rec.source_sequence_number = e.base.sequence_number;
   rec.source_log_event_id = e.base.log_event_id;

   SubmissionAttemptProjection_AppendRecord(rec);
   outReason = "applied - new submission attempt registered";
   return true;
}

//---------------------------------------------------------------------
// SubmissionOutcomeProjection line application.
//---------------------------------------------------------------------
bool SubmissionOutcomeProjection_ApplyLineWithLineage(string line, string &outReason)
{
   if(StringLen(line) > MLQUANTAI_BROKERSUBAUDITPROJ_MAX_LINE_LENGTH)
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

   ENUM_SUBMISSION_STATUS expectedStatus;
   if(e.base.event_type == EventTypeToString(EVENT_TYPE_ORDER_SUBMISSION_ERROR))
      expectedStatus = SUBMISSION_STATUS_ERROR;
   else if(e.base.event_type == EventTypeToString(EVENT_TYPE_ORDER_SUBMITTED))
      expectedStatus = SUBMISSION_STATUS_SUBMITTED;
   else if(e.base.event_type == EventTypeToString(EVENT_TYPE_ORDER_REJECTED))
      expectedStatus = SUBMISSION_STATUS_REJECTED;
   else if(e.base.event_type == EventTypeToString(EVENT_TYPE_EXECUTION_SUBMISSION_UNKNOWN))
      expectedStatus = SUBMISSION_STATUS_UNKNOWN;
   else
   {
      outReason = "not one of the four recognized submission outcome event types";
      return false;
   }

   string schemaVersion  = EventSerializer_GetStr(line, "execution_submission_result_schema_version");
   string requestId       = EventSerializer_GetStr(line, "execution_request_id");
   string requestHash      = EventSerializer_GetStr(line, "execution_request_hash");
   string correlationId     = EventSerializer_GetStr(line, "correlation_id");
   string statusStr           = EventSerializer_GetStr(line, "submission_status");
   string reasonStr             = EventSerializer_GetStr(line, "reason_code");

   if(schemaVersion == "" || requestId == "" || requestHash == "" || correlationId == "" || statusStr == "")
   {
      outReason = "missing a required ExecutionSubmissionResult field";
      return false;
   }
   if(!EventSerializer_HasKey(line, "submit_attempt"))
   {
      outReason = "missing submit_attempt";
      return false;
   }
   int submitAttempt = EventSerializer_GetInt(line, "submit_attempt");
   if(submitAttempt != 1)
   {
      outReason = "submit_attempt is not 1 - C2 never produces any other value";
      return false;
   }

   bool orderSendReturned;
   if(!SubmissionOutcomeProjection_GetBoolField(line, "order_send_returned", orderSendReturned))
   {
      outReason = "missing or malformed order_send_returned";
      return false;
   }

   ENUM_SUBMISSION_STATUS statusVal = SubmissionStatusFromString(statusStr);
   if(statusVal != expectedStatus)
   {
      outReason = "submission_status payload field does not match the line's own event type - corruption, rejected";
      return false;
   }

   ENUM_REASON_CODE reasonVal = ReasonCodeFromString(reasonStr);

   if(expectedStatus == SUBMISSION_STATUS_ERROR)
   {
      if(orderSendReturned)
      {
         outReason = "ERROR outcome but order_send_returned is true - violates the outcome invariant";
         return false;
      }
   }
   else
   {
      if(!orderSendReturned)
      {
         outReason = "SUBMITTED/REJECTED/UNKNOWN outcome but order_send_returned is false - violates the outcome invariant";
         return false;
      }
      if(expectedStatus == SUBMISSION_STATUS_SUBMITTED && reasonVal != REASON_SUBMITTED_OK)
      {
         outReason = "SUBMITTED outcome but reason_code is not REASON_SUBMITTED_OK - violates the outcome invariant";
         return false;
      }
      if(expectedStatus == SUBMISSION_STATUS_UNKNOWN && reasonVal != REASON_EXECUTION_SUBMISSION_AMBIGUOUS)
      {
         outReason = "UNKNOWN outcome but reason_code is not REASON_EXECUTION_SUBMISSION_AMBIGUOUS - violates the outcome invariant";
         return false;
      }
      if(expectedStatus == SUBMISSION_STATUS_REJECTED &&
         reasonVal != REASON_BROKER_REJECT && reasonVal != REASON_INVALID_STOPS &&
         reasonVal != REASON_INSUFFICIENT_MARGIN && reasonVal != REASON_REQUOTE)
      {
         outReason = "REJECTED outcome but reason_code is not one of the explicit rejection reasons - violates the outcome invariant";
         return false;
      }
   }

   // Idempotent replay - identical to the attempt-side rule above.
   int dupIdx = SubmissionOutcomeProjection_FindByLogEventId(e.base.log_event_id);
   if(dupIdx >= 0)
   {
      SubmissionOutcomeProjectionRecord existing = g_SubOutcomeProj_Records[dupIdx];
      if(existing.execution_request_id == requestId && existing.execution_request_hash == requestHash &&
         existing.submission_status == expectedStatus && existing.source_sequence_number == e.base.sequence_number)
      {
         outReason = "duplicate outcome event replay - identical log_event_id already applied, not re-applied";
         return true;
      }
      outReason = StringFormat("log_event_id collision: '%s' already registered with a DIFFERENT outcome payload - rejected as a conflict, not a duplicate",
                                e.base.log_event_id);
      return false;
   }

   // Ordering/orphan check - the sibling pair this commit itself owns:
   // a matching attempt MUST already be applied earlier in this same
   // interleaved pass. A completion before its own attempt (bad
   // ordering) and a reference to an attempt that never happened at all
   // both fail here identically, by design - same rule C1.3 already
   // froze for its own ExecutionRequestProjection/DryRunResultProjection
   // pair.
   if(!SubmissionAttemptProjection_HasAnyFor(requestId, requestHash))
   {
      outReason = "orphan submission outcome: execution_request_id '" + requestId + "' has no matching EXECUTION_SUBMISSION_ATTEMPTED "
                  "applied so far in this store - either a genuine orphan or an ordering violation (an outcome before its own attempt), "
                  "both rejected identically - rejected";
      return false;
   }

   SubmissionOutcomeProjectionRecord rec;
   SubmissionOutcomeProjectionRecord_Init(rec);
   rec.execution_submission_result_schema_version = schemaVersion;
   rec.execution_request_id = requestId;
   rec.execution_request_hash = requestHash;
   rec.correlation_id = correlationId;
   rec.submit_attempt = submitAttempt;
   rec.submission_status = expectedStatus;
   rec.order_send_returned = orderSendReturned;
   rec.terminal_last_error = EventSerializer_GetInt(line, "terminal_last_error");
   rec.retcode = (uint)EventSerializer_GetLong(line, "retcode");
   rec.retcode_external = EventSerializer_GetInt(line, "retcode_external");
   rec.request_id = EventSerializer_GetLong(line, "request_id");
   rec.order_ticket = (ulong)EventSerializer_GetLong(line, "order_ticket");
   rec.deal_ticket = (ulong)EventSerializer_GetLong(line, "deal_ticket");
   rec.requested_price = EventSerializer_GetDouble(line, "requested_price");
   rec.observed_submit_price = EventSerializer_GetDouble(line, "observed_submit_price");
   rec.submission_timestamp = (datetime)EventSerializer_GetLong(line, "submission_timestamp");
   rec.reason_code = reasonVal;
   rec.source_sequence_number = e.base.sequence_number;
   rec.source_log_event_id = e.base.log_event_id;

   SubmissionOutcomeProjection_AppendRecord(rec);
   outReason = "applied - new submission outcome registered";
   return true;
}

//---------------------------------------------------------------------
// SubmissionAttemptRegistry - the frozen, consumer-facing query
// interface from Docs/PhaseC_C2_1_BrokerSubmissionContract.md's
// "Durable idempotency - C2.3's first deliverable" section. Any other
// layer (the future C2.2 integration patch) calls ONLY these two
// functions - no parsing/replay logic is ever duplicated outside this
// file.
//---------------------------------------------------------------------
bool SubmissionAttemptRegistry_HasAttempt(string executionRequestId)
{
   for(int i = 0; i < g_SubAttemptProj_Count; i++)
      if(g_SubAttemptProj_Records[i].execution_request_id == executionRequestId)
         return true;
   return false;
}

// True only if an attempt exists for this id AND no conclusive outcome
// (any of SUBMITTED/REJECTED/ERROR/UNKNOWN) has been durably recorded
// for it yet. A request never attempted at all is not "unresolved" -
// it simply was never submitted.
bool SubmissionAttemptRegistry_IsUnresolved(string executionRequestId)
{
   if(!SubmissionAttemptRegistry_HasAttempt(executionRequestId))
      return false;

   for(int i = 0; i < g_SubOutcomeProj_Count; i++)
      if(g_SubOutcomeProj_Records[i].execution_request_id == executionRequestId)
         return false;

   return true;
}

//---------------------------------------------------------------------
// Combined rebuild - stages C1.3's own ExecutionAuditProjection_
// RebuildFromFile (unmodified black-box gate, whole file, first), then
// ONE new, genuinely interleaved pass over this commit's own sibling
// pair (EXECUTION_SUBMISSION_ATTEMPTED and the outcome quartet).
//---------------------------------------------------------------------
struct BrokerSubmissionAuditProjectionReport
{
   bool   ok;
   int    lines_total;
   int    attempt_lines_applied;
   int    outcome_lines_applied;
   int    lines_skipped;
   int    lines_failed;
   string first_error;
};

void BrokerSubmissionAuditProjectionReport_Init(BrokerSubmissionAuditProjectionReport &r)
{
   r.ok = true;
   r.lines_total = 0;
   r.attempt_lines_applied = 0;
   r.outcome_lines_applied = 0;
   r.lines_skipped = 0;
   r.lines_failed = 0;
   r.first_error = "";
}

BrokerSubmissionAuditProjectionReport BrokerSubmissionAuditProjection_RebuildFromFile(string fileName)
{
   BrokerSubmissionAuditProjectionReport report;
   BrokerSubmissionAuditProjectionReport_Init(report);

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

   SubmissionAttemptProjection_Reset();
   SubmissionOutcomeProjection_Reset();

   string attemptType = EventTypeToString(EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED);
   string errType     = EventTypeToString(EVENT_TYPE_ORDER_SUBMISSION_ERROR);
   string subType     = EventTypeToString(EVENT_TYPE_ORDER_SUBMITTED);
   string rejType     = EventTypeToString(EVENT_TYPE_ORDER_REJECTED);
   string unkType     = EventTypeToString(EVENT_TYPE_EXECUTION_SUBMISSION_UNKNOWN);

   for(int i = 0; i < n; i++)
   {
      if(!EventSerializer_HasKey(lines[i], "type"))
      {
         report.lines_skipped++;
         continue;
      }
      string lineType = EventSerializer_GetStr(lines[i], "type");

      bool isAttempt = (lineType == attemptType);
      bool isOutcome = (lineType == errType || lineType == subType || lineType == rejType || lineType == unkType);

      if(!isAttempt && !isOutcome)
      {
         report.lines_skipped++;
         continue;
      }

      string reason;
      bool applied;
      bool countIncreased;
      if(isAttempt)
      {
         int beforeCount = SubmissionAttemptProjection_Count();
         applied = SubmissionAttemptProjection_ApplyLineWithLineage(lines[i], reason);
         countIncreased = SubmissionAttemptProjection_Count() > beforeCount;
         if(applied && countIncreased)
            report.attempt_lines_applied++;
      }
      else
      {
         int beforeCount = SubmissionOutcomeProjection_Count();
         applied = SubmissionOutcomeProjection_ApplyLineWithLineage(lines[i], reason);
         countIncreased = SubmissionOutcomeProjection_Count() > beforeCount;
         if(applied && countIncreased)
            report.outcome_lines_applied++;
      }

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
// BrokerSubmissionReconciliationReport - one row per distinct
// execution_request_id with >=1 applied SubmissionAttemptProjection
// record. latest_status reuses ENUM_SUBMISSION_STATUS verbatim -
// SUBMISSION_STATUS_NONE stands for "NO_OUTCOME" (an attempt exists
// with no outcome yet), never produced by any real outcome line, so
// there is no collision with a genuine ERROR/REJECTED/SUBMITTED/
// UNKNOWN row. Computed only after a clean rebuild.
//---------------------------------------------------------------------
struct BrokerSubmissionReconciliationRow
{
   string execution_request_id;
   string execution_request_hash;
   ENUM_SUBMISSION_STATUS latest_status; // SUBMISSION_STATUS_NONE == NO_OUTCOME
   long   latest_outcome_sequence_number;
   int    attempt_count;
};

BrokerSubmissionReconciliationRow g_BrokerSubReconcile_Rows[];
int                               g_BrokerSubReconcile_Count = 0;

void BrokerSubmissionReconciliation_Reset()
{
   ArrayResize(g_BrokerSubReconcile_Rows, 0);
   g_BrokerSubReconcile_Count = 0;
}

int BrokerSubmissionReconciliation_Count() { return g_BrokerSubReconcile_Count; }

bool BrokerSubmissionReconciliation_GetAt(int index, BrokerSubmissionReconciliationRow &out)
{
   if(index < 0 || index >= g_BrokerSubReconcile_Count) return false;
   out = g_BrokerSubReconcile_Rows[index];
   return true;
}

int BrokerSubmissionReconciliation_FindRowIndex(string executionRequestId)
{
   for(int i = 0; i < g_BrokerSubReconcile_Count; i++)
      if(g_BrokerSubReconcile_Rows[i].execution_request_id == executionRequestId)
         return i;
   return -1;
}

void BrokerSubmissionReconciliation_Build()
{
   BrokerSubmissionReconciliation_Reset();

   for(int i = 0; i < SubmissionAttemptProjection_Count(); i++)
   {
      SubmissionAttemptProjectionRecord rec;
      SubmissionAttemptProjection_GetAt(i, rec);

      int idx = BrokerSubmissionReconciliation_FindRowIndex(rec.execution_request_id);
      if(idx < 0)
      {
         BrokerSubmissionReconciliationRow row;
         row.execution_request_id = rec.execution_request_id;
         row.execution_request_hash = rec.execution_request_hash;
         row.latest_status = SUBMISSION_STATUS_NONE;
         row.latest_outcome_sequence_number = 0;
         row.attempt_count = 1;

         int newIdx = g_BrokerSubReconcile_Count;
         ArrayResize(g_BrokerSubReconcile_Rows, newIdx + 1);
         g_BrokerSubReconcile_Rows[newIdx] = row;
         g_BrokerSubReconcile_Count++;
      }
      else
      {
         g_BrokerSubReconcile_Rows[idx].attempt_count++;
      }
   }

   for(int i = 0; i < SubmissionOutcomeProjection_Count(); i++)
   {
      SubmissionOutcomeProjectionRecord rec;
      SubmissionOutcomeProjection_GetAt(i, rec);

      int idx = BrokerSubmissionReconciliation_FindRowIndex(rec.execution_request_id);
      if(idx < 0)
         continue; // cannot happen - the orphan check at apply time already guarantees an attempt row exists

      if(rec.source_sequence_number > g_BrokerSubReconcile_Rows[idx].latest_outcome_sequence_number)
      {
         g_BrokerSubReconcile_Rows[idx].latest_status = rec.submission_status;
         g_BrokerSubReconcile_Rows[idx].latest_outcome_sequence_number = rec.source_sequence_number;
      }
   }
}

#endif // __MLQUANTAI_BROKERSUBMISSIONAUDITPROJECTION_MQH__
