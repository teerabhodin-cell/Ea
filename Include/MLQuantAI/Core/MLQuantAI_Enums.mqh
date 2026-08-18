//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_Enums.mqh                             |
//| Shared enums used across every module.                           |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ENUMS_MQH__
#define __MLQUANTAI_ENUMS_MQH__

enum ENUM_MARKET_REGIME
{
   REGIME_TREND_UP,
   REGIME_TREND_DOWN,
   REGIME_RANGE,
   REGIME_VOLATILITY_EXPANSION,
   REGIME_LIQUIDITY_SWEEP_SESSION,
   REGIME_HIGH_NEWS_RISK,
   REGIME_TRANSITION
};

enum ENUM_SIGNAL_DIRECTION
{
   SIGNAL_NONE,
   SIGNAL_BUY,
   SIGNAL_SELL
};

// STRAT_COUNT must stay last - arrays elsewhere are sized off it.
// V1 active: STRAT_CRT, STRAT_SMC, STRAT_TREND. The rest exist as IDs now
// so candidate/router code doesn't need to change shape when they're
// switched on later - they just stay disabled until implemented.
enum ENUM_STRATEGY_ID
{
   STRAT_CRT,
   STRAT_SMC,
   STRAT_TREND,
   STRAT_BREAKOUT,
   STRAT_SILVER_BULLET,
   STRAT_MEAN_REVERSION,
   STRAT_COUNT
};

string RegimeToString(ENUM_MARKET_REGIME r)
{
   switch(r)
   {
      case REGIME_TREND_UP:               return "TREND_UP";
      case REGIME_TREND_DOWN:             return "TREND_DOWN";
      case REGIME_RANGE:                  return "RANGE";
      case REGIME_VOLATILITY_EXPANSION:   return "VOL_EXPANSION";
      case REGIME_LIQUIDITY_SWEEP_SESSION:return "LIQUIDITY_SWEEP";
      case REGIME_HIGH_NEWS_RISK:         return "HIGH_NEWS_RISK";
      case REGIME_TRANSITION:             return "TRANSITION";
   }
   return "UNKNOWN";
}

string StrategyIdToString(int id)
{
   switch(id)
   {
      case STRAT_CRT:            return "CRT";
      case STRAT_SMC:             return "SMC_Liquidity";
      case STRAT_TREND:           return "Trend_Pullback";
      case STRAT_BREAKOUT:        return "Breakout_Retest";
      case STRAT_SILVER_BULLET:   return "Silver_Bullet";
      case STRAT_MEAN_REVERSION:  return "Mean_Reversion";
   }
   return "Unknown";
}

// What the AI Meta-Filter is allowed to decide (Phase C). Deliberately has
// no "flip direction" option - the enum shape itself enforces the spec's
// "AI ห้าม สร้าง Buy/Sell / เปลี่ยนทิศทาง" rule; there's no value here that
// could express that even if a future AI module tried to.
enum ENUM_AI_DECISION
{
   AI_DECISION_NONE,        // no model loaded / no opinion
   AI_DECISION_ALLOW,
   AI_DECISION_REJECT,
   AI_DECISION_REDUCE_RISK
};

string AiDecisionToString(ENUM_AI_DECISION d)
{
   switch(d)
   {
      case AI_DECISION_NONE:        return "NONE";
      case AI_DECISION_ALLOW:       return "ALLOW";
      case AI_DECISION_REJECT:      return "REJECT";
      case AI_DECISION_REDUCE_RISK: return "REDUCE_RISK";
   }
   return "UNKNOWN";
}

// The Global Risk Manager's final verdict on a candidate.
enum ENUM_RISK_DECISION
{
   RISK_DECISION_NONE,
   RISK_DECISION_ALLOW,
   RISK_DECISION_BLOCK
};

string RiskDecisionToString(ENUM_RISK_DECISION d)
{
   switch(d)
   {
      case RISK_DECISION_NONE:  return "NONE";
      case RISK_DECISION_ALLOW: return "ALLOW";
      case RISK_DECISION_BLOCK: return "BLOCK";
   }
   return "UNKNOWN";
}

// Every event_type string that ever appears in the Event Store, as a real
// enum instead of ad-hoc string literals scattered across modules - one
// place to see the full vocabulary, and EventTypeFromString() gives
// EventStoreValidator a way to flag an unrecognized type as corruption
// instead of silently accepting typos.
enum ENUM_EVENT_TYPE
{
   EVENT_TYPE_UNKNOWN,

   // system
   EVENT_TYPE_SYSTEM_STARTED,
   EVENT_TYPE_SYSTEM_STOPPED,
   EVENT_TYPE_SAFE_MODE_ENGAGED,
   EVENT_TYPE_SAFE_MODE_CLEARED,
   EVENT_TYPE_SYSTEM_EVENT_STORE_CORRUPTED,
   EVENT_TYPE_SYSTEM_ERROR,
   EVENT_TYPE_MARKET_CONTEXT_READY,

   // candidate lifecycle - one per ENUM_CANDIDATE_STATE
   EVENT_TYPE_CANDIDATE_CREATED,
   EVENT_TYPE_CANDIDATE_ROUTED_OUT,
   EVENT_TYPE_CANDIDATE_MERGED,
   EVENT_TYPE_CANDIDATE_REJECTED_BY_ARBITRATOR,
   EVENT_TYPE_CANDIDATE_REJECTED_BY_AI,
   EVENT_TYPE_CANDIDATE_REJECTED_BY_RISK,
   EVENT_TYPE_CANDIDATE_EXPIRED,
   EVENT_TYPE_CANDIDATE_SUBMITTED,
   EVENT_TYPE_CANDIDATE_EXECUTED,
   EVENT_TYPE_CANDIDATE_REJECTED_BY_BROKER,
   EVENT_TYPE_CANDIDATE_ERROR,

   // execution / position - schema locked now, nothing produces these
   // until Phase B's Execution Engine exists
   EVENT_TYPE_ORDER_SUBMITTED,
   EVENT_TYPE_ORDER_FILLED,
   EVENT_TYPE_ORDER_REJECTED,
   EVENT_TYPE_POSITION_CLOSED,
   EVENT_TYPE_TRADE_OUTCOME_LABELED,

   // Phase B7: RiskPlan - a SystemEvent (see
   // Docs/PhaseB_B7_RiskPlanContract.md's B7 Commit 2 addendum), not a
   // candidate lifecycle transition. Appended at the very end of the
   // enum, not inserted earlier - the persisted event store format
   // only ever stores/compares the STRING form via
   // EventTypeToString/EventTypeFromString, never the raw ordinal, so
   // an insertion wouldn't actually break anything in practice, but
   // appending at the end keeps that guarantee trivially true rather
   // than relying on it.
   EVENT_TYPE_RISK_PLAN_CREATED
};

string EventTypeToString(ENUM_EVENT_TYPE t)
{
   switch(t)
   {
      case EVENT_TYPE_SYSTEM_STARTED:                    return "SYSTEM_STARTED";
      case EVENT_TYPE_SYSTEM_STOPPED:                     return "SYSTEM_STOPPED";
      case EVENT_TYPE_SAFE_MODE_ENGAGED:                  return "SAFE_MODE_ENGAGED";
      case EVENT_TYPE_SAFE_MODE_CLEARED:                  return "SAFE_MODE_CLEARED";
      case EVENT_TYPE_SYSTEM_EVENT_STORE_CORRUPTED:       return "SYSTEM_EVENT_STORE_CORRUPTED";
      case EVENT_TYPE_SYSTEM_ERROR:                       return "SYSTEM_ERROR";
      case EVENT_TYPE_MARKET_CONTEXT_READY:               return "MARKET_CONTEXT_READY";
      case EVENT_TYPE_CANDIDATE_CREATED:                  return "CANDIDATE_CREATED";
      case EVENT_TYPE_CANDIDATE_ROUTED_OUT:               return "CANDIDATE_ROUTED_OUT";
      case EVENT_TYPE_CANDIDATE_MERGED:                   return "CANDIDATE_MERGED";
      case EVENT_TYPE_CANDIDATE_REJECTED_BY_ARBITRATOR:   return "CANDIDATE_REJECTED_BY_ARBITRATOR";
      case EVENT_TYPE_CANDIDATE_REJECTED_BY_AI:           return "CANDIDATE_REJECTED_BY_AI";
      case EVENT_TYPE_CANDIDATE_REJECTED_BY_RISK:         return "CANDIDATE_REJECTED_BY_RISK";
      case EVENT_TYPE_CANDIDATE_EXPIRED:                  return "CANDIDATE_EXPIRED";
      case EVENT_TYPE_CANDIDATE_SUBMITTED:                return "CANDIDATE_SUBMITTED";
      case EVENT_TYPE_CANDIDATE_EXECUTED:                 return "CANDIDATE_EXECUTED";
      case EVENT_TYPE_CANDIDATE_REJECTED_BY_BROKER:       return "CANDIDATE_REJECTED_BY_BROKER";
      case EVENT_TYPE_CANDIDATE_ERROR:                    return "CANDIDATE_ERROR";
      case EVENT_TYPE_ORDER_SUBMITTED:                    return "ORDER_SUBMITTED";
      case EVENT_TYPE_ORDER_FILLED:                       return "ORDER_FILLED";
      case EVENT_TYPE_ORDER_REJECTED:                     return "ORDER_REJECTED";
      case EVENT_TYPE_POSITION_CLOSED:                    return "POSITION_CLOSED";
      case EVENT_TYPE_TRADE_OUTCOME_LABELED:               return "TRADE_OUTCOME_LABELED";
      case EVENT_TYPE_RISK_PLAN_CREATED:                  return "RISK_PLAN_CREATED";
   }
   return "UNKNOWN";
}

ENUM_EVENT_TYPE EventTypeFromString(string s)
{
   if(s == "SYSTEM_STARTED")                    return EVENT_TYPE_SYSTEM_STARTED;
   if(s == "SYSTEM_STOPPED")                    return EVENT_TYPE_SYSTEM_STOPPED;
   if(s == "SAFE_MODE_ENGAGED")                 return EVENT_TYPE_SAFE_MODE_ENGAGED;
   if(s == "SAFE_MODE_CLEARED")                 return EVENT_TYPE_SAFE_MODE_CLEARED;
   if(s == "SYSTEM_EVENT_STORE_CORRUPTED")      return EVENT_TYPE_SYSTEM_EVENT_STORE_CORRUPTED;
   if(s == "SYSTEM_ERROR")                      return EVENT_TYPE_SYSTEM_ERROR;
   if(s == "MARKET_CONTEXT_READY")              return EVENT_TYPE_MARKET_CONTEXT_READY;
   if(s == "CANDIDATE_CREATED")                 return EVENT_TYPE_CANDIDATE_CREATED;
   if(s == "CANDIDATE_ROUTED_OUT")              return EVENT_TYPE_CANDIDATE_ROUTED_OUT;
   if(s == "CANDIDATE_MERGED")                  return EVENT_TYPE_CANDIDATE_MERGED;
   if(s == "CANDIDATE_REJECTED_BY_ARBITRATOR")  return EVENT_TYPE_CANDIDATE_REJECTED_BY_ARBITRATOR;
   if(s == "CANDIDATE_REJECTED_BY_AI")          return EVENT_TYPE_CANDIDATE_REJECTED_BY_AI;
   if(s == "CANDIDATE_REJECTED_BY_RISK")        return EVENT_TYPE_CANDIDATE_REJECTED_BY_RISK;
   if(s == "CANDIDATE_EXPIRED")                 return EVENT_TYPE_CANDIDATE_EXPIRED;
   if(s == "CANDIDATE_SUBMITTED")               return EVENT_TYPE_CANDIDATE_SUBMITTED;
   if(s == "CANDIDATE_EXECUTED")                return EVENT_TYPE_CANDIDATE_EXECUTED;
   if(s == "CANDIDATE_REJECTED_BY_BROKER")      return EVENT_TYPE_CANDIDATE_REJECTED_BY_BROKER;
   if(s == "CANDIDATE_ERROR")                   return EVENT_TYPE_CANDIDATE_ERROR;
   if(s == "ORDER_SUBMITTED")                   return EVENT_TYPE_ORDER_SUBMITTED;
   if(s == "ORDER_FILLED")                      return EVENT_TYPE_ORDER_FILLED;
   if(s == "ORDER_REJECTED")                    return EVENT_TYPE_ORDER_REJECTED;
   if(s == "POSITION_CLOSED")                   return EVENT_TYPE_POSITION_CLOSED;
   if(s == "TRADE_OUTCOME_LABELED")             return EVENT_TYPE_TRADE_OUTCOME_LABELED;
   if(s == "RISK_PLAN_CREATED")                 return EVENT_TYPE_RISK_PLAN_CREATED;
   return EVENT_TYPE_UNKNOWN;
}

// Graded health of the Event Store, as tracked by EventStoreHealth.mqh.
// UNKNOWN is the state before the first validation ever runs (e.g. brand
// new EA, no file yet) - it is deliberately NOT the same as HEALTHY, so
// nothing can accidentally treat "never checked" as "confirmed fine".
enum ENUM_EVENT_STORE_HEALTH
{
   EVENT_STORE_HEALTH_UNKNOWN,
   EVENT_STORE_HEALTH_HEALTHY,
   EVENT_STORE_HEALTH_CORRUPTED
};

string EventStoreHealthToString(ENUM_EVENT_STORE_HEALTH h)
{
   switch(h)
   {
      case EVENT_STORE_HEALTH_UNKNOWN:   return "UNKNOWN";
      case EVENT_STORE_HEALTH_HEALTHY:   return "HEALTHY";
      case EVENT_STORE_HEALTH_CORRUPTED: return "CORRUPTED";
   }
   return "UNKNOWN";
}

#endif // __MLQUANTAI_ENUMS_MQH__
