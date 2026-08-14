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
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_NEWSENGINE_MQH__
#define __MLQUANTAI_NEWSENGINE_MQH__

#include "../Logging/MLQuantAI_SystemLogger.mqh"
#include "MLQuantAI_NewsSnapshot.mqh"
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
// News_BuildSnapshots() (below) for that, which takes an explicit asOf
// instead of reading "now" and returns the full NewsSnapshot[] Phase B
// B3 embeds into MARKET_CONTEXT_READY for replay.
bool News_HighImpactNear(string currency, int minutesBefore, int minutesAfter)
{
   datetime now = TimeCurrent();
   if(MQLInfoInteger(MQL_TESTER))
      return News_HighImpactNear_Csv(currency, now, minutesBefore, minutesAfter);
   return News_HighImpactNear_Live(currency, now, minutesBefore, minutesAfter);
}

// Same integer impact scale on both sources (0=NONE/unknown, 1=LOW,
// 2=MEDIUM/MODERATE, 3=HIGH) so MarketContext.max_news_impact is
// meaningful regardless of which source built the snapshot.
int News_CsvImpactToInt(string impact)
{
   string u = impact;
   StringToUpper(u);
   if(u == "HIGH")   return 3;
   if(u == "MEDIUM") return 2;
   if(u == "LOW")    return 1;
   return 0;
}

// Builds the full replayable NewsSnapshot[] anchored at asOf - the Phase
// B B3 entry point MarketContext building should use, NOT
// News_HighImpactNear(). Deliberately takes asOf as a parameter instead
// of reading TimeCurrent(): the same asOf must always produce the same
// snapshots, on live, in the Tester, and across repeated calls in the
// determinism test - the whole reason NewsSnapshot exists is to embed
// this into MARKET_CONTEXT_READY so replay never needs to re-query
// the calendar (live or CSV) again.
int News_BuildSnapshots_Live(string currency, datetime asOf, int minutesBefore, int minutesAfter, NewsSnapshot &outArr[])
{
   ArrayResize(outArr, 0);
   datetime from = asOf - minutesBefore * 60;
   datetime to   = asOf + minutesAfter * 60;

   MqlCalendarValue values[];
   if(!CalendarValueHistory(values, from, to, NULL, currency))
      return 0;

   int count = 0;
   for(int i = 0; i < ArraySize(values); i++)
   {
      MqlCalendarEvent evt;
      if(!CalendarEventById(values[i].event_id, evt)) continue;

      ArrayResize(outArr, count + 1);
      NewsSnapshot_Init(outArr[count]);
      outArr[count].calendar_event_id = IntegerToString(values[i].event_id) + "_" + IntegerToString((long)values[i].time);
      outArr[count].currency           = currency;
      outArr[count].impact              = (int)evt.importance;
      outArr[count].title                = evt.name;
      outArr[count].release_time          = values[i].time;
      outArr[count].minutes_to_event       = (int)((values[i].time - asOf) / 60);
      outArr[count].source_kind             = "LIVE_CALENDAR";
      outArr[count].source_version           = MLQUANTAI_NEWS_SCHEMA_V1;
      count++;
   }
   return count;
}

// CSV fallback counterpart. KNOWN LIMITATION (Phase B B4 will address
// this - "News Engine parity" is explicitly a separate step): the CSV
// format (time,currency,impact) has no event id or title, so those are
// synthesized here rather than sourced from real calendar metadata -
// still enough for replay determinism (same CSV row -> same synthesized
// id/title every time), just not as descriptive as the live path.
int News_BuildSnapshots_Csv(string currency, datetime asOf, int minutesBefore, int minutesAfter, NewsSnapshot &outArr[])
{
   ArrayResize(outArr, 0);
   if(!g_NewsCsvLoaded) return 0;

   datetime from = asOf - minutesBefore * 60;
   datetime to   = asOf + minutesAfter * 60;

   int count = 0;
   for(int i = 0; i < ArraySize(g_NewsCsv); i++)
   {
      if(g_NewsCsv[i].time < from || g_NewsCsv[i].time > to) continue;
      if(currency != "" && g_NewsCsv[i].currency != currency) continue;

      ArrayResize(outArr, count + 1);
      NewsSnapshot_Init(outArr[count]);
      outArr[count].calendar_event_id = "CSV_" + TimeToString(g_NewsCsv[i].time, TIME_DATE|TIME_SECONDS) + "_" + g_NewsCsv[i].currency;
      outArr[count].currency           = g_NewsCsv[i].currency;
      outArr[count].impact              = News_CsvImpactToInt(g_NewsCsv[i].impact);
      outArr[count].title                = g_NewsCsv[i].currency + " " + g_NewsCsv[i].impact + " impact news (CSV, no title in source)";
      outArr[count].release_time          = g_NewsCsv[i].time;
      outArr[count].minutes_to_event       = (int)((g_NewsCsv[i].time - asOf) / 60);
      outArr[count].source_kind             = "CSV_STATIC";
      outArr[count].source_version           = MLQUANTAI_NEWS_SCHEMA_V1;
      count++;
   }
   return count;
}

// The one function MarketContext building should call. Routes to the CSV
// fallback inside Strategy Tester, the live Economic Calendar otherwise -
// same live/Tester routing convention as News_HighImpactNear(), but
// anchored on asOf and returning full snapshots instead of a bool.
int News_BuildSnapshots(string currency, datetime asOf, int minutesBefore, int minutesAfter, NewsSnapshot &outArr[])
{
   if(MQLInfoInteger(MQL_TESTER))
      return News_BuildSnapshots_Csv(currency, asOf, minutesBefore, minutesAfter, outArr);
   return News_BuildSnapshots_Live(currency, asOf, minutesBefore, minutesAfter, outArr);
}

#endif // __MLQUANTAI_NEWSENGINE_MQH__
