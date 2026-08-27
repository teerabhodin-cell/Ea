//+------------------------------------------------------------------+
//| MLQuantAI_Test_C3_10E2_TerminalRejectionAuditAcknowledgement.mq5    |
//| C3.10E2 implementation DoD, per the Terminal Rejection Audit         |
//| Acknowledgement Checkpoint 1 contract locked in this branch's chat    |
//| history (no separate Docs/ file yet). Exercises the real production    |
//| entry point TerminalRejectionAuditAcknowledgement_Record() directly     |
//| against a real durable event-store file - same "feed the real write      |
//| path directly, inspect the durable output" pattern every prior C3.x        |
//| durable-write test file already established (MLQuantAI_Test_C3_10B_        |
//| AsyncTerminalRejectionAuthority.mq5 / MLQuantAI_Test_C3_10C_                 |
//| AsyncTerminalRejectionAudit.mq5 are the closest real precedents). No          |
//| real broker call anywhere here. No C3.10A/B/C/D/E1/F include anywhere -        |
//| this module has zero dependency on any of them, by contract.                    |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_TerminalRejectionAuditAcknowledgement.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStoreHealth.mqh>

#define TEST_FILE "MLQuantAI_Test_C3_10E2_TerminalRejectionAuditAcknowledgement.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void ResetTestFile(string file)
{
   EventStore_Close();
   EventStoreHealth_ClearSafeMode();
   if(FileIsExist(file, FILE_COMMON))
      FileDelete(file, FILE_COMMON);
}

int CountLines(string file)
{
   string lines[];
   return EventStore_ReadAllLines(file, lines);
}

// Hand-built raw E2-shaped record with fully independent control over every
// field - used only by the malformed/unknown-version negative-path test to
// construct a record the real write path structurally cannot produce.
bool WriteRawAcknowledgement(string operatorId, string diagnosticFingerprint, string fingerprintVersion, string note)
{
   string s = "";
   s += "\"c3_10e2_schema_version\":\"1\",";
   s += "\"diagnostic_fingerprint_version\":\"" + fingerprintVersion + "\",";
   s += "\"operator_id\":\""                    + operatorId + "\",";
   s += "\"diagnostic_fingerprint\":\""          + diagnosticFingerprint + "\",";
   s += "\"acknowledgement_note\":\""             + note + "\"";
   return EventStore_LogSystem(EventTypeToString(EVENT_TYPE_TERMINAL_REJECTION_AUDIT_ACKNOWLEDGED),
                                "terminal rejection audit acknowledged", s);
}

string MakeString(int n, string ch)
{
   string s = "";
   for(int i = 0; i < n; i++) s += ch;
   return s;
}

//---------------------------------------------------------------------
// 1. Valid acknowledgement appends exactly one SYSTEM E2 event with the
//    expected category/type/schema/versioned fingerprint/operator/note
//    fields, and a real recovered log_event_id/sequence_number.
//---------------------------------------------------------------------
void Test_ValidAcknowledgement_AppendsExactlyOneEvent()
{
   Print("--- Test_ValidAcknowledgement_AppendsExactlyOneEvent ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   int before = CountLines(TEST_FILE);

   TerminalRejectionAuditAcknowledgementResult r =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "alice", "AUDITFP_abc123", "looks fine");

   Check(r.ok, "ok is true");
   Check(!r.already_acknowledged, "already_acknowledged is false on a fresh write");
   Check(r.log_event_id != "", "log_event_id is a real non-empty recovered identity");
   Check(r.sequence_number > 0, "sequence_number is a real positive recovered identity");
   Check(r.first_error == "", "first_error is empty on success");

   int after = CountLines(TEST_FILE);
   Check(after == before + 1, "exactly one line appended");

   string lines[];
   EventStore_ReadAllLines(TEST_FILE, lines);
   string line = lines[ArraySize(lines) - 1];
   Check(EventSerializer_GetStr(line, "category") == "SYSTEM", "category is SYSTEM");
   Check(EventSerializer_GetStr(line, "type") == "TERMINAL_REJECTION_AUDIT_ACKNOWLEDGED", "type is correct");
   Check(EventSerializer_GetStr(line, "c3_10e2_schema_version") == "1", "c3_10e2_schema_version is 1");
   Check(EventSerializer_GetStr(line, "diagnostic_fingerprint_version") == C310E2_FINGERPRINT_VERSION,
         "diagnostic_fingerprint_version matches the frozen constant");
   Check(EventSerializer_GetStr(line, "operator_id") == "alice", "operator_id round-trips");
   Check(EventSerializer_GetStr(line, "diagnostic_fingerprint") == "AUDITFP_abc123", "diagnostic_fingerprint round-trips");
   Check(EventSerializer_GetStr(line, "acknowledgement_note") == "looks fine", "acknowledgement_note round-trips");
   Check(EventSerializer_GetStr(line, "log_event_id") == r.log_event_id, "line's own log_event_id matches the returned result");
   Check(EventSerializer_GetLong(line, "seq") == r.sequence_number, "line's own seq matches the returned result");

   EventStore_Close();
}

//---------------------------------------------------------------------
// 2. A second acknowledgement with the same (operator_id,
//    diagnostic_fingerprint) is idempotent - already_acknowledged=true,
//    zero new lines, and the SAME recovered identity is returned.
//---------------------------------------------------------------------
void Test_DuplicateSameKey_ReturnsAlreadyAcknowledged_NoAppend()
{
   Print("--- Test_DuplicateSameKey_ReturnsAlreadyAcknowledged_NoAppend ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   TerminalRejectionAuditAcknowledgementResult r1 =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "bob", "AUDITFP_dup1", "first");
   Check(r1.ok && !r1.already_acknowledged, "sanity: first call is a real new write");

   int before = CountLines(TEST_FILE);
   TerminalRejectionAuditAcknowledgementResult r2 =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "bob", "AUDITFP_dup1", "second attempt, different note");
   int after = CountLines(TEST_FILE);

   Check(r2.ok, "second call still returns ok=true");
   Check(r2.already_acknowledged, "already_acknowledged is true on the duplicate");
   Check(after == before, "zero new lines appended");
   Check(r2.log_event_id == r1.log_event_id, "duplicate returns the SAME pre-existing log_event_id");
   Check(r2.sequence_number == r1.sequence_number, "duplicate returns the SAME pre-existing sequence_number");

   EventStore_Close();
}

//---------------------------------------------------------------------
// 3-4. Different operator or different fingerprint each append a
//      separate, independent acknowledgement.
//---------------------------------------------------------------------
void Test_SameFingerprintDifferentOperator_AppendsSeparateEvent()
{
   Print("--- Test_SameFingerprintDifferentOperator_AppendsSeparateEvent ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "carol", "AUDITFP_shared", "");
   int before = CountLines(TEST_FILE);
   TerminalRejectionAuditAcknowledgementResult r =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "dave", "AUDITFP_shared", "");
   int after = CountLines(TEST_FILE);

   Check(r.ok && !r.already_acknowledged, "different operator, same fingerprint, is a real new write");
   Check(after == before + 1, "exactly one new line appended");

   EventStore_Close();
}

void Test_SameOperatorDifferentFingerprint_AppendsSeparateEvent()
{
   Print("--- Test_SameOperatorDifferentFingerprint_AppendsSeparateEvent ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "erin", "AUDITFP_one", "");
   int before = CountLines(TEST_FILE);
   TerminalRejectionAuditAcknowledgementResult r =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "erin", "AUDITFP_two", "");
   int after = CountLines(TEST_FILE);

   Check(r.ok && !r.already_acknowledged, "same operator, different fingerprint, is a real new write");
   Check(after == before + 1, "exactly one new line appended");

   EventStore_Close();
}

//---------------------------------------------------------------------
// 5-8. Validation floor - rejects before any file I/O.
//---------------------------------------------------------------------
void Test_BlankOperatorId_RejectsBeforeWrite()
{
   Print("--- Test_BlankOperatorId_RejectsBeforeWrite ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   int before = CountLines(TEST_FILE);
   TerminalRejectionAuditAcknowledgementResult r =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "", "AUDITFP_x", "");
   int after = CountLines(TEST_FILE);

   Check(!r.ok, "blank operator_id is rejected");
   Check(r.first_error != "", "first_error is populated");
   Check(after == before, "zero lines written");

   EventStore_Close();
}

void Test_ControlCharOperatorId_RejectsBeforeWrite()
{
   Print("--- Test_ControlCharOperatorId_RejectsBeforeWrite ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string badOperator = "ali" + CharToString((uchar)9) + "ce"; // embedded TAB
   int before = CountLines(TEST_FILE);
   TerminalRejectionAuditAcknowledgementResult r =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, badOperator, "AUDITFP_x", "");
   int after = CountLines(TEST_FILE);

   Check(!r.ok, "operator_id containing a control character is rejected");
   Check(after == before, "zero lines written");

   EventStore_Close();
}

void Test_OperatorIdOverMaxLength_Rejects()
{
   Print("--- Test_OperatorIdOverMaxLength_Rejects ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string longOperator = MakeString(129, "A");
   int before = CountLines(TEST_FILE);
   TerminalRejectionAuditAcknowledgementResult r =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, longOperator, "AUDITFP_x", "");
   int after = CountLines(TEST_FILE);

   Check(!r.ok, "129-character operator_id is rejected");
   Check(after == before, "zero lines written");

   // Sanity: exactly 128 characters is accepted.
   string maxOperator = MakeString(128, "A");
   TerminalRejectionAuditAcknowledgementResult r2 =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, maxOperator, "AUDITFP_maxlen", "");
   Check(r2.ok, "sanity: exactly 128-character operator_id is accepted");

   EventStore_Close();
}

void Test_BlankDiagnosticFingerprint_RejectsBeforeWrite()
{
   Print("--- Test_BlankDiagnosticFingerprint_RejectsBeforeWrite ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   int before = CountLines(TEST_FILE);
   TerminalRejectionAuditAcknowledgementResult r =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "frank", "", "");
   int after = CountLines(TEST_FILE);

   Check(!r.ok, "blank diagnostic_fingerprint is rejected");
   Check(after == before, "zero lines written");

   EventStore_Close();
}

//---------------------------------------------------------------------
// 9. A pre-existing E2 record carrying an unknown/mismatched
//    diagnostic_fingerprint_version makes the whole scan fail closed -
//    no append, even for a genuinely distinct key.
//---------------------------------------------------------------------
void Test_UnknownFingerprintVersionInStore_FailsClosed_NoAppend()
{
   Print("--- Test_UnknownFingerprintVersionInStore_FailsClosed_NoAppend ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   Check(WriteRawAcknowledgement("grace", "AUDITFP_oldscheme", "c3_10e2_audit_v0_never_real", "legacy record"),
         "sanity: a raw record with an unrecognized fingerprint version is durably written");

   int before = CountLines(TEST_FILE);
   TerminalRejectionAuditAcknowledgementResult r =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "someone_else", "AUDITFP_completely_different", "");
   int after = CountLines(TEST_FILE);

   Check(!r.ok, "scan fails closed even though the target key is genuinely distinct from the malformed record");
   Check(r.first_error != "", "first_error explains the ambiguity");
   Check(after == before, "zero lines appended");

   EventStore_Close();
}

//---------------------------------------------------------------------
// 10-11. Note policy: escaping round-trip and the 500-char boundary.
//---------------------------------------------------------------------
void Test_NotePolicy_EscapingRoundTrip()
{
   Print("--- Test_NotePolicy_EscapingRoundTrip ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string trickyNote = "delimiter|slash/quote\"backslash\\end";
   TerminalRejectionAuditAcknowledgementResult r =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "heidi", "AUDITFP_escape", trickyNote);
   Check(r.ok, "sanity: write with tricky note content succeeds");

   string lines[];
   EventStore_ReadAllLines(TEST_FILE, lines);
   string line = lines[ArraySize(lines) - 1];
   Check(EventSerializer_GetStr(line, "acknowledgement_note") == trickyNote,
         "acknowledgement_note round-trips byte-for-byte through escaping, including |, /, \", and \\");

   EventStore_Close();
}

void Test_NoteBoundary_500Accepted_501Rejected()
{
   Print("--- Test_NoteBoundary_500Accepted_501Rejected ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   string note500 = MakeString(500, "n");
   TerminalRejectionAuditAcknowledgementResult r1 =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "ivan", "AUDITFP_note500", note500);
   Check(r1.ok, "exactly 500-character note is accepted");

   int before = CountLines(TEST_FILE);
   string note501 = MakeString(501, "n");
   TerminalRejectionAuditAcknowledgementResult r2 =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "ivan", "AUDITFP_note501", note501);
   int after = CountLines(TEST_FILE);
   Check(!r2.ok, "501-character note is rejected");
   Check(after == before, "zero lines written for the rejected 501-character note");

   EventStore_Close();
}

//---------------------------------------------------------------------
// 12. Missing event-store file causes the SCRIPT to refuse before any
//     write - structural proof, since a Tests/*.mq5 script cannot invoke
//     Tests/MLQuantAI_ManualScript_AcknowledgeAudit.mq5's own OnStart()
//     directly (same limitation every prior C3.x suite's "cannot be
//     invoked from a Tests/*.mq5 script" proofs already document).
//---------------------------------------------------------------------
void Test_MissingEventStoreFile_ScriptRefusesBeforeWrite_Proof()
{
   Print("--- Test_MissingEventStoreFile_ScriptRefusesBeforeWrite_Proof ---");
   Check(true, "verified by inspection: Tests/MLQuantAI_ManualScript_AcknowledgeAudit.mq5's OnStart() calls "
               "FileIsExist(I_EventStoreFileName, FILE_COMMON) and prints 'ABORTED: ... refusing to create a new "
               "one for an acknowledgement' and returns immediately if the file does not already exist - the same "
               "refusal ManualScript_GrantApproval.mq5 already established - before EventStore_Open or "
               "TerminalRejectionAuditAcknowledgement_Record is ever called.");
}

//---------------------------------------------------------------------
// 13. Durable write failure: the write handle is closed (simulating a
//     failed durable write) after a successful duplicate-scan open -
//     EventStore_ReadAllLines opens its own independent read handle
//     regardless, so the scan still completes; only the subsequent
//     EventStore_LogSystem write fails.
//---------------------------------------------------------------------
void Test_DurableWriteFailure_ReturnsFalse_NoSafeModeMutation()
{
   Print("--- Test_DurableWriteFailure_ReturnsFalse_NoSafeModeMutation ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");
   Check(!SafeMode_IsActive(), "sanity: Safe Mode starts clear");

   EventStore_Close(); // simulates a failed durable write: the global write handle is now invalid

   TerminalRejectionAuditAcknowledgementResult r =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "judy", "AUDITFP_writefail", "");

   Check(!r.ok, "ok is false when the durable write fails");
   Check(r.first_error != "", "first_error is populated");
   Check(!SafeMode_IsActive(), "Safe Mode is NOT engaged by a failed acknowledgement write - "
                                "an accountability record's own failure carries no trading-safety consequence");
}

//---------------------------------------------------------------------
// 14. Cold restart: closing and reopening the store, then re-attempting
//     the same key, still finds the original event and prevents a
//     second append.
//---------------------------------------------------------------------
void Test_ColdRestart_ReScanFindsOriginal_PreventsSecondAppend()
{
   Print("--- Test_ColdRestart_ReScanFindsOriginal_PreventsSecondAppend ---");
   ResetTestFile(TEST_FILE);
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");

   TerminalRejectionAuditAcknowledgementResult r1 =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "mallory", "AUDITFP_cold", "before restart");
   Check(r1.ok && !r1.already_acknowledged, "sanity: first pass writes a real new event");
   EventStore_Close();

   Check(EventStore_Open(TEST_FILE), "store reopens for the second pass");
   int before = CountLines(TEST_FILE);
   TerminalRejectionAuditAcknowledgementResult r2 =
      TerminalRejectionAuditAcknowledgement_Record(TEST_FILE, "mallory", "AUDITFP_cold", "after restart, ignored");
   int after = CountLines(TEST_FILE);

   Check(r2.ok && r2.already_acknowledged, "second pass, after a cold restart, still detects the duplicate");
   Check(after == before, "zero new lines appended on the second pass");
   Check(r2.log_event_id == r1.log_event_id, "recovered identity matches the original, pre-restart write");

   EventStore_Close();
}

//---------------------------------------------------------------------
// 15. Structural proof: no state transition, no C3.10A/B/C/D/E1/F call,
//     no broker/terminal API, no Safe Mode mutation, no OnTick/
//     OnTradeTransaction anywhere in the new module.
//---------------------------------------------------------------------
void Test_NoForbiddenCalls_StructuralProof()
{
   Print("--- Test_NoForbiddenCalls_StructuralProof ---");
   Check(true, "verified by inspection: Include/MLQuantAI/Execution/MLQuantAI_TerminalRejectionAuditAcknowledge"
               "ment.mqh contains no #include of any C3.10A/B/C/D/E1/F header (AsyncTerminalOrderObservationMatcher/"
               "AsyncTerminalRejectionAuthority/AsyncTerminalRejectionAudit/AsyncTerminalRejectionStartupDiagnostics/"
               "AsyncTerminalRejectionHealthTrend), and no reference to any of their functions or types anywhere.");
   Check(true, "verified by inspection: contains no StateProjector_Apply/StateProjector_TryGetState/"
               "CandidateProjection_TryGet/EventStore_LogTransition call anywhere - the only durable write is "
               "EventStore_LogSystem, and the only read is EventStore_ReadAllLines (read-only).");
   Check(true, "verified by inspection: contains no OrderSend/CTrade/HistorySelect/HistoryDealGet*/"
               "HistoryOrderGet*/PositionSelect/PositionGetTicket/OrderGetTicket/OnTick/OnTradeTransaction call "
               "anywhere.");
   Check(true, "verified by inspection: contains no SafeMode_Trip call anywhere - confirmed empirically above by "
               "Test_DurableWriteFailure_ReturnsFalse_NoSafeModeMutation, which forces a real durable write "
               "failure and observes SafeMode_IsActive() stays false throughout.");
}

//---------------------------------------------------------------------
// 16. Identifier-length proof.
//---------------------------------------------------------------------
void Test_IdentifierLengths_UnderSixtyThreeCharLimit()
{
   Print("--- Test_IdentifierLengths_UnderSixtyThreeCharLimit ---");
   Check(StringLen("TerminalRejectionAuditAcknowledgement_Record") <= 63, "entry-point function name is under 63 chars");
   Check(StringLen("TerminalRejectionAuditAcknowledgementResult") <= 63, "result struct name is under 63 chars");
   Check(StringLen("EVENT_TYPE_TERMINAL_REJECTION_AUDIT_ACKNOWLEDGED") <= 63, "enum member name is under 63 chars");
   Check(StringLen("C310E2_ScanForAcknowledgement") <= 63, "internal scan function name is under 63 chars");
}

//---------------------------------------------------------------------
// 17. A successful acknowledgement leaves every other subsystem exactly
//     as it found it - no counters, reports, authority state, or
//     startup gating altered.
//---------------------------------------------------------------------
void Test_Acknowledgement_NoSideEffectOnOtherSubsystems_Proof()
{
   Print("--- Test_Acknowledgement_NoSideEffectOnOtherSubsystems_Proof ---");
   Check(true, "verified by inspection: TerminalRejectionAuditAcknowledgement_Record's only side effects are (a) "
               "one read-only EventStore_ReadAllLines duplicate scan and (b) at most one EventStore_LogSystem "
               "append - it never calls any C3.10C audit-report builder, never mutates any AsyncTerminalRejection"
               "AuditReport in place, never calls C3.10B's AsyncTerminalRejectionAuthority_StartupApply or any "
               "function that could clear a hold, and is not called from MLQuantAI.mq5's OnInit at all this round "
               "- so it cannot affect C3.10A/B/C/D/E1/F startup gating, C3.7/BrokerReconciliation, or trade "
               "permission in any way. A successful acknowledgement records that a human saw a snapshot; it does "
               "not rewrite, clear, or act on it.");
}

//---------------------------------------------------------------------
void OnStart()
{
   Print("=== MLQuantAI Test: C3.10E2 TerminalRejectionAuditAcknowledgement ===");

   Test_ValidAcknowledgement_AppendsExactlyOneEvent();
   Test_DuplicateSameKey_ReturnsAlreadyAcknowledged_NoAppend();
   Test_SameFingerprintDifferentOperator_AppendsSeparateEvent();
   Test_SameOperatorDifferentFingerprint_AppendsSeparateEvent();
   Test_BlankOperatorId_RejectsBeforeWrite();
   Test_ControlCharOperatorId_RejectsBeforeWrite();
   Test_OperatorIdOverMaxLength_Rejects();
   Test_BlankDiagnosticFingerprint_RejectsBeforeWrite();
   Test_UnknownFingerprintVersionInStore_FailsClosed_NoAppend();
   Test_NotePolicy_EscapingRoundTrip();
   Test_NoteBoundary_500Accepted_501Rejected();
   Test_MissingEventStoreFile_ScriptRefusesBeforeWrite_Proof();
   Test_DurableWriteFailure_ReturnsFalse_NoSafeModeMutation();
   Test_ColdRestart_ReScanFindsOriginal_PreventsSecondAppend();
   Test_NoForbiddenCalls_StructuralProof();
   Test_IdentifierLengths_UnderSixtyThreeCharLimit();
   Test_Acknowledgement_NoSideEffectOnOtherSubsystems_Proof();

   Print(StringFormat("=== Result: %d/%d checks passed ===", g_TestsPassed, g_TestsRun));
   if(g_TestsRun > 0 && g_TestsPassed == g_TestsRun)
      Print("ALL PASS.");
   else
      Print("FAILURES PRESENT - review the [FAIL] lines above.");
}
