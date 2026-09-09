//+------------------------------------------------------------------+
//| MLQuantAI_Test_W1_AC_N1_ForcedFailure.mq5                         |
//| W1-AC-N1 (C6.2/C6.3 Wave 1 acceptance criterion, frozen chat-      |
//| history authorization, no separate Docs/ file yet): proves the     |
//| Layer A "register unconditionally" invariant                       |
//| (MLQuantAI_ExecutionDiscoveryGuard.mqh, ExecutionDiscovery_         |
//| EmitAndRegister) actually holds when ExecutionRequest_             |
//| EmitAndEvaluate()'s underlying EventStore write fails outright -    |
//| not just when it partially succeeds.                                |
//|                                                                      |
//| Forces the failure by closing/never-opening the EventStore handle   |
//| before the emission call, so EventStore_WriteLine()'s own           |
//| INVALID_HANDLE guard fires immediately (see MLQuantAI_EventStore.   |
//| mqh) - no disk I/O, no partial write, fully deterministic. This is  |
//| the only reproducible way to force this failure: a bad              |
//| EventStoreFileNameOverride fails OnInit itself (EA never reaches    |
//| OnTick), and a genuine disk-full condition would fail every other   |
//| same-tick emission too, not just this one.                          |
//|                                                                      |
//| Fixture helpers below are deliberately the same shapes as           |
//| MLQuantAI_Test_C1_2_ExecutionRequestSafetyGate.mq5 - same project    |
//| convention every prior B7/B8.x/B9/C1.2 test file already follows.    |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_ToTradeCandidate.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_ModelArtifactBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionDiscoveryGuard.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as MLQuantAI_Test_C1_2_ExecutionRequest
// SafetyGate.mq5. No event emission needed for candidate/plan/AI/
// eligibility layers, since ExecutionRequest_Build only reads the
// in-memory structs it is handed, never the event store.
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
   ctx.context_event_id = "CTX_acn1_" + suffix;
   ctx.context_hash      = "test_context_hash_acn1_" + suffix;
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

void BuildHealthyEligibilityContext(EligibilityContext &context)
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
   policy.eligibility_policy_version = "ELIGPOLICY_ACN1_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

bool BuildEligibleChain(TradeCandidate &c, RiskPlan &plan, AIDecision &decision, EligibilityDecision &eligDecision,
                          string suffix, int dayOffset, float pSuccessValue = 0.90f, double aiThreshold = 0.70)
{
   MarketContext ctx;
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.01.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;

   FeatureSnapshot snapshot;
   if(!Candidate_ToFeatureSnapshot(c, ctx, snapshot)) return false;

   ModelArtifact artifact;
   if(!ModelArtifact_Build("MODEL_" + suffix, "v1", "hash_artifact_" + suffix,
                             "FEATURES_B8_1_V1", "TDSET_dummy_" + suffix, "hash_tdset_" + suffix,
                             "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                             "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, artifact))
      return false;

   InferenceResult inference;
   BuildValidInferenceResult(snapshot, artifact.model_registry_id, artifact.model_registry_hash, artifact.model_artifact_hash,
                               pSuccessValue, inference);
   AIDecisionPolicy aiPolicy;
   AIDecisionPolicy_Init(aiPolicy);
   aiPolicy.decision_policy_version = "AIPOLICY_ACN1_V1";
   aiPolicy.threshold_version       = "THRESH_ACN1_V1";
   aiPolicy.allow_threshold         = aiThreshold;
   string aiReasonDetail;
   if(!AIDecision_Build(inference, snapshot, aiPolicy, decision, aiReasonDetail)) return false;

   RiskContext riskCtx; BuildValidRiskContext(riskCtx, suffix);
   if(!Candidate_ToRiskPlan(c, riskCtx, plan)) return false;

   EligibilityContext eligContext; BuildHealthyEligibilityContext(eligContext);
   EligibilityPolicy eligPolicy; BuildEnabledEligibilityPolicy(eligPolicy);

   string eligReasonDetail;
   return EligibilityDecision_Build(plan, decision, snapshot, eligContext, eligPolicy, eligDecision, eligReasonDetail);
}

// Same as MLQuantAI_Test_C1_2_ExecutionRequestSafetyGate.mq5's own
// BuildAcceptingExecutionPolicy - a fully-configured ExecutionPolicy
// that would ACCEPT under the live terminal's own current account/
// symbol. Irrelevant to this test's own outcome (the write fails before
// SafetyGate_Evaluate ever runs), kept only so ExecutionRequest_Build's
// own validation has a well-formed policy to build against.
void BuildAcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_ACN1_V1";
   policy.environment_mode = EXECUTION_ENV_TESTER;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

//=====================================================================
// W1-AC-N1: forced EventStore write failure -> Layer A still registers
// the id unconditionally -> the discovery guard resolves the same id
// via Layer A (not MISSING) on the very next check, exactly as if a
// second OnTick had run - proving no second emitter call would ever be
// attempted for this id within the same session, even though nothing
// about this attempt was ever durably recorded.
//=====================================================================
void Test_W1_AC_N1_ForcedFailure_RegistersLayerA()
{
   Print("--- W1-AC-N1: EventStore write failure still registers Layer A, preventing same-session re-emission ---");

   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   Check(BuildEligibleChain(c, plan, decision, eligDecision, "ACN1", 1), "sanity: chain built");
   Check(eligDecision.decision == ELIGIBILITY_DECISION_ELIGIBLE, "sanity: eligibility decision is ELIGIBLE");

   ExecutionPolicy policy; BuildAcceptingExecutionPolicy(policy);
   ExecutionRequest req; string rd;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd), "sanity: build succeeds");
   Check(req.execution_request_id != "", "sanity: execution_request_id is non-empty");

   // A real, empty file to check against afterward - opened once so we
   // have something concrete to read back, then closed immediately so
   // g_EventStore_Handle == INVALID_HANDLE for the emission attempt
   // below. This is the only deterministic, isolated way to force
   // EventStore_WriteLine()'s own failure guard: see this file's header
   // comment for why a bad EventStoreFileNameOverride or a genuine
   // disk-full condition cannot substitute for this.
   string file = "MLQuantAI_Test_W1_AC_N1_ForcedFailure.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   EventStore_Close();

   ExecutionDiscoverySession_Reset();
   Check(!ExecutionDiscoverySession_Contains(req.execution_request_id),
         "sanity: id not yet known to Layer A before the emission attempt");

   DryRunExecutionResult result;
   bool emitOk = ExecutionDiscovery_EmitAndRegister(req, policy, result);
   Check(!emitOk, "ExecutionDiscovery_EmitAndRegister returns false when the underlying EventStore write fails outright");

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   Check(n == 0, "no EXECUTION_REQUEST_CREATED (or any event) was durably written - store remains empty");

   Check(ExecutionDiscoverySession_Contains(req.execution_request_id),
         "Layer A registers execution_request_id UNCONDITIONALLY even though nothing was durably written "
         "(C6.3 section 5 invariant 3)");

   ExecutionDiscoveryResult discovery;
   ExecutionDiscovery_Resolve(req.execution_request_id, discovery);
   Check(discovery.resolution == EXEC_DISCOVERY_FOUND_SESSION,
         "next tick: discovery resolves via Layer A (FOUND_SESSION, not MISSING) - the real MLQuantAI.mq5 caller "
         "returns immediately on this resolution, so no second ExecutionDiscovery_EmitAndRegister call would ever "
         "be attempted for this id within the same session");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: W1-AC-N1 - forced EventStore write failure vs. Layer A registration ===");

   Test_W1_AC_N1_ForcedFailure_RegistersLayerA();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
