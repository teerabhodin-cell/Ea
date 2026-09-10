//+------------------------------------------------------------------+
//| MLQuantAI_ManualScript_GrantApproval.mq5                          |
//| RA-31 (QA-frozen Single-Writer Command/Response Protocol) rewrite: |
//| this script no longer opens the canonical EventStore or appends    |
//| EXECUTION_MANUAL_APPROVAL_GRANTED itself - RA-30.1 proved            |
//| deterministically (150/150 FileOpen failures, err=5004) that it     |
//| never could safely do so while the EA holds the same file open.     |
//|                                                                    |
//| This script is now a thin COMMAND ISSUER only: it writes one        |
//| GRANT_MANUAL_APPROVAL command to the mailbox                        |
//| (MLQuantAI_CeremonyCommandMailbox.mqh), signals the EA, and polls   |
//| the mailbox for a terminal result. The EA (MLQuantAI.mq5,           |
//| GrantManualApprovalCommand) looks execution_request_hash/           |
//| execution_policy_version/candidate_id/correlation_id up itself from |
//| its own durable ExecutionRequestProjection, given only              |
//| target_execution_request_id - removing the entire class of          |
//| operator field-swap mistake QA caught repeatedly in earlier rounds  |
//| (RA-19/RA-21) when those four fields had to be hand-retyped here.   |
//|                                                                    |
//| *** Still never calls OrderSend/CTrade directly, and still only     |
//| *** ever leads to one durable approval-fact event - this rewrite    |
//| *** changes WHO writes it (the EA, not this script), not WHAT it    |
//| *** does. A separate, QA-authorized SUBMIT_ORDER command is what    |
//| *** actually attempts a real submission, never this script.        |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_CeremonyCommandMailbox.mqh>
#include <MLQuantAI/Core/MLQuantAI_Ids.mqh>

input double I_ExpectedEABindingNonce   = 0.0; // RA-29.1 (re-scoped by RA-31.2 condition F): copy the EXACT nonce MLQuantAI.mq5 just printed at its own OnInit ("RA-29.1 binding published: ... nonce=..."). 0.0 = ABORT.
input string I_TargetExecutionRequestId = ""; // REQUIRED - execution_request_id of the candidate being approved (from the RUN_C22_CEREMONY_FIXTURE command's own result/DIAGNOSTIC print)
input string I_ApproverIdentity         = ""; // REQUIRED - who is granting this approval (name/handle) - never blank
input int    I_ValidityWindowMinutes    = 15;  // approval_expiry = approval_timestamp + this many minutes; must be > 0
input int    I_PollTimeoutSeconds       = 30;

string CanonicalCeremonyFile() { return "MLQuantAI_SmokeTest_C2_2.jsonl"; }

int g_LocalCommandCounter = 0;
string NewCommandId()
{
   g_LocalCommandCounter++;
   string key = IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN)) + "|" +
                TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "|" +
                IntegerToString((int)GetMicrosecondCount()) + "|" +
                IntegerToString(g_LocalCommandCounter) + "|" +
                IntegerToString(MathRand());
   return "CMD_" + StringSubstr(Ids_Sha256Hex(key), 0, 16);
}

bool ValidateInputs()
{
   if(I_ExpectedEABindingNonce <= 0.0)   { Print("ABORTED: I_ExpectedEABindingNonce not provided (<=0.0)."); return false; }
   if(I_TargetExecutionRequestId == "")  { Print("ABORTED: I_TargetExecutionRequestId is blank."); return false; }
   if(I_ApproverIdentity == "")          { Print("ABORTED: I_ApproverIdentity is blank - an anonymous approval is not a real approval."); return false; }
   if(I_ValidityWindowMinutes <= 0)      { Print("ABORTED: I_ValidityWindowMinutes must be > 0."); return false; }
   return true;
}

void OnStart()
{
   Print("=== MLQuantAI C2 manual-approval grant command issuer (RA-31) ===");
   Print("*** This script never calls OrderSend/CTrade, and never opens the EventStore itself. ***");

   if(!ValidateInputs())
      return;

   if(!CeremonyCommandMailbox_IsFreeForNewCommand())
   {
      Print("ABORTED: a previous ceremony command is still in flight (mailbox not terminal) - "
            "wait for it to finish before issuing a new one.");
      return;
   }

   string file = CanonicalCeremonyFile();
   string counterName = "MLQuantAI_CommandCounter__" + file;
   string pendingName  = "MLQuantAI_CommandPending__" + file;

   double counter = GlobalVariableCheck(counterName) ? GlobalVariableGet(counterName) : 0.0;
   double seq = counter + 1.0;
   if(GlobalVariableSet(counterName, seq) == 0)
   {
      Print("ABORTED: could not publish command_sequence (GlobalVariableSet failed).");
      return;
   }

   CeremonyCommand cmd;
   CeremonyCommand_Init(cmd);
   cmd.command_id                  = NewCommandId();
   cmd.command_type                = CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL;
   cmd.command_sequence             = seq;
   cmd.expected_ea_binding_nonce    = I_ExpectedEABindingNonce;
   cmd.expected_eventstore_filename = file;
   cmd.target_execution_request_id  = I_TargetExecutionRequestId;
   cmd.approver_identity            = I_ApproverIdentity;
   cmd.approval_validity_minutes    = I_ValidityWindowMinutes;
   cmd.mailbox_status               = CEREMONY_MAILBOX_STATUS_PENDING;

   if(!CeremonyCommandMailbox_Write(cmd))
   {
      Print("ABORTED: could not write the command mailbox file.");
      return;
   }
   if(GlobalVariableSet(pendingName, seq) == 0)
   {
      Print("ABORTED: could not signal the EA (GlobalVariableSet on '", pendingName, "' failed).");
      return;
   }

   Print("Command issued: command_id=", cmd.command_id, " type=GRANT_MANUAL_APPROVAL target_execution_request_id=",
         I_TargetExecutionRequestId, " approver=", I_ApproverIdentity, " command_sequence=", DoubleToString(seq, 0));
   Print("Waiting up to ", I_PollTimeoutSeconds, "s for the EA to claim and finish this command...");

   ulong startTick = GetTickCount64();
   CeremonyCommand result;
   bool sawClaimed = false;
   while((long)(GetTickCount64() - startTick) < (long)I_PollTimeoutSeconds * 1000)
   {
      if(CeremonyCommandMailbox_Read(result) && result.command_id == cmd.command_id)
      {
         if(!sawClaimed && result.mailbox_status != CEREMONY_MAILBOX_STATUS_PENDING)
         {
            sawClaimed = true;
            Print("EA claimed the command (mailbox_status=", CeremonyMailboxStatus_ToString(result.mailbox_status), ") - waiting for it to finish...");
         }
         if(CeremonyMailboxStatus_IsTerminal(result.mailbox_status))
         {
            Print("=== Command finished: mailbox_status=", CeremonyMailboxStatus_ToString(result.mailbox_status), " ===");
            Print("reason_code=", result.result_reason_code, "  message=", result.result_message);
            Print("execution_request_id=", result.result_execution_request_id);
            Print("candidate_id=", result.result_candidate_id);
            if(result.mailbox_status == CEREMONY_MAILBOX_STATUS_COMPLETE)
               Print("Approval durably recorded by the EA. NOTE: not yet a submission - a separate, "
                     "QA-authorized SUBMIT_ORDER command is required to actually reach OrderSend.");
            return;
         }
      }
      Sleep(500);
   }

   Print("TIMEOUT after ", I_PollTimeoutSeconds, "s: the command may still be pending or in progress - "
         "check the EA's own Experts log directly.");
}
