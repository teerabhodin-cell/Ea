//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_RealizedOutcomeCommandHandler.mqh |
//| RA-62 Slice 2 (QA-frozen): the pure orchestration logic behind the |
//| RECORD_REALIZED_OUTCOME ceremony command. Extracted into its own    |
//| includable file - same "keep the .mq5 wrapper thin, put the real    |
//| decision logic in a testable .mqh" pattern this project already     |
//| established (BrokerSubmission_SelectFillingMode, EnvironmentLock_   |
//| TradeModePermitsNewPosition, etc.) - so this exact function is       |
//| directly unit-testable with fabricated CandidateProjection/          |
//| RealizedOutcomeProjection registry state, without needing a real     |
//| ceremony command/mailbox/EA restart.                                 |
//|                                                                       |
//| Calls ONLY already-sealed, UNCHANGED functions:                       |
//| CandidateProjection_TryGet, RealizedOutcomeBuilder_ValidateInput,      |
//| RealizedOutcome_Build, RealizedOutcomeProjection_TryGet,               |
//| RealizedOutcome_EmitTradeOutcomeLabeled - QA's explicit "must not       |
//| modify RealizedOutcome_Build()/RealizedOutcome_EmitTradeOutcomeLabeled()|
//| " boundary. No OrderSend/CTrade/broker call anywhere, no execution      |
//| authority added.                                                        |
//|                                                                          |
//| Idempotency: pre-checks RealizedOutcomeProjection_TryGet() using the     |
//| SAME public lookup the sealed emitter itself uses internally, so         |
//| "already recorded" (idempotent no-op, success-like) is distinguishable   |
//| from "candidate not found"/"validation failed" (this call's input was    |
//| invalid) and from "emit failed" (the durable write itself broke,          |
//| fail-closed) - three genuinely different outcome classes, never            |
//| collapsed into one bool.                                                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_REALIZEDOUTCOMECOMMANDHANDLER_MQH__
#define __MLQUANTAI_REALIZEDOUTCOMECOMMANDHANDLER_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_RealizedOutcomeEventEmission.mqh"
#include "../AI/MLQuantAI_RealizedOutcomeBuilder.mqh"

enum ENUM_RECORD_OUTCOME_RESULT
{
   RECORD_OUTCOME_RESULT_NONE,
   RECORD_OUTCOME_RESULT_RECORDED,           // fresh, first-time durable write succeeded this call
   RECORD_OUTCOME_RESULT_ALREADY_RECORDED,   // idempotent no-op - a RealizedOutcome already existed for this identity
   RECORD_OUTCOME_RESULT_CANDIDATE_NOT_FOUND,
   RECORD_OUTCOME_RESULT_VALIDATION_FAILED,  // RealizedOutcomeBuilder_ValidateInput (sealed, unchanged) rejected the input
   RECORD_OUTCOME_RESULT_EMIT_FAILED         // genuine durable-write failure - EventStore_LogSystem's own SafeMode_Trip already fired
};

string RecordOutcomeResultToString(ENUM_RECORD_OUTCOME_RESULT r)
{
   switch(r)
   {
      case RECORD_OUTCOME_RESULT_RECORDED:            return "recorded";
      case RECORD_OUTCOME_RESULT_ALREADY_RECORDED:     return "already_recorded";
      case RECORD_OUTCOME_RESULT_CANDIDATE_NOT_FOUND:  return "candidate_not_found";
      case RECORD_OUTCOME_RESULT_VALIDATION_FAILED:    return "validation_failed";
      case RECORD_OUTCOME_RESULT_EMIT_FAILED:          return "emit_durable_write_failed";
   }
   return "none";
}

struct RecordOutcomeCommandResult
{
   ENUM_RECORD_OUTCOME_RESULT status;
   string reason_detail;        // validation failure reason (from RealizedOutcomeBuilder_ValidateInput), else ""
   string realized_outcome_id;  // populated on RECORDED/ALREADY_RECORDED only
};

void RecordOutcomeCommandResult_Init(RecordOutcomeCommandResult &r)
{
   r.status = RECORD_OUTCOME_RESULT_NONE;
   r.reason_detail = "";
   r.realized_outcome_id = "";
}

// The entry point. Never mutates candidateId/label/outcomeReference/
// outcomeHash/outcomeTime - all four outcome-content values (label,
// outcomeReference, outcomeHash, outcomeTime) are passed through
// verbatim to RealizedOutcome_Build() exactly as supplied by the
// caller (per QA's frozen requirement: outcome_hash is external
// evidence, "supplied, not computed here" - this function never
// regenerates or replaces it). label_schema_version is always the
// sealed MLQUANTAI_LABEL_SCHEMA_B8_2_V1 - not a caller-supplied
// parameter, same reasoning RealizedOutcomeBuilder_ValidateInput's own
// scope-decision-5 comment already gives for that field.
void RecordRealizedOutcomeCommand_Process(string candidateId, string label, string outcomeReference,
                                            string outcomeHash, datetime outcomeTime,
                                            RecordOutcomeCommandResult &outResult)
{
   RecordOutcomeCommandResult_Init(outResult);

   CandidateProjectionRecord candRec;
   if(!CandidateProjection_TryGet(candidateId, candRec))
   {
      outResult.status = RECORD_OUTCOME_RESULT_CANDIDATE_NOT_FOUND;
      return;
   }

   // Minimal, correct-enough TradeCandidate reconstruction - the only
   // fields RealizedOutcomeBuilder_ValidateInput/RealizedOutcome_Build
   // actually read (candidate_id, candidate_hash, state,
   // setup_anchor_bar_time), verified against their own real source.
   // .state is always CANDIDATE_CREATED in CandidateProjectionRecord
   // (a B6-only projection - same fact SubmitOrderCommand's own
   // reconstruction comment already documents), matching exactly what
   // RealizedOutcomeBuilder_ValidateInput requires.
   TradeCandidate candidate;
   TradeCandidate_Init(candidate);
   candidate.candidate_id          = candRec.candidate_id;
   candidate.candidate_hash        = candRec.candidate_hash;
   candidate.state                 = candRec.state;
   candidate.setup_anchor_bar_time = candRec.setup_anchor_bar_time;

   string validationReason = RealizedOutcomeBuilder_ValidateInput(candidate, label, outcomeReference, outcomeHash,
                                                                     outcomeTime, MLQUANTAI_LABEL_SCHEMA_B8_2_V1);
   if(validationReason != "")
   {
      outResult.status = RECORD_OUTCOME_RESULT_VALIDATION_FAILED;
      outResult.reason_detail = validationReason;
      return;
   }

   RealizedOutcome outcome;
   if(!RealizedOutcome_Build(candidate, label, outcomeReference, outcomeHash, outcomeTime,
                               MLQUANTAI_LABEL_SCHEMA_B8_2_V1, outcome))
   {
      // Structurally unreachable given the identical validation already
      // passed above - never assumed impossible, fail closed rather than
      // silently proceed with a partially-built outcome.
      outResult.status = RECORD_OUTCOME_RESULT_VALIDATION_FAILED;
      outResult.reason_detail = "RealizedOutcome_Build failed after its own validation already passed - structural inconsistency";
      return;
   }
   outResult.realized_outcome_id = outcome.realized_outcome_id;

   // Idempotency pre-check, using the SAME public lookup
   // RealizedOutcome_EmitTradeOutcomeLabeled already uses internally -
   // never a re-implementation of its own guard, only checked first here
   // so ALREADY_RECORDED (success-like) is distinguishable from
   // EMIT_FAILED (the durable write itself broke).
   RealizedOutcomeProjectionRecord existing;
   if(RealizedOutcomeProjection_TryGet(outcome.realized_outcome_id, existing))
   {
      outResult.status = RECORD_OUTCOME_RESULT_ALREADY_RECORDED;
      return;
   }

   if(!RealizedOutcome_EmitTradeOutcomeLabeled(outcome))
   {
      outResult.status = RECORD_OUTCOME_RESULT_EMIT_FAILED;
      return;
   }

   outResult.status = RECORD_OUTCOME_RESULT_RECORDED;
}

#endif // __MLQUANTAI_REALIZEDOUTCOMECOMMANDHANDLER_MQH__
