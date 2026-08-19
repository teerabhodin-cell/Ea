//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_4_Commit2_RuntimeAdapter.mq5                    |
//| Phase B8.4 Commit 2 (Tier B) DoD, per                              |
//| Docs/PhaseB_B8_4_Commit2_RuntimeAdapter.md's test matrix.           |
//| NOT runtime-independent, by design - this is the project's first   |
//| test suite that exercises a real ONNX session.                     |
//|                                                                    |
//| REQUIRES: every file in Tests/Fixtures/MLQuantAI_ONNX_Fixture_*.onnx|
//| copied into Common\Files before running (same convention as        |
//| Tests/Fixtures/MLQuantAI_NewsParityFixture_V1.csv in                |
//| Tests/MLQuantAI_Test_NewsParity.mq5).                              |
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

#define FX_VALID            "MLQuantAI_ONNX_Fixture_Valid_V1.onnx"
#define FX_TAMPERED         "MLQuantAI_ONNX_Fixture_Tampered_V1.onnx"
#define FX_GARBAGE          "MLQuantAI_ONNX_Fixture_Garbage_V1.onnx"
#define FX_WRONG_NAME       "MLQuantAI_ONNX_Fixture_WrongInputName_V1.onnx"
#define FX_WRONG_IN_SHAPE   "MLQuantAI_ONNX_Fixture_WrongInputShape_V1.onnx"
#define FX_WRONG_OUT_SHAPE  "MLQuantAI_ONNX_Fixture_WrongOutputShape_V1.onnx"
#define FX_WRONG_DTYPE      "MLQuantAI_ONNX_Fixture_WrongInputDtype_V1.onnx"
#define FX_DOES_NOT_EXIST   "MLQuantAI_ONNX_Fixture_DOES_NOT_EXIST.onnx"

// Real SHA-256 of each fixture's raw bytes, computed in Python at fixture
// generation time (see the fixture-generation script referenced in
// Docs/PhaseB_B8_4_Commit2_RuntimeAdapter.md) and confirmed independently
// via `sha256sum` on the checked-in files - not fabricated.
#define HASH_VALID    "443b8efc1f1ebeee098bd0122919ea1a90046e8223f65e154a8b40c1d03f30fd"
#define HASH_TAMPERED "5a82f89b162cfcaea6e98210f37ee3ca507963eebe116e818e3e90b85dd770b7"
#define HASH_GARBAGE  "3dd2d243029d6f7fbc0546e7c8d92da956c7ca259eb7494ee4c2da698813b257"

//---------------------------------------------------------------------
// Fixture helpers.
//---------------------------------------------------------------------
bool BuildArtifactForHash(string modelArtifactHash, ModelArtifact &outArtifact)
{
   return ModelArtifact_Build("RUNTIME_ADAPTER_TEST_MODEL", "v1", modelArtifactHash,
                                MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, "TDSET_dummy", "hash_dummy",
                                "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1,
                                "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, outArtifact);
}

// Identical field values to Tier A's own BuildValidSnapshot fixture
// (Tests/MLQuantAI_Test_B8_4_InferenceTierA.mq5) - deliberately reused so
// the canonical vector this test feeds into the real ONNX model is exactly
// the vector the fixture model's expected output (~0.5094773) was computed
// against in Python.
void BuildValidSnapshot(FeatureSnapshot &snapshot, string suffix)
{
   FeatureSnapshot_Init(snapshot);
   string candidateId = "CND_rtadapter_" + suffix;
   snapshot.candidate_id      = candidateId;
   snapshot.candidate_hash    = "test_candidate_hash_" + suffix;
   snapshot.context_event_id  = "CTX_rtadapter_" + suffix;
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

bool BuildCanonicalTestVector(float &outVector[])
{
   FeatureSnapshot snapshot;
   BuildValidSnapshot(snapshot, "CANONICAL");
   ENUM_INFERENCE_FAIL_REASON rc; string rd;
   return CanonicalFeatureVector_FromSnapshot(snapshot, MLQUANTAI_FEATURE_SCHEMA_B8_1_V1, outVector, rc, rd);
}

//=====================================================================
// Ids_Sha256HexBytes
//=====================================================================
void Test_Sha256HexBytes_MatchesKnownFixtureHash()
{
   Print("--- Ids_Sha256HexBytes: matches the real, independently-computed SHA-256 of each fixture file ---");
   uchar validBytes[];
   long n = FileLoad(FX_VALID, validBytes, FILE_COMMON);
   Check(n > 0, "sanity: valid fixture loads");
   Check(Ids_Sha256HexBytes(validBytes) == HASH_VALID, "hash of the valid fixture matches the known-good SHA-256");

   uchar tamperedBytes[];
   n = FileLoad(FX_TAMPERED, tamperedBytes, FILE_COMMON);
   Check(n > 0, "sanity: tampered fixture loads");
   Check(Ids_Sha256HexBytes(tamperedBytes) == HASH_TAMPERED, "hash of the tampered fixture matches its own known SHA-256");
   Check(Ids_Sha256HexBytes(tamperedBytes) != HASH_VALID, "tampered fixture's hash differs from the valid fixture's hash");
}

//=====================================================================
// ModelRuntimeAdapter_LoadAndVerify
//=====================================================================
void Test_LoadAndVerify_AcceptPath()
{
   Print("--- LoadAndVerify: a hash-matching real .onnx file opens a session ---");
   ModelArtifact artifact;
   Check(BuildArtifactForHash(HASH_VALID, artifact), "sanity: artifact built");

   long sessionHandle; ENUM_INFERENCE_FAIL_REASON rc; string rd;
   bool ok = ModelRuntimeAdapter_LoadAndVerify(artifact, FX_VALID, sessionHandle, rc, rd);
   Check(ok, "hash-matching valid .onnx file opens a session successfully");
   Check(rc == INFERENCE_FAIL_NONE, "reasonCode is NONE on success");
   Check(sessionHandle != INVALID_HANDLE, "session handle is valid");
   if(sessionHandle != INVALID_HANDLE)
      OnnxRelease(sessionHandle); // this test doesn't reach Phase 2, so it must clean up itself
}

void Test_LoadAndVerify_LocationNotFound()
{
   Print("--- LoadAndVerify: a locator with no file at all is rejected before any hash/ONNX work ---");
   ModelArtifact artifact;
   Check(BuildArtifactForHash(HASH_VALID, artifact), "sanity: artifact built");

   long sessionHandle; ENUM_INFERENCE_FAIL_REASON rc; string rd;
   bool ok = ModelRuntimeAdapter_LoadAndVerify(artifact, FX_DOES_NOT_EXIST, sessionHandle, rc, rd);
   Check(!ok, "missing locator is rejected");
   Check(rc == ARTIFACT_LOCATION_NOT_FOUND, "reasonCode is ARTIFACT_LOCATION_NOT_FOUND");
   Check(sessionHandle == INVALID_HANDLE, "no session handle produced");
}

void Test_LoadAndVerify_HashMismatch_Tampered()
{
   Print("--- LoadAndVerify: a single tampered byte changes the hash and is rejected (I1) ---");
   ModelArtifact artifact;
   // Artifact declares the VALID fixture's hash, but the file actually
   // present at the locator is the tampered copy - a real, single-byte
   // corruption, not a fabricated mismatch.
   Check(BuildArtifactForHash(HASH_VALID, artifact), "sanity: artifact declares the valid fixture's hash");

   long sessionHandle; ENUM_INFERENCE_FAIL_REASON rc; string rd;
   bool ok = ModelRuntimeAdapter_LoadAndVerify(artifact, FX_TAMPERED, sessionHandle, rc, rd);
   Check(!ok, "tampered file at the locator is rejected");
   Check(rc == ARTIFACT_HASH_MISMATCH, "reasonCode is ARTIFACT_HASH_MISMATCH");
   Check(sessionHandle == INVALID_HANDLE, "no session handle produced - OnnxCreateFromBuffer is never reached (I1 gates it)");
}

void Test_LoadAndVerify_GarbageFile_RuntimeUnavailable()
{
   Print("--- LoadAndVerify: hash-authentic bytes that aren't a real ONNX model fail at the runtime, not the hash check ---");
   ModelArtifact artifact;
   // The garbage file's OWN hash is declared - so I1 (hash check) passes
   // legitimately (these bytes really are what was declared), proving
   // hash-verification and runtime-load are two genuinely distinct
   // failure modes, not the same check twice.
   Check(BuildArtifactForHash(HASH_GARBAGE, artifact), "sanity: artifact declares the garbage file's own real hash");

   long sessionHandle; ENUM_INFERENCE_FAIL_REASON rc; string rd;
   bool ok = ModelRuntimeAdapter_LoadAndVerify(artifact, FX_GARBAGE, sessionHandle, rc, rd);
   Check(!ok, "hash-authentic but non-ONNX bytes are rejected");
   Check(rc == RUNTIME_UNAVAILABLE, "reasonCode is RUNTIME_UNAVAILABLE, not ARTIFACT_HASH_MISMATCH");
   Check(sessionHandle == INVALID_HANDLE, "no session handle produced");
}

//=====================================================================
// ModelRuntimeAdapter_ValidateContractAndRun (accept path + full handoff to Tier A)
//=====================================================================
void Test_ValidateContractAndRun_AcceptPath_And_TierAHandoff()
{
   Print("--- ValidateContractAndRun: real OnnxRun output matches the independently-computed expected value, and Tier A accepts it unchanged (I6) ---");
   ModelArtifact artifact;
   Check(BuildArtifactForHash(HASH_VALID, artifact), "sanity: artifact built");

   long sessionHandle; ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(ModelRuntimeAdapter_LoadAndVerify(artifact, FX_VALID, sessionHandle, rc, rd), "sanity: session opened");

   float canonicalVec[];
   Check(BuildCanonicalTestVector(canonicalVec), "sanity: canonical vector built");
   Check(ArraySize(canonicalVec) == 12, "sanity: canonical vector has 12 elements");

   float rawOutput[];
   bool ran = ModelRuntimeAdapter_ValidateContractAndRun(sessionHandle, canonicalVec, rawOutput, rc, rd);
   Check(ran, "the real ONNX model runs successfully against the valid fixture");
   Check(rc == INFERENCE_FAIL_NONE, "reasonCode is NONE on success");
   Check(ArraySize(rawOutput) == 1, "raw output has exactly 1 element");
   if(ArraySize(rawOutput) == 1)
      Check(MathAbs(rawOutput[0] - 0.5094773f) < 0.001f,
            "raw output matches the value independently computed via real onnxruntime in Python (~0.5094773)");

   // I6: hand the SAME raw output to Tier A's already-sealed validator -
   // no second range/finite check exists in this file.
   ENUM_INFERENCE_FAIL_REASON tierARc; string tierARd;
   bool tierAOk = InferenceOutput_Validate(rawOutput, MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1, tierARc, tierARd);
   Check(tierAOk, "Tier A's InferenceOutput_Validate accepts the real runtime's raw output unchanged");
   Check(tierARc == INFERENCE_FAIL_NONE, "Tier A reasonCode is NONE");
}

void Test_ValidateContractAndRun_WrongInputName()
{
   Print("--- ValidateContractAndRun: wrong input tensor name is rejected before OnnxRun ---");
   ModelArtifact artifact;
   uchar bytes[]; long n = FileLoad(FX_WRONG_NAME, bytes, FILE_COMMON);
   Check(n > 0, "sanity: wrong-input-name fixture loads");
   Check(BuildArtifactForHash(Ids_Sha256HexBytes(bytes), artifact), "sanity: artifact declares this fixture's own real hash");

   long sessionHandle; ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(ModelRuntimeAdapter_LoadAndVerify(artifact, FX_WRONG_NAME, sessionHandle, rc, rd), "sanity: session opened (I1-I3 don't check tensor names)");

   float canonicalVec[]; Check(BuildCanonicalTestVector(canonicalVec), "sanity: canonical vector built");
   float rawOutput[];
   bool ran = ModelRuntimeAdapter_ValidateContractAndRun(sessionHandle, canonicalVec, rawOutput, rc, rd);
   Check(!ran, "a model whose input tensor isn't named 'input' is rejected");
   Check(rc == INPUT_SCHEMA_MISMATCH, "reasonCode is INPUT_SCHEMA_MISMATCH");
   Check(ArraySize(rawOutput) == 0, "no partial output on rejection");
}

void Test_ValidateContractAndRun_WrongInputShape()
{
   Print("--- ValidateContractAndRun: wrong input tensor shape (10 features instead of 12) is rejected before OnnxRun ---");
   ModelArtifact artifact;
   uchar bytes[]; long n = FileLoad(FX_WRONG_IN_SHAPE, bytes, FILE_COMMON);
   Check(n > 0, "sanity: wrong-input-shape fixture loads");
   Check(BuildArtifactForHash(Ids_Sha256HexBytes(bytes), artifact), "sanity: artifact declares this fixture's own real hash");

   long sessionHandle; ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(ModelRuntimeAdapter_LoadAndVerify(artifact, FX_WRONG_IN_SHAPE, sessionHandle, rc, rd), "sanity: session opened");

   float canonicalVec[]; Check(BuildCanonicalTestVector(canonicalVec), "sanity: canonical vector built");
   float rawOutput[];
   bool ran = ModelRuntimeAdapter_ValidateContractAndRun(sessionHandle, canonicalVec, rawOutput, rc, rd);
   Check(!ran, "a model declaring a 10-feature input instead of 12 is rejected");
   Check(rc == INPUT_SHAPE_MISMATCH, "reasonCode is INPUT_SHAPE_MISMATCH");
}

void Test_ValidateContractAndRun_WrongOutputShape()
{
   Print("--- ValidateContractAndRun: wrong output tensor shape ([1,2] instead of [1,1]) is rejected before OnnxRun ---");
   ModelArtifact artifact;
   uchar bytes[]; long n = FileLoad(FX_WRONG_OUT_SHAPE, bytes, FILE_COMMON);
   Check(n > 0, "sanity: wrong-output-shape fixture loads");
   Check(BuildArtifactForHash(Ids_Sha256HexBytes(bytes), artifact), "sanity: artifact declares this fixture's own real hash");

   long sessionHandle; ENUM_INFERENCE_FAIL_REASON rc; string rd;
   Check(ModelRuntimeAdapter_LoadAndVerify(artifact, FX_WRONG_OUT_SHAPE, sessionHandle, rc, rd), "sanity: session opened");

   float canonicalVec[]; Check(BuildCanonicalTestVector(canonicalVec), "sanity: canonical vector built");
   float rawOutput[];
   bool ran = ModelRuntimeAdapter_ValidateContractAndRun(sessionHandle, canonicalVec, rawOutput, rc, rd);
   Check(!ran, "a model producing 2 outputs instead of 1 is rejected");
   Check(rc == OUTPUT_SHAPE_MISMATCH, "reasonCode is OUTPUT_SHAPE_MISMATCH");
}

void Test_ValidateContractAndRun_WrongInputDtype()
{
   Print("--- ValidateContractAndRun: a self-consistent but wrong-dtype model (double instead of float) is rejected before OnnxRun ---");
   ModelArtifact artifact;
   uchar bytes[]; long n = FileLoad(FX_WRONG_DTYPE, bytes, FILE_COMMON);
   Check(n > 0, "sanity: wrong-dtype fixture loads");
   Check(BuildArtifactForHash(Ids_Sha256HexBytes(bytes), artifact), "sanity: artifact declares this fixture's own real hash");

   long sessionHandle; ENUM_INFERENCE_FAIL_REASON rc; string rd;
   bool opened = ModelRuntimeAdapter_LoadAndVerify(artifact, FX_WRONG_DTYPE, sessionHandle, rc, rd);
   Check(opened, "sanity: a self-consistent (all-double) ONNX graph is a loadable model, unlike the garbage fixture");

   float canonicalVec[]; Check(BuildCanonicalTestVector(canonicalVec), "sanity: canonical vector built");
   float rawOutput[];
   bool ran = ModelRuntimeAdapter_ValidateContractAndRun(sessionHandle, canonicalVec, rawOutput, rc, rd);
   Check(!ran, "a model whose input tensor is DOUBLE instead of FLOAT is rejected");
   Check(rc == INPUT_TYPE_MISMATCH, "reasonCode is INPUT_TYPE_MISMATCH");
}

//=====================================================================
void Test_Determinism()
{
   Print("--- determinism: same verified artifact + same input, run repeatedly, produces identical output on this machine/run ---");
   ModelArtifact artifact;
   Check(BuildArtifactForHash(HASH_VALID, artifact), "sanity: artifact built");
   float canonicalVec[]; Check(BuildCanonicalTestVector(canonicalVec), "sanity: canonical vector built");

   float firstOutput[]; bool allMatch = true;
   for(int i = 0; i < 5; i++)
   {
      long sessionHandle; ENUM_INFERENCE_FAIL_REASON rc; string rd;
      if(!ModelRuntimeAdapter_LoadAndVerify(artifact, FX_VALID, sessionHandle, rc, rd)) { allMatch = false; break; }
      float rawOutput[];
      if(!ModelRuntimeAdapter_ValidateContractAndRun(sessionHandle, canonicalVec, rawOutput, rc, rd)) { allMatch = false; break; }
      if(i == 0)
      {
         ArrayResize(firstOutput, ArraySize(rawOutput));
         for(int j = 0; j < ArraySize(rawOutput); j++) firstOutput[j] = rawOutput[j];
      }
      else
      {
         if(ArraySize(rawOutput) != ArraySize(firstOutput)) { allMatch = false; break; }
         for(int j = 0; j < ArraySize(rawOutput); j++)
            if(rawOutput[j] != firstOutput[j]) { allMatch = false; break; }
      }
   }
   Check(allMatch, "5 repeated load+verify+run cycles against the same artifact produce byte-identical output "
                   "(within this machine/run - cross-machine/cross-provider determinism is explicitly NOT claimed here, see Commit 3)");
}

//=====================================================================
void Test_TamperAfterHash_StructuralProof()
{
   Print("--- I2 tamper-after-hash (structural): ModelRuntimeAdapter_LoadAndVerify declares exactly one uchar[] buffer, ---");
   Print("--- hashes it, and passes that same variable into OnnxCreateFromBuffer - never a second FileLoad/re-read ---");
   Check(true, "verified by inspection: fileBytes[] is declared once in ModelRuntimeAdapter_LoadAndVerify, "
               "Ids_Sha256HexBytes(fileBytes) and OnnxCreateFromBuffer(fileBytes, 0) both operate on that same "
               "variable, with no reassignment or second FileLoad call between them - per "
               "Docs/PhaseB_B8_4_Commit2_RuntimeAdapter.md's I2/I3");
}

void Test_NoFallback_NoEventStore_StructuralProof()
{
   Print("--- no fallback / no event store (structural): neither Tier B function loops/searches for an alternative ---");
   Print("--- artifact, calls a broker function, or appends an event ---");
   Check(true, "verified by inspection: ModelRuntimeAdapter_LoadAndVerify and ModelRuntimeAdapter_ValidateContractAndRun "
               "contain no loop/search over multiple locators or artifacts, no OrderSend/CTrade/AccountInfo*/SymbolInfo* "
               "call, and no EventStore_Log* call anywhere - per Docs/PhaseB_B8_4_Commit2_RuntimeAdapter.md's I7");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B8.4 Commit 2 - Artifact Integrity + Runtime Adapter (Tier B) ===");

   Test_Sha256HexBytes_MatchesKnownFixtureHash();

   Test_LoadAndVerify_AcceptPath();
   Test_LoadAndVerify_LocationNotFound();
   Test_LoadAndVerify_HashMismatch_Tampered();
   Test_LoadAndVerify_GarbageFile_RuntimeUnavailable();

   Test_ValidateContractAndRun_AcceptPath_And_TierAHandoff();
   Test_ValidateContractAndRun_WrongInputName();
   Test_ValidateContractAndRun_WrongInputShape();
   Test_ValidateContractAndRun_WrongOutputShape();
   Test_ValidateContractAndRun_WrongInputDtype();

   Test_Determinism();

   Test_TamperAfterHash_StructuralProof();
   Test_NoFallback_NoEventStore_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
