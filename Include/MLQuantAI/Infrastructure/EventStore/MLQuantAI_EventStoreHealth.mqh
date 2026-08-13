//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_EventStoreHealth.mqh|
//| Wraps the Validator into a go/no-go decision: run validation, and |
//| if the store is corrupted, trip Safe Mode.                        |
//|                                                                    |
//| Safe Mode design (confirmed): blocks new candidates only. It does |
//| NOT force-close existing positions - a corrupted event log is a   |
//| bookkeeping/audit-trail problem, not proof that open positions are|
//| in danger, and existing positions already carry their own         |
//| broker-side SL/TP independent of our event store. Forcing closes  |
//| off a read we already know might be wrong would be trading on     |
//| bad information, which is worse than doing nothing new.           |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EVENTSTOREHEALTH_MQH__
#define __MLQUANTAI_EVENTSTOREHEALTH_MQH__

#include "MLQuantAI_EventStoreValidator.mqh"
#include "../../Logging/MLQuantAI_SystemLogger.mqh"

bool   g_EventStoreHealth_SafeMode = false;
string g_EventStoreHealth_Reason   = "";

void EventStoreHealth_TripSafeMode(string reason)
{
   g_EventStoreHealth_SafeMode = true;
   g_EventStoreHealth_Reason = reason;
   LogError("SAFE MODE engaged: " + reason +
            " - new candidates are blocked. Existing positions are left alone (broker-side SL/TP still applies) "
            "until this is manually cleared.");
}

void EventStoreHealth_ClearSafeMode()
{
   g_EventStoreHealth_SafeMode = false;
   g_EventStoreHealth_Reason = "";
}

bool EventStoreHealth_IsSafeMode()          { return g_EventStoreHealth_SafeMode; }
string EventStoreHealth_Reason()            { return g_EventStoreHealth_Reason; }
bool EventStoreHealth_AllowNewCandidates()  { return !g_EventStoreHealth_SafeMode; }

// Validates fileName and trips Safe Mode if it's not clean. Returns the
// validation report so the caller (e.g. OnInit, or a recovery test) can
// log/inspect the specifics beyond just ok/not-ok.
EventStoreValidationReport EventStoreHealth_CheckFile(string fileName)
{
   EventStoreValidationReport report = EventStoreValidator_ValidateFile(fileName);
   if(!report.ok)
   {
      EventStoreHealth_TripSafeMode(StringFormat(
         "event store validation failed (%d malformed, %d gaps, %d duplicates) - first error: %s",
         report.lines_malformed, report.sequence_gaps, report.sequence_duplicates, report.first_error));
   }
   return report;
}

#endif // __MLQUANTAI_EVENTSTOREHEALTH_MQH__
