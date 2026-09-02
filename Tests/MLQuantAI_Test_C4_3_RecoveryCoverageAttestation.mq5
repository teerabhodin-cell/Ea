//+------------------------------------------------------------------+
//| MLQuantAI_Test_C4_3_RecoveryCoverageAttestation.mq5               |
//| C4.3 v1 implementation test suite, per                            |
//| Docs/PhaseC_C4_RecoveryHistoryPolicy.md §11 (adopted) and the       |
//| post-merge implementation-authorization design review that froze  |
//| the parameter-only v1 scope, the ScanLive overload plan, the       |
//| source/evaluator validation boundary, the report-detail-token      |
//| rule, and this 25-case test mapping.                               |
//|                                                                    |
//| Cases 1-22 and 25b are direct pure-evaluator tests (no ScanLive,   |
//| no OrderAggregateRegistry/ExecutionRequestProjection staging).     |
//| Case 23 and 24 are ScanLive() integration tests, using a local     |
//| stub IHistorySource (this file cannot reuse Tests/MLQuantAI_Test_  |
//| C4_2_RecoveryReconciliation.mq5's private CFakeHistorySource - one |
//| .mq5 script cannot include another) and the real, production       |
//| ParameterCoverageAttestationSource.                                |
//|                                                                    |
//| Case 25a (the stronger "no I/O/clock/platform-call at all" claim)  |
//| is explicitly NOT a compiled test in this file - it is a           |
//| reviewer-performed, read-only structural inspection of             |
//| MLQuantAI_RecoveryCoverageEvaluator.mqh performed before compile    |
//| authorization is granted for it (frozen this checkpoint - an MQL5  |
//| runtime test cannot reliably prove the absence of every possible   |
//| call, only exercise the calls it happens to think of). Case 25b    |
//| below is the weaker, but real, compiled determinism/no-leakage     |
//| test - kept as a separate named function from Case 22 per the      |
//| design review's explicit instruction, even though both assert      |
//| repeated-call output stability.                                    |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_RecoveryReconciliation.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ParameterCoverageAttestationSource.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixed scan-context/fixture constants shared by every case below -
// deliberately identical to what RecoveryReconciliation_ScanLive's
// scan-context capture would produce for a real account whose
// ACCOUNT_SERVER=="ServerA", ACCOUNT_LOGIN==1000001.
//---------------------------------------------------------------------
#define TEST_BROKER    "ServerA"
#define TEST_ACCOUNT   "1000001"
#define TEST_TIMEBASIS "MT5_TRADE_SERVER_TIME"
#define TEST_MARKER    MLQUANTAI_C4_3_COVERAGE_ATTESTATION_INTEGRITY_MARKER

datetime REQUIRED_FROM = D'2026.01.01 08:00:00';
datetime REQUIRED_TO   = D'2026.01.01 09:00:00';
datetime EVAL_TIME     = D'2026.01.01 09:00:00';

RecoveryCoverageAttestation MakeAttestation(string broker, string account, string timeBasis,
                                              datetime coverageFrom, datetime coverageTo, datetime validUntil,
                                              string integrityMarker)
{
   RecoveryCoverageAttestation a;
   RecoveryCoverageAttestation_Init(a);
   a.broker_identity = broker;
   a.account_identity = account;
   a.server_time_basis = timeBasis;
   a.coverage_from = coverageFrom;
   a.coverage_to = coverageTo;
   a.valid_until = validUntil;
   a.issuer_identity = "TEST_ISSUER";
   a.evidence_reference = "TEST_REF";
   a.integrity_identifier = integrityMarker;
   return a;
}

//---------------------------------------------------------------------
// Minimal local IHistorySource stub for Case 23/24's ScanLive
// integration tests. Orders/deals total always 0 - these two cases are
// about adequacy/evidence classification, not full ORDER/DEAL
// corroboration content.
//---------------------------------------------------------------------
class CStubHistorySourceC43 : public IHistorySource
{
public:
   bool m_selectReturn;
   virtual bool  Select(datetime from, datetime to) { return m_selectReturn; }
   virtual int   OrdersTotal() { return 0; }
   virtual int   DealsTotal()  { return 0; }
   virtual ulong OrderTicketByIndex(int index) { return 0; }
   virtual ulong DealTicketByIndex(int index)  { return 0; }
   virtual bool  OrderGetInteger(ulong ticket, ENUM_ORDER_PROPERTY_INTEGER prop, long &value) { return false; }
   virtual bool  OrderGetDouble(ulong ticket, ENUM_ORDER_PROPERTY_DOUBLE prop, double &value) { return false; }
   virtual bool  OrderGetString(ulong ticket, ENUM_ORDER_PROPERTY_STRING prop, string &value) { return false; }
   virtual bool  DealGetInteger(ulong ticket, ENUM_DEAL_PROPERTY_INTEGER prop, long &value) { return false; }
   virtual bool  DealGetDouble(ulong ticket, ENUM_DEAL_PROPERTY_DOUBLE prop, double &value) { return false; }
   virtual bool  DealGetString(ulong ticket, ENUM_DEAL_PROPERTY_STRING prop, string &value) { return false; }
   virtual int   LastError() { return 0; }
   virtual void  ResetError() {}
};

RecoveryReconciliationRow FindRowC43(const RecoveryReconciliationRow &rows[], string scope, ulong ticket, bool &found)
{
   found = false;
   RecoveryReconciliationRow empty;
   RecoveryReconciliationRow_Init(empty);
   for(int i = 0; i < ArraySize(rows); i++)
   {
      if(rows[i].comparison_scope == scope && rows[i].order_ticket_known && rows[i].order_ticket == ticket)
      {
         found = true;
         return rows[i];
      }
   }
   return empty;
}

// PushLocalOrderAggregate/PushExecutionRequestRecord: local copies of
// Tests/MLQuantAI_Test_C4_2_RecoveryReconciliation.mq5's own private
// fixture helpers of the same name - one .mq5 script cannot include
// another, so this file cannot reuse those definitions directly, even
// though the production globals/functions they touch
// (g_TxOrder_Records/g_TxOrder_Count/OrderAggregateRecord_Init in
// MLQuantAI_TransactionMatchingProjection.mqh,
// ExecutionRequestProjectionRecord_Init/ExecutionRequestProjection_
// AppendRecord in MLQuantAI_ExecutionAuditProjection.mqh) are already
// transitively included via MLQuantAI_RecoveryReconciliation.mqh.
// Kept byte-for-byte equivalent to the C4.2 test file's versions.
void PushLocalOrderAggregate(ulong ticket, double runningVolume, string matchedExecId)
{
   OrderAggregateRecord rec;
   OrderAggregateRecord_Init(rec);
   rec.order_ticket = ticket;
   rec.running_filled_volume = runningVolume;
   rec.matched_execution_request_id = matchedExecId;
   rec.match_status = (matchedExecId != "") ? TX_MATCH_PARTIAL : TX_MATCH_UNMATCHED;
   int idx = g_TxOrder_Count;
   ArrayResize(g_TxOrder_Records, idx + 1);
   g_TxOrder_Records[idx] = rec;
   g_TxOrder_Count++;
}

void PushExecutionRequestRecord(string execId, string candidateId, datetime anchor, bool anchorKnown, double lotSize)
{
   ExecutionRequestProjectionRecord rec;
   ExecutionRequestProjectionRecord_Init(rec);
   rec.execution_request_id = execId;
   rec.execution_request_hash = "hash_" + execId;
   rec.candidate_id = candidateId;
   rec.side = ORDER_TYPE_BUY;
   rec.lot_size = lotSize;
   rec.recovery_anchor_time = anchor;
   rec.recovery_anchor_time_known = anchorKnown;
   ExecutionRequestProjection_AppendRecord(rec);
}

//=====================================================================
// Case 1
//=====================================================================
void Test_C43_Case01_NoAttestation_Absent()
{
   Print("--- Case 1: no attestation supplied -> ABSENT -> UNASSESSED ---");
   RecoveryCoverageAttestation empty;
   RecoveryCoverageAttestation_Init(empty);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      false, empty, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_ABSENT, "attestation_present=false classifies as ABSENT");

   ENUM_RECOVERY_COVERAGE_VERDICT verdict = RecoveryCoverage_Evaluate(
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, empty, status);
   Check(verdict == RECOVERY_COVERAGE_VERDICT_UNASSESSED, "ABSENT evidence -> UNASSESSED verdict");
   Check(RecoveryCoverage_DetailToken(status, verdict) == "COVERAGE_EVIDENCE_ABSENT", "detail token is the fixed ABSENT literal");
}

//=====================================================================
// Case 2
//=====================================================================
void Test_C43_Case02_FullCoverage_QuerySucceeded_Proven()
{
   Print("--- Case 2: attestation fully covers required window, query succeeded -> PROVEN ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM - 3600, REQUIRED_TO + 3600, EVAL_TIME + 3600, TEST_MARKER);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_VALID, "matching, fresh attestation classifies as VALID");
   ENUM_RECOVERY_COVERAGE_VERDICT verdict = RecoveryCoverage_Evaluate(
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, a, status);
   Check(verdict == RECOVERY_COVERAGE_VERDICT_PROVEN, "full coverage + succeeded query -> PROVEN");
   Check(RecoveryCoverage_DetailToken(status, verdict) == "", "PROVEN carries no detail token - never surfaced into a row anyway");
}

//=====================================================================
// Case 3
//=====================================================================
void Test_C43_Case03_ExactBoundaryCoverage_Proven()
{
   Print("--- Case 3: attestation covers required window exactly at both boundaries -> PROVEN ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, TEST_MARKER);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   ENUM_RECOVERY_COVERAGE_VERDICT verdict = RecoveryCoverage_Evaluate(
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, a, status);
   Check(verdict == RECOVERY_COVERAGE_VERDICT_PROVEN, "coverage_from==required_from and coverage_to==required_to (inclusive) -> PROVEN");
}

//=====================================================================
// Case 4
//=====================================================================
void Test_C43_Case04_MissingTailCoverage_Insufficient()
{
   Print("--- Case 4: attestation partially covers required window (missing tail) -> INSUFFICIENT ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO - 600, EVAL_TIME, TEST_MARKER);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   ENUM_RECOVERY_COVERAGE_VERDICT verdict = RecoveryCoverage_Evaluate(
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, a, status);
   Check(verdict == RECOVERY_COVERAGE_VERDICT_INSUFFICIENT, "coverage_to < required_to -> INSUFFICIENT");
   Check(RecoveryCoverage_DetailToken(status, verdict) == "COVERAGE_GAP_ATTESTED", "detail token is the fixed gap literal");
}

//=====================================================================
// Case 5
//=====================================================================
void Test_C43_Case05_MissingHeadCoverage_Insufficient()
{
   Print("--- Case 5: attestation partially covers required window (missing head) -> INSUFFICIENT ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM + 600, REQUIRED_TO, EVAL_TIME, TEST_MARKER);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   ENUM_RECOVERY_COVERAGE_VERDICT verdict = RecoveryCoverage_Evaluate(
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, a, status);
   Check(verdict == RECOVERY_COVERAGE_VERDICT_INSUFFICIENT, "coverage_from > required_from -> INSUFFICIENT");
}

//=====================================================================
// Case 6
//=====================================================================
void Test_C43_Case06_FullCoverage_QueryFailed_Unassessed()
{
   Print("--- Case 6: attestation fully covers required window but query failed -> UNASSESSED ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, TEST_MARKER);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_VALID, "full coverage attestation is itself VALID regardless of query outcome");
   ENUM_RECOVERY_COVERAGE_VERDICT verdict = RecoveryCoverage_Evaluate(
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, false, a, status);
   Check(verdict == RECOVERY_COVERAGE_VERDICT_UNASSESSED, "VALID evidence but history_select_succeeded=false -> UNASSESSED (decision-order step 4)");
}

//=====================================================================
// Case 7
//=====================================================================
void Test_C43_Case07_GapAndQueryFailed_InsufficientWins()
{
   Print("--- Case 7: attestation does not cover required window AND query failed -> INSUFFICIENT (decision-order step 3 precedes step 4) ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO - 600, EVAL_TIME, TEST_MARKER);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   ENUM_RECOVERY_COVERAGE_VERDICT verdict = RecoveryCoverage_Evaluate(
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, false, a, status);
   Check(verdict == RECOVERY_COVERAGE_VERDICT_INSUFFICIENT, "coverage gap wins over query failure - never UNASSESSED here");
}

//=====================================================================
// Case 8
//=====================================================================
void Test_C43_Case08_MissingIntegrityMarker_Invalid()
{
   Print("--- Case 8: integrity_identifier empty -> INVALID -> UNASSESSED (evaluator-owned, never source-rejected) ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, "");
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_INVALID, "empty integrity_identifier classifies as INVALID");
   ENUM_RECOVERY_COVERAGE_VERDICT verdict = RecoveryCoverage_Evaluate(
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, a, status);
   Check(verdict == RECOVERY_COVERAGE_VERDICT_UNASSESSED, "INVALID evidence -> UNASSESSED");

   // Source/evaluator validation boundary: ParameterCoverageAttestationSource
   // never inspects integrity_identifier - TryGet must still succeed with
   // an empty marker, since the three presence-only fields are all
   // non-empty here.
   ParameterCoverageAttestationSource src;
   src.Configure(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, REQUIRED_FROM, REQUIRED_TO, EVAL_TIME,
                 "ISSUER", "REF", "");
   RecoveryCoverageAttestation out;
   string reason = "";
   bool present = src.TryGet(TEST_BROKER, TEST_ACCOUNT, out, reason);
   Check(present, "TryGet=true even with an empty integrity_identifier - the source is presence-only, integrity is evaluator-owned");
}

//=====================================================================
// Case 9
//=====================================================================
void Test_C43_Case09_WrongIntegrityMarker_Invalid()
{
   Print("--- Case 9: integrity_identifier wrong literal value -> INVALID -> UNASSESSED ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, "WRONG_MARKER");
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_INVALID, "wrong integrity_identifier literal classifies as INVALID");
   ENUM_RECOVERY_COVERAGE_VERDICT verdict = RecoveryCoverage_Evaluate(
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, a, status);
   Check(verdict == RECOVERY_COVERAGE_VERDICT_UNASSESSED, "INVALID evidence -> UNASSESSED");
}

//=====================================================================
// Case 10
//=====================================================================
void Test_C43_Case10_IntegrityMarkerCaseVariant_Invalid()
{
   Print("--- Case 10: integrity_identifier case-variant of correct literal -> still INVALID (no case-folding) ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, "recovery_coverage_attestation_c4_v1");
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_INVALID, "case-variant marker still classifies as INVALID - byte-exact comparison only");
}

//=====================================================================
// Case 11
//=====================================================================
void Test_C43_Case11_EmptyBrokerIdentity_SourceRejects_Absent()
{
   Print("--- Case 11: empty broker_identity is rejected by the SOURCE (presence-only validation) -> ABSENT, never BROKER_MISMATCH ---");
   ParameterCoverageAttestationSource src;
   src.Configure("", TEST_ACCOUNT, TEST_TIMEBASIS, REQUIRED_FROM, REQUIRED_TO, EVAL_TIME,
                 "ISSUER", "REF", TEST_MARKER);
   RecoveryCoverageAttestation out;
   string reason = "";
   bool present = src.TryGet(TEST_BROKER, TEST_ACCOUNT, out, reason);
   Check(!present, "TryGet returns false for an empty broker_identity");
   Check(reason == "broker_identity is empty", "out_reason names the exact empty field");

   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      present, out, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_ABSENT, "source decline classifies as ABSENT, never BROKER_MISMATCH");
}

//=====================================================================
// Case 12
//=====================================================================
void Test_C43_Case12_BrokerIdentityMismatch()
{
   Print("--- Case 12: broker_identity present on both sides but different -> BROKER_MISMATCH ---");
   RecoveryCoverageAttestation a = MakeAttestation("ServerB", TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, TEST_MARKER);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_BROKER_MISMATCH, "different non-empty broker_identity -> BROKER_MISMATCH");
   ENUM_RECOVERY_COVERAGE_VERDICT verdict = RecoveryCoverage_Evaluate(
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, a, status);
   Check(verdict == RECOVERY_COVERAGE_VERDICT_UNASSESSED, "BROKER_MISMATCH -> UNASSESSED");
}

//=====================================================================
// Case 13
//=====================================================================
void Test_C43_Case13_BrokerCaseWhitespaceVariant_StillMismatch()
{
   Print("--- Case 13: broker_identity differs only by case/whitespace -> still BROKER_MISMATCH (no folding/trimming) ---");
   RecoveryCoverageAttestation a = MakeAttestation("servera ", TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, TEST_MARKER);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_BROKER_MISMATCH, "case/whitespace variant is still a mismatch - byte-exact only");
}

//=====================================================================
// Case 14
//=====================================================================
void Test_C43_Case14_EmptyAccountIdentity_SourceRejects_Absent()
{
   Print("--- Case 14: empty account_identity is rejected by the source -> ABSENT ---");
   ParameterCoverageAttestationSource src;
   src.Configure(TEST_BROKER, "", TEST_TIMEBASIS, REQUIRED_FROM, REQUIRED_TO, EVAL_TIME,
                 "ISSUER", "REF", TEST_MARKER);
   RecoveryCoverageAttestation out;
   string reason = "";
   bool present = src.TryGet(TEST_BROKER, TEST_ACCOUNT, out, reason);
   Check(!present, "TryGet returns false for an empty account_identity");
   Check(reason == "account_identity is empty", "out_reason names the exact empty field");
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      present, out, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_ABSENT, "source decline classifies as ABSENT, never ACCOUNT_MISMATCH");
}

//=====================================================================
// Case 15
//=====================================================================
void Test_C43_Case15_AccountIdentityMismatch()
{
   Print("--- Case 15: account_identity present on both sides but different -> ACCOUNT_MISMATCH ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, "9999999", TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, TEST_MARKER);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_ACCOUNT_MISMATCH, "different non-empty account_identity -> ACCOUNT_MISMATCH");
}

//=====================================================================
// Case 16
//=====================================================================
void Test_C43_Case16_EmptyTimeBasis_SourceRejects_Absent()
{
   Print("--- Case 16: empty server_time_basis is rejected by the source -> ABSENT ---");
   ParameterCoverageAttestationSource src;
   src.Configure(TEST_BROKER, TEST_ACCOUNT, "", REQUIRED_FROM, REQUIRED_TO, EVAL_TIME,
                 "ISSUER", "REF", TEST_MARKER);
   RecoveryCoverageAttestation out;
   string reason = "";
   bool present = src.TryGet(TEST_BROKER, TEST_ACCOUNT, out, reason);
   Check(!present, "TryGet returns false for an empty server_time_basis");
   Check(reason == "server_time_basis is empty", "out_reason names the exact empty field");
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      present, out, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_ABSENT, "source decline classifies as ABSENT, never TIME_BASIS_MISMATCH");
}

//=====================================================================
// Case 17
//=====================================================================
void Test_C43_Case17_TimeBasisMismatch()
{
   Print("--- Case 17: server_time_basis present on both sides but different -> TIME_BASIS_MISMATCH ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, "OTHER_BASIS",
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, TEST_MARKER);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_TIME_BASIS_MISMATCH, "different non-empty server_time_basis -> TIME_BASIS_MISMATCH");
}

//=====================================================================
// Case 18
//=====================================================================
void Test_C43_Case18_ValidUntilZero_Stale()
{
   Print("--- Case 18: valid_until == 0 -> STALE ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO, 0, TEST_MARKER);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_STALE, "valid_until==0 -> STALE");
}

//=====================================================================
// Case 19
//=====================================================================
void Test_C43_Case19_EvaluationTimeAfterValidUntil_Stale()
{
   Print("--- Case 19: evaluation_time > valid_until -> STALE ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME - 60, TEST_MARKER);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_STALE, "evaluation_time one minute past valid_until -> STALE");
}

//=====================================================================
// Case 20
//=====================================================================
void Test_C43_Case20_EvaluationTimeEqualsValidUntil_NotStale()
{
   Print("--- Case 20: evaluation_time == valid_until -> not stale, proceeds to coverage check ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, TEST_MARKER);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status == RECOVERY_COVERAGE_EVIDENCE_VALID, "evaluation_time==valid_until is inclusive - VALID, not STALE");
   ENUM_RECOVERY_COVERAGE_VERDICT verdict = RecoveryCoverage_Evaluate(
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, a, status);
   Check(verdict == RECOVERY_COVERAGE_VERDICT_PROVEN, "full coverage + VALID + succeeded query -> PROVEN");
}

//=====================================================================
// Case 21
//=====================================================================
void Test_C43_Case21_RequiredWindowInvalid_InsufficientRegardless()
{
   Print("--- Case 21: required_from > required_to -> INSUFFICIENT regardless of attestation/query - evidence never consulted (evaluator-only, no report row constructed) ---");
   RecoveryCoverageAttestation fullyValid = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM - 3600, REQUIRED_TO + 3600, EVAL_TIME + 3600, TEST_MARKER);

   // Canonical frozen fixture: evidence_status=ABSENT, evidence_detail=""
   // (decision-order step 1 fires before evidence is ever consulted).
   ENUM_RECOVERY_COVERAGE_VERDICT verdictAbsent = RecoveryCoverage_Evaluate(
      REQUIRED_TO, REQUIRED_FROM, EVAL_TIME, true, fullyValid, RECOVERY_COVERAGE_EVIDENCE_ABSENT);
   Check(verdictAbsent == RECOVERY_COVERAGE_VERDICT_INSUFFICIENT, "malformed bounds -> INSUFFICIENT with the canonical ABSENT fixture");

   // Irrelevance proof: VALID evidence with full coverage and a succeeded
   // query still cannot override step 1.
   ENUM_RECOVERY_COVERAGE_VERDICT verdictValid = RecoveryCoverage_Evaluate(
      REQUIRED_TO, REQUIRED_FROM, EVAL_TIME, true, fullyValid, RECOVERY_COVERAGE_EVIDENCE_VALID);
   Check(verdictValid == RECOVERY_COVERAGE_VERDICT_INSUFFICIENT, "malformed bounds -> INSUFFICIENT even with VALID evidence and full coverage");

   // Irrelevance proof: query failure also cannot override step 1.
   ENUM_RECOVERY_COVERAGE_VERDICT verdictQueryFailed = RecoveryCoverage_Evaluate(
      REQUIRED_TO, REQUIRED_FROM, EVAL_TIME, false, fullyValid, RECOVERY_COVERAGE_EVIDENCE_VALID);
   Check(verdictQueryFailed == RECOVERY_COVERAGE_VERDICT_INSUFFICIENT, "malformed bounds -> INSUFFICIENT even when the query also failed");
}

//=====================================================================
// Case 22
//=====================================================================
void Test_C43_Case22_Determinism_RepeatedCallsIdentical()
{
   Print("--- Case 22: same fixed input gives the same evaluator outputs on repeated calls ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, TEST_MARKER);

   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status1 = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status2 = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status3 = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   Check(status1 == status2 && status2 == status3, "RecoveryCoverage_ClassifyEvidence: three repeated calls, identical inputs, identical outputs");

   ENUM_RECOVERY_COVERAGE_VERDICT verdict1 = RecoveryCoverage_Evaluate(REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, a, status1);
   ENUM_RECOVERY_COVERAGE_VERDICT verdict2 = RecoveryCoverage_Evaluate(REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, a, status1);
   ENUM_RECOVERY_COVERAGE_VERDICT verdict3 = RecoveryCoverage_Evaluate(REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, a, status1);
   Check(verdict1 == verdict2 && verdict2 == verdict3, "RecoveryCoverage_Evaluate: three repeated calls, identical inputs, identical outputs");
}

//=====================================================================
// Case 23 - ScanLive integration
//=====================================================================
void Test_C43_Case23_WorkedExample_PerFactIndependence()
{
   Print("--- Case 23: §11.7 worked example via real ScanLive - two local facts, one shared attestation, independent verdicts ---");
   OrderAggregateRegistry_Reset();
   ExecutionRequestProjection_Reset();

   // Fixture bounds are computed relative to a captured "now" - ScanLive
   // itself reads TimeCurrent() internally for scanServerTime, and this
   // test cannot inject that value, so every bound below is deliberately
   // built from the SAME clock source (TimeCurrent(), read once here)
   // rather than a fixed calendar literal, with a 7-day margin around
   // the attestation's validity/coverage so the (negligible, same-tick-
   // in-practice) gap between this read and ScanLive's own internal
   // TimeCurrent() read can never flip either verdict.
   //
   // Identity fix (this review round): ScanLive's scan-context capture
   // reads the REAL connected terminal's AccountInfoString(ACCOUNT_SERVER)
   // / AccountInfoInteger(ACCOUNT_LOGIN) - not the TEST_BROKER/TEST_ACCOUNT
   // literals used by the pure-evaluator cases above (which compare a
   // fixture against itself and never touch a real account). Configuring
   // the attestation source with fixed literals here would almost
   // certainly BROKER_MISMATCH/ACCOUNT_MISMATCH against whatever real
   // demo/live account this test runs under, collapsing both facts to
   // UNASSESSED and silently testing nothing. The attestation is
   // therefore configured with the SAME runtime identity ScanLive will
   // observe, captured via the same two calls.
   datetime testNow = TimeCurrent();
   string   runtimeBroker  = AccountInfoString(ACCOUNT_SERVER);
   string   runtimeAccount = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   bool     identityReady  = (runtimeBroker != "" && runtimeAccount != "");
   Check(identityReady, "Case 23 fixture-environment precondition: terminal server/login identity is non-empty");
   if(!identityReady)
   {
      Print("  [ABORT] Case 23 body not run after failed fixture-environment precondition - Check() alone is non-fatal and already emitted [FAIL] above; this Print is not a distinct skip-accounting mechanism, just a return before the test proceeds on a broken fixture");
      return;
   }

   datetime anchorA = testNow - 3 * 3600;  // required window [testNow-4h, testNow] - fully inside coverage below
   datetime anchorB = testNow - 48 * 3600; // required window starts ~48h before testNow - outside coverage's head

   PushExecutionRequestRecord("EXEC_A", "CAND_A", anchorA, true, 1.0);
   PushLocalOrderAggregate(81001, 1.0, "EXEC_A");
   PushExecutionRequestRecord("EXEC_B", "CAND_B", anchorB, true, 1.0);
   PushLocalOrderAggregate(81002, 1.0, "EXEC_B");

   CStubHistorySourceC43 src;
   src.m_selectReturn = true;

   ParameterCoverageAttestationSource attSrc;
   attSrc.Configure(runtimeBroker, runtimeAccount, TEST_TIMEBASIS,
                     testNow - 24 * 3600, testNow + 7 * 24 * 3600, testNow + 7 * 24 * 3600,
                     "ISSUER", "REF", TEST_MARKER);

   RecoveryScanDiagnostics diag;
   RecoveryReconciliationReport report = RecoveryReconciliation_ScanLive(src, attSrc, false, 0, diag);
   // report.ok is NOT a "scan completed without error" flag - per
   // RecoveryReconciliation_BuildReport, it is true only when EVERY row's
   // posture is neither DEGRADED nor BLOCK_RECOMMENDED (real compile/run
   // evidence, this checkpoint's review round). Since C4.2 v1 Option B
   // means the ORDER unit always resolves to
   // RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE (DEGRADED) whenever any local
   // order exists, report.ok is essentially never true for a populated
   // scan - it is an "everything fully corroborated" signal, not a
   // fail-closed/error signal (see the C4.2 test suite's own
   // Test_OkTrue_WhenNoRowsAtAll, which names exactly the one case where
   // it is true). Not asserted here - the row-level checks below are
   // what actually verify this test's claims.

   // "AGGREGATE_DEAL_VOLUME" finding is RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE-
   // class findings only via the ORDER scope (C4.2 v1 Option B); for
   // AGGREGATE_DEAL_VOLUME specifically, BuildReport's gate (verified by
   // reading MLQuantAI_RecoveryReconciliation.mqh directly) sets
   // gated=false if and only if outcome.adequacy==PROVEN - with zero
   // deals staged in the stub source, a non-gated AGGREGATE_DEAL_VOLUME
   // row resolves to RECOVERY_NO_CORROBORATING_HISTORY specifically, so
   // asserting that exact value (not merely "!=INSUFFICIENT") is a
   // precise, not approximate, proof that adequacy==PROVEN was reached.
   bool foundA = false;
   RecoveryReconciliationRow rowA = FindRowC43(report.rows, "AGGREGATE_DEAL_VOLUME", 81001, foundA);
   Check(foundA, "Order A's AGGREGATE_DEAL_VOLUME row exists");
   Check(rowA.finding == RECOVERY_NO_CORROBORATING_HISTORY,
         "Order A is NOT gated - PROVEN unlocked full evaluation (fully covered by the attestation), and with zero staged deals the unlocked finding is exactly RECOVERY_NO_CORROBORATING_HISTORY, never RECOVERY_WINDOW_INSUFFICIENT");

   bool foundB = false;
   RecoveryReconciliationRow rowB = FindRowC43(report.rows, "AGGREGATE_DEAL_VOLUME", 81002, foundB);
   Check(foundB, "Order B's AGGREGATE_DEAL_VOLUME row exists");
   Check(rowB.finding == RECOVERY_WINDOW_INSUFFICIENT, "Order B IS gated - INSUFFICIENT (its required window extends before the attestation's coverage_from)");
   Check(rowB.detail == "COVERAGE_GAP_ATTESTED", "Order B's detail carries the fixed gap token - same scan, same attestation, different verdict than Order A");
}

//=====================================================================
// Case 24 - ScanLive integration
//=====================================================================
// NOTE ON WHAT THIS TEST DOES AND DOES NOT PROVE (correction from this
// checkpoint's review round): the private outcome-level claim "step 3
// (coverage gap) wins over step 4 (query failure) inside
// RecoveryCoverage_Evaluate" is Case 7's job - a direct pure-evaluator
// test, since RecoveryQueryOutcome (and its evidence_status/adequacy
// fields) is never exposed on RecoveryReconciliationReport/Row and so
// cannot be observed through ScanLive at all. This test's actual,
// narrower and still valuable claim is a PUBLIC-SURFACE non-leakage
// regression: even in the one scenario where the private per-fact
// evaluation now (post-C4.3) resolves to INSUFFICIENT-via-gap rather
// than UNASSESSED-via-query-failure, Branch B of
// RecoveryReconciliation_BuildReport's gate - which ignores
// outcome.adequacy unconditionally whenever the query itself failed -
// still produces the exact same public finding/detail C4.2 always
// produced. A regression here would mean C4.3's wiring had started
// leaking private adequacy into a code path §11.9's compatibility
// freeze says must stay untouched.
void Test_C43_Case24_ScanLive_PublicSurfaceNoLeakage()
{
   Print("--- Case 24: two-part test - (1) the pure evaluator, called with the same configured attestation, runtime identity, overlap rule, and deliberately large coverage-head gap that Part 2 also uses, is asserted directly to land on VALID/INSUFFICIENT-via-gap; (2) the real ScanLive(), given that same attestation and gap relationship plus a failed HistorySelect(), is asserted to still produce Branch B's unchanged public finding/detail. Part 1's requiredTo/evaluation_time use a testNow captured in this test, not ScanLive's own later internal TimeCurrent() read (scanServerTime) - those are two separate clock reads, not identical; the deliberately large head-side gap (~25h) makes Part 1's INSUFFICIENT result robust to that gap regardless. Part 1 does not read ScanLive's internal outcomes[] (impossible - that array is never exposed on the report); it establishes that the fixture ITSELF genuinely constructs the gap scenario, so Part 2's public-surface assertion is not resting on an unverified assumption about what the private path did ---");
   OrderAggregateRegistry_Reset();
   ExecutionRequestProjection_Reset();

   // Same identity fix as Case 23 (this review round): the attestation
   // must be configured with the REAL runtime ACCOUNT_SERVER/
   // ACCOUNT_LOGIN, not fixed literals - otherwise the fixture would
   // classify as BROKER_MISMATCH/ACCOUNT_MISMATCH on a real terminal,
   // not the VALID+coverage-gap scenario this test is about.
   datetime testNow = TimeCurrent();
   string   runtimeBroker  = AccountInfoString(ACCOUNT_SERVER);
   string   runtimeAccount = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   bool     identityReady  = (runtimeBroker != "" && runtimeAccount != "");
   Check(identityReady, "Case 24 fixture-environment precondition: terminal server/login identity is non-empty");
   if(!identityReady)
   {
      Print("  [ABORT] Case 24 body not run after failed fixture-environment precondition - Check() alone is non-fatal and already emitted [FAIL] above; this Print is not a distinct skip-accounting mechanism, just a return before the test proceeds on a broken fixture");
      return;
   }

   datetime anchor       = testNow - 48 * 3600;
   datetime coverageFrom = testNow - 24 * 3600;
   datetime coverageTo   = testNow + 7 * 24 * 3600;
   datetime validUntil   = testNow + 7 * 24 * 3600;
   // required window extends before coverageFrom -> gap, by construction:
   // required_from = anchor - overlap(3600s) = testNow-49h < coverageFrom = testNow-24h.

   // --- Part 1: pure-evaluator verification of the fixture itself ---
   RecoveryCoverageAttestation fixtureAttestation = MakeAttestation(
      runtimeBroker, runtimeAccount, TEST_TIMEBASIS, coverageFrom, coverageTo, validUntil, TEST_MARKER);
   datetime requiredFrom = anchor - MLQUANTAI_C4_RECOVERY_OVERLAP_MINUTES_DEFAULT * 60;
   datetime requiredTo   = testNow;

   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS directStatus = RecoveryCoverage_ClassifyEvidence(
      true, fixtureAttestation, runtimeBroker, runtimeAccount, TEST_TIMEBASIS, testNow);
   Check(directStatus == RECOVERY_COVERAGE_EVIDENCE_VALID,
         "Part 1: with matching runtime identity, the fixture attestation classifies as VALID (not a mismatch/staleness false-positive)");

   ENUM_RECOVERY_COVERAGE_VERDICT directVerdict = RecoveryCoverage_Evaluate(
      requiredFrom, requiredTo, testNow, false /* mirrors Part 2's failed query */, fixtureAttestation, directStatus);
   Check(directVerdict == RECOVERY_COVERAGE_VERDICT_INSUFFICIENT,
         "Part 1: this configured attestation and deliberately large head-gap relationship, with failed-query flag, resolves to INSUFFICIENT via decision-order step 3 before step 4");

   // --- Part 2: ScanLive integration, public-surface non-leakage ---
   PushExecutionRequestRecord("EXEC_C", "CAND_C", anchor, true, 1.0);
   PushLocalOrderAggregate(81003, 1.0, "EXEC_C");

   CStubHistorySourceC43 src;
   src.m_selectReturn = false;  // HistorySelect() itself fails

   ParameterCoverageAttestationSource attSrc;
   attSrc.Configure(runtimeBroker, runtimeAccount, TEST_TIMEBASIS,
                     coverageFrom, coverageTo, validUntil,
                     "ISSUER", "REF", TEST_MARKER);

   RecoveryScanDiagnostics diag;
   RecoveryReconciliationReport report = RecoveryReconciliation_ScanLive(src, attSrc, false, 0, diag);
   // report.ok not asserted here either - same reasoning as Case 23
   // above: it is an aggregate "every row fully corroborated" signal,
   // not a completion/error flag, and this fixture's ORDER row is
   // guaranteed DEGRADED by C4.2 v1 Option B regardless of C4.3.

   bool found = false;
   RecoveryReconciliationRow row = FindRowC43(report.rows, "ORDER", 81003, found);
   Check(found, "Part 2: the ORDER row exists");
   Check(row.finding == RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE,
         "Part 2: public finding is still RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE, unchanged from C4.2 - Branch B ignores outcome.adequacy entirely when the query itself failed. The Part 1 fixture verification establishes the same valid-attestation and head-gap condition exercised here; the ScanLive outcome itself remains intentionally private.");
   Check(row.detail == "", "Part 2: Branch B never surfaces evidence_detail into the public row, even though it was computed on the private outcome - no leakage");
}

//=====================================================================
// Case 25b (Case 25a is a reviewer-performed structural gate, not a
// compiled test - see this file's header comment).
//=====================================================================
void Test_C43_Case25_Determinism_NoStateDependence()
{
   Print("--- Case 25b: evaluator output does not change after unrelated stub-history activity occurs between equivalent calls (weaker than Case 25a's structural review - proves behavioral purity for the inputs tested, does NOT and cannot prove the complete absence of every possible call) ---");
   RecoveryCoverageAttestation a = MakeAttestation(TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS,
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, TEST_MARKER);

   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS statusBefore = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   ENUM_RECOVERY_COVERAGE_VERDICT verdictBefore = RecoveryCoverage_Evaluate(
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, a, statusBefore);

   // Unrelated activity deliberately interleaved between equivalent
   // calls, to probe for environmental leakage into the pure functions
   // under test - a fixed, unrelated stub-history call. Deliberately NOT
   // a real TimeCurrent() read: a test named "NoStateDependence" should
   // not itself depend on the live terminal clock for its own fixture
   // construction.
   CStubHistorySourceC43 unrelatedSrc;
   unrelatedSrc.m_selectReturn = true;
   unrelatedSrc.Select(D'2026.06.15 11:00:00', D'2026.06.15 12:00:00');

   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS statusAfter = RecoveryCoverage_ClassifyEvidence(
      true, a, TEST_BROKER, TEST_ACCOUNT, TEST_TIMEBASIS, EVAL_TIME);
   ENUM_RECOVERY_COVERAGE_VERDICT verdictAfter = RecoveryCoverage_Evaluate(
      REQUIRED_FROM, REQUIRED_TO, EVAL_TIME, true, a, statusAfter);

   Check(statusBefore == statusAfter, "RecoveryCoverage_ClassifyEvidence: unaffected by intervening stub-history activity");
   Check(verdictBefore == verdictAfter, "RecoveryCoverage_Evaluate: unaffected by intervening stub-history activity");
   Check(true, "this test proves behavioral purity for the inputs exercised here ONLY - it does not and cannot prove the complete absence of every possible call; that stronger claim rests on Case 25a's structural review, performed separately, not by this compiled test");
}

void OnStart()
{
   Print("=== MLQuantAI Test: C4.3 Recovery Coverage Attestation (§11 v1 - parameter source only) ===");

   Test_C43_Case01_NoAttestation_Absent();
   Test_C43_Case02_FullCoverage_QuerySucceeded_Proven();
   Test_C43_Case03_ExactBoundaryCoverage_Proven();
   Test_C43_Case04_MissingTailCoverage_Insufficient();
   Test_C43_Case05_MissingHeadCoverage_Insufficient();
   Test_C43_Case06_FullCoverage_QueryFailed_Unassessed();
   Test_C43_Case07_GapAndQueryFailed_InsufficientWins();
   Test_C43_Case08_MissingIntegrityMarker_Invalid();
   Test_C43_Case09_WrongIntegrityMarker_Invalid();
   Test_C43_Case10_IntegrityMarkerCaseVariant_Invalid();
   Test_C43_Case11_EmptyBrokerIdentity_SourceRejects_Absent();
   Test_C43_Case12_BrokerIdentityMismatch();
   Test_C43_Case13_BrokerCaseWhitespaceVariant_StillMismatch();
   Test_C43_Case14_EmptyAccountIdentity_SourceRejects_Absent();
   Test_C43_Case15_AccountIdentityMismatch();
   Test_C43_Case16_EmptyTimeBasis_SourceRejects_Absent();
   Test_C43_Case17_TimeBasisMismatch();
   Test_C43_Case18_ValidUntilZero_Stale();
   Test_C43_Case19_EvaluationTimeAfterValidUntil_Stale();
   Test_C43_Case20_EvaluationTimeEqualsValidUntil_NotStale();
   Test_C43_Case21_RequiredWindowInvalid_InsufficientRegardless();
   Test_C43_Case22_Determinism_RepeatedCallsIdentical();
   Test_C43_Case23_WorkedExample_PerFactIndependence();
   Test_C43_Case24_ScanLive_PublicSurfaceNoLeakage();
   Test_C43_Case25_Determinism_NoStateDependence();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
