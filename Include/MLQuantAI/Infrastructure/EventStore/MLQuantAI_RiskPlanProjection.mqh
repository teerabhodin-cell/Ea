//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_RiskPlanProjection.mqh|
//| Phase B7 Commit 2 (B7.5): a read-only RiskPlan registry projected  |
//| from persisted RISK_PLAN_CREATED lines, mirroring                  |
//| MLQuantAI_CandidateProjection.mqh's exact structure and hardening  |
//| discipline (schema/required-field/numerical validation,            |
//| payload-aware collision-vs-duplicate detection, referential         |
//| integrity, EventStoreValidator-gated atomic rebuild). See           |
//| Docs/PhaseB_B7_RiskPlanContract.md's B7 Commit 2 addendum for the    |
//| full contract this file implements.                                 |
//|                                                                    |
//| Strictly additive and read-only: no B5/B6 sealed file touched, no  |
//| live market/broker/account call, no event append here (that's       |
//| MLQuantAI_RiskPlanEventEmission.mqh). Depends on                    |
//| MLQuantAI_CandidateProjection.mqh (rebuilt from the SAME file        |
//| immediately before this one, as a referential-integrity              |
//| prerequisite) - the same dependency direction                       |
//| MLQuantAI_CandidateDatasetExport.mqh (B6.2) already has on it.       |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_RISKPLANPROJECTION_MQH__
#define __MLQUANTAI_RISKPLANPROJECTION_MQH__

#include "MLQuantAI_CandidateProjection.mqh"
#include "../../Core/MLQuantAI_RiskPlan.mqh"

#define MLQUANTAI_RISKPLANPROJ_MAX_LINE_LENGTH 65536

struct RiskPlanProjectionRecord
{
   string risk_plan_schema_version;
   string risk_plan_id;
   string candidate_id;
   string candidate_hash;
   string risk_context_hash;

   double planned_entry;
   double planned_sl;
   double planned_tp;

   double stop_distance_points;
   double rr_ratio;

   double risk_percent;
   double risk_amount;
   double lot_size;

   string sizing_method;
   string sizing_rules_version;

   string plan_hash;

   long   source_sequence_number; // audit trail: which event this record came from
   string source_log_event_id;
};

void RiskPlanProjectionRecord_Init(RiskPlanProjectionRecord &r)
{
   r.risk_plan_schema_version = "";
   r.risk_plan_id = "";
   r.candidate_id = "";
   r.candidate_hash = "";
   r.risk_context_hash = "";

   r.planned_entry = 0;
   r.planned_sl = 0;
   r.planned_tp = 0;

   r.stop_distance_points = 0;
   r.rr_ratio = 0;

   r.risk_percent = 0;
   r.risk_amount = 0;
   r.lot_size = 0;

   r.sizing_method = "";
   r.sizing_rules_version = "";

   r.plan_hash = "";

   r.source_sequence_number = 0;
   r.source_log_event_id = "";
}

RiskPlanProjectionRecord g_RiskPlanProj_Records[];
int                      g_RiskPlanProj_Count = 0;

void RiskPlanProjection_Reset()
{
   ArrayResize(g_RiskPlanProj_Records, 0);
   g_RiskPlanProj_Count = 0;
}

int RiskPlanProjection_Count() { return g_RiskPlanProj_Count; }

int RiskPlanProjection_FindIndex(string riskPlanId)
{
   for(int i = 0; i < g_RiskPlanProj_Count; i++)
      if(g_RiskPlanProj_Records[i].risk_plan_id == riskPlanId)
         return i;
   return -1;
}

bool RiskPlanProjection_TryGet(string riskPlanId, RiskPlanProjectionRecord &out)
{
   int idx = RiskPlanProjection_FindIndex(riskPlanId);
   if(idx < 0) return false;
   out = g_RiskPlanProj_Records[idx];
   return true;
}

bool RiskPlanProjection_GetAt(int index, RiskPlanProjectionRecord &out)
{
   if(index < 0 || index >= g_RiskPlanProj_Count) return false;
   out = g_RiskPlanProj_Records[index];
   return true;
}

void RiskPlanProjection_AppendRecord(const RiskPlanProjectionRecord &rec)
{
   int idx = g_RiskPlanProj_Count;
   ArrayResize(g_RiskPlanProj_Records, idx + 1);
   g_RiskPlanProj_Records[idx] = rec;
   g_RiskPlanProj_Count++;
}

// Live-session sync path - called directly by RiskPlan_EmitRiskPlanCreated
// right after a durable write, from the in-memory RiskPlan struct itself
// (no JSON round-trip needed, unlike the replay path below). Mirrors
// CRT_EmitCandidateCreated's own StateProjector_Apply call. Does NOT
// re-check for an existing record - RiskPlan_EmitRiskPlanCreated's own
// RiskPlanProjection_TryGet guard already ensured this risk_plan_id is
// new before writing.
void RiskPlanProjection_ApplyLiveRecord(const RiskPlan &p)
{
   RiskPlanProjectionRecord rec;
   RiskPlanProjectionRecord_Init(rec);
   rec.risk_plan_schema_version = p.risk_plan_schema_version;
   rec.risk_plan_id             = p.risk_plan_id;
   rec.candidate_id              = p.candidate_id;
   rec.candidate_hash            = p.candidate_hash;
   rec.risk_context_hash         = p.risk_context_hash;
   rec.planned_entry             = p.planned_entry;
   rec.planned_sl                = p.planned_sl;
   rec.planned_tp                = p.planned_tp;
   rec.stop_distance_points      = p.stop_distance_points;
   rec.rr_ratio                   = p.rr_ratio;
   rec.risk_percent               = p.risk_percent;
   rec.risk_amount                = p.risk_amount;
   rec.lot_size                    = p.lot_size;
   rec.sizing_method               = p.sizing_method;
   rec.sizing_rules_version        = p.sizing_rules_version;
   rec.plan_hash                   = p.plan_hash;
   // source_sequence_number/source_log_event_id stay at Init() defaults
   // (0/"") for a live-applied record - the durable append already
   // happened via EventStore_LogSystem, which owns the real seq/
   // log_event_id assignment; this function only mirrors the CONTENT
   // into the live registry, same as StateProjector_Apply does for
   // CRT_EmitCandidateCreated's own live-sync call.
   RiskPlanProjection_AppendRecord(rec);
}

//---------------------------------------------------------------------
// Validation helpers - mirrors CandidateProjection's own ladder.
//---------------------------------------------------------------------
string RiskPlanProjection_ValidateRequiredFields(string riskPlanId, string candidateId, string candidateHash,
                                                   string riskContextHash, string planHash, string sizingMethod,
                                                   string sizingRulesVersion)
{
   if(riskPlanId == "")         return "missing risk_plan_id";
   if(candidateId == "")        return "missing candidate_id";
   if(candidateHash == "")      return "missing candidate_hash";
   if(riskContextHash == "")    return "missing risk_context_hash";
   if(planHash == "")            return "missing plan_hash";
   if(sizingMethod == "")        return "missing sizing_method";
   if(sizingRulesVersion == "")  return "missing sizing_rules_version";
   return "";
}

string RiskPlanProjection_ValidateNumericalIntegrity(double plannedEntry, double plannedSl, double plannedTp,
                                                       double stopDistancePoints, double rrRatio,
                                                       double riskPercent, double riskAmount, double lotSize)
{
   if(!MathIsValidNumber(plannedEntry) || !MathIsValidNumber(plannedSl) || !MathIsValidNumber(plannedTp))
      return "planned_entry/planned_sl/planned_tp contains NaN or Inf";
   if(plannedEntry <= 0 || plannedSl <= 0 || plannedTp <= 0)
      return "planned_entry/planned_sl/planned_tp contains a zero/negative price";

   if(!MathIsValidNumber(stopDistancePoints) || stopDistancePoints <= 0)
      return "stop_distance_points is not a positive number";
   if(!MathIsValidNumber(rrRatio) || rrRatio < 0)
      return "rr_ratio is not a valid non-negative number";
   if(!MathIsValidNumber(riskPercent) || riskPercent <= 0)
      return "risk_percent is not a positive number";
   if(!MathIsValidNumber(riskAmount) || riskAmount <= 0)
      return "risk_amount is not a positive number";
   if(!MathIsValidNumber(lotSize) || lotSize <= 0)
      return "lot_size is not a positive number";
   return "";
}

//---------------------------------------------------------------------
// Applies one raw persisted line to the registry - the replay path.
//---------------------------------------------------------------------
bool RiskPlanProjection_ApplyLine(string line, string &outReason)
{
   if(StringLen(line) > MLQUANTAI_RISKPLANPROJ_MAX_LINE_LENGTH)
   {
      outReason = "line exceeds the defensive length bound - rejected before parsing";
      return false;
   }

   // Same two-part gate CandidateProjection_ApplyLine's own hardening
   // pass fixed: "type" key must be PRESENT with a DIFFERENT value to
   // be skipped as irrelevant - a line with no "type" key at all still
   // falls through to the parse attempt and fails there.
   if(EventSerializer_HasKey(line, "type") &&
      EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_RISK_PLAN_CREATED))
   {
      outReason = "not a RISK_PLAN_CREATED event - skipped, not relevant to this projection";
      return true;
   }

   SystemEvent e;
   if(!EventSerializer_ParseSystem(line, e))
   {
      outReason = "not a parsable event line";
      return false;
   }

   string riskPlanId       = EventSerializer_GetStr(line, "risk_plan_id");
   string candidateId       = EventSerializer_GetStr(line, "candidate_id");
   string candidateHash     = EventSerializer_GetStr(line, "candidate_hash");
   string riskContextHash   = EventSerializer_GetStr(line, "risk_context_hash");
   string planHash          = EventSerializer_GetStr(line, "plan_hash");
   string sizingMethod      = EventSerializer_GetStr(line, "sizing_method");
   string sizingRulesVersion = EventSerializer_GetStr(line, "sizing_rules_version");
   string schemaVersion      = EventSerializer_GetStr(line, "risk_plan_schema_version");

   string fieldsErr = RiskPlanProjection_ValidateRequiredFields(riskPlanId, candidateId, candidateHash,
                                                                  riskContextHash, planHash, sizingMethod,
                                                                  sizingRulesVersion);
   if(fieldsErr != "") { outReason = fieldsErr; return false; }

   double plannedEntry        = EventSerializer_GetDouble(line, "planned_entry");
   double plannedSl            = EventSerializer_GetDouble(line, "planned_sl");
   double plannedTp            = EventSerializer_GetDouble(line, "planned_tp");
   double stopDistancePoints   = EventSerializer_GetDouble(line, "stop_distance_points");
   double rrRatio               = EventSerializer_GetDouble(line, "rr_ratio");
   double riskPercent           = EventSerializer_GetDouble(line, "risk_percent");
   double riskAmount            = EventSerializer_GetDouble(line, "risk_amount");
   double lotSize                = EventSerializer_GetDouble(line, "lot_size");

   string numErr = RiskPlanProjection_ValidateNumericalIntegrity(plannedEntry, plannedSl, plannedTp,
                                                                    stopDistancePoints, rrRatio, riskPercent,
                                                                    riskAmount, lotSize);
   if(numErr != "") { outReason = numErr; return false; }

   int existingIdx = RiskPlanProjection_FindIndex(riskPlanId);
   if(existingIdx >= 0)
   {
      if(g_RiskPlanProj_Records[existingIdx].plan_hash == planHash)
      {
         outReason = "duplicate risk_plan_id - already registered with an identical plan_hash, not re-applied";
         return true;
      }
      outReason = StringFormat("risk_plan_id collision: '%s' already registered with plan_hash '%s', "
                                "this line carries a DIFFERENT plan_hash '%s' - rejected as a conflict, not a duplicate",
                                riskPlanId, g_RiskPlanProj_Records[existingIdx].plan_hash, planHash);
      return false;
   }

   RiskPlanProjectionRecord rec;
   RiskPlanProjectionRecord_Init(rec);
   rec.risk_plan_schema_version = schemaVersion;
   rec.risk_plan_id              = riskPlanId;
   rec.candidate_id               = candidateId;
   rec.candidate_hash             = candidateHash;
   rec.risk_context_hash          = riskContextHash;
   rec.planned_entry              = plannedEntry;
   rec.planned_sl                  = plannedSl;
   rec.planned_tp                  = plannedTp;
   rec.stop_distance_points        = stopDistancePoints;
   rec.rr_ratio                     = rrRatio;
   rec.risk_percent                 = riskPercent;
   rec.risk_amount                  = riskAmount;
   rec.lot_size                      = lotSize;
   rec.sizing_method                 = sizingMethod;
   rec.sizing_rules_version          = sizingRulesVersion;
   rec.plan_hash                     = planHash;
   rec.source_sequence_number        = e.base.sequence_number;
   rec.source_log_event_id           = e.base.log_event_id;

   RiskPlanProjection_AppendRecord(rec);
   outReason = "applied - new risk plan registered";
   return true;
}

// Referential-integrity-aware variant used by RebuildFromFile: rejects a
// RISK_PLAN_CREATED line as an orphan (no matching candidate_id in
// CandidateProjection's own, already-rebuilt-from-the-same-file
// registry) or a candidate_hash mismatch BEFORE ever calling
// RiskPlanProjection_ApplyLine, so a referentially-broken plan never
// reaches the registry regardless of how well-formed it otherwise
// looks. Every other line type is passed straight through to ApplyLine
// unchanged.
bool RiskPlanProjection_ApplyLineWithCandidates(string line, string &outReason)
{
   if(EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_RISK_PLAN_CREATED))
      return RiskPlanProjection_ApplyLine(line, outReason);

   string candidateId   = EventSerializer_GetStr(line, "candidate_id");
   string candidateHash = EventSerializer_GetStr(line, "candidate_hash");

   CandidateProjectionRecord candRecord;
   if(!CandidateProjection_TryGet(candidateId, candRecord))
   {
      outReason = "orphan risk plan: candidate_id '" + candidateId + "' has no matching CANDIDATE_CREATED event in this store - rejected";
      return false;
   }
   if(candRecord.candidate_hash != candidateHash)
   {
      outReason = "candidate_hash mismatch: risk plan's candidate_hash does not match its referenced candidate's own candidate_hash - rejected";
      return false;
   }

   return RiskPlanProjection_ApplyLine(line, outReason);
}

//---------------------------------------------------------------------
// A from-scratch rebuild. Gated on EventStoreValidator first (ordering/
// atomicity, same as CandidateProjection), THEN on CandidateProjection
// itself being successfully rebuilt from the SAME file (a RiskPlan
// registry can't be trusted if the candidate registry it references
// can't be trusted) - if either fails, THIS registry is left completely
// untouched.
//---------------------------------------------------------------------
struct RiskPlanProjectionReport
{
   bool   ok;
   int    lines_total;
   int    lines_applied;  // genuinely new risk plans registered
   int    lines_skipped;  // non-RISK_PLAN_CREATED lines, or idempotent duplicates
   int    lines_failed;   // malformed/corrupt/invalid/orphaned RISK_PLAN_CREATED-typed lines
   string first_error;
};

void RiskPlanProjectionReport_Init(RiskPlanProjectionReport &r)
{
   r.ok = true;
   r.lines_total = 0;
   r.lines_applied = 0;
   r.lines_skipped = 0;
   r.lines_failed = 0;
   r.first_error = "";
}

RiskPlanProjectionReport RiskPlanProjection_RebuildFromFile(string fileName)
{
   RiskPlanProjectionReport report;
   RiskPlanProjectionReport_Init(report);

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

   CandidateProjectionReport candReport = CandidateProjection_RebuildFromFile(fileName);
   if(!candReport.ok)
   {
      report.ok = false;
      report.first_error = "candidate registry failed to rebuild from the same store - rebuild refused, registry left unchanged: " + candReport.first_error;
      return report;
   }

   RiskPlanProjection_Reset();

   for(int i = 0; i < n; i++)
   {
      int beforeCount = RiskPlanProjection_Count();
      string reason;
      bool applied = RiskPlanProjection_ApplyLineWithCandidates(lines[i], reason);
      if(!applied)
      {
         report.ok = false;
         report.lines_failed++;
         if(report.first_error == "")
            report.first_error = StringFormat("line %d: %s", i, reason);
         continue;
      }
      if(RiskPlanProjection_Count() > beforeCount)
         report.lines_applied++;
      else
         report.lines_skipped++;
   }
   return report;
}

#endif // __MLQUANTAI_RISKPLANPROJECTION_MQH__
