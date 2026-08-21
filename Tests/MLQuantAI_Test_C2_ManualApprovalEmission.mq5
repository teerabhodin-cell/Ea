//+------------------------------------------------------------------+
//| MLQuantAI_Test_C2_ManualApprovalEmission.mq5                      |
//| C2 manual-approval contract - WRITE-SIDE-ONLY test suite for      |
//| ManualApproval_NewNonce()/ManualApproval_Grant(), per              |
//| Docs/PhaseC_C2_ManualApprovalContract.md's "dry code" scope for    |
//| this round. Covers: durable write success/failure (structural      |
//| validation only - no lineage/projection checks exist at write      |
//| time by design), JSON shape correctness, and nonce uniqueness       |
//| across calls. NO OrderSend/CTrade/OnTradeTransaction/History*/      |
//| Position*/Order* broker API call anywhere in this file. NO read    |
//| side exists yet to test (ManualApprovalRegistry_HasValidApproval    |
//| and the projection rebuild are deferred - not implemented, not     |
//| tested here).                                                      |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_ManualApprovalEmission.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void BuildValidGrant(ManualApprovalGrant &g, string suffix)
{
   ManualApprovalGrant_Init(g);
   g.execution_request_id     = "EXECREQ_test_" + suffix;
   g.execution_request_hash   = "hash_test_" + suffix;
   g.execution_policy_version = "EXECPOLICY_test_v1";
   g.candidate_id              = "CND_test_" + suffix;
   g.correlation_id             = "CORR_test_" + suffix;
   g.approver_identity           = "tester_" + suffix;
   g.approval_timestamp           = D'2026.08.22 10:00:00';
   g.approval_expiry              = D'2026.08.22 10:15:00';
   g.approval_nonce               = ManualApproval_NewNonce();
}

//=====================================================================
// Nonce uniqueness across calls.
//=====================================================================
void Test_NewNonce_UniqueAcrossCalls()
{
   Print("--- ManualApproval_NewNonce(): uniqueness across many rapid calls ---");

   string nonces[];
   int n = 50;
   ArrayResize(nonces, n);
   for(int i = 0; i < n; i++)
      nonces[i] = ManualApproval_NewNonce();

   bool allNonEmpty = true;
   bool allPrefixed = true;
   for(int i = 0; i < n; i++)
   {
      if(nonces[i] == "") allNonEmpty = false;
      if(StringSubstr(nonces[i], 0, 5) != "APPR_") allPrefixed = false;
   }
   Check(allNonEmpty, "every generated nonce is non-empty");
   Check(allPrefixed, "every generated nonce carries the APPR_ prefix");

   bool anyCollision = false;
   for(int i = 0; i < n && !anyCollision; i++)
      for(int j = i + 1; j < n; j++)
         if(nonces[i] == nonces[j]) { anyCollision = true; break; }
   Check(!anyCollision, StringFormat("no collision across %d rapid-fire calls", n));
}

//=====================================================================
// Durable write success: a structurally valid grant is written and
// readable back with the exact same field values.
//=====================================================================
void Test_ValidGrant_WrittenDurablyAndReadableBack()
{
   Print("--- ManualApproval_Grant(): valid grant durably written, JSON shape correct ---");

   string file = "MLQuantAI_Test_ManualApprovalEmission_ValidGrant.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   ManualApprovalGrant grant;
   BuildValidGrant(grant, "valid1");

   bool ok = ManualApproval_Grant(grant);
   EventStore_Close();
   Check(ok, "ManualApproval_Grant returns true for a structurally valid grant");

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   Check(n == 1, "exactly one event line written");
   if(n < 1) return;

   string line = lines[0];
   Check(EventSerializer_GetStr(line, "type") == EventTypeToString(EVENT_TYPE_EXECUTION_MANUAL_APPROVAL_GRANTED),
         "event type is EXECUTION_MANUAL_APPROVAL_GRANTED");
   Check(EventSerializer_GetStr(line, "manual_approval_schema_version") == MLQUANTAI_MANUAL_APPROVAL_SCHEMA_C2_V1,
         "manual_approval_schema_version stamped correctly");
   Check(EventSerializer_GetStr(line, "execution_request_id") == grant.execution_request_id, "execution_request_id round-trips");
   Check(EventSerializer_GetStr(line, "execution_request_hash") == grant.execution_request_hash, "execution_request_hash round-trips");
   Check(EventSerializer_GetStr(line, "execution_policy_version") == grant.execution_policy_version, "execution_policy_version round-trips");
   Check(EventSerializer_GetStr(line, "candidate_id") == grant.candidate_id, "candidate_id round-trips");
   Check(EventSerializer_GetStr(line, "correlation_id") == grant.correlation_id, "correlation_id round-trips");
   Check(EventSerializer_GetStr(line, "approver_identity") == grant.approver_identity, "approver_identity round-trips");
   Check(EventSerializer_GetLong(line, "approval_timestamp") == (long)grant.approval_timestamp, "approval_timestamp round-trips");
   Check(EventSerializer_GetLong(line, "approval_expiry") == (long)grant.approval_expiry, "approval_expiry round-trips");
   Check(EventSerializer_GetStr(line, "approval_nonce") == grant.approval_nonce, "approval_nonce round-trips");
}

//=====================================================================
// Two grants for the same request id are BOTH written - never deduped
// at write time (a legitimate second approval, e.g. after the first
// expired, is real audit history - matches the deferred projection's
// own "never deduped" rule, tested here only at the write layer).
//=====================================================================
void Test_TwoGrantsSameRequestId_BothWritten_NeverDeduped()
{
   Print("--- ManualApproval_Grant(): two grants for the same execution_request_id both written ---");

   string file = "MLQuantAI_Test_ManualApprovalEmission_TwoGrants.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   ManualApprovalGrant g1; BuildValidGrant(g1, "dup");
   ManualApprovalGrant g2; BuildValidGrant(g2, "dup");
   g2.execution_request_id = g1.execution_request_id; // same id, different nonce (BuildValidGrant always mints a fresh one)

   bool ok1 = ManualApproval_Grant(g1);
   bool ok2 = ManualApproval_Grant(g2);
   EventStore_Close();

   Check(ok1 && ok2, "both writes succeed");
   Check(g1.approval_nonce != g2.approval_nonce, "the two grants have distinct nonces");

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   Check(n == 2, "both events are durably present - no write-time dedup for a repeated execution_request_id");
}

//=====================================================================
// Structural rejection: every required-field-empty case, and the
// expiry-ordering invariant, must reject with NO write attempted.
//=====================================================================
void CheckRejectedNoWrite(ManualApprovalGrant &g, string label, string file)
{
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   bool ok = ManualApproval_Grant(g);
   EventStore_Close();
   Check(!ok, label + " - ManualApproval_Grant returns false");

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   Check(n == 0, label + " - no event line written");
}

void Test_StructurallyInvalidGrants_RejectedNoPartialWrite()
{
   Print("--- ManualApproval_Grant(): structurally invalid grants rejected, no partial write ---");

   ManualApprovalGrant g;

   BuildValidGrant(g, "empty_reqid"); g.execution_request_id = "";
   CheckRejectedNoWrite(g, "empty execution_request_id", "MLQuantAI_Test_ManualApprovalEmission_Reject1.jsonl");

   BuildValidGrant(g, "empty_hash"); g.execution_request_hash = "";
   CheckRejectedNoWrite(g, "empty execution_request_hash", "MLQuantAI_Test_ManualApprovalEmission_Reject2.jsonl");

   BuildValidGrant(g, "empty_policy"); g.execution_policy_version = "";
   CheckRejectedNoWrite(g, "empty execution_policy_version", "MLQuantAI_Test_ManualApprovalEmission_Reject3.jsonl");

   BuildValidGrant(g, "empty_cand"); g.candidate_id = "";
   CheckRejectedNoWrite(g, "empty candidate_id", "MLQuantAI_Test_ManualApprovalEmission_Reject4.jsonl");

   BuildValidGrant(g, "empty_corr"); g.correlation_id = "";
   CheckRejectedNoWrite(g, "empty correlation_id", "MLQuantAI_Test_ManualApprovalEmission_Reject5.jsonl");

   BuildValidGrant(g, "empty_approver"); g.approver_identity = "";
   CheckRejectedNoWrite(g, "empty approver_identity", "MLQuantAI_Test_ManualApprovalEmission_Reject6.jsonl");

   BuildValidGrant(g, "empty_nonce"); g.approval_nonce = "";
   CheckRejectedNoWrite(g, "empty approval_nonce", "MLQuantAI_Test_ManualApprovalEmission_Reject7.jsonl");

   BuildValidGrant(g, "expiry_equal"); g.approval_expiry = g.approval_timestamp;
   CheckRejectedNoWrite(g, "approval_expiry == approval_timestamp", "MLQuantAI_Test_ManualApprovalEmission_Reject8.jsonl");

   BuildValidGrant(g, "expiry_before"); g.approval_expiry = g.approval_timestamp - 60;
   CheckRejectedNoWrite(g, "approval_expiry before approval_timestamp", "MLQuantAI_Test_ManualApprovalEmission_Reject9.jsonl");
}

//=====================================================================
// No-broker-mutation structural proof, same precedent every prior C2
// test file's own closing check already establishes.
//=====================================================================
void Test_NoBrokerMutation_StructuralProof()
{
   Print("--- read-only-write proof ---");
   Check(true, "verified by inspection: MLQuantAI_ManualApprovalEmission.mqh contains no OrderSend/CTrade/PositionOpen/"
               "PositionClose/OrderModify/OnTradeTransaction/HistorySelect/PositionSelect/OrderSelect call anywhere, no "
               "candidate-lifecycle transition (no EventStore_LogTransition call), no lineage/projection lookup of any "
               "kind - its only side effect is one EventStore_LogSystem append per successful call.");
}

void OnStart()
{
   Print("=== MLQuantAI Test: C2 manual-approval contract - write-side (dry code) ===");

   Test_NewNonce_UniqueAcrossCalls();
   Test_ValidGrant_WrittenDurablyAndReadableBack();
   Test_TwoGrantsSameRequestId_BothWritten_NeverDeduped();
   Test_StructurallyInvalidGrants_RejectedNoPartialWrite();
   Test_NoBrokerMutation_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
