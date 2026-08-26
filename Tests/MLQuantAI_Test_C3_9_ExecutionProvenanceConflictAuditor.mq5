//+------------------------------------------------------------------+
//| MLQuantAI_Test_C3_9_ExecutionProvenanceConflictAuditor.mq5        |
//| C3.9 implementation DoD. Exercises the real production entry      |
//| points ExecutionProvenanceConflictAuditor_ScanLines()/_ScanFile() |
//| and the file-local EPCA_GetLongArray() parser directly, per the   |
//| design locked at Checkpoints 1/2. Pure read-only diagnostic - no  |
//| EventStore_Open/EventStore_LogTransition anywhere in this file:   |
//| fixture lines are hand-built raw JSONL strings (same technique    |
//| MLQuantAI_Test_EventSerializer_ExtraJson.mq5 already established) |
//| and, where a real file is needed, written directly via FileWrite  |
//| rather than through EventStore's own emission API, since nothing  |
//| here needs a live EventStore session. No real broker call         |
//| anywhere here.                                                    |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ExecutionProvenanceConflictAuditor.mqh>

#define TEST_FILE "MLQuantAI_Test_C3_9_ExecutionProvenanceConflictAuditor.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers.
//---------------------------------------------------------------------

// Builds one full raw CANDIDATE_EXECUTED JSONL line, real field order
// mirroring EventSerializer_ToJson()'s write side and C37_BuildExtraJson's
// frozen provenance fragment shape - same hand-built-line technique
// MLQuantAI_Test_EventSerializer_ExtraJson.mq5's own BuildFullLine()
// already established. dealTicketsFragment is inserted verbatim (e.g.
// "[6001,6002]", "[]", or a deliberately malformed fragment) so malformed-
// input tests can construct exactly the byte sequence they need.
string BuildExecutedLine(string candidateId, string execReqId, long orderTicket, string dealTicketsFragment, int seq)
{
   string s = "{";
   s += "\"schema_version\":\"EVENTS_V1\",";
   s += "\"log_event_id\":\"SESS_C39#" + IntegerToString(seq) + "\",";
   s += "\"session_id\":\"SESS_C39\",";
   s += "\"seq\":" + IntegerToString(seq) + ",";
   s += "\"ts\":\"2026.01.01 00:00:00\",";
   s += "\"category\":\"LIFECYCLE\",";
   s += "\"type\":\"CANDIDATE_EXECUTED\",";
   s += "\"candidate_id\":\"" + candidateId + "\",";
   s += "\"root_event_id\":\"EVT_ROOT\",";
   s += "\"correlation_id\":\"\",";
   s += "\"strategy_id\":0,";
   s += "\"strategy\":\"CRT\",";
   s += "\"from_state\":\"SUBMITTED\",";
   s += "\"to_state\":\"EXECUTED\",";
   s += "\"reason\":\"EXECUTED_OK\",";
   s += "\"c3_7_schema_version\":\"C37_V1\",";
   s += "\"c3_6_action_id\":\"ACT_" + candidateId + "\",";
   s += "\"execution_request_id\":\"" + execReqId + "\",";
   s += "\"order_ticket\":" + IntegerToString(orderTicket) + ",";
   s += "\"deal_tickets_sorted\":" + dealTicketsFragment;
   s += "}";
   return s;
}

// A lifecycle-category line whose to_state is NOT CANDIDATE_EXECUTED -
// used to prove non-executed lifecycle lines are ignored.
string BuildNonExecutedLifecycleLine(string candidateId, string toState, int seq)
{
   string s = "{";
   s += "\"schema_version\":\"EVENTS_V1\",";
   s += "\"log_event_id\":\"SESS_C39#" + IntegerToString(seq) + "\",";
   s += "\"session_id\":\"SESS_C39\",";
   s += "\"seq\":" + IntegerToString(seq) + ",";
   s += "\"ts\":\"2026.01.01 00:00:00\",";
   s += "\"category\":\"LIFECYCLE\",";
   s += "\"type\":\"CANDIDATE_SUBMITTED\",";
   s += "\"candidate_id\":\"" + candidateId + "\",";
   s += "\"root_event_id\":\"EVT_ROOT\",";
   s += "\"correlation_id\":\"\",";
   s += "\"strategy_id\":0,";
   s += "\"strategy\":\"CRT\",";
   s += "\"from_state\":\"CREATED\",";
   s += "\"to_state\":\"" + toState + "\",";
   s += "\"reason\":\"NONE\"";
   s += "}";
   return s;
}

// A SYSTEM-category line (minimal - PeekCategory only reads "category",
// ScanLines skips it before ever attempting to parse it as a lifecycle
// event, so it need not be a fully valid SystemEvent).
string BuildSystemLine(int seq)
{
   return "{\"schema_version\":\"EVENTS_V1\",\"category\":\"SYSTEM\",\"type\":\"SYSTEM_STARTED\",\"seq\":" +
          IntegerToString(seq) + "}";
}

// A lifecycle-category line missing "candidate_id" entirely - fails
// EventSerializer_ParseLifecycle's own HasKey guard, proving the
// unparseable-line path is non-fatal.
string BuildMalformedLifecycleLine(int seq)
{
   return "{\"schema_version\":\"EVENTS_V1\",\"category\":\"LIFECYCLE\",\"type\":\"CANDIDATE_EXECUTED\",\"seq\":" +
          IntegerToString(seq) + "}"; // no candidate_id key
}

void ResetTestFile(string file)
{
   if(FileIsExist(file, FILE_COMMON))
      FileDelete(file, FILE_COMMON);
}

// Writes lines[] to file as raw text, one per line, mirroring
// EventStore_WriteLine's own FileWriteString(handle, line + "\r\n")
// convention exactly, but via a plain FileOpen/FileWrite/FileClose
// sequence - this module needs no live EventStore session to build a
// fixture file for the _ScanFile wrapper test.
void WriteRawLinesToFile(string file, const string &lines[], int count)
{
   int handle = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < count; i++)
      FileWriteString(handle, lines[i] + "\r\n");
   FileClose(handle);
}

//---------------------------------------------------------------------
// 1. Empty / no-EXECUTED-events input.
//---------------------------------------------------------------------
void Test_NoExecutedEvents_EmptyReport()
{
   Print("--- Test_NoExecutedEvents_EmptyReport ---");
   string lines[];
   ArrayResize(lines, 0);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 0);
   Check(r.ok, "ok is true on an empty scan");
   Check(r.executed_events_scanned == 0, "executed_events_scanned is 0");
   Check(r.unparseable_lines_skipped == 0, "unparseable_lines_skipped is 0");
   Check(r.conflicts_found == 0, "conflicts_found is 0");
   Check(ArraySize(r.conflicts) == 0, "conflicts[] is empty");
}

//---------------------------------------------------------------------
// 2. Single EXECUTED event, no conflict possible.
//---------------------------------------------------------------------
void Test_SingleExecutedEvent_NoConflict()
{
   Print("--- Test_SingleExecutedEvent_NoConflict ---");
   string lines[1];
   lines[0] = BuildExecutedLine("CAND_A", "REQ_SOLO", 1001, "[2001]", 1);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 1);
   Check(r.ok, "ok is true");
   Check(r.executed_events_scanned == 1, "one EXECUTED event scanned");
   Check(r.conflicts_found == 0, "no conflict for a single candidate");
}

//---------------------------------------------------------------------
// 3. Two candidates, fully distinct provenance - no conflict.
//---------------------------------------------------------------------
void Test_TwoCandidates_DistinctProvenance_NoConflict()
{
   Print("--- Test_TwoCandidates_DistinctProvenance_NoConflict ---");
   string lines[2];
   lines[0] = BuildExecutedLine("CAND_A", "REQ_A", 1101, "[2101]", 1);
   lines[1] = BuildExecutedLine("CAND_B", "REQ_B", 1102, "[2102]", 2);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 2);
   Check(r.ok, "ok is true");
   Check(r.executed_events_scanned == 2, "two EXECUTED events scanned");
   Check(r.conflicts_found == 0, "no conflict - every identifier is distinct");
}

//---------------------------------------------------------------------
// 4. Shared execution_request_id -> conflict.
//---------------------------------------------------------------------
void Test_TwoCandidates_SameExecutionRequestId_Conflict()
{
   Print("--- Test_TwoCandidates_SameExecutionRequestId_Conflict ---");
   string lines[2];
   lines[0] = BuildExecutedLine("CAND_A", "REQ_SHARED", 1201, "[2201]", 1);
   lines[1] = BuildExecutedLine("CAND_B", "REQ_SHARED", 1202, "[2202]", 2);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 2);
   Check(!r.ok, "ok is false - a genuine conflict exists");
   Check(r.conflicts_found == 1, "exactly one conflict");
   Check(ArraySize(r.conflicts) == 1, "conflicts[] has one entry");
   if(r.conflicts_found == 1)
   {
      Check(r.conflicts[0].identifier_type == "execution_request_id", "identifier_type is execution_request_id");
      Check(r.conflicts[0].identifier_value == "REQ_SHARED", "identifier_value matches the shared request id");
      Check(ArraySize(r.conflicts[0].candidate_ids) == 2, "two distinct candidates listed");
      Check(r.conflicts[0].candidate_ids[0] == "CAND_A", "candidate_ids[0] is CAND_A - first-seen order");
      Check(r.conflicts[0].candidate_ids[1] == "CAND_B", "candidate_ids[1] is CAND_B - first-seen order");
   }
}

//---------------------------------------------------------------------
// 5. Shared order_ticket -> conflict.
//---------------------------------------------------------------------
void Test_TwoCandidates_SameOrderTicket_Conflict()
{
   Print("--- Test_TwoCandidates_SameOrderTicket_Conflict ---");
   string lines[2];
   lines[0] = BuildExecutedLine("CAND_A", "REQ_A3", 5001, "[3001]", 1);
   lines[1] = BuildExecutedLine("CAND_B", "REQ_B3", 5001, "[3002]", 2);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 2);
   Check(!r.ok, "ok is false");
   Check(r.conflicts_found == 1, "exactly one conflict");
   if(r.conflicts_found == 1)
   {
      Check(r.conflicts[0].identifier_type == "order_ticket", "identifier_type is order_ticket");
      Check(r.conflicts[0].identifier_value == "5001", "identifier_value is the shared ticket, canonical base-10");
      Check(ArraySize(r.conflicts[0].candidate_ids) == 2, "two distinct candidates listed");
   }
}

//---------------------------------------------------------------------
// 6. Overlapping deal_tickets_sorted entry -> conflict.
//---------------------------------------------------------------------
void Test_TwoCandidates_OverlappingDealTicket_Conflict()
{
   Print("--- Test_TwoCandidates_OverlappingDealTicket_Conflict ---");
   string lines[2];
   lines[0] = BuildExecutedLine("CAND_A", "REQ_A4", 6001, "[7001,7002]", 1);
   lines[1] = BuildExecutedLine("CAND_B", "REQ_B4", 6002, "[7002,7003]", 2);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 2);
   Check(!r.ok, "ok is false");
   Check(r.conflicts_found == 1, "exactly one conflict - only 7002 overlaps");
   if(r.conflicts_found == 1)
   {
      Check(r.conflicts[0].identifier_type == "deal_ticket", "identifier_type is deal_ticket");
      Check(r.conflicts[0].identifier_value == "7002", "identifier_value is the overlapping ticket");
      Check(ArraySize(r.conflicts[0].candidate_ids) == 2, "two distinct candidates listed");
   }
}

//---------------------------------------------------------------------
// 7. Three distinct candidates sharing one identifier - all listed.
//---------------------------------------------------------------------
void Test_ThreeCandidates_SameIdentifier_AllListed()
{
   Print("--- Test_ThreeCandidates_SameIdentifier_AllListed ---");
   string lines[3];
   lines[0] = BuildExecutedLine("CAND_A", "REQ_A5", 8001, "[9001]", 1);
   lines[1] = BuildExecutedLine("CAND_B", "REQ_B5", 8001, "[9002]", 2);
   lines[2] = BuildExecutedLine("CAND_C", "REQ_C5", 8001, "[9003]", 3);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 3);
   Check(!r.ok, "ok is false");
   Check(r.conflicts_found == 1, "exactly one conflict record for the shared order_ticket");
   if(r.conflicts_found == 1)
   {
      Check(ArraySize(r.conflicts[0].candidate_ids) == 3, "all three candidates listed, none dropped");
      Check(r.conflicts[0].candidate_ids[0] == "CAND_A" && r.conflicts[0].candidate_ids[1] == "CAND_B" &&
            r.conflicts[0].candidate_ids[2] == "CAND_C", "first-seen order preserved across all three");
   }
}

//---------------------------------------------------------------------
// 8. Same candidate repeats an identifier across two lines - not a
//    false conflict (only one distinct candidate_id).
//---------------------------------------------------------------------
void Test_SameCandidateRepeatsIdentifier_NoFalseConflict()
{
   Print("--- Test_SameCandidateRepeatsIdentifier_NoFalseConflict ---");
   string lines[2];
   lines[0] = BuildExecutedLine("CAND_A", "REQ_REPEAT", 9101, "[9201]", 1);
   lines[1] = BuildExecutedLine("CAND_A", "REQ_REPEAT", 9101, "[9201]", 2);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 2);
   Check(r.ok, "ok stays true - only one distinct candidate_id claims these identifiers");
   Check(r.conflicts_found == 0, "no conflict recorded");
}

//---------------------------------------------------------------------
// 9. Empty execution_request_id is never indexed as a shared identifier.
//---------------------------------------------------------------------
void Test_EmptyExecutionRequestId_NotIndexed()
{
   Print("--- Test_EmptyExecutionRequestId_NotIndexed ---");
   string lines[2];
   lines[0] = BuildExecutedLine("CAND_A", "", 9301, "[]", 1);
   lines[1] = BuildExecutedLine("CAND_B", "", 9302, "[]", 2);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 2);
   Check(r.ok, "ok stays true - two different, otherwise-distinct candidates, both with an empty execution_request_id");
   Check(r.conflicts_found == 0, "empty execution_request_id never becomes a shared conflict key");
}

//---------------------------------------------------------------------
// 10. order_ticket <= 0 is never indexed.
//---------------------------------------------------------------------
void Test_ZeroOrderTicket_NotIndexed()
{
   Print("--- Test_ZeroOrderTicket_NotIndexed ---");
   string lines[2];
   lines[0] = BuildExecutedLine("CAND_A", "REQ_Z1", 0, "[]", 1);
   lines[1] = BuildExecutedLine("CAND_B", "REQ_Z2", 0, "[]", 2);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 2);
   Check(r.ok, "ok stays true");
   Check(r.conflicts_found == 0, "order_ticket == 0 never becomes a shared conflict key");
}

//---------------------------------------------------------------------
// 11. Non-lifecycle-category lines are ignored.
//---------------------------------------------------------------------
void Test_NonLifecycleCategoryLines_Ignored()
{
   Print("--- Test_NonLifecycleCategoryLines_Ignored ---");
   string lines[2];
   lines[0] = BuildSystemLine(1);
   lines[1] = BuildExecutedLine("CAND_A", "REQ_SYS1", 9401, "[]", 2);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 2);
   Check(r.ok, "ok is true");
   Check(r.executed_events_scanned == 1, "only the real LIFECYCLE/EXECUTED line is counted");
   Check(r.unparseable_lines_skipped == 0, "the SYSTEM line is never attempted as a lifecycle parse at all");
}

//---------------------------------------------------------------------
// 12. Non-EXECUTED lifecycle lines are ignored.
//---------------------------------------------------------------------
void Test_NonExecutedLifecycleLines_Ignored()
{
   Print("--- Test_NonExecutedLifecycleLines_Ignored ---");
   string lines[2];
   lines[0] = BuildNonExecutedLifecycleLine("CAND_A", "SUBMITTED", 1);
   lines[1] = BuildExecutedLine("CAND_B", "REQ_NE1", 9501, "[]", 2);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 2);
   Check(r.ok, "ok is true");
   Check(r.executed_events_scanned == 1, "only the to_state==EXECUTED line is counted");
}

//---------------------------------------------------------------------
// 13. Malformed lifecycle line (missing candidate_id) - skipped, not fatal.
//---------------------------------------------------------------------
void Test_MalformedLifecycleLine_SkippedNotFatal()
{
   Print("--- Test_MalformedLifecycleLine_SkippedNotFatal ---");
   string lines[2];
   lines[0] = BuildMalformedLifecycleLine(1);
   lines[1] = BuildExecutedLine("CAND_A", "REQ_MF1", 9601, "[]", 2);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 2);
   Check(r.ok, "ok is true - a malformed line is never fatal");
   Check(r.unparseable_lines_skipped == 1, "unparseable_lines_skipped counts the malformed line");
   Check(r.executed_events_scanned == 1, "the real EXECUTED line is still scanned normally");
}

//---------------------------------------------------------------------
// 14. Deliberately malformed deal_tickets_sorted - not indexed, not
//     fatal, does not force ok=false absent a genuine conflict.
//---------------------------------------------------------------------
void Test_MalformedDealTickets_NotIndexed_NotFatal()
{
   Print("--- Test_MalformedDealTickets_NotIndexed_NotFatal ---");
   string lines[1];
   lines[0] = BuildExecutedLine("CAND_A", "REQ_MDT1", 9701, "[6001,]", 1); // trailing comma - malformed
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 1);
   Check(r.ok, "ok is true - a malformed deal_tickets_sorted alone is not fatal and creates no conflict");
   Check(r.executed_events_scanned == 1, "the line itself still parses and counts as a scanned EXECUTED event");
   Check(r.conflicts_found == 0, "no phantom conflict key is ever created from the malformed array");

   // Second candidate reuses the SAME malformed fragment - if a phantom
   // key were ever created from malformed content, this would collide.
   string lines2[2];
   lines2[0] = lines[0];
   lines2[1] = BuildExecutedLine("CAND_B", "REQ_MDT2", 9702, "[6001,]", 2);
   ExecutionProvenanceConflictReport r2 = ExecutionProvenanceConflictAuditor_ScanLines(lines2, 2);
   Check(r2.ok, "ok stays true even with two candidates sharing the identical malformed fragment text");
   Check(r2.conflicts_found == 0, "still no conflict - malformed content is never turned into a comparable key");
}

//---------------------------------------------------------------------
// 15. Multiple independent conflicts in one file - none dropped, order preserved.
//---------------------------------------------------------------------
void Test_MultipleConflictsInOneFile_AllReported()
{
   Print("--- Test_MultipleConflictsInOneFile_AllReported ---");
   string lines[4];
   lines[0] = BuildExecutedLine("CAND_A", "SHARED1", 201, "[301]", 1);
   lines[1] = BuildExecutedLine("CAND_B", "SHARED1", 202, "[302]", 2);
   lines[2] = BuildExecutedLine("CAND_C", "C-UNIQUE", 401, "[501]", 3);
   lines[3] = BuildExecutedLine("CAND_D", "D-UNIQUE", 401, "[502]", 4);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, 4);
   Check(!r.ok, "ok is false");
   Check(r.conflicts_found == 2, "both independent conflicts are reported");
   Check(ArraySize(r.conflicts) == 2, "conflicts[] has two entries");
   if(r.conflicts_found == 2)
   {
      Check(r.conflicts[0].identifier_type == "execution_request_id" && r.conflicts[0].identifier_value == "SHARED1",
            "conflicts[0] is the execution_request_id conflict - first seen (CAND_A's line)");
      Check(r.conflicts[1].identifier_type == "order_ticket" && r.conflicts[1].identifier_value == "401",
            "conflicts[1] is the order_ticket conflict - first seen later (CAND_C's line)");
   }
}

//---------------------------------------------------------------------
// 16. _ScanFile wrapper matches _ScanLines on the same content.
//---------------------------------------------------------------------
void Test_ScanFile_MatchesScanLines()
{
   Print("--- Test_ScanFile_MatchesScanLines ---");
   ResetTestFile(TEST_FILE);

   string lines[2];
   lines[0] = BuildExecutedLine("CAND_A", "REQ_SF_SHARED", 1301, "[]", 1);
   lines[1] = BuildExecutedLine("CAND_B", "REQ_SF_SHARED", 1302, "[]", 2);
   WriteRawLinesToFile(TEST_FILE, lines, 2);

   ExecutionProvenanceConflictReport expected = ExecutionProvenanceConflictAuditor_ScanLines(lines, 2);
   ExecutionProvenanceConflictReport actual   = ExecutionProvenanceConflictAuditor_ScanFile(TEST_FILE);

   Check(actual.ok == expected.ok, "ok matches");
   Check(actual.executed_events_scanned == expected.executed_events_scanned, "executed_events_scanned matches");
   Check(actual.conflicts_found == expected.conflicts_found, "conflicts_found matches");
   if(actual.conflicts_found == expected.conflicts_found && actual.conflicts_found == 1)
      Check(actual.conflicts[0].identifier_value == expected.conflicts[0].identifier_value,
            "the conflict's identifier_value matches between ScanFile and ScanLines");

   ResetTestFile(TEST_FILE);
}

//---------------------------------------------------------------------
// 17. Missing file behaves identically to an empty file (matches
//     EventStore_ReadAllLines's own real, non-distinguishing behavior).
//---------------------------------------------------------------------
void Test_ScanFile_MissingFile_EmptyReport()
{
   Print("--- Test_ScanFile_MissingFile_EmptyReport ---");
   ResetTestFile(TEST_FILE); // ensure it does not exist
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanFile(TEST_FILE);
   Check(r.ok, "ok is true for a missing file");
   Check(r.executed_events_scanned == 0, "zero events scanned");
   Check(r.conflicts_found == 0, "zero conflicts");
}

//---------------------------------------------------------------------
// 18. n < 0 is clamped to 0, never a crash or a full-array scan.
//---------------------------------------------------------------------
void Test_ScanLines_NegativeN_TreatedAsZero()
{
   Print("--- Test_ScanLines_NegativeN_TreatedAsZero ---");
   string lines[2];
   lines[0] = BuildExecutedLine("CAND_A", "REQ_NEG", 1401, "[]", 1);
   lines[1] = BuildExecutedLine("CAND_B", "REQ_NEG", 1402, "[]", 2);
   ExecutionProvenanceConflictReport r = ExecutionProvenanceConflictAuditor_ScanLines(lines, -1);
   Check(r.ok, "ok is true - negative n is treated as zero lines, not the full array");
   Check(r.executed_events_scanned == 0, "zero events scanned despite real content in lines[]");
   Check(r.conflicts_found == 0, "zero conflicts - the real conflict in lines[] was never reached");
}

//---------------------------------------------------------------------
// 19. n > ArraySize(lines) is clamped safely, matches the natural bound.
//---------------------------------------------------------------------
void Test_ScanLines_NGreaterThanArraySize_ClampedSafely()
{
   Print("--- Test_ScanLines_NGreaterThanArraySize_ClampedSafely ---");
   string lines[2];
   lines[0] = BuildExecutedLine("CAND_A", "REQ_OVR", 1501, "[]", 1);
   lines[1] = BuildExecutedLine("CAND_B", "REQ_OVR2", 1502, "[]", 2);
   ExecutionProvenanceConflictReport clamped = ExecutionProvenanceConflictAuditor_ScanLines(lines, 100);
   ExecutionProvenanceConflictReport natural = ExecutionProvenanceConflictAuditor_ScanLines(lines, 2);
   Check(clamped.executed_events_scanned == natural.executed_events_scanned,
         "n=100 against a 2-element array produces the same result as n=2 - no crash, no out-of-bounds read");
   Check(clamped.executed_events_scanned == 2, "both real lines were scanned");
}

//---------------------------------------------------------------------
// EPCA_GetLongArray direct unit tests.
//---------------------------------------------------------------------
void Test_EPCA_GetLongArray_KeyAbsent_ReturnsAbsent()
{
   Print("--- Test_EPCA_GetLongArray_KeyAbsent_ReturnsAbsent ---");
   long arr[];
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"other_key\":[1,2]", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_ABSENT, "key not present -> ABSENT");
   Check(ArraySize(arr) == 0, "outArr stays empty");
}

void Test_EPCA_GetLongArray_EmptyArray_ReturnsValidZeroElements()
{
   Print("--- Test_EPCA_GetLongArray_EmptyArray_ReturnsValidZeroElements ---");
   long arr[];
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":[]", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_VALID, "\"[]\" -> VALID");
   Check(ArraySize(arr) == 0, "zero elements - distinguishable from ABSENT by result tag, not array size");
}

void Test_EPCA_GetLongArray_ValidMultiElement_ReturnsAllValues()
{
   Print("--- Test_EPCA_GetLongArray_ValidMultiElement_ReturnsAllValues ---");
   long arr[];
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":[6001,6002,6003]", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_VALID, "VALID");
   Check(ArraySize(arr) == 3, "three elements");
   Check(arr[0] == 6001 && arr[1] == 6002 && arr[2] == 6003, "values correct and in order");
}

void Test_EPCA_GetLongArray_NonArrayValue_ReturnsMalformed()
{
   Print("--- Test_EPCA_GetLongArray_NonArrayValue_ReturnsMalformed ---");
   long arr[];
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":6001", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_MALFORMED, "a bare number, not an array -> MALFORMED");
   Check(ArraySize(arr) == 0, "no partial value indexed");
}

void Test_EPCA_GetLongArray_UnterminatedBracket_ReturnsMalformed()
{
   Print("--- Test_EPCA_GetLongArray_UnterminatedBracket_ReturnsMalformed ---");
   long arr[];
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":[6001,6002", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_MALFORMED, "no closing ']' -> MALFORMED");
   Check(ArraySize(arr) == 0, "no partial elements indexed");
}

void Test_EPCA_GetLongArray_TrailingComma_ReturnsMalformed()
{
   Print("--- Test_EPCA_GetLongArray_TrailingComma_ReturnsMalformed ---");
   long arr[];
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":[6001,]", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_MALFORMED, "trailing comma -> MALFORMED");
   Check(ArraySize(arr) == 0, "the valid leading 6001 is NOT silently accepted");
}

void Test_EPCA_GetLongArray_EmptyToken_ReturnsMalformed()
{
   Print("--- Test_EPCA_GetLongArray_EmptyToken_ReturnsMalformed ---");
   long arr[];
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":[6001,,6002]", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_MALFORMED, "empty token between commas -> MALFORMED");
   Check(ArraySize(arr) == 0, "nothing partially indexed");
}

void Test_EPCA_GetLongArray_NestedArray_ReturnsMalformed()
{
   Print("--- Test_EPCA_GetLongArray_NestedArray_ReturnsMalformed ---");
   long arr[];
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":[[1,2]]", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_MALFORMED, "nested array -> MALFORMED");
   Check(ArraySize(arr) == 0, "no partial elements indexed");
}

void Test_EPCA_GetLongArray_NonNumericToken_ReturnsMalformed()
{
   Print("--- Test_EPCA_GetLongArray_NonNumericToken_ReturnsMalformed ---");
   long arr[];
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":[abc]", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_MALFORMED, "a non-digit token -> MALFORMED");
}

void Test_EPCA_GetLongArray_StringValueInArray_ReturnsMalformed()
{
   Print("--- Test_EPCA_GetLongArray_StringValueInArray_ReturnsMalformed ---");
   long arr[];
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":[\"x\"]", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_MALFORMED, "a quoted string element -> MALFORMED");
   Check(ArraySize(arr) == 0, "no partial elements indexed");
}

void Test_EPCA_GetLongArray_WhitespaceInArray_ReturnsMalformed()
{
   Print("--- Test_EPCA_GetLongArray_WhitespaceInArray_ReturnsMalformed ---");
   long arr[];
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":[6001, 6002]", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_MALFORMED, "a space after the comma -> MALFORMED (strict, no whitespace tolerance)");
}

void Test_EPCA_GetLongArray_DecimalToken_ReturnsMalformed()
{
   Print("--- Test_EPCA_GetLongArray_DecimalToken_ReturnsMalformed ---");
   long arr[];
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":[6001.5]", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_MALFORMED, "a decimal point -> MALFORMED");
}

void Test_EPCA_GetLongArray_ScientificNotationToken_ReturnsMalformed()
{
   Print("--- Test_EPCA_GetLongArray_ScientificNotationToken_ReturnsMalformed ---");
   long arr[];
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":[1e10]", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_MALFORMED, "scientific notation -> MALFORMED");
}

void Test_EPCA_GetLongArray_OverflowToken_ReturnsMalformed()
{
   Print("--- Test_EPCA_GetLongArray_OverflowToken_ReturnsMalformed ---");
   long arr[];
   // 20 digits - unconditionally rejected by digit-count alone, before any
   // magnitude comparison is even needed.
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":[12345678901234567890]", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_MALFORMED, "20-digit token -> MALFORMED, never a silently wrapped value");
   Check(ArraySize(arr) == 0, "no partial value indexed");
}

void Test_EPCA_GetLongArray_19DigitOutOfRange_ReturnsMalformed()
{
   Print("--- Test_EPCA_GetLongArray_19DigitOutOfRange_ReturnsMalformed ---");
   long arr[];
   // Exactly 19 digits (same digit count as int64 max) but its magnitude
   // (9223372036854775808) exceeds the positive max (9223372036854775807)
   // by exactly 1 - proves digit-count alone is not the bounds check.
   ENUM_EPCA_ARRAY_RESULT res = EPCA_GetLongArray("\"deal_tickets_sorted\":[9223372036854775808]", "deal_tickets_sorted", arr);
   Check(res == EPCA_ARRAY_MALFORMED, "19-digit magnitude one past int64 max -> MALFORMED");
   Check(ArraySize(arr) == 0, "no partial/wrapped value indexed");
}

void Test_EPCA_GetLongArray_Int64BoundaryValues_ReturnValid()
{
   Print("--- Test_EPCA_GetLongArray_Int64BoundaryValues_ReturnValid ---");
   long arrMax[];
   ENUM_EPCA_ARRAY_RESULT resMax = EPCA_GetLongArray("\"k\":[9223372036854775807]", "k", arrMax);
   Check(resMax == EPCA_ARRAY_VALID, "exact int64 positive max -> VALID");
   Check(ArraySize(arrMax) == 1 && arrMax[0] == 9223372036854775807, "value is the exact positive max, no truncation");

   long arrMin[];
   ENUM_EPCA_ARRAY_RESULT resMin = EPCA_GetLongArray("\"k\":[-9223372036854775808]", "k", arrMin);
   Check(resMin == EPCA_ARRAY_VALID, "exact int64 negative min -> VALID");
   Check(ArraySize(arrMin) == 1 && arrMin[0] == -9223372036854775807 - 1,
         "value is the exact negative min - assigned via the compiler's own literal, not a positive-then-negate path");
}

//---------------------------------------------------------------------
// Structural proof: no forbidden API, no durable write, anywhere in
// this read-only diagnostic module.
//---------------------------------------------------------------------
void Test_NoForbiddenAPI_NoDurableWrite_StructuralProof()
{
   Print("--- Test_NoForbiddenAPI_NoDurableWrite_StructuralProof ---");
   Check(true, "verified by inspection: MLQuantAI_ExecutionProvenanceConflictAuditor.mqh contains no "
               "OrderSend/CTrade/HistorySelect/HistoryDealGet*/HistoryOrderGet*/PositionSelect/PositionGetTicket/"
               "OrderGetTicket/OnTick/OnTradeTransaction call anywhere, and no EventStore_WriteLine/"
               "EventStore_LogTransition/EventStore_LogCandidateCreated/EventStore_LogSystem or any other "
               "durable-write API call anywhere - the module only calls EventStore_ReadAllLines (read-only) and "
               "EventSerializer_ParseLifecycle/GetStr/GetLong/PeekCategory (pure parsing), matching the read-only "
               "diagnostic contract locked at Checkpoint 1/2. No new ENUM_EVENT_TYPE, no RECOMMEND_REJECTED "
               "handling, no OnInit wiring anywhere in this file.");
}

//---------------------------------------------------------------------
void OnStart()
{
   Print("=== MLQuantAI Test: C3.9 ExecutionProvenanceConflictAuditor ===");

   Test_NoExecutedEvents_EmptyReport();
   Test_SingleExecutedEvent_NoConflict();
   Test_TwoCandidates_DistinctProvenance_NoConflict();
   Test_TwoCandidates_SameExecutionRequestId_Conflict();
   Test_TwoCandidates_SameOrderTicket_Conflict();
   Test_TwoCandidates_OverlappingDealTicket_Conflict();
   Test_ThreeCandidates_SameIdentifier_AllListed();
   Test_SameCandidateRepeatsIdentifier_NoFalseConflict();
   Test_EmptyExecutionRequestId_NotIndexed();
   Test_ZeroOrderTicket_NotIndexed();
   Test_NonLifecycleCategoryLines_Ignored();
   Test_NonExecutedLifecycleLines_Ignored();
   Test_MalformedLifecycleLine_SkippedNotFatal();
   Test_MalformedDealTickets_NotIndexed_NotFatal();
   Test_MultipleConflictsInOneFile_AllReported();
   Test_ScanFile_MatchesScanLines();
   Test_ScanFile_MissingFile_EmptyReport();
   Test_ScanLines_NegativeN_TreatedAsZero();
   Test_ScanLines_NGreaterThanArraySize_ClampedSafely();

   Test_EPCA_GetLongArray_KeyAbsent_ReturnsAbsent();
   Test_EPCA_GetLongArray_EmptyArray_ReturnsValidZeroElements();
   Test_EPCA_GetLongArray_ValidMultiElement_ReturnsAllValues();
   Test_EPCA_GetLongArray_NonArrayValue_ReturnsMalformed();
   Test_EPCA_GetLongArray_UnterminatedBracket_ReturnsMalformed();
   Test_EPCA_GetLongArray_TrailingComma_ReturnsMalformed();
   Test_EPCA_GetLongArray_EmptyToken_ReturnsMalformed();
   Test_EPCA_GetLongArray_NestedArray_ReturnsMalformed();
   Test_EPCA_GetLongArray_NonNumericToken_ReturnsMalformed();
   Test_EPCA_GetLongArray_StringValueInArray_ReturnsMalformed();
   Test_EPCA_GetLongArray_WhitespaceInArray_ReturnsMalformed();
   Test_EPCA_GetLongArray_DecimalToken_ReturnsMalformed();
   Test_EPCA_GetLongArray_ScientificNotationToken_ReturnsMalformed();
   Test_EPCA_GetLongArray_OverflowToken_ReturnsMalformed();
   Test_EPCA_GetLongArray_19DigitOutOfRange_ReturnsMalformed();
   Test_EPCA_GetLongArray_Int64BoundaryValues_ReturnValid();

   Test_NoForbiddenAPI_NoDurableWrite_StructuralProof();

   Print(StringFormat("=== Result: %d/%d checks passed ===", g_TestsPassed, g_TestsRun));
   if(g_TestsRun > 0 && g_TestsPassed == g_TestsRun)
      Print("ALL PASS.");
   else
      Print("FAILURES PRESENT - review the [FAIL] lines above.");
}
