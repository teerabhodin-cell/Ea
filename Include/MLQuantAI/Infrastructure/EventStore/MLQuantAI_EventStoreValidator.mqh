//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_EventStoreValidator.mqh|
//| Reads a store file and checks it's internally consistent:         |
//| every line parses, ends in a closed brace (catches a truncated    |
//| write from a mid-write crash), and within each session's lines,   |
//| sequence_number is contiguous starting at 1 with no gaps or       |
//| duplicates. This is what EventStoreHealth relies on to decide      |
//| whether to trip Safe Mode.                                        |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EVENTSTOREVALIDATOR_MQH__
#define __MLQUANTAI_EVENTSTOREVALIDATOR_MQH__

#include "MLQuantAI_EventStore.mqh"

struct EventStoreValidationReport
{
   bool     ok;
   int      lines_total;
   int      lines_parsed_ok;
   int      lines_malformed;
   int      sequence_gaps;
   int      sequence_duplicates;
   string   first_error;
};

void EventStoreValidationReport_Init(EventStoreValidationReport &r)
{
   r.ok = true;
   r.lines_total = 0;
   r.lines_parsed_ok = 0;
   r.lines_malformed = 0;
   r.sequence_gaps = 0;
   r.sequence_duplicates = 0;
   r.first_error = "";
}

EventStoreValidationReport EventStoreValidator_ValidateLines(const string &lines[])
{
   EventStoreValidationReport report;
   EventStoreValidationReport_Init(report);

   string trackedSessions[];
   long   trackedLastSeq[];
   ArrayResize(trackedSessions, 0);
   ArrayResize(trackedLastSeq, 0);

   int n = ArraySize(lines);
   report.lines_total = n;

   for(int i = 0; i < n; i++)
   {
      string line = lines[i];
      long seq; string sessionId;

      if(line == "" || !EventSerializer_PeekSequence(line, seq, sessionId))
      {
         report.lines_malformed++;
         report.ok = false;
         if(report.first_error == "")
            report.first_error = StringFormat("line %d: malformed / missing seq or session_id", i);
         continue;
      }

      if(StringGetCharacter(line, StringLen(line) - 1) != '}')
      {
         report.lines_malformed++;
         report.ok = false;
         if(report.first_error == "")
            report.first_error = StringFormat("line %d: does not end with '}' - looks truncated (partial write)", i);
         continue;
      }

      report.lines_parsed_ok++;

      int idx = -1;
      for(int j = 0; j < ArraySize(trackedSessions); j++)
         if(trackedSessions[j] == sessionId) { idx = j; break; }

      if(idx < 0)
      {
         ArrayResize(trackedSessions, ArraySize(trackedSessions) + 1);
         ArrayResize(trackedLastSeq, ArraySize(trackedLastSeq) + 1);
         idx = ArraySize(trackedSessions) - 1;
         trackedSessions[idx] = sessionId;
         trackedLastSeq[idx] = 0;

         if(seq != 1)
         {
            report.sequence_gaps++;
            report.ok = false;
            if(report.first_error == "")
               report.first_error = StringFormat("line %d: session %s starts at seq %d, expected 1", i, sessionId, (int)seq);
         }
      }
      else
      {
         long expected = trackedLastSeq[idx] + 1;
         if(seq <= trackedLastSeq[idx])
         {
            report.sequence_duplicates++;
            report.ok = false;
            if(report.first_error == "")
               report.first_error = StringFormat("line %d: session %s duplicate/backwards seq %d (last was %d)",
                                                  i, sessionId, (int)seq, (int)trackedLastSeq[idx]);
            continue; // don't advance trackedLastSeq on a duplicate/backwards seq
         }
         else if(seq != expected)
         {
            report.sequence_gaps++;
            report.ok = false;
            if(report.first_error == "")
               report.first_error = StringFormat("line %d: session %s gap - expected seq %d, got %d",
                                                  i, sessionId, (int)expected, (int)seq);
         }
      }
      trackedLastSeq[idx] = seq;
   }

   return report;
}

EventStoreValidationReport EventStoreValidator_ValidateFile(string fileName)
{
   string lines[];
   EventStore_ReadAllLines(fileName, lines);
   return EventStoreValidator_ValidateLines(lines);
}

#endif // __MLQUANTAI_EVENTSTOREVALIDATOR_MQH__
