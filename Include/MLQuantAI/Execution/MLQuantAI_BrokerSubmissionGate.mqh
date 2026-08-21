//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BrokerSubmissionGate.mqh         |
//| Phase C2.2: the final pre-submit safety re-validation from        |
//| Docs/PhaseC_C2_1_BrokerSubmissionContract.md - every C1.2 gate,    |
//| re-run FRESH via the sealed, unmodified SafetyGate_Evaluate()      |
//| (never trusted from the earlier ACCEPTED dry-run evaluation, which |
//| may be stale by the time this actually runs), PLUS the real        |
//| ACCOUNT_TRADE_MODE_DEMO cross-check and an in-session idempotency  |
//| check. This file never edits MLQuantAI_SafetyGate.mqh - C1.2's own |
//| gate stays exactly as PASSED and sealed; this is a strictly        |
//| additive layer on top. Pure evaluation only: no OrderSend/CTrade/  |
//| position-mutating call anywhere, no candidate.state transition, no |
//| mutation of ExecutionRequest/ExecutionPolicy/TradeCandidate.       |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BROKERSUBMISSIONGATE_MQH__
#define __MLQUANTAI_BROKERSUBMISSIONGATE_MQH__

#include "MLQuantAI_SafetyGate.mqh"

// In-session idempotency registry: execution_request_ids that have
// already crossed this gate and been handed to a real submission
// attempt. Deliberately session-scoped only (matches
// ExecutionSubmissionResult.request_id's own session-scoped nature) -
// C2.2 has no durable idempotency store, and submit_attempt never
// auto-increments (no retry logic), so a second attempt at the same
// execution_request_id within one session can only be a bug, never a
// legitimate resubmission.
string g_BrokerSubmissionGate_AttemptedIds[];

void BrokerSubmissionGate_Reset()
{
   ArrayResize(g_BrokerSubmissionGate_AttemptedIds, 0);
}

bool BrokerSubmissionGate_HasAlreadyAttempted(string executionRequestId)
{
   int n = ArraySize(g_BrokerSubmissionGate_AttemptedIds);
   for(int i = 0; i < n; i++)
      if(g_BrokerSubmissionGate_AttemptedIds[i] == executionRequestId)
         return true;
   return false;
}

// Called only after a real submission attempt has actually been made
// (EXECUTION_SUBMISSION_ATTEMPTED durably logged) - a gate rejection
// must never mark an id as attempted, since nothing was attempted.
void BrokerSubmissionGate_MarkAttempted(string executionRequestId)
{
   int n = ArraySize(g_BrokerSubmissionGate_AttemptedIds);
   ArrayResize(g_BrokerSubmissionGate_AttemptedIds, n + 1);
   g_BrokerSubmissionGate_AttemptedIds[n] = executionRequestId;
}

// Returns false only on the same structural failure SafetyGate_Evaluate
// itself defines (empty execution_request_id) - no outResult is
// produced at all in that case, same "no partial record" rule C1.2
// already froze. Every other path returns true, with outResult set
// exactly as SafetyGate_Evaluate would have set it, UNLESS the
// inherited gate itself already ACCEPTED - only then are the two C2-
// owned checks (real account-mode, idempotency) evaluated, in that
// order, each capable of overriding an ACCEPTED verdict to REJECTED.
// Reuses REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED (account-mode
// failure - environment permission is exactly what this reason already
// means) and REASON_DUPLICATE_EVENT (idempotency failure - a repeat
// execution_request_id is exactly a duplicate submission attempt) -
// zero new ENUM_REASON_CODE values, per the frozen C2.1 contract.
bool BrokerSubmissionGate_Evaluate(const ExecutionRequest &request, const ExecutionPolicy &policy, DryRunExecutionResult &outResult)
{
   if(!SafetyGate_Evaluate(request, policy, outResult))
      return false;

   if(outResult.decision != SAFETY_GATE_ACCEPTED)
      return true; // inherited gate already rejected - its reason_code stands, unchanged

   // Both sides of the environment claim must agree, exact match only -
   // per the frozen "Environment authorization" section:
   // ExecutionPolicy.environment_mode == EXECUTION_ENV_LIVE is explicitly
   // rejected fail-closed even if the real account happens to be DEMO,
   // and EXECUTION_ENV_TESTER is explicitly NOT granted real submission
   // authority in C2.2 (Strategy Tester's own ACCOUNT_TRADE_MODE
   // interaction is unverified) - only EXECUTION_ENV_DEMO paired with a
   // real ACCOUNT_TRADE_MODE_DEMO account passes. Any mismatch between
   // the two is exactly the "policy/runtime mismatch of any kind" the
   // contract names as fail-closed.
   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(policy.environment_mode != EXECUTION_ENV_DEMO || tradeMode != ACCOUNT_TRADE_MODE_DEMO)
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED;
      return true;
   }

   if(BrokerSubmissionGate_HasAlreadyAttempted(request.execution_request_id))
   {
      outResult.decision    = SAFETY_GATE_REJECTED;
      outResult.reason_code = REASON_DUPLICATE_EVENT;
      return true;
   }

   return true; // outResult stays ACCEPTED, exactly as SafetyGate_Evaluate produced it
}

#endif // __MLQUANTAI_BROKERSUBMISSIONGATE_MQH__
