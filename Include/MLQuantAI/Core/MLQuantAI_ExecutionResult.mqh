//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_ExecutionResult.mqh                   |
//| What actually happened when the Execution Engine submitted an    |
//| order. success/ticket come from the immediate OrderSend result;  |
//| OnTradeTransaction reconciliation (Sprint 2+) fills in the real   |
//| fill price/slippage once the broker confirms the deal, since a   |
//| successful OrderSend is a submission acknowledgement, not proof  |
//| of an actual fill at the requested price.                         |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EXECUTIONRESULT_MQH__
#define __MLQUANTAI_EXECUTIONRESULT_MQH__

#include "MLQuantAI_ReasonCodes.mqh"

struct ExecutionResult
{
   bool                success;
   ulong               ticket;
   uint                retcode;
   double              requested_price;
   double              fill_price;       // 0 until reconciled via OnTradeTransaction
   double              slippage_points;  // 0 until reconciled
   ENUM_REASON_CODE    reason;
};

void ExecutionResult_Init(ExecutionResult &e)
{
   e.success = false;
   e.ticket = 0;
   e.retcode = 0;
   e.requested_price = 0;
   e.fill_price = 0;
   e.slippage_points = 0;
   e.reason = REASON_NONE;
}

#endif // __MLQUANTAI_EXECUTIONRESULT_MQH__
