//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_ExecutionEvent.mqh|
//| One broker interaction outcome (submit/fill/reject). Phase A has  |
//| no Execution Engine yet, so nothing produces these live - this    |
//| struct + its serialization exist now so the format is locked      |
//| before Phase B needs it, and so BrokerReconciliationTest has a    |
//| real shape to test against (using simulated data for now).        |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EXECUTIONEVENT_MQH__
#define __MLQUANTAI_EXECUTIONEVENT_MQH__

#include "MLQuantAI_BaseEvent.mqh"

struct ExecutionEvent
{
   BaseEvent   base;
   string      correlation_id;
   ulong       ticket;
   uint        retcode;
   double      requested_price;
   double      fill_price;       // 0 until reconciled
   double      slippage_points;  // 0 until reconciled
   double      lot;
};

void ExecutionEvent_Init(ExecutionEvent &e)
{
   BaseEvent_Init(e.base);
   e.base.category = EVENT_CAT_EXECUTION;
   e.correlation_id = "";
   e.ticket = 0;
   e.retcode = 0;
   e.requested_price = 0;
   e.fill_price = 0;
   e.slippage_points = 0;
   e.lot = 0;
}

#endif // __MLQUANTAI_EXECUTIONEVENT_MQH__
