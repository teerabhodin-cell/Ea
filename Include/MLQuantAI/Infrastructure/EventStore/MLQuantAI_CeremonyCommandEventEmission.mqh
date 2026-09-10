//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/                            |
//| MLQuantAI_CeremonyCommandEventEmission.mqh                        |
//| RA-31 (QA-frozen Single-Writer Command/Response Protocol): the      |
//| durable side of the command state machine. Every transition here   |
//| is written to the canonical EventStore as a                        |
//| CEREMONY_COMMAND_STATE_CHANGED SystemEvent - per RA-31.2 condition  |
//| 2, this is the ONLY historical truth about a command; the mailbox   |
//| file (MLQuantAI_CeremonyCommandMailbox.mqh) is transport only and   |
//| is never consulted by anything in this file for that purpose.      |
//|                                                                    |
//| ONLY the EA may call anything in this file - it is the sole         |
//| EventStore writer under RA-31's single-writer architecture. A       |
//| script must never include this file.                                |
//|                                                                    |
//| States (RA-31.1/RA-31.2, frozen):                                   |
//|   COMMAND_RECEIVED       -&gt; claimed, validated                     |
//|   COMMAND_REJECTED       [terminal] stale nonce / filename mismatch /|
//|                           unknown command type                      |
//|   CEREMONY_IN_PROGRESS   -&gt; building candidate...execution request  |
//|                           (RUN_C22_CEREMONY_FIXTURE only)            |
//|   CEREMONY_READY         -&gt; dry-run accepted, awaiting a separate    |
//|                           GRANT_MANUAL_APPROVAL/SUBMIT_ORDER command |
//|   APPROVAL_RECORDED      [terminal] GRANT_MANUAL_APPROVAL only        |
//|   SUBMISSION_IN_PROGRESS -&gt; L1 written, about to call OrderSend()    |
//|   SUBMISSION_COMPLETE    -&gt; L2 written (OrderSend returned)          |
//|   OBSERVATION_COMPLETE   [terminal] L3 written (OnTradeTransaction)  |
//|   COMMAND_FAILED         [terminal] fail-closed at any point         |
//|                                                                    |
//| Restart semantics (RA-31.2 condition C, frozen):                    |
//|   terminal state            -&gt; ignore duplicate signals             |
//|   CEREMONY_IN_PROGRESS      -&gt; force COMMAND_FAILED(interrupted_by_ |
//|                                 restart), NEVER auto-resume          |
//|   CEREMONY_READY            -&gt; safe to leave as-is, resume waiting  |
//|   SUBMISSION_IN_PROGRESS    -&gt; global unresolved-submission gate     |
//|                                 (RA-31.2 condition B)                |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CEREMONYCOMMANDEVENTEMISSION_MQH__
#define __MLQUANTAI_CEREMONYCOMMANDEVENTEMISSION_MQH__

#include "MLQuantAI_EventStore.mqh"
#include "../../Core/MLQuantAI_Enums.mqh"
#include "../../Core/MLQuantAI_CanonicalFormat.mqh"
#include "../../Execution/MLQuantAI_CeremonyCommandMailbox.mqh"

enum ENUM_CEREMONY_COMMAND_STATE
{
   CEREMONY_STATE_UNKNOWN,
   CEREMONY_STATE_COMMAND_RECEIVED,
   CEREMONY_STATE_COMMAND_REJECTED,
   CEREMONY_STATE_CEREMONY_IN_PROGRESS,
   CEREMONY_STATE_CEREMONY_READY,
   CEREMONY_STATE_APPROVAL_RECORDED,
   CEREMONY_STATE_SUBMISSION_IN_PROGRESS,
   CEREMONY_STATE_SUBMISSION_COMPLETE,
   CEREMONY_STATE_OBSERVATION_COMPLETE,
   CEREMONY_STATE_COMMAND_FAILED,

   // RA-30.3 (QA-frozen Read-Only Entry Compatibility Diagnostic):
   // terminal state for EVALUATE_ENTRY_COMPATIBILITY only. Reached
   // directly from COMMAND_RECEIVED in a single synchronous call - no
   // intermediate non-terminal state exists for this command type (see
   // MLQuantAI_EntryCompatibilityDiagnosticEmission.mqh). Whether the
   // gate itself accepted or rejected is carried in the
   // ENTRY_COMPATIBILITY_EVALUATED event's own gate_result field, not
   // encoded as a separate command state - same convention as
   // APPROVAL_RECORDED.
   CEREMONY_STATE_ENTRY_COMPATIBILITY_EVALUATED
};

string CeremonyCommandState_ToString(ENUM_CEREMONY_COMMAND_STATE s)
{
   switch(s)
   {
      case CEREMONY_STATE_COMMAND_RECEIVED:       return "COMMAND_RECEIVED";
      case CEREMONY_STATE_COMMAND_REJECTED:       return "COMMAND_REJECTED";
      case CEREMONY_STATE_CEREMONY_IN_PROGRESS:   return "CEREMONY_IN_PROGRESS";
      case CEREMONY_STATE_CEREMONY_READY:         return "CEREMONY_READY";
      case CEREMONY_STATE_APPROVAL_RECORDED:      return "APPROVAL_RECORDED";
      case CEREMONY_STATE_SUBMISSION_IN_PROGRESS: return "SUBMISSION_IN_PROGRESS";
      case CEREMONY_STATE_SUBMISSION_COMPLETE:    return "SUBMISSION_COMPLETE";
      case CEREMONY_STATE_OBSERVATION_COMPLETE:   return "OBSERVATION_COMPLETE";
      case CEREMONY_STATE_COMMAND_FAILED:         return "COMMAND_FAILED";
      case CEREMONY_STATE_ENTRY_COMPATIBILITY_EVALUATED: return "ENTRY_COMPATIBILITY_EVALUATED";
   }
   return "UNKNOWN";
}

ENUM_CEREMONY_COMMAND_STATE CeremonyCommandState_FromString(string s)
{
   if(s == "COMMAND_RECEIVED")       return CEREMONY_STATE_COMMAND_RECEIVED;
   if(s == "COMMAND_REJECTED")       return CEREMONY_STATE_COMMAND_REJECTED;
   if(s == "CEREMONY_IN_PROGRESS")   return CEREMONY_STATE_CEREMONY_IN_PROGRESS;
   if(s == "CEREMONY_READY")         return CEREMONY_STATE_CEREMONY_READY;
   if(s == "APPROVAL_RECORDED")      return CEREMONY_STATE_APPROVAL_RECORDED;
   if(s == "SUBMISSION_IN_PROGRESS") return CEREMONY_STATE_SUBMISSION_IN_PROGRESS;
   if(s == "SUBMISSION_COMPLETE")    return CEREMONY_STATE_SUBMISSION_COMPLETE;
   if(s == "OBSERVATION_COMPLETE")   return CEREMONY_STATE_OBSERVATION_COMPLETE;
   if(s == "COMMAND_FAILED")         return CEREMONY_STATE_COMMAND_FAILED;
   if(s == "ENTRY_COMPATIBILITY_EVALUATED") return CEREMONY_STATE_ENTRY_COMPATIBILITY_EVALUATED;
   return CEREMONY_STATE_UNKNOWN;
}

// EventStore-level terminal (restart/duplicate-ignore sense) - NOT the
// same partition as the mailbox's own terminal set. CEREMONY_READY and
// SUBMISSION_COMPLETE are deliberately NOT here even though the mailbox
// may already show COMPLETE for them - see the file header.
bool CeremonyCommandState_IsTerminal(ENUM_CEREMONY_COMMAND_STATE s)
{
   return s == CEREMONY_STATE_COMMAND_REJECTED || s == CEREMONY_STATE_APPROVAL_RECORDED
       || s == CEREMONY_STATE_OBSERVATION_COMPLETE || s == CEREMONY_STATE_COMMAND_FAILED
       || s == CEREMONY_STATE_ENTRY_COMPATIBILITY_EVALUATED;
}

//---------------------------------------------------------------------
// In-memory registry, rebuilt from the EventStore on every OnInit -
// this (not the mailbox) is what restart recovery and duplicate-command
// rejection consult.
//---------------------------------------------------------------------
struct CeremonyCommandRegistryEntry
{
   string                        command_id;
   ENUM_CEREMONY_COMMAND_TYPE    command_type;
   ENUM_CEREMONY_COMMAND_STATE   current_state;
   string                        execution_request_id;
};

CeremonyCommandRegistryEntry g_CeremonyCommandRegistry[];

int CeremonyCommandRegistry_FindIndex(string commandId)
{
   for(int i = 0; i < ArraySize(g_CeremonyCommandRegistry); i++)
      if(g_CeremonyCommandRegistry[i].command_id == commandId)
         return i;
   return -1;
}

bool CeremonyCommandRegistry_IsKnown(string commandId)
{
   return CeremonyCommandRegistry_FindIndex(commandId) >= 0;
}

ENUM_CEREMONY_COMMAND_STATE CeremonyCommandRegistry_GetState(string commandId)
{
   int idx = CeremonyCommandRegistry_FindIndex(commandId);
   return (idx < 0) ? CEREMONY_STATE_UNKNOWN : g_CeremonyCommandRegistry[idx].current_state;
}

struct CeremonyCommandRegistryReport
{
   bool ok;
   int  lines_applied;
};

void CeremonyCommandRegistryReport_Init(CeremonyCommandRegistryReport &r) { r.ok = true; r.lines_applied = 0; }

// Rebuilds g_CeremonyCommandRegistry from every CEREMONY_COMMAND_STATE_
// CHANGED line in fileName, keeping only the LATEST state per command_id
// (file is append-only/chronological, so last-seen wins). Call once
// from OnInit, after EventStore_Open(), same pattern as
// BrokerSubmissionAudit_StartupRebuild/ManualApproval_StartupRebuild.
CeremonyCommandRegistryReport CeremonyCommandRegistry_RebuildFromFile(string fileName)
{
   CeremonyCommandRegistryReport report;
   CeremonyCommandRegistryReport_Init(report);
   ArrayResize(g_CeremonyCommandRegistry, 0);

   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);
   for(int i = 0; i < n; i++)
   {
      string line = lines[i];
      if(line == "") continue;
      if(EventSerializer_PeekCategory(line) != EVENT_CAT_SYSTEM) continue;
      if(EventSerializer_GetStr(line, "type") != "CEREMONY_COMMAND_STATE_CHANGED") continue;

      string commandId = EventSerializer_GetStr(line, "command_id");
      if(commandId == "") continue; // malformed - skip this line defensively, don't abort the whole rebuild

      ENUM_CEREMONY_COMMAND_STATE toState = CeremonyCommandState_FromString(EventSerializer_GetStr(line, "to_state"));
      string execReqId = EventSerializer_GetStr(line, "execution_request_id");

      int idx = CeremonyCommandRegistry_FindIndex(commandId);
      if(idx < 0)
      {
         idx = ArraySize(g_CeremonyCommandRegistry);
         ArrayResize(g_CeremonyCommandRegistry, idx + 1);
         g_CeremonyCommandRegistry[idx].command_id = commandId;
         g_CeremonyCommandRegistry[idx].command_type = CeremonyCommandType_FromString(EventSerializer_GetStr(line, "command_type"));
         g_CeremonyCommandRegistry[idx].execution_request_id = "";
      }
      g_CeremonyCommandRegistry[idx].current_state = toState;
      if(execReqId != "")
         g_CeremonyCommandRegistry[idx].execution_request_id = execReqId;

      report.lines_applied++;
   }
   return report;
}

// RA-31.2 condition C: any command left at CEREMONY_IN_PROGRESS when the
// EA restarted must be force-failed, never resumed (the builder chain
// mints fresh IDs on every call - resuming mid-build risks the exact
// duplicate-genesis SafeMode trip RA-26 hit). Call once from OnInit,
// right after CeremonyCommandRegistry_RebuildFromFile().
int CeremonyCommandRegistry_FailInterruptedCommands()
{
   int failedCount = 0;
   int total = ArraySize(g_CeremonyCommandRegistry);
   for(int i = 0; i < total; i++)
   {
      if(g_CeremonyCommandRegistry[i].current_state != CEREMONY_STATE_CEREMONY_IN_PROGRESS)
         continue;
      EventStore_LogCeremonyCommandState(g_CeremonyCommandRegistry[i].command_id, g_CeremonyCommandRegistry[i].command_type,
                                          CEREMONY_STATE_CEREMONY_IN_PROGRESS, CEREMONY_STATE_COMMAND_FAILED,
                                          "interrupted_by_restart", "");
      failedCount++;
   }
   return failedCount;
}

// RA-31.2 condition B: true if ANY command is stuck at SUBMISSION_IN_
// PROGRESS (L1 durably written, OrderSend outcome unknown - EA may have
// crashed between OrderSend() and writing L2). A true return here must
// globally block every NEW SUBMIT_ORDER command, regardless of which
// execution_request_id it targets, until reconciliation resolves it.
bool CeremonyCommandRegistry_HasUnresolvedSubmission()
{
   int total = ArraySize(g_CeremonyCommandRegistry);
   for(int i = 0; i < total; i++)
      if(g_CeremonyCommandRegistry[i].current_state == CEREMONY_STATE_SUBMISSION_IN_PROGRESS)
         return true;
   return false;
}

//---------------------------------------------------------------------
// The durable append itself - every CEREMONY_COMMAND_STATE_CHANGED line
// ever written goes through here, and only here.
//---------------------------------------------------------------------
bool EventStore_LogCeremonyCommandState(string commandId, ENUM_CEREMONY_COMMAND_TYPE commandType,
                                          ENUM_CEREMONY_COMMAND_STATE fromState, ENUM_CEREMONY_COMMAND_STATE toState,
                                          string reason, string executionRequestId = "", string extraJson = "")
{
   string extra = "";
   extra += "\"command_id\":\""            + EventSerializer_Escape(commandId) + "\",";
   extra += "\"command_type\":\""          + EventSerializer_Escape(CeremonyCommandType_ToString(commandType)) + "\",";
   extra += "\"from_state\":\""            + EventSerializer_Escape(CeremonyCommandState_ToString(fromState)) + "\",";
   extra += "\"to_state\":\""              + EventSerializer_Escape(CeremonyCommandState_ToString(toState)) + "\",";
   extra += "\"reason\":\""                + EventSerializer_Escape(reason) + "\",";
   extra += "\"execution_request_id\":\""  + EventSerializer_Escape(executionRequestId) + "\"";
   if(extraJson != "")
      extra += "," + extraJson;

   bool ok = EventStore_LogSystem(EventTypeToString(EVENT_TYPE_CEREMONY_COMMAND_STATE_CHANGED),
                                    "ceremony command state changed", extra);
   if(ok)
   {
      int idx = CeremonyCommandRegistry_FindIndex(commandId);
      if(idx < 0)
      {
         idx = ArraySize(g_CeremonyCommandRegistry);
         ArrayResize(g_CeremonyCommandRegistry, idx + 1);
         g_CeremonyCommandRegistry[idx].command_id = commandId;
         g_CeremonyCommandRegistry[idx].command_type = commandType;
         g_CeremonyCommandRegistry[idx].execution_request_id = "";
      }
      g_CeremonyCommandRegistry[idx].current_state = toState;
      if(executionRequestId != "")
         g_CeremonyCommandRegistry[idx].execution_request_id = executionRequestId;
   }
   return ok;
}

//---------------------------------------------------------------------
// Claim orchestration - the only sanctioned way the mailbox_status ever
// becomes CLAIMED (RA-31.2 condition 1's hard invariant: the durable
// COMMAND_RECEIVED append must succeed FIRST).
//---------------------------------------------------------------------

// Call every OnTick. Cheap no-op (one mailbox file read) when there is
// nothing new. Returns true and populates outCommand only when a fresh
// command was just claimed (accepted) this call - the caller is then
// responsible for actually running it (CEREMONY_IN_PROGRESS onward) and
// for eventually calling CeremonyCommand_Complete()/CeremonyCommand_Fail().
bool CeremonyCommand_TryClaim(string eaEventStoreFileName, double eaCurrentNonce, CeremonyCommand &outCommand)
{
   CeremonyCommand_Init(outCommand);

   CeremonyCommand mb;
   if(!CeremonyCommandMailbox_Read(mb))
      return false; // no mailbox file yet

   if(mb.mailbox_status != CEREMONY_MAILBOX_STATUS_PENDING)
      return false; // nothing new - already claimed or terminal

   // RA-31.2 condition 1/C: a command_id already known (in ANY state) is
   // never re-executed - covers a duplicate signal or a restart re-
   // reading a stale pending mailbox after a crash.
   if(CeremonyCommandRegistry_IsKnown(mb.command_id))
      return false;

   string rejectReason = "";
   if(mb.expected_ea_binding_nonce != eaCurrentNonce)
      rejectReason = "stale_ea_binding_nonce";
   else if(mb.expected_eventstore_filename != eaEventStoreFileName)
      rejectReason = "eventstore_filename_mismatch";
   else if(mb.command_type == CEREMONY_COMMAND_TYPE_UNKNOWN)
      rejectReason = "unknown_command_type";

   if(rejectReason != "")
   {
      // Durable record of the rejection comes before the mailbox update -
      // the mailbox is never truth on its own (RA-31.2 condition 2).
      EventStore_LogCeremonyCommandState(mb.command_id, mb.command_type,
                                          CEREMONY_STATE_UNKNOWN, CEREMONY_STATE_COMMAND_REJECTED, rejectReason);
      mb.mailbox_status = CEREMONY_MAILBOX_STATUS_REJECTED;
      mb.result_reason_code = rejectReason;
      mb.result_message = "RA-31 command rejected: " + rejectReason;
      CeremonyCommandMailbox_Write(mb);
      return false;
   }

   // RA-31.1 point A / RA-31.2 condition 1's hard invariant: durable
   // claim first, mailbox CLAIMED only on success.
   string claimExtra = "\"expected_ea_binding_nonce\":" + CanonicalDouble(mb.expected_ea_binding_nonce);
   if(!EventStore_LogCeremonyCommandState(mb.command_id, mb.command_type,
                                           CEREMONY_STATE_UNKNOWN, CEREMONY_STATE_COMMAND_RECEIVED,
                                           "claimed", "", claimExtra))
      return false; // durable append failed - mailbox stays PENDING, retried next tick

   mb.mailbox_status = CEREMONY_MAILBOX_STATUS_CLAIMED;
   CeremonyCommandMailbox_Write(mb); // best-effort - the durable claim already happened, so even if this write is lost, CeremonyCommandRegistry_IsKnown() above still prevents re-execution

   outCommand = mb;
   return true;
}

// Called once a command's synchronous work is done successfully -
// CEREMONY_READY for RUN_C22_CEREMONY_FIXTURE, APPROVAL_RECORDED for
// GRANT_MANUAL_APPROVAL, or SUBMISSION_COMPLETE for SUBMIT_ORDER (the
// Script does not wait for the later, async OBSERVATION_COMPLETE - see
// file header). Durably logs the state, then marks the mailbox COMPLETE
// with the given result fields so the Script can read them and is free
// to issue its next command.
bool CeremonyCommand_Complete(CeremonyCommand &cmd, ENUM_CEREMONY_COMMAND_STATE fromState, ENUM_CEREMONY_COMMAND_STATE toState,
                                string reason, string executionRequestId)
{
   if(!EventStore_LogCeremonyCommandState(cmd.command_id, cmd.command_type, fromState, toState, reason, executionRequestId))
      return false;
   cmd.mailbox_status = CEREMONY_MAILBOX_STATUS_COMPLETE;
   cmd.result_reason_code = reason;
   CeremonyCommandMailbox_Write(cmd);
   return true;
}

// Called when a command fails at any point after claim.
void CeremonyCommand_Fail(CeremonyCommand &cmd, ENUM_CEREMONY_COMMAND_STATE fromState, string reason, string message)
{
   EventStore_LogCeremonyCommandState(cmd.command_id, cmd.command_type, fromState, CEREMONY_STATE_COMMAND_FAILED, reason);
   cmd.mailbox_status = CEREMONY_MAILBOX_STATUS_FAILED;
   cmd.result_reason_code = reason;
   cmd.result_message = message;
   CeremonyCommandMailbox_Write(cmd);
}

#endif // __MLQUANTAI_CEREMONYCOMMANDEVENTEMISSION_MQH__
