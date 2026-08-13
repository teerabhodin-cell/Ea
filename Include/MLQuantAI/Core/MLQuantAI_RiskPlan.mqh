//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_RiskPlan.mqh                          |
//| Output of the Global Risk Manager: either a concrete lot size to |
//| execute, or a reason the candidate is blocked. This is the final |
//| authority the spec describes - nothing downstream recomputes     |
//| risk, the Execution Engine just executes what's here.             |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_RISKPLAN_MQH__
#define __MLQUANTAI_RISKPLAN_MQH__

#include "MLQuantAI_Enums.mqh"
#include "MLQuantAI_ReasonCodes.mqh"
#include "MLQuantAI_VersionRegistry.mqh"

struct RiskPlan
{
   ENUM_RISK_DECISION  decision;
   bool                allowed;
   double              lot;
   double              risk_money;
   double              risk_percent;
   ENUM_REASON_CODE    reject_reason;
   string              risk_schema_version; // MLQUANTAI_RISK_SCHEMA_VERSION
};

void RiskPlan_Init(RiskPlan &r)
{
   r.decision = RISK_DECISION_NONE;
   r.allowed = false;
   r.lot = 0;
   r.risk_money = 0;
   r.risk_percent = 0;
   r.reject_reason = REASON_NONE;
   r.risk_schema_version = MLQUANTAI_RISK_SCHEMA_VERSION;
}

#endif // __MLQUANTAI_RISKPLAN_MQH__
