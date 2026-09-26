//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BoundedAutomationIssuance.mqh     |
//| C5.2 §6.3 Bounded-Automation Design Contract Rev.14 (QA-frozen     |
//| FINAL DESIGN FREEZE, commit 6b7e836). Implementation Wave 1:        |
//| command / mailbox / state machinery for the Decision Engine.         |
//|                                                                    |
//|   §2.3.2 step 1 precondition - one validated EventStore snapshot     |
//|           (zero lines or ValidateLines().ok == false -> issue        |
//|           nothing), BoundedAutomation_ReadValidatedSnapshot()         |
//|   §2.3.2 step 1 - raw E2 scan of that snapshot,                       |
//|           BoundedAutomation_HasSubmissionAttempt()                    |
//|   §2.3.2 step 2 - ONE mailbox read, three-way branch,                 |
//|           BoundedAutomation_ReadMailboxSnapshot()                     |
//|   §2.3.2 steps 1-4 - pure derivation,                                 |
//|           BoundedAutomation_DeriveCandidateState()                    |
//|   §2.3.2a - occupancy check -> write -> read-your-own-write,          |
//|           BoundedAutomation_IssueCommand()                            |
//|   §2.3.2b - WRITE_FAILED / LOST / ISSUED_CONFIRMED, no in-memory      |
//|           ledger of any kind                                          |
//|                                                                    |
//| Scope fence (Wave 1): nothing here is called from MLQuantAI.mq5 yet  |
//| (runtime wiring is Wave 5). No OrderSend/CTrade, no C2 gate call,     |
//| no EventStore append, no candidate.state mutation, no GlobalVariable |
//| write anywhere in this file. The only file this module ever WRITES   |
//| is the ceremony mailbox, and only through the sealed, unmodified      |
//| CeremonyCommandMailbox_Write() - the same transport a human ceremony  |
//| script already uses (§2.1: no new dispatch path).                     |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BOUNDEDAUTOMATIONISSUANCE_MQH__
#define __MLQUANTAI_BOUNDEDAUTOMATIONISSUANCE_MQH__

#include "MLQuantAI_BoundedAutomationContract.mqh"
#include "MLQuantAI_BoundedAutomationProvenance.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_CeremonyCommandEventEmission.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventStoreValidator.mqh"
#include "MLQuantAI_ManualApprovalReadiness.mqh"
#include "../Core/MLQuantAI_Ids.mqh"

//---------------------------------------------------------------------
// §2.3.2 step 1 precondition (Rev.11 text, same discipline as Check A,
// Rev.7): read the EventStore ONCE, then validate that SAME array.
// EventStore_ReadAllLines() returns 0 both for an unopenable file and a
// genuinely empty one (MLQuantAI_EventStore.mqh:257-258), and
// EventStoreValidator_ValidateLines() is vacuously ok on an empty array -
// so zero lines is rejected explicitly, BEFORE validation. Returns false
// (issue nothing this invocation) on either condition; outLines[] is only
// meaningful when this returns true.
//---------------------------------------------------------------------
bool BoundedAutomation_ReadValidatedSnapshot(string fileName, string &outLines[], string &outError)
{
   outError = "";
   EventStore_ReadAllLines(fileName, outLines);
   if(ArraySize(outLines) == 0)
   {
      outError = "event store read returned zero lines - unopenable or empty, never trusted";
      return false;
   }
   EventStoreValidationReport validation = EventStoreValidator_ValidateLines(outLines);
   if(!validation.ok)
   {
      outError = "event store validation failed: " + validation.first_error;
      return false;
   }
   return true;
}

//---------------------------------------------------------------------
// §2.3.2 step 1 / §2.3.2a "E1/E2": SUBMISSION_ISSUED iff >= 1 E2 line
// (EXECUTION_SUBMISSION_ATTEMPTED, sole producer the sealed
// BrokerSubmission_RecordAttempt()) exists for this exact
// execution_request_id. A raw scan of the caller's validated snapshot -
// NEVER SubmissionAttemptRegistry_HasAttempt(), whose registry is
// rebuild-only and can lag in-session. E1 lines
// (CEREMONY_COMMAND_STATE_CHANGED) also carry execution_request_id and
// must NOT match: the type test comes first.
//---------------------------------------------------------------------
bool BoundedAutomation_HasSubmissionAttempt(const string &lines[], string executionRequestId)
{
   if(executionRequestId == "")
      return false;
   string attemptType = EventTypeToString(EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED);
   int n = ArraySize(lines);
   for(int i = 0; i < n; i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != attemptType)
         continue;
      if(EventSerializer_GetStr(lines[i], "execution_request_id") == executionRequestId)
         return true;
   }
   return false;
}

//---------------------------------------------------------------------
// §2.3.2 step 2: the mailbox is read fresh ONCE per invocation and every
// candidate's derivation branches over that SAME read. "present" is the
// sealed CeremonyCommandMailbox_Read() return value (false = no file yet
// or unreadable right now - both "treat as no command").
//---------------------------------------------------------------------
struct BoundedAutomationMailboxSnapshot
{
   bool            present;
   CeremonyCommand command;
};

void BoundedAutomation_ReadMailboxSnapshot(BoundedAutomationMailboxSnapshot &out)
{
   out.present = CeremonyCommandMailbox_Read(out.command);
}

// Occupied = the exact negation of the sealed
// CeremonyCommandMailbox_IsFreeForNewCommand() (absent -> free; present ->
// free iff terminal). An unrecognised status (UNKNOWN, e.g. a garbled
// file) is not terminal, so it counts as occupied - same as the sealed
// guard, never looser.
bool BoundedAutomation_MailboxIsOccupied(const BoundedAutomationMailboxSnapshot &mailbox)
{
   if(!mailbox.present)
      return false;
   return !CeremonyMailboxStatus_IsTerminal(mailbox.command.mailbox_status);
}

//---------------------------------------------------------------------
// §2.3.2 steps 1-4, pure (no I/O, no globals). Order is frozen:
//   1  E2 exists                                   -> SUBMISSION_ISSUED
//   1b AUTOMATION E1 exists, no E2 (Rev.15, D5)    -> AUTOMATION_EXHAUSTED
//   2  mailbox occupied, ONE three-way branch over the same snapshot:
//      2a own SUBMIT_ORDER (same execution_request_id) -> SUBMISSION_ISSUED
//      2b own GRANT_MANUAL_APPROVAL (same id)          -> APPROVAL_QUEUED
//      2c anything else                                -> MAILBOX_BUSY
//      2d mailbox free                                 -> step 3
//   3  valid unexpired grant                       -> APPROVED_NOT_SUBMITTED
//   4  otherwise                                   -> NOT_YET_APPROVED
// hasValidApproval is consulted ONLY on the 2d path, so a caller-supplied
// true can never override an occupied mailbox.
//---------------------------------------------------------------------
ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE BoundedAutomation_DeriveCandidateState(bool submissionAttemptExists,
                                                                               bool automationExhausted,
                                                                               const BoundedAutomationMailboxSnapshot &mailbox,
                                                                               string executionRequestId,
                                                                               bool hasValidApproval)
{
   if(executionRequestId == "")
      return BOUNDED_AUTOMATION_STATE_UNKNOWN;

   if(submissionAttemptExists)
      return BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED;

   if(automationExhausted)
      return BOUNDED_AUTOMATION_STATE_AUTOMATION_EXHAUSTED;

   if(BoundedAutomation_MailboxIsOccupied(mailbox))
   {
      bool sameTarget = (mailbox.command.target_execution_request_id == executionRequestId);
      if(sameTarget && mailbox.command.command_type == CEREMONY_COMMAND_TYPE_SUBMIT_ORDER)
         return BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED;
      if(sameTarget && mailbox.command.command_type == CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL)
         return BOUNDED_AUTOMATION_STATE_APPROVAL_QUEUED;
      return BOUNDED_AUTOMATION_STATE_MAILBOX_BUSY;
   }

   if(hasValidApproval)
      return BOUNDED_AUTOMATION_STATE_APPROVED_NOT_SUBMITTED;
   return BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED;
}

// Wave 1 signature, kept so the closed Wave 1 suite runs unchanged: the
// same derivation for a request with no AUTOMATION E1.
ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE BoundedAutomation_DeriveCandidateState(bool submissionAttemptExists,
                                                                               const BoundedAutomationMailboxSnapshot &mailbox,
                                                                               string executionRequestId,
                                                                               bool hasValidApproval)
{
   return BoundedAutomation_DeriveCandidateState(submissionAttemptExists, false, mailbox, executionRequestId, hasValidApproval);
}

//---------------------------------------------------------------------
// §2.3.2 for one ExecutionRequest, over a validated snapshot and a single
// mailbox read the caller already holds. The approval registry is read
// only on the 2d path (after E2 and occupancy are ruled out), with a
// fresh asOf, through the sealed ManualApprovalRegistry_HasValidApproval()
// on all five identity fields - the same call the C2 gate makes
// (MLQuantAI_EnvironmentLockGate.mqh:189).
//
// Fail-closed (Wave 1 implementation decision, disclosed at checkpoint):
// asOf <= 0, or the manual-approval registry not ready this session
// (ManualApprovalReadiness_IsReady() == false - its answer would be over
// an unrebuilt/failed registry), yields UNKNOWN, which issues nothing.
// Both conditions already make the C2 gate reject
// (MLQuantAI_EnvironmentLockGate.mqh:169-187); this only stops the
// Decision Engine issuing a GRANT on a basis it cannot trust.
//---------------------------------------------------------------------
ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE BoundedAutomation_EvaluateCandidateState(const string &validatedLines[],
                                                                                 const BoundedAutomationMailboxSnapshot &mailbox,
                                                                                 const ExecutionRequestProjectionRecord &request,
                                                                                 datetime asOf)
{
   if(request.execution_request_id == "")
      return BOUNDED_AUTOMATION_STATE_UNKNOWN;

   bool submissionAttemptExists = BoundedAutomation_HasSubmissionAttempt(validatedLines, request.execution_request_id);

   // Rev.15 step 1b (D5), through the PROV-1 reader. An INVALID E1 for this
   // request fails closed (UNKNOWN) - never read as "not exhausted" (R15).
   bool automationExhausted = false;
   if(!submissionAttemptExists)
   {
      ENUM_BOUNDED_AUTOMATION_REQUEST_E1_STATUS e1Status = BoundedAutomation_RequestE1Status(validatedLines, request.execution_request_id);
      if(e1Status == BOUNDED_AUTOMATION_REQUEST_E1_INVALID)
         return BOUNDED_AUTOMATION_STATE_UNKNOWN;
      automationExhausted = (e1Status == BOUNDED_AUTOMATION_REQUEST_E1_EXHAUSTED);
   }

   bool hasValidApproval = false;
   if(!submissionAttemptExists && !automationExhausted && !BoundedAutomation_MailboxIsOccupied(mailbox))
   {
      if(asOf <= 0 || !ManualApprovalReadiness_IsReady())
         return BOUNDED_AUTOMATION_STATE_UNKNOWN;
      hasValidApproval = ManualApprovalRegistry_HasValidApproval(request.execution_request_id, request.execution_request_hash,
                                                                 request.execution_policy_version, request.candidate_id,
                                                                 request.correlation_id, asOf);
   }

   return BoundedAutomation_DeriveCandidateState(submissionAttemptExists, automationExhausted, mailbox,
                                                 request.execution_request_id, hasValidApproval);
}

// §2.3.2 frozen transition rule: which command (if any) a state issues.
// Returns false for every "do nothing this invocation" state.
bool BoundedAutomation_StateIssuesCommand(ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE state, ENUM_CEREMONY_COMMAND_TYPE &outCommandType)
{
   outCommandType = CEREMONY_COMMAND_TYPE_UNKNOWN;
   if(state == BOUNDED_AUTOMATION_STATE_APPROVED_NOT_SUBMITTED)
   {
      outCommandType = CEREMONY_COMMAND_TYPE_SUBMIT_ORDER;
      return true;
   }
   if(state == BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED)
   {
      outCommandType = CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL;
      return true;
   }
   return false;
}

//---------------------------------------------------------------------
// Fresh command_id (§2.3.2a "<fresh unique id>", §7 item 5: generation
// helper is implementation detail). Same recipe and "CMD_" + 16-hex
// shape as the human issuer script's NewCommandId()
// (Tests/MLQuantAI_ManualScript_GrantApproval.mq5); in-process
// uniqueness comes from the counter, exactly as Ids_NewRuntimeSessionId()
// documents for its own counter.
//---------------------------------------------------------------------
int g_BoundedAutomation_CommandCounter = 0;

string BoundedAutomation_NewCommandId()
{
   g_BoundedAutomation_CommandCounter++;
   string key = IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN)) + "|" +
                TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "|" +
                IntegerToString((int)GetMicrosecondCount()) + "|" +
                IntegerToString(g_BoundedAutomation_CommandCounter) + "|" +
                IntegerToString(MathRand());
   string hex = Ids_Sha256Hex(key);
   if(hex == "")
      return "";
   return "CMD_" + StringSubstr(hex, 0, 16);
}

//---------------------------------------------------------------------
// Builds the ONLY two command types the Decision Engine may issue
// (§2.1), each carrying the reserved approver_identity (§2.3.2 frozen
// transition rule: set on BOTH GRANT and SUBMIT). Nonce and EventStore
// filename are the EA's own live values, so CeremonyCommand_TryClaim()
// accepts the command exactly as it accepts a human script's.
// command_sequence stays 0.0: nothing in the EA reads it (it only
// mirrors the script-side GlobalVariable counter, which this module
// never touches). Returns false - and nothing may be issued - on any
// missing input, a non-issuable type, or a command_id collision with a
// command already known to the durable registry (TryClaim would refuse
// it and leave the mailbox PENDING forever).
//---------------------------------------------------------------------
bool BoundedAutomation_BuildCommand(ENUM_CEREMONY_COMMAND_TYPE commandType, string executionRequestId,
                                    double eaBindingNonce, string eventStoreFileName, CeremonyCommand &out)
{
   CeremonyCommand_Init(out);

   if(commandType != CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL && commandType != CEREMONY_COMMAND_TYPE_SUBMIT_ORDER)
      return false;
   if(executionRequestId == "" || eaBindingNonce <= 0.0 || eventStoreFileName == "")
      return false;

   string commandId = BoundedAutomation_NewCommandId();
   if(commandId == "" || CeremonyCommandRegistry_IsKnown(commandId))
      return false;

   out.command_id                   = commandId;
   out.command_type                 = commandType;
   out.command_sequence             = 0.0;
   out.expected_ea_binding_nonce    = eaBindingNonce;
   out.expected_eventstore_filename = eventStoreFileName;
   out.target_execution_request_id  = executionRequestId;
   out.approver_identity            = MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY;
   if(commandType == CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL)
      out.approval_validity_minutes = MLQUANTAI_BOUNDED_AUTOMATION_GRANT_VALIDITY_MINUTES;
   out.mailbox_status               = CEREMONY_MAILBOX_STATUS_PENDING;
   return true;
}

//---------------------------------------------------------------------
// §2.3.2a read-your-own-write classification, pure. The sealed
// CeremonyCommandMailbox_Write() has no compare-and-swap, so the only
// confirmation is: the mailbox read back right after the write succeeds
// AND carries this invocation's own command_id. Anything else is LOST
// (§2.3.2b: "overwritten" and "confirmation read failed" are one
// accounting case, deliberately not split).
//---------------------------------------------------------------------
ENUM_BOUNDED_AUTOMATION_ISSUANCE_OUTCOME BoundedAutomation_ClassifyConfirmation(bool confirmReadOk,
                                                                               const CeremonyCommand &confirm,
                                                                               string issuedCommandId)
{
   if(!confirmReadOk || issuedCommandId == "" || confirm.command_id != issuedCommandId)
      return BOUNDED_AUTOMATION_ISSUANCE_LOST;
   return BOUNDED_AUTOMATION_ISSUANCE_ISSUED_CONFIRMED;
}

// A command this module is allowed to put in the mailbox: built by
// BoundedAutomation_BuildCommand() (or identical in every checked field).
bool BoundedAutomation_IsIssuableCommand(const CeremonyCommand &cmd)
{
   if(cmd.command_id == "" || cmd.target_execution_request_id == "")
      return false;
   if(cmd.command_type != CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL && cmd.command_type != CEREMONY_COMMAND_TYPE_SUBMIT_ORDER)
      return false;
   if(cmd.approver_identity != MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY)
      return false;
   if(cmd.mailbox_status != CEREMONY_MAILBOX_STATUS_PENDING)
      return false;
   return true;
}

//---------------------------------------------------------------------
// §2.3.2a issuance write protocol, verbatim order:
//   IsFreeForNewCommand() (sealed RA-31.2 condition A guard) -> Write()
//   -> Read() back -> command_id match.
// No retry inside the call (§2.3.2a (C) FROZEN LIVENESS RULE): WRITE_FAILED
// and LOST both end this invocation; the next invocation re-derives state
// from scratch. Nothing is recorded anywhere by this function - §2.3.2b
// forbids any in-memory issuance ledger; caps count durable E1 only.
//---------------------------------------------------------------------
ENUM_BOUNDED_AUTOMATION_ISSUANCE_OUTCOME BoundedAutomation_IssueCommand(const CeremonyCommand &cmd)
{
   if(!BoundedAutomation_IsIssuableCommand(cmd))
      return BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_INVALID_COMMAND;

   if(!CeremonyCommandMailbox_IsFreeForNewCommand())
      return BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_MAILBOX_BUSY;

   if(!CeremonyCommandMailbox_Write(cmd))
      return BOUNDED_AUTOMATION_ISSUANCE_WRITE_FAILED;

   CeremonyCommand confirm;
   bool confirmReadOk = CeremonyCommandMailbox_Read(confirm);
   return BoundedAutomation_ClassifyConfirmation(confirmReadOk, confirm, cmd.command_id);
}

#endif // __MLQUANTAI_BOUNDEDAUTOMATIONISSUANCE_MQH__
