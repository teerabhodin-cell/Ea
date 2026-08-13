//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_BaseEvent.mqh    |
//| Envelope fields shared by every event category. MQL5 structs      |
//| don't support inheritance (only classes do), so LifecycleEvent/   |
//| ExecutionEvent/SystemEvent each embed a BaseEvent by composition  |
//| instead of extending it.                                          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BASEEVENT_MQH__
#define __MLQUANTAI_BASEEVENT_MQH__

enum ENUM_EVENT_CATEGORY
{
   EVENT_CAT_LIFECYCLE,
   EVENT_CAT_EXECUTION,
   EVENT_CAT_SYSTEM
};

string EventCategoryToString(ENUM_EVENT_CATEGORY c)
{
   switch(c)
   {
      case EVENT_CAT_LIFECYCLE: return "LIFECYCLE";
      case EVENT_CAT_EXECUTION: return "EXECUTION";
      case EVENT_CAT_SYSTEM:    return "SYSTEM";
   }
   return "UNKNOWN";
}

ENUM_EVENT_CATEGORY EventCategoryFromString(string s)
{
   if(s == "LIFECYCLE") return EVENT_CAT_LIFECYCLE;
   if(s == "EXECUTION") return EVENT_CAT_EXECUTION;
   return EVENT_CAT_SYSTEM;
}

struct BaseEvent
{
   string               log_event_id;       // runtime_session_id + "#" + sequence_number
   string               runtime_session_id;
   long                 sequence_number;    // 1-based, contiguous per session, ordering authority
   datetime             ts;                 // metadata only - NEVER used for ordering, sequence_number is
   ENUM_EVENT_CATEGORY  category;
   string               event_type;         // e.g. "CANDIDATE_CREATED", "ORDER_FILLED", "SYSTEM_STARTED"
};

void BaseEvent_Init(BaseEvent &b)
{
   b.log_event_id = "";
   b.runtime_session_id = "";
   b.sequence_number = 0;
   b.ts = 0;
   b.category = EVENT_CAT_SYSTEM;
   b.event_type = "";
}

#endif // __MLQUANTAI_BASEEVENT_MQH__
