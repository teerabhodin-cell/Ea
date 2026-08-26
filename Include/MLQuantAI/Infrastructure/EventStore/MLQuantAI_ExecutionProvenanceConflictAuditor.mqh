//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/                            |
//| MLQuantAI_ExecutionProvenanceConflictAuditor.mqh                  |
//| C3.9 implementation. Read-only diagnostic: scans the full durable |
//| lifecycle log for CANDIDATE_EXECUTED events and flags any broker- |
//| side identifier (execution_request_id, order_ticket, or an        |
//| individual deal_tickets_sorted entry) claimed by more than one     |
//| distinct candidate_id.                                             |
//|                                                                     |
//| Deliberately does NOT replay state, check genesis uniqueness,      |
//| chain continuity, or transition legality - that is already sealed, |
//| already-tested, already-wired-into-OnInit territory owned by       |
//| ReplayEngine_Run()/StateProjector_Apply() (MLQuantAI.mq5's OnInit   |
//| already trips Safe Mode on any such inconsistency, every restart). |
//| This module covers the one narrower, non-overlapping gap: two      |
//| DIFFERENT candidates both durably claiming the same real broker    |
//| fill. StateProjector only tracks state per single candidate_id and |
//| never reads extra_json back, so nothing else in the sealed         |
//| pipeline checks this.                                              |
//|                                                                     |
//| No durable write, no OnInit wiring, no Safe Mode trip in this      |
//| round - report only.                                               |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_EXECUTIONPROVENANCECONFLICTAUDITOR_MQH__
#define __MLQUANTAI_EXECUTIONPROVENANCECONFLICTAUDITOR_MQH__

#include "MLQuantAI_EventStore.mqh"
#include "MLQuantAI_EventSerializer.mqh"

//---------------------------------------------------------------------
// EPCA_GetLongArray - "key":[n,n,...] -> outArr (unquoted integer
// array). Not a general EventSerializer API: EventSerializer_GetStringArray
// only decodes quoted-string arrays, and deal_tickets_sorted (written by
// C37_BuildExtraJson) is the only unquoted-integer array field this
// codebase currently produces. File-local to this module by design -
// must never be added to MLQuantAI_EventSerializer.mqh (sealed).
//
// Strict grammar, no whitespace tolerance (matches EventSerializer's own
// "closed-format parser" philosophy; C37_BuildExtraJson never emits
// whitespace inside this array):
//   array  := '[' ']'  |  '[' number (',' number)* ']'
//   number := '-'? digit{1,19}
// A 19-digit magnitude is further checked against the exact int64 bounds
// via string comparison before any numeric conversion is attempted,
// since 19 digits alone does not guarantee in-range (e.g.
// 9999999999999999999 is 19 digits and already exceeds int64 max).
//---------------------------------------------------------------------
enum ENUM_EPCA_ARRAY_RESULT
{
   EPCA_ARRAY_ABSENT,
   EPCA_ARRAY_VALID,
   EPCA_ARRAY_MALFORMED
};

#define EPCA_INT64_MAX_DIGITS            "9223372036854775807"
#define EPCA_INT64_MIN_MAGNITUDE_DIGITS   "9223372036854775808"

// Pure digit-by-digit accumulation for a digit run already proven safe by
// EPCA_DigitsInRange() - never delegates overflow handling to
// StringToInteger, since the whole point of this helper is to not trust
// an unverified library conversion at the exact int64 boundary.
bool EPCA_AccumulateDigits(string s, int start, int end, long &outVal)
{
   long val = 0;
   for(int i = start; i < end; i++)
   {
      ushort ch = StringGetCharacter(s, i);
      if(ch < '0' || ch > '9') return false;
      val = val * 10 + (ch - '0');
   }
   outVal = val;
   return true;
}

// Validates one token's digit-only substring s[start..end) against the
// int64 bounds using pure string comparison - no numeric conversion is
// attempted until the magnitude is already proven safe. isNegative
// selects which bound (max vs |min|) applies. Equal-length pure-digit
// strings compare ordinally the same as numerically, so this is exact
// regardless of leading zeros.
bool EPCA_DigitsInRange(string s, int start, int end, bool isNegative)
{
   int digitCount = end - start;
   if(digitCount == 0 || digitCount > 19) return false;
   if(digitCount < 19) return true; // shorter than the max magnitude's digit count - always safe

   string bound = isNegative ? EPCA_INT64_MIN_MAGNITUDE_DIGITS : EPCA_INT64_MAX_DIGITS;
   for(int i = 0; i < 19; i++)
   {
      ushort a = StringGetCharacter(s, start + i);
      ushort b = StringGetCharacter(bound, i);
      if(a < b) return true;   // strictly less than the bound - safe
      if(a > b) return false;  // strictly greater - out of range
   }
   return true; // exactly equal to the bound - in range (inclusive)
}

// Parses one signed integer token s[start..tokenEnd). Handles the exact
// INT64_MIN case explicitly: its magnitude (9223372036854775808) cannot
// be represented as a positive long en route to negation, so it is
// assigned directly from the compiler's own signed literal instead of
// runtime accumulation - never trusting a positive-then-negate path for
// that one value.
bool EPCA_ParseSignedToken(string s, int start, int tokenEnd, long &outVal)
{
   if(start >= tokenEnd) return false; // empty token (e.g. "[6001,,6002]" or "[6001,]")

   bool neg = (StringGetCharacter(s, start) == '-');
   int digitsStart = neg ? start + 1 : start;
   if(digitsStart >= tokenEnd) return false; // bare "-" with no digits

   if(!EPCA_DigitsInRange(s, digitsStart, tokenEnd, neg))
      return false;

   int digitCount = tokenEnd - digitsStart;
   if(neg && digitCount == 19 && StringSubstr(s, digitsStart, 19) == EPCA_INT64_MIN_MAGNITUDE_DIGITS)
   {
      outVal = -9223372036854775807 - 1;
      return true;
   }

   long magnitude;
   if(!EPCA_AccumulateDigits(s, digitsStart, tokenEnd, magnitude))
      return false;
   outVal = neg ? -magnitude : magnitude;
   return true;
}

ENUM_EPCA_ARRAY_RESULT EPCA_GetLongArray(string json, string key, long &outArr[])
{
   ArrayResize(outArr, 0);

   string needle = "\"" + key + "\":";
   int p = StringFind(json, needle);
   if(p < 0) return EPCA_ARRAY_ABSENT;

   int i = p + StringLen(needle);
   int len = StringLen(json);
   if(i >= len || StringGetCharacter(json, i) != '[')
      return EPCA_ARRAY_MALFORMED;

   i++; // past '['
   if(i < len && StringGetCharacter(json, i) == ']')
      return EPCA_ARRAY_VALID; // "[]" - valid, zero elements

   long values[];
   int count = 0;
   int tokenStart = i;

   while(true)
   {
      if(i >= len) return EPCA_ARRAY_MALFORMED; // ran off the end - unterminated

      ushort ch = StringGetCharacter(json, i);
      if(ch == ',' || ch == ']')
      {
         long v;
         if(!EPCA_ParseSignedToken(json, tokenStart, i, v))
            return EPCA_ARRAY_MALFORMED;
         ArrayResize(values, count + 1);
         values[count] = v;
         count++;

         if(ch == ']')
         {
            ArrayResize(outArr, count);
            for(int k = 0; k < count; k++) outArr[k] = values[k];
            return EPCA_ARRAY_VALID;
         }
         i++; // past ','
         tokenStart = i;
         continue;
      }

      // Any character that isn't a digit, or a leading '-' at the very
      // start of a token, is malformed - rejects whitespace, nested
      // brackets/objects, quoted strings, decimals, and scientific
      // notation outright.
      bool okChar = (ch >= '0' && ch <= '9') || (ch == '-' && i == tokenStart);
      if(!okChar) return EPCA_ARRAY_MALFORMED;
      i++;
   }
   return EPCA_ARRAY_MALFORMED; // unreachable - the loop above always returns via one of its own branches (i>=len, a rejected char, or a completed ']'); this satisfies MQL5's control-flow check, which does not prove while(true) loops always return.
}

//---------------------------------------------------------------------
// Report shape (locked at Checkpoint 1/2).
//---------------------------------------------------------------------
struct ExecutionProvenanceConflict
{
   string identifier_type;    // "execution_request_id" | "order_ticket" | "deal_ticket"
   string identifier_value;   // raw execution_request_id, or IntegerToString(ticket)
   string candidate_ids[];    // distinct candidate_id values, first-seen order, >= 2 entries
};

struct ExecutionProvenanceConflictReport
{
   bool                          ok;                          // true iff conflicts_found == 0
   int                           executed_events_scanned;      // EVENT_CAT_LIFECYCLE lines with to_state==CANDIDATE_EXECUTED that parsed
   int                           unparseable_lines_skipped;     // EVENT_CAT_LIFECYCLE lines EventSerializer_ParseLifecycle rejected - informational only
   int                           conflicts_found;
   ExecutionProvenanceConflict   conflicts[];
};

void ExecutionProvenanceConflictReport_Init(ExecutionProvenanceConflictReport &r)
{
   r.ok = true;
   r.executed_events_scanned = 0;
   r.unparseable_lines_skipped = 0;
   r.conflicts_found = 0;
   ArrayResize(r.conflicts, 0);
}

//---------------------------------------------------------------------
// Internal working state - local to ExecutionProvenanceConflictAuditor_
// ScanLines only, never a module global, keeping the function pure/
// reentrant (same discipline as EventStoreValidator_ValidateLines's own
// local trackedSessions[]/trackedLastSeq[] arrays).
//---------------------------------------------------------------------
enum ENUM_EPCA_IDENTIFIER_TYPE
{
   EPCA_ID_EXECUTION_REQUEST,
   EPCA_ID_ORDER_TICKET,
   EPCA_ID_DEAL_TICKET
};

string EPCA_IdentifierTypeToString(ENUM_EPCA_IDENTIFIER_TYPE t)
{
   switch(t)
   {
      case EPCA_ID_EXECUTION_REQUEST: return "execution_request_id";
      case EPCA_ID_ORDER_TICKET:      return "order_ticket";
      case EPCA_ID_DEAL_TICKET:       return "deal_ticket";
   }
   return "unknown";
}

struct EPCA_Entry
{
   ENUM_EPCA_IDENTIFIER_TYPE id_type;
   string                    canonical_value;
   string                    candidate_ids[];
};

// Records that candidateId claims (idType, canonicalValue). Matching is
// always the typed pair (id_type, canonical_value) - never a concatenated
// string - so a value that happens to look like another type's display
// form can never collide across types. First occurrence of a key appends
// a new entry (giving entries[] first-seen order); first occurrence of a
// candidate within that entry appends to candidate_ids[] (giving it
// first-seen order too); a repeat claim by the same candidate is a no-op,
// which is exactly what prevents a false conflict.
void EPCA_RecordClaim(EPCA_Entry &entries[], int &entryCount, ENUM_EPCA_IDENTIFIER_TYPE idType,
                       string canonicalValue, string candidateId)
{
   int idx = -1;
   for(int i = 0; i < entryCount; i++)
   {
      if(entries[i].id_type == idType && entries[i].canonical_value == canonicalValue)
      {
         idx = i;
         break;
      }
   }
   if(idx < 0)
   {
      ArrayResize(entries, entryCount + 1);
      entries[entryCount].id_type = idType;
      entries[entryCount].canonical_value = canonicalValue;
      ArrayResize(entries[entryCount].candidate_ids, 0);
      idx = entryCount;
      entryCount++;
   }

   int cn = ArraySize(entries[idx].candidate_ids);
   for(int j = 0; j < cn; j++)
      if(entries[idx].candidate_ids[j] == candidateId) return; // already claimed by this candidate

   ArrayResize(entries[idx].candidate_ids, cn + 1);
   entries[idx].candidate_ids[cn] = candidateId;
}

//---------------------------------------------------------------------
// Pure core - takes lines[] directly (never opens/reads a file itself),
// same split EventStoreValidator_ValidateLines/_ValidateFile and C3.7's
// own C37_FindMatchingExecutedLine already establish, so the test suite
// can exercise it in isolation.
//---------------------------------------------------------------------
ExecutionProvenanceConflictReport ExecutionProvenanceConflictAuditor_ScanLines(const string &lines[], int n)
{
   ExecutionProvenanceConflictReport report;
   ExecutionProvenanceConflictReport_Init(report);

   int limit = n;
   if(limit < 0) limit = 0;
   int avail = ArraySize(lines);
   if(limit > avail) limit = avail;

   EPCA_Entry entries[];
   int entryCount = 0;

   for(int i = 0; i < limit; i++)
   {
      string line = lines[i];
      if(line == "") continue;
      if(EventSerializer_PeekCategory(line) != EVENT_CAT_LIFECYCLE) continue;

      LifecycleEvent e;
      if(!EventSerializer_ParseLifecycle(line, e))
      {
         report.unparseable_lines_skipped++;
         continue;
      }

      if(e.to_state != CANDIDATE_EXECUTED) continue;

      report.executed_events_scanned++;

      string execReqId = EventSerializer_GetStr(e.extra_json, "execution_request_id");
      if(execReqId != "")
         EPCA_RecordClaim(entries, entryCount, EPCA_ID_EXECUTION_REQUEST, execReqId, e.candidate_id);

      long orderTicket = EventSerializer_GetLong(e.extra_json, "order_ticket");
      if(orderTicket > 0)
         EPCA_RecordClaim(entries, entryCount, EPCA_ID_ORDER_TICKET, IntegerToString(orderTicket), e.candidate_id);

      long dealTickets[];
      ENUM_EPCA_ARRAY_RESULT dtResult = EPCA_GetLongArray(e.extra_json, "deal_tickets_sorted", dealTickets);
      if(dtResult == EPCA_ARRAY_VALID)
      {
         int dn = ArraySize(dealTickets);
         for(int k = 0; k < dn; k++)
            if(dealTickets[k] > 0)
               EPCA_RecordClaim(entries, entryCount, EPCA_ID_DEAL_TICKET, IntegerToString(dealTickets[k]), e.candidate_id);
      }
      // EPCA_ARRAY_ABSENT or EPCA_ARRAY_MALFORMED -> no deal-ticket
      // identifiers indexed from this event; not fatal, not separately
      // counted (the locked report shape has no field for this beyond
      // what Checkpoint 1 approved).
   }

   for(int i = 0; i < entryCount; i++)
   {
      int cn = ArraySize(entries[i].candidate_ids);
      if(cn < 2) continue;

      int cc = ArraySize(report.conflicts);
      ArrayResize(report.conflicts, cc + 1);
      report.conflicts[cc].identifier_type  = EPCA_IdentifierTypeToString(entries[i].id_type);
      report.conflicts[cc].identifier_value = entries[i].canonical_value;
      ArrayResize(report.conflicts[cc].candidate_ids, cn);
      for(int j = 0; j < cn; j++)
         report.conflicts[cc].candidate_ids[j] = entries[i].candidate_ids[j];
   }

   report.conflicts_found = ArraySize(report.conflicts);
   report.ok = (report.conflicts_found == 0);

   return report;
}

// Thin wrapper: EventStore_ReadAllLines(fileName, lines) then _ScanLines.
// EventStore_ReadAllLines returns 0 with an empty lines[] for both a
// missing/unopenable file and a genuinely empty file - no distinct error
// signal exists at that layer (confirmed by reading its implementation;
// EventStoreValidator_ValidateFile already inherits this same
// non-distinguishing behavior today) - so both cases flow through to the
// same clean, empty report here.
ExecutionProvenanceConflictReport ExecutionProvenanceConflictAuditor_ScanFile(string fileName)
{
   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);
   return ExecutionProvenanceConflictAuditor_ScanLines(lines, n);
}

#endif // __MLQUANTAI_EXECUTIONPROVENANCECONFLICTAUDITOR_MQH__
