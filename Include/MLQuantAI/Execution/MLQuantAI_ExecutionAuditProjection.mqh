//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_ExecutionAuditProjection.mqh     |
//| Phase C1.3: read-only audit projections over the durable          |
//| EXECUTION_REQUEST_CREATED/EXECUTION_DRY_RUN_COMPLETED events C1.2  |
//| already writes, plus a reconciliation report over both. Per        |
//| Docs/PhaseC_C1_1_ExecutionRequestContract.md's C1.3 addendum.      |
//|                                                                    |
//| Strictly additive and read-only: no B5-B9/C1.1/C1.2 sealed file    |
//| touched, no broker query, no broker mutation, no candidate-        |
//| lifecycle transition, no event append here.                        |
//|                                                                    |
//| Two frozen corrections to the precedent every prior *Projection.mqh|
//| in this project follows:                                           |
//|  1. An orphan EXECUTION_DRY_RUN_COMPLETED (referencing a request   |
//|     not yet seen) fails the WHOLE rebuild - it can never surface   |
//|     as a soft reconciliation status.                                |
//|  2. ExecutionRequestProjection and DryRunResultProjection are built|
//|     together in ONE single, sequential, interleaved pass over the  |
//|     file, in strict line order - a naive two-pass design (rebuild  |
//|     requests from the whole file, then check completions) would    |
//|     silently fail to catch a completion appearing before its own   |
//|     request in file order, since the request projection would      |
//|     already have seen the entire file by the time completions are  |
//|     checked. This makes event ordering a genuinely tested invariant|
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EXECUTIONAUDITPROJECTION_MQH__
#define __MLQUANTAI_EXECUTIONAUDITPROJECTION_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventStoreValidator.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_RiskPlanProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_AIDecisionProjection.mqh"
#include "MLQuantAI_EligibilityDecisionProjection.mqh"
#include "MLQuantAI_ExecutionRequestContract.mqh"

#define MLQUANTAI_EXECAUDITPROJ_MAX_LINE_LENGTH 65536

//---------------------------------------------------------------------
// ExecutionRequestProjection - 1 record per execution_request_id.
//---------------------------------------------------------------------
struct ExecutionRequestProjectionRecord
{
   string execution_request_schema_version;

   string execution_request_id;
   string execution_request_hash;

   string candidate_id;
   string candidate_hash;
   string risk_plan_id;
   string plan_hash;
   string ai_decision_id;
   string ai_decision_hash;
   string eligibility_decision_id;
   string eligibility_decision_hash;

   string execution_policy_version;

   string correlation_id;
   int    submit_attempt;

   ENUM_ORDER_TYPE side;
   double          planned_entry;
   double          planned_sl;
   double          planned_tp;
   double          lot_size;
   double          risk_amount;

   long   source_sequence_number;
   string source_log_event_id;
};

void ExecutionRequestProjectionRecord_Init(ExecutionRequestProjectionRecord &r)
{
   r.execution_request_schema_version = "";
   r.execution_request_id = "";
   r.execution_request_hash = "";
   r.candidate_id = "";
   r.candidate_hash = "";
   r.risk_plan_id = "";
   r.plan_hash = "";
   r.ai_decision_id = "";
   r.ai_decision_hash = "";
   r.eligibility_decision_id = "";
   r.eligibility_decision_hash = "";
   r.execution_policy_version = "";
   r.correlation_id = "";
   r.submit_attempt = 0;
   r.side = ORDER_TYPE_BUY;
   r.planned_entry = 0;
   r.planned_sl = 0;
   r.planned_tp = 0;
   r.lot_size = 0;
   r.risk_amount = 0;
   r.source_sequence_number = 0;
   r.source_log_event_id = "";
}

ExecutionRequestProjectionRecord g_ExecReqProj_Records[];
int                              g_ExecReqProj_Count = 0;

void ExecutionRequestProjection_Reset()
{
   ArrayResize(g_ExecReqProj_Records, 0);
   g_ExecReqProj_Count = 0;
}

int ExecutionRequestProjection_Count() { return g_ExecReqProj_Count; }

int ExecutionRequestProjection_FindIndex(string executionRequestId)
{
   for(int i = 0; i < g_ExecReqProj_Count; i++)
      if(g_ExecReqProj_Records[i].execution_request_id == executionRequestId)
         return i;
   return -1;
}

bool ExecutionRequestProjection_TryGet(string executionRequestId, ExecutionRequestProjectionRecord &out)
{
   int idx = ExecutionRequestProjection_FindIndex(executionRequestId);
   if(idx < 0) return false;
   out = g_ExecReqProj_Records[idx];
   return true;
}

bool ExecutionRequestProjection_GetAt(int index, ExecutionRequestProjectionRecord &out)
{
   if(index < 0 || index >= g_ExecReqProj_Count) return false;
   out = g_ExecReqProj_Records[index];
   return true;
}

void ExecutionRequestProjection_AppendRecord(const ExecutionRequestProjectionRecord &rec)
{
   int idx = g_ExecReqProj_Count;
   ArrayResize(g_ExecReqProj_Records, idx + 1);
   g_ExecReqProj_Records[idx] = rec;
   g_ExecReqProj_Count++;
}

//---------------------------------------------------------------------
// DryRunResultProjection - 0..N records per execution_request_id,
// never deduped (each is a distinct real evaluation).
//---------------------------------------------------------------------
struct DryRunResultProjectionRecord
{
   string dry_run_result_schema_version;

   string execution_request_id;
   string execution_request_hash;

   ENUM_SAFETY_GATE_DECISION decision;
   ENUM_REASON_CODE          reason_code;

   string observed_symbol;
   long   observed_account_login;

   long   source_sequence_number;
   string source_log_event_id;
};

void DryRunResultProjectionRecord_Init(DryRunResultProjectionRecord &r)
{
   r.dry_run_result_schema_version = "";
   r.execution_request_id = "";
   r.execution_request_hash = "";
   r.decision = SAFETY_GATE_NONE;
   r.reason_code = REASON_NONE;
   r.observed_symbol = "";
   r.observed_account_login = 0;
   r.source_sequence_number = 0;
   r.source_log_event_id = "";
}

DryRunResultProjectionRecord g_DryRunProj_Records[];
int                          g_DryRunProj_Count = 0;

void DryRunResultProjection_Reset()
{
   ArrayResize(g_DryRunProj_Records, 0);
   g_DryRunProj_Count = 0;
}

int DryRunResultProjection_Count() { return g_DryRunProj_Count; }

bool DryRunResultProjection_GetAt(int index, DryRunResultProjectionRecord &out)
{
   if(index < 0 || index >= g_DryRunProj_Count) return false;
   out = g_DryRunProj_Records[index];
   return true;
}

void DryRunResultProjection_AppendRecord(const DryRunResultProjectionRecord &rec)
{
   int idx = g_DryRunProj_Count;
   ArrayResize(g_DryRunProj_Records, idx + 1);
   g_DryRunProj_Records[idx] = rec;
   g_DryRunProj_Count++;
}

// True if at least one applied DryRunResultProjection record matches
// this exact execution_request_id/execution_request_hash pair.
bool DryRunResultProjection_HasAnyFor(string executionRequestId, string executionRequestHash)
{
   for(int i = 0; i < g_DryRunProj_Count; i++)
      if(g_DryRunProj_Records[i].execution_request_id == executionRequestId &&
         g_DryRunProj_Records[i].execution_request_hash == executionRequestHash)
         return true;
   return false;
}

//---------------------------------------------------------------------
// ExecutionRequestProjection line application.
//---------------------------------------------------------------------
bool ExecutionRequestProjection_ApplyLine(string line, string &outReason)
{
   if(StringLen(line) > MLQUANTAI_EXECAUDITPROJ_MAX_LINE_LENGTH)
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

   string schemaVersion   = EventSerializer_GetStr(line, "execution_request_schema_version");
   string requestId        = EventSerializer_GetStr(line, "execution_request_id");
   string requestHash       = EventSerializer_GetStr(line, "execution_request_hash");
   string candidateId        = EventSerializer_GetStr(line, "candidate_id");
   string candidateHash       = EventSerializer_GetStr(line, "candidate_hash");
   string riskPlanId            = EventSerializer_GetStr(line, "risk_plan_id");
   string planHash                = EventSerializer_GetStr(line, "plan_hash");
   string aiDecisionId              = EventSerializer_GetStr(line, "ai_decision_id");
   string aiDecisionHash              = EventSerializer_GetStr(line, "ai_decision_hash");
   string eligibilityDecisionId         = EventSerializer_GetStr(line, "eligibility_decision_id");
   string eligibilityDecisionHash         = EventSerializer_GetStr(line, "eligibility_decision_hash");
   string executionPolicyVersion            = EventSerializer_GetStr(line, "execution_policy_version");
   string correlationId                       = EventSerializer_GetStr(line, "correlation_id");

   if(schemaVersion == "" || requestId == "" || requestHash == "" || candidateId == "" || candidateHash == "" ||
      riskPlanId == "" || planHash == "" || aiDecisionId == "" || aiDecisionHash == "" ||
      eligibilityDecisionId == "" || eligibilityDecisionHash == "" || executionPolicyVersion == "" || correlationId == "")
   {
      outReason = "missing a required ExecutionRequest field";
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
      outReason = "submit_attempt is not 1 - C1 never produces any other value";
      return false;
   }

   string sideStr = EventSerializer_GetStr(line, "side");
   if(sideStr != "BUY" && sideStr != "SELL")
   {
      outReason = "side is neither BUY nor SELL";
      return false;
   }
   ENUM_ORDER_TYPE side = (sideStr == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double plannedEntry = EventSerializer_GetDouble(line, "planned_entry");
   double plannedSl       = EventSerializer_GetDouble(line, "planned_sl");
   double plannedTp         = EventSerializer_GetDouble(line, "planned_tp");
   double lotSize             = EventSerializer_GetDouble(line, "lot_size");
   double riskAmount            = EventSerializer_GetDouble(line, "risk_amount");

   if(!MathIsValidNumber(plannedEntry) || !MathIsValidNumber(plannedSl) || !MathIsValidNumber(plannedTp) ||
      !MathIsValidNumber(lotSize) || !MathIsValidNumber(riskAmount))
   {
      outReason = "planned_entry/planned_sl/planned_tp/lot_size/risk_amount contains NaN or Inf";
      return false;
   }

   if(correlationId != Ids_CorrelationId(candidateId, submitAttempt))
   {
      outReason = "correlation_id does not match Ids_CorrelationId(candidate_id, submit_attempt) - tampered or corrupted";
      return false;
   }

   string recomputedId = Ids_ExecutionRequestId(candidateId, eligibilityDecisionId, aiDecisionId, riskPlanId, executionPolicyVersion);
   if(recomputedId != requestId)
   {
      outReason = "execution_request_id does not match a fresh recompute from its own persisted lineage fields - tampered or corrupted";
      return false;
   }

   ExecutionRequestProjectionRecord candidate;
   ExecutionRequestProjectionRecord_Init(candidate);
   candidate.execution_request_schema_version = schemaVersion;
   candidate.execution_request_id = requestId;
   candidate.execution_request_hash = requestHash;
   candidate.candidate_id = candidateId;
   candidate.candidate_hash = candidateHash;
   candidate.risk_plan_id = riskPlanId;
   candidate.plan_hash = planHash;
   candidate.ai_decision_id = aiDecisionId;
   candidate.ai_decision_hash = aiDecisionHash;
   candidate.eligibility_decision_id = eligibilityDecisionId;
   candidate.eligibility_decision_hash = eligibilityDecisionHash;
   candidate.execution_policy_version = executionPolicyVersion;
   candidate.correlation_id = correlationId;
   candidate.submit_attempt = submitAttempt;
   candidate.side = side;
   candidate.planned_entry = plannedEntry;
   candidate.planned_sl = plannedSl;
   candidate.planned_tp = plannedTp;
   candidate.lot_size = lotSize;
   candidate.risk_amount = riskAmount;

   string recomputedHash = ExecutionRequest_ComputeHash(candidate);
   if(recomputedHash != requestHash)
   {
      outReason = "execution_request_hash does not match a fresh recompute from the persisted payload - tampered or corrupted";
      return false;
   }

   int existingIdx = ExecutionRequestProjection_FindIndex(requestId);
   if(existingIdx >= 0)
   {
      if(g_ExecReqProj_Records[existingIdx].execution_request_hash == requestHash)
      {
         outReason = "duplicate execution_request_id - already registered with an identical execution_request_hash, not re-applied";
         return true;
      }
      outReason = StringFormat("execution_request_id collision: '%s' already registered with execution_request_hash '%s', "
                                "this line carries a DIFFERENT execution_request_hash '%s' - rejected as a conflict, not a duplicate",
                                requestId, g_ExecReqProj_Records[existingIdx].execution_request_hash, requestHash);
      return false;
   }

   candidate.source_sequence_number = e.base.sequence_number;
   candidate.source_log_event_id    = e.base.log_event_id;

   ExecutionRequestProjection_AppendRecord(candidate);
   outReason = "applied - new execution request registered";
   return true;
}

// Referential-integrity-aware variant: rejects a request whose RiskPlan/
// AIDecision/EligibilityDecision lineage don't resolve against the
// already-rebuilt upstream registries BEFORE ever calling ApplyLine.
bool ExecutionRequestProjection_ApplyLineWithLineage(string line, string &outReason)
{
   string riskPlanId    = EventSerializer_GetStr(line, "risk_plan_id");
   string planHash        = EventSerializer_GetStr(line, "plan_hash");
   string candidateId       = EventSerializer_GetStr(line, "candidate_id");
   string candidateHash      = EventSerializer_GetStr(line, "candidate_hash");

   RiskPlanProjectionRecord planRecord;
   if(!RiskPlanProjection_TryGet(riskPlanId, planRecord))
   {
      outReason = "orphan execution request: risk_plan_id '" + riskPlanId + "' has no matching RISK_PLAN_CREATED event in this store - rejected";
      return false;
   }
   if(planRecord.plan_hash != planHash || planRecord.candidate_id != candidateId || planRecord.candidate_hash != candidateHash)
   {
      outReason = "RiskPlan lineage mismatch: execution request's plan_hash/candidate_id/candidate_hash "
                  "does not match the referenced RiskPlanProjection record - rejected";
      return false;
   }

   string aiDecisionId    = EventSerializer_GetStr(line, "ai_decision_id");
   string aiDecisionHash    = EventSerializer_GetStr(line, "ai_decision_hash");

   AIDecisionProjectionRecord aiRecord;
   if(!AIDecisionProjection_TryGet(aiDecisionId, aiRecord))
   {
      outReason = "orphan execution request: ai_decision_id '" + aiDecisionId + "' has no matching AI_DECISION_CREATED event in this store - rejected";
      return false;
   }
   if(aiRecord.ai_decision_hash != aiDecisionHash || aiRecord.candidate_id != candidateId || aiRecord.candidate_hash != candidateHash)
   {
      outReason = "AIDecision lineage mismatch: execution request's ai_decision_hash/candidate_id/candidate_hash "
                  "does not match the referenced AIDecisionProjection record - rejected";
      return false;
   }

   string eligibilityDecisionId    = EventSerializer_GetStr(line, "eligibility_decision_id");
   string eligibilityDecisionHash    = EventSerializer_GetStr(line, "eligibility_decision_hash");

   EligibilityDecisionProjectionRecord eligRecord;
   if(!EligibilityDecisionProjection_TryGet(eligibilityDecisionId, eligRecord))
   {
      outReason = "orphan execution request: eligibility_decision_id '" + eligibilityDecisionId + "' has no matching EXECUTION_ELIGIBILITY_DECIDED event in this store - rejected";
      return false;
   }
   if(eligRecord.eligibility_decision_hash != eligibilityDecisionHash || eligRecord.candidate_id != candidateId || eligRecord.candidate_hash != candidateHash)
   {
      outReason = "EligibilityDecision lineage mismatch: execution request's eligibility_decision_hash/candidate_id/candidate_hash "
                  "does not match the referenced EligibilityDecisionProjection record - rejected";
      return false;
   }
   if(eligRecord.decision != ELIGIBILITY_DECISION_ELIGIBLE)
   {
      outReason = "the referenced EligibilityDecision is not ELIGIBLE - an ExecutionRequest may only be built from an ELIGIBLE decision";
      return false;
   }

   return ExecutionRequestProjection_ApplyLine(line, outReason);
}

//---------------------------------------------------------------------
// DryRunResultProjection line application.
//---------------------------------------------------------------------
bool DryRunResultProjection_ApplyLine(string line, string &outReason)
{
   if(StringLen(line) > MLQUANTAI_EXECAUDITPROJ_MAX_LINE_LENGTH)
   {
      outReason = "line exceeds the defensive length bound - rejected before parsing";
      return false;
   }

   if(StringFind(line, "\"ticket\"") >= 0 || StringFind(line, "\"retcode\"") >= 0 ||
      StringFind(line, "\"fill_price\"") >= 0 || StringFind(line, "\"slippage_points\"") >= 0)
   {
      outReason = "a ticket/retcode/fill_price/slippage_points field is present - real C1 emission never writes these, "
                  "this is evidence of corruption or a foreign line";
      return false;
   }

   SystemEvent e;
   if(!EventSerializer_ParseSystem(line, e))
   {
      outReason = "not a parsable event line";
      return false;
   }

   string schemaVersion  = EventSerializer_GetStr(line, "dry_run_result_schema_version");
   string requestId        = EventSerializer_GetStr(line, "execution_request_id");
   string requestHash        = EventSerializer_GetStr(line, "execution_request_hash");
   string decisionStr          = EventSerializer_GetStr(line, "decision");
   string reasonCodeStr          = EventSerializer_GetStr(line, "reason_code");
   string observedSymbol           = EventSerializer_GetStr(line, "observed_symbol");

   if(schemaVersion == "" || requestId == "" || requestHash == "" || decisionStr == "" || reasonCodeStr == "")
   {
      outReason = "missing a required DryRunExecutionResult field";
      return false;
   }
   if(!EventSerializer_HasKey(line, "observed_account_login"))
   {
      outReason = "missing observed_account_login";
      return false;
   }
   long observedLogin = EventSerializer_GetLong(line, "observed_account_login");

   ENUM_SAFETY_GATE_DECISION decision = SafetyGateDecisionFromString(decisionStr);
   ENUM_REASON_CODE reasonCode        = ReasonCodeFromString(reasonCodeStr);

   if(decision == SAFETY_GATE_ACCEPTED && reasonCode != REASON_NONE)
   {
      outReason = "decision is ACCEPTED but reason_code is not REASON_NONE - violates the outcome invariant";
      return false;
   }
   if(decision == SAFETY_GATE_REJECTED && reasonCode == REASON_NONE)
   {
      outReason = "decision is REJECTED but reason_code is REASON_NONE - violates the outcome invariant";
      return false;
   }
   if(decision != SAFETY_GATE_ACCEPTED && decision != SAFETY_GATE_REJECTED)
   {
      outReason = "decision is neither ACCEPTED nor REJECTED";
      return false;
   }

   DryRunResultProjectionRecord rec;
   DryRunResultProjectionRecord_Init(rec);
   rec.dry_run_result_schema_version = schemaVersion;
   rec.execution_request_id = requestId;
   rec.execution_request_hash = requestHash;
   rec.decision = decision;
   rec.reason_code = reasonCode;
   rec.observed_symbol = observedSymbol;
   rec.observed_account_login = observedLogin;
   rec.source_sequence_number = e.base.sequence_number;
   rec.source_log_event_id    = e.base.log_event_id;

   DryRunResultProjection_AppendRecord(rec);
   outReason = "applied - new dry-run result registered";
   return true;
}

// Referential-integrity-aware variant: the referenced execution_request_id
// must ALREADY be applied to ExecutionRequestProjection AT THIS POINT in
// the single interleaved scan - a completion appearing before its own
// request (bad ordering) or referencing a request that doesn't exist at
// all both fail here identically, by design (see this file's header).
bool DryRunResultProjection_ApplyLineWithLineage(string line, string &outReason)
{
   string requestId   = EventSerializer_GetStr(line, "execution_request_id");
   string requestHash   = EventSerializer_GetStr(line, "execution_request_hash");

   ExecutionRequestProjectionRecord reqRecord;
   if(!ExecutionRequestProjection_TryGet(requestId, reqRecord))
   {
      outReason = "orphan dry-run result: execution_request_id '" + requestId + "' has no matching EXECUTION_REQUEST_CREATED event "
                  "applied so far in this store - either a genuine orphan or an ordering violation (a completion before its own "
                  "request), both rejected identically - rejected";
      return false;
   }
   if(reqRecord.execution_request_hash != requestHash)
   {
      outReason = "the completion's execution_request_hash does not match the referenced ExecutionRequestProjection record's own hash - rejected";
      return false;
   }

   return DryRunResultProjection_ApplyLine(line, outReason);
}

//---------------------------------------------------------------------
// Combined rebuild - ONE single, sequential, interleaved pass. Gated on
// EventStoreValidator, then EligibilityDecisionProjection_RebuildFromFile
// (which itself transitively rebuilds RiskPlanProjection/
// AIDecisionProjection/FeatureSnapshotProjection/ModelArtifactProjection) -
// if that fails, THIS registry is left completely untouched.
//---------------------------------------------------------------------
struct ExecutionAuditProjectionReport
{
   bool   ok;
   int    lines_total;
   int    request_lines_applied;
   int    result_lines_applied;
   int    lines_skipped;
   int    lines_failed;
   string first_error;
};

void ExecutionAuditProjectionReport_Init(ExecutionAuditProjectionReport &r)
{
   r.ok = true;
   r.lines_total = 0;
   r.request_lines_applied = 0;
   r.result_lines_applied = 0;
   r.lines_skipped = 0;
   r.lines_failed = 0;
   r.first_error = "";
}

ExecutionAuditProjectionReport ExecutionAuditProjection_RebuildFromFile(string fileName)
{
   ExecutionAuditProjectionReport report;
   ExecutionAuditProjectionReport_Init(report);

   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);
   report.lines_total = n;

   EventStoreValidationReport validation = EventStoreValidator_ValidateLines(lines);
   if(!validation.ok)
   {
      report.ok = false;
      report.first_error = "event store failed validation - rebuild refused, registry left unchanged: " + validation.first_error;
      return report;
   }

   EligibilityDecisionProjectionReport eligReport = EligibilityDecisionProjection_RebuildFromFile(fileName);
   if(!eligReport.ok)
   {
      report.ok = false;
      report.first_error = "eligibility decision registry failed to rebuild from the same store - rebuild refused, registry left unchanged: " + eligReport.first_error;
      return report;
   }

   ExecutionRequestProjection_Reset();
   DryRunResultProjection_Reset();

   string requestType = EventTypeToString(EVENT_TYPE_EXECUTION_REQUEST_CREATED);
   string resultType  = EventTypeToString(EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED);

   for(int i = 0; i < n; i++)
   {
      if(!EventSerializer_HasKey(lines[i], "type"))
      {
         report.lines_skipped++;
         continue;
      }
      string lineType = EventSerializer_GetStr(lines[i], "type");

      if(lineType != requestType && lineType != resultType)
      {
         report.lines_skipped++;
         continue;
      }

      string reason;
      bool applied;
      bool countIncreased;
      if(lineType == requestType)
      {
         int beforeCount = ExecutionRequestProjection_Count();
         applied = ExecutionRequestProjection_ApplyLineWithLineage(lines[i], reason);
         countIncreased = ExecutionRequestProjection_Count() > beforeCount;
         if(applied && countIncreased)
            report.request_lines_applied++;
      }
      else
      {
         int beforeCount = DryRunResultProjection_Count();
         applied = DryRunResultProjection_ApplyLineWithLineage(lines[i], reason);
         countIncreased = DryRunResultProjection_Count() > beforeCount;
         if(applied && countIncreased)
            report.result_lines_applied++;
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
         report.lines_skipped++; // applied but a no-op - e.g. a duplicate execution_request_id/hash pair
   }

   return report;
}

//---------------------------------------------------------------------
// Reconciliation report - computed only after a clean rebuild.
//---------------------------------------------------------------------
struct ExecutionReconciliationReport
{
   int    total_requests;
   int    paired_count;
   int    unpaired_count;
   string first_unpaired_request_id;
};

void ExecutionReconciliationReport_Init(ExecutionReconciliationReport &r)
{
   r.total_requests = 0;
   r.paired_count = 0;
   r.unpaired_count = 0;
   r.first_unpaired_request_id = "";
}

ExecutionReconciliationReport ExecutionReconciliation_BuildReport()
{
   ExecutionReconciliationReport report;
   ExecutionReconciliationReport_Init(report);

   report.total_requests = ExecutionRequestProjection_Count();
   for(int i = 0; i < ExecutionRequestProjection_Count(); i++)
   {
      ExecutionRequestProjectionRecord rec;
      ExecutionRequestProjection_GetAt(i, rec);
      if(DryRunResultProjection_HasAnyFor(rec.execution_request_id, rec.execution_request_hash))
      {
         report.paired_count++;
      }
      else
      {
         report.unpaired_count++;
         if(report.first_unpaired_request_id == "")
            report.first_unpaired_request_id = rec.execution_request_id;
      }
   }
   return report;
}

#endif // __MLQUANTAI_EXECUTIONAUDITPROJECTION_MQH__
