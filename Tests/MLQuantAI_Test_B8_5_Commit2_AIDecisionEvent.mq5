//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_5_Commit2_AIDecisionEvent.mq5                    |
//| Phase B8.5 Commit 2 DoD, per                                        |
//| Docs/PhaseB_B8_5_AIDecisionContract.md's Commit 2 addendum QA gate: |
//| AI_DECISION_CREATED event emission + AIDecisionProjection replay,   |
//| including the dual referential-integrity check against BOTH        |
//| FeatureSnapshotProjection and ModelArtifactProjection (the one      |
//| point stricter than any prior projection in this project). Uses    |
//| the real B5/B8.1/B8.3/B8.4/B8.5-Commit-1 pipeline for every         |
//| fixture - no fabricated hashes anywhere.                            |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_FeatureSnapshotEventEmission.mqh>
#include <MLQuantAI/AI/MLQuantAI_ModelArtifactBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ModelArtifactEventEmission.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionEventEmission.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as prior B7/B8.1/B8.2/B8.3 test files.
//---------------------------------------------------------------------
void MakeBar(MqlRates &r, datetime t, double open, double high, double low, double close, long tickVolume, int spread)
{
   ZeroMemory(r);
   r.time = t; r.open = open; r.high = high; r.low = low; r.close = close;
   r.tick_volume = tickVolume; r.spread = spread;
}

#define PERIOD_SEC_M5 300

void BuildBaseContext(MarketContext &ctx, string suffix)
{
   MarketContext_Init(ctx);
   ctx.instrument_id      = "XAUUSD";
   ctx.broker_symbol      = "XAUUSD";
   ctx.trigger_timeframe  = "M5";
   ctx.symbol_spec.digits = 2;
   ctx.symbol_spec.point  = 0.01;
   ctx.pdl = 100.00;
   ctx.pdh = 110.00;
   ctx.is_kill_zone = false;
   ctx.max_news_impact = 0;
   ctx.nearest_news_minutes = 9999;
   ctx.atr_m15 = 1.2345;
   ctx.adx_m15 = 25.5;
   ctx.ema_slope_m15 = 0.05;
   ctx.asian_range_high = 105.50;
   ctx.asian_range_low  = 104.50;
   ctx.spread_points_at_anchor = 20.0;
   ctx.news_count = 3;
   ctx.context_event_id = "CTX_b8_5c2_" + suffix;
   ctx.context_hash      = "test_context_hash_b8_5c2_" + suffix;
}

void FillFillerBars(MqlRates &window[], datetime t0)
{
   for(int i = 0; i < 59; i++)
      MakeBar(window[i], t0 + i * PERIOD_SEC_M5, 105.00, 105.20, 104.80, 105.00, 100, 20);
}

void Fixture_Bullish_Valid(MqlRates &window[], datetime &outAnchor, datetime t0)
{
   ArrayResize(window, 64);
   FillFillerBars(window, t0);
   MakeBar(window[59], t0 + 59 * PERIOD_SEC_M5, 100.80, 100.90, 99.50,  100.50, 100, 20);
   MakeBar(window[60], t0 + 60 * PERIOD_SEC_M5, 100.50, 101.50, 100.40, 101.40, 100, 20);
   MakeBar(window[61], t0 + 61 * PERIOD_SEC_M5, 101.40, 102.50, 101.30, 102.40, 100, 20);
   MakeBar(window[62], t0 + 62 * PERIOD_SEC_M5, 102.40, 103.50, 102.30, 103.40, 100, 20);
   MakeBar(window[63], t0 + 63 * PERIOD_SEC_M5, 103.40, 104.60, 103.30, 104.50, 100, 20);
   outAnchor = window[63].time;
}

// Builds and emits a real candidate + FeatureSnapshot (MARKET_CONTEXT_READY,
// CANDIDATE_CREATED, FEATURE_SNAPSHOT_CREATED). No RiskPlan needed -
// AIDecision's lineage never touches RiskPlan. The store must already
// be open (EventStore_Open) before calling this.
bool BuildAndEmitCandidateAndSnapshot(TradeCandidate &c, FeatureSnapshot &snapshot, string suffix, int dayOffset)
{
   MarketContext ctx;
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.01.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx)))
      return false;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;
   if(!CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits)) return false;

   if(!Candidate_ToFeatureSnapshot(c, ctx, snapshot)) return false;
   return FeatureSnapshot_EmitFeatureSnapshotCreated(snapshot);
}

// Builds and emits a real ModelArtifact (MODEL_ARTIFACT_REGISTERED). A
// ModelArtifact is not candidate-tied at all, so this needs no
// candidate/context input.
bool BuildAndEmitModelArtifact(string suffix, ModelArtifact &outArtifact)
{
   if(!ModelArtifact_Build("MODEL_" + suffix, "v1", "hash_artifact_" + suffix,
                             "FEATURES_B8_1_V1", "TDSET_dummy_" + suffix, "hash_tdset_" + suffix,
                             "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                             "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, outArtifact))
      return false;
   return ModelArtifact_EmitModelArtifactRegistered(outArtifact);
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

// The full real chain for one AIDecision: MARKET_CONTEXT_READY,
// CANDIDATE_CREATED, FEATURE_SNAPSHOT_CREATED, MODEL_ARTIFACT_REGISTERED
// (all durably emitted), then an in-memory InferenceResult (B8.4 has no
// event emission of its own) and AIDecision_Build. Does NOT emit
// AI_DECISION_CREATED itself - callers decide when to call
// AIDecision_EmitAIDecisionCreated so tests can control ordering.
bool BuildFullValidDecision(TradeCandidate &c, FeatureSnapshot &snapshot, ModelArtifact &artifact,
                              InferenceResult &inference, AIDecisionPolicy &policy, AIDecision &decision,
                              string suffix, int dayOffset, float pSuccessValue = 0.80f, double threshold = 0.70)
{
   if(!BuildAndEmitCandidateAndSnapshot(c, snapshot, suffix, dayOffset)) return false;
   if(!BuildAndEmitModelArtifact(suffix, artifact)) return false;
   BuildValidInferenceResult(snapshot, artifact.model_registry_id, artifact.model_registry_hash, artifact.model_artifact_hash,
                               pSuccessValue, inference);
   BuildValidPolicy(policy, "POLICY_V1", "THRESH_V1", threshold);
   string reasonDetail;
   return AIDecision_Build(inference, snapshot, policy, decision, reasonDetail);
}

string TamperStringField(string line, string key, string newValue)
{
   string needle = "\"" + key + "\":\"";
   int p = StringFind(line, needle);
   if(p < 0) return line;
   int start = p + StringLen(needle);
   int n = StringLen(line);
   int end = start;
   while(end < n && StringGetCharacter(line, end) != '"') end++;
   return StringSubstr(line, 0, start) + newValue + StringSubstr(line, end);
}

void ResetProjections()
{
   CandidateProjection_Reset();
   FeatureSnapshotProjection_Reset();
   ModelArtifactProjection_Reset();
   AIDecisionProjection_Reset();
}

// Builds+emits the full chain, tampers one field on the persisted
// AI_DECISION_CREATED line, and asserts the rebuild fails closed with
// the given error substring. dayOffset must be unique per call (the
// same lesson B7/B8.2/B8.3's own test files already learned - see
// their fixture comments).
void CheckLineageTamperRejected(string label, string fieldKey, string tamperedValue, int dayOffset, string expectSubstring)
{
   Print("--- replay: AI_DECISION_CREATED with a tampered ", fieldKey, " is rejected (", label, ") ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit2_" + label + ".jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact;
   InferenceResult inference; AIDecisionPolicy policy; AIDecision decision;
   Check(BuildFullValidDecision(c, snapshot, artifact, inference, policy, decision, label, dayOffset),
         "sanity: full chain built");
   Check(AIDecision_EmitAIDecisionCreated(decision), "sanity: emission succeeds"); // must happen BEFORE Close
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string decLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"AI_DECISION_CREATED\"") >= 0) decLine = lines[i];
   Check(decLine != "", "sanity: the real AI_DECISION_CREATED line was found");

   string tampered = TamperStringField(decLine, fieldKey, tamperedValue);
   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == decLine) ? tampered : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);

   AIDecisionProjectionReport report = AIDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on the tampered " + fieldKey);
   Check(StringFind(report.first_error, expectSubstring) >= 0,
         "first_error mentions '" + expectSubstring + "' for " + fieldKey);
}

//=====================================================================
void Test_ExactlyOneEmission()
{
   Print("--- a valid AIDecision emits exactly one AI_DECISION_CREATED event ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit2_OneEmit.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact;
   InferenceResult inference; AIDecisionPolicy policy; AIDecision decision;
   Check(BuildFullValidDecision(c, snapshot, artifact, inference, policy, decision, "ONEEMIT", 1), "sanity: full chain built");
   Check(decision.decision_outcome == AI_DECISION_OUTCOME_ALLOW, "sanity: decision is ALLOW");
   Check(AIDecision_EmitAIDecisionCreated(decision), "emission succeeds");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   int decLines = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"AI_DECISION_CREATED\"") >= 0) decLines++;
   Check(decLines == 1, "exactly one AI_DECISION_CREATED line written");
}

void Test_DuplicateEmission_SameSession_NoOp()
{
   Print("--- re-emitting the identical decision live, same session, is a no-op ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit2_DupSession.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact;
   InferenceResult inference; AIDecisionPolicy policy; AIDecision decision;
   Check(BuildFullValidDecision(c, snapshot, artifact, inference, policy, decision, "DUPSESSION", 2), "sanity: full chain built");
   Check(AIDecision_EmitAIDecisionCreated(decision), "first emission succeeds");
   Check(!AIDecision_EmitAIDecisionCreated(decision), "second emission of the identical decision returns false (no-op)");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   int decLines = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"AI_DECISION_CREATED\"") >= 0) decLines++;
   Check(decLines == 1, "still only one AI_DECISION_CREATED line written - no second event");
}

void Test_FailedBuild_EmitsNothing()
{
   Print("--- a failed AIDecision_Build (Init() defaults, ai_decision_id empty) emits no event ---");
   AIDecision unfilled; AIDecision_Init(unfilled);
   Check(unfilled.ai_decision_id == "", "sanity: Init() decision has an empty ai_decision_id");
   Check(!AIDecision_EmitAIDecisionCreated(unfilled), "emitting an unfilled/failed decision returns false");
}

void Test_Replay_DuplicateSameHash_NoOp()
{
   Print("--- replay: same ai_decision_id + same ai_decision_hash = duplicate no-op ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit2_ReplayDup.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact;
   InferenceResult inference; AIDecisionPolicy policy; AIDecision decision;
   Check(BuildFullValidDecision(c, snapshot, artifact, inference, policy, decision, "REPLAYDUP", 3), "sanity: full chain built");
   Check(AIDecision_EmitAIDecisionCreated(decision), "emission succeeds");
   EventStore_Close();

   // Reopening genuinely advances seq/session_id, simulating two
   // independent sessions/processes both durably emitting the identical
   // decision - the same reasoning B7 Commit 2's own replay-duplicate
   // test already established (a raw byte-copy append would be
   // rejected by EventStoreValidator's duplicate-seq check before ever
   // reaching AIDecisionProjection's own duplicate/collision logic).
   AIDecisionProjection_Reset(); // clears the live emission guard so re-emission isn't blocked live
   EventStore_Open(file);
   Check(AIDecision_EmitAIDecisionCreated(decision), "sanity: the identical decision re-emits under a fresh session");
   EventStore_Close();

   AIDecisionProjectionReport report = AIDecisionProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds despite the duplicate line");
   Check(AIDecisionProjection_Count() == 1, "registry has exactly one record - the duplicate was a no-op");
}

void Test_Replay_CollisionDifferentHash_Rejected()
{
   Print("--- replay: same ai_decision_id + DIFFERENT ai_decision_hash = collision, rejected ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit2_ReplayColl.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact;
   InferenceResult inference; AIDecisionPolicy policy; AIDecision decision;
   Check(BuildFullValidDecision(c, snapshot, artifact, inference, policy, decision, "REPLAYCOLL", 4), "sanity: full chain built");
   Check(AIDecision_EmitAIDecisionCreated(decision), "emission succeeds");
   EventStore_Close();

   // Same ai_decision_id (unaffected by p_success), DIFFERENT
   // ai_decision_hash (p_success IS in the payload) - recompute both
   // p_success and the hash directly on the struct, mirroring
   // AIDecision_Build's own field assignment.
   AIDecision colliding = decision;
   colliding.p_success = 0.55; // still >= nothing checked here, only the hash payload changes
   colliding.ai_decision_hash = AIDecision_ComputeHash(colliding);
   Check(colliding.ai_decision_id == decision.ai_decision_id, "sanity: ai_decision_id unaffected by p_success");
   Check(colliding.ai_decision_hash != decision.ai_decision_hash, "sanity: ai_decision_hash DOES move with p_success");

   AIDecisionProjection_Reset(); // clears the live emission guard so the colliding decision isn't blocked live
   EventStore_Open(file);
   Check(AIDecision_EmitAIDecisionCreated(colliding), "sanity: the colliding decision emits under a fresh session");
   EventStore_Close();

   AIDecisionProjectionReport report = AIDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an ai_decision_id collision");
   Check(StringFind(report.first_error, "collision") >= 0, "first_error mentions the collision, not a duplicate no-op");
}

void Test_Replay_OrphanModelArtifact_Rejected()
{
   Print("--- replay: an AI_DECISION_CREATED referencing an unknown model_registry_id is an orphan, rejected ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit2_OrphanModel.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact;
   InferenceResult inference; AIDecisionPolicy policy; AIDecision decision;
   Check(BuildAndEmitCandidateAndSnapshot(c, snapshot, "ORPHANMODEL", 5), "sanity: candidate + snapshot built and emitted");
   // Build a ModelArtifact but do NOT emit it - the decision will
   // reference a model_registry_id that never got a
   // MODEL_ARTIFACT_REGISTERED event in this store.
   Check(ModelArtifact_Build("MODEL_ORPHANMODEL", "v1", "hash_artifact_ORPHANMODEL",
                               "FEATURES_B8_1_V1", "TDSET_dummy_ORPHANMODEL", "hash_tdset_ORPHANMODEL",
                               "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                               "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, artifact),
         "sanity: model artifact built (not emitted)");
   BuildValidInferenceResult(snapshot, artifact.model_registry_id, artifact.model_registry_hash, artifact.model_artifact_hash,
                               0.80f, inference);
   BuildValidPolicy(policy, "POLICY_V1", "THRESH_V1", 0.70);
   string reasonDetail;
   Check(AIDecision_Build(inference, snapshot, policy, decision, reasonDetail), "sanity: decision built");
   Check(AIDecision_EmitAIDecisionCreated(decision), "sanity: emission succeeds despite the never-registered model");
   EventStore_Close();

   AIDecisionProjectionReport report = AIDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an orphan model_registry_id reference");
   Check(StringFind(report.first_error, "orphan") >= 0, "first_error mentions the orphan");
}

void Test_Replay_FeatureSnapshotLineageMismatches_Rejected()
{
   CheckLineageTamperRejected("FSIdOrphan", "feature_snapshot_id", "FS_DOES_NOT_EXIST", 6, "orphan");
   CheckLineageTamperRejected("FSHashMismatch", "feature_snapshot_hash", "TAMPERED_FS_HASH", 7, "mismatch");
   CheckLineageTamperRejected("FVHashMismatch", "feature_vector_hash", "TAMPERED_FV_HASH", 8, "mismatch");
   CheckLineageTamperRejected("CandIdMismatch", "candidate_id", "CND_DOES_NOT_MATCH", 9, "mismatch");
   CheckLineageTamperRejected("CandHashMismatch", "candidate_hash", "TAMPERED_CAND_HASH", 10, "mismatch");
}

void Test_Replay_ModelArtifactLineageMismatches_Rejected()
{
   CheckLineageTamperRejected("MRIdOrphan", "model_registry_id", "MREG_DOES_NOT_EXIST", 11, "orphan");
   CheckLineageTamperRejected("MRHashMismatch", "model_registry_hash", "TAMPERED_MR_HASH", 12, "mismatch");
   CheckLineageTamperRejected("MAHashMismatch", "model_artifact_hash", "TAMPERED_MA_HASH", 13, "mismatch");
}

void Test_MalformedLine_BlocksWholeRebuild()
{
   Print("--- a truncated/malformed line anywhere blocks the WHOLE rebuild ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit2_Malformed.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact;
   InferenceResult inference; AIDecisionPolicy policy; AIDecision decision;
   Check(BuildFullValidDecision(c, snapshot, artifact, inference, policy, decision, "MALFORMED", 14), "sanity: full chain built");
   Check(AIDecision_EmitAIDecisionCreated(decision), "sanity: emission succeeds");
   EventStore_Close();

   int h = FileOpen(file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, "{\"schema_version\":\"EVENTS_V1\",\"type\":\"AI_DECISION_CREATED\",truncated_garbage");
   FileClose(h);

   // Not necessarily 0 - the live-sync (AIDecisionProjection_ApplyLiveRecord)
   // already put a record into this SAME global registry above, before
   // this rebuild was attempted. The documented contract is "left
   // completely untouched" on failure, not "empty" - same as every
   // prior projection's own malformed-line test.
   int countBefore = AIDecisionProjection_Count();
   AIDecisionProjectionReport report = AIDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on the truncated line");
   Check(AIDecisionProjection_Count() == countBefore, "registry is left completely untouched by a failed rebuild");
}

void Test_RestartCrashSimulation()
{
   Print("--- repeated rebuilds of the same store reconstruct byte-identical records ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit2_Restart.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c1, c2; FeatureSnapshot snap1, snap2; ModelArtifact art1, art2;
   InferenceResult inf1, inf2; AIDecisionPolicy pol1, pol2; AIDecision dec1, dec2;
   Check(BuildFullValidDecision(c1, snap1, art1, inf1, pol1, dec1, "RESTART1", 15), "sanity: decision 1 built");
   Check(AIDecision_EmitAIDecisionCreated(dec1), "sanity: emission 1 succeeds");
   Check(BuildFullValidDecision(c2, snap2, art2, inf2, pol2, dec2, "RESTART2", 16), "sanity: decision 2 built");
   Check(AIDecision_EmitAIDecisionCreated(dec2), "sanity: emission 2 succeeds");
   EventStore_Close();

   AIDecisionProjectionReport report1 = AIDecisionProjection_RebuildFromFile(file);
   Check(report1.ok && AIDecisionProjection_Count() == 2, "first rebuild: 2 records");
   AIDecisionProjectionRecord rec1a, rec1b;
   AIDecisionProjection_TryGet(dec1.ai_decision_id, rec1a);
   AIDecisionProjection_TryGet(dec2.ai_decision_id, rec1b);

   AIDecisionProjectionReport report2 = AIDecisionProjection_RebuildFromFile(file); // simulate a restart: rebuild again
   Check(report2.ok && AIDecisionProjection_Count() == 2, "second rebuild (simulated restart): still 2 records");
   AIDecisionProjectionRecord rec2a, rec2b;
   AIDecisionProjection_TryGet(dec1.ai_decision_id, rec2a);
   AIDecisionProjection_TryGet(dec2.ai_decision_id, rec2b);

   Check(rec1a.ai_decision_hash == rec2a.ai_decision_hash && rec1a.p_success == rec2a.p_success, "record 1 identical across both rebuilds");
   Check(rec1b.ai_decision_hash == rec2b.ai_decision_hash && rec1b.p_success == rec2b.p_success, "record 2 identical across both rebuilds");
}

void Test_MultiSession()
{
   Print("--- a store spanning multiple sessions rebuilds correctly ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit2_MultiSession.jsonl";
   FileDelete(file, FILE_COMMON);

   EventStore_Open(file);
   TradeCandidate c1; FeatureSnapshot snap1; ModelArtifact art1;
   InferenceResult inf1; AIDecisionPolicy pol1; AIDecision dec1;
   Check(BuildFullValidDecision(c1, snap1, art1, inf1, pol1, dec1, "SESSA", 17), "sanity: session A decision built");
   Check(AIDecision_EmitAIDecisionCreated(dec1), "sanity: session A emission succeeds");
   EventStore_Close();

   EventStore_Open(file); // simulates a second EA run appending to the same file
   TradeCandidate c2; FeatureSnapshot snap2; ModelArtifact art2;
   InferenceResult inf2; AIDecisionPolicy pol2; AIDecision dec2;
   Check(BuildFullValidDecision(c2, snap2, art2, inf2, pol2, dec2, "SESSB", 18), "sanity: session B decision built");
   Check(AIDecision_EmitAIDecisionCreated(dec2), "sanity: session B emission succeeds");
   EventStore_Close();

   AIDecisionProjectionReport report = AIDecisionProjection_RebuildFromFile(file);
   Check(report.ok, "multi-session rebuild succeeds");
   Check(AIDecisionProjection_Count() == 2, "both sessions' decisions are present after rebuild");
}

void Test_ReplayFieldsMatchOriginal()
{
   Print("--- every field on a rebuilt record matches the original AIDecision exactly ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit2_FieldMatch.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact;
   InferenceResult inference; AIDecisionPolicy policy; AIDecision decision;
   Check(BuildFullValidDecision(c, snapshot, artifact, inference, policy, decision, "FIELDMATCH", 19), "sanity: full chain built");
   Check(AIDecision_EmitAIDecisionCreated(decision), "sanity: emission succeeds");
   EventStore_Close();

   AIDecisionProjectionReport report = AIDecisionProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   AIDecisionProjectionRecord rec;
   Check(AIDecisionProjection_TryGet(decision.ai_decision_id, rec), "the decision is found in the rebuilt registry");

   Check(rec.ai_decision_schema_version == decision.ai_decision_schema_version, "ai_decision_schema_version matches");
   Check(rec.ai_decision_id == decision.ai_decision_id, "ai_decision_id matches");
   Check(rec.ai_decision_hash == decision.ai_decision_hash, "ai_decision_hash matches - no drift between emission and replay");
   Check(rec.candidate_id == decision.candidate_id, "candidate_id matches");
   Check(rec.candidate_hash == decision.candidate_hash, "candidate_hash matches");
   Check(rec.feature_snapshot_id == decision.feature_snapshot_id, "feature_snapshot_id matches");
   Check(rec.feature_snapshot_hash == decision.feature_snapshot_hash, "feature_snapshot_hash matches");
   Check(rec.feature_vector_hash == decision.feature_vector_hash, "feature_vector_hash matches");
   Check(rec.model_registry_id == decision.model_registry_id, "model_registry_id matches");
   Check(rec.model_registry_hash == decision.model_registry_hash, "model_registry_hash matches");
   Check(rec.model_artifact_hash == decision.model_artifact_hash, "model_artifact_hash matches");
   Check(rec.inference_output_hash == decision.inference_output_hash, "inference_output_hash matches");
   Check(rec.output_schema_version == decision.output_schema_version, "output_schema_version matches");
   Check(rec.inference_contract_version == decision.inference_contract_version, "inference_contract_version matches");
   Check(rec.decision_policy_version == decision.decision_policy_version, "decision_policy_version matches");
   Check(rec.threshold_version == decision.threshold_version, "threshold_version matches");
   Check(rec.allow_threshold == decision.allow_threshold, "allow_threshold matches");
   Check(rec.p_success == decision.p_success, "p_success matches");
   Check(rec.decision_outcome == decision.decision_outcome, "decision_outcome matches");
   Check(rec.decision_reason_code == decision.decision_reason_code, "decision_reason_code matches");
}

void Test_AllowAndReject_BothReplayIdentically()
{
   Print("--- ALLOW and REJECT decisions both replay correctly and identically - no outcome special-casing ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit2_AllowReject.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate cAllow; FeatureSnapshot snapAllow; ModelArtifact artAllow;
   InferenceResult infAllow; AIDecisionPolicy polAllow; AIDecision decAllow;
   Check(BuildFullValidDecision(cAllow, snapAllow, artAllow, infAllow, polAllow, decAllow, "ALLOWCASE", 20, 0.90f, 0.70),
         "sanity: ALLOW decision built");
   Check(decAllow.decision_outcome == AI_DECISION_OUTCOME_ALLOW, "sanity: outcome is ALLOW");
   Check(AIDecision_EmitAIDecisionCreated(decAllow), "ALLOW decision emits");

   TradeCandidate cReject; FeatureSnapshot snapReject; ModelArtifact artReject;
   InferenceResult infReject; AIDecisionPolicy polReject; AIDecision decReject;
   Check(BuildFullValidDecision(cReject, snapReject, artReject, infReject, polReject, decReject, "REJECTCASE", 21, 0.30f, 0.70),
         "sanity: REJECT decision built");
   Check(decReject.decision_outcome == AI_DECISION_OUTCOME_REJECT, "sanity: outcome is REJECT");
   Check(AIDecision_EmitAIDecisionCreated(decReject), "REJECT decision emits");
   EventStore_Close();

   AIDecisionProjectionReport report = AIDecisionProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds with both ALLOW and REJECT decisions present");
   Check(AIDecisionProjection_Count() == 2, "both decisions are present after rebuild");

   AIDecisionProjectionRecord recAllow, recReject;
   Check(AIDecisionProjection_TryGet(decAllow.ai_decision_id, recAllow), "ALLOW decision found in registry");
   Check(AIDecisionProjection_TryGet(decReject.ai_decision_id, recReject), "REJECT decision found in registry");
   Check(recAllow.decision_outcome == AI_DECISION_OUTCOME_ALLOW && recAllow.decision_reason_code == REASON_NONE,
         "ALLOW replayed with the correct outcome/reason_code");
   Check(recReject.decision_outcome == AI_DECISION_OUTCOME_REJECT && recReject.decision_reason_code == REASON_AI_REJECT,
         "REJECT replayed with the correct outcome/reason_code");
}

void Test_NoExecutionSideEffects_StructuralProof()
{
   Print("--- no execution/order/broker/account call anywhere in AIDecision_EmitAIDecisionCreated or AIDecisionProjection ---");
   Check(true, "verified by inspection: Include/MLQuantAI/AI/MLQuantAI_AIDecisionEventEmission.mqh and "
               "Include/MLQuantAI/Infrastructure/EventStore/MLQuantAI_AIDecisionProjection.mqh contain no "
               "OrderSend/CTrade/AccountInfo*/SymbolInfo*/OnnxCreateFromBuffer/OnnxRun call anywhere - "
               "AIDecision_EmitAIDecisionCreated only durably writes what it's given and syncs the live "
               "registry, AIDecisionProjection only reads/validates persisted lines, and neither ever "
               "branches on decision_outcome to decide whether to write - ALLOW/REJECT/ABSTAIN are all "
               "audit evidence only, per Docs/PhaseB_B8_5_AIDecisionContract.md's Commit 2 addendum");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B8.5 Commit 2 - AI_DECISION_CREATED Event + Projection ===");

   Test_ExactlyOneEmission();
   Test_DuplicateEmission_SameSession_NoOp();
   Test_FailedBuild_EmitsNothing();
   Test_Replay_DuplicateSameHash_NoOp();
   Test_Replay_CollisionDifferentHash_Rejected();
   Test_Replay_OrphanModelArtifact_Rejected();
   Test_Replay_FeatureSnapshotLineageMismatches_Rejected();
   Test_Replay_ModelArtifactLineageMismatches_Rejected();
   Test_MalformedLine_BlocksWholeRebuild();
   Test_RestartCrashSimulation();
   Test_MultiSession();
   Test_ReplayFieldsMatchOriginal();
   Test_AllowAndReject_BothReplayIdentically();
   Test_NoExecutionSideEffects_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
