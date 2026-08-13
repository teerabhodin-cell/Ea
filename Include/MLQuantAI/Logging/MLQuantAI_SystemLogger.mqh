//+------------------------------------------------------------------+
//| MLQuantAI - Logging/MLQuantAI_SystemLogger.mqh                   |
//| Plain Experts-log printing, separate from the append-only event  |
//| log - this is for human debugging, the event log is the audit    |
//| trail / dataset source.                                           |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_SYSTEMLOGGER_MQH__
#define __MLQUANTAI_SYSTEMLOGGER_MQH__

bool g_SysLog_Debug = false;

void LogDebug(string msg) { if(g_SysLog_Debug) Print("[MLQuantAI] ", msg); }
void LogInfo(string msg)  { Print("[MLQuantAI] ", msg); }
void LogWarn(string msg)  { Print("[MLQuantAI][WARN] ", msg); }
void LogError(string msg) { Print("[MLQuantAI][ERROR] ", msg); }

#endif // __MLQUANTAI_SYSTEMLOGGER_MQH__
