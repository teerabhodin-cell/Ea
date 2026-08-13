//+------------------------------------------------------------------+
//| MLQuantAI_Test_DeterministicId.mq5                               |
//| Phase A Step 8 requires a standalone DeterministicIdTest          |
//| (previously this coverage only existed embedded inside            |
//| MLQuantAI_Test_DummyLifecycle.mq5). Proves root_event_id/          |
//| candidate_id/correlation_id are pure functions of their inputs -   |
//| calling them twice with identical inputs must produce identical   |
//| output, and different inputs must (in practice) produce different |
//| output. No Event Store, no file I/O.                              |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Core/MLQuantAI_Ids.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void OnStart()
{
   Print("=== MLQuantAI Test: Deterministic IDs (Phase A) ===");

   datetime anchor = D'2026.08.14 09:30';

   // ---- root_event_id: same inputs -> same id, every time ----
   string r1 = Ids_RootEventId("XAUUSD", "M15", "SWEEP_LOW", 3345.20, anchor, 2);
   string r2 = Ids_RootEventId("XAUUSD", "M15", "SWEEP_LOW", 3345.20, anchor, 2);
   string r3 = Ids_RootEventId("XAUUSD", "M15", "SWEEP_LOW", 3345.20, anchor, 2);
   Check(r1 != "" && r1 == r2 && r2 == r3, "Ids_RootEventId: identical inputs called 3x produce identical id");

   // ---- Changing ANY one input field must change the id ----
   string rDiffSymbol = Ids_RootEventId("EURUSD", "M15", "SWEEP_LOW", 3345.20, anchor, 2);
   string rDiffTf      = Ids_RootEventId("XAUUSD", "H1",  "SWEEP_LOW", 3345.20, anchor, 2);
   string rDiffType     = Ids_RootEventId("XAUUSD", "M15", "SWEEP_HIGH", 3345.20, anchor, 2);
   string rDiffPrice    = Ids_RootEventId("XAUUSD", "M15", "SWEEP_LOW", 3345.25, anchor, 2);
   string rDiffTime     = Ids_RootEventId("XAUUSD", "M15", "SWEEP_LOW", 3345.20, anchor + 60, 2);
   Check(rDiffSymbol != r1, "changing symbol changes root_event_id");
   Check(rDiffTf != r1,      "changing timeframe tag changes root_event_id");
   Check(rDiffType != r1,    "changing event type changes root_event_id");
   Check(rDiffPrice != r1,   "changing price changes root_event_id");
   Check(rDiffTime != r1,    "changing anchor time changes root_event_id");

   // ---- candidate_id: same root + strategy + version -> same id ----
   string c1 = Ids_CandidateId(r1, "CRT", "V1");
   string c2 = Ids_CandidateId(r1, "CRT", "V1");
   Check(c1 != "" && c1 == c2, "Ids_CandidateId: identical inputs produce identical id");

   string cDiffStrategy = Ids_CandidateId(r1, "SMC", "V1");
   string cDiffVersion   = Ids_CandidateId(r1, "CRT", "V2");
   string cDiffRoot       = Ids_CandidateId(rDiffSymbol, "CRT", "V1");
   Check(cDiffStrategy != c1, "changing strategy tag changes candidate_id");
   Check(cDiffVersion != c1,   "changing strategy version changes candidate_id");
   Check(cDiffRoot != c1,       "changing root_event_id changes candidate_id");

   // Same root_event_id shared by two strategies (the whole point of
   // root_event_id: CRT and SMC seeing the same sweep should be able to
   // find each other via a shared root, while still getting distinct
   // candidate_ids for their own candidates).
   Check(Ids_CandidateId(r1, "SMC", "V1") == Ids_CandidateId(r1, "SMC", "V1"),
         "two candidates from the same root_event_id + same strategy collide correctly (same candidate)");

   // ---- correlation_id: same candidate + attempt -> same id ----
   string corr1 = Ids_CorrelationId(c1, 1);
   string corr2 = Ids_CorrelationId(c1, 1);
   string corrRetry = Ids_CorrelationId(c1, 2);
   Check(corr1 != "" && corr1 == corr2, "Ids_CorrelationId: identical inputs produce identical id");
   Check(corrRetry != corr1, "a different submit attempt number changes correlation_id");

   // ---- runtime_session_id: intentionally NOT deterministic ----
   // (identifies one specific run, not a repeatable market event) - two
   // calls back to back should still differ.
   string s1 = Ids_NewRuntimeSessionId();
   string s2 = Ids_NewRuntimeSessionId();
   Check(s1 != "" && s2 != "" && s1 != s2, "Ids_NewRuntimeSessionId is NOT deterministic (two calls differ, by design)");

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   Print(g_TestsPassed == g_TestsRun ? "ALL PASS." : "FAILURES ABOVE.");
}
