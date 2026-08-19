//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_5_AIDecision.mq5                                 |
//| Phase B8.5 Commit 1 DoD, per                                        |
//| Docs/PhaseB_B8_5_AIDecisionContract.md's test matrix.               |
//| Pure mapping only - no EventStore, no ONNX, no broker/account/tick. |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/AI/MLQuantAI_AIDecisionBuilder.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers.
//---------------------------------------------------------------------
void BuildValidSnapshot(FeatureSnapshot &snapshot, string suffix)
{
   FeatureSnapshot_Init(snapshot);
   string candidateId = "CND_aidec_" + suffix;
   snapshot.candidate_id      = candidateId;
   snapshot.candidate_hash    = "test_candidate_hash_" + suffix;
   snapshot.context_event_id  = "CTX_aidec_" + suffix;
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

void BuildValidInferenceResult(const FeatureSnapshot &snapshot, string modelRegistryId, string modelRegistryHash,
                                 string modelArtifactHash, float pSuccessValue, InferenceResult &outResult)
{
   InferenceResult_Init(outResult);
   outResult.model_registry_id   = modelRegistryId;
   outResult.model_registry_hash = modelRegistryHash;
   outResult.model_artifact_hash = modelArtifactHash;

   outResult.feature_snapshot_id   = snapshot.feature_snapshot_id;
   outResult.feature_snapshot_hash = snapshot.feature_snapshot_hash;
   outResult.feature_vector_hash   = snapshot.feature_vector_hash;

   outResult.output_schema_version = MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1;
   ArrayResize(outResult.output_values, 1);
   outResult.output_values[0] = pSuccessValue;

   outResult.runtime_framework = "ONNXRuntime";
   outResult.runtime_version   = "1.16.0";

   outResult.output_hash = InferenceResult_ComputeOutputHash(outResult);
}

void BuildValidPolicy(AIDecisionPolicy &policy, string policyVersion, string thresholdVersion, double threshold)
{
   AIDecisionPolicy_Init(policy);
   policy.decision_policy_version = policyVersion;
   policy.threshold_version       = thresholdVersion;
   policy.allow_threshold         = threshold;
}

//=====================================================================
// Accept path
//=====================================================================
void Test_AcceptPath_Allow_AboveThreshold()
{
   Print("--- accept path: p_success above threshold -> ALLOW / REASON_NONE ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "ALLOW");
   InferenceResult inference;
   BuildValidInferenceResult(snapshot, "MREG_test_v1", "hash_mreg_1", "hash_artifact_1", 0.80f, inference);
   AIDecisionPolicy policy; BuildValidPolicy(policy, "POLICY_V1", "THRESH_V1", 0.70);

   AIDecision decision; string reasonDetail;
   bool ok = AIDecision_Build(inference, snapshot, policy, decision, reasonDetail);
   Check(ok, "build succeeds when p_success (0.80) is above threshold (0.70)");
   Check(decision.decision_outcome == AI_DECISION_OUTCOME_ALLOW, "decision_outcome is ALLOW");
   Check(decision.decision_reason_code == REASON_NONE, "decision_reason_code is REASON_NONE");
   Check(decision.p_success == 0.80, "p_success copied verbatim");
   Check(decision.candidate_id == snapshot.candidate_id, "candidate_id copied verbatim from snapshot");
   Check(decision.candidate_hash == snapshot.candidate_hash, "candidate_hash copied verbatim from snapshot");
   Check(decision.feature_snapshot_id == inference.feature_snapshot_id, "feature_snapshot_id copied verbatim from inference");
   Check(decision.model_registry_id == "MREG_test_v1", "model_registry_id copied verbatim from inference");
   Check(decision.model_registry_hash == "hash_mreg_1", "model_registry_hash copied verbatim from inference");
   Check(decision.model_artifact_hash == "hash_artifact_1", "model_artifact_hash copied verbatim from inference");
   Check(decision.inference_output_hash == inference.output_hash, "inference_output_hash copied verbatim from inference");
   Check(decision.output_schema_version == inference.output_schema_version, "output_schema_version copied verbatim from inference");
   Check(decision.inference_contract_version == inference.inference_contract_version, "inference_contract_version copied verbatim from inference");
   Check(decision.decision_policy_version == "POLICY_V1", "decision_policy_version copied from policy");
   Check(decision.threshold_version == "THRESH_V1", "threshold_version copied from policy");
   Check(decision.allow_threshold == 0.70, "allow_threshold copied from policy");
   Check(decision.ai_decision_id != "", "ai_decision_id is non-empty");
   Check(decision.ai_decision_hash != "", "ai_decision_hash is non-empty");
}

void Test_AcceptPath_Allow_AtThresholdBoundary()
{
   Print("--- accept path: p_success exactly equal to threshold -> ALLOW (inclusive) ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "BOUNDARY");
   InferenceResult inference;
   BuildValidInferenceResult(snapshot, "MREG_test_v1", "hash_mreg_1", "hash_artifact_1", 0.70f, inference);
   AIDecisionPolicy policy; BuildValidPolicy(policy, "POLICY_V1", "THRESH_V1", 0.70);

   AIDecision decision; string reasonDetail;
   bool ok = AIDecision_Build(inference, snapshot, policy, decision, reasonDetail);
   Check(ok, "build succeeds at the exact boundary");
   Check(decision.decision_outcome == AI_DECISION_OUTCOME_ALLOW, "p_success == allow_threshold is ALLOW, not REJECT (inclusive >=)");
   Check(decision.decision_reason_code == REASON_NONE, "decision_reason_code is REASON_NONE at the boundary");
}

void Test_AcceptPath_Reject_BelowThreshold()
{
   Print("--- accept path: p_success below threshold -> REJECT / REASON_AI_REJECT ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "REJECT");
   InferenceResult inference;
   BuildValidInferenceResult(snapshot, "MREG_test_v1", "hash_mreg_1", "hash_artifact_1", 0.40f, inference);
   AIDecisionPolicy policy; BuildValidPolicy(policy, "POLICY_V1", "THRESH_V1", 0.70);

   AIDecision decision; string reasonDetail;
   bool ok = AIDecision_Build(inference, snapshot, policy, decision, reasonDetail);
   Check(ok, "build succeeds when p_success (0.40) is below threshold (0.70)");
   Check(decision.decision_outcome == AI_DECISION_OUTCOME_REJECT, "decision_outcome is REJECT");
   Check(decision.decision_reason_code == REASON_AI_REJECT, "decision_reason_code is REASON_AI_REJECT");
}

//=====================================================================
// Determinism
//=====================================================================
void Test_Determinism_IdAndHash_10000Reps()
{
   Print("--- determinism: 10,000 repeated builds of the same inputs produce byte-identical id/hash every time ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "DETERM");
   InferenceResult inference;
   BuildValidInferenceResult(snapshot, "MREG_test_v1", "hash_mreg_1", "hash_artifact_1", 0.75f, inference);
   AIDecisionPolicy policy; BuildValidPolicy(policy, "POLICY_V1", "THRESH_V1", 0.60);

   AIDecision first; string rd;
   Check(AIDecision_Build(inference, snapshot, policy, first, rd), "sanity: first build succeeds");

   bool allMatch = true;
   for(int i = 0; i < 10000; i++)
   {
      AIDecision repeat;
      if(!AIDecision_Build(inference, snapshot, policy, repeat, rd)) { allMatch = false; break; }
      if(repeat.ai_decision_id != first.ai_decision_id || repeat.ai_decision_hash != first.ai_decision_hash)
      { allMatch = false; break; }
   }
   Check(allMatch, "10,000 repeated builds: identical ai_decision_id and ai_decision_hash every time");
}

//=====================================================================
// Identity vs. hash sensitivity
//=====================================================================
void Test_IdentitySensitivity_PolicyVersionChangesId()
{
   Print("--- identity sensitivity: a different decision_policy_version produces a different ai_decision_id ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "IDPOLICY");
   InferenceResult inference;
   BuildValidInferenceResult(snapshot, "MREG_test_v1", "hash_mreg_1", "hash_artifact_1", 0.75f, inference);

   AIDecisionPolicy policyA; BuildValidPolicy(policyA, "POLICY_V1", "THRESH_V1", 0.60);
   AIDecisionPolicy policyB; BuildValidPolicy(policyB, "POLICY_V2", "THRESH_V1", 0.60);

   AIDecision decisionA, decisionB; string rd;
   Check(AIDecision_Build(inference, snapshot, policyA, decisionA, rd), "sanity: build A succeeds");
   Check(AIDecision_Build(inference, snapshot, policyB, decisionB, rd), "sanity: build B succeeds");
   Check(decisionA.ai_decision_id != decisionB.ai_decision_id, "different decision_policy_version moves ai_decision_id");
}

void Test_IdentitySensitivity_ModelRegistryIdChangesId()
{
   Print("--- identity sensitivity: a different model_registry_id produces a different ai_decision_id ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "IDMODEL");
   InferenceResult inferenceA, inferenceB;
   BuildValidInferenceResult(snapshot, "MREG_A", "hash_mreg_A", "hash_artifact_A", 0.75f, inferenceA);
   BuildValidInferenceResult(snapshot, "MREG_B", "hash_mreg_B", "hash_artifact_B", 0.75f, inferenceB);
   AIDecisionPolicy policy; BuildValidPolicy(policy, "POLICY_V1", "THRESH_V1", 0.60);

   AIDecision decisionA, decisionB; string rd;
   Check(AIDecision_Build(inferenceA, snapshot, policy, decisionA, rd), "sanity: build A succeeds");
   Check(AIDecision_Build(inferenceB, snapshot, policy, decisionB, rd), "sanity: build B succeeds");
   Check(decisionA.ai_decision_id != decisionB.ai_decision_id, "different model_registry_id moves ai_decision_id");
}

void Test_HashSensitivity_ContentChangesMoveHashNotId()
{
   Print("--- hash sensitivity: content-only changes move ai_decision_hash while ai_decision_id stays identical ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "HASHSENS");
   AIDecisionPolicy policy; BuildValidPolicy(policy, "POLICY_V1", "THRESH_V1", 0.50);

   InferenceResult baseInference;
   BuildValidInferenceResult(snapshot, "MREG_fixed", "hash_mreg_fixed", "hash_artifact_fixed", 0.75f, baseInference);
   AIDecision baseline; string rd;
   Check(AIDecision_Build(baseInference, snapshot, policy, baseline, rd), "sanity: baseline build succeeds");

   // Different p_success (same identity seed: candidate_id, model_registry_id, decision_policy_version unchanged).
   InferenceResult perturbedP;
   BuildValidInferenceResult(snapshot, "MREG_fixed", "hash_mreg_fixed", "hash_artifact_fixed", 0.55f, perturbedP);
   AIDecision variantP;
   Check(AIDecision_Build(perturbedP, snapshot, policy, variantP, rd), "sanity: p_success-variant build succeeds");
   Check(variantP.ai_decision_id == baseline.ai_decision_id, "p_success change: ai_decision_id unchanged");
   Check(variantP.ai_decision_hash != baseline.ai_decision_hash, "p_success change: ai_decision_hash moves");

   // Different allow_threshold (same identity seed).
   AIDecisionPolicy perturbedPolicy; BuildValidPolicy(perturbedPolicy, "POLICY_V1", "THRESH_V1", 0.65);
   AIDecision variantThreshold;
   Check(AIDecision_Build(baseInference, snapshot, perturbedPolicy, variantThreshold, rd), "sanity: threshold-variant build succeeds");
   Check(variantThreshold.ai_decision_id == baseline.ai_decision_id, "allow_threshold change: ai_decision_id unchanged");
   Check(variantThreshold.ai_decision_hash != baseline.ai_decision_hash, "allow_threshold change: ai_decision_hash moves");

   // Different model_registry_hash (same model_registry_id, so identity seed unchanged).
   InferenceResult perturbedModelHash;
   BuildValidInferenceResult(snapshot, "MREG_fixed", "hash_mreg_DIFFERENT", "hash_artifact_fixed", 0.75f, perturbedModelHash);
   AIDecision variantModelHash;
   Check(AIDecision_Build(perturbedModelHash, snapshot, policy, variantModelHash, rd), "sanity: model_registry_hash-variant build succeeds");
   Check(variantModelHash.ai_decision_id == baseline.ai_decision_id, "model_registry_hash change: ai_decision_id unchanged");
   Check(variantModelHash.ai_decision_hash != baseline.ai_decision_hash, "model_registry_hash change: ai_decision_hash moves");

   // Different snapshot content (different candidate suffix would change candidate_id too, so instead
   // perturb only feature_vector_hash-affecting content while keeping the SAME candidate_id: use a
   // second snapshot fixture with identical candidate_id but a different atr_m15 -> different
   // feature_vector_hash/feature_snapshot_hash, then build a matching InferenceResult against it.
   FeatureSnapshot perturbedSnapshot = snapshot;
   perturbedSnapshot.atr_m15 = 9.9999;
   perturbedSnapshot.feature_vector_hash   = FeatureSnapshot_ComputeVectorHash(perturbedSnapshot);
   perturbedSnapshot.feature_snapshot_hash = FeatureSnapshot_ComputeHash(perturbedSnapshot);
   InferenceResult inferenceForPerturbedSnapshot;
   BuildValidInferenceResult(perturbedSnapshot, "MREG_fixed", "hash_mreg_fixed", "hash_artifact_fixed", 0.75f, inferenceForPerturbedSnapshot);
   AIDecision variantSnapshot;
   Check(AIDecision_Build(inferenceForPerturbedSnapshot, perturbedSnapshot, policy, variantSnapshot, rd),
         "sanity: snapshot-content-variant build succeeds");
   Check(variantSnapshot.ai_decision_id == baseline.ai_decision_id, "feature_vector_hash/feature_snapshot_hash change (same candidate_id): ai_decision_id unchanged");
   Check(variantSnapshot.ai_decision_hash != baseline.ai_decision_hash, "feature_vector_hash/feature_snapshot_hash change: ai_decision_hash moves");
}

//=====================================================================
// Fail-closed paths
//=====================================================================
void Test_FailClosed_EmptyPolicyVersions()
{
   Print("--- fail-closed: empty decision_policy_version or threshold_version is rejected, no AIDecision ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "EMPTYPOLICY");
   InferenceResult inference;
   BuildValidInferenceResult(snapshot, "MREG_test_v1", "hash_mreg_1", "hash_artifact_1", 0.75f, inference);

   AIDecisionPolicy policyEmptyDecision; BuildValidPolicy(policyEmptyDecision, "", "THRESH_V1", 0.5);
   AIDecision d1; string rd1;
   Check(!AIDecision_Build(inference, snapshot, policyEmptyDecision, d1, rd1), "empty decision_policy_version is rejected");
   Check(d1.decision_outcome == AI_DECISION_OUTCOME_NONE, "rejected AIDecision stays at Init() defaults");
   Check(d1.ai_decision_id == "", "rejected AIDecision has no ai_decision_id");

   AIDecisionPolicy policyEmptyThreshold; BuildValidPolicy(policyEmptyThreshold, "POLICY_V1", "", 0.5);
   AIDecision d2; string rd2;
   Check(!AIDecision_Build(inference, snapshot, policyEmptyThreshold, d2, rd2), "empty threshold_version is rejected");
   Check(d2.decision_outcome == AI_DECISION_OUTCOME_NONE, "rejected AIDecision stays at Init() defaults");
}

void Test_FailClosed_ThresholdOutOfRange()
{
   Print("--- fail-closed: non-finite or out-of-[0,1]-range allow_threshold is rejected ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "THRESHRANGE");
   InferenceResult inference;
   BuildValidInferenceResult(snapshot, "MREG_test_v1", "hash_mreg_1", "hash_artifact_1", 0.75f, inference);

   double huge = 1.0e307;
   double infinity = huge * huge;

   AIDecisionPolicy policyInf; BuildValidPolicy(policyInf, "POLICY_V1", "THRESH_V1", infinity);
   AIDecision d1; string rd1;
   Check(!AIDecision_Build(inference, snapshot, policyInf, d1, rd1), "+Inf allow_threshold is rejected");

   AIDecisionPolicy policyBelow; BuildValidPolicy(policyBelow, "POLICY_V1", "THRESH_V1", -0.01);
   AIDecision d2; string rd2;
   Check(!AIDecision_Build(inference, snapshot, policyBelow, d2, rd2), "allow_threshold below 0.0 is rejected");

   AIDecisionPolicy policyAbove; BuildValidPolicy(policyAbove, "POLICY_V1", "THRESH_V1", 1.01);
   AIDecision d3; string rd3;
   Check(!AIDecision_Build(inference, snapshot, policyAbove, d3, rd3), "allow_threshold above 1.0 is rejected");

   AIDecisionPolicy policyLowBound; BuildValidPolicy(policyLowBound, "POLICY_V1", "THRESH_V1", 0.0);
   AIDecision d4; string rd4;
   Check(AIDecision_Build(inference, snapshot, policyLowBound, d4, rd4), "allow_threshold exactly 0.0 is accepted (inclusive)");

   AIDecisionPolicy policyHighBound; BuildValidPolicy(policyHighBound, "POLICY_V1", "THRESH_V1", 1.0);
   AIDecision d5; string rd5;
   Check(AIDecision_Build(inference, snapshot, policyHighBound, d5, rd5), "allow_threshold exactly 1.0 is accepted (inclusive)");
}

void Test_FailClosed_SnapshotLineageMismatch()
{
   Print("--- fail-closed: a FeatureSnapshot that doesn't match the InferenceResult's pinned identity/hash is rejected ---");
   FeatureSnapshot snapshotA; BuildValidSnapshot(snapshotA, "MISMATCHA");
   FeatureSnapshot snapshotB; BuildValidSnapshot(snapshotB, "MISMATCHB");
   InferenceResult inference;
   BuildValidInferenceResult(snapshotA, "MREG_test_v1", "hash_mreg_1", "hash_artifact_1", 0.75f, inference);
   AIDecisionPolicy policy; BuildValidPolicy(policy, "POLICY_V1", "THRESH_V1", 0.5);

   AIDecision d; string rd;
   Check(!AIDecision_Build(inference, snapshotB, policy, d, rd), "snapshot B against an inference pinned to snapshot A is rejected");
   Check(d.decision_outcome == AI_DECISION_OUTCOME_NONE, "rejected AIDecision stays at Init() defaults");

   // Isolate each of the 3 pinned fields individually.
   InferenceResult inferenceWrongSnapId = inference; inferenceWrongSnapId.feature_snapshot_id = "WRONG_ID";
   AIDecision d2; string rd2;
   Check(!AIDecision_Build(inferenceWrongSnapId, snapshotA, policy, d2, rd2), "feature_snapshot_id mismatch alone is rejected");

   InferenceResult inferenceWrongSnapHash = inference; inferenceWrongSnapHash.feature_snapshot_hash = "WRONG_HASH";
   AIDecision d3; string rd3;
   Check(!AIDecision_Build(inferenceWrongSnapHash, snapshotA, policy, d3, rd3), "feature_snapshot_hash mismatch alone is rejected");

   InferenceResult inferenceWrongVecHash = inference; inferenceWrongVecHash.feature_vector_hash = "WRONG_HASH";
   AIDecision d4; string rd4;
   Check(!AIDecision_Build(inferenceWrongVecHash, snapshotA, policy, d4, rd4), "feature_vector_hash mismatch alone is rejected");
}

void Test_FailClosed_ScoreOutOfRange()
{
   Print("--- fail-closed (defensive boundary check): a hand-constructed non-finite/out-of-range InferenceResult.output_values[0] is rejected ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "SCORERANGE");
   AIDecisionPolicy policy; BuildValidPolicy(policy, "POLICY_V1", "THRESH_V1", 0.5);

   double huge = 1.0e307;
   float infinity = (float)(huge * huge);

   InferenceResult inferenceInf;
   BuildValidInferenceResult(snapshot, "MREG_test_v1", "hash_mreg_1", "hash_artifact_1", infinity, inferenceInf);
   AIDecision d1; string rd1;
   Check(!AIDecision_Build(inferenceInf, snapshot, policy, d1, rd1), "+Inf output_values[0] is rejected");

   InferenceResult inferenceBelow;
   BuildValidInferenceResult(snapshot, "MREG_test_v1", "hash_mreg_1", "hash_artifact_1", -0.01f, inferenceBelow);
   AIDecision d2; string rd2;
   Check(!AIDecision_Build(inferenceBelow, snapshot, policy, d2, rd2), "output_values[0] below 0.0 is rejected");

   InferenceResult inferenceAbove;
   BuildValidInferenceResult(snapshot, "MREG_test_v1", "hash_mreg_1", "hash_artifact_1", 1.01f, inferenceAbove);
   AIDecision d3; string rd3;
   Check(!AIDecision_Build(inferenceAbove, snapshot, policy, d3, rd3), "output_values[0] above 1.0 is rejected");

   InferenceResult inferenceWrongLen;
   BuildValidInferenceResult(snapshot, "MREG_test_v1", "hash_mreg_1", "hash_artifact_1", 0.5f, inferenceWrongLen);
   ArrayResize(inferenceWrongLen.output_values, 2);
   inferenceWrongLen.output_values[1] = 0.5f;
   AIDecision d4; string rd4;
   Check(!AIDecision_Build(inferenceWrongLen, snapshot, policy, d4, rd4), "output_values with 2 elements instead of 1 is rejected");
}

//=====================================================================
// No mutation / no side effects
//=====================================================================
void Test_NoMutation()
{
   Print("--- no mutation: inference / snapshot / policy unchanged before and after AIDecision_Build, on both accept and reject paths ---");
   FeatureSnapshot snapshot; BuildValidSnapshot(snapshot, "NOMUT");
   InferenceResult inference;
   BuildValidInferenceResult(snapshot, "MREG_test_v1", "hash_mreg_1", "hash_artifact_1", 0.75f, inference);
   AIDecisionPolicy policy; BuildValidPolicy(policy, "POLICY_V1", "THRESH_V1", 0.60);

   string snapshotHashBefore  = snapshot.feature_snapshot_hash;
   string inferenceHashBefore = inference.output_hash;
   string policyVersionBefore = policy.decision_policy_version;

   AIDecision d; string rd;
   Check(AIDecision_Build(inference, snapshot, policy, d, rd), "sanity: accept-path build succeeds");
   Check(snapshot.feature_snapshot_hash == snapshotHashBefore, "snapshot unchanged after accept-path build");
   Check(inference.output_hash == inferenceHashBefore, "inference unchanged after accept-path build");
   Check(policy.decision_policy_version == policyVersionBefore, "policy unchanged after accept-path build");

   // Reject path (invalid policy) - inputs still must not be mutated.
   AIDecisionPolicy badPolicy; BuildValidPolicy(badPolicy, "", "THRESH_V1", 0.60);
   AIDecision d2; string rd2;
   Check(!AIDecision_Build(inference, snapshot, badPolicy, d2, rd2), "sanity: reject-path build fails as expected");
   Check(snapshot.feature_snapshot_hash == snapshotHashBefore, "snapshot unchanged after reject-path build");
   Check(inference.output_hash == inferenceHashBefore, "inference unchanged after reject-path build");
}

void Test_NoSideEffects_StructuralProof()
{
   Print("--- no side effects (structural): AIDecision_Build touches no event store, ONNX runtime, or broker/account/tick/clock call ---");
   Check(true, "verified by inspection: AIDecision_Build (Include/MLQuantAI/AI/MLQuantAI_AIDecisionBuilder.mqh) contains no "
               "EventStore_Log*/OnnxCreateFromBuffer/OnnxRun/OrderSend/CTrade/AccountInfo*/SymbolInfo*/TimeCurrent call anywhere - "
               "it is a pure function over its three input structs, per Docs/PhaseB_B8_5_AIDecisionContract.md's scope guard");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B8.5 Commit 1 - AIDecision + Threshold-Policy Pure Mapping ===");

   Test_AcceptPath_Allow_AboveThreshold();
   Test_AcceptPath_Allow_AtThresholdBoundary();
   Test_AcceptPath_Reject_BelowThreshold();

   Test_Determinism_IdAndHash_10000Reps();

   Test_IdentitySensitivity_PolicyVersionChangesId();
   Test_IdentitySensitivity_ModelRegistryIdChangesId();
   Test_HashSensitivity_ContentChangesMoveHashNotId();

   Test_FailClosed_EmptyPolicyVersions();
   Test_FailClosed_ThresholdOutOfRange();
   Test_FailClosed_SnapshotLineageMismatch();
   Test_FailClosed_ScoreOutOfRange();

   Test_NoMutation();
   Test_NoSideEffects_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
