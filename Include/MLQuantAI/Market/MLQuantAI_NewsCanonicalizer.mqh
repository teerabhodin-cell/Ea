//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_NewsCanonicalizer.mqh                |
//| Phase B B4: the ONE place raw news data gets turned into decision-|
//| relevant, source-independent events. Every function here is pure  |
//| (no MT5 calendar access, no file I/O) so it's fully testable      |
//| without a live broker connection - see                            |
//| Tests/MLQuantAI_Test_NewsParity.mq5.                               |
//|                                                                    |
//| Pipeline: RawNewsEvent[] -> (normalize) -> NormalizedNewsEvent[]  |
//| -> (dedup) -> (sort + select) -> NewsSnapshot[] for embedding in  |
//| MarketContext. Both LiveCalendarNewsSource and CsvStaticNewsSource|
//| route through this SAME pipeline - neither source is allowed its  |
//| own normalization logic (MLQuantAI_NewsSource.mqh's INewsSource   |
//| contract only reads raw data).                                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_NEWSCANONICALIZER_MQH__
#define __MLQUANTAI_NEWSCANONICALIZER_MQH__

#include "MLQuantAI_NewsSource.mqh"
#include "MLQuantAI_NewsSnapshot.mqh"
#include "../Core/MLQuantAI_Ids.mqh"
#include "../Core/MLQuantAI_ContractVersions.mqh"

// FROZEN window/selection contract (Phase B B4) - not input-tunable on
// purpose. Changing these would change what "the same anchor bar"
// selects, which would break replay determinism for anything logged
// under the current values; a real change here needs a new schema
// version, the same discipline MLQuantAI_ContractVersions.mqh already
// runs on for every other frozen constant.
#define MLQUANTAI_NEWS_LOOKBACK_MINUTES  1440
#define MLQUANTAI_NEWS_LOOKAHEAD_MINUTES 1440
#define MLQUANTAI_NEWS_MAX_EVENTS        10

// The pipeline's internal working struct - a superset of NewsSnapshot's
// fields plus source_content_hash, which is audit-only and deliberately
// NOT part of the final embedded NewsSnapshot (it describes the raw
// payload, not the normalized event).
struct NormalizedNewsEvent
{
   string   calendar_event_id;
   string   normalized_event_key;
   string   currency;
   int      impact_normalized;
   string   title_normalized;
   datetime release_time_utc;
   int      minutes_to_event;

   string   news_schema_version;
   string   revision_id;
   datetime revision_timestamp;

   string   source_kind;
   string   source_version;
   string   source_content_hash;
   int      source_priority;

   // Phase B B4 seal hardening: additive, optional - see RawNewsEvent's
   // matching fields in MLQuantAI_NewsSource.mqh for why these exist.
   // Carried through News_NormalizedEvent_From_Raw() and folded into
   // News_SnapshotIdentity() (audit trail) but deliberately excluded from
   // News_DecisionHash() and NewsSnapshot itself - see
   // Tests/MLQuantAI_Test_NewsSchemaEvolution.mq5.
   string   forecast;
   string   actual;
   string   previous;
};

void NormalizedNewsEvent_Init(NormalizedNewsEvent &e)
{
   e.calendar_event_id = "";
   e.normalized_event_key = "";
   e.currency = "";
   e.impact_normalized = 0;
   e.title_normalized = "";
   e.release_time_utc = 0;
   e.minutes_to_event = 0;

   e.news_schema_version = MLQUANTAI_NEWS_SCHEMA_V1;
   e.revision_id = "";
   e.revision_timestamp = 0;

   e.source_kind = "";
   e.source_version = "";
   e.source_content_hash = "";
   e.source_priority = 0;

   e.forecast = "";
   e.actual = "";
   e.previous = "";
}

//---------------------------------------------------------------------
// Normalization primitives
//---------------------------------------------------------------------

// Trims, collapses internal whitespace runs to a single space, and
// upper-cases - so "Non-Farm Payrolls", " non-farm   payrolls ", and
// "NON-FARM PAYROLLS" all normalize to the identical string. Case/
// whitespace variance is exactly what a human-edited CSV or a calendar
// provider's own formatting quirks would introduce; the normalized_event_key
// built from this must not fracture on that noise.
string News_NormalizeTitle(string title)
{
   string t = title;
   StringTrimLeft(t);
   StringTrimRight(t);
   StringToUpper(t);

   string collapsed = "";
   bool lastWasSpace = false;
   int n = StringLen(t);
   for(int i = 0; i < n; i++)
   {
      ushort ch = StringGetCharacter(t, i);
      bool isSpace = (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n');
      if(isSpace)
      {
         if(!lastWasSpace) collapsed += " ";
         lastWasSpace = true;
      }
      else
      {
         collapsed += StringFormat("%c", ch);
         lastWasSpace = false;
      }
   }
   return collapsed;
}

// Case-insensitive impact mapping onto a fixed integer scale (shared with
// NewsSnapshot.impact's existing convention): 0=NONE/unrecognized,
// 1=LOW, 2=MEDIUM/MODERATE, 3=HIGH. Also accepts a plain numeric string
// ("0".."3") in case a source already reports the normalized scale.
int News_NormalizeImpact(string impactRaw)
{
   string u = impactRaw;
   StringTrimLeft(u);
   StringTrimRight(u);
   StringToUpper(u);

   if(u == "HIGH" || u == "3")               return 3;
   if(u == "MEDIUM" || u == "MODERATE" || u == "2") return 2;
   if(u == "LOW" || u == "1")                return 1;
   return 0;
}

// "UTC" in this project means the SAME single canonical clock every
// closed-bar/anchor computation already uses project-wide (broker server
// time, per iTime/TimeCurrent() throughout Market/MLQuantAI_*.mqh) - MQL5
// has no reliable way to convert an arbitrary HISTORICAL datetime to true
// UTC without knowing the broker's GMT offset at that exact historical
// moment (which can include DST transitions), so this is deliberately an
// identity pass-through, not a real timezone conversion. Named _utc to
// match the frozen field name and to signal "this is the canonical
// clock", not because it performs a real UTC conversion. Documented
// explicitly as a known limitation - see Docs/PhaseB_B4_NewsParity.md.
datetime News_NormalizeTimeUtc(datetime sourceTime)
{
   return sourceTime;
}

string News_MakeCanonicalEventKey(string currency, string normalizedTitle, datetime releaseTimeUtc)
{
   string curUpper = currency;
   StringToUpper(curUpper);
   return curUpper + "|" + normalizedTitle + "|" + TimeToString(releaseTimeUtc, TIME_DATE|TIME_SECONDS);
}

// Truncates toward zero for both positive and negative offsets - MQL5
// integer division on signed integral types already truncates toward
// zero (matching C/C++ since C99), so plain division is correct here for
// both "event already released" (negative) and "event still ahead"
// (positive) without any extra branching.
int News_ComputeMinutesToEvent(datetime releaseTimeUtc, datetime anchorTimeUtc)
{
   long diffSeconds = (long)releaseTimeUtc - (long)anchorTimeUtc;
   return (int)(diffSeconds / 60);
}

void News_NormalizedEvent_From_Raw(const RawNewsEvent &raw, datetime anchorTimeUtc, NormalizedNewsEvent &out)
{
   NormalizedNewsEvent_Init(out);

   out.currency           = raw.currency;
   out.impact_normalized   = News_NormalizeImpact(raw.impact_raw);
   out.title_normalized     = News_NormalizeTitle(raw.title);
   out.release_time_utc      = News_NormalizeTimeUtc(raw.release_time);
   out.normalized_event_key   = News_MakeCanonicalEventKey(out.currency, out.title_normalized, out.release_time_utc);
   out.minutes_to_event        = News_ComputeMinutesToEvent(out.release_time_utc, anchorTimeUtc);

   out.calendar_event_id = raw.provider_event_id;
   out.revision_id         = raw.revision_id;
   out.revision_timestamp   = raw.revision_timestamp;

   out.source_kind           = raw.source_kind;
   out.source_version         = raw.source_version;
   out.source_content_hash     = raw.source_content_hash;
   out.source_priority          = raw.source_priority;

   out.forecast = raw.forecast;
   out.actual   = raw.actual;
   out.previous = raw.previous;
}

int News_NormalizeAll(const RawNewsEvent &rawArr[], datetime anchorTimeUtc, NormalizedNewsEvent &outArr[])
{
   int n = ArraySize(rawArr);
   ArrayResize(outArr, n);
   for(int i = 0; i < n; i++)
      News_NormalizedEvent_From_Raw(rawArr[i], anchorTimeUtc, outArr[i]);
   return n;
}

//---------------------------------------------------------------------
// Dedup - same normalized_event_key reported by more than one row
// (possible even from a single source, e.g. a source republishing a
// revision) collapses to ONE event via a deterministic tie-break.
//---------------------------------------------------------------------

// Returns >0 if 'a' wins over 'b', <0 if 'b' wins, 0 if fully tied
// (identical priority, revision_timestamp, and source_kind).
int News_CompareForDedup(const NormalizedNewsEvent &a, const NormalizedNewsEvent &b)
{
   if(a.source_priority != b.source_priority)
      return (a.source_priority > b.source_priority) ? 1 : -1;
   if(a.revision_timestamp != b.revision_timestamp)
      return (a.revision_timestamp > b.revision_timestamp) ? 1 : -1;
   if(a.source_kind != b.source_kind)
      return (a.source_kind < b.source_kind) ? 1 : -1; // lexically smaller source_kind wins, an arbitrary but deterministic tie-break
   return 0;
}

// Collapses inArr[] to at most one event per normalized_event_key, using
// News_CompareForDedup's tie-break order. If two candidates for the same
// key are FULLY tied (all three tie-break fields equal) YET their
// decision-relevant fields (impact_normalized/release_time_utc) actually
// disagree, that is a genuine data-quality conflict - returns false
// rather than silently picking one, so a parity fixture with a real
// conflict fails loudly instead of nondeterministically picking a winner
// based on array order.
bool News_Deduplicate(const NormalizedNewsEvent &inArr[], NormalizedNewsEvent &outArr[], string &outError)
{
   outError = "";
   ArrayResize(outArr, 0);

   int n = ArraySize(inArr);
   for(int i = 0; i < n; i++)
   {
      int existingIdx = -1;
      for(int j = 0; j < ArraySize(outArr); j++)
      {
         if(outArr[j].normalized_event_key == inArr[i].normalized_event_key)
         {
            existingIdx = j;
            break;
         }
      }

      if(existingIdx < 0)
      {
         ArrayResize(outArr, ArraySize(outArr) + 1);
         outArr[ArraySize(outArr) - 1] = inArr[i];
         continue;
      }

      int cmp = News_CompareForDedup(outArr[existingIdx], inArr[i]);
      if(cmp == 0)
      {
         bool decisionFieldsAgree = (outArr[existingIdx].impact_normalized == inArr[i].impact_normalized &&
                                      outArr[existingIdx].release_time_utc == inArr[i].release_time_utc);
         if(!decisionFieldsAgree)
         {
            outError = StringFormat("News_Deduplicate: conflicting decision fields for normalized_event_key '%s' "
                                     "with no tie-break winner (equal source_priority/revision_timestamp/source_kind)",
                                     inArr[i].normalized_event_key);
            return false;
         }
         // fully tied and decision fields agree - keep the existing entry, no-op
      }
      else if(cmp < 0)
      {
         outArr[existingIdx] = inArr[i]; // candidate wins the tie-break
      }
      // else existing already wins - no-op
   }
   return true;
}

//---------------------------------------------------------------------
// Sort + select
//---------------------------------------------------------------------

// true if 'a' sorts before 'b': abs(minutes_to_event) ASC, then
// impact_normalized DESC, then release_time_utc ASC, then
// normalized_event_key ASC (final deterministic tie-break).
bool News_SortLess(const NormalizedNewsEvent &a, const NormalizedNewsEvent &b)
{
   int absA = (int)MathAbs(a.minutes_to_event);
   int absB = (int)MathAbs(b.minutes_to_event);
   if(absA != absB) return absA < absB;
   if(a.impact_normalized != b.impact_normalized) return a.impact_normalized > b.impact_normalized;
   if(a.release_time_utc != b.release_time_utc) return a.release_time_utc < b.release_time_utc;
   return a.normalized_event_key < b.normalized_event_key;
}

// Sorts in place (insertion sort - these arrays are always small, at
// most a handful of news rows near one anchor bar), then truncates to
// maxEvents. The sort key is fully deterministic (no equal-rank ties
// left unresolved thanks to the normalized_event_key tie-break), so the
// same input set always selects the same top-N regardless of the order
// the source originally returned it in.
void News_SortAndSelect(NormalizedNewsEvent &arr[], int maxEvents)
{
   int n = ArraySize(arr);
   for(int i = 1; i < n; i++)
   {
      NormalizedNewsEvent key = arr[i];
      int j = i - 1;
      while(j >= 0 && News_SortLess(key, arr[j]))
      {
         arr[j + 1] = arr[j];
         j--;
      }
      arr[j + 1] = key;
   }
   if(ArraySize(arr) > maxEvents)
      ArrayResize(arr, maxEvents);
}

//---------------------------------------------------------------------
// Hashes over the FINAL selected set
//---------------------------------------------------------------------

// news_decision_hash: hash of ONLY the fields that could affect a
// trading decision (currency/impact_normalized/release_time_utc/
// minutes_to_event), per selected event, in final sorted order.
// Deliberately excludes calendar_event_id/title/lineage/provenance -
// two DIFFERENT sources (or two different provider event ids for what's
// really the same economic release) that agree on decision-relevant
// fields produce the SAME news_decision_hash. This is what feeds
// MarketContext's overall context_hash (see
// MLQuantAI_MarketContext.mqh's MarketContext_HashPayload) - metadata-
// only differences must never move context_hash, and this hash is how
// that's enforced.
string News_DecisionHash(const NormalizedNewsEvent &arr[])
{
   string payload = "";
   for(int i = 0; i < ArraySize(arr); i++)
      payload += arr[i].currency + "|" + IntegerToString(arr[i].impact_normalized) + "|" +
                 TimeToString(arr[i].release_time_utc, TIME_DATE|TIME_SECONDS) + "|" +
                 IntegerToString(arr[i].minutes_to_event) + ";";
   return Ids_Sha256Hex(payload);
}

// news_snapshot_identity: hash of the full selected set INCLUDING
// lineage/provenance (normalized_event_key, calendar_event_id,
// revision_id, revision_timestamp, source_kind, source_priority, and -
// Phase B B4 seal hardening - forecast/actual/previous) - changes
// whenever ANY metadata changes, even when the decision-relevant fields
// stay the same (e.g. a revision correction, a different source_priority
// tie-break winner, or a consensus/actual value updating). This is the
// audit-trail hash B5's dataset lineage keys off - distinct from
// news_decision_hash, which stays stable across exactly these kinds of
// metadata-only changes. Safe to extend the payload here (same
// reasoning as MLQuantAI_MarketContext.mqh's MarketContext_HashPayload
// change): no candidate dataset yet depends on a historical
// news_snapshot_identity value, since B5 hasn't started.
string News_SnapshotIdentity(const NormalizedNewsEvent &arr[])
{
   string payload = "";
   for(int i = 0; i < ArraySize(arr); i++)
      payload += arr[i].normalized_event_key + "|" + arr[i].calendar_event_id + "|" +
                 arr[i].revision_id + "|" + TimeToString(arr[i].revision_timestamp, TIME_DATE|TIME_SECONDS) + "|" +
                 arr[i].source_kind + "|" + IntegerToString(arr[i].source_priority) + "|" +
                 arr[i].forecast + "|" + arr[i].actual + "|" + arr[i].previous + ";";
   return Ids_Sha256Hex(payload);
}

//---------------------------------------------------------------------
// Final conversion - the pipeline's working struct becomes the frozen,
// embeddable NewsSnapshot contract.
//---------------------------------------------------------------------

void News_ToSnapshot(const NormalizedNewsEvent &e, NewsSnapshot &out)
{
   NewsSnapshot_Init(out);
   out.calendar_event_id = e.calendar_event_id;
   out.currency            = e.currency;
   out.impact               = e.impact_normalized;
   out.title                 = e.title_normalized;
   out.release_time          = e.release_time_utc;
   out.minutes_to_event       = e.minutes_to_event;
   out.source_kind             = e.source_kind;
   out.source_version           = e.source_version;
   out.normalized_event_key      = e.normalized_event_key;
   out.revision_id                = e.revision_id;
   out.revision_timestamp          = e.revision_timestamp;
   out.source_priority              = e.source_priority;
}

int News_ToSnapshotArray(const NormalizedNewsEvent &arr[], NewsSnapshot &outArr[])
{
   int n = ArraySize(arr);
   ArrayResize(outArr, n);
   for(int i = 0; i < n; i++)
      News_ToSnapshot(arr[i], outArr[i]);
   return n;
}

#endif // __MLQUANTAI_NEWSCANONICALIZER_MQH__
