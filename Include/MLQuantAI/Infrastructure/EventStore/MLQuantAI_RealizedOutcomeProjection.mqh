//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_RealizedOutcomeProjection.mqh|
//| Phase B8.2 Commit 3: a read-only RealizedOutcome registry projected|
//| from persisted TRADE_OUTCOME_LABELED lines, mirroring               |
//| MLQuantAI_FeatureSnapshotProjection.mqh's exact structure and        |
//| hardening discipline (required-field/numerical validation,           |
//| payload-aware collision-vs-duplicate detection, referential          |
//| integrity, EventStoreValidator-gated atomic rebuild). See            |
//| Docs/PhaseB_B8_2_Commit3_OutcomeLabelContract.md's Part 1 for the     |
//| full contract this file implements.                                   |
//|                                                                    |
//| Strictly additive and read-only: no B5/B6/B7/B8.1/B8.2 sealed file |
//| touched, no live market/broker/account call, no event append here  |
//| (that's MLQuantAI_RealizedOutcomeEventEmission.mqh). Depends on     |
//| MLQuantAI_CandidateProjection.mqh (rebuilt from the SAME file        |
//| immediately before this one, as a referential-integrity              |
//| prerequisite) - the same dependency direction                       |
//| MLQuantAI_FeatureSnapshotProjection.mqh already has on it.           |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_REALIZEDOUTCOMEPROJECTION_MQH__
#define __MLQUANTAI_REALIZEDOUTCOMEPROJECTION_MQH__

#include "MLQuantAI_CandidateProjection.mqh"
#include "../../AI/MLQuantAI_RealizedOutcome.mqh"

#define MLQUANTAI_REALIZEDOUTCOMEPROJ_MAX_LINE_LENGTH 65536

struct RealizedOutcomeProjectionRecord
{
   string   realized_outcome_schema_version;

   string   realized_outcome_id;
   string   candidate_id;
   string   candidate_hash;

   string   label_schema_version;
   string   label;
   string   outcome_reference;
   string   outcome_hash;
   datetime outcome_time;

   string   realized_outcome_hash;

   long     source_sequence_number; // audit trail: which event this record came from
   string   source_log_event_id;
};

void RealizedOutcomeProjectionRecord_Init(RealizedOutcomeProjectionRecord &r)
{
   r.realized_outcome_schema_version = "";

   r.realized_outcome_id = "";
   r.candidate_id = "";
   r.candidate_hash = "";

   r.label_schema_version = "";
   r.label = "";
   r.outcome_reference = "";
   r.outcome_hash = "";
   r.outcome_time = 0;

   r.realized_outcome_hash = "";

   r.source_sequence_number = 0;
   r.source_log_event_id = "";
}

RealizedOutcomeProjectionRecord g_RealizedOutcomeProj_Records[];
int                             g_RealizedOutcomeProj_Count = 0;

void RealizedOutcomeProjection_Reset()
{
   ArrayResize(g_RealizedOutcomeProj_Records, 0);
   g_RealizedOutcomeProj_Count = 0;
}

int RealizedOutcomeProjection_Count() { return g_RealizedOutcomeProj_Count; }

int RealizedOutcomeProjection_FindIndex(string realizedOutcomeId)
{
   for(int i = 0; i < g_RealizedOutcomeProj_Count; i++)
      if(g_RealizedOutcomeProj_Records[i].realized_outcome_id == realizedOutcomeId)
         return i;
   return -1;
}

bool RealizedOutcomeProjection_TryGet(string realizedOutcomeId, RealizedOutcomeProjectionRecord &out)
{
   int idx = RealizedOutcomeProjection_FindIndex(realizedOutcomeId);
   if(idx < 0) return false;
   out = g_RealizedOutcomeProj_Records[idx];
   return true;
}

bool RealizedOutcomeProjection_GetAt(int index, RealizedOutcomeProjectionRecord &out)
{
   if(index < 0 || index >= g_RealizedOutcomeProj_Count) return false;
   out = g_RealizedOutcomeProj_Records[index];
   return true;
}

void RealizedOutcomeProjection_AppendRecord(const RealizedOutcomeProjectionRecord &rec)
{
   int idx = g_RealizedOutcomeProj_Count;
   ArrayResize(g_RealizedOutcomeProj_Records, idx + 1);
   g_RealizedOutcomeProj_Records[idx] = rec;
   g_RealizedOutcomeProj_Count++;
}

// Live-session sync path - called directly by
// RealizedOutcome_EmitTradeOutcomeLabeled right after a durable write,
// from the in-memory RealizedOutcome struct itself (no JSON round-trip
// needed, unlike the replay path below). Does NOT re-check for an
// existing record - the emitter's own
// RealizedOutcomeProjection_TryGet guard already ensured this
// realized_outcome_id is new before writing.
void RealizedOutcomeProjection_ApplyLiveRecord(const RealizedOutcome &o)
{
   RealizedOutcomeProjectionRecord rec;
   RealizedOutcomeProjectionRecord_Init(rec);
   rec.realized_outcome_schema_version = o.realized_outcome_schema_version;
   rec.realized_outcome_id              = o.realized_outcome_id;
   rec.candidate_id                      = o.candidate_id;
   rec.candidate_hash                     = o.candidate_hash;
   rec.label_schema_version                = o.label_schema_version;
   rec.label                                = o.label;
   rec.outcome_reference                     = o.outcome_reference;
   rec.outcome_hash                           = o.outcome_hash;
   rec.outcome_time                            = o.outcome_time;
   rec.realized_outcome_hash                    = o.realized_outcome_hash;
   // source_sequence_number/source_log_event_id stay at Init()
   // defaults (0/"") for a live-applied record - the durable append
   // already happened via EventStore_LogSystem, which owns the real
   // seq/log_event_id assignment.
   RealizedOutcomeProjection_AppendRecord(rec);
}

//---------------------------------------------------------------------
// Validation helpers - mirrors FeatureSnapshotProjection's own ladder.
//---------------------------------------------------------------------
string RealizedOutcomeProjection_ValidateRequiredFields(string realizedOutcomeId, string candidateId, string candidateHash,
                                                           string labelSchemaVersion, string label,
                                                           string outcomeReference, string outcomeHash)
{
   if(realizedOutcomeId == "")  return "missing realized_outcome_id";
   if(candidateId == "")         return "missing candidate_id";
   if(candidateHash == "")       return "missing candidate_hash";
   if(labelSchemaVersion == "")  return "missing label_schema_version";
   if(label == "")                return "missing label";
   if(outcomeReference == "")      return "missing outcome_reference";
   if(outcomeHash == "")            return "missing outcome_hash";
   return "";
}

//---------------------------------------------------------------------
// Applies one raw persisted line to the registry - the replay path.
//---------------------------------------------------------------------
bool RealizedOutcomeProjection_ApplyLine(string line, string &outReason)
{
   if(StringLen(line) > MLQUANTAI_REALIZEDOUTCOMEPROJ_MAX_LINE_LENGTH)
   {
      outReason = "line exceeds the defensive length bound - rejected before parsing";
      return false;
   }

   if(EventSerializer_HasKey(line, "type") &&
      EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_TRADE_OUTCOME_LABELED))
   {
      outReason = "not a TRADE_OUTCOME_LABELED event - skipped, not relevant to this projection";
      return true;
   }

   SystemEvent e;
   if(!EventSerializer_ParseSystem(line, e))
   {
      outReason = "not a parsable event line";
      return false;
   }

   string realizedOutcomeId  = EventSerializer_GetStr(line, "realized_outcome_id");
   string candidateId         = EventSerializer_GetStr(line, "candidate_id");
   string candidateHash        = EventSerializer_GetStr(line, "candidate_hash");
   string labelSchemaVersion     = EventSerializer_GetStr(line, "label_schema_version");
   string label                    = EventSerializer_GetStr(line, "label");
   string outcomeReference           = EventSerializer_GetStr(line, "outcome_reference");
   string outcomeHash                  = EventSerializer_GetStr(line, "outcome_hash");
   string realizedOutcomeHash             = EventSerializer_GetStr(line, "realized_outcome_hash");
   string schemaVersion                     = EventSerializer_GetStr(line, "realized_outcome_schema_version");
   datetime outcomeTime = StringToTime(EventSerializer_GetStr(line, "outcome_time"));

   string fieldsErr = RealizedOutcomeProjection_ValidateRequiredFields(realizedOutcomeId, candidateId, candidateHash,
                                                                          labelSchemaVersion, label, outcomeReference, outcomeHash);
   if(fieldsErr != "") { outReason = fieldsErr; return false; }
   if(realizedOutcomeHash == "") { outReason = "missing realized_outcome_hash"; return false; }
   if(outcomeTime <= 0) { outReason = "outcome_time is zero/negative/unparsable"; return false; }

   int existingIdx = RealizedOutcomeProjection_FindIndex(realizedOutcomeId);
   if(existingIdx >= 0)
   {
      if(g_RealizedOutcomeProj_Records[existingIdx].realized_outcome_hash == realizedOutcomeHash)
      {
         outReason = "duplicate realized_outcome_id - already registered with an identical realized_outcome_hash, not re-applied";
         return true;
      }
      outReason = StringFormat("realized_outcome_id collision: '%s' already registered with realized_outcome_hash '%s', "
                                "this line carries a DIFFERENT realized_outcome_hash '%s' - rejected as a conflict, not a duplicate",
                                realizedOutcomeId, g_RealizedOutcomeProj_Records[existingIdx].realized_outcome_hash, realizedOutcomeHash);
      return false;
   }

   RealizedOutcomeProjectionRecord rec;
   RealizedOutcomeProjectionRecord_Init(rec);
   rec.realized_outcome_schema_version = schemaVersion;
   rec.realized_outcome_id              = realizedOutcomeId;
   rec.candidate_id                      = candidateId;
   rec.candidate_hash                     = candidateHash;
   rec.label_schema_version                = labelSchemaVersion;
   rec.label                                = label;
   rec.outcome_reference                     = outcomeReference;
   rec.outcome_hash                           = outcomeHash;
   rec.outcome_time                            = outcomeTime;
   rec.realized_outcome_hash                    = realizedOutcomeHash;
   rec.source_sequence_number                     = e.base.sequence_number;
   rec.source_log_event_id                          = e.base.log_event_id;

   RealizedOutcomeProjection_AppendRecord(rec);
   outReason = "applied - new realized outcome registered";
   return true;
}

// Referential-integrity-aware variant used by RebuildFromFile: rejects
// a TRADE_OUTCOME_LABELED line as an orphan (no matching candidate_id
// in CandidateProjection's own, already-rebuilt-from-the-same-file
// registry), a candidate_hash mismatch, or a temporal-boundary
// violation (outcome_time not strictly after the referenced
// candidate's own setup_anchor_bar_time) BEFORE ever calling
// RealizedOutcomeProjection_ApplyLine, so a referentially-broken or
// temporally-impossible outcome never reaches the registry regardless
// of how well-formed it otherwise looks. Every other line type is
// passed straight through to ApplyLine unchanged.
bool RealizedOutcomeProjection_ApplyLineWithCandidates(string line, string &outReason)
{
   if(EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_TRADE_OUTCOME_LABELED))
      return RealizedOutcomeProjection_ApplyLine(line, outReason);

   string candidateId   = EventSerializer_GetStr(line, "candidate_id");
   string candidateHash = EventSerializer_GetStr(line, "candidate_hash");
   datetime outcomeTime = StringToTime(EventSerializer_GetStr(line, "outcome_time"));

   CandidateProjectionRecord candRecord;
   if(!CandidateProjection_TryGet(candidateId, candRecord))
   {
      outReason = "orphan realized outcome: candidate_id '" + candidateId + "' has no matching CANDIDATE_CREATED event in this store - rejected";
      return false;
   }
   if(candRecord.candidate_hash != candidateHash)
   {
      outReason = "candidate_hash mismatch: realized outcome's candidate_hash does not match its referenced candidate's own candidate_hash - rejected";
      return false;
   }
   if(outcomeTime <= candRecord.setup_anchor_bar_time)
   {
      outReason = "temporal boundary violation: outcome_time is not strictly after the referenced candidate's setup_anchor_bar_time - rejected";
      return false;
   }

   return RealizedOutcomeProjection_ApplyLine(line, outReason);
}

//---------------------------------------------------------------------
// A from-scratch rebuild. Gated on EventStoreValidator first, THEN on
// CandidateProjection itself being successfully rebuilt from the SAME
// file - if either fails, THIS registry is left completely untouched.
//---------------------------------------------------------------------
struct RealizedOutcomeProjectionReport
{
   bool   ok;
   int    lines_total;
   int    lines_applied;  // genuinely new outcomes registered
   int    lines_skipped;  // non-TRADE_OUTCOME_LABELED lines, or idempotent duplicates
   int    lines_failed;   // malformed/corrupt/invalid/orphaned/temporally-impossible TRADE_OUTCOME_LABELED-typed lines
   string first_error;
};

void RealizedOutcomeProjectionReport_Init(RealizedOutcomeProjectionReport &r)
{
   r.ok = true;
   r.lines_total = 0;
   r.lines_applied = 0;
   r.lines_skipped = 0;
   r.lines_failed = 0;
   r.first_error = "";
}

RealizedOutcomeProjectionReport RealizedOutcomeProjection_RebuildFromFile(string fileName)
{
   RealizedOutcomeProjectionReport report;
   RealizedOutcomeProjectionReport_Init(report);

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

   RealizedOutcomeProjection_Reset();

   for(int i = 0; i < n; i++)
   {
      int beforeCount = RealizedOutcomeProjection_Count();
      string reason;
      bool applied = RealizedOutcomeProjection_ApplyLineWithCandidates(lines[i], reason);
      if(!applied)
      {
         report.ok = false;
         report.lines_failed++;
         if(report.first_error == "")
            report.first_error = StringFormat("line %d: %s", i, reason);
         continue;
      }
      if(RealizedOutcomeProjection_Count() > beforeCount)
         report.lines_applied++;
      else
         report.lines_skipped++;
   }
   return report;
}

#endif // __MLQUANTAI_REALIZEDOUTCOMEPROJECTION_MQH__
