//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_ReasonCodes.mqh                       |
//| One flat enum for "why" a candidate moved to a given state.      |
//| Every rejection/terminal transition should carry one of these -  |
//| free-text reasons rot the log for anyone (or anything) trying to |
//| aggregate outcomes by cause later.                                |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_REASONCODES_MQH__
#define __MLQUANTAI_REASONCODES_MQH__

enum ENUM_REASON_CODE
{
   REASON_NONE,

   // routing / arbitration
   REASON_REGIME_MISMATCH,
   REASON_EXPIRED,
   REASON_DUPLICATE_EVENT,
   REASON_MERGED_INTO_OTHER,
   REASON_CONFLICTING_DIRECTION,
   REASON_LOW_SCORE,
   REASON_MAX_CANDIDATES_EXCEEDED,

   // AI filter
   REASON_AI_LOW_CONFIDENCE,
   REASON_AI_HIGH_UNCERTAINTY,
   REASON_AI_REJECT,

   // risk manager
   REASON_RISK_DAILY_LOSS_LIMIT,
   REASON_RISK_MAX_DRAWDOWN,
   REASON_RISK_MAX_TOTAL_EXPOSURE,
   REASON_RISK_MAX_PER_TRADE,
   REASON_RISK_MARGIN,
   REASON_RISK_SPREAD_TOO_WIDE,
   REASON_RISK_NEWS_BLOCK,
   REASON_RISK_MAX_OPEN_POSITIONS,
   REASON_RISK_CIRCUIT_BREAKER,

   // execution
   REASON_BROKER_REJECT,
   REASON_INVALID_STOPS,
   REASON_INSUFFICIENT_MARGIN,
   REASON_REQUOTE,
   REASON_ERROR_INTERNAL,

   // success
   REASON_SUBMITTED_OK,
   REASON_EXECUTED_OK,

   // Phase B8.5: AIDecision outcome reasons - appended at the tail, per
   // this enum's append-only discipline (REASON_AI_LOW_CONFIDENCE and
   // REASON_AI_HIGH_UNCERTAINTY above predate B8.5 and stay reserved/
   // unreachable under its single-scalar p_success threshold policy).
   REASON_AI_ABSTAIN,

   // Phase C1.2: SafetyGate/ExecutionRequest reasons - appended at the
   // tail, per this enum's append-only discipline. See
   // Docs/PhaseC_C1_1_ExecutionRequestContract.md's C1.2 addendum for
   // the frozen gate order each of these maps to. REASON_RISK_CIRCUIT_BREAKER
   // (above) is reused for the Safe Mode gate rather than duplicated.
   REASON_EXECUTION_SUBMIT_DISABLED,
   REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED,
   REASON_EXECUTION_MANUAL_APPROVAL_REQUIRED,
   REASON_EXECUTION_ACCOUNT_NOT_ALLOWED,
   REASON_EXECUTION_SYMBOL_NOT_ALLOWED,
   REASON_EXECUTION_ORDER_TYPE_NOT_MARKET,
   REASON_EXECUTION_VOLUME_POLICY_INVALID,
   REASON_EXECUTION_VOLUME_CAP_EXCEEDED,
   REASON_EXECUTION_EXPOSURE_POLICY_INVALID,
   REASON_EXECUTION_EXPOSURE_CAP_EXCEEDED,
   REASON_EXECUTION_DEVIATION_POLICY_INVALID,
   REASON_EXECUTION_LINEAGE_INVALID,

   // C2.2 amendment (post-PASSED, real user review): OrderSend()
   // returning true with a retcode that is neither an explicit
   // acceptance (TRADE_RETCODE_DONE/_DONE_PARTIAL) nor an explicit
   // rejection - e.g. TRADE_RETCODE_CONNECTION, TRADE_RETCODE_PLACED,
   // or any unrecognized/future retcode. The candidate still legally
   // transitions to and stays at CANDIDATE_SUBMITTED (per the sealed
   // state machine and the frozen C2.1 lifecycle), but REASON_SUBMITTED_OK
   // would falsely claim a positive broker acknowledgment that never
   // happened - this reason makes that distinction honest without
   // touching the state transition itself. See
   // Docs/PhaseC_C2_1_BrokerSubmissionContract.md's C2.2 amendment.
   REASON_EXECUTION_SUBMISSION_AMBIGUOUS,

   // C2.2/C2.3 startup-rebuild integration patch: the durable submission-
   // attempt audit registry (SubmissionAttemptRegistry) has not been
   // successfully rebuilt from the event store this session yet - the
   // gate cannot trust ANY answer from it, so every request is rejected
   // with this reason until BrokerSubmissionAudit_StartupRebuild()
   // succeeds. Never the same condition as REASON_DUPLICATE_EVENT (which
   // means the registry WAS consulted and found a real prior attempt) -
   // this means the registry could not be consulted at all.
   REASON_EXECUTION_AUDIT_NOT_READY,

   // C2 environment-lock checklist (frozen, per
   // Docs/PhaseC_C2_EnvironmentLockChecklist.md): five new, genuinely
   // new runtime assertions not covered by any earlier gate - appended
   // at the tail, per this enum's append-only discipline.
   REASON_EXECUTION_SERVER_NOT_ALLOWED,
   REASON_EXECUTION_TERMINAL_TRADE_DISABLED,
   REASON_EXECUTION_ACCOUNT_TRADE_DISABLED,
   REASON_EXECUTION_EXPERT_TRADE_DISABLED,
   REASON_EXECUTION_VOLUME_BELOW_MINIMUM,

   REASON_COUNT
};

string ReasonCodeToString(ENUM_REASON_CODE r)
{
   switch(r)
   {
      case REASON_NONE:                       return "NONE";
      case REASON_REGIME_MISMATCH:            return "REGIME_MISMATCH";
      case REASON_EXPIRED:                    return "EXPIRED";
      case REASON_DUPLICATE_EVENT:            return "DUPLICATE_EVENT";
      case REASON_MERGED_INTO_OTHER:          return "MERGED_INTO_OTHER";
      case REASON_CONFLICTING_DIRECTION:      return "CONFLICTING_DIRECTION";
      case REASON_LOW_SCORE:                  return "LOW_SCORE";
      case REASON_MAX_CANDIDATES_EXCEEDED:    return "MAX_CANDIDATES_EXCEEDED";
      case REASON_AI_LOW_CONFIDENCE:          return "AI_LOW_CONFIDENCE";
      case REASON_AI_HIGH_UNCERTAINTY:        return "AI_HIGH_UNCERTAINTY";
      case REASON_AI_REJECT:                  return "AI_REJECT";
      case REASON_RISK_DAILY_LOSS_LIMIT:      return "RISK_DAILY_LOSS_LIMIT";
      case REASON_RISK_MAX_DRAWDOWN:          return "RISK_MAX_DRAWDOWN";
      case REASON_RISK_MAX_TOTAL_EXPOSURE:    return "RISK_MAX_TOTAL_EXPOSURE";
      case REASON_RISK_MAX_PER_TRADE:         return "RISK_MAX_PER_TRADE";
      case REASON_RISK_MARGIN:                return "RISK_MARGIN";
      case REASON_RISK_SPREAD_TOO_WIDE:       return "RISK_SPREAD_TOO_WIDE";
      case REASON_RISK_NEWS_BLOCK:            return "RISK_NEWS_BLOCK";
      case REASON_RISK_MAX_OPEN_POSITIONS:    return "RISK_MAX_OPEN_POSITIONS";
      case REASON_RISK_CIRCUIT_BREAKER:       return "RISK_CIRCUIT_BREAKER";
      case REASON_BROKER_REJECT:              return "BROKER_REJECT";
      case REASON_INVALID_STOPS:              return "INVALID_STOPS";
      case REASON_INSUFFICIENT_MARGIN:        return "INSUFFICIENT_MARGIN";
      case REASON_REQUOTE:                    return "REQUOTE";
      case REASON_ERROR_INTERNAL:             return "ERROR_INTERNAL";
      case REASON_SUBMITTED_OK:               return "SUBMITTED_OK";
      case REASON_EXECUTED_OK:                return "EXECUTED_OK";
      case REASON_AI_ABSTAIN:                 return "AI_ABSTAIN";
      case REASON_EXECUTION_SUBMIT_DISABLED:            return "EXECUTION_SUBMIT_DISABLED";
      case REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED:  return "EXECUTION_ENVIRONMENT_NOT_PERMITTED";
      case REASON_EXECUTION_MANUAL_APPROVAL_REQUIRED:   return "EXECUTION_MANUAL_APPROVAL_REQUIRED";
      case REASON_EXECUTION_ACCOUNT_NOT_ALLOWED:        return "EXECUTION_ACCOUNT_NOT_ALLOWED";
      case REASON_EXECUTION_SYMBOL_NOT_ALLOWED:         return "EXECUTION_SYMBOL_NOT_ALLOWED";
      case REASON_EXECUTION_ORDER_TYPE_NOT_MARKET:      return "EXECUTION_ORDER_TYPE_NOT_MARKET";
      case REASON_EXECUTION_VOLUME_POLICY_INVALID:      return "EXECUTION_VOLUME_POLICY_INVALID";
      case REASON_EXECUTION_VOLUME_CAP_EXCEEDED:        return "EXECUTION_VOLUME_CAP_EXCEEDED";
      case REASON_EXECUTION_EXPOSURE_POLICY_INVALID:    return "EXECUTION_EXPOSURE_POLICY_INVALID";
      case REASON_EXECUTION_EXPOSURE_CAP_EXCEEDED:      return "EXECUTION_EXPOSURE_CAP_EXCEEDED";
      case REASON_EXECUTION_DEVIATION_POLICY_INVALID:   return "EXECUTION_DEVIATION_POLICY_INVALID";
      case REASON_EXECUTION_LINEAGE_INVALID:            return "EXECUTION_LINEAGE_INVALID";
      case REASON_EXECUTION_SUBMISSION_AMBIGUOUS:       return "EXECUTION_SUBMISSION_AMBIGUOUS";
      case REASON_EXECUTION_AUDIT_NOT_READY:            return "EXECUTION_AUDIT_NOT_READY";
      case REASON_EXECUTION_SERVER_NOT_ALLOWED:         return "EXECUTION_SERVER_NOT_ALLOWED";
      case REASON_EXECUTION_TERMINAL_TRADE_DISABLED:    return "EXECUTION_TERMINAL_TRADE_DISABLED";
      case REASON_EXECUTION_ACCOUNT_TRADE_DISABLED:     return "EXECUTION_ACCOUNT_TRADE_DISABLED";
      case REASON_EXECUTION_EXPERT_TRADE_DISABLED:      return "EXECUTION_EXPERT_TRADE_DISABLED";
      case REASON_EXECUTION_VOLUME_BELOW_MINIMUM:       return "EXECUTION_VOLUME_BELOW_MINIMUM";
   }
   return "UNKNOWN";
}

// Reverse of ReasonCodeToString, for parsing stored lines back. An
// unrecognized string maps to REASON_NONE (not an error state itself -
// the state machine's own CANDIDATE_ERROR/CandidateStateFromString is
// what flags a corrupted line, this just avoids inventing a fake reason).
ENUM_REASON_CODE ReasonCodeFromString(string s)
{
   if(s == "NONE")                       return REASON_NONE;
   if(s == "REGIME_MISMATCH")            return REASON_REGIME_MISMATCH;
   if(s == "EXPIRED")                    return REASON_EXPIRED;
   if(s == "DUPLICATE_EVENT")            return REASON_DUPLICATE_EVENT;
   if(s == "MERGED_INTO_OTHER")          return REASON_MERGED_INTO_OTHER;
   if(s == "CONFLICTING_DIRECTION")      return REASON_CONFLICTING_DIRECTION;
   if(s == "LOW_SCORE")                  return REASON_LOW_SCORE;
   if(s == "MAX_CANDIDATES_EXCEEDED")    return REASON_MAX_CANDIDATES_EXCEEDED;
   if(s == "AI_LOW_CONFIDENCE")          return REASON_AI_LOW_CONFIDENCE;
   if(s == "AI_HIGH_UNCERTAINTY")        return REASON_AI_HIGH_UNCERTAINTY;
   if(s == "AI_REJECT")                  return REASON_AI_REJECT;
   if(s == "RISK_DAILY_LOSS_LIMIT")      return REASON_RISK_DAILY_LOSS_LIMIT;
   if(s == "RISK_MAX_DRAWDOWN")          return REASON_RISK_MAX_DRAWDOWN;
   if(s == "RISK_MAX_TOTAL_EXPOSURE")    return REASON_RISK_MAX_TOTAL_EXPOSURE;
   if(s == "RISK_MAX_PER_TRADE")         return REASON_RISK_MAX_PER_TRADE;
   if(s == "RISK_MARGIN")                return REASON_RISK_MARGIN;
   if(s == "RISK_SPREAD_TOO_WIDE")       return REASON_RISK_SPREAD_TOO_WIDE;
   if(s == "RISK_NEWS_BLOCK")            return REASON_RISK_NEWS_BLOCK;
   if(s == "RISK_MAX_OPEN_POSITIONS")    return REASON_RISK_MAX_OPEN_POSITIONS;
   if(s == "RISK_CIRCUIT_BREAKER")       return REASON_RISK_CIRCUIT_BREAKER;
   if(s == "BROKER_REJECT")              return REASON_BROKER_REJECT;
   if(s == "INVALID_STOPS")              return REASON_INVALID_STOPS;
   if(s == "INSUFFICIENT_MARGIN")        return REASON_INSUFFICIENT_MARGIN;
   if(s == "REQUOTE")                    return REASON_REQUOTE;
   if(s == "ERROR_INTERNAL")             return REASON_ERROR_INTERNAL;
   if(s == "SUBMITTED_OK")               return REASON_SUBMITTED_OK;
   if(s == "EXECUTED_OK")                return REASON_EXECUTED_OK;
   if(s == "AI_ABSTAIN")                 return REASON_AI_ABSTAIN;
   if(s == "EXECUTION_SUBMIT_DISABLED")           return REASON_EXECUTION_SUBMIT_DISABLED;
   if(s == "EXECUTION_ENVIRONMENT_NOT_PERMITTED") return REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED;
   if(s == "EXECUTION_MANUAL_APPROVAL_REQUIRED")  return REASON_EXECUTION_MANUAL_APPROVAL_REQUIRED;
   if(s == "EXECUTION_ACCOUNT_NOT_ALLOWED")       return REASON_EXECUTION_ACCOUNT_NOT_ALLOWED;
   if(s == "EXECUTION_SYMBOL_NOT_ALLOWED")        return REASON_EXECUTION_SYMBOL_NOT_ALLOWED;
   if(s == "EXECUTION_ORDER_TYPE_NOT_MARKET")     return REASON_EXECUTION_ORDER_TYPE_NOT_MARKET;
   if(s == "EXECUTION_VOLUME_POLICY_INVALID")     return REASON_EXECUTION_VOLUME_POLICY_INVALID;
   if(s == "EXECUTION_VOLUME_CAP_EXCEEDED")       return REASON_EXECUTION_VOLUME_CAP_EXCEEDED;
   if(s == "EXECUTION_EXPOSURE_POLICY_INVALID")   return REASON_EXECUTION_EXPOSURE_POLICY_INVALID;
   if(s == "EXECUTION_EXPOSURE_CAP_EXCEEDED")     return REASON_EXECUTION_EXPOSURE_CAP_EXCEEDED;
   if(s == "EXECUTION_DEVIATION_POLICY_INVALID")  return REASON_EXECUTION_DEVIATION_POLICY_INVALID;
   if(s == "EXECUTION_LINEAGE_INVALID")           return REASON_EXECUTION_LINEAGE_INVALID;
   if(s == "EXECUTION_SUBMISSION_AMBIGUOUS")      return REASON_EXECUTION_SUBMISSION_AMBIGUOUS;
   if(s == "EXECUTION_AUDIT_NOT_READY")           return REASON_EXECUTION_AUDIT_NOT_READY;
   return REASON_NONE;
}

#endif // __MLQUANTAI_REASONCODES_MQH__
