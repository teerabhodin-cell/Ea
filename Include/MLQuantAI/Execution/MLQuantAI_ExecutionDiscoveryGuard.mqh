//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_ExecutionDiscoveryGuard.mqh      |
//| C6.2/C6.3 Wave 1 implementation: Two-Layer Discovery Model        |
//| (frozen chat-history contracts, no separate Docs/ file yet).      |
//|                                                                    |
//| Layer A (session registry, memory-only) exists because Model B is |
//| confirmed: EventStore_LogSystem() never touches projection arrays |
//| live - Layer B alone cannot see this session's own writes. Layer  |
//| B (ExecutionRequestProjection, durable) exists because Layer A is |
//| memory-only and vanishes on restart. Neither substitutes for the  |
//| other (C6.3 section 3).                                           |
//|                                                                    |
//| The ONLY authorized wrapper around ExecutionRequest_EmitAndEvaluate|
//| in this project - every call site must go through                 |
//| ExecutionDiscovery_Resolve() first, then, only on                  |
//| EXEC_DISCOVERY_MISSING, ExecutionDiscovery_EmitAndRegister().      |
//| Registration into Layer A happens unconditionally after the        |
//| EmitAndEvaluate() call, regardless of its return value (C6.3       |
//| section 5 invariant 3) - a false return can still mean the         |
//| EXECUTION_REQUEST_CREATED line is already durable, so re-invoking  |
//| for the same identity would risk the same-ID-different-hash        |
//| collision that fails BrokerSubmissionAuditReadiness for the whole  |
//| session (C6.2 section 5).                                          |
//|                                                                    |
//| No submission authority, no candidate-lifecycle transition, no     |
//| OrderSend/CTrade/BrokerSubmission_Submit call anywhere in this      |
//| file - out of scope per the frozen C6 Wave 1 authorization.         |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EXECUTIONDISCOVERYGUARD_MQH__
#define __MLQUANTAI_EXECUTIONDISCOVERYGUARD_MQH__

#include "MLQuantAI_ExecutionAuditProjection.mqh"
#include "MLQuantAI_ExecutionRequestEventEmission.mqh"

//---------------------------------------------------------------------
// Layer A - in-session emission registry. Memory-only, reset every
// OnInit (a fresh process has no prior-session Layer A knowledge -
// Layer B is what carries history across restart, per C6.3 section 3).
//---------------------------------------------------------------------
string g_ExecDiscovery_SessionIds[];
int    g_ExecDiscovery_SessionCount = 0;

void ExecutionDiscoverySession_Reset()
{
   ArrayResize(g_ExecDiscovery_SessionIds, 0);
   g_ExecDiscovery_SessionCount = 0;
}

int ExecutionDiscoverySession_Count() { return g_ExecDiscovery_SessionCount; }

bool ExecutionDiscoverySession_Contains(string executionRequestId)
{
   for(int i = 0; i < g_ExecDiscovery_SessionCount; i++)
      if(g_ExecDiscovery_SessionIds[i] == executionRequestId)
         return true;
   return false;
}

// Idempotent: registering an id already present, or an empty id (never
// a real identity - guards against a caller ever polluting the
// registry with a failed-build sentinel), is a no-op. Called
// unconditionally after every EmitAndEvaluate() invocation - see
// ExecutionDiscovery_EmitAndRegister() below.
void ExecutionDiscoverySession_Register(string executionRequestId)
{
   if(executionRequestId == "") return;
   if(ExecutionDiscoverySession_Contains(executionRequestId)) return;

   int idx = g_ExecDiscovery_SessionCount;
   ArrayResize(g_ExecDiscovery_SessionIds, idx + 1);
   g_ExecDiscovery_SessionIds[idx] = executionRequestId;
   g_ExecDiscovery_SessionCount++;
}

//---------------------------------------------------------------------
// Resolution outcome - what the discovery check found, before any
// decision about emission is made by the caller.
//---------------------------------------------------------------------
enum ENUM_EXEC_DISCOVERY_RESOLUTION
{
   EXEC_DISCOVERY_FOUND_SESSION,   // Layer A - already emitted (or attempted) this session
   EXEC_DISCOVERY_FOUND_DURABLE,   // Layer B - durable record from this or a prior session
   EXEC_DISCOVERY_MISSING          // neither - eligible to cross the emission boundary
};

struct ExecutionDiscoveryResult
{
   ENUM_EXEC_DISCOVERY_RESOLUTION   resolution;
   ExecutionRequestProjectionRecord durable_record; // valid only when resolution == EXEC_DISCOVERY_FOUND_DURABLE
};

void ExecutionDiscoveryResult_Init(ExecutionDiscoveryResult &r)
{
   r.resolution = EXEC_DISCOVERY_MISSING;
   ExecutionRequestProjectionRecord_Init(r.durable_record);
}

// The discovery half of "discover-before-emit" (C6.3 section 4). Pure
// read - no EventStore write. The caller must derive
// executionRequestId via the pure Ids_* chain (candidate/eligibility/
// AI/risk-plan identity + policy-version strings only - see C6.2
// section 3 / C6.3 section 2) BEFORE calling this - no live balance
// read, and no FeatureSnapshot/RiskPlan/AIDecision/EligibilityDecision/
// ExecutionRequest content build, is required to resolve discovery.
// Layer A checked first (cheapest, in-memory); Layer B checked only if
// Layer A misses.
void ExecutionDiscovery_Resolve(string executionRequestId, ExecutionDiscoveryResult &out)
{
   ExecutionDiscoveryResult_Init(out);

   if(ExecutionDiscoverySession_Contains(executionRequestId))
   {
      out.resolution = EXEC_DISCOVERY_FOUND_SESSION;
      return;
   }

   ExecutionRequestProjectionRecord rec;
   if(ExecutionRequestProjection_TryGet(executionRequestId, rec))
   {
      out.resolution = EXEC_DISCOVERY_FOUND_DURABLE;
      out.durable_record = rec;
      return;
   }

   out.resolution = EXEC_DISCOVERY_MISSING;
}

// The emission half. Callers MUST only reach this after
// ExecutionDiscovery_Resolve() returned EXEC_DISCOVERY_MISSING for
// request.execution_request_id - never called speculatively, never
// called a second time for the same identity within the same session
// (C6.3 section 5 invariant 3). Wraps the sealed C1.2
// ExecutionRequest_EmitAndEvaluate() exactly once, then registers into
// Layer A UNCONDITIONALLY - including when this function returns false
// - because a false return does not mean nothing was written (see
// ExecutionRequestEventEmission.mqh's own "no partial record" /
// failure-mode rule: EXECUTION_REQUEST_CREATED can already be durable
// even when the subsequent EXECUTION_DRY_RUN_COMPLETED write fails).
bool ExecutionDiscovery_EmitAndRegister(const ExecutionRequest &request, const ExecutionPolicy &policy,
                                          DryRunExecutionResult &outResult)
{
   bool ok = ExecutionRequest_EmitAndEvaluate(request, policy, outResult);
   ExecutionDiscoverySession_Register(request.execution_request_id);
   return ok;
}

#endif // __MLQUANTAI_EXECUTIONDISCOVERYGUARD_MQH__
