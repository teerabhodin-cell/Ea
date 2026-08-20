//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_EligibilityDecisionProjection.mqh |
//| Phase B9 Commit 2: a read-only EligibilityDecision registry         |
//| projected from persisted EXECUTION_ELIGIBILITY_DECIDED lines,        |
//| mirroring MLQuantAI_AIDecisionProjection.mqh's structure and         |
//| hardening discipline (schema/required-field/numerical validation,    |
//| payload-aware collision-vs-duplicate detection, referential          |
//| integrity, EventStoreValidator-gated atomic rebuild). See            |
//| Docs/PhaseB_B9_ExecutionEligibilityContract.md's Commit 2 addendum    |
//| for the full contract this file implements.                          |
//|                                                                    |
//| Strictly additive and read-only: no B5/B6/B7/B8/B9-Commit-1 sealed |
//| file touched, no live market/broker/account call, no event append   |
//| here (that's MLQuantAI_EligibilityEventEmission.mqh). Rebuilds AND   |
//| verifies THREE independent upstream registries -                     |
//| RiskPlanProjection, AIDecisionProjection, and FeatureSnapshotProjection|
//| (the last reached both directly here and indirectly via              |
//| AIDecisionProjection's own record) - the first projection in this    |
//| project with three upstream chains to check. Also reconstructs and   |
//| verifies EligibilityContext's own content hash from the raw account/  |
//| safe-mode evidence persisted in the same line, since EligibilityContext|
//| has no upstream event of its own to cross-check against.             |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ELIGIBILITYDECISIONPROJECTION_MQH__
#define __MLQUANTAI_ELIGIBILITYDECISIONPROJECTION_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventStoreValidator.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_RiskPlanProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_AIDecisionProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_FeatureSnapshotProjection.mqh"
#include "MLQuantAI_EligibilityContract.mqh"

#define MLQUANTAI_ELIGIBILITYPROJ_MAX_LINE_LENGTH 65536

struct EligibilityDecisionProjectionRecord
{
   string eligibility_decision_schema_version;

   string eligibility_decision_id;
   string eligibility_decision_hash;

   string candidate_id;
   string candidate_hash;

   string risk_plan_id;
   string plan_hash;

   string ai_decision_id;
   string ai_decision_hash;

   string eligibility_context_schema_version;
   string eligibility_context_hash;
   string eligibility_policy_version;

   ENUM_ELIGIBILITY_DECISION decision;
   ENUM_REASON_CODE          reason_code;

   // Raw EligibilityContext evidence, persisted verbatim so this
   // record's own eligibility_context_hash can be independently
   // recomputed and verified - see the contract addendum.
   double account_balance;
   double account_equity;
   double account_margin_level;
   int    account_open_positions_count;
   double account_open_risk_percent;
   double account_daily_pnl_percent;
   double account_drawdown_from_peak_percent;
   string account_context_schema_version;
   bool   safe_mode_active;

   long   source_sequence_number; // audit trail: which event this record came from
   string source_log_event_id;
};

void EligibilityDecisionProjectionRecord_Init(EligibilityDecisionProjectionRecord &r)
{
   r.eligibility_decision_schema_version = "";

   r.eligibility_decision_id = "";
   r.eligibility_decision_hash = "";

   r.candidate_id = "";
   r.candidate_hash = "";

   r.risk_plan_id = "";
   r.plan_hash = "";

   r.ai_decision_id = "";
   r.ai_decision_hash = "";

   r.eligibility_context_schema_version = "";
   r.eligibility_context_hash = "";
   r.eligibility_policy_version = "";

   r.decision = ELIGIBILITY_DECISION_NONE;
   r.reason_code = REASON_NONE;

   r.account_balance = 0.0;
   r.account_equity = 0.0;
   r.account_margin_level = 0.0;
   r.account_open_positions_count = 0;
   r.account_open_risk_percent = 0.0;
   r.account_daily_pnl_percent = 0.0;
   r.account_drawdown_from_peak_percent = 0.0;
   r.account_context_schema_version = "";
   r.safe_mode_active = false;

   r.source_sequence_number = 0;
   r.source_log_event_id = "";
}

// Rebuilds the EligibilityContext this record's evidence describes, so
// EligibilityContext_ComputeHash() can be recomputed and compared
// against the persisted eligibility_context_hash.
void EligibilityDecisionProjectionRecord_ToContext(const EligibilityDecisionProjectionRecord &r, EligibilityContext &outContext)
{
   EligibilityContext_Init(outContext);
   outContext.eligibility_context_schema_version = r.eligibility_context_schema_version;
   outContext.account.context_schema_version      = r.account_context_schema_version;
   outContext.account.balance                       = r.account_balance;
   outContext.account.equity                          = r.account_equity;
   outContext.account.margin_level                      = r.account_margin_level;
   outContext.account.open_positions_count                = r.account_open_positions_count;
   outContext.account.open_risk_percent                     = r.account_open_risk_percent;
   outContext.account.daily_pnl_percent                       = r.account_daily_pnl_percent;
   outContext.account.drawdown_from_peak_percent                = r.account_drawdown_from_peak_percent;
   outContext.safe_mode_active                                    = r.safe_mode_active;
}

EligibilityDecisionProjectionRecord g_EligibilityProj_Records[];
int                                 g_EligibilityProj_Count = 0;

void EligibilityDecisionProjection_Reset()
{
   ArrayResize(g_EligibilityProj_Records, 0);
   g_EligibilityProj_Count = 0;
}

int EligibilityDecisionProjection_Count() { return g_EligibilityProj_Count; }

int EligibilityDecisionProjection_FindIndex(string eligibilityDecisionId)
{
   for(int i = 0; i < g_EligibilityProj_Count; i++)
      if(g_EligibilityProj_Records[i].eligibility_decision_id == eligibilityDecisionId)
         return i;
   return -1;
}

bool EligibilityDecisionProjection_TryGet(string eligibilityDecisionId, EligibilityDecisionProjectionRecord &out)
{
   int idx = EligibilityDecisionProjection_FindIndex(eligibilityDecisionId);
   if(idx < 0) return false;
   out = g_EligibilityProj_Records[idx];
   return true;
}

bool EligibilityDecisionProjection_GetAt(int index, EligibilityDecisionProjectionRecord &out)
{
   if(index < 0 || index >= g_EligibilityProj_Count) return false;
   out = g_EligibilityProj_Records[index];
   return true;
}

void EligibilityDecisionProjection_AppendRecord(const EligibilityDecisionProjectionRecord &rec)
{
   int idx = g_EligibilityProj_Count;
   ArrayResize(g_EligibilityProj_Records, idx + 1);
   g_EligibilityProj_Records[idx] = rec;
   g_EligibilityProj_Count++;
}

// Live-session sync path - called directly by
// EligibilityDecision_EmitDecisionAndWireLifecycle right after a
// durable write, from the in-memory EligibilityDecision/EligibilityContext
// structs themselves (no JSON round-trip needed, unlike the replay path
// below). Does NOT re-check for an existing record - the emitter's own
// EligibilityDecisionProjection_TryGet guard already ensured this
// eligibility_decision_id is new before writing.
void EligibilityDecisionProjection_ApplyLiveRecord(const EligibilityDecision &d, const EligibilityContext &context)
{
   EligibilityDecisionProjectionRecord rec;
   EligibilityDecisionProjectionRecord_Init(rec);
   rec.eligibility_decision_schema_version = d.eligibility_decision_schema_version;
   rec.eligibility_decision_id              = d.eligibility_decision_id;
   rec.eligibility_decision_hash             = d.eligibility_decision_hash;
   rec.candidate_id                           = d.candidate_id;
   rec.candidate_hash                          = d.candidate_hash;
   rec.risk_plan_id                             = d.risk_plan_id;
   rec.plan_hash                                 = d.plan_hash;
   rec.ai_decision_id                             = d.ai_decision_id;
   rec.ai_decision_hash                            = d.ai_decision_hash;
   rec.eligibility_context_schema_version           = context.eligibility_context_schema_version;
   rec.eligibility_context_hash                      = d.eligibility_context_hash;
   rec.eligibility_policy_version                     = d.eligibility_policy_version;
   rec.decision                                        = d.decision;
   rec.reason_code                                      = d.reason_code;
   rec.account_balance                                   = context.account.balance;
   rec.account_equity                                     = context.account.equity;
   rec.account_margin_level                                = context.account.margin_level;
   rec.account_open_positions_count                          = context.account.open_positions_count;
   rec.account_open_risk_percent                               = context.account.open_risk_percent;
   rec.account_daily_pnl_percent                                 = context.account.daily_pnl_percent;
   rec.account_drawdown_from_peak_percent                          = context.account.drawdown_from_peak_percent;
   rec.account_context_schema_version                                = context.account.context_schema_version;
   rec.safe_mode_active                                                = context.safe_mode_active;
   // source_sequence_number/source_log_event_id stay at Init() defaults
   // (0/"") for a live-applied record - the durable append already
   // happened via EventStore_LogSystem, which owns the real
   // seq/log_event_id assignment.
   EligibilityDecisionProjection_AppendRecord(rec);
}

//---------------------------------------------------------------------
// Validation helpers.
//---------------------------------------------------------------------
string EligibilityDecisionProjection_ValidateRequiredFields(string eligibilityDecisionId, string eligibilityDecisionHash,
                                                               string candidateId, string candidateHash, string riskPlanId,
                                                               string planHash, string aiDecisionId, string aiDecisionHash,
                                                               string eligibilityContextSchemaVersion, string eligibilityContextHash,
                                                               string eligibilityPolicyVersion, string eligibilityDecisionSchemaVersion)
{
   if(eligibilityDecisionId == "")             return "missing eligibility_decision_id";
   if(eligibilityDecisionHash == "")            return "missing eligibility_decision_hash";
   if(candidateId == "")                         return "missing candidate_id";
   if(candidateHash == "")                        return "missing candidate_hash";
   if(riskPlanId == "")                            return "missing risk_plan_id";
   if(planHash == "")                               return "missing plan_hash";
   if(aiDecisionId == "")                            return "missing ai_decision_id";
   if(aiDecisionHash == "")                           return "missing ai_decision_hash";
   if(eligibilityContextSchemaVersion == "")           return "missing eligibility_context_schema_version";
   if(eligibilityContextHash == "")                     return "missing eligibility_context_hash";
   if(eligibilityPolicyVersion == "")                    return "missing eligibility_policy_version";
   if(eligibilityDecisionSchemaVersion == "")             return "missing eligibility_decision_schema_version";
   return "";
}

string EligibilityDecisionProjection_ValidateNumericalIntegrity(double balance, double equity, double marginLevel,
                                                                    double openRiskPercent, double dailyPnlPercent,
                                                                    double drawdownFromPeakPercent)
{
   if(!MathIsValidNumber(balance) || !MathIsValidNumber(equity) || !MathIsValidNumber(marginLevel))
      return "account_balance/account_equity/account_margin_level contains NaN or Inf";
   if(!MathIsValidNumber(openRiskPercent) || !MathIsValidNumber(dailyPnlPercent) || !MathIsValidNumber(drawdownFromPeakPercent))
      return "account_open_risk_percent/account_daily_pnl_percent/account_drawdown_from_peak_percent contains NaN or Inf";
   return "";
}

//---------------------------------------------------------------------
// Applies one raw persisted line to the registry - the replay path.
// Structural/schema validation and context-hash reconstruction only;
// the three-chain referential-integrity check lives in
// EligibilityDecisionProjection_ApplyLineWithLineage below, which wraps
// this.
//---------------------------------------------------------------------
bool EligibilityDecisionProjection_ApplyLine(string line, string &outReason)
{
   if(StringLen(line) > MLQUANTAI_ELIGIBILITYPROJ_MAX_LINE_LENGTH)
   {
      outReason = "line exceeds the defensive length bound - rejected before parsing";
      return false;
   }

   if(EventSerializer_HasKey(line, "type") &&
      EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED))
   {
      outReason = "not an EXECUTION_ELIGIBILITY_DECIDED event - skipped, not relevant to this projection";
      return true;
   }

   SystemEvent e;
   if(!EventSerializer_ParseSystem(line, e))
   {
      outReason = "not a parsable event line";
      return false;
   }

   string eligibilityDecisionSchemaVersion = EventSerializer_GetStr(line, "eligibility_decision_schema_version");
   string eligibilityDecisionId             = EventSerializer_GetStr(line, "eligibility_decision_id");
   string eligibilityDecisionHash            = EventSerializer_GetStr(line, "eligibility_decision_hash");
   string candidateId                         = EventSerializer_GetStr(line, "candidate_id");
   string candidateHash                        = EventSerializer_GetStr(line, "candidate_hash");
   string riskPlanId                            = EventSerializer_GetStr(line, "risk_plan_id");
   string planHash                               = EventSerializer_GetStr(line, "plan_hash");
   string aiDecisionId                            = EventSerializer_GetStr(line, "ai_decision_id");
   string aiDecisionHash                           = EventSerializer_GetStr(line, "ai_decision_hash");
   string eligibilityContextSchemaVersion            = EventSerializer_GetStr(line, "eligibility_context_schema_version");
   string eligibilityContextHash                      = EventSerializer_GetStr(line, "eligibility_context_hash");
   string eligibilityPolicyVersion                     = EventSerializer_GetStr(line, "eligibility_policy_version");

   string fieldsErr = EligibilityDecisionProjection_ValidateRequiredFields(eligibilityDecisionId, eligibilityDecisionHash,
                                                                              candidateId, candidateHash, riskPlanId, planHash,
                                                                              aiDecisionId, aiDecisionHash,
                                                                              eligibilityContextSchemaVersion, eligibilityContextHash,
                                                                              eligibilityPolicyVersion, eligibilityDecisionSchemaVersion);
   if(fieldsErr != "") { outReason = fieldsErr; return false; }

   string decisionStr    = EventSerializer_GetStr(line, "decision");
   string reasonCodeStr  = EventSerializer_GetStr(line, "reason_code");
   if(decisionStr == "")   { outReason = "missing decision"; return false; }
   if(reasonCodeStr == "") { outReason = "missing reason_code"; return false; }

   double balance                    = EventSerializer_GetDouble(line, "account_balance");
   double equity                       = EventSerializer_GetDouble(line, "account_equity");
   double marginLevel                    = EventSerializer_GetDouble(line, "account_margin_level");
   int    openPositionsCount               = EventSerializer_GetInt(line, "account_open_positions_count");
   double openRiskPercent                    = EventSerializer_GetDouble(line, "account_open_risk_percent");
   double dailyPnlPercent                      = EventSerializer_GetDouble(line, "account_daily_pnl_percent");
   double drawdownFromPeakPercent                = EventSerializer_GetDouble(line, "account_drawdown_from_peak_percent");
   string accountContextSchemaVersion              = EventSerializer_GetStr(line, "account_context_schema_version");
   bool   safeModeActive                             = StringFind(line, "\"safe_mode_active\":true") >= 0;

   string numErr = EligibilityDecisionProjection_ValidateNumericalIntegrity(balance, equity, marginLevel, openRiskPercent,
                                                                               dailyPnlPercent, drawdownFromPeakPercent);
   if(numErr != "") { outReason = numErr; return false; }

   EligibilityDecisionProjectionRecord candidate;
   EligibilityDecisionProjectionRecord_Init(candidate);
   candidate.eligibility_decision_schema_version = eligibilityDecisionSchemaVersion;
   candidate.eligibility_decision_id              = eligibilityDecisionId;
   candidate.eligibility_decision_hash             = eligibilityDecisionHash;
   candidate.candidate_id                           = candidateId;
   candidate.candidate_hash                          = candidateHash;
   candidate.risk_plan_id                             = riskPlanId;
   candidate.plan_hash                                 = planHash;
   candidate.ai_decision_id                             = aiDecisionId;
   candidate.ai_decision_hash                            = aiDecisionHash;
   candidate.eligibility_context_schema_version            = eligibilityContextSchemaVersion;
   candidate.eligibility_context_hash                       = eligibilityContextHash;
   candidate.eligibility_policy_version                      = eligibilityPolicyVersion;
   candidate.decision                                         = EligibilityDecisionFromString(decisionStr);
   candidate.reason_code                                       = ReasonCodeFromString(reasonCodeStr);
   candidate.account_balance                                    = balance;
   candidate.account_equity                                      = equity;
   candidate.account_margin_level                                 = marginLevel;
   candidate.account_open_positions_count                          = openPositionsCount;
   candidate.account_open_risk_percent                               = openRiskPercent;
   candidate.account_daily_pnl_percent                                 = dailyPnlPercent;
   candidate.account_drawdown_from_peak_percent                          = drawdownFromPeakPercent;
   candidate.account_context_schema_version                                = accountContextSchemaVersion;
   candidate.safe_mode_active                                                = safeModeActive;

   // Reconstruct EligibilityContext from the persisted raw evidence and
   // recompute its hash - require an exact match. This is what makes
   // the persisted raw evidence protective, not merely informational:
   // tampering any single account_*/safe_mode_active field moves the
   // recomputed hash and fails this line closed.
   EligibilityContext reconstructedContext;
   EligibilityDecisionProjectionRecord_ToContext(candidate, reconstructedContext);
   string recomputedContextHash = EligibilityContext_ComputeHash(reconstructedContext);
   if(recomputedContextHash != eligibilityContextHash)
   {
      outReason = "eligibility_context_hash does not match a fresh recompute from the persisted raw account/safe-mode evidence - "
                  "tampered or corrupted evidence";
      return false;
   }

   int existingIdx = EligibilityDecisionProjection_FindIndex(eligibilityDecisionId);
   if(existingIdx >= 0)
   {
      if(g_EligibilityProj_Records[existingIdx].eligibility_decision_hash == eligibilityDecisionHash)
      {
         outReason = "duplicate eligibility_decision_id - already registered with an identical eligibility_decision_hash, not re-applied";
         return true;
      }
      outReason = StringFormat("eligibility_decision_id collision: '%s' already registered with eligibility_decision_hash '%s', "
                                "this line carries a DIFFERENT eligibility_decision_hash '%s' - rejected as a conflict, not a duplicate",
                                eligibilityDecisionId, g_EligibilityProj_Records[existingIdx].eligibility_decision_hash, eligibilityDecisionHash);
      return false;
   }

   candidate.source_sequence_number = e.base.sequence_number;
   candidate.source_log_event_id    = e.base.log_event_id;

   EligibilityDecisionProjection_AppendRecord(candidate);
   outReason = "applied - new eligibility decision registered";
   return true;
}

// Referential-integrity-aware variant used by RebuildFromFile: rejects
// an EXECUTION_ELIGIBILITY_DECIDED line whose RiskPlan lineage,
// AIDecision lineage, or the FeatureSnapshot lineage reached through
// that AIDecision record don't resolve against the already-rebuilt
// upstream registries - BEFORE ever calling
// EligibilityDecisionProjection_ApplyLine, so a referentially-broken
// decision never reaches the registry regardless of how well-formed it
// otherwise looks. Every other line type is passed straight through to
// ApplyLine unchanged.
bool EligibilityDecisionProjection_ApplyLineWithLineage(string line, string &outReason)
{
   if(EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED))
      return EligibilityDecisionProjection_ApplyLine(line, outReason);

   string riskPlanId    = EventSerializer_GetStr(line, "risk_plan_id");
   string planHash        = EventSerializer_GetStr(line, "plan_hash");
   string candidateId       = EventSerializer_GetStr(line, "candidate_id");
   string candidateHash      = EventSerializer_GetStr(line, "candidate_hash");

   RiskPlanProjectionRecord planRecord;
   if(!RiskPlanProjection_TryGet(riskPlanId, planRecord))
   {
      outReason = "orphan eligibility decision: risk_plan_id '" + riskPlanId + "' has no matching RISK_PLAN_CREATED event in this store - rejected";
      return false;
   }
   if(planRecord.plan_hash != planHash || planRecord.candidate_id != candidateId || planRecord.candidate_hash != candidateHash)
   {
      outReason = "RiskPlan lineage mismatch: eligibility decision's plan_hash/candidate_id/candidate_hash "
                  "does not match the referenced RiskPlanProjection record - rejected";
      return false;
   }

   string aiDecisionId    = EventSerializer_GetStr(line, "ai_decision_id");
   string aiDecisionHash    = EventSerializer_GetStr(line, "ai_decision_hash");

   AIDecisionProjectionRecord aiRecord;
   if(!AIDecisionProjection_TryGet(aiDecisionId, aiRecord))
   {
      outReason = "orphan eligibility decision: ai_decision_id '" + aiDecisionId + "' has no matching AI_DECISION_CREATED event in this store - rejected";
      return false;
   }
   if(aiRecord.ai_decision_hash != aiDecisionHash || aiRecord.candidate_id != candidateId || aiRecord.candidate_hash != candidateHash)
   {
      outReason = "AIDecision lineage mismatch: eligibility decision's ai_decision_hash/candidate_id/candidate_hash "
                  "does not match the referenced AIDecisionProjection record - rejected";
      return false;
   }

   // Reached via the AIDecision record found above (EligibilityDecision
   // itself carries no feature_snapshot_id) - confirms the full
   // candidate -> snapshot -> AI decision -> eligibility decision chain
   // agrees on candidate identity at every hop, not just trusting
   // AIDecisionProjection's own already-completed internal check.
   FeatureSnapshotProjectionRecord snapRecord;
   if(!FeatureSnapshotProjection_TryGet(aiRecord.feature_snapshot_id, snapRecord))
   {
      outReason = "orphan eligibility decision: the referenced AIDecision's feature_snapshot_id '" + aiRecord.feature_snapshot_id +
                  "' has no matching FEATURE_SNAPSHOT_CREATED event in this store - rejected";
      return false;
   }
   if(snapRecord.candidate_id != candidateId || snapRecord.candidate_hash != candidateHash)
   {
      outReason = "FeatureSnapshot lineage mismatch: the candidate_id/candidate_hash reached via the AIDecision's own "
                  "feature snapshot does not match the eligibility decision's own candidate_id/candidate_hash - rejected";
      return false;
   }

   return EligibilityDecisionProjection_ApplyLine(line, outReason);
}

//---------------------------------------------------------------------
// A from-scratch rebuild. Gated on EventStoreValidator first, THEN on
// RiskPlanProjection, AIDecisionProjection, AND FeatureSnapshotProjection
// all being successfully rebuilt from the SAME file - three independent
// upstream chains (see this file's header) - if any fails, THIS
// registry is left completely untouched.
//---------------------------------------------------------------------
struct EligibilityDecisionProjectionReport
{
   bool   ok;
   int    lines_total;
   int    lines_applied;  // genuinely new decisions registered
   int    lines_skipped;  // non-EXECUTION_ELIGIBILITY_DECIDED lines, or idempotent duplicates
   int    lines_failed;   // malformed/corrupt/invalid/orphaned EXECUTION_ELIGIBILITY_DECIDED-typed lines
   string first_error;
};

void EligibilityDecisionProjectionReport_Init(EligibilityDecisionProjectionReport &r)
{
   r.ok = true;
   r.lines_total = 0;
   r.lines_applied = 0;
   r.lines_skipped = 0;
   r.lines_failed = 0;
   r.first_error = "";
}

EligibilityDecisionProjectionReport EligibilityDecisionProjection_RebuildFromFile(string fileName)
{
   EligibilityDecisionProjectionReport report;
   EligibilityDecisionProjectionReport_Init(report);

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

   RiskPlanProjectionReport planReport = RiskPlanProjection_RebuildFromFile(fileName);
   if(!planReport.ok)
   {
      report.ok = false;
      report.first_error = "risk plan registry failed to rebuild from the same store - rebuild refused, registry left unchanged: " + planReport.first_error;
      return report;
   }

   AIDecisionProjectionReport aiReport = AIDecisionProjection_RebuildFromFile(fileName);
   if(!aiReport.ok)
   {
      report.ok = false;
      report.first_error = "AI decision registry failed to rebuild from the same store - rebuild refused, registry left unchanged: " + aiReport.first_error;
      return report;
   }

   FeatureSnapshotProjectionReport snapReport = FeatureSnapshotProjection_RebuildFromFile(fileName);
   if(!snapReport.ok)
   {
      report.ok = false;
      report.first_error = "feature snapshot registry failed to rebuild from the same store - rebuild refused, registry left unchanged: " + snapReport.first_error;
      return report;
   }

   EligibilityDecisionProjection_Reset();

   for(int i = 0; i < n; i++)
   {
      int beforeCount = EligibilityDecisionProjection_Count();
      string reason;
      bool applied = EligibilityDecisionProjection_ApplyLineWithLineage(lines[i], reason);
      if(!applied)
      {
         report.ok = false;
         report.lines_failed++;
         if(report.first_error == "")
            report.first_error = StringFormat("line %d: %s", i, reason);
         continue;
      }
      if(EligibilityDecisionProjection_Count() > beforeCount)
         report.lines_applied++;
      else
         report.lines_skipped++;
   }
   return report;
}

#endif // __MLQUANTAI_ELIGIBILITYDECISIONPROJECTION_MQH__
