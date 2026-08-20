//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_EligibilityContract.mqh          |
//| Phase B9 Commit 1: EligibilityContext (live-state snapshot, no     |
//| identity of its own - see the contract doc), EligibilityPolicy     |
//| (the explicit, versioned threshold input), and EligibilityDecision |
//| (the frozen output record), per                                    |
//| Docs/PhaseB_B9_ExecutionEligibilityContract.md. Every lineage/hash  |
//| field on EligibilityDecision is copied verbatim from RiskPlan/      |
//| AIDecision/EligibilityContext - nothing here recomputes an          |
//| upstream hash.                                                      |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ELIGIBILITYCONTRACT_MQH__
#define __MLQUANTAI_ELIGIBILITYCONTRACT_MQH__

#include "../Core/MLQuantAI_CanonicalFormat.mqh"
#include "../Core/MLQuantAI_ContractVersions.mqh"
#include "../Core/MLQuantAI_Ids.mqh"
#include "../Core/MLQuantAI_Enums.mqh"
#include "../Core/MLQuantAI_ReasonCodes.mqh"
#include "../Core/MLQuantAI_AccountSnapshot.mqh"

// A live-state snapshot, captured once by the CALLER before invoking
// EligibilityDecision_Build (never read live from inside the builder
// itself). No eligibility_context_id - see the contract doc's
// "Identity and hash" section for why a per-candidate identity would
// break this project's own collision-detection idiom here (the same
// candidate is legitimately re-evaluated multiple times, with
// genuinely different account state each time).
struct EligibilityContext
{
   string          eligibility_context_schema_version; // MLQUANTAI_ELIGIBILITY_CONTEXT_SCHEMA_B9_V1
   string          eligibility_context_hash;            // content hash - see EligibilityContext_HashPayload

   AccountSnapshot account;          // Phase A struct, embedded verbatim
   bool            safe_mode_active; // captured from SafeMode_IsActive() by the CALLER
};

void EligibilityContext_Init(EligibilityContext &c)
{
   c.eligibility_context_schema_version = MLQUANTAI_ELIGIBILITY_CONTEXT_SCHEMA_B9_V1;
   c.eligibility_context_hash = "";
   AccountSnapshot_Init(c.account);
   c.safe_mode_active = false;
}

// Deliberately INCLUDES account - a departure from RiskContext_HashPayload's
// own precedent (which excludes account because RiskContext's hash
// answers "same sizing rule set", never "same plan"). EligibilityContext's
// entire purpose is the opposite: it IS the audit evidence of the live
// account/safe-mode state at decision time, so excluding account would
// defeat the struct's only reason to exist. See the contract doc.
// eligibility_context_schema_version excluded (own top-level schema
// stamp), matching the project's default precedent.
string EligibilityContext_HashPayload(const EligibilityContext &c)
{
   return CanonicalDouble(c.account.balance) + "|" +
          CanonicalDouble(c.account.equity) + "|" +
          CanonicalDouble(c.account.margin_level) + "|" +
          IntegerToString(c.account.open_positions_count) + "|" +
          CanonicalDouble(c.account.open_risk_percent) + "|" +
          CanonicalDouble(c.account.daily_pnl_percent) + "|" +
          CanonicalDouble(c.account.drawdown_from_peak_percent) + "|" +
          (c.safe_mode_active ? "true" : "false");
}

string EligibilityContext_ComputeHash(const EligibilityContext &c)
{
   return Ids_Sha256Hex(EligibilityContext_HashPayload(c));
}

// The minimal, explicit, versioned policy input EligibilityDecision_Build
// requires - no implicit default anywhere.
// max_daily_loss_percent/max_drawdown_percent/max_total_exposure_percent
// in [0,100]; max_open_positions in [0, INT_MAX]; min_margin_level in
// [0, +inf). Zero means "this gate is disabled", not "reject everything"
// - required because account.daily_pnl_percent/.drawdown_from_peak_percent/
// .open_risk_percent are still hard-coded 0 in live population today
// (see the contract doc's collision check) - treating 0 as a real,
// enforced threshold would reject every candidate the moment any of
// those three gates is turned on.
struct EligibilityPolicy
{
   string eligibility_policy_version;

   double max_daily_loss_percent;
   double max_drawdown_percent;
   double max_total_exposure_percent;
   int    max_open_positions;
   double min_margin_level;
};

void EligibilityPolicy_Init(EligibilityPolicy &p)
{
   p.eligibility_policy_version = "";
   p.max_daily_loss_percent = 0.0;
   p.max_drawdown_percent = 0.0;
   p.max_total_exposure_percent = 0.0;
   p.max_open_positions = 0;
   p.min_margin_level = 0.0;
}

struct EligibilityDecision
{
   string eligibility_decision_schema_version; // MLQUANTAI_ELIGIBILITY_DECISION_SCHEMA_B9_V1

   string eligibility_decision_id;   // identity - Ids_EligibilityDecisionId(candidate_id, eligibility_policy_version)
   string eligibility_decision_hash; // content integrity - see EligibilityDecision_ComputeHash

   string candidate_id;   // copied verbatim from RiskPlan (cross-checked against AIDecision/FeatureSnapshot)
   string candidate_hash; // copied verbatim from RiskPlan (cross-checked against AIDecision/FeatureSnapshot)

   string risk_plan_id; // copied verbatim from RiskPlan
   string plan_hash;    // copied verbatim from RiskPlan

   string ai_decision_id;   // copied verbatim from AIDecision
   string ai_decision_hash; // copied verbatim from AIDecision

   string eligibility_context_hash;   // copied verbatim from EligibilityContext
   string eligibility_policy_version; // from the supplied EligibilityPolicy

   ENUM_ELIGIBILITY_DECISION decision;
   ENUM_REASON_CODE          reason_code;
};

void EligibilityDecision_Init(EligibilityDecision &d)
{
   d.eligibility_decision_schema_version = MLQUANTAI_ELIGIBILITY_DECISION_SCHEMA_B9_V1;

   d.eligibility_decision_id = "";
   d.eligibility_decision_hash = "";

   d.candidate_id = "";
   d.candidate_hash = "";

   d.risk_plan_id = "";
   d.plan_hash = "";

   d.ai_decision_id = "";
   d.ai_decision_hash = "";

   d.eligibility_context_hash = "";
   d.eligibility_policy_version = "";

   d.decision = ELIGIBILITY_DECISION_NONE;
   d.reason_code = REASON_NONE;
}

// Excludes eligibility_decision_id (identity, not content) and
// eligibility_decision_schema_version (the struct's own top-level
// schema stamp), matching the RiskPlan/TrainingDatasetRow/AIDecision
// default.
string EligibilityDecision_HashPayload(const EligibilityDecision &d)
{
   return d.candidate_id + "|" +
          d.candidate_hash + "|" +
          d.risk_plan_id + "|" +
          d.plan_hash + "|" +
          d.ai_decision_id + "|" +
          d.ai_decision_hash + "|" +
          d.eligibility_context_hash + "|" +
          d.eligibility_policy_version + "|" +
          EligibilityDecisionToString(d.decision) + "|" +
          ReasonCodeToString(d.reason_code);
}

string EligibilityDecision_ComputeHash(const EligibilityDecision &d)
{
   return Ids_Sha256Hex(EligibilityDecision_HashPayload(d));
}

#endif // __MLQUANTAI_ELIGIBILITYCONTRACT_MQH__
