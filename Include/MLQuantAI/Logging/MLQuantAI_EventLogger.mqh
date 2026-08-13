//+------------------------------------------------------------------+
//| MLQuantAI - Logging/MLQuantAI_EventLogger.mqh                    |
//| Append-only JSONL lifecycle log - the source of truth the spec   |
//| describes. Every candidate state transition writes exactly one   |
//| line here and nothing is ever rewritten, so the file itself is   |
//| the audit trail: replaying it reconstructs every candidate's     |
//| full history.                                                     |
//|                                                                    |
//| File handle is opened ONCE in OnInit and kept open for the EA's  |
//| lifetime - QuantixFlowEA's CSV logger originally reopened its     |
//| file on every single write and that alone made tick-by-tick       |
//| backtests crawl. This logger does it right from the start.        |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EVENTLOGGER_MQH__
#define __MLQUANTAI_EVENTLOGGER_MQH__

#include "../Core/MLQuantAI_TradeCandidate.mqh"
#include "../Core/MLQuantAI_StateMachine.mqh"
#include "../Core/MLQuantAI_ReasonCodes.mqh"
#include "../Core/MLQuantAI_VersionRegistry.mqh"
#include "MLQuantAI_SystemLogger.mqh"

int g_EventLog_Handle = INVALID_HANDLE;

bool EventLogger_Open(string fileName)
{
   g_EventLog_Handle = FileOpen(fileName, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(g_EventLog_Handle == INVALID_HANDLE)
   {
      LogWarn("failed to open event log '" + fileName + "', err=" + IntegerToString(GetLastError()));
      return false;
   }
   FileSeek(g_EventLog_Handle, 0, SEEK_END);
   return true;
}

void EventLogger_Close()
{
   if(g_EventLog_Handle != INVALID_HANDLE)
   {
      FileClose(g_EventLog_Handle);
      g_EventLog_Handle = INVALID_HANDLE;
   }
}

// Minimal hand-rolled JSON: every value here is an internally-generated
// ID/enum/number, never free-text/user input, so there's nothing that
// needs escaping. If a free-text field is ever added to this line, it
// MUST be escaped (quotes/backslashes/control chars) before being
// interpolated here, or one bad string can corrupt every line after it.
string EventLogger_JsonLine(string candidateId, string rootEventId, string correlationId,
                             ENUM_CANDIDATE_STATE fromState, ENUM_CANDIDATE_STATE toState,
                             ENUM_REASON_CODE reason, int strategyId, string extraJsonFields)
{
   string s = "{";
   s += "\"ts\":\"" + TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"schema_version\":\"" + MLQUANTAI_SCHEMA_VERSION + "\",";
   s += "\"candidate_id\":\"" + candidateId + "\",";
   s += "\"root_event_id\":\"" + rootEventId + "\",";
   s += "\"correlation_id\":\"" + correlationId + "\",";
   s += "\"strategy_id\":" + IntegerToString(strategyId) + ",";
   s += "\"strategy\":\"" + StrategyIdToString(strategyId) + "\",";
   s += "\"from_state\":\"" + CandidateStateToString(fromState) + "\",";
   s += "\"to_state\":\"" + CandidateStateToString(toState) + "\",";
   s += "\"reason\":\"" + ReasonCodeToString(reason) + "\"";
   if(extraJsonFields != "")
      s += "," + extraJsonFields;
   s += "}";
   return s;
}

void EventLogger_WriteLine(string jsonLine)
{
   if(g_EventLog_Handle == INVALID_HANDLE) return;
   FileWriteString(g_EventLog_Handle, jsonLine + "\r\n");
}

// Transitions the candidate through the state machine AND appends the
// corresponding lifecycle line in one call, so it is structurally
// impossible to log a transition the state machine itself rejected -
// either both happen or neither does.
bool EventLogger_LogTransition(TradeCandidate &c, ENUM_CANDIDATE_STATE to, ENUM_REASON_CODE reason, string extraJsonFields="")
{
   ENUM_CANDIDATE_STATE from = c.state;
   if(!TradeCandidate_Transition(c, to, reason))
   {
      LogWarn(StringFormat("illegal candidate transition blocked: %s  %s -> %s",
              c.candidate_id, CandidateStateToString(from), CandidateStateToString(to)));
      return false;
   }
   EventLogger_WriteLine(EventLogger_JsonLine(c.candidate_id, c.root_event_id, c.correlation_id,
                                               from, to, reason, c.strategy_id, extraJsonFields));
   return true;
}

#endif // __MLQUANTAI_EVENTLOGGER_MQH__
