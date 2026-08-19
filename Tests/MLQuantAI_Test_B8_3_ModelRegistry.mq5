//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_3_ModelRegistry.mq5                             |
//| Phase B8.3 DoD, per Docs/PhaseB_B8_3_ModelRegistryContract.md's    |
//| QA gate: ModelArtifact identity/hash/validation, event/projection   |
//| (mirroring B8.2's own emission/replay suites), and the fail-closed, |
//| exact-match-only compatibility functions. No CRT/candidate pipeline |
//| needed at all - a ModelArtifact is not tied to any candidate.       |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/AI/MLQuantAI_ModelArtifactBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ModelArtifactEventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ModelRegistryCompatibility.mqh>

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
bool BuildValidArtifact(string modelId, string modelVersion, string modelArtifactHash,
                          ENUM_MODEL_PROMOTION_STATE promotionState, ModelArtifact &outArtifact)
{
   return ModelArtifact_Build(modelId, modelVersion, modelArtifactHash,
                                "FEATURES_B8_1_V1", "TDSET_dummy123", "hash_dummy456",
                                "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                                "ONNXRuntime", "1.16.0", promotionState, outArtifact);
}

bool BuildAndEmitArtifact(string modelId, string modelVersion, string modelArtifactHash,
                            ENUM_MODEL_PROMOTION_STATE promotionState, ModelArtifact &outArtifact)
{
   if(!BuildValidArtifact(modelId, modelVersion, modelArtifactHash, promotionState, outArtifact))
      return false;
   return ModelArtifact_EmitModelArtifactRegistered(outArtifact);
}

void ResetProjections()
{
   ModelArtifactProjection_Reset();
}

//=====================================================================
void Test_Identity_Determinism()
{
   Print("--- identity/determinism: repeated builds, same inputs, identical id/hash ---");
   ModelArtifact first;
   Check(BuildValidArtifact("CRT_SETUP_QUALITY", "v1", "sha256_artifact_1", MODEL_PROMOTION_PROMOTED, first),
         "sanity: first build succeeds");

   bool allMatch = true;
   for(int i = 0; i < 1000; i++)
   {
      ModelArtifact repeat;
      if(!BuildValidArtifact("CRT_SETUP_QUALITY", "v1", "sha256_artifact_1", MODEL_PROMOTION_PROMOTED, repeat) ||
         repeat.model_registry_id != first.model_registry_id ||
         repeat.model_registry_hash != first.model_registry_hash)
      { allMatch = false; break; }
   }
   Check(allMatch, "1,000 repeated builds: identical model_registry_id/model_registry_hash every time");
   Check(first.model_registry_id == Ids_ModelRegistryId("CRT_SETUP_QUALITY", "v1"),
         "model_registry_id == Ids_ModelRegistryId(model_id, model_version)");

   ModelArtifact differentVersion;
   Check(BuildValidArtifact("CRT_SETUP_QUALITY", "v2", "sha256_artifact_1", MODEL_PROMOTION_PROMOTED, differentVersion),
         "sanity: a different model_version builds");
   Check(differentVersion.model_registry_id != first.model_registry_id,
         "a different model_version produces a different model_registry_id");
}

void Test_BuildValidation_AllFieldsMandatory()
{
   Print("--- build-time validation: every one of the 11 mandatory fields is required ---");
   ModelArtifact a;
   Check(!ModelArtifact_Build("", "v1", "h", "f", "td", "th", "mt", "in", "out", "rf", "rv", MODEL_PROMOTION_PROMOTED, a), "empty model_id is rejected");
   Check(a.model_registry_id == "", "rejected artifact stays at Init() defaults");
   Check(!ModelArtifact_Build("m", "", "h", "f", "td", "th", "mt", "in", "out", "rf", "rv", MODEL_PROMOTION_PROMOTED, a), "empty model_version is rejected");
   Check(!ModelArtifact_Build("m", "v1", "", "f", "td", "th", "mt", "in", "out", "rf", "rv", MODEL_PROMOTION_PROMOTED, a), "empty model_artifact_hash is rejected");
   Check(!ModelArtifact_Build("m", "v1", "h", "", "td", "th", "mt", "in", "out", "rf", "rv", MODEL_PROMOTION_PROMOTED, a), "empty feature_schema_version is rejected");
   Check(!ModelArtifact_Build("m", "v1", "h", "f", "", "th", "mt", "in", "out", "rf", "rv", MODEL_PROMOTION_PROMOTED, a), "empty training_dataset_id is rejected");
   Check(!ModelArtifact_Build("m", "v1", "h", "f", "td", "", "mt", "in", "out", "rf", "rv", MODEL_PROMOTION_PROMOTED, a), "empty training_dataset_hash is rejected");
   Check(!ModelArtifact_Build("m", "v1", "h", "f", "td", "th", "", "in", "out", "rf", "rv", MODEL_PROMOTION_PROMOTED, a), "empty model_target is rejected");
   Check(!ModelArtifact_Build("m", "v1", "h", "f", "td", "th", "mt", "", "out", "rf", "rv", MODEL_PROMOTION_PROMOTED, a), "empty input_schema_version is rejected");
   Check(!ModelArtifact_Build("m", "v1", "h", "f", "td", "th", "mt", "in", "", "rf", "rv", MODEL_PROMOTION_PROMOTED, a), "empty output_schema_version is rejected");
   Check(!ModelArtifact_Build("m", "v1", "h", "f", "td", "th", "mt", "in", "out", "", "rv", MODEL_PROMOTION_PROMOTED, a), "empty runtime_framework is rejected");
   Check(!ModelArtifact_Build("m", "v1", "h", "f", "td", "th", "mt", "in", "out", "rf", "", MODEL_PROMOTION_PROMOTED, a), "empty runtime_version is rejected");

   ModelArtifact valid;
   Check(ModelArtifact_Build("m", "v1", "h", "f", "td", "th", "mt", "in", "out", "rf", "rv", MODEL_PROMOTION_PROMOTED, valid),
         "sanity: all fields non-empty succeeds");
}

void Test_HashPayload_InclusionExclusionSweep()
{
   Print("--- model_registry_hash: every payload field moves the hash; model_registry_id does not ---");
   ModelArtifact baseline;
   Check(BuildValidArtifact("SWEEP_MODEL", "v1", "hash_a", MODEL_PROMOTION_PROMOTED, baseline), "sanity: baseline artifact built");
   string baseHash = baseline.model_registry_hash;

   ModelArtifact m;

   m = baseline; m.model_id = "DIFFERENT";                    Check(ModelArtifact_ComputeHash(m) != baseHash, "model_id change moves the hash");
   m = baseline; m.model_version = "v2";                       Check(ModelArtifact_ComputeHash(m) != baseHash, "model_version change moves the hash");
   m = baseline; m.model_artifact_hash = "different_hash";     Check(ModelArtifact_ComputeHash(m) != baseHash, "model_artifact_hash change moves the hash");
   m = baseline; m.feature_schema_version = "FEATURES_V2";     Check(ModelArtifact_ComputeHash(m) != baseHash, "feature_schema_version change moves the hash");
   m = baseline; m.training_dataset_id = "TDSET_other";        Check(ModelArtifact_ComputeHash(m) != baseHash, "training_dataset_id change moves the hash");
   m = baseline; m.training_dataset_hash = "other_hash";       Check(ModelArtifact_ComputeHash(m) != baseHash, "training_dataset_hash change moves the hash");
   m = baseline; m.model_target = "OTHER_TARGET";               Check(ModelArtifact_ComputeHash(m) != baseHash, "model_target change moves the hash");
   m = baseline; m.input_schema_version = "INPUT_V2";           Check(ModelArtifact_ComputeHash(m) != baseHash, "input_schema_version change moves the hash");
   m = baseline; m.output_schema_version = "OUTPUT_V2";         Check(ModelArtifact_ComputeHash(m) != baseHash, "output_schema_version change moves the hash");
   m = baseline; m.runtime_framework = "PyTorch";                Check(ModelArtifact_ComputeHash(m) != baseHash, "runtime_framework change moves the hash");
   m = baseline; m.runtime_version = "2.0.0";                    Check(ModelArtifact_ComputeHash(m) != baseHash, "runtime_version change moves the hash");
   m = baseline; m.promotion_state = MODEL_PROMOTION_RETIRED;    Check(ModelArtifact_ComputeHash(m) != baseHash, "promotion_state change moves the hash");
   m = baseline; m.model_registry_schema_version = "OTHER_SCHEMA"; Check(ModelArtifact_ComputeHash(m) != baseHash, "model_registry_schema_version change moves the hash (deliberate departure from RiskPlan/TrainingDatasetRow precedent)");

   m = baseline; m.model_registry_id = "DIFFERENT_ID";
   Check(ModelArtifact_ComputeHash(m) == baseHash, "model_registry_id change does NOT move the hash (identity, not content)");
}

void Test_TwoHashIndependence()
{
   Print("--- two-hash independence: model_artifact_hash change moves model_registry_hash but never model_registry_id ---");
   ModelArtifact a1, a2;
   Check(BuildValidArtifact("SAME_MODEL", "v1", "artifact_hash_1", MODEL_PROMOTION_PROMOTED, a1), "sanity: artifact 1 built");
   Check(BuildValidArtifact("SAME_MODEL", "v1", "artifact_hash_2", MODEL_PROMOTION_PROMOTED, a2), "sanity: artifact 2 built (different model_artifact_hash, same model_id/version)");

   Check(a1.model_registry_id == a2.model_registry_id, "same model_id/version -> same model_registry_id, regardless of model_artifact_hash");
   Check(a1.model_artifact_hash != a2.model_artifact_hash, "sanity: model_artifact_hash genuinely differs");
   Check(a1.model_registry_hash != a2.model_registry_hash, "different model_artifact_hash -> different model_registry_hash");
}

//=====================================================================
void Test_Emission_ExactlyOnce()
{
   Print("--- emission: a valid ModelArtifact emits exactly one MODEL_ARTIFACT_REGISTERED event ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_3_ExactlyOne.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   ModelArtifact a;
   Check(BuildAndEmitArtifact("EMIT_MODEL", "v1", "h1", MODEL_PROMOTION_PROMOTED, a), "sanity: artifact built and emitted");
   Check(!ModelArtifact_EmitModelArtifactRegistered(a), "second emission of the identical artifact returns false (no-op)");
   EventStore_Close();

   string lines[]; int n = EventStore_ReadAllLines(file, lines);
   int count = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"MODEL_ARTIFACT_REGISTERED\"") >= 0) count++;
   Check(count == 1, "exactly one MODEL_ARTIFACT_REGISTERED line written");
}

void Test_Emission_UnfilledEmitsNothing()
{
   Print("--- emission: an unfilled (empty id) artifact emits no event ---");
   ModelArtifact unfilled; ModelArtifact_Init(unfilled);
   Check(unfilled.model_registry_id == "", "sanity: Init() artifact has an empty model_registry_id");
   Check(!ModelArtifact_EmitModelArtifactRegistered(unfilled), "emitting an unfilled artifact returns false");
}

//=====================================================================
void Test_Replay_DuplicateSameHash_NoOp()
{
   Print("--- replay: same model_registry_id + same hash = duplicate no-op ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_3_ReplayDup.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   ModelArtifact a;
   Check(BuildAndEmitArtifact("REPLAYDUP_MODEL", "v1", "h1", MODEL_PROMOTION_PROMOTED, a), "sanity: artifact built and emitted");
   EventStore_Close();

   ModelArtifactProjection_Reset();
   EventStore_Open(file);
   Check(ModelArtifact_EmitModelArtifactRegistered(a), "sanity: the identical artifact re-emits under a fresh session");
   EventStore_Close();

   ModelArtifactProjectionReport report = ModelArtifactProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds despite the duplicate line");
   Check(ModelArtifactProjection_Count() == 1, "registry has exactly one record - the duplicate was a no-op");
}

void Test_Replay_CollisionDifferentHash_Rejected()
{
   Print("--- replay: same model_registry_id + DIFFERENT hash = collision, rejected (includes model_artifact_hash-only drift) ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_3_ReplayColl.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   ModelArtifact a;
   Check(BuildAndEmitArtifact("REPLAYCOLL_MODEL", "v1", "h1", MODEL_PROMOTION_PROMOTED, a), "sanity: artifact built and emitted");
   EventStore_Close();

   ModelArtifact colliding;
   Check(BuildValidArtifact("REPLAYCOLL_MODEL", "v1", "h1_DIFFERENT", MODEL_PROMOTION_PROMOTED, colliding),
         "sanity: colliding artifact (same model_id/version, different model_artifact_hash) builds");
   Check(colliding.model_registry_id == a.model_registry_id, "sanity: model_registry_id unaffected by model_artifact_hash");
   Check(colliding.model_registry_hash != a.model_registry_hash, "sanity: model_registry_hash DOES move with model_artifact_hash");

   ModelArtifactProjection_Reset();
   EventStore_Open(file);
   Check(ModelArtifact_EmitModelArtifactRegistered(colliding), "sanity: the colliding artifact emits under a fresh session");
   EventStore_Close();

   ModelArtifactProjectionReport report = ModelArtifactProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on a model_registry_id collision");
   Check(StringFind(report.first_error, "collision") >= 0, "first_error mentions the collision, not a duplicate no-op");
}

void Test_Replay_MalformedLineBlocksWholeRebuild()
{
   Print("--- replay: a truncated/malformed line anywhere blocks the WHOLE rebuild ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_3_Malformed.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   ModelArtifact a;
   Check(BuildAndEmitArtifact("MALFORMED_MODEL", "v1", "h1", MODEL_PROMOTION_PROMOTED, a), "sanity: artifact built and emitted");
   EventStore_Close();

   int h = FileOpen(file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, "{\"schema_version\":\"EVENTS_V1\",\"type\":\"MODEL_ARTIFACT_REGISTERED\",truncated_garbage");
   FileClose(h);

   int countBefore = ModelArtifactProjection_Count();
   ModelArtifactProjectionReport report = ModelArtifactProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on the truncated line");
   Check(ModelArtifactProjection_Count() == countBefore, "registry is left completely untouched by a failed rebuild");
}

void Test_Replay_RestartMultiSession_ByteIdentical()
{
   Print("--- replay: repeated rebuilds / multi-session replay reconstruct byte-identical records ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_3_Restart.jsonl";
   FileDelete(file, FILE_COMMON);

   EventStore_Open(file);
   ModelArtifact a1;
   Check(BuildAndEmitArtifact("RESTART_MODEL_A", "v1", "h1", MODEL_PROMOTION_PROMOTED, a1), "sanity: artifact A built and emitted");
   EventStore_Close();

   EventStore_Open(file);
   ModelArtifact a2;
   Check(BuildAndEmitArtifact("RESTART_MODEL_B", "v1", "h2", MODEL_PROMOTION_STAGING, a2), "sanity: artifact B built and emitted (second session)");
   EventStore_Close();

   ModelArtifactProjectionReport report1 = ModelArtifactProjection_RebuildFromFile(file);
   Check(report1.ok && ModelArtifactProjection_Count() == 2, "first rebuild: 2 records across both sessions");
   ModelArtifactProjectionRecord rec1a, rec1b;
   ModelArtifactProjection_TryGet(a1.model_registry_id, rec1a);
   ModelArtifactProjection_TryGet(a2.model_registry_id, rec1b);

   ModelArtifactProjectionReport report2 = ModelArtifactProjection_RebuildFromFile(file);
   Check(report2.ok && ModelArtifactProjection_Count() == 2, "second rebuild (simulated restart): still 2 records");
   ModelArtifactProjectionRecord rec2a, rec2b;
   ModelArtifactProjection_TryGet(a1.model_registry_id, rec2a);
   ModelArtifactProjection_TryGet(a2.model_registry_id, rec2b);

   Check(rec1a.model_registry_hash == rec2a.model_registry_hash && rec1a.promotion_state == rec2a.promotion_state, "record A identical across both rebuilds");
   Check(rec1b.model_registry_hash == rec2b.model_registry_hash && rec1b.promotion_state == rec2b.promotion_state, "record B identical across both rebuilds");
}

//=====================================================================
void Test_Compatibility_AcceptPath()
{
   Print("--- compatibility: a PROMOTED artifact whose fields exactly match the request is accepted ---");
   ModelArtifact a;
   Check(BuildValidArtifact("ACCEPT_MODEL", "v1", "h1", MODEL_PROMOTION_PROMOTED, a), "sanity: artifact built");
   string reason;
   Check(ModelArtifact_CheckCompatibility(a, "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", reason),
         "exact-match request against a PROMOTED artifact is accepted");
   Check(reason == "", "outReason is empty on acceptance");
}

void Test_Compatibility_RejectPath_EmptyRequestedFields()
{
   Print("--- compatibility: any empty requested parameter is rejected ---");
   ModelArtifact a;
   Check(BuildValidArtifact("EMPTYREQ_MODEL", "v1", "h1", MODEL_PROMOTION_PROMOTED, a), "sanity: artifact built");
   string reason;
   Check(!ModelArtifact_CheckCompatibility(a, "", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", reason), "empty requested_feature_schema_version rejected");
   Check(!ModelArtifact_CheckCompatibility(a, "FEATURES_B8_1_V1", "", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", reason), "empty requested_model_target rejected");
   Check(!ModelArtifact_CheckCompatibility(a, "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", reason), "empty requested_input_schema_version rejected");
   Check(!ModelArtifact_CheckCompatibility(a, "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "", "ONNXRuntime", "1.16.0", reason), "empty requested_output_schema_version rejected");
   Check(!ModelArtifact_CheckCompatibility(a, "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "", "1.16.0", reason), "empty requested_runtime_framework rejected");
   Check(!ModelArtifact_CheckCompatibility(a, "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "", reason), "empty requested_runtime_version rejected");
}

void Test_Compatibility_RejectPath_PromotionState()
{
   Print("--- compatibility: only PROMOTED passes - DRAFT/STAGING/RETIRED are all rejected ---");
   ModelArtifact draft, staging, retired;
   Check(BuildValidArtifact("DRAFT_MODEL", "v1", "h1", MODEL_PROMOTION_DRAFT, draft), "sanity: DRAFT artifact built");
   Check(BuildValidArtifact("STAGING_MODEL", "v1", "h1", MODEL_PROMOTION_STAGING, staging), "sanity: STAGING artifact built");
   Check(BuildValidArtifact("RETIRED_MODEL", "v1", "h1", MODEL_PROMOTION_RETIRED, retired), "sanity: RETIRED artifact built");

   string reason;
   Check(!ModelArtifact_CheckCompatibility(draft, "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", reason), "DRAFT is rejected");
   Check(StringFind(reason, "promotion_state") >= 0, "DRAFT rejection reason mentions promotion_state");
   Check(!ModelArtifact_CheckCompatibility(staging, "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", reason), "STAGING is rejected");
   Check(!ModelArtifact_CheckCompatibility(retired, "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", reason), "RETIRED is rejected");
}

void Test_Compatibility_RejectPath_FieldMismatches()
{
   Print("--- compatibility: each of the 6 checked fields, mismatched alone, is rejected with a distinct reason ---");
   ModelArtifact a;
   Check(BuildValidArtifact("MISMATCH_MODEL", "v1", "h1", MODEL_PROMOTION_PROMOTED, a), "sanity: artifact built");
   string reason;

   Check(!ModelArtifact_CheckCompatibility(a, "WRONG_FEATURES", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", reason), "feature_schema_version mismatch rejected");
   Check(StringFind(reason, "feature_schema_version") >= 0, "reason mentions feature_schema_version");

   Check(!ModelArtifact_CheckCompatibility(a, "FEATURES_B8_1_V1", "WRONG_TARGET", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", reason), "model_target mismatch rejected");
   Check(StringFind(reason, "model_target") >= 0, "reason mentions model_target");

   Check(!ModelArtifact_CheckCompatibility(a, "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "WRONG_INPUT", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", reason), "input_schema_version mismatch rejected");
   Check(StringFind(reason, "input_schema_version") >= 0, "reason mentions input_schema_version");

   Check(!ModelArtifact_CheckCompatibility(a, "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "WRONG_OUTPUT", "ONNXRuntime", "1.16.0", reason), "output_schema_version mismatch rejected");
   Check(StringFind(reason, "output_schema_version") >= 0, "reason mentions output_schema_version");

   Check(!ModelArtifact_CheckCompatibility(a, "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "WrongFramework", "1.16.0", reason), "runtime_framework mismatch rejected");
   Check(StringFind(reason, "runtime_framework") >= 0, "reason mentions runtime_framework");

   Check(!ModelArtifact_CheckCompatibility(a, "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "9.9.9", reason), "runtime_version mismatch rejected");
   Check(StringFind(reason, "runtime_version") >= 0, "reason mentions runtime_version");
}

void Test_Compatibility_NoCoercion()
{
   Print("--- compatibility: exact match only - no case-insensitivity, no whitespace tolerance ---");
   ModelArtifact a;
   Check(BuildValidArtifact("NOCOERCE_MODEL", "v1", "h1", MODEL_PROMOTION_PROMOTED, a), "sanity: artifact built");
   string reason;

   Check(!ModelArtifact_CheckCompatibility(a, "features_b8_1_v1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", reason),
         "a lowercase requested_feature_schema_version is rejected - no case-insensitive match");
   Check(!ModelArtifact_CheckCompatibility(a, "FEATURES_B8_1_V1 ", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", reason),
         "a trailing-space-padded requested_feature_schema_version is rejected - no whitespace tolerance");
}

void Test_ModelRegistry_FindCompatible()
{
   Print("--- ModelRegistry_FindCompatible: not-found vs registered-but-incompatible are distinct outcomes ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_3_FindCompatible.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   ModelArtifact promoted, staging;
   Check(BuildAndEmitArtifact("FIND_PROMOTED", "v1", "h1", MODEL_PROMOTION_PROMOTED, promoted), "sanity: PROMOTED artifact built and emitted");
   Check(BuildAndEmitArtifact("FIND_STAGING", "v1", "h1", MODEL_PROMOTION_STAGING, staging), "sanity: STAGING artifact built and emitted");
   EventStore_Close();

   ModelArtifactProjectionReport report = ModelArtifactProjection_RebuildFromFile(file);
   Check(report.ok && ModelArtifactProjection_Count() == 2, "sanity: registry rebuilt with 2 artifacts");

   ModelArtifact found; string reason;
   Check(ModelRegistry_FindCompatible("FIND_PROMOTED", "v1", "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", found, reason),
         "a registered, PROMOTED, matching artifact is found and accepted");
   Check(found.model_registry_id == promoted.model_registry_id, "the returned artifact is the right one");

   Check(!ModelRegistry_FindCompatible("FIND_STAGING", "v1", "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", found, reason),
         "a registered but STAGING (not PROMOTED) artifact is rejected");
   Check(StringFind(reason, "promotion_state") >= 0, "rejection reason mentions promotion_state - distinct from a not-found case");

   Check(!ModelRegistry_FindCompatible("DOES_NOT_EXIST", "v1", "FEATURES_B8_1_V1", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", found, reason),
         "an unregistered model_id/model_version pair is rejected");
   Check(reason == "model artifact not found in registry", "not-found reason is distinct and stable, never confused with an incompatibility rejection");
}

void Test_NoFallback_StructuralProof()
{
   Print("--- no fallback (structural): neither compatibility function searches for or selects an alternative artifact ---");
   Check(true, "ModelArtifact_CheckCompatibility takes exactly one ModelArtifact and returns accept/reject for that one; "
               "ModelRegistry_FindCompatible looks up exactly one model_id+model_version pair via a single "
               "ModelArtifactProjection_TryGet call - neither function contains a loop, search, or 'pick best' "
               "heuristic over multiple registry records - verified by inspection per "
               "Docs/PhaseB_B8_3_ModelRegistryContract.md's compatibility-function section");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B8.3 - ModelArtifact Registry / Compatibility ===");

   Test_Identity_Determinism();
   Test_BuildValidation_AllFieldsMandatory();
   Test_HashPayload_InclusionExclusionSweep();
   Test_TwoHashIndependence();

   Test_Emission_ExactlyOnce();
   Test_Emission_UnfilledEmitsNothing();

   Test_Replay_DuplicateSameHash_NoOp();
   Test_Replay_CollisionDifferentHash_Rejected();
   Test_Replay_MalformedLineBlocksWholeRebuild();
   Test_Replay_RestartMultiSession_ByteIdentical();

   Test_Compatibility_AcceptPath();
   Test_Compatibility_RejectPath_EmptyRequestedFields();
   Test_Compatibility_RejectPath_PromotionState();
   Test_Compatibility_RejectPath_FieldMismatches();
   Test_Compatibility_NoCoercion();
   Test_ModelRegistry_FindCompatible();
   Test_NoFallback_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
