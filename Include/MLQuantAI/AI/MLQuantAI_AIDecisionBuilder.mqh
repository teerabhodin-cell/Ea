//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_AIDecisionBuilder.mqh                    |
//| Phase B8.5 Commit 1: AIDecision_Build() - pure mapping from a       |
//| validated InferenceResult + the FeatureSnapshot it was built from  |
//| + an explicit, versioned AIDecisionPolicy, to an AIDecision. Per   |
//| Docs/PhaseB_B8_5_AIDecisionContract.md. No ONNX/runtime call, no    |
//| event emission, no mutation of any input, no execution authority.   |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_AIDECISIONBUILDER_MQH__
#define __MLQUANTAI_AIDECISIONBUILDER_MQH__

#include "MLQuantAI_AIDecisionContract.mqh"
#include "MLQuantAI_InferenceContract.mqh"
#include "../Market/MLQuantAI_FeatureSnapshot.mqh"

// Fail-closed ladder (mirrors ModelInference_ResolveAndPrepare's own
// style): policy shape -> threshold range -> referential match between
// inference and snapshot -> defensive p_success re-check -> decide.
// On any failure, outDecision is left at AIDecision_Init() defaults -
// no partial record, and the caller must not treat that as ABSTAIN
// (ABSTAIN is reserved for an explicit policy condition, never an
// error/fail-closed path - see the frozen contract).
bool AIDecision_Build(const InferenceResult &inference, const FeatureSnapshot &snapshot,
                        const AIDecisionPolicy &policy, AIDecision &outDecision, string &outReasonDetail)
{
   AIDecision_Init(outDecision);
   outReasonDetail = "";

   if(policy.decision_policy_version == "" || policy.threshold_version == "")
   {
      outReasonDetail = "AIDecisionPolicy has an empty decision_policy_version or threshold_version";
      return false;
   }

   if(!MathIsValidNumber(policy.allow_threshold) || policy.allow_threshold < 0.0 || policy.allow_threshold > 1.0)
   {
      outReasonDetail = "AIDecisionPolicy.allow_threshold is not finite or not in [0,1]";
      return false;
   }

   if(inference.feature_snapshot_id != snapshot.feature_snapshot_id ||
      inference.feature_snapshot_hash != snapshot.feature_snapshot_hash ||
      inference.feature_vector_hash != snapshot.feature_vector_hash)
   {
      outReasonDetail = "the supplied FeatureSnapshot does not match the identity/hash the InferenceResult carries";
      return false;
   }

   if(ArraySize(inference.output_values) != 1)
   {
      outReasonDetail = "InferenceResult.output_values does not have exactly 1 element";
      return false;
   }

   double pSuccess = (double)inference.output_values[0];
   if(!MathIsValidNumber(pSuccess) || pSuccess < 0.0 || pSuccess > 1.0)
   {
      outReasonDetail = "InferenceResult.output_values[0] is not finite or not in [0,1]";
      return false;
   }

   outDecision.candidate_id   = snapshot.candidate_id;
   outDecision.candidate_hash = snapshot.candidate_hash;

   outDecision.feature_snapshot_id   = inference.feature_snapshot_id;
   outDecision.feature_snapshot_hash = inference.feature_snapshot_hash;
   outDecision.feature_vector_hash   = inference.feature_vector_hash;

   outDecision.model_registry_id   = inference.model_registry_id;
   outDecision.model_registry_hash = inference.model_registry_hash;
   outDecision.model_artifact_hash = inference.model_artifact_hash;

   outDecision.inference_output_hash      = inference.output_hash;
   outDecision.output_schema_version      = inference.output_schema_version;
   outDecision.inference_contract_version = inference.inference_contract_version;

   outDecision.decision_policy_version = policy.decision_policy_version;
   outDecision.threshold_version       = policy.threshold_version;
   outDecision.allow_threshold         = policy.allow_threshold;

   outDecision.p_success = pSuccess;

   if(pSuccess >= policy.allow_threshold)
   {
      outDecision.decision_outcome     = AI_DECISION_OUTCOME_ALLOW;
      outDecision.decision_reason_code = REASON_NONE;
   }
   else
   {
      outDecision.decision_outcome     = AI_DECISION_OUTCOME_REJECT;
      outDecision.decision_reason_code = REASON_AI_REJECT;
   }

   outDecision.ai_decision_id = Ids_AIDecisionId(outDecision.candidate_id, outDecision.model_registry_id,
                                                   outDecision.decision_policy_version);
   outDecision.ai_decision_hash = AIDecision_ComputeHash(outDecision);

   return true;
}

#endif // __MLQUANTAI_AIDECISIONBUILDER_MQH__
