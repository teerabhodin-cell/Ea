//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BoundedAutomationDiscovery.mqh    |
//| C5.2 §6.3 Bounded-Automation Design Contract - Wave 2 implemented   |
//| Rev.14 (6b7e836); R15-A reconciles it to Rev.15 (FROZEN, 07a3581).  |
//| Candidate discovery + invocation ordering.                          |
//|                                                                    |
//|   §2.3.1: the ONLY discovery source is the sealed                    |
//|          ExecutionRequestProjection_Count()/_GetAt(); the whole     |
//|          registry is scanned and every candidate's state is         |
//|          re-derived from durable evidence each invocation - no      |
//|          in-memory flag, cache or "already processed" marker.       |
//|          Rev.15: static ADMISSIBLE(X) (D3, D4) -> inadmissible SKIP.|
//|   §2.3.1a (R16 as amended by Rev.15): native index order, no sort.  |
//|          empty id -> STOP; inadmissible / SUBMISSION_ISSUED /        |
//|          AUTOMATION_EXHAUSTED -> SKIP; UNKNOWN -> STOP; the first    |
//|          admissible, state-eligible candidate is SELECTED.           |
//|   §2.3.2 frozen transition rule: mailbox occupancy is checked ONCE, |
//|          at the start; occupied -> the whole invocation is a no-op. |
//|   R15: any post-cutoff E1 that PROV-1 classifies INVALID halts       |
//|          automatic issuance (PROVENANCE_INVALID) - no recovery here.|
//|                                                                    |
//| Scope fence: this file SELECTS, it never issues. It does not call    |
//| BoundedAutomation_IssueCommand()/CeremonyCommandMailbox_Write(),     |
//| does not write the EventStore, and does not evaluate caps (Wave 3), |
//| pre-flight parity (R15-B) or kill switch / stage / environment      |
//| (Wave 5). Not called from MLQuantAI.mq5. No OrderSend/CTrade/C2     |
//| gate anywhere in this file.                                          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BOUNDEDAUTOMATIONDISCOVERY_MQH__
#define __MLQUANTAI_BOUNDEDAUTOMATIONDISCOVERY_MQH__

#include "MLQuantAI_BoundedAutomationIssuance.mqh"
#include "MLQuantAI_BoundedAutomationProvenance.mqh"
#include "MLQuantAI_BoundedAutomationPolicy.mqh"
#include "MLQuantAI_BoundedAutomationAdmissibility.mqh"

enum ENUM_BOUNDED_AUTOMATION_DISCOVERY_OUTCOME
{
   BOUNDED_AUTOMATION_DISCOVERY_UNKNOWN,
   BOUNDED_AUTOMATION_DISCOVERY_SNAPSHOT_INVALID,          // §2.3.2 step 1 precondition failed - issue nothing
   BOUNDED_AUTOMATION_DISCOVERY_MAILBOX_OCCUPIED,          // §2.3.2 frozen rule - whole invocation is a no-op
   BOUNDED_AUTOMATION_DISCOVERY_PROJECTION_READ_FAILED,    // GetAt(i) failed for i < Count() - fail closed
   BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_STATE_UNKNOWN,   // a candidate derived UNKNOWN - fail closed, stop the scan
   BOUNDED_AUTOMATION_DISCOVERY_NO_ELIGIBLE_CANDIDATE,     // scanned everything, nothing to issue
   BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_SELECTED,        // exactly one candidate selected
   BOUNDED_AUTOMATION_DISCOVERY_PROVENANCE_INVALID         // Rev.15/R15: a post-cutoff E1 is PROV-1 INVALID - halt, human reconciliation
};

string BoundedAutomationDiscoveryOutcome_ToString(ENUM_BOUNDED_AUTOMATION_DISCOVERY_OUTCOME o)
{
   switch(o)
   {
      case BOUNDED_AUTOMATION_DISCOVERY_SNAPSHOT_INVALID:        return "SNAPSHOT_INVALID";
      case BOUNDED_AUTOMATION_DISCOVERY_MAILBOX_OCCUPIED:        return "MAILBOX_OCCUPIED";
      case BOUNDED_AUTOMATION_DISCOVERY_PROJECTION_READ_FAILED:  return "PROJECTION_READ_FAILED";
      case BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_STATE_UNKNOWN: return "CANDIDATE_STATE_UNKNOWN";
      case BOUNDED_AUTOMATION_DISCOVERY_NO_ELIGIBLE_CANDIDATE:   return "NO_ELIGIBLE_CANDIDATE";
      case BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_SELECTED:      return "CANDIDATE_SELECTED";
      case BOUNDED_AUTOMATION_DISCOVERY_PROVENANCE_INVALID:      return "PROVENANCE_INVALID";
   }
   return "UNKNOWN";
}

struct BoundedAutomationSelection
{
   ENUM_BOUNDED_AUTOMATION_DISCOVERY_OUTCOME outcome;
   string                                    detail;              // diagnostic only
   int                                       candidates_scanned;  // how many GetAt() indices were evaluated this invocation
   int                                       selected_index;      // -1 unless CANDIDATE_SELECTED (also the failing index for the two fail-closed outcomes)
   ExecutionRequestProjectionRecord          selected_request;    // meaningful only when CANDIDATE_SELECTED
   ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE   selected_state;      // APPROVED_NOT_SUBMITTED or NOT_YET_APPROVED when selected
   ENUM_CEREMONY_COMMAND_TYPE                command_type;        // SUBMIT_ORDER or GRANT_MANUAL_APPROVAL when selected
   // Rev.15 skip accounting (diagnostic only - never read back by any decision)
   int                                       skipped_inadmissible;
   int                                       skipped_submission_issued;
   int                                       skipped_automation_exhausted;
};

void BoundedAutomationSelection_Init(BoundedAutomationSelection &s)
{
   s.outcome            = BOUNDED_AUTOMATION_DISCOVERY_UNKNOWN;
   s.detail             = "";
   s.candidates_scanned = 0;
   s.selected_index     = -1;
   ExecutionRequestProjectionRecord_Init(s.selected_request);
   s.selected_state     = BOUNDED_AUTOMATION_STATE_UNKNOWN;
   s.command_type       = CEREMONY_COMMAND_TYPE_UNKNOWN;
   s.skipped_inadmissible         = 0;
   s.skipped_submission_issued    = 0;
   s.skipped_automation_exhausted = 0;
}

//---------------------------------------------------------------------
// One invocation's selection, over inputs the caller read exactly once:
// validatedLines[] (BoundedAutomation_ReadValidatedSnapshot() == true),
// one mailbox snapshot, and one asOf. Reads only sealed projections and
// the validated snapshot. Writes nothing.
//
// Rev.15 order (§2.3.1a as amended, R16; P-3), R15-A:
//   invocation: mailbox occupied                     -> MAILBOX_OCCUPIED (no-op)
//               any post-cutoff E1 PROV-1 INVALID    -> PROVENANCE_INVALID (R15 halt)
//   per index (native GetAt order):
//     1. empty execution_request_id                  -> STOP (D6)
//     2. not ADMISSIBLE                              -> SKIP (D3, D4)
//     3. SUBMISSION_ISSUED                           -> SKIP
//        AUTOMATION_EXHAUSTED                        -> SKIP (D5)
//        APPROVED_NOT_SUBMITTED / NOT_YET_APPROVED   -> SELECT, stop
//        UNKNOWN (or anything else)                  -> STOP (D6)
// The policy is the frozen one (BoundedAutomationPolicy_InitFrozen) - no
// caller can pass different values.
//---------------------------------------------------------------------
void BoundedAutomation_SelectCandidate(const string &validatedLines[],
                                       const BoundedAutomationMailboxSnapshot &mailbox,
                                       datetime asOf,
                                       BoundedAutomationSelection &out)
{
   BoundedAutomationSelection_Init(out);

   if(BoundedAutomation_MailboxIsOccupied(mailbox))
   {
      out.outcome = BOUNDED_AUTOMATION_DISCOVERY_MAILBOX_OCCUPIED;
      out.detail  = "mailbox holds command_id=" + mailbox.command.command_id + " status=" +
                    CeremonyMailboxStatus_ToString(mailbox.command.mailbox_status);
      return;
   }

   BoundedAutomationProvenanceScan provenance;
   BoundedAutomation_ScanProvenance(validatedLines, provenance);
   if(provenance.invalid > 0)
   {
      out.outcome = BOUNDED_AUTOMATION_DISCOVERY_PROVENANCE_INVALID;
      out.detail  = StringFormat("%d post-cutoff E1 line(s) classify INVALID under PROV-1 (first at snapshot line %d) - "
                                 "automatic issuance halted until human reconciliation (R15)",
                                 provenance.invalid, provenance.first_invalid_index);
      return;
   }

   BoundedAutomationPolicy policy;
   BoundedAutomationPolicy_InitFrozen(policy);

   int count = ExecutionRequestProjection_Count();
   for(int i = 0; i < count; i++)
   {
      ExecutionRequestProjectionRecord request;
      if(!ExecutionRequestProjection_GetAt(i, request))
      {
         out.outcome        = BOUNDED_AUTOMATION_DISCOVERY_PROJECTION_READ_FAILED;
         out.selected_index = i;
         out.detail         = StringFormat("ExecutionRequestProjection_GetAt(%d) failed with Count()=%d", i, count);
         return;
      }
      out.candidates_scanned++;

      // 1. record integrity - STOP, never skip untrusted data (D6)
      if(request.execution_request_id == "")
      {
         out.outcome        = BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_STATE_UNKNOWN;
         out.selected_index = i;
         out.detail         = StringFormat("index %d has an empty execution_request_id - untrusted record, scan stopped", i);
         return;
      }

      // 2. static admissibility - SKIP (D3, D4)
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY admissibility = BoundedAutomation_CheckAdmissible(request, validatedLines, policy);
      if(admissibility != BOUNDED_AUTOMATION_ADMISSIBLE)
      {
         out.skipped_inadmissible++;
         continue;
      }

      // 3. §2.3.2 state
      ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE state = BoundedAutomation_EvaluateCandidateState(validatedLines, mailbox, request, asOf);

      if(state == BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED)
      {
         out.skipped_submission_issued++;
         continue;
      }
      if(state == BOUNDED_AUTOMATION_STATE_AUTOMATION_EXHAUSTED)
      {
         out.skipped_automation_exhausted++;
         continue;
      }

      ENUM_CEREMONY_COMMAND_TYPE commandType;
      if(BoundedAutomation_StateIssuesCommand(state, commandType))
      {
         out.outcome          = BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_SELECTED;
         out.selected_index   = i;
         out.selected_request = request;
         out.selected_state   = state;
         out.command_type     = commandType;
         out.detail           = "execution_request_id=" + request.execution_request_id + " state=" +
                                BoundedAutomationCandidateState_ToString(state);
         return;
      }

      // UNKNOWN (or any state that neither skips nor issues) - STOP (D6)
      out.outcome        = BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_STATE_UNKNOWN;
      out.selected_index = i;
      out.detail         = StringFormat("index %d execution_request_id='%s' state=%s", i, request.execution_request_id,
                                        BoundedAutomationCandidateState_ToString(state));
      return;
   }

   out.outcome = BOUNDED_AUTOMATION_DISCOVERY_NO_ELIGIBLE_CANDIDATE;
   if(out.candidates_scanned == 0)
      out.detail = "registry empty - 0 candidates";
   else
      out.detail = StringFormat("%d candidate(s) scanned, none eligible (inadmissible=%d, submission_issued=%d, automation_exhausted=%d)",
                                out.candidates_scanned, out.skipped_inadmissible, out.skipped_submission_issued,
                                out.skipped_automation_exhausted);
}

//---------------------------------------------------------------------
// The per-invocation entry point: exactly ONE validated EventStore read
// and exactly ONE mailbox read, then BoundedAutomation_SelectCandidate().
// asOf is the invocation's single captured time (Wave 5 passes
// TimeCurrent()). The mailbox is not read at all when the snapshot is
// invalid - nothing can be issued anyway.
//---------------------------------------------------------------------
void BoundedAutomation_DiscoverForInvocation(string eventStoreFileName, datetime asOf, BoundedAutomationSelection &out)
{
   BoundedAutomationSelection_Init(out);

   string lines[];
   string err;
   if(!BoundedAutomation_ReadValidatedSnapshot(eventStoreFileName, lines, err))
   {
      out.outcome = BOUNDED_AUTOMATION_DISCOVERY_SNAPSHOT_INVALID;
      out.detail  = err;
      return;
   }

   BoundedAutomationMailboxSnapshot mailbox;
   BoundedAutomation_ReadMailboxSnapshot(mailbox);

   BoundedAutomation_SelectCandidate(lines, mailbox, asOf, out);
}

#endif // __MLQUANTAI_BOUNDEDAUTOMATIONDISCOVERY_MQH__
