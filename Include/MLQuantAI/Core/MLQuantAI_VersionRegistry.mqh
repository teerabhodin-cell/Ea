//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_VersionRegistry.mqh                   |
//| Every versioned "rule set" in the system gets a name here.       |
//| Changing a rule set's behavior means adding a new version        |
//| constant and switching modules to it - never silently editing    |
//| what a V1 label means after candidates/logs already reference    |
//| it, or old log rows become uninterpretable.                      |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_VERSIONREGISTRY_MQH__
#define __MLQUANTAI_VERSIONREGISTRY_MQH__

#define MLQUANTAI_SCHEMA_VERSION     "1"
#define MLQUANTAI_EA_VERSION         "0.1.0-sprint1"
#define MLQUANTAI_REGIME_RULES_VER   "REGIME_RULES_V1"
#define MLQUANTAI_ROUTER_RULES_VER   "ROUTER_RULES_V1"

#endif // __MLQUANTAI_VERSIONREGISTRY_MQH__
