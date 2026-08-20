//+------------------------------------------------------------------+
//| MLQuantAI_Test_B9_Commit3_IntegrationRegression.mq5                |
//| Phase B9 Commit 3 DoD, per                                         |
//| Docs/PhaseB_B9_ExecutionEligibilityContract.md's Commit 3 addendum: |
//| proves the full MARKET_CONTEXT_READY -> CANDIDATE_CREATED ->        |
//| FEATURE_SNAPSHOT_CREATED (+ MODEL_ARTIFACT_REGISTERED, independent) |
//| -> AI_DECISION_CREATED, RISK_PLAN_CREATED (independent) ->          |
//| EligibilityDecision_Build -> EXECUTION_ELIGIBILITY_DECIDED (+       |
//| CANDIDATE_REJECTED_BY_RISK, REJECTED only) -> Restart/Replay chain  |
//| composes correctly end to end, across all THREE independent         |
//| upstream chains feeding EligibilityDecisionProjection. Adds ZERO    |
//| new production behavior - no B5/B7/B8/B9-Commit-1/B9-Commit-2       |
//| sealed file touched. Does NOT re-prove anything already covered by  |
//| Test_B9_ExecutionEligibility.mq5 or                                 |
//| Test_B9_Commit2_EligibilityEvent.mq5's own suites - see the         |
//| addendum for exactly what is genuinely new here: end-to-end linkage |
//| in one place, cross-layer failure propagation for all THREE         |
//| upstream chains independently, full-chain multi-decision restart,   |
//| multi-candidate cross-linking, and rejected-without-lifecycle-      |
//| consequence reconciliation.                                         |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RiskPlanEventEmission.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_FeatureSnapshotEventEmission.mqh>
#include <MLQuantAI/AI/MLQuantAI_ModelArtifactBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ModelArtifactEventEmission.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityEventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_StateProjector.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as Test_B9_Commit2_EligibilityEvent.mq5
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
   ctx.context_event_id = "CTX_b9c3_" + suffix;
   ctx.context_hash      = "test_context_hash_b9c3_" + suffix;
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

void BuildValidRiskContext(RiskContext &ctx, string suffix)
{
   RiskContext_Init(ctx);
   ctx.symbol_spec.instrument_id = "XAUUSD";
   ctx.symbol_spec.broker_symbol = "XAUUSD" + suffix;
   ctx.symbol_spec.tick_size     = 0.01;
   ctx.symbol_spec.tick_value    = 1.0;
   ctx.symbol_spec.contract_size = 100;
   ctx.symbol_spec.volume_min    = 0.01;
   ctx.symbol_spec.volume_max    = 100.0;
   ctx.symbol_spec.volume_step   = 0.01;
   ctx.symbol_spec.digits        = 2;

   ctx.account.balance = 10000.0;
   ctx.account.equity  = 10000.0;

   ctx.target_risk_percent  = 1.0;
   ctx.sizing_method        = "FIXED_PERCENT_RISK";
   ctx.sizing_rules_version = MLQUANTAI_RISK_SIZING_RULES_V1;

   ctx.risk_context_hash = RiskContext_ComputeHash(ctx);
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

void BuildHealthyContext(EligibilityContext &context)
{
   EligibilityContext_Init(context);
   context.account.balance = 10000.0;
   context.account.equity = 10000.0;
   context.account.margin_level = 500.0;
   context.account.open_positions_count = 0;
   context.account.open_risk_percent = 0.0;
   context.account.daily_pnl_percent = 0.0;
   context.account.drawdown_from_peak_percent = 0.0;
   context.safe_mode_active = false;
   context.eligibility_context_hash = EligibilityContext_ComputeHash(context);
}

void BuildEnabledEligibilityPolicy(EligibilityPolicy &policy)
{
   EligibilityPolicy_Init(policy);
   policy.eligibility_policy_version = "ELIGPOLICY_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
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
   RiskPlanProjection_Reset();
   EligibilityDecisionProjection_Reset();
   StateProjector_Reset();
}

// Rewrites fileName, replacing every line equal to oldLine with newLine
// - used by the cross-layer failure tests to swap in a tampered line
// without disturbing any other line's own sequence number.
void RewriteFile(string fileName, string &lines[], int n, string oldLine, string newLine)
{
   FileDelete(fileName, FILE_COMMON);
   int h = FileOpen(fileName, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == oldLine) ? newLine : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);
}

// Builds AND emits every layer of the real chain for one eligibility
// decision (MARKET_CONTEXT_READY, CANDIDATE_CREATED, FEATURE_SNAPSHOT_CREATED,
// MODEL_ARTIFACT_REGISTERED, AI_DECISION_CREATED, RISK_PLAN_CREATED,
// EXECUTION_ELIGIBILITY_DECIDED, and CANDIDATE_REJECTED_BY_RISK if
// REJECTED) - unlike Commit 2's own BuildFullChain, this ALSO emits the
// eligibility decision itself, since Commit 3's whole point is checking
// the full persisted chain, not leaving the last hop to the caller.
// dayOffset must be unique within one event store file (see the same
// lesson from every prior test file's own history).
// emitAndWireLifecycle=false skips EligibilityDecision_EmitDecisionAndWireLifecycle
// entirely and instead writes ONLY the EXECUTION_ELIGIBILITY_DECIDED
// line directly (mirroring that function's own first half) - used by
// the reconciliation test to simulate "the lifecycle write never
// happened" WITHOUT ever allocating a sequence number for it. Dropping
// an already-written line from the file afterwards would instead trip
// EventStoreValidator's own gapless-sequence-number requirement for the
// wrong reason (a sequence gap, not the reconciliation scenario) - never
// allocating the number in the first place is what "never wrote it"
// actually means.
bool BuildFullChain(MarketContext &ctx, TradeCandidate &c, FeatureSnapshot &snapshot, ModelArtifact &artifact,
                      InferenceResult &inference, RiskPlan &plan, AIDecision &decision, EligibilityContext &context,
                      EligibilityPolicy &policy, EligibilityDecision &eligDecision, string suffix, int dayOffset,
                      float pSuccessValue = 0.90f, double aiThreshold = 0.70, bool emitAndWireLifecycle = true)
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
   AIDecisionPolicy aiPolicy;
   AIDecisionPolicy_Init(aiPolicy);
   aiPolicy.decision_policy_version = "AIPOLICY_V1";
   aiPolicy.threshold_version       = "THRESH_V1";
   aiPolicy.allow_threshold         = aiThreshold;
   string aiReasonDetail;
   if(!AIDecision_Build(inference, snapshot, aiPolicy, decision, aiReasonDetail)) return false;
   if(!AIDecision_EmitAIDecisionCreated(decision)) return false;

   RiskContext riskCtx; BuildValidRiskContext(riskCtx, suffix);
   if(!Candidate_ToRiskPlan(c, riskCtx, plan)) return false;
   if(!RiskPlan_EmitRiskPlanCreated(plan)) return false;

   BuildHealthyContext(context);
   BuildEnabledEligibilityPolicy(policy);

   string eligReasonDetail;
   if(!EligibilityDecision_Build(plan, decision, snapshot, context, policy, eligDecision, eligReasonDetail)) return false;

   if(!emitAndWireLifecycle)
   {
      string extraJson = EligibilityDecision_ToExtraJson(eligDecision, context);
      if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED), "execution eligibility decided", extraJson))
         return false;
      EligibilityDecisionProjection_ApplyLiveRecord(eligDecision, context);
      return true;
   }

   return EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, context, c);
}

bool BuildThreeChains(MarketContext &ctxs[], TradeCandidate &candidates[], FeatureSnapshot &snapshots[],
                        ModelArtifact &artifacts[], InferenceResult &inferences[], RiskPlan &plans[],
                        AIDecision &decisions[], EligibilityContext &contexts[], EligibilityPolicy &policies[],
                        EligibilityDecision &eligDecisions[], string suffixPrefix, int baseDayOffset)
{
   ArrayResize(ctxs, 3); ArrayResize(candidates, 3); ArrayResize(snapshots, 3); ArrayResize(artifacts, 3);
   ArrayResize(inferences, 3); ArrayResize(plans, 3); ArrayResize(decisions, 3); ArrayResize(contexts, 3);
   ArrayResize(policies, 3); ArrayResize(eligDecisions, 3);

   // Mixed outcomes on purpose: 0 and 2 ELIGIBLE (p_success above
   // threshold), 1 REJECTED (below threshold, via REASON_AI_REJECT) -
   // proving restart/cross-linking hold regardless of verdict mix.
   float pVals[3] = {0.90f, 0.30f, 0.85f};
   for(int i = 0; i < 3; i++)
   {
      if(!BuildFullChain(ctxs[i], candidates[i], snapshots[i], artifacts[i], inferences[i], plans[i], decisions[i],
                           contexts[i], policies[i], eligDecisions[i], suffixPrefix + IntegerToString(i),
                           baseDayOffset + i, pVals[i], 0.70))
         return false;
   }
   return true;
}

bool CandidateRecordsEqual(const CandidateProjectionRecord &a, const CandidateProjectionRecord &b)
{
   return a.candidate_id == b.candidate_id && a.candidate_hash == b.candidate_hash &&
          a.context_hash == b.context_hash && a.context_event_id == b.context_event_id;
}

bool FeatureSnapshotRecordsEqual(const FeatureSnapshotProjectionRecord &a, const FeatureSnapshotProjectionRecord &b)
{
   return a.feature_snapshot_id == b.feature_snapshot_id && a.feature_snapshot_hash == b.feature_snapshot_hash &&
          a.candidate_id == b.candidate_id && a.candidate_hash == b.candidate_hash;
}

bool ModelArtifactRecordsEqual(const ModelArtifactProjectionRecord &a, const ModelArtifactProjectionRecord &b)
{
   return a.model_registry_id == b.model_registry_id && a.model_registry_hash == b.model_registry_hash &&
          a.model_artifact_hash == b.model_artifact_hash;
}

bool AIDecisionRecordsEqual(const AIDecisionProjectionRecord &a, const AIDecisionProjectionRecord &b)
{
   return a.ai_decision_id == b.ai_decision_id && a.ai_decision_hash == b.ai_decision_hash &&
          a.feature_snapshot_id == b.feature_snapshot_id && a.model_registry_id == b.model_registry_id &&
          a.decision_outcome == b.decision_outcome;
}

bool RiskPlanRecordsEqual(const RiskPlanProjectionRecord &a, const RiskPlanProjectionRecord &b)
{
   return a.risk_plan_id == b.risk_plan_id && a.plan_hash == b.plan_hash &&
          a.candidate_id == b.candidate_id && a.candidate_hash == b.candidate_hash;
}

bool EligibilityDecisionRecordsEqual(const EligibilityDecisionProjectionRecord &a, const EligibilityDecisionProjectionRecord &b)
{
   return a.eligibility_decision_id == b.eligibility_decision_id && a.eligibility_decision_hash == b.eligibility_decision_hash &&
          a.candidate_id == b.candidate_id && a.risk_plan_id == b.risk_plan_id && a.ai_decision_id == b.ai_decision_id &&
          a.decision == b.decision && a.reason_code == b.reason_code;
}

// New, test-only reconciliation helper (per the Commit 3 addendum) -
// NOT production code, does not exist anywhere under Include/. Scans a
// rebuilt EligibilityDecisionProjection for every REJECTED record and
// cross-checks each against StateProjector_TryGetState (never
// CandidateProjection, which by design only ever tracks
// CANDIDATE_CREATED) for that record's own candidate_id. Reports every
// REJECTED decision whose candidate is NOT at CANDIDATE_REJECTED_BY_RISK
// as an inconsistency - detection only, no recovery/rewrite of
// anything, per Commit 2's own frozen non-rollback rule.
int FindRejectedWithoutLifecycleConsequence(string &outInconsistentIds[])
{
   ArrayResize(outInconsistentIds, 0);
   int found = 0;
   int n = EligibilityDecisionProjection_Count();
   for(int i = 0; i < n; i++)
   {
      EligibilityDecisionProjectionRecord rec;
      if(!EligibilityDecisionProjection_GetAt(i, rec)) continue;
      if(rec.decision != ELIGIBILITY_DECISION_REJECTED) continue;

      ENUM_CANDIDATE_STATE state;
      bool stateFound = StateProjector_TryGetState(rec.candidate_id, state);
      if(!stateFound || state != CANDIDATE_REJECTED_BY_RISK)
      {
         ArrayResize(outInconsistentIds, found + 1);
         outInconsistentIds[found] = rec.candidate_id;
         found++;
      }
   }
   return found;
}

//=====================================================================
void Test_EndToEndLinkage_SingleDecision()
{
   Print("--- end-to-end: context -> candidate -> snapshot -> (model -> AI decision) + risk plan -> eligibility decision linkage matches at every hop ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit3_E2E.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx; TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   Check(BuildFullChain(ctx, c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision, "E2E", 400),
         "sanity: full chain built and emitted");
   EventStore_Close();

   EligibilityDecisionProjectionReport report = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(report.ok, "full six-layer chain rebuilds from the store alone");

   CandidateProjectionRecord candRec;
   Check(CandidateProjection_TryGet(c.candidate_id, candRec), "candidate is present in the rebuilt CandidateProjection");
   Check(candRec.context_hash == ctx.context_hash, "candidate's persisted context_hash matches the real MarketContext's own context_hash");

   FeatureSnapshotProjectionRecord snapRec;
   Check(FeatureSnapshotProjection_TryGet(snapshot.feature_snapshot_id, snapRec), "snapshot is present in the rebuilt FeatureSnapshotProjection");
   Check(snapRec.candidate_hash == candRec.candidate_hash, "snapshot and candidate agree on candidate_hash across BOTH projections");

   ModelArtifactProjectionRecord modelRec;
   Check(ModelArtifactProjection_TryGet(artifact.model_registry_id, modelRec), "model artifact is present in the rebuilt ModelArtifactProjection");

   AIDecisionProjectionRecord decRec;
   Check(AIDecisionProjection_TryGet(decision.ai_decision_id, decRec), "AI decision is present in the rebuilt AIDecisionProjection");
   Check(decRec.feature_snapshot_hash == snapRec.feature_snapshot_hash, "AI decision and snapshot agree on feature_snapshot_hash across BOTH projections");
   Check(decRec.model_registry_hash == modelRec.model_registry_hash, "AI decision and model artifact agree on model_registry_hash across BOTH projections");

   RiskPlanProjectionRecord planRec;
   Check(RiskPlanProjection_TryGet(plan.risk_plan_id, planRec), "risk plan is present in the rebuilt RiskPlanProjection");
   Check(planRec.candidate_hash == candRec.candidate_hash, "risk plan and candidate agree on candidate_hash across BOTH projections");

   EligibilityDecisionProjectionRecord eligRec;
   Check(EligibilityDecisionProjection_TryGet(eligDecision.eligibility_decision_id, eligRec), "eligibility decision is present in the rebuilt EligibilityDecisionProjection");
   Check(eligRec.candidate_hash == candRec.candidate_hash, "eligibility decision and candidate agree on candidate_hash");
   Check(eligRec.risk_plan_id == plan.risk_plan_id && eligRec.plan_hash == planRec.plan_hash,
         "eligibility decision's persisted risk_plan_id/plan_hash match the real RiskPlanProjection record");
   Check(eligRec.ai_decision_id == decision.ai_decision_id && eligRec.ai_decision_hash == decRec.ai_decision_hash,
         "eligibility decision's persisted ai_decision_id/ai_decision_hash match the real AIDecisionProjection record");
   Check(eligDecision.eligibility_decision_id == Ids_EligibilityDecisionId(c.candidate_id, policy.eligibility_policy_version),
         "eligibility_decision_id is deterministically derived from this exact candidate_id + eligibility_policy_version");
}

void Test_CrossLayerFailure_CandidateCorrupt_BlocksEligibility()
{
   Print("--- cross-layer: a corrupted CANDIDATE_CREATED line blocks eligibility rebuild too (via RiskPlanProjection's own CandidateProjection dependency) ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit3_CandLayerFailure.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx; TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   Check(BuildFullChain(ctx, c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision, "CANDFAIL", 410),
         "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string candidateLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"CANDIDATE_CREATED\"") >= 0) candidateLine = lines[i];
   Check(candidateLine != "", "sanity: the real CANDIDATE_CREATED line was found");

   string tampered = TamperStringField(candidateLine, "candidate_id", "");
   Check(tampered != candidateLine, "sanity: candidate_id was actually tampered");
   RewriteFile(file, lines, n, candidateLine, tampered);

   EligibilityDecisionProjectionReport report = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "eligibility rebuild fails entirely when the candidate layer is corrupted");
   Check(StringFind(report.first_error, "risk plan registry") >= 0 && StringFind(report.first_error, "candidate registry") >= 0,
         "first_error attributes the failure to the risk plan registry prerequisite, nested with the candidate registry it itself depends on");
}

void Test_CrossLayerFailure_RiskPlanCorrupt_BlocksEligibility()
{
   Print("--- cross-layer: a corrupted RISK_PLAN_CREATED line blocks eligibility rebuild too (independent chain, not via the candidate layer) ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit3_PlanLayerFailure.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx; TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   Check(BuildFullChain(ctx, c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision, "PLANFAIL", 420),
         "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string planLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"RISK_PLAN_CREATED\"") >= 0) planLine = lines[i];
   Check(planLine != "", "sanity: the real RISK_PLAN_CREATED line was found");

   // This is the point genuinely harder than a single-parent case: the
   // candidate/snapshot/model/AI-decision side of this same store is
   // completely untouched and valid - only the INDEPENDENT risk-plan
   // line's own required field is corrupted, proving that chain is
   // checked on its own, not merely as a side effect of candidate-layer
   // validation.
   string tampered = TamperStringField(planLine, "risk_plan_id", "");
   Check(tampered != planLine, "sanity: risk_plan_id was actually tampered");
   RewriteFile(file, lines, n, planLine, tampered);

   EligibilityDecisionProjectionReport report = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "eligibility rebuild fails entirely when the (independent) risk plan layer is corrupted");
   Check(StringFind(report.first_error, "risk plan registry") >= 0 && StringFind(report.first_error, "candidate registry") < 0,
         "first_error attributes the failure to the risk plan registry itself, NOT the candidate registry - proving this is a distinct failure path from candidate corruption");
}

void Test_CrossLayerFailure_ModelCorrupt_BlocksEligibility()
{
   Print("--- cross-layer: a corrupted MODEL_ARTIFACT_REGISTERED line blocks eligibility rebuild too (via AIDecisionProjection's own ModelArtifactProjection dependency) ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit3_ModelLayerFailure.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx; TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   Check(BuildFullChain(ctx, c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision, "MODELFAIL", 430),
         "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string modelLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"MODEL_ARTIFACT_REGISTERED\"") >= 0) modelLine = lines[i];
   Check(modelLine != "", "sanity: the real MODEL_ARTIFACT_REGISTERED line was found");

   string tampered = TamperStringField(modelLine, "model_registry_id", "");
   Check(tampered != modelLine, "sanity: model_registry_id was actually tampered");
   RewriteFile(file, lines, n, modelLine, tampered);

   EligibilityDecisionProjectionReport report = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "eligibility rebuild fails entirely when the (independent) model artifact layer is corrupted");
   Check(StringFind(report.first_error, "AI decision registry") >= 0 && StringFind(report.first_error, "model artifact registry") >= 0,
         "first_error attributes the failure to the AI decision registry prerequisite, nested with the model artifact registry it itself depends on");
}

void Test_FullChainRestartSimulation_MultiDecision()
{
   Print("--- full-chain restart: repeated rebuilds of a multi-decision store reconstruct byte-identical state in ALL SIX projections ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit3_MultiRestart.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctxs[]; TradeCandidate candidates[]; FeatureSnapshot snapshots[]; ModelArtifact artifacts[];
   InferenceResult inferences[]; RiskPlan plans[]; AIDecision decisions[]; EligibilityContext contexts[];
   EligibilityPolicy policies[]; EligibilityDecision eligDecisions[];
   Check(BuildThreeChains(ctxs, candidates, snapshots, artifacts, inferences, plans, decisions, contexts, policies,
                            eligDecisions, "RESTART", 440),
         "sanity: three full chains built and emitted (mixed ELIGIBLE/REJECTED)");
   EventStore_Close();

   EligibilityDecisionProjectionReport report1 = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(report1.ok && CandidateProjection_Count() == 3 && FeatureSnapshotProjection_Count() == 3 &&
         ModelArtifactProjection_Count() == 3 && AIDecisionProjection_Count() == 3 &&
         RiskPlanProjection_Count() == 3 && EligibilityDecisionProjection_Count() == 3,
         "first rebuild: 3 candidates + 3 snapshots + 3 models + 3 AI decisions + 3 risk plans + 3 eligibility decisions");

   CandidateProjectionRecord candBefore[3];
   FeatureSnapshotProjectionRecord snapBefore[3];
   ModelArtifactProjectionRecord modelBefore[3];
   AIDecisionProjectionRecord decBefore[3];
   RiskPlanProjectionRecord planBefore[3];
   EligibilityDecisionProjectionRecord eligBefore[3];
   for(int i = 0; i < 3; i++)
   {
      CandidateProjection_TryGet(candidates[i].candidate_id, candBefore[i]);
      FeatureSnapshotProjection_TryGet(snapshots[i].feature_snapshot_id, snapBefore[i]);
      ModelArtifactProjection_TryGet(artifacts[i].model_registry_id, modelBefore[i]);
      AIDecisionProjection_TryGet(decisions[i].ai_decision_id, decBefore[i]);
      RiskPlanProjection_TryGet(plans[i].risk_plan_id, planBefore[i]);
      EligibilityDecisionProjection_TryGet(eligDecisions[i].eligibility_decision_id, eligBefore[i]);
   }

   EligibilityDecisionProjectionReport report2 = EligibilityDecisionProjection_RebuildFromFile(file); // simulate a restart
   Check(report2.ok && CandidateProjection_Count() == 3 && FeatureSnapshotProjection_Count() == 3 &&
         ModelArtifactProjection_Count() == 3 && AIDecisionProjection_Count() == 3 &&
         RiskPlanProjection_Count() == 3 && EligibilityDecisionProjection_Count() == 3,
         "second rebuild (simulated restart): counts unchanged across all six projections");

   bool allCandidatesMatch = true, allSnapshotsMatch = true, allModelsMatch = true,
        allDecisionsMatch = true, allPlansMatch = true, allEligMatch = true;
   for(int i = 0; i < 3; i++)
   {
      CandidateProjectionRecord candAfter; FeatureSnapshotProjectionRecord snapAfter;
      ModelArtifactProjectionRecord modelAfter; AIDecisionProjectionRecord decAfter;
      RiskPlanProjectionRecord planAfter; EligibilityDecisionProjectionRecord eligAfter;
      CandidateProjection_TryGet(candidates[i].candidate_id, candAfter);
      FeatureSnapshotProjection_TryGet(snapshots[i].feature_snapshot_id, snapAfter);
      ModelArtifactProjection_TryGet(artifacts[i].model_registry_id, modelAfter);
      AIDecisionProjection_TryGet(decisions[i].ai_decision_id, decAfter);
      RiskPlanProjection_TryGet(plans[i].risk_plan_id, planAfter);
      EligibilityDecisionProjection_TryGet(eligDecisions[i].eligibility_decision_id, eligAfter);
      if(!CandidateRecordsEqual(candBefore[i], candAfter))             allCandidatesMatch = false;
      if(!FeatureSnapshotRecordsEqual(snapBefore[i], snapAfter))       allSnapshotsMatch = false;
      if(!ModelArtifactRecordsEqual(modelBefore[i], modelAfter))       allModelsMatch = false;
      if(!AIDecisionRecordsEqual(decBefore[i], decAfter))              allDecisionsMatch = false;
      if(!RiskPlanRecordsEqual(planBefore[i], planAfter))              allPlansMatch = false;
      if(!EligibilityDecisionRecordsEqual(eligBefore[i], eligAfter))   allEligMatch = false;
   }
   Check(allCandidatesMatch, "every CandidateProjection record is byte-identical across both rebuilds");
   Check(allSnapshotsMatch, "every FeatureSnapshotProjection record is byte-identical across both rebuilds");
   Check(allModelsMatch, "every ModelArtifactProjection record is byte-identical across both rebuilds");
   Check(allDecisionsMatch, "every AIDecisionProjection record is byte-identical across both rebuilds");
   Check(allPlansMatch, "every RiskPlanProjection record is byte-identical across both rebuilds");
   Check(allEligMatch, "every EligibilityDecisionProjection record is byte-identical across both rebuilds");

   // ELIGIBLE candidates (0 and 2) leave no lifecycle trace even after a
   // real restart/replay of a MULTI-candidate store; the REJECTED one
   // (1) does, confirmed via StateProjector (not CandidateProjection,
   // which by design only ever tracks CANDIDATE_CREATED).
   ReplayReport replay = ReplayEngine_Run(file);
   Check(replay.ok, "sanity: full replay of the multi-decision store succeeds");
   ENUM_CANDIDATE_STATE state0, state1, state2;
   Check(StateProjector_TryGetState(candidates[0].candidate_id, state0) && state0 == CANDIDATE_CREATED,
         "ELIGIBLE candidate 0 stays at CANDIDATE_CREATED after full-chain replay");
   Check(StateProjector_TryGetState(candidates[1].candidate_id, state1) && state1 == CANDIDATE_REJECTED_BY_RISK,
         "REJECTED candidate 1 reaches CANDIDATE_REJECTED_BY_RISK after full-chain replay");
   Check(StateProjector_TryGetState(candidates[2].candidate_id, state2) && state2 == CANDIDATE_CREATED,
         "ELIGIBLE candidate 2 stays at CANDIDATE_CREATED after full-chain replay");
}

void Test_MultiCandidateCrossLinking()
{
   Print("--- multi-candidate: every eligibility decision links to exactly its own risk plan and its own AI decision, never a neighbor's ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit3_CrossLink.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctxs[]; TradeCandidate candidates[]; FeatureSnapshot snapshots[]; ModelArtifact artifacts[];
   InferenceResult inferences[]; RiskPlan plans[]; AIDecision decisions[]; EligibilityContext contexts[];
   EligibilityPolicy policies[]; EligibilityDecision eligDecisions[];
   Check(BuildThreeChains(ctxs, candidates, snapshots, artifacts, inferences, plans, decisions, contexts, policies,
                            eligDecisions, "XLINK", 450),
         "sanity: three full chains built and emitted");
   EventStore_Close();

   EligibilityDecisionProjectionReport report = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(report.ok, "multi-candidate rebuild succeeds");

   for(int i = 0; i < 3; i++)
   {
      EligibilityDecisionProjectionRecord eligRec;
      Check(EligibilityDecisionProjection_TryGet(eligDecisions[i].eligibility_decision_id, eligRec),
            StringFormat("eligibility decision %d found in the rebuilt registry", i));
      Check(eligRec.risk_plan_id == plans[i].risk_plan_id, StringFormat("eligibility decision %d links to its OWN risk_plan_id", i));
      Check(eligRec.ai_decision_id == decisions[i].ai_decision_id, StringFormat("eligibility decision %d links to its OWN ai_decision_id", i));

      for(int j = 0; j < 3; j++)
      {
         if(j == i) continue;
         Check(eligRec.risk_plan_id != plans[j].risk_plan_id, StringFormat("eligibility decision %d does NOT link to risk plan %d", i, j));
         Check(eligRec.ai_decision_id != decisions[j].ai_decision_id, StringFormat("eligibility decision %d does NOT link to AI decision %d", i, j));
      }
   }
}

void Test_RejectedWithoutLifecycleConsequence_Reconciliation()
{
   Print("--- reconciliation: a REJECTED decision event whose paired CANDIDATE_REJECTED_BY_RISK line never made it into the store is detected deterministically ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit3_Reconcile.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx; TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   // AI REJECT drives ELIGIBILITY_DECISION_REJECTED via the frozen
   // precedence order. emitAndWireLifecycle=false simulates the
   // non-rollback failure mode Commit 2's own contract froze: the
   // EXECUTION_ELIGIBILITY_DECIDED write succeeds and is durable, but
   // the lifecycle write is never even attempted - so no
   // CANDIDATE_REJECTED_BY_RISK sequence number is ever allocated
   // (never "written then removed," which would corrupt sequence
   // continuity for an unrelated reason).
   Check(BuildFullChain(ctx, c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision,
                          "RECONCILE", 460, 0.30f, 0.70, false),
         "sanity: full chain built, decision event emitted, lifecycle wiring deliberately skipped");
   Check(eligDecision.decision == ELIGIBILITY_DECISION_REJECTED, "sanity: decision is REJECTED");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   bool lifecycleLineExists = false;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"CANDIDATE_REJECTED_BY_RISK\"") >= 0) lifecycleLineExists = true;
   Check(!lifecycleLineExists, "sanity: no CANDIDATE_REJECTED_BY_RISK line exists in this store at all");

   ResetProjections();
   EligibilityDecisionProjectionReport report = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(report.ok, "eligibility rebuild itself still succeeds - the decision event alone is a structurally complete, valid line");
   ReplayReport replay = ReplayEngine_Run(file);
   Check(replay.ok, "replay of the store still succeeds - a missing lifecycle line is not itself corruption");

   string inconsistentIds[];
   int foundCount = FindRejectedWithoutLifecycleConsequence(inconsistentIds);
   Check(foundCount == 1, "reconciliation finds exactly one REJECTED decision without its lifecycle consequence");
   Check(foundCount == 1 && inconsistentIds[0] == c.candidate_id,
         "the flagged candidate_id is exactly the one whose lifecycle line was dropped");

   // Negative case, same helper, on the CLEAN full-chain store from
   // Test_EndToEndLinkage_SingleDecision's own fixture shape (rebuilt
   // fresh here to avoid any cross-test state leakage) - no false
   // positives on a store where the lifecycle write really did happen.
   ResetProjections();
   string cleanFile = "MLQuantAI_Test_B9_Commit3_ReconcileClean.jsonl";
   FileDelete(cleanFile, FILE_COMMON);
   EventStore_Open(cleanFile);
   MarketContext ctx2; TradeCandidate c2; FeatureSnapshot snapshot2; ModelArtifact artifact2; InferenceResult inference2;
   RiskPlan plan2; AIDecision decision2; EligibilityContext context2; EligibilityPolicy policy2; EligibilityDecision eligDecision2;
   Check(BuildFullChain(ctx2, c2, snapshot2, artifact2, inference2, plan2, decision2, context2, policy2, eligDecision2,
                          "RECONCILECLEAN", 461, 0.30f, 0.70),
         "sanity: second full chain built and emitted, REJECTED verdict, lifecycle line intact this time");
   EventStore_Close();
   EligibilityDecisionProjectionReport cleanReport = EligibilityDecisionProjection_RebuildFromFile(cleanFile);
   Check(cleanReport.ok, "sanity: clean store rebuilds fine");
   ReplayReport cleanReplay = ReplayEngine_Run(cleanFile);
   Check(cleanReplay.ok, "sanity: clean store replays fine");
   string noneFound[];
   int cleanCount = FindRejectedWithoutLifecycleConsequence(noneFound);
   Check(cleanCount == 0, "reconciliation reports zero inconsistencies on a store where every REJECTED decision has its lifecycle consequence - no false positives");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B9 Commit 3 - Full-Chain Integration + Regression Proof ===");

   Test_EndToEndLinkage_SingleDecision();
   Test_CrossLayerFailure_CandidateCorrupt_BlocksEligibility();
   Test_CrossLayerFailure_RiskPlanCorrupt_BlocksEligibility();
   Test_CrossLayerFailure_ModelCorrupt_BlocksEligibility();
   Test_FullChainRestartSimulation_MultiDecision();
   Test_MultiCandidateCrossLinking();
   Test_RejectedWithoutLifecycleConsequence_Reconciliation();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");

   Print("=== Manual regression checklist (per the B9 Commit 3 addendum) - re-run each of these in the same MetaEditor session and confirm ALL PASS: ===");
   Print("  MLQuantAI_Test_B9_ExecutionEligibility.mq5");
   Print("  MLQuantAI_Test_B9_Commit2_EligibilityEvent.mq5");
}
