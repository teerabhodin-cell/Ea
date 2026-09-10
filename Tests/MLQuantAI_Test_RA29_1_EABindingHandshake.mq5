//+------------------------------------------------------------------+
//| MLQuantAI_Test_RA29_1_EABindingHandshake.mq5                      |
//| RA-29.1 (QA-frozen contract, amended after CONDITIONAL PASS        |
//| review): Ceremony EventStore Binding Integrity. Regression coverage|
//| for the handshake mechanism added to MLQuantAI.mq5 (OnInit:        |
//| publish a fresh per-OnInit nonce - a persistent, monotonically-    |
//| increasing counter scoped per EventStore filename, NOT a timestamp |
//| - under GlobalVariableTemp("MLQuantAI_EABinding__" + fileName),    |
//| which never persists across a terminal restart) and                |
//| Tests/MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5 (OnStart:         |
//| preflight check of that binding before EventStore_Open()/any      |
//| Candidate/lineage generation).                                    |
//|                                                                    |
//| Known, inherent limitation (disclosed, not hidden): MQL5 cannot    |
//| #include one .mq5 from another .mq5 - only .mqh headers. Neither   |
//| MLQuantAI.mq5's OnInit nor the smoke test script's OnStart can be  |
//| invoked directly from here. This file therefore duplicates the     |
//| exact preflight algorithm (RA29_1_Preflight) and the exact nonce   |
//| publish sequence (RA29_1_SimulateOnInitPublish, RA-29.1 amendment: |
//| a persistent, monotonically-increasing counter per filename - NOT  |
//| the earlier TimeLocal()/GetTickCount() formula, which this file's  |
//| own first run proved could collide) as pure, parameterized         |
//| functions and tests THOSE - it validates the algorithm as          |
//| specified, not the deployed .mq5 files byte-for-byte. Keep this    |
//| file's copies in lockstep with the two real files by inspection on |
//| any future change to either.                                      |
//|                                                                    |
//| Safety: every GlobalVariable this file touches uses a test-only    |
//| filename ("RA29_1_TEST_FILE_*.jsonl") that can never collide with  |
//| the real canonical ceremony filename                                |
//| (MLQuantAI_SmokeTest_C2_2.jsonl) or its real binding variable - so  |
//| running this test can never clobber a real EA instance's live      |
//| RA-29.1 binding, even if one happens to be attached on the same     |
//| terminal at the same time. Every variable this file creates is     |
//| cleaned up (GlobalVariableDel) after use.                          |
//|                                                                    |
//| No OrderSend, no EventStore core, no Candidate/lineage, no C2.1/   |
//| C2.2/C2.3, no C3.2, no Entry Compatibility Gate, no RiskSizing -    |
//| this file only ever touches MQL5's own GlobalVariable* API.        |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

// This build's GlobalVariableTemp() CREATES the variable as temporary -
// it does not just flip a flag on one that already exists. Found
// empirically (real EA run, 2026.09.10): calling GlobalVariableSet()
// first, then GlobalVariableTemp(), fails every time, because
// GlobalVariableTemp() then finds a variable with that name already
// exists. The correct order, mirrored here from the fix applied to
// MLQuantAI.mq5's OnInit: delete any leftover first (best-effort), let
// GlobalVariableTemp() create it fresh as temporary, then
// GlobalVariableSet() assigns the value onto that already-temporary
// variable.
bool PublishTestBinding(string name, double value)
{
   GlobalVariableDel(name); // best-effort: clear any leftover before (re)creating fresh
   return GlobalVariableTemp(name) && (GlobalVariableSet(name, value) != 0);
}

//---------------------------------------------------------------------
// Exact duplicate of the preflight block in
// Tests/MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5 (RA-29.1), refactored
// into a pure, parameterized function so it can be exercised here
// without a real EA or a real ceremony run.
//---------------------------------------------------------------------
bool RA29_1_Preflight(string canonicalFile, double expectedNonce, string &outReason)
{
   string bindingName = "MLQuantAI_EABinding__" + canonicalFile;
   if(expectedNonce <= 0.0)
   {
      outReason = "missing nonce (<=0)";
      return false;
   }
   if(!GlobalVariableCheck(bindingName))
   {
      outReason = "missing binding";
      return false;
   }
   double actual = GlobalVariableGet(bindingName);
   if(actual != expectedNonce)
   {
      outReason = "nonce mismatch";
      return false;
   }
   outReason = "PASS";
   return true;
}

//---------------------------------------------------------------------
// Exact duplicate of the RA-29.1 amendment's publish sequence in
// MLQuantAI.mq5's OnInit (QA-authorized, replacing the earlier
// TimeLocal()/GetTickCount() formula this file's own first regression
// run proved could collide): reads the per-filename counter (0 if it
// has never existed), writes back current+1, and publishes that
// strictly-larger value as the binding's nonce - both the counter
// write and the binding publish (delete-leftover -> Temp -> Set, same
// ordering fix as PublishTestBinding above) must succeed. Returns the
// published nonce, or 0.0 if anything failed.
//---------------------------------------------------------------------
double RA29_1_SimulateOnInitPublish(string canonicalFile)
{
   string counterName = "MLQuantAI_EABindingCounter__" + canonicalFile;
   string bindingName = "MLQuantAI_EABinding__" + canonicalFile;
   double counter = GlobalVariableCheck(counterName) ? GlobalVariableGet(counterName) : 0.0;
   double nonce    = counter + 1.0;
   if(GlobalVariableSet(counterName, nonce) == 0) return 0.0;
   if(!PublishTestBinding(bindingName, nonce)) return 0.0;
   return nonce;
}

void OnStart()
{
   Print("=== RA-29.1 EA Binding Handshake - regression test ===");

   // Defensive: clean up any residue from a previous crashed/aborted run
   // of this exact test file before starting, so every case below runs
   // against a known-clean, test-only namespace.
   string testFiles[] = {"RA29_1_TEST_FILE_A.jsonl", "RA29_1_TEST_FILE_B.jsonl", "RA29_1_TEST_FILE_C.jsonl",
                          "RA29_1_TEST_FILE_D.jsonl", "RA29_1_TEST_FILE_E.jsonl", "RA29_1_TEST_FILE_F1.jsonl",
                          "RA29_1_TEST_FILE_F2.jsonl"};
   for(int i = 0; i < ArraySize(testFiles); i++)
   {
      GlobalVariableDel("MLQuantAI_EABinding__" + testFiles[i]);
      GlobalVariableDel("MLQuantAI_EABindingCounter__" + testFiles[i]);
   }

   string reason;
   bool result;

   // --- RA29.1-A: missing nonce (<=0) -> ABORT, no progression ---------
   result = RA29_1_Preflight("RA29_1_TEST_FILE_A.jsonl", 0.0, reason);
   Check(!result && reason == "missing nonce (<=0)", "RA29.1-A: expectedNonce=0.0 -> ABORT (missing nonce)");
   result = RA29_1_Preflight("RA29_1_TEST_FILE_A.jsonl", -5.0, reason);
   Check(!result && reason == "missing nonce (<=0)", "RA29.1-A: expectedNonce=-5.0 -> ABORT (missing nonce)");

   // --- RA29.1-B: expected nonce > 0, but no binding exists -> ABORT ---
   GlobalVariableDel("MLQuantAI_EABinding__RA29_1_TEST_FILE_B.jsonl"); // ensure absent
   result = RA29_1_Preflight("RA29_1_TEST_FILE_B.jsonl", 12345.0, reason);
   Check(!result && reason == "missing binding", "RA29.1-B: no binding published for this file -> ABORT (missing binding)");

   // --- RA29.1-C: binding exists but actual != expected -> ABORT -------
   PublishTestBinding("MLQuantAI_EABinding__RA29_1_TEST_FILE_C.jsonl", 111.0);
   result = RA29_1_Preflight("RA29_1_TEST_FILE_C.jsonl", 222.0, reason);
   Check(!result && reason == "nonce mismatch", "RA29.1-C: binding=111.0, expected=222.0 -> ABORT (nonce mismatch)");
   GlobalVariableDel("MLQuantAI_EABinding__RA29_1_TEST_FILE_C.jsonl");

   // --- RA29.1-D: binding exists and actual == expected -> PASS --------
   PublishTestBinding("MLQuantAI_EABinding__RA29_1_TEST_FILE_D.jsonl", 999.0);
   result = RA29_1_Preflight("RA29_1_TEST_FILE_D.jsonl", 999.0, reason);
   Check(result && reason == "PASS", "RA29.1-D: binding=999.0, expected=999.0 -> PASS");
   GlobalVariableDel("MLQuantAI_EABinding__RA29_1_TEST_FILE_D.jsonl");

   // --- RA29.1-E: fresh OnInit nonce differs from previous instance ----
   // RA-29.1 amendment (QA-authorized): reproduces QA's exact required
   // acceptance scenario - "same terminal, same EventStore filename,
   // OnInit #1 -> nonce #1, OnInit #2 -> nonce #2, #2 must not accept
   // #1" - using the REAL production publish sequence
   // (RA29_1_SimulateOnInitPublish), not arbitrary literals. This is a
   // deterministic property of the monotonic counter, not a timing-
   // dependent sanity check.
   GlobalVariableDel("MLQuantAI_EABindingCounter__RA29_1_TEST_FILE_E.jsonl");
   GlobalVariableDel("MLQuantAI_EABinding__RA29_1_TEST_FILE_E.jsonl");

   double nonceInstance1 = RA29_1_SimulateOnInitPublish("RA29_1_TEST_FILE_E.jsonl"); // simulated OnInit #1 (e.g. first EA attach)
   result = RA29_1_Preflight("RA29_1_TEST_FILE_E.jsonl", nonceInstance1, reason);
   Check(result && reason == "PASS", "RA29.1-E: instance #1's own nonce passes against instance #1's binding");

   double nonceInstance2 = RA29_1_SimulateOnInitPublish("RA29_1_TEST_FILE_E.jsonl"); // simulated OnInit #2 (e.g. EA restarted)
   Check(nonceInstance2 > nonceInstance1,
         "RA29.1-E: instance #2's nonce is strictly greater than instance #1's (deterministic, not probabilistic)");

   result = RA29_1_Preflight("RA29_1_TEST_FILE_E.jsonl", nonceInstance1, reason);
   Check(!result && reason == "nonce mismatch",
         "RA29.1-E: instance #1's now-stale nonce is REJECTED against instance #2's current binding");

   result = RA29_1_Preflight("RA29_1_TEST_FILE_E.jsonl", nonceInstance2, reason);
   Check(result && reason == "PASS", "RA29.1-E: instance #2's current nonce is ACCEPTED");

   double nonceInstance3 = RA29_1_SimulateOnInitPublish("RA29_1_TEST_FILE_E.jsonl"); // simulated OnInit #3 - confirm the counter keeps advancing, not a one-off increment
   Check(nonceInstance3 > nonceInstance2,
         "RA29.1-E: instance #3's nonce is strictly greater than instance #2's (counter keeps advancing across repeated restarts)");

   GlobalVariableDel("MLQuantAI_EABindingCounter__RA29_1_TEST_FILE_E.jsonl");
   GlobalVariableDel("MLQuantAI_EABinding__RA29_1_TEST_FILE_E.jsonl");

   // --- RA29.1-F: binding is filename-scoped --------------------------
   // A binding published for one filename must NOT be found when the
   // preflight looks up a DIFFERENT filename, even with the matching
   // nonce value.
   GlobalVariableDel("MLQuantAI_EABinding__RA29_1_TEST_FILE_F2.jsonl"); // ensure absent
   PublishTestBinding("MLQuantAI_EABinding__RA29_1_TEST_FILE_F1.jsonl", 555.0);
   result = RA29_1_Preflight("RA29_1_TEST_FILE_F2.jsonl", 555.0, reason);
   Check(!result && reason == "missing binding",
         "RA29.1-F: binding published under FILE_F1 is NOT found when looking up FILE_F2 (different filename), "
         "even with the matching nonce value");
   // Confirm the SAME binding DOES pass under its own, correct filename -
   // proves the ABORT above was because of the filename mismatch
   // specifically, not some other defect.
   result = RA29_1_Preflight("RA29_1_TEST_FILE_F1.jsonl", 555.0, reason);
   Check(result && reason == "PASS", "RA29.1-F: the same binding DOES pass under its own correct filename (FILE_F1)");
   GlobalVariableDel("MLQuantAI_EABinding__RA29_1_TEST_FILE_F1.jsonl");

   // Final cleanup - leave no test-only globals behind.
   for(int i = 0; i < ArraySize(testFiles); i++)
   {
      GlobalVariableDel("MLQuantAI_EABinding__" + testFiles[i]);
      GlobalVariableDel("MLQuantAI_EABindingCounter__" + testFiles[i]);
   }

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else Print("SOME CHECKS FAILED - see [FAIL] lines above.");
}
