//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BoundedAutomationProvenance.mqh   |
//| C5.2 §6.3 Design Contract Rev.15 (FROZEN, commit 07a3581):          |
//| INVARIANT PROV-1 (READER) - canonical E1 provenance classification. |
//| R15-A slice (QA Q3: the pure reader is pulled forward; the E1       |
//| WRITER in SubmitOrderCommand() (R14) is NOT part of this slice).    |
//|                                                                    |
//| E1 = CEREMONY_COMMAND_STATE_CHANGED with to_state ==                 |
//|      "SUBMISSION_IN_PROGRESS".                                       |
//|   CASE A - E1 timestamp earlier than the first-ever                  |
//|            EXECUTION_ROLLOUT_STAGE_CHANGED(to_stage =                  |
//|            DEMO_BOUNDED_AUTOMATION) in the snapshot -> PRE_MECHANISM  |
//|   CASE B - k = count of the exact substring                           |
//|            "\"submission_provenance\":" in the line,                   |
//|            v = EventSerializer_GetStr(line, "submission_provenance"):  |
//|              k == 1 && v == "SYSTEM_BOUNDED_AUTOMATION_V1" -> AUTOMATION|
//|              k == 1 && v == "HUMAN"                        -> HUMAN     |
//|              anything else                                  -> INVALID   |
//|            empty execution_request_id                       -> INVALID   |
//|            AUTOMATION whose request is not in                            |
//|            ExecutionRequestProjection                        -> INVALID   |
//|                                                                    |
//| IMPLEMENTATION CONSTRAINT (Rev.13/QA Round 13): k is COUNTED.         |
//| EventSerializer_HasKey() alone and EventSerializer_GetStr() alone are |
//| never used as the classifier.                                        |
//|                                                                    |
//| Read-only: no EventStore write, no mailbox write, no OrderSend, no   |
//| C2 gate. Not called from MLQuantAI.mq5.                               |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BOUNDEDAUTOMATIONPROVENANCE_MQH__
#define __MLQUANTAI_BOUNDEDAUTOMATIONPROVENANCE_MQH__

#include "MLQuantAI_BoundedAutomationContract.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_CeremonyCommandEventEmission.mqh"
#include "MLQuantAI_ExecutionAuditProjection.mqh"

#define MLQUANTAI_E1_PROVENANCE_KEY_NEEDLE  "\"submission_provenance\":"
#define MLQUANTAI_E1_PROVENANCE_HUMAN_TOKEN "HUMAN"

enum ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE
{
   BOUNDED_AUTOMATION_E1_PROVENANCE_PRE_MECHANISM,   // CASE A - automation cannot have produced it; never counted
   BOUNDED_AUTOMATION_E1_PROVENANCE_AUTOMATION,
   BOUNDED_AUTOMATION_E1_PROVENANCE_HUMAN,
   BOUNDED_AUTOMATION_E1_PROVENANCE_INVALID          // neither HUMAN nor AUTOMATION; fails closed (R15)
};

string BoundedAutomationE1Provenance_ToString(ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE p)
{
   switch(p)
   {
      case BOUNDED_AUTOMATION_E1_PROVENANCE_PRE_MECHANISM: return "PRE_MECHANISM";
      case BOUNDED_AUTOMATION_E1_PROVENANCE_AUTOMATION:    return "AUTOMATION";
      case BOUNDED_AUTOMATION_E1_PROVENANCE_HUMAN:         return "HUMAN";
      case BOUNDED_AUTOMATION_E1_PROVENANCE_INVALID:       return "INVALID";
   }
   return "INVALID";
}

bool BoundedAutomation_IsE1Line(string line)
{
   if(EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_CEREMONY_COMMAND_STATE_CHANGED))
      return false;
   return EventSerializer_GetStr(line, "to_state") == CeremonyCommandState_ToString(CEREMONY_STATE_SUBMISSION_IN_PROGRESS);
}

// Non-overlapping occurrence count of an exact substring.
int BoundedAutomation_CountOccurrences(string haystack, string needle)
{
   int needleLen = StringLen(needle);
   if(needleLen == 0)
      return 0;
   int count = 0;
   int from  = 0;
   while(true)
   {
      int pos = StringFind(haystack, needle, from);
      if(pos < 0)
         break;
      count++;
      from = pos + needleLen;
   }
   return count;
}

//---------------------------------------------------------------------
// The PROV-1 cutoff: the FIRST-EVER EXECUTION_ROLLOUT_STAGE_CHANGED with
// to_stage == DEMO_BOUNDED_AUTOMATION in the snapshot. (Not
// RolloutStageObservationWindow_FindStart(), which returns the LAST match.)
//
// Precision (disclosed at the R15-A checkpoint):
//  - no cutoff line in the snapshot -> every E1 is PRE_MECHANISM. The stage
//    replayed from the same snapshot is then not DEMO_BOUNDED_AUTOMATION,
//    so no automatic issuance can happen anyway (stage gate, Wave 5);
//  - CASE A needs a PROVABLY earlier timestamp. An unparsable timestamp on
//    the cutoff line or on the E1 line cannot prove "earlier", so the E1
//    falls to CASE B (the conservative side, never the permissive one).
//    An E1 in the same second as the cutoff is not earlier -> CASE B.
//---------------------------------------------------------------------
struct BoundedAutomationProvenanceCutoff
{
   bool     found;
   int      line_index;
   datetime ts;          // 0 when unparsable
};

void BoundedAutomation_FindProvenanceCutoff(const string &lines[], BoundedAutomationProvenanceCutoff &out)
{
   out.found      = false;
   out.line_index = -1;
   out.ts         = 0;

   string stageType   = EventTypeToString(EVENT_TYPE_EXECUTION_ROLLOUT_STAGE_CHANGED);
   string targetStage = ExecutionRolloutStageToString(ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION);
   int n = ArraySize(lines);
   for(int i = 0; i < n; i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != stageType) continue;
      if(EventSerializer_GetStr(lines[i], "to_stage") != targetStage) continue;
      out.found      = true;
      out.line_index = i;
      out.ts         = StringToTime(EventSerializer_GetStr(lines[i], "ts"));
      return;
   }
}

//---------------------------------------------------------------------
// Pure PROV-1 classification of one E1 line (CASE A + CASE B + the
// execution_request_id rule). No projection lookup - see the WithLookup
// variant for the AUTOMATION-line lookup rule.
//---------------------------------------------------------------------
ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE BoundedAutomation_ClassifyE1(string line, const BoundedAutomationProvenanceCutoff &cutoff)
{
   // CASE A
   if(!cutoff.found)
      return BOUNDED_AUTOMATION_E1_PROVENANCE_PRE_MECHANISM;
   if(cutoff.ts > 0)
   {
      datetime lineTs = StringToTime(EventSerializer_GetStr(line, "ts"));
      if(lineTs > 0 && lineTs < cutoff.ts)
         return BOUNDED_AUTOMATION_E1_PROVENANCE_PRE_MECHANISM;
   }

   // CASE B
   if(EventSerializer_GetStr(line, "execution_request_id") == "")
      return BOUNDED_AUTOMATION_E1_PROVENANCE_INVALID;

   int    k = BoundedAutomation_CountOccurrences(line, MLQUANTAI_E1_PROVENANCE_KEY_NEEDLE);
   string v = EventSerializer_GetStr(line, "submission_provenance");
   if(k == 1 && v == MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY)
      return BOUNDED_AUTOMATION_E1_PROVENANCE_AUTOMATION;
   if(k == 1 && v == MLQUANTAI_E1_PROVENANCE_HUMAN_TOKEN)
      return BOUNDED_AUTOMATION_E1_PROVENANCE_HUMAN;
   return BOUNDED_AUTOMATION_E1_PROVENANCE_INVALID;
}

// PROV-1 in full: an AUTOMATION line whose execution_request_id has no
// ExecutionRequestProjection record is INVALID (BUD-1's volume lookup).
ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE BoundedAutomation_ClassifyE1WithLookup(string line, const BoundedAutomationProvenanceCutoff &cutoff)
{
   ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c = BoundedAutomation_ClassifyE1(line, cutoff);
   if(c == BOUNDED_AUTOMATION_E1_PROVENANCE_AUTOMATION)
   {
      ExecutionRequestProjectionRecord rec;
      if(!ExecutionRequestProjection_TryGet(EventSerializer_GetStr(line, "execution_request_id"), rec))
         return BOUNDED_AUTOMATION_E1_PROVENANCE_INVALID;
   }
   return c;
}

//---------------------------------------------------------------------
// Whole-snapshot scan. invalid > 0 means R15: automatic issuance halts
// until a human reconciles the EventStore - no automatic recovery.
//---------------------------------------------------------------------
struct BoundedAutomationProvenanceScan
{
   BoundedAutomationProvenanceCutoff cutoff;
   int e1_lines;
   int pre_mechanism;
   int automation;
   int human;
   int invalid;
   int first_invalid_index;   // -1 when none
};

void BoundedAutomation_ScanProvenance(const string &lines[], BoundedAutomationProvenanceScan &out)
{
   BoundedAutomation_FindProvenanceCutoff(lines, out.cutoff);
   out.e1_lines = 0; out.pre_mechanism = 0; out.automation = 0; out.human = 0; out.invalid = 0;
   out.first_invalid_index = -1;

   int n = ArraySize(lines);
   for(int i = 0; i < n; i++)
   {
      if(!BoundedAutomation_IsE1Line(lines[i])) continue;
      out.e1_lines++;
      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c = BoundedAutomation_ClassifyE1WithLookup(lines[i], out.cutoff);
      if(c == BOUNDED_AUTOMATION_E1_PROVENANCE_PRE_MECHANISM)   out.pre_mechanism++;
      else if(c == BOUNDED_AUTOMATION_E1_PROVENANCE_AUTOMATION) out.automation++;
      else if(c == BOUNDED_AUTOMATION_E1_PROVENANCE_HUMAN)      out.human++;
      else
      {
         out.invalid++;
         if(out.first_invalid_index < 0) out.first_invalid_index = i;
      }
   }
}

//---------------------------------------------------------------------
// Rev.15 §2.3.2 step 1b, per request. EXHAUSTED iff >= 1 E1 for this
// execution_request_id classifies AUTOMATION. Any E1 for this request that
// classifies INVALID -> INVALID (the caller fails closed).
//---------------------------------------------------------------------
enum ENUM_BOUNDED_AUTOMATION_REQUEST_E1_STATUS
{
   BOUNDED_AUTOMATION_REQUEST_E1_NONE,
   BOUNDED_AUTOMATION_REQUEST_E1_EXHAUSTED,
   BOUNDED_AUTOMATION_REQUEST_E1_INVALID
};

ENUM_BOUNDED_AUTOMATION_REQUEST_E1_STATUS BoundedAutomation_RequestE1Status(const string &lines[], string executionRequestId)
{
   if(executionRequestId == "")
      return BOUNDED_AUTOMATION_REQUEST_E1_INVALID;

   BoundedAutomationProvenanceCutoff cutoff;
   BoundedAutomation_FindProvenanceCutoff(lines, cutoff);

   bool exhausted = false;
   int n = ArraySize(lines);
   for(int i = 0; i < n; i++)
   {
      if(!BoundedAutomation_IsE1Line(lines[i])) continue;
      if(EventSerializer_GetStr(lines[i], "execution_request_id") != executionRequestId) continue;
      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c = BoundedAutomation_ClassifyE1WithLookup(lines[i], cutoff);
      if(c == BOUNDED_AUTOMATION_E1_PROVENANCE_INVALID)
         return BOUNDED_AUTOMATION_REQUEST_E1_INVALID;
      if(c == BOUNDED_AUTOMATION_E1_PROVENANCE_AUTOMATION)
         exhausted = true;
   }
   return exhausted ? BOUNDED_AUTOMATION_REQUEST_E1_EXHAUSTED : BOUNDED_AUTOMATION_REQUEST_E1_NONE;
}

#endif // __MLQUANTAI_BOUNDEDAUTOMATIONPROVENANCE_MQH__
