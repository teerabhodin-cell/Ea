//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BoundedAutomationContract.mqh     |
//| C5.2 §6.3 Bounded-Automation Design Contract Rev.14 (QA-frozen     |
//| FINAL DESIGN FREEZE, R1-R17 ratified, commit 6b7e836,               |
//| Docs/PhaseC_C5_2_Section6_3_BoundedAutomationDesignContract.md).    |
//| Implementation Wave 1 (command / mailbox / state machinery):         |
//| shared constants and closed enums only - no logic, no I/O.          |
//|                                                                    |
//| Nothing in this file grants execution authority. It defines names   |
//| the Decision Engine and (in later waves) the two ratified Class 2    |
//| amendments (R13 GrantManualApprovalCommand, R14 SubmitOrderCommand)  |
//| share, so the reserved identity string is written in exactly one     |
//| place.                                                               |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BOUNDEDAUTOMATIONCONTRACT_MQH__
#define __MLQUANTAI_BOUNDEDAUTOMATIONCONTRACT_MQH__

// §2.1/§2.4: the reserved approver_identity every Decision-Engine-issued
// ceremony command (GRANT_MANUAL_APPROVAL and SUBMIT_ORDER) carries.
// The value is fixed by INVARIANT PROV-1 (§3.2): the E1 writer emits
// this exact constant as the "submission_provenance" AUTOMATION token,
// and the PROV-1 reader classifies AUTOMATION iff the token equals
// "SYSTEM_BOUNDED_AUTOMATION_V1". Changing this value changes PROV-1 and
// is therefore a contract change, never an in-place edit.
#define MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY "SYSTEM_BOUNDED_AUTOMATION_V1"

// approval_validity_minutes for a Decision-Engine-issued
// GRANT_MANUAL_APPROVAL command. Rev.14 does not specify this value (it
// is not one of R1-R17). 15 is the value the sealed
// GrantManualApprovalCommand() already falls back to when the field is 0
// (MLQuantAI.mq5:1044) and the human issuer script's default
// (Tests/MLQuantAI_ManualScript_GrantApproval.mq5, I_ValidityWindowMinutes)
// - no new policy value is introduced here. Disclosed at the Wave 1
// checkpoint for QA's explicit decision.
#define MLQUANTAI_BOUNDED_AUTOMATION_GRANT_VALIDITY_MINUTES 15

// Rev.15 §2.3.1 (e) M1 / D4-b: the execution_policy_version literal the
// sealed RUN_C22_CEREMONY_FIXTURE handler hard-codes (MLQuantAI.mq5:991).
// A request carrying it is a ceremony fixture (M1). R15-A only READS this
// value for M1; the D4-b OnInit guard that forbids the C5 pipeline from
// using it is a separate slice (R15-D) and is not implemented here.
#define MLQUANTAI_RESERVED_FIXTURE_EXECUTION_POLICY_VERSION "EXECPOLICY_C2_SMOKE_V1"

//---------------------------------------------------------------------
// §2.3.2 per-execution_request_id state, derived fresh every invocation.
// UNKNOWN is the fail-closed value for an input the derivation cannot
// trust (empty execution_request_id, untrusted asOf, manual-approval
// registry not ready) - it issues nothing, same as the three "do
// nothing" states the contract names.
//---------------------------------------------------------------------
enum ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE
{
   BOUNDED_AUTOMATION_STATE_UNKNOWN,
   BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED,       // step 1 (durable E2) or step 2a (own SUBMIT occupies mailbox)
   BOUNDED_AUTOMATION_STATE_APPROVAL_QUEUED,         // step 2b (own GRANT occupies mailbox)
   BOUNDED_AUTOMATION_STATE_MAILBOX_BUSY,            // step 2c (anything else occupies mailbox)
   BOUNDED_AUTOMATION_STATE_APPROVED_NOT_SUBMITTED,  // step 3 (mailbox free, valid grant) -> issue SUBMIT_ORDER
   BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED,        // step 4 (mailbox free, no valid grant) -> issue GRANT_MANUAL_APPROVAL
   BOUNDED_AUTOMATION_STATE_AUTOMATION_EXHAUSTED     // Rev.15 step 1b (D5): AUTOMATION E1, no E2 -> automation skips permanently
};

string BoundedAutomationCandidateState_ToString(ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE s)
{
   switch(s)
   {
      case BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED:      return "SUBMISSION_ISSUED";
      case BOUNDED_AUTOMATION_STATE_APPROVAL_QUEUED:        return "APPROVAL_QUEUED";
      case BOUNDED_AUTOMATION_STATE_MAILBOX_BUSY:           return "MAILBOX_BUSY";
      case BOUNDED_AUTOMATION_STATE_APPROVED_NOT_SUBMITTED: return "APPROVED_NOT_SUBMITTED";
      case BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED:       return "NOT_YET_APPROVED";
      case BOUNDED_AUTOMATION_STATE_AUTOMATION_EXHAUSTED:   return "AUTOMATION_EXHAUSTED";
   }
   return "UNKNOWN";
}

//---------------------------------------------------------------------
// §2.3.2a/§2.3.2b issuance outcome. WRITE_FAILED / LOST /
// ISSUED_CONFIRMED are the contract's frozen taxonomy (RETRY-ELIGIBLE is
// deliberately NOT a value - §2.3.2b: it is the natural consequence of
// WRITE_FAILED or LOST, not a tracked status). The two NOT_ATTEMPTED_*
// values mean the mailbox file was never written at all.
//---------------------------------------------------------------------
enum ENUM_BOUNDED_AUTOMATION_ISSUANCE_OUTCOME
{
   BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_INVALID_COMMAND,
   BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_MAILBOX_BUSY,
   BOUNDED_AUTOMATION_ISSUANCE_WRITE_FAILED,
   BOUNDED_AUTOMATION_ISSUANCE_LOST,
   BOUNDED_AUTOMATION_ISSUANCE_ISSUED_CONFIRMED
};

string BoundedAutomationIssuanceOutcome_ToString(ENUM_BOUNDED_AUTOMATION_ISSUANCE_OUTCOME o)
{
   switch(o)
   {
      case BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_INVALID_COMMAND: return "NOT_ATTEMPTED_INVALID_COMMAND";
      case BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_MAILBOX_BUSY:    return "NOT_ATTEMPTED_MAILBOX_BUSY";
      case BOUNDED_AUTOMATION_ISSUANCE_WRITE_FAILED:                  return "WRITE_FAILED";
      case BOUNDED_AUTOMATION_ISSUANCE_LOST:                          return "LOST";
      case BOUNDED_AUTOMATION_ISSUANCE_ISSUED_CONFIRMED:              return "ISSUED_CONFIRMED";
   }
   return "UNKNOWN";
}

#endif // __MLQUANTAI_BOUNDEDAUTOMATIONCONTRACT_MQH__
