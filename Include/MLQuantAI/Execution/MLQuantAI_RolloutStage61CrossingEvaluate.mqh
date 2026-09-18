//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_RolloutStage61CrossingEvaluate.mqh |
//| §6.1 Evidence-Gate Design Contract Rev.4 (QA-frozen DESIGN FREEZE,  |
//| Docs/PhaseC_C5_2_Section6_1_PipelineOutsideTesterDesignContract.md): |
//| the ONE declared environment-crossing pair's own dedicated           |
//| predicate - isDeclaredEnvironmentCrossingPair() (§1.2's closed,        |
//| per-pair whitelist) plus RolloutStage61Crossing_Evaluate() (§1.3's      |
//| 6 preconditions). Called ONLY from                                       |
//| MLQuantAI_RolloutStageTransitionCommandProcess.mqh's Step 2, in           |
//| place of the ORIGINAL blanket RolloutStage_IsValidForEnvironment(          |
//| currentStage, environmentMode) check, and ONLY for the one pair            |
//| isDeclaredEnvironmentCrossingPair() returns true for (§1.2). Every           |
//| other pair (including DEMO_BOUNDED_AUTOMATION -> LIVE_SHADOW) is              |
//| completely untouched by this file and keeps the ORIGINAL blanket check         |
//| byte-for-byte (Commit-2's own frozen regression test #6).                        |
//|                                                                                     |
//| §1.4's three invariants (A/B/C), restated as code-level facts about this           |
//| file specifically:                                                                   |
//|   A - RolloutStage_IsValidForEnvironment() (MLQuantAI_RolloutStageCrossValidity.      |
//|       mqh) is called here (item 6, defense-in-depth) but never modified -              |
//|       TEST_FIXTURE x DEMO remains `reject` in that table, unconditionally,               |
//|       forever.                                                                             |
//|   B - an ALLOW from this file means ONLY "this specific, declared transition                |
//|       is eligible to be durably recorded" (§7) - never "TEST_FIXTURE is valid                 |
//|       under DEMO."                                                                              |
//|   C - isDeclaredEnvironmentCrossingPair() is a closed, hard-coded, per-pair                       |
//|       identity check - no flag, no parameter, no config value anywhere in this                     |
//|       file can widen it. A future pair (e.g. a hypothetical, not-yet-frozen                          |
//|       §6.4) requires its OWN independently-frozen design contract and its                             |
//|       OWN amendment to this function - never inferred from this pair's                                   |
//|       precedent.                                                                                             |
//|                                                                                                                  |
//| §1.5's tie to Step 3: this file does NOT touch                                                                   |
//| RolloutStageTransition_IsForwardPairImplemented() (Commit-1-sealed,                                                |
//| MLQuantAI_RolloutStageTransitionEvaluate.mqh) - that function's own,                                                  |
//| separate amendment (flipping (TEST_FIXTURE, DEMO_DRY_RUN) to true) is what                                              |
//| lets Step 3 agree with this file's own ALLOW. Both amendments are driven by                                               |
//| the SAME single declared pair (§1.5) - never two independently-maintained                                                   |
//| lists.                                                                                                                          |
//|                                                                                                                                    |
//| §2/§3 evidence predicates (P1/P2) below reuse only sealed, unmodified                                                              |
//| infrastructure - RolloutStageObservationWindow_FindStart,                                                                            |
//| CandidateProjection_RebuildFromFile/_TryGet,                                                                                           |
//| ExecutionAuditProjection_RebuildFromFile/ExecutionRequestProjection_TryGet,                                                              |
//| ReplayEngine_Run, SafeModeProjection_ReplayEngagedDuringWindow,                                                                            |
//| SafeModeQuarantineWitness_Exists - exactly the same reuse discipline §6.2's                                                                 |
//| own evaluator (MLQuantAI_RolloutGateReadinessEvaluate.mqh) established.                                                                        |
//|                                                                                                                                                    |
//| Relies on g_EventStore_FileName / g_RolloutIntegrityFatalHalt (both module                                                                          |
//| globals, included transitively below) as the fresh-read target/gate for                                                                              |
//| every rebuild call in this file - never a caller-supplied filename.                                                                                     |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ROLLOUTSTAGE61CROSSINGEVALUATE_MQH__
#define __MLQUANTAI_ROLLOUTSTAGE61CROSSINGEVALUATE_MQH__

#include "../Core/MLQuantAI_Enums.mqh"
#include "MLQuantAI_RolloutStageCrossValidity.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_RolloutStageObservationWindow.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_C62SessionEstablishment.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh"
#include "MLQuantAI_ExecutionAuditProjection.mqh"

// §1.2 - closed, per-pair, identity-checked whitelist. `true` for exactly
// ONE hard-coded pair in this revision. Deliberately NOT a generic
// `allowCrossEnvironment`-style flag/parameter anywhere - QA's explicit
// constraint (§1.2/§1.4.C). A future declared pair requires its OWN
// independently-frozen §6.x design contract and its OWN amendment to this
// function body - never inferred, never config-driven.
bool isDeclaredEnvironmentCrossingPair(ENUM_EXECUTION_ROLLOUT_STAGE fromStage, ENUM_EXECUTION_ROLLOUT_STAGE toStage)
{
   if(fromStage == ROLLOUT_STAGE_TEST_FIXTURE && toStage == ROLLOUT_STAGE_DEMO_DRY_RUN)
      return true;

   return false; // every other pair, including (DEMO_BOUNDED_AUTOMATION, LIVE_SHADOW) - §6.4 does not exist
}

enum ENUM_ROLLOUT_STAGE_61_CROSSING_REASON
{
   ROLLOUT_STAGE_61_CROSSING_NONE,
   ROLLOUT_STAGE_61_CROSSING_ALLOW,
   ROLLOUT_STAGE_61_CROSSING_WRONG_PAIR,                              // §1.3 items 1/2
   ROLLOUT_STAGE_61_CROSSING_ENVIRONMENT_NOT_DEMO,                    // §1.3 item 3
   ROLLOUT_STAGE_61_CROSSING_WINDOW_NOT_FOUND,                        // §2
   ROLLOUT_STAGE_61_CROSSING_SOURCE_STAGE_NOT_DURABLY_TESTER,         // §1.3 item 4
   ROLLOUT_STAGE_61_CROSSING_AUDIT_CHAIN_BROKEN,                      // fresh rebuild / P1 lineage
   ROLLOUT_STAGE_61_CROSSING_INSUFFICIENT_TESTER_COMPLETIONS, // §3/P1 (identifier shortened - MQL5 identifier length limit)
   ROLLOUT_STAGE_61_CROSSING_REPLAY_FAILED,                           // §3/P2
   ROLLOUT_STAGE_61_CROSSING_SAFE_MODE_ENGAGED_IN_WINDOW,             // §3/P2
   ROLLOUT_STAGE_61_CROSSING_TARGET_ENVIRONMENT_INVALID,              // §1.3 item 6 (defense-in-depth)
   ROLLOUT_STAGE_61_CROSSING_INTEGRITY_FATAL_HALT,                    // §6
   ROLLOUT_STAGE_61_CROSSING_EVIDENCE_SNAPSHOT_CHANGED                // §5
};

string RolloutStage61CrossingReasonToString(ENUM_ROLLOUT_STAGE_61_CROSSING_REASON r)
{
   switch(r)
   {
      case ROLLOUT_STAGE_61_CROSSING_ALLOW:                                return "allow";
      case ROLLOUT_STAGE_61_CROSSING_WRONG_PAIR:                            return "wrong_pair";
      case ROLLOUT_STAGE_61_CROSSING_ENVIRONMENT_NOT_DEMO:                  return "environment_not_demo";
      case ROLLOUT_STAGE_61_CROSSING_WINDOW_NOT_FOUND:                      return "window_not_found";
      case ROLLOUT_STAGE_61_CROSSING_SOURCE_STAGE_NOT_DURABLY_TESTER:       return "source_stage_not_durably_tester";
      case ROLLOUT_STAGE_61_CROSSING_AUDIT_CHAIN_BROKEN:                    return "audit_chain_broken";
      case ROLLOUT_STAGE_61_CROSSING_INSUFFICIENT_TESTER_COMPLETIONS: return "insufficient_tester_validated_completions";
      case ROLLOUT_STAGE_61_CROSSING_REPLAY_FAILED:                         return "replay_failed";
      case ROLLOUT_STAGE_61_CROSSING_SAFE_MODE_ENGAGED_IN_WINDOW:           return "safe_mode_engaged_in_window";
      case ROLLOUT_STAGE_61_CROSSING_TARGET_ENVIRONMENT_INVALID:            return "target_environment_invalid";
      case ROLLOUT_STAGE_61_CROSSING_INTEGRITY_FATAL_HALT:                  return "integrity_fatal_halt";
      case ROLLOUT_STAGE_61_CROSSING_EVIDENCE_SNAPSHOT_CHANGED:             return "evidence_snapshot_changed_during_evaluation";
   }
   return "none";
}

struct RolloutStage61CrossingResult
{
   bool                                   allow;
   ENUM_ROLLOUT_STAGE_61_CROSSING_REASON  reason;
   string                                  diagnostic; // free-text, operator-facing detail - never parsed, reason is the machine-readable field
};

void RolloutStage61CrossingResult_Init(RolloutStage61CrossingResult &r)
{
   r.allow      = false;
   r.reason     = ROLLOUT_STAGE_61_CROSSING_NONE;
   r.diagnostic = "";
}

//---------------------------------------------------------------------
// Small local helper - independently defined here (not shared with
// MLQuantAI_RolloutGateReadinessEvaluate.mqh's own copy), matching this
// checkpoint's established precedent that each evaluator's local helpers
// stay local. Maps a projection record's own source_log_event_id back to
// its position within a raw lines[] snapshot - a -1 result means the
// fresh rebuild and the original snapshot have diverged (the store grew
// between the caller's read and this evaluation), always treated as
// audit_chain_broken by every caller below.
//---------------------------------------------------------------------
int RolloutStage61_FindLineIndexByLogEventId(const string &lines[], string logEventId)
{
   for(int i = 0; i < ArraySize(lines); i++)
      if(EventSerializer_GetStr(lines[i], "log_event_id") == logEventId)
         return i;
   return -1;
}

// §5: byte-for-byte comparison of a fresh re-read against the original
// snapshot. Size checked FIRST (either direction), same pattern
// EvidenceSnapshot_Unchanged() in MLQuantAI_RolloutGateReadinessEvaluate.mqh
// already established for §6.2's own §2.1.
bool RolloutStage61_EvidenceSnapshotUnchanged(const string &original[], const string &fresh[])
{
   if(ArraySize(fresh) != ArraySize(original))
      return false;
   for(int i = 0; i < ArraySize(original); i++)
      if(fresh[i] != original[i])
         return false;
   return true;
}

//---------------------------------------------------------------------
// §3/P1 - Tester-validated pipeline throughput: >= 3 distinct
// EXECUTION_DRY_RUN_COMPLETED lines in-window, each with a distinct
// candidate_id, complete lineage back to a real in-window
// CANDIDATE_CREATED. EXECUTION_ENV_TESTER provenance is DERIVED from
// window membership itself (§3's frozen provenance clarification, Rev.4) -
// no new environment_mode field is read or proposed on the completion
// event.
//---------------------------------------------------------------------
RolloutStage61CrossingResult P1_VerifyTesterValidatedThroughput(const string &lines[], int windowStartIndex)
{
   RolloutStage61CrossingResult result;
   RolloutStage61CrossingResult_Init(result);

   string completedType = EventTypeToString(EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED);

   string distinctCandidateIds[];
   int m = 0;

   for(int i = windowStartIndex + 1; i < ArraySize(lines); i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != completedType) continue;

      string execRequestId = EventSerializer_GetStr(lines[i], "execution_request_id");

      ExecutionRequestProjectionRecord execReq;
      if(!ExecutionRequestProjection_TryGet(execRequestId, execReq))
      {
         result.reason     = ROLLOUT_STAGE_61_CROSSING_AUDIT_CHAIN_BROKEN;
         result.diagnostic = "P1: in-window EXECUTION_DRY_RUN_COMPLETED line's execution_request_id '" + execRequestId +
                              "' has no matching ExecutionRequestProjection record in the fresh rebuild";
         return result;
      }

      string candidateId = execReq.candidate_id;

      CandidateProjectionRecord candRec;
      if(!CandidateProjection_TryGet(candidateId, candRec))
      {
         result.reason     = ROLLOUT_STAGE_61_CROSSING_AUDIT_CHAIN_BROKEN;
         result.diagnostic = "P1: candidate '" + candidateId +
                              "' referenced by an in-window dry-run completion has no CandidateProjection record - no real CANDIDATE_CREATED lineage exists";
         return result;
      }

      int candLineIdx = RolloutStage61_FindLineIndexByLogEventId(lines, candRec.source_log_event_id);
      if(candLineIdx < 0)
      {
         result.reason     = ROLLOUT_STAGE_61_CROSSING_AUDIT_CHAIN_BROKEN;
         result.diagnostic = "P1: candidate '" + candidateId + "' CANDIDATE_CREATED log_event_id '" + candRec.source_log_event_id +
                              "' from the fresh rebuild has no matching line in the evidence snapshot";
         return result;
      }
      if(candLineIdx <= windowStartIndex)
         continue; // CANDIDATE_CREATED predates this observation window - lineage is not "also in-window" (§3/P1), does not count

      bool already = false;
      for(int k = 0; k < m; k++)
         if(distinctCandidateIds[k] == candidateId) { already = true; break; }
      if(already) continue;

      ArrayResize(distinctCandidateIds, m + 1);
      distinctCandidateIds[m] = candidateId;
      m++;
   }

   if(m < 3)
   {
      result.reason     = ROLLOUT_STAGE_61_CROSSING_INSUFFICIENT_TESTER_COMPLETIONS;
      result.diagnostic = StringFormat("P1: only %d distinct in-window, lineage-complete EXECUTION_DRY_RUN_COMPLETED candidate(s) found - >=3 required", m);
      return result;
   }

   return result; // reason stays NONE - P1 passed
}

//---------------------------------------------------------------------
// §3/P2 - durable-log health: fresh replay clean, no durable Safe Mode
// engagement ever in-window, no out-of-band quarantine witness present.
// No BrokerReconciliation_CheckAll()/post-side-effect re-read pairing is
// needed here (unlike §6.2's own P4a/P4c) - no broker-submission concept
// exists at this pre-submission stage (§2's frozen note), so nothing
// called by this predicate can itself trip Safe Mode.
//---------------------------------------------------------------------
RolloutStage61CrossingResult P2_VerifyDurableLogHealth(const string &lines[], int windowStartIndex)
{
   RolloutStage61CrossingResult result;
   RolloutStage61CrossingResult_Init(result);

   ReplayReport replayReport = ReplayEngine_Run(g_EventStore_FileName);
   if(!replayReport.ok)
   {
      result.reason     = ROLLOUT_STAGE_61_CROSSING_REPLAY_FAILED;
      result.diagnostic = "P2: ReplayEngine_Run failed against the currently-open store";
      return result;
   }

   bool safeModeEverEngaged;
   SafeModeProjection_ReplayEngagedDuringWindow(lines, windowStartIndex, safeModeEverEngaged);
   if(safeModeEverEngaged || SafeModeQuarantineWitness_Exists())
   {
      result.reason     = ROLLOUT_STAGE_61_CROSSING_SAFE_MODE_ENGAGED_IN_WINDOW;
      result.diagnostic = "P2: Safe Mode was engaged during the observation window and/or a quarantine witness file is present";
      return result;
   }

   return result; // reason stays NONE - P2 passed
}

//---------------------------------------------------------------------
// The main evaluator - §1.3's 6 preconditions, in this order:
//   1/2 (pair identity) -> 3 (fresh environment) -> §2 window lookup ->
//   4 (durable-TESTER integrity cross-check, same anchor line §2 found) ->
//   fresh rebuilds -> 5 (P1, P2) -> 6 (defense-in-depth target validity) ->
//   §6 (integrity-fatal-halt) -> §5 (final snapshot consistency) -> ALLOW.
// lines[] is the caller's own fresh read, taken immediately before
// calling this function - §5 below re-reads and compares against exactly
// this same array, byte for byte.
//---------------------------------------------------------------------
RolloutStage61CrossingResult RolloutStage61Crossing_Evaluate(ENUM_EXECUTION_ROLLOUT_STAGE fromStage, ENUM_EXECUTION_ROLLOUT_STAGE toStage,
                                                                const string &lines[], ENUM_EXECUTION_ENVIRONMENT_MODE environmentMode)
{
   RolloutStage61CrossingResult result;
   RolloutStage61CrossingResult_Init(result);

   // §1.3 items 1/2 - this predicate applies ONLY to this exact pair,
   // self-enforced (never merely trusting the caller's own
   // isDeclaredEnvironmentCrossingPair() gate that led here).
   if(fromStage != ROLLOUT_STAGE_TEST_FIXTURE || toStage != ROLLOUT_STAGE_DEMO_DRY_RUN)
   {
      result.reason     = ROLLOUT_STAGE_61_CROSSING_WRONG_PAIR;
      result.diagnostic = "§1.3 items 1/2: this predicate only evaluates (TEST_FIXTURE -> DEMO_DRY_RUN)";
      return result;
   }

   // §1.3 item 3 - the fresh environment_mode, replacing the blanket
   // check for this one declared pair.
   if(environmentMode != EXECUTION_ENV_DEMO)
   {
      result.reason     = ROLLOUT_STAGE_61_CROSSING_ENVIRONMENT_NOT_DEMO;
      result.diagnostic = "§1.3 item 3: fresh environment_mode is not EXECUTION_ENV_DEMO";
      return result;
   }

   // §2 - observation window, anchored to the LATEST
   // EXECUTION_ROLLOUT_STAGE_CHANGED(to_stage=TEST_FIXTURE) line. Not
   // found is a hard REJECT. The same anchor line is reused immediately
   // below for item 4's own integrity cross-check.
   int windowStartIndex;
   if(!RolloutStageObservationWindow_FindStart(lines, ROLLOUT_STAGE_TEST_FIXTURE, windowStartIndex))
   {
      result.reason     = ROLLOUT_STAGE_61_CROSSING_WINDOW_NOT_FOUND;
      result.diagnostic = "§2: no EXECUTION_ROLLOUT_STAGE_CHANGED(to_stage=TEST_FIXTURE) line found in the evidence snapshot";
      return result;
   }

   // §1.3 item 4 - the anchor line's OWN recorded environment_mode field
   // must literally equal "TESTER": the current stage was not merely
   // NAMED TEST_FIXTURE, it was verifiably, durably EARNED under TESTER.
   string anchorEnvironmentMode = EventSerializer_GetStr(lines[windowStartIndex], "environment_mode");
   if(anchorEnvironmentMode != ExecutionEnvironmentModeToString(EXECUTION_ENV_TESTER))
   {
      result.reason     = ROLLOUT_STAGE_61_CROSSING_SOURCE_STAGE_NOT_DURABLY_TESTER;
      result.diagnostic = "§1.3 item 4: the latest to_stage=TEST_FIXTURE line's own environment_mode field is '" +
                           anchorEnvironmentMode + "', not 'TESTER'";
      return result;
   }

   // Fresh rebuilds, both against the currently-open store file - a
   // failure in either leaves BOTH registries untouched (each rebuild's
   // own frozen fail-closed contract) and is reported identically here.
   CandidateProjectionReport candReport = CandidateProjection_RebuildFromFile(g_EventStore_FileName);
   if(!candReport.ok)
   {
      result.reason     = ROLLOUT_STAGE_61_CROSSING_AUDIT_CHAIN_BROKEN;
      result.diagnostic = "audit chain: CandidateProjection_RebuildFromFile failed - " + candReport.first_error;
      return result;
   }

   ExecutionAuditProjectionReport execReport = ExecutionAuditProjection_RebuildFromFile(g_EventStore_FileName);
   if(!execReport.ok)
   {
      result.reason     = ROLLOUT_STAGE_61_CROSSING_AUDIT_CHAIN_BROKEN;
      result.diagnostic = "audit chain: ExecutionAuditProjection_RebuildFromFile failed - " + execReport.first_error;
      return result;
   }

   // §1.3 item 5 / §3 - P1, P2.
   RolloutStage61CrossingResult p1 = P1_VerifyTesterValidatedThroughput(lines, windowStartIndex);
   if(p1.reason != ROLLOUT_STAGE_61_CROSSING_NONE)
      return p1;

   RolloutStage61CrossingResult p2 = P2_VerifyDurableLogHealth(lines, windowStartIndex);
   if(p2.reason != ROLLOUT_STAGE_61_CROSSING_NONE)
      return p2;

   // §1.3 item 6 - defense-in-depth. Structurally unreachable given the
   // frozen cross-validity table (DEMO_DRY_RUN is valid under exactly
   // EXECUTION_ENV_DEMO, which item 3 above already confirmed), but
   // checked anyway - never relying solely on one layer's guarantee, this
   // checkpoint's own established style (§6.2's §2.2 alongside
   // ExpertRemove() itself).
   if(!RolloutStage_IsValidForEnvironment(ROLLOUT_STAGE_DEMO_DRY_RUN, EXECUTION_ENV_DEMO))
   {
      result.reason     = ROLLOUT_STAGE_61_CROSSING_TARGET_ENVIRONMENT_INVALID;
      result.diagnostic = "§1.3 item 6: RolloutStage_IsValidForEnvironment(DEMO_DRY_RUN, EXECUTION_ENV_DEMO) unexpectedly returned false";
      return result;
   }

   // §6 - independent integrity-fatal-halt gate, immediately before §5's
   // own final check.
   if(g_RolloutIntegrityFatalHalt)
   {
      result.reason     = ROLLOUT_STAGE_61_CROSSING_INTEGRITY_FATAL_HALT;
      result.diagnostic = "§6: g_RolloutIntegrityFatalHalt is true - a prior double I/O failure already halted evidence integrity for this session";
      return result;
   }

   // §5 - final evidence snapshot consistency gate. Fresh re-read,
   // compared byte-for-byte against the ORIGINAL lines[] this function
   // was called with.
   string finalLines[];
   EventStore_ReadAllLines(g_EventStore_FileName, finalLines);
   if(!RolloutStage61_EvidenceSnapshotUnchanged(lines, finalLines))
   {
      result.reason     = ROLLOUT_STAGE_61_CROSSING_EVIDENCE_SNAPSHOT_CHANGED;
      result.diagnostic = "§5: the evidence snapshot changed during evaluation - re-evaluate against a fresh read";
      return result;
   }

   result.allow      = true;
   result.reason     = ROLLOUT_STAGE_61_CROSSING_ALLOW;
   result.diagnostic = "§6.1 crossing predicate: all frozen preconditions satisfied";
   return result;
}

#endif // __MLQUANTAI_ROLLOUTSTAGE61CROSSINGEVALUATE_MQH__
