//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_EventStore.mqh   |
//| Append-only file I/O. Owns the session id and the per-session      |
//| sequence counter, and is the ONLY thing that writes lines - every |
//| other module builds an event struct and calls one of the          |
//| EventStore_Append* functions here.                                 |
//|                                                                    |
//| File handle is opened ONCE (EventStore_Open) and kept open for    |
//| the caller's lifetime; every append calls FileFlush() immediately |
//| (the spec requires durability over raw throughput here - unlike   |
//| QuantixFlowEA's bug, which was reopening the file on every write, |
//| flushing an already-open handle is cheap and doesn't reintroduce  |
//| that problem).                                                     |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EVENTSTORE_MQH__
#define __MLQUANTAI_EVENTSTORE_MQH__

#include "MLQuantAI_EventSerializer.mqh"
#include "MLQuantAI_SafeModeState.mqh"
#include "../../Core/MLQuantAI_Ids.mqh"
#include "../../Core/MLQuantAI_TradeCandidate.mqh"
#include "../../Logging/MLQuantAI_SystemLogger.mqh"

int    g_EventStore_Handle    = INVALID_HANDLE;
string g_EventStore_SessionId = "";
long   g_EventStore_NextSeq   = 1;

bool EventStore_Open(string fileName)
{
   g_EventStore_Handle = FileOpen(fileName, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(g_EventStore_Handle == INVALID_HANDLE)
   {
      LogWarn("EventStore: failed to open '" + fileName + "', err=" + IntegerToString(GetLastError()));
      return false;
   }
   FileSeek(g_EventStore_Handle, 0, SEEK_END);
   g_EventStore_SessionId = Ids_NewRuntimeSessionId();
   g_EventStore_NextSeq = 1;
   return true;
}

void EventStore_Close()
{
   if(g_EventStore_Handle != INVALID_HANDLE)
   {
      FileClose(g_EventStore_Handle);
      g_EventStore_Handle = INVALID_HANDLE;
   }
}

string EventStore_SessionId() { return g_EventStore_SessionId; }

long EventStore_NextSequence()
{
   long seq = g_EventStore_NextSeq;
   g_EventStore_NextSeq++;
   return seq;
}

string EventStore_BuildLogEventId(long seq)
{
   return g_EventStore_SessionId + "#" + IntegerToString(seq);
}

// Returns false if the write did not durably succeed. Callers MUST NOT
// commit any in-memory state change (candidate.state, etc.) unless this
// returns true - the event log is the source of truth, so in-memory state
// must never get ahead of what's actually been written and flushed.
bool EventStore_WriteLine(string jsonLine)
{
   if(g_EventStore_Handle == INVALID_HANDLE) return false;

   ResetLastError();
   uint written = FileWriteString(g_EventStore_Handle, jsonLine + "\r\n");
   int err = GetLastError();
   if(written == 0 || err != 0)
   {
      LogError(StringFormat("EventStore: FileWriteString failed (written=%d, err=%d)", written, err));
      return false;
   }

   ResetLastError();
   FileFlush(g_EventStore_Handle);
   err = GetLastError();
   if(err != 0)
   {
      LogError(StringFormat("EventStore: FileFlush failed, err=%d", err));
      return false;
   }
   return true;
}

//---------------------------------------------------------------------
// Typed append helpers - fill in the envelope (session/seq/log_event_id/
// ts) and write. Callers only need to fill in the category-specific
// fields before calling. All return false (write not durable) if the
// underlying FileWriteString/FileFlush failed.
//---------------------------------------------------------------------

bool EventStore_AppendLifecycle(LifecycleEvent &e)
{
   e.base.sequence_number    = EventStore_NextSequence();
   e.base.runtime_session_id = g_EventStore_SessionId;
   e.base.log_event_id       = EventStore_BuildLogEventId(e.base.sequence_number);
   e.base.ts                 = TimeCurrent();
   e.base.category            = EVENT_CAT_LIFECYCLE;
   return EventStore_WriteLine(EventSerializer_ToJson(e));
}

bool EventStore_AppendExecution(ExecutionEvent &e)
{
   e.base.sequence_number    = EventStore_NextSequence();
   e.base.runtime_session_id = g_EventStore_SessionId;
   e.base.log_event_id       = EventStore_BuildLogEventId(e.base.sequence_number);
   e.base.ts                 = TimeCurrent();
   e.base.category            = EVENT_CAT_EXECUTION;
   return EventStore_WriteLine(EventSerializer_ToJson(e));
}

bool EventStore_AppendSystem(SystemEvent &e)
{
   e.base.sequence_number    = EventStore_NextSequence();
   e.base.runtime_session_id = g_EventStore_SessionId;
   e.base.log_event_id       = EventStore_BuildLogEventId(e.base.sequence_number);
   e.base.ts                 = TimeCurrent();
   e.base.category            = EVENT_CAT_SYSTEM;
   return EventStore_WriteLine(EventSerializer_ToJson(e));
}

// Convenience: builds + appends a system event in one call.
bool EventStore_LogSystem(string eventType, string message, string extraJson="")
{
   SystemEvent e;
   SystemEvent_Init(e);
   e.base.event_type = eventType;
   e.message = message;
   e.extra_json = extraJson;
   return EventStore_AppendSystem(e);
}

// Logs the candidate's birth: a CANDIDATE_CREATED event with
// from_state == to_state == CREATED, marking the point a candidate_id
// first exists. Call this once, right after building the candidate and
// before any EventStore_LogTransition call - the StateProjector uses this
// exact from==to==CREATED shape to distinguish "this candidate is being
// born" from "this candidate looped back to CREATED" (which the state
// machine itself never allows anyway). Returns false if the birth event
// could not be durably written - callers should treat the candidate as
// not safely usable in that case.
bool EventStore_LogCandidateCreated(const TradeCandidate &c)
{
   LifecycleEvent e;
   LifecycleEvent_Init(e);
   e.candidate_id     = c.candidate_id;
   e.root_event_id    = c.root_event_id;
   e.correlation_id   = c.correlation_id;
   e.strategy_id       = c.strategy_id;
   e.from_state         = CANDIDATE_CREATED;
   e.to_state           = CANDIDATE_CREATED;
   e.reason             = REASON_NONE;
   e.base.event_type   = EventTypeToString(EVENT_TYPE_CANDIDATE_CREATED);
   if(!EventStore_AppendLifecycle(e))
   {
      SafeMode_Trip(StringFormat("failed to durably write CANDIDATE_CREATED for %s", c.candidate_id));
      return false;
   }
   return true;
}

// Validates the transition, WRITES the event, and only commits the
// in-memory state change (c.state/c.last_reason) after the write is
// confirmed durable. This ordering is deliberate and load-bearing: if the
// write fails, the candidate MUST stay at its old state in memory,
// because the event log - not the in-memory struct - is what replay and
// every other consumer treats as the truth. A candidate that silently
// "moved on" in memory while the log never recorded it would make replay
// diverge from what actually happened.
bool EventStore_LogTransition(TradeCandidate &c, ENUM_CANDIDATE_STATE to, ENUM_REASON_CODE reason, string extraJson="")
{
   ENUM_CANDIDATE_STATE from = c.state;
   if(!StateMachine_CanTransition(from, to))
   {
      LogWarn(StringFormat("EventStore: illegal candidate transition blocked: %s  %s -> %s",
              c.candidate_id, CandidateStateToString(from), CandidateStateToString(to)));
      return false;
   }

   LifecycleEvent e;
   LifecycleEvent_Init(e);
   e.candidate_id   = c.candidate_id;
   e.root_event_id  = c.root_event_id;
   e.correlation_id = c.correlation_id;
   e.strategy_id    = c.strategy_id;
   e.from_state      = from;
   e.to_state        = to;
   e.reason          = reason;
   e.extra_json       = extraJson;
   e.base.event_type = EventTypeToString(EventTypeForCandidateState(to));

   if(!EventStore_AppendLifecycle(e))
   {
      SafeMode_Trip(StringFormat("failed to durably write lifecycle event for %s (%s -> %s) - "
                                  "in-memory state left at %s, NOT advanced to %s",
                                  c.candidate_id, CandidateStateToString(from), CandidateStateToString(to),
                                  CandidateStateToString(from), CandidateStateToString(to)));
      return false;
   }

   // Only now, with the event durably on disk, commit the in-memory change.
   c.state = to;
   c.last_reason = reason;
   return true;
}

//---------------------------------------------------------------------
// Read-back - for the Validator/ReplayEngine, which need every raw line
// in the file, not just the ones this session appended.
//---------------------------------------------------------------------

// Reads every line from fileName into outLines[]. Opens its own
// short-lived handle (separate from g_EventStore_Handle) so this can be
// called on a store this same run has open for writing, or on a totally
// different file (e.g. a corrupted copy in EventStoreRecoveryTest)
// without disturbing the live write handle.
int EventStore_ReadAllLines(string fileName, string &outLines[])
{
   ArrayResize(outLines, 0);
   int handle = FileOpen(fileName, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle == INVALID_HANDLE)
      return 0;

   int count = 0;
   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      if(line == "" && FileIsEnding(handle)) break; // trailing blank read at EOF, not a real line
      ArrayResize(outLines, count+1);
      outLines[count] = line;
      count++;
   }
   FileClose(handle);
   return count;
}

#endif // __MLQUANTAI_EVENTSTORE_MQH__
