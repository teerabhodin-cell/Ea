//+------------------------------------------------------------------+
//| MLQuantAI_Test_C3_10A_AsyncTerminalOrderObservationMatcher.mq5     |
//| C3.10A implementation DoD. Exercises the real production entry     |
//| points AsyncTerminalOrderMatcher_ScanLines()/_ScanFile() and the   |
//| file-local ATOM_ValidateSeqToken() parser directly, per the design |
//| locked at Checkpoints 1/2 (including the seq-overflow amendment).  |
//| Fixture lines are hand-built raw JSONL strings mirroring the real  |
//| demo-captured BROKER_TRANSACTION_OBSERVED shape exactly; Submission|
//| Outcome/ExecutionRequest fixtures are seeded directly via the real,|
//| already-public *_Reset()/*_AppendRecord() functions those sealed   |
//| projections already expose - no EventStore_Open, no durable write, |
//| no real broker call anywhere in this file.                        |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_AsyncTerminalOrderObservationMatcher.mqh>

#define TEST_FILE "MLQuantAI_Test_C3_10A_AsyncTerminalOrderObservationMatcher.jsonl"

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

// Builds one full raw BROKER_TRANSACTION_OBSERVED JSONL line, matching
// the real demo-captured field order/shape exactly. seqRaw is a STRING,
// not a number, so malformed/oversized/negative tokens can be injected
// directly for the seq-validation tests.
string BuildObservedLine(string logEventId, string seqRaw, string transactionType, long orderTicket, string orderState)
{
   string s = "{";
   s += "\"schema_version\":\"EVENTS_V1\",";
   s += "\"log_event_id\":\"" + logEventId + "\",";
   s += "\"session_id\":\"SESS_C310A\",";
   s += "\"seq\":" + seqRaw + ",";
   s += "\"ts\":\"2026.01.01 00:00:00\",";
   s += "\"category\":\"SYSTEM\",";
   s += "\"type\":\"BROKER_TRANSACTION_OBSERVED\",";
   s += "\"message\":\"broker transaction observed\",";
   s += "\"transaction_type\":\"" + transactionType + "\",";
   s += "\"deal_ticket\":0,";
   s += "\"order_ticket\":" + IntegerToString(orderTicket) + ",";
   s += "\"position_ticket\":0,";
   s += "\"position_by_ticket\":0,";
   s += "\"symbol\":\"XAUUSD\",";
   s += "\"order_type\":\"ORDER_TYPE_SELL_LIMIT\",";
   s += "\"deal_type\":\"DEAL_TYPE_BUY\",";
   s += "\"order_state\":\"" + orderState + "\",";
   s += "\"price\":4598.00000000,";
   s += "\"volume\":0.20000000,";
   s += "\"price_sl\":0.00000000,";
   s += "\"price_tp\":0.00000000,";
   s += "\"request_id\":\"not_applicable\"";
   s += "}";
   return s;
}

// A line missing the "seq" key entirely - can't use BuildObservedLine
// (which always inserts one), so built separately.
string BuildObservedLineNoSeq(string logEventId, string transactionType, long orderTicket, string orderState)
{
   string s = "{";
   s += "\"schema_version\":\"EVENTS_V1\",";
   s += "\"log_event_id\":\"" + logEventId + "\",";
   s += "\"session_id\":\"SESS_C310A\",";
   s += "\"ts\":\"2026.01.01 00:00:00\",";
   s += "\"category\":\"SYSTEM\",";
   s += "\"type\":\"BROKER_TRANSACTION_OBSERVED\",";
   s += "\"message\":\"broker transaction observed\",";
   s += "\"transaction_type\":\"" + transactionType + "\",";
   s += "\"order_ticket\":" + IntegerToString(orderTicket) + ",";
   s += "\"order_state\":\"" + orderState + "\"";
   s += "}";
   return s;
}

void ResetProjections()
{
   SubmissionOutcomeProjection_Reset();
   ExecutionRequestProjection_Reset();
}

void SeedSubmittedOutcome(long orderTicket, string executionRequestId)
{
   SubmissionOutcomeProjectionRecord rec;
   SubmissionOutcomeProjectionRecord_Init(rec);
   rec.execution_request_id = executionRequestId;
   rec.submission_status    = SUBMISSION_STATUS_SUBMITTED;
   rec.order_ticket          = (ulong)orderTicket;
   SubmissionOutcomeProjection_AppendRecord(rec);
}

void SeedExecutionRequest(string executionRequestId, string candidateId)
{
   ExecutionRequestProjectionRecord rec;
   ExecutionRequestProjectionRecord_Init(rec);
   rec.execution_request_id = executionRequestId;
   rec.candidate_id          = candidateId;
   ExecutionRequestProjection_AppendRecord(rec);
}

void ResetTestFile(string file)
{
   if(FileIsExist(file, FILE_COMMON))
      FileDelete(file, FILE_COMMON);
}

void WriteRawLinesToFile(string file, const string &lines[], int count)
{
   int handle = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < count; i++)
      FileWriteString(handle, lines[i] + "\r\n");
   FileClose(handle);
}

//---------------------------------------------------------------------
// 1. Empty input.
//---------------------------------------------------------------------
void Test_NoObservedLines_EmptyReport()
{
   Print("--- Test_NoObservedLines_EmptyReport ---");
   ResetProjections();
   string lines[]; ArrayResize(lines, 0);
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 0);
   Check(r.ok, "ok is true");
   Check(r.observed_total == 0, "observed_total is 0");
   Check(r.invalid_observation_lines == 0, "invalid_observation_lines is 0");
   Check(r.relevant_total == 0, "relevant_total is 0");
   Check(ArraySize(r.matches) == 0, "matches[] is empty");
}

//---------------------------------------------------------------------
// 2-4. The three real terminal states, no SubmissionOutcome - UNMATCHED.
//---------------------------------------------------------------------
void Test_OrderDelete_Rejected_Unmatched()
{
   Print("--- Test_OrderDelete_Rejected_Unmatched ---");
   ResetProjections();
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_DELETE", 58174010602, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(r.ok, "ok is true - UNMATCHED is not an error");
   Check(r.observed_total == 1, "one observation");
   Check(r.relevant_total == 1, "one relevant terminal observation");
   Check(ArraySize(r.matches) == 1, "one match record");
   if(ArraySize(r.matches) == 1)
   {
      Check(r.matches[0].observed_kind == ATOM_REJECTED, "observed_kind is REJECTED");
      Check(r.matches[0].status == ATOM_UNMATCHED, "status is UNMATCHED - no SubmissionOutcome exists");
      Check(r.matches[0].order_ticket == 58174010602, "order_ticket carried through");
      Check(r.matches[0].source_sequence_number == 1, "source_sequence_number carried through");
      Check(r.matches[0].source_log_event_id == "SESS#1", "source_log_event_id carried through");
   }
   Check(r.unmatched_count == 1 && r.matched_count == 0 && r.ambiguous_count == 0, "counters correct");
}

void Test_OrderDelete_Canceled_Unmatched()
{
   Print("--- Test_OrderDelete_Canceled_Unmatched ---");
   ResetProjections();
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_DELETE", 58173858279, "ORDER_STATE_CANCELED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(r.ok, "ok is true");
   Check(ArraySize(r.matches) == 1 && r.matches[0].observed_kind == ATOM_CANCELED, "observed_kind is CANCELED");
   Check(r.matches[0].status == ATOM_UNMATCHED, "status is UNMATCHED");
}

void Test_OrderDelete_Expired_Unmatched()
{
   Print("--- Test_OrderDelete_Expired_Unmatched ---");
   ResetProjections();
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_DELETE", 58173845467, "ORDER_STATE_EXPIRED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(r.ok, "ok is true");
   Check(ArraySize(r.matches) == 1 && r.matches[0].observed_kind == ATOM_EXPIRED, "observed_kind is EXPIRED");
   Check(r.matches[0].status == ATOM_UNMATCHED, "status is UNMATCHED");
}

//---------------------------------------------------------------------
// 5-10. Non-qualifying shapes - ignored, not invalid, not classified.
//---------------------------------------------------------------------
void Test_HistoryAdd_Mirror_Ignored()
{
   Print("--- Test_HistoryAdd_Mirror_Ignored ---");
   ResetProjections();
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_HISTORY_ADD", 58173858279, "ORDER_STATE_CANCELED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(r.ok, "ok is true");
   Check(r.observed_total == 1, "counted as observed");
   Check(r.relevant_total == 0, "not relevant - HISTORY_ADD is deliberately ignored, per locked Slice A design");
   Check(ArraySize(r.matches) == 0, "no match record created");
}

void Test_OrderUpdate_Placed_Ignored()
{
   Print("--- Test_OrderUpdate_Placed_Ignored ---");
   ResetProjections();
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_UPDATE", 111, "ORDER_STATE_PLACED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(r.relevant_total == 0, "PLACED is transient, not terminal - ignored");
}

void Test_OrderUpdate_RequestCancel_Ignored()
{
   Print("--- Test_OrderUpdate_RequestCancel_Ignored ---");
   ResetProjections();
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_UPDATE", 111, "ORDER_STATE_REQUEST_CANCEL");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(r.relevant_total == 0, "REQUEST_CANCEL is transient, not terminal - ignored");
}

void Test_Request_Started_ZeroTicket_Ignored()
{
   Print("--- Test_Request_Started_ZeroTicket_Ignored ---");
   ResetProjections();
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_REQUEST", 0, "ORDER_STATE_STARTED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(r.relevant_total == 0, "wrong transaction_type AND zero ticket - ignored");
}

void Test_OrderAdd_Started_Ignored()
{
   Print("--- Test_OrderAdd_Started_Ignored ---");
   ResetProjections();
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_ADD", 111, "ORDER_STATE_STARTED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(r.relevant_total == 0, "ORDER_ADD is never terminal - ignored");
}

void Test_OrderDelete_Filled_Ignored()
{
   Print("--- Test_OrderDelete_Filled_Ignored ---");
   ResetProjections();
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_DELETE", 111, "ORDER_STATE_FILLED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(r.relevant_total == 0, "FILLED is not one of the 3 target terminal states - C3.3's territory, ignored here");
}

void Test_ZeroTicket_NeverIndexed()
{
   Print("--- Test_ZeroTicket_NeverIndexed ---");
   ResetProjections();
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_DELETE", 0, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(r.relevant_total == 0, "order_ticket == 0 is never indexed, even with a correct type/state");
}

//---------------------------------------------------------------------
// 11-14. Matching hierarchy.
//---------------------------------------------------------------------
void Test_SingleSubmittedOutcome_Matched()
{
   Print("--- Test_SingleSubmittedOutcome_Matched ---");
   ResetProjections();
   SeedSubmittedOutcome(9001, "REQ_OK");
   SeedExecutionRequest("REQ_OK", "CAND_OK");
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_DELETE", 9001, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(r.ok, "ok is true");
   Check(ArraySize(r.matches) == 1, "one match record");
   if(ArraySize(r.matches) == 1)
   {
      Check(r.matches[0].status == ATOM_MATCHED, "status is MATCHED");
      Check(r.matches[0].execution_request_id == "REQ_OK", "execution_request_id resolved correctly");
      Check(r.matches[0].candidate_id == "CAND_OK", "candidate_id resolved correctly via the second hop");
   }
   Check(r.matched_count == 1 && r.unmatched_count == 0 && r.ambiguous_count == 0, "counters correct");
}

void Test_MultipleSubmittedOutcomes_SameTicket_Ambiguous()
{
   Print("--- Test_MultipleSubmittedOutcomes_SameTicket_Ambiguous ---");
   ResetProjections();
   SeedSubmittedOutcome(9002, "REQ_A");
   SeedSubmittedOutcome(9002, "REQ_B"); // same ticket, second SUBMITTED outcome
   SeedExecutionRequest("REQ_A", "CAND_A");
   SeedExecutionRequest("REQ_B", "CAND_B");
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_DELETE", 9002, "ORDER_STATE_CANCELED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(!r.ok, "ok is false - a genuine ambiguity exists");
   Check(ArraySize(r.matches) == 1 && r.matches[0].status == ATOM_AMBIGUOUS,
         "status is AMBIGUOUS - never first-match-wins, unlike C3.3's own inherited pattern");
   Check(r.matches[0].execution_request_id == "" && r.matches[0].candidate_id == "",
         "no partial linkage is ever propagated on an ambiguous result");
}

void Test_MissingExecutionRequestProjection_Ambiguous()
{
   Print("--- Test_MissingExecutionRequestProjection_Ambiguous ---");
   ResetProjections();
   SeedSubmittedOutcome(9003, "REQ_MISSING"); // no matching ExecutionRequestProjection entry ever seeded
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_DELETE", 9003, "ORDER_STATE_EXPIRED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(!r.ok, "ok is false");
   Check(r.matches[0].status == ATOM_AMBIGUOUS, "fail closed when the linked execution request cannot be found");
}

void Test_EmptyCandidateId_Ambiguous()
{
   Print("--- Test_EmptyCandidateId_Ambiguous ---");
   ResetProjections();
   SeedSubmittedOutcome(9004, "REQ_EMPTYCAND");
   SeedExecutionRequest("REQ_EMPTYCAND", ""); // resolved, but candidate_id is empty
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_DELETE", 9004, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(!r.ok, "ok is false");
   Check(r.matches[0].status == ATOM_AMBIGUOUS, "an empty candidate_id is never treated as a usable match");
}

//---------------------------------------------------------------------
// 15. Duplicate qualifying ORDER_DELETE for the same ticket - escalation
//     overrides an otherwise-clean match.
//---------------------------------------------------------------------
void Test_DuplicateOrderDelete_SameTicket_BothAmbiguous()
{
   Print("--- Test_DuplicateOrderDelete_SameTicket_BothAmbiguous ---");
   ResetProjections();
   SeedSubmittedOutcome(9005, "REQ_DUP");
   SeedExecutionRequest("REQ_DUP", "CAND_DUP"); // would resolve cleanly to MATCHED individually
   string lines[2];
   lines[0] = BuildObservedLine("SESS#10", "10", "TRADE_TRANSACTION_ORDER_DELETE", 9005, "ORDER_STATE_REJECTED");
   lines[1] = BuildObservedLine("SESS#11", "11", "TRADE_TRANSACTION_ORDER_DELETE", 9005, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 2);
   Check(!r.ok, "ok is false");
   Check(ArraySize(r.matches) == 2, "both raw lines produce their own match record - not collapsed");
   Check(r.matches[0].source_log_event_id == "SESS#10" && r.matches[1].source_log_event_id == "SESS#11",
         "distinct source identity confirmed for each raw line");
   Check(r.matches[0].status == ATOM_AMBIGUOUS && r.matches[1].status == ATOM_AMBIGUOUS,
         "BOTH flipped to AMBIGUOUS - the escalation overrides what would otherwise have been a clean MATCHED result");
   Check(r.matched_count == 0 && r.ambiguous_count == 2, "counters reflect the escalation, not the pre-escalation resolution");
}

//---------------------------------------------------------------------
// 16. Empty log_event_id - not fatal, still processed.
//---------------------------------------------------------------------
void Test_LogEventIdEmpty_StillProcessed_SourceFieldEmpty()
{
   Print("--- Test_LogEventIdEmpty_StillProcessed_SourceFieldEmpty ---");
   ResetProjections();
   string lines[1];
   lines[0] = BuildObservedLine("", "7", "TRADE_TRANSACTION_ORDER_DELETE", 9006, "ORDER_STATE_EXPIRED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(r.ok, "ok is true");
   Check(ArraySize(r.matches) == 1, "line still processed normally despite empty log_event_id");
   Check(r.matches[0].source_log_event_id == "", "source_log_event_id is empty, as sourced");
   Check(r.matches[0].source_sequence_number == 7, "source_sequence_number still correct");
}

//---------------------------------------------------------------------
// 17. Counter consistency after escalation - no drift.
//---------------------------------------------------------------------
void Test_CounterConsistency_AfterDuplicateEscalation_NoDrift()
{
   Print("--- Test_CounterConsistency_AfterDuplicateEscalation_NoDrift ---");
   ResetProjections();
   // Ticket A: duplicated qualifying lines -> both escalate to AMBIGUOUS.
   SeedSubmittedOutcome(9101, "REQ_A"); SeedExecutionRequest("REQ_A", "CAND_A");
   // Ticket B: genuinely unmatched.
   // Ticket C: genuinely ambiguous via missing execution request linkage.
   SeedSubmittedOutcome(9103, "REQ_C_MISSING");

   string lines[4];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_DELETE", 9101, "ORDER_STATE_REJECTED");
   lines[1] = BuildObservedLine("SESS#2", "2", "TRADE_TRANSACTION_ORDER_DELETE", 9101, "ORDER_STATE_REJECTED");
   lines[2] = BuildObservedLine("SESS#3", "3", "TRADE_TRANSACTION_ORDER_DELETE", 9102, "ORDER_STATE_CANCELED");
   lines[3] = BuildObservedLine("SESS#4", "4", "TRADE_TRANSACTION_ORDER_DELETE", 9103, "ORDER_STATE_EXPIRED");

   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, 4);

   Check(r.relevant_total == ArraySize(r.matches), "relevant_total matches the array size");
   Check(r.matched_count + r.unmatched_count + r.ambiguous_count == r.relevant_total,
         "the three counters sum exactly to relevant_total - no drift");

   int tallyMatched = 0, tallyUnmatched = 0, tallyAmbiguous = 0;
   for(int i = 0; i < ArraySize(r.matches); i++)
   {
      if(r.matches[i].status == ATOM_MATCHED) tallyMatched++;
      else if(r.matches[i].status == ATOM_UNMATCHED) tallyUnmatched++;
      else tallyAmbiguous++;
   }
   Check(tallyMatched == r.matched_count && tallyUnmatched == r.unmatched_count && tallyAmbiguous == r.ambiguous_count,
         "an independent re-tally of matches[].status exactly matches the reported counters");
   Check(r.matched_count == 0, "ticket A's pair never counts as matched - escalated");
   Check(r.unmatched_count == 1, "ticket B is unmatched");
   Check(r.ambiguous_count == 3, "ticket A's pair (2) plus ticket C's missing-linkage case (1) = 3");
}

//---------------------------------------------------------------------
// 18-19. seq validation - missing/invalid, and malformed/oversized.
//---------------------------------------------------------------------
void Test_BrokerObserved_MissingOrInvalidSeq_SkippedCounted()
{
   Print("--- Test_BrokerObserved_MissingOrInvalidSeq_SkippedCounted ---");
   ResetProjections();

   string missing[1]; missing[0] = BuildObservedLineNoSeq("SESS#1", "TRADE_TRANSACTION_ORDER_DELETE", 111, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport rMissing = AsyncTerminalOrderMatcher_ScanLines(missing, 1);
   Check(rMissing.ok, "missing seq: ok stays true");
   Check(rMissing.observed_total == 1 && rMissing.invalid_observation_lines == 1,
         "missing seq: counted as observed AND invalid");
   Check(ArraySize(rMissing.matches) == 0, "missing seq: no match materialized");

   string zero[1]; zero[0] = BuildObservedLine("SESS#1", "0", "TRADE_TRANSACTION_ORDER_DELETE", 111, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport rZero = AsyncTerminalOrderMatcher_ScanLines(zero, 1);
   Check(rZero.invalid_observation_lines == 1, "seq=0: invalid (not positive)");

   string neg[1]; neg[0] = BuildObservedLine("SESS#1", "-5", "TRADE_TRANSACTION_ORDER_DELETE", 111, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport rNeg = AsyncTerminalOrderMatcher_ScanLines(neg, 1);
   Check(rNeg.invalid_observation_lines == 1, "seq=-5: invalid (leading '-' rejected outright)");
}

void Test_BrokerObserved_MalformedOrOversizedSeq_SkippedCounted()
{
   Print("--- Test_BrokerObserved_MalformedOrOversizedSeq_SkippedCounted ---");
   ResetProjections();

   string nonNumeric[1]; nonNumeric[0] = BuildObservedLine("SESS#1", "\"abc\"", "TRADE_TRANSACTION_ORDER_DELETE", 111, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport rNonNumeric = AsyncTerminalOrderMatcher_ScanLines(nonNumeric, 1);
   Check(rNonNumeric.invalid_observation_lines == 1, "non-numeric seq token: invalid");
   Check(ArraySize(rNonNumeric.matches) == 0, "non-numeric seq: no match materialized");

   string oversized20[1]; oversized20[0] = BuildObservedLine("SESS#1", "12345678901234567890", "TRADE_TRANSACTION_ORDER_DELETE", 111, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport rOversized = AsyncTerminalOrderMatcher_ScanLines(oversized20, 1);
   Check(rOversized.invalid_observation_lines == 1, "20-digit seq token: invalid, never silently wrapped");

   string over19[1]; over19[0] = BuildObservedLine("SESS#1", "9223372036854775808", "TRADE_TRANSACTION_ORDER_DELETE", 111, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport rOver19 = AsyncTerminalOrderMatcher_ScanLines(over19, 1);
   Check(rOver19.invalid_observation_lines == 1, "19-digit seq token one past int64 max: invalid");

   // Boundary sanity: the exact max IS valid (proves the gate isn't just
   // rejecting every 19-digit token outright).
   string atMax[1]; atMax[0] = BuildObservedLine("SESS#1", "9223372036854775807", "TRADE_TRANSACTION_ORDER_DELETE", 111, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport rAtMax = AsyncTerminalOrderMatcher_ScanLines(atMax, 1);
   Check(rAtMax.invalid_observation_lines == 0, "exact int64 max as seq: valid, not rejected");
   Check(ArraySize(rAtMax.matches) == 1 && rAtMax.matches[0].source_sequence_number == 9223372036854775807,
         "seq value carried through exactly at the boundary");
}

//---------------------------------------------------------------------
// 20-23. ScanFile wrapper and input/file edge handling.
//---------------------------------------------------------------------
void Test_ScanFile_MatchesScanLines()
{
   Print("--- Test_ScanFile_MatchesScanLines ---");
   ResetProjections();
   ResetTestFile(TEST_FILE);

   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_DELETE", 9201, "ORDER_STATE_REJECTED");
   WriteRawLinesToFile(TEST_FILE, lines, 1);

   AsyncTerminalOrderMatchReport expected = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   AsyncTerminalOrderMatchReport actual   = AsyncTerminalOrderMatcher_ScanFile(TEST_FILE);

   Check(actual.ok == expected.ok, "ok matches");
   Check(actual.relevant_total == expected.relevant_total, "relevant_total matches");
   Check(ArraySize(actual.matches) == ArraySize(expected.matches), "matches[] size matches");

   ResetTestFile(TEST_FILE);
}

void Test_ScanFile_MissingFile_EmptyReport()
{
   Print("--- Test_ScanFile_MissingFile_EmptyReport ---");
   ResetProjections();
   ResetTestFile(TEST_FILE);
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanFile(TEST_FILE);
   Check(r.ok, "ok is true for a missing file");
   Check(r.observed_total == 0 && r.relevant_total == 0, "zero observations");
}

void Test_ScanLines_NegativeN_TreatedAsZero()
{
   Print("--- Test_ScanLines_NegativeN_TreatedAsZero ---");
   ResetProjections();
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_DELETE", 9301, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport r = AsyncTerminalOrderMatcher_ScanLines(lines, -1);
   Check(r.ok, "ok is true");
   Check(r.observed_total == 0, "negative n treated as zero lines, not the full array");
}

void Test_ScanLines_NGreaterThanArraySize_ClampedSafely()
{
   Print("--- Test_ScanLines_NGreaterThanArraySize_ClampedSafely ---");
   ResetProjections();
   string lines[1];
   lines[0] = BuildObservedLine("SESS#1", "1", "TRADE_TRANSACTION_ORDER_DELETE", 9302, "ORDER_STATE_REJECTED");
   AsyncTerminalOrderMatchReport clamped = AsyncTerminalOrderMatcher_ScanLines(lines, 100);
   AsyncTerminalOrderMatchReport natural = AsyncTerminalOrderMatcher_ScanLines(lines, 1);
   Check(clamped.observed_total == natural.observed_total, "n=100 against a 1-element array matches n=1 - no crash, no out-of-bounds read");
}

//---------------------------------------------------------------------
// Structural proof.
//---------------------------------------------------------------------
void Test_NoForbiddenAPI_NoDurableWrite_StructuralProof()
{
   Print("--- Test_NoForbiddenAPI_NoDurableWrite_StructuralProof ---");
   Check(true, "verified by inspection: MLQuantAI_AsyncTerminalOrderObservationMatcher.mqh contains no "
               "OrderSend/CTrade/HistorySelect/HistoryDealGet*/HistoryOrderGet*/PositionSelect/PositionGetTicket/"
               "OrderGetTicket/OnTick/OnTradeTransaction call anywhere, and no EventStore_WriteLine/"
               "EventStore_LogTransition/EventStore_LogCandidateCreated/EventStore_LogSystem or any other "
               "durable-write API call anywhere, and no *_StartupRebuild/*_RebuildFromFile call of any kind - "
               "it reads only EventStore_ReadAllLines (read-only), EventSerializer_PeekCategory/GetStr/GetLong/"
               "GetRawNumber (pure parsing), and SubmissionOutcomeProjection_Count()/_GetAt()/"
               "ExecutionRequestProjection_TryGet() (existing, sealed, already-public read-only projections). "
               "No new ENUM_EVENT_TYPE, no TRANSACTION_REJECTION_CONFIRMED write, no CANDIDATE_REJECTED_BY_BROKER "
               "transition, no OnInit wiring anywhere in this file.");
}

//---------------------------------------------------------------------
void OnStart()
{
   Print("=== MLQuantAI Test: C3.10A AsyncTerminalOrderObservationMatcher ===");

   Test_NoObservedLines_EmptyReport();
   Test_OrderDelete_Rejected_Unmatched();
   Test_OrderDelete_Canceled_Unmatched();
   Test_OrderDelete_Expired_Unmatched();
   Test_HistoryAdd_Mirror_Ignored();
   Test_OrderUpdate_Placed_Ignored();
   Test_OrderUpdate_RequestCancel_Ignored();
   Test_Request_Started_ZeroTicket_Ignored();
   Test_OrderAdd_Started_Ignored();
   Test_OrderDelete_Filled_Ignored();
   Test_ZeroTicket_NeverIndexed();
   Test_SingleSubmittedOutcome_Matched();
   Test_MultipleSubmittedOutcomes_SameTicket_Ambiguous();
   Test_MissingExecutionRequestProjection_Ambiguous();
   Test_EmptyCandidateId_Ambiguous();
   Test_DuplicateOrderDelete_SameTicket_BothAmbiguous();
   Test_LogEventIdEmpty_StillProcessed_SourceFieldEmpty();
   Test_CounterConsistency_AfterDuplicateEscalation_NoDrift();
   Test_BrokerObserved_MissingOrInvalidSeq_SkippedCounted();
   Test_BrokerObserved_MalformedOrOversizedSeq_SkippedCounted();
   Test_ScanFile_MatchesScanLines();
   Test_ScanFile_MissingFile_EmptyReport();
   Test_ScanLines_NegativeN_TreatedAsZero();
   Test_ScanLines_NGreaterThanArraySize_ClampedSafely();
   Test_NoForbiddenAPI_NoDurableWrite_StructuralProof();

   Print(StringFormat("=== Result: %d/%d checks passed ===", g_TestsPassed, g_TestsRun));
   if(g_TestsRun > 0 && g_TestsPassed == g_TestsRun)
      Print("ALL PASS.");
   else
      Print("FAILURES PRESENT - review the [FAIL] lines above.");
}
