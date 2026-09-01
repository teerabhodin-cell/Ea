//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_ParameterCoverageAttestationSource|
//| .mqh                                                              |
//| C4.3 v1 implementation, per                                       |
//| Docs/PhaseC_C4_RecoveryHistoryPolicy.md §11.5 (adopted).           |
//|                                                                    |
//| ParameterCoverageAttestationSource is C4.3 v1's only authorized    |
//| ICoverageAttestationSource implementation. It performs zero file   |
//| I/O and zero network/live calls - it wraps nine caller-supplied    |
//| values (typically EA input parameters, read by the caller and     |
//| handed to Configure(); MQL5 `input` variables cannot be declared   |
//| inside an .mqh file) and returns them, or declines, on TryGet().   |
//| CsvStaticCoverageAttestationSource is out of scope for this        |
//| checkpoint (deferred to a separate C4.3.1 proposal) - this file    |
//| adds no FileOpen/FILE_COMMON/FILE_TXT/FILE_CSV dependency of any   |
//| kind.                                                              |
//|                                                                    |
//| Validation boundary (frozen this checkpoint): this source          |
//| validates ONLY that broker_identity/account_identity/              |
//| server_time_basis are non-empty - an empty required field means    |
//| TryGet() returns false (classifies as ABSENT downstream, never a   |
//| *_MISMATCH). integrity_identifier correctness, staleness, identity |
//| equality against scan context, and coverage-window containment are|
//| all evaluator-owned (MLQuantAI_RecoveryCoverageEvaluator.mqh) -    |
//| this source never inspects those fields' content, only its three   |
//| siblings' presence.                                                |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_PARAMETERCOVERAGEATTESTATIONSOURCE_MQH__
#define __MLQUANTAI_PARAMETERCOVERAGEATTESTATIONSOURCE_MQH__

#include "MLQuantAI_CoverageAttestation.mqh"

class ParameterCoverageAttestationSource : public ICoverageAttestationSource
{
private:
   string   m_brokerIdentity;
   string   m_accountIdentity;
   string   m_serverTimeBasis;
   datetime m_coverageFrom;
   datetime m_coverageTo;
   datetime m_validUntil;
   string   m_issuerIdentity;
   string   m_evidenceReference;
   string   m_integrityIdentifier;

public:
   void Configure(
      string   brokerIdentity,
      string   accountIdentity,
      string   serverTimeBasis,
      datetime coverageFrom,
      datetime coverageTo,
      datetime validUntil,
      string   issuerIdentity,
      string   evidenceReference,
      string   integrityIdentifier
   )
   {
      m_brokerIdentity = brokerIdentity;
      m_accountIdentity = accountIdentity;
      m_serverTimeBasis = serverTimeBasis;
      m_coverageFrom = coverageFrom;
      m_coverageTo = coverageTo;
      m_validUntil = validUntil;
      m_issuerIdentity = issuerIdentity;
      m_evidenceReference = evidenceReference;
      m_integrityIdentifier = integrityIdentifier;
   }

   virtual bool TryGet(
      string broker_identity,
      string account_identity,
      RecoveryCoverageAttestation &out_attestation,
      string &out_reason
   )
   {
      RecoveryCoverageAttestation_Init(out_attestation);

      // Source-owned validation: presence only (frozen this checkpoint -
      // see this file's header comment). Never inspects
      // integrity_identifier, coverage bounds, valid_until, or equality
      // against broker_identity/account_identity - all evaluator-owned.
      if(m_brokerIdentity == "")
      {
         out_reason = "broker_identity is empty";
         return false;
      }
      if(m_accountIdentity == "")
      {
         out_reason = "account_identity is empty";
         return false;
      }
      if(m_serverTimeBasis == "")
      {
         out_reason = "server_time_basis is empty";
         return false;
      }

      out_attestation.broker_identity = m_brokerIdentity;
      out_attestation.account_identity = m_accountIdentity;
      out_attestation.server_time_basis = m_serverTimeBasis;
      out_attestation.coverage_from = m_coverageFrom;
      out_attestation.coverage_to = m_coverageTo;
      out_attestation.valid_until = m_validUntil;
      out_attestation.issuer_identity = m_issuerIdentity;
      out_attestation.evidence_reference = m_evidenceReference;
      out_attestation.integrity_identifier = m_integrityIdentifier;
      out_reason = "";
      return true;
   }
};

#endif // __MLQUANTAI_PARAMETERCOVERAGEATTESTATIONSOURCE_MQH__
