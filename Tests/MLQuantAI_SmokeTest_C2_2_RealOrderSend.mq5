//+------------------------------------------------------------------+
//| MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5                        |
//| RA-31 (QA-frozen Single-Writer Command/Response Protocol) rewrite: |
//| this script no longer opens the canonical EventStore, builds any   |
//| candidate/lineage, or calls BrokerSubmission_Submit()/OrderSend()   |
//| itself - RA-30.1 proved deterministically (150/150 FileOpen        |
//| failures, err=5004) that it never could safely do so while the EA  |
//| holds the same file open, which RA-29.1's own binding requires it   |
//| to do continuously to ever capture L3.                              |
//|                                                                    |
//| This script is now a thin COMMAND ISSUER only: it writes one        |
//| RUN_C22_CEREMONY_FIXTURE command to the mailbox                     |
//| (MLQuantAI_CeremonyCommandMailbox.mqh), signals the EA, and polls   |
//| the mailbox for a terminal result. The EA (MLQuantAI.mq5) is the    |
//| ONLY EventStore writer - see its own RA-31 section                 |
//| (RunC22CeremonyFixtureCommand) for the actual candidate-building     |
//| logic, which is a byte-for-byte copy of what used to live in this   |
//| file, so the resulting candidate_hash/execution_request_hash chain  |
//| is unchanged from every previously-verified real run (RA-19        |
//| through RA-30).                                                     |
//|                                                                    |
//| *** This script's command can still lead to a REAL order via the    |
//| EA's OrderSend() call - but only later, via a SEPARATE SUBMIT_ORDER |
//| command this script does not issue. This script alone can never     |
//| open a real position. ***                                           |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_CeremonyCommandMailbox.mqh>
#include <MLQuantAI/Core/MLQuantAI_Ids.mqh>

input bool   I_Understand_This_May_Open_A_Real_Position = false; // must be set true to run - script aborts otherwise (kept as an early, redundant safety check even though the EA re-validates everything itself)
input double CeremonyReferencePrice = 0.0; // C6.6-RA-06: 0.0 = EA captures current SYMBOL_BID and prints it as this run's frozen ceremony reference; >0 = reuse the EXACT value printed by an earlier run, unmodified/unrounded, so this run's identity chain matches that earlier run's
input double I_ExpectedEABindingNonce = 0.0; // RA-29.1 (re-scoped by RA-31.2 condition F): copy the EXACT nonce MLQuantAI.mq5 just printed at its own OnInit ("RA-29.1 binding published: ... nonce=..."). 0.0 = ABORT.
input int    I_PollTimeoutSeconds = 60; // how long to wait for the EA to claim and finish this command before giving up (the durable command itself is unaffected by this timeout - only this script's own patience)

input group "=== SUBMIT_ORDER mode (QA EMP-01 authorization required before use) ==="
input bool   I_IssueSubmitOrderInstead      = false; // false (default) = issue RUN_C22_CEREMONY_FIXTURE as before. true = issue SUBMIT_ORDER instead - THE ONLY MODE THAT CAN REACH A REAL OrderSend(). Every input above except I_ExpectedEABindingNonce/I_PollTimeoutSeconds is ignored in this mode.
input string I_TargetExecutionRequestIdForSubmit = ""; // REQUIRED when I_IssueSubmitOrderInstead=true - the execution_request_id an EMP-01-authorized GRANT_MANUAL_APPROVAL command has already approved

string CanonicalCeremonyFile() { return "MLQuantAI_SmokeTest_C2_2.jsonl"; }

// Local command_id generator - deliberately NOT added to MLQuantAI_Ids.mqh
// (out of RA-31's authorized file scope), so this mirrors that file's own
// Ids_NewRuntimeSessionId() technique (account+time+microsecond-count+
// counter+MathRand(), hashed) using only its already-exported
// Ids_Sha256Hex(), rather than a raw GetTickCount()-only seed (that
// file's own header explicitly warns millisecond resolution alone can
// collide on back-to-back calls).
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

void OnStart()
{
   Print("=== MLQuantAI C2.2 ceremony command issuer (RA-31) ===");

   if(!I_Understand_This_May_Open_A_Real_Position)
   {
      Print("ABORTED: set input I_Understand_This_May_Open_A_Real_Position = true to run this script.");
      return;
   }

   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   Print("Account login: ", login, "  ACCOUNT_TRADE_MODE: ", EnumToString((ENUM_ACCOUNT_TRADE_MODE)tradeMode));
   if(tradeMode != ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("ABORTED (script-level check): this account is not ACCOUNT_TRADE_MODE_DEMO. "
            "The EA's own BrokerSubmissionGate would fail-closed here too, but this script refuses even earlier.");
      return;
   }

   if(I_ExpectedEABindingNonce <= 0.0)
   {
      Print("ABORTED: I_ExpectedEABindingNonce not provided (<=0.0). Read the EA's own Experts log line "
            "'RA-29.1 binding published: ... nonce=...' for file=", CanonicalCeremonyFile(),
            " and copy that exact value into this input before running.");
      return;
   }

   if(I_IssueSubmitOrderInstead && I_TargetExecutionRequestIdForSubmit == "")
   {
      Print("ABORTED: I_IssueSubmitOrderInstead=true but I_TargetExecutionRequestIdForSubmit is blank.");
      return;
   }
   if(I_IssueSubmitOrderInstead)
      Print("*** SUBMIT_ORDER MODE: this run, if it reaches the EA, can result in a REAL OrderSend() for "
            "execution_request_id=", I_TargetExecutionRequestIdForSubmit, ". Only proceed under an explicit "
            "QA EMP-01 authorization for this exact execution_request_id. ***");

   // RA-31.2 condition A's core guard: never overwrite a command that
   // hasn't reached a terminal mailbox status yet.
   if(!CeremonyCommandMailbox_IsFreeForNewCommand())
   {
      Print("ABORTED: a previous ceremony command is still in flight (mailbox not terminal) - "
            "wait for it to finish, or check the EA's own log for why it is stuck, before issuing a new one.");
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
   cmd.command_type                = I_IssueSubmitOrderInstead ? CEREMONY_COMMAND_TYPE_SUBMIT_ORDER
                                                                 : CEREMONY_COMMAND_TYPE_RUN_C22_CEREMONY_FIXTURE;
   cmd.command_sequence             = seq;
   cmd.expected_ea_binding_nonce    = I_ExpectedEABindingNonce;
   cmd.expected_eventstore_filename = file;
   cmd.ceremony_reference_price     = CeremonyReferencePrice;
   cmd.target_execution_request_id  = I_TargetExecutionRequestIdForSubmit;
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

   Print("Command issued: command_id=", cmd.command_id, " type=RUN_C22_CEREMONY_FIXTURE command_sequence=",
         DoubleToString(seq, 0), " expected_ea_binding_nonce=", DoubleToString(I_ExpectedEABindingNonce, 0));
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
            Print("candidate_id=", result.result_candidate_id);
            Print("execution_request_id=", result.result_execution_request_id);
            Print("execution_request_hash=", result.result_execution_request_hash);
            Print("correlation_id=", result.result_correlation_id);
            if(I_IssueSubmitOrderInstead)
            {
               Print("order_ticket=", result.result_order_ticket, "  deal_ticket=", result.result_deal_ticket,
                     "  retcode=", result.result_retcode);
               if(result.mailbox_status == CEREMONY_MAILBOX_STATUS_COMPLETE)
                  Print("*** A REAL POSITION MAY NOW BE OPEN (order_ticket=", result.result_order_ticket, "). "
                        "This script has no close-position scope - close it manually in the terminal. ***");
               else if(result.result_reason_code == "l2_durability_write_failed_unresolved")
                  Print("*** UNRESOLVED: OrderSend() may have reached the broker but the EA could not durably "
                        "record the result. Do NOT retry. Human reconciliation required - see the EA's own log. ***");
            }
            else if(result.mailbox_status == CEREMONY_MAILBOX_STATUS_COMPLETE)
               Print("DIAGNOSTIC (for the GRANT_MANUAL_APPROVAL command): execution_request_id=",
                     result.result_execution_request_id, " is now ready for approval, then a separate, "
                     "QA-authorized SUBMIT_ORDER command (I_IssueSubmitOrderInstead=true on this same script).");
            return;
         }
      }
      Sleep(500);
   }

   Print("TIMEOUT after ", I_PollTimeoutSeconds, "s: the command may still be pending or in progress - "
         "check the EA's own Experts log directly. This script's own timeout does not cancel or affect the "
         "durable command in any way.");
}
