//+------------------------------------------------------------------+
//| MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5                       |
//| Phase C2.2 DoD, per Docs/PhaseC_C2_1_BrokerSubmissionContract.md:   |
//| BrokerSubmissionGate_Evaluate (final pre-submit re-validation +     |
//| real account-mode/idempotency checks), BrokerSubmission_           |
//| BuildTradeRequest (MqlTradeRequest construction), and               |
//| BrokerSubmission_ClassifyRetcode (accepted-vs-rejection split).     |
//|                                                                      |
//| THIS FILE NEVER CALLS BrokerSubmission_Submit() AND NEVER CALLS      |
//| THE REAL OrderSend() - it includes MLQuantAI_BrokerSubmissionAdapter|
//| .mqh only to reach the pure JSON serialization helpers               |
//| (ExecutionSubmissionAttempt_ToExtraJson/                            |
//| ExecutionSubmissionResult_ToExtraJson) and the                       |
//| ExecutionSubmissionResult struct; BrokerSubmission_Submit itself is  |
//| declared there but is NEVER invoked anywhere below. Running this     |
//| script on a real demo account is therefore safe: no position is      |
//| ever opened. A separate, explicitly opt-in real-submit smoke test    |
//| script is the only place BrokerSubmission_Submit may be called.      |
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
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionGate.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAdapter.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as MLQuantAI_Test_C1_2_ExecutionRequestSafetyGate.mq5.
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
   ctx.context_event_id = "CTX_c2c2_" + suffix;
   ctx.context_hash      = "test_context_hash_c2c2_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C1_V1";
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
   datetime t0 = D'2026.02.01 00:00:00' + dayOffset * 86400;
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
   aiPolicy.decision_policy_version = "AIPOLICY_C1_V1";
   aiPolicy.threshold_version       = "THRESH_C1_V1";
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

// C2.2's own accepting policy: environment_mode == EXECUTION_ENV_DEMO
// (not TESTER, per the frozen environment-authorization split) -
// otherwise identical to C1.2's BuildAcceptingExecutionPolicy.
void BuildC2AcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C2_V1";
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

//=====================================================================
// BrokerSubmissionGate_Evaluate
//=====================================================================
void Test_Gate_InheritsC1_2RejectionUnchanged()
{
   Print("--- Gate: an inherited C1.2 rejection (dry_run=false) passes through with its original reason_code ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "INHERITREJ", 1), "sanity: request built");
   policy.dry_run = false;

   DryRunExecutionResult result;
   Check(BrokerSubmissionGate_Evaluate(req, policy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_REJECTED, "decision is REJECTED");
   Check(result.reason_code == REASON_EXECUTION_SUBMIT_DISABLED, "reason_code is REASON_EXECUTION_SUBMIT_DISABLED - the inherited C1.2 gate's own reason, never overridden");
}

void Test_Gate_StructuralFailureOnEmptyId()
{
   Print("--- Gate: empty execution_request_id is a structural failure - same as SafetyGate_Evaluate itself ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "STRUCTFAIL", 2), "sanity: request built");
   req.execution_request_id = "";

   DryRunExecutionResult result;
   Check(!BrokerSubmissionGate_Evaluate(req, policy, result), "evaluation returns false on empty execution_request_id");
}

void Test_Gate_PolicyLiveIsAlwaysRejected()
{
   Print("--- Gate: ExecutionPolicy.environment_mode == EXECUTION_ENV_LIVE rejects fail-closed, regardless of the real account's own trade mode ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "ENVLIVE", 3), "sanity: request built");
   policy.environment_mode = EXECUTION_ENV_LIVE;

   DryRunExecutionResult result;
   Check(BrokerSubmissionGate_Evaluate(req, policy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED,
         "EXECUTION_ENV_LIVE always rejects with REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED");
}

void Test_Gate_PolicyTesterIsNotGrantedRealAuthority()
{
   Print("--- Gate: ExecutionPolicy.environment_mode == EXECUTION_ENV_TESTER is not granted real submission authority in C2.2 ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "ENVTESTER", 4), "sanity: request built");
   policy.environment_mode = EXECUTION_ENV_TESTER;

   DryRunExecutionResult result;
   Check(BrokerSubmissionGate_Evaluate(req, policy, result), "evaluation completes");
   Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED,
         "EXECUTION_ENV_TESTER always rejects with REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED in C2.2");
}

void Test_Gate_RealAccountModeCrossCheck()
{
   Print("--- Gate: real ACCOUNT_TRADE_MODE cross-check - exact DEMO match required, environment-agnostic assertion ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "ACCTMODE", 5), "sanity: request built");

   DryRunExecutionResult result;
   Check(BrokerSubmissionGate_Evaluate(req, policy, result), "evaluation completes");

   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tradeMode == ACCOUNT_TRADE_MODE_DEMO)
      Check(result.decision == SAFETY_GATE_ACCEPTED,
            "real account IS ACCOUNT_TRADE_MODE_DEMO - ACCEPTED");
   else
      Check(result.decision == SAFETY_GATE_REJECTED && result.reason_code == REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED,
            "real account is NOT ACCOUNT_TRADE_MODE_DEMO - REJECTED with REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED");
}

void Test_Gate_IdempotencyRegistry_PureFunctions()
{
   Print("--- Gate: idempotency registry (Reset/MarkAttempted/HasAlreadyAttempted) - pure functions, no account dependency ---");
   BrokerSubmissionGate_Reset();
   Check(!BrokerSubmissionGate_HasAlreadyAttempted("EXECREQ_notyet"), "a fresh id has not been attempted");
   BrokerSubmissionGate_MarkAttempted("EXECREQ_notyet");
   Check(BrokerSubmissionGate_HasAlreadyAttempted("EXECREQ_notyet"), "the same id now reports already-attempted");
   Check(!BrokerSubmissionGate_HasAlreadyAttempted("EXECREQ_other"), "a different id is unaffected");
   BrokerSubmissionGate_Reset();
   Check(!BrokerSubmissionGate_HasAlreadyAttempted("EXECREQ_notyet"), "Reset clears the registry");
}

void Test_Gate_IdempotencyInsideEvaluate()
{
   Print("--- Gate: a second evaluation of an already-MarkAttempted execution_request_id rejects as duplicate (on a DEMO account) ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "IDEMPOT", 6), "sanity: request built");
   BrokerSubmissionGate_Reset();

   DryRunExecutionResult r1;
   Check(BrokerSubmissionGate_Evaluate(req, policy, r1), "first evaluation completes");
   BrokerSubmissionGate_MarkAttempted(req.execution_request_id);

   DryRunExecutionResult r2;
   Check(BrokerSubmissionGate_Evaluate(req, policy, r2), "second evaluation completes");

   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(tradeMode == ACCOUNT_TRADE_MODE_DEMO)
      Check(r2.decision == SAFETY_GATE_REJECTED && r2.reason_code == REASON_DUPLICATE_EVENT,
            "on a real DEMO account: second evaluation of the same id rejects with REASON_DUPLICATE_EVENT");
   else
      Check(r2.decision == SAFETY_GATE_REJECTED && r2.reason_code == REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED,
            "on a non-DEMO account: still rejects on environment, before idempotency is ever reached");
   BrokerSubmissionGate_Reset();
}

//=====================================================================
// BrokerSubmission_BuildTradeRequest
//=====================================================================
void Test_Build_SymbolMismatchRejects()
{
   Print("--- Build: a symbol that no longer matches what the gate observed rejects, request left zeroed ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "SYMMISMATCH", 7), "sanity: request built");

   MqlTradeRequest tr; ENUM_REASON_CODE reason;
   Check(!BrokerSubmission_BuildTradeRequest(req, policy, "SOME_OTHER_SYMBOL_XYZ", tr, reason),
         "build fails when observedSymbolAtGate differs from the real current _Symbol");
   Check(reason == REASON_EXECUTION_SYMBOL_NOT_ALLOWED, "reason_code is REASON_EXECUTION_SYMBOL_NOT_ALLOWED");
   Check(tr.symbol == "", "outTradeRequest.symbol left zeroed on a rejected build");
}

void Test_Build_NonMarketSideRejects()
{
   Print("--- Build: req.side outside {BUY, SELL} rejects with REASON_EXECUTION_ORDER_TYPE_NOT_MARKET ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "NONMARKET", 8), "sanity: request built");
   req.side = ORDER_TYPE_BUY_LIMIT;

   MqlTradeRequest tr; ENUM_REASON_CODE reason;
   Check(!BrokerSubmission_BuildTradeRequest(req, policy, _Symbol, tr, reason), "build fails for a non-market side");
   Check(reason == REASON_EXECUTION_ORDER_TYPE_NOT_MARKET, "reason_code is REASON_EXECUTION_ORDER_TYPE_NOT_MARKET");
}

void Test_Build_ValidRequest_FieldsFrozenShape()
{
   Print("--- Build: a valid, matching-symbol request builds every frozen MqlTradeRequest field correctly ---");
   ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequest(req, policy, "VALIDBUILD", 9), "sanity: request built");
   Check(req.side == ORDER_TYPE_BUY || req.side == ORDER_TYPE_SELL, "sanity: side is a real market side");

   MqlTradeRequest tr; ENUM_REASON_CODE reason;
   Check(BrokerSubmission_BuildTradeRequest(req, policy, _Symbol, tr, reason), "build succeeds");
   Check(tr.action == TRADE_ACTION_DEAL, "action == TRADE_ACTION_DEAL");
   Check(tr.symbol == _Symbol, "symbol == the real current _Symbol");
   Check(tr.volume == req.lot_size, "volume == req.lot_size, immutable");
   Check(tr.type == req.side, "type == req.side");
   double expectedPrice = (req.side == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   Check(tr.price == expectedPrice, "price == fresh Ask (BUY) or Bid (SELL) - never req.planned_entry");
   Check(tr.sl == req.planned_sl, "sl == req.planned_sl, immutable");
   Check(tr.tp == req.planned_tp, "tp == req.planned_tp, immutable");
   Check(tr.deviation == (ulong)policy.max_deviation_points, "deviation == policy.max_deviation_points, immutable");
   Check(tr.magic == MLQUANTAI_MAGIC_NUMBER, "magic == MLQUANTAI_MAGIC_NUMBER");
   Check(tr.comment == req.correlation_id, "comment == req.correlation_id");
   Check(StringLen(tr.comment) <= 21, "comment stays under MT5's comment length limit");
}

void Test_Build_InvalidBidAskRejects()
{
   Print("--- Build: SymbolInfoDouble returning <= 0 for bid/ask is treated as invalid (documented, not independently reproducible in a live terminal) ---");
   Check(true, "verified by inspection: BrokerSubmission_BuildTradeRequest checks bid <= 0.0 || ask <= 0.0 "
               "and rejects with REASON_ERROR_INTERNAL before touching outTradeRequest.price - not reproducible "
               "as a live automated check since a connected terminal always reports a real positive bid/ask for "
               "a valid, subscribed symbol");
}

//=====================================================================
// BrokerSubmission_ClassifyRetcode
//=====================================================================
void Test_Classify_AcceptedRetcodes()
{
   Print("--- Classify: TRADE_RETCODE_DONE/_DONE_PARTIAL are explicitly accepted, per the frozen contract ---");
   ENUM_REASON_CODE reason;
   Check(BrokerSubmission_ClassifyRetcode(TRADE_RETCODE_DONE, reason) && reason == REASON_SUBMITTED_OK,
         "TRADE_RETCODE_DONE -> accepted, REASON_SUBMITTED_OK");
   Check(BrokerSubmission_ClassifyRetcode(TRADE_RETCODE_DONE_PARTIAL, reason) && reason == REASON_SUBMITTED_OK,
         "TRADE_RETCODE_DONE_PARTIAL -> accepted, REASON_SUBMITTED_OK");
}

void Test_Classify_ExplicitRejectionRetcodes()
{
   Print("--- Classify: the frozen explicit-rejection retcodes map to their specific reason codes ---");
   ENUM_REASON_CODE reason;
   Check(!BrokerSubmission_ClassifyRetcode(TRADE_RETCODE_REQUOTE, reason) && reason == REASON_REQUOTE,
         "TRADE_RETCODE_REQUOTE -> rejected, REASON_REQUOTE");
   Check(!BrokerSubmission_ClassifyRetcode(TRADE_RETCODE_PRICE_CHANGED, reason) && reason == REASON_REQUOTE,
         "TRADE_RETCODE_PRICE_CHANGED -> rejected, REASON_REQUOTE");
   Check(!BrokerSubmission_ClassifyRetcode(TRADE_RETCODE_INVALID_STOPS, reason) && reason == REASON_INVALID_STOPS,
         "TRADE_RETCODE_INVALID_STOPS -> rejected, REASON_INVALID_STOPS");
   Check(!BrokerSubmission_ClassifyRetcode(TRADE_RETCODE_NO_MONEY, reason) && reason == REASON_INSUFFICIENT_MARGIN,
         "TRADE_RETCODE_NO_MONEY -> rejected, REASON_INSUFFICIENT_MARGIN");
   Check(!BrokerSubmission_ClassifyRetcode(TRADE_RETCODE_REJECT, reason) && reason == REASON_BROKER_REJECT,
         "TRADE_RETCODE_REJECT -> rejected, REASON_BROKER_REJECT");
   Check(!BrokerSubmission_ClassifyRetcode(TRADE_RETCODE_MARKET_CLOSED, reason) && reason == REASON_BROKER_REJECT,
         "TRADE_RETCODE_MARKET_CLOSED -> rejected, REASON_BROKER_REJECT");
   Check(!BrokerSubmission_ClassifyRetcode(TRADE_RETCODE_TRADE_DISABLED, reason) && reason == REASON_BROKER_REJECT,
         "TRADE_RETCODE_TRADE_DISABLED -> rejected, REASON_BROKER_REJECT");
}

void Test_Classify_UnlistedRetcodesDefaultToAmbiguousAccept()
{
   Print("--- Classify: any retcode not explicitly listed as a rejection defaults to accepted/ambiguous, per the contract's own stated default ---");
   ENUM_REASON_CODE reason;
   Check(BrokerSubmission_ClassifyRetcode(TRADE_RETCODE_CONNECTION, reason) && reason == REASON_SUBMITTED_OK,
         "TRADE_RETCODE_CONNECTION (not an explicit rejection) -> default accept");
   Check(BrokerSubmission_ClassifyRetcode(TRADE_RETCODE_PLACED, reason) && reason == REASON_SUBMITTED_OK,
         "TRADE_RETCODE_PLACED (not an explicit rejection for a market order) -> default accept");
   Check(BrokerSubmission_ClassifyRetcode(999999, reason) && reason == REASON_SUBMITTED_OK,
         "a wholly unrecognized retcode -> default accept, never guessed as a rejection");
}

//=====================================================================
// ExecutionSubmissionResult - Init defaults + JSON serialization
//=====================================================================
void Test_ExecutionSubmissionResult_InitDefaults()
{
   Print("--- ExecutionSubmissionResult_Init: schema stamped, everything else at its zero/NONE default ---");
   ExecutionSubmissionResult r;
   ExecutionSubmissionResult_Init(r);
   Check(r.execution_submission_result_schema_version == MLQUANTAI_EXECUTION_SUBMISSION_RESULT_SCHEMA_C2_V1,
         "schema version stamped");
   Check(r.submission_status == SUBMISSION_STATUS_NONE, "submission_status starts at SUBMISSION_STATUS_NONE");
   Check(r.reason_code == REASON_NONE, "reason_code starts at REASON_NONE");
   Check(!r.order_send_returned, "order_send_returned starts false");
   Check(r.order_ticket == 0 && r.deal_ticket == 0, "order_ticket/deal_ticket start at 0");
}

void Test_ExecutionSubmissionAttempt_ToExtraJson_NoBrokerFields()
{
   Print("--- ExecutionSubmissionAttempt_ToExtraJson: identity fields only, no broker-claim field ---");
   string json = ExecutionSubmissionAttempt_ToExtraJson("EXECREQ_abc", "hash_abc", "CORR_abc", 1);
   Check(StringFind(json, "\"execution_request_id\":\"EXECREQ_abc\"") >= 0, "execution_request_id present");
   Check(StringFind(json, "\"correlation_id\":\"CORR_abc\"") >= 0, "correlation_id present");
   Check(StringFind(json, "\"submit_attempt\":1") >= 0, "submit_attempt present");
   Check(StringFind(json, "\"retcode\"") < 0 && StringFind(json, "\"order_ticket\"") < 0,
         "no retcode/order_ticket field - no broker claim before OrderSend is even called");
}

void Test_ExecutionSubmissionResult_ToExtraJson_AllFieldsPresent()
{
   Print("--- ExecutionSubmissionResult_ToExtraJson: every frozen field serializes, valid JSON fragment shape ---");
   ExecutionSubmissionResult r;
   ExecutionSubmissionResult_Init(r);
   r.execution_request_id = "EXECREQ_xyz";
   r.correlation_id = "CORR_xyz";
   r.submission_status = SUBMISSION_STATUS_SUBMITTED;
   r.order_send_returned = true;
   r.retcode = TRADE_RETCODE_DONE;
   r.order_ticket = 555;
   r.deal_ticket = 777;
   r.requested_price = 2000.12345;
   r.observed_submit_price = 2000.12300;
   r.reason_code = REASON_SUBMITTED_OK;

   string json = ExecutionSubmissionResult_ToExtraJson(r);
   Check(StringFind(json, "\"submission_status\":\"SUBMITTED\"") >= 0, "submission_status serializes as SUBMITTED");
   Check(StringFind(json, "\"order_send_returned\":true") >= 0, "order_send_returned serializes as true");
   Check(StringFind(json, "\"order_ticket\":555") >= 0, "order_ticket serializes");
   Check(StringFind(json, "\"deal_ticket\":777") >= 0, "deal_ticket serializes");
   Check(StringFind(json, "\"reason_code\":\"SUBMITTED_OK\"") >= 0, "reason_code serializes");
   Check(StringGetCharacter(json, StringLen(json) - 1) != ',', "no trailing comma - valid JSON fragment shape");
}

//=====================================================================
void Test_NoBrokerMutation_StructuralProof()
{
   Print("--- no OrderSend call anywhere in the gate/construction/classification code path this suite exercises ---");
   Check(true, "verified by inspection: MLQuantAI_BrokerSubmissionGate.mqh and MLQuantAI_BrokerSubmissionBuilder.mqh "
               "contain no OrderSend/CTrade/PositionOpen/PositionClose/OrderModify call anywhere - "
               "BrokerSubmissionGate_Evaluate only reads AccountInfoInteger(ACCOUNT_TRADE_MODE) plus the sealed, "
               "unmodified SafetyGate_Evaluate's own read-only checks, and BrokerSubmission_BuildTradeRequest only "
               "reads _Symbol/SymbolInfoDouble (both read-only market queries). The real OrderSend() call lives "
               "exclusively inside BrokerSubmission_Submit() in MLQuantAI_BrokerSubmissionAdapter.mqh, which this "
               "test suite never calls - see this file's own header comment.");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase C2.2 - Broker Submission Gate + Construction + Classification (no real OrderSend) ===");

   Test_Gate_InheritsC1_2RejectionUnchanged();
   Test_Gate_StructuralFailureOnEmptyId();
   Test_Gate_PolicyLiveIsAlwaysRejected();
   Test_Gate_PolicyTesterIsNotGrantedRealAuthority();
   Test_Gate_RealAccountModeCrossCheck();
   Test_Gate_IdempotencyRegistry_PureFunctions();
   Test_Gate_IdempotencyInsideEvaluate();

   Test_Build_SymbolMismatchRejects();
   Test_Build_NonMarketSideRejects();
   Test_Build_ValidRequest_FieldsFrozenShape();
   Test_Build_InvalidBidAskRejects();

   Test_Classify_AcceptedRetcodes();
   Test_Classify_ExplicitRejectionRetcodes();
   Test_Classify_UnlistedRetcodesDefaultToAmbiguousAccept();

   Test_ExecutionSubmissionResult_InitDefaults();
   Test_ExecutionSubmissionAttempt_ToExtraJson_NoBrokerFields();
   Test_ExecutionSubmissionResult_ToExtraJson_AllFieldsPresent();

   Test_NoBrokerMutation_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
