//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_RiskPlan.mqh                          |
//| Output of the Global Risk Manager: either a concrete lot size to |
//| execute, or a reason the candidate is blocked. This is the final |
//| authority the spec describes - nothing downstream recomputes     |
//| risk, the Execution Engine just executes what's here.             |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_RISKPLAN_MQH__
#define __MLQUANTAI_RISKPLAN_MQH__

#include "MLQuantAI_ReasonCodes.mqh"

struct RiskPlan
{
   bool                allowed;
   double              lot;
   double              risk_money;
   double              risk_percent;
   ENUM_REASON_CODE    reject_reason;
};

void RiskPlan_Init(RiskPlan &r)
{
   r.allowed = false;
   r.lot = 0;
   r.risk_money = 0;
   r.risk_percent = 0;
   r.reject_reason = REASON_NONE;
}

#endif // __MLQUANTAI_RISKPLAN_MQH__
