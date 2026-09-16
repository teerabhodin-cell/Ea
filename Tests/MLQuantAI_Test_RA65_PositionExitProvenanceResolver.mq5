//+------------------------------------------------------------------+
//| MLQuantAI_Test_RA65_PositionExitProvenanceResolver.mq5             |
//| RA-65 Slice 1 (QA-frozen, CORRECTED per pre-push diff-audit         |
//| blocker): proves PositionExitProvenance_Resolve() correctly walks    |
//| the frozen 3-step reverse chain (position_ticket -> order_ticket ->   |
//| execution_request_id -> candidate_id/correlation_id), and correctly   |
//| classifies EVERY step as exactly one of unresolved/ambiguous/          |
//| resolved - never guessing a "first hit"/"most recent" winner.           |
//|                                                                           |
//| QA's pre-push finding on the original version of this file/resolver:      |
//| a real position ALWAYS has at least two BROKER_TRANSACTION_OBSERVED         |
//| DEAL_ADD lines sharing one position_ticket - the opening deal and the        |
//| closing deal under resolution. The original resolver counted ALL such         |
//| lines with no way to tell them apart, so the ordinary single-open/single-       |
//| close case always misclassified as AMBIGUOUS_OBSERVATION - not an edge case,     |
//| a 100% failure rate. This file now ALWAYS records both an opening and a           |
//| closing observation per scenario (two RecordDealAdd() calls sharing one            |
//| position_ticket but different deal_ticket values), and PositionExitProvenance_       |
//| Resolve() takes the current transaction's own                                        |
//| closing_deal_ticket as an explicit, separate parameter from position_ticket -         |
//| never conflated.                                                                        |
//|                                                                                            |
//| Step 1 evidence (BROKER_TRANSACTION_OBSERVED lines) is produced by the REAL,               |
//| sealed C3.2 BrokerTransactionObservation_RecordAndGuard() against a real temp                |
//| EventStore file - never a hand-typed line. Step 2/3 registries                                 |
//| (SubmissionOutcomeProjection/ExecutionRequestProjection) are populated via their                  |
//| own already-public *_AppendRecord() direct-construction accessors.                                 |
//|                                                                                                        |
//| No OrderSend, no OnTradeTransaction wiring, no POSITION_CLOSED emission - this                        |
//| file exercises ONLY the pure resolver. Running on a real account is safe.                               |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_PositionExitProvenanceResolver.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerTransactionObservation.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_RA65_PositionExitProvenanceResolver.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

// Records one real TRADE_TRANSACTION_DEAL_ADD BROKER_TRANSACTION_OBSERVED
// line via the sealed C3.2 recorder - the same call site MLQuantAI.mq5's
// own OnTradeTransaction would make. Used for BOTH the opening and the
// closing deal in every scenario below (same helper, different ticket
// arguments) - trans.deal_type is fixed and carries no meaning to this
// resolver (Addendum B's reducing-deal check belongs to RA-65 Slice 2, not
// here).
//
// MqlTradeTransaction/MqlTradeRequest/MqlTradeResult all contain string
// members - MQL5's string type is a reference-counted handle, not raw
// bytes, so ZeroMemory() on a struct containing one does not reliably
// leave it as "" (same platform pitfall already documented in
// Tests/MLQuantAI_Test_C3_2_BrokerTransactionObservation.mq5's own
// MakeTrans/MakeResult/MakeEmptyRequest helpers). Manual field-by-field
// init, same precedent, avoids it entirely.
void RecordDealAdd(ulong dealTicket, ulong orderTicket, ulong positionTicket)
{
   MqlTradeTransaction trans;
   trans.type            = TRADE_TRANSACTION_DEAL_ADD;
   trans.deal             = dealTicket;
   trans.order            = orderTicket;
   trans.symbol           = "XAUUSD";
   trans.order_type       = ORDER_TYPE_BUY;
   trans.order_state      = ORDER_STATE_FILLED;
   trans.deal_type        = DEAL_TYPE_SELL;
   trans.time_type        = ORDER_TIME_GTC;
   trans.time_expiration  = 0;
   trans.price             = 100.0;
   trans.price_trigger     = 0.0;
   trans.price_sl          = 0.0;
   trans.price_tp          = 0.0;
   trans.volume             = 0.01;
   trans.position           = positionTicket;
   trans.position_by        = 0;

   MqlTradeRequest request;
   request.action        = (ENUM_TRADE_REQUEST_ACTIONS)0;
   request.magic          = 0;
   request.order           = 0;
   request.symbol          = "";
   request.volume          = 0;
   request.price            = 0;
   request.stoplimit        = 0;
   request.sl                = 0;
   request.tp                = 0;
   request.deviation         = 0;
   request.type              = ORDER_TYPE_BUY;
   request.type_filling      = ORDER_FILLING_FOK;
   request.type_time         = ORDER_TIME_GTC;
   request.expiration        = 0;
   request.comment           = "";
   request.position          = 0;
   request.position_by       = 0;

   MqlTradeResult result;
   result.retcode          = 0;
   result.deal              = 0;
   result.order              = 0;
   result.volume             = 0;
   result.price              = 0;
   result.bid                 = 0;
   result.ask                 = 0;
   result.comment             = "";
   result.request_id          = 0;
   result.retcode_external    = 0;

   BrokerTransactionObservation_RecordAndGuard(trans, request, result);
}

void MakeSubmissionOutcome(ulong orderTicket, string executionRequestId, ENUM_SUBMISSION_STATUS status)
{
   SubmissionOutcomeProjectionRecord rec;
   SubmissionOutcomeProjectionRecord_Init(rec);
   rec.execution_request_id = executionRequestId;
   rec.order_ticket          = orderTicket;
   rec.submission_status     = status;
   SubmissionOutcomeProjection_AppendRecord(rec);
}

void MakeExecutionRequest(string executionRequestId, string candidateId, string correlationId)
{
   ExecutionRequestProjectionRecord rec;
   ExecutionRequestProjectionRecord_Init(rec);
   rec.execution_request_id = executionRequestId;
   rec.candidate_id          = candidateId;
   rec.correlation_id        = correlationId;
   ExecutionRequestProjection_AppendRecord(rec);
}

void ResetAll()
{
   SubmissionOutcomeProjection_Reset();
   ExecutionRequestProjection_Reset();
}

void OnStart()
{
   Print("=== MLQuantAI_Test_RA65_PositionExitProvenanceResolver.mq5 ===");

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   Check(EventStore_Open(TEST_EVENT_STORE_FILE), "setup: event store opens");

   //=====================================================================
   // 1. Full successful resolution - the ORDINARY case: one opening
   //    DEAL_ADD (deal 8001, order 5001) and one closing DEAL_ADD (deal
   //    9001, the transaction under resolution) sharing position 7001.
   //    This is QA's own regression scenario: "same position_ticket +
   //    prior DEAL_ADD observation + current closing DEAL_ADD observation
   //    -> must resolve current closing transaction deterministically."
   //=====================================================================
   Print("--- ordinary open+close lifecycle resolves deterministically (QA regression scenario) ---");
   ResetAll();
   RecordDealAdd(8001, 5001, 7001); // opening deal
   RecordDealAdd(9001, 6001, 7001); // closing deal - a DIFFERENT (closing) order ticket, matching real MT5 behavior where closing a position is typically its own separate order
   MakeSubmissionOutcome(5001, "EXECREQ_ra65_a", SUBMISSION_STATUS_SUBMITTED);
   MakeExecutionRequest("EXECREQ_ra65_a", "CND_ra65_a", "CORR_ra65_a");
   {
      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);

      PositionExitProvenanceResult result;
      PositionExitProvenance_Resolve(7001, 9001, lines, result); // 9001 = the CURRENT closing deal

      Check(result.status == POSITION_EXIT_PROVENANCE_RESOLVED, "status == RESOLVED despite 2 observed lines for this position (open+close)");
      Check(result.order_ticket == 5001, "order_ticket resolved correctly (the opening order, not the closing deal itself)");
      Check(result.execution_request_id == "EXECREQ_ra65_a", "execution_request_id resolved correctly");
      Check(result.candidate_id == "CND_ra65_a", "candidate_id resolved correctly");
      Check(result.correlation_id == "CORR_ra65_a", "correlation_id resolved correctly");
      Check(PositionExitProvenance_IsResolved(result.status), "PositionExitProvenance_IsResolved() agrees");
   }

   //=====================================================================
   // 2. No BROKER_TRANSACTION_OBSERVED line at all for this position_ticket.
   //=====================================================================
   Print("--- no BROKER_TRANSACTION_OBSERVED line for this position_ticket -> NO_OBSERVATION ---");
   {
      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);

      PositionExitProvenanceResult result;
      PositionExitProvenance_Resolve(99999999, 99999998, lines, result); // neither ticket ever recorded
      Check(result.status == POSITION_EXIT_PROVENANCE_NO_OBSERVATION, "status == NO_OBSERVATION");
      Check(!PositionExitProvenance_IsResolved(result.status), "not resolved");
      Check(result.candidate_id == "", "candidate_id left empty");
   }

   //=====================================================================
   // 3. CORRECTED regression (this is the exact bug QA's pre-push audit
   //    found): the CURRENT closing transaction's own observation was
   //    NEVER durably recorded (e.g. its own BrokerTransactionObservation
   //    write just failed), but a PRIOR opening observation for the SAME
   //    position_ticket exists. Must NOT resolve from the stale prior
   //    observation alone - must report NO_OBSERVATION.
   //=====================================================================
   Print("--- current closing transaction's own observation missing (only a prior opening observation exists) -> NO_OBSERVATION, never resolves from stale evidence ---");
   ResetAll();
   RecordDealAdd(8002, 5002, 7002); // opening deal only - closing deal 9002 is deliberately NEVER recorded
   MakeSubmissionOutcome(5002, "EXECREQ_ra65_c", SUBMISSION_STATUS_SUBMITTED);
   MakeExecutionRequest("EXECREQ_ra65_c", "CND_ra65_c", "CORR_ra65_c");
   {
      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);

      PositionExitProvenanceResult result;
      PositionExitProvenance_Resolve(7002, 9002, lines, result); // 9002 was never recorded as observed
      Check(result.status == POSITION_EXIT_PROVENANCE_NO_OBSERVATION, "status == NO_OBSERVATION - never resolves from the stale opening-only observation");
      Check(!PositionExitProvenance_IsResolved(result.status), "not resolved");
      Check(result.candidate_id == "", "candidate_id left empty - no silent resolution from stale evidence");
   }

   //=====================================================================
   // 4. Genuine ambiguity: the position was opened by TWO DIFFERENT
   //    orders (real multi-order averaging-in), plus the current closing
   //    deal. Must still report AMBIGUOUS_OBSERVATION - this is the
   //    correctly-preserved intent of the original test, now expressed
   //    with real distinct order identities rather than duplicate lines
   //    for the same order.
   //=====================================================================
   Print("--- position opened by two DIFFERENT orders (real averaging-in) -> AMBIGUOUS_OBSERVATION ---");
   ResetAll();
   RecordDealAdd(8003, 5003, 7003);  // opening deal, order A
   RecordDealAdd(8004, 5004, 7003);  // opening deal, order B - a genuinely different order on the same position
   RecordDealAdd(9003, 6003, 7003);  // the current closing deal under resolution - its own order ticket is irrelevant/excluded either way
   {
      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);

      PositionExitProvenanceResult result;
      PositionExitProvenance_Resolve(7003, 9003, lines, result);
      Check(result.status == POSITION_EXIT_PROVENANCE_AMBIGUOUS_OBSERVATION, "status == AMBIGUOUS_OBSERVATION (two distinct opening orders)");
      Check(!PositionExitProvenance_IsResolved(result.status), "not resolved");
   }

   //=====================================================================
   // 5. Multiple partial-fill entries under the SAME order must NOT be
   //    ambiguous - they collapse to one distinct order_ticket.
   //=====================================================================
   Print("--- position opened via two partial fills of the SAME order -> resolves cleanly, not ambiguous ---");
   ResetAll();
   RecordDealAdd(8005, 5005, 7005); // opening partial fill #1, order 5005
   RecordDealAdd(8006, 5005, 7005); // opening partial fill #2, SAME order 5005
   RecordDealAdd(9005, 6005, 7005); // the current closing deal - a distinct closing order ticket
   MakeSubmissionOutcome(5005, "EXECREQ_ra65_e", SUBMISSION_STATUS_SUBMITTED);
   MakeExecutionRequest("EXECREQ_ra65_e", "CND_ra65_e", "CORR_ra65_e");
   {
      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);

      PositionExitProvenanceResult result;
      PositionExitProvenance_Resolve(7005, 9005, lines, result);
      Check(result.status == POSITION_EXIT_PROVENANCE_RESOLVED, "status == RESOLVED - two partial-fill lines for ONE order are not ambiguous");
      Check(result.order_ticket == 5005, "order_ticket resolved correctly");
   }

   //=====================================================================
   // 6. Observation resolves, but no SUBMITTED SubmissionOutcome exists
   //    for that order_ticket (only a REJECTED one - proves filtering,
   //    not just absence).
   //=====================================================================
   Print("--- observation resolves, only a REJECTED submission outcome exists -> NO_SUBMISSION ---");
   ResetAll();
   RecordDealAdd(8007, 5007, 7007);
   RecordDealAdd(9007, 6007, 7007); // distinct closing order ticket
   MakeSubmissionOutcome(5007, "EXECREQ_ra65_f", SUBMISSION_STATUS_REJECTED);
   {
      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);

      PositionExitProvenanceResult result;
      PositionExitProvenance_Resolve(7007, 9007, lines, result);
      Check(result.status == POSITION_EXIT_PROVENANCE_NO_SUBMISSION, "status == NO_SUBMISSION (REJECTED does not count)");
      Check(result.order_ticket == 5007, "order_ticket still recorded from step 1 despite step 2 failure");
   }

   //=====================================================================
   // 7. Two SUBMITTED SubmissionOutcome records for the same order_ticket
   //    -> AMBIGUOUS_SUBMISSION.
   //=====================================================================
   Print("--- two SUBMITTED submission outcomes for the same order_ticket -> AMBIGUOUS_SUBMISSION ---");
   ResetAll();
   RecordDealAdd(8008, 5008, 7008);
   RecordDealAdd(9008, 6008, 7008); // distinct closing order ticket
   MakeSubmissionOutcome(5008, "EXECREQ_ra65_g1", SUBMISSION_STATUS_SUBMITTED);
   MakeSubmissionOutcome(5008, "EXECREQ_ra65_g2", SUBMISSION_STATUS_SUBMITTED);
   {
      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);

      PositionExitProvenanceResult result;
      PositionExitProvenance_Resolve(7008, 9008, lines, result);
      Check(result.status == POSITION_EXIT_PROVENANCE_AMBIGUOUS_SUBMISSION, "status == AMBIGUOUS_SUBMISSION");
   }

   //=====================================================================
   // 8. Submission resolves, but no ExecutionRequestProjection record
   //    exists for that execution_request_id -> NO_EXECUTION_REQUEST.
   //=====================================================================
   Print("--- submission resolves, no ExecutionRequestProjection record exists -> NO_EXECUTION_REQUEST ---");
   ResetAll();
   RecordDealAdd(8009, 5009, 7009);
   RecordDealAdd(9009, 6009, 7009); // distinct closing order ticket
   MakeSubmissionOutcome(5009, "EXECREQ_ra65_h", SUBMISSION_STATUS_SUBMITTED);
   {
      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);

      PositionExitProvenanceResult result;
      PositionExitProvenance_Resolve(7009, 9009, lines, result);
      Check(result.status == POSITION_EXIT_PROVENANCE_NO_EXECUTION_REQUEST, "status == NO_EXECUTION_REQUEST");
      Check(result.execution_request_id == "EXECREQ_ra65_h", "execution_request_id still recorded from step 2 despite step 3 failure");
   }

   //=====================================================================
   // 9. Two ExecutionRequestProjection records sharing one
   //    execution_request_id -> AMBIGUOUS_EXECUTION_REQUEST.
   //=====================================================================
   Print("--- two ExecutionRequestProjection records share one execution_request_id -> AMBIGUOUS_EXECUTION_REQUEST ---");
   ResetAll();
   RecordDealAdd(8010, 5010, 7010);
   RecordDealAdd(9010, 6010, 7010); // distinct closing order ticket
   MakeSubmissionOutcome(5010, "EXECREQ_ra65_i", SUBMISSION_STATUS_SUBMITTED);
   MakeExecutionRequest("EXECREQ_ra65_i", "CND_ra65_i1", "CORR_ra65_i1");
   MakeExecutionRequest("EXECREQ_ra65_i", "CND_ra65_i2", "CORR_ra65_i2");
   {
      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);

      PositionExitProvenanceResult result;
      PositionExitProvenance_Resolve(7010, 9010, lines, result);
      Check(result.status == POSITION_EXIT_PROVENANCE_AMBIGUOUS_EXECUTION_REQUEST, "status == AMBIGUOUS_EXECUTION_REQUEST");
      Check(result.candidate_id == "", "candidate_id left empty on ambiguity, never a guessed pick");
   }

   //=====================================================================
   // 10. Successful complete resolution, restated with a distinct
   //     identity set and its own open+close pair.
   //=====================================================================
   Print("--- successful complete resolution (second, independent open+close identity set) ---");
   ResetAll();
   RecordDealAdd(8011, 5011, 7011);
   RecordDealAdd(9011, 6011, 7011); // distinct closing order ticket
   MakeSubmissionOutcome(5011, "EXECREQ_ra65_j", SUBMISSION_STATUS_SUBMITTED);
   MakeExecutionRequest("EXECREQ_ra65_j", "CND_ra65_j", "CORR_ra65_j");
   {
      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);

      PositionExitProvenanceResult result;
      PositionExitProvenance_Resolve(7011, 9011, lines, result);
      Check(result.status == POSITION_EXIT_PROVENANCE_RESOLVED, "status == RESOLVED");
      Check(result.candidate_id == "CND_ra65_j" && result.correlation_id == "CORR_ra65_j", "candidate/correlation identity matches exactly");
   }

   EventStore_Close();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
