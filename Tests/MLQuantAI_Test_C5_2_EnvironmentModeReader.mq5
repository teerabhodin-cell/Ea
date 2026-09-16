//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_EnvironmentModeReader.mq5                        |
//| C5.2 Commit 1 (QA-frozen FINAL DESIGN FREEZE, Docs/PhaseC_C5_2_     |
//| ControlledExecutionEnvironmentLadderContract.md §3/§4/§9): proves     |
//| EnvironmentMode_ReadLive()'s mapping is internally consistent with the  |
//| SAME live MQLInfoInteger(MQL_TESTER)/AccountInfoInteger(ACCOUNT_TRADE_    |
//| MODE) facts BrokerSubmissionGate.mqh:132 already reads inline - this       |
//| test cannot pin a single expected environment_mode value (it depends on     |
//| whatever account/context actually runs it), so it asserts the MAPPING        |
//| RULE rather than a fixed answer. Read-only, no OrderSend - running on a        |
//| real account is safe.                                                            |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_EnvironmentModeReader.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void OnStart()
{
   Print("=== MLQuantAI_Test_C5_2_EnvironmentModeReader.mq5 ===");

   ENUM_EXECUTION_ENVIRONMENT_MODE result = EnvironmentMode_ReadLive();
   Print("EnvironmentMode_ReadLive() -> ", ExecutionEnvironmentModeToString(result),
         " (MQLInfoInteger(MQL_TESTER)=", (string)MQLInfoInteger(MQL_TESTER),
         ", AccountInfoInteger(ACCOUNT_TRADE_MODE)=", (string)AccountInfoInteger(ACCOUNT_TRADE_MODE), ")");

   //=====================================================================
   // 1. Tester always wins, regardless of the simulated account's own
   //    ACCOUNT_TRADE_MODE (Strategy Tester always reports
   //    ACCOUNT_TRADE_MODE_DEMO for its simulated account).
   //=====================================================================
   if(MQLInfoInteger(MQL_TESTER))
   {
      Check(result == EXECUTION_ENV_TESTER, "running inside Strategy Tester -> EXECUTION_ENV_TESTER, regardless of the simulated ACCOUNT_TRADE_MODE");
   }
   else
   {
      //==================================================================
      // 2. Outside the Tester, the mapping must match the real
      //    ACCOUNT_TRADE_MODE exactly - never inverted, never defaulted
      //    to the wrong value.
      //==================================================================
      long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
      if(tradeMode == ACCOUNT_TRADE_MODE_REAL)
         Check(result == EXECUTION_ENV_LIVE, "ACCOUNT_TRADE_MODE_REAL -> EXECUTION_ENV_LIVE");
      else if(tradeMode == ACCOUNT_TRADE_MODE_DEMO)
         Check(result == EXECUTION_ENV_DEMO, "ACCOUNT_TRADE_MODE_DEMO -> EXECUTION_ENV_DEMO");
      else
         Check(result == EXECUTION_ENV_NONE, "an unrecognized ACCOUNT_TRADE_MODE (e.g. CONTEST) -> EXECUTION_ENV_NONE, fail-closed rather than guessing");
   }

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
