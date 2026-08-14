//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_ContractVersions.mqh                  |
//| Phase B contract registry, separate from Phase A's                |
//| MLQuantAI_VersionRegistry.mqh (which MLQuantAI.mq5 / SYSTEM_STARTED|
//| already depends on and stays untouched). Version stamps for every |
//| struct frozen across Phase B's steps: B1 froze MarketContext/     |
//| NewsSnapshot/TradeCandidate/RiskDecision; B2 adds SymbolSpec's     |
//| resolved-symbol contract. Same rule as VersionRegistry: changing  |
//| a schema's meaning means adding a new _V2 constant, never          |
//| redefining what an existing _V1 means.                             |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CONTRACTVERSIONS_MQH__
#define __MLQUANTAI_CONTRACTVERSIONS_MQH__

#define MLQUANTAI_MARKET_CONTEXT_SCHEMA_V1 "MARKET_CONTEXT_V1"
#define MLQUANTAI_FEATURE_SCHEMA_V1        "FEATURES_V1"
#define MLQUANTAI_CANDIDATE_SCHEMA_V1      "CANDIDATE_V1"
#define MLQUANTAI_NEWS_SCHEMA_V1           "NEWS_V1"
#define MLQUANTAI_RISK_SCHEMA_V1           "RISK_V1"

// B2: Symbol Resolution
#define MLQUANTAI_SYMBOL_SPEC_SCHEMA_V1    "SYMBOL_SPEC_V1"

// B5: CRT_V1 detector rules version (candidate_id's strategyVersion
// argument, see Docs/PhaseB_B5_CRTContract.md section 6) - distinct from
// MLQUANTAI_CANDIDATE_SCHEMA_V1 (the TradeCandidate struct shape) the
// same way TradeCandidate.regime_rules_version is distinct from
// candidate_schema_version. Bump to a new _V2 string, never redefine
// _V1 in place, if any of the frozen CRT_V1 parameters in
// Strategies/MLQuantAI_CRT_V1_Contract.mqh ever change.
#define MLQUANTAI_CRT_V1_RULES_VERSION     "CRT_V1"

#endif // __MLQUANTAI_CONTRACTVERSIONS_MQH__
