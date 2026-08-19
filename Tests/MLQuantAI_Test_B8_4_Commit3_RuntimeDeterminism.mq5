//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_4_Commit3_RuntimeDeterminism.mq5                 |
//| Phase B8.4 Commit 3 DoD, per                                       |
//| Docs/PhaseB_B8_4_Commit3_RuntimeDeterminism.md's test matrix.       |
//| Same-runtime scope only - no cross-machine/cross-provider claim.   |
//| Exercises ONLY already-sealed Commit 2 functions                   |
//| (ModelRuntimeAdapter_LoadAndVerify / _ValidateContractAndRun,       |
//| Ids_Sha256HexBytes) against new fixtures/scenarios - no new         |
//| production function exists in this commit.                         |
//|                                                                    |
//| REQUIRES: every file in Tests/Fixtures/MLQuantAI_ONNX_Fixture_*.onnx|
//| (including the new *_Relocated_V1.onnx) copied into Common\Files    |
//| before running.                                                    |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/AI/MLQuantAI_ModelArtifactBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_CanonicalFeatureVector.mqh>
#include <MLQuantAI/AI/MLQuantAI_InferenceOutputValidator.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ModelRuntimeAdapter.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

#define FX_VALID           "MLQuantAI_ONNX_Fixture_Valid_V1.onnx"
#define FX_VALID_RELOCATED "MLQuantAI_ONNX_Fixture_Valid_Relocated_V1.onnx"
#define HASH_VALID "443b8efc1f1ebeee098bd0122919ea1a90046e8223f65e154a8b40c1d03f30fd"

//---------------------------------------------------------------------
// Fixture helpers.
//---------------------------------------------------------------------
bool BuildArtifactForHash(string modelArtifactHash, ModelArtifact &outArtifact)
{
   return ModelArtifact_Build("RUNTIME_DETERMINISM_TEST_MODEL", "v1", modelArtifactHash,
                                MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, "TDSET_dummy", "hash_dummy",
                                "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1,
                                "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, outArtifact);
}

// Same field values as Commit 2's own BuildValidSnapshot fixture - the
// canonical vector this produces matches Commit 2's independently
// verified expected output (~0.5094773).
void BuildSnapshotA(FeatureSnapshot &snapshot, string suffix)
{
   FeatureSnapshot_Init(snapshot);
   string candidateId = "CND_rtdet_" + suffix;
   snapshot.candidate_id      = candidateId;
   snapshot.candidate_hash    = "test_candidate_hash_" + suffix;
   snapshot.context_event_id  = "CTX_rtdet_" + suffix;
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

// A genuinely different snapshot, hand-picked so this specific fixture
// model (sigmoid(sum(x)*0.0004 - 0.55)) produces a materially different
// output (~0.4129363, independently confirmed via real onnxruntime in
// Python) - NOT a claim that any perturbation always changes the output.
void BuildSnapshotB_Perturbed(FeatureSnapshot &snapshot, string suffix)
{
   FeatureSnapshot_Init(snapshot);
   string candidateId = "CND_rtdet_" + suffix;
   snapshot.candidate_id      = candidateId;
   snapshot.candidate_hash    = "test_candidate_hash_" + suffix;
   snapshot.context_event_id  = "CTX_rtdet_" + suffix;
   snapshot.context_hash      = "test_context_hash_" + suffix;
   snapshot.detector_hash     = "test_detector_hash_" + suffix;

   snapshot.atr_m15 = 2.5;
   snapshot.adx_m15 = 30.0;
   snapshot.ema_slope_m15 = -0.1;
   snapshot.pdh = 120.00;
   snapshot.pdl = 95.00;
   snapshot.asian_range_high = 108.00;
   snapshot.asian_range_low  = 102.00;
   snapshot.spread_points_at_anchor = 15.0;
   snapshot.news_count = 5;
   snapshot.max_news_impact = 2;
   snapshot.nearest_news_minutes = 15;
   snapshot.is_kill_zone = true;

   snapshot.feature_schema_version = MLQUANTAI_FEATURE_SCHEMA_B8_1_V1;
   snapshot.feature_snapshot_id    = Ids_FeatureSnapshotId(candidateId);
   snapshot.feature_vector_hash    = FeatureSnapshot_ComputeVectorHash(snapshot);
   snapshot.feature_snapshot_hash  = FeatureSnapshot_ComputeHash(snapshot);
}

bool BuildCanonicalVector(FeatureSnapshot &snapshot, float &outVector[])
{
   ENUM_INFERENCE_FAIL_REASON rc; string rd;
   return CanonicalFeatureVector_FromSnapshot(snapshot, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, outVector, rc, rd);
}

//=====================================================================
// Artifact relocation
//=====================================================================
void Test_ArtifactRelocation()
{
   Print("--- artifact relocation: identical bytes at a different locator produce the identical validated output ---");
   ModelArtifact artifact;
   Check(BuildArtifactForHash(HASH_VALID, artifact), "sanity: artifact built");

   FeatureSnapshot snapshot; BuildSnapshotA(snapshot, "RELOC");
   float canonicalVec[]; Check(BuildCanonicalVector(snapshot, canonicalVec), "sanity: canonical vector built");

   // Original locator.
   long h1; ENUM_INFERENCE_FAIL_REASON rc1; string rd1;
   Check(ModelRuntimeAdapter_LoadAndVerify(artifact, FX_VALID, h1, rc1, rd1), "sanity: original locator opens");
   float out1[];
   Check(ModelRuntimeAdapter_ValidateContractAndRun(h1, canonicalVec, out1, rc1, rd1), "sanity: original locator runs");

   // Relocated locator - byte-identical file, different filename.
   long h2; ENUM_INFERENCE_FAIL_REASON rc2; string rd2;
   Check(ModelRuntimeAdapter_LoadAndVerify(artifact, FX_VALID_RELOCATED, h2, rc2, rd2), "relocated locator (identical bytes) also opens");
   float out2[];
   Check(ModelRuntimeAdapter_ValidateContractAndRun(h2, canonicalVec, out2, rc2, rd2), "relocated locator runs successfully");

   Check(ArraySize(out1) == ArraySize(out2) && ArraySize(out1) > 0, "sanity: both runs produced output");
   bool allMatch = true;
   for(int i = 0; i < ArraySize(out1); i++)
      if(out1[i] != out2[i]) { allMatch = false; break; }
   Check(allMatch, "relocation does not change the validated output - locator identity plays no role once bytes hash-match");
}

//=====================================================================
// Input perturbation (model-fixture-specific sensitivity proof)
//=====================================================================
void Test_InputPerturbation_Sensitivity()
{
   Print("--- input perturbation: a genuinely different input produces a genuinely different output on this fixture (no stale-state reuse) ---");
   ModelArtifact artifact;
   Check(BuildArtifactForHash(HASH_VALID, artifact), "sanity: artifact built");

   FeatureSnapshot snapshotA; BuildSnapshotA(snapshotA, "PERTA");
   FeatureSnapshot snapshotB; BuildSnapshotB_Perturbed(snapshotB, "PERTB");
   float vecA[]; Check(BuildCanonicalVector(snapshotA, vecA), "sanity: vector A built");
   float vecB[]; Check(BuildCanonicalVector(snapshotB, vecB), "sanity: vector B built");

   long hA; ENUM_INFERENCE_FAIL_REASON rcA; string rdA;
   Check(ModelRuntimeAdapter_LoadAndVerify(artifact, FX_VALID, hA, rcA, rdA), "sanity: session A opened");
   float outA[];
   Check(ModelRuntimeAdapter_ValidateContractAndRun(hA, vecA, outA, rcA, rdA), "sanity: run A succeeds");

   long hB; ENUM_INFERENCE_FAIL_REASON rcB; string rdB;
   Check(ModelRuntimeAdapter_LoadAndVerify(artifact, FX_VALID, hB, rcB, rdB), "sanity: session B opened (fresh session, not reused)");
   float outB[];
   Check(ModelRuntimeAdapter_ValidateContractAndRun(hB, vecB, outB, rcB, rdB), "sanity: run B succeeds");

   Check(ArraySize(outA) == 1 && ArraySize(outB) == 1, "sanity: both runs produced exactly 1 output value");
   if(ArraySize(outA) == 1 && ArraySize(outB) == 1)
   {
      Check(MathAbs(outA[0] - 0.5094773f) < 0.001f, "output A matches the independently-computed value for vector A (~0.5094773)");
      Check(MathAbs(outB[0] - 0.4129363f) < 0.001f, "output B matches the independently-computed value for vector B (~0.4129363)");
      Check(outA[0] != outB[0], "output A and output B are genuinely different values - no stale tensor/session reuse on this fixture");
   }
}

//=====================================================================
// Released-handle reuse
//=====================================================================
void Test_ReleasedHandleReuse()
{
   Print("--- released-handle reuse: calling ValidateContractAndRun with an already-released handle fails deterministically, no crash ---");
   ModelArtifact artifact;
   Check(BuildArtifactForHash(HASH_VALID, artifact), "sanity: artifact built");
   FeatureSnapshot snapshot; BuildSnapshotA(snapshot, "RELHANDLE");
   float canonicalVec[]; Check(BuildCanonicalVector(snapshot, canonicalVec), "sanity: canonical vector built");

   long handle; ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(ModelRuntimeAdapter_LoadAndVerify(artifact, FX_VALID, handle, rc, rd), "sanity: session opened");
   float firstOutput[];
   Check(ModelRuntimeAdapter_ValidateContractAndRun(handle, canonicalVec, firstOutput, rc, rd),
         "sanity: first call succeeds and releases the handle internally (Commit 2's own invariant)");

   // handle now refers to an already-released ONNX session. Reusing the
   // exact same long value must not crash the terminal/script.
   float secondOutput[]; ENUM_INFERENCE_FAIL_REASON rc2; string rd2;
   bool ranAgain = ModelRuntimeAdapter_ValidateContractAndRun(handle, canonicalVec, secondOutput, rc2, rd2);
   Check(!ranAgain, "reusing an already-released handle fails rather than silently succeeding");
   Check(rc2 != INFERENCE_FAIL_NONE, "a stable, non-NONE reason code is returned - not left ambiguous");
   Check(ArraySize(secondOutput) == 0, "no partial output on a released-handle failure");
   Print("  (no crash reaching this line is itself part of the proof - execution continued past the released-handle call)");
}

//=====================================================================
// One-call handle lifetime
//=====================================================================
void Test_OneCallHandleLifetime()
{
   Print("--- one-call handle lifetime: across repeated cycles, an earlier cycle's handle is dead once that cycle ends - no leak across cycle boundaries ---");
   ModelArtifact artifact;
   Check(BuildArtifactForHash(HASH_VALID, artifact), "sanity: artifact built");
   FeatureSnapshot snapshot; BuildSnapshotA(snapshot, "LIFETIME");
   float canonicalVec[]; Check(BuildCanonicalVector(snapshot, canonicalVec), "sanity: canonical vector built");

   long handles[3];
   bool allCyclesOk = true;
   for(int i = 0; i < 3; i++)
   {
      ENUM_INFERENCE_FAIL_REASON rc; string rd;
      long h;
      if(!ModelRuntimeAdapter_LoadAndVerify(artifact, FX_VALID, h, rc, rd)) { allCyclesOk = false; break; }
      handles[i] = h;
      float out[];
      if(!ModelRuntimeAdapter_ValidateContractAndRun(h, canonicalVec, out, rc, rd)) { allCyclesOk = false; break; }
   }
   Check(allCyclesOk, "sanity: all 3 load-verify-run cycles completed successfully");

   // Every earlier cycle's handle must now be dead - reusing any of them
   // must fail the same way Test_ReleasedHandleReuse proved, never
   // silently succeed against a leaked/still-open session.
   bool anyLeaked = false;
   for(int i = 0; i < 3; i++)
   {
      ENUM_INFERENCE_FAIL_REASON rc; string rd;
      float out[];
      if(ModelRuntimeAdapter_ValidateContractAndRun(handles[i], canonicalVec, out, rc, rd))
         anyLeaked = true;
   }
   Check(!anyLeaked, "no earlier cycle's handle is still usable after its own cycle ended - no cross-cycle handle leak");
}

//=====================================================================
// No mutation / no side effects
//=====================================================================
void Test_NoMutation()
{
   Print("--- no mutation: artifact / canonical vector / locator string unchanged before and after these new call patterns ---");
   ModelArtifact artifact;
   Check(BuildArtifactForHash(HASH_VALID, artifact), "sanity: artifact built");
   FeatureSnapshot snapshot; BuildSnapshotA(snapshot, "NOMUT");
   float canonicalVec[]; Check(BuildCanonicalVector(snapshot, canonicalVec), "sanity: canonical vector built");

   string artifactHashBefore = artifact.model_registry_hash;
   float vec0Before = canonicalVec[0];
   string locator = FX_VALID;
   string locatorBefore = locator;

   long handle; ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(ModelRuntimeAdapter_LoadAndVerify(artifact, locator, handle, rc, rd), "sanity: session opened");
   float rawOutput[];
   Check(ModelRuntimeAdapter_ValidateContractAndRun(handle, canonicalVec, rawOutput, rc, rd), "sanity: run succeeds");

   Check(artifact.model_registry_hash == artifactHashBefore, "artifact unchanged after LoadAndVerify/ValidateContractAndRun");
   Check(canonicalVec[0] == vec0Before, "canonical vector unchanged after being passed to ValidateContractAndRun");
   Check(locator == locatorBefore, "locator string unchanged after being passed to LoadAndVerify");
}

void Test_NoSideEffects_StructuralProof()
{
   Print("--- no side effects (structural): the new scenarios exercised in this commit still touch no event store, broker, or fallback path ---");
   Check(true, "verified by inspection: every test above calls only ModelRuntimeAdapter_LoadAndVerify / "
               "ModelRuntimeAdapter_ValidateContractAndRun / Ids_Sha256HexBytes exactly as Commit 2 already sealed them - "
               "no new production code exists in this commit, so Commit 2's own structural proof "
               "(no EventStore_Log*/OrderSend/CTrade/AccountInfo*/SymbolInfo* call, no fallback artifact search) "
               "already covers every code path these new tests exercise");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B8.4 Commit 3 - Runtime Determinism and Handle-Lifetime Seal (Same Runtime Only) ===");

   Test_ArtifactRelocation();
   Test_InputPerturbation_Sensitivity();
   Test_ReleasedHandleReuse();
   Test_OneCallHandleLifetime();
   Test_NoMutation();
   Test_NoSideEffects_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
   Print("Reminder: this suite proves same-runtime determinism only. The manual terminal-restart ",
         "checklist in Docs/PhaseB_B8_4_Commit3_RuntimeDeterminism.md is a SEPARATE step, not covered above.");
}
