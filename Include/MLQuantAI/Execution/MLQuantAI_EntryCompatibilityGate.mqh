//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_EntryCompatibilityGate.mqh       |
//| RA-13: EntryCompatibilityGate_Evaluate() - pure, unit-testable    |
//| logic only, NO OrderSend call anywhere in this file. Implements   |
//| the gate frozen at Docs/PhaseC_C2_4_EntryPriceCompatibilityContract|
//| .md §2/§4/§7/§8, positioned between B9 (Execution Eligibility) and |
//| C2 (BrokerSubmission) per that contract's own authority table     |
//| (§5) - a distinct component, never folded into B7/RiskSizing or   |
//| into MLQuantAI_BrokerSubmissionBuilder.mqh.                        |
//|                                                                     |
//| Captures execution_reference_price EXACTLY ONCE per evaluation     |
//| (BUY = SYMBOL_ASK, SELL = SYMBOL_BID, per C2.4 §7's normative      |
//| invariant) and returns it to the caller for binding into the same  |
//| submission attempt's MqlTradeRequest.price - this file never       |
//| re-reads the market itself, and the caller (BrokerSubmission_Submit|
//| , MLQuantAI_BrokerSubmissionAdapter.mqh) must pass the returned    |
//| value straight through to MLQuantAI_BrokerSubmissionBuilder.mqh    |
//| without any intervening reread (C2.4 AC-10 / the RA-12 amendment   |
//| to Docs/PhaseC_C2_1_BrokerSubmissionContract.md).                  |
//|                                                                     |
//| Directional hard constraint (C2.4 §8) is checked BEFORE, and       |
//| independently of, the risk-divergence calculation - a reference    |
//| price already on the wrong side of planned_sl means the stop       |
//| geometry itself is invalid, so the divergence percentage is never  |
//| computed in that case.                                             |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ENTRYCOMPATIBILITYGATE_MQH__
#define __MLQUANTAI_ENTRYCOMPATIBILITYGATE_MQH__

#include "MLQuantAI_ExecutionRequestContract.mqh"

// C2.4 §8 (frozen, QA ruling): realized-risk-percent divergence,
// threshold ±10%. Not related to ExecutionPolicy.max_deviation_points
// (a broker round-trip slippage parameter, C2.4 §1/AC-05) - this
// constant is Entry Compatibility Gate's own, separately-named policy
// value, never read from or written to that field.
#define MLQUANTAI_ENTRY_COMPATIBILITY_MAX_RISK_DIVERGENCE_PCT 10.0

// Gate's own result shape - deliberately not a reuse of
// DryRunExecutionResult (C1.2's own struct, out of this checkpoint's
// allowed-files scope, and it has no field for the bound price this
// gate must return). execution_reference_price is meaningful only
// when decision == SAFETY_GATE_ACCEPTED; risk_divergence_pct is
// diagnostic/audit evidence, populated whenever the divergence
// calculation actually runs (i.e. the directional constraint passed),
// left at 0.0 if the gate rejected before reaching that step.
struct EntryCompatibilityResult
{
   ENUM_SAFETY_GATE_DECISION decision;
   ENUM_REASON_CODE          reason_code;

   double execution_reference_price; // the bound value - BUY=ASK, SELL=BID, captured once
   double risk_divergence_pct;       // diagnostic only - abs(realized-planned)/planned * 100
};

void EntryCompatibilityResult_Init(EntryCompatibilityResult &r)
{
   r.decision = SAFETY_GATE_NONE;
   r.reason_code = REASON_NONE;
   r.execution_reference_price = 0.0;
   r.risk_divergence_pct = 0.0;
}

// Returns false only on a structural failure (empty execution_request_id) -
// no EntryCompatibilityResult is produced at all in that case, same
// convention SafetyGate_Evaluate (MLQuantAI_SafetyGate.mqh) already
// established. Every other path returns true, with outResult.decision
// set to SAFETY_GATE_ACCEPTED or SAFETY_GATE_REJECTED and
// outResult.reason_code set to the specific cause (REASON_NONE on
// acceptance).
bool EntryCompatibilityGate_Evaluate(const ExecutionRequest &request, EntryCompatibilityResult &outResult)
{
   EntryCompatibilityResult_Init(outResult);

   if(request.execution_request_id == "")
      return false;

   if(request.side != ORDER_TYPE_BUY && request.side != ORDER_TYPE_SELL)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_ORDER_TYPE_NOT_MARKET;
      return true;
   }

   // Runtime Safety Context read, exactly once, per C2.4 §7's binding
   // invariant - reused for the rest of this evaluation, never
   // re-read later by this file or by the caller for the same attempt.
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_ERROR_INTERNAL;
      return true;
   }

   double executionReferencePrice = (request.side == ORDER_TYPE_BUY) ? ask : bid;
   outResult.execution_reference_price = executionReferencePrice;

   // Directional hard constraint (C2.4 §8) - checked before, and
   // independently of, the divergence calculation below.
   bool directionalOk = (request.side == ORDER_TYPE_BUY)
                            ? (executionReferencePrice > request.planned_sl)
                            : (executionReferencePrice < request.planned_sl);
   if(!directionalOk)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_ENTRY_PRICE_DEVIATION_EXCEEDED;
      return true;
   }

   // tick_value read the same way RiskPlan/B7 already does
   // (MLQuantAI_RiskSizing.mqh's own comment: "tick_value is MT5's own
   // SYMBOL_TRADE_TICK_VALUE") - not a new source of this value, just
   // read directly here instead of threaded through a RiskContext this
   // gate has no access to.
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue <= 0.0)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_ERROR_INTERNAL;
      return true;
   }

   double plannedStopDistance = MathAbs(request.planned_entry - request.planned_sl);
   if(plannedStopDistance <= 0.0 || request.lot_size <= 0.0)
   {
      // Degenerate input (planned_entry == planned_sl, or a non-positive
      // lot_size) - cannot be a real RiskPlan-sized request (B7's own
      // stop_distance_points > 0 / volume_min > 0 guards already reject
      // this upstream), fail closed rather than divide by zero below.
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_ERROR_INTERNAL;
      return true;
   }
   double realizedStopDistance = MathAbs(executionReferencePrice - request.planned_sl);

   // lot_size and tick_value are common factors of both money terms
   // below and cancel exactly in the ratio - kept explicit anyway,
   // matching C2.4 §8's normative formula verbatim rather than the
   // algebraically-reduced form, so this function stays a direct,
   // auditable transcription of the frozen contract text.
   double plannedRiskMoney  = request.lot_size * plannedStopDistance  * tickValue;
   double realizedRiskMoney = request.lot_size * realizedStopDistance * tickValue;

   double riskDivergencePct = MathAbs(realizedRiskMoney - plannedRiskMoney) / plannedRiskMoney * 100.0;
   outResult.risk_divergence_pct = riskDivergencePct;

   if(riskDivergencePct > MLQUANTAI_ENTRY_COMPATIBILITY_MAX_RISK_DIVERGENCE_PCT)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_ENTRY_PRICE_DEVIATION_EXCEEDED;
      return true;
   }

   outResult.decision    = SAFETY_GATE_ACCEPTED;
   outResult.reason_code = REASON_NONE;
   return true;
}

#endif // __MLQUANTAI_ENTRYCOMPATIBILITYGATE_MQH__
