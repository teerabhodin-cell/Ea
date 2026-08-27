//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_AsyncTerminalRejectionAudit.mqh  |
//| C3.10C implementation (per the Async Terminal Rejection Audit     |
//| Checkpoint 1 contract, locked in this branch's chat history - no  |
//| separate Docs/ file yet).                                         |
//|                                                                    |
//| Strictly read-only, non-blocking startup audit. Verifies that      |
//| every durable EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED SystemEvent|
//| C3.10B ever wrote is internally consistent with: the candidate's    |
//| current StateProjector state, its own linked lifecycle transition,   |
//| CandidateProjection lineage, and the terminal-observation evidence    |
//| the SAME atomReport instance C3.10B consumed resolves it to. Never     |
//| appends, repairs, transitions state, or trips Safe Mode - a pure        |
//| post-condition observer, not a new lifecycle authority.                  |
//|                                                                            |
//| C2.2 vs C3.10B (locked, central design point): a CANDIDATE_REJECTED_       |
//| BY_BROKER transition is C3.10B-owned ONLY when its own extra_json           |
//| carries a non-empty confirmation_log_event_id - C2.2's synchronous          |
//| path (Execution/MLQuantAI_BrokerSubmissionAdapter.mqh:237) always            |
//| passes extraJson="", so that key is structurally absent from every            |
//| C2.2-driven transition. No such key, empty value, or absent extra_json          |
//| -> out of scope, never contributes to missing_confirmation_count. A              |
//| non-empty confirmation_log_event_id with a missing/zero/invalid                   |
//| confirmation_sequence_number is a MALFORMED C3.10B-link, not C2.2 - it               |
//| naturally lands in missing_confirmation_count because no real durable                |
//| confirmation ever has seq==0 (EventStore_NextSequence always starts at 1),             |
//| so the identity lookup below simply never finds a match - no special-case               |
//| branch needed.                                                                            |
//|                                                                                              |
//| Traversal (locked, never short-circuits - always completes both passes,                      |
//| tallying every finding):                                                                       |
//| 1. Forward chronological pass over durable confirmation events - checks                          |
//|    CandidateProjection lineage, current-state + link (-> missing_transition),                       |
//|    source evidence via atomReport.matches[] (-> source_evidence_missing/                              |
//|    ambiguous/provenance_mismatch), and tallies duplicate candidate_ids.                                 |
//| 2. Backward pass over REJECTED_BY_BROKER transitions carrying a non-empty                                |
//|    confirmation_log_event_id - checks each against the confirmations already                              |
//|    collected in pass 1 (-> missing_confirmation).                                                            |
//| first_error records only the FIRST finding in that ordering (pass 1 entirely                                  |
//| precedes pass 2); every counter keeps accumulating regardless.                                                  |
//|                                                                                                                    |
//| Strictly bounded: no History*/Position*/Order*/OrderSend/CTrade API, no                                            |
//| OnTick/OnTradeTransaction, no edit to any sealed file, no *_RebuildFromFile                                          |
//| call of any kind, no EventStore_LogSystem/EventStore_LogTransition/                                                    |
//| EventStore_WriteLine/SafeMode_Trip call anywhere in this file.                                                            |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ASYNCTERMINALREJECTIONAUDIT_MQH__
#define __MLQUANTAI_ASYNCTERMINALREJECTIONAUDIT_MQH__

#include "MLQuantAI_AsyncTerminalOrderObservationMatcher.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_StateProjector.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh"

//---------------------------------------------------------------------
// Report. ok=false whenever any finding counter is nonzero. Never a
// Safe-Mode / initialization-blocking condition on its own - the
// caller (MLQuantAI.mq5's OnInit) only LogErrors on ok==false, per
// the locked non-blocking policy.
//---------------------------------------------------------------------
struct AsyncTerminalRejectionAuditReport
{
   bool   ok;
   int    confirmations_total;
   int    verified_total;
   int    missing_transition_count;
   int    missing_confirmation_count;
   int    duplicate_confirmation_count;
   int    provenance_mismatch_count;
   int    source_evidence_missing_count;
   int    source_evidence_ambiguous_count;
   string first_error;
};

void AsyncTerminalRejectionAuditReport_Init(AsyncTerminalRejectionAuditReport &r)
{
   r.ok = true;
   r.confirmations_total = 0;
   r.verified_total = 0;
   r.missing_transition_count = 0;
   r.missing_confirmation_count = 0;
   r.duplicate_confirmation_count = 0;
   r.provenance_mismatch_count = 0;
   r.source_evidence_missing_count = 0;
   r.source_evidence_ambiguous_count = 0;
   r.first_error = "";
}

//---------------------------------------------------------------------
// One durable TRANSACTION_REJECTION_CONFIRMED line's own identity +
// claimed fields - file-local, never exported.
//---------------------------------------------------------------------
struct C310C_ConfirmationRecord
{
   string log_event_id;
   long   seq;
   string candidate_id;
   ulong  order_ticket;
   string execution_request_id;
   string observed_kind;
   string source_log_event_id;
   long   source_sequence_number;
};

int C310C_CountConfirmationsForCandidate(const C310C_ConfirmationRecord &confirmations[], string candidateId)
{
   int count = 0;
   int total = ArraySize(confirmations);
   for(int i = 0; i < total; i++)
      if(confirmations[i].candidate_id == candidateId) count++;
   return count;
}

//---------------------------------------------------------------------
// THE entry point. Slots after the existing, unmodified C3.10B/C3.7/
// BrokerReconciliation control-flow block - never reparses or rebuilds
// any upstream projection, never touches atomReport's own resolution
// (reused as given, never re-scanned).
//---------------------------------------------------------------------
AsyncTerminalRejectionAuditReport AsyncTerminalRejectionAudit_StartupScan(
   string fileName, const AsyncTerminalOrderMatchReport &atomReport)
{
   AsyncTerminalRejectionAuditReport report;
   AsyncTerminalRejectionAuditReport_Init(report);

   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);

   //--------------------------------------------------------------
   // Pass 1: forward chronological scan over confirmation events.
   //--------------------------------------------------------------
   C310C_ConfirmationRecord confirmations[];
   ArrayResize(confirmations, 0);

   for(int i = 0; i < n; i++)
   {
      string line = lines[i];
      if(line == "") continue;
      if(EventSerializer_PeekCategory(line) != EVENT_CAT_SYSTEM) continue;
      if(EventSerializer_GetStr(line, "type") != "TRANSACTION_REJECTION_CONFIRMED") continue;

      C310C_ConfirmationRecord rec;
      rec.log_event_id           = EventSerializer_GetStr(line, "log_event_id");
      rec.seq                    = EventSerializer_GetLong(line, "seq");
      rec.candidate_id           = EventSerializer_GetStr(line, "candidate_id");
      rec.order_ticket           = (ulong)EventSerializer_GetLong(line, "order_ticket");
      rec.execution_request_id   = EventSerializer_GetStr(line, "execution_request_id");
      rec.observed_kind          = EventSerializer_GetStr(line, "observed_kind");
      rec.source_log_event_id    = EventSerializer_GetStr(line, "source_log_event_id");
      rec.source_sequence_number = EventSerializer_GetLong(line, "source_sequence_number");

      int idx = ArraySize(confirmations);
      ArrayResize(confirmations, idx + 1);
      confirmations[idx] = rec;
   }

   report.confirmations_total = ArraySize(confirmations);

   string dupCountedCandidateIds[];
   ArrayResize(dupCountedCandidateIds, 0);

   for(int ci = 0; ci < ArraySize(confirmations); ci++)
   {
      C310C_ConfirmationRecord rec = confirmations[ci];
      bool findingThisRecord = false;

      // CandidateProjection lineage sanity (required for every
      // confirmation, per the locked contract) - never used to derive
      // or inspect lifecycle state, existence only.
      CandidateProjectionRecord candRec;
      if(!CandidateProjection_TryGet(rec.candidate_id, candRec))
      {
         report.provenance_mismatch_count++;
         findingThisRecord = true;
         if(report.first_error == "")
            report.first_error = StringFormat("confirmation %s: candidate_id %s has no CandidateProjection lineage",
                                                rec.log_event_id, rec.candidate_id);
      }

      // Current state + linked transition -> missing_transition_count.
      // Both are independent detection paths for ONE logical finding -
      // checked together, tallied once.
      ENUM_CANDIDATE_STATE liveState;
      bool stateOk = StateProjector_TryGetState(rec.candidate_id, liveState) && liveState == CANDIDATE_REJECTED_BY_BROKER;

      bool linkFound = false;
      for(int li = 0; li < n && !linkFound; li++)
      {
         string tline = lines[li];
         if(tline == "") continue;
         if(EventSerializer_PeekCategory(tline) != EVENT_CAT_LIFECYCLE) continue;
         LifecycleEvent te;
         if(!EventSerializer_ParseLifecycle(tline, te)) continue;
         if(te.candidate_id != rec.candidate_id || te.to_state != CANDIDATE_REJECTED_BY_BROKER) continue;
         if(EventSerializer_GetStr(tline, "confirmation_log_event_id") != rec.log_event_id) continue;
         if(EventSerializer_GetLong(tline, "confirmation_sequence_number") != rec.seq) continue;
         linkFound = true;
      }

      if(!stateOk || !linkFound)
      {
         report.missing_transition_count++;
         findingThisRecord = true;
         if(report.first_error == "")
            report.first_error = StringFormat("confirmation %s: candidate %s missing/unlinked REJECTED_BY_BROKER transition",
                                                rec.log_event_id, rec.candidate_id);
      }

      // Source evidence lookup against the SAME atomReport instance
      // C3.10B consumed - never re-scanned.
      int matchIdx = -1;
      int totalMatches = ArraySize(atomReport.matches);
      for(int mi = 0; mi < totalMatches; mi++)
      {
         if(atomReport.matches[mi].source_log_event_id == rec.source_log_event_id &&
            atomReport.matches[mi].source_sequence_number == rec.source_sequence_number)
         { matchIdx = mi; break; }
      }

      if(matchIdx < 0)
      {
         report.source_evidence_missing_count++;
         findingThisRecord = true;
         if(report.first_error == "")
            report.first_error = StringFormat("confirmation %s: claimed source (%s, seq %d) not found in the current terminal-observation scan",
                                                rec.log_event_id, rec.source_log_event_id, rec.source_sequence_number);
      }
      else if(atomReport.matches[matchIdx].status == ATOM_AMBIGUOUS)
      {
         report.source_evidence_ambiguous_count++;
         findingThisRecord = true;
         if(report.first_error == "")
            report.first_error = StringFormat("confirmation %s: claimed source (%s, seq %d) now resolves ATOM_AMBIGUOUS",
                                                rec.log_event_id, rec.source_log_event_id, rec.source_sequence_number);
      }
      else
      {
         if(atomReport.matches[matchIdx].candidate_id != rec.candidate_id ||
            atomReport.matches[matchIdx].order_ticket != rec.order_ticket ||
            ATOM_ObservedKindToString(atomReport.matches[matchIdx].observed_kind) != rec.observed_kind)
         {
            report.provenance_mismatch_count++;
            findingThisRecord = true;
            if(report.first_error == "")
               report.first_error = StringFormat("confirmation %s: candidate_id/order_ticket/observed_kind differs from resolved source evidence",
                                                   rec.log_event_id);
         }
      }

      // Duplicate confirmation, keyed on candidate_id alone (broader
      // than C3.10B's own 6-field write-time idempotency key - see
      // Checkpoint 1 rationale). Counted once per distinct candidate_id.
      if(C310C_CountConfirmationsForCandidate(confirmations, rec.candidate_id) > 1)
      {
         findingThisRecord = true;
         bool alreadyCounted = false;
         for(int di = 0; di < ArraySize(dupCountedCandidateIds); di++)
            if(dupCountedCandidateIds[di] == rec.candidate_id) { alreadyCounted = true; break; }
         if(!alreadyCounted)
         {
            report.duplicate_confirmation_count++;
            int dsz = ArraySize(dupCountedCandidateIds);
            ArrayResize(dupCountedCandidateIds, dsz + 1);
            dupCountedCandidateIds[dsz] = rec.candidate_id;
            if(report.first_error == "")
               report.first_error = StringFormat("candidate %s has more than one durable confirmation", rec.candidate_id);
         }
      }

      if(!findingThisRecord) report.verified_total++;
   }

   //--------------------------------------------------------------
   // Pass 2: backward-direction scan over REJECTED_BY_BROKER
   // transitions carrying a non-empty confirmation_log_event_id
   // (the structural C3.10B-ownership marker, per the locked
   // contract) - checked against confirmations[] already collected
   // in pass 1.
   //--------------------------------------------------------------
   for(int i = n - 1; i >= 0; i--)
   {
      string line = lines[i];
      if(line == "") continue;
      if(EventSerializer_PeekCategory(line) != EVENT_CAT_LIFECYCLE) continue;

      LifecycleEvent e;
      if(!EventSerializer_ParseLifecycle(line, e)) continue;
      if(e.to_state != CANDIDATE_REJECTED_BY_BROKER) continue;

      string confLogEventId = EventSerializer_GetStr(line, "confirmation_log_event_id");
      if(confLogEventId == "") continue; // C2.2 - out of scope, per locked contract

      long confSeq = EventSerializer_GetLong(line, "confirmation_sequence_number");

      bool found = false;
      int totalConf = ArraySize(confirmations);
      for(int ci = 0; ci < totalConf; ci++)
      {
         if(confirmations[ci].log_event_id == confLogEventId && confirmations[ci].seq == confSeq)
         { found = true; break; }
      }

      if(!found)
      {
         report.missing_confirmation_count++;
         if(report.first_error == "")
            report.first_error = StringFormat("candidate %s: C3.10B-linked transition references confirmation %s (seq %d) which is not durably found",
                                                e.candidate_id, confLogEventId, confSeq);
      }
   }

   report.ok = report.missing_transition_count == 0 &&
               report.missing_confirmation_count == 0 &&
               report.duplicate_confirmation_count == 0 &&
               report.provenance_mismatch_count == 0 &&
               report.source_evidence_missing_count == 0 &&
               report.source_evidence_ambiguous_count == 0;

   return report;
}

#endif // __MLQUANTAI_ASYNCTERMINALREJECTIONAUDIT_MQH__
