//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/                             |
//| MLQuantAI_C62SessionEstablishment.mqh                               |
//| §6.2 Evidence-Gate Design Contract Rev.8 (QA-frozen DESIGN FREEZE,   |
//| Docs/PhaseC_C5_2_Section6_2_EvidenceGateDesignContract.md §7.2): the   |
//| OnInit establishment contract - a proactively-written session marker,  |
//| MLQuantAI_SessionActive.flag, plus the durable EVENT_TYPE_EA_SESSION_    |
//| STARTED restart-evidence event P4b reads. Both are the "written at         |
//| health, not reactively at failure" evidence this checkpoint's whole          |
//| chain of design revisions converged on: an OMISSION (not clearing the         |
//| marker) is what signals an unclean prior session, never a NEW write             |
//| attempted because of an incident.                                                 |
//|                                                                                       |
//| Same out-of-band, plain-file-I/O channel as the §7.1 SafeMode quarantine              |
//| witness (MLQuantAI_SafeModeState.mqh) - outside the EventStore JSONL                    |
//| entirely.                                                                                  |
//|                                                                                                |
//| Frozen ordering (§7.2): marker check -> (if absent) marker creation ->                          |
//| session-started event append, strictly in that order, each step gating                            |
//| the next. ANY of the three failing suspends §6.2 evaluation capability                              |
//| for the WHOLE session (not just a single evaluation attempt) - never                                  |
//| defaults to "probably fine, proceed".                                                                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_C62SESSIONESTABLISHMENT_MQH__
#define __MLQUANTAI_C62SESSIONESTABLISHMENT_MQH__

#include "../../Core/MLQuantAI_Enums.mqh"
#include "MLQuantAI_EventStore.mqh"
#include "MLQuantAI_RolloutStageObservationWindow.mqh"

#define MLQUANTAI_SESSION_ACTIVE_FILENAME "MLQuantAI_SessionActive.flag"

// §7.2 (this revision's fix): tri-state marker-existence check. An
// inability to determine existence (CHECK_FAILED) must NEVER be collapsed
// into CONFIRMED_ABSENT - "cannot verify clean" is treated identically to
// "found unclean" (§7.2's own frozen rule). Implemented via FileIsExist()
// + GetLastError(): FileIsExist() returning false with no error (or the
// well-known ERR_FILE_NOT_EXIST) means genuinely absent; any OTHER nonzero
// error means the check itself could not be trusted.
enum ENUM_MARKER_CHECK_RESULT
{
   MARKER_CONFIRMED_ABSENT,    // checked successfully, genuinely not there
   MARKER_CONFIRMED_PRESENT,   // checked successfully, IS there
   MARKER_CHECK_FAILED         // could not determine either way
};

ENUM_MARKER_CHECK_RESULT CheckSessionActiveMarker()
{
   ResetLastError();
   bool exists = FileIsExist(MLQUANTAI_SESSION_ACTIVE_FILENAME, FILE_COMMON);
   int err = GetLastError();

   if(exists)
      return MARKER_CONFIRMED_PRESENT;

   // FileIsExist() returned false. err==0 or ERR_FILE_NOT_EXIST (5019) is
   // the ordinary "genuinely not there" case; any other nonzero error
   // means the check itself is not trustworthy.
   if(err == 0 || err == 5019)
      return MARKER_CONFIRMED_ABSENT;

   return MARKER_CHECK_FAILED;
}

// Writes the marker fresh, containing this session's own
// runtime_session_id (diagnostic content only - existence, not content, is
// what §7.2's logic reads). Returns false if the write did not succeed.
bool WriteSessionActiveMarker()
{
   ResetLastError();
   int handle = FileOpen(MLQUANTAI_SESSION_ACTIVE_FILENAME, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return false;
   uint written = FileWriteString(handle, "runtime_session_id=" + EventStore_SessionId() + "\r\n");
   FileClose(handle);
   return written > 0;
}

// §7.2's OnDeinit half: clears the marker ONLY on an ordinary shutdown
// (g_C62IntegrityFatalHalt == false). Called from MLQuantAI.mq5's
// OnDeinit(). A failed delete is only logged - the marker being left
// behind on a delete failure is itself indistinguishable from (and just
// as safely handled as) an unclean shutdown by the NEXT OnInit's own
// CheckSessionActiveMarker() call - fail-closed either way, never a
// silent loss of the safety property.
void C62_ClearSessionActiveMarkerOnCleanShutdown()
{
   if(g_C62IntegrityFatalHalt)
      return; // §7.1/§7.2: deliberately NOT cleared - this is the signal the next OnInit reads.

   ResetLastError();
   if(!FileDelete(MLQUANTAI_SESSION_ACTIVE_FILENAME, FILE_COMMON))
      LogWarn("C5.2/§6.2: MLQuantAI_SessionActive.flag delete failed on clean shutdown, err=" + IntegerToString(GetLastError()) +
              " - the next OnInit will read this as an unclean prior session and suspend §6.2 evaluation until manually cleared.");
}

enum ENUM_C62_SESSION_ESTABLISHMENT_RESULT
{
   C62_SESSION_NOT_YET_ESTABLISHED,             // default before OnInit's own call ever runs - treated as suspended, defensive only
   C62_SESSION_ESTABLISHED,                     // all 3 steps succeeded
   C62_SESSION_SUSPENDED_UNCLEAN_PRIOR,         // marker check: CONFIRMED_PRESENT
   C62_SESSION_SUSPENDED_MARKER_CHECK_FAILED,   // marker check: could not determine
   C62_SESSION_SUSPENDED_MARKER_CREATE_FAILED,  // marker was absent, but creating it failed
   C62_SESSION_SUSPENDED_SESSION_EVENT_FAILED   // marker OK, but EVENT_TYPE_EA_SESSION_STARTED append failed
};

string C62SessionEstablishmentResultToString(ENUM_C62_SESSION_ESTABLISHMENT_RESULT r)
{
   switch(r)
   {
      case C62_SESSION_ESTABLISHED:                    return "session_established";
      case C62_SESSION_SUSPENDED_UNCLEAN_PRIOR:         return "evaluation_suspended_unclean_prior_session";
      case C62_SESSION_SUSPENDED_MARKER_CHECK_FAILED:   return "evaluation_suspended_marker_check_failed";
      case C62_SESSION_SUSPENDED_MARKER_CREATE_FAILED:  return "evaluation_suspended_marker_create_failed";
      case C62_SESSION_SUSPENDED_SESSION_EVENT_FAILED:  return "evaluation_suspended_session_event_failed";
   }
   return "not_yet_established";
}

// Module-global result of the ONE OnInit-time establishment call this
// session ever makes - RolloutGateReadiness_Evaluate reads this later,
// possibly many ticks/timers afterward, to decide whether §6.2 evaluation
// capability exists at all THIS session. Defaults to the defensive
// NOT_YET_ESTABLISHED sentinel (treated identically to a SUSPENDED_* value
// by anything that reads it) so a (structurally impossible, but never
// assumed) call to the evaluator before OnInit ever runs still fails
// closed.
ENUM_C62_SESSION_ESTABLISHMENT_RESULT g_C62SessionEstablishmentResult = C62_SESSION_NOT_YET_ESTABLISHED;

bool C62SessionEstablishmentResult_PermitsEvaluation(ENUM_C62_SESSION_ESTABLISHMENT_RESULT r)
{
   return r == C62_SESSION_ESTABLISHED;
}

// Called from OnInit, strictly AFTER EventStore_Open()/replay already
// succeeded - the filesystem is provably healthy right here. Stores its
// own result into g_C62SessionEstablishmentResult (for
// RolloutGateReadiness_Evaluate to read later) and also returns it.
ENUM_C62_SESSION_ESTABLISHMENT_RESULT C62_EstablishSession()
{
   ENUM_MARKER_CHECK_RESULT checkResult = CheckSessionActiveMarker();

   if(checkResult == MARKER_CONFIRMED_PRESENT)
   {
      g_C62SessionEstablishmentResult = C62_SESSION_SUSPENDED_UNCLEAN_PRIOR;
      return g_C62SessionEstablishmentResult;
   }
   if(checkResult == MARKER_CHECK_FAILED)
   {
      g_C62SessionEstablishmentResult = C62_SESSION_SUSPENDED_MARKER_CHECK_FAILED;
      return g_C62SessionEstablishmentResult;
   }

   // checkResult == MARKER_CONFIRMED_ABSENT - create it.
   if(!WriteSessionActiveMarker())
   {
      g_C62SessionEstablishmentResult = C62_SESSION_SUSPENDED_MARKER_CREATE_FAILED;
      return g_C62SessionEstablishmentResult;
   }

   // Durable restart-evidence event (§2/P4b) - a NEW, dedicated event type
   // (QA's explicit Implementation Authorization decision, 2026-09-17: not
   // a repurposing of the pre-existing EVENT_TYPE_SYSTEM_STARTED).
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EA_SESSION_STARTED), "EA session established (§6.2 evidence marker)"))
   {
      g_C62SessionEstablishmentResult = C62_SESSION_SUSPENDED_SESSION_EVENT_FAILED;
      return g_C62SessionEstablishmentResult;
   }

   g_C62SessionEstablishmentResult = C62_SESSION_ESTABLISHED;
   return g_C62SessionEstablishmentResult;
}

// §6.2/P4c (Rev.8): "no durable Safe Mode engagement in-window" is a
// HISTORICAL claim (did it EVER engage during this window), not a
// "currently engaged" claim - deliberately NOT the same "latest wins"
// pattern KillSwitchProjection_ReplayActive uses. A SAFE_MODE_ENGAGED line
// anywhere strictly after windowStartIndex sets outEverEngaged=true
// regardless of any later SAFE_MODE_CLEARED in the same window - an
// episode that happened and was later cleared still happened.
void SafeModeProjection_ReplayEngagedDuringWindow(const string &lines[], int windowStartIndex, bool &outEverEngaged)
{
   outEverEngaged = false;
   string engagedType = EventTypeToString(EVENT_TYPE_SAFE_MODE_ENGAGED);

   for(int i = windowStartIndex + 1; i < ArraySize(lines); i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != engagedType) continue;
      outEverEngaged = true;
      return;
   }
}

// §6.2/P4c: the out-of-band quarantine witness (§7.1) existing at all,
// checked unconditionally - regardless of what the EventStore replay
// shows. There is no code path in which this file's existence is
// compatible with an ALLOW verdict.
bool SafeModeQuarantineWitness_Exists()
{
   ResetLastError();
   return FileIsExist(MLQUANTAI_SAFEMODE_WITNESS_FILENAME, FILE_COMMON);
}

#endif // __MLQUANTAI_C62SESSIONESTABLISHMENT_MQH__
