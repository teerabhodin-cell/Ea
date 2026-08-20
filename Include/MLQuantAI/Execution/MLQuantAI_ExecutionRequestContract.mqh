//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_ExecutionRequestContract.mqh     |
//| Phase C1.2: ExecutionPolicy (caller-supplied configuration),      |
//| ExecutionRequest (the frozen, immutable execution intent, built    |
//| only from an ELIGIBLE EligibilityDecision), and                    |
//| DryRunExecutionResult (SafetyGate_Evaluate's own verdict). Per     |
//| Docs/PhaseC_C1_1_ExecutionRequestContract.md's C1.2 addendum.      |
//| Deliberately NOT a reuse of the dormant Phase-A/pre-B              |
//| ExecutionResult/ExecutionEvent structs - those assume a real       |
//| broker response (ticket/retcode/fill_price), which C1's dry-run    |
//| never has. Every lineage field on ExecutionRequest is copied       |
//| verbatim from RiskPlan/AIDecision/EligibilityDecision/TradeCandidate|
//| - nothing here recomputes an upstream hash.                        |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EXECUTIONREQUESTCONTRACT_MQH__
#define __MLQUANTAI_EXECUTIONREQUESTCONTRACT_MQH__

#include "../Core/MLQuantAI_CanonicalFormat.mqh"
#include "../Core/MLQuantAI_ContractVersions.mqh"
#include "../Core/MLQuantAI_Ids.mqh"
#include "../Core/MLQuantAI_Enums.mqh"
#include "../Core/MLQuantAI_ReasonCodes.mqh"

// Reserved fields (account_allowlist/symbol_allowlist/max_volume/
// max_planned_risk_amount/max_deviation_points/allowed_order_types)
// ARE enforced by C1.2's SafetyGate - only allowed_order_types stays
// unused in C1.2 (market-only is a hard-coded C1 invariant, not
// policy-driven yet). See the C1.2 addendum's zero-cap semantics
// table: unlike B9's policy thresholds, 0/unset here means
// "unconfigured -> reject", never "unlimited".
struct ExecutionPolicy
{
   string execution_policy_version; // MLQUANTAI_EXECUTION_POLICY_SCHEMA_C1_V1 stamped by _Init, caller sets the real version

   ENUM_EXECUTION_ENVIRONMENT_MODE environment_mode; // TESTER | DEMO | LIVE - EXECUTION_ENV_NONE fails closed
   bool   dry_run;                 // C1.2: MUST be true; false is rejected fail-closed, never overridden
   bool   manual_approval_required;

   string account_allowlist; // comma-separated ACCOUNT_LOGIN values; empty = unconfigured, fails closed
   string symbol_allowlist;  // comma-separated symbols; empty = unconfigured, fails closed
   double max_volume;              // <= 0 = unconfigured, fails closed
   double max_planned_risk_amount; // <= 0 = unconfigured, fails closed (per-trade planned monetary risk cap, NOT notional)
   double max_deviation_points;    // < 0 = unconfigured, fails closed; 0 is a valid explicit zero-deviation policy

   string allowed_order_types; // reserved, unused in C1.2 - market-only is a hard-coded C1 invariant
};

void ExecutionPolicy_Init(ExecutionPolicy &p)
{
   p.execution_policy_version = "";

   p.environment_mode = EXECUTION_ENV_NONE;
   p.dry_run = true;
   p.manual_approval_required = false;

   p.account_allowlist = "";
   p.symbol_allowlist = "";
   p.max_volume = 0.0;
   p.max_planned_risk_amount = 0.0;
   p.max_deviation_points = -1.0;

   p.allowed_order_types = "";
}

// The frozen, immutable execution intent. Built only from an ELIGIBLE
// EligibilityDecision - see ExecutionRequest_Build. Never mutated once
// built: a changed intent means a brand new ExecutionRequest with a
// new identity/hash, never an in-place edit.
struct ExecutionRequest
{
   string execution_request_schema_version; // MLQUANTAI_EXECUTION_REQUEST_SCHEMA_C1_V1

   string execution_request_id;   // identity - Ids_ExecutionRequestId(...)
   string execution_request_hash; // content integrity - see ExecutionRequest_ComputeHash

   // Lineage - every field copied verbatim from its real upstream
   // source, never recomputed here.
   string candidate_id;
   string candidate_hash;
   string risk_plan_id;
   string plan_hash;
   string ai_decision_id;
   string ai_decision_hash;
   string eligibility_decision_id;
   string eligibility_decision_hash;

   string execution_policy_version;

   string correlation_id; // Ids_CorrelationId(candidate_id, submit_attempt)
   int    submit_attempt; // C1.2: always 1, never auto-incremented

   // Order intent - copied verbatim from TradeCandidate/RiskPlan,
   // never recomputed.
   ENUM_ORDER_TYPE side;
   double          planned_entry;
   double          planned_sl;
   double          planned_tp;
   double          lot_size;
   double          risk_amount; // C1.2 addendum: added so the exposure cap has something to check without a separate RiskPlan dependency
};

void ExecutionRequest_Init(ExecutionRequest &r)
{
   r.execution_request_schema_version = MLQUANTAI_EXECUTION_REQUEST_SCHEMA_C1_V1;

   r.execution_request_id = "";
   r.execution_request_hash = "";

   r.candidate_id = "";
   r.candidate_hash = "";
   r.risk_plan_id = "";
   r.plan_hash = "";
   r.ai_decision_id = "";
   r.ai_decision_hash = "";
   r.eligibility_decision_id = "";
   r.eligibility_decision_hash = "";

   r.execution_policy_version = "";

   r.correlation_id = "";
   r.submit_attempt = 0;

   r.side = ORDER_TYPE_BUY;
   r.planned_entry = 0;
   r.planned_sl = 0;
   r.planned_tp = 0;
   r.lot_size = 0;
   r.risk_amount = 0;
}

// Excludes execution_request_id (identity, not content) and
// execution_request_schema_version (the struct's own top-level schema
// stamp), matching the RiskPlan/AIDecision/EligibilityDecision default.
string ExecutionRequest_HashPayload(const ExecutionRequest &r)
{
   return r.candidate_id + "|" +
          r.candidate_hash + "|" +
          r.risk_plan_id + "|" +
          r.plan_hash + "|" +
          r.ai_decision_id + "|" +
          r.ai_decision_hash + "|" +
          r.eligibility_decision_id + "|" +
          r.eligibility_decision_hash + "|" +
          r.execution_policy_version + "|" +
          r.correlation_id + "|" +
          IntegerToString(r.submit_attempt) + "|" +
          (r.side == ORDER_TYPE_BUY ? "BUY" : "SELL") + "|" +
          CanonicalPrice(r.planned_entry) + "|" +
          CanonicalPrice(r.planned_sl) + "|" +
          CanonicalPrice(r.planned_tp) + "|" +
          CanonicalDouble(r.lot_size) + "|" +
          CanonicalDouble(r.risk_amount);
}

string ExecutionRequest_ComputeHash(const ExecutionRequest &r)
{
   return Ids_Sha256Hex(ExecutionRequest_HashPayload(r));
}

// SafetyGate_Evaluate's own verdict. observed_symbol/observed_account_login
// are Runtime Safety Context evidence recorded for traceability only -
// never fed into execution_request_id/execution_request_hash, never
// used to mutate ExecutionRequest/TradeCandidate. No ticket/retcode/
// fill_price/slippage_points field anywhere - this is not a broker
// response.
struct DryRunExecutionResult
{
   string dry_run_result_schema_version; // MLQUANTAI_DRY_RUN_RESULT_SCHEMA_C1_V1

   string execution_request_id;   // verbatim - links back to the request
   string execution_request_hash; // verbatim

   ENUM_SAFETY_GATE_DECISION decision;
   ENUM_REASON_CODE          reason_code;

   string observed_symbol;         // _Symbol at evaluation time - audit evidence only
   long   observed_account_login;  // AccountInfoInteger(ACCOUNT_LOGIN) at evaluation time - audit evidence only
};

void DryRunExecutionResult_Init(DryRunExecutionResult &d)
{
   d.dry_run_result_schema_version = MLQUANTAI_DRY_RUN_RESULT_SCHEMA_C1_V1;

   d.execution_request_id = "";
   d.execution_request_hash = "";

   d.decision = SAFETY_GATE_NONE;
   d.reason_code = REASON_NONE;

   d.observed_symbol = "";
   d.observed_account_login = 0;
}

#endif // __MLQUANTAI_EXECUTIONREQUESTCONTRACT_MQH__
