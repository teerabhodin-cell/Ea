//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_TradeCandidate.mqh                    |
//| What a strategy module hands back to the pool. Strategies fill   |
//| this in and return it - they never call CTrade themselves, and   |
//| they never set .state directly (see MLQuantAI_StateMachine.mqh - |
//| all state changes go through StateMachine_Transition()).          |
//|                                                                    |
//| Phase B B1.4 extended this struct ADDITIVELY: every field Phase A |
//| already sealed (candidate_id..last_reason below the B1 block)     |
//| keeps its name, type and meaning unchanged, because Phase A's     |
//| StateMachine/DummyLifecycle tests and MLQuantAI.mq5's Step 8.5    |
//| smoke test already depend on them and Phase A is closed - the     |
//| same "never silently redefine a frozen version" rule the whole    |
//| contract-versioning discipline runs on. The new B1 fields (below  |
//| candidate_schema_version) are what a CRT-style detector (B5) will |
//| actually fill in: context lineage (context_event_id/context_hash),|
//| a closed-bar anchor + expiry-after-bars (not TimeCurrent() + N    |
//| minutes), and an explainable reason tree (trigger_reason_mask /   |
//| trigger_reasons[]) instead of just a score. `side` is additive    |
//| alongside the existing `direction` field for the same reason.     |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_TRADECANDIDATE_MQH__
#define __MLQUANTAI_TRADECANDIDATE_MQH__

#include "MLQuantAI_Enums.mqh"
#include "MLQuantAI_StateMachine.mqh"
#include "MLQuantAI_ReasonCodes.mqh"
#include "MLQuantAI_ContractVersions.mqh"

struct TradeCandidate
{
   // identity / lineage (Phase A, sealed - unchanged)
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

   // --- Phase B B1.4: additive dataset/detector contract ---
   string                 candidate_schema_version; // MLQUANTAI_CANDIDATE_SCHEMA_V1

   string                 context_event_id; // the MarketContext this candidate was built from
   string                 context_hash;     // copy of that context's context_hash, for tamper/mismatch detection

   ENUM_ORDER_TYPE         side;             // ORDER_TYPE_BUY / ORDER_TYPE_SELL - canonical for B5+ detectors
   datetime                setup_anchor_bar_time; // the closed bar the setup was detected on

   int                     expiry_after_bars; // candidate expires setup_anchor_bar_time + N bars on trigger_timeframe
   // expiry_time is a DERIVED value for querying only - never assign it
   // from TimeCurrent() + N minutes; recompute it from setup_anchor_bar_time
   // + expiry_after_bars bars on the candidate's trigger timeframe.

   double                  entry_hint;       // pre-risk-adjustment price hints, as the detector saw them
   double                  sl_hint;
   double                  tp_hint;

   ulong                   trigger_reason_mask; // bitmask of setup conditions (sweep/mss/fvg/ob/... - detector-defined)
   string                  trigger_reasons[];   // human-readable reason tree, e.g. {"liquidity_sweep","mss_confirmed"}
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

   c.candidate_schema_version = MLQUANTAI_CANDIDATE_SCHEMA_V1;

   c.context_event_id = "";
   c.context_hash = "";

   c.side = ORDER_TYPE_BUY; // meaningless until direction/side is actually set - same "0 means not ready" convention as elsewhere
   c.setup_anchor_bar_time = 0;

   c.expiry_after_bars = 0;

   c.entry_hint = 0;
   c.sl_hint = 0;
   c.tp_hint = 0;

   c.trigger_reason_mask = 0;
   ArrayResize(c.trigger_reasons, 0);
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

// The ONLY sanctioned way to derive TradeCandidate.expiry_time - always
// setup_anchor_bar_time + expiry_after_bars bars on the given trigger
// timeframe, NEVER TimeCurrent() + N minutes (that would make the same
// candidate expire at a different wall-clock time depending on when this
// function happens to run, breaking replay determinism).
datetime TradeCandidate_ComputeExpiryTime(datetime setupAnchorBarTime, int expiryAfterBars, ENUM_TIMEFRAMES triggerTimeframe)
{
   return setupAnchorBarTime + (datetime)(expiryAfterBars * PeriodSeconds(triggerTimeframe));
}

#endif // __MLQUANTAI_TRADECANDIDATE_MQH__
