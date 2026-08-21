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

// Phase B8.5: the AIDecision outcome vocabulary - deliberately a NEW,
// separate enum from ENUM_AI_DECISION above, not a reuse. ENUM_AI_DECISION
// carries AI_DECISION_REDUCE_RISK, a risk-scaling capability B8.5 does not
// have (AIDecision never touches RiskPlan/lot_size) - reusing it would
// carry a value B8.5 can never legally produce. See
// Docs/PhaseB_B8_5_AIDecisionContract.md's collision check.
enum ENUM_AI_DECISION_OUTCOME
{
   AI_DECISION_OUTCOME_NONE,    // Init()/unfilled only - never a real decision's value
   AI_DECISION_OUTCOME_ALLOW,
   AI_DECISION_OUTCOME_REJECT,
   AI_DECISION_OUTCOME_ABSTAIN  // frozen now, unreachable under Commit 1's threshold-only policy - reserved for a future explicit-abstain policy version
};

string AiDecisionOutcomeToString(ENUM_AI_DECISION_OUTCOME o)
{
   switch(o)
   {
      case AI_DECISION_OUTCOME_NONE:    return "NONE";
      case AI_DECISION_OUTCOME_ALLOW:   return "ALLOW";
      case AI_DECISION_OUTCOME_REJECT:  return "REJECT";
      case AI_DECISION_OUTCOME_ABSTAIN: return "ABSTAIN";
   }
   return "UNKNOWN";
}

ENUM_AI_DECISION_OUTCOME AiDecisionOutcomeFromString(string s)
{
   if(s == "NONE")    return AI_DECISION_OUTCOME_NONE;
   if(s == "ALLOW")   return AI_DECISION_OUTCOME_ALLOW;
   if(s == "REJECT")  return AI_DECISION_OUTCOME_REJECT;
   if(s == "ABSTAIN") return AI_DECISION_OUTCOME_ABSTAIN;
   return AI_DECISION_OUTCOME_NONE;
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

// Phase B9: the execution-eligibility verdict vocabulary - deliberately
// a NEW, separate enum from ENUM_RISK_DECISION above (B7's sizing-success
// axis) and from ENUM_AI_DECISION_OUTCOME (B8.5's AI-only axis). B9
// combines RiskPlan + AIDecision + operational constraints into this
// verdict; it is not either of those upstream decisions restated. See
// Docs/PhaseB_B9_ExecutionEligibilityContract.md's collision check.
enum ENUM_ELIGIBILITY_DECISION
{
   ELIGIBILITY_DECISION_NONE,     // Init()/unfilled only - never a real decision's value
   ELIGIBILITY_DECISION_ELIGIBLE,
   ELIGIBILITY_DECISION_REJECTED
};

string EligibilityDecisionToString(ENUM_ELIGIBILITY_DECISION d)
{
   switch(d)
   {
      case ELIGIBILITY_DECISION_NONE:     return "NONE";
      case ELIGIBILITY_DECISION_ELIGIBLE: return "ELIGIBLE";
      case ELIGIBILITY_DECISION_REJECTED: return "REJECTED";
   }
   return "UNKNOWN";
}

ENUM_ELIGIBILITY_DECISION EligibilityDecisionFromString(string s)
{
   if(s == "NONE")     return ELIGIBILITY_DECISION_NONE;
   if(s == "ELIGIBLE") return ELIGIBILITY_DECISION_ELIGIBLE;
   if(s == "REJECTED") return ELIGIBILITY_DECISION_REJECTED;
   return ELIGIBILITY_DECISION_NONE;
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
   EVENT_TYPE_RISK_PLAN_CREATED,

   // Phase B8.2 Commit 2: same append-at-end rule as
   // EVENT_TYPE_RISK_PLAN_CREATED above - a FeatureSnapshot is a
   // derived artifact tied to a candidate (SystemEvent), not a
   // candidate lifecycle transition.
   EVENT_TYPE_FEATURE_SNAPSHOT_CREATED,

   // Phase B8.3: same append-at-end rule. A ModelArtifact is a
   // SystemEvent tied to a registered model, not a candidate lifecycle
   // transition or even candidate-tied at all.
   EVENT_TYPE_MODEL_ARTIFACT_REGISTERED,

   // Phase B8.5 Commit 2: same append-at-end rule. An AIDecision is a
   // SystemEvent tied to a candidate (via the FeatureSnapshot it was
   // built from) - a derived artifact, not a candidate lifecycle
   // transition. Deliberately NOT the same thing as the dormant,
   // Phase-A EVENT_TYPE_CANDIDATE_REJECTED_BY_AI candidate-state value
   // above - that is a state-machine transition B8.5 does not drive.
   EVENT_TYPE_AI_DECISION_CREATED,

   // Phase B9 Commit 2: same append-at-end rule. An EligibilityDecision
   // is a SystemEvent tied to a candidate (via RiskPlan/AIDecision) - a
   // derived audit artifact, not itself a candidate-lifecycle
   // transition. The separate CANDIDATE_REJECTED_BY_RISK LifecycleEvent
   // (already declared above, in the candidate-lifecycle block) is the
   // real state transition this commit wires as a REJECTED-only
   // consequence - see Docs/PhaseB_B9_ExecutionEligibilityContract.md's
   // Commit 2 addendum.
   EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED,

   // Phase C1.2: same append-at-end rule. An ExecutionRequest and its
   // DryRunExecutionResult are derived audit artifacts tied to a
   // candidate (via EligibilityDecision) - SystemEvents, not candidate-
   // lifecycle transitions. Neither means a real broker submission -
   // see Docs/PhaseC_C1_1_ExecutionRequestContract.md's C1.2 addendum.
   // The dormant EVENT_TYPE_ORDER_SUBMITTED/_FILLED/_REJECTED/
   // _POSITION_CLOSED above stay reserved for C2's real broker facts.
   EVENT_TYPE_EXECUTION_REQUEST_CREATED,
   EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED,

   // Phase C2.2: same append-at-end rule. EXECUTION_SUBMISSION_ATTEMPTED
   // is a SystemEvent audit artifact - crossed the final pre-submit gate,
   // no broker claim yet, NOT a candidate-lifecycle transition (that is
   // CANDIDATE_SUBMITTED above, logged separately once OrderSend
   // actually returns true). ORDER_SUBMISSION_ERROR covers OrderSend()
   // returning false or an unclassifiable local/API failure - the
   // request never reached the trade server, candidate.state stays
   // CANDIDATE_CREATED. See
   // Docs/PhaseC_C2_1_BrokerSubmissionContract.md's event vocabulary.
   // The dormant EVENT_TYPE_ORDER_SUBMITTED/_ORDER_REJECTED declared
   // above (in the execution/position block) are reused as-is for the
   // post-OrderSend accepted/ambiguous and explicit-rejection cases.
   EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED,
   EVENT_TYPE_ORDER_SUBMISSION_ERROR,

   // C2.2 second amendment (post-PASSED, real user review): a retcode
   // that is neither an explicit acceptance nor an explicit rejection
   // (TRADE_RETCODE_CONNECTION, TRADE_RETCODE_PLACED, or any
   // unrecognized/future retcode) gets its own event and its own
   // SUBMISSION_STATUS_UNKNOWN status - never folded into
   // EVENT_TYPE_ORDER_SUBMITTED (which would falsely imply a positive
   // acknowledgment) and never transitions the candidate at all. See
   // Docs/PhaseC_C2_1_BrokerSubmissionContract.md's second amendment.
   EVENT_TYPE_EXECUTION_SUBMISSION_UNKNOWN
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
      case EVENT_TYPE_FEATURE_SNAPSHOT_CREATED:           return "FEATURE_SNAPSHOT_CREATED";
      case EVENT_TYPE_MODEL_ARTIFACT_REGISTERED:          return "MODEL_ARTIFACT_REGISTERED";
      case EVENT_TYPE_AI_DECISION_CREATED:                return "AI_DECISION_CREATED";
      case EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED:      return "EXECUTION_ELIGIBILITY_DECIDED";
      case EVENT_TYPE_EXECUTION_REQUEST_CREATED:          return "EXECUTION_REQUEST_CREATED";
      case EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED:        return "EXECUTION_DRY_RUN_COMPLETED";
      case EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED:     return "EXECUTION_SUBMISSION_ATTEMPTED";
      case EVENT_TYPE_ORDER_SUBMISSION_ERROR:             return "ORDER_SUBMISSION_ERROR";
      case EVENT_TYPE_EXECUTION_SUBMISSION_UNKNOWN:       return "EXECUTION_SUBMISSION_UNKNOWN";
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
   if(s == "FEATURE_SNAPSHOT_CREATED")          return EVENT_TYPE_FEATURE_SNAPSHOT_CREATED;
   if(s == "MODEL_ARTIFACT_REGISTERED")         return EVENT_TYPE_MODEL_ARTIFACT_REGISTERED;
   if(s == "AI_DECISION_CREATED")               return EVENT_TYPE_AI_DECISION_CREATED;
   if(s == "EXECUTION_ELIGIBILITY_DECIDED")     return EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED;
   if(s == "EXECUTION_REQUEST_CREATED")         return EVENT_TYPE_EXECUTION_REQUEST_CREATED;
   if(s == "EXECUTION_DRY_RUN_COMPLETED")       return EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED;
   if(s == "EXECUTION_SUBMISSION_ATTEMPTED")    return EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED;
   if(s == "ORDER_SUBMISSION_ERROR")            return EVENT_TYPE_ORDER_SUBMISSION_ERROR;
   if(s == "EXECUTION_SUBMISSION_UNKNOWN")      return EVENT_TYPE_EXECUTION_SUBMISSION_UNKNOWN;
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

// Phase C1.2: ExecutionPolicy.environment_mode. Reserved field shape -
// C1 never chooses/enforces which mode is "permitted" beyond requiring
// it be explicitly set (not NONE); C2 freezes real per-mode enforcement
// separately, with explicit user authorization, before it opens. See
// Docs/PhaseC_C1_1_ExecutionRequestContract.md's C1.2 addendum.
enum ENUM_EXECUTION_ENVIRONMENT_MODE
{
   EXECUTION_ENV_NONE,
   EXECUTION_ENV_TESTER,
   EXECUTION_ENV_DEMO,
   EXECUTION_ENV_LIVE
};

string ExecutionEnvironmentModeToString(ENUM_EXECUTION_ENVIRONMENT_MODE m)
{
   switch(m)
   {
      case EXECUTION_ENV_NONE:   return "NONE";
      case EXECUTION_ENV_TESTER: return "TESTER";
      case EXECUTION_ENV_DEMO:   return "DEMO";
      case EXECUTION_ENV_LIVE:   return "LIVE";
   }
   return "NONE";
}

ENUM_EXECUTION_ENVIRONMENT_MODE ExecutionEnvironmentModeFromString(string s)
{
   if(s == "TESTER") return EXECUTION_ENV_TESTER;
   if(s == "DEMO")   return EXECUTION_ENV_DEMO;
   if(s == "LIVE")   return EXECUTION_ENV_LIVE;
   return EXECUTION_ENV_NONE;
}

// Phase C1.2: SafetyGate_Evaluate's own verdict - deliberately not a
// reuse of ENUM_ELIGIBILITY_DECISION (B9's ELIGIBLE/REJECTED axis) or
// ENUM_RISK_DECISION (B7's sizing-success axis) - a dry-run safety
// verdict is a different concept from either.
enum ENUM_SAFETY_GATE_DECISION
{
   SAFETY_GATE_NONE,
   SAFETY_GATE_ACCEPTED,
   SAFETY_GATE_REJECTED
};

string SafetyGateDecisionToString(ENUM_SAFETY_GATE_DECISION d)
{
   switch(d)
   {
      case SAFETY_GATE_NONE:     return "NONE";
      case SAFETY_GATE_ACCEPTED: return "ACCEPTED";
      case SAFETY_GATE_REJECTED: return "REJECTED";
   }
   return "NONE";
}

ENUM_SAFETY_GATE_DECISION SafetyGateDecisionFromString(string s)
{
   if(s == "ACCEPTED") return SAFETY_GATE_ACCEPTED;
   if(s == "REJECTED") return SAFETY_GATE_REJECTED;
   return SAFETY_GATE_NONE;
}

// Phase C2.2: ExecutionSubmissionResult.submission_status - a real
// broker-facing outcome, deliberately distinct from
// ENUM_SAFETY_GATE_DECISION (C1.2's own dry-run-only ACCEPTED/REJECTED
// axis, which never claims anything about a broker). NONE = never
// attempted (Init()/unfilled, or the pre-submit gate rejected before
// OrderSend was ever called). ERROR = OrderSend() itself returned
// false - a provable local/pre-dispatch failure (GetLastError()
// captured as evidence). REJECTED = OrderSend() returned true but
// result.retcode was an explicit server rejection.
//
// C2.2 second amendment (post-PASSED, real user review):
// SUBMISSION_STATUS_UNKNOWN added, split out of what SUBMITTED used to
// cover. SUBMITTED now means ONLY a genuine positive acknowledgment
// (TRADE_RETCODE_DONE/_DONE_PARTIAL) - it transitions the candidate to
// CANDIDATE_SUBMITTED. UNKNOWN covers every retcode that is neither an
// explicit acceptance nor an explicit rejection (TRADE_RETCODE_CONNECTION,
// TRADE_RETCODE_PLACED, or any unrecognized/future retcode) - the
// candidate is NEVER transitioned for this status, exactly like the
// ERROR case, since no real acknowledgment happened. See
// Docs/PhaseC_C2_1_BrokerSubmissionContract.md's second amendment.
enum ENUM_SUBMISSION_STATUS
{
   SUBMISSION_STATUS_NONE,
   SUBMISSION_STATUS_ERROR,
   SUBMISSION_STATUS_REJECTED,
   SUBMISSION_STATUS_SUBMITTED,
   SUBMISSION_STATUS_UNKNOWN
};

string SubmissionStatusToString(ENUM_SUBMISSION_STATUS s)
{
   switch(s)
   {
      case SUBMISSION_STATUS_NONE:      return "NONE";
      case SUBMISSION_STATUS_ERROR:     return "ERROR";
      case SUBMISSION_STATUS_REJECTED:  return "REJECTED";
      case SUBMISSION_STATUS_SUBMITTED: return "SUBMITTED";
      case SUBMISSION_STATUS_UNKNOWN:   return "UNKNOWN";
   }
   return "NONE";
}

ENUM_SUBMISSION_STATUS SubmissionStatusFromString(string s)
{
   if(s == "ERROR")     return SUBMISSION_STATUS_ERROR;
   if(s == "REJECTED")  return SUBMISSION_STATUS_REJECTED;
   if(s == "SUBMITTED") return SUBMISSION_STATUS_SUBMITTED;
   if(s == "UNKNOWN")   return SUBMISSION_STATUS_UNKNOWN;
   return SUBMISSION_STATUS_NONE;
}

#endif // __MLQUANTAI_ENUMS_MQH__
