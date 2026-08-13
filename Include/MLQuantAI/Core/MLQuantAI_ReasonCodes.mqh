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
   }
   return "UNKNOWN";
}

#endif // __MLQUANTAI_REASONCODES_MQH__
