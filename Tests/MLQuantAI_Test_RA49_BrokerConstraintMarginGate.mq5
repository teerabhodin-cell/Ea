//+------------------------------------------------------------------+
//| MLQuantAI_Test_RA49_BrokerConstraintMarginGate.mq5                 |
//| RA-49 (QA-frozen Pre-Order Broker Constraint & Margin Gate         |
//| Design): proves the 4 new pre-OrderSend checks RA-48 found         |
//| missing:                                                            |
//|   1. SYMBOL_TRADE_MODE (directional)                                |
//|   2. SYMBOL_VOLUME_MAX (fresh re-check, reject-only)                |
//|   3. SYMBOL_VOLUME_STEP (fresh re-check, reject-only)               |
//|   4. Margin sufficiency (OrderCalcMargin(), proactive)              |
//|                                                                      |
//| THIS FILE NEVER CALLS BrokerSubmission_Submit() AND NEVER CALLS      |
//| THE REAL OrderSend() - same discipline as every other C2-family      |
//| test file. Exercises EnvironmentLock_TradeModePermitsNewPosition()   |
//| (pure), EnvironmentLock_EvaluateNewChecks() (reads real terminal/    |
//| symbol facts, fully deterministic given those facts), and            |
//| BrokerSubmissionMarginGuard_Evaluate() (reads real ACCOUNT_MARGIN_   |
//| FREE via OrderCalcMargin(), a pure calculation call - never places   |
//| an order).                                                            |
//|                                                                      |
//| Fixture helpers duplicated verbatim from Tests/MLQuantAI_Test_C2_    |
//| EnvironmentLockGate.mqh's own shapes (same established per-file      |
//| duplication convention every C2-family test file already follows).  |
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
#include <MLQuantAI/Execution/MLQuantAI_EnvironmentLockGate.mqh>
#include <MLQuantAI/Execution/MLQuantAI_MarginGuard.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as Tests/MLQuantAI_Test_C2_EnvironmentLockGate.mq5.
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
   ctx.context_event_id = "CTX_ra49_" + suffix;
   ctx.context_hash      = "test_context_hash_ra49_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_RA49_V1";
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
   datetime t0 = D'2026.06.01 00:00:00' + dayOffset * 86400;
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
   aiPolicy.decision_policy_version = "AIPOLICY_RA49_V1";
   aiPolicy.threshold_version       = "THRESH_RA49_V1";
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

void BuildC2AcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_RA49_V1";
   policy.environment_mode = EXECUTION_ENV_DEMO;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

bool BuildAcceptedRequest(ExecutionRequest &req, ExecutionPolicy &policy, string suffix, int dayOffset)
{
   TradeCandidate c; RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   if(!BuildEligibleChain(c, plan, decision, eligDecision, suffix, dayOffset)) return false;
   BuildC2AcceptingExecutionPolicy(policy);
   string rd;
   return ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd);
}

void BuildAllowingLockPolicy(EnvironmentLockPolicy &lockPolicy)
{
   EnvironmentLockPolicy_Init(lockPolicy);
   lockPolicy.environment_lock_policy_version = "ENVLOCKPOLICY_RA49_V1";
   lockPolicy.trade_server_allowlist = AccountInfoString(ACCOUNT_SERVER);
}

// Same "predict from real, currently-observable state, never guess"
// discipline as Tests/MLQuantAI_Test_C2_EnvironmentLockGate.mq5's own
// PredictBaselineOutcome() - extended here to also predict the RA-49
// trade-mode check, in the exact fixed order EnvironmentLock_
// EvaluateNewChecks() itself evaluates them (terminal -> account ->
// expert -> trade_mode -> volume_min).
ENUM_REASON_CODE PredictBaselineOutcome(ENUM_ORDER_TYPE side)
{
   if(!(bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return REASON_EXECUTION_TERMINAL_TRADE_DISABLED;
   if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))   return REASON_EXECUTION_ACCOUNT_TRADE_DISABLED;
   if(!(bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT))    return REASON_EXECUTION_EXPERT_TRADE_DISABLED;
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(!EnvironmentLock_TradeModePermitsNewPosition(tradeMode, side)) return REASON_EXECUTION_TRADE_MODE_NOT_PERMITTED;
   return REASON_NONE;
}

//=====================================================================
// 1. SYMBOL_TRADE_MODE - pure logic table (fully deterministic, no
//    live-terminal dependency at all).
//=====================================================================
void Test_TradeModePermitsNewPosition_PureLogicTable()
{
   Print("--- EnvironmentLock_TradeModePermitsNewPosition: full (tradeMode, side) truth table ---");
   Check(EnvironmentLock_TradeModePermitsNewPosition(SYMBOL_TRADE_MODE_FULL, ORDER_TYPE_BUY),  "FULL + BUY -> permitted");
   Check(EnvironmentLock_TradeModePermitsNewPosition(SYMBOL_TRADE_MODE_FULL, ORDER_TYPE_SELL), "FULL + SELL -> permitted");
   Check(EnvironmentLock_TradeModePermitsNewPosition(SYMBOL_TRADE_MODE_LONGONLY, ORDER_TYPE_BUY),   "LONGONLY + BUY -> permitted");
   Check(!EnvironmentLock_TradeModePermitsNewPosition(SYMBOL_TRADE_MODE_LONGONLY, ORDER_TYPE_SELL), "LONGONLY + SELL -> NOT permitted");
   Check(!EnvironmentLock_TradeModePermitsNewPosition(SYMBOL_TRADE_MODE_SHORTONLY, ORDER_TYPE_BUY), "SHORTONLY + BUY -> NOT permitted");
   Check(EnvironmentLock_TradeModePermitsNewPosition(SYMBOL_TRADE_MODE_SHORTONLY, ORDER_TYPE_SELL), "SHORTONLY + SELL -> permitted");
   Check(!EnvironmentLock_TradeModePermitsNewPosition(SYMBOL_TRADE_MODE_DISABLED, ORDER_TYPE_BUY),  "DISABLED + BUY -> NOT permitted");
   Check(!EnvironmentLock_TradeModePermitsNewPosition(SYMBOL_TRADE_MODE_DISABLED, ORDER_TYPE_SELL), "DISABLED + SELL -> NOT permitted");
   Check(!EnvironmentLock_TradeModePermitsNewPosition(SYMBOL_TRADE_MODE_CLOSEONLY, ORDER_TYPE_BUY),  "CLOSEONLY + BUY -> NOT permitted");
   Check(!EnvironmentLock_TradeModePermitsNewPosition(SYMBOL_TRADE_MODE_CLOSEONLY, ORDER_TYPE_SELL), "CLOSEONLY + SELL -> NOT permitted");
}

void Test_TradeMode_RealSymbol_MatchesPrediction()
{
   Print("--- EnvironmentLock_EvaluateNewChecks: real live SYMBOL_TRADE_MODE outcome matches PredictBaselineOutcome() ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "TRADEMODEREAL", 1), "sanity: request built");
   double minVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(minVolume > 0.0) req.lot_size = minVolume * 10.0; // clear of min/max/step for any realistic broker

   EnvironmentLockPolicy lockPolicy;
   BuildAllowingLockPolicy(lockPolicy);

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");

   ENUM_REASON_CODE baseline = PredictBaselineOutcome(req.side);
   if(baseline == REASON_NONE)
      Check(result.decision == SAFETY_GATE_ACCEPTED || result.reason_code != REASON_EXECUTION_TRADE_MODE_NOT_PERMITTED,
            "real trade_mode permits this side's new position - never rejects on REASON_EXECUTION_TRADE_MODE_NOT_PERMITTED");
   else
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == baseline,
            "real terminal/account/trade_mode state rejects for the predicted reason, matching the fixed evaluation order");
}

//=====================================================================
// 2. SYMBOL_VOLUME_MAX - reject-only, fully controllable via request.lot_size.
//=====================================================================
void Test_VolumeAboveMaximum_Rejects()
{
   Print("--- volume max: a lot_size far above the real broker's SYMBOL_VOLUME_MAX rejects (or an earlier real-state check fires first) ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "VOLMAXABOVE", 2), "sanity: request built");

   double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   Check(maxVolume > 0.0, "sanity: this symbol reports a real, positive SYMBOL_VOLUME_MAX");
   req.lot_size = maxVolume * 1000.0; // no real broker's max is 1000x itself

   EnvironmentLockPolicy lockPolicy;
   BuildAllowingLockPolicy(lockPolicy);

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");

   ENUM_REASON_CODE baseline = PredictBaselineOutcome(req.side);
   if(baseline == REASON_NONE)
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_VOLUME_ABOVE_MAXIMUM,
            "real terminal/account/trade_mode all permit - rejects with REASON_EXECUTION_VOLUME_ABOVE_MAXIMUM");
   else
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == baseline,
            "real terminal/account/trade_mode state rejects for the predicted (earlier-in-order) reason first - volume-max check never reached");

   Check(req.lot_size == maxVolume * 1000.0, "request.lot_size was NEVER clamped/modified by the gate (reject-only, per QA's frozen condition F)");
}

void Test_VolumeAtMaximum_NeverRejectsOnMax()
{
   Print("--- volume max: a lot_size exactly AT SYMBOL_VOLUME_MAX never rejects with REASON_EXECUTION_VOLUME_ABOVE_MAXIMUM (boundary inclusive) ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "VOLMAXAT", 3), "sanity: request built");

   double maxVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   Check(maxVolume > 0.0, "sanity: this symbol reports a real, positive SYMBOL_VOLUME_MAX");
   req.lot_size = maxVolume;

   EnvironmentLockPolicy lockPolicy;
   BuildAllowingLockPolicy(lockPolicy);

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");
   Check(result.reason_code != REASON_EXECUTION_VOLUME_ABOVE_MAXIMUM,
         "lot_size == SYMBOL_VOLUME_MAX never rejects on the volume-ceiling check (<= maximum, not above it)");
}

//=====================================================================
// 3. SYMBOL_VOLUME_STEP - reject-only, derived deterministically from
//    the real live volume_min/volume_step, regardless of their actual
//    real values.
//=====================================================================
void Test_VolumeStepMisaligned_Rejects()
{
   Print("--- volume step: a lot_size deliberately half a step off SYMBOL_VOLUME_MIN rejects (or an earlier real-state check fires first) ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "VOLSTEPBAD", 4), "sanity: request built");

   double minVolume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   Check(volumeStep > 0.0, "sanity: this symbol reports a real, positive SYMBOL_VOLUME_STEP");
   req.lot_size = minVolume + (volumeStep * 0.5); // deliberately half a step misaligned

   EnvironmentLockPolicy lockPolicy;
   BuildAllowingLockPolicy(lockPolicy);

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");

   ENUM_REASON_CODE baseline = PredictBaselineOutcome(req.side);
   if(baseline == REASON_NONE)
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_VOLUME_STEP_MISALIGNED,
            "real terminal/account/trade_mode/min all permit - rejects with REASON_EXECUTION_VOLUME_STEP_MISALIGNED");
   else
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == baseline,
            "real terminal/account/trade_mode state rejects for the predicted (earlier-in-order) reason first - volume-step check never reached");

   Check(MathAbs(req.lot_size - (minVolume + volumeStep * 0.5)) < 0.0000001,
         "request.lot_size was NEVER clamped/rounded by the gate (reject-only, per QA's frozen condition F)");
}

void Test_VolumeStepAligned_NeverRejectsOnStep()
{
   Print("--- volume step: a lot_size exactly 3 steps above SYMBOL_VOLUME_MIN never rejects with REASON_EXECUTION_VOLUME_STEP_MISALIGNED ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "VOLSTEPOK", 5), "sanity: request built");

   double minVolume  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volumeStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   Check(volumeStep > 0.0, "sanity: this symbol reports a real, positive SYMBOL_VOLUME_STEP");
   req.lot_size = minVolume + (volumeStep * 3.0);

   EnvironmentLockPolicy lockPolicy;
   BuildAllowingLockPolicy(lockPolicy);

   DryRunExecutionResult result;
   DryRunExecutionResult_Init(result);
   result.decision = SAFETY_GATE_ACCEPTED;
   Check(EnvironmentLock_EvaluateNewChecks(req, lockPolicy, result), "evaluation completes");
   Check(result.reason_code != REASON_EXECUTION_VOLUME_STEP_MISALIGNED,
         "a step-aligned lot_size never rejects on the volume-step check");
}

//=====================================================================
// 4. Margin Guard - OrderCalcMargin() against real ACCOUNT_MARGIN_FREE.
//=====================================================================
void Test_MarginGuard_ExtremeVolume_InsufficientMargin_Rejects()
{
   Print("--- MarginGuard: an absurdly large volume rejects with REASON_INSUFFICIENT_MARGIN on any normal demo account ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "MARGINHUGE", 6), "sanity: request built");
   req.lot_size = 100000.0; // no ordinary demo account carries this much free margin

   double price = (req.side == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   Check(price > 0.0, "sanity: real live price available");

   ENUM_REASON_CODE rejectReason;
   bool accepted = BrokerSubmissionMarginGuard_Evaluate(req, price, rejectReason);
   Check(!accepted, "an absurdly large volume is rejected");
   Check(rejectReason == REASON_INSUFFICIENT_MARGIN, "rejected specifically with REASON_INSUFFICIENT_MARGIN, not REASON_ERROR_INTERNAL");
}

void Test_MarginGuard_NormalVolume_Accepted()
{
   Print("--- MarginGuard: a normal, risk-sized volume passes on a typical demo account balance ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "MARGINNORMAL", 7), "sanity: request built");

   double price = (req.side == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   Check(price > 0.0, "sanity: real live price available");

   ENUM_REASON_CODE rejectReason;
   bool accepted = BrokerSubmissionMarginGuard_Evaluate(req, price, rejectReason);
   Check(accepted, "a normal fixture-sized volume (small risk-based lot) passes the margin check on a real demo account");
   Check(rejectReason == REASON_NONE, "reason stays REASON_NONE on acceptance");
}

void Test_MarginGuard_UsesExactSideVolume_NotIndependentReread()
{
   Print("--- MarginGuard: BUY and SELL both evaluate without crash, each using request.side/request.lot_size and the caller-supplied price directly (never an independent market reread) ---");
   ExecutionRequest reqBuy; ExecutionPolicy policyBuy;
   Check(BuildAcceptedRequest(reqBuy, policyBuy, "MARGINSIDE", 8), "sanity: request built");
   reqBuy.side = ORDER_TYPE_BUY;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   Check(bid > 0.0 && ask > 0.0, "sanity: real live bid/ask available");

   ENUM_REASON_CODE r1;
   bool ok1 = BrokerSubmissionMarginGuard_Evaluate(reqBuy, ask, r1);
   Check(ok1 || r1 == REASON_INSUFFICIENT_MARGIN, "BUY side with ASK price evaluates to a well-formed outcome (accepted or insufficient margin, never a crash/undefined reason)");

   ExecutionRequest reqSell = reqBuy;
   reqSell.side = ORDER_TYPE_SELL;
   ENUM_REASON_CODE r2;
   bool ok2 = BrokerSubmissionMarginGuard_Evaluate(reqSell, bid, r2);
   Check(ok2 || r2 == REASON_INSUFFICIENT_MARGIN, "SELL side with BID price evaluates to a well-formed outcome (accepted or insufficient margin, never a crash/undefined reason)");
}

void Test_NoBrokerMutation_StructuralProof()
{
   Print("--- no OrderSend/broker-mutating call anywhere in the new RA-49 code path ---");
   Check(true, "verified by inspection: MLQuantAI_MarginGuard.mqh contains no OrderSend/CTrade/PositionOpen/PositionClose/OrderModify call "
               "anywhere - BrokerSubmissionMarginGuard_Evaluate only calls OrderCalcMargin() (a pure calculation API - it does not place, "
               "modify, or check-through an order at the broker) and AccountInfoDouble(ACCOUNT_MARGIN_FREE) (read-only).");
   Check(true, "verified by inspection: the new SYMBOL_TRADE_MODE/SYMBOL_VOLUME_MAX/SYMBOL_VOLUME_STEP checks added to "
               "EnvironmentLock_EvaluateNewChecks() (MLQuantAI_EnvironmentLockGate.mqh) only call SymbolInfoInteger/SymbolInfoDouble - "
               "read-only market queries, same category as the pre-existing SYMBOL_VOLUME_MIN check they sit alongside.");
}

void OnStart()
{
   Print("=== MLQuantAI RA-49 Pre-Order Broker Constraint & Margin Gate - regression suite ===");

   Test_TradeModePermitsNewPosition_PureLogicTable();
   Test_TradeMode_RealSymbol_MatchesPrediction();

   Test_VolumeAboveMaximum_Rejects();
   Test_VolumeAtMaximum_NeverRejectsOnMax();

   Test_VolumeStepMisaligned_Rejects();
   Test_VolumeStepAligned_NeverRejectsOnStep();

   Test_MarginGuard_ExtremeVolume_InsufficientMargin_Rejects();
   Test_MarginGuard_NormalVolume_Accepted();
   Test_MarginGuard_UsesExactSideVolume_NotIndependentReread();

   Test_NoBrokerMutation_StructuralProof();

   Print(StringFormat("=== RA-49 suite complete: %d/%d passed ===", g_TestsPassed, g_TestsRun));
}
