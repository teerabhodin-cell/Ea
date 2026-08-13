//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_TradeCandidate.mqh                    |
//| What a strategy module hands back to the pool. Strategies fill   |
//| this in and return it - they never call CTrade themselves, and   |
//| they never set .state directly (see MLQuantAI_StateMachine.mqh - |
//| all state changes go through StateMachine_Transition()).          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_TRADECANDIDATE_MQH__
#define __MLQUANTAI_TRADECANDIDATE_MQH__

#include "MLQuantAI_Enums.mqh"
#include "MLQuantAI_StateMachine.mqh"
#include "MLQuantAI_ReasonCodes.mqh"

struct TradeCandidate
{
   // identity / lineage
   string                 candidate_id;
   string                 root_event_id;       // shared across candidates seeing the same market event
   string                 correlation_id;       // set once submitted; ties to order/position events
   string                 parent_candidate_ids; // comma-joined, non-empty only for merged candidates

   int                    strategy_id;
   string                 strategy_name;
   string                 strategy_version;

   ENUM_SIGNAL_DIRECTION  direction;

   double                 score;           // 0..100, raw strategy confidence
   double                 confidence;      // 0..1, filled in during arbitration

   double                 entry;
   double                 sl;
   double                 tp;
   double                 rr;

   double                 atr;
   double                 stop_distance;   // price units, always positive

   ENUM_MARKET_REGIME     compatible_regime;
   string                 regime_rules_version; // regime rules version active when this candidate was created

   bool                   has_liquidity_sweep;
   bool                   has_mss;
   bool                   has_fvg;
   bool                   has_order_block;
   bool                   in_killzone;
   bool                   news_risk;

   datetime               signal_time;
   datetime               expiry_time;

   ENUM_CANDIDATE_STATE   state;
   ENUM_REASON_CODE       last_reason;
};

void TradeCandidate_Init(TradeCandidate &c)
{
   c.candidate_id = "";
   c.root_event_id = "";
   c.correlation_id = "";
   c.parent_candidate_ids = "";

   c.strategy_id = -1;
   c.strategy_name = "";
   c.strategy_version = "";

   c.direction = SIGNAL_NONE;
   c.score = 0;
   c.confidence = 0;
   c.entry = 0; c.sl = 0; c.tp = 0; c.rr = 0;
   c.atr = 0; c.stop_distance = 0;
   c.compatible_regime = REGIME_TRANSITION;
   c.regime_rules_version = "";

   c.has_liquidity_sweep = false;
   c.has_mss = false;
   c.has_fvg = false;
   c.has_order_block = false;
   c.in_killzone = false;
   c.news_risk = false;

   c.signal_time = 0;
   c.expiry_time = 0;

   c.state = CANDIDATE_CREATED;
   c.last_reason = REASON_NONE;
}

// The only place candidate.state should ever be assigned outside of
// TradeCandidate_Init. Returns false (and leaves the candidate untouched)
// if the transition is illegal - callers MUST check this, an ignored false
// here is exactly the "EXECUTED -> CREATED" class of bug the state machine
// exists to catch.
bool TradeCandidate_Transition(TradeCandidate &c, ENUM_CANDIDATE_STATE to, ENUM_REASON_CODE reason)
{
   if(!StateMachine_Transition(c.state, to))
      return false;
   c.last_reason = reason;
   return true;
}

// Maps a candidate state to its ENUM_EVENT_TYPE - one per state, used when
// logging a lifecycle transition so the event_type string always comes
// from the enum (EventTypeToString) instead of ad-hoc string
// concatenation scattered across callers.
ENUM_EVENT_TYPE EventTypeForCandidateState(ENUM_CANDIDATE_STATE s)
{
   switch(s)
   {
      case CANDIDATE_CREATED:                return EVENT_TYPE_CANDIDATE_CREATED;
      case CANDIDATE_ROUTED_OUT:              return EVENT_TYPE_CANDIDATE_ROUTED_OUT;
      case CANDIDATE_MERGED:                  return EVENT_TYPE_CANDIDATE_MERGED;
      case CANDIDATE_REJECTED_BY_ARBITRATOR:  return EVENT_TYPE_CANDIDATE_REJECTED_BY_ARBITRATOR;
      case CANDIDATE_REJECTED_BY_AI:          return EVENT_TYPE_CANDIDATE_REJECTED_BY_AI;
      case CANDIDATE_REJECTED_BY_RISK:        return EVENT_TYPE_CANDIDATE_REJECTED_BY_RISK;
      case CANDIDATE_EXPIRED:                 return EVENT_TYPE_CANDIDATE_EXPIRED;
      case CANDIDATE_SUBMITTED:               return EVENT_TYPE_CANDIDATE_SUBMITTED;
      case CANDIDATE_EXECUTED:                return EVENT_TYPE_CANDIDATE_EXECUTED;
      case CANDIDATE_REJECTED_BY_BROKER:      return EVENT_TYPE_CANDIDATE_REJECTED_BY_BROKER;
      case CANDIDATE_ERROR:                   return EVENT_TYPE_CANDIDATE_ERROR;
   }
   return EVENT_TYPE_UNKNOWN;
}

#endif // __MLQUANTAI_TRADECANDIDATE_MQH__
