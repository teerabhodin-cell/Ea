//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_EligibilityBuilder.mqh            |
//| Phase B9 Commit 1: EligibilityDecision_Build() - pure mapping from  |
//| a validated RiskPlan + AIDecision + the FeatureSnapshot AIDecision  |
//| was built from + an explicit, versioned EligibilityPolicy + a       |
//| captured EligibilityContext, to an EligibilityDecision. Per         |
//| Docs/PhaseB_B9_ExecutionEligibilityContract.md. No live account/     |
//| tick/broker/SafeMode call, no event emission, no state-machine       |
//| transition, no mutation of any input, no execution.                  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ELIGIBILITYBUILDER_MQH__
#define __MLQUANTAI_ELIGIBILITYBUILDER_MQH__

#include "MLQuantAI_EligibilityContract.mqh"
#include "../Core/MLQuantAI_RiskPlan.mqh"
#include "../AI/MLQuantAI_AIDecisionContract.mqh"
#include "../Market/MLQuantAI_FeatureSnapshot.mqh"

// Fail-closed ladder (mirrors AIDecision_Build's own style): RiskPlan/
// AIDecision boundary checks -> 3-way lineage cross-check -> policy
// shape -> EligibilityContext integrity -> decide, in the frozen
// precedence order (AI veto first, then each operational gate, then
// ELIGIBLE). On any failure, outDecision is left at
// EligibilityDecision_Init() defaults - no partial record.
bool EligibilityDecision_Build(const RiskPlan &plan, const AIDecision &decision, const FeatureSnapshot &snapshot,
                                 const EligibilityContext &context, const EligibilityPolicy &policy,
                                 EligibilityDecision &outDecision, string &outReasonDetail)
{
   EligibilityDecision_Init(outDecision);
   outReasonDetail = "";

   if(plan.risk_plan_id == "")
   {
      outReasonDetail = "RiskPlan.risk_plan_id is empty - not an allowed plan";
      return false;
   }

   if(decision.ai_decision_id == "")
   {
      outReasonDetail = "AIDecision.ai_decision_id is empty - not a built decision";
      return false;
   }

   if(plan.candidate_id != decision.candidate_id || plan.candidate_hash != decision.candidate_hash)
   {
      outReasonDetail = "RiskPlan and AIDecision do not agree on candidate_id/candidate_hash";
      return false;
   }

   if(decision.feature_snapshot_id != snapshot.feature_snapshot_id ||
      decision.feature_snapshot_hash != snapshot.feature_snapshot_hash ||
      decision.feature_vector_hash != snapshot.feature_vector_hash)
   {
      outReasonDetail = "the supplied FeatureSnapshot does not match the identity/hash the AIDecision carries";
      return false;
   }

   if(snapshot.candidate_id != plan.candidate_id || snapshot.candidate_hash != plan.candidate_hash)
   {
      outReasonDetail = "FeatureSnapshot and RiskPlan do not agree on candidate_id/candidate_hash";
      return false;
   }

   if(policy.eligibility_policy_version == "")
   {
      outReasonDetail = "EligibilityPolicy.eligibility_policy_version is empty";
      return false;
   }

   if(!MathIsValidNumber(policy.max_daily_loss_percent) || policy.max_daily_loss_percent < 0.0 || policy.max_daily_loss_percent > 100.0)
   {
      outReasonDetail = "EligibilityPolicy.max_daily_loss_percent is not finite or not in [0,100]";
      return false;
   }
   if(!MathIsValidNumber(policy.max_drawdown_percent) || policy.max_drawdown_percent < 0.0 || policy.max_drawdown_percent > 100.0)
   {
      outReasonDetail = "EligibilityPolicy.max_drawdown_percent is not finite or not in [0,100]";
      return false;
   }
   if(!MathIsValidNumber(policy.max_total_exposure_percent) || policy.max_total_exposure_percent < 0.0 || policy.max_total_exposure_percent > 100.0)
   {
      outReasonDetail = "EligibilityPolicy.max_total_exposure_percent is not finite or not in [0,100]";
      return false;
   }
   if(policy.max_open_positions < 0)
   {
      outReasonDetail = "EligibilityPolicy.max_open_positions is negative";
      return false;
   }
   if(!MathIsValidNumber(policy.min_margin_level) || policy.min_margin_level < 0.0)
   {
      outReasonDetail = "EligibilityPolicy.min_margin_level is not finite or negative";
      return false;
   }

   if(context.eligibility_context_hash == "" || context.eligibility_context_hash != EligibilityContext_ComputeHash(context))
   {
      outReasonDetail = "EligibilityContext.eligibility_context_hash is empty or does not match a fresh recompute";
      return false;
   }

   if(!MathIsValidNumber(context.account.balance) || !MathIsValidNumber(context.account.equity) ||
      !MathIsValidNumber(context.account.margin_level) || !MathIsValidNumber(context.account.open_risk_percent) ||
      !MathIsValidNumber(context.account.daily_pnl_percent) || !MathIsValidNumber(context.account.drawdown_from_peak_percent))
   {
      outReasonDetail = "EligibilityContext.account contains a non-finite field";
      return false;
   }

   outDecision.candidate_id   = plan.candidate_id;
   outDecision.candidate_hash = plan.candidate_hash;

   outDecision.risk_plan_id = plan.risk_plan_id;
   outDecision.plan_hash    = plan.plan_hash;

   outDecision.ai_decision_id   = decision.ai_decision_id;
   outDecision.ai_decision_hash = decision.ai_decision_hash;

   outDecision.eligibility_context_hash   = context.eligibility_context_hash;
   outDecision.eligibility_policy_version = policy.eligibility_policy_version;

   // Frozen precedence order - first match wins. AI veto is checked
   // before every operational gate: the model's verdict is a
   // deterministic, already-audited decision (AIDecision, sealed at
   // B8.5); keeping it first keeps precedence itself deterministic and
   // auditable. Changing this order later requires a new
   // eligibility_policy_version, never a silent behavior change under
   // an existing one.
   if(decision.decision_outcome == AI_DECISION_OUTCOME_REJECT)
   {
      outDecision.decision     = ELIGIBILITY_DECISION_REJECTED;
      outDecision.reason_code  = REASON_AI_REJECT;
   }
   else if(decision.decision_outcome == AI_DECISION_OUTCOME_ABSTAIN)
   {
      outDecision.decision     = ELIGIBILITY_DECISION_REJECTED;
      outDecision.reason_code  = REASON_AI_ABSTAIN;
   }
   else if(policy.max_daily_loss_percent > 0.0 && context.account.daily_pnl_percent <= -policy.max_daily_loss_percent)
   {
      outDecision.decision    = ELIGIBILITY_DECISION_REJECTED;
      outDecision.reason_code = REASON_RISK_DAILY_LOSS_LIMIT;
   }
   else if(policy.max_drawdown_percent > 0.0 && context.account.drawdown_from_peak_percent >= policy.max_drawdown_percent)
   {
      outDecision.decision    = ELIGIBILITY_DECISION_REJECTED;
      outDecision.reason_code = REASON_RISK_MAX_DRAWDOWN;
   }
   else if(policy.max_total_exposure_percent > 0.0 && context.account.open_risk_percent >= policy.max_total_exposure_percent)
   {
      outDecision.decision    = ELIGIBILITY_DECISION_REJECTED;
      outDecision.reason_code = REASON_RISK_MAX_TOTAL_EXPOSURE;
   }
   else if(policy.max_open_positions > 0 && context.account.open_positions_count >= policy.max_open_positions)
   {
      outDecision.decision    = ELIGIBILITY_DECISION_REJECTED;
      outDecision.reason_code = REASON_RISK_MAX_OPEN_POSITIONS;
   }
   else if(policy.min_margin_level > 0.0 && context.account.margin_level > 0.0 && context.account.margin_level < policy.min_margin_level)
   {
      outDecision.decision    = ELIGIBILITY_DECISION_REJECTED;
      outDecision.reason_code = REASON_RISK_MARGIN;
   }
   else if(context.safe_mode_active)
   {
      outDecision.decision    = ELIGIBILITY_DECISION_REJECTED;
      outDecision.reason_code = REASON_RISK_CIRCUIT_BREAKER;
   }
   else
   {
      outDecision.decision    = ELIGIBILITY_DECISION_ELIGIBLE;
      outDecision.reason_code = REASON_NONE;
   }

   outDecision.eligibility_decision_id = Ids_EligibilityDecisionId(outDecision.candidate_id, outDecision.eligibility_policy_version);
   outDecision.eligibility_decision_hash = EligibilityDecision_ComputeHash(outDecision);

   return true;
}

#endif // __MLQUANTAI_ELIGIBILITYBUILDER_MQH__
