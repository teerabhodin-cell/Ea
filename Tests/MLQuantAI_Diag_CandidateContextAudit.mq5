//+------------------------------------------------------------------+
//| MLQuantAI_Diag_CandidateContextAudit.mq5                          |
//| READ-ONLY diagnostic. Lists every CANDIDATE_CREATED line's own    |
//| candidate_id/context_event_id, every MARKET_CONTEXT_READY line's   |
//| own context_event_id, and flags any CANDIDATE_CREATED whose        |
//| context_event_id has no matching MARKET_CONTEXT_READY line in the  |
//| same file - the exact condition CandidateProjection's own "orphan  |
//| candidate" rejection checks (MLQuantAI_CandidateProjection.mqh).   |
//|                                                                    |
//| Calls ONLY EventStore_ReadAllLines() - opens its own short-lived,  |
//| read-only file handle if no session is already open (see that      |
//| function's own implementation). No EventStore_Open/write, no       |
//| OrderSend/CTrade/broker call of any kind, no projection mutation.   |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

input string I_EventStoreFileName = ""; // REQUIRED - the live EA's own event store file (Common Files); blank aborts

#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStore.mqh>

void OnStart()
{
   Print("=== MLQuantAI diagnostic: candidate/context audit (read-only) ===");

   if(I_EventStoreFileName == "")
   {
      Print("ABORTED: I_EventStoreFileName is blank.");
      return;
   }
   if(!FileIsExist(I_EventStoreFileName, FILE_COMMON))
   {
      Print("ABORTED: file '", I_EventStoreFileName, "' does not exist in Common Files.");
      return;
   }

   // Open directly here (rather than only via EventStore_ReadAllLines,
   // whose own 0-lines return is ambiguous between "genuinely empty"
   // and "open failed") so a locked/in-use file reports its REAL
   // GetLastError() instead of silently looking like an empty file -
   // relevant since the live EA may still be attached to a chart with
   // this same file open in its own write session right now.
   int probeHandle = FileOpen(I_EventStoreFileName, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(probeHandle == INVALID_HANDLE)
   {
      Print("ABORTED: FileOpen failed for '", I_EventStoreFileName, "' - GetLastError()=", GetLastError(),
            ". If the live EA is still attached to a chart, this file may be locked by that session's own open write "
            "handle - try detaching/removing the EA from its chart first, then re-run this script.");
      return;
   }
   FileClose(probeHandle);

   string lines[];
   int n = EventStore_ReadAllLines(I_EventStoreFileName, lines);
   Print("Read ", n, " line(s) from '", I_EventStoreFileName, "'.");
   if(n == 0)
      Print("NOTE: 0 lines read but the file DOES exist and opened successfully for this probe - "
            "either the file is genuinely empty right now, or EventStore_ReadAllLines's own FileOpen call "
            "(a SEPARATE open, immediately after this probe closed) hit a transient lock. If the live EA "
            "reports a non-zero line count for this same file, that is the more trustworthy number.");

   string contextType   = EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY);
   string candidateType = EventTypeToString(EVENT_TYPE_CANDIDATE_CREATED);

   string knownContextIds[];
   int contextCount = 0;

   Print("--- MARKET_CONTEXT_READY lines ---");
   for(int i = 0; i < n; i++)
   {
      if(!EventSerializer_HasKey(lines[i], "type")) continue;
      if(EventSerializer_GetStr(lines[i], "type") != contextType) continue;
      string ctxId = EventSerializer_GetStr(lines[i], "context_event_id");
      Print("  line ", i, ": context_event_id='", ctxId, "'");
      ArrayResize(knownContextIds, contextCount + 1);
      knownContextIds[contextCount] = ctxId;
      contextCount++;
   }
   Print("Total MARKET_CONTEXT_READY lines: ", contextCount);

   Print("--- CANDIDATE_CREATED lines (from==to==CREATED genesis only) ---");
   int candidateCount = 0;
   int orphanCount = 0;
   for(int i = 0; i < n; i++)
   {
      if(!EventSerializer_HasKey(lines[i], "type")) continue;
      if(EventSerializer_GetStr(lines[i], "type") != candidateType) continue;
      candidateCount++;

      string candId = EventSerializer_GetStr(lines[i], "candidate_id");
      string ctxId  = EventSerializer_GetStr(lines[i], "context_event_id");

      bool found = false;
      for(int j = 0; j < contextCount; j++)
         if(knownContextIds[j] == ctxId) { found = true; break; }

      Print("  line ", i, ": candidate_id='", candId, "' context_event_id='", ctxId, "' -> ",
            (found ? "OK (matches a MARKET_CONTEXT_READY line)" : "*** ORPHAN - no matching MARKET_CONTEXT_READY line ***"));
      if(!found) orphanCount++;
   }

   Print("=== Total CANDIDATE_CREATED lines: ", candidateCount, " - orphaned: ", orphanCount, " ===");
   if(orphanCount > 0)
      Print("These orphaned candidate(s) are what causes BrokerSubmissionAudit_StartupRebuild/ManualApproval_StartupRebuild "
            "to fail closed on this file - CandidateProjection's own 'orphan candidate' rejection.");
}
