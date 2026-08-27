//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_TerminalRejectionAuditAcknowledge |
//| ment.mqh                                                           |
//| C3.10E2 implementation (per the Terminal Rejection Audit            |
//| Acknowledgement Checkpoint 1 contract, locked in this branch's       |
//| chat history - no separate Docs/ file yet).                          |
//|                                                                        |
//| Durable, append-only accountability record: a human operator            |
//| acknowledges a specific C3.10C audit-report snapshot (identified by       |
//| diagnostic_fingerprint alone, never raw evidence). NOT repair, NOT         |
//| override, NOT a Safe Mode clear, NOT an unblock of C3.10B, and NOT an       |
//| authority over trade permission - a record that a human saw the current      |
//| finding-counts and chose to note it, nothing more.                             |
//|                                                                                   |
//| Deliberately has ZERO dependency on any C3.10A/B/C/D/E1/F header or type -        |
//| diagnostic_fingerprint arrives as an opaque, already-computed, operator-           |
//| supplied string (per the Checkpoint 1 eligibility rule: this scope does             |
//| not auto-read or recompute the current audit report). The frozen                     |
//| canonical-string/hash formula that PRODUCES a diagnostic_fingerprint from              |
//| a real AsyncTerminalRejectionAuditReport (Ids_Deterministic("AUDITFP", ...))            |
//| lives outside this file's scope this round - documented in the contract,                 |
//| not implemented here, so this module's own structural-purity proof                        |
//| (no C3.10A-F call anywhere) holds without qualification.                                    |
//|                                                                                                |
//| Timestamp authority: acknowledged_at is never a caller-supplied parameter -                    |
//| EventStore_LogSystem's own envelope (log_event_id/sequence_number/ts, all                       |
//| assigned internally via TimeCurrent()) is the durable record's identity and                      |
//| timing authority, exactly like every other event type in this codebase.                            |
//|                                                                                                       |
//| Idempotent only under the existing single-terminal/single-writer operational                          |
//| model: the read-before-write duplicate scan below is NOT an atomic claim                                |
//| primitive. Two separate EA/script processes could interleave scan->append                                 |
//| and both durably write a matching-key acknowledgement. This is an accepted                                  |
//| limitation of this scope, not a bug - a future multi-writer-safe scope would                                 |
//| need an event-store-level atomic append/claim primitive, which does not exist                                  |
//| today.                                                                                                          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_TERMINALREJECTIONAUDITACKNOWLEDGEMENT_MQH__
#define __MLQUANTAI_TERMINALREJECTIONAUDITACKNOWLEDGEMENT_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh"
#include "../Core/MLQuantAI_Enums.mqh"
#include "../Logging/MLQuantAI_SystemLogger.mqh"

// Frozen (Checkpoint 1): identifies the exact canonical-string/hash formula a
// diagnostic_fingerprint was computed under. A pre-existing durable E2 record
// carrying any OTHER value here (or missing/blank diagnostic_fingerprint_version
// or diagnostic_fingerprint) is treated as ambiguous by the duplicate scan below
// and fails the whole scan closed - never silently skipped as "not a match".
const string C310E2_FINGERPRINT_VERSION = "c3_10e2_audit_v1";

const int C310E2_OPERATOR_ID_MAX_LEN = 128;
const int C310E2_NOTE_MAX_LEN        = 500;

struct TerminalRejectionAuditAcknowledgementResult
{
   bool   ok;
   bool   already_acknowledged;
   string log_event_id;
   long   sequence_number;
   string first_error;
};

void TerminalRejectionAuditAcknowledgementResult_Init(TerminalRejectionAuditAcknowledgementResult &r)
{
   r.ok                    = false;
   r.already_acknowledged   = false;
   r.log_event_id            = "";
   r.sequence_number          = 0;
   r.first_error                = "";
}

//---------------------------------------------------------------------
// True if s contains any ASCII control character (0x00-0x1F or 0x7F).
// Deliberately conservative - a durable audit-trail identity field
// should never carry raw control bytes into a JSON payload.
//---------------------------------------------------------------------
bool C310E2_HasControlChar(string s)
{
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
   {
      ushort c = StringGetCharacter(s, i);
      if(c <= 0x1F || c == 0x7F)
         return true;
   }
   return false;
}

//---------------------------------------------------------------------
// Validation floor - never writes a garbage record, same "reject before
// any file I/O" rule every prior *_EventEmission.mqh emitter enforces
// (see ManualApproval_Grant). Returns "" if valid, else the first_error
// text.
//---------------------------------------------------------------------
string C310E2_ValidateInputs(string operatorId, string diagnosticFingerprint, string acknowledgementNote)
{
   if(operatorId == "")
      return "operator_id is blank";
   if(StringLen(operatorId) > C310E2_OPERATOR_ID_MAX_LEN)
      return "operator_id exceeds " + IntegerToString(C310E2_OPERATOR_ID_MAX_LEN) + " characters";
   if(C310E2_HasControlChar(operatorId))
      return "operator_id contains a control character";
   if(diagnosticFingerprint == "")
      return "diagnostic_fingerprint is blank";
   if(StringLen(acknowledgementNote) > C310E2_NOTE_MAX_LEN)
      return "acknowledgement_note exceeds " + IntegerToString(C310E2_NOTE_MAX_LEN) + " characters";
   return "";
}

//---------------------------------------------------------------------
// Payload builder. Exact frozen keys: c3_10e2_schema_version,
// diagnostic_fingerprint_version, operator_id, diagnostic_fingerprint,
// acknowledgement_note. No acknowledgement id, no timestamp - the event
// store's own envelope is the identity/timing authority.
//---------------------------------------------------------------------
string C310E2_ToExtraJson(string operatorId, string diagnosticFingerprint, string acknowledgementNote)
{
   string s = "";
   s += "\"c3_10e2_schema_version\":\"1\",";
   s += "\"diagnostic_fingerprint_version\":\"" + EventSerializer_Escape(C310E2_FINGERPRINT_VERSION) + "\",";
   s += "\"operator_id\":\""                    + EventSerializer_Escape(operatorId) + "\",";
   s += "\"diagnostic_fingerprint\":\""          + EventSerializer_Escape(diagnosticFingerprint) + "\",";
   s += "\"acknowledgement_note\":\""             + EventSerializer_Escape(acknowledgementNote) + "\"";
   return s;
}

//---------------------------------------------------------------------
// Read-before-write duplicate scan. Fail-closed (outAmbiguous=true) the
// instant any line typed TERMINAL_REJECTION_AUDIT_ACKNOWLEDGED carries a
// diagnostic_fingerprint_version other than C310E2_FINGERPRINT_VERSION,
// or a blank diagnostic_fingerprint/operator_id - even one seen AFTER a
// real match was already found earlier in the scan. A confusing record
// anywhere in the store means the scan cannot honestly claim "no
// duplicate exists", so it claims nothing at all.
//---------------------------------------------------------------------
void C310E2_ScanForAcknowledgement(const string &lines[], string operatorId, string diagnosticFingerprint,
                                    bool &outFound, string &outLogEventId, long &outSequenceNumber, bool &outAmbiguous)
{
   outFound          = false;
   outLogEventId     = "";
   outSequenceNumber = 0;
   outAmbiguous      = false;

   string targetType = EventTypeToString(EVENT_TYPE_TERMINAL_REJECTION_AUDIT_ACKNOWLEDGED);
   int n = ArraySize(lines);

   for(int i = 0; i < n; i++)
   {
      string line = lines[i];
      if(EventSerializer_GetStr(line, "type") != targetType)
         continue;

      string recordVersion     = EventSerializer_GetStr(line, "diagnostic_fingerprint_version");
      string recordFingerprint = EventSerializer_GetStr(line, "diagnostic_fingerprint");
      string recordOperator    = EventSerializer_GetStr(line, "operator_id");

      if(recordVersion != C310E2_FINGERPRINT_VERSION || recordFingerprint == "" || recordOperator == "")
      {
         outFound          = false;
         outLogEventId     = "";
         outSequenceNumber = 0;
         outAmbiguous      = true;
         return;
      }

      if(!outFound && recordOperator == operatorId && recordFingerprint == diagnosticFingerprint)
      {
         outFound          = true;
         outLogEventId     = EventSerializer_GetStr(line, "log_event_id");
         outSequenceNumber = EventSerializer_GetLong(line, "seq");
      }
   }
}

//---------------------------------------------------------------------
// THE entry point. Caller (the manual script) must already have a
// successfully-open event store (EventStore_Open) before calling this,
// and closes it afterward - this function neither opens nor closes the
// store itself, matching every other *_EventEmission.mqh write helper's
// division of labor. fileName is passed through to EventStore_ReadAll
// Lines only, which reuses the already-open handle when fileName matches
// the currently-open store (its own established behavior).
//---------------------------------------------------------------------
TerminalRejectionAuditAcknowledgementResult TerminalRejectionAuditAcknowledgement_Record(
   string fileName, string operatorId, string diagnosticFingerprint, string acknowledgementNote)
{
   TerminalRejectionAuditAcknowledgementResult result;
   TerminalRejectionAuditAcknowledgementResult_Init(result);

   string validationError = C310E2_ValidateInputs(operatorId, diagnosticFingerprint, acknowledgementNote);
   if(validationError != "")
   {
      result.first_error = validationError;
      return result;
   }

   string lines[];
   EventStore_ReadAllLines(fileName, lines);

   bool   found = false;
   string existingLogEventId = "";
   long   existingSequenceNumber = 0;
   bool   ambiguous = false;
   C310E2_ScanForAcknowledgement(lines, operatorId, diagnosticFingerprint,
                                  found, existingLogEventId, existingSequenceNumber, ambiguous);

   if(ambiguous)
   {
      result.first_error = "duplicate scan is ambiguous - a pre-existing "
                            "TERMINAL_REJECTION_AUDIT_ACKNOWLEDGED record carries an unrecognized "
                            "diagnostic_fingerprint_version or a blank identity field; refusing to "
                            "append until this is resolved";
      LogError("C3.10E2 terminal rejection audit acknowledgement: " + result.first_error);
      return result;
   }

   if(found)
   {
      result.ok                    = true;
      result.already_acknowledged  = true;
      result.log_event_id          = existingLogEventId;
      result.sequence_number       = existingSequenceNumber;
      return result;
   }

   string extraJson = C310E2_ToExtraJson(operatorId, diagnosticFingerprint, acknowledgementNote);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_TERMINAL_REJECTION_AUDIT_ACKNOWLEDGED),
                             "terminal rejection audit acknowledged", extraJson))
   {
      result.first_error = "durable write failed";
      LogError("C3.10E2 terminal rejection audit acknowledgement: durable write failed for operator_id=" +
               operatorId + " diagnostic_fingerprint=" + diagnosticFingerprint);
      return result;
   }

   // Recover the just-written event's own real identity - never fabricate it.
   string freshLines[];
   EventStore_ReadAllLines(fileName, freshLines);
   bool   confirmFound = false;
   string confirmLogEventId = "";
   long   confirmSequenceNumber = 0;
   bool   confirmAmbiguous = false;
   C310E2_ScanForAcknowledgement(freshLines, operatorId, diagnosticFingerprint,
                                  confirmFound, confirmLogEventId, confirmSequenceNumber, confirmAmbiguous);

   if(!confirmFound)
   {
      // Should be structurally unreachable (we just wrote it durably), but an
      // identity-recovery step must never fabricate a placeholder identity.
      result.first_error = "durable write succeeded but the written event could not be recovered "
                            "for identity confirmation";
      LogError("C3.10E2 terminal rejection audit acknowledgement: " + result.first_error);
      return result;
   }

   result.ok                   = true;
   result.already_acknowledged = false;
   result.log_event_id         = confirmLogEventId;
   result.sequence_number      = confirmSequenceNumber;
   return result;
}

#endif // __MLQUANTAI_TERMINALREJECTIONAUDITACKNOWLEDGEMENT_MQH__
