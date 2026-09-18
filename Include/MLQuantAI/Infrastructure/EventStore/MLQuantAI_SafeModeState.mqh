//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_SafeModeState.mqh|
//| The Safe Mode flag itself, split out from EventStoreHealth.mqh so |
//| EventStore.mqh can trip it directly on a durable-write failure    |
//| without creating a circular include (EventStore -> Health ->      |
//| Validator -> EventStore). This file still has NO #include on       |
//| MLQuantAI_EventStore.mqh - the §6.2 amendment below CALLS             |
//| EventStore_LogSystem()/references EVENT_TYPE_SAFE_MODE_ENGAGED/       |
//| _CLEARED without including their defining files, the SAME               |
//| established pattern MLQuantAI_EventStoreHealth.mqh already uses           |
//| (its own EventStoreHealth_CheckFile() calls EventStore_LogSystem()          |
//| and reads g_EventStore_Handle with no EventStore.mqh #include at all)        |
//| - every real caller of SafeMode_Trip()/Clear() in this codebase already        |
//| has EventStore.mqh/MLQuantAI_Enums.mqh included transitively (confirmed          |
//| by inspection: no test or file includes MLQuantAI_SafeModeState.mqh in            |
//| isolation), so this stays safe without a literal circular #include.                |
//|                                                                                        |
//| §6.2 Evidence-Gate Design Contract Rev.8 (QA-frozen DESIGN FREEZE,                       |
//| Docs/PhaseC_C5_2_Section6_2_EvidenceGateDesignContract.md §7.1), Class 2,                   |
//| additive: SafeMode_Trip()/SafeMode_Clear() now ALSO attempt a best-effort,                    |
//| durable EVENT_TYPE_SAFE_MODE_ENGAGED/_CLEARED append (both event types                          |
//| already existed in MLQuantAI_Enums.mqh before this checkpoint - only the                          |
//| EMISSION is new). The in-memory flag mutation happens FIRST, exactly as                              |
//| before, completely unconditionally - every existing caller's visible                                   |
//| behavior is byte-for-byte unaffected by whether the durable append below                                |
//| succeeds. A durable-append failure on ENGAGE writes an out-of-band                                        |
//| quarantine witness file; if THAT also fails, this calls ExpertRemove()                                     |
//| after setting g_RolloutIntegrityFatalHalt=true - see §7.1/§7.2/§2.2 for the                                   |
//| full rationale (no further "write more evidence" layer can close a                                             |
//| double I/O failure; halting the process is what actually closes it).                                             |
//|                                                                                                                     |
//| §6.1 Rev.4 (QA-authorized rename, Implementation Authorization checkpoint):                                          |
//| g_C62IntegrityFatalHalt renamed to g_RolloutIntegrityFatalHalt - semantic                                              |
//| rename only, zero behavior change. The flag's own meaning ("a double I/O                                                |
//| failure already halted this session's durable-evidence integrity") is                                                    |
//| process-wide, not scoped to one checkpoint, so its identifier no longer                                                    |
//| carries a "C62"/"§6.2" label. Both §6.2's RolloutGateReadiness_Evaluate and                                                   |
//| §6.1's own crossing evaluator read this same flag.                                                                              |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_SAFEMODESTATE_MQH__
#define __MLQUANTAI_SAFEMODESTATE_MQH__

#include "../../Logging/MLQuantAI_SystemLogger.mqh"

#define MLQUANTAI_SAFEMODE_WITNESS_FILENAME "MLQuantAI_SafeMode_DurableWriteFailure.flag"

bool   g_SafeMode_Active = false;
string g_SafeMode_Reason = "";

// §6.2/§2.2 (Rev.8), renamed by §6.1/Rev.4 (semantic rename only): set to
// true ONLY at the one double-failure call site below, immediately before
// ExpertRemove() - never reset to false within a running process (a fresh
// process starts with a fresh, false, global). RolloutGateReadiness_Evaluate's
// own final gate (§6.2) and the §6.1 crossing evaluator's own final gate
// both read this directly, as an independent guarantee alongside
// ExpertRemove() itself (§2.2) - not relying solely on ExpertRemove()'s own
// call-stack semantics.
bool g_RolloutIntegrityFatalHalt = false;

// §6.2/§7.1 (Rev.8): best-effort, out-of-band (plain file I/O, outside the
// EventStore JSONL entirely) witness that a Safe Mode ENGAGE's own durable
// EventStore append failed. Written only on that specific failure path,
// consumed by RolloutGateReadiness_Evaluate's P4c check. A write failure
// here is only logged, never escalated on its own - escalation to
// ExpertRemove() happens only when BOTH the durable append and this
// witness write have failed for the same incident (see SafeMode_Trip()
// below).
bool SafeMode_WriteQuarantineWitness()
{
   ResetLastError();
   int handle = FileOpen(MLQUANTAI_SAFEMODE_WITNESS_FILENAME, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return false;
   uint written = FileWriteString(handle, "SAFE_MODE_ENGAGED durable EventStore append failed - see SystemLogger for the reason.\r\n");
   FileClose(handle);
   return written > 0;
}

// Safe Mode design (confirmed with the user): blocks new candidates only.
// It does NOT force-close existing positions - a corrupted/unwritable
// event store is a bookkeeping/audit-trail problem, not proof that open
// positions are in danger, and existing positions already carry their own
// broker-side SL/TP independent of our event store. Forcing closes off a
// read we already know might be wrong would be trading on bad
// information, which is worse than doing nothing new.
void SafeMode_Trip(string reason)
{
   g_SafeMode_Active = true;
   g_SafeMode_Reason = reason;
   LogError("SAFE MODE engaged: " + reason +
            " - new candidates are blocked. Existing positions are left alone (broker-side SL/TP still applies) "
            "until this is manually cleared.");

   // §6.2/§7.1 (Rev.8): best-effort durable record, attempted SECOND,
   // after the in-memory trip above. Every existing caller's own
   // behavior (which only ever depended on SafeMode_IsActive() reading
   // true immediately after this call) is unaffected by anything below.
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SAFE_MODE_ENGAGED), reason))
   {
      LogError("SAFE MODE: durable EVENT_TYPE_SAFE_MODE_ENGAGED append failed - writing out-of-band quarantine witness.");
      if(!SafeMode_WriteQuarantineWitness())
      {
         LogError("SAFE MODE: quarantine witness write ALSO failed - durable-evidence integrity cannot be established for "
                  "this incident. Halting the EA now (ExpertRemove) rather than risk a future evaluation seeing "
                  "clean-looking evidence.");
         g_RolloutIntegrityFatalHalt = true;
         ExpertRemove();
      }
   }
}

void SafeMode_Clear()
{
   g_SafeMode_Active = false;
   g_SafeMode_Reason = "";

   // §6.2/§7.1 (Rev.8): best-effort durable record, attempted SECOND. No
   // witness/escalation on this path (asymmetry, frozen) - a failed
   // CLEARED append leaves the durable log reading "still engaged",
   // which is a false-REJECT (over-conservative), never a false-ALLOW.
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SAFE_MODE_CLEARED), "safe mode cleared"))
      LogError("SAFE MODE: durable EVENT_TYPE_SAFE_MODE_CLEARED append failed - the durable log will still read "
               "as engaged until this succeeds; no further escalation on this path (frozen asymmetry, §7.1).");
}

bool   SafeMode_IsActive()           { return g_SafeMode_Active; }
string SafeMode_Reason()             { return g_SafeMode_Reason; }
bool   SafeMode_AllowNewCandidates() { return !g_SafeMode_Active; }

#endif // __MLQUANTAI_SAFEMODESTATE_MQH__
