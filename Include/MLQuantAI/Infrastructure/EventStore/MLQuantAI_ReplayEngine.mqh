//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh |
//| Reads a store file end to end and folds every LifecycleEvent AND  |
//| SystemEvent through the StateProjector, in file order. This is    |
//| the "delete the snapshot, replay the log, get the same state      |
//| back" capability event sourcing exists for - there is no separate |
//| snapshot format in Phase A, the event log alone is authoritative. |
//|                                                                    |
//| ExecutionEvent lines are counted but NOT projected: Phase A has no|
//| Execution Engine (that's Phase B/Sprint 3), so nothing in this    |
//| codebase writes ticket/fill/slippage data yet - there is nothing  |
//| real to reconstruct. Building projection logic against a schema   |
//| nothing populates would be speculative, not tested; execution     |
//| replay gets built alongside the Execution Engine itself.          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_REPLAYENGINE_MQH__
#define __MLQUANTAI_REPLAYENGINE_MQH__

#include "MLQuantAI_EventStore.mqh"
#include "MLQuantAI_StateProjector.mqh"

struct ReplayReport
{
   bool     ok;
   int      lifecycle_events_total;
   int      lifecycle_events_applied;
   int      lifecycle_events_failed;
   int      system_events_total;
   int      system_events_applied;
   int      execution_events_seen; // counted only, not projected in Phase A
   string   first_error;
};

void ReplayReport_Init(ReplayReport &r)
{
   r.ok = true;
   r.lifecycle_events_total = 0;
   r.lifecycle_events_applied = 0;
   r.lifecycle_events_failed = 0;
   r.system_events_total = 0;
   r.system_events_applied = 0;
   r.execution_events_seen = 0;
   r.first_error = "";
}

// Runs replay against fileName and leaves the result in the StateProjector
// module globals (g_Proj_Candidates / g_Proj_RuntimeState) for the caller
// to inspect via StateProjector_TryGetState() etc. Resets the projector
// first, so this is always a from-scratch replay, never incremental.
ReplayReport ReplayEngine_Run(string fileName)
{
   ReplayReport report;
   ReplayReport_Init(report);

   StateProjector_Reset();

   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);

   for(int i = 0; i < n; i++)
   {
      string line = lines[i];
      if(line == "") continue;

      ENUM_EVENT_CATEGORY cat = EventSerializer_PeekCategory(line);

      if(cat == EVENT_CAT_LIFECYCLE)
      {
         LifecycleEvent e;
         if(!EventSerializer_ParseLifecycle(line, e))
         {
            report.lifecycle_events_failed++;
            report.ok = false;
            if(report.first_error == "")
               report.first_error = StringFormat("line %d: could not parse as LifecycleEvent", i);
            continue;
         }
         report.lifecycle_events_total++;

         string err;
         if(!StateProjector_Apply(e, err))
         {
            report.lifecycle_events_failed++;
            report.ok = false;
            if(report.first_error == "")
               report.first_error = StringFormat("line %d: %s", i, err);
         }
         else
         {
            report.lifecycle_events_applied++;
         }
      }
      else if(cat == EVENT_CAT_SYSTEM)
      {
         SystemEvent se;
         if(!EventSerializer_ParseSystem(line, se))
         {
            report.ok = false;
            if(report.first_error == "")
               report.first_error = StringFormat("line %d: could not parse as SystemEvent", i);
            continue;
         }
         report.system_events_total++;

         string err;
         if(!StateProjector_ApplySystem(se, err))
         {
            report.ok = false;
            if(report.first_error == "")
               report.first_error = StringFormat("line %d: %s", i, err);
         }
         else
         {
            report.system_events_applied++;
         }
      }
      else if(cat == EVENT_CAT_EXECUTION)
      {
         report.execution_events_seen++;
      }
   }
   return report;
}

#endif // __MLQUANTAI_REPLAYENGINE_MQH__
