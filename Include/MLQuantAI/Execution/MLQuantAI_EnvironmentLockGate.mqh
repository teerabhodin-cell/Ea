//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_EnvironmentLockGate.mqh          |
//| C2 environment-lock checklist (frozen, per                        |
//| Docs/PhaseC_C2_EnvironmentLockChecklist.md): the final,             |
//| consolidated re-verification pass before a real OrderSend call      |
//| would ever be authorized. Chains the already-sealed                 |
//| BrokerSubmissionGate_Evaluate() FIRST (inherits every C1.2 gate,     |
//| the real account-mode cross-check, the durable-audit-readiness       |
//| check, and both idempotency checks unchanged) - never re-implements  |
//| any of that. Adds ONLY the checklist items no earlier gate covers:   |
//| trade-server allowlist, terminal/account/expert trade permission,    |
//| and a fresh broker-side minimum-volume floor.                        |
//|                                                                       |
//| Pure evaluation only: no OrderSend/CTrade/position-mutating call      |
//| anywhere, no candidate.state transition, no event append, no          |
//| OnTradeTransaction, no broker history/position/order query. Every     |
//| new check here reads only TerminalInfoInteger/AccountInfoInteger/     |
//| AccountInfoString/SymbolInfoDouble - all read-only.                   |
//|                                                                       |
//| THIRD AMENDMENT (C2 manual-approval contract, gate integration        |
//| round): adds a sixth check, after the original five, per               |
//| Docs/PhaseC_C2_ManualApprovalContract.md's "C2 gate integration" and   |
//| "Approval timing boundary" sections - manual-approval registry         |
//| readiness, then a single captured asOf, then                          |
//| ManualApprovalRegistry_HasValidApproval() against all five identity    |
//| fields. Mandatory and unconditional, independent of                    |
//| ExecutionPolicy.manual_approval_required's own value (that field       |
//| stays a sealed C1 concern, untouched). Does NOT re-check                |
//| SubmissionAttemptRegistry_HasAttempt() here - that is already           |
//| mandatory and already ran earlier in this same evaluation, inherited   |
//| from BrokerSubmissionGate_Evaluate below - see the contract doc's      |
//| "Approval scope and gate order" section.                                |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ENVIRONMENTLOCKGATE_MQH__
#define __MLQUANTAI_ENVIRONMENTLOCKGATE_MQH__

#include "MLQuantAI_BrokerSubmissionGate.mqh"
#include "MLQuantAI_EnvironmentLockContract.mqh"
#include "MLQuantAI_ManualApprovalReadiness.mqh"

// Pure(ish): assumes outResult already carries an ACCEPTED verdict from
// every earlier gate (the caller's responsibility, exactly as
// BrokerSubmissionEnvironmentLock_Evaluate below does it) - never calls
// BrokerSubmissionGate_Evaluate itself, so this is exercisable by the
// automated suite with fabricated ExecutionRequest/EnvironmentLockPolicy
// inputs regardless of which account mode the real terminal happens to
// be on when compiling (unlike the full chained entry point below,
// which a non-DEMO test terminal would always reject on environment
// before ever reaching these checks - split out for the same reason
// BrokerSubmission_ProcessSendResult was split from BrokerSubmission_
// Submit in C2.2's own first amendment). Evaluates this file's own five
// new checks, in this fixed order, each capable of overriding an
// ACCEPTED verdict to REJECTED. First-match-wins, same discipline every
// earlier gate in this project already follows.
bool EnvironmentLock_EvaluateNewChecks(const ExecutionRequest &request, const EnvironmentLockPolicy &lockPolicy, DryRunExecutionResult &outResult)
{
   string observedServer = AccountInfoString(ACCOUNT_SERVER);
   if(!SafetyGate_AllowlistContains(lockPolicy.trade_server_allowlist, observedServer))
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_SERVER_NOT_ALLOWED;
      return true;
   }

   if(!(bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_TERMINAL_TRADE_DISABLED;
      return true;
   }

   if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_ACCOUNT_TRADE_DISABLED;
      return true;
   }

   if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_EXPERT_TRADE_DISABLED;
      return true;
   }

   // A fresh, live re-check against the real broker's own current
   // minimum - deliberately re-read here rather than trusted from
   // RiskSizing's own earlier volume_min check (Core/MLQuantAI_RiskSizing.mqh),
   // which happened at signal time and may be stale by now - same
   // "never trust an earlier evaluation" rule every other C2 check
   // already follows for account mode/symbol/gates.
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(minVolume > 0.0 && request.lot_size < minVolume)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_VOLUME_BELOW_MINIMUM;
      return true;
   }

   // Sixth check, third amendment: manual-approval registry readiness,
   // then a single captured asOf, then HasValidApproval() against all
   // five identity fields - see this file's own header for the frozen
   // ordering/timing rules this implements.
   if(!ManualApprovalReadiness_IsReady())
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_AUDIT_NOT_READY;
      return true;
   }

   datetime asOf = TimeCurrent();
   if(asOf <= 0)
   {
      // MQL5 does not document TimeCurrent()'s return value for a
      // terminal that has never connected/received a quote - treated
      // as the same "cannot be trusted" condition as an unready
      // registry, same defensive pattern BrokerSubmission_
      // BuildTradeRequest already uses for bid <= 0.0 || ask <= 0.0.
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_AUDIT_NOT_READY;
      return true;
   }

   if(!ManualApprovalRegistry_HasValidApproval(request.execution_request_id, request.execution_request_hash,
                                                 request.execution_policy_version, request.candidate_id,
                                                 request.correlation_id, asOf))
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED;
      return true;
   }

   return true; // outResult stays ACCEPTED
}

// Returns false only on the same structural failure BrokerSubmissionGate_
// Evaluate/SafetyGate_Evaluate themselves define (empty
// execution_request_id) - no outResult produced at all in that case.
// Every other path returns true, with outResult set exactly as
// BrokerSubmissionGate_Evaluate produced it, UNLESS that inherited
// verdict is already ACCEPTED - only then does EnvironmentLock_
// EvaluateNewChecks run. This is the only function in this file that
// calls BrokerSubmissionGate_Evaluate - the real-world entry point.
bool BrokerSubmissionEnvironmentLock_Evaluate(const ExecutionRequest &request, const ExecutionPolicy &policy,
                                                const EnvironmentLockPolicy &lockPolicy, DryRunExecutionResult &outResult)
{
   if(!BrokerSubmissionGate_Evaluate(request, policy, outResult))
      return false;

   if(outResult.decision != SAFETY_GATE_ACCEPTED)
      return true; // an earlier gate already rejected - its reason_code stands, unchanged

   return EnvironmentLock_EvaluateNewChecks(request, lockPolicy, outResult);
}

#endif // __MLQUANTAI_ENVIRONMENTLOCKGATE_MQH__
