//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_SessionEngine.mqh                   |
//| Session / kill-zone detection from broker server time alone - no |
//| external API, no data feed, just TimeCurrent(). Hours are inputs |
//| because every broker publishes a different server-time offset    |
//| from GMT, so "London kill zone" as a fixed UTC window would be   |
//| wrong for most brokers out of the box; these need calibrating    |
//| once per broker, same pattern QuantixApexEA/QuantixFlowEA used   |
//| for their session filters.                                       |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_SESSIONENGINE_MQH__
#define __MLQUANTAI_SESSIONENGINE_MQH__

input group "=== Session Engine (broker server time) ==="
input int AsiaStartHour     = 0;
input int AsiaEndHour       = 8;
input int LondonKZStartHour = 9;
input int LondonKZEndHour   = 12;
input int NewYorkKZStartHour = 14;
input int NewYorkKZEndHour   = 17;

// Handles windows that wrap past midnight (startHour > endHour) as well
// as normal same-day windows.
bool Session_InHourWindow(int startHour, int endHour, datetime t)
{
   MqlDateTime tm;
   TimeToStruct(t, tm);
   int h = tm.hour;
   if(startHour <= endHour)
      return (h >= startHour && h < endHour);
   return (h >= startHour || h < endHour);
}

bool Session_IsAsia(datetime t)      { return Session_InHourWindow(AsiaStartHour, AsiaEndHour, t); }
bool Session_IsLondonKZ(datetime t)  { return Session_InHourWindow(LondonKZStartHour, LondonKZEndHour, t); }
bool Session_IsNewYorkKZ(datetime t) { return Session_InHourWindow(NewYorkKZStartHour, NewYorkKZEndHour, t); }

// Start of the broker-server-time calendar day containing t (00:00:00).
// Used by DataHub's Asian-range scan - not calendar-exact for brokers
// whose "trading day" doesn't start at server midnight, but stable and
// good enough for a session-range feature rather than a legal boundary.
datetime Session_DayStart(datetime t)
{
   MqlDateTime tm;
   TimeToStruct(t, tm);
   tm.hour = 0; tm.min = 0; tm.sec = 0;
   return StructToTime(tm);
}

#endif // __MLQUANTAI_SESSIONENGINE_MQH__
