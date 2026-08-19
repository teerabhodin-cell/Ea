//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_AIDecisionContract.mqh                   |
//| Phase B8.5 Commit 1: AIDecisionPolicy (the explicit, versioned      |
//| threshold input) and AIDecision (the frozen output record), per    |
//| Docs/PhaseB_B8_5_AIDecisionContract.md. Every lineage/hash field on |
//| AIDecision is copied verbatim from InferenceResult/FeatureSnapshot -|
//| nothing here recomputes an upstream hash.                          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_AIDECISIONCONTRACT_MQH__
#define __MLQUANTAI_AIDECISIONCONTRACT_MQH__

#include "../Core/MLQuantAI_CanonicalFormat.mqh"
#include "../Core/MLQuantAI_ContractVersions.mqh"
#include "../Core/MLQuantAI_Ids.mqh"
#include "../Core/MLQuantAI_Enums.mqh"
#include "../Core/MLQuantAI_ReasonCodes.mqh"

// The explicit, versioned policy input AIDecision_Build requires - no
// implicit default anywhere. decision_policy_version/threshold_version
// are mandatory non-empty strings; allow_threshold must be finite and
// in [0,1] (both checked by AIDecision_Build, not here).
struct AIDecisionPolicy
{
   string decision_policy_version;
   string threshold_version;
   double allow_threshold;
};

void AIDecisionPolicy_Init(AIDecisionPolicy &p)
{
   p.decision_policy_version = "";
   p.threshold_version = "";
   p.allow_threshold = 0.0;
}

struct AIDecision
{
   string ai_decision_schema_version; // MLQUANTAI_AI_DECISION_SCHEMA_B8_5_V1

   string ai_decision_id;   // identity - Ids_AIDecisionId(candidate_id, model_registry_id, decision_policy_version)
   string ai_decision_hash; // content integrity - see AIDecision_ComputeHash

   string candidate_id;     // copied verbatim from the verified FeatureSnapshot
   string candidate_hash;   // copied verbatim from the verified FeatureSnapshot

   string feature_snapshot_id;   // copied verbatim from InferenceResult (cross-checked against snapshot)
   string feature_snapshot_hash; // copied verbatim from InferenceResult (cross-checked against snapshot)
   string feature_vector_hash;   // copied verbatim from InferenceResult (cross-checked against snapshot)

   string model_registry_id;   // copied verbatim from InferenceResult
   string model_registry_hash; // copied verbatim from InferenceResult
   string model_artifact_hash; // copied verbatim from InferenceResult

   string inference_output_hash;      // copied verbatim from InferenceResult.output_hash
   string output_schema_version;      // copied verbatim from InferenceResult
   string inference_contract_version; // copied verbatim from InferenceResult

   string decision_policy_version; // from the supplied AIDecisionPolicy
   string threshold_version;       // from the supplied AIDecisionPolicy
   double allow_threshold;         // from the supplied AIDecisionPolicy - the actual numeric value used, for audit without a policy-registry lookup

   double p_success; // copied verbatim from InferenceResult.output_values[0] - never recomputed

   ENUM_AI_DECISION_OUTCOME decision_outcome;
   ENUM_REASON_CODE         decision_reason_code;
};

void AIDecision_Init(AIDecision &d)
{
   d.ai_decision_schema_version = MLQUANTAI_AI_DECISION_SCHEMA_B8_5_V1;

   d.ai_decision_id = "";
   d.ai_decision_hash = "";

   d.candidate_id = "";
   d.candidate_hash = "";

   d.feature_snapshot_id = "";
   d.feature_snapshot_hash = "";
   d.feature_vector_hash = "";

   d.model_registry_id = "";
   d.model_registry_hash = "";
   d.model_artifact_hash = "";

   d.inference_output_hash = "";
   d.output_schema_version = "";
   d.inference_contract_version = "";

   d.decision_policy_version = "";
   d.threshold_version = "";
   d.allow_threshold = 0.0;

   d.p_success = 0.0;

   d.decision_outcome = AI_DECISION_OUTCOME_NONE;
   d.decision_reason_code = REASON_NONE;
}

// Excludes ai_decision_id (identity, not content) and
// ai_decision_schema_version (the struct's own top-level schema stamp -
// follows the RiskPlan/TrainingDatasetRow default, not ModelArtifact's
// deliberate departure; see Docs/PhaseB_B8_5_AIDecisionContract.md's
// "Identity and hash" section for the reasoning).
string AIDecision_HashPayload(const AIDecision &d)
{
   return d.candidate_id + "|" +
          d.candidate_hash + "|" +
          d.feature_snapshot_id + "|" +
          d.feature_snapshot_hash + "|" +
          d.feature_vector_hash + "|" +
          d.model_registry_id + "|" +
          d.model_registry_hash + "|" +
          d.model_artifact_hash + "|" +
          d.inference_output_hash + "|" +
          d.output_schema_version + "|" +
          d.inference_contract_version + "|" +
          d.decision_policy_version + "|" +
          d.threshold_version + "|" +
          CanonicalDouble(d.allow_threshold) + "|" +
          CanonicalDouble(d.p_success) + "|" +
          AiDecisionOutcomeToString(d.decision_outcome) + "|" +
          ReasonCodeToString(d.decision_reason_code);
}

string AIDecision_ComputeHash(const AIDecision &d)
{
   return Ids_Sha256Hex(AIDecision_HashPayload(d));
}

#endif // __MLQUANTAI_AIDECISIONCONTRACT_MQH__
