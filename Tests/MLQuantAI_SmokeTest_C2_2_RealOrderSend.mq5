//+------------------------------------------------------------------+
//| MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5                         |
//| Phase C2.2 - MANUAL, EXPLICITLY OPT-IN ONLY. NOT part of the        |
//| automated regression suite (Tests/MLQuantAI_Test_C2_2_             |
//| BrokerSubmissionGate.mq5) and NEVER run by that suite or by any     |
//| CI/automated process.                                                |
//|                                                                       |
//| *** THIS SCRIPT CALLS THE REAL BrokerSubmission_Submit() / OrderSend |
//| *** AND, IF THE PRE-SUBMIT GATE ACCEPTS, WILL SEND A REAL ORDER TO   |
//| *** WHATEVER ACCOUNT THIS TERMINAL IS CURRENTLY LOGGED INTO.         |
//|                                                                       |
//| The pre-submit gate (BrokerSubmissionGate_Evaluate) independently    |
//| fails closed unless the account is a real ACCOUNT_TRADE_MODE_DEMO    |
//| account AND ExecutionPolicy.environment_mode == EXECUTION_ENV_DEMO - |
//| but this script adds its own separate check and an explicit          |
//| confirmation input BEFORE even attempting, as a second, independent  |
//| layer, never relying on the gate alone.                              |
//|                                                                       |
//| The fixture candidate this script builds reuses the same synthetic   |
//| CRT-detection fixture as the automated suite (price scale ~100-104,  |
//| NOT real XAUUSD price levels) for its planned_sl/planned_tp - so a   |
//| real OrderSend call is very likely to be broker-rejected             |
//| (TRADE_RETCODE_INVALID_STOPS or similar), which is the SAFE,         |
//| EXPECTED, and still fully informative outcome: it proves the real    |
//| gate -> OrderSend -> classify -> event/lifecycle wiring works end-   |
//| to-end without meaningfully risking an actual filled position. If    |
//| the broker DOES accept it (TRADE_RETCODE_DONE/_DONE_PARTIAL), a REAL |
//| POSITION WILL BE OPEN - C2 has no scope to close it. The user must   |
//| close it manually in the terminal.                                   |
//|                                                                       |
//| C2 manual-approval contract, gate integration round (per               |
//| Docs/PhaseC_C2_ManualApprovalContract.md's "A real wiring gap found    |
//| while implementing this round"): BrokerSubmission_Submit() now calls  |
//| BrokerSubmissionEnvironmentLock_Evaluate(), which includes the new     |
//| manual-approval check. This script's fabricated, freshly-generated     |
//| execution_request_id can never have a real, human-granted approval     |
//| for it (that would require a human running                             |
//| MLQuantAI_ManualScript_GrantApproval.mq5 with this exact run's own      |
//| identity fields BEFORE this script executes, which no automated or      |
//| interactive single-script run can do) - so this script is now EXPECTED |
//| to reject at the audit/manual-approval gate (REASON_EXECUTION_AUDIT_    |
//| NOT_READY or REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED) before ever  |
//| reaching OrderSend, same "safe, expected, still informative" category   |
//| as a broker-side rejection.                                             |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

input bool I_Understand_This_May_Open_A_Real_Position = false; // must be set true to run - script aborts otherwise

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_ToTradeCandidate.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_ModelArtifactBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAdapter.mqh>

void MakeBar(MqlRates &r, datetime t, double open, double high, double low, double close, long tickVolume, int spread)
{
   ZeroMemory(r);
   r.time = t; r.open = open; r.high = high; r.low = low; r.close = close;
   r.tick_volume = tickVolume; r.spread = spread;
}

#define PERIOD_SEC_M5 300

void BuildBaseContext(MarketContext &ctx)
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
   ctx.context_event_id = "CTX_smoke_c22";
   ctx.context_hash      = "test_context_hash_smoke_c22";
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

void BuildValidRiskContext(RiskContext &ctx)
{
   RiskContext_Init(ctx);
   ctx.symbol_spec.instrument_id = "XAUUSD";
   ctx.symbol_spec.broker_symbol = "XAUUSD_smoke";
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

bool BuildAcceptedRequest(TradeCandidate &c, ExecutionRequest &req, ExecutionPolicy &policy)
{
   MarketContext ctx;
   BuildBaseContext(ctx);
   datetime t0 = D'2026.03.01 00:00:00';
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) { Print("smoke: CRT fixture did not detect - aborting"); return false; }
   if(!CRT_ToTradeCandidate(ctx, r, c)) { Print("smoke: CRT_ToTradeCandidate failed - aborting"); return false; }

   FeatureSnapshot snapshot;
   if(!Candidate_ToFeatureSnapshot(c, ctx, snapshot)) return false;

   ModelArtifact artifact;
   if(!ModelArtifact_Build("MODEL_smoke", "v1", "hash_artifact_smoke",
                             "FEATURES_B8_1_V1", "TDSET_dummy_smoke", "hash_tdset_smoke",
                             "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                             "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, artifact))
      return false;

   InferenceResult inference;
   InferenceResult_Init(inference);
   inference.model_registry_id   = artifact.model_registry_id;
   inference.model_registry_hash = artifact.model_registry_hash;
   inference.model_artifact_hash = artifact.model_artifact_hash;
   inference.feature_snapshot_id   = snapshot.feature_snapshot_id;
   inference.feature_snapshot_hash = snapshot.feature_snapshot_hash;
   inference.feature_vector_hash   = snapshot.feature_vector_hash;
   inference.output_schema_version = MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1;
   ArrayResize(inference.output_values, 1);
   inference.output_values[0] = 0.90f;
   inference.runtime_framework = "ONNXRuntime";
   inference.runtime_version   = "1.16.0";
   inference.output_hash = InferenceResult_ComputeOutputHash(inference);

   AIDecisionPolicy aiPolicy;
   AIDecisionPolicy_Init(aiPolicy);
   aiPolicy.decision_policy_version = "AIPOLICY_C1_V1";
   aiPolicy.threshold_version       = "THRESH_C1_V1";
   aiPolicy.allow_threshold         = 0.70;
   AIDecision decision; string aiReasonDetail;
   if(!AIDecision_Build(inference, snapshot, aiPolicy, decision, aiReasonDetail)) return false;

   RiskContext riskCtx; BuildValidRiskContext(riskCtx);
   RiskPlan plan;
   if(!Candidate_ToRiskPlan(c, riskCtx, plan)) return false;

   EligibilityContext eligContext;
   EligibilityContext_Init(eligContext);
   eligContext.account.balance = 10000.0;
   eligContext.account.equity = 10000.0;
   eligContext.account.margin_level = 500.0;
   eligContext.account.open_positions_count = 0;
   eligContext.account.open_risk_percent = 0.0;
   eligContext.account.daily_pnl_percent = 0.0;
   eligContext.account.drawdown_from_peak_percent = 0.0;
   eligContext.safe_mode_active = false;
   eligContext.eligibility_context_hash = EligibilityContext_ComputeHash(eligContext);

   EligibilityPolicy eligPolicy;
   EligibilityPolicy_Init(eligPolicy);
   eligPolicy.eligibility_policy_version = "ELIGPOLICY_C1_V1";
   eligPolicy.max_daily_loss_percent = 5.0;
   eligPolicy.max_drawdown_percent = 10.0;
   eligPolicy.max_total_exposure_percent = 20.0;
   eligPolicy.max_open_positions = 5;
   eligPolicy.min_margin_level = 200.0;

   EligibilityDecision eligDecision; string eligReasonDetail;
   if(!EligibilityDecision_Build(plan, decision, snapshot, eligContext, eligPolicy, eligDecision, eligReasonDetail))
      return false;
   if(eligDecision.decision != ELIGIBILITY_DECISION_ELIGIBLE)
   {
      Print("smoke: EligibilityDecision was not ELIGIBLE (", eligReasonDetail, ") - aborting");
      return false;
   }

   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C2_SMOKE_V1";
   policy.environment_mode = EXECUTION_ENV_DEMO;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;

   string rd;
   return ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd);
}

void OnStart()
{
   Print("=== MLQuantAI C2.2 REAL-SUBMIT SMOKE TEST ===");
   Print("*** This script can send a REAL order via OrderSend() to whatever account this terminal is logged into. ***");

   if(!I_Understand_This_May_Open_A_Real_Position)
   {
      Print("ABORTED: set input I_Understand_This_May_Open_A_Real_Position = true to run this script.");
      return;
   }

   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   Print("Account login: ", login, "  ACCOUNT_TRADE_MODE: ", EnumToString((ENUM_ACCOUNT_TRADE_MODE)tradeMode));
   if(tradeMode != ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("ABORTED (script-level check): this account is not ACCOUNT_TRADE_MODE_DEMO. "
            "BrokerSubmissionGate_Evaluate would fail-closed here too, but this script refuses even earlier.");
      return;
   }

   TradeCandidate candidate;
   ExecutionRequest req;
   ExecutionPolicy policy;
   if(!BuildAcceptedRequest(candidate, req, policy))
   {
      Print("ABORTED: could not build a valid ExecutionRequest fixture - see prior Print lines.");
      return;
   }

   string file = "MLQuantAI_SmokeTest_C2_2.jsonl";
   EventStore_Open(file);

   // Realistic startup sequence, same calls MLQuantAI.mq5's own OnInit
   // makes - both registries default fail-closed, so without these
   // calls the gate would always reject on readiness alone, never
   // reaching the checks below.
   BrokerSubmissionAuditProjectionReport auditReport = BrokerSubmissionAudit_StartupRebuild(file);
   ManualApprovalProjectionReport approvalReport = ManualApproval_StartupRebuild(file);
   Print("Startup rebuild: submission-audit ready=", BrokerSubmissionAuditReadiness_IsReady(),
         " (", auditReport.first_error, "); manual-approval ready=", ManualApprovalReadiness_IsReady(),
         " (", approvalReport.first_error, ")");

   EnvironmentLockPolicy lockPolicy;
   EnvironmentLockPolicy_Init(lockPolicy);
   lockPolicy.environment_lock_policy_version = "ENVLOCK_C2_SMOKE_V1";
   lockPolicy.trade_server_allowlist = AccountInfoString(ACCOUNT_SERVER);

   Print("Submitting real order: symbol=", _Symbol, " side=", (req.side == ORDER_TYPE_BUY ? "BUY" : "SELL"),
         " lot=", DoubleToString(req.lot_size, 2), " correlation_id=", req.correlation_id);
   Print("NOTE: planned_sl/planned_tp come from a synthetic ~100-104 price-scale fixture, NOT real ", _Symbol,
         " price levels - a broker rejection (e.g. TRADE_RETCODE_INVALID_STOPS) is the expected, safe outcome. "
         "A gate rejection at REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED is ALSO an expected, safe outcome - "
         "see this file's own header.");

   ExecutionSubmissionResult result;
   bool ran = BrokerSubmission_Submit(candidate, req, policy, lockPolicy, result);

   EventStore_Close();

   Print("BrokerSubmission_Submit durability return: ", (ran ? "true (every event write succeeded)" : "false (see prior Print/[FAIL]-style lines)"));
   Print("submission_status: ", SubmissionStatusToString(result.submission_status));
   Print("order_send_returned: ", result.order_send_returned, "  terminal_last_error: ", result.terminal_last_error);
   Print("retcode: ", result.retcode, "  retcode_external: ", result.retcode_external);
   Print("order_ticket: ", result.order_ticket, "  deal_ticket: ", result.deal_ticket);
   Print("requested_price: ", DoubleToString(result.requested_price, 5), "  observed_submit_price: ", DoubleToString(result.observed_submit_price, 5));
   Print("reason_code: ", ReasonCodeToString(result.reason_code));
   Print("candidate.state after submit: ", CandidateStateToString(candidate.state));

   if(result.submission_status == SUBMISSION_STATUS_SUBMITTED)
      Print("*** A REAL POSITION MAY NOW BE OPEN (order_ticket=", result.order_ticket, "). "
            "C2 has no close-position scope - close it manually in the terminal. ***");

   Print("Full event trail written to (Common Files): ", file);
   Print("=== smoke test complete ===");
}
