//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_NewsSource.mqh                      |
//| Phase B B4: the RAW event shape every news source produces, and   |
//| the interface both LiveCalendarNewsSource and CsvStaticNewsSource |
//| implement. Nothing downstream of a source ever normalizes data    |
//| itself - RawNewsEvent is handed to                                |
//| Market/MLQuantAI_NewsCanonicalizer.mqh's                          |
//| News_NormalizedEvent_From_Raw(), the ONE place normalization      |
//| logic lives, so Live and CSV can never drift into two different   |
//| interpretations of "the same" event.                              |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_NEWSSOURCE_MQH__
#define __MLQUANTAI_NEWSSOURCE_MQH__

// Exactly what a source read, before any normalization. Field values are
// whatever the source itself reports - impact_raw is a free-form string
// (e.g. "HIGH", "High", "3"), release_time is in the source's own native
// clock (broker server time for both MT5's calendar and this project's
// CSV convention - see MLQuantAI_NewsCanonicalizer.mqh's
// News_NormalizeTimeUtc for why "UTC" here means "this project's single
// canonical clock", not literal UTC).
struct RawNewsEvent
{
   string   provider_event_id;
   string   currency;
   string   impact_raw;
   string   title;
   datetime release_time;
   string   source_kind;          // "LIVE_CALENDAR" | "CSV_STATIC"
   string   source_version;
   string   source_content_hash;  // hash of the raw row/payload as read - audit trail only, never used for decisions
   int      source_priority;      // News_Deduplicate's tie-break input when two sources report the same normalized_event_key
   string   revision_id;          // "" if the source doesn't track revisions
   datetime revision_timestamp;   // 0 if unknown

   // Phase B B4 seal hardening: additive, optional consensus/actual data -
   // "" when a source doesn't provide it (both current concrete sources
   // leave these at ""; the frozen 7-column CSV format is UNCHANGED, these
   // are NOT CSV columns). Proves the pipeline tolerates a schema growing
   // new fields before B5 ever depends on a specific NormalizedNewsEvent
   // shape - see MLQuantAI_NewsCanonicalizer.mqh's News_SnapshotIdentity
   // and Tests/MLQuantAI_Test_NewsSchemaEvolution.mq5.
   string   forecast;
   string   actual;
   string   previous;
};

void RawNewsEvent_Init(RawNewsEvent &e)
{
   e.provider_event_id = "";
   e.currency = "";
   e.impact_raw = "";
   e.title = "";
   e.release_time = 0;
   e.source_kind = "";
   e.source_version = "";
   e.source_content_hash = "";
   e.source_priority = 0;
   e.revision_id = "";
   e.revision_timestamp = 0;
   e.forecast = "";
   e.actual = "";
   e.previous = "";
}

// One news source. Both concrete sources (LiveCalendarNewsSource,
// CsvStaticNewsSource) implement ONLY reading + shaping raw data - no
// normalization, no dedup, no sorting. FAILS CLOSED: ReadRawEvents
// returns false on any hard failure (missing file, live query failure,
// malformed row) with a reason in outError - callers must never treat a
// false return as "confirmed no news", and must never silently fall back
// to "no news" behavior.
class INewsSource
{
public:
   virtual bool   ReadRawEvents(string currency, datetime anchorTime, int lookbackMinutes, int lookaheadMinutes,
                                 RawNewsEvent &outArr[], string &outError) = 0;
   virtual string SourceKind() = 0;
};

#endif // __MLQUANTAI_NEWSSOURCE_MQH__
