//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_LiveCalendarNewsSource.mqh          |
//| Phase B B4: reads MT5's built-in Economic Calendar and shapes it  |
//| into RawNewsEvent[] - NO normalization logic here (that's         |
//| Market/MLQuantAI_NewsCanonicalizer.mqh's job, the ONE place both  |
//| this and CsvStaticNewsSource funnel through). A live query        |
//| failure returns an explicit false + reason - never a silent       |
//| "no news" fallback, since that would be indistinguishable from a  |
//| genuinely quiet calendar.                                         |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_LIVECALENDARNEWSSOURCE_MQH__
#define __MLQUANTAI_LIVECALENDARNEWSSOURCE_MQH__

#include "MLQuantAI_NewsSource.mqh"
#include "../Core/MLQuantAI_Ids.mqh"
#include "../Core/MLQuantAI_ContractVersions.mqh"

// See MLQuantAI_CsvStaticNewsSource.mqh's MLQUANTAI_CSV_NEWS_SOURCE_
// DEFAULT_PRIORITY comment - live outranks CSV by default in the (rare,
// mostly test-only) case both are compared by News_Deduplicate.
#define MLQUANTAI_LIVE_NEWS_SOURCE_DEFAULT_PRIORITY 20

class LiveCalendarNewsSource : public INewsSource
{
private:
   int    m_priority;
   string m_sourceVersion;

public:
   LiveCalendarNewsSource(int priority = MLQUANTAI_LIVE_NEWS_SOURCE_DEFAULT_PRIORITY)
   {
      m_priority = priority;
      m_sourceVersion = MLQUANTAI_NEWS_SCHEMA_V1;
   }

   virtual bool ReadRawEvents(string currency, datetime anchorTime, int lookbackMinutes, int lookaheadMinutes,
                               RawNewsEvent &outArr[], string &outError) override
   {
      ArrayResize(outArr, 0);
      outError = "";

      datetime from = anchorTime - lookbackMinutes * 60;
      datetime to   = anchorTime + lookaheadMinutes * 60;

      MqlCalendarValue values[];
      if(!CalendarValueHistory(values, from, to, NULL, currency))
      {
         outError = StringFormat("LiveCalendarNewsSource: CalendarValueHistory failed, err=%d", GetLastError());
         return false;
      }

      int count = 0;
      for(int i = 0; i < ArraySize(values); i++)
      {
         MqlCalendarEvent evt;
         if(!CalendarEventById(values[i].event_id, evt))
            continue; // one event lookup miss isn't a hard source failure - the query itself succeeded

         string eventCurrency = currency;
         if(eventCurrency == "")
         {
            MqlCalendarCountry country;
            if(CalendarCountryById(evt.country_id, country))
               eventCurrency = country.currency;
         }

         RawNewsEvent raw;
         RawNewsEvent_Init(raw);
         raw.provider_event_id = IntegerToString(values[i].event_id) + "_" + IntegerToString((long)values[i].time);
         raw.currency            = eventCurrency;
         raw.impact_raw           = IntegerToString((int)evt.importance); // News_NormalizeImpact accepts this numeric-string form
         raw.title                 = evt.name;
         raw.release_time          = values[i].time;
         raw.revision_id            = IntegerToString(values[i].revision);
         raw.revision_timestamp      = values[i].time;
         raw.source_kind              = SourceKind();
         raw.source_version            = m_sourceVersion;
         raw.source_priority            = m_priority;
         raw.source_content_hash         = Ids_Sha256Hex(raw.provider_event_id + "|" + raw.currency + "|" + raw.impact_raw + "|" +
                                                           raw.title + "|" + TimeToString(raw.release_time, TIME_DATE|TIME_SECONDS));

         ArrayResize(outArr, count + 1);
         outArr[count] = raw;
         count++;
      }

      return true;
   }

   virtual string SourceKind() override { return "LIVE_CALENDAR"; }
};

#endif // __MLQUANTAI_LIVECALENDARNEWSSOURCE_MQH__
