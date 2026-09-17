//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/                             |
//| MLQuantAI_CandidateTerminalTransitionLocator.mqh                    |
//| §6.2 Evidence-Gate Design Contract Rev.8 (QA-frozen DESIGN FREEZE,   |
//| Docs/PhaseC_C5_2_Section6_2_EvidenceGateDesignContract.md §2/P3):      |
//| re-scans lines[] directly for the specific lifecycle-event line that   |
//| performed one candidate's transition into a terminal                    |
//| ENUM_CANDIDATE_STATE, and returns THAT line's own ARRAY INDEX within       |
//| lines[] - never inferred from a projection's rolled-up current state (a    |
//| projection has no positional memory of which line caused it).                |
//|                                                                                 |
//| Deliberately the array INDEX, not the JSON "seq" field: "seq" is only          |
//| unique WITHIN one runtime_session_id (EventStore.mqh resets its sequence        |
//| counter to 1 on every EventStore_Open) - across a multi-session file it          |
//| is not a safe basis for a window-membership comparison against another            |
//| line's own index. The array index, for one EventStore_ReadAllLines()               |
//| snapshot read in file order, is a strictly monotonic position equivalent             |
//| to chronological order - exactly what §6.2's window-membership checks                  |
//| actually need, and consistent with how every other predicate in this                     |
//| checkpoint (P1/P2, §1's own window boundary) already compares position.                    |
//|                                                                                   |
//| Frozen tri-state semantics (§2/P3): under correct operation a terminal            |
//| state is entered at most once per candidate_id (StateMachine_IsTerminal            |
//| states have no outgoing transitions at all - MLQuantAI_StateMachine.mqh,           |
//| unmodified, Class 1). 0 matches is an internal inconsistency (the               |
//| projection says terminal but no causing line can be found); >1 matches           |
//| is a durable-log anomaly (duplicate emission/idempotency defect) - never        |
//| resolved by picking either the first or the latest match.                        |
//|                                                                                   |
//| Independent of, and without modifying, MLQuantAI_CandidateProjection.mqh          |
//| (Class 1, untouched - that file's own CandidateProjectionRecord.state is           |
//| always CANDIDATE_CREATED, a B6.1-only "candidate content" projection, never         |
//| a terminal-state source) or MLQuantAI_StateProjector.mqh (Class 1,                   |
//| untouched - its g_Proj_Candidates[] IS the correct current-state source for          |
//| "is this candidate_id terminal", but carries no per-line sequence-number             |
//| provenance either, which is exactly the gap this file closes).                        |
//|                                                                                          |
//| Pure: no EventStore read/write, no live MT5 API, no Safe Mode, no OrderSend,             |
//| no candidate-lifecycle authority.                                                          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CANDIDATETERMINALTRANSITIONLOCATOR_MQH__
#define __MLQUANTAI_CANDIDATETERMINALTRANSITIONLOCATOR_MQH__

#include "../../Core/MLQuantAI_StateMachine.mqh"
#include "MLQuantAI_EventSerializer.mqh"

enum ENUM_TERMINAL_TRANSITION_LOCATE_RESULT
{
   TERMINAL_TRANSITION_FOUND_ONE,      // exactly one match - accept
   TERMINAL_TRANSITION_NOT_LOCATED,    // zero matches
   TERMINAL_TRANSITION_AMBIGUOUS        // more than one match
};

// Scans lines[] for every lifecycle-event line (structurally identified by
// carrying both a "candidate_id" and a "to_state" key, same discriminator
// EventSerializer_ParseLifecycle itself requires) whose candidate_id
// matches and whose to_state is terminal (StateMachine_IsTerminal). Returns
// the tri-state result; outLineIndex is populated ONLY when the result is
// TERMINAL_TRANSITION_FOUND_ONE.
//
// Named _FindLineIndex, deliberately NOT _FindSequenceNumber (an earlier
// name this function briefly carried, before the seq-vs-index correction
// documented in this file's own header): outLineIndex is an ARRAY INDEX
// into this specific lines[] snapshot, never a durable sequence_number.
// Renaming closes the last residual naming artifact from that correction -
// QA's own semantic-integrity review (Diff Review round on
// MLQuantAI_RolloutGateReadinessEvaluate.mqh's P3) flagged that a function
// whose name says "SequenceNumber" while its out-parameter is an index
// risks exactly the identity conflation §2/P3 must never produce. No
// caller ever stored this value into any field named/typed as a durable
// sequence_number - this is a pure identifier fix, zero logic change.
ENUM_TERMINAL_TRANSITION_LOCATE_RESULT CandidateTerminalTransition_FindLineIndex(const string &lines[], string candidateId, int &outLineIndex)
{
   outLineIndex = -1;
   int matchCount = 0;
   int matchedIndex = -1;

   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(!EventSerializer_HasKey(lines[i], "candidate_id")) continue;
      if(!EventSerializer_HasKey(lines[i], "to_state")) continue;
      if(EventSerializer_GetStr(lines[i], "candidate_id") != candidateId) continue;

      ENUM_CANDIDATE_STATE toState = CandidateStateFromString(EventSerializer_GetStr(lines[i], "to_state"));
      if(!StateMachine_IsTerminal(toState)) continue;

      matchCount++;
      matchedIndex = i;
   }

   if(matchCount == 0)
      return TERMINAL_TRANSITION_NOT_LOCATED;
   if(matchCount > 1)
      return TERMINAL_TRANSITION_AMBIGUOUS;

   outLineIndex = matchedIndex;
   return TERMINAL_TRANSITION_FOUND_ONE;
}

#endif // __MLQUANTAI_CANDIDATETERMINALTRANSITIONLOCATOR_MQH__
