//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_AccountSnapshot.mqh                   |
//| Account state captured once per MarketContext build, so risk     |
//| decisions and AI features see a consistent snapshot instead of   |
//| re-querying AccountInfoDouble() at random points in the pipeline |
//| where the balance could have moved between reads.                |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ACCOUNTSNAPSHOT_MQH__
#define __MLQUANTAI_ACCOUNTSNAPSHOT_MQH__

#include "MLQuantAI_VersionRegistry.mqh"

struct AccountSnapshot
{
   string   context_schema_version; // MLQUANTAI_CONTEXT_SCHEMA_VERSION
   double   balance;
   double   equity;
   double   margin_level;      // 0 if no margin used
   int      open_positions_count;
   double   open_risk_percent; // sum of risk on all currently-open positions, as % of equity
   double   daily_pnl_percent;
   double   drawdown_from_peak_percent;
};

void AccountSnapshot_Init(AccountSnapshot &a)
{
   a.context_schema_version = MLQUANTAI_CONTEXT_SCHEMA_VERSION;
   a.balance = 0;
   a.equity = 0;
   a.margin_level = 0;
   a.open_positions_count = 0;
   a.open_risk_percent = 0;
   a.daily_pnl_percent = 0;
   a.drawdown_from_peak_percent = 0;
}

#endif // __MLQUANTAI_ACCOUNTSNAPSHOT_MQH__
