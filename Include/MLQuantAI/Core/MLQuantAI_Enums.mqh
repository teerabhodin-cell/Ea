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

#endif // __MLQUANTAI_ENUMS_MQH__
