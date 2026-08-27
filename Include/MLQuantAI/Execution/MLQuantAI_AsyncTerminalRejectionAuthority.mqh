//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_AsyncTerminalRejectionAuthority. |
//| mqh                                                               |
//| C3.10B implementation (per the Async Terminal Rejection          |
//| Authority Checkpoint 2 contract, locked in this branch's chat     |
//| history - no separate Docs/ file yet).                            |
//|                                                                    |
//| The SOLE component authorized to turn a C3.10A ATOM_MATCHED       |
//| async terminal-order observation (REJECTED/CANCELED/EXPIRED) into  |
//| a durable EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED SystemEvent   |
//| followed by a real CANDIDATE_SUBMITTED -> CANDIDATE_REJECTED_BY_   |
//| BROKER lifecycle transition, via the existing sealed               |
//| EventStore_LogSystem()/EventStore_LogTransition() - the same        |
//| production write paths C2.2/C3.7 already use. No new ENUM_EVENT_    |
//| TYPE beyond EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED, no new      |
//| ENUM_REASON_CODE beyond REASON_ORDER_CANCELLED (REASON_BROKER_      |
//| REJECT/REASON_EXPIRED already exist, sealed, reused as-is).         |
//|                                                                     |
//| Fail-closed gates (Checkpoint 2, locked):                          |
//| 1. atomReport.ok==false (C3.10A found ANY ambiguous observation     |
//|    anywhere in the batch) stops this authority before ANY write -   |
//|    evidentiary uncertainty about what happened, not a benign        |
//|    policy skip like C3.6's RECOMMEND_BLOCKED. Does NOT trip Safe    |
//|    Mode - this is an upstream data-quality signal, not proof the    |
//|    durable event store itself is inconsistent.                     |
//| 2. Every ATOM_MATCHED entry must carry a valid source identity      |
//|    (source_log_event_id != "" AND source_sequence_number > 0)       |
//|    before ANY write - trips Safe Mode and stops the whole scan      |
//|    immediately if not (C3.10A permits an empty source_log_event_id  |
//|    as a non-fatal read-only diagnostic; C3.10B, which creates       |
//|    durable identity and lifecycle effect, cannot).                  |
//|                                                                      |
//| A FRESH StateProjector_TryGetState() re-check happens immediately    |
//| before every write - AsyncTerminalOrderMatch is evidence, never      |
//| write-time authority.                                                |
//|                                                                       |
//| Idempotency: a fresh-state recheck alone is not sufficient (it        |
//| only prevents a duplicate LIFECYCLE transition, not a duplicate       |
//| CONFIRMATION write in a partial-write/restart scenario). Before        |
//| any write, C310B_FindMatchingRejectionConfirmation() durably           |
//| scans for an existing confirmation with the same schema version +      |
//| 6-field identity: 0 matches -> proceed; 1 match -> Safe Mode (partial   |
//| write, refuse to auto-complete); >1 matches -> Safe Mode (duplicate      |
//| confirmations). After a successful confirmation write, the SAME          |
//| lookup recovers the real just-written evidence (never fabricated) -       |
//| the transition's own extra_json carries only that recovered identity.     |
//|                                                                              |
//| After a successful EventStore_LogTransition, this file does NOT trust       |
//| that call's own c.state=to mutation (which only updates the LOCAL           |
//| TradeCandidate variable, never the global StateProjector registry). It       |
//| re-reads the event store and recovers the REAL just-appended LIFECYCLE       |
//| line via C310B_FindMatchingRejectionTransition, then calls                    |
//| StateProjector_Apply on it - same "recover real evidence, never               |
//| fabricate, then synchronously apply to StateProjector" discipline C3.7         |
//| itself established (found missing here via a real MetaEditor test run:         |
//| Test_HappyPath_Rejected/Canceled/Expired all failed on this exact gap           |
//| before the fix).                                                                 |
//|                                                                              |
//| Strictly bounded: no History*/Position*/Order*/OrderSend/CTrade API,        |
//| no OnTick/OnTradeTransaction, no edit to any sealed file, no                |
//| *_RebuildFromFile call of any kind (reads only StateProjector +             |
//| CandidateProjection read models already built by replay, and the           |
//| caller-supplied AsyncTerminalOrderMatchReport).                             |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ASYNCTERMINALREJECTIONAUTHORITY_MQH__
#define __MLQUANTAI_ASYNCTERMINALREJECTIONAUTHORITY_MQH__

#include "MLQuantAI_AsyncTerminalOrderObservationMatcher.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_StateProjector.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_SafeModeState.mqh"
#include "../Logging/MLQuantAI_SystemLogger.mqh"

//---------------------------------------------------------------------
// Report. ok=false on either fail-closed gate above or a scan-level
// write/recovery failure - the caller (MLQuantAI.mq5's OnInit) must
// skip both LifecycleAuthority_StartupApply() (C3.7) and
// BrokerReconciliation_CheckAll() when ok==false.
//---------------------------------------------------------------------
struct AsyncTerminalRejectionAuthorityReport
{
   bool   ok;
   bool   upstream_observation_ambiguous;   // true iff atomReport.ok was false - scan never started
   int    observations_total;               // == atomReport.relevant_total
   int    matched_total;                    // ATOM_MATCHED entries in atomReport.matches[]
   int    skipped_unmatched;                // ATOM_UNMATCHED - informational, not fatal
   int    skipped_not_submitted;            // fresh StateProjector state != CANDIDATE_SUBMITTED
   int    skipped_missing_candidate_projection; // CandidateProjection_TryGet failed
   int    confirmed_count;                  // successfully wrote confirmation + transition this scan
   bool   scan_stopped_early;
   string stop_reason;   // "" | "upstream_observation_ambiguous" | "invalid_source_identity" |
                          // "partial_write_detected" | "duplicate_confirmation_detected" |
                          // "durable_confirmation_write_failure" | "confirmation_evidence_not_recovered" |
                          // "confirmation_evidence_ambiguous" | "durable_transition_write_failure" |
                          // "transition_evidence_not_recovered" | "transition_evidence_ambiguous" |
                          // "projector_apply_failed"
   string first_error;
};

void AsyncTerminalRejectionAuthorityReport_Init(AsyncTerminalRejectionAuthorityReport &r)
{
   r.ok = true;
   r.upstream_observation_ambiguous = false;
   r.observations_total = 0;
   r.matched_total = 0;
   r.skipped_unmatched = 0;
   r.skipped_not_submitted = 0;
   r.skipped_missing_candidate_projection = 0;
   r.confirmed_count = 0;
   r.scan_stopped_early = false;
   r.stop_reason = "";
   r.first_error = "";
}

//---------------------------------------------------------------------
// Reason-code mapping (locked, Checkpoint 2 section "Authority API").
//---------------------------------------------------------------------
ENUM_REASON_CODE C310B_ReasonForObservedKind(ENUM_ATOM_OBSERVED_KIND k)
{
   switch(k)
   {
      case ATOM_REJECTED: return REASON_BROKER_REJECT;
      case ATOM_CANCELED: return REASON_ORDER_CANCELLED;
      case ATOM_EXPIRED:  return REASON_EXPIRED;
   }
   return REASON_NONE; // unreachable - ENUM_ATOM_OBSERVED_KIND has exactly 3 values
}

//---------------------------------------------------------------------
// Confirmation extra_json builder. confirmation_key is display-only -
// never parsed back (the durable lookup below compares 6 typed fields
// directly), so delimiter collision inside it is harmless.
//---------------------------------------------------------------------
string C310B_BuildConfirmationExtraJson(const AsyncTerminalOrderMatch &m)
{
   string kindStr = ATOM_ObservedKindToString(m.observed_kind);
   string confirmationKey = m.candidate_id + "|" + IntegerToString((long)m.order_ticket) + "|" +
                             m.execution_request_id + "|" + kindStr + "|" +
                             m.source_log_event_id + "|" + IntegerToString(m.source_sequence_number);

   string s = "";
   s += "\"c3_10b_schema_version\":\"C310B_V1\",";
   s += "\"confirmation_key\":\""      + EventSerializer_Escape(confirmationKey) + "\",";
   s += "\"candidate_id\":\""          + EventSerializer_Escape(m.candidate_id) + "\",";
   s += "\"order_ticket\":"            + IntegerToString((long)m.order_ticket) + ",";
   s += "\"execution_request_id\":\""  + EventSerializer_Escape(m.execution_request_id) + "\",";
   s += "\"observed_kind\":\""         + kindStr + "\",";
   s += "\"source_log_event_id\":\""   + EventSerializer_Escape(m.source_log_event_id) + "\",";
   s += "\"source_sequence_number\":"  + IntegerToString(m.source_sequence_number);
   return s;
}

//---------------------------------------------------------------------
// Durable confirmation lookup - real reference shape mirrors
// C37_FindMatchingExecutedLine (LifecycleAuthorityProcessor.mqh):
// backward scan, lines[]/n supplied by the caller, returns matchCount
// directly. Used BOTH as the pre-write idempotency check and (called
// again after a successful write) to recover the just-written
// evidence's real log_event_id/seq - never fabricated.
//---------------------------------------------------------------------
int C310B_FindMatchingRejectionConfirmation(
   const string &lines[], int n,
   string candidateId, ulong orderTicket, string executionRequestId,
   ENUM_ATOM_OBSERVED_KIND observedKind, string sourceLogEventId, long sourceSequenceNumber,
   string &outConfirmationLogEventId, long &outConfirmationSequenceNumber)
{
   outConfirmationLogEventId = "";
   outConfirmationSequenceNumber = 0;

   // Defensive bounds clamp - the real reference shape doesn't guard
   // this because its caller always passes n == ArraySize(lines) fresh
   // off EventStore_ReadAllLines. Added here so a mismatched n can
   // never trigger an out-of-bounds array read.
   int safeN = n;
   int avail = ArraySize(lines);
   if(safeN > avail) safeN = avail;
   if(safeN < 0) safeN = 0;

   int matchCount = 0;
   for(int i = safeN - 1; i >= 0; i--)
   {
      string line = lines[i];
      if(line == "") continue;
      if(EventSerializer_PeekCategory(line) != EVENT_CAT_SYSTEM) continue;
      // real serialized "type" value strips the EVENT_TYPE_ prefix
      // (Core/MLQuantAI_Enums.mqh's EventTypeToString, every case).
      if(EventSerializer_GetStr(line, "type") != "TRANSACTION_REJECTION_CONFIRMED") continue;
      if(EventSerializer_GetStr(line, "c3_10b_schema_version") != "C310B_V1") continue;

      if(EventSerializer_GetStr(line, "candidate_id")             != candidateId)          continue;
      if((ulong)EventSerializer_GetLong(line, "order_ticket")     != orderTicket)           continue;
      if(EventSerializer_GetStr(line, "execution_request_id")     != executionRequestId)    continue;
      if(EventSerializer_GetStr(line, "observed_kind")            != ATOM_ObservedKindToString(observedKind)) continue;
      if(EventSerializer_GetStr(line, "source_log_event_id")      != sourceLogEventId)      continue;
      if(EventSerializer_GetLong(line, "source_sequence_number")  != sourceSequenceNumber)  continue;

      matchCount++;
      if(matchCount == 1)
      {
         outConfirmationLogEventId     = EventSerializer_GetStr(line, "log_event_id");
         outConfirmationSequenceNumber = EventSerializer_GetLong(line, "seq");
      }
   }
   return matchCount;
}

//---------------------------------------------------------------------
// Durable transition-evidence lookup - real reference shape mirrors
// C37_FindMatchingExecutedLine (LifecycleAuthorityProcessor.mqh)
// exactly: backward scan, LIFECYCLE category, candidate_id + from/to
// state match, returns matchCount directly. Called ONLY right after a
// successful EventStore_LogTransition, to recover the REAL just-written
// line (never fabricated) for StateProjector_Apply - by construction,
// this candidate could not already have had a CANDIDATE_REJECTED_BY_
// BROKER line before this call (the fresh SUBMITTED pre-check above
// would have excluded it via skipped_not_submitted otherwise), so at
// most one match is ever expected.
//---------------------------------------------------------------------
int C310B_FindMatchingRejectionTransition(const string &lines[], int n, string candidateId, LifecycleEvent &outEvent)
{
   int safeN = n;
   int avail = ArraySize(lines);
   if(safeN > avail) safeN = avail;
   if(safeN < 0) safeN = 0;

   int matchCount = 0;
   for(int i = safeN - 1; i >= 0; i--)
   {
      string line = lines[i];
      if(line == "") continue;
      if(EventSerializer_PeekCategory(line) != EVENT_CAT_LIFECYCLE) continue;

      LifecycleEvent e;
      if(!EventSerializer_ParseLifecycle(line, e)) continue;

      if(e.candidate_id != candidateId) continue;
      if(e.from_state != CANDIDATE_SUBMITTED || e.to_state != CANDIDATE_REJECTED_BY_BROKER) continue;

      matchCount++;
      if(matchCount == 1) outEvent = e;
   }
   return matchCount;
}

//---------------------------------------------------------------------
// THE entry point (Checkpoint 2 section 6, frozen OnInit placement).
// Slots between DeferredTransactionProcessor_StartupScan (C3.6) and
// LifecycleAuthority_StartupApply (C3.7) - never reparses the event
// store beyond its own idempotency lookups, never rebuilds
// StateProjector/CandidateProjection/atomReport itself.
//---------------------------------------------------------------------
AsyncTerminalRejectionAuthorityReport AsyncTerminalRejectionAuthority_StartupApply(
   string fileName, const AsyncTerminalOrderMatchReport &atomReport)
{
   AsyncTerminalRejectionAuthorityReport report;
   AsyncTerminalRejectionAuthorityReport_Init(report);

   report.observations_total = atomReport.relevant_total; // pure read, safe before the gate below

   // Gate 1 (Checkpoint 2, locked): any ambiguous observation anywhere
   // in the batch stops this authority before any durable write.
   // Deliberately does NOT call SafeMode_Trip - this is an upstream
   // data-quality signal about C3.10A's raw evidence, not proof the
   // durable event store itself is inconsistent.
   if(!atomReport.ok)
   {
      report.upstream_observation_ambiguous = true;
      report.ok = false;
      report.scan_stopped_early = true;
      report.stop_reason = "upstream_observation_ambiguous";
      report.first_error = "C3.10A reported ambiguous terminal order observations";
      LogWarn("C3.10B async terminal rejection authority: " + report.first_error +
              " - skipping this session, no confirmation/transition written.");
      return report;
   }

   // Pass 1: tally only. atomReport.ok==true here guarantees
   // atomReport.ambiguous_count==0 (AsyncTerminalOrderObservationMatcher.
   // mqh: report.ok = (report.ambiguous_count == 0)), so no
   // ATOM_AMBIGUOUS entry can exist in atomReport.matches[] past this
   // point - the classification needs only two branches.
   int total = ArraySize(atomReport.matches);
   for(int i = 0; i < total; i++)
   {
      if(atomReport.matches[i].status == ATOM_MATCHED) report.matched_total++;
      else                                             report.skipped_unmatched++;
   }

   // Pass 2: gate 2, then the state/candidate-projection/idempotency
   // logic, only for ATOM_MATCHED entries.
   for(int i = 0; i < total; i++)
   {
      AsyncTerminalOrderMatch m = atomReport.matches[i];
      if(m.status != ATOM_MATCHED) continue; // already tallied in pass 1

      // Gate 2 (Checkpoint 2, locked): mandatory source identity.
      // Full-stop, mirrors every other fail-closed branch below - once
      // Safe Mode is tripped, this scan performs zero further writes.
      if(m.source_log_event_id == "" || m.source_sequence_number <= 0)
      {
         SafeMode_Trip(StringFormat("C3.10B matched observation has invalid source identity for %s "
                        "(order_ticket %I64u) - source_log_event_id=\"%s\" source_sequence_number=%d",
                        m.candidate_id, m.order_ticket, m.source_log_event_id, m.source_sequence_number));
         report.ok = false; report.scan_stopped_early = true;
         report.stop_reason = "invalid_source_identity";
         report.first_error = StringFormat("invalid source identity for %s (order_ticket %I64u)",
                                             m.candidate_id, m.order_ticket);
         return report;
      }

      // Fresh state re-check - AsyncTerminalOrderMatch is evidence,
      // never write-time authority (same discipline as C3.7).
      ENUM_CANDIDATE_STATE liveState;
      if(!StateProjector_TryGetState(m.candidate_id, liveState) || liveState != CANDIDATE_SUBMITTED)
      {
         report.skipped_not_submitted++;
         continue;
      }

      CandidateProjectionRecord candRec;
      if(!CandidateProjection_TryGet(m.candidate_id, candRec))
      {
         report.skipped_missing_candidate_projection++;
         continue;
      }

      // Two-source TradeCandidate assembly, same split as C3.7:
      // .state comes ONLY from the fresh StateProjector lookup above -
      // never from CandidateProjectionRecord.state, which is always
      // CREATED in that B6-only projection.
      TradeCandidate candidate;
      TradeCandidate_Init(candidate);
      candidate.candidate_id   = candRec.candidate_id;
      candidate.root_event_id  = candRec.root_event_id;
      candidate.correlation_id = candRec.correlation_id;
      candidate.strategy_id    = candRec.strategy_id;
      candidate.state          = liveState;

      // Pre-write idempotency lookup.
      string lines[];
      int n = EventStore_ReadAllLines(fileName, lines);

      string existingLogEventId; long existingSeq;
      int matchCount = C310B_FindMatchingRejectionConfirmation(lines, n,
                            m.candidate_id, m.order_ticket, m.execution_request_id, m.observed_kind,
                            m.source_log_event_id, m.source_sequence_number,
                            existingLogEventId, existingSeq);

      if(matchCount == 1)
      {
         SafeMode_Trip(StringFormat("C3.10B confirmation durable but transition never applied for %s "
                        "(order_ticket %I64u) - possible partial write, refusing to auto-complete",
                        m.candidate_id, m.order_ticket));
         report.ok = false; report.scan_stopped_early = true;
         report.stop_reason = "partial_write_detected";
         report.first_error = StringFormat("existing confirmation %s (seq %d) has no matching transition",
                                             existingLogEventId, existingSeq);
         return report;
      }
      if(matchCount > 1)
      {
         SafeMode_Trip(StringFormat("C3.10B duplicate durable confirmation evidence for %s (order_ticket %I64u)",
                        m.candidate_id, m.order_ticket));
         report.ok = false; report.scan_stopped_early = true;
         report.stop_reason = "duplicate_confirmation_detected";
         report.first_error = StringFormat("%d matching durable confirmation lines found for %s (expected 0 or 1)",
                                             matchCount, m.candidate_id);
         return report;
      }
      // matchCount == 0: proceed.

      ENUM_REASON_CODE reason = C310B_ReasonForObservedKind(m.observed_kind);
      string confirmExtraJson = C310B_BuildConfirmationExtraJson(m);

      if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED),
                                "transaction rejection confirmed", confirmExtraJson))
      {
         // EventStore_LogSystem does NOT auto-trip Safe Mode on failure
         // (Infrastructure/EventStore/MLQuantAI_EventStore.mqh) - real
         // precedent for a caller explicitly tripping it on exactly
         // this kind of SYSTEM-event failure:
         // Execution/MLQuantAI_BrokerTransactionObservation.mqh.
         SafeMode_Trip(StringFormat("C3.10B durable confirmation write failed for %s (order_ticket %I64u)",
                        m.candidate_id, m.order_ticket));
         report.ok = false; report.scan_stopped_early = true;
         report.stop_reason = "durable_confirmation_write_failure";
         report.first_error = StringFormat("EventStore_LogSystem failed for %s", m.candidate_id);
         return report;
      }

      // Recover the REAL durably-written line - never fabricate.
      string lines2[];
      int n2 = EventStore_ReadAllLines(fileName, lines2);
      string recoveredLogEventId; long recoveredSeq;
      int recoveredCount = C310B_FindMatchingRejectionConfirmation(lines2, n2,
                            m.candidate_id, m.order_ticket, m.execution_request_id, m.observed_kind,
                            m.source_log_event_id, m.source_sequence_number,
                            recoveredLogEventId, recoveredSeq);

      if(recoveredCount == 0)
      {
         SafeMode_Trip("C3.10B durable confirmation write succeeded but exact appended evidence could not be recovered");
         report.ok = false; report.scan_stopped_early = true;
         report.stop_reason = "confirmation_evidence_not_recovered";
         report.first_error = StringFormat("no matching durable confirmation line found for %s after a successful write",
                                             m.candidate_id);
         return report;
      }
      if(recoveredCount > 1)
      {
         SafeMode_Trip("C3.10B ambiguous durable confirmation evidence after write");
         report.ok = false; report.scan_stopped_early = true;
         report.stop_reason = "confirmation_evidence_ambiguous";
         report.first_error = StringFormat("%d matching durable confirmation lines found for %s (expected exactly 1)",
                                             recoveredCount, m.candidate_id);
         return report;
      }

      string transitionExtraJson = StringFormat(
         "\"confirmation_log_event_id\":\"%s\",\"confirmation_sequence_number\":%d",
         EventSerializer_Escape(recoveredLogEventId), recoveredSeq);

      if(!EventStore_LogTransition(candidate, CANDIDATE_REJECTED_BY_BROKER, reason, transitionExtraJson))
      {
         // EventStore_LogTransition auto-trips Safe Mode internally
         // ONLY on a durable-write failure (EventStore_AppendLifecycle
         // fails). If StateMachine_CanTransition instead rejected the
         // transition as illegal, that branch returns false with only
         // a LogWarn - no auto SafeMode_Trip - so trap that case here
         // explicitly rather than assume it was already handled.
         if(!SafeMode_IsActive())
            SafeMode_Trip(StringFormat("C3.10B lifecycle transition rejected as illegal for %s "
                           "(SUBMITTED -> REJECTED_BY_BROKER) despite a fresh pre-check confirming SUBMITTED - "
                           "state machine invariant violated", m.candidate_id));
         report.ok = false; report.scan_stopped_early = true;
         report.stop_reason = "durable_transition_write_failure";
         report.first_error = StringFormat("durable transition write failed for %s", m.candidate_id);
         return report;
      }

      // Recover the REAL durably-written transition line and apply it
      // to StateProjector - never fabricate. Without this step,
      // EventStore_LogTransition's own c.state=to mutation only ever
      // updates the LOCAL `candidate` variable above, which no other
      // consumer (a later match in this same scan, C3.7 running after
      // this authority, BrokerReconciliation_CheckAll) ever reads from
      // - same discipline C3.7 itself established
      // (LifecycleAuthorityProcessor.mqh: "synchronously applies the
      // REAL recovered durable event to StateProjector...so
      // BrokerReconciliation_CheckAll below sees this session's own
      // fresh EXECUTED candidates, not just prior-session ones").
      string lines3[];
      int n3 = EventStore_ReadAllLines(fileName, lines3);
      LifecycleEvent recoveredTransition;
      int transMatchCount = C310B_FindMatchingRejectionTransition(lines3, n3, m.candidate_id, recoveredTransition);

      if(transMatchCount == 0)
      {
         SafeMode_Trip("C3.10B durable transition write succeeded but exact appended lifecycle evidence could not be recovered");
         report.ok = false; report.scan_stopped_early = true;
         report.stop_reason = "transition_evidence_not_recovered";
         report.first_error = StringFormat("no matching durable CANDIDATE_REJECTED_BY_BROKER line found for %s after a successful write",
                                             m.candidate_id);
         return report;
      }
      if(transMatchCount > 1)
      {
         SafeMode_Trip("C3.10B ambiguous durable transition evidence after write");
         report.ok = false; report.scan_stopped_early = true;
         report.stop_reason = "transition_evidence_ambiguous";
         report.first_error = StringFormat("%d matching durable CANDIDATE_REJECTED_BY_BROKER lines found for %s (expected exactly 1)",
                                             transMatchCount, m.candidate_id);
         return report;
      }

      string applyErr;
      if(!StateProjector_Apply(recoveredTransition, applyErr))
      {
         SafeMode_Trip(StringFormat("C3.10B StateProjector_Apply failed after a successful durable write: %s", applyErr));
         report.ok = false; report.scan_stopped_early = true;
         report.stop_reason = "projector_apply_failed";
         report.first_error = applyErr;
         return report;
      }

      report.confirmed_count++;
   }

   return report;
}

#endif // __MLQUANTAI_ASYNCTERMINALREJECTIONAUTHORITY_MQH__
