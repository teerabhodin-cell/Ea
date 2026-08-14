//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh|
//| Phase B B6.1: a read-only candidate registry projected from        |
//| persisted CANDIDATE_CREATED lines - the "candidate dataset" read   |
//| model B6.2's export and B6.3's validator both build on. Sibling to |
//| MLQuantAI_StateProjector.mqh (which folds LifecycleEvents into      |
//| lifecycle STATE), except this one folds them into full candidate   |
//| CONTENT (every field Commit 5's extra_json persisted), keyed by    |
//| candidate_id.                                                      |
//|                                                                    |
//| Strictly additive and read-only: no B5 Strategies/ file (CRT       |
//| detector, ctx->candidate mapping, or event emission) is touched or |
//| depended on here - this only ever reads persisted lines back,      |
//| exactly what B6's own "no CRT rule changes, everything read-only   |
//| from the event store" discipline requires. No live market call,    |
//| no CopyRates/iTime/AccountInfo*/TimeCurrent(), no event append.    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CANDIDATEPROJECTION_MQH__
#define __MLQUANTAI_CANDIDATEPROJECTION_MQH__

#include "MLQuantAI_EventStore.mqh"

// Everything a CANDIDATE_CREATED line actually carries today: the native
// LifecycleEvent fields (candidate_id/root_event_id/correlation_id/
// strategy_id) plus every field Commit 5's CRT_CandidateCreatedExtraJson
// adds via extra_json. Deliberately does NOT include fields no persisted
// CANDIDATE_CREATED event carries yet - swept_level/mss_confirmation_
// price/resolved_zone_kind/resolved_zone_low/resolved_zone_high (only
// ever live on CRTDetectionResult, never copied onto TradeCandidate or
// the event) and instrument_id/trigger_timeframe/news_decision_hash/
// news_snapshot_identity (only live on MarketContext, joinable via
// context_event_id but not duplicated onto the candidate event). B6.2's
// canonical dataset column list wants all of these - inventing them here
// would mean either fabricating data this projection was never given or
// silently reaching into B5's sealed emission code, neither acceptable
// for a "read-only from what's already persisted" B6.1 gate. Flagged for
// the B6.2 kickoff decision: extend Commit 5's extra_json additively, or
// have the B6.2 export join against the corresponding MARKET_CONTEXT_
// READY event via context_event_id (which already exists specifically
// "so every candidate can be traced back to the exact snapshot it came
// from" - MarketContext.mqh's own stated B1 design intent).
struct CandidateProjectionRecord
{
   string   candidate_id;
   string   root_event_id;
   string   correlation_id;
   int      strategy_id;
   ENUM_CANDIDATE_STATE state; // always CANDIDATE_CREATED in this B6-only projection - B6 never applies later transitions

   string   context_event_id;
   string   context_hash;
   string   candidate_hash;
   string   detector_hash;
   string   candidate_schema_version;

   ENUM_ORDER_TYPE side;
   datetime setup_anchor_bar_time;
   int      expiry_after_bars;
   datetime expiry_time;

   double   entry_hint;
   double   sl_hint;
   double   tp_hint;

   ulong    trigger_reason_mask;
   string   trigger_reasons[];

   long     source_sequence_number; // audit trail: which event this record came from
   string   source_log_event_id;
};

void CandidateProjectionRecord_Init(CandidateProjectionRecord &r)
{
   r.candidate_id = "";
   r.root_event_id = "";
   r.correlation_id = "";
   r.strategy_id = -1;
   r.state = CANDIDATE_CREATED;

   r.context_event_id = "";
   r.context_hash = "";
   r.candidate_hash = "";
   r.detector_hash = "";
   r.candidate_schema_version = "";

   r.side = ORDER_TYPE_BUY;
   r.setup_anchor_bar_time = 0;
   r.expiry_after_bars = 0;
   r.expiry_time = 0;

   r.entry_hint = 0;
   r.sl_hint = 0;
   r.tp_hint = 0;

   r.trigger_reason_mask = 0;
   ArrayResize(r.trigger_reasons, 0);

   r.source_sequence_number = 0;
   r.source_log_event_id = "";
}

CandidateProjectionRecord g_CandProj_Records[];
int                       g_CandProj_Count = 0;

void CandidateProjection_Reset()
{
   ArrayResize(g_CandProj_Records, 0);
   g_CandProj_Count = 0;
}

int CandidateProjection_Count() { return g_CandProj_Count; }

int CandidateProjection_FindIndex(string candidateId)
{
   for(int i = 0; i < g_CandProj_Count; i++)
      if(g_CandProj_Records[i].candidate_id == candidateId)
         return i;
   return -1;
}

// The registry lookup B6.1's own spec names explicitly (CandidateLookup).
bool CandidateProjection_TryGet(string candidateId, CandidateProjectionRecord &out)
{
   int idx = CandidateProjection_FindIndex(candidateId);
   if(idx < 0) return false;
   out = g_CandProj_Records[idx];
   return true;
}

// Applies one raw persisted line to the registry. Returns false ONLY for
// a genuine failure (fail-closed) - a malformed line, a CANDIDATE_CREATED-
// typed line whose from/to state isn't the CREATED genesis shape, or an
// empty candidate_id. outReason always explains the outcome, whether
// success or failure, for audit.
//
// Returns true (a no-op, NOT an error) for:
//  - a line that isn't a CANDIDATE_CREATED event at all - this
//    projection only cares about candidate genesis, every other event
//    type/category in the store is legitimately irrelevant to it.
//  - a duplicate candidate_id already in the registry - idempotent by
//    design, matching StateProjector's own "duplicate CREATED genesis"
//    handling one layer up (a duplicate here would mean either a replay
//    re-applying the same line, or CRT_EmitCandidateCreated's own
//    session-level idempotency guard having a gap - either way, this
//    projection does not compound the problem by registering it twice).
bool CandidateProjection_ApplyLine(string line, string &outReason)
{
   LifecycleEvent e;
   if(!EventSerializer_ParseLifecycle(line, e))
   {
      outReason = "not a parsable lifecycle event line";
      return false;
   }

   if(e.base.event_type != EventTypeToString(EVENT_TYPE_CANDIDATE_CREATED))
   {
      outReason = "not a CANDIDATE_CREATED event - skipped, not relevant to this projection";
      return true;
   }

   if(e.from_state != CANDIDATE_CREATED || e.to_state != CANDIDATE_CREATED)
   {
      outReason = StringFormat("CANDIDATE_CREATED type but from/to state isn't the genesis shape (from=%s to=%s) - corruption",
                                CandidateStateToString(e.from_state), CandidateStateToString(e.to_state));
      return false;
   }

   if(e.candidate_id == "")
   {
      outReason = "empty candidate_id on a CANDIDATE_CREATED line - corruption";
      return false;
   }

   if(CandidateProjection_FindIndex(e.candidate_id) >= 0)
   {
      outReason = "duplicate candidate_id - already registered, not re-applied";
      return true;
   }

   CandidateProjectionRecord rec;
   CandidateProjectionRecord_Init(rec);
   rec.candidate_id   = e.candidate_id;
   rec.root_event_id  = e.root_event_id;
   rec.correlation_id = e.correlation_id;
   rec.strategy_id    = e.strategy_id;
   rec.state          = CANDIDATE_CREATED;

   rec.context_event_id         = EventSerializer_GetStr(line, "context_event_id");
   rec.context_hash              = EventSerializer_GetStr(line, "context_hash");
   rec.candidate_hash            = EventSerializer_GetStr(line, "candidate_hash");
   rec.detector_hash             = EventSerializer_GetStr(line, "detector_hash");
   rec.candidate_schema_version  = EventSerializer_GetStr(line, "candidate_schema_version");

   rec.side = (EventSerializer_GetStr(line, "side") == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   rec.setup_anchor_bar_time = StringToTime(EventSerializer_GetStr(line, "setup_anchor_bar_time"));
   rec.expiry_after_bars      = EventSerializer_GetInt(line, "expiry_after_bars");
   rec.expiry_time             = StringToTime(EventSerializer_GetStr(line, "expiry_time"));

   rec.entry_hint = EventSerializer_GetDouble(line, "entry_hint");
   rec.sl_hint    = EventSerializer_GetDouble(line, "sl_hint");
   rec.tp_hint    = EventSerializer_GetDouble(line, "tp_hint");

   rec.trigger_reason_mask = (ulong)EventSerializer_GetLong(line, "trigger_reason_mask");
   EventSerializer_GetStringArray(line, "trigger_reasons", rec.trigger_reasons);

   rec.source_sequence_number = e.base.sequence_number;
   rec.source_log_event_id     = e.base.log_event_id;

   ArrayResize(g_CandProj_Records, g_CandProj_Count + 1);
   g_CandProj_Records[g_CandProj_Count] = rec;
   g_CandProj_Count++;

   outReason = "applied - new candidate registered";
   return true;
}

// A from-scratch rebuild: resets the registry, reads every line in
// fileName (via EventStore_ReadAllLines, the same read-back primitive
// ReplayEngine/the Validator already use), and applies each in file
// order. Always a full rebuild, never incremental - same discipline
// ReplayEngine_Run's own StateProjector_Reset() call follows.
struct CandidateProjectionReport
{
   bool   ok;
   int    lines_total;
   int    lines_applied;  // genuinely new candidates registered
   int    lines_skipped;  // non-CANDIDATE_CREATED lines, or idempotent duplicates
   int    lines_failed;   // malformed/corrupt CANDIDATE_CREATED-typed lines
   string first_error;
};

void CandidateProjectionReport_Init(CandidateProjectionReport &r)
{
   r.ok = true;
   r.lines_total = 0;
   r.lines_applied = 0;
   r.lines_skipped = 0;
   r.lines_failed = 0;
   r.first_error = "";
}

CandidateProjectionReport CandidateProjection_RebuildFromFile(string fileName)
{
   CandidateProjectionReport report;
   CandidateProjectionReport_Init(report);

   CandidateProjection_Reset();

   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);
   report.lines_total = n;

   for(int i = 0; i < n; i++)
   {
      int beforeCount = CandidateProjection_Count();
      string reason;
      bool applied = CandidateProjection_ApplyLine(lines[i], reason);
      if(!applied)
      {
         report.ok = false;
         report.lines_failed++;
         if(report.first_error == "")
            report.first_error = StringFormat("line %d: %s", i, reason);
         continue;
      }
      if(CandidateProjection_Count() > beforeCount)
         report.lines_applied++;
      else
         report.lines_skipped++;
   }
   return report;
}

#endif // __MLQUANTAI_CANDIDATEPROJECTION_MQH__
