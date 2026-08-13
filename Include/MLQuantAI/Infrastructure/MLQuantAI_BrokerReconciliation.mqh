//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/MLQuantAI_BrokerReconciliation.mqh    |
//| Compares replayed RuntimeState against what MT5 actually reports  |
//| right now: for every candidate the Event Store says reached       |
//| EXECUTED, is there a real open position whose comment carries its |
//| correlation_id? A mismatch means the Event Store's belief about   |
//| the world has diverged from the broker's - trip Safe Mode rather  |
//| than trade on a belief that might be wrong.                       |
//|                                                                    |
//| This is REAL MT5 data (PositionsTotal/PositionGetTicket/           |
//| PositionGetString), not the mock used in                          |
//| Tests/MLQuantAI_Test_BrokerReconciliation.mq5 - that test proves   |
//| the matching CONTRACT works without depending on live terminal    |
//| state; this file is what a real EA calls from OnInit. Until       |
//| Phase B's Execution Engine exists and tags real orders with        |
//| correlation_id in the position comment, no EA in this codebase     |
//| ever opens a real position, so in practice this always reconciles |
//| trivially (0 replayed EXECUTED candidates, 0 real positions) -     |
//| but the real comparison function is what will need to work        |
//| correctly once that's no longer true.                              |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BROKERRECONCILIATION_MQH__
#define __MLQUANTAI_BROKERRECONCILIATION_MQH__

#include "EventStore/MLQuantAI_StateProjector.mqh"
#include "../Logging/MLQuantAI_SystemLogger.mqh"
#include "EventStore/MLQuantAI_SafeModeState.mqh"

struct BrokerReconciliationReport
{
   bool   ok;
   int    replayed_executed_count;
   int    matched_count;
   int    mismatched_count;
   string first_mismatch_candidate_id;
};

void BrokerReconciliationReport_Init(BrokerReconciliationReport &r)
{
   r.ok = true;
   r.replayed_executed_count = 0;
   r.matched_count = 0;
   r.mismatched_count = 0;
   r.first_mismatch_candidate_id = "";
}

// True if some currently-open MT5 position's comment carries correlationId.
// Real orders (Phase B) are expected to tag their comment with the
// correlation_id so this lookup works - see
// Tests/MLQuantAI_Test_BrokerReconciliation.mq5 for the same contract
// tested against a mock position list.
bool BrokerReconciliation_HasMatchingPosition(string correlationId)
{
   if(correlationId == "") return false;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      string comment = PositionGetString(POSITION_COMMENT);
      if(StringFind(comment, correlationId) >= 0)
         return true;
   }
   return false;
}

// Call after ReplayEngine_Run() has populated g_Proj_Candidates. Walks
// every replayed candidate currently in CANDIDATE_EXECUTED and checks it
// against real MT5 position state. Trips Safe Mode on ANY mismatch - per
// the spec, "Mismatch -> Safe Mode", no partial-trust middle ground.
BrokerReconciliationReport BrokerReconciliation_CheckAll()
{
   BrokerReconciliationReport report;
   BrokerReconciliationReport_Init(report);

   for(int i = 0; i < g_Proj_Count; i++)
   {
      if(g_Proj_Candidates[i].state != CANDIDATE_EXECUTED) continue;
      report.replayed_executed_count++;

      if(BrokerReconciliation_HasMatchingPosition(g_Proj_Candidates[i].correlation_id))
      {
         report.matched_count++;
      }
      else
      {
         report.mismatched_count++;
         report.ok = false;
         if(report.first_mismatch_candidate_id == "")
            report.first_mismatch_candidate_id = g_Proj_Candidates[i].candidate_id;
      }
   }

   if(!report.ok)
   {
      SafeMode_Trip(StringFormat(
         "broker reconciliation mismatch: %d of %d replayed EXECUTED candidates have no matching MT5 position "
         "(first: %s) - event store and broker state have diverged",
         report.mismatched_count, report.replayed_executed_count, report.first_mismatch_candidate_id));
   }
   else
   {
      LogInfo(StringFormat("broker reconciliation OK: %d/%d replayed EXECUTED candidates matched a real position",
                            report.matched_count, report.replayed_executed_count));
   }

   return report;
}

#endif // __MLQUANTAI_BROKERRECONCILIATION_MQH__
