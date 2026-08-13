//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_SystemEvent.mqh  |
//| System-level events not tied to any single candidate:             |
//| SYSTEM_STARTED, SYSTEM_STOPPED, SAFE_MODE_ENGAGED, and anything   |
//| else the RuntimeState projector needs to fold that isn't a        |
//| candidate transition.                                             |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_SYSTEMEVENT_MQH__
#define __MLQUANTAI_SYSTEMEVENT_MQH__

#include "MLQuantAI_BaseEvent.mqh"

struct SystemEvent
{
   BaseEvent   base;
   string      message;
   string      extra_json; // caller-supplied, must already be valid JSON fragment
};

void SystemEvent_Init(SystemEvent &e)
{
   BaseEvent_Init(e.base);
   e.base.category = EVENT_CAT_SYSTEM;
   e.message = "";
   e.extra_json = "";
}

#endif // __MLQUANTAI_SYSTEMEVENT_MQH__
