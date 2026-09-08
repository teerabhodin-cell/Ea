//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_RecoveryReconciliationStartup.mqh |
//| C4.4 implementation, per this checkpoint's frozen design.         |
//|                                                                    |
//| Wires the already-shipped, already-tested C4.2/C4.3/C4.3.1        |
//| capability - RecoveryReconciliation_ScanLive(), the real           |
//| CLiveHistorySource, and both v1-authorized                        |
//| ICoverageAttestationSource implementations                        |
//| (ParameterCoverageAttestationSource, CsvStaticCoverageAttestation  |
//| Source) - into the real EA for the first time, as one read-only,   |
//| diagnostic-only startup scan. Nothing in RecoveryReconciliation.mqh,|
//| the evaluator, either concrete source, or CLiveHistorySource is     |
//| changed by this checkpoint - this file is wiring only.             |
//|                                                                    |
//| Explicit source-selection mode (frozen this checkpoint) - no        |
//| auto-detection, no source-to-source fallback, ever:                |
//|   NONE      - NullCoverageAttestationSource. Default. Reproduces    |
//|               today's exact shipped four-argument-wrapper behavior  |
//|               (adequacy always UNASSESSED).                        |
//|   PARAMETER - ParameterCoverageAttestationSource, Configure()'d      |
//|               from raw EA inputs, passed through unconditionally.  |
//|               This source's own already-shipped TryGet() presence   |
//|               boundary (broker_identity/account_identity/           |
//|               server_time_basis must be non-empty) is the ONLY      |
//|               "cannot provide a record" gate for this mode - this   |
//|               file does not duplicate that check. A declining       |
//|               source here behaves identically to NONE from          |
//|               ScanLive's perspective (RECOVERY_COVERAGE_EVIDENCE_   |
//|               ABSENT), with no separate wrapper-level substitution   |
//|               needed.                                              |
//|   CSV       - CsvStaticCoverageAttestationSource, Load()'d exactly   |
//|               once here, at startup. A Load() failure (missing/     |
//|               malformed file, including a blank configured          |
//|               filename) is the one genuine "cannot construct/       |
//|               provide loaded data" case this file itself handles:   |
//|               logs the deterministic reason and substitutes          |
//|               NullCoverageAttestationSource for this session's      |
//|               scan only.                                            |
//|                                                                    |
//| Fallback boundary (frozen): "fallback" here means ONLY selected-    |
//| source construction/load/presence failure. A source that            |
//| successfully provides a record - even one the evaluator will go on   |
//| to classify INVALID, STALE, or *_MISMATCH, or whose coverage does    |
//| not span the required window - is never intercepted or replaced      |
//| here. That classification is, and remains, entirely evaluator-owned  |
//| (MLQuantAI_RecoveryCoverageEvaluator.mqh, §11.8) - this file never    |
//| re-derives or pre-empts it, including never independently checking   |
//| valid_until==0, coverage_from>coverage_to, or the integrity marker.  |
//|                                                                    |
//| Startup effect (frozen): this scan can never return INIT_FAILED,     |
//| can never trip Safe Mode, and performs no durable write - it is a    |
//| read-only recommendation subsystem with no execution-gate authority  |
//| (Docs/PhaseC_C4_RecoveryHistoryPolicy.md §5/§8). A scan or source     |
//| failure is diagnostic-only (LogWarn/LogInfo), exactly like every      |
//| other read-only *_StartupScan/*_StartupRebuild call in                |
//| MLQuantAI.mq5's OnInit().                                             |
//|                                                                    |
//| Object lifetime: every concrete source and the CLiveHistorySource     |
//| instance are local to RecoveryReconciliation_StartupScan() below -    |
//| constructed fresh on each call, never a global/persistent handle,     |
//| out of scope the moment this function returns. CsvStaticCoverage      |
//| AttestationSource::TryGet() performs no file I/O of its own by        |
//| construction (only Load() does) - this file relies on, and does       |
//| not change, that existing guarantee.                                 |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_RECOVERYRECONCILIATIONSTARTUP_MQH__
#define __MLQUANTAI_RECOVERYRECONCILIATIONSTARTUP_MQH__

#include "MLQuantAI_RecoveryReconciliation.mqh"
#include "MLQuantAI_ParameterCoverageAttestationSource.mqh"
#include "MLQuantAI_CsvStaticCoverageAttestationSource.mqh"
#include "../Logging/MLQuantAI_SystemLogger.mqh"

enum ENUM_C44_COVERAGE_SOURCE_MODE
{
   C44_COVERAGE_SOURCE_NONE,
   C44_COVERAGE_SOURCE_PARAMETER,
   C44_COVERAGE_SOURCE_CSV
};

string C44CoverageSourceModeToString(ENUM_C44_COVERAGE_SOURCE_MODE mode)
{
   switch(mode)
   {
      case C44_COVERAGE_SOURCE_NONE:      return "NONE";
      case C44_COVERAGE_SOURCE_PARAMETER: return "PARAMETER";
      case C44_COVERAGE_SOURCE_CSV:       return "CSV";
      default:                            return "UNKNOWN";
   }
}

// Diagnostic-only row count by posture - never used to decide control
// flow, only to summarize report.rows[] for the one LogInfo line below.
int RecoveryReconciliation_CountPosture(const RecoveryReconciliationReport &report, ENUM_RECOVERY_POSTURE posture)
{
   int n = 0;
   for(int i = 0; i < ArraySize(report.rows); i++)
      if(report.rows[i].posture == posture)
         n++;
   return n;
}

void RecoveryReconciliation_LogScanSummary(ENUM_C44_COVERAGE_SOURCE_MODE mode, string effectiveSource,
                                            const RecoveryReconciliationReport &report)
{
   int informational = RecoveryReconciliation_CountPosture(report, RECOVERY_POSTURE_INFORMATIONAL);
   int degraded       = RecoveryReconciliation_CountPosture(report, RECOVERY_POSTURE_DEGRADED);
   int blockRecommended = RecoveryReconciliation_CountPosture(report, RECOVERY_POSTURE_BLOCK_RECOMMENDED);

   LogInfo(StringFormat(
      "C4.4 recovery-coverage scan: mode=%s effective_source=%s report.ok=%s "
      "local_facts_scanned=%d rows(informational=%d degraded=%d block_recommended=%d)",
      C44CoverageSourceModeToString(mode), effectiveSource, report.ok ? "true" : "false",
      report.local_facts_scanned, informational, degraded, blockRecommended));

   if(!report.ok)
      LogWarn("C4.4 recovery-coverage scan: report.ok=false - first_error: " + report.first_error);
}

// The C4.4 startup wrapper - construct real objects, run exactly one
// RecoveryReconciliation_ScanLive() call, log a summary, return the
// report. Call once from OnInit(), immediately after
// TransactionMatching_StartupRebuild() (the point both
// OrderAggregateRegistry and ExecutionRequestProjection - the only two
// registries ScanLive reads - are guaranteed already rebuilt this
// session) and before EVENT_TYPE_SYSTEM_STARTED is logged.
RecoveryReconciliationReport RecoveryReconciliation_StartupScan(
   ENUM_C44_COVERAGE_SOURCE_MODE sourceMode,
   string   csvFileName,
   string   paramBrokerIdentity,
   string   paramAccountIdentity,
   string   paramServerTimeBasis,
   datetime paramCoverageFrom,
   datetime paramCoverageTo,
   datetime paramValidUntil,
   string   paramIssuerIdentity,
   string   paramEvidenceReference,
   string   paramIntegrityIdentifier)
{
   CLiveHistorySource liveSrc;
   RecoveryScanDiagnostics diag;
   RecoveryReconciliationReport report;
   string effectiveSource;

   if(sourceMode == C44_COVERAGE_SOURCE_CSV)
   {
      CsvStaticCoverageAttestationSource csvSrc(csvFileName);
      string loadError;
      if(csvSrc.Load(loadError))
      {
         effectiveSource = "CSV";
         report = RecoveryReconciliation_ScanLive(liveSrc, csvSrc, false, 0, diag);
      }
      else
      {
         LogWarn(StringFormat(
            "C4.4 recovery-coverage: mode=CSV could not load ('%s') - "
            "using no attestation for this session's scan (effective_source=NULL_FALLBACK)",
            loadError));
         NullCoverageAttestationSource nullSrc;
         effectiveSource = "NULL_FALLBACK";
         report = RecoveryReconciliation_ScanLive(liveSrc, nullSrc, false, 0, diag);
      }
   }
   else if(sourceMode == C44_COVERAGE_SOURCE_PARAMETER)
   {
      ParameterCoverageAttestationSource paramSrc;
      paramSrc.Configure(paramBrokerIdentity, paramAccountIdentity, paramServerTimeBasis,
                          paramCoverageFrom, paramCoverageTo, paramValidUntil,
                          paramIssuerIdentity, paramEvidenceReference, paramIntegrityIdentifier);
      // No presence pre-check here, deliberately - ParameterCoverageAttestationSource
      // ::TryGet() already owns that boundary. A declining source resolves to
      // RECOVERY_COVERAGE_EVIDENCE_ABSENT inside ScanLive, the same observable
      // outcome as NONE, without this file duplicating that validation.
      effectiveSource = "PARAMETER";
      report = RecoveryReconciliation_ScanLive(liveSrc, paramSrc, false, 0, diag);
   }
   else
   {
      NullCoverageAttestationSource nullSrc;
      effectiveSource = "NONE";
      report = RecoveryReconciliation_ScanLive(liveSrc, nullSrc, false, 0, diag);
   }

   RecoveryReconciliation_LogScanSummary(sourceMode, effectiveSource, report);
   return report;
}

#endif // __MLQUANTAI_RECOVERYRECONCILIATIONSTARTUP_MQH__
