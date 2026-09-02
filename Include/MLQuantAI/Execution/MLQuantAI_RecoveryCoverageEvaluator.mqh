//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_RecoveryCoverageEvaluator.mqh    |
//| C4.3 v1 implementation, per                                       |
//| Docs/PhaseC_C4_RecoveryHistoryPolicy.md §11.6/§11.8 (adopted).     |
//|                                                                    |
//| Case 25a structural-review gate (frozen this checkpoint, NOT a    |
//| compiled test - a reviewer-performed inspection before compile     |
//| authorization is granted for this file): this file must include    |
//| ONLY MLQuantAI_CoverageAttestation.mqh, and must contain no        |
//| reference to TimeCurrent, TimeLocal, GetTickCount, MathRand,       |
//| AccountInfo*, HistorySelect, HistoryOrder*, HistoryDeal*, File*,   |
//| WebRequest, Send*, Symbol*, OrderSend, or any other platform/time/ |
//| I-O/network/trade API. Both RecoveryCoverage_ClassifyEvidence and  |
//| RecoveryCoverage_Evaluate are pure: identical inputs must yield     |
//| identical outputs, and neither reads any global or static state.   |
//| evaluation_time is always caller-supplied, never read internally   |
//| (§11.6).                                                           |
//|                                                                    |
//| RecoveryCoverage_DetailToken is NOT one of §11.6's two frozen      |
//| function names - it is an additive helper introduced this          |
//| checkpoint to implement the report-detail-token freeze from the    |
//| post-merge implementation-authorization design review (Branch C    |
//| of RecoveryReconciliation_BuildReport's gated-row detail rule, see |
//| MLQuantAI_RecoveryReconciliation.mqh). It is pure for the same      |
//| reasons as the two §11.6 functions above and is covered by the     |
//| same Case 25a structural gate.                                     |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_RECOVERYCOVERAGEEVALUATOR_MQH__
#define __MLQUANTAI_RECOVERYCOVERAGEEVALUATOR_MQH__

#include "MLQuantAI_CoverageAttestation.mqh"

//---------------------------------------------------------------------
// §11.8 frozen decision table. Evaluated in the stated order - the
// first matching non-VALID status wins; no later condition may
// overwrite a classification already made by an earlier one.
//   1. attestation_present == false                         -> ABSENT
//   2. malformed interval or wrong integrity_identifier      -> INVALID
//   3. broker_identity empty/mismatched                      -> BROKER_MISMATCH
//   4. account_identity empty/mismatched                     -> ACCOUNT_MISMATCH
//   5. server_time_basis empty/mismatched                    -> TIME_BASIS_MISMATCH
//   6. valid_until==0 or evaluation_time > valid_until        -> STALE
//   7. otherwise                                               -> VALID
//---------------------------------------------------------------------
ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS RecoveryCoverage_ClassifyEvidence(
   bool     attestation_present,
   const RecoveryCoverageAttestation &attestation,
   string   scan_broker_identity,
   string   scan_account_identity,
   string   scan_server_time_basis,
   datetime evaluation_time
)
{
   if(!attestation_present)
      return RECOVERY_COVERAGE_EVIDENCE_ABSENT;

   // §11.4: exact-literal integrity-marker check, no case-fold/trim.
   if(attestation.coverage_from > attestation.coverage_to)
      return RECOVERY_COVERAGE_EVIDENCE_INVALID;
   if(attestation.integrity_identifier != MLQUANTAI_C4_3_COVERAGE_ATTESTATION_INTEGRITY_MARKER)
      return RECOVERY_COVERAGE_EVIDENCE_INVALID;

   // §11.4: byte-for-byte exact comparison, no case-folding/trimming/
   // alias/locale-conversion/default-value; an empty field on either
   // side fails at this tier (never a wildcard/"unspecified" match).
   if(attestation.broker_identity == "" || scan_broker_identity == "" ||
      attestation.broker_identity != scan_broker_identity)
      return RECOVERY_COVERAGE_EVIDENCE_BROKER_MISMATCH;

   if(attestation.account_identity == "" || scan_account_identity == "" ||
      attestation.account_identity != scan_account_identity)
      return RECOVERY_COVERAGE_EVIDENCE_ACCOUNT_MISMATCH;

   if(attestation.server_time_basis == "" || scan_server_time_basis == "" ||
      attestation.server_time_basis != scan_server_time_basis)
      return RECOVERY_COVERAGE_EVIDENCE_TIME_BASIS_MISMATCH;

   if(attestation.valid_until == 0 || evaluation_time > attestation.valid_until)
      return RECOVERY_COVERAGE_EVIDENCE_STALE;

   return RECOVERY_COVERAGE_EVIDENCE_VALID;
}

//---------------------------------------------------------------------
// §11.8 frozen decision order (verbatim):
//  1. Required bounds unavailable/invalid           -> INSUFFICIENT
//  2. evidence_status != VALID                       -> UNASSESSED
//  3. coverage_from > required_from OR
//     coverage_to   < required_to                    -> INSUFFICIENT
//     (checked BEFORE step 4, regardless of query success)
//  4. history_select_succeeded == false               -> UNASSESSED
//  5. otherwise                                        -> PROVEN
//---------------------------------------------------------------------
// evaluation_time is part of this function's frozen §11.6 signature
// (Docs/PhaseC_C4_RecoveryHistoryPolicy.md, adopted via PR #11) and is
// intentionally kept even though this v1 body never reads it directly
// - staleness (the one place evaluation_time matters) is already fully
// resolved by RecoveryCoverage_ClassifyEvidence above, whose
// evidence_status this function takes as an input rather than
// re-deriving. Removing this parameter would be a deviation from the
// merged, adopted contract text, not a pure code-quality cleanup - it
// is deliberately not removed here.
ENUM_RECOVERY_COVERAGE_VERDICT RecoveryCoverage_Evaluate(
   datetime required_from,
   datetime required_to,
   datetime evaluation_time,
   bool     history_select_succeeded,
   const RecoveryCoverageAttestation &attestation,
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS evidence_status
)
{
   if(required_from > required_to)
      return RECOVERY_COVERAGE_VERDICT_INSUFFICIENT;

   if(evidence_status != RECOVERY_COVERAGE_EVIDENCE_VALID)
      return RECOVERY_COVERAGE_VERDICT_UNASSESSED;

   if(attestation.coverage_from > required_from || attestation.coverage_to < required_to)
      return RECOVERY_COVERAGE_VERDICT_INSUFFICIENT;

   if(!history_select_succeeded)
      return RECOVERY_COVERAGE_VERDICT_UNASSESSED;

   return RECOVERY_COVERAGE_VERDICT_PROVEN;
}

//---------------------------------------------------------------------
// Report-detail-token freeze (this checkpoint's design review, Branch
// C of RecoveryReconciliation_BuildReport's gated-row detail rule
// only). Returns a fixed canonical token with no interpolation: no
// raw identity value, no timestamp, no source out_reason text, ever.
// Branches A/B/D never call this - they pass "" to
// RRAppendLocalGatedRow's default detail parameter instead; this
// function returning "" for the VALID+non-gap verdicts is purely
// defensive and is never surfaced into a report row in that case.
//---------------------------------------------------------------------
string RecoveryCoverage_DetailToken(
   ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS evidence_status,
   ENUM_RECOVERY_COVERAGE_VERDICT verdict
)
{
   if(evidence_status == RECOVERY_COVERAGE_EVIDENCE_VALID)
   {
      if(verdict == RECOVERY_COVERAGE_VERDICT_INSUFFICIENT)
         return "COVERAGE_GAP_ATTESTED";
      return "";
   }
   switch(evidence_status)
   {
      case RECOVERY_COVERAGE_EVIDENCE_ABSENT:             return "COVERAGE_EVIDENCE_ABSENT";
      case RECOVERY_COVERAGE_EVIDENCE_INVALID:             return "COVERAGE_EVIDENCE_INVALID";
      case RECOVERY_COVERAGE_EVIDENCE_STALE:               return "COVERAGE_EVIDENCE_STALE";
      case RECOVERY_COVERAGE_EVIDENCE_BROKER_MISMATCH:     return "COVERAGE_EVIDENCE_BROKER_MISMATCH";
      case RECOVERY_COVERAGE_EVIDENCE_ACCOUNT_MISMATCH:    return "COVERAGE_EVIDENCE_ACCOUNT_MISMATCH";
      case RECOVERY_COVERAGE_EVIDENCE_TIME_BASIS_MISMATCH: return "COVERAGE_EVIDENCE_TIME_BASIS_MISMATCH";
      default:                                               return "";
   }
}

#endif // __MLQUANTAI_RECOVERYCOVERAGEEVALUATOR_MQH__
