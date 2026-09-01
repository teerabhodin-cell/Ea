//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_CoverageAttestation.mqh          |
//| C4.3 v1 implementation, per                                       |
//| Docs/PhaseC_C4_RecoveryHistoryPolicy.md §11 (adopted).             |
//|                                                                    |
//| RecoveryCoverageAttestation is the locally-supplied, non-live     |
//| evidence record §11.3 defines. ICoverageAttestationSource (§11.5) |
//| is the only seam a coverage-evidence provider may implement - no  |
//| implementation of it may perform a network call, live broker      |
//| query, terminal-history query, or any external live fetch.        |
//|                                                                    |
//| ENUM_RECOVERY_COVERAGE_VERDICT is NOT part of §11's frozen text - |
//| it exists solely so MLQuantAI_RecoveryCoverageEvaluator.mqh never |
//| needs to #include anything beyond this file (the Case 25a         |
//| structural-review gate requires the evaluator include ONLY the    |
//| attestation definition header). MLQuantAI_RecoveryReconciliation  |
//| .mqh maps this private verdict onto its own, separately frozen,   |
//| ENUM_RECOVERY_WINDOW_ADEQUACY - the two enums are intentionally    |
//| kept distinct rather than sharing one definition across files.    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_COVERAGEATTESTATION_MQH__
#define __MLQUANTAI_COVERAGEATTESTATION_MQH__

// §11.4 frozen literal - schema-recognition marker only, explicitly
// NOT a cryptographic integrity guarantee.
#define MLQUANTAI_C4_3_COVERAGE_ATTESTATION_INTEGRITY_MARKER "RECOVERY_COVERAGE_ATTESTATION_C4_V1"

//---------------------------------------------------------------------
// §11.3 frozen schema.
//---------------------------------------------------------------------
struct RecoveryCoverageAttestation
{
   string   broker_identity;
   string   account_identity;
   string   server_time_basis;
   datetime coverage_from;
   datetime coverage_to;
   datetime valid_until;
   string   issuer_identity;
   string   evidence_reference;
   string   integrity_identifier;
};

void RecoveryCoverageAttestation_Init(RecoveryCoverageAttestation &a)
{
   a.broker_identity = "";
   a.account_identity = "";
   a.server_time_basis = "";
   a.coverage_from = 0;
   a.coverage_to = 0;
   a.valid_until = 0;
   a.issuer_identity = "";
   a.evidence_reference = "";
   a.integrity_identifier = "";
}

//---------------------------------------------------------------------
// §11.6/§11.8 frozen evidence-classification taxonomy. Evaluated by
// RecoveryCoverage_ClassifyEvidence (MLQuantAI_RecoveryCoverageEvaluator
// .mqh) in the exact §11.8 order - first matching non-VALID status
// wins, no later condition may overwrite an earlier classification.
//---------------------------------------------------------------------
enum ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS
{
   RECOVERY_COVERAGE_EVIDENCE_ABSENT = 0,
   RECOVERY_COVERAGE_EVIDENCE_VALID,
   RECOVERY_COVERAGE_EVIDENCE_INVALID,
   RECOVERY_COVERAGE_EVIDENCE_STALE,
   RECOVERY_COVERAGE_EVIDENCE_BROKER_MISMATCH,
   RECOVERY_COVERAGE_EVIDENCE_ACCOUNT_MISMATCH,
   RECOVERY_COVERAGE_EVIDENCE_TIME_BASIS_MISMATCH
};

//---------------------------------------------------------------------
// PRIVATE to the C4.3 evaluator seam - not §11's frozen public schema,
// not C4.2's frozen ENUM_RECOVERY_WINDOW_ADEQUACY. Exists only to keep
// MLQuantAI_RecoveryCoverageEvaluator.mqh's dependency surface to this
// one header (see this file's own header comment above). Values are a
// 1:1 semantic mirror of ENUM_RECOVERY_WINDOW_ADEQUACY - the mapping
// lives in MLQuantAI_RecoveryReconciliation.mqh, the only file
// authorized to see both enums.
//---------------------------------------------------------------------
enum ENUM_RECOVERY_COVERAGE_VERDICT
{
   RECOVERY_COVERAGE_VERDICT_UNASSESSED = 0,
   RECOVERY_COVERAGE_VERDICT_PROVEN,
   RECOVERY_COVERAGE_VERDICT_INSUFFICIENT
};

//---------------------------------------------------------------------
// §11.5 frozen boundary. No implementation of this interface may
// perform a network call, live broker query, terminal-history query,
// or any external live fetch in C4.3 v1 - implementations may read
// only operator/system-supplied static inputs (configured parameters
// or a locally supplied static file) and must not mutate state.
//
// broker_identity/account_identity are a lookup key for a possible
// future multi-attestation source (e.g. a keyed CSV row); TryGet() is
// not required to use them to filter its result -
// MLQuantAI_ParameterCoverageAttestationSource.mqh (C4.3 v1's only
// authorized source) always returns its single configured attestation
// or declines, regardless of the identity requested, since it has
// nothing to look up against. Identity comparison against these two
// arguments is entirely the evaluator's responsibility (§11.8), never
// the source's.
//---------------------------------------------------------------------
class ICoverageAttestationSource
{
public:
   virtual bool TryGet(
      string broker_identity,
      string account_identity,
      RecoveryCoverageAttestation &out_attestation,
      string &out_reason
   ) = 0;
};

//---------------------------------------------------------------------
// NullCoverageAttestationSource - the sole reason
// RecoveryReconciliation_ScanLive()'s existing four-argument C4.2
// signature can remain a behavior-preserving wrapper (see
// MLQuantAI_RecoveryReconciliation.mqh). TryGet() always declines;
// every C4.2-era call site therefore always evaluates to
// RECOVERY_COVERAGE_EVIDENCE_ABSENT, reproducing C4.2's unconditional
// UNASSESSED result exactly.
//---------------------------------------------------------------------
class NullCoverageAttestationSource : public ICoverageAttestationSource
{
public:
   virtual bool TryGet(
      string broker_identity,
      string account_identity,
      RecoveryCoverageAttestation &out_attestation,
      string &out_reason
   )
   {
      RecoveryCoverageAttestation_Init(out_attestation);
      out_reason = "no coverage attestation source supplied (legacy four-argument ScanLive overload)";
      return false;
   }
};

#endif // __MLQUANTAI_COVERAGEATTESTATION_MQH__
