//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_SafeModeState.mqh|
//| The Safe Mode flag itself, split out from EventStoreHealth.mqh so |
//| EventStore.mqh can trip it directly on a durable-write failure    |
//| without creating a circular include (EventStore -> Health ->      |
//| Validator -> EventStore). This file has NO dependency on the      |
//| Event Store or Validator - just the flag and its accessors.       |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_SAFEMODESTATE_MQH__
#define __MLQUANTAI_SAFEMODESTATE_MQH__

#include "../../Logging/MLQuantAI_SystemLogger.mqh"

bool   g_SafeMode_Active = false;
string g_SafeMode_Reason = "";

// Safe Mode design (confirmed with the user): blocks new candidates only.
// It does NOT force-close existing positions - a corrupted/unwritable
// event store is a bookkeeping/audit-trail problem, not proof that open
// positions are in danger, and existing positions already carry their own
// broker-side SL/TP independent of our event store. Forcing closes off a
// read we already know might be wrong would be trading on bad
// information, which is worse than doing nothing new.
void SafeMode_Trip(string reason)
{
   g_SafeMode_Active = true;
   g_SafeMode_Reason = reason;
   LogError("SAFE MODE engaged: " + reason +
            " - new candidates are blocked. Existing positions are left alone (broker-side SL/TP still applies) "
            "until this is manually cleared.");
}

void SafeMode_Clear()
{
   g_SafeMode_Active = false;
   g_SafeMode_Reason = "";
}

bool   SafeMode_IsActive()           { return g_SafeMode_Active; }
string SafeMode_Reason()             { return g_SafeMode_Reason; }
bool   SafeMode_AllowNewCandidates() { return !g_SafeMode_Active; }

#endif // __MLQUANTAI_SAFEMODESTATE_MQH__
