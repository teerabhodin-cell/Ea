//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_EventStoreHealth.mqh|
//| Wraps the Validator into a go/no-go decision: run validation, and |
//| if the store is corrupted, trip Safe Mode. Delegates the actual   |
//| flag to MLQuantAI_SafeModeState.mqh, which EventStore.mqh ALSO    |
//| trips directly on a durable-write failure - both paths share one  |
//| flag instead of each owning a separate one.                       |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EVENTSTOREHEALTH_MQH__
#define __MLQUANTAI_EVENTSTOREHEALTH_MQH__

#include "MLQuantAI_SafeModeState.mqh"
#include "MLQuantAI_EventStoreValidator.mqh"

void   EventStoreHealth_TripSafeMode(string reason)   { SafeMode_Trip(reason); }
void   EventStoreHealth_ClearSafeMode()                { SafeMode_Clear(); }
bool   EventStoreHealth_IsSafeMode()                   { return SafeMode_IsActive(); }
string EventStoreHealth_Reason()                       { return SafeMode_Reason(); }
bool   EventStoreHealth_AllowNewCandidates()           { return SafeMode_AllowNewCandidates(); }

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
