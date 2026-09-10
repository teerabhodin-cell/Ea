//+------------------------------------------------------------------+
//| MLQuantAI_ManualScript_EvaluateEntryCompatibility.mq5              |
//| RA-30.3 (QA-frozen Read-Only Entry Compatibility Diagnostic): a     |
//| thin COMMAND ISSUER only, same shape as                            |
//| MLQuantAI_ManualScript_GrantApproval.mq5 - writes one                |
//| EVALUATE_ENTRY_COMPATIBILITY command to the mailbox                  |
//| (MLQuantAI_CeremonyCommandMailbox.mqh), signals the EA, and polls    |
//| the mailbox for a terminal result.                                  |
//|                                                                    |
//| *** This script never calls OrderSend/CTrade, never opens the       |
//| *** EventStore itself, and this command NEVER reaches               |
//| *** BrokerSubmission_Submit()/OrderSend() inside the EA either -     |
//| *** EntryCompatibilityGate_Evaluate() is a pure evaluation, not a    |
//| *** submission. A separate, QA-authorized SUBMIT_ORDER command is    |
//| *** what actually attempts a real submission, never this one.       |
//|                                                                    |
//| The diagnostic result is EVIDENCE only (RA-30.3 QA verdict): it     |
//| does NOT authorize SUBMIT_ORDER by itself, because the live ASK/BID  |
//| price may move between this evaluation and any later SUBMIT_ORDER - |
//| the real, authoritative Entry Compatibility Gate result is always   |
//| the one SubmitOrderCommand() evaluates fresh at submit time.        |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_CeremonyCommandMailbox.mqh>
#include <MLQuantAI/Core/MLQuantAI_Ids.mqh>

input double I_ExpectedEABindingNonce   = 0.0; // RA-29.1 (re-scoped by RA-31.2 condition F): copy the EXACT nonce MLQuantAI.mq5 just printed at its own OnInit ("RA-29.1 binding published: ... nonce=..."). 0.0 = ABORT.
input string I_TargetExecutionRequestId = ""; // REQUIRED - execution_request_id to evaluate (from the RUN_C22_CEREMONY_FIXTURE command's own result/DIAGNOSTIC print)
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
   return true;
}

void OnStart()
{
   Print("=== MLQuantAI RA-30.3 Entry Compatibility diagnostic command issuer ===");
   Print("*** READ-ONLY: this command never calls OrderSend, never mutates submission state. ***");

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
   cmd.command_type                = CEREMONY_COMMAND_TYPE_EVALUATE_ENTRY_COMPATIBILITY;
   cmd.command_sequence             = seq;
   cmd.expected_ea_binding_nonce    = I_ExpectedEABindingNonce;
   cmd.expected_eventstore_filename = file;
   cmd.target_execution_request_id  = I_TargetExecutionRequestId;
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

   Print("Command issued: command_id=", cmd.command_id, " type=EVALUATE_ENTRY_COMPATIBILITY target_execution_request_id=",
         I_TargetExecutionRequestId, " command_sequence=", DoubleToString(seq, 0));
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
            Print("execution_request_hash=", result.result_execution_request_hash);
            Print("correlation_id=", result.result_correlation_id);
            Print("candidate_id=", result.result_candidate_id);
            if(result.mailbox_status == CEREMONY_MAILBOX_STATUS_COMPLETE)
            {
               Print("--- Entry Compatibility Diagnostic Result ---");
               Print("gate_result=", result.result_gate_decision);
               Print("execution_reference_price=", DoubleToString(result.result_execution_reference_price, _Digits));
               Print("planned_stop_distance=", DoubleToString(result.result_planned_stop_distance, _Digits));
               Print("realized_stop_distance=", DoubleToString(result.result_realized_stop_distance, _Digits));
               Print("planned_risk_money=", DoubleToString(result.result_planned_risk_money, 2));
               Print("realized_risk_money=", DoubleToString(result.result_realized_risk_money, 2));
               Print("risk_divergence_pct=", DoubleToString(result.result_risk_divergence_pct, 4));
               Print("directional_constraint_ok=", (result.result_directional_constraint_ok != 0 ? "true" : "false"));
               Print("NOTE: this is DIAGNOSTIC EVIDENCE ONLY - it does NOT authorize SUBMIT_ORDER. "
                     "The authoritative pre-submit Entry Compatibility Gate result is only the one "
                     "SubmitOrderCommand() evaluates fresh at actual submission time (price may have moved since).");
            }
            return;
         }
      }
      Sleep(500);
   }

   Print("TIMEOUT after ", I_PollTimeoutSeconds, "s: the command may still be pending or in progress - "
         "check the EA's own Experts log directly.");
}
