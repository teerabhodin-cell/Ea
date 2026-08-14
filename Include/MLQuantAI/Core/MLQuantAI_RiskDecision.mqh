//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_RiskDecision.mqh                      |
//| Phase B B1: contract for what the (B7+) Global Risk Manager will |
//| record for EVERY candidate it evaluates - approved or rejected.  |
//| This is what makes "no survivorship bias" possible: a rejected   |
//| candidate's RiskDecision carries the exact spread/news/account   |
//| state at the moment it was rejected, not just a boolean.         |
//|                                                                    |
//| Contract-only in B1: no Risk Manager exists yet to produce these -|
//| that's B7. This is distinct from the existing MLQuantAI_RiskPlan. |
//| mqh (Phase A's sizing-output struct: lot/risk_money/risk_percent).|
//| RiskDecision is the AUDIT record ("did this candidate pass, and   |
//| why"); RiskPlan is the SIZING output for one that passed. B7      |
//| reconciles how the two relate when the Risk Manager is built.     |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_RISKDECISION_MQH__
#define __MLQUANTAI_RISKDECISION_MQH__

#include "MLQuantAI_ReasonCodes.mqh"
#include "MLQuantAI_ContractVersions.mqh"

struct RiskDecision
{
   string             candidate_id;
   string             decision;          // "APPROVED" | "REJECTED"
   ENUM_REASON_CODE   reason_code;
   datetime           evaluated_at;
   string             risk_config_version;
   double             spread_at_decision;
   string             news_state_at_decision;
   string             account_state_at_decision;
   string             risk_schema_version; // MLQUANTAI_RISK_SCHEMA_V1
};

void RiskDecision_Init(RiskDecision &d)
{
   d.candidate_id = "";
   d.decision = "";
   d.reason_code = REASON_NONE;
   d.evaluated_at = 0;
   d.risk_config_version = "";
   d.spread_at_decision = 0;
   d.news_state_at_decision = "";
   d.account_state_at_decision = "";
   d.risk_schema_version = MLQUANTAI_RISK_SCHEMA_V1;
}

#endif // __MLQUANTAI_RISKDECISION_MQH__
