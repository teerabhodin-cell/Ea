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

#define MLQUANTAI_EA_NAME                  "MLQuantAI"
#define MLQUANTAI_EA_VERSION               "0.1.0"

// Phase C2.2: the fixed identity every MqlTradeRequest.magic this EA ever
// sends carries, and every C2-owned reconciliation path checks against -
// see Docs/PhaseC_C2_1_BrokerSubmissionContract.md's "Order construction"
// section. Arbitrary but fixed: once a real order has ever been sent
// under this value, it must never change (existing broker-side
// positions would stop matching on reconciliation).
#define MLQUANTAI_MAGIC_NUMBER             773700

#define MLQUANTAI_EVENT_SCHEMA_VERSION     "EVENTS_V1"
#define MLQUANTAI_CONTEXT_SCHEMA_VERSION   "CONTEXT_V1"
#define MLQUANTAI_FEATURE_SCHEMA_VERSION   "FEATURES_V1"
#define MLQUANTAI_LABEL_SCHEMA_VERSION     "TBM_V1"
#define MLQUANTAI_REGIME_SCHEMA_VERSION    "REGIME_RULES_V1"
#define MLQUANTAI_ROUTER_SCHEMA_VERSION    "ROUTER_RULES_V1"
#define MLQUANTAI_RISK_SCHEMA_VERSION      "RISK_V1"
#define MLQUANTAI_EXECUTION_SCHEMA_VERSION "EXECUTION_V1"
#define MLQUANTAI_AI_MODEL_VERSION         "NONE"

// Builds the version registry as a JSON fragment (no surrounding braces)
// suitable for passing as the extraJson argument to
// EventStore_LogSystem("SYSTEM_STARTED", ...) - every version constant
// above should be visible in that one event, so replaying the log alone
// tells you exactly which rule sets were active for a given session,
// without cross-referencing source code.
string VersionRegistry_AsJsonFragment()
{
   string s = "";
   s += "\"ea_name\":\""                  + MLQUANTAI_EA_NAME + "\",";
   s += "\"ea_version\":\""               + MLQUANTAI_EA_VERSION + "\",";
   s += "\"event_schema_version\":\""     + MLQUANTAI_EVENT_SCHEMA_VERSION + "\",";
   s += "\"context_schema_version\":\""   + MLQUANTAI_CONTEXT_SCHEMA_VERSION + "\",";
   s += "\"feature_schema_version\":\""   + MLQUANTAI_FEATURE_SCHEMA_VERSION + "\",";
   s += "\"label_schema_version\":\""     + MLQUANTAI_LABEL_SCHEMA_VERSION + "\",";
   s += "\"regime_schema_version\":\""    + MLQUANTAI_REGIME_SCHEMA_VERSION + "\",";
   s += "\"router_schema_version\":\""    + MLQUANTAI_ROUTER_SCHEMA_VERSION + "\",";
   s += "\"risk_schema_version\":\""      + MLQUANTAI_RISK_SCHEMA_VERSION + "\",";
   s += "\"execution_schema_version\":\"" + MLQUANTAI_EXECUTION_SCHEMA_VERSION + "\",";
   s += "\"ai_model_version\":\""         + MLQUANTAI_AI_MODEL_VERSION + "\",";
   s += "\"magic_number\":"               + IntegerToString(MLQUANTAI_MAGIC_NUMBER);
   return s;
}

#endif // __MLQUANTAI_VERSIONREGISTRY_MQH__
