//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh|
//| Turns event structs into one JSON line each, and back. This is a  |
//| closed-format parser, not a general JSON library: it only needs   |
//| to correctly round-trip lines THIS file itself writes, which is   |
//| a much easier problem than parsing arbitrary JSON and is the      |
//| pragmatic choice given MQL5 has no JSON library in the standard    |
//| library. Every free-text field (SystemEvent.message) is escaped   |
//| before being written; extra_json fields are trusted to already be |
//| valid JSON fragments supplied by the caller.                       |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EVENTSERIALIZER_MQH__
#define __MLQUANTAI_EVENTSERIALIZER_MQH__

#include "MLQuantAI_BaseEvent.mqh"
#include "MLQuantAI_LifecycleEvent.mqh"
#include "MLQuantAI_ExecutionEvent.mqh"
#include "MLQuantAI_SystemEvent.mqh"
#include "../../Core/MLQuantAI_VersionRegistry.mqh"

//---------------------------------------------------------------------
// Escaping / parsing primitives
//---------------------------------------------------------------------

string EventSerializer_Escape(string s)
{
   string out = "";
   int len = StringLen(s);
   for(int i = 0; i < len; i++)
   {
      ushort ch = StringGetCharacter(s, i);
      if(ch == '"' || ch == '\\')
      {
         out += "\\";
         out += CharToString((uchar)ch);
      }
      else if(ch == '\n') out += "\\n";
      else if(ch == '\r') out += "\\r";
      else out += CharToString((uchar)ch);
   }
   return out;
}

// "key":"value"  ->  value (quoted string values only). Walks char by
// char and decodes \", \\, \n, \r rather than jumping to the first
// unescaped-or-not '"' - a naive StringFind() for the closing quote would
// stop early on an escaped quote inside the value (e.g. a message like
// `broker said \"invalid stops\"`) and silently truncate it. Must mirror
// EventSerializer_Escape() exactly, in reverse.
string EventSerializer_GetStr(string json, string key)
{
   string needle = "\"" + key + "\":\"";
   int p = StringFind(json, needle);
   if(p < 0) return "";
   int i = p + StringLen(needle);
   int len = StringLen(json);
   string out = "";
   while(i < len)
   {
      ushort ch = StringGetCharacter(json, i);
      if(ch == '\\' && i + 1 < len)
      {
         ushort next = StringGetCharacter(json, i + 1);
         if(next == 'n')      out += "\n";
         else if(next == 'r') out += "\r";
         else if(next == '"') out += "\"";
         else if(next == '\\') out += "\\";
         else out += CharToString((uchar)next); // unknown escape - pass the literal char through
         i += 2;
         continue;
      }
      if(ch == '"') break; // real, unescaped closing quote
      out += CharToString((uchar)ch);
      i++;
   }
   return out;
}

// "key":123  or  "key":123.45  (unquoted numeric values)
string EventSerializer_GetRawNumber(string json, string key)
{
   string needle = "\"" + key + "\":";
   int p = StringFind(json, needle);
   if(p < 0) return "";
   int start = p + StringLen(needle);
   int len = StringLen(json);
   int end = start;
   while(end < len)
   {
      ushort ch = StringGetCharacter(json, end);
      if(ch == ',' || ch == '}') break;
      end++;
   }
   return StringSubstr(json, start, end - start);
}

long   EventSerializer_GetLong(string json, string key)   { string r = EventSerializer_GetRawNumber(json, key); return (r=="") ? 0 : StringToInteger(r); }
int    EventSerializer_GetInt(string json, string key)    { return (int)EventSerializer_GetLong(json, key); }
double EventSerializer_GetDouble(string json, string key) { string r = EventSerializer_GetRawNumber(json, key); return (r=="") ? 0.0 : StringToDouble(r); }
bool   EventSerializer_HasKey(string json, string key)
{
   return StringFind(json, "\"" + key + "\":") >= 0;
}

//---------------------------------------------------------------------
// LifecycleEvent <-> JSON
//---------------------------------------------------------------------

string EventSerializer_ToJson(const LifecycleEvent &e)
{
   string s = "{";
   s += "\"schema_version\":\""     + MLQUANTAI_SCHEMA_VERSION + "\",";
   s += "\"log_event_id\":\""       + EventSerializer_Escape(e.base.log_event_id) + "\",";
   s += "\"session_id\":\""         + EventSerializer_Escape(e.base.runtime_session_id) + "\",";
   s += "\"seq\":"                  + IntegerToString(e.base.sequence_number) + ",";
   s += "\"ts\":\""                 + TimeToString(e.base.ts, TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"category\":\""           + EventCategoryToString(e.base.category) + "\",";
   s += "\"type\":\""               + EventSerializer_Escape(e.base.event_type) + "\",";
   s += "\"candidate_id\":\""       + EventSerializer_Escape(e.candidate_id) + "\",";
   s += "\"root_event_id\":\""      + EventSerializer_Escape(e.root_event_id) + "\",";
   s += "\"correlation_id\":\""     + EventSerializer_Escape(e.correlation_id) + "\",";
   s += "\"strategy_id\":"          + IntegerToString(e.strategy_id) + ",";
   s += "\"strategy\":\""           + StrategyIdToString(e.strategy_id) + "\",";
   s += "\"from_state\":\""         + CandidateStateToString(e.from_state) + "\",";
   s += "\"to_state\":\""           + CandidateStateToString(e.to_state) + "\",";
   s += "\"reason\":\""             + ReasonCodeToString(e.reason) + "\"";
   if(e.extra_json != "")
      s += "," + e.extra_json;
   s += "}";
   return s;
}

// Parses only the fields the Validator/StateProjector actually need.
// Returns false if the line is too malformed to be a lifecycle event at
// all (missing seq or candidate_id) - callers treat that as corruption.
bool EventSerializer_ParseLifecycle(string line, LifecycleEvent &out)
{
   LifecycleEvent_Init(out);
   if(!EventSerializer_HasKey(line, "seq") || !EventSerializer_HasKey(line, "candidate_id"))
      return false;

   out.base.log_event_id       = EventSerializer_GetStr(line, "log_event_id");
   out.base.runtime_session_id = EventSerializer_GetStr(line, "session_id");
   out.base.sequence_number    = EventSerializer_GetLong(line, "seq");
   out.base.category           = EventCategoryFromString(EventSerializer_GetStr(line, "category"));
   out.base.event_type         = EventSerializer_GetStr(line, "type");

   out.candidate_id   = EventSerializer_GetStr(line, "candidate_id");
   out.root_event_id  = EventSerializer_GetStr(line, "root_event_id");
   out.correlation_id = EventSerializer_GetStr(line, "correlation_id");
   out.strategy_id    = EventSerializer_GetInt(line, "strategy_id");

   string fromStr = EventSerializer_GetStr(line, "from_state");
   string toStr   = EventSerializer_GetStr(line, "to_state");
   out.from_state = CandidateStateFromString(fromStr);
   out.to_state   = CandidateStateFromString(toStr);
   out.reason     = ReasonCodeFromString(EventSerializer_GetStr(line, "reason"));
   return true;
}

//---------------------------------------------------------------------
// SystemEvent <-> JSON
//---------------------------------------------------------------------

string EventSerializer_ToJson(const SystemEvent &e)
{
   string s = "{";
   s += "\"schema_version\":\"" + MLQUANTAI_SCHEMA_VERSION + "\",";
   s += "\"log_event_id\":\"" + EventSerializer_Escape(e.base.log_event_id) + "\",";
   s += "\"session_id\":\""   + EventSerializer_Escape(e.base.runtime_session_id) + "\",";
   s += "\"seq\":"            + IntegerToString(e.base.sequence_number) + ",";
   s += "\"ts\":\""           + TimeToString(e.base.ts, TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"category\":\""     + EventCategoryToString(e.base.category) + "\",";
   s += "\"type\":\""         + EventSerializer_Escape(e.base.event_type) + "\",";
   s += "\"message\":\""      + EventSerializer_Escape(e.message) + "\"";
   if(e.extra_json != "")
      s += "," + e.extra_json;
   s += "}";
   return s;
}

bool EventSerializer_ParseSystem(string line, SystemEvent &out)
{
   SystemEvent_Init(out);
   if(!EventSerializer_HasKey(line, "seq"))
      return false;
   out.base.log_event_id       = EventSerializer_GetStr(line, "log_event_id");
   out.base.runtime_session_id = EventSerializer_GetStr(line, "session_id");
   out.base.sequence_number    = EventSerializer_GetLong(line, "seq");
   out.base.category           = EventCategoryFromString(EventSerializer_GetStr(line, "category"));
   out.base.event_type         = EventSerializer_GetStr(line, "type");
   out.message                 = EventSerializer_GetStr(line, "message");
   return true;
}

//---------------------------------------------------------------------
// ExecutionEvent <-> JSON
//---------------------------------------------------------------------

string EventSerializer_ToJson(const ExecutionEvent &e)
{
   string s = "{";
   s += "\"schema_version\":\""   + MLQUANTAI_SCHEMA_VERSION + "\",";
   s += "\"log_event_id\":\""   + EventSerializer_Escape(e.base.log_event_id) + "\",";
   s += "\"session_id\":\""     + EventSerializer_Escape(e.base.runtime_session_id) + "\",";
   s += "\"seq\":"              + IntegerToString(e.base.sequence_number) + ",";
   s += "\"ts\":\""             + TimeToString(e.base.ts, TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"category\":\""       + EventCategoryToString(e.base.category) + "\",";
   s += "\"type\":\""           + EventSerializer_Escape(e.base.event_type) + "\",";
   s += "\"correlation_id\":\"" + EventSerializer_Escape(e.correlation_id) + "\",";
   s += "\"ticket\":"           + IntegerToString((long)e.ticket) + ",";
   s += "\"retcode\":"          + IntegerToString((long)e.retcode) + ",";
   s += "\"requested_price\":"  + DoubleToString(e.requested_price, 5) + ",";
   s += "\"fill_price\":"       + DoubleToString(e.fill_price, 5) + ",";
   s += "\"slippage_points\":"  + DoubleToString(e.slippage_points, 2) + ",";
   s += "\"lot\":"              + DoubleToString(e.lot, 2);
   s += "}";
   return s;
}

bool EventSerializer_ParseExecution(string line, ExecutionEvent &out)
{
   ExecutionEvent_Init(out);
   if(!EventSerializer_HasKey(line, "seq") || !EventSerializer_HasKey(line, "ticket"))
      return false;
   out.base.log_event_id       = EventSerializer_GetStr(line, "log_event_id");
   out.base.runtime_session_id = EventSerializer_GetStr(line, "session_id");
   out.base.sequence_number    = EventSerializer_GetLong(line, "seq");
   out.base.category           = EventCategoryFromString(EventSerializer_GetStr(line, "category"));
   out.base.event_type         = EventSerializer_GetStr(line, "type");
   out.correlation_id          = EventSerializer_GetStr(line, "correlation_id");
   out.ticket                  = (ulong)EventSerializer_GetLong(line, "ticket");
   out.retcode                 = (uint)EventSerializer_GetLong(line, "retcode");
   out.requested_price         = EventSerializer_GetDouble(line, "requested_price");
   out.fill_price               = EventSerializer_GetDouble(line, "fill_price");
   out.slippage_points          = EventSerializer_GetDouble(line, "slippage_points");
   out.lot                      = EventSerializer_GetDouble(line, "lot");
   return true;
}

//---------------------------------------------------------------------
// Generic line inspection - used by the Validator/ReplayEngine to decide
// which typed parser to hand a line to before knowing its category.
//---------------------------------------------------------------------

ENUM_EVENT_CATEGORY EventSerializer_PeekCategory(string line)
{
   return EventCategoryFromString(EventSerializer_GetStr(line, "category"));
}

bool EventSerializer_PeekSequence(string line, long &seq, string &sessionId)
{
   if(!EventSerializer_HasKey(line, "seq")) return false;
   seq = EventSerializer_GetLong(line, "seq");
   sessionId = EventSerializer_GetStr(line, "session_id");
   return sessionId != "";
}

#endif // __MLQUANTAI_EVENTSERIALIZER_MQH__
