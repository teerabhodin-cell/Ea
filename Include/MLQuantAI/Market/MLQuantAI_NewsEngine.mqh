//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_NewsEngine.mqh                      |
//| High-impact news proximity check. Live trading can use MT5's      |
//| built-in Economic Calendar (CalendarValueHistory); Strategy       |
//| Tester cannot reliably rely on it for arbitrary historical        |
//| periods (calendar coverage isn't guaranteed for every backtest    |
//| date range), so the Tester path reads a CSV fallback instead.     |
//| News_HighImpactNear() is the ONE function callers use either way -|
//| "Live และ Tester ใช้ interface เดียวกัน" is satisfied by that      |
//| single call signature, even though the data source underneath    |
//| differs by necessity.                                             |
//|                                                                    |
//| CSV format (no header row), FILE_CSV/comma-delimited:             |
//|   time,currency,impact                                            |
//|   2026.08.14 12:30:00,USD,HIGH                                    |
//| impact is one of HIGH/MEDIUM/LOW (only HIGH blocks).               |
//|                                                                    |
//| Phase B B4 added NewsEngine_Build() below - the orchestrator       |
//| FeatureEngine_BuildContext() calls to populate MarketContext.news[]|
//| / news_decision_hash / news_snapshot_identity via the new Raw ->   |
//| Normalize -> Dedup -> Sort/Select pipeline (Market/MLQuantAI_      |
//| NewsCanonicalizer.mqh). Everything above this point (News_LoadCsv/ |
//| News_HighImpactNear* and the 3-column CSV format) is UNCHANGED and |
//| stays a separate, still-live "gate check right now" utility - not  |
//| what builds a replayable snapshot anymore.                         |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_NEWSENGINE_MQH__
#define __MLQUANTAI_NEWSENGINE_MQH__

#include "../Logging/MLQuantAI_SystemLogger.mqh"
#include "MLQuantAI_NewsSnapshot.mqh"
#include "MLQuantAI_NewsSource.mqh"
#include "MLQuantAI_NewsCanonicalizer.mqh"
#include "MLQuantAI_CsvStaticNewsSource.mqh"
#include "MLQuantAI_LiveCalendarNewsSource.mqh"
#include "../Core/MLQuantAI_ContractVersions.mqh"

input group "=== News Engine ==="
input bool   UseNewsFilter     = true;
input string NewsCurrency      = "USD";
input int    NewsMinutesBefore = 30;
input int    NewsMinutesAfter  = 30;
input string NewsCsvFileName   = "MLQuantAI_News.csv"; // Tester-only fallback, Common\Files

struct NewsCsvEntry
{
   datetime time;
   string   currency;
   string   impact;
};

NewsCsvEntry g_NewsCsv[];
bool         g_NewsCsvLoaded = false;

// Loads the CSV fallback once (call from OnInit). Returns false if the
// file couldn't be opened - callers should NOT treat that as "confirmed
// no news risk", it means the filter has no data to check against at all.
bool News_LoadCsv(string fileName)
{
   ArrayResize(g_NewsCsv, 0);
   g_NewsCsvLoaded = false;

   int handle = FileOpen(fileName, FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(handle == INVALID_HANDLE)
   {
      LogWarn(StringFormat("NewsEngine: could not open news CSV '%s', err=%d - "
                            "news filter will report 'no news near' unconditionally until this is fixed.",
                            fileName, GetLastError()));
      return false;
   }

   int count = 0;
   while(!FileIsEnding(handle))
   {
      string timeStr = FileReadString(handle);
      if(timeStr == "") break;
      string currency = FileReadString(handle);
      string impact    = FileReadString(handle);

      datetime t = StringToTime(timeStr);
      if(t <= 0) continue; // malformed row - skip rather than abort the whole load

      ArrayResize(g_NewsCsv, count + 1);
      g_NewsCsv[count].time     = t;
      g_NewsCsv[count].currency = currency;
      g_NewsCsv[count].impact   = impact;
      count++;
   }
   FileClose(handle);

   g_NewsCsvLoaded = true;
   LogInfo(StringFormat("NewsEngine: loaded %d news rows from CSV fallback '%s'", count, fileName));
   return true;
}

// Advisory check, not a hard gate: compares the CSV's own min/max
// timestamps against [rangeStart, rangeEnd] and warns (does not block)
// if the CSV doesn't fully cover the requested range - "News CSV
// coverage ถูก validate ก่อน backtest".
bool News_ValidateCsvCoverage(datetime rangeStart, datetime rangeEnd)
{
   if(!g_NewsCsvLoaded || ArraySize(g_NewsCsv) == 0)
   {
      LogWarn("NewsEngine: no CSV rows loaded - coverage cannot be validated, "
              "the news filter has effectively no data for this run.");
      return false;
   }

   datetime minT = g_NewsCsv[0].time, maxT = g_NewsCsv[0].time;
   for(int i = 1; i < ArraySize(g_NewsCsv); i++)
   {
      if(g_NewsCsv[i].time < minT) minT = g_NewsCsv[i].time;
      if(g_NewsCsv[i].time > maxT) maxT = g_NewsCsv[i].time;
   }

   bool covers = (minT <= rangeStart && maxT >= rangeEnd);
   if(!covers)
      LogWarn(StringFormat("NewsEngine: CSV coverage %s .. %s does NOT fully cover the requested range %s .. %s",
              TimeToString(minT), TimeToString(maxT), TimeToString(rangeStart), TimeToString(rangeEnd)));
   else
      LogInfo(StringFormat("NewsEngine: CSV coverage %s .. %s covers the requested range", TimeToString(minT), TimeToString(maxT)));
   return covers;
}

bool News_HighImpactNear_Live(string currency, datetime now, int minutesBefore, int minutesAfter)
{
   datetime from = now - minutesBefore * 60;
   datetime to   = now + minutesAfter * 60;

   MqlCalendarValue values[];
   if(!CalendarValueHistory(values, from, to, NULL, currency))
      return false;

   for(int i = 0; i < ArraySize(values); i++)
   {
      MqlCalendarEvent evt;
      if(!CalendarEventById(values[i].event_id, evt)) continue;
      if(evt.importance == CALENDAR_IMPORTANCE_HIGH)
         return true;
   }
   return false;
}

bool News_HighImpactNear_Csv(string currency, datetime now, int minutesBefore, int minutesAfter)
{
   if(!g_NewsCsvLoaded) return false;

   datetime from = now - minutesBefore * 60;
   datetime to   = now + minutesAfter * 60;

   for(int i = 0; i < ArraySize(g_NewsCsv); i++)
   {
      if(g_NewsCsv[i].time < from || g_NewsCsv[i].time > to) continue;
      if(currency != "" && g_NewsCsv[i].currency != currency) continue;
      if(g_NewsCsv[i].impact == "HIGH") return true;
   }
   return false;
}

// The one function every other module should call for a live "is there
// news risk RIGHT NOW" gate (e.g. a future Risk Manager blocking a
// submission in real time). Routes to the CSV fallback inside Strategy
// Tester, the live Economic Calendar otherwise. Reads TimeCurrent()
// internally BY DESIGN - this is a live gate check, not a replayable
// snapshot. Do NOT use this to populate MarketContext.news[] - use
// NewsEngine_Build() (below) for that, which takes an explicit anchor
// time instead of reading "now" and returns the full NewsSnapshot[]
// (via the Canonicalizer pipeline) that MARKET_CONTEXT_READY embeds
// for replay.
bool News_HighImpactNear(string currency, int minutesBefore, int minutesAfter)
{
   datetime now = TimeCurrent();
   if(MQLInfoInteger(MQL_TESTER))
      return News_HighImpactNear_Csv(currency, now, minutesBefore, minutesAfter);
   return News_HighImpactNear_Live(currency, now, minutesBefore, minutesAfter);
}

//---------------------------------------------------------------------
// Phase B B4: NewsEngine_Build() - the orchestrator. Supersedes B3.5's
// News_BuildSnapshots()/_Live/_Csv (removed - nothing else referenced
// them by name, and they built a NewsSnapshot directly instead of
// routing through the Canonicalizer, which is exactly the "no
// normalization logic duplicated outside the Canonicalizer" rule B4
// exists to enforce).
//---------------------------------------------------------------------

input group "=== News Engine V2 (Phase B B4) ==="
input string NewsSourceCsvFileName = "MLQuantAI_NewsSourceV1.csv"; // CsvStaticNewsSource file (Tester only), Common\Files, see MLQuantAI_CsvStaticNewsSource.mqh for the frozen format

CsvStaticNewsSource *g_NewsEngine_CsvSource = NULL;

// Phase B B4 seal hardening: NewsEngine_Build() is the ONLY function in
// the whole project that ever touches an INewsSource (see its own
// comment below) - this counter turns that architectural claim into a
// mechanically checked one. Tests/MLQuantAI_Test_NewsReplayIsolation.mq5
// snapshots this before/after a build+persist+replay sequence and
// asserts it never moved during the replay portion, instead of just
// asserting "true, by construction".
int g_NewsEngine_BuildCallCount = 0;

struct NewsEngineResult
{
   bool         ok;
   string       error;
   NewsSnapshot snapshots[];
   int          news_count;
   int          max_news_impact;
   int          nearest_news_minutes;
   string       news_decision_hash;
   string       news_snapshot_identity;
};

void NewsEngineResult_Init(NewsEngineResult &r)
{
   r.ok = false;
   r.error = "";
   ArrayResize(r.snapshots, 0);
   r.news_count = 0;
   r.max_news_impact = 0;
   r.nearest_news_minutes = 0;
   r.news_decision_hash = "";
   r.news_snapshot_identity = "";
}

// Call once from OnInit when running in the Tester (never in live/demo -
// live trading uses LiveCalendarNewsSource, created fresh per call
// instead, since it holds no state worth persisting). Loads the CSV
// source and hard-validates its coverage against [rangeStart, rangeEnd]
// (typically the full backtest range) - returns false on ANY load or
// coverage problem; callers (MLQuantAI.mq5's OnInit) MUST treat that as
// INIT_FAILED, not a warning.
bool NewsEngine_InitCsvSource(datetime rangeStart, datetime rangeEnd, string &outError)
{
   if(g_NewsEngine_CsvSource != NULL)
   {
      delete g_NewsEngine_CsvSource;
      g_NewsEngine_CsvSource = NULL;
   }

   CsvStaticNewsSource *src = new CsvStaticNewsSource(NewsSourceCsvFileName);
   if(!src.Load(outError))
   {
      delete src;
      return false;
   }
   if(!src.ValidateCoverage(rangeStart, rangeEnd, outError))
   {
      delete src;
      return false;
   }

   g_NewsEngine_CsvSource = src;
   return true;
}

void NewsEngine_DeinitCsvSource()
{
   if(g_NewsEngine_CsvSource != NULL)
   {
      delete g_NewsEngine_CsvSource;
      g_NewsEngine_CsvSource = NULL;
   }
}

// The ONE function FeatureEngine_BuildContext() calls to populate
// MarketContext's news fields. Selects the source by the same live/
// Tester routing convention every other module in this project uses,
// reads raw events for the FROZEN window (MLQUANTAI_NEWS_LOOKBACK_
// MINUTES/MLQUANTAI_NEWS_LOOKAHEAD_MINUTES, both 1440 - see
// MLQuantAI_NewsCanonicalizer.mqh), then runs the full pipeline:
// normalize -> dedup -> sort/select -> hash -> convert to NewsSnapshot[].
//
// REPLAY NEVER CALLS THIS - a replayed context reads NewsSnapshot[]
// straight back out of the already-logged MARKET_CONTEXT_READY event,
// it does not re-run source reads or the pipeline. See
// Docs/PhaseB_B4_NewsParity.md.
NewsEngineResult NewsEngine_Build(datetime anchorTime)
{
   g_NewsEngine_BuildCallCount++;

   NewsEngineResult result;
   NewsEngineResult_Init(result);

   string sourceKindForLog;
   RawNewsEvent rawArr[];
   string err = "";
   bool readOk;

   if(MQLInfoInteger(MQL_TESTER))
   {
      sourceKindForLog = "CSV_STATIC";
      if(g_NewsEngine_CsvSource == NULL)
      {
         result.error = "NewsEngine_Build: CSV source not initialized - call NewsEngine_InitCsvSource() from OnInit first";
         LogError(result.error);
         return result;
      }
      readOk = g_NewsEngine_CsvSource.ReadRawEvents(NewsCurrency, anchorTime,
                                                     MLQUANTAI_NEWS_LOOKBACK_MINUTES, MLQUANTAI_NEWS_LOOKAHEAD_MINUTES,
                                                     rawArr, err);
   }
   else
   {
      sourceKindForLog = "LIVE_CALENDAR";
      LiveCalendarNewsSource live;
      readOk = live.ReadRawEvents(NewsCurrency, anchorTime,
                                   MLQUANTAI_NEWS_LOOKBACK_MINUTES, MLQUANTAI_NEWS_LOOKAHEAD_MINUTES,
                                   rawArr, err);
   }

   if(!readOk)
   {
      result.error = "NewsEngine_Build: " + err;
      LogError(result.error);
      return result;
   }

   NormalizedNewsEvent normalized[];
   News_NormalizeAll(rawArr, anchorTime, normalized);

   NormalizedNewsEvent deduped[];
   if(!News_Deduplicate(normalized, deduped, err))
   {
      result.error = "NewsEngine_Build: " + err;
      LogError(result.error);
      return result;
   }

   News_SortAndSelect(deduped, MLQUANTAI_NEWS_MAX_EVENTS);

   result.news_decision_hash    = News_DecisionHash(deduped);
   result.news_snapshot_identity = News_SnapshotIdentity(deduped);
   result.news_count              = News_ToSnapshotArray(deduped, result.snapshots);

   int maxImpact = 0, nearestAbsMinutes = -1, nearestSignedMinutes = 0;
   for(int i = 0; i < result.news_count; i++)
   {
      if(result.snapshots[i].impact > maxImpact)
         maxImpact = result.snapshots[i].impact;
      int absMinutes = (int)MathAbs(result.snapshots[i].minutes_to_event);
      if(nearestAbsMinutes < 0 || absMinutes < nearestAbsMinutes)
      {
         nearestAbsMinutes = absMinutes;
         nearestSignedMinutes = result.snapshots[i].minutes_to_event;
      }
   }
   result.max_news_impact      = maxImpact;
   result.nearest_news_minutes = (nearestAbsMinutes < 0) ? 0 : nearestSignedMinutes;
   result.ok = true;

   LogInfo(StringFormat("NewsEngine: source=%s anchor=%s window=[-%dm,+%dm] raw_events=%d canonical_events=%d "
                         "selected_events=%d news_decision_hash=%s news_snapshot_identity=%s status=OK",
           sourceKindForLog, TimeToString(anchorTime, TIME_DATE|TIME_SECONDS),
           MLQUANTAI_NEWS_LOOKBACK_MINUTES, MLQUANTAI_NEWS_LOOKAHEAD_MINUTES,
           ArraySize(rawArr), ArraySize(deduped), result.news_count,
           result.news_decision_hash, result.news_snapshot_identity));

   return result;
}

#endif // __MLQUANTAI_NEWSENGINE_MQH__
