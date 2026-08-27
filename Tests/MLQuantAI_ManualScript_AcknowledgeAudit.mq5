//+------------------------------------------------------------------+
//| MLQuantAI_ManualScript_AcknowledgeAudit.mq5                       |
//| C3.10E2 - the standalone, human-run script that is the ONLY writer|
//| of TERMINAL_REJECTION_AUDIT_ACKNOWLEDGED events. Per the Terminal  |
//| Rejection Audit Acknowledgement Checkpoint 1 contract, locked in   |
//| this branch's chat history (no separate Docs/ file yet).           |
//|                                                                    |
//| A human runs this manually, once, per acknowledgement, after       |
//| observing the current C3.10C audit report's finding counts         |
//| wherever the EA's own logs/event store display them. This script   |
//| never reads the event store to discover or recompute the current   |
//| diagnostic_fingerprint itself - it is typed/pasted in by the       |
//| operator, deliberately, per the frozen eligibility rule (no audit  |
//| discovery/recomputation inside the operator command).              |
//|                                                                    |
//| *** NEVER calls OrderSend/CTrade or any broker-mutating API. The   |
//| *** only side effect is one durable, append-only event write -     |
//| *** identical in kind to every other *_EventEmission.mqh caller    |
//| *** in this project (see ManualScript_GrantApproval.mq5).          |
//| *** Records an acknowledgement of the SUPPLIED snapshot only. It   |
//| *** does NOT prove that snapshot is current, does NOT clear any    |
//| *** audit finding, does NOT unblock C3.10B, does NOT touch Safe    |
//| *** Mode, and does NOT alter trading authority in any way.         |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

input string I_EventStoreFileName    = ""; // REQUIRED - must exactly match the live EA's own event store file (Common Files); blank aborts
input string I_OperatorId            = ""; // REQUIRED - who is acknowledging this audit snapshot (name/handle) - never blank
input string I_DiagnosticFingerprint = ""; // REQUIRED - the diagnostic_fingerprint of the audit-report snapshot being acknowledged (operator-supplied, not computed by this script)
input string I_AcknowledgementNote   = ""; // optional free-text note, max 500 characters

#include <MLQuantAI/Execution/MLQuantAI_TerminalRejectionAuditAcknowledgement.mqh>

bool ValidateInputs()
{
   if(I_EventStoreFileName == "")    { Print("ABORTED: I_EventStoreFileName is blank - must exactly match the live EA's own event store file."); return false; }
   if(I_OperatorId == "")            { Print("ABORTED: I_OperatorId is blank - an anonymous acknowledgement is not a real acknowledgement."); return false; }
   if(I_DiagnosticFingerprint == "") { Print("ABORTED: I_DiagnosticFingerprint is blank."); return false; }
   return true;
}

void OnStart()
{
   Print("=== MLQuantAI C3.10E2 terminal rejection audit acknowledgement script ===");
   Print("*** This script never calls OrderSend/CTrade. It only appends one durable audit-trail event. ***");
   Print("*** WARNING: this records an acknowledgement of the SUPPLIED report snapshot only. It does ***");
   Print("*** NOT prove the snapshot is current, does NOT clear any audit finding, does NOT unblock  ***");
   Print("*** C3.10B, does NOT touch Safe Mode, and does NOT alter trading authority in any way.      ***");

   if(!ValidateInputs())
      return;

   if(!FileIsExist(I_EventStoreFileName, FILE_COMMON))
   {
      Print("ABORTED: event store file '", I_EventStoreFileName, "' does not exist in Common Files - refusing to create a new one for an acknowledgement.");
      return;
   }

   if(!EventStore_Open(I_EventStoreFileName))
   {
      Print("ABORTED: could not open event store file '", I_EventStoreFileName, "'.");
      return;
   }

   Print("Acknowledging: operator_id=", I_OperatorId,
         " diagnostic_fingerprint=", I_DiagnosticFingerprint,
         " note_len=", IntegerToString(StringLen(I_AcknowledgementNote)));

   TerminalRejectionAuditAcknowledgementResult result =
      TerminalRejectionAuditAcknowledgement_Record(I_EventStoreFileName, I_OperatorId, I_DiagnosticFingerprint, I_AcknowledgementNote);

   EventStore_Close();

   if(result.ok && result.already_acknowledged)
      Print("Already acknowledged by this operator for this exact snapshot - no new event written. "
            "log_event_id=", result.log_event_id, " sequence_number=", IntegerToString(result.sequence_number));
   else if(result.ok)
      Print("Acknowledgement durably recorded. log_event_id=", result.log_event_id,
            " sequence_number=", IntegerToString(result.sequence_number));
   else
      Print("FAILED: acknowledgement was NOT recorded - ", result.first_error);

   Print("=== acknowledgement script complete ===");
}
