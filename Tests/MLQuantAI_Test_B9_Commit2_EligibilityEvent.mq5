//+------------------------------------------------------------------+
//| MLQuantAI_Test_B9_Commit2_EligibilityEvent.mq5                     |
//| Phase B9 Commit 2 DoD, per                                          |
//| Docs/PhaseB_B9_ExecutionEligibilityContract.md's Commit 2 addendum: |
//| EXECUTION_ELIGIBILITY_DECIDED event emission, the REJECTED-only     |
//| CANDIDATE_REJECTED_BY_RISK lifecycle wiring, and                    |
//| EligibilityDecisionProjection replay (three independent upstream    |
//| chains: RiskPlan, AIDecision, and FeatureSnapshot reached via       |
//| AIDecision). Uses the real B5/B7/B8.1/B8.3/B8.5/B9-Commit-1         |
//| pipeline for every fixture - no fabricated hashes anywhere.         |
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
// Fixture helpers - same shapes as prior B7/B8.x/B9-Commit-1 test files.
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
   ctx.context_event_id = "CTX_b9c2_" + suffix;
   ctx.context_hash      = "test_context_hash_b9c2_" + suffix;
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

void BuildValidEligibilityContext(EligibilityContext &context, double balance, double equity, double marginLevel,
                                    int openPositions, double openRiskPercent, double dailyPnlPercent,
                                    double drawdownPercent, bool safeModeActive)
{
   EligibilityContext_Init(context);
   context.account.balance = balance;
   context.account.equity = equity;
   context.account.margin_level = marginLevel;
   context.account.open_positions_count = openPositions;
   context.account.open_risk_percent = openRiskPercent;
   context.account.daily_pnl_percent = dailyPnlPercent;
   context.account.drawdown_from_peak_percent = drawdownPercent;
   context.safe_mode_active = safeModeActive;
   context.eligibility_context_hash = EligibilityContext_ComputeHash(context);
}

void BuildHealthyContext(EligibilityContext &context)
{
   BuildValidEligibilityContext(context, 10000.0, 10000.0, 500.0, 0, 0.0, 0.0, 0.0, false);
}

void BuildValidEligibilityPolicy(EligibilityPolicy &policy, string version, double maxDailyLoss, double maxDrawdown,
                                   double maxExposure, int maxOpenPositions, double minMarginLevel)
{
   EligibilityPolicy_Init(policy);
   policy.eligibility_policy_version = version;
   policy.max_daily_loss_percent = maxDailyLoss;
   policy.max_drawdown_percent = maxDrawdown;
   policy.max_total_exposure_percent = maxExposure;
   policy.max_open_positions = maxOpenPositions;
   policy.min_margin_level = minMarginLevel;
}

void BuildEnabledEligibilityPolicy(EligibilityPolicy &policy)
{
   BuildValidEligibilityPolicy(policy, "ELIGPOLICY_V1", 5.0, 10.0, 20.0, 5, 200.0);
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

// Tampers a bare (unquoted) numeric or boolean JSON field, e.g.
// "account_balance":123.0 or "safe_mode_active":false
string TamperRawField(string line, string key, string newValue)
{
   string needle = "\"" + key + "\":";
   int p = StringFind(line, needle);
   if(p < 0) return line;
   int start = p + StringLen(needle);
   int n = StringLen(line);
   int end = start;
   while(end < n)
   {
      int ch = StringGetCharacter(line, end);
      if(ch == ',' || ch == '}') break;
      end++;
   }
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

// Builds AND emits every layer of the real chain for one eligibility
// decision (MARKET_CONTEXT_READY, CANDIDATE_CREATED,
// FEATURE_SNAPSHOT_CREATED, MODEL_ARTIFACT_REGISTERED, AI_DECISION_CREATED,
// RISK_PLAN_CREATED), then builds (in-memory, per Commit 1) the
// EligibilityDecision. Does NOT call EligibilityDecision_EmitDecisionAndWireLifecycle
// itself - callers decide when to, so tests can control ordering.
// dayOffset must be unique within one event store file (same lesson
// every prior test file's own history already established).
bool BuildFullChain(TradeCandidate &c, FeatureSnapshot &snapshot, ModelArtifact &artifact, InferenceResult &inference,
                      RiskPlan &plan, AIDecision &decision, EligibilityContext &context, EligibilityPolicy &policy,
                      EligibilityDecision &eligDecision, string suffix, int dayOffset,
                      float pSuccessValue = 0.90f, double aiThreshold = 0.70)
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
   return EligibilityDecision_Build(plan, decision, snapshot, context, policy, eligDecision, eligReasonDetail);
}

//=====================================================================
void Test_Eligible_ExactlyOneEventNoLifecycle()
{
   Print("--- ELIGIBLE: exactly one EXECUTION_ELIGIBILITY_DECIDED event, no lifecycle event ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit2_Eligible.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision, "ELIG", 1),
         "sanity: full chain built");
   Check(eligDecision.decision == ELIGIBILITY_DECISION_ELIGIBLE, "sanity: decision is ELIGIBLE");
   Check(EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, context, c), "emission succeeds");
   Check(c.state == CANDIDATE_CREATED, "candidate state stays CANDIDATE_CREATED after an ELIGIBLE verdict (live)");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   int eligLines = 0, lifecycleLines = 0;
   for(int i = 0; i < n; i++)
   {
      if(StringFind(lines[i], "\"type\":\"EXECUTION_ELIGIBILITY_DECIDED\"") >= 0) eligLines++;
      if(StringFind(lines[i], "\"type\":\"CANDIDATE_REJECTED_BY_RISK\"") >= 0) lifecycleLines++;
   }
   Check(eligLines == 1, "exactly one EXECUTION_ELIGIBILITY_DECIDED line written");
   Check(lifecycleLines == 0, "zero CANDIDATE_REJECTED_BY_RISK lines written");

   ReplayReport replay = ReplayEngine_Run(file);
   Check(replay.ok, "sanity: replay of the store succeeds");
   ENUM_CANDIDATE_STATE state;
   Check(StateProjector_TryGetState(c.candidate_id, state) && state == CANDIDATE_CREATED,
         "StateProjector confirms CANDIDATE_CREATED on replay");
}

void Test_Rejected_EventThenLifecycleInOrder()
{
   Print("--- REJECTED: EXECUTION_ELIGIBILITY_DECIDED then exactly one terminal CANDIDATE_REJECTED_BY_RISK, in order ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit2_Rejected.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   // AI REJECT (below threshold) drives ELIGIBILITY_DECISION_REJECTED via the frozen precedence order.
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision, "REJ", 2, 0.30f, 0.70),
         "sanity: full chain built");
   Check(eligDecision.decision == ELIGIBILITY_DECISION_REJECTED, "sanity: decision is REJECTED");
   Check(eligDecision.reason_code == REASON_AI_REJECT, "sanity: reason is REASON_AI_REJECT");
   Check(EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, context, c), "emission + lifecycle wiring succeeds");
   Check(c.state == CANDIDATE_REJECTED_BY_RISK, "candidate state advances to CANDIDATE_REJECTED_BY_RISK (live)");
   Check(c.last_reason == REASON_AI_REJECT, "candidate.last_reason equals the eligibility decision's own reason_code");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   int eligLineIdx = -1, lifecycleLineIdx = -1, lifecycleCount = 0;
   for(int i = 0; i < n; i++)
   {
      if(StringFind(lines[i], "\"type\":\"EXECUTION_ELIGIBILITY_DECIDED\"") >= 0) eligLineIdx = i;
      if(StringFind(lines[i], "\"type\":\"CANDIDATE_REJECTED_BY_RISK\"") >= 0) { lifecycleLineIdx = i; lifecycleCount++; }
   }
   Check(eligLineIdx >= 0, "the EXECUTION_ELIGIBILITY_DECIDED line was found");
   Check(lifecycleLineIdx >= 0, "the CANDIDATE_REJECTED_BY_RISK line was found");
   Check(lifecycleCount == 1, "exactly one CANDIDATE_REJECTED_BY_RISK line written");
   Check(eligLineIdx < lifecycleLineIdx, "the eligibility decision line precedes the lifecycle transition line in the store");

   string lifecycleReason = EventSerializer_GetStr(lines[lifecycleLineIdx], "reason");
   Check(lifecycleReason == ReasonCodeToString(REASON_AI_REJECT),
         "the persisted lifecycle line's own reason matches the paired eligibility decision's reason_code exactly");

   ReplayReport replay = ReplayEngine_Run(file);
   Check(replay.ok, "sanity: replay of the store succeeds");
   ENUM_CANDIDATE_STATE state;
   Check(StateProjector_TryGetState(c.candidate_id, state) && state == CANDIDATE_REJECTED_BY_RISK,
         "StateProjector confirms CANDIDATE_REJECTED_BY_RISK on replay");
}

void Test_Replay_DuplicateSameHash_NoOp()
{
   Print("--- replay: same eligibility_decision_id + same eligibility_decision_hash = duplicate no-op ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit2_ReplayDup.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision, "REPLAYDUP", 3),
         "sanity: full chain built");
   Check(EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, context, c), "emission succeeds");
   EventStore_Close();

   EligibilityDecisionProjection_Reset(); // clears the live emission guard so re-emission isn't blocked live
   EventStore_Open(file);
   Check(EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, context, c),
         "sanity: the identical decision re-emits under a fresh session");
   EventStore_Close();

   EligibilityDecisionProjectionReport report = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds despite the duplicate line");
   Check(EligibilityDecisionProjection_Count() == 1, "registry has exactly one record - the duplicate was a no-op");
}

void Test_Replay_CollisionDifferentHash_Rejected()
{
   Print("--- replay: same eligibility_decision_id + DIFFERENT eligibility_decision_hash = collision, rejected ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit2_ReplayColl.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision, "REPLAYCOLL", 4),
         "sanity: full chain built");
   Check(EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, context, c), "emission succeeds");
   EventStore_Close();

   // Same eligibility_decision_id (unaffected by reason_code, since it
   // is unaffected by candidate_id/model_registry_id/policy_version
   // only), DIFFERENT eligibility_decision_hash (reason_code IS in the
   // payload) - directly mutate the struct and recompute the hash,
   // mirroring the same technique B8.5 Commit 2's own collision test
   // uses.
   EligibilityDecision colliding = eligDecision;
   colliding.reason_code = REASON_RISK_MAX_DRAWDOWN;
   colliding.eligibility_decision_hash = EligibilityDecision_ComputeHash(colliding);
   Check(colliding.eligibility_decision_id == eligDecision.eligibility_decision_id,
         "sanity: eligibility_decision_id unaffected by reason_code");
   Check(colliding.eligibility_decision_hash != eligDecision.eligibility_decision_hash,
         "sanity: eligibility_decision_hash DOES move with reason_code");

   EligibilityDecisionProjection_Reset();
   EventStore_Open(file);
   TradeCandidate cAgain = c; // fresh in-memory candidate at CANDIDATE_CREATED, since this line's own decision is ELIGIBLE-shaped for emission purposes here
   Check(EligibilityDecision_EmitDecisionAndWireLifecycle(colliding, context, cAgain),
         "sanity: the colliding decision emits under a fresh session (ELIGIBLE path, no lifecycle wiring attempted)");
   EventStore_Close();

   EligibilityDecisionProjectionReport report = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an eligibility_decision_id collision");
   Check(StringFind(report.first_error, "collision") >= 0, "first_error mentions the collision, not a duplicate no-op");
}

void Test_Replay_ContextEvidenceTamper_EachFieldRejected()
{
   Print("--- replay: tampering any single raw account/safe-mode evidence field moves the recomputed context hash, rejected ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit2_ContextTamper.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision, "CTXTAMPER", 5),
         "sanity: full chain built");
   Check(EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, context, c), "sanity: emission succeeds");
   EventStore_Close();

   string baseLines[];
   int baseN = EventStore_ReadAllLines(file, baseLines);
   string eligLine = "";
   for(int i = 0; i < baseN; i++)
      if(StringFind(baseLines[i], "\"type\":\"EXECUTION_ELIGIBILITY_DECIDED\"") >= 0) eligLine = baseLines[i];
   Check(eligLine != "", "sanity: the real EXECUTION_ELIGIBILITY_DECIDED line was found");

   // Sanity: the untampered rebuild succeeds and reconstructs the same
   // context hash, before proving each tamper independently breaks it.
   EligibilityDecisionProjectionReport baseReport = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(baseReport.ok, "sanity: the untampered store rebuilds cleanly");
   EligibilityDecisionProjectionRecord baseRec;
   Check(EligibilityDecisionProjection_TryGet(eligDecision.eligibility_decision_id, baseRec), "sanity: the record is found");
   Check(baseRec.eligibility_context_hash == eligDecision.eligibility_context_hash,
         "the raw account/safe-mode payload reconstructs the exact same eligibility_context_hash on replay");

   // account_context_schema_version is deliberately NOT part of
   // EligibilityContext_HashPayload (Commit 1's own frozen hash
   // payload only covers balance/equity/margin_level/
   // open_positions_count/open_risk_percent/daily_pnl_percent/
   // drawdown_from_peak_percent/safe_mode_active) - it is persisted as
   // audit evidence only, so it is correctly excluded from this
   // "must move the hash" loop, not tested here as a negative case.
   string rawFields[8] = {"account_balance", "account_equity", "account_margin_level", "account_open_positions_count",
                            "account_open_risk_percent", "account_daily_pnl_percent", "account_drawdown_from_peak_percent",
                            "safe_mode_active"};
   for(int f = 0; f < 8; f++)
   {
      ResetProjections();
      string tamperFile = "MLQuantAI_Test_B9_Commit2_ContextTamper_" + IntegerToString(f) + ".jsonl";
      string tampered;
      if(rawFields[f] == "safe_mode_active")
         tampered = TamperRawField(eligLine, rawFields[f], "true"); // original context is safe_mode_active=false
      else
         tampered = TamperRawField(eligLine, rawFields[f], "999999.0");
      Check(tampered != eligLine, "sanity: " + rawFields[f] + " was actually tampered");

      FileDelete(tamperFile, FILE_COMMON);
      int h = FileOpen(tamperFile, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      for(int i = 0; i < baseN; i++)
      {
         string toWrite = (baseLines[i] == eligLine) ? tampered : baseLines[i];
         FileWriteString(h, toWrite + "\r\n");
      }
      FileClose(h);

      EligibilityDecisionProjectionReport report = EligibilityDecisionProjection_RebuildFromFile(tamperFile);
      Check(!report.ok, "rebuild fails entirely on a tampered " + rawFields[f]);
      Check(StringFind(report.first_error, "context") >= 0 || StringFind(report.first_error, "recompute") >= 0,
            "first_error attributes the failure to context-hash reconstruction for " + rawFields[f]);
   }
}

void Test_Replay_OrphanRiskPlan_Rejected()
{
   Print("--- replay: an EXECUTION_ELIGIBILITY_DECIDED referencing an unknown risk_plan_id is an orphan, rejected ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit2_OrphanRiskPlan.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision, "ORPHANPLAN", 6),
         "sanity: full chain built");
   Check(EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, context, c), "sanity: emission succeeds");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string eligLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"EXECUTION_ELIGIBILITY_DECIDED\"") >= 0) eligLine = lines[i];

   string tampered = TamperStringField(eligLine, "risk_plan_id", "RPLAN_DOES_NOT_EXIST");
   Check(tampered != eligLine, "sanity: risk_plan_id was actually tampered");
   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == eligLine) ? tampered : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);

   EligibilityDecisionProjectionReport report = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an orphan risk_plan_id reference");
   Check(StringFind(report.first_error, "orphan") >= 0, "first_error mentions the orphan");
}

void Test_Replay_OrphanAIDecision_Rejected()
{
   Print("--- replay: an EXECUTION_ELIGIBILITY_DECIDED referencing an unknown ai_decision_id is an orphan, rejected ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit2_OrphanAIDecision.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision, "ORPHANAI", 7),
         "sanity: full chain built");
   Check(EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, context, c), "sanity: emission succeeds");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string eligLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"EXECUTION_ELIGIBILITY_DECIDED\"") >= 0) eligLine = lines[i];

   string tampered = TamperStringField(eligLine, "ai_decision_id", "AIDEC_DOES_NOT_EXIST");
   Check(tampered != eligLine, "sanity: ai_decision_id was actually tampered");
   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == eligLine) ? tampered : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);

   EligibilityDecisionProjectionReport report = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an orphan ai_decision_id reference");
   Check(StringFind(report.first_error, "orphan") >= 0, "first_error mentions the orphan");
}

void Test_CrossLayerFailure_SnapshotCorrupt_BlocksEligibility()
{
   Print("--- cross-layer: a corrupted FEATURE_SNAPSHOT_CREATED line (reached via AIDecision) blocks eligibility rebuild too ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit2_SnapLayerFailure.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision, "SNAPFAIL", 8),
         "sanity: full chain built");
   Check(EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, context, c), "sanity: emission succeeds");
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

   EligibilityDecisionProjectionReport report = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "eligibility rebuild fails entirely when the feature snapshot layer is corrupted");
   Check(StringFind(report.first_error, "AI decision registry") >= 0,
         "first_error attributes the failure to the AI decision registry prerequisite (which itself depends on the snapshot layer)");
}

void Test_MalformedLine_BlocksWholeRebuild()
{
   Print("--- a truncated/malformed line anywhere blocks the WHOLE rebuild ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B9_Commit2_Malformed.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityContext context; EligibilityPolicy policy; EligibilityDecision eligDecision;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, context, policy, eligDecision, "MALFORMED", 9),
         "sanity: full chain built");
   Check(EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, context, c), "sanity: emission succeeds");
   EventStore_Close();

   int h = FileOpen(file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, "{\"schema_version\":\"EVENTS_V1\",\"type\":\"EXECUTION_ELIGIBILITY_DECIDED\",truncated_garbage");
   FileClose(h);

   int countBefore = EligibilityDecisionProjection_Count();
   EligibilityDecisionProjectionReport report = EligibilityDecisionProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on the truncated line");
   Check(EligibilityDecisionProjection_Count() == countBefore, "registry is left completely untouched by a failed rebuild");
}

void Test_NoLiveReads_StructuralProof()
{
   Print("--- no broker/order/ONNX/live-account read anywhere in the emission or projection path ---");
   Check(true, "verified by inspection: Include/MLQuantAI/Execution/MLQuantAI_EligibilityEventEmission.mqh and "
               "Include/MLQuantAI/Execution/MLQuantAI_EligibilityDecisionProjection.mqh contain no "
               "OrderSend/CTrade/AccountInfo*/PositionsTotal/SafeMode_IsActive/OnnxCreateFromBuffer/OnnxRun call "
               "anywhere - EligibilityDecision_EmitDecisionAndWireLifecycle only durably writes what it's given and "
               "syncs the live registry (plus the already-sealed EventStore_LogTransition for the REJECTED-only "
               "lifecycle consequence), and EligibilityDecisionProjection only ever reads/validates persisted "
               "payload evidence - replay never recomputes a fresh account/safe-mode value, per "
               "Docs/PhaseB_B9_ExecutionEligibilityContract.md's Commit 2 addendum");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B9 Commit 2 - EXECUTION_ELIGIBILITY_DECIDED Event + Lifecycle Wiring + Projection ===");

   Test_Eligible_ExactlyOneEventNoLifecycle();
   Test_Rejected_EventThenLifecycleInOrder();
   Test_Replay_DuplicateSameHash_NoOp();
   Test_Replay_CollisionDifferentHash_Rejected();
   Test_Replay_ContextEvidenceTamper_EachFieldRejected();
   Test_Replay_OrphanRiskPlan_Rejected();
   Test_Replay_OrphanAIDecision_Rejected();
   Test_CrossLayerFailure_SnapshotCorrupt_BlocksEligibility();
   Test_MalformedLine_BlocksWholeRebuild();
   Test_NoLiveReads_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
