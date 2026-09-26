//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BoundedAutomationAdmissibility.mqh|
//| C5.2 §6.3 Design Contract Rev.15 (FROZEN, commit 07a3581),          |
//| §2.3.1 static admissibility (D3, D4; precision notes P-1, P-2, P-4). |
//| R15-A slice.                                                        |
//|                                                                    |
//| ADMISSIBLE(X) iff ALL of:                                           |
//|  (a) >= 1 dry-run record for X, and EVERY one is                     |
//|      SAFETY_GATE_ACCEPTED (P-4)                                      |
//|  (b) X.lot_size <= max_lot_size_per_submission (R2 hard ceiling,     |
//|      exact comparison - no tolerance widens it; P-c)                 |
//|  (c) every such record's observed_symbol is in symbol_allowlist      |
//|      (R8 = runtime _Symbol) (P-1)                                    |
//|  (d) strategy_allowlist non-empty -> candidate strategy_id in it,    |
//|      lookup failure -> inadmissible; "" -> no restriction, no lookup |
//|      (P-2)                                                           |
//|  (e) NOT FIXTURE: NOT (M1 OR M2) (D4)                                |
//| Inadmissible -> the discovery scan SKIPS X, never stops (§2.3.1a).   |
//|                                                                    |
//| Pure read: sealed DryRunResultProjection / CandidateProjection       |
//| accessors and the caller's validated snapshot. No write of any kind, |
//| no OrderSend, no C2 gate.                                            |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BOUNDEDAUTOMATIONADMISSIBILITY_MQH__
#define __MLQUANTAI_BOUNDEDAUTOMATIONADMISSIBILITY_MQH__

#include "MLQuantAI_BoundedAutomationContract.mqh"
#include "MLQuantAI_BoundedAutomationPolicy.mqh"
#include "MLQuantAI_ExecutionAuditProjection.mqh"
#include "MLQuantAI_SafetyGate.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_CeremonyCommandEventEmission.mqh"

enum ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY
{
   BOUNDED_AUTOMATION_ADMISSIBLE,
   BOUNDED_AUTOMATION_INADMISSIBLE_NO_DRY_RUN_RECORD,     // (a)
   BOUNDED_AUTOMATION_INADMISSIBLE_DRY_RUN_NOT_ACCEPTED,  // (a) / P-4
   BOUNDED_AUTOMATION_INADMISSIBLE_LOT_ABOVE_MAX,         // (b)
   BOUNDED_AUTOMATION_INADMISSIBLE_SYMBOL_NOT_ALLOWED,    // (c) / P-1
   BOUNDED_AUTOMATION_INADMISSIBLE_STRATEGY_LOOKUP_FAILED,// (d) / P-2
   BOUNDED_AUTOMATION_INADMISSIBLE_STRATEGY_NOT_ALLOWED,  // (d)
   BOUNDED_AUTOMATION_INADMISSIBLE_FIXTURE_M1,            // (e) policy literal
   BOUNDED_AUTOMATION_INADMISSIBLE_FIXTURE_M2             // (e) RUN_C22 ceremony line
};

string BoundedAutomationAdmissibility_ToString(ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a)
{
   switch(a)
   {
      case BOUNDED_AUTOMATION_ADMISSIBLE:                          return "ADMISSIBLE";
      case BOUNDED_AUTOMATION_INADMISSIBLE_NO_DRY_RUN_RECORD:      return "NO_DRY_RUN_RECORD";
      case BOUNDED_AUTOMATION_INADMISSIBLE_DRY_RUN_NOT_ACCEPTED:   return "DRY_RUN_NOT_ACCEPTED";
      case BOUNDED_AUTOMATION_INADMISSIBLE_LOT_ABOVE_MAX:          return "LOT_ABOVE_MAX";
      case BOUNDED_AUTOMATION_INADMISSIBLE_SYMBOL_NOT_ALLOWED:     return "SYMBOL_NOT_ALLOWED";
      case BOUNDED_AUTOMATION_INADMISSIBLE_STRATEGY_LOOKUP_FAILED: return "STRATEGY_LOOKUP_FAILED";
      case BOUNDED_AUTOMATION_INADMISSIBLE_STRATEGY_NOT_ALLOWED:   return "STRATEGY_NOT_ALLOWED";
      case BOUNDED_AUTOMATION_INADMISSIBLE_FIXTURE_M1:             return "FIXTURE_M1";
      case BOUNDED_AUTOMATION_INADMISSIBLE_FIXTURE_M2:             return "FIXTURE_M2";
   }
   return "UNKNOWN";
}

// M1 (D4): the request carries the reserved fixture policy literal.
bool BoundedAutomation_IsFixtureM1(const ExecutionRequestProjectionRecord &request)
{
   return request.execution_policy_version == MLQUANTAI_RESERVED_FIXTURE_EXECUTION_POLICY_VERSION;
}

// M2 (D4): the validated snapshot holds a CEREMONY_COMMAND_STATE_CHANGED
// line with command_type RUN_C22_CEREMONY_FIXTURE naming this request.
// A RUN_C22 line with an empty execution_request_id never matches.
bool BoundedAutomation_IsFixtureM2(const string &validatedLines[], string executionRequestId)
{
   if(executionRequestId == "")
      return false;
   string stateType   = EventTypeToString(EVENT_TYPE_CEREMONY_COMMAND_STATE_CHANGED);
   string fixtureType = CeremonyCommandType_ToString(CEREMONY_COMMAND_TYPE_RUN_C22_CEREMONY_FIXTURE);
   int n = ArraySize(validatedLines);
   for(int i = 0; i < n; i++)
   {
      if(EventSerializer_GetStr(validatedLines[i], "type") != stateType) continue;
      if(EventSerializer_GetStr(validatedLines[i], "command_type") != fixtureType) continue;
      if(EventSerializer_GetStr(validatedLines[i], "execution_request_id") == executionRequestId)
         return true;
   }
   return false;
}

//---------------------------------------------------------------------
// ADMISSIBLE(X). Returns the FIRST failing condition in contract order
// (a) (b) (c) (d) (e), or BOUNDED_AUTOMATION_ADMISSIBLE. The caller skips
// on anything but ADMISSIBLE. Every input is immutable durable data, so
// the answer for a given X never changes between invocations.
//---------------------------------------------------------------------
ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY BoundedAutomation_CheckAdmissible(const ExecutionRequestProjectionRecord &request,
                                                                        const string &validatedLines[],
                                                                        const BoundedAutomationPolicy &policy)
{
   // (a) + (c) in one pass over the sealed dry-run projection (no by-id accessor exists)
   int  recordsForRequest = 0;
   bool anyNotAccepted    = false;
   bool anySymbolRejected = false;
   int  dryRunCount = DryRunResultProjection_Count();
   for(int i = 0; i < dryRunCount; i++)
   {
      DryRunResultProjectionRecord rec;
      if(!DryRunResultProjection_GetAt(i, rec)) continue;
      if(rec.execution_request_id != request.execution_request_id) continue;
      recordsForRequest++;
      if(rec.decision != SAFETY_GATE_ACCEPTED)
         anyNotAccepted = true;
      if(!SafetyGate_AllowlistContains(policy.symbol_allowlist, rec.observed_symbol))
         anySymbolRejected = true;
   }
   if(recordsForRequest == 0)
      return BOUNDED_AUTOMATION_INADMISSIBLE_NO_DRY_RUN_RECORD;
   if(anyNotAccepted)
      return BOUNDED_AUTOMATION_INADMISSIBLE_DRY_RUN_NOT_ACCEPTED;

   // (b) - R2 is a hard ceiling: lot_size > 0.01 is inadmissible, with
   // no tolerance of any size (P-c). Float representation error can only
   // make this reject, never admit, a value above the ceiling.
   if(request.lot_size > policy.max_lot_size_per_submission)
      return BOUNDED_AUTOMATION_INADMISSIBLE_LOT_ABOVE_MAX;

   // (c)
   if(anySymbolRejected)
      return BOUNDED_AUTOMATION_INADMISSIBLE_SYMBOL_NOT_ALLOWED;

   // (d) - an EMPTY strategy_allowlist means "no restriction" (R8/P-2). It
   // must never reach SafetyGate_AllowlistContains(), which reads an empty
   // list as "reject everything" (MLQuantAI_SafetyGate.mqh:17-24).
   if(policy.strategy_allowlist != "")
   {
      CandidateProjectionRecord candidate;
      if(!CandidateProjection_TryGet(request.candidate_id, candidate))
         return BOUNDED_AUTOMATION_INADMISSIBLE_STRATEGY_LOOKUP_FAILED;
      if(!SafetyGate_AllowlistContains(policy.strategy_allowlist, StrategyIdToString(candidate.strategy_id)))
         return BOUNDED_AUTOMATION_INADMISSIBLE_STRATEGY_NOT_ALLOWED;
   }

   // (e)
   if(BoundedAutomation_IsFixtureM1(request))
      return BOUNDED_AUTOMATION_INADMISSIBLE_FIXTURE_M1;
   if(BoundedAutomation_IsFixtureM2(validatedLines, request.execution_request_id))
      return BOUNDED_AUTOMATION_INADMISSIBLE_FIXTURE_M2;

   return BOUNDED_AUTOMATION_ADMISSIBLE;
}

#endif // __MLQUANTAI_BOUNDEDAUTOMATIONADMISSIBILITY_MQH__
