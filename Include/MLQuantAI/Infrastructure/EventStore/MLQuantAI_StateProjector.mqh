//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_StateProjector.mqh|
//| Folds a stream of LifecycleEvents into current candidate states.  |
//| This is the "replay reconstructs state" half of event sourcing -  |
//| and re-validates every transition against the SAME state machine  |
//| rules used at write time, so replay independently catches          |
//| corruption/tampering that write-time checks wouldn't (e.g. a hand-|
//| edited or bit-flipped store file), not just parse it back.        |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_STATEPROJECTOR_MQH__
#define __MLQUANTAI_STATEPROJECTOR_MQH__

#include "MLQuantAI_LifecycleEvent.mqh"
#include "MLQuantAI_SystemEvent.mqh"
#include "../../Core/MLQuantAI_RuntimeState.mqh"

struct ProjectedCandidate
{
   string                candidate_id;
   ENUM_CANDIDATE_STATE  state;
   int                   strategy_id;
   string                root_event_id;
   string                correlation_id;
};

ProjectedCandidate g_Proj_Candidates[];
int                g_Proj_Count = 0;
RuntimeState       g_Proj_RuntimeState;

void StateProjector_Reset()
{
   ArrayResize(g_Proj_Candidates, 0);
   g_Proj_Count = 0;
   RuntimeState_Init(g_Proj_RuntimeState);
}

int StateProjector_FindIndex(string candidateId)
{
   for(int i = 0; i < g_Proj_Count; i++)
      if(g_Proj_Candidates[i].candidate_id == candidateId)
         return i;
   return -1;
}

bool StateProjector_TryGetState(string candidateId, ENUM_CANDIDATE_STATE &outState)
{
   int idx = StateProjector_FindIndex(candidateId);
   if(idx < 0) return false;
   outState = g_Proj_Candidates[idx].state;
   return true;
}

// C3.8.0: read-only enumeration surface, mirroring the _Count()/_GetAt()
// pair every other sealed projection in this codebase already exposes
// (ExecutionRequestProjection, SubmissionOutcomeProjection,
// OrderAggregateRegistry, DeferredTransactionProcessor,
// TransactionDealRegistry). No behavior change to any other function in
// this file. Callers needing every (candidate_id, current_state) pair -
// e.g. C3.8.1's future submitted-candidate visibility diagnostic - use
// this instead of reaching into g_Proj_Candidates[]/g_Proj_Count
// directly.
int StateProjector_Count() { return g_Proj_Count; }

bool StateProjector_GetAt(int index, ProjectedCandidate &out)
{
   if(index < 0 || index >= g_Proj_Count) return false;
   out = g_Proj_Candidates[index];
   return true;
}

// Applies one lifecycle event to the projected state. Returns false (with
// a reason) if the event is inconsistent with everything replayed so
// far - callers (ReplayEngine) treat that as a corruption finding, not a
// crash: replay must always finish and report, never throw away partial
// results.
bool StateProjector_Apply(const LifecycleEvent &e, string &outError)
{
   outError = "";
   g_Proj_RuntimeState.last_sequence_number = e.base.sequence_number;
   int idx = StateProjector_FindIndex(e.candidate_id);

   bool isGenesis = (e.from_state == CANDIDATE_CREATED && e.to_state == CANDIDATE_CREATED);

   if(idx < 0)
   {
      if(!isGenesis)
      {
         outError = StringFormat("candidate %s: first event seen is not a CREATED genesis event (from=%s to=%s)",
                                  e.candidate_id, CandidateStateToString(e.from_state), CandidateStateToString(e.to_state));
         return false;
      }
      ArrayResize(g_Proj_Candidates, g_Proj_Count + 1);
      g_Proj_Candidates[g_Proj_Count].candidate_id   = e.candidate_id;
      g_Proj_Candidates[g_Proj_Count].state          = CANDIDATE_CREATED;
      g_Proj_Candidates[g_Proj_Count].strategy_id    = e.strategy_id;
      g_Proj_Candidates[g_Proj_Count].root_event_id  = e.root_event_id;
      g_Proj_Candidates[g_Proj_Count].correlation_id = e.correlation_id;
      g_Proj_Count++;
      g_Proj_RuntimeState.candidates_created++;
      return true;
   }

   if(isGenesis)
   {
      outError = StringFormat("candidate %s: duplicate CREATED genesis event", e.candidate_id);
      return false;
   }

   ENUM_CANDIDATE_STATE current = g_Proj_Candidates[idx].state;
   if(current != e.from_state)
   {
      outError = StringFormat("candidate %s: event claims from_state=%s but projector has %s - store is inconsistent",
                               e.candidate_id, CandidateStateToString(e.from_state), CandidateStateToString(current));
      return false;
   }
   if(!StateMachine_CanTransition(current, e.to_state))
   {
      outError = StringFormat("candidate %s: illegal transition %s -> %s replayed from store",
                               e.candidate_id, CandidateStateToString(current), CandidateStateToString(e.to_state));
      return false;
   }

   g_Proj_Candidates[idx].state = e.to_state;
   if(e.correlation_id != "")
      g_Proj_Candidates[idx].correlation_id = e.correlation_id;

   switch(e.to_state)
   {
      case CANDIDATE_SUBMITTED:              g_Proj_RuntimeState.candidates_submitted++; break;
      case CANDIDATE_EXECUTED:               g_Proj_RuntimeState.candidates_executed++;  break;
      case CANDIDATE_MERGED:                 g_Proj_RuntimeState.candidates_merged++;    break;
      case CANDIDATE_EXPIRED:                g_Proj_RuntimeState.candidates_expired++;   break;
      case CANDIDATE_REJECTED_BY_ARBITRATOR:
      case CANDIDATE_REJECTED_BY_AI:
      case CANDIDATE_REJECTED_BY_RISK:
      case CANDIDATE_REJECTED_BY_BROKER:     g_Proj_RuntimeState.candidates_rejected++;  break;
      default: break;
   }

   return true;
}

// Folds SystemEvents into RuntimeState - session identity, session start
// time, and Safe Mode status all live here, not on any single candidate.
// Phase A only emits SYSTEM_STARTED/SAFE_MODE_ENGAGED/SAFE_MODE_CLEARED
// today (nothing produces SYSTEM_STOPPED-driven state changes beyond the
// log line itself); unrecognized event_type values are accepted as a
// no-op rather than an error, since SystemEvent is meant to grow new
// types over time without every old build's projector treating an
// unknown one as corruption.
bool StateProjector_ApplySystem(const SystemEvent &e, string &outError)
{
   outError = "";
   g_Proj_RuntimeState.last_sequence_number = e.base.sequence_number;

   if(e.base.event_type == "SYSTEM_STARTED")
   {
      g_Proj_RuntimeState.runtime_session_id = e.base.runtime_session_id;
      g_Proj_RuntimeState.session_start_time = e.base.ts;
   }
   else if(e.base.event_type == "SAFE_MODE_ENGAGED")
   {
      g_Proj_RuntimeState.safe_mode = true;
      g_Proj_RuntimeState.safe_mode_reason = e.message;
   }
   else if(e.base.event_type == "SAFE_MODE_CLEARED")
   {
      g_Proj_RuntimeState.safe_mode = false;
      g_Proj_RuntimeState.safe_mode_reason = "";
   }
   return true;
}

#endif // __MLQUANTAI_STATEPROJECTOR_MQH__
