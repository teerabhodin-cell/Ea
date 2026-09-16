//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_EnvironmentModeReader.mqh          |
//| C5.2 Commit 1 (QA-frozen FINAL DESIGN FREEZE, Docs/PhaseC_C5_2_     |
//| ControlledExecutionEnvironmentLadderContract.md §3/§4/§9): the        |
//| single "fresh, live-read environment_mode" function every C5.2         |
//| enforcement point (§3's transition-time check, §4 rule 5's OnInit       |
//| check, §9's per-tick OnTick check) is required to use - "never a         |
//| cached/remembered value" (§3), one source of truth for the real            |
//| account fact, matching the SAME live ACCOUNT_TRADE_MODE read                |
//| MLQuantAI_BrokerSubmissionGate.mqh:132 already performs inline for            |
//| its own narrower DEMO-only check.                                              |
//|                                                                                  |
//| Pure read, no side effect, no Safe Mode, no candidate-lifecycle                 |
//| authority, no OrderSend. Mirrors ExecutionPolicy.environment_mode's own          |
//| ENUM_EXECUTION_ENVIRONMENT_MODE shape (Core/MLQuantAI_Enums.mqh,                  |
//| Class 1, untouched) - never a new mode value, never a new meaning for              |
//| an existing one.                                                                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ENVIRONMENTMODEREADER_MQH__
#define __MLQUANTAI_ENVIRONMENTMODEREADER_MQH__

#include "../Core/MLQuantAI_Enums.mqh"

// EXECUTION_ENV_TESTER wins over the account's own ACCOUNT_TRADE_MODE
// whenever MQLInfoInteger(MQL_TESTER) is true - Strategy Tester always
// reports ACCOUNT_TRADE_MODE_DEMO for its simulated account, which would
// otherwise be indistinguishable from a genuine DEMO account (same
// ambiguity C5.0's research already found, C5.2 §3 comment). Outside the
// Tester: ACCOUNT_TRADE_MODE_REAL -> LIVE, ACCOUNT_TRADE_MODE_DEMO ->
// DEMO, anything else (e.g. ACCOUNT_TRADE_MODE_CONTEST, or a future
// broker-reported value this codebase does not yet recognize) -> NONE,
// fail-closed rather than guessing.
ENUM_EXECUTION_ENVIRONMENT_MODE EnvironmentMode_ReadLive()
{
   if(MQLInfoInteger(MQL_TESTER))
      return EXECUTION_ENV_TESTER;

   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tradeMode == ACCOUNT_TRADE_MODE_REAL) return EXECUTION_ENV_LIVE;
   if(tradeMode == ACCOUNT_TRADE_MODE_DEMO) return EXECUTION_ENV_DEMO;
   return EXECUTION_ENV_NONE;
}

#endif // __MLQUANTAI_ENVIRONMENTMODEREADER_MQH__
