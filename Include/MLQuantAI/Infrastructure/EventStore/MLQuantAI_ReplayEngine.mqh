//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh |
//| Reads a store file end to end and folds every LifecycleEvent      |
//| through the StateProjector, in file order. This is the "delete    |
//| the snapshot, replay the log, get the same state back" capability |
//| event sourcing exists for - there is no separate snapshot format  |
//| in Phase A, the event log alone is authoritative.                  |
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
   string   first_error;
};

void ReplayReport_Init(ReplayReport &r)
{
   r.ok = true;
   r.lifecycle_events_total = 0;
   r.lifecycle_events_applied = 0;
   r.lifecycle_events_failed = 0;
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
      if(EventSerializer_PeekCategory(line) != EVENT_CAT_LIFECYCLE) continue;

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
   return report;
}

#endif // __MLQUANTAI_REPLAYENGINE_MQH__
