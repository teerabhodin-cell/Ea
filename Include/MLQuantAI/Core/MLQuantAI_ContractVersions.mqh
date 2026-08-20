//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_ContractVersions.mqh                  |
//| Phase B contract registry, separate from Phase A's                |
//| MLQuantAI_VersionRegistry.mqh (which MLQuantAI.mq5 / SYSTEM_STARTED|
//| already depends on and stays untouched). Version stamps for every |
//| struct frozen across Phase B's steps: B1 froze MarketContext/     |
//| NewsSnapshot/TradeCandidate/RiskDecision; B2 adds SymbolSpec's     |
//| resolved-symbol contract. Same rule as VersionRegistry: changing  |
//| a schema's meaning means adding a new _V2 constant, never          |
//| redefining what an existing _V1 means.                             |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CONTRACTVERSIONS_MQH__
#define __MLQUANTAI_CONTRACTVERSIONS_MQH__

#define MLQUANTAI_MARKET_CONTEXT_SCHEMA_V1 "MARKET_CONTEXT_V1"
#define MLQUANTAI_FEATURE_SCHEMA_V1        "FEATURES_V1"
#define MLQUANTAI_CANDIDATE_SCHEMA_V1      "CANDIDATE_V1"
#define MLQUANTAI_NEWS_SCHEMA_V1           "NEWS_V1"
#define MLQUANTAI_RISK_SCHEMA_V1           "RISK_V1"

// B2: Symbol Resolution
#define MLQUANTAI_SYMBOL_SPEC_SCHEMA_V1    "SYMBOL_SPEC_V1"

// B5: CRT_V1 detector rules version (candidate_id's strategyVersion
// argument, see Docs/PhaseB_B5_CRTContract.md section 6) - distinct from
// MLQUANTAI_CANDIDATE_SCHEMA_V1 (the TradeCandidate struct shape) the
// same way TradeCandidate.regime_rules_version is distinct from
// candidate_schema_version. Bump to a new _V2 string, never redefine
// _V1 in place, if any of the frozen CRT_V1 parameters in
// Strategies/MLQuantAI_CRT_V1_Contract.mqh ever change.
#define MLQUANTAI_CRT_V1_RULES_VERSION     "CRT_V1"

// B7: RiskContext/RiskPlan additive schema stamps - distinct from
// MLQUANTAI_RISK_SCHEMA_V1 (Phase A's original RiskPlan shape, kept
// unchanged), the same way MLQUANTAI_CANDIDATE_SCHEMA_V1 is distinct
// from MLQUANTAI_CRT_V1_RULES_VERSION. See
// Docs/PhaseB_B7_RiskPlanContract.md.
#define MLQUANTAI_RISK_CONTEXT_SCHEMA_V1   "RISK_CONTEXT_V1"
#define MLQUANTAI_RISK_PLAN_SCHEMA_V1      "RISK_PLAN_V1"
#define MLQUANTAI_RISK_SIZING_RULES_V1     "FIXED_PERCENT_RISK_V1"

// B8.1: the canonical AI feature-vector contract version - distinct
// from MLQUANTAI_FEATURE_SCHEMA_V1 (Phase B1's dormant, unwired stub
// default), the same way MLQUANTAI_RISK_PLAN_SCHEMA_V1 is distinct
// from Phase A's MLQUANTAI_RISK_SCHEMA_V1. FeatureSnapshot_Init()
// still stamps MLQUANTAI_FEATURE_SCHEMA_V1 (unchanged, keeps
// Test_PhaseBContracts.mq5's sealed assertion true);
// Candidate_ToFeatureSnapshot() overwrites it with this constant on a
// successful build. See Docs/PhaseB_B8_1_FeatureSnapshotContract.md.
#define MLQUANTAI_FEATURE_SCHEMA_B8_1_V1   "FEATURES_B8_1_V1"

// B8.2: the training-dataset row/manifest contract, its label-schema
// version, and its split policy - all distinct from any Phase A
// placeholder (MLQUANTAI_LABEL_SCHEMA_VERSION = "TBM_V1" in
// VersionRegistry.mqh is never wired to a real struct; B8.2 mints its
// own rather than reuse it, same precedent MLQUANTAI_FEATURE_SCHEMA_B8_1_V1
// already set). See Docs/PhaseB_B8_2_TrainingDatasetContract.md.
#define MLQUANTAI_DATASET_SCHEMA_B8_2_V1   "TRAINING_DATASET_B8_2_V1"
#define MLQUANTAI_LABEL_SCHEMA_B8_2_V1     "LABEL_B8_2_V1"
#define MLQUANTAI_DATASET_SPLIT_POLICY_V1  "SPLIT_70_15_15_V1"

// B8.2 Commit 3: RealizedOutcome's own schema stamp - distinct from
// MLQUANTAI_LABEL_SCHEMA_B8_2_V1 (TrainingDatasetRow's label-schema
// field, which RealizedOutcome_Build requires every RealizedOutcome's
// own label_schema_version to equal - see
// Docs/PhaseB_B8_2_Commit3_OutcomeLabelContract.md scope decision 5).
// This constant versions RealizedOutcome's own record SHAPE, the same
// role MLQUANTAI_RISK_PLAN_SCHEMA_V1/MLQUANTAI_DATASET_SCHEMA_B8_2_V1
// already play for their own structs.
#define MLQUANTAI_REALIZED_OUTCOME_SCHEMA_B8_2_V1 "REALIZED_OUTCOME_B8_2_V1"

// B8.3: ModelArtifact's own record-shape stamp. Unlike every prior
// schema-version constant, this one is DELIBERATELY included in its
// own struct's content hash (model_registry_hash) rather than
// excluded - see Docs/PhaseB_B8_3_ModelRegistryContract.md's "two
// hashes" section for the reasoning.
#define MLQUANTAI_MODEL_REGISTRY_SCHEMA_B8_3_V1 "MODEL_REGISTRY_B8_3_V1"

// B8.4 Commit 1: InferenceRequest's own shape stamp, and
// InferenceResult's own contract-version stamp (the request->result
// mapping this commit's orchestration implements). See
// Docs/PhaseB_B8_4_InferenceContract.md.
#define MLQUANTAI_INFERENCE_REQUEST_SCHEMA_B8_4_V1 "INFERENCE_REQUEST_B8_4_V1"
#define MLQUANTAI_INFERENCE_CONTRACT_B8_4_V1       "INFERENCE_CONTRACT_B8_4_V1"

// B8.4 Commit 1: the canonical input length for FEATURES_B8_1_V1's
// 12-field vector, and the one output schema this commit freezes as a
// concrete proof of the output-validation shape.
#define MLQUANTAI_INFERENCE_INPUT_LENGTH_B8_1_V1 12
#define MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1     "OUTPUT_P_SUCCESS_V1"

// B8.4 Commit 2 (Tier B): the exact ONNX tensor contract every
// PROMOTED artifact's model file must expose, for the one frozen
// INPUT_SCHEMA_V1/OUTPUT_P_SUCCESS_V1 pairing this phase supports.
// ModelArtifact carries no literal tensor name/shape/dtype fields
// (input_schema_version/output_schema_version are version identifiers,
// not shape declarations) - these are the fixed values that version
// identifier maps to, frozen here rather than duplicated per-artifact.
// A future input/output schema version would freeze its own constants
// alongside these, never redefine them.
#define MLQUANTAI_ONNX_INPUT_TENSOR_NAME  "input"
#define MLQUANTAI_ONNX_OUTPUT_TENSOR_NAME "output"
#define MLQUANTAI_ONNX_BATCH_SIZE 1 // dimension 0 of both input and output tensors

// B8.5: AIDecision's own record-shape stamp - distinct from
// MLQUANTAI_INFERENCE_CONTRACT_B8_4_V1 (InferenceResult's shape, which
// AIDecision consumes but does not restamp). See
// Docs/PhaseB_B8_5_AIDecisionContract.md.
#define MLQUANTAI_AI_DECISION_SCHEMA_B8_5_V1 "AI_DECISION_B8_5_V1"

// B9: EligibilityContext's and EligibilityDecision's own record-shape
// stamps. See Docs/PhaseB_B9_ExecutionEligibilityContract.md.
#define MLQUANTAI_ELIGIBILITY_CONTEXT_SCHEMA_B9_V1  "ELIGIBILITY_CONTEXT_B9_V1"
#define MLQUANTAI_ELIGIBILITY_DECISION_SCHEMA_B9_V1 "ELIGIBILITY_DECISION_B9_V1"

#endif // __MLQUANTAI_CONTRACTVERSIONS_MQH__
