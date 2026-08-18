//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_RiskPlan.mqh                          |
//| Output of the Global Risk Manager: either a concrete lot size to |
//| execute, or a reason the candidate is blocked. This is the final |
//| authority the spec describes - nothing downstream recomputes     |
//| risk, the Execution Engine just executes what's here.             |
//|                                                                    |
//| Phase B7 (additive): Core/MLQuantAI_RiskDecision.mqh's own doc     |
//| comment already named this moment - "RiskDecision is the AUDIT     |
//| record; RiskPlan is the SIZING output for one that passed. B7      |
//| reconciles how the two relate when the Risk Manager is built."     |
//| Every field above this comment is UNCHANGED. The new fields below  |
//| are what Candidate_ToRiskPlan() (Core/MLQuantAI_RiskSizing.mqh)    |
//| fills, alongside the original ones, from the SAME computation -    |
//| lot==lot_size and risk_money==risk_amount are two names for the    |
//| same value (old names kept because Phase A code, however dormant,  |
//| was written against them; new names kept because they match        |
//| plan_hash's own payload vocabulary). See                           |
//| Docs/PhaseB_B7_RiskPlanContract.md section 3 for the full contract.|
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_RISKPLAN_MQH__
#define __MLQUANTAI_RISKPLAN_MQH__

#include "MLQuantAI_CanonicalFormat.mqh"
#include "MLQuantAI_ContractVersions.mqh"
#include "MLQuantAI_Enums.mqh"
#include "MLQuantAI_Ids.mqh"
#include "MLQuantAI_ReasonCodes.mqh"
#include "MLQuantAI_VersionRegistry.mqh"

struct RiskPlan
{
   // --- Phase A, sealed, UNCHANGED ---
   ENUM_RISK_DECISION  decision;
   bool                allowed;
   double              lot;
   double              risk_money;
   double              risk_percent;
   ENUM_REASON_CODE    reject_reason;
   string              risk_schema_version; // MLQUANTAI_RISK_SCHEMA_VERSION

   // --- Phase B7, additive ---
   string risk_plan_schema_version; // MLQUANTAI_RISK_PLAN_SCHEMA_V1
   string risk_plan_id;
   string candidate_id;
   string candidate_hash;      // copied verbatim from TradeCandidate - never recomputed
   string risk_context_hash;   // copied verbatim from RiskContext - never recomputed

   double planned_entry;       // copied verbatim from candidate.entry_hint
   double planned_sl;          // copied verbatim from candidate.sl_hint
   double planned_tp;          // copied verbatim from candidate.tp_hint

   double stop_distance_points;
   double rr_ratio;

   double risk_amount;         // same value as risk_money - see file header
   double lot_size;            // same value as lot - see file header

   string sizing_method;       // copied verbatim from RiskContext.sizing_method
   string sizing_rules_version;// copied verbatim from RiskContext.sizing_rules_version

   string plan_hash;
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

   r.risk_plan_schema_version = MLQUANTAI_RISK_PLAN_SCHEMA_V1;
   r.risk_plan_id = "";
   r.candidate_id = "";
   r.candidate_hash = "";
   r.risk_context_hash = "";

   r.planned_entry = 0;
   r.planned_sl = 0;
   r.planned_tp = 0;

   r.stop_distance_points = 0;
   r.rr_ratio = 0;

   r.risk_amount = 0;
   r.lot_size = 0;

   r.sizing_method = "";
   r.sizing_rules_version = "";

   r.plan_hash = "";
}

// Hash payload - exact field order per Docs/PhaseB_B7_RiskPlanContract.md
// section 3. Excludes risk_plan_schema_version/risk_plan_id (identity,
// not content), and the Phase A fields (decision/allowed/reject_reason/
// risk_schema_version/lot/risk_money) - lot/risk_money are duplicates of
// lot_size/risk_amount already in this payload under their B7 names;
// hashing both would be redundant, same "don't hash the same thing
// twice" rule this project has used since B2.
string RiskPlan_HashPayload(const RiskPlan &p)
{
   return p.candidate_id + "|" +
          p.candidate_hash + "|" +
          p.risk_context_hash + "|" +
          CanonicalPrice(p.planned_entry) + "|" +
          CanonicalPrice(p.planned_sl) + "|" +
          CanonicalPrice(p.planned_tp) + "|" +
          CanonicalDouble(p.stop_distance_points) + "|" +
          CanonicalDouble(p.rr_ratio) + "|" +
          CanonicalPercent(p.risk_percent) + "|" +
          CanonicalDouble(p.risk_amount) + "|" +
          CanonicalDouble(p.lot_size) + "|" +
          p.sizing_method + "|" +
          p.sizing_rules_version;
}

string RiskPlan_ComputeHash(const RiskPlan &p)
{
   return Ids_Sha256Hex(RiskPlan_HashPayload(p));
}

#endif // __MLQUANTAI_RISKPLAN_MQH__
