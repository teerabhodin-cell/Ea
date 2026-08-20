//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_5_Commit3_IntegrationRegression.mq5              |
//| Phase B8.5 Commit 3 DoD, per                                        |
//| Docs/PhaseB_B8_5_AIDecisionContract.md's Commit 3 addendum: proves  |
//| the full MARKET_CONTEXT_READY -> CANDIDATE_CREATED ->               |
//| FEATURE_SNAPSHOT_CREATED (+ MODEL_ARTIFACT_REGISTERED, independent) |
//| -> AIDecision_Build -> AI_DECISION_CREATED -> AIDecisionProjection  |
//| -> Restart/Replay chain composes correctly end to end, across BOTH  |
//| independent upstream parents (FeatureSnapshot and ModelArtifact).   |
//| Adds ZERO new production behavior - no B5/B8.1/B8.3/B8.5 sealed     |
//| file touched. Does NOT re-prove anything already covered by         |
//| Test_B8_5_AIDecision.mq5 or Test_B8_5_Commit2_AIDecisionEvent.mq5's |
//| own suites - see the addendum for exactly what is genuinely new     |
//| here: end-to-end linkage in one place, cross-layer failure          |
//| propagation for BOTH upstream chains independently, full-chain      |
//| multi-decision restart, and multi-candidate/multi-model             |
//| cross-linking.                                                      |
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

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_B8_5_Commit3_IntegrationRegression.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as Test_B8_5_Commit2_AIDecisionEvent.mq5
// (each .mq5 test script in this project is standalone; no shared
// fixture include exists, matching every prior test file's own
// convention).
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
   ctx.context_event_id = "CTX_b8_5c3_" + suffix;
   ctx.context_hash      = "test_context_hash_b8_5c3_" + suffix;
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

// The one new fixture primitive this file adds: builds AND emits every
// layer of the real chain for one decision (MARKET_CONTEXT_READY,
// CANDIDATE_CREATED, FEATURE_SNAPSHOT_CREATED, MODEL_ARTIFACT_REGISTERED,
// AI_DECISION_CREATED), returning ctx (unlike Commit 2's
// BuildFullValidDecision, which discarded it) - Commit 3's whole point
// is checking each layer's persisted state against what was actually
// fed into the layer before it, so the caller needs ctx, not just the
// final AIDecision.
// dayOffset must be unique within one event store file (see the same
// lesson from every prior test file's own history).
bool BuildFullChain(MarketContext &ctx, TradeCandidate &c, FeatureSnapshot &snapshot, ModelArtifact &artifact,
                      InferenceResult &inference, AIDecisionPolicy &policy, AIDecision &decision,
                      string suffix, int dayOffset, float pSuccessValue = 0.80f, double threshold = 0.70)
{
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
   if(!FeatureSnapshot_EmitFeatureSnapshotCreated(snapshot)) return false;

   if(!ModelArtifact_Build("MODEL_" + suffix, "v1", "hash_artifact_" + suffix,
                             "FEATURES_B8_1_V1", "TDSET_dummy_" + suffix, "hash_tdset_" + suffix,
                             "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                             "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, artifact))
      return false;
   if(!ModelArtifact_EmitModelArtifactRegistered(artifact)) return false;

   BuildValidInferenceResult(snapshot, artifact.model_registry_id, artifact.model_registry_hash, artifact.model_artifact_hash,
                               pSuccessValue, inference);
   BuildValidPolicy(policy, "POLICY_V1", "THRESH_V1", threshold);
   string reasonDetail;
   if(!AIDecision_Build(inference, snapshot, policy, decision, reasonDetail)) return false;

   return AIDecision_EmitAIDecisionCreated(decision);
}

bool BuildThreeChains(MarketContext &ctxs[], TradeCandidate &candidates[], FeatureSnapshot &snapshots[],
                        ModelArtifact &artifacts[], InferenceResult &inferences[], AIDecisionPolicy &policies[],
                        AIDecision &decisions[], string suffixPrefix, int baseDayOffset, bool shareModel)
{
   ArrayResize(ctxs, 3); ArrayResize(candidates, 3); ArrayResize(snapshots, 3);
   ArrayResize(artifacts, 3); ArrayResize(inferences, 3); ArrayResize(policies, 3); ArrayResize(decisions, 3);

   if(shareModel)
   {
      // Candidate/snapshot 0 and 2 share ONE ModelArtifact; candidate 1
      // uses its own - proving the two-independent-parents shape
      // doesn't let a decision accidentally pick up a neighboring
      // candidate's snapshot OR a neighboring decision's model, in a
      // mixed shared/distinct topology.
      ModelArtifact sharedArtifact;
      if(!ModelArtifact_Build("MODEL_SHARED_" + suffixPrefix, "v1", "hash_artifact_shared_" + suffixPrefix,
                                "FEATURES_B8_1_V1", "TDSET_dummy_shared_" + suffixPrefix, "hash_tdset_shared_" + suffixPrefix,
                                "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                                "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, sharedArtifact))
         return false;
      if(!ModelArtifact_EmitModelArtifactRegistered(sharedArtifact)) return false;

      for(int i = 0; i < 3; i++)
      {
         string suffix = suffixPrefix + IntegerToString(i);
         BuildBaseContext(ctxs[i], suffix);
         datetime t0 = D'2026.01.01 00:00:00' + (baseDayOffset + i) * 86400;
         datetime anchor;
         Fixture_Bullish_Valid(ctxs[i].trigger_tf_recent, anchor, t0);
         ctxs[i].anchor_bar_time = anchor;

         if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctxs[i])))
            return false;

         CRTDetectionResult r;
         CRT_DetectV1(ctxs[i], r);
         if(!r.detected) return false;
         if(!CRT_ToTradeCandidate(ctxs[i], r, candidates[i])) return false;
         if(!CRT_EmitCandidateCreated(candidates[i], ctxs[i].symbol_spec.digits)) return false;

         if(!Candidate_ToFeatureSnapshot(candidates[i], ctxs[i], snapshots[i])) return false;
         if(!FeatureSnapshot_EmitFeatureSnapshotCreated(snapshots[i])) return false;

         // candidate 1 uses its OWN distinct model; 0 and 2 share sharedArtifact
         if(i == 1)
         {
            if(!ModelArtifact_Build("MODEL_OWN_" + suffix, "v1", "hash_artifact_own_" + suffix,
                                      "FEATURES_B8_1_V1", "TDSET_dummy_own_" + suffix, "hash_tdset_own_" + suffix,
                                      "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                                      "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, artifacts[i]))
               return false;
            if(!ModelArtifact_EmitModelArtifactRegistered(artifacts[i])) return false;
         }
         else
         {
            artifacts[i] = sharedArtifact;
         }

         BuildValidInferenceResult(snapshots[i], artifacts[i].model_registry_id, artifacts[i].model_registry_hash,
                                     artifacts[i].model_artifact_hash, 0.80f, inferences[i]);
         BuildValidPolicy(policies[i], "POLICY_V1", "THRESH_V1", 0.70);
         string reasonDetail;
         if(!AIDecision_Build(inferences[i], snapshots[i], policies[i], decisions[i], reasonDetail)) return false;
         if(!AIDecision_EmitAIDecisionCreated(decisions[i])) return false;
      }
      return true;
   }

   for(int i = 0; i < 3; i++)
   {
      if(!BuildFullChain(ctxs[i], candidates[i], snapshots[i], artifacts[i], inferences[i], policies[i], decisions[i],
                           suffixPrefix + IntegerToString(i), baseDayOffset + i))
         return false;
   }
   return true;
}

bool CandidateRecordsEqual(const CandidateProjectionRecord &a, const CandidateProjectionRecord &b)
{
   return a.candidate_id == b.candidate_id &&
          a.candidate_hash == b.candidate_hash &&
          a.context_hash == b.context_hash &&
          a.context_event_id == b.context_event_id &&
          a.detector_hash == b.detector_hash;
}

bool FeatureSnapshotRecordsEqual(const FeatureSnapshotProjectionRecord &a, const FeatureSnapshotProjectionRecord &b)
{
   return a.feature_snapshot_id == b.feature_snapshot_id &&
          a.feature_snapshot_hash == b.feature_snapshot_hash &&
          a.feature_vector_hash == b.feature_vector_hash &&
          a.candidate_id == b.candidate_id &&
          a.candidate_hash == b.candidate_hash &&
          a.atr_m15 == b.atr_m15;
}

bool ModelArtifactRecordsEqual(const ModelArtifactProjectionRecord &a, const ModelArtifactProjectionRecord &b)
{
   return a.model_registry_id == b.model_registry_id &&
          a.model_registry_hash == b.model_registry_hash &&
          a.model_artifact_hash == b.model_artifact_hash;
}

bool AIDecisionRecordsEqual(const AIDecisionProjectionRecord &a, const AIDecisionProjectionRecord &b)
{
   return a.ai_decision_id == b.ai_decision_id &&
          a.ai_decision_hash == b.ai_decision_hash &&
          a.feature_snapshot_id == b.feature_snapshot_id &&
          a.model_registry_id == b.model_registry_id &&
          a.decision_outcome == b.decision_outcome;
}

//=====================================================================
void Test_EndToEndLinkage_SingleDecision()
{
   Print("--- end-to-end: context -> candidate -> snapshot -> model -> decision hash/ID linkage matches at every hop ---");
   ResetProjections();
   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   EventStore_Open(TEST_EVENT_STORE_FILE);

   MarketContext ctx; TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact;
   InferenceResult inference; AIDecisionPolicy policy; AIDecision decision;
   Check(BuildFullChain(ctx, c, snapshot, artifact, inference, policy, decision, "E2E", 300), "sanity: full chain built and emitted");
   EventStore_Close();

   AIDecisionProjectionReport report = AIDecisionProjection_RebuildFromFile(TEST_EVENT_STORE_FILE);
   Check(report.ok, "full chain rebuilds from the store alone");

   CandidateProjectionRecord candRec;
   Check(CandidateProjection_TryGet(c.candidate_id, candRec), "candidate is present in the rebuilt CandidateProjection");
   Check(candRec.context_hash == ctx.context_hash, "candidate's persisted context_hash matches the real MarketContext's own context_hash");

   FeatureSnapshotProjectionRecord snapRec;
   Check(FeatureSnapshotProjection_TryGet(snapshot.feature_snapshot_id, snapRec), "snapshot is present in the rebuilt FeatureSnapshotProjection");
   Check(snapRec.candidate_id == c.candidate_id, "snapshot's persisted candidate_id matches the real candidate's own id");
   Check(snapRec.candidate_hash == candRec.candidate_hash, "snapshot and candidate agree on candidate_hash across BOTH projections");

   ModelArtifactProjectionRecord modelRec;
   Check(ModelArtifactProjection_TryGet(artifact.model_registry_id, modelRec), "model artifact is present in the rebuilt ModelArtifactProjection");
   Check(modelRec.model_artifact_hash == artifact.model_artifact_hash, "model artifact's persisted model_artifact_hash matches the real ModelArtifact's own hash");

   AIDecisionProjectionRecord decRec;
   Check(AIDecisionProjection_TryGet(decision.ai_decision_id, decRec), "decision is present in the rebuilt AIDecisionProjection");
   Check(decRec.feature_snapshot_id == snapshot.feature_snapshot_id, "decision's persisted feature_snapshot_id matches the real snapshot's own id");
   Check(decRec.feature_snapshot_hash == snapRec.feature_snapshot_hash, "decision and snapshot agree on feature_snapshot_hash across BOTH projections");
   Check(decRec.model_registry_id == artifact.model_registry_id, "decision's persisted model_registry_id matches the real model artifact's own id");
   Check(decRec.model_registry_hash == modelRec.model_registry_hash, "decision and model artifact agree on model_registry_hash across BOTH projections");
   Check(decision.ai_decision_id == Ids_AIDecisionId(c.candidate_id, artifact.model_registry_id, policy.decision_policy_version),
         "ai_decision_id is deterministically derived from this exact candidate_id + model_registry_id + decision_policy_version");
}

void Test_CrossLayerFailure_CandidateCorrupt_BlocksAIDecision()
{
   Print("--- cross-layer: a corrupted CANDIDATE_CREATED line blocks AIDecisionProjection's rebuild too (via FeatureSnapshotProjection) ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit3_CandLayerFailure.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx; TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact;
   InferenceResult inference; AIDecisionPolicy policy; AIDecision decision;
   Check(BuildFullChain(ctx, c, snapshot, artifact, inference, policy, decision, "CANDFAIL", 310), "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string candidateLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"CANDIDATE_CREATED\"") >= 0) candidateLine = lines[i];
   Check(candidateLine != "", "sanity: the real CANDIDATE_CREATED line was found");

   // Empties candidate_id - stays syntactically valid JSON, but is a
   // structural corruption CandidateProjection_ApplyLine itself
   // rejects. Exercises AIDecisionProjection_RebuildFromFile's chain of
   // prerequisites two levels deep: FeatureSnapshotProjection's own
   // CandidateProjection dependency.
   string tampered = TamperStringField(candidateLine, "candidate_id", "");
   Check(tampered != candidateLine, "sanity: candidate_id was actually tampered");
   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == candidateLine) ? tampered : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);

   int countBefore = AIDecisionProjection_Count();
   AIDecisionProjectionReport report = AIDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "AIDecisionProjection rebuild fails entirely when the candidate layer is corrupted");
   Check(StringFind(report.first_error, "feature snapshot registry") >= 0,
         "first_error attributes the failure to the feature snapshot registry prerequisite, not the decision layer");
   Check(AIDecisionProjection_Count() == countBefore, "AIDecisionProjection's own registry is left untouched by a candidate-layer failure");
}

void Test_CrossLayerFailure_SnapshotCorrupt_BlocksAIDecision()
{
   Print("--- cross-layer: a corrupted FEATURE_SNAPSHOT_CREATED line blocks AIDecisionProjection's rebuild too ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit3_SnapLayerFailure.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx; TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact;
   InferenceResult inference; AIDecisionPolicy policy; AIDecision decision;
   Check(BuildFullChain(ctx, c, snapshot, artifact, inference, policy, decision, "SNAPFAIL", 320), "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string snapLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"FEATURE_SNAPSHOT_CREATED\"") >= 0) snapLine = lines[i];
   Check(snapLine != "", "sanity: the real FEATURE_SNAPSHOT_CREATED line was found");

   string tampered = TamperStringField(snapLine, "feature_snapshot_id", "");
   Check(tampered != snapLine, "sanity: feature_snapshot_id was actually tampered");
   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == snapLine) ? tampered : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);

   int countBefore = AIDecisionProjection_Count();
   AIDecisionProjectionReport report = AIDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "AIDecisionProjection rebuild fails entirely when the snapshot layer is corrupted");
   Check(StringFind(report.first_error, "feature snapshot registry") >= 0,
         "first_error attributes the failure to the feature snapshot registry prerequisite");
   Check(AIDecisionProjection_Count() == countBefore, "AIDecisionProjection's own registry is left untouched by a snapshot-layer failure");
}

void Test_CrossLayerFailure_ModelCorruption_BlocksAIDecisionRebuild()
{
   Print("--- cross-layer: a corrupted MODEL_ARTIFACT_REGISTERED line blocks AIDecisionProjection's rebuild too (independent chain) ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit3_ModelLayerFailure.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx; TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact;
   InferenceResult inference; AIDecisionPolicy policy; AIDecision decision;
   Check(BuildFullChain(ctx, c, snapshot, artifact, inference, policy, decision, "MODELFAIL", 330), "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string modelLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"MODEL_ARTIFACT_REGISTERED\"") >= 0) modelLine = lines[i];
   Check(modelLine != "", "sanity: the real MODEL_ARTIFACT_REGISTERED line was found");

   // This is the point genuinely harder than B7's single-parent case:
   // the candidate/snapshot side of this same store is completely
   // untouched and valid - only the INDEPENDENT model-side prerequisite
   // is corrupted, proving that chain is checked on its own, not merely
   // as a side effect of the feature-snapshot chain's own validation.
   string tampered = TamperStringField(modelLine, "model_registry_id", "");
   Check(tampered != modelLine, "sanity: model_registry_id was actually tampered");
   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == modelLine) ? tampered : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);

   int countBefore = AIDecisionProjection_Count();
   AIDecisionProjectionReport report = AIDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "AIDecisionProjection rebuild fails entirely when the (independent) model layer is corrupted");
   Check(StringFind(report.first_error, "model artifact registry") >= 0,
         "first_error attributes the failure to the model artifact registry prerequisite, not the feature snapshot side");
   Check(AIDecisionProjection_Count() == countBefore, "AIDecisionProjection's own registry is left untouched by a model-layer failure");
}

void Test_FullChainRestartSimulation_MultiDecision()
{
   Print("--- full-chain restart: repeated rebuilds of a multi-decision store reconstruct byte-identical state in ALL FOUR projections ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit3_MultiRestart.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctxs[]; TradeCandidate candidates[]; FeatureSnapshot snapshots[]; ModelArtifact artifacts[];
   InferenceResult inferences[]; AIDecisionPolicy policies[]; AIDecision decisions[];
   Check(BuildThreeChains(ctxs, candidates, snapshots, artifacts, inferences, policies, decisions, "RESTART", 340, false),
         "sanity: three full chains built and emitted");
   EventStore_Close();

   AIDecisionProjectionReport report1 = AIDecisionProjection_RebuildFromFile(file);
   Check(report1.ok && CandidateProjection_Count() == 3 && FeatureSnapshotProjection_Count() == 3 &&
         ModelArtifactProjection_Count() == 3 && AIDecisionProjection_Count() == 3,
         "first rebuild: 3 candidates + 3 snapshots + 3 model artifacts + 3 decisions");

   CandidateProjectionRecord candBefore[3];
   FeatureSnapshotProjectionRecord snapBefore[3];
   ModelArtifactProjectionRecord modelBefore[3];
   AIDecisionProjectionRecord decBefore[3];
   for(int i = 0; i < 3; i++)
   {
      CandidateProjection_TryGet(candidates[i].candidate_id, candBefore[i]);
      FeatureSnapshotProjection_TryGet(snapshots[i].feature_snapshot_id, snapBefore[i]);
      ModelArtifactProjection_TryGet(artifacts[i].model_registry_id, modelBefore[i]);
      AIDecisionProjection_TryGet(decisions[i].ai_decision_id, decBefore[i]);
   }

   AIDecisionProjectionReport report2 = AIDecisionProjection_RebuildFromFile(file); // simulate a restart: rebuild again
   Check(report2.ok && CandidateProjection_Count() == 3 && FeatureSnapshotProjection_Count() == 3 &&
         ModelArtifactProjection_Count() == 3 && AIDecisionProjection_Count() == 3,
         "second rebuild (simulated restart): still 3 candidates + 3 snapshots + 3 model artifacts + 3 decisions");

   bool allCandidatesMatch = true, allSnapshotsMatch = true, allModelsMatch = true, allDecisionsMatch = true;
   for(int i = 0; i < 3; i++)
   {
      CandidateProjectionRecord candAfter;
      FeatureSnapshotProjectionRecord snapAfter;
      ModelArtifactProjectionRecord modelAfter;
      AIDecisionProjectionRecord decAfter;
      CandidateProjection_TryGet(candidates[i].candidate_id, candAfter);
      FeatureSnapshotProjection_TryGet(snapshots[i].feature_snapshot_id, snapAfter);
      ModelArtifactProjection_TryGet(artifacts[i].model_registry_id, modelAfter);
      AIDecisionProjection_TryGet(decisions[i].ai_decision_id, decAfter);
      if(!CandidateRecordsEqual(candBefore[i], candAfter))             allCandidatesMatch = false;
      if(!FeatureSnapshotRecordsEqual(snapBefore[i], snapAfter))       allSnapshotsMatch = false;
      if(!ModelArtifactRecordsEqual(modelBefore[i], modelAfter))       allModelsMatch = false;
      if(!AIDecisionRecordsEqual(decBefore[i], decAfter))              allDecisionsMatch = false;
   }
   Check(allCandidatesMatch, "every CandidateProjection record is byte-identical across both rebuilds");
   Check(allSnapshotsMatch, "every FeatureSnapshotProjection record is byte-identical across both rebuilds");
   Check(allModelsMatch, "every ModelArtifactProjection record is byte-identical across both rebuilds");
   Check(allDecisionsMatch, "every AIDecisionProjection record is byte-identical across both rebuilds");
}

void Test_MultiCandidateMultiModelCrossLinking()
{
   Print("--- multi-candidate, multi-model: every decision links to exactly its own snapshot and its own model, never a neighbor's ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B8_5_Commit3_CrossLink.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctxs[]; TradeCandidate candidates[]; FeatureSnapshot snapshots[]; ModelArtifact artifacts[];
   InferenceResult inferences[]; AIDecisionPolicy policies[]; AIDecision decisions[];
   Check(BuildThreeChains(ctxs, candidates, snapshots, artifacts, inferences, policies, decisions, "XLINK", 350, true),
         "sanity: three full chains built (0 and 2 sharing one model, 1 with its own) and emitted");
   Check(artifacts[0].model_registry_id == artifacts[2].model_registry_id, "sanity: candidates 0 and 2 really do share one model_registry_id");
   Check(artifacts[1].model_registry_id != artifacts[0].model_registry_id, "sanity: candidate 1 really does use a distinct model_registry_id");
   EventStore_Close();

   AIDecisionProjectionReport report = AIDecisionProjection_RebuildFromFile(file);
   Check(report.ok, "multi-candidate, multi-model rebuild succeeds");

   for(int i = 0; i < 3; i++)
   {
      AIDecisionProjectionRecord decRec;
      Check(AIDecisionProjection_TryGet(decisions[i].ai_decision_id, decRec), StringFormat("decision %d found in the rebuilt registry", i));
      Check(decRec.feature_snapshot_id == snapshots[i].feature_snapshot_id, StringFormat("decision %d links to its OWN feature_snapshot_id", i));
      Check(decRec.model_registry_id == artifacts[i].model_registry_id, StringFormat("decision %d links to its OWN model_registry_id", i));

      for(int j = 0; j < 3; j++)
      {
         if(j == i) continue;
         Check(decRec.feature_snapshot_id != snapshots[j].feature_snapshot_id,
               StringFormat("decision %d does NOT link to snapshot %d", i, j));
      }
   }
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B8.5 Commit 3 - Full-Chain Integration + Regression Proof ===");

   Test_EndToEndLinkage_SingleDecision();
   Test_CrossLayerFailure_CandidateCorrupt_BlocksAIDecision();
   Test_CrossLayerFailure_SnapshotCorrupt_BlocksAIDecision();
   Test_CrossLayerFailure_ModelCorruption_BlocksAIDecisionRebuild();
   Test_FullChainRestartSimulation_MultiDecision();
   Test_MultiCandidateMultiModelCrossLinking();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");

   Print("=== Manual regression checklist (per the B8.5 Commit 3 addendum) - re-run each of these in the same MetaEditor session and confirm ALL PASS: ===");
   Print("  MLQuantAI_Test_B8_1_FeatureSnapshot.mq5");
   Print("  MLQuantAI_Test_B8_3_ModelRegistry.mq5");
   Print("  MLQuantAI_Test_B8_5_AIDecision.mq5");
   Print("  MLQuantAI_Test_B8_5_Commit2_AIDecisionEvent.mq5");
}
