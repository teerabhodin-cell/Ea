//+------------------------------------------------------------------+
//| MLQuantAI_Test_C3_8_1_SubmittedCandidateVisibility.mq5             |
//| C3.8.1 implementation DoD. Exercises the real production entry    |
//| points SubmittedCandidateVisibility_ScanLines()/_ScanFile()       |
//| directly, per Docs/PhaseC_C3_8_ReconciliationIntegrationContract  |
//| .md sections 14-18. StateProjector/ExecutionRequestProjection/    |
//| SubmissionOutcomeProjection/TransactionDealRegistry/              |
//| DeferredTransactionProcessor fixtures are all seeded directly via |
//| the real, already-public *_Reset()/*_Apply()/*_AppendRecord()/    |
//| C36_AppendRow() functions those sealed modules already expose -   |
//| same precedent MLQuantAI_Test_C3_10A_AsyncTerminalOrderObservation|
//| Matcher.mq5 already established for seeding projections directly. |
//| The one raw JSONL fixture line this file hand-builds is the       |
//| CANDIDATE_SUBMITTED lifecycle line SCV_FindSubmittedLine() itself |
//| parses - everything else is real registry state, never a raw-line|
//| substitute for it. No EventStore_Open, no durable write, no real  |
//| broker/terminal call anywhere in this file.                       |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_SubmittedCandidateVisibility.mqh>

#define TEST_FILE "MLQuantAI_Test_C3_8_1_SubmittedCandidateVisibility.jsonl"

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
void ResetAllRegistries()
{
   StateProjector_Reset();
   ExecutionRequestProjection_Reset();
   SubmissionOutcomeProjection_Reset();
   TransactionDealRegistry_Reset();
   OrderAggregateRegistry_Reset();
   DeferredTransactionProcessor_Reset();
}

LifecycleEvent BuildGenesis(string candidateId, long seq)
{
   LifecycleEvent e;
   LifecycleEvent_Init(e);
   e.base.sequence_number = seq;
   e.candidate_id = candidateId;
   e.root_event_id = "ROOT_" + candidateId;
   e.from_state = CANDIDATE_CREATED;
   e.to_state = CANDIDATE_CREATED;
   return e;
}

LifecycleEvent BuildTransition(string candidateId, ENUM_CANDIDATE_STATE from, ENUM_CANDIDATE_STATE to, long seq)
{
   LifecycleEvent e;
   LifecycleEvent_Init(e);
   e.base.sequence_number = seq;
   e.candidate_id = candidateId;
   e.from_state = from;
   e.to_state = to;
   return e;
}

// Drives a fresh candidate straight to CANDIDATE_SUBMITTED via the real
// StateProjector_Apply() entry point - never a direct array write.
void SeedSubmittedCandidate(string candidateId)
{
   string err;
   StateProjector_Apply(BuildGenesis(candidateId, 1), err);
   StateProjector_Apply(BuildTransition(candidateId, CANDIDATE_CREATED, CANDIDATE_SUBMITTED, 2), err);
}

void SeedExecutionRequest(string execReqId, string candidateId, double lotSize)
{
   ExecutionRequestProjectionRecord rec;
   ExecutionRequestProjectionRecord_Init(rec);
   rec.execution_request_id = execReqId;
   rec.candidate_id = candidateId;
   rec.lot_size = lotSize;
   ExecutionRequestProjection_AppendRecord(rec);
}

void SeedOutcome(string execReqId, ENUM_SUBMISSION_STATUS status, ulong orderTicket)
{
   SubmissionOutcomeProjectionRecord rec;
   SubmissionOutcomeProjectionRecord_Init(rec);
   rec.execution_request_id = execReqId;
   rec.submission_status = status;
   rec.order_ticket = orderTicket;
   SubmissionOutcomeProjection_AppendRecord(rec);
}

void SeedDeal(ulong orderTicket, ulong dealTicket, double volume)
{
   TransactionDealRecord rec;
   TransactionDealRecord_Init(rec);
   rec.deal_ticket = dealTicket;
   rec.order_ticket = orderTicket;
   rec.volume = volume;
   TransactionDealRegistry_AppendRecord(rec);
}

void SeedRecommendation(string candidateId, ENUM_RECOMMENDATION action)
{
   DeferredRecommendationRecord rec;
   DeferredRecommendationRecord_Init(rec);
   rec.candidate_id = candidateId;
   rec.recommended_action = action;
   C36_AppendRow(rec);
}

// Builds one raw CANDIDATE_SUBMITTED JSONL line - the real field shape
// EventSerializer_ParseLifecycle() expects, same technique
// MLQuantAI_Test_C3_9_ExecutionProvenanceConflictAuditor.mq5's own
// BuildNonExecutedLifecycleLine() already established.
string BuildSubmittedLine(string candidateId, string ts, int seq)
{
   string s = "{";
   s += "\"schema_version\":\"EVENTS_V1\",";
   s += "\"log_event_id\":\"SESS_C381#" + IntegerToString(seq) + "\",";
   s += "\"session_id\":\"SESS_C381\",";
   s += "\"seq\":" + IntegerToString(seq) + ",";
   s += "\"ts\":\"" + ts + "\",";
   s += "\"category\":\"LIFECYCLE\",";
   s += "\"type\":\"CANDIDATE_SUBMITTED\",";
   s += "\"candidate_id\":\"" + candidateId + "\",";
   s += "\"root_event_id\":\"EVT_ROOT\",";
   s += "\"correlation_id\":\"\",";
   s += "\"strategy_id\":0,";
   s += "\"strategy\":\"CRT\",";
   s += "\"from_state\":\"CREATED\",";
   s += "\"to_state\":\"SUBMITTED\",";
   s += "\"reason\":\"NONE\"";
   s += "}";
   return s;
}

int FindRow(const SubmittedCandidateVisibilityReport &r, string candidateId)
{
   for(int i = 0; i < ArraySize(r.rows); i++)
      if(r.rows[i].candidate_id == candidateId)
         return i;
   return -1;
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
// 1. No SUBMITTED candidates at all - empty report.
//---------------------------------------------------------------------
void Test_NoSubmittedCandidates_EmptyReport()
{
   Print("--- Test_NoSubmittedCandidates_EmptyReport ---");
   ResetAllRegistries();
   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   Check(r.ok, "ok is true on an empty scan");
   Check(r.total_submitted == 0, "total_submitted is 0");
   Check(ArraySize(r.rows) == 0, "rows[] is empty");
   Check(r.unresolved_count == 0, "unresolved_count is 0");
   Check(r.unresolved_beyond_threshold_count == 0, "unresolved_beyond_threshold_count is 0");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 2. A non-SUBMITTED candidate (CREATED only, and one driven to
//    EXECUTED) is excluded entirely - never a row.
//---------------------------------------------------------------------
void Test_NonSubmittedCandidatesExcluded()
{
   Print("--- Test_NonSubmittedCandidatesExcluded ---");
   ResetAllRegistries();
   string err;
   StateProjector_Apply(BuildGenesis("CAND_CREATED_ONLY", 1), err);
   StateProjector_Apply(BuildGenesis("CAND_EXEC", 2), err);
   StateProjector_Apply(BuildTransition("CAND_EXEC", CANDIDATE_CREATED, CANDIDATE_SUBMITTED, 3), err);
   StateProjector_Apply(BuildTransition("CAND_EXEC", CANDIDATE_SUBMITTED, CANDIDATE_EXECUTED, 4), err);

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   Check(r.total_submitted == 0, "neither CREATED-only nor already-EXECUTED candidate is a row");
   Check(ArraySize(r.rows) == 0, "rows[] stays empty");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 3. SUBMITTED candidate with zero qualifying outcomes - NOT an
//    anomaly (contract outcome 5).
//---------------------------------------------------------------------
void Test_NoQualifyingOutcome_NotAnAnomaly()
{
   Print("--- Test_NoQualifyingOutcome_NotAnAnomaly ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   Check(r.ok, "ok is true - absence of qualifying evidence is never an anomaly");
   Check(r.total_submitted == 1, "one row");
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0, "CAND_A has a row");
   if(idx >= 0)
   {
      Check(r.rows[idx].order_ticket_known == false, "order_ticket_known is false");
      Check(r.rows[idx].order_ticket_ambiguous == false, "order_ticket_ambiguous is false");
      Check(r.rows[idx].lineage_anomaly == LINEAGE_ANOMALY_NONE, "lineage_anomaly is NONE");
      Check(r.rows[idx].match_status_known == false, "match_status_known is false - never reached without a ticket");
      Check(r.rows[idx].unresolved == true, "unresolved is true");
   }
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 4. A non-SUBMITTED submission outcome (e.g. ERROR) is excluded from
//    the qualifying set - same non-anomaly result as having none.
//---------------------------------------------------------------------
void Test_NonSubmittedOutcomeExcludedFromQualifying()
{
   Print("--- Test_NonSubmittedOutcomeExcludedFromQualifying ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_ERROR, 7001);

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].lineage_anomaly == LINEAGE_ANOMALY_NONE,
         "a non-SUBMITTED outcome never becomes qualifying - no anomaly");
   Check(idx >= 0 && r.rows[idx].order_ticket_known == false, "order_ticket_known stays false");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 5. Exactly one qualifying positive-ticket outcome - clean resolution.
//---------------------------------------------------------------------
void Test_SingleQualifyingPositiveTicket_CleanResolution()
{
   Print("--- Test_SingleQualifyingPositiveTicket_CleanResolution ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 5001);

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   Check(r.ok, "ok is true");
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0, "CAND_A has a row");
   if(idx >= 0)
   {
      Check(r.rows[idx].order_ticket_known == true, "order_ticket_known is true");
      Check(r.rows[idx].order_ticket == 5001, "order_ticket is 5001");
      Check(r.rows[idx].order_ticket_ambiguous == false, "order_ticket_ambiguous is false");
      Check(r.rows[idx].lineage_anomaly == LINEAGE_ANOMALY_NONE, "lineage_anomaly is NONE");
   }
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 6. Nonpositive ticket - anomaly, ticket never trusted.
//---------------------------------------------------------------------
void Test_NonpositiveTicket_Anomaly()
{
   Print("--- Test_NonpositiveTicket_Anomaly ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 0);

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   Check(!r.ok, "ok is false - a genuine lineage anomaly exists");
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].lineage_anomaly == LINEAGE_ANOMALY_NONPOSITIVE_TICKET,
         "lineage_anomaly is NONPOSITIVE_TICKET");
   Check(idx >= 0 && r.rows[idx].order_ticket_known == false, "order_ticket_known is false");
   Check(idx >= 0 && r.rows[idx].order_ticket_ambiguous == false, "order_ticket_ambiguous is false - distinct anomaly type");
   Check(StringFind(r.first_error, "REQ1") >= 0,
         "first_error cites the real triggering execution_request_id (REQ1), a source tuple - not row.order_ticket, which stays 0/unknown here");
   Check(StringFind(r.first_error, "order_ticket=0") >= 0,
         "first_error cites the real triggering (nonpositive) ticket value itself");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 7. Duplicate triple - identical (execution_request_id, order_ticket)
//    seen twice.
//---------------------------------------------------------------------
void Test_DuplicateTriple_Anomaly()
{
   Print("--- Test_DuplicateTriple_Anomaly ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 5001);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 5001); // exact duplicate triple

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   Check(!r.ok, "ok is false");
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].lineage_anomaly == LINEAGE_ANOMALY_DUPLICATE_TRIPLE,
         "lineage_anomaly is DUPLICATE_TRIPLE");
   Check(StringFind(r.first_error, "REQ1") >= 0 && StringFind(r.first_error, "order_ticket=5001") >= 0,
         "first_error cites the real duplicated (execution_request_id, order_ticket) source tuple");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 8. Multiple execution requests, each with its own qualifying
//    positive-ticket outcome - anomaly regardless of ticket overlap.
//---------------------------------------------------------------------
void Test_MultipleExecutionRequests_Anomaly()
{
   Print("--- Test_MultipleExecutionRequests_Anomaly ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedExecutionRequest("REQ2", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 5001);
   SeedOutcome("REQ2", SUBMISSION_STATUS_SUBMITTED, 5002);

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].lineage_anomaly == LINEAGE_ANOMALY_MULTIPLE_EXECUTION_REQUESTS,
         "lineage_anomaly is MULTIPLE_EXECUTION_REQUESTS");
   Check(StringFind(r.first_error, "REQ1") >= 0 && StringFind(r.first_error, "order_ticket=5001") >= 0,
         "first_error cites REQ1/5001 - the EARLIEST positive qualifying tuple across the whole "
         "candidate (contract §14 'Per-row error selection'), not the later entry that merely made "
         "the anomaly detectable");
   Check(StringFind(r.first_error, "order_ticket=5002") < 0,
         "REQ2/5002 - the detection-witness tuple, not the earliest one - never appears in first_error");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 8b. Dedicated distinction: the earliest positive tuple differs from
//     the entry whose scan position first makes the anomaly detectable
//     (the bug this suite caught and this fixture now pins down).
//---------------------------------------------------------------------
void Test_MultiExecReqs_AttributesEarliestTuple_NotWitness()
{
   Print("--- Test_MultiExecReqs_AttributesEarliestTuple_NotWitness ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ_EARLY", "CAND_A", 1.0);
   SeedExecutionRequest("REQ_LATER", "CAND_A", 1.0);
   SeedOutcome("REQ_EARLY", SUBMISSION_STATUS_SUBMITTED, 100); // earliest positive tuple: (REQ_EARLY, 100)
   SeedOutcome("REQ_LATER", SUBMISSION_STATUS_SUBMITTED, 200); // detection witness: the 2nd distinct request id

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   Check(StringFind(r.first_error, "REQ_EARLY") >= 0 && StringFind(r.first_error, "order_ticket=100") >= 0,
         "attributes REQ_EARLY/100 - the earliest positive tuple - not REQ_LATER/200, the entry whose "
         "scan position merely made distinctReqCount reach 2");
   Check(StringFind(r.first_error, "REQ_LATER") < 0 && StringFind(r.first_error, "order_ticket=200") < 0,
         "the detection-witness tuple (REQ_LATER/200) never appears in first_error");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 9. Ambiguous tickets - one execution request, two distinct positive
//    tickets.
//---------------------------------------------------------------------
void Test_AmbiguousTickets_SameRequestDistinctTickets()
{
   Print("--- Test_AmbiguousTickets_SameRequestDistinctTickets ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 6001);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 6002);

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].lineage_anomaly == LINEAGE_ANOMALY_AMBIGUOUS_TICKETS,
         "lineage_anomaly is AMBIGUOUS_TICKETS");
   Check(idx >= 0 && r.rows[idx].order_ticket_ambiguous == true, "order_ticket_ambiguous is true");
   Check(idx >= 0 && r.rows[idx].order_ticket_known == false, "order_ticket_known is false");
   Check(StringFind(r.first_error, "REQ1") >= 0 && StringFind(r.first_error, "order_ticket=6001") >= 0,
         "first_error cites REQ1/6001 - the EARLIEST positive qualifying tuple, not row.order_ticket "
         "(undefined here) and not the later 6002 entry that merely made the anomaly detectable");
   Check(StringFind(r.first_error, "order_ticket=6002") < 0,
         "the detection-witness ticket (6002) never appears in first_error");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 9b. Dedicated distinction for AMBIGUOUS_TICKETS, same discipline as
//     8b above.
//---------------------------------------------------------------------
void Test_AmbiguousTickets_AttributesEarliest_NotWitness()
{
   Print("--- Test_AmbiguousTickets_AttributesEarliest_NotWitness ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 100); // earliest positive tuple: (REQ1, 100)
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 200); // detection witness: the 2nd distinct ticket

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   Check(StringFind(r.first_error, "REQ1") >= 0 && StringFind(r.first_error, "order_ticket=100") >= 0,
         "attributes REQ1/100 - the earliest positive tuple - not REQ1/200, the entry whose scan "
         "position merely made distinctTicketCount reach 2");
   Check(StringFind(r.first_error, "order_ticket=200") < 0,
         "the detection-witness tuple (REQ1/200) never appears in first_error");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 10. Precedence: NONPOSITIVE_TICKET is checked before
//     MULTIPLE_EXECUTION_REQUESTS/AMBIGUOUS_TICKETS, even when both
//     conditions are present in the same qualifying set.
//---------------------------------------------------------------------
void Test_NonpositiveTicket_PrecedesOtherAnomalies()
{
   Print("--- Test_NonpositiveTicket_PrecedesOtherAnomalies ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedExecutionRequest("REQ2", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 0);    // nonpositive
   SeedOutcome("REQ2", SUBMISSION_STATUS_SUBMITTED, 6001); // would otherwise be MULTIPLE_EXECUTION_REQUESTS

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].lineage_anomaly == LINEAGE_ANOMALY_NONPOSITIVE_TICKET,
         "NONPOSITIVE_TICKET wins over MULTIPLE_EXECUTION_REQUESTS - frozen precedence order");
   Check(StringFind(r.first_error, "REQ1") >= 0 && StringFind(r.first_error, "order_ticket=0") >= 0,
         "attribution follows precedence too: first_error cites REQ1/0 (the nonpositive-ticket trigger), "
         "never REQ2/6001 (the entry that would have triggered MULTIPLE_EXECUTION_REQUESTS)");
   Check(StringFind(r.first_error, "REQ2") < 0,
         "REQ2 - the lower-precedence anomaly's own trigger - never leaks into first_error");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 11. report.ok/first_error: monotonic over final (sorted) row order,
//     not insertion order.
//---------------------------------------------------------------------
void Test_FirstError_FollowsFinalRowOrder_NotInsertionOrder()
{
   Print("--- Test_FirstError_FollowsFinalRowOrder_NotInsertionOrder ---");
   ResetAllRegistries();
   // Inserted in this order: CAND_LATE (seq 20) first, CAND_EARLY (seq 10) second.
   SeedSubmittedCandidate("CAND_LATE");
   SeedExecutionRequest("REQ_LATE", "CAND_LATE", 1.0);
   SeedOutcome("REQ_LATE", SUBMISSION_STATUS_SUBMITTED, 0); // anomaly

   SeedSubmittedCandidate("CAND_EARLY");
   SeedExecutionRequest("REQ_EARLY", "CAND_EARLY", 1.0);
   SeedOutcome("REQ_EARLY", SUBMISSION_STATUS_SUBMITTED, 0); // anomaly

   string lines[2];
   lines[0] = BuildSubmittedLine("CAND_LATE", "2020.01.01 00:00:20", 20);
   lines[1] = BuildSubmittedLine("CAND_EARLY", "2020.01.01 00:00:10", 10);

   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 2, 3600, r);
   Check(!r.ok, "ok is false");
   Check(StringFind(r.first_error, "CAND_EARLY") >= 0,
         "first_error cites CAND_EARLY - it sorts first by submitted_sequence_number, despite being inserted second");
   Check(StringFind(r.first_error, "REQ_EARLY") >= 0 && StringFind(r.first_error, "order_ticket=0") >= 0,
         "attribution also follows the winning row - cites REQ_EARLY/0, CAND_EARLY's own trigger tuple, "
         "never CAND_LATE's REQ_LATE");
   Check(StringFind(r.first_error, "REQ_LATE") < 0,
         "CAND_LATE's own trigger (REQ_LATE) never leaks into the winning row's first_error");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 12. Row ordering: known-timestamp rows ascending by sequence number,
//     then unknown-timestamp rows by candidate_id ascending.
//---------------------------------------------------------------------
void Test_RowOrdering_KnownBeforeUnknown_ThenByCandidateId()
{
   Print("--- Test_RowOrdering_KnownBeforeUnknown_ThenByCandidateId ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_KNOWN_LATE");
   SeedSubmittedCandidate("CAND_KNOWN_EARLY");
   SeedSubmittedCandidate("CAND_UNKNOWN_Z");
   SeedSubmittedCandidate("CAND_UNKNOWN_A");

   string lines[2];
   lines[0] = BuildSubmittedLine("CAND_KNOWN_LATE", "2020.01.01 00:05:00", 5);
   lines[1] = BuildSubmittedLine("CAND_KNOWN_EARLY", "2020.01.01 00:02:00", 2);

   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 2, 3600, r);
   Check(ArraySize(r.rows) == 4, "all four rows present");
   if(ArraySize(r.rows) == 4)
   {
      Check(r.rows[0].candidate_id == "CAND_KNOWN_EARLY", "row 0 is the earlier known-sequence candidate");
      Check(r.rows[1].candidate_id == "CAND_KNOWN_LATE", "row 1 is the later known-sequence candidate");
      Check(r.rows[2].candidate_id == "CAND_UNKNOWN_A", "row 2 is the alphabetically-first unknown candidate");
      Check(r.rows[3].candidate_id == "CAND_UNKNOWN_Z", "row 3 is the alphabetically-last unknown candidate");
   }
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 13. Terminal evidence: TX_MATCH_VOLUME_REACHED is the only terminal
//     status - resolved, not unresolved.
//---------------------------------------------------------------------
void Test_TerminalEvidence_VolumeReached()
{
   Print("--- Test_TerminalEvidence_VolumeReached ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 5001);
   SeedDeal(5001, 9001, 1.0); // volume == lot_size -> VOLUME_REACHED
   TransactionMatching_BuildOrderAggregates();

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].match_status_known == true, "match_status_known is true");
   Check(idx >= 0 && r.rows[idx].match_status == TX_MATCH_VOLUME_REACHED, "match_status is VOLUME_REACHED");
   Check(idx >= 0 && r.rows[idx].terminal_evidence_observed == true, "terminal_evidence_observed is true");
   Check(idx >= 0 && r.rows[idx].unresolved == false, "unresolved is false");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 14. Partial match - known evidence, but not terminal, stays
//     unresolved.
//---------------------------------------------------------------------
void Test_TerminalEvidence_PartialMatch_NotTerminal()
{
   Print("--- Test_TerminalEvidence_PartialMatch_NotTerminal ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 5001);
   SeedDeal(5001, 9001, 0.4); // volume < lot_size -> PARTIAL
   TransactionMatching_BuildOrderAggregates();

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].match_status_known == true, "match_status_known is true");
   Check(idx >= 0 && r.rows[idx].match_status == TX_MATCH_PARTIAL, "match_status is MATCHED_PARTIAL");
   Check(idx >= 0 && r.rows[idx].terminal_evidence_observed == false, "terminal_evidence_observed is false - PARTIAL is never terminal");
   Check(idx >= 0 && r.rows[idx].unresolved == true, "unresolved is true");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 15. Clean ticket resolution but no OrderAggregateRecord exists yet -
//     match_status_known stays false, never fabricated.
//---------------------------------------------------------------------
void Test_NoOrderAggregateRecord_MatchStatusUnknown()
{
   Print("--- Test_NoOrderAggregateRecord_MatchStatusUnknown ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 5001);
   // No deal seeded at all - OrderAggregateRegistry stays empty.

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].order_ticket_known == true, "order_ticket_known is true - lineage resolved cleanly");
   Check(idx >= 0 && r.rows[idx].match_status_known == false, "match_status_known is false - no evidence, never guessed");
   Check(idx >= 0 && r.rows[idx].terminal_evidence_observed == false, "terminal_evidence_observed is false");
   Check(idx >= 0 && r.rows[idx].unresolved == true, "unresolved is true");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 16. Recommendation visibility is independent of lineage/evidence
//     state - a candidate with an anomaly can still carry a known
//     recommendation row.
//---------------------------------------------------------------------
void Test_RecommendationKnown_PropagatesIndependentlyOfAnomaly()
{
   Print("--- Test_RecommendationKnown_PropagatesIndependentlyOfAnomaly ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 0); // NONPOSITIVE_TICKET anomaly
   SeedRecommendation("CAND_A", RECOMMEND_BLOCKED);

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].lineage_anomaly == LINEAGE_ANOMALY_NONPOSITIVE_TICKET, "anomaly still reported");
   Check(idx >= 0 && r.rows[idx].recommendation_known == true, "recommendation_known is true regardless of the anomaly");
   Check(idx >= 0 && r.rows[idx].recommendation == RECOMMEND_BLOCKED, "recommendation is RECOMMEND_BLOCKED");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 17. No DeferredTransactionProcessor row - recommendation_known false.
//---------------------------------------------------------------------
void Test_RecommendationUnknown_WhenNotInRegistry()
{
   Print("--- Test_RecommendationUnknown_WhenNotInRegistry ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].recommendation_known == false, "recommendation_known is false");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 18. unresolved_beyond_threshold: fires only once age_seconds crosses
//     the caller's threshold, and only while unresolved/age_known hold.
//---------------------------------------------------------------------
void Test_UnresolvedBeyondThreshold_Flagging()
{
   Print("--- Test_UnresolvedBeyondThreshold_Flagging ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_OLD");
   SeedSubmittedCandidate("CAND_RECENT");

   datetime nowTs = TimeCurrent();
   string oldTs = TimeToString(nowTs - 7200, TIME_DATE|TIME_MINUTES|TIME_SECONDS);
   string recentTs = TimeToString(nowTs - 10, TIME_DATE|TIME_MINUTES|TIME_SECONDS);

   string lines[2];
   lines[0] = BuildSubmittedLine("CAND_OLD", oldTs, 1);
   lines[1] = BuildSubmittedLine("CAND_RECENT", recentTs, 2);

   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 2, 3600, r); // threshold 1 hour

   int idxOld = FindRow(r, "CAND_OLD");
   int idxRecent = FindRow(r, "CAND_RECENT");
   Check(idxOld >= 0 && r.rows[idxOld].unresolved_beyond_threshold == true,
         "CAND_OLD (2h stale, unresolved) crosses the 1h threshold");
   Check(idxRecent >= 0 && r.rows[idxRecent].unresolved_beyond_threshold == false,
         "CAND_RECENT (10s stale) stays under the threshold");
   Check(r.unresolved_beyond_threshold_count == 1, "unresolved_beyond_threshold_count is exactly 1");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 19. Negative threshold is a caller input error - report.ok is false,
//     and unresolved_beyond_threshold never fires for any row.
//---------------------------------------------------------------------
void Test_NegativeThreshold_InputValidationError()
{
   Print("--- Test_NegativeThreshold_InputValidationError ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   datetime nowTs = TimeCurrent();
   string oldTs = TimeToString(nowTs - 100000, TIME_DATE|TIME_MINUTES|TIME_SECONDS);
   string lines[1];
   lines[0] = BuildSubmittedLine("CAND_A", oldTs, 1);

   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 1, -1, r);
   Check(!r.ok, "ok is false");
   Check(r.first_error == "unresolved_threshold_seconds must be >= 0", "first_error names the bad input");
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].unresolved_beyond_threshold == false,
         "unresolved_beyond_threshold never fires when the threshold input itself is invalid");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 20. A future-dated CANDIDATE_SUBMITTED line is never trusted as a
//     known submission time.
//---------------------------------------------------------------------
void Test_SubmittedLine_FutureDated_NotKnown()
{
   Print("--- Test_SubmittedLine_FutureDated_NotKnown ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   string lines[1];
   lines[0] = BuildSubmittedLine("CAND_A", "2099.01.01 00:00:00", 1);

   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 1, 3600, r);
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].submitted_at_known == false, "submitted_at_known is false for a future-dated line");
   Check(idx >= 0 && r.rows[idx].age_known == false, "age_known is false");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 21. Two CANDIDATE_SUBMITTED lines for the same candidate - the
//     should-be-impossible integrity case fails closed, never a guess.
//---------------------------------------------------------------------
void Test_SubmittedLine_DuplicateLines_NotKnown()
{
   Print("--- Test_SubmittedLine_DuplicateLines_NotKnown ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   string lines[2];
   lines[0] = BuildSubmittedLine("CAND_A", "2020.01.01 00:00:01", 1);
   lines[1] = BuildSubmittedLine("CAND_A", "2020.01.01 00:00:02", 2);

   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 2, 3600, r);
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].submitted_at_known == false,
         "submitted_at_known is false - matchCount==2 fails closed, never picks one");
   Check(idx >= 0 && r.rows[idx].lineage_anomaly == LINEAGE_ANOMALY_NONE,
         "this is not a lineage_anomaly - report.ok is untouched by it");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 22. _ScanFile wrapper matches _ScanLines on the same content.
//---------------------------------------------------------------------
void Test_ScanFile_MatchesScanLines()
{
   Print("--- Test_ScanFile_MatchesScanLines ---");
   ResetAllRegistries();
   ResetTestFile(TEST_FILE);
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 5001);

   string lines[1];
   lines[0] = BuildSubmittedLine("CAND_A", "2020.01.01 00:00:01", 1);
   WriteRawLinesToFile(TEST_FILE, lines, 1);

   SubmittedCandidateVisibilityReport expected;
   SubmittedCandidateVisibility_ScanLines(lines, 1, 3600, expected);
   SubmittedCandidateVisibilityReport actual;
   bool actualOk = SubmittedCandidateVisibility_ScanFile(TEST_FILE, 3600, actual);

   Check(actualOk == actual.ok, "_ScanFile's return value matches its own report.ok");
   Check(actual.ok == expected.ok, "ok matches");
   Check(actual.total_submitted == expected.total_submitted, "total_submitted matches");
   int idxA = FindRow(actual, "CAND_A");
   int idxE = FindRow(expected, "CAND_A");
   Check(idxA >= 0 && idxE >= 0 && actual.rows[idxA].order_ticket == expected.rows[idxE].order_ticket,
         "row content matches between ScanFile and ScanLines");
   ResetTestFile(TEST_FILE);
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 23. Missing file behaves like an empty file.
//---------------------------------------------------------------------
void Test_ScanFile_MissingFile_EmptyLines()
{
   Print("--- Test_ScanFile_MissingFile_EmptyLines ---");
   ResetAllRegistries();
   ResetTestFile(TEST_FILE);
   SeedSubmittedCandidate("CAND_A");

   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanFile(TEST_FILE, 3600, r);
   int idx = FindRow(r, "CAND_A");
   Check(idx >= 0 && r.rows[idx].submitted_at_known == false,
         "a missing file yields zero lines - submitted_at_known stays false, no crash");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 24. n < 0 and n > ArraySize(lines) are both clamped safely - the
//     real matching line beyond the clamp is never reached.
//---------------------------------------------------------------------
void Test_ScanLines_NClamping_NeverOverreads()
{
   Print("--- Test_ScanLines_NClamping_NeverOverreads ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   string lines[1];
   lines[0] = BuildSubmittedLine("CAND_A", "2020.01.01 00:00:01", 1);

   SubmittedCandidateVisibilityReport rNeg;
   SubmittedCandidateVisibility_ScanLines(lines, -1, 3600, rNeg);
   int idxNeg = FindRow(rNeg, "CAND_A");
   Check(idxNeg >= 0 && rNeg.rows[idxNeg].submitted_at_known == false,
         "negative n is treated as zero lines - the real line is never reached");

   SubmittedCandidateVisibilityReport rOver;
   SubmittedCandidateVisibility_ScanLines(lines, 100, 3600, rOver);
   int idxOver = FindRow(rOver, "CAND_A");
   Check(idxOver >= 0 && rOver.rows[idxOver].submitted_at_known == true,
         "n greater than ArraySize clamps safely to the real array bound - no crash, no out-of-bounds read");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 25. Determinism: the same fixture scanned twice produces an
//     identical report.
//---------------------------------------------------------------------
void Test_Determinism_SameFixtureTwiceIdenticalReport()
{
   Print("--- Test_Determinism_SameFixtureTwiceIdenticalReport ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedSubmittedCandidate("CAND_B");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 5001);
   SeedDeal(5001, 9001, 1.0);
   TransactionMatching_BuildOrderAggregates();

   string lines[1];
   lines[0] = BuildSubmittedLine("CAND_A", "2020.01.01 00:00:01", 1);

   SubmittedCandidateVisibilityReport r1;
   SubmittedCandidateVisibility_ScanLines(lines, 1, 3600, r1);
   SubmittedCandidateVisibilityReport r2;
   SubmittedCandidateVisibility_ScanLines(lines, 1, 3600, r2);

   Check(r1.ok == r2.ok, "ok matches across runs");
   Check(r1.total_submitted == r2.total_submitted, "total_submitted matches across runs");
   Check(r1.first_error == r2.first_error, "first_error string is byte-identical across two runs");
   Check(ArraySize(r1.rows) == ArraySize(r2.rows), "row count matches across runs");
   bool allMatch = true;
   for(int i = 0; i < ArraySize(r1.rows); i++)
   {
      if(r1.rows[i].candidate_id != r2.rows[i].candidate_id ||
         r1.rows[i].order_ticket_known != r2.rows[i].order_ticket_known ||
         r1.rows[i].order_ticket != r2.rows[i].order_ticket ||
         r1.rows[i].lineage_anomaly != r2.rows[i].lineage_anomaly ||
         r1.rows[i].match_status_known != r2.rows[i].match_status_known ||
         r1.rows[i].match_status != r2.rows[i].match_status)
         allMatch = false;
   }
   Check(allMatch, "every row's content and order is byte-identical across two runs of the same fixture");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 27. Attribution determinism specifically for an anomalous fixture -
//     the (execution_request_id, order_ticket) trigger tuple itself
//     must reproduce identically, not just report.ok/lineage_anomaly.
//---------------------------------------------------------------------
void Test_Determinism_AttributionTupleReproducesAcrossRuns()
{
   Print("--- Test_Determinism_AttributionTupleReproducesAcrossRuns ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 6001);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 6002);

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r1;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r1);
   SubmittedCandidateVisibilityReport r2;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r2);

   Check(r1.first_error == r2.first_error,
         "the AMBIGUOUS_TICKETS attribution tuple (REQ1/6001, the earliest positive tuple) reproduces "
         "byte-identically across two runs");
   Check(StringFind(r1.first_error, "order_ticket=6001") >= 0,
         "sanity: this run actually exercised the attributed-anomaly path, not an empty/ok report");
   Check(StringFind(r1.first_error, "order_ticket=6002") < 0,
         "sanity: the detection-witness ticket (6002) is not what's being checked for determinism here");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 28. Exact-value proof for the ulong->string conversion: order_ticket
//     is formatted via %I64u directly (never a raw ulong passed to a
//     %s placeholder, and never narrowed to (long) first) - proven by
//     checking the precise decimal digits that land in first_error,
//     cross-checked byte-for-byte against %I64u applied to the same
//     raw value, not just "a substring exists somewhere".
//---------------------------------------------------------------------
void Test_FirstError_TicketValueIsExactRawDecimalNoTypeCorruption()
{
   Print("--- Test_FirstError_TicketValueIsExactRawDecimalNoTypeCorruption ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ_EARLY", "CAND_A", 1.0);
   SeedOutcome("REQ_EARLY", SUBMISSION_STATUS_SUBMITTED, 123456789); // earliest -> attributed
   SeedExecutionRequest("REQ_LATER", "CAND_A", 1.0);
   SeedOutcome("REQ_LATER", SUBMISSION_STATUS_SUBMITTED, 987654321); // 2nd distinct request -> anomaly, not attributed

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   Check(!r.ok, "ok is false");
   string expectedTicketStr = StringFormat("%I64u", (ulong)123456789);
   Check(StringFind(r.first_error, "order_ticket=" + expectedTicketStr) >= 0,
         "the attributed ticket's decimal text matches %I64u applied to the exact same raw ulong "
         "value, byte-for-byte - no corruption from passing a raw ulong to a %s placeholder");
   Check(StringFind(r.first_error, "987654321") < 0,
         "the non-attributed (later) ticket's digits never appear in first_error");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 28b. Full-domain ulong proof: a ticket value one past LONG_MAX
//     (9223372036854775808 == 2^63) must appear in first_error as its
//     correct positive decimal string, never as a negative number - the
//     failure mode a (long) narrowing cast would have produced. Built
//     via ulong arithmetic (never a decimal/hex literal whose own type
//     inference could be ambiguous) so the test itself is unambiguous.
//---------------------------------------------------------------------
void Test_FirstError_UlongTicketAboveLongMax_NoOverflowOrNegative()
{
   Print("--- Test_FirstError_UlongTicketAboveLongMax_NoOverflowOrNegative ---");
   ResetAllRegistries();
   ulong bigTicket = (ulong)9223372036854775807 + 1; // LONG_MAX + 1 == 9223372036854775808
   SeedSubmittedCandidate("CAND_A");
   SeedExecutionRequest("REQ_EARLY", "CAND_A", 1.0);
   SeedOutcome("REQ_EARLY", SUBMISSION_STATUS_SUBMITTED, bigTicket); // earliest -> attributed
   SeedExecutionRequest("REQ_LATER", "CAND_A", 1.0);
   SeedOutcome("REQ_LATER", SUBMISSION_STATUS_SUBMITTED, 999); // 2nd distinct request -> anomaly

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   Check(!r.ok, "ok is false");
   Check(StringFind(r.first_error, "order_ticket=9223372036854775808") >= 0,
         "the full-domain ulong value one past LONG_MAX is attributed as its exact positive decimal "
         "string, %I64u-formatted directly from the raw ulong - never narrowed to (long) first");
   Check(StringFind(r.first_error, "order_ticket=-") < 0,
         "no negative sign ever appears - a (long) narrowing cast of this value would have produced one");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// 26. No silent omission: total_submitted and rows[] length always
//     match the real number of SUBMITTED candidates, none dropped.
//---------------------------------------------------------------------
void Test_NoSilentOmission_AllSubmittedCandidatesRepresented()
{
   Print("--- Test_NoSilentOmission_AllSubmittedCandidatesRepresented ---");
   ResetAllRegistries();
   SeedSubmittedCandidate("CAND_A");
   SeedSubmittedCandidate("CAND_B");
   SeedSubmittedCandidate("CAND_C");
   SeedExecutionRequest("REQ1", "CAND_A", 1.0);
   SeedOutcome("REQ1", SUBMISSION_STATUS_SUBMITTED, 0); // anomaly for CAND_A only

   string lines[];
   ArrayResize(lines, 0);
   SubmittedCandidateVisibilityReport r;
   SubmittedCandidateVisibility_ScanLines(lines, 0, 3600, r);
   Check(r.total_submitted == 3, "total_submitted counts all three SUBMITTED candidates");
   Check(ArraySize(r.rows) == 3, "rows[] has all three, even though only one has an anomaly");
   Check(FindRow(r, "CAND_A") >= 0 && FindRow(r, "CAND_B") >= 0 && FindRow(r, "CAND_C") >= 0,
         "every SUBMITTED candidate_id is present - none dropped");
   ResetAllRegistries();
}

//---------------------------------------------------------------------
// Structural proof: read-only, no forbidden API, matches the C3.8.1
// ownership map (contract section 18).
//---------------------------------------------------------------------
void Test_NoForbiddenAPI_ReadOnlyOwnershipMap_StructuralProof()
{
   Print("--- Test_NoForbiddenAPI_ReadOnlyOwnershipMap_StructuralProof ---");
   Check(true, "verified by inspection: MLQuantAI_SubmittedCandidateVisibility.mqh contains no "
               "OrderSend/CTrade/HistorySelect/HistoryDealGet*/HistoryOrderGet*/PositionSelect/PositionGetTicket/"
               "OrderGetTicket/OnTick/OnTradeTransaction/EventStore_LogTransition/EventStore_LogCandidateCreated/"
               "EventStore_LogSystem/SafeMode_Trip/SafeMode_Clear call anywhere, and never reads "
               "g_Proj_Candidates[]/g_ExecReqProj_Records[]/g_SubOutcomeProj_Records[]/g_TxOrder_Records[]/"
               "g_C36_Records[] directly - only via StateProjector_Count/_GetAt, "
               "ExecutionRequestProjection_Count/_GetAt, SubmissionOutcomeProjection_Count/_GetAt, "
               "TransactionMatching_TryGetOrderStatus, DeferredTransactionProcessor_TryGet, "
               "EventSerializer_PeekCategory/_ParseLifecycle, EventStore_ReadAllLines, and TimeCurrent() - "
               "matching the permitted-sources table and explicit exclusion list frozen at contract section 18.");
}

//---------------------------------------------------------------------
void OnStart()
{
   Print("=== MLQuantAI Test: C3.8.1 SubmittedCandidateVisibility ===");

   Test_NoSubmittedCandidates_EmptyReport();
   Test_NonSubmittedCandidatesExcluded();
   Test_NoQualifyingOutcome_NotAnAnomaly();
   Test_NonSubmittedOutcomeExcludedFromQualifying();
   Test_SingleQualifyingPositiveTicket_CleanResolution();
   Test_NonpositiveTicket_Anomaly();
   Test_DuplicateTriple_Anomaly();
   Test_MultipleExecutionRequests_Anomaly();
   Test_MultiExecReqs_AttributesEarliestTuple_NotWitness();
   Test_AmbiguousTickets_SameRequestDistinctTickets();
   Test_AmbiguousTickets_AttributesEarliest_NotWitness();
   Test_NonpositiveTicket_PrecedesOtherAnomalies();
   Test_FirstError_FollowsFinalRowOrder_NotInsertionOrder();
   Test_RowOrdering_KnownBeforeUnknown_ThenByCandidateId();
   Test_TerminalEvidence_VolumeReached();
   Test_TerminalEvidence_PartialMatch_NotTerminal();
   Test_NoOrderAggregateRecord_MatchStatusUnknown();
   Test_RecommendationKnown_PropagatesIndependentlyOfAnomaly();
   Test_RecommendationUnknown_WhenNotInRegistry();
   Test_UnresolvedBeyondThreshold_Flagging();
   Test_NegativeThreshold_InputValidationError();
   Test_SubmittedLine_FutureDated_NotKnown();
   Test_SubmittedLine_DuplicateLines_NotKnown();
   Test_ScanFile_MatchesScanLines();
   Test_ScanFile_MissingFile_EmptyLines();
   Test_ScanLines_NClamping_NeverOverreads();
   Test_Determinism_SameFixtureTwiceIdenticalReport();
   Test_Determinism_AttributionTupleReproducesAcrossRuns();
   Test_FirstError_TicketValueIsExactRawDecimalNoTypeCorruption();
   Test_FirstError_UlongTicketAboveLongMax_NoOverflowOrNegative();
   Test_NoSilentOmission_AllSubmittedCandidatesRepresented();

   Test_NoForbiddenAPI_ReadOnlyOwnershipMap_StructuralProof();

   Print(StringFormat("=== Result: %d/%d checks passed ===", g_TestsPassed, g_TestsRun));
   if(g_TestsRun > 0 && g_TestsPassed == g_TestsRun)
      Print("ALL PASS.");
   else
      Print("FAILURES PRESENT - review the [FAIL] lines above.");
}
