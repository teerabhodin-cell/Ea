//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_StateMachine.mqh                      |
//| The candidate lifecycle state machine. This is the enforcement   |
//| point for the rules the whole architecture depends on: a         |
//| candidate that reached EXECUTED/MERGED/REJECTED_*/EXPIRED can    |
//| never move again. Every module MUST go through                  |
//| StateMachine_Transition() instead of writing candidate.state     |
//| directly, or the guarantee "terminal means terminal" stops being |
//| true and the event log can no longer be trusted as an audit      |
//| trail.                                                            |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_STATEMACHINE_MQH__
#define __MLQUANTAI_STATEMACHINE_MQH__

enum ENUM_CANDIDATE_STATE
{
   CANDIDATE_CREATED,
   CANDIDATE_ROUTED_OUT,
   CANDIDATE_MERGED,
   CANDIDATE_REJECTED_BY_ARBITRATOR,
   CANDIDATE_REJECTED_BY_AI,
   CANDIDATE_REJECTED_BY_RISK,
   CANDIDATE_EXPIRED,
   CANDIDATE_SUBMITTED,
   CANDIDATE_EXECUTED,
   CANDIDATE_REJECTED_BY_BROKER,
   CANDIDATE_ERROR
};

string CandidateStateToString(ENUM_CANDIDATE_STATE s)
{
   switch(s)
   {
      case CANDIDATE_CREATED:                return "CREATED";
      case CANDIDATE_ROUTED_OUT:              return "ROUTED_OUT";
      case CANDIDATE_MERGED:                  return "MERGED";
      case CANDIDATE_REJECTED_BY_ARBITRATOR:  return "REJECTED_BY_ARBITRATOR";
      case CANDIDATE_REJECTED_BY_AI:          return "REJECTED_BY_AI";
      case CANDIDATE_REJECTED_BY_RISK:        return "REJECTED_BY_RISK";
      case CANDIDATE_EXPIRED:                 return "EXPIRED";
      case CANDIDATE_SUBMITTED:               return "SUBMITTED";
      case CANDIDATE_EXECUTED:                return "EXECUTED";
      case CANDIDATE_REJECTED_BY_BROKER:      return "REJECTED_BY_BROKER";
      case CANDIDATE_ERROR:                   return "ERROR";
   }
   return "UNKNOWN";
}

// Reverse of CandidateStateToString - used by EventSerializer when parsing
// a stored line back into a LifecycleEvent. An unrecognized/corrupted
// string maps to CANDIDATE_ERROR rather than silently defaulting to
// CREATED, so a malformed state string can never be mistaken for a real
// "freshly created" candidate during replay.
ENUM_CANDIDATE_STATE CandidateStateFromString(string s)
{
   if(s == "CREATED")                 return CANDIDATE_CREATED;
   if(s == "ROUTED_OUT")              return CANDIDATE_ROUTED_OUT;
   if(s == "MERGED")                  return CANDIDATE_MERGED;
   if(s == "REJECTED_BY_ARBITRATOR")  return CANDIDATE_REJECTED_BY_ARBITRATOR;
   if(s == "REJECTED_BY_AI")          return CANDIDATE_REJECTED_BY_AI;
   if(s == "REJECTED_BY_RISK")        return CANDIDATE_REJECTED_BY_RISK;
   if(s == "EXPIRED")                 return CANDIDATE_EXPIRED;
   if(s == "SUBMITTED")               return CANDIDATE_SUBMITTED;
   if(s == "EXECUTED")                return CANDIDATE_EXECUTED;
   if(s == "REJECTED_BY_BROKER")      return CANDIDATE_REJECTED_BY_BROKER;
   return CANDIDATE_ERROR;
}

// Terminal = no further transition is ever valid from this state.
bool StateMachine_IsTerminal(ENUM_CANDIDATE_STATE s)
{
   switch(s)
   {
      case CANDIDATE_ROUTED_OUT:
      case CANDIDATE_MERGED:
      case CANDIDATE_REJECTED_BY_ARBITRATOR:
      case CANDIDATE_REJECTED_BY_AI:
      case CANDIDATE_REJECTED_BY_RISK:
      case CANDIDATE_EXPIRED:
      case CANDIDATE_EXECUTED:
      case CANDIDATE_REJECTED_BY_BROKER:
      case CANDIDATE_ERROR:
         return true;
      default:
         return false; // CREATED, SUBMITTED are non-terminal
   }
}

// Encodes exactly the lifecycle tree from the spec:
//   CREATED    -> {ROUTED_OUT, MERGED, REJECTED_BY_ARBITRATOR,
//                  REJECTED_BY_AI, REJECTED_BY_RISK, EXPIRED, SUBMITTED}
//   SUBMITTED  -> {EXECUTED, REJECTED_BY_BROKER, ERROR}
//   everything else is a leaf: no outgoing transitions at all.
bool StateMachine_CanTransition(ENUM_CANDIDATE_STATE from, ENUM_CANDIDATE_STATE to)
{
   if(StateMachine_IsTerminal(from))
      return false; // e.g. EXECUTED -> CREATED, MERGED -> SUBMITTED: always rejected

   if(from == CANDIDATE_CREATED)
   {
      return to == CANDIDATE_ROUTED_OUT
          || to == CANDIDATE_MERGED
          || to == CANDIDATE_REJECTED_BY_ARBITRATOR
          || to == CANDIDATE_REJECTED_BY_AI
          || to == CANDIDATE_REJECTED_BY_RISK
          || to == CANDIDATE_EXPIRED
          || to == CANDIDATE_SUBMITTED;
   }

   if(from == CANDIDATE_SUBMITTED)
   {
      return to == CANDIDATE_EXECUTED
          || to == CANDIDATE_REJECTED_BY_BROKER
          || to == CANDIDATE_ERROR;
   }

   return false;
}

// Applies the transition if (and only if) it's legal, returns success/failure
// so callers can distinguish "moved" from "rejected, state left untouched" -
// never mutate candidate.state directly, always go through this.
bool StateMachine_Transition(ENUM_CANDIDATE_STATE &state, ENUM_CANDIDATE_STATE to)
{
   if(!StateMachine_CanTransition(state, to))
      return false;
   state = to;
   return true;
}

#endif // __MLQUANTAI_STATEMACHINE_MQH__
