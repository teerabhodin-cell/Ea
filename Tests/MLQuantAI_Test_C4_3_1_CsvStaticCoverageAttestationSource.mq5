//+------------------------------------------------------------------+
//| MLQuantAI_Test_C4_3_1_CsvStaticCoverageAttestationSource.mq5      |
//| C4.3.1 implementation test suite, per this checkpoint's frozen    |
//| design (CsvStaticCoverageAttestationSource - the second of §11.5's |
//| two v1-authorized ICoverageAttestationSource implementations).    |
//|                                                                    |
//| Scope: this file tests ONLY the new source class's own            |
//| structural/parse behavior (its Load()/TryGet() lifecycle, file    |
//| format, and validation-ownership boundary) plus the already-       |
//| shipped evaluator's response to CSV-sourced content for cases     |
//| 16-19. It does not modify, re-run, or duplicate the existing      |
//| C4.3 §11 Case 1-25 evaluator suite (see                            |
//| MLQuantAI_Test_C4_3_RecoveryCoverageAttestation.mq5), does not     |
//| touch RecoveryReconciliation_ScanLive() or any evaluator source,   |
//| and performs no MLQuantAI.mq5 runtime wiring - all out of scope    |
//| for this checkpoint.                                               |
//|                                                                    |
//| Case 20 (failed reload invalidates cache) needs the same source    |
//| instance's fixed-at-construction file to change content between    |
//| two Load() calls - Load()'s frozen signature takes no filename     |
//| argument (§ design), so this case writes and deletes its own       |
//| test-runtime scratch file rather than reusing a committed fixture; |
//| that scratch file is not part of the checkpoint's file allowlist   |
//| because it never persists past this test's execution.              |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_CsvStaticCoverageAttestationSource.mqh>
#include <MLQuantAI/Execution/MLQuantAI_RecoveryCoverageEvaluator.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Case 1: the happy path - every one of the 9 fields must come back
// exactly as written in the fixture, with no trimming/case-folding.
// valid.csv also carries a blank trailing EOF line (§ format), so this
// case implicitly exercises that tolerance too.
//---------------------------------------------------------------------
void Test_C431_Case01_ValidParse()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.valid.csv");
   string err;
   Check(src.Load(err), "Case01: Load() succeeds on valid.csv (including its blank trailing EOF line)");

   RecoveryCoverageAttestation a;
   string reason;
   bool got = src.TryGet("ignored_broker", "ignored_account", a, reason);
   Check(got, "Case01: TryGet() succeeds after a successful Load()");
   Check(a.broker_identity == "ServerA", "Case01: broker_identity preserved exactly");
   Check(a.account_identity == "1000001", "Case01: account_identity preserved exactly");
   Check(a.server_time_basis == "MT5_TRADE_SERVER_TIME", "Case01: server_time_basis preserved exactly");
   Check(a.coverage_from == D'2026.09.01 00:00:00', "Case01: coverage_from parsed exactly");
   Check(a.coverage_to == D'2026.09.02 00:00:00', "Case01: coverage_to parsed exactly");
   Check(a.valid_until == D'2026.09.02 00:00:00', "Case01: valid_until parsed exactly");
   Check(a.issuer_identity == "OPS", "Case01: issuer_identity preserved exactly");
   Check(a.evidence_reference == "Ref-A_01", "Case01: evidence_reference preserved exactly (no trim/case-fold)");
   Check(a.integrity_identifier == "RECOVERY_COVERAGE_ATTESTATION_C4_V1", "Case01: integrity_identifier preserved exactly");
}

void Test_C431_Case02_TryGetBeforeLoad()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.valid.csv");
   RecoveryCoverageAttestation a;
   string reason;
   bool got = src.TryGet("x", "y", a, reason);
   Check(!got, "Case02: TryGet() before Load() declines");
   Check(reason == "coverage attestation source is not loaded", "Case02: TryGet() before Load() reason is deterministic");
}

void Test_C431_Case03_MissingFile()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.does_not_exist.csv");
   string err;
   Check(!src.Load(err), "Case03: Load() fails closed on a missing/unopenable file");
   Check(err != "", "Case03: Load() reports a non-empty error on a missing file");
}

void Test_C431_Case04_EmptyFile()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.empty.csv");
   string err;
   Check(!src.Load(err), "Case04: Load() fails closed on an empty file");
}

void Test_C431_Case05_MissingHeader()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.no_header.csv");
   string err;
   Check(!src.Load(err), "Case05: Load() fails closed when the header line is absent entirely");
}

void Test_C431_Case06_WrongHeader()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.bad_header.csv");
   string err;
   Check(!src.Load(err), "Case06: Load() fails closed on a present-but-reordered/wrong header");
}

void Test_C431_Case07_MissingColumn()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.missing_column.csv");
   string err;
   Check(!src.Load(err), "Case07: Load() fails closed when the data row has fewer than 9 fields");
}

void Test_C431_Case08_ExtraColumn()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.extra_column.csv");
   string err;
   Check(!src.Load(err), "Case08: Load() fails closed when the data row has more than 9 fields");
}

void Test_C431_Case09_SecondDataRow()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.two_rows.csv");
   string err;
   Check(!src.Load(err), "Case09: Load() fails closed on a second non-empty data row");
}

void Test_C431_Case10_EmptyBroker()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.empty_broker.csv");
   string err;
   Check(!src.Load(err), "Case10: Load() fails closed when broker_identity is empty");
}

void Test_C431_Case11_EmptyAccount()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.empty_account.csv");
   string err;
   Check(!src.Load(err), "Case11: Load() fails closed when account_identity is empty");
}

void Test_C431_Case12_EmptyTimeBasis()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.empty_time_basis.csv");
   string err;
   Check(!src.Load(err), "Case12: Load() fails closed when server_time_basis is empty");
}

void Test_C431_Case13_BadCoverageFrom()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.bad_coverage_from.csv");
   string err;
   Check(!src.Load(err), "Case13: Load() fails closed on an unparseable coverage_from");
}

void Test_C431_Case14_BadCoverageTo()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.bad_coverage_to.csv");
   string err;
   Check(!src.Load(err), "Case14: Load() fails closed on an unparseable coverage_to");
}

void Test_C431_Case15_BadValidUntil()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.bad_valid_until.csv");
   string err;
   Check(!src.Load(err), "Case15: Load() fails closed on an unparseable valid_until");
}

//---------------------------------------------------------------------
// Cases 16-19: content/policy semantics stay evaluator-owned - the
// source must Load() these successfully (they are all structurally
// well-formed), and the already-shipped, unmodified evaluator must be
// the one to classify them.
//---------------------------------------------------------------------
void Test_C431_Case16_InvalidMarkerEvaluatorInvalid()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.invalid_marker.csv");
   string err;
   Check(src.Load(err), "Case16: Load() succeeds - marker correctness is evaluator-owned, not source-owned");

   RecoveryCoverageAttestation a;
   string reason;
   src.TryGet("ServerA", "1000001", a, reason);

   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status =
      RecoveryCoverage_ClassifyEvidence(true, a, "ServerA", "1000001", "MT5_TRADE_SERVER_TIME", D'2026.09.01 12:00:00');
   Check(status == RECOVERY_COVERAGE_EVIDENCE_INVALID, "Case16: evaluator classifies a wrong integrity marker as INVALID");
}

void Test_C431_Case17_ReversedBoundsEvaluatorInvalid()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.reversed_bounds.csv");
   string err;
   Check(src.Load(err), "Case17: Load() succeeds - bounds ordering is evaluator-owned, not source-owned");

   RecoveryCoverageAttestation a;
   string reason;
   src.TryGet("ServerA", "1000001", a, reason);

   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status =
      RecoveryCoverage_ClassifyEvidence(true, a, "ServerA", "1000001", "MT5_TRADE_SERVER_TIME", D'2026.09.03 00:00:00');
   Check(status == RECOVERY_COVERAGE_EVIDENCE_INVALID, "Case17: evaluator classifies coverage_from > coverage_to as INVALID");
}

void Test_C431_Case18_ExpiredEvaluatorStale()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.expired.csv");
   string err;
   Check(src.Load(err), "Case18: Load() succeeds - staleness is evaluator-owned, not source-owned");

   RecoveryCoverageAttestation a;
   string reason;
   src.TryGet("ServerA", "1000001", a, reason);

   // expired.csv's valid_until is 2026.09.01 00:00:00 - evaluate as of a
   // later, fixed time so staleness is proven deterministically, never
   // dependent on real wall-clock time.
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status =
      RecoveryCoverage_ClassifyEvidence(true, a, "ServerA", "1000001", "MT5_TRADE_SERVER_TIME", D'2026.09.05 00:00:00');
   Check(status == RECOVERY_COVERAGE_EVIDENCE_STALE, "Case18: evaluator classifies a past-valid_until attestation as STALE");
}

void Test_C431_Case19_ContextMismatchEvaluator()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.valid.csv");
   string err;
   Check(src.Load(err), "Case19: Load() succeeds on valid.csv");

   RecoveryCoverageAttestation a;
   string reason;
   src.TryGet("ServerA", "1000001", a, reason);

   // valid.csv's broker_identity is "ServerA"; supply a different scan
   // broker identity to exercise BROKER_MISMATCH. TryGet() itself never
   // filtered on identity (source/evaluator boundary), so this proves
   // the mismatch is purely evaluator-computed.
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS status =
      RecoveryCoverage_ClassifyEvidence(true, a, "ServerB", "1000001", "MT5_TRADE_SERVER_TIME", D'2026.09.01 12:00:00');
   Check(status == RECOVERY_COVERAGE_EVIDENCE_BROKER_MISMATCH, "Case19: evaluator classifies a broker-identity mismatch correctly");
}

//---------------------------------------------------------------------
// Case 20: a failed reload must invalidate a previously cached, valid
// attestation. Load()'s frozen signature carries no filename argument,
// so the same instance's file content must change on disk between two
// Load() calls - done here via a test-runtime scratch file, written
// and deleted entirely within this function (not a committed fixture).
//---------------------------------------------------------------------
void Test_C431_Case20_FailedReloadInvalidatesCache()
{
   string scratchName = "MLQuantAI_CoverageAttestationFixture_V1.c431_case20_scratch.csv";

   int wHandle = FileOpen(scratchName, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   Check(wHandle != INVALID_HANDLE, "Case20 setup: scratch file opens for writing");
   FileWrite(wHandle, MLQUANTAI_C4_3_1_COVERAGE_CSV_REQUIRED_HEADER);
   FileWrite(wHandle, "ServerA,1000001,MT5_TRADE_SERVER_TIME,2026.09.01 00:00:00,2026.09.02 00:00:00,2026.09.02 00:00:00,OPS,Ref-A_01,RECOVERY_COVERAGE_ATTESTATION_C4_V1");
   FileClose(wHandle);

   CsvStaticCoverageAttestationSource src(scratchName);
   string err;
   Check(src.Load(err), "Case20: initial Load() on the scratch file succeeds");

   RecoveryCoverageAttestation a1;
   string reason1;
   bool got1 = src.TryGet("x", "y", a1, reason1);
   Check(got1, "Case20: TryGet() succeeds after the initial successful Load()");
   Check(a1.broker_identity == "ServerA", "Case20: initial cached attestation has the expected content");

   int wHandle2 = FileOpen(scratchName, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   Check(wHandle2 != INVALID_HANDLE, "Case20 setup: scratch file reopens for a corrupting overwrite");
   FileWrite(wHandle2, "not,a,valid,header,at,all");
   FileClose(wHandle2);

   string err2;
   bool reloaded = src.Load(err2);
   Check(!reloaded, "Case20: reload against corrupted content fails closed");

   RecoveryCoverageAttestation a2;
   string reason2;
   bool got2 = src.TryGet("x", "y", a2, reason2);
   Check(!got2, "Case20: TryGet() after a failed reload no longer serves the previously cached attestation");

   FileDelete(scratchName, FILE_COMMON);
}

void Test_C431_Case21_WhitespaceOnlyRowFailsClosed()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.whitespace_row.csv");
   string err;
   Check(!src.Load(err), "Case21: Load() fails closed on a whitespace-only line after the data row (non-zero length, not tolerated as blank)");
}

void Test_C431_Case22_BomHeaderFailsClosed()
{
   CsvStaticCoverageAttestationSource src("MLQuantAI_CoverageAttestationFixture_V1.bom_header.csv");
   string err;
   Check(!src.Load(err), "Case22: Load() fails closed on a UTF-8 BOM-prefixed header via the ordinary header-mismatch path");
}

void OnStart()
{
   Print("=== MLQuantAI Test: C4.3.1 CsvStaticCoverageAttestationSource ===");

   Test_C431_Case01_ValidParse();
   Test_C431_Case02_TryGetBeforeLoad();
   Test_C431_Case03_MissingFile();
   Test_C431_Case04_EmptyFile();
   Test_C431_Case05_MissingHeader();
   Test_C431_Case06_WrongHeader();
   Test_C431_Case07_MissingColumn();
   Test_C431_Case08_ExtraColumn();
   Test_C431_Case09_SecondDataRow();
   Test_C431_Case10_EmptyBroker();
   Test_C431_Case11_EmptyAccount();
   Test_C431_Case12_EmptyTimeBasis();
   Test_C431_Case13_BadCoverageFrom();
   Test_C431_Case14_BadCoverageTo();
   Test_C431_Case15_BadValidUntil();
   Test_C431_Case16_InvalidMarkerEvaluatorInvalid();
   Test_C431_Case17_ReversedBoundsEvaluatorInvalid();
   Test_C431_Case18_ExpiredEvaluatorStale();
   Test_C431_Case19_ContextMismatchEvaluator();
   Test_C431_Case20_FailedReloadInvalidatesCache();
   Test_C431_Case21_WhitespaceOnlyRowFailsClosed();
   Test_C431_Case22_BomHeaderFailsClosed();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
}
