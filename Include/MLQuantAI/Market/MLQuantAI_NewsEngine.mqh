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

// The one function every other module should call. Routes to the CSV
// fallback inside Strategy Tester, the live Economic Calendar otherwise.
bool News_HighImpactNear(string currency, int minutesBefore, int minutesAfter)
{
   datetime now = TimeCurrent();
   if(MQLInfoInteger(MQL_TESTER))
      return News_HighImpactNear_Csv(currency, now, minutesBefore, minutesAfter);
   return News_HighImpactNear_Live(currency, now, minutesBefore, minutesAfter);
}

#endif // __MLQUANTAI_NEWSENGINE_MQH__
