//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_NewsSnapshot.mqh                    |
//| Phase B B1.3: one calendar event captured at MarketContext build |
//| time. MarketContext embeds an array of these (NewsSnapshot       |
//| news[]) instead of a single boolean, and MARKET_CONTEXT_READY    |
//| will serialize the full array - so replay can see exactly which  |
//| news rows were near the anchor bar without re-querying the       |
//| calendar (which would answer differently on tester vs. live, or  |
//| on a re-run after the calendar's own data has moved on).         |
//| source_kind distinguishes a row read from MT5's live Economic    |
//| Calendar from one read out of the Tester's static CSV fallback - |
//| both populate the SAME struct shape, per News_HighImpactNear()'s |
//| "one interface either way" convention (MLQuantAI_NewsEngine.mqh).|
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_NEWSSNAPSHOT_MQH__
#define __MLQUANTAI_NEWSSNAPSHOT_MQH__

#include "../Core/MLQuantAI_ContractVersions.mqh"

struct NewsSnapshot
{
   string   calendar_event_id;
   string   currency;
   int      impact;             // maps to MqlCalendarEvent.importance (CALENDAR_IMPORTANCE_*)
   string   title;

   datetime release_time;
   int      minutes_to_event;   // relative to anchor_bar_time, can be negative (already released)

   string   source_kind;        // "LIVE_CALENDAR" | "CSV_STATIC"
   string   source_version;     // e.g. news_schema_version at capture time, or CSV file name/tag
};

void NewsSnapshot_Init(NewsSnapshot &n)
{
   n.calendar_event_id = "";
   n.currency = "";
   n.impact = 0;
   n.title = "";
   n.release_time = 0;
   n.minutes_to_event = 0;
   n.source_kind = "";
   n.source_version = "";
}

// Minimal JSON escaping - just enough for the quotes/backslashes a news
// title could plausibly contain. Deliberately self-contained (no
// dependency on Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh)
// since B1 is contract-only and must not reach into Phase A's Event
// Store internals.
string NewsSnapshot_JsonEscape(string s)
{
   string out = "";
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
   {
      ushort ch = StringGetCharacter(s, i);
      if(ch == '"' || ch == '\\')
         out += "\\";
      out += StringFormat("%c", ch);
   }
   return out;
}

// Serializes ONE NewsSnapshot to a JSON object string. This is the
// per-element building block for embedding a replayable NewsSnapshot[]
// inside MarketContext's eventual MARKET_CONTEXT_READY payload (B2/B3
// wires that up; B1 only proves the round-trip works).
string NewsSnapshot_ToJson(const NewsSnapshot &n)
{
   return StringFormat(
      "{\"calendar_event_id\":\"%s\",\"currency\":\"%s\",\"impact\":%d,\"title\":\"%s\","
      "\"release_time\":\"%s\",\"minutes_to_event\":%d,\"source_kind\":\"%s\",\"source_version\":\"%s\"}",
      NewsSnapshot_JsonEscape(n.calendar_event_id), NewsSnapshot_JsonEscape(n.currency),
      n.impact, NewsSnapshot_JsonEscape(n.title),
      TimeToString(n.release_time, TIME_DATE|TIME_SECONDS), n.minutes_to_event,
      NewsSnapshot_JsonEscape(n.source_kind), NewsSnapshot_JsonEscape(n.source_version));
}

// Reads back a single string field "key":"value" from a JSON object
// string, honoring escaped quotes/backslashes char-by-char rather than
// naively splitting on the next unescaped-looking quote.
string NewsSnapshot_JsonGetStr(string json, string key)
{
   string needle = "\"" + key + "\":\"";
   int start = StringFind(json, needle);
   if(start < 0) return "";
   start += StringLen(needle);

   string result = "";
   int n = StringLen(json);
   for(int i = start; i < n; i++)
   {
      ushort ch = StringGetCharacter(json, i);
      if(ch == '\\' && i + 1 < n)
      {
         i++;
         result += StringFormat("%c", StringGetCharacter(json, i));
         continue;
      }
      if(ch == '"') break;
      result += StringFormat("%c", ch);
   }
   return result;
}

long NewsSnapshot_JsonGetInt(string json, string key)
{
   string needle = "\"" + key + "\":";
   int start = StringFind(json, needle);
   if(start < 0) return 0;
   start += StringLen(needle);
   int end = start;
   int n = StringLen(json);
   while(end < n)
   {
      ushort ch = StringGetCharacter(json, end);
      if(ch == ',' || ch == '}') break;
      end++;
   }
   return StringToInteger(StringSubstr(json, start, end - start));
}

// Reverse of NewsSnapshot_ToJson. Returns false if the JSON is missing
// even the identity field (calendar_event_id) - a malformed/truncated
// row should never be mistaken for a real "empty but valid" snapshot.
bool NewsSnapshot_FromJson(string json, NewsSnapshot &out)
{
   NewsSnapshot_Init(out);
   if(StringFind(json, "\"calendar_event_id\":") < 0)
      return false;

   out.calendar_event_id = NewsSnapshot_JsonGetStr(json, "calendar_event_id");
   out.currency           = NewsSnapshot_JsonGetStr(json, "currency");
   out.impact              = (int)NewsSnapshot_JsonGetInt(json, "impact");
   out.title                = NewsSnapshot_JsonGetStr(json, "title");
   out.release_time         = StringToTime(NewsSnapshot_JsonGetStr(json, "release_time"));
   out.minutes_to_event      = (int)NewsSnapshot_JsonGetInt(json, "minutes_to_event");
   out.source_kind           = NewsSnapshot_JsonGetStr(json, "source_kind");
   out.source_version        = NewsSnapshot_JsonGetStr(json, "source_version");
   return true;
}

// Serializes an array of NewsSnapshot to a JSON array string - what
// MarketContext.news[] will embed into MARKET_CONTEXT_READY once B2/B3
// wire the Data Hub to this contract.
string NewsSnapshot_ArrayToJson(const NewsSnapshot &arr[])
{
   string s = "[";
   for(int i = 0; i < ArraySize(arr); i++)
   {
      if(i > 0) s += ",";
      s += NewsSnapshot_ToJson(arr[i]);
   }
   s += "]";
   return s;
}

// Reverse of NewsSnapshot_ArrayToJson. Finds element boundaries by
// tracking brace depth across the whole array string.
//
// KNOWN LIMITATION (acceptable for B1's contract-only scope, must be
// hardened before B2/B3 wires this into the real MARKET_CONTEXT_READY
// payload): depth tracking counts EVERY '{'/'}' character, including any
// that happen to appear inside a string field's VALUE (e.g. a news
// title containing a literal brace) - NewsSnapshot_JsonEscape only
// escapes quotes/backslashes, not braces. A title like "Fed says {rates
// unchanged}" would desync the element boundaries. B2/B3 should route
// through Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh's more
// hardened parsing (or extend it) instead of this standalone helper once
// this is wired into real replay.
int NewsSnapshot_ArrayFromJson(string json, NewsSnapshot &outArr[])
{
   ArrayResize(outArr, 0);
   string trimmed = json;
   StringTrimLeft(trimmed);
   StringTrimRight(trimmed);
   if(StringLen(trimmed) < 2) return 0;
   string inner = StringSubstr(trimmed, 1, StringLen(trimmed) - 2); // strip [ ]
   if(StringLen(inner) == 0) return 0;

   // MQL5's StringSplit only takes a single-char separator, and the
   // boundary between array elements ("},{") is multi-char, so scan for
   // matching-brace boundaries manually instead.
   int count = 0;
   int depth = 0;
   int elemStart = 0;
   int n = StringLen(inner);
   for(int i = 0; i < n; i++)
   {
      ushort ch = StringGetCharacter(inner, i);
      if(ch == '{') depth++;
      else if(ch == '}')
      {
         depth--;
         if(depth == 0)
         {
            string elem = StringSubstr(inner, elemStart, i - elemStart + 1);
            NewsSnapshot ns;
            if(NewsSnapshot_FromJson(elem, ns))
            {
               ArrayResize(outArr, count + 1);
               outArr[count] = ns;
               count++;
            }
            // skip the separating comma, if any
            int j = i + 1;
            while(j < n && (StringGetCharacter(inner, j) == ',' )) j++;
            elemStart = j;
            i = j - 1;
         }
      }
   }
   return count;
}

#endif // __MLQUANTAI_NEWSSNAPSHOT_MQH__
