//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_LifecycleAuthorityProcessor.mqh   |
//| C3.7 implementation (per                                          |
//| Docs/PhaseC_C3_7_BoundedLifecycleAuthorityContract.md, FROZEN).    |
//|                                                                    |
//| The SOLE component authorized to turn a C3.6 RECOMMEND_EXECUTED    |
//| row into a real, durable CANDIDATE_SUBMITTED -> CANDIDATE_EXECUTED |
//| lifecycle transition, via the existing sealed                     |
//| EventStore_LogTransition() - the same production write path C2.2's |
//| BrokerSubmissionAdapter already uses. No new ENUM_EVENT_TYPE, no   |
//| new ENUM_REASON_CODE (EVENT_TYPE_CANDIDATE_EXECUTED and            |
//| REASON_EXECUTED_OK already exist, sealed, previously unused).      |
//|                                                                    |
//| RECOMMEND_EXECUTED is evidence, never write-time authority: a      |
//| FRESH StateProjector_TryGetState() re-check happens immediately    |
//| before every transition attempt - DeferredRecommendationRecord.    |
//| candidate_state_evidence (a C3.6-scan-time snapshot) is never      |
//| trusted for the write itself.                                      |
//|                                                                    |
//| After a successful durable write, this file does NOT fabricate a   |
//| LifecycleEvent for StateProjector_Apply. It re-reads the event      |
//| store via the existing, sealed EventStore_ReadAllLines() and       |
//| parses the real just-appended line back via the existing, sealed   |
//| EventSerializer_ParseLifecycle() - the SAME deserializer            |
//| ReplayEngine_Run() itself uses - so this session's in-memory        |
//| StateProjector state is always built from the true durable event    |
//| (real sequence_number/log_event_id/ts), never a semantically        |
//| similar substitute. The matching line is found by scanning EVERY    |
//| re-read line and checking every field explicitly (candidate_id/     |
//| from_state/to_state/reason/c3_6_action_id) - "the last line in the   |
//| file" is never assumed, since a future SYSTEM_STOPPED or other       |
//| diagnostic/system line could follow. Exactly one match is required;  |
//| zero or more than one both engage Safe Mode and stop the scan.       |
//|                                                                      |
//| On a durable-write failure OR a post-write evidence/apply failure,   |
//| this scan STOPS immediately (never continues to attempt further      |
//| transitions once state integrity is uncertain) and the caller must   |
//| skip BrokerReconciliation_CheckAll() for that session (see the       |
//| report's own .ok field) - reconciling against a provably-diverged    |
//| read model would be worse than skipping it.                          |
//|                                                                       |
//| Strictly bounded: no History*/Position*/Order*/OrderSend/CTrade API,  |
//| no OnTick/OnTradeTransaction, no RECOMMEND_REJECTED handling, no       |
//| edit to any sealed file, no *_RebuildFromFile call of any kind (reads |
//| only the already-built C3.6 registry + StateProjector +               |
//| CandidateProjection read models). BrokerReconciliation.mqh itself is  |
//| never touched - only its position in MLQuantAI.mq5's OnInit shifts.   |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_LIFECYCLEAUTHORITYPROCESSOR_MQH__
#define __MLQUANTAI_LIFECYCLEAUTHORITYPROCESSOR_MQH__

#include "MLQuantAI_DeferredTransactionProcessor.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_StateProjector.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_SafeModeState.mqh"
#include "../Logging/MLQuantAI_SystemLogger.mqh"

//---------------------------------------------------------------------
// Report (contract section 9's failure table + section 10's
// observability rule). ok=false only on a scan-level failure (durable
// write failure / evidence-recovery failure / ambiguous-evidence
// failure / StateProjector_Apply failure) - the caller (MLQuantAI.mq5's
// OnInit) must skip BrokerReconciliation_CheckAll() when ok==false.
//---------------------------------------------------------------------
struct LifecycleAuthorityReport
{
   bool   ok;
   int    recommendations_total;                  // C3.6 registry size
   int    blocked_count;                           // tallied from C3.6 registry (informational)
   int    none_count;                               // tallied from C3.6 registry (informational)
   int    eligible_count;                            // RECOMMEND_EXECUTED rows in C3.6 registry
   int    transitioned_count;                         // successfully written + applied this scan
   int    skipped_not_submitted;                       // section 1 clause 2 - state absent/not SUBMITTED
   int    skipped_missing_candidate_projection;          // section 1 clause 3
   int    skipped_missing_provenance;                      // section 1 clause 4
   bool   scan_stopped_early;
   string stop_reason;   // "" | "durable_write_failure" | "evidence_not_recovered" | "ambiguous_evidence" | "projector_apply_failed"
   string first_error;
};

void LifecycleAuthorityReport_Init(LifecycleAuthorityReport &r)
{
   r.ok                                     = true;
   r.recommendations_total                   = 0;
   r.blocked_count                            = 0;
   r.none_count                                = 0;
   r.eligible_count                             = 0;
   r.transitioned_count                          = 0;
   r.skipped_not_submitted                        = 0;
   r.skipped_missing_candidate_projection          = 0;
   r.skipped_missing_provenance                     = 0;
   r.scan_stopped_early                              = false;
   r.stop_reason                                      = "";
   r.first_error                                       = "";
}

//---------------------------------------------------------------------
// extra_json provenance contract (contract section 7, FROZEN field
// set) - copied verbatim from the RECOMMEND_EXECUTED row, never
// recomputed or re-derived.
//---------------------------------------------------------------------
string C37_BuildExtraJson(const DeferredRecommendationRecord &row)
{
   string dealTicketsJson = "[";
   int dn = ArraySize(row.deal_tickets);
   for(int i = 0; i < dn; i++)
   {
      if(i > 0) dealTicketsJson += ",";
      dealTicketsJson += IntegerToString((long)row.deal_tickets[i]);
   }
   dealTicketsJson += "]";

   string dealLogEventIdsJson = "[";
   int ldn = ArraySize(row.deal_source_log_event_ids);
   for(int i = 0; i < ldn; i++)
   {
      if(i > 0) dealLogEventIdsJson += ",";
      dealLogEventIdsJson += "\"" + EventSerializer_Escape(row.deal_source_log_event_ids[i]) + "\"";
   }
   dealLogEventIdsJson += "]";

   string dealSeqNumsJson = "[";
   int sdn = ArraySize(row.deal_source_sequence_numbers);
   for(int i = 0; i < sdn; i++)
   {
      if(i > 0) dealSeqNumsJson += ",";
      dealSeqNumsJson += IntegerToString(row.deal_source_sequence_numbers[i]);
   }
   dealSeqNumsJson += "]";

   string s = "";
   s += "\"c3_7_schema_version\":\"C37_V1\",";
   s += "\"c3_6_action_id\":\""                             + EventSerializer_Escape(row.action_id) + "\",";
   s += "\"execution_request_id\":\""                       + EventSerializer_Escape(row.execution_request_id) + "\",";
   s += "\"order_ticket\":"                                  + IntegerToString((long)row.order_ticket) + ",";
   s += "\"deal_tickets_sorted\":"                            + dealTicketsJson + ",";
   s += "\"terminal_match_status\":\"MATCHED_VOLUME_REACHED\",";
   s += "\"running_filled_volume\":"                           + DoubleToString(row.running_filled_volume, 8) + ",";
   s += "\"intended_lot_size\":"                                + DoubleToString(row.intended_lot_size, 8) + ",";
   s += "\"execution_request_source_log_event_id\":\""          + EventSerializer_Escape(row.execution_request_source_log_event_id) + "\",";
   s += "\"execution_request_source_sequence_number\":"          + IntegerToString(row.execution_request_source_sequence_number) + ",";
   s += "\"deal_source_log_event_ids_sorted\":"                   + dealLogEventIdsJson + ",";
   s += "\"deal_source_sequence_numbers_sorted\":"                 + dealSeqNumsJson;
   return s;
}

//---------------------------------------------------------------------
// Durable-evidence recovery (the frozen refinement over "last line in
// the file"). Scans EVERY re-read line, matching every field
// explicitly: category==LIFECYCLE, candidate_id, from_state==SUBMITTED,
// to_state==EXECUTED, reason==REASON_EXECUTED_OK, and extra_json
// carrying this exact c3_6_action_id. Returns the number of matches
// found (0/1/2+); outEvent is populated only when exactly one match
// exists. Internal to this file - not a new public EventStore API, and
// takes lines[] directly (never opens/reads a file itself) so it can be
// exercised in isolation by the test suite for the zero/multiple-match
// cases without violating append semantics.
//---------------------------------------------------------------------
int C37_FindMatchingExecutedLine(const string &lines[], int n, string candidateId, string actionId,
                                  LifecycleEvent &outEvent)
{
   int matchCount = 0;
   for(int i = n - 1; i >= 0; i--)
   {
      string line = lines[i];
      if(line == "") continue;
      if(EventSerializer_PeekCategory(line) != EVENT_CAT_LIFECYCLE) continue;

      LifecycleEvent e;
      if(!EventSerializer_ParseLifecycle(line, e)) continue;

      if(e.candidate_id != candidateId) continue;
      if(e.from_state != CANDIDATE_SUBMITTED || e.to_state != CANDIDATE_EXECUTED) continue;
      if(e.reason != REASON_EXECUTED_OK) continue;
      if(StringFind(e.extra_json, "\"c3_6_action_id\":\"" + actionId + "\"") < 0) continue;

      matchCount++;
      if(matchCount == 1) outEvent = e;
   }
   return matchCount;
}

//---------------------------------------------------------------------
// THE entry point (contract section 3, FROZEN OnInit placement).
// Slots between DeferredTransactionProcessor_StartupScan (C3.6) and
// BrokerReconciliation_CheckAll. Reads the already-built C3.6
// recommendation registry, StateProjector, and CandidateProjection only
// - never reparses the event store or rebuilds any upstream projection
// at runtime. fileName is used only for the durable-evidence read-back
// after each successful write (section 8's frozen refinement), never to
// re-derive any upstream projection.
//---------------------------------------------------------------------
LifecycleAuthorityReport LifecycleAuthority_StartupApply(string fileName)
{
   LifecycleAuthorityReport report;
   LifecycleAuthorityReport_Init(report);

   int total = DeferredTransactionProcessor_Count();
   report.recommendations_total = total;

   // First pass: tally the COMPLETE C3.6 registry - decoupled from the
   // transition-attempting loop below, so the blocked-count summary WARN
   // (contract section 10) always reflects everything C3.6 produced,
   // even if the second pass stops early on a failure.
   for(int i = 0; i < total; i++)
   {
      DeferredRecommendationRecord row;
      if(!DeferredTransactionProcessor_GetAt(i, row)) continue;
      switch(row.recommended_action)
      {
         case RECOMMEND_BLOCKED:  report.blocked_count++;  break;
         case RECOMMEND_NONE:     report.none_count++;     break;
         case RECOMMEND_EXECUTED: report.eligible_count++; break;
      }
   }

   // Contract section 10: exactly one summary WARN, never per-row. NONE
   // rows never produce a warning - an expected, non-terminal condition.
   if(report.blocked_count > 0)
      LogWarn(StringFormat("C3.7 lifecycle authority: %d recommendation(s) blocked; no blocked row was transitioned.",
              report.blocked_count));

   // Second pass: attempt the transition for every RECOMMEND_EXECUTED
   // row, in the C3.6 registry's own frozen semantic order (C3.6
   // contract section 13). Stops immediately on any transition-layer
   // failure - never continues to attempt further transitions once
   // state integrity is uncertain (contract section 9's corrected
   // failure semantics).
   for(int i = 0; i < total; i++)
   {
      DeferredRecommendationRecord row;
      if(!DeferredTransactionProcessor_GetAt(i, row)) continue;
      if(row.recommended_action != RECOMMEND_EXECUTED) continue;

      // Section 1 clause 4: structural provenance completeness.
      if(row.action_id == "" || row.execution_request_id == "" || row.order_ticket == 0)
      {
         report.skipped_missing_provenance++;
         continue;
      }

      // Section 1 clause 2 / section 6: FRESH live state re-check -
      // never trust row.candidate_state_evidence, a C3.6-scan-time
      // snapshot, as write-time authority.
      ENUM_CANDIDATE_STATE liveState;
      if(!StateProjector_TryGetState(row.candidate_id, liveState) || liveState != CANDIDATE_SUBMITTED)
      {
         report.skipped_not_submitted++;
         continue;
      }

      // Section 1 clause 3 / section 6: CandidateProjection lineage.
      CandidateProjectionRecord candRec;
      if(!CandidateProjection_TryGet(row.candidate_id, candRec))
      {
         report.skipped_missing_candidate_projection++;
         continue;
      }

      // Section 6: two-source TradeCandidate assembly. .state comes
      // ONLY from the fresh StateProjector lookup above - never from
      // CandidateProjectionRecord.state, which is always CREATED in
      // that B6-only projection.
      TradeCandidate candidate;
      TradeCandidate_Init(candidate);
      candidate.candidate_id   = candRec.candidate_id;
      candidate.root_event_id  = candRec.root_event_id;
      candidate.correlation_id = candRec.correlation_id;
      candidate.strategy_id    = candRec.strategy_id;
      candidate.state           = liveState;

      string extraJson = C37_BuildExtraJson(row);

      if(!EventStore_LogTransition(candidate, CANDIDATE_EXECUTED, REASON_EXECUTED_OK, extraJson))
      {
         // Durable write failure - EventStore_LogTransition already
         // called SafeMode_Trip internally (sealed, unchanged behavior).
         // Stop here: state integrity is now uncertain, never continue
         // to attempt further transitions this scan.
         report.ok               = false;
         report.scan_stopped_early = true;
         report.stop_reason        = "durable_write_failure";
         report.first_error         = StringFormat("durable write failed for candidate %s", row.candidate_id);
         LogWarn(StringFormat("C3.7 lifecycle authority: durable transition write failed for %s - stopping scan, "
                 "skipping reconciliation this session.", row.candidate_id));
         return report;
      }

      // Recover the REAL durably-written line - never fabricate a
      // LifecycleEvent (contract section 8's frozen refinement). Never
      // assume "last line in the file" - scan and match every field
      // explicitly.
      string lines[];
      int n = EventStore_ReadAllLines(fileName, lines);
      LifecycleEvent recovered;
      int matchCount = C37_FindMatchingExecutedLine(lines, n, row.candidate_id, row.action_id, recovered);

      if(matchCount == 0)
      {
         SafeMode_Trip("C3.7 durable transition write succeeded but exact appended lifecycle evidence could not be recovered");
         report.ok               = false;
         report.scan_stopped_early = true;
         report.stop_reason        = "evidence_not_recovered";
         report.first_error         = StringFormat("no matching durable CANDIDATE_EXECUTED line found for %s after a successful write", row.candidate_id);
         return report;
      }
      if(matchCount > 1)
      {
         SafeMode_Trip("C3.7 ambiguous durable transition evidence after write");
         report.ok               = false;
         report.scan_stopped_early = true;
         report.stop_reason        = "ambiguous_evidence";
         report.first_error         = StringFormat("%d matching durable CANDIDATE_EXECUTED lines found for %s (expected exactly 1)",
                                                     matchCount, row.candidate_id);
         return report;
      }

      string applyErr;
      if(!StateProjector_Apply(recovered, applyErr))
      {
         SafeMode_Trip(StringFormat("C3.7 StateProjector_Apply failed after a successful durable write: %s", applyErr));
         report.ok               = false;
         report.scan_stopped_early = true;
         report.stop_reason        = "projector_apply_failed";
         report.first_error         = applyErr;
         return report;
      }

      report.transitioned_count++;
   }

   LogInfo(StringFormat("C3.7 lifecycle authority: startup apply complete - %d/%d eligible recommendation(s) transitioned "
           "(skipped: not_submitted=%d missing_candidate_projection=%d missing_provenance=%d).",
           report.transitioned_count, report.eligible_count, report.skipped_not_submitted,
           report.skipped_missing_candidate_projection, report.skipped_missing_provenance));

   return report;
}

#endif // __MLQUANTAI_LIFECYCLEAUTHORITYPROCESSOR_MQH__
