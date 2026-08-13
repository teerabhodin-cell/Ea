//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_Ids.mqh                                |
//| ID generators for the candidate lifecycle:                       |
//|   root_event_id  - the underlying market event (e.g. one         |
//|                     liquidity sweep); CRT and SMC seeing the same |
//|                     sweep should end up with the same root id so |
//|                     the deduplicator can find them.               |
//|   candidate_id   - one specific strategy's candidate.             |
//|   correlation_id - ties a submitted/executed candidate to every   |
//|                     order/position event that follows it.         |
//| Counters reset every EA run - IDs are unique within one run's     |
//| log, not globally across restarts, which is enough for tracing   |
//| a single backtest or live session.                                |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_IDS_MQH__
#define __MLQUANTAI_IDS_MQH__

int g_Ids_CandidateCounter  = 0;
int g_Ids_RootEventCounter  = 0;
int g_Ids_CorrelationCounter = 0;

string Ids_NewCandidateId(string strategyTag)
{
   g_Ids_CandidateCounter++;
   return StringFormat("CND_%s_%06d", strategyTag, g_Ids_CandidateCounter);
}

string Ids_NewRootEventId(string tag="XAU")
{
   g_Ids_RootEventCounter++;
   return StringFormat("EVT_%s_%06d", tag, g_Ids_RootEventCounter);
}

string Ids_NewCorrelationId(string tag="XAU")
{
   g_Ids_CorrelationCounter++;
   return StringFormat("CORR_%s_%06d", tag, g_Ids_CorrelationCounter);
}

#endif // __MLQUANTAI_IDS_MQH__
