//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_RiskSizing.mqh                        |
//| Phase B7.3: Candidate_ToRiskPlan() - the pure, deterministic       |
//| fixed-fractional-risk sizing formula frozen in                    |
//| Docs/PhaseB_B7_RiskPlanContract.md section 4. Copy/compute only -  |
//| never recomputes anything CRT_V1 (B5) already decided, never       |
//| touches AccountInfoDouble()/SymbolInfoDouble()/TimeCurrent() or    |
//| any broker/order/history/tick call, never appends an event, never  |
//| mutates its inputs.                                                |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_RISKSIZING_MQH__
#define __MLQUANTAI_RISKSIZING_MQH__

#include "MLQuantAI_Ids.mqh"
#include "MLQuantAI_RiskContext.mqh"
#include "MLQuantAI_RiskPlan.mqh"
#include "MLQuantAI_TradeCandidate.mqh"

// Fail-closed input validation - contract section 4 step 1. Returns ""
// on success, a reason string on failure (not classified into an enum
// here; B7.3 has exactly one caller-visible outcome shape - a filled
// RiskPlan or nothing at all - unlike B6.1's registry which needed a
// reason taxonomy for a whole store's worth of independently-failing
// lines).
string RiskSizing_ValidateInput(const TradeCandidate &candidate, const RiskContext &ctx)
{
   if(candidate.candidate_id == "") return "empty candidate_id";
   if(candidate.state != CANDIDATE_CREATED) return "candidate.state is not CANDIDATE_CREATED";

   if(!MathIsValidNumber(candidate.entry_hint) || !MathIsValidNumber(candidate.sl_hint) || !MathIsValidNumber(candidate.tp_hint))
      return "entry_hint/sl_hint/tp_hint contains NaN or Inf";
   if(candidate.entry_hint <= 0 || candidate.sl_hint <= 0 || candidate.tp_hint <= 0)
      return "entry_hint/sl_hint/tp_hint contains a zero/negative price";

   if(candidate.side == ORDER_TYPE_BUY)
   {
      if(!(candidate.sl_hint < candidate.entry_hint && candidate.entry_hint < candidate.tp_hint))
         return "SL/TP ordering violates BUY semantics (need sl_hint < entry_hint < tp_hint)";
   }
   else
   {
      if(!(candidate.sl_hint > candidate.entry_hint && candidate.entry_hint > candidate.tp_hint))
         return "SL/TP ordering violates SELL semantics (need sl_hint > entry_hint > tp_hint)";
   }

   if(ctx.symbol_spec.tick_size <= 0)  return "RiskContext.symbol_spec.tick_size is not positive";
   if(ctx.symbol_spec.tick_value <= 0) return "RiskContext.symbol_spec.tick_value is not positive";
   if(ctx.symbol_spec.volume_step <= 0) return "RiskContext.symbol_spec.volume_step is not positive";
   if(ctx.symbol_spec.volume_min <= 0)  return "RiskContext.symbol_spec.volume_min is not positive";

   if(!MathIsValidNumber(ctx.target_risk_percent) || ctx.target_risk_percent <= 0)
      return "RiskContext.target_risk_percent is not a positive number";
   if(!MathIsValidNumber(ctx.account.balance) || ctx.account.balance <= 0)
      return "RiskContext.account.balance is not a positive number";

   return "";
}

// The B7.3 entry point. Returns true with outPlan fully filled (both
// the Phase A and Phase B7 field groups - see RiskPlan.mqh's own
// header) only on success. Returns false, with outPlan left at
// RiskPlan_Init() defaults, on any fail-closed condition - no partial
// output, matching every other B5/B6 mapping function's own rule.
bool Candidate_ToRiskPlan(const TradeCandidate &candidate, const RiskContext &ctx, RiskPlan &outPlan)
{
   RiskPlan_Init(outPlan);

   if(RiskSizing_ValidateInput(candidate, ctx) != "")
      return false;

   // Step 2: copy planned prices verbatim - B7 never adjusts CRT's own
   // entry/exit decision.
   double plannedEntry = candidate.entry_hint;
   double plannedSl     = candidate.sl_hint;
   double plannedTp     = candidate.tp_hint;

   // Step 3: stop distance in points, broker-agnostic via tick_size
   // (never _Point/Point()).
   double stopDistancePrice  = MathAbs(plannedEntry - plannedSl);
   double stopDistancePoints = stopDistancePrice / ctx.symbol_spec.tick_size;
   if(stopDistancePoints <= 0) return false; // second, independent guard - see contract step 3

   // Step 4: reward/risk ratio - two price distances over the same
   // tick_size cancel out, no unit conversion needed.
   double rrRatio = MathAbs(plannedTp - plannedEntry) / MathAbs(plannedEntry - plannedSl);

   // Step 5: risk amount.
   double riskAmount = ctx.account.balance * (ctx.target_risk_percent / 100.0);

   // Step 6: raw lot size. tick_value is MT5's own SYMBOL_TRADE_TICK_VALUE
   // - already the monetary value of one tick move for 1.0 lot, contract
   // size and currency conversion already folded in by the terminal, so
   // no separate contract-size multiplication is needed.
   double rawLot = riskAmount / (stopDistancePoints * ctx.symbol_spec.tick_value);

   // Step 7: round DOWN to the nearest volume_step - never up, that
   // would silently risk more than target_risk_percent asked for.
   double steppedLot = MathFloor(rawLot / ctx.symbol_spec.volume_step) * ctx.symbol_spec.volume_step;

   // Step 8: clamp/reject against broker limits. Below volume_min is a
   // genuine rejection (bumping up would silently exceed the configured
   // risk); above volume_max is safe to clamp down (only ever reduces
   // risk below the target).
   if(steppedLot < ctx.symbol_spec.volume_min) return false;
   if(ctx.symbol_spec.volume_max > 0 && steppedLot > ctx.symbol_spec.volume_max)
      steppedLot = ctx.symbol_spec.volume_max;

   // Step 9: fill both field vocabularies from the same computation.
   outPlan.candidate_id     = candidate.candidate_id;
   outPlan.candidate_hash   = candidate.candidate_hash;
   outPlan.risk_context_hash = ctx.risk_context_hash;

   outPlan.planned_entry = plannedEntry;
   outPlan.planned_sl    = plannedSl;
   outPlan.planned_tp    = plannedTp;

   outPlan.stop_distance_points = stopDistancePoints;
   outPlan.rr_ratio               = rrRatio;

   outPlan.risk_percent = ctx.target_risk_percent; // Phase A field, same value as the B7 percent input
   outPlan.risk_amount  = riskAmount;
   outPlan.lot_size      = steppedLot;
   outPlan.risk_money   = riskAmount; // Phase A field - see RiskPlan.mqh header
   outPlan.lot           = steppedLot; // Phase A field - see RiskPlan.mqh header

   outPlan.sizing_method        = ctx.sizing_method;
   outPlan.sizing_rules_version = ctx.sizing_rules_version;

   outPlan.decision      = RISK_DECISION_ALLOW;
   outPlan.allowed        = true;
   outPlan.reject_reason = REASON_NONE;

   outPlan.risk_plan_id = Ids_RiskPlanId(candidate.candidate_id, ctx.sizing_rules_version);

   // Step 10: plan_hash computed LAST, over the finished struct - same
   // "hash the finished object" convention every other hash in this
   // project follows.
   outPlan.plan_hash = RiskPlan_ComputeHash(outPlan);

   return true;
}

#endif // __MLQUANTAI_RISKSIZING_MQH__
