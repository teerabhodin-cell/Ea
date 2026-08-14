//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_ContractVersions.mqh                  |
//| Phase B B1: Contract Freeze. Version stamps for every struct     |
//| frozen in this pass (MarketContext, NewsSnapshot, TradeCandidate,|
//| RiskDecision). Separate from MLQuantAI_VersionRegistry.mqh       |
//| (Phase A's registry, which MLQuantAI.mq5 / SYSTEM_STARTED        |
//| already depends on and stays untouched) - this file is the       |
//| Phase B contract registry specifically, so B1 can freeze new     |
//| version constants without touching what Phase A already sealed.  |
//| Same rule as VersionRegistry: changing a schema's meaning means  |
//| adding a new _V2 constant, never redefining what _V1 means.      |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CONTRACTVERSIONS_MQH__
#define __MLQUANTAI_CONTRACTVERSIONS_MQH__

#define MLQUANTAI_MARKET_CONTEXT_SCHEMA_V1 "MARKET_CONTEXT_V1"
#define MLQUANTAI_FEATURE_SCHEMA_V1        "FEATURES_V1"
#define MLQUANTAI_CANDIDATE_SCHEMA_V1      "CANDIDATE_V1"
#define MLQUANTAI_NEWS_SCHEMA_V1           "NEWS_V1"
#define MLQUANTAI_RISK_SCHEMA_V1           "RISK_V1"

#endif // __MLQUANTAI_CONTRACTVERSIONS_MQH__
