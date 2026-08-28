//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_SubmittedCandidateVisibility.mqh  |
//| C3.8.1. Pure, read-only diagnostic: for every candidate currently |
//| at CANDIDATE_SUBMITTED (per StateProjector, C3.8.0's own          |
//| Count()/GetAt() enumeration surface - the only permitted way to   |
//| reach that registry, per Docs/PhaseC_C3_8_                        |
//| ReconciliationIntegrationContract.md §18), reports whatever real,  |
//| already-durable evidence exists for it: submission timing, ticket |
//| lineage, C3.3 terminal match status, and C3.6 recommendation      |
//| visibility. No lifecycle authority, no broker/terminal query, no  |
//| write of any kind - see the frozen contract's §§14-18 for the     |
//| full semantics this file implements.                              |
//|                                                                    |
//| Absence of evidence is never rejection (contract §3). A candidate  |
//| with malformed/ambiguous ticket lineage is reported as an          |
//| integrity finding (report.ok=false), never silently dropped or     |
//| guessed at (contract §14).                                         |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_SUBMITTEDCANDIDATEVISIBILITY_MQH__
#define __MLQUANTAI_SUBMITTEDCANDIDATEVISIBILITY_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_StateProjector.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh"
#include "MLQuantAI_ExecutionAuditProjection.mqh"
#include "MLQuantAI_BrokerSubmissionAuditProjection.mqh"
#include "MLQuantAI_TransactionMatchingProjection.mqh"
#include "MLQuantAI_DeferredTransactionProcessor.mqh"

//---------------------------------------------------------------------
// Contract §14: the anomaly vocabulary. NO_QUALIFYING_OUTCOME is
// deliberately absent - "no qualifying submitted outcome" is a normal
// absence (LINEAGE_ANOMALY_NONE), never an integrity finding.
//---------------------------------------------------------------------
enum ENUM_LINEAGE_ANOMALY
{
   LINEAGE_ANOMALY_NONE = 0,
   LINEAGE_ANOMALY_NONPOSITIVE_TICKET,
   LINEAGE_ANOMALY_DUPLICATE_TRIPLE,
   LINEAGE_ANOMALY_MULTIPLE_EXECUTION_REQUESTS,
   LINEAGE_ANOMALY_AMBIGUOUS_TICKETS
};

string SCV_AnomalyToString(ENUM_LINEAGE_ANOMALY a)
{
   switch(a)
   {
      case LINEAGE_ANOMALY_NONE:                      return "NONE";
      case LINEAGE_ANOMALY_NONPOSITIVE_TICKET:         return "NONPOSITIVE_TICKET";
      case LINEAGE_ANOMALY_DUPLICATE_TRIPLE:           return "DUPLICATE_TRIPLE";
      case LINEAGE_ANOMALY_MULTIPLE_EXECUTION_REQUESTS:return "MULTIPLE_EXECUTION_REQUESTS";
      case LINEAGE_ANOMALY_AMBIGUOUS_TICKETS:          return "AMBIGUOUS_TICKETS";
   }
   return "UNKNOWN";
}

//---------------------------------------------------------------------
// Row shape (contract §4, amended §14/§16). Every "undefined unless"
// field must never be read/compared/serialized by a caller outside its
// own guard flag - the struct is not zero-initialized to a meaningful
// sentinel, just to a fixed, documented placeholder.
//---------------------------------------------------------------------
struct SubmittedCandidateVisibilityRow
{
   string   candidate_id;
   ENUM_CANDIDATE_STATE state;              // always CANDIDATE_SUBMITTED by construction

   bool     submitted_at_known;
   datetime submitted_at_server_time;       // undefined unless submitted_at_known
   long     submitted_sequence_number;      // undefined unless submitted_at_known

   bool     order_ticket_known;
   bool     order_ticket_ambiguous;
   ulong    order_ticket;                   // undefined unless order_ticket_known
   ENUM_LINEAGE_ANOMALY lineage_anomaly;

   bool                  match_status_known;
   ENUM_TX_MATCH_STATUS  match_status;       // undefined unless match_status_known

   bool     terminal_evidence_observed;
   bool     unresolved;

   bool     age_known;                      // == submitted_at_known
   int      age_seconds;                    // undefined unless age_known; server-time (TimeCurrent())

   bool     recommendation_known;
   ENUM_RECOMMENDATION recommendation;      // undefined unless recommendation_known

   bool     unresolved_beyond_threshold;
};

void SubmittedCandidateVisibilityRow_Init(SubmittedCandidateVisibilityRow &r)
{
   r.candidate_id = "";
   r.state = CANDIDATE_SUBMITTED;
   r.submitted_at_known = false;
   r.submitted_at_server_time = 0;
   r.submitted_sequence_number = 0;
   r.order_ticket_known = false;
   r.order_ticket_ambiguous = false;
   r.order_ticket = 0;
   r.lineage_anomaly = LINEAGE_ANOMALY_NONE;
   r.match_status_known = false;
   r.match_status = TX_MATCH_UNMATCHED;
   r.terminal_evidence_observed = false;
   r.unresolved = true;
   r.age_known = false;
   r.age_seconds = 0;
   r.recommendation_known = false;
   r.recommendation = RECOMMEND_NONE;
   r.unresolved_beyond_threshold = false;
}

struct SubmittedCandidateVisibilityReport
{
   bool     ok;
   int      total_submitted;
   SubmittedCandidateVisibilityRow rows[];
   int      unresolved_count;
   int      unresolved_beyond_threshold_count;
   string   first_error;
};

void SubmittedCandidateVisibilityReport_Init(SubmittedCandidateVisibilityReport &r)
{
   r.ok = true;
   r.total_submitted = 0;
   ArrayResize(r.rows, 0);
   r.unresolved_count = 0;
   r.unresolved_beyond_threshold_count = 0;
   r.first_error = "";
}

//---------------------------------------------------------------------
// §14: qualifying-submitted-outcome gathering. Two nested, deterministic
// ascending-index scans over already-sealed registries - the array this
// produces is therefore already in scan order, so "earliest" for
// anomaly-source selection is simply "first in this array".
//---------------------------------------------------------------------
struct SCV_QualifyingOutcome
{
   string execution_request_id;
   ulong  order_ticket;
};

// §14 "Per-row error selection": the specific (execution_request_id,
// order_ticket) source tuple whose scan-index pair triggered a row's
// lineage_anomaly - NOT part of the frozen row shape (§14's "Row fields
// and anomaly enum" lists no such field), held only long enough to build
// report.first_error's deterministic, attributable text. Never derived
// from row.order_ticket, which stays semantically undefined on every
// anomalous row (order_ticket_known == false for outcomes 1-4).
struct SCV_AnomalyTrigger
{
   bool   present;
   string execution_request_id;
   ulong  order_ticket;
};

void SCV_AnomalyTrigger_Init(SCV_AnomalyTrigger &t)
{
   t.present = false;
   t.execution_request_id = "";
   t.order_ticket = 0;
}

int SCV_GatherQualifying(string candidateId, SCV_QualifyingOutcome &out[])
{
   ArrayResize(out, 0);
   int count = 0;
   int reqCount = ExecutionRequestProjection_Count();
   for(int i = 0; i < reqCount; i++)
   {
      ExecutionRequestProjectionRecord execReq;
      if(!ExecutionRequestProjection_GetAt(i, execReq)) continue;
      if(execReq.candidate_id != candidateId) continue;

      int outCount = SubmissionOutcomeProjection_Count();
      for(int j = 0; j < outCount; j++)
      {
         SubmissionOutcomeProjectionRecord outcome;
         if(!SubmissionOutcomeProjection_GetAt(j, outcome)) continue;
         if(outcome.execution_request_id != execReq.execution_request_id) continue;
         // §14 non-SUBMITTED exclusion: NONE/ERROR/REJECTED/UNKNOWN never
         // reach this point - excluded before the qualifying set exists.
         if(outcome.submission_status != SUBMISSION_STATUS_SUBMITTED) continue;

         ArrayResize(out, count + 1);
         out[count].execution_request_id = execReq.execution_request_id;
         out[count].order_ticket = outcome.order_ticket;
         count++;
      }
   }
   return count;
}

// §14 six-outcome resolution, in the frozen precedence order. trigger is
// populated with the exact (execution_request_id, order_ticket) source
// tuple for outcomes 1-4 (the precedence-selected (i,j)/k position that
// caused that specific anomaly), left at its Init default (present ==
// false) for outcomes 5-6 - neither is an anomaly, so neither has a
// first_error to attribute.
void SCV_ResolveLineage(string candidateId, SubmittedCandidateVisibilityRow &row, SCV_AnomalyTrigger &trigger)
{
   SCV_AnomalyTrigger_Init(trigger);
   SCV_QualifyingOutcome qualifying[];
   int qCount = SCV_GatherQualifying(candidateId, qualifying);

   // Outcome 1: NONPOSITIVE_TICKET - first qualifying entry with ticket <= 0.
   for(int k = 0; k < qCount; k++)
   {
      if(qualifying[k].order_ticket <= 0)
      {
         row.order_ticket_known = false;
         row.order_ticket_ambiguous = false;
         row.lineage_anomaly = LINEAGE_ANOMALY_NONPOSITIVE_TICKET;
         trigger.present = true;
         trigger.execution_request_id = qualifying[k].execution_request_id;
         trigger.order_ticket = qualifying[k].order_ticket;
         return;
      }
   }

   // Every remaining entry has order_ticket > 0.
   SCV_QualifyingOutcome positive[];
   int posCount = 0;
   ArrayResize(positive, qCount);
   for(int k = 0; k < qCount; k++)
   {
      positive[posCount] = qualifying[k];
      posCount++;
   }

   // Outcome 2: DUPLICATE_TRIPLE - identical (execution_request_id, order_ticket)
   // pair repeated. candidate_id is already fixed for this whole scan.
   for(int a = 0; a < posCount; a++)
   {
      for(int b = a + 1; b < posCount; b++)
      {
         if(positive[a].execution_request_id == positive[b].execution_request_id &&
            positive[a].order_ticket == positive[b].order_ticket)
         {
            row.order_ticket_known = false;
            row.order_ticket_ambiguous = false;
            row.lineage_anomaly = LINEAGE_ANOMALY_DUPLICATE_TRIPLE;
            trigger.present = true;
            trigger.execution_request_id = positive[a].execution_request_id;
            trigger.order_ticket = positive[a].order_ticket;
            return;
         }
      }
   }

   // Outcome 3: MULTIPLE_EXECUTION_REQUESTS - 2+ distinct execution_request_id
   // values each with at least one qualifying positive-ticket outcome.
   // Attribution (§14 "Per-row error selection"): the EARLIEST positive
   // qualifying tuple across the whole candidate - positive[0] - never the
   // later entry that happens to make the anomaly detectable (the "second
   // distinct id/ticket" position is a detection witness, not the earliest
   // (i,j) pair the contract requires).
   string distinctReqIds[];
   int distinctReqCount = 0;
   for(int k = 0; k < posCount; k++)
   {
      bool found = false;
      for(int m = 0; m < distinctReqCount; m++)
         if(distinctReqIds[m] == positive[k].execution_request_id) { found = true; break; }
      if(!found)
      {
         ArrayResize(distinctReqIds, distinctReqCount + 1);
         distinctReqIds[distinctReqCount] = positive[k].execution_request_id;
         distinctReqCount++;
      }
   }
   if(distinctReqCount >= 2)
   {
      row.order_ticket_known = false;
      row.order_ticket_ambiguous = false;
      row.lineage_anomaly = LINEAGE_ANOMALY_MULTIPLE_EXECUTION_REQUESTS;
      trigger.present = true;
      trigger.execution_request_id = positive[0].execution_request_id;
      trigger.order_ticket = positive[0].order_ticket;
      return;
   }

   // Outcome 4: AMBIGUOUS_TICKETS - reachable only once outcome 3 is excluded
   // (exactly one execution_request_id among positive entries). Same
   // earliest-tuple attribution discipline as outcome 3: positive[0], never
   // the second-distinct-ticket detection witness.
   ulong distinctTickets[];
   int distinctTicketCount = 0;
   for(int k = 0; k < posCount; k++)
   {
      bool found = false;
      for(int m = 0; m < distinctTicketCount; m++)
         if(distinctTickets[m] == positive[k].order_ticket) { found = true; break; }
      if(!found)
      {
         ArrayResize(distinctTickets, distinctTicketCount + 1);
         distinctTickets[distinctTicketCount] = positive[k].order_ticket;
         distinctTicketCount++;
      }
   }
   if(distinctTicketCount >= 2)
   {
      row.order_ticket_known = false;
      row.order_ticket_ambiguous = true;
      row.lineage_anomaly = LINEAGE_ANOMALY_AMBIGUOUS_TICKETS;
      trigger.present = true;
      trigger.execution_request_id = positive[0].execution_request_id;
      trigger.order_ticket = positive[0].order_ticket;
      return;
   }

   // Outcome 5: no qualifying submitted outcome - NOT an anomaly.
   if(posCount == 0)
   {
      row.order_ticket_known = false;
      row.order_ticket_ambiguous = false;
      row.lineage_anomaly = LINEAGE_ANOMALY_NONE;
      return;
   }

   // Outcome 6: exactly one clean usable positive ticket.
   row.order_ticket_known = true;
   row.order_ticket_ambiguous = false;
   row.order_ticket = positive[0].order_ticket;
   row.lineage_anomaly = LINEAGE_ANOMALY_NONE;
}

//---------------------------------------------------------------------
// §15: downstream evidence gating. Only reached when order_ticket_known.
//---------------------------------------------------------------------
void SCV_ResolveEvidence(SubmittedCandidateVisibilityRow &row)
{
   if(!row.order_ticket_known)
   {
      row.match_status_known = false;
      row.terminal_evidence_observed = false;
      row.unresolved = true;
      return;
   }

   OrderAggregateRecord agg;
   bool found = TransactionMatching_TryGetOrderStatus(row.order_ticket, agg);
   row.match_status_known = found;
   if(found)
   {
      row.match_status = agg.match_status;
      row.terminal_evidence_observed = (agg.match_status == TX_MATCH_VOLUME_REACHED);
   }
   else
   {
      row.terminal_evidence_observed = false;
   }
   row.unresolved = !row.terminal_evidence_observed;
}

//---------------------------------------------------------------------
// §16 (recovery): direct scan for this candidate's own CANDIDATE_SUBMITTED
// line - same lines[]-direct-scan pattern C3.7/C3.9 already established.
// Per the state machine, CREATED -> SUBMITTED happens at most once, so a
// clean, already-replayed log should produce matchCount in {0,1}.
// matchCount==0, a zero/future-dated timestamp, or matchCount>1 (a
// should-be-impossible integrity case this component has no authority
// to repair or flag via Safe Mode) all fail closed to
// submitted_at_known=false - never a fabricated pick, never a
// side-effect on report.ok, which per contract §14 is driven solely by
// lineage_anomaly.
//---------------------------------------------------------------------
bool SCV_FindSubmittedLine(const string &lines[], int n, string candidateId,
                            datetime &outTs, long &outSeq)
{
   int matchCount = 0;
   datetime foundTs = 0;
   long     foundSeq = 0;

   for(int idx = 0; idx < n; idx++)
   {
      string line = lines[idx];
      if(line == "") continue;
      if(EventSerializer_PeekCategory(line) != EVENT_CAT_LIFECYCLE) continue;

      LifecycleEvent e;
      if(!EventSerializer_ParseLifecycle(line, e)) continue;
      if(e.candidate_id != candidateId) continue;
      if(e.to_state != CANDIDATE_SUBMITTED) continue;

      matchCount++;
      if(matchCount == 1)
      {
         foundTs = e.base.ts;
         foundSeq = e.base.sequence_number;
      }
   }

   if(matchCount != 1) return false;
   outTs = foundTs;
   outSeq = foundSeq;
   return true;
}

//---------------------------------------------------------------------
// §16 row ordering: known-timestamp rows ascending by
// submitted_sequence_number, then unknown-timestamp rows by candidate_id
// ascending. Plain insertion sort - row counts here are bounded by the
// live SUBMITTED population, never large enough to need better.
//
// SCV_RowWithTrigger carries each row's SCV_AnomalyTrigger in lockstep
// through the sort, so report.first_error (built after sorting, from
// final row order per §14's "Report aggregation and first_error
// ordering") can still cite the correct source tuple for whichever row
// ends up first - the trigger is local scratch state, never copied into
// the frozen SubmittedCandidateVisibilityRow/Report shapes.
//---------------------------------------------------------------------
struct SCV_RowWithTrigger
{
   SubmittedCandidateVisibilityRow row;
   SCV_AnomalyTrigger              trigger;
};

bool SCV_RowBefore(const SubmittedCandidateVisibilityRow &a, const SubmittedCandidateVisibilityRow &b)
{
   if(a.submitted_at_known && b.submitted_at_known)
      return a.submitted_sequence_number < b.submitted_sequence_number;
   if(a.submitted_at_known && !b.submitted_at_known)
      return true;
   if(!a.submitted_at_known && b.submitted_at_known)
      return false;
   return a.candidate_id < b.candidate_id;
}

void SCV_SortRows(SCV_RowWithTrigger &rows[], int count)
{
   for(int i = 1; i < count; i++)
   {
      SCV_RowWithTrigger key = rows[i];
      int j = i - 1;
      while(j >= 0 && SCV_RowBefore(key.row, rows[j].row))
      {
         rows[j + 1] = rows[j];
         j--;
      }
      rows[j + 1] = key;
   }
}

//---------------------------------------------------------------------
// THE entry points. _ScanLines is the pure, hand-buildable-fixture
// core; _ScanFile is a thin FileOpen/EventStore_ReadAllLines wrapper -
// same split every C3.x diagnostic in this codebase already uses.
//
// unresolvedThresholdSeconds < 0 is a caller programming error: every
// row's unresolved_beyond_threshold is forced false, and report.ok/
// first_error report the bad input - contract §4b's invariant
// (unresolved_beyond_threshold == false whenever age_known == false)
// still holds trivially since the flag never fires at all in this case.
//---------------------------------------------------------------------
int SubmittedCandidateVisibility_ScanLines(const string &lines[], int n,
                                            int unresolvedThresholdSeconds,
                                            SubmittedCandidateVisibilityReport &outReport)
{
   SubmittedCandidateVisibilityReport_Init(outReport);

   bool thresholdValid = (unresolvedThresholdSeconds >= 0);
   if(!thresholdValid)
   {
      outReport.ok = false;
      outReport.first_error = "unresolved_threshold_seconds must be >= 0";
   }

   int nSafe = n;
   if(nSafe < 0) nSafe = 0;
   if(nSafe > ArraySize(lines)) nSafe = ArraySize(lines);

   int candCount = StateProjector_Count();
   SCV_RowWithTrigger rows[];
   int rowCount = 0;
   datetime nowTs = TimeCurrent();

   for(int ci = 0; ci < candCount; ci++)
   {
      ProjectedCandidate cand;
      if(!StateProjector_GetAt(ci, cand)) continue;
      if(cand.state != CANDIDATE_SUBMITTED) continue;

      SubmittedCandidateVisibilityRow row;
      SubmittedCandidateVisibilityRow_Init(row);
      row.candidate_id = cand.candidate_id;

      datetime ts = 0;
      long seq = 0;
      bool foundLine = SCV_FindSubmittedLine(lines, nSafe, cand.candidate_id, ts, seq);
      if(foundLine && ts > 0 && ts <= nowTs)
      {
         row.submitted_at_known = true;
         row.submitted_at_server_time = ts;
         row.submitted_sequence_number = seq;
         row.age_known = true;
         row.age_seconds = (int)(nowTs - ts);
      }

      SCV_AnomalyTrigger trigger;
      SCV_ResolveLineage(cand.candidate_id, row, trigger);
      SCV_ResolveEvidence(row);

      DeferredRecommendationRecord rec;
      row.recommendation_known = DeferredTransactionProcessor_TryGet(cand.candidate_id, rec);
      if(row.recommendation_known) row.recommendation = rec.recommended_action;

      if(thresholdValid && row.unresolved && row.age_known &&
         row.age_seconds >= unresolvedThresholdSeconds)
         row.unresolved_beyond_threshold = true;

      ArrayResize(rows, rowCount + 1);
      rows[rowCount].row = row;
      rows[rowCount].trigger = trigger;
      rowCount++;
   }

   SCV_SortRows(rows, rowCount);

   // report.ok / first_error: monotonic aggregation over lineage_anomaly
   // only, in final report-row order (contract §14). Skipped entirely if
   // the threshold input itself was already invalid - that error takes
   // priority and is never overwritten by a per-row finding. The cited
   // execution_request_id/order_ticket come from that row's own
   // SCV_AnomalyTrigger (§14 "Per-row error selection") - a real source
   // tuple from the precedence-selected (i,j)/k position, never derived
   // from row.order_ticket (which stays undefined on every anomalous row).
   if(thresholdValid)
   {
      for(int k = 0; k < rowCount; k++)
      {
         if(rows[k].row.lineage_anomaly != LINEAGE_ANOMALY_NONE)
         {
            outReport.ok = false;
            // order_ticket is ulong across its FULL domain (up to
            // 2^64-1) - formatted via %I64u, never narrowed to `long`
            // first (a (long) cast of a value above LONG_MAX would
            // reinterpret the bit pattern as negative and corrupt the
            // attributed value). Same %I64u-on-a-raw-ulong idiom
            // MLQuantAI_AsyncTerminalRejectionAuthority.mqh already uses
            // for order_ticket. tickStr is still a genuine string by the
            // time it reaches the outer %s below - no raw ulong is ever
            // passed to a %s placeholder.
            string reqStr = rows[k].trigger.present ? rows[k].trigger.execution_request_id : "unknown";
            string tickStr = rows[k].trigger.present ? StringFormat("%I64u", rows[k].trigger.order_ticket) : "unknown";
            outReport.first_error = StringFormat("candidate %s: lineage anomaly %s (execution_request_id=%s, order_ticket=%s)",
                                                   rows[k].row.candidate_id,
                                                   SCV_AnomalyToString(rows[k].row.lineage_anomaly),
                                                   reqStr, tickStr);
            break;
         }
      }
   }

   outReport.total_submitted = rowCount;
   ArrayResize(outReport.rows, rowCount);
   for(int k = 0; k < rowCount; k++)
   {
      outReport.rows[k] = rows[k].row;
      if(rows[k].row.unresolved) outReport.unresolved_count++;
      if(rows[k].row.unresolved_beyond_threshold) outReport.unresolved_beyond_threshold_count++;
   }

   return rowCount;
}

bool SubmittedCandidateVisibility_ScanFile(string fileName, int unresolvedThresholdSeconds,
                                            SubmittedCandidateVisibilityReport &outReport)
{
   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);
   SubmittedCandidateVisibility_ScanLines(lines, n, unresolvedThresholdSeconds, outReport);
   return outReport.ok;
}

#endif // __MLQUANTAI_SUBMITTEDCANDIDATEVISIBILITY_MQH__
