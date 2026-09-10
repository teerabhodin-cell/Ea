//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_CeremonyCommandMailbox.mqh        |
//| RA-31 (QA-frozen Single-Writer Command/Response Protocol,          |
//| RA-31.2 condition A/2): the command "mailbox" - a small, ephemeral, |
//| single-slot file (NOT the EventStore) carrying one ceremony        |
//| command's request fields from a script to the EA, and the EA's     |
//| coarse response fields back. This file is transport/control only - |
//| per RA-31.2 condition 2, it is NEVER historical truth. The         |
//| EventStore (via MLQuantAI_CeremonyCommandEventEmission.mqh) is the |
//| only durable record of what actually happened; this file may be    |
//| lost, corrupted, or overwritten without any loss of history - a    |
//| restart/crash recovery never trusts anything read from here.       |
//|                                                                    |
//| Unlike the EventStore, this file is never held open continuously   |
//| by either side - every read/write here is a brief, immediate       |
//| open -> read-or-write -> close by whichever program touches it at  |
//| that moment. That is what keeps this file free of the exact        |
//| exclusive-lock contention RA-30.1 proved for the EventStore itself |
//| (150/150 concurrent-open failures, err=5004, while the EA held the |
//| file open continuously) - two brief, non-overlapping opens don't   |
//| collide, even without FILE_SHARE_* flags.                          |
//|                                                                    |
//| Claim/ack protocol (RA-31.1 point A, RA-31.2 condition 1):         |
//|   mailbox_status="PENDING"  - Script just wrote a new command,      |
//|                                nobody has claimed it yet            |
//|   mailbox_status="CLAIMED"  - EA has taken ownership; from this      |
//|                                point on ONLY the EA may write this  |
//|                                file, until a terminal status        |
//|   mailbox_status="COMPLETE"/"REJECTED"/"FAILED" (terminal) - the     |
//|                                EA is done; the Script may now read  |
//|                                the result fields, and is then free  |
//|                                to overwrite with a new command      |
//|                                                                    |
//| This file only ever sets mailbox_status=CLAIMED as a side effect of |
//| CeremonyCommand_TryClaim() in                                       |
//| MLQuantAI_CeremonyCommandEventEmission.mqh, which durably appends   |
//| COMMAND_RECEIVED to the EventStore FIRST and only writes CLAIMED to |
//| this file if that durable append succeeded (RA-31.2 condition 1:    |
//| "EventStore append failed -> mailbox ห้ามกลายเป็น CLAIMED"). This    |
//| file itself has no EventStore dependency and knows nothing about    |
//| that ordering - it is a pure, dumb transport.                       |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CEREMONYCOMMANDMAILBOX_MQH__
#define __MLQUANTAI_CEREMONYCOMMANDMAILBOX_MQH__

// MLQuantAI_Enums.mqh must come before MLQuantAI_EventSerializer.mqh -
// found empirically (real compile, 2026.09.11): EventSerializer.mqh
// calls StrategyIdToString() (declared in Enums.mqh) but does not
// include Enums.mqh itself - every pre-existing call site happened to
// already have Enums.mqh included first via some other path; this file
// is the first to include EventSerializer.mqh without that, so it must
// bring Enums.mqh in explicitly rather than rely on inclusion order luck.
#include "../Core/MLQuantAI_Enums.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh"
#include "../Core/MLQuantAI_CanonicalFormat.mqh"

#define MLQUANTAI_CEREMONY_MAILBOX_FILENAME "MLQuantAI_CeremonyCommand.json"

//---------------------------------------------------------------------
// Command type - deliberately closed/small (RA-31.2 scope): exactly the
// three ceremony steps that used to be three separate EventStore
// writers (the smoke test script's own submission flow, and the
// standalone ManualScript_GrantApproval.mq5) and are now all routed
// through the EA as commands instead.
//---------------------------------------------------------------------
enum ENUM_CEREMONY_COMMAND_TYPE
{
   CEREMONY_COMMAND_TYPE_UNKNOWN,
   CEREMONY_COMMAND_TYPE_RUN_C22_CEREMONY_FIXTURE,
   CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL,
   CEREMONY_COMMAND_TYPE_SUBMIT_ORDER
};

string CeremonyCommandType_ToString(ENUM_CEREMONY_COMMAND_TYPE t)
{
   switch(t)
   {
      case CEREMONY_COMMAND_TYPE_RUN_C22_CEREMONY_FIXTURE: return "RUN_C22_CEREMONY_FIXTURE";
      case CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL:    return "GRANT_MANUAL_APPROVAL";
      case CEREMONY_COMMAND_TYPE_SUBMIT_ORDER:             return "SUBMIT_ORDER";
   }
   return "UNKNOWN";
}

ENUM_CEREMONY_COMMAND_TYPE CeremonyCommandType_FromString(string s)
{
   if(s == "RUN_C22_CEREMONY_FIXTURE") return CEREMONY_COMMAND_TYPE_RUN_C22_CEREMONY_FIXTURE;
   if(s == "GRANT_MANUAL_APPROVAL")    return CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL;
   if(s == "SUBMIT_ORDER")             return CEREMONY_COMMAND_TYPE_SUBMIT_ORDER;
   return CEREMONY_COMMAND_TYPE_UNKNOWN;
}

//---------------------------------------------------------------------
// Mailbox-file status - transport-layer claim/ack ONLY. NOT the same as
// the durable, EventStore-resident CEREMONY_COMMAND_STATE_CHANGED state
// machine (MLQuantAI_CeremonyCommandEventEmission.mqh), which has more
// states and is the actual source of truth for restart recovery.
//---------------------------------------------------------------------
enum ENUM_CEREMONY_MAILBOX_STATUS
{
   CEREMONY_MAILBOX_STATUS_UNKNOWN,
   CEREMONY_MAILBOX_STATUS_PENDING,
   CEREMONY_MAILBOX_STATUS_CLAIMED,
   CEREMONY_MAILBOX_STATUS_COMPLETE,
   CEREMONY_MAILBOX_STATUS_REJECTED,
   CEREMONY_MAILBOX_STATUS_FAILED
};

string CeremonyMailboxStatus_ToString(ENUM_CEREMONY_MAILBOX_STATUS s)
{
   switch(s)
   {
      case CEREMONY_MAILBOX_STATUS_PENDING:  return "PENDING";
      case CEREMONY_MAILBOX_STATUS_CLAIMED:  return "CLAIMED";
      case CEREMONY_MAILBOX_STATUS_COMPLETE: return "COMPLETE";
      case CEREMONY_MAILBOX_STATUS_REJECTED: return "REJECTED";
      case CEREMONY_MAILBOX_STATUS_FAILED:   return "FAILED";
   }
   return "UNKNOWN";
}

ENUM_CEREMONY_MAILBOX_STATUS CeremonyMailboxStatus_FromString(string s)
{
   if(s == "PENDING")  return CEREMONY_MAILBOX_STATUS_PENDING;
   if(s == "CLAIMED")  return CEREMONY_MAILBOX_STATUS_CLAIMED;
   if(s == "COMPLETE") return CEREMONY_MAILBOX_STATUS_COMPLETE;
   if(s == "REJECTED") return CEREMONY_MAILBOX_STATUS_REJECTED;
   if(s == "FAILED")   return CEREMONY_MAILBOX_STATUS_FAILED;
   return CEREMONY_MAILBOX_STATUS_UNKNOWN;
}

// Terminal = the EA is fully done with this command; the Script may read
// the result fields and is then free to overwrite the mailbox with a
// new command (RA-31.2 condition A's core invariant).
bool CeremonyMailboxStatus_IsTerminal(ENUM_CEREMONY_MAILBOX_STATUS s)
{
   return s == CEREMONY_MAILBOX_STATUS_COMPLETE || s == CEREMONY_MAILBOX_STATUS_REJECTED || s == CEREMONY_MAILBOX_STATUS_FAILED;
}

//---------------------------------------------------------------------
// The mailbox record itself. Request fields are written by the Script
// before mailbox_status ever becomes anything but PENDING. Result
// fields are written/overwritten only by the EA, from CLAIMED onward.
//---------------------------------------------------------------------
struct CeremonyCommand
{
   // --- request (Script) ---
   string                       command_id;
   ENUM_CEREMONY_COMMAND_TYPE   command_type;
   double                       command_sequence;               // must equal the GlobalVariable MLQuantAI_CommandPending__<file> value that woke the EA
   double                       expected_ea_binding_nonce;       // RA-29.1 nonce, re-scoped per RA-31.2: proves this command targets a live, non-stale EA instance
   string                       expected_eventstore_filename;
   string                       correlation_id;                  // RUN_C22_CEREMONY_FIXTURE: script-generated, fresh per command
   double                       ceremony_reference_price;        // RUN_C22_CEREMONY_FIXTURE only; 0.0 = EA captures live bid fresh
   string                       target_execution_request_id;     // GRANT_MANUAL_APPROVAL / SUBMIT_ORDER only: which existing request this command acts on
   string                       approver_identity;                // GRANT_MANUAL_APPROVAL only
   int                          approval_validity_minutes;        // GRANT_MANUAL_APPROVAL only

   // --- response (EA) ---
   ENUM_CEREMONY_MAILBOX_STATUS mailbox_status;
   string                       result_reason_code;
   string                       result_message;
   string                       result_candidate_id;
   string                       result_execution_request_id;
   string                       result_execution_request_hash;
   string                       result_correlation_id;
   long                         result_order_ticket;
   long                         result_deal_ticket;
   int                          result_retcode;
};

void CeremonyCommand_Init(CeremonyCommand &c)
{
   c.command_id                    = "";
   c.command_type                  = CEREMONY_COMMAND_TYPE_UNKNOWN;
   c.command_sequence               = 0.0;
   c.expected_ea_binding_nonce      = 0.0;
   c.expected_eventstore_filename   = "";
   c.correlation_id                 = "";
   c.ceremony_reference_price       = 0.0;
   c.target_execution_request_id    = "";
   c.approver_identity              = "";
   c.approval_validity_minutes      = 0;
   c.mailbox_status                 = CEREMONY_MAILBOX_STATUS_UNKNOWN;
   c.result_reason_code             = "";
   c.result_message                 = "";
   c.result_candidate_id            = "";
   c.result_execution_request_id    = "";
   c.result_execution_request_hash  = "";
   c.result_correlation_id          = "";
   c.result_order_ticket            = 0;
   c.result_deal_ticket             = 0;
   c.result_retcode                 = 0;
}

string CeremonyCommand_ToJson(const CeremonyCommand &c)
{
   string s = "{";
   s += "\"command_id\":\""                    + EventSerializer_Escape(c.command_id) + "\",";
   s += "\"command_type\":\""                  + EventSerializer_Escape(CeremonyCommandType_ToString(c.command_type)) + "\",";
   s += "\"command_sequence\":"                 + CanonicalDouble(c.command_sequence) + ",";
   s += "\"expected_ea_binding_nonce\":"        + CanonicalDouble(c.expected_ea_binding_nonce) + ",";
   s += "\"expected_eventstore_filename\":\""   + EventSerializer_Escape(c.expected_eventstore_filename) + "\",";
   s += "\"correlation_id\":\""                 + EventSerializer_Escape(c.correlation_id) + "\",";
   s += "\"ceremony_reference_price\":"         + CanonicalDouble(c.ceremony_reference_price) + ",";
   s += "\"target_execution_request_id\":\""    + EventSerializer_Escape(c.target_execution_request_id) + "\",";
   s += "\"approver_identity\":\""              + EventSerializer_Escape(c.approver_identity) + "\",";
   s += "\"approval_validity_minutes\":"        + IntegerToString(c.approval_validity_minutes) + ",";
   s += "\"mailbox_status\":\""                 + EventSerializer_Escape(CeremonyMailboxStatus_ToString(c.mailbox_status)) + "\",";
   s += "\"result_reason_code\":\""             + EventSerializer_Escape(c.result_reason_code) + "\",";
   s += "\"result_message\":\""                 + EventSerializer_Escape(c.result_message) + "\",";
   s += "\"result_candidate_id\":\""            + EventSerializer_Escape(c.result_candidate_id) + "\",";
   s += "\"result_execution_request_id\":\""    + EventSerializer_Escape(c.result_execution_request_id) + "\",";
   s += "\"result_execution_request_hash\":\""  + EventSerializer_Escape(c.result_execution_request_hash) + "\",";
   s += "\"result_correlation_id\":\""          + EventSerializer_Escape(c.result_correlation_id) + "\",";
   s += "\"result_order_ticket\":"              + IntegerToString(c.result_order_ticket) + ",";
   s += "\"result_deal_ticket\":"                + IntegerToString(c.result_deal_ticket) + ",";
   s += "\"result_retcode\":"                    + IntegerToString(c.result_retcode);
   s += "}";
   return s;
}

void CeremonyCommand_FromJson(string json, CeremonyCommand &out)
{
   CeremonyCommand_Init(out);
   out.command_id                    = EventSerializer_GetStr(json, "command_id");
   out.command_type                  = CeremonyCommandType_FromString(EventSerializer_GetStr(json, "command_type"));
   out.command_sequence               = EventSerializer_GetDouble(json, "command_sequence");
   out.expected_ea_binding_nonce      = EventSerializer_GetDouble(json, "expected_ea_binding_nonce");
   out.expected_eventstore_filename   = EventSerializer_GetStr(json, "expected_eventstore_filename");
   out.correlation_id                 = EventSerializer_GetStr(json, "correlation_id");
   out.ceremony_reference_price       = EventSerializer_GetDouble(json, "ceremony_reference_price");
   out.target_execution_request_id    = EventSerializer_GetStr(json, "target_execution_request_id");
   out.approver_identity              = EventSerializer_GetStr(json, "approver_identity");
   out.approval_validity_minutes      = EventSerializer_GetInt(json, "approval_validity_minutes");
   out.mailbox_status                 = CeremonyMailboxStatus_FromString(EventSerializer_GetStr(json, "mailbox_status"));
   out.result_reason_code             = EventSerializer_GetStr(json, "result_reason_code");
   out.result_message                 = EventSerializer_GetStr(json, "result_message");
   out.result_candidate_id            = EventSerializer_GetStr(json, "result_candidate_id");
   out.result_execution_request_id    = EventSerializer_GetStr(json, "result_execution_request_id");
   out.result_execution_request_hash  = EventSerializer_GetStr(json, "result_execution_request_hash");
   out.result_correlation_id          = EventSerializer_GetStr(json, "result_correlation_id");
   out.result_order_ticket            = EventSerializer_GetLong(json, "result_order_ticket");
   out.result_deal_ticket             = EventSerializer_GetLong(json, "result_deal_ticket");
   out.result_retcode                 = EventSerializer_GetInt(json, "result_retcode");
}

//---------------------------------------------------------------------
// Raw file I/O - brief open/close every call, never held open (see file
// header). Returns false on any I/O failure; callers must treat that as
// "try again next poll", never as a fatal/durable failure - this file
// is not historical truth (RA-31.2 condition 2).
//---------------------------------------------------------------------
bool CeremonyCommandMailbox_Write(const CeremonyCommand &c)
{
   ResetLastError();
   int handle = FileOpen(MLQUANTAI_CEREMONY_MAILBOX_FILENAME, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return false;
   uint written = FileWriteString(handle, CeremonyCommand_ToJson(c) + "\r\n");
   FileClose(handle);
   return written > 0;
}

// Returns false if the file doesn't exist yet (never used) or can't be
// read right now - both cases mean "treat as no command", not an error.
bool CeremonyCommandMailbox_Read(CeremonyCommand &out)
{
   CeremonyCommand_Init(out);
   int handle = FileOpen(MLQUANTAI_CEREMONY_MAILBOX_FILENAME, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return false;
   string json = FileIsEnding(handle) ? "" : FileReadString(handle);
   FileClose(handle);
   if(json == "")
      return false;
   CeremonyCommand_FromJson(json, out);
   return true;
}

// RA-31.2 condition A's core guard: the Script MUST call this before
// ever writing a new command. True if there has never been a command
// (no mailbox file yet) or the last one reached a terminal status.
bool CeremonyCommandMailbox_IsFreeForNewCommand()
{
   CeremonyCommand existing;
   if(!CeremonyCommandMailbox_Read(existing))
      return true;
   return CeremonyMailboxStatus_IsTerminal(existing.mailbox_status);
}

#endif // __MLQUANTAI_CEREMONYCOMMANDMAILBOX_MQH__
