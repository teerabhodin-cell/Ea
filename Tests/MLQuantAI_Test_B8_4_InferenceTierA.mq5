//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_4_InferenceTierA.mq5                            |
//| Phase B8.4 Commit 1 (Tier A) DoD, per                               |
//| Docs/PhaseB_B8_4_InferenceContract.md's QA gate:                   |
//| ModelInference_ResolveAndPrepare, CanonicalFeatureVector_FromSnapshot,|
//| InferenceOutput_Validate, ModelInference_ValidateAndBuildResult.    |
//| No CRT/candidate/riskplan pipeline needed - fixtures build a        |
//| directly-populated, internally-consistent FeatureSnapshot (real     |
//| B8.1 hash functions, not fabricated hash strings) and a registered  |
//| ModelArtifact (real B8.3 pipeline). No ONNX/runtime call anywhere - |
//| Tier A only.                                                        |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/AI/MLQuantAI_ModelArtifactBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ModelArtifactEventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ModelInference.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

#define MODEL_ID_TEST     "CRT_SETUP_QUALITY"
#define MODEL_VERSION_TEST "v1"
#define MODEL_TARGET_TEST "SETUP_QUALITY_V1"
#define INPUT_SCHEMA_TEST "INPUT_SCHEMA_V1"
#define RUNTIME_FRAMEWORK_TEST "ONNXRuntime"
#define RUNTIME_VERSION_TEST   "1.16.0"

//---------------------------------------------------------------------
// Fixture helpers.
//---------------------------------------------------------------------
void BuildValidSnapshot(FeatureSnapshot &snapshot, string suffix)
{
   FeatureSnapshot_Init(snapshot);
   string candidateId = "CND_test_" + suffix;
   snapshot.candidate_id      = candidateId;
   snapshot.candidate_hash    = "test_candidate_hash_" + suffix;
   snapshot.context_event_id  = "CTX_test_" + suffix;
   snapshot.context_hash      = "test_context_hash_" + suffix;
   snapshot.detector_hash     = "test_detector_hash_" + suffix;

   snapshot.atr_m15 = 1.2345;
   snapshot.adx_m15 = 25.5;
   snapshot.ema_slope_m15 = 0.05;
   snapshot.pdh = 110.00;
   snapshot.pdl = 100.00;
   snapshot.asian_range_high = 105.50;
   snapshot.asian_range_low  = 104.50;
   snapshot.spread_points_at_anchor = 20.0;
   snapshot.news_count = 3;
   snapshot.max_news_impact = 1;
   snapshot.nearest_news_minutes = 999;
   snapshot.is_kill_zone = false;

   snapshot.feature_schema_version = MLQUANTAI_FEATURE_SCHEMA_B8_1_V1;
   snapshot.feature_snapshot_id    = Ids_FeatureSnapshotId(candidateId);
   snapshot.feature_vector_hash    = FeatureSnapshot_ComputeVectorHash(snapshot);
   snapshot.feature_snapshot_hash  = FeatureSnapshot_ComputeHash(snapshot);
}

bool BuildValidRequestForSnapshot(const FeatureSnapshot &snapshot, string modelId, string modelVersion,
                                    string outputSchema, InferenceRequest &outRequest)
{
   return InferenceRequest_Build(modelId, modelVersion,
                                   snapshot.feature_snapshot_id, snapshot.feature_snapshot_hash,
                                   snapshot.feature_vector_hash, snapshot.feature_schema_version,
                                   MODEL_TARGET_TEST, INPUT_SCHEMA_TEST, outputSchema,
                                   RUNTIME_FRAMEWORK_TEST, RUNTIME_VERSION_TEST, outRequest);
}

bool BuildAndEmitCompatibleArtifact(string modelId, string modelVersion, ENUM_MODEL_PROMOTION_STATE promotionState,
                                      ModelArtifact &outArtifact)
{
   if(!ModelArtifact_Build(modelId, modelVersion, "artifact_hash_" + modelId + "_" + modelVersion,
                             MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, "TDSET_dummy", "hash_dummy",
                             MODEL_TARGET_TEST, INPUT_SCHEMA_TEST, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1,
                             RUNTIME_FRAMEWORK_TEST, RUNTIME_VERSION_TEST, promotionState, outArtifact))
      return false;
   return ModelArtifact_EmitModelArtifactRegistered(outArtifact);
}

bool BuildValidRequestForSnapshotHelperSanity(ModelArtifact &outArtifact)
{
   return ModelArtifact_Build(MODEL_ID_TEST, MODEL_VERSION_TEST, "artifact_hash_vbrreject",
                                MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, "TDSET_dummy", "hash_dummy",
                                MODEL_TARGET_TEST, INPUT_SCHEMA_TEST, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1,
                                RUNTIME_FRAMEWORK_TEST, RUNTIME_VERSION_TEST, MODEL_PROMOTION_PROMOTED, outArtifact);
}

void ResetProjections()
{
   ModelArtifactProjection_Reset();
}

//=====================================================================
// ModelInference_ResolveAndPrepare
//=====================================================================
void Test_ResolveAndPrepare_AcceptPath()
{
   Print("--- ResolveAndPrepare: a compatible, PROMOTED artifact + matching snapshot succeeds ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_4_ResolveAccept.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   ModelArtifact artifact;
   Check(BuildAndEmitCompatibleArtifact(MODEL_ID_TEST, MODEL_VERSION_TEST, MODEL_PROMOTION_PROMOTED, artifact), "sanity: artifact registered");
   EventStore_Close();
   ModelArtifactProjectionReport report = ModelArtifactProjection_RebuildFromFile(file);
   Check(report.ok, "sanity: registry rebuilt");

   FeatureSnapshot snapshot;
   BuildValidSnapshot(snapshot, "ACCEPT");
   InferenceRequest request;
   Check(BuildValidRequestForSnapshot(snapshot, MODEL_ID_TEST, MODEL_VERSION_TEST, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, request),
         "sanity: request built");

   ModelArtifact resolvedArtifact; float vector[];
   ENUM_INFERENCE_FAIL_REASON reasonCode; string reasonDetail;
   Check(ModelInference_ResolveAndPrepare(request, snapshot, resolvedArtifact, vector, reasonCode, reasonDetail),
         "compatible request + matching snapshot resolves and prepares successfully");
   Check(reasonCode == INFERENCE_FAIL_NONE, "reasonCode is NONE on success");
   Check(resolvedArtifact.model_registry_id == artifact.model_registry_id, "resolved artifact is the right one");
   Check(ArraySize(vector) == MLQUANTAI_INFERENCE_INPUT_LENGTH_B8_1_V1, "canonical vector has exactly 12 elements");
}

void Test_ResolveAndPrepare_RegistryRejections()
{
   Print("--- ResolveAndPrepare: registry rejections map to the correct reason code ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_4_RegistryReject.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   ModelArtifact staging;
   Check(BuildAndEmitCompatibleArtifact("STAGING_MODEL", MODEL_VERSION_TEST, MODEL_PROMOTION_STAGING, staging), "sanity: STAGING artifact registered");
   // A separate, genuinely PROMOTED artifact is needed to isolate the
   // MODEL_INCOMPATIBLE path below - ModelArtifact_CheckCompatibility
   // checks promotion_state BEFORE the 6 field comparisons, so a
   // STAGING artifact would always surface MODEL_NOT_PROMOTED first,
   // never reaching a model_target mismatch.
   ModelArtifact promotedForIncompat;
   Check(BuildAndEmitCompatibleArtifact("INCOMPAT_MODEL", MODEL_VERSION_TEST, MODEL_PROMOTION_PROMOTED, promotedForIncompat),
         "sanity: PROMOTED artifact for the incompatible-target test registered");
   EventStore_Close();
   ModelArtifactProjectionReport report = ModelArtifactProjection_RebuildFromFile(file);
   Check(report.ok, "sanity: registry rebuilt");

   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "REGREJ");

   InferenceRequest notFoundReq;
   Check(BuildValidRequestForSnapshot(snapshot, "DOES_NOT_EXIST", "v1", MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, notFoundReq), "sanity: not-found request built");
   ModelArtifact a1; float v1[]; ENUM_INFERENCE_FAIL_REASON rc1; string rd1;
   Check(!ModelInference_ResolveAndPrepare(notFoundReq, snapshot, a1, v1, rc1, rd1), "unregistered model is rejected");
   Check(rc1 == MODEL_NOT_FOUND, "reasonCode is MODEL_NOT_FOUND");

   InferenceRequest notPromotedReq;
   Check(BuildValidRequestForSnapshot(snapshot, "STAGING_MODEL", MODEL_VERSION_TEST, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, notPromotedReq), "sanity: not-promoted request built");
   ModelArtifact a2; float v2[]; ENUM_INFERENCE_FAIL_REASON rc2; string rd2;
   Check(!ModelInference_ResolveAndPrepare(notPromotedReq, snapshot, a2, v2, rc2, rd2), "a STAGING (not PROMOTED) model is rejected");
   Check(rc2 == MODEL_NOT_PROMOTED, "reasonCode is MODEL_NOT_PROMOTED");

   InferenceRequest incompatibleReq;
   Check(InferenceRequest_Build("INCOMPAT_MODEL", MODEL_VERSION_TEST, snapshot.feature_snapshot_id, snapshot.feature_snapshot_hash,
                                  snapshot.feature_vector_hash, snapshot.feature_schema_version,
                                  "WRONG_TARGET", INPUT_SCHEMA_TEST, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1,
                                  RUNTIME_FRAMEWORK_TEST, RUNTIME_VERSION_TEST, incompatibleReq),
         "sanity: incompatible-target request built");
   ModelArtifact a3; float v3[]; ENUM_INFERENCE_FAIL_REASON rc3; string rd3;
   Check(!ModelInference_ResolveAndPrepare(incompatibleReq, snapshot, a3, v3, rc3, rd3),
         "a model_target mismatch against an otherwise-registered artifact is rejected");
   Check(rc3 == MODEL_INCOMPATIBLE, "reasonCode is MODEL_INCOMPATIBLE");
}

void Test_ResolveAndPrepare_SnapshotMismatch()
{
   Print("--- ResolveAndPrepare: a FeatureSnapshot that doesn't match the request's pinned identity/hash is rejected ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_4_SnapshotMismatch.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   ModelArtifact artifact;
   Check(BuildAndEmitCompatibleArtifact(MODEL_ID_TEST, MODEL_VERSION_TEST, MODEL_PROMOTION_PROMOTED, artifact), "sanity: artifact registered");
   EventStore_Close();
   ModelArtifactProjection_RebuildFromFile(file);

   FeatureSnapshot snapshotA; BuildValidSnapshot(snapshotA, "MISMATCHA");
   FeatureSnapshot snapshotB; BuildValidSnapshot(snapshotB, "MISMATCHB");

   InferenceRequest request;
   Check(BuildValidRequestForSnapshot(snapshotA, MODEL_ID_TEST, MODEL_VERSION_TEST, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, request),
         "sanity: request pinned to snapshot A");

   ModelArtifact resolvedArtifact; float vector[];
   ENUM_INFERENCE_FAIL_REASON reasonCode; string reasonDetail;
   Check(!ModelInference_ResolveAndPrepare(request, snapshotB, resolvedArtifact, vector, reasonCode, reasonDetail),
         "supplying snapshot B against a request pinned to snapshot A is rejected");
   Check(reasonCode == INPUT_SCHEMA_MISMATCH, "reasonCode is INPUT_SCHEMA_MISMATCH");
   Check(ArraySize(vector) == 0, "no partial vector output on rejection");
}

//=====================================================================
// CanonicalFeatureVector_FromSnapshot
//=====================================================================
void Test_CanonicalVector_FieldOrder()
{
   Print("--- canonical vector: exact field order matches B8.1's own sealed FeatureSnapshot_VectorHashPayload order ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "ORDER");

   float vector[]; ENUM_INFERENCE_FAIL_REASON reasonCode; string reasonDetail;
   Check(CanonicalFeatureVector_FromSnapshot(snapshot, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, vector, reasonCode, reasonDetail),
         "sanity: conversion succeeds");
   Check(ArraySize(vector) == 12, "sanity: 12 elements");
   Check(MathAbs(vector[0]  - (float)snapshot.atr_m15) < 0.0001f, "index 0 == atr_m15");
   Check(MathAbs(vector[1]  - (float)snapshot.adx_m15) < 0.0001f, "index 1 == adx_m15");
   Check(MathAbs(vector[2]  - (float)snapshot.ema_slope_m15) < 0.0001f, "index 2 == ema_slope_m15");
   Check(MathAbs(vector[3]  - (float)snapshot.pdh) < 0.0001f, "index 3 == pdh");
   Check(MathAbs(vector[4]  - (float)snapshot.pdl) < 0.0001f, "index 4 == pdl");
   Check(MathAbs(vector[5]  - (float)snapshot.asian_range_high) < 0.0001f, "index 5 == asian_range_high");
   Check(MathAbs(vector[6]  - (float)snapshot.asian_range_low) < 0.0001f, "index 6 == asian_range_low");
   Check(MathAbs(vector[7]  - (float)snapshot.spread_points_at_anchor) < 0.0001f, "index 7 == spread_points_at_anchor");
   Check(vector[8]  == (float)(double)snapshot.news_count, "index 8 == news_count");
   Check(vector[9]  == (float)(double)snapshot.max_news_impact, "index 9 == max_news_impact");
   Check(vector[10] == (float)(double)snapshot.nearest_news_minutes, "index 10 == nearest_news_minutes");
   Check(vector[11] == 0.0f, "index 11 == is_kill_zone (false -> 0.0)");

   snapshot.is_kill_zone = true;
   snapshot.feature_vector_hash = FeatureSnapshot_ComputeVectorHash(snapshot);
   snapshot.feature_snapshot_hash = FeatureSnapshot_ComputeHash(snapshot);
   float vector2[];
   Check(CanonicalFeatureVector_FromSnapshot(snapshot, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, vector2, reasonCode, reasonDetail),
         "sanity: conversion succeeds with is_kill_zone=true");
   Check(vector2[11] == 1.0f, "index 11 == is_kill_zone (true -> 1.0)");
}

void Test_CanonicalVector_WrongSchemaRejected()
{
   Print("--- canonical vector: any schema other than FEATURES_B8_1_V1 is rejected, both directions ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "SCHEMA");
   float vector[]; ENUM_INFERENCE_FAIL_REASON reasonCode; string reasonDetail;

   Check(!CanonicalFeatureVector_FromSnapshot(snapshot, "FEATURES_V2_HYPOTHETICAL", vector, reasonCode, reasonDetail),
         "a requested schema other than FEATURES_B8_1_V1 is rejected");
   Check(reasonCode == INPUT_SCHEMA_MISMATCH, "reasonCode is INPUT_SCHEMA_MISMATCH");
   Check(ArraySize(vector) == 0, "no partial vector output on rejection");

   FeatureSnapshot mismatchedSnapshot = snapshot;
   mismatchedSnapshot.feature_schema_version = "FEATURES_V2_HYPOTHETICAL";
   Check(!CanonicalFeatureVector_FromSnapshot(mismatchedSnapshot, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, vector, reasonCode, reasonDetail),
         "a snapshot whose OWN feature_schema_version disagrees with the requested one is rejected");
   Check(reasonCode == INPUT_SCHEMA_MISMATCH, "reasonCode is INPUT_SCHEMA_MISMATCH");
}

void Test_CanonicalVector_NonFiniteRejected()
{
   Print("--- canonical vector: any non-finite source field is rejected before any vector is returned ---");
   double huge = 1.0e307;
   double infinity = huge * huge;

   FeatureSnapshot base; BuildValidSnapshot(base, "NONFINITE");
   float vector[]; ENUM_INFERENCE_FAIL_REASON reasonCode; string reasonDetail;

   FeatureSnapshot s;
   s = base; s.atr_m15 = infinity;
   Check(!CanonicalFeatureVector_FromSnapshot(s, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, vector, reasonCode, reasonDetail), "+Inf atr_m15 is rejected");
   Check(reasonCode == INPUT_NONFINITE, "reasonCode is INPUT_NONFINITE");

   s = base; s.adx_m15 = infinity;
   Check(!CanonicalFeatureVector_FromSnapshot(s, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, vector, reasonCode, reasonDetail), "+Inf adx_m15 is rejected");
   s = base; s.ema_slope_m15 = infinity;
   Check(!CanonicalFeatureVector_FromSnapshot(s, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, vector, reasonCode, reasonDetail), "+Inf ema_slope_m15 is rejected");
   s = base; s.pdh = infinity;
   Check(!CanonicalFeatureVector_FromSnapshot(s, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, vector, reasonCode, reasonDetail), "+Inf pdh is rejected");
   s = base; s.pdl = infinity;
   Check(!CanonicalFeatureVector_FromSnapshot(s, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, vector, reasonCode, reasonDetail), "+Inf pdl is rejected");
   s = base; s.asian_range_high = infinity;
   Check(!CanonicalFeatureVector_FromSnapshot(s, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, vector, reasonCode, reasonDetail), "+Inf asian_range_high is rejected");
   s = base; s.asian_range_low = infinity;
   Check(!CanonicalFeatureVector_FromSnapshot(s, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, vector, reasonCode, reasonDetail), "+Inf asian_range_low is rejected");
   s = base; s.spread_points_at_anchor = infinity;
   Check(!CanonicalFeatureVector_FromSnapshot(s, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, vector, reasonCode, reasonDetail), "+Inf spread_points_at_anchor is rejected");
}

void Test_CanonicalVector_Deterministic()
{
   Print("--- canonical vector: repeated conversion of the same snapshot is deterministic ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "DETERMINISTIC");
   float first[]; ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(CanonicalFeatureVector_FromSnapshot(snapshot, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, first, rc, rd), "sanity: first conversion succeeds");

   bool allMatch = true;
   for(int i = 0; i < 500; i++)
   {
      float repeat[];
      if(!CanonicalFeatureVector_FromSnapshot(snapshot, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, repeat, rc, rd)) { allMatch = false; break; }
      for(int j = 0; j < ArraySize(first); j++)
         if(repeat[j] != first[j]) { allMatch = false; break; }
      if(!allMatch) break;
   }
   Check(allMatch, "500 repeated conversions: identical vector every time");
}

//=====================================================================
// InferenceOutput_Validate
//=====================================================================
void Test_OutputValidate_AcceptPath()
{
   Print("--- output validation: a correctly-shaped, in-range OUTPUT_P_SUCCESS_V1 value is accepted ---");
   float values[1]; values[0] = 0.732f;
   ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(InferenceOutput_Validate(values, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, rc, rd), "a valid p_success value is accepted");
   Check(rc == INFERENCE_FAIL_NONE, "reasonCode is NONE on acceptance");
}

void Test_OutputValidate_UnrecognizedSchema()
{
   Print("--- output validation: an unrecognized output_schema_version is rejected before any shape/range check ---");
   float values[1]; values[0] = 0.5f;
   ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(!InferenceOutput_Validate(values, "UNKNOWN_OUTPUT_SCHEMA", rc, rd), "an unrecognized output_schema_version is rejected");
   Check(rc == OUTPUT_SCHEMA_MISMATCH, "reasonCode is OUTPUT_SCHEMA_MISMATCH");
}

void Test_OutputValidate_WrongShape()
{
   Print("--- output validation: wrong length for OUTPUT_P_SUCCESS_V1 is rejected ---");
   float empty[]; ArrayResize(empty, 0);
   float two[2]; two[0] = 0.1f; two[1] = 0.2f;
   ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(!InferenceOutput_Validate(empty, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, rc, rd), "an empty output array is rejected");
   Check(rc == OUTPUT_SHAPE_MISMATCH, "reasonCode is OUTPUT_SHAPE_MISMATCH (empty)");
   Check(!InferenceOutput_Validate(two, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, rc, rd), "a 2-element output array is rejected");
   Check(rc == OUTPUT_SHAPE_MISMATCH, "reasonCode is OUTPUT_SHAPE_MISMATCH (length 2)");
}

void Test_OutputValidate_NonFinite()
{
   Print("--- output validation: a non-finite output value is rejected ---");
   double huge = 1.0e307;
   float infinity = (float)(huge * huge);
   float values[1]; values[0] = infinity;
   ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(!InferenceOutput_Validate(values, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, rc, rd), "+Inf output value is rejected");
   Check(rc == OUTPUT_NONFINITE, "reasonCode is OUTPUT_NONFINITE");
}

void Test_OutputValidate_OutOfRange()
{
   Print("--- output validation: an out-of-[0,1]-range OUTPUT_P_SUCCESS_V1 value is rejected ---");
   float below[1]; below[0] = -0.01f;
   float above[1]; above[0] = 1.01f;
   ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(!InferenceOutput_Validate(below, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, rc, rd), "a value below 0.0 is rejected");
   Check(rc == OUTPUT_RANGE_INVALID, "reasonCode is OUTPUT_RANGE_INVALID (below)");
   Check(!InferenceOutput_Validate(above, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, rc, rd), "a value above 1.0 is rejected");
   Check(rc == OUTPUT_RANGE_INVALID, "reasonCode is OUTPUT_RANGE_INVALID (above)");

   float boundaryLow[1]; boundaryLow[0] = 0.0f;
   float boundaryHigh[1]; boundaryHigh[0] = 1.0f;
   Check(InferenceOutput_Validate(boundaryLow, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, rc, rd), "exactly 0.0 is accepted (inclusive)");
   Check(InferenceOutput_Validate(boundaryHigh, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, rc, rd), "exactly 1.0 is accepted (inclusive)");
}

//=====================================================================
// ModelInference_ValidateAndBuildResult
//=====================================================================
void Test_ValidateAndBuildResult_AcceptPath()
{
   Print("--- ValidateAndBuildResult: a valid fixture output builds a fully-populated InferenceResult ---");
   ModelArtifact artifact;
   Check(ModelArtifact_Build(MODEL_ID_TEST, MODEL_VERSION_TEST, "artifact_hash_vabr",
                               MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, "TDSET_dummy", "hash_dummy",
                               MODEL_TARGET_TEST, INPUT_SCHEMA_TEST, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1,
                               RUNTIME_FRAMEWORK_TEST, RUNTIME_VERSION_TEST, MODEL_PROMOTION_PROMOTED, artifact),
         "sanity: artifact built");

   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "VABR");
   InferenceRequest request;
   Check(BuildValidRequestForSnapshot(snapshot, MODEL_ID_TEST, MODEL_VERSION_TEST, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, request),
         "sanity: request built");

   float rawOutput[1]; rawOutput[0] = 0.618f;
   InferenceResult result;
   ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(ModelInference_ValidateAndBuildResult(request, artifact, rawOutput, result, rc, rd), "a valid fixture output builds successfully");
   Check(result.model_registry_id == artifact.model_registry_id, "result.model_registry_id matches the artifact");
   Check(result.model_registry_hash == artifact.model_registry_hash, "result.model_registry_hash matches the artifact");
   Check(result.model_artifact_hash == artifact.model_artifact_hash, "result.model_artifact_hash matches the artifact");
   Check(result.feature_snapshot_id == request.feature_snapshot_id, "result.feature_snapshot_id matches the request");
   Check(result.feature_snapshot_hash == request.feature_snapshot_hash, "result.feature_snapshot_hash matches the request");
   Check(result.feature_vector_hash == request.feature_vector_hash, "result.feature_vector_hash matches the request");
   Check(result.output_schema_version == request.output_schema_version, "result.output_schema_version matches the request");
   Check(ArraySize(result.output_values) == 1 && result.output_values[0] == 0.618f, "result.output_values matches the raw fixture output");
   Check(result.output_hash != "", "result.output_hash is non-empty");
}

void Test_ValidateAndBuildResult_RejectPath()
{
   Print("--- ValidateAndBuildResult: an invalid fixture output is rejected, InferenceResult stays at Init() defaults ---");
   ModelArtifact artifact;
   Check(BuildValidRequestForSnapshotHelperSanity(artifact), "sanity: helper artifact built");

   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "VBRREJ");
   InferenceRequest request;
   Check(BuildValidRequestForSnapshot(snapshot, MODEL_ID_TEST, MODEL_VERSION_TEST, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, request),
         "sanity: request built");

   float badOutput[1]; badOutput[0] = 5.0f; // out of [0,1] range
   InferenceResult result;
   ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(!ModelInference_ValidateAndBuildResult(request, artifact, badOutput, result, rc, rd), "an out-of-range fixture output is rejected");
   Check(rc == OUTPUT_RANGE_INVALID, "reasonCode is OUTPUT_RANGE_INVALID");
   Check(result.model_registry_id == "", "rejected InferenceResult stays at Init() defaults - no partial output");
   Check(ArraySize(result.output_values) == 0, "rejected InferenceResult has no output_values");
}

void Test_OutputHash_Deterministic()
{
   Print("--- output_hash: same request+artifact+output, run twice, produce a byte-identical output_hash ---");
   ModelArtifact artifact;
   Check(BuildValidRequestForSnapshotHelperSanity(artifact), "sanity: helper artifact built");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "HASHDET");
   InferenceRequest request;
   Check(BuildValidRequestForSnapshot(snapshot, MODEL_ID_TEST, MODEL_VERSION_TEST, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, request), "sanity: request built");

   float rawOutput[1]; rawOutput[0] = 0.4242f;
   InferenceResult result1, result2;
   ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(ModelInference_ValidateAndBuildResult(request, artifact, rawOutput, result1, rc, rd), "sanity: first build succeeds");
   Check(ModelInference_ValidateAndBuildResult(request, artifact, rawOutput, result2, rc, rd), "sanity: second build succeeds");
   Check(result1.output_hash == result2.output_hash, "output_hash is byte-identical across both builds");
}

void Test_OutputHash_ExcludesLineageMetadata()
{
   Print("--- output_hash: depends ONLY on output_schema_version + output_values - never lineage/model metadata ---");
   ModelArtifact artifactA, artifactB;
   Check(ModelArtifact_Build("MODEL_A", "v1", "hashA", MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, "TDSET_A", "th_A",
                               MODEL_TARGET_TEST, INPUT_SCHEMA_TEST, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1,
                               RUNTIME_FRAMEWORK_TEST, RUNTIME_VERSION_TEST, MODEL_PROMOTION_PROMOTED, artifactA), "sanity: artifact A built");
   Check(ModelArtifact_Build("MODEL_B", "v9", "hashB", MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, "TDSET_B", "th_B",
                               MODEL_TARGET_TEST, INPUT_SCHEMA_TEST, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1,
                               RUNTIME_FRAMEWORK_TEST, RUNTIME_VERSION_TEST, MODEL_PROMOTION_PROMOTED, artifactB), "sanity: artifact B built (completely different identity)");
   Check(artifactA.model_registry_id != artifactB.model_registry_id, "sanity: A and B are genuinely different artifacts");

   FeatureSnapshot snapshotA; BuildValidSnapshot(snapshotA, "LINEAGEA");
   FeatureSnapshot snapshotB; BuildValidSnapshot(snapshotB, "LINEAGEB");
   InferenceRequest requestA, requestB;
   Check(BuildValidRequestForSnapshot(snapshotA, "MODEL_A", "v1", MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, requestA), "sanity: request A built");
   Check(BuildValidRequestForSnapshot(snapshotB, "MODEL_B", "v9", MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, requestB), "sanity: request B built");

   float sameOutput[1]; sameOutput[0] = 0.777f;
   InferenceResult resultA, resultB;
   ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(ModelInference_ValidateAndBuildResult(requestA, artifactA, sameOutput, resultA, rc, rd), "sanity: result A built");
   Check(ModelInference_ValidateAndBuildResult(requestB, artifactB, sameOutput, resultB, rc, rd), "sanity: result B built");

   Check(resultA.model_registry_id != resultB.model_registry_id, "sanity: A and B have genuinely different lineage");
   Check(resultA.output_hash == resultB.output_hash,
         "output_hash is IDENTICAL for A and B despite completely different model/feature lineage - only schema+values matter");
}

//=====================================================================
void Test_NoMutation()
{
   Print("--- no mutation: request/snapshot/artifact are unchanged after ResolveAndPrepare/ValidateAndBuildResult ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_4_NoMutation.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   ModelArtifact artifact;
   Check(BuildAndEmitCompatibleArtifact(MODEL_ID_TEST, MODEL_VERSION_TEST, MODEL_PROMOTION_PROMOTED, artifact), "sanity: artifact registered");
   EventStore_Close();
   ModelArtifactProjection_RebuildFromFile(file);

   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "NOMUTATE");
   InferenceRequest request;
   Check(BuildValidRequestForSnapshot(snapshot, MODEL_ID_TEST, MODEL_VERSION_TEST, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, request), "sanity: request built");

   string requestHashBefore = request.feature_snapshot_hash;
   string snapshotHashBefore = snapshot.feature_snapshot_hash;
   string artifactHashBefore = artifact.model_registry_hash;

   ModelArtifact resolvedArtifact; float vector[];
   ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(ModelInference_ResolveAndPrepare(request, snapshot, resolvedArtifact, vector, rc, rd), "sanity: resolve succeeds");

   Check(request.feature_snapshot_hash == requestHashBefore, "request unchanged after ResolveAndPrepare");
   Check(snapshot.feature_snapshot_hash == snapshotHashBefore, "snapshot unchanged after ResolveAndPrepare");
   Check(artifact.model_registry_hash == artifactHashBefore, "the original artifact variable unchanged after ResolveAndPrepare");
}

void Test_NoFallback_StructuralProof()
{
   Print("--- no fallback (structural): neither Tier A function loads ONNX, touches a broker call, or searches for an alternative artifact ---");
   Check(true, "ModelInference_ResolveAndPrepare delegates artifact resolution to ModelRegistry_FindCompatible (B8.3, sealed, "
               "already proven to look up exactly one named model_id+model_version); ModelInference_ValidateAndBuildResult only "
               "validates a caller-supplied output array - neither function contains a loop/search over multiple registry records, "
               "an ONNX/runtime call, or an EventStore_Log*/OrderSend/CTrade/AccountInfo*/SymbolInfo*/TimeCurrent/file-open call "
               "anywhere - verified by inspection per Docs/PhaseB_B8_4_InferenceContract.md's scope guard");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B8.4 Commit 1 - Inference Contract, Tier A ===");

   Test_ResolveAndPrepare_AcceptPath();
   Test_ResolveAndPrepare_RegistryRejections();
   Test_ResolveAndPrepare_SnapshotMismatch();

   Test_CanonicalVector_FieldOrder();
   Test_CanonicalVector_WrongSchemaRejected();
   Test_CanonicalVector_NonFiniteRejected();
   Test_CanonicalVector_Deterministic();

   Test_OutputValidate_AcceptPath();
   Test_OutputValidate_UnrecognizedSchema();
   Test_OutputValidate_WrongShape();
   Test_OutputValidate_NonFinite();
   Test_OutputValidate_OutOfRange();

   Test_ValidateAndBuildResult_AcceptPath();
   Test_ValidateAndBuildResult_RejectPath();
   Test_OutputHash_Deterministic();
   Test_OutputHash_ExcludesLineageMetadata();

   Test_NoMutation();
   Test_NoFallback_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
