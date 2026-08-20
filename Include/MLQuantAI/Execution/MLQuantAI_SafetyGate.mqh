//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_SafetyGate.mqh                   |
//| Phase C1.2: SafetyGate_Evaluate() - the frozen, ordered gate       |
//| ladder from Docs/PhaseC_C1_1_ExecutionRequestContract.md's C1.2    |
//| addendum. Pure evaluation only: no OrderSend/CTrade/position-      |
//| mutating call anywhere, no candidate.state transition, no          |
//| mutation of ExecutionRequest/ExecutionPolicy/TradeCandidate. _Symbol|
//| and AccountInfoInteger(ACCOUNT_LOGIN) are read-only terminal/       |
//| account queries, not broker mutations - each read exactly once, at |
//| the start of evaluation, and reused as a local value throughout.   |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_SAFETYGATE_MQH__
#define __MLQUANTAI_SAFETYGATE_MQH__

#include "MLQuantAI_ExecutionRequestContract.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_SafeModeState.mqh"

// True if needle appears as a whole, comma-separated entry inside
// haystack (never a bare substring match - "1" must not match inside
// "12345"). Empty haystack never matches anything (the "unconfigured
// means reject, never unlimited" rule from the C1.2 addendum).
bool SafetyGate_AllowlistContains(string haystack, string needle)
{
   if(haystack == "" || needle == "") return false;
   string parts[];
   int n = StringSplit(haystack, ',', parts);
   for(int i = 0; i < n; i++)
   {
      string p = parts[i];
      StringTrimLeft(p);
      StringTrimRight(p);
      if(p == needle) return true;
   }
   return false;
}

// Returns false only on a structural failure (empty execution_request_id) -
// no DryRunExecutionResult is produced at all in that case. Every other
// path returns true, with outResult.decision set to SAFETY_GATE_ACCEPTED
// or SAFETY_GATE_REJECTED and outResult.reason_code set to the specific
// gate that tripped (REASON_NONE on acceptance). Frozen gate order,
// first match wins - see the C1.2 addendum for the full rationale per
// gate.
bool SafetyGate_Evaluate(const ExecutionRequest &request, const ExecutionPolicy &policy, DryRunExecutionResult &outResult)
{
   DryRunExecutionResult_Init(outResult);

   if(request.execution_request_id == "")
      return false;

   outResult.execution_request_id   = request.execution_request_id;
   outResult.execution_request_hash = request.execution_request_hash;

   // Runtime Safety Context - read exactly once, here, reused for the
   // rest of this evaluation.
   string observedSymbol = _Symbol;
   long   observedLogin   = AccountInfoInteger(ACCOUNT_LOGIN);
   outResult.observed_symbol        = observedSymbol;
   outResult.observed_account_login = observedLogin;

   if(!policy.dry_run)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_SUBMIT_DISABLED;
      return true;
   }

   if(SafeMode_IsActive())
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_RISK_CIRCUIT_BREAKER;
      return true;
   }

   if(policy.environment_mode == EXECUTION_ENV_NONE)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED;
      return true;
   }

   if(policy.manual_approval_required)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_MANUAL_APPROVAL_REQUIRED;
      return true;
   }

   if(!SafetyGate_AllowlistContains(policy.account_allowlist, IntegerToString(observedLogin)))
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_ACCOUNT_NOT_ALLOWED;
      return true;
   }

   if(!SafetyGate_AllowlistContains(policy.symbol_allowlist, observedSymbol))
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_SYMBOL_NOT_ALLOWED;
      return true;
   }

   if(request.side != ORDER_TYPE_BUY && request.side != ORDER_TYPE_SELL)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_ORDER_TYPE_NOT_MARKET;
      return true;
   }

   if(policy.max_volume <= 0.0)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_VOLUME_POLICY_INVALID;
      return true;
   }
   if(request.lot_size > policy.max_volume)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_VOLUME_CAP_EXCEEDED;
      return true;
   }

   if(policy.max_planned_risk_amount <= 0.0)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_EXPOSURE_POLICY_INVALID;
      return true;
   }
   if(request.risk_amount > policy.max_planned_risk_amount)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_EXPOSURE_CAP_EXCEEDED;
      return true;
   }

   if(policy.max_deviation_points < 0.0)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_DEVIATION_POLICY_INVALID;
      return true;
   }

   if(request.execution_request_hash != ExecutionRequest_ComputeHash(request))
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_LINEAGE_INVALID;
      return true;
   }

   outResult.decision    = SAFETY_GATE_ACCEPTED;
   outResult.reason_code = REASON_NONE;
   return true;
}

#endif // __MLQUANTAI_SAFETYGATE_MQH__
