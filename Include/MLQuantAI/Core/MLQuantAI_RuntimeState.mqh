//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_RuntimeState.mqh                      |
//| System-wide derived state - what the StateProjector rebuilds by   |
//| folding SystemEvents + LifecycleEvents, and what the live EA      |
//| (Phase B+) carries as its working state. Kept separate from any   |
//| single TradeCandidate: this is about the whole system's health,   |
//| not one candidate's lifecycle.                                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_RUNTIMESTATE_MQH__
#define __MLQUANTAI_RUNTIMESTATE_MQH__

#include "MLQuantAI_Enums.mqh"
#include "MLQuantAI_VersionRegistry.mqh"

struct RuntimeState
{
   string                    event_schema_version; // MLQUANTAI_EVENT_SCHEMA_VERSION - what this snapshot was built from
   string                    runtime_session_id;
   datetime                  session_start_time;
   long                      last_sequence_number;

   ENUM_EVENT_STORE_HEALTH   event_store_health;
   bool                      safe_mode;
   string                    safe_mode_reason;

   int      candidates_created;
   int      candidates_submitted;
   int      candidates_executed;
   int      candidates_rejected;
   int      candidates_merged;
   int      candidates_expired;
};

void RuntimeState_Init(RuntimeState &s)
{
   s.event_schema_version = MLQUANTAI_EVENT_SCHEMA_VERSION;
   s.runtime_session_id = "";
   s.session_start_time = 0;
   s.last_sequence_number = 0;
   s.event_store_health = EVENT_STORE_HEALTH_UNKNOWN;
   s.safe_mode = false;
   s.safe_mode_reason = "";
   s.candidates_created = 0;
   s.candidates_submitted = 0;
   s.candidates_executed = 0;
   s.candidates_rejected = 0;
   s.candidates_merged = 0;
   s.candidates_expired = 0;
}

#endif // __MLQUANTAI_RUNTIMESTATE_MQH__
