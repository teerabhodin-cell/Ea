//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_RiskContext.mqh                       |
//| Phase B7.1: the frozen snapshot Candidate_ToRiskPlan() sizes      |
//| against. Built ONCE, by a caller OUTSIDE Candidate_ToRiskPlan,    |
//| from live AccountInfoDouble()/SymbolInfoDouble() reads - the same |
//| "captured once, reused everywhere downstream" discipline          |
//| AccountSnapshot/SymbolSpec already established (Phase A / B2).    |
//| Candidate_ToRiskPlan itself must never call AccountInfoDouble(),   |
//| SymbolInfoDouble(), or TimeCurrent() - every value it needs must   |
//| already be sitting on this struct or on TradeCandidate. See        |
//| Docs/PhaseB_B7_RiskPlanContract.md section 1.                      |
//|                                                                    |
//| IMPORTANT: risk_context_hash is a RULES/SPEC snapshot hash, not a |
//| full sizing-input hash - it deliberately excludes account.balance/|
//| equity (same precedent MarketContext_HashPayload already set for  |
//| its own .account field). Two RiskContext values with the IDENTICAL|
//| risk_context_hash can legitimately produce DIFFERENT RiskPlan      |
//| outputs if their account.balance differs. It answers "is this the |
//| same sizing rule set", never "will this produce the same plan" -   |
//| only RiskPlan.plan_hash answers that.                              |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_RISKCONTEXT_MQH__
#define __MLQUANTAI_RISKCONTEXT_MQH__

#include "MLQuantAI_AccountSnapshot.mqh"
#include "MLQuantAI_CanonicalFormat.mqh"
#include "MLQuantAI_ContractVersions.mqh"
#include "MLQuantAI_Ids.mqh"
#include "../Market/MLQuantAI_SymbolSpec.mqh"

struct RiskContext
{
   string risk_context_schema_version;
   string risk_context_hash; // hash of the fields below, EXCLUDING account (see RiskContext_HashPayload)

   AccountSnapshot account;      // Phase A struct, embedded verbatim - snapshot-only
   SymbolSpec      symbol_spec;  // Phase B B2 struct, embedded verbatim - snapshot-only

   double target_risk_percent;   // the account's configured risk-per-trade, e.g. 1.0 == 1%
   string sizing_method;         // e.g. "FIXED_PERCENT_RISK" (B7.3's only method for now)
   string sizing_rules_version;  // frozen version tag, same role MLQUANTAI_CRT_V1_RULES_VERSION plays for CRT
};

void RiskContext_Init(RiskContext &c)
{
   c.risk_context_schema_version = MLQUANTAI_RISK_CONTEXT_SCHEMA_V1;
   c.risk_context_hash = "";

   AccountSnapshot_Init(c.account);
   SymbolSpec_Init(c.symbol_spec);

   c.target_risk_percent = 0;
   c.sizing_method = "";
   c.sizing_rules_version = "";
}

// Hash payload - INCLUDED: everything that defines the sizing
// environment's own content (symbol sizing constraints, target risk,
// sizing method/version). EXCLUDED: account.* entirely (same precedent
// MarketContext_HashPayload already set for its own .account field -
// runtime-only, must not move an identity/content hash; balance's
// effect on sizing reaches plan_hash only indirectly, through the
// risk_amount/lot_size it produces - see the contract doc's own gate
// list), symbol_spec fields that aren't sizing-relevant
// (currency_base/currency_profit/currency_margin/trade_mode/
// stops_level_points/freeze_level_points/point/schema versions/symbol),
// and risk_context_schema_version/risk_context_hash themselves (derived
// from this payload, not part of it).
string RiskContext_HashPayload(const RiskContext &c)
{
   return c.symbol_spec.instrument_id + "|" +
          c.symbol_spec.broker_symbol + "|" +
          CanonicalPrice(c.symbol_spec.tick_size) + "|" +
          CanonicalDouble(c.symbol_spec.tick_value) + "|" +
          CanonicalDouble(c.symbol_spec.contract_size) + "|" +
          CanonicalDouble(c.symbol_spec.volume_min) + "|" +
          CanonicalDouble(c.symbol_spec.volume_max) + "|" +
          CanonicalDouble(c.symbol_spec.volume_step) + "|" +
          IntegerToString(c.symbol_spec.digits) + "|" +
          CanonicalPercent(c.target_risk_percent) + "|" +
          c.sizing_method + "|" +
          c.sizing_rules_version;
}

string RiskContext_ComputeHash(const RiskContext &c)
{
   return Ids_Sha256Hex(RiskContext_HashPayload(c));
}

#endif // __MLQUANTAI_RISKCONTEXT_MQH__
