//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_RolloutGateReadinessEvaluate.mqh  |
//| §6.2 Evidence-Gate Design Contract Rev.8 (QA-frozen DESIGN FREEZE, |
//| Docs/PhaseC_C5_2_Section6_2_EvidenceGateDesignContract.md): the     |
//| single evaluator this whole checkpoint exists to build -           |
//| RolloutGateReadiness_Evaluate() - purpose-built for exactly the     |
//| DEMO_DRY_RUN -> DEMO_REAL_SUBMIT forward pair (§1's own window       |
//| anchor is hardcoded to ROLLOUT_STAGE_DEMO_DRY_RUN; this is not a      |
//| generic "evaluate any rollout pair" function). Called ONLY from       |
//| MLQuantAI_RolloutStageTransitionCommandProcess.mqh, strictly BEFORE     |
//| RolloutStageTransition_Emit() (Commit 1, frozen, unmodified), gated       |
//| to that one pair (§7 Authority Boundary) - an ALLOW here means ONLY        |
//| "eligible to durably record the transition", never an OrderSend           |
//| authorization.                                                              |
//|                                                                              |
//| Frozen evaluation order (§0/§1/§2/§2.1/§2.2/§6/§7.1/§7.2), exactly as         |
//| this checkpoint's whole design-review cycle converged on:                     |
//|   1. §7.2 session-establishment gate (g_C62SessionEstablishmentResult)         |
//|   2. §1  observation-window lookup (to_stage=DEMO_DRY_RUN, "latest wins")       |
//|   3. fresh CandidateProjection_RebuildFromFile / BrokerSubmissionAudit           |
//|      Projection_RebuildFromFile (audit_chain_broken on either failure)           |
//|   4. P1 - 0 duplicate submissions in-window (duplicate_exact /                    |
//|      duplicate_conflicting)                                                        |
//|   5. P2 - 0 uncorrelated broker facts in-window (delegates to                       |
//|      MLQuantAI_BrokerFactCorrelationVerify.mqh, unmodified)                          |
//|   6. P3 - 100% durable audit linkage for every in-window terminal                     |
//|      candidate (delegates to MLQuantAI_CandidateTerminalTransitionLocator.mqh,          |
//|      unmodified)                                                                          |
//|   7. P4a - fresh ReplayEngine_Run + BrokerReconciliation_CheckAll, both must               |
//|      be .ok                                                                                  |
//|   8. P4b - >=1 EVENT_TYPE_EA_SESSION_STARTED line in-window                                    |
//|   9. P4c - fresh POST-P4a re-read: no durable Safe Mode engagement ever                          |
//|      in-window, and no out-of-band quarantine witness present (catches a                          |
//|      Safe-Mode trip self-caused by P4a's own BrokerReconciliation_CheckAll)                          |
//|  10. §2.2 - independent g_C62IntegrityFatalHalt check (belt-and-suspenders                              |
//|      alongside ExpertRemove() itself, see MLQuantAI_SafeModeState.mqh)                                    |
//|  11. §2.1 - final fresh re-read, compared byte-for-byte against the ORIGINAL                                |
//|      lines[] snapshot this function was called with (size-inequality checked                                 |
//|      first, either direction) - any mismatch is an unconditional REJECT                                        |
//|                                                                                                                    |
//| Exactly ONE code path reaches allow=true, only after every predicate above                                         |
//| independently confirmed true (§6) - any sub-check error is itself a REJECT,                                          |
//| never defaulted to ALLOW.                                                                                              |
//|                                                                                                                            |
//| Relies on g_C62SessionEstablishmentResult/g_C62IntegrityFatalHalt (both        |
//| module globals defined in files included below) and on g_EventStore_FileName    |
//| (MLQuantAI_EventStore.mqh, included transitively) as the fresh-read target for    |
//| every *_RebuildFromFile/ReplayEngine_Run/EventStore_ReadAllLines call in this       |
//| file - never a caller-supplied filename, so every fresh read is always against       |
//| the one real, currently-open store.                                                     |
//|                                                                                            |
//| Pure with respect to candidate-lifecycle/OrderSend authority: this file itself             |
//| never appends an event, never calls OrderSend, never trips/clears Safe Mode -               |
//| ReplayEngine_Run/BrokerReconciliation_CheckAll (P4a) are the only calls here that             |
//| can have a side effect (BrokerReconciliation_CheckAll may call SafeMode_Trip()                 |
//| internally on a mismatch, which is exactly why P4c re-reads fresh AFTER P4a               |
//| rather than reusing an earlier snapshot).                                                     |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ROLLOUTGATEREADINESSEVALUATE_MQH__
#define __MLQUANTAI_ROLLOUTGATEREADINESSEVALUATE_MQH__

#include "../Core/MLQuantAI_Enums.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_RolloutStageObservationWindow.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_C62SessionEstablishment.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_CandidateTerminalTransitionLocator.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh"
#include "../Infrastructure/MLQuantAI_BrokerReconciliation.mqh"
#include "MLQuantAI_BrokerSubmissionAuditProjection.mqh"
#include "MLQuantAI_BrokerFactCorrelationVerify.mqh"

enum ENUM_ROLLOUT_GATE_READINESS_REASON
{
   ROLLOUT_GATE_READINESS_NONE,
   ROLLOUT_GATE_READINESS_ALLOW,
   ROLLOUT_GATE_READINESS_SESSION_NOT_ESTABLISHED,
   ROLLOUT_GATE_READINESS_WINDOW_NOT_FOUND,
   ROLLOUT_GATE_READINESS_AUDIT_CHAIN_BROKEN,
   ROLLOUT_GATE_READINESS_DUPLICATE_EXACT,
   ROLLOUT_GATE_READINESS_DUPLICATE_CONFLICTING,
   ROLLOUT_GATE_READINESS_UNCORRELATED_BROKER_FACT,
   ROLLOUT_GATE_READINESS_UNCORRELATED_BROKER_FACT_AMBIGUOUS,
   ROLLOUT_GATE_READINESS_TERMINAL_TRANSITION_NOT_LOCATED,
   ROLLOUT_GATE_READINESS_TERMINAL_TRANSITION_AMBIGUOUS,
   ROLLOUT_GATE_READINESS_EXECUTION_REQUEST_MISSING,
   ROLLOUT_GATE_READINESS_REPLAY_OR_RECONCILIATION_FAILED,
   ROLLOUT_GATE_READINESS_NO_SESSION_RESTART_EVIDENCE,
   ROLLOUT_GATE_READINESS_SAFE_MODE_ENGAGED_IN_WINDOW,
   ROLLOUT_GATE_READINESS_INTEGRITY_FATAL_HALT,
   ROLLOUT_GATE_READINESS_EVIDENCE_SNAPSHOT_CHANGED
};

string RolloutGateReadinessReasonToString(ENUM_ROLLOUT_GATE_READINESS_REASON r)
{
   switch(r)
   {
      case ROLLOUT_GATE_READINESS_ALLOW:                              return "allow";
      case ROLLOUT_GATE_READINESS_SESSION_NOT_ESTABLISHED:            return "session_not_established";
      case ROLLOUT_GATE_READINESS_WINDOW_NOT_FOUND:                   return "window_not_found";
      case ROLLOUT_GATE_READINESS_AUDIT_CHAIN_BROKEN:                 return "audit_chain_broken";
      case ROLLOUT_GATE_READINESS_DUPLICATE_EXACT:                    return "duplicate_exact";
      case ROLLOUT_GATE_READINESS_DUPLICATE_CONFLICTING:              return "duplicate_conflicting";
      case ROLLOUT_GATE_READINESS_UNCORRELATED_BROKER_FACT:           return "uncorrelated_broker_fact";
      case ROLLOUT_GATE_READINESS_UNCORRELATED_BROKER_FACT_AMBIGUOUS: return "uncorrelated_broker_fact_ambiguous";
      case ROLLOUT_GATE_READINESS_TERMINAL_TRANSITION_NOT_LOCATED:    return "terminal_transition_not_located";
      case ROLLOUT_GATE_READINESS_TERMINAL_TRANSITION_AMBIGUOUS:      return "terminal_transition_ambiguous";
      case ROLLOUT_GATE_READINESS_EXECUTION_REQUEST_MISSING:          return "execution_request_missing_for_terminal_candidate";
      case ROLLOUT_GATE_READINESS_REPLAY_OR_RECONCILIATION_FAILED:    return "replay_or_reconciliation_failed";
      case ROLLOUT_GATE_READINESS_NO_SESSION_RESTART_EVIDENCE:        return "no_session_restart_evidence";
      case ROLLOUT_GATE_READINESS_SAFE_MODE_ENGAGED_IN_WINDOW:        return "safe_mode_engaged_in_window";
      case ROLLOUT_GATE_READINESS_INTEGRITY_FATAL_HALT:               return "integrity_fatal_halt";
      case ROLLOUT_GATE_READINESS_EVIDENCE_SNAPSHOT_CHANGED:          return "evidence_snapshot_changed_during_evaluation";
   }
   return "none";
}

struct RolloutGateReadinessResult
{
   bool                                allow;
   ENUM_ROLLOUT_GATE_READINESS_REASON  reason;
   string                              diagnostic; // free-text, operator-facing detail - never parsed, reason is the machine-readable field
};

void RolloutGateReadinessResult_Init(RolloutGateReadinessResult &r)
{
   r.allow      = false;
   r.reason     = ROLLOUT_GATE_READINESS_NONE;
   r.diagnostic = "";
}

//---------------------------------------------------------------------
// Small local helpers - both new for this checkpoint, neither exists
// elsewhere in the codebase.
//---------------------------------------------------------------------

// P1: maps a projection record's own source_log_event_id back to its
// position within a raw lines[] snapshot - needed because
// SubmissionAttemptProjection is rebuilt from the fresh file (via
// BrokerSubmissionAuditProjection_RebuildFromFile), but window membership
// (§1) is decided against the ORIGINAL lines[] this function received as
// a parameter. A -1 result means the fresh rebuild and the original
// snapshot have diverged (the store grew between the caller's read and
// this evaluation) - treated as audit_chain_broken by every caller below,
// never silently skipped.
int FindLineIndexByLogEventId(const string &lines[], string logEventId)
{
   for(int i = 0; i < ArraySize(lines); i++)
      if(EventSerializer_GetStr(lines[i], "log_event_id") == logEventId)
         return i;
   return -1;
}

// §2.1: byte-for-byte comparison of a fresh re-read against the original
// snapshot. Size checked FIRST (either direction) so a shrink/corruption
// is caught before any index access ever occurs, per the frozen §2.1
// text.
bool EvidenceSnapshot_Unchanged(const string &original[], const string &fresh[])
{
   if(ArraySize(fresh) != ArraySize(original))
      return false;
   for(int i = 0; i < ArraySize(original); i++)
      if(fresh[i] != original[i])
         return false;
   return true;
}

//---------------------------------------------------------------------
// P1 - 0 duplicate submissions in-window. Dedup key: execution_request_id.
// Two in-window EXECUTION_SUBMISSION_ATTEMPTED lines sharing the same
// execution_request_id are ALWAYS a REJECT here (SubmissionAttemptProjection
// itself deliberately never dedupes by execution_request_id - "0..N,
// never deduped... a legitimate future retry" - that tolerance is correct
// for the audit registry in general, but this evidence gate's own frozen
// criterion is that the DEMO_DRY_RUN observation window itself must show
// zero such repeats before a real-money stage is unlocked). Exact hash
// match vs conflicting hash mismatch are reported with different
// diagnostic reason codes, both REJECT.
//---------------------------------------------------------------------
RolloutGateReadinessResult P1_VerifyNoDuplicateSubmissionsInWindow(const string &lines[], int windowStartIndex)
{
   RolloutGateReadinessResult result;
   RolloutGateReadinessResult_Init(result);

   int    inWindowLineIdx[];
   string inWindowRequestId[];
   string inWindowHash[];
   int    n = 0;

   for(int i = 0; i < SubmissionAttemptProjection_Count(); i++)
   {
      SubmissionAttemptProjectionRecord rec;
      SubmissionAttemptProjection_GetAt(i, rec);

      int lineIdx = FindLineIndexByLogEventId(lines, rec.source_log_event_id);
      if(lineIdx < 0)
      {
         result.reason     = ROLLOUT_GATE_READINESS_AUDIT_CHAIN_BROKEN;
         result.diagnostic = "P1: submission attempt log_event_id '" + rec.source_log_event_id +
                              "' from the fresh rebuild has no matching line in the evidence snapshot";
         return result;
      }
      if(lineIdx <= windowStartIndex) continue; // not in the observation window

      ArrayResize(inWindowLineIdx, n + 1);
      ArrayResize(inWindowRequestId, n + 1);
      ArrayResize(inWindowHash, n + 1);
      inWindowLineIdx[n]   = lineIdx;
      inWindowRequestId[n] = rec.execution_request_id;
      inWindowHash[n]      = rec.execution_request_hash;
      n++;
   }

   for(int a = 0; a < n; a++)
   {
      for(int b = a + 1; b < n; b++)
      {
         if(inWindowRequestId[a] != inWindowRequestId[b]) continue;

         if(inWindowHash[a] == inWindowHash[b])
         {
            result.reason     = ROLLOUT_GATE_READINESS_DUPLICATE_EXACT;
            result.diagnostic = "P1: execution_request_id '" + inWindowRequestId[a] +
                                 "' has more than one EXECUTION_SUBMISSION_ATTEMPTED line in-window with an identical execution_request_hash";
         }
         else
         {
            result.reason     = ROLLOUT_GATE_READINESS_DUPLICATE_CONFLICTING;
            result.diagnostic = "P1: execution_request_id '" + inWindowRequestId[a] +
                                 "' has more than one EXECUTION_SUBMISSION_ATTEMPTED line in-window with CONFLICTING execution_request_hash values";
         }
         return result;
      }
   }

   return result; // reason stays ROLLOUT_GATE_READINESS_NONE - P1 passed
}

//---------------------------------------------------------------------
// P3 - 100% durable audit linkage. Collects every DISTINCT candidate_id
// that entered a terminal ENUM_CANDIDATE_STATE in-window (raw scan over
// the caller's own lines[], never inferred from a rolled-up projection),
// then independently confirms each one via the frozen tri-state locator
// (MLQuantAI_CandidateTerminalTransitionLocator.mqh, unmodified) and, for
// EXECUTED/REJECTED_BY_BROKER/ERROR specifically, that an
// ExecutionRequestProjectionRecord actually exists for that candidate.
//---------------------------------------------------------------------
bool P3_ExecutionRequestExistsForCandidate(string candidateId)
{
   for(int i = 0; i < ExecutionRequestProjection_Count(); i++)
   {
      ExecutionRequestProjectionRecord rec;
      ExecutionRequestProjection_GetAt(i, rec);
      if(rec.candidate_id == candidateId) return true;
   }
   return false;
}

int P3_CollectTerminalCandidateIds(const string &lines[], int windowStartIndex, string &outCandidateIds[])
{
   ArrayResize(outCandidateIds, 0);
   int m = 0;

   for(int i = windowStartIndex + 1; i < ArraySize(lines); i++)
   {
      if(!EventSerializer_HasKey(lines[i], "candidate_id")) continue;
      if(!EventSerializer_HasKey(lines[i], "to_state")) continue;

      ENUM_CANDIDATE_STATE toState = CandidateStateFromString(EventSerializer_GetStr(lines[i], "to_state"));
      if(!StateMachine_IsTerminal(toState)) continue;

      string candidateId = EventSerializer_GetStr(lines[i], "candidate_id");

      bool already = false;
      for(int k = 0; k < m; k++)
         if(outCandidateIds[k] == candidateId) { already = true; break; }
      if(already) continue;

      ArrayResize(outCandidateIds, m + 1);
      outCandidateIds[m] = candidateId;
      m++;
   }
   return m;
}

RolloutGateReadinessResult P3_VerifyTerminalAuditLinkageInWindow(const string &lines[], int windowStartIndex)
{
   RolloutGateReadinessResult result;
   RolloutGateReadinessResult_Init(result);

   string terminalCandidateIds[];
   int m = P3_CollectTerminalCandidateIds(lines, windowStartIndex, terminalCandidateIds);

   for(int k = 0; k < m; k++)
   {
      int foundLineIdx;
      ENUM_TERMINAL_TRANSITION_LOCATE_RESULT locateResult =
         CandidateTerminalTransition_FindLineIndex(lines, terminalCandidateIds[k], foundLineIdx);

      if(locateResult == TERMINAL_TRANSITION_NOT_LOCATED)
      {
         result.reason     = ROLLOUT_GATE_READINESS_TERMINAL_TRANSITION_NOT_LOCATED;
         result.diagnostic = "P3: candidate '" + terminalCandidateIds[k] +
                              "' entered a terminal state in-window but the locator found no causing line in the durable log";
         return result;
      }
      if(locateResult == TERMINAL_TRANSITION_AMBIGUOUS)
      {
         result.reason     = ROLLOUT_GATE_READINESS_TERMINAL_TRANSITION_AMBIGUOUS;
         result.diagnostic = "P3: candidate '" + terminalCandidateIds[k] +
                              "' has more than one terminal-transition line in the durable log - anomaly";
         return result;
      }

      ENUM_CANDIDATE_STATE terminalState = CandidateStateFromString(EventSerializer_GetStr(lines[foundLineIdx], "to_state"));
      if(terminalState == CANDIDATE_EXECUTED || terminalState == CANDIDATE_REJECTED_BY_BROKER || terminalState == CANDIDATE_ERROR)
      {
         if(!P3_ExecutionRequestExistsForCandidate(terminalCandidateIds[k]))
         {
            result.reason     = ROLLOUT_GATE_READINESS_EXECUTION_REQUEST_MISSING;
            result.diagnostic = "P3: candidate '" + terminalCandidateIds[k] +
                                 "' reached EXECUTED/REJECTED_BY_BROKER/ERROR but has no ExecutionRequestProjection record";
            return result;
         }
      }
   }

   return result; // reason stays ROLLOUT_GATE_READINESS_NONE - P3 passed
}

//---------------------------------------------------------------------
// The main evaluator. lines[] is the caller's own fresh read, taken
// immediately before calling this function - §2.1 below re-reads and
// compares against exactly this same array, byte for byte.
//---------------------------------------------------------------------
RolloutGateReadinessResult RolloutGateReadiness_Evaluate(const string &lines[])
{
   RolloutGateReadinessResult result;
   RolloutGateReadinessResult_Init(result);

   // §7.2 - session-establishment gate. Any non-ESTABLISHED result
   // suspends §6.2 evaluation capability for the WHOLE session, never
   // just this one attempt.
   if(!C62SessionEstablishmentResult_PermitsEvaluation(g_C62SessionEstablishmentResult))
   {
      result.reason     = ROLLOUT_GATE_READINESS_SESSION_NOT_ESTABLISHED;
      result.diagnostic = "§7.2: session establishment result is '" +
                           C62SessionEstablishmentResultToString(g_C62SessionEstablishmentResult) + "' - evaluation suspended";
      return result;
   }

   // §1 - observation window. Anchored to the LATEST
   // EXECUTION_ROLLOUT_STAGE_CHANGED(to_stage=DEMO_DRY_RUN) line. Not
   // found is a hard REJECT, never an empty-but-usable window.
   int windowStartIndex;
   if(!RolloutStageObservationWindow_FindStart(lines, ROLLOUT_STAGE_DEMO_DRY_RUN, windowStartIndex))
   {
      result.reason     = ROLLOUT_GATE_READINESS_WINDOW_NOT_FOUND;
      result.diagnostic = "§1: no EXECUTION_ROLLOUT_STAGE_CHANGED(to_stage=DEMO_DRY_RUN) line found in the evidence snapshot";
      return result;
   }

   // Fresh rebuilds, both against the currently-open store file - a
   // failure in either leaves BOTH registries untouched (each rebuild's
   // own frozen fail-closed contract) and is reported identically here.
   CandidateProjectionReport candReport = CandidateProjection_RebuildFromFile(g_EventStore_FileName);
   if(!candReport.ok)
   {
      result.reason     = ROLLOUT_GATE_READINESS_AUDIT_CHAIN_BROKEN;
      result.diagnostic = "audit chain: CandidateProjection_RebuildFromFile failed - " + candReport.first_error;
      return result;
   }

   BrokerSubmissionAuditProjectionReport subReport = BrokerSubmissionAuditProjection_RebuildFromFile(g_EventStore_FileName);
   if(!subReport.ok)
   {
      result.reason     = ROLLOUT_GATE_READINESS_AUDIT_CHAIN_BROKEN;
      result.diagnostic = "audit chain: BrokerSubmissionAuditProjection_RebuildFromFile failed - " + subReport.first_error;
      return result;
   }

   // P1 - 0 duplicate submissions in-window.
   RolloutGateReadinessResult p1 = P1_VerifyNoDuplicateSubmissionsInWindow(lines, windowStartIndex);
   if(p1.reason != ROLLOUT_GATE_READINESS_NONE)
      return p1;

   // P2 - 0 uncorrelated broker facts in-window. Delegates entirely to
   // the canonical, unmodified resolver.
   BrokerFactCorrelationVerifyResult p2 = BrokerFactCorrelation_VerifyWindow(lines, windowStartIndex);
   if(p2.status == P2_VERIFY_UNCORRELATED)
   {
      result.reason     = ROLLOUT_GATE_READINESS_UNCORRELATED_BROKER_FACT;
      result.diagnostic = StringFormat("P2: uncorrelated broker fact at seq %d", (int)p2.failing_sequence_number);
      return result;
   }
   if(p2.status == P2_VERIFY_AMBIGUOUS)
   {
      result.reason     = ROLLOUT_GATE_READINESS_UNCORRELATED_BROKER_FACT_AMBIGUOUS;
      result.diagnostic = StringFormat("P2: ambiguous broker fact correlation at seq %d", (int)p2.failing_sequence_number);
      return result;
   }

   // P3 - 100% durable audit linkage for every in-window terminal candidate.
   RolloutGateReadinessResult p3 = P3_VerifyTerminalAuditLinkageInWindow(lines, windowStartIndex);
   if(p3.reason != ROLLOUT_GATE_READINESS_NONE)
      return p3;

   // P4a - fresh replay + broker reconciliation, both must be .ok. This
   // is the one step in this function that can have a side effect
   // (BrokerReconciliation_CheckAll may call SafeMode_Trip() on a
   // mismatch) - P4c below deliberately re-reads AFTER this, fresh, to
   // catch exactly that.
   ReplayReport replayReport = ReplayEngine_Run(g_EventStore_FileName);
   BrokerReconciliationReport reconReport = BrokerReconciliation_CheckAll();
   if(!replayReport.ok || !reconReport.ok)
   {
      result.reason     = ROLLOUT_GATE_READINESS_REPLAY_OR_RECONCILIATION_FAILED;
      result.diagnostic = "P4a: replay.ok=" + (replayReport.ok ? "true" : "false") +
                           " reconciliation.ok=" + (reconReport.ok ? "true" : "false");
      return result;
   }

   // P4b - >=1 EA_SESSION_STARTED line in-window (restart/replay
   // evidence actually exercised during the observation window).
   string sessionStartedType = EventTypeToString(EVENT_TYPE_EA_SESSION_STARTED);
   int sessionStartedCountInWindow = 0;
   for(int i = windowStartIndex + 1; i < ArraySize(lines); i++)
      if(EventSerializer_GetStr(lines[i], "type") == sessionStartedType)
         sessionStartedCountInWindow++;
   if(sessionStartedCountInWindow < 1)
   {
      result.reason     = ROLLOUT_GATE_READINESS_NO_SESSION_RESTART_EVIDENCE;
      result.diagnostic = "P4b: 0 EVENT_TYPE_EA_SESSION_STARTED lines in-window - restart/replay was never exercised during the observation window";
      return result;
   }

   // P4c - fresh POST-P4a re-read: no durable Safe Mode engagement ever
   // in-window, and no out-of-band quarantine witness present.
   string postP4aLines[];
   EventStore_ReadAllLines(g_EventStore_FileName, postP4aLines);

   bool safeModeEverEngaged;
   SafeModeProjection_ReplayEngagedDuringWindow(postP4aLines, windowStartIndex, safeModeEverEngaged);
   if(safeModeEverEngaged || SafeModeQuarantineWitness_Exists())
   {
      result.reason     = ROLLOUT_GATE_READINESS_SAFE_MODE_ENGAGED_IN_WINDOW;
      result.diagnostic = "P4c: Safe Mode was engaged during the observation window and/or a quarantine witness file is present";
      return result;
   }

   // §2.2 - independent integrity-fatal-halt gate, immediately before
   // §2.1's own final check, so the ALLOW return below can never be
   // reached regardless of ExpertRemove()'s own call-stack-unwind
   // behavior.
   if(g_C62IntegrityFatalHalt)
   {
      result.reason     = ROLLOUT_GATE_READINESS_INTEGRITY_FATAL_HALT;
      result.diagnostic = "§2.2: g_C62IntegrityFatalHalt is true - a prior double I/O failure already halted evidence integrity for this session";
      return result;
   }

   // §2.1 - final evidence snapshot consistency gate. Fresh re-read,
   // compared byte-for-byte against the ORIGINAL lines[] this function
   // was called with. Size-inequality checked first (either direction),
   // inside EvidenceSnapshot_Unchanged().
   string finalLines[];
   EventStore_ReadAllLines(g_EventStore_FileName, finalLines);
   if(!EvidenceSnapshot_Unchanged(lines, finalLines))
   {
      result.reason     = ROLLOUT_GATE_READINESS_EVIDENCE_SNAPSHOT_CHANGED;
      result.diagnostic = "§2.1: the evidence snapshot changed during evaluation - re-evaluate against a fresh read";
      return result;
   }

   result.allow      = true;
   result.reason     = ROLLOUT_GATE_READINESS_ALLOW;
   result.diagnostic = "§6.2 evidence gate: all frozen criteria satisfied";
   return result;
}

#endif // __MLQUANTAI_ROLLOUTGATEREADINESSEVALUATE_MQH__
