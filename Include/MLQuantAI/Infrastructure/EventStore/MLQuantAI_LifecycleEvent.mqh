//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_LifecycleEvent.mqh|
//| One candidate state transition. This is the record type the       |
//| StateProjector/ReplayEngine actually fold - it must carry enough  |
//| to replay the transition (candidate_id, from/to state) and enough |
//| to audit it (reason, strategy, root/correlation ids).             |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_LIFECYCLEEVENT_MQH__
#define __MLQUANTAI_LIFECYCLEEVENT_MQH__

#include "MLQuantAI_BaseEvent.mqh"
#include "../../Core/MLQuantAI_StateMachine.mqh"
#include "../../Core/MLQuantAI_ReasonCodes.mqh"

struct LifecycleEvent
{
   BaseEvent               base;
   string                  candidate_id;
   string                  root_event_id;
   string                  correlation_id;   // empty until CANDIDATE_SUBMITTED
   int                     strategy_id;
   ENUM_CANDIDATE_STATE    from_state;
   ENUM_CANDIDATE_STATE    to_state;
   ENUM_REASON_CODE        reason;
   string                  extra_json;       // caller-supplied, must already be valid JSON fragment (no leading/trailing comma)
};

void LifecycleEvent_Init(LifecycleEvent &e)
{
   BaseEvent_Init(e.base);
   e.base.category = EVENT_CAT_LIFECYCLE;
   e.candidate_id = "";
   e.root_event_id = "";
   e.correlation_id = "";
   e.strategy_id = -1;
   e.from_state = CANDIDATE_CREATED;
   e.to_state = CANDIDATE_CREATED;
   e.reason = REASON_NONE;
   e.extra_json = "";
}

#endif // __MLQUANTAI_LIFECYCLEEVENT_MQH__
