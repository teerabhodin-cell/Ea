//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_EnvironmentIdentitySnapshot.mqh   |
//| C6.1: EnvironmentIdentitySnapshot - a pure, read-only observation |
//| of environment/identity/authority runtime facts. Authority: NONE. |
//| Advisory only - per the C6.1 design freeze:                       |
//|  - MUST NOT call OrderSend/BrokerSubmission_Submit/EventStore_Log*/|
//|    ManualApprovalRegistry_Grant*/SafeMode_* anywhere in this file. |
//|  - MUST NOT replace any sealed submission-time gate's own fresh   |
//|    runtime read - every sealed gate re-reads its own facts live,  |
//|    this snapshot is never a cached substitute for that.           |
//|  - MUST NOT create persistent execution denial state - a negative |
//|    finding here is diagnostic-only, never a pipeline suppression. |
//|  - observed_at is diagnostic metadata only, never a freshness     |
//|    guarantee for the facts captured alongside it.                 |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ENVIRONMENTIDENTITYSNAPSHOT_MQH__
#define __MLQUANTAI_ENVIRONMENTIDENTITYSNAPSHOT_MQH__

#include "MLQuantAI_SafetyGate.mqh"
#include "../Logging/MLQuantAI_SystemLogger.mqh"

#define MLQUANTAI_ENVIRONMENT_IDENTITY_SNAPSHOT_V1 "ENVIRONMENT_IDENTITY_SNAPSHOT_V1"

struct EnvironmentIdentitySnapshot
{
   string   snapshot_schema_version;
   datetime observed_at; // diagnostic metadata only - see this file's header

   long     account_trade_mode;
   bool     is_demo;
   long     account_login;
   string   account_server;
   string   symbol;

   bool     terminal_trade_allowed;
   bool     mql_trade_allowed;
   bool     account_trade_allowed;
   bool     account_trade_expert;
   bool     terminal_connected; // diagnostic only, never gates - see header

   bool     account_login_allowlisted;
   bool     account_server_allowlisted;
   bool     symbol_allowlisted;
};

void EnvironmentIdentitySnapshot_Init(EnvironmentIdentitySnapshot &s)
{
   s.snapshot_schema_version = MLQUANTAI_ENVIRONMENT_IDENTITY_SNAPSHOT_V1;
   s.observed_at = 0;

   s.account_trade_mode = 0;
   s.is_demo = false;
   s.account_login = 0;
   s.account_server = "";
   s.symbol = "";

   s.terminal_trade_allowed = false;
   s.mql_trade_allowed = false;
   s.account_trade_allowed = false;
   s.account_trade_expert = false;
   s.terminal_connected = false;

   s.account_login_allowlisted = false;
   s.account_server_allowlisted = false;
   s.symbol_allowlisted = false;
}

// Pure observation - live runtime reads only, no state mutation, no
// broker/order/EventStore call anywhere. Allowlist comparisons reuse
// SafetyGate_AllowlistContains() unchanged (empty allowlist = fails
// closed, same convention every other allowlist in this project
// follows) rather than re-implementing that logic here.
void EnvironmentIdentitySnapshot_Build(string accountAllowlist, string serverAllowlist, string symbolAllowlist,
                                          EnvironmentIdentitySnapshot &outSnapshot)
{
   EnvironmentIdentitySnapshot_Init(outSnapshot);

   outSnapshot.observed_at = TimeCurrent();

   outSnapshot.account_trade_mode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   outSnapshot.is_demo            = (outSnapshot.account_trade_mode == ACCOUNT_TRADE_MODE_DEMO);
   outSnapshot.account_login      = AccountInfoInteger(ACCOUNT_LOGIN);
   outSnapshot.account_server     = AccountInfoString(ACCOUNT_SERVER);
   outSnapshot.symbol             = _Symbol;

   outSnapshot.terminal_trade_allowed = (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
   outSnapshot.mql_trade_allowed      = (bool)MQLInfoInteger(MQL_TRADE_ALLOWED);
   outSnapshot.account_trade_allowed  = (bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED);
   outSnapshot.account_trade_expert   = (bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
   outSnapshot.terminal_connected     = (bool)TerminalInfoInteger(TERMINAL_CONNECTED);

   outSnapshot.account_login_allowlisted  = SafetyGate_AllowlistContains(accountAllowlist, IntegerToString(outSnapshot.account_login));
   outSnapshot.account_server_allowlisted = SafetyGate_AllowlistContains(serverAllowlist, outSnapshot.account_server);
   outSnapshot.symbol_allowlisted         = SafetyGate_AllowlistContains(symbolAllowlist, outSnapshot.symbol);
}

// Diagnostic-only formatter - per the C6.1 design freeze, "allowlist is
// empty" and "value not found in a non-empty allowlist" MUST NOT be
// collapsed into one message, even though both are the same mismatch
// operationally.
string EnvironmentIdentitySnapshot_AllowlistDetail(string observedValue, string allowlist, bool matched)
{
   if(matched) return "OK";
   if(allowlist == "") return "allowlist is empty (unconfigured - fails closed by convention)";
   return "value '" + observedValue + "' not found in configured allowlist [" + allowlist + "]";
}

// Logs the full snapshot. Advisory only - never suppresses the
// pipeline, never mutates any state, never called by or fed into any
// authoritative gate. ENUM_REASON_CODE names referenced in the log
// text are for human cross-reference to the matching sealed gate only
// - this function never returns or stores an ENUM_REASON_CODE itself,
// per the C6.1 design freeze's "no parallel reason-code universe" rule.
void EnvironmentIdentitySnapshot_Log(const EnvironmentIdentitySnapshot &s, string accountAllowlist, string serverAllowlist, string symbolAllowlist)
{
   LogInfo("C6.1 ENVIRONMENT IDENTITY SNAPSHOT: schema=" + s.snapshot_schema_version +
           " observed_at=" + TimeToString(s.observed_at, TIME_DATE|TIME_SECONDS) +
           " account_trade_mode=" + IntegerToString(s.account_trade_mode) +
           " is_demo=" + (s.is_demo ? "true" : "false") +
           " account_login=" + IntegerToString(s.account_login) +
           " account_server=" + s.account_server +
           " symbol=" + s.symbol +
           " terminal_trade_allowed=" + (s.terminal_trade_allowed ? "true" : "false") +
           " mql_trade_allowed=" + (s.mql_trade_allowed ? "true" : "false") +
           " account_trade_allowed=" + (s.account_trade_allowed ? "true" : "false") +
           " account_trade_expert=" + (s.account_trade_expert ? "true" : "false") +
           " terminal_connected(diagnostic_only)=" + (s.terminal_connected ? "true" : "false"));

   if(!s.is_demo)
      LogWarn("C6.1 ENVIRONMENT IDENTITY: is_demo=false (ACCOUNT_TRADE_MODE != ACCOUNT_TRADE_MODE_DEMO) - "
              "not eligible for C6 broker authority; ref EXECUTION_ENVIRONMENT_NOT_PERMITTED");
   if(!s.terminal_trade_allowed)
      LogWarn("C6.1 ENVIRONMENT IDENTITY: terminal_trade_allowed=false; ref EXECUTION_TERMINAL_TRADE_DISABLED");
   if(!s.mql_trade_allowed)
      LogWarn("C6.1 ENVIRONMENT IDENTITY: mql_trade_allowed=false - program-level automated trading permission "
              "is disabled for this EA instance (no existing sealed reason-code match)");
   if(!s.account_trade_allowed)
      LogWarn("C6.1 ENVIRONMENT IDENTITY: account_trade_allowed=false; ref EXECUTION_ACCOUNT_TRADE_DISABLED");
   if(!s.account_trade_expert)
      LogWarn("C6.1 ENVIRONMENT IDENTITY: account_trade_expert=false; ref EXECUTION_EXPERT_TRADE_DISABLED");
   if(!s.account_login_allowlisted)
      LogWarn("C6.1 ENVIRONMENT IDENTITY: account_login not allowlisted - " +
              EnvironmentIdentitySnapshot_AllowlistDetail(IntegerToString(s.account_login), accountAllowlist, s.account_login_allowlisted) +
              "; ref EXECUTION_ACCOUNT_NOT_ALLOWED");
   if(!s.account_server_allowlisted)
      LogWarn("C6.1 ENVIRONMENT IDENTITY: account_server not allowlisted - " +
              EnvironmentIdentitySnapshot_AllowlistDetail(s.account_server, serverAllowlist, s.account_server_allowlisted) +
              "; ref EXECUTION_SERVER_NOT_ALLOWED");
   if(!s.symbol_allowlisted)
      LogWarn("C6.1 ENVIRONMENT IDENTITY: symbol not allowlisted - " +
              EnvironmentIdentitySnapshot_AllowlistDetail(s.symbol, symbolAllowlist, s.symbol_allowlisted) +
              "; ref EXECUTION_SYMBOL_NOT_ALLOWED");
}

#endif // __MLQUANTAI_ENVIRONMENTIDENTITYSNAPSHOT_MQH__
