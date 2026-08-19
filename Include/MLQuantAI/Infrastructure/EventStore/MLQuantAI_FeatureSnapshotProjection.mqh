//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_FeatureSnapshotProjection.mqh|
//| Phase B8.2 Commit 2 (Part 0): a read-only FeatureSnapshot registry |
//| projected from persisted FEATURE_SNAPSHOT_CREATED lines, mirroring |
//| MLQuantAI_RiskPlanProjection.mqh's exact structure and hardening   |
//| discipline (schema/required-field/numerical validation,            |
//| payload-aware collision-vs-duplicate detection, referential         |
//| integrity, EventStoreValidator-gated atomic rebuild). See           |
//| Docs/PhaseB_B8_2_Commit2_ExportContract.md's Part 0 for the full     |
//| contract this file implements.                                      |
//|                                                                    |
//| Strictly additive and read-only: no B5/B6/B7/B8.1 sealed file      |
//| touched, no live market/broker/account call, no event append here   |
//| (that's MLQuantAI_FeatureSnapshotEventEmission.mqh). Depends on      |
//| MLQuantAI_CandidateProjection.mqh (rebuilt from the SAME file        |
//| immediately before this one, as a referential-integrity              |
//| prerequisite) - the same dependency direction                       |
//| MLQuantAI_RiskPlanProjection.mqh already has on it.                  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_FEATURESNAPSHOTPROJECTION_MQH__
#define __MLQUANTAI_FEATURESNAPSHOTPROJECTION_MQH__

#include "MLQuantAI_CandidateProjection.mqh"
#include "../../Market/MLQuantAI_FeatureSnapshot.mqh"

#define MLQUANTAI_FEATURESNAPSHOTPROJ_MAX_LINE_LENGTH 65536

struct FeatureSnapshotProjectionRecord
{
   string feature_schema_version;
   string context_event_id;

   double atr_m15;
   double adx_m15;
   double ema_slope_m15;
   double pdh;
   double pdl;
   double asian_range_high;
   double asian_range_low;
   double spread_points_at_anchor;

   int    news_count;
   int    max_news_impact;
   int    nearest_news_minutes;
   bool   is_kill_zone;

   string feature_snapshot_id;
   string candidate_id;
   string candidate_hash;
   string context_hash;
   string detector_hash;
   string feature_vector_hash;
   string feature_snapshot_hash;

   long   source_sequence_number; // audit trail: which event this record came from
   string source_log_event_id;
};

void FeatureSnapshotProjectionRecord_Init(FeatureSnapshotProjectionRecord &r)
{
   r.feature_schema_version = "";
   r.context_event_id = "";

   r.atr_m15 = 0;
   r.adx_m15 = 0;
   r.ema_slope_m15 = 0;
   r.pdh = 0;
   r.pdl = 0;
   r.asian_range_high = 0;
   r.asian_range_low = 0;
   r.spread_points_at_anchor = 0;

   r.news_count = 0;
   r.max_news_impact = 0;
   r.nearest_news_minutes = 0;
   r.is_kill_zone = false;

   r.feature_snapshot_id = "";
   r.candidate_id = "";
   r.candidate_hash = "";
   r.context_hash = "";
   r.detector_hash = "";
   r.feature_vector_hash = "";
   r.feature_snapshot_hash = "";

   r.source_sequence_number = 0;
   r.source_log_event_id = "";
}

FeatureSnapshotProjectionRecord g_FeatSnapProj_Records[];
int                             g_FeatSnapProj_Count = 0;

void FeatureSnapshotProjection_Reset()
{
   ArrayResize(g_FeatSnapProj_Records, 0);
   g_FeatSnapProj_Count = 0;
}

int FeatureSnapshotProjection_Count() { return g_FeatSnapProj_Count; }

int FeatureSnapshotProjection_FindIndex(string featureSnapshotId)
{
   for(int i = 0; i < g_FeatSnapProj_Count; i++)
      if(g_FeatSnapProj_Records[i].feature_snapshot_id == featureSnapshotId)
         return i;
   return -1;
}

bool FeatureSnapshotProjection_TryGet(string featureSnapshotId, FeatureSnapshotProjectionRecord &out)
{
   int idx = FeatureSnapshotProjection_FindIndex(featureSnapshotId);
   if(idx < 0) return false;
   out = g_FeatSnapProj_Records[idx];
   return true;
}

bool FeatureSnapshotProjection_GetAt(int index, FeatureSnapshotProjectionRecord &out)
{
   if(index < 0 || index >= g_FeatSnapProj_Count) return false;
   out = g_FeatSnapProj_Records[index];
   return true;
}

void FeatureSnapshotProjection_AppendRecord(const FeatureSnapshotProjectionRecord &rec)
{
   int idx = g_FeatSnapProj_Count;
   ArrayResize(g_FeatSnapProj_Records, idx + 1);
   g_FeatSnapProj_Records[idx] = rec;
   g_FeatSnapProj_Count++;
}

// Live-session sync path - called directly by
// FeatureSnapshot_EmitFeatureSnapshotCreated right after a durable
// write, from the in-memory FeatureSnapshot struct itself (no JSON
// round-trip needed, unlike the replay path below). Does NOT re-check
// for an existing record - the emitter's own
// FeatureSnapshotProjection_TryGet guard already ensured this
// feature_snapshot_id is new before writing.
void FeatureSnapshotProjection_ApplyLiveRecord(const FeatureSnapshot &f)
{
   FeatureSnapshotProjectionRecord rec;
   FeatureSnapshotProjectionRecord_Init(rec);
   rec.feature_schema_version = f.feature_schema_version;
   rec.context_event_id        = f.context_event_id;
   rec.atr_m15                  = f.atr_m15;
   rec.adx_m15                   = f.adx_m15;
   rec.ema_slope_m15              = f.ema_slope_m15;
   rec.pdh                         = f.pdh;
   rec.pdl                          = f.pdl;
   rec.asian_range_high              = f.asian_range_high;
   rec.asian_range_low                = f.asian_range_low;
   rec.spread_points_at_anchor          = f.spread_points_at_anchor;
   rec.news_count                        = f.news_count;
   rec.max_news_impact                    = f.max_news_impact;
   rec.nearest_news_minutes                = f.nearest_news_minutes;
   rec.is_kill_zone                          = f.is_kill_zone;
   rec.feature_snapshot_id                    = f.feature_snapshot_id;
   rec.candidate_id                            = f.candidate_id;
   rec.candidate_hash                           = f.candidate_hash;
   rec.context_hash                              = f.context_hash;
   rec.detector_hash                              = f.detector_hash;
   rec.feature_vector_hash                         = f.feature_vector_hash;
   rec.feature_snapshot_hash                        = f.feature_snapshot_hash;
   // source_sequence_number/source_log_event_id stay at Init()
   // defaults (0/"") for a live-applied record - the durable append
   // already happened via EventStore_LogSystem, which owns the real
   // seq/log_event_id assignment.
   FeatureSnapshotProjection_AppendRecord(rec);
}

//---------------------------------------------------------------------
// Validation helpers - mirrors RiskPlanProjection's own ladder.
//---------------------------------------------------------------------
string FeatureSnapshotProjection_ValidateRequiredFields(string featureSnapshotId, string candidateId, string candidateHash,
                                                          string contextEventId, string contextHash, string detectorHash,
                                                          string featureVectorHash, string featureSchemaVersion)
{
   if(featureSnapshotId == "")   return "missing feature_snapshot_id";
   if(candidateId == "")          return "missing candidate_id";
   if(candidateHash == "")        return "missing candidate_hash";
   if(contextEventId == "")       return "missing context_event_id";
   if(contextHash == "")           return "missing context_hash";
   if(detectorHash == "")          return "missing detector_hash";
   if(featureVectorHash == "")      return "missing feature_vector_hash";
   if(featureSchemaVersion == "")   return "missing feature_schema_version";
   return "";
}

string FeatureSnapshotProjection_ValidateNumericalIntegrity(double atrM15, double adxM15, double emaSlopeM15,
                                                              double pdh, double pdl, double asianRangeHigh,
                                                              double asianRangeLow, double spreadPointsAtAnchor)
{
   if(!MathIsValidNumber(atrM15) || !MathIsValidNumber(adxM15) || !MathIsValidNumber(emaSlopeM15))
      return "atr_m15/adx_m15/ema_slope_m15 contains NaN or Inf";
   if(!MathIsValidNumber(pdh) || !MathIsValidNumber(pdl))
      return "pdh/pdl contains NaN or Inf";
   if(!MathIsValidNumber(asianRangeHigh) || !MathIsValidNumber(asianRangeLow))
      return "asian_range_high/asian_range_low contains NaN or Inf";
   if(!MathIsValidNumber(spreadPointsAtAnchor))
      return "spread_points_at_anchor contains NaN or Inf";
   return "";
}

// EventSerializer_GetStr's needle requires a quoted value
// ("key":"value") - is_kill_zone is emitted as an unquoted JSON
// boolean literal ("key":true/false, matching MarketContext's own
// is_kill_zone serialization convention), so GetStr would always
// return "" for it. This local helper reads that literal directly -
// kept local to this file rather than added to the shared, sealed
// EventSerializer.mqh, since no other projection in this codebase has
// ever needed to read a raw boolean back from JSON yet.
bool FeatureSnapshotProjection_GetBoolLiteral(string json, string key)
{
   return StringFind(json, "\"" + key + "\":true") >= 0;
}

//---------------------------------------------------------------------
// Applies one raw persisted line to the registry - the replay path.
//---------------------------------------------------------------------
bool FeatureSnapshotProjection_ApplyLine(string line, string &outReason)
{
   if(StringLen(line) > MLQUANTAI_FEATURESNAPSHOTPROJ_MAX_LINE_LENGTH)
   {
      outReason = "line exceeds the defensive length bound - rejected before parsing";
      return false;
   }

   if(EventSerializer_HasKey(line, "type") &&
      EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_FEATURE_SNAPSHOT_CREATED))
   {
      outReason = "not a FEATURE_SNAPSHOT_CREATED event - skipped, not relevant to this projection";
      return true;
   }

   SystemEvent e;
   if(!EventSerializer_ParseSystem(line, e))
   {
      outReason = "not a parsable event line";
      return false;
   }

   string featureSnapshotId  = EventSerializer_GetStr(line, "feature_snapshot_id");
   string candidateId         = EventSerializer_GetStr(line, "candidate_id");
   string candidateHash        = EventSerializer_GetStr(line, "candidate_hash");
   string contextEventId        = EventSerializer_GetStr(line, "context_event_id");
   string contextHash             = EventSerializer_GetStr(line, "context_hash");
   string detectorHash              = EventSerializer_GetStr(line, "detector_hash");
   string featureVectorHash           = EventSerializer_GetStr(line, "feature_vector_hash");
   string featureSnapshotHash           = EventSerializer_GetStr(line, "feature_snapshot_hash");
   string featureSchemaVersion            = EventSerializer_GetStr(line, "feature_schema_version");

   string fieldsErr = FeatureSnapshotProjection_ValidateRequiredFields(featureSnapshotId, candidateId, candidateHash,
                                                                          contextEventId, contextHash, detectorHash,
                                                                          featureVectorHash, featureSchemaVersion);
   if(fieldsErr != "") { outReason = fieldsErr; return false; }
   if(featureSnapshotHash == "") { outReason = "missing feature_snapshot_hash"; return false; }

   double atrM15               = EventSerializer_GetDouble(line, "atr_m15");
   double adxM15                 = EventSerializer_GetDouble(line, "adx_m15");
   double emaSlopeM15              = EventSerializer_GetDouble(line, "ema_slope_m15");
   double pdh                        = EventSerializer_GetDouble(line, "pdh");
   double pdl                          = EventSerializer_GetDouble(line, "pdl");
   double asianRangeHigh                 = EventSerializer_GetDouble(line, "asian_range_high");
   double asianRangeLow                    = EventSerializer_GetDouble(line, "asian_range_low");
   double spreadPointsAtAnchor                = EventSerializer_GetDouble(line, "spread_points_at_anchor");
   int    newsCount                             = EventSerializer_GetInt(line, "news_count");
   int    maxNewsImpact                           = EventSerializer_GetInt(line, "max_news_impact");
   int    nearestNewsMinutes                        = EventSerializer_GetInt(line, "nearest_news_minutes");
   bool   isKillZone                                  = FeatureSnapshotProjection_GetBoolLiteral(line, "is_kill_zone");

   string numErr = FeatureSnapshotProjection_ValidateNumericalIntegrity(atrM15, adxM15, emaSlopeM15, pdh, pdl,
                                                                          asianRangeHigh, asianRangeLow, spreadPointsAtAnchor);
   if(numErr != "") { outReason = numErr; return false; }

   int existingIdx = FeatureSnapshotProjection_FindIndex(featureSnapshotId);
   if(existingIdx >= 0)
   {
      if(g_FeatSnapProj_Records[existingIdx].feature_snapshot_hash == featureSnapshotHash)
      {
         outReason = "duplicate feature_snapshot_id - already registered with an identical feature_snapshot_hash, not re-applied";
         return true;
      }
      outReason = StringFormat("feature_snapshot_id collision: '%s' already registered with feature_snapshot_hash '%s', "
                                "this line carries a DIFFERENT feature_snapshot_hash '%s' - rejected as a conflict, not a duplicate",
                                featureSnapshotId, g_FeatSnapProj_Records[existingIdx].feature_snapshot_hash, featureSnapshotHash);
      return false;
   }

   FeatureSnapshotProjectionRecord rec;
   FeatureSnapshotProjectionRecord_Init(rec);
   rec.feature_schema_version = featureSchemaVersion;
   rec.context_event_id        = contextEventId;
   rec.atr_m15                   = atrM15;
   rec.adx_m15                    = adxM15;
   rec.ema_slope_m15                = emaSlopeM15;
   rec.pdh                            = pdh;
   rec.pdl                              = pdl;
   rec.asian_range_high                   = asianRangeHigh;
   rec.asian_range_low                      = asianRangeLow;
   rec.spread_points_at_anchor                 = spreadPointsAtAnchor;
   rec.news_count                                = newsCount;
   rec.max_news_impact                             = maxNewsImpact;
   rec.nearest_news_minutes                          = nearestNewsMinutes;
   rec.is_kill_zone                                    = isKillZone;
   rec.feature_snapshot_id                              = featureSnapshotId;
   rec.candidate_id                                       = candidateId;
   rec.candidate_hash                                      = candidateHash;
   rec.context_hash                                          = contextHash;
   rec.detector_hash                                           = detectorHash;
   rec.feature_vector_hash                                       = featureVectorHash;
   rec.feature_snapshot_hash                                       = featureSnapshotHash;
   rec.source_sequence_number                                        = e.base.sequence_number;
   rec.source_log_event_id                                             = e.base.log_event_id;

   FeatureSnapshotProjection_AppendRecord(rec);
   outReason = "applied - new feature snapshot registered";
   return true;
}

// Referential-integrity-aware variant used by RebuildFromFile: rejects
// a FEATURE_SNAPSHOT_CREATED line as an orphan (no matching
// candidate_id in CandidateProjection's own, already-rebuilt-from-the-
// same-file registry) or a candidate_hash mismatch BEFORE ever calling
// FeatureSnapshotProjection_ApplyLine, so a referentially-broken
// snapshot never reaches the registry regardless of how well-formed it
// otherwise looks. Every other line type is passed straight through to
// ApplyLine unchanged.
bool FeatureSnapshotProjection_ApplyLineWithCandidates(string line, string &outReason)
{
   if(EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_FEATURE_SNAPSHOT_CREATED))
      return FeatureSnapshotProjection_ApplyLine(line, outReason);

   string candidateId   = EventSerializer_GetStr(line, "candidate_id");
   string candidateHash = EventSerializer_GetStr(line, "candidate_hash");

   CandidateProjectionRecord candRecord;
   if(!CandidateProjection_TryGet(candidateId, candRecord))
   {
      outReason = "orphan feature snapshot: candidate_id '" + candidateId + "' has no matching CANDIDATE_CREATED event in this store - rejected";
      return false;
   }
   if(candRecord.candidate_hash != candidateHash)
   {
      outReason = "candidate_hash mismatch: feature snapshot's candidate_hash does not match its referenced candidate's own candidate_hash - rejected";
      return false;
   }

   return FeatureSnapshotProjection_ApplyLine(line, outReason);
}

//---------------------------------------------------------------------
// A from-scratch rebuild. Gated on EventStoreValidator first, THEN on
// CandidateProjection itself being successfully rebuilt from the SAME
// file - if either fails, THIS registry is left completely untouched.
//---------------------------------------------------------------------
struct FeatureSnapshotProjectionReport
{
   bool   ok;
   int    lines_total;
   int    lines_applied;  // genuinely new snapshots registered
   int    lines_skipped;  // non-FEATURE_SNAPSHOT_CREATED lines, or idempotent duplicates
   int    lines_failed;   // malformed/corrupt/invalid/orphaned FEATURE_SNAPSHOT_CREATED-typed lines
   string first_error;
};

void FeatureSnapshotProjectionReport_Init(FeatureSnapshotProjectionReport &r)
{
   r.ok = true;
   r.lines_total = 0;
   r.lines_applied = 0;
   r.lines_skipped = 0;
   r.lines_failed = 0;
   r.first_error = "";
}

FeatureSnapshotProjectionReport FeatureSnapshotProjection_RebuildFromFile(string fileName)
{
   FeatureSnapshotProjectionReport report;
   FeatureSnapshotProjectionReport_Init(report);

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

   FeatureSnapshotProjection_Reset();

   for(int i = 0; i < n; i++)
   {
      int beforeCount = FeatureSnapshotProjection_Count();
      string reason;
      bool applied = FeatureSnapshotProjection_ApplyLineWithCandidates(lines[i], reason);
      if(!applied)
      {
         report.ok = false;
         report.lines_failed++;
         if(report.first_error == "")
            report.first_error = StringFormat("line %d: %s", i, reason);
         continue;
      }
      if(FeatureSnapshotProjection_Count() > beforeCount)
         report.lines_applied++;
      else
         report.lines_skipped++;
   }
   return report;
}

#endif // __MLQUANTAI_FEATURESNAPSHOTPROJECTION_MQH__
