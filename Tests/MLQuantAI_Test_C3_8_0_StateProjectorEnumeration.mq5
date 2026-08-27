//+------------------------------------------------------------------+
//| MLQuantAI_Test_C3_8_0_StateProjectorEnumeration.mq5                |
//| C3.8.0 implementation DoD. Exercises the real production entry    |
//| points StateProjector_Count()/StateProjector_GetAt() directly, per|
//| the design locked at Checkpoints 1/2. Behavioral coverage through |
//| the public API only - this file proves NOTHING about sealed-file  |
//| byte-diffs (that proof belongs in the Checkpoint 3 git-based      |
//| evidence package, per the user's explicit correction, not inside  |
//| an MQL5 test).                                                    |
//|                                                                    |
//| Every fixture is built via the existing, sealed                   |
//| StateProjector_Apply() entry point - this file never writes       |
//| g_Proj_Candidates[]/g_Proj_Count directly, since that would test   |
//| internal storage instead of the public state-projector contract.  |
//| Every test function calls StateProjector_Reset() at its own start |
//| and end, so no test can leak state into the next one (or into any |
//| other suite that happens to run in the same terminal session).    |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_StateProjector.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - build LifecycleEvents and feed them through the
// real, sealed StateProjector_Apply() entry point. Never touch
// g_Proj_Candidates[]/g_Proj_Count directly.
//---------------------------------------------------------------------

LifecycleEvent BuildGenesis(string candidateId, int strategyId, string rootEventId, long seq)
{
   LifecycleEvent e;
   LifecycleEvent_Init(e);
   e.base.sequence_number = seq;
   e.candidate_id = candidateId;
   e.root_event_id = rootEventId;
   e.strategy_id = strategyId;
   e.from_state = CANDIDATE_CREATED;
   e.to_state = CANDIDATE_CREATED;
   return e;
}

LifecycleEvent BuildTransition(string candidateId, ENUM_CANDIDATE_STATE from, ENUM_CANDIDATE_STATE to,
                                string correlationId, long seq)
{
   LifecycleEvent e;
   LifecycleEvent_Init(e);
   e.base.sequence_number = seq;
   e.candidate_id = candidateId;
   e.from_state = from;
   e.to_state = to;
   e.correlation_id = correlationId;
   return e;
}

//---------------------------------------------------------------------
// 1. Empty registry and invalid indices.
//---------------------------------------------------------------------
void Test_EmptyRegistry_CountZero_GetAtAlwaysFalse()
{
   Print("--- Test_EmptyRegistry_CountZero_GetAtAlwaysFalse ---");
   StateProjector_Reset();

   Check(StateProjector_Count() == 0, "empty registry: Count() == 0");

   ProjectedCandidate out;
   Check(!StateProjector_GetAt(0, out),   "empty registry: GetAt(0) == false");
   Check(!StateProjector_GetAt(-1, out),  "empty registry: GetAt(-1) == false");
   Check(!StateProjector_GetAt(5, out),   "empty registry: GetAt(5) == false (large positive on empty)");

   StateProjector_Reset();
}

//---------------------------------------------------------------------
// 2. Bounds at -1, 0, N-1, N, and a large positive index.
//---------------------------------------------------------------------
void Test_Bounds_NegativeZeroLastPastEndLargePositive()
{
   Print("--- Test_Bounds_NegativeZeroLastPastEndLargePositive ---");
   StateProjector_Reset();

   string err;
   Check(StateProjector_Apply(BuildGenesis("CAND_A", 1, "ROOT_A", 1), err), "setup: CAND_A genesis applied");
   Check(StateProjector_Apply(BuildGenesis("CAND_B", 2, "ROOT_B", 2), err), "setup: CAND_B genesis applied");
   Check(StateProjector_Apply(BuildGenesis("CAND_C", 3, "ROOT_C", 3), err), "setup: CAND_C genesis applied");

   int n = StateProjector_Count();
   Check(n == 3, "Count() == 3 after three genesis applications");

   ProjectedCandidate out;
   Check(!StateProjector_GetAt(-1, out),        "GetAt(-1) == false");
   Check(StateProjector_GetAt(0, out) && out.candidate_id == "CAND_A", "GetAt(0) valid, first candidate");
   Check(StateProjector_GetAt(n - 1, out) && out.candidate_id == "CAND_C", "GetAt(N-1) valid, last candidate");
   Check(!StateProjector_GetAt(n, out),          "GetAt(N) == false (one past end)");
   Check(!StateProjector_GetAt(1000000, out),    "GetAt(large positive) == false");

   StateProjector_Reset();
}

//---------------------------------------------------------------------
// 3. Count reflects real StateProjector_Apply()-created records.
//---------------------------------------------------------------------
void Test_Count_TracksRealAppliedRecords()
{
   Print("--- Test_Count_TracksRealAppliedRecords ---");
   StateProjector_Reset();

   string err;
   Check(StateProjector_Count() == 0, "Count() == 0 before any Apply()");

   StateProjector_Apply(BuildGenesis("CAND_ONE", 1, "ROOT_ONE", 1), err);
   Check(StateProjector_Count() == 1, "Count() == 1 after first genesis");

   StateProjector_Apply(BuildGenesis("CAND_TWO", 2, "ROOT_TWO", 2), err);
   Check(StateProjector_Count() == 2, "Count() == 2 after second genesis");

   // A transition on an EXISTING candidate must not change Count() - only
   // new genesis events grow the registry.
   StateProjector_Apply(BuildTransition("CAND_ONE", CANDIDATE_CREATED, CANDIDATE_SUBMITTED, "", 3), err);
   Check(StateProjector_Count() == 2, "Count() unchanged (still 2) after a transition on an existing candidate");

   StateProjector_Reset();
}

//---------------------------------------------------------------------
// 4. Stable insertion ordering.
//---------------------------------------------------------------------
void Test_InsertionOrdering_Stable()
{
   Print("--- Test_InsertionOrdering_Stable ---");
   StateProjector_Reset();

   string err;
   StateProjector_Apply(BuildGenesis("CAND_X", 10, "ROOT_X", 1), err);
   StateProjector_Apply(BuildGenesis("CAND_Y", 20, "ROOT_Y", 2), err);
   StateProjector_Apply(BuildGenesis("CAND_Z", 30, "ROOT_Z", 3), err);

   ProjectedCandidate out;
   Check(StateProjector_GetAt(0, out) && out.candidate_id == "CAND_X", "GetAt(0) == CAND_X (first inserted)");
   Check(StateProjector_GetAt(1, out) && out.candidate_id == "CAND_Y", "GetAt(1) == CAND_Y (second inserted)");
   Check(StateProjector_GetAt(2, out) && out.candidate_id == "CAND_Z", "GetAt(2) == CAND_Z (third inserted)");

   StateProjector_Reset();
}

//---------------------------------------------------------------------
// 5. Full five-field record fidelity, cross-checked against
//    StateProjector_TryGetState() independently.
//---------------------------------------------------------------------
void Test_RecordFidelity_AllFiveFields()
{
   Print("--- Test_RecordFidelity_AllFiveFields ---");
   StateProjector_Reset();

   string err;
   StateProjector_Apply(BuildGenesis("CAND_FID", 42, "ROOT_FID", 1), err);
   StateProjector_Apply(BuildTransition("CAND_FID", CANDIDATE_CREATED, CANDIDATE_SUBMITTED, "CORR_FID", 2), err);

   ProjectedCandidate out;
   bool found = StateProjector_GetAt(0, out);
   Check(found, "GetAt(0) returns the one candidate applied");
   Check(out.candidate_id == "CAND_FID",   "field fidelity: candidate_id");
   Check(out.state == CANDIDATE_SUBMITTED, "field fidelity: state");
   Check(out.strategy_id == 42,            "field fidelity: strategy_id");
   Check(out.root_event_id == "ROOT_FID",  "field fidelity: root_event_id");
   Check(out.correlation_id == "CORR_FID", "field fidelity: correlation_id");

   ENUM_CANDIDATE_STATE crossCheckState;
   bool haveState = StateProjector_TryGetState("CAND_FID", crossCheckState);
   Check(haveState && crossCheckState == out.state,
         "GetAt's state agrees with TryGetState's independently-reported state");

   StateProjector_Reset();
}

//---------------------------------------------------------------------
// 6. Caller mutation of returned `out` cannot alter the stored registry
//    record - proven by mutating a first copy, then re-fetching the same
//    index and confirming the second copy is unaffected.
//---------------------------------------------------------------------
void Test_CallerMutation_DoesNotAlterRegistry()
{
   Print("--- Test_CallerMutation_DoesNotAlterRegistry ---");
   StateProjector_Reset();

   string err;
   StateProjector_Apply(BuildGenesis("CAND_MUT", 7, "ROOT_MUT", 1), err);

   ProjectedCandidate first;
   Check(StateProjector_GetAt(0, first), "first GetAt(0) succeeds");

   // Mutate every field of the returned copy.
   first.candidate_id   = "TAMPERED";
   first.state           = CANDIDATE_EXECUTED;
   first.strategy_id     = 999;
   first.root_event_id   = "TAMPERED_ROOT";
   first.correlation_id  = "TAMPERED_CORR";

   ProjectedCandidate second;
   Check(StateProjector_GetAt(0, second), "second GetAt(0) succeeds");
   Check(second.candidate_id == "CAND_MUT",   "registry candidate_id unaffected by caller mutation");
   Check(second.state == CANDIDATE_CREATED,   "registry state unaffected by caller mutation");
   Check(second.strategy_id == 7,             "registry strategy_id unaffected by caller mutation");
   Check(second.root_event_id == "ROOT_MUT",  "registry root_event_id unaffected by caller mutation");
   Check(second.correlation_id == "",         "registry correlation_id unaffected by caller mutation");

   StateProjector_Reset();
}

//---------------------------------------------------------------------
// 7. Live transition visibility: the SAME index reflects a state
//    transition applied after the first GetAt() call, not a stale
//    snapshot taken at genesis time.
//---------------------------------------------------------------------
void Test_LiveTransitionVisibility_SameIndex()
{
   Print("--- Test_LiveTransitionVisibility_SameIndex ---");
   StateProjector_Reset();

   string err;
   StateProjector_Apply(BuildGenesis("CAND_LIVE", 1, "ROOT_LIVE", 1), err);

   ProjectedCandidate beforeTransition;
   Check(StateProjector_GetAt(0, beforeTransition), "GetAt(0) succeeds before transition");
   Check(beforeTransition.state == CANDIDATE_CREATED, "state == CREATED before transition");

   Check(StateProjector_Apply(BuildTransition("CAND_LIVE", CANDIDATE_CREATED, CANDIDATE_SUBMITTED, "", 2), err),
         "CREATED -> SUBMITTED transition applied");

   ProjectedCandidate afterTransition;
   Check(StateProjector_GetAt(0, afterTransition), "GetAt(0) succeeds after transition, same index");
   Check(afterTransition.state == CANDIDATE_SUBMITTED,
         "state == SUBMITTED after transition - GetAt reads live registry state, not a cached copy");

   StateProjector_Reset();
}

//---------------------------------------------------------------------
// 8. Reset clears the visible enumeration surface.
//---------------------------------------------------------------------
void Test_Reset_ClearsEnumerationSurface()
{
   Print("--- Test_Reset_ClearsEnumerationSurface ---");
   StateProjector_Reset();

   string err;
   StateProjector_Apply(BuildGenesis("CAND_R1", 1, "ROOT_R1", 1), err);
   StateProjector_Apply(BuildGenesis("CAND_R2", 2, "ROOT_R2", 2), err);
   Check(StateProjector_Count() == 2, "setup: Count() == 2 before Reset()");

   StateProjector_Reset();

   Check(StateProjector_Count() == 0, "Count() == 0 immediately after Reset()");
   ProjectedCandidate out;
   Check(!StateProjector_GetAt(0, out), "GetAt(0) == false after Reset() - index that was valid before is not now");
   Check(!StateProjector_GetAt(1, out), "GetAt(1) == false after Reset()");

   StateProjector_Reset();
}

void OnStart()
{
   Print("=== MLQuantAI C3.8.0 StateProjector enumeration accessor test ===");

   Test_EmptyRegistry_CountZero_GetAtAlwaysFalse();
   Test_Bounds_NegativeZeroLastPastEndLargePositive();
   Test_Count_TracksRealAppliedRecords();
   Test_InsertionOrdering_Stable();
   Test_RecordFidelity_AllFiveFields();
   Test_CallerMutation_DoesNotAlterRegistry();
   Test_LiveTransitionVisibility_SameIndex();
   Test_Reset_ClearsEnumerationSurface();

   Print(StringFormat("=== Result: %d/%d checks passed ===", g_TestsPassed, g_TestsRun));
   if(g_TestsRun > 0 && g_TestsPassed == g_TestsRun)
      Print("ALL PASS.");
   else
      Print("FAILURES PRESENT - review the [FAIL] lines above.");
}
