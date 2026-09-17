//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Section6_2_RolloutGateReadinessEvaluate.mq5    |
//| §6.2 Evidence-Gate Design Contract Rev.8 (QA-frozen DESIGN FREEZE, |
//| Docs/PhaseC_C5_2_Section6_2_EvidenceGateDesignContract.md): E2E     |
//| coverage of RolloutGateReadiness_Evaluate() through the real,       |
//| authoritative path - a genuine EventStore file, real fresh rebuilds, |
//| real ReplayEngine_Run/BrokerReconciliation_CheckAll, real CRT/       |
//| execution-request pipeline fixtures. NO OrderSend/CTrade anywhere    |
//| in this file - every "broker fact" is a fabricated                    |
//| BROKER_TRANSACTION_OBSERVED line or a fabricated MqlTradeResult fed     |
//| into the already-sealed BrokerSubmission_ProcessSendResult(), exactly    |
//| the same convention C2.2/C2.3's own test files already use. Safe to run   |
//| on a real account - running this script never calls OrderSend.             |
//|                                                                               |
//| Per QA's explicit ruling (this checkpoint's Test Authorization round):        |
//| P1's duplicate_conflicting branch is CONFIRMED UNREACHABLE through this         |
//| authoritative E2E path (a conflicting-hash duplicate is caught by               |
//| BrokerSubmissionAuditProjection_RebuildFromFile's own tamper check FIRST,          |
//| surfacing as audit_chain_broken before P1 ever runs) - Test_P1_Conflicting          |
//| below proves this empirically rather than asserting DUPLICATE_CONFLICTING.           |
//| The pure-predicate-level test for that branch lives in the separate file              |
//| MLQuantAI_Test_C5_2_Section6_2_P1PurePredicate.mq5, per QA's own direction.             |
//|                                                                                           |
//| Window-isolation technique: each logically independent scenario group calls               |
//| EnterFreshDemoWindowWithRestart() first, which durably writes a NEW                          |
//| EXECUTION_ROLLOUT_STAGE_CHANGED(to_stage=DEMO_DRY_RUN) line (§1's "latest wins"                |
//| rule means this becomes the new window boundary, cleanly excluding every earlier                 |
//| group's fixtures) and simulates an EA restart (clear marker -> C62_EstablishSession           |
//| again), so P4b's in-window EA_SESSION_STARTED requirement is satisfied fresh for              |
//| every group without carrying over any earlier group's Safe Mode incidents,                   |
//| duplicate submissions, or terminal candidates.                                                  |
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
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAdapter.mqh>
#include <MLQuantAI/Execution/MLQuantAI_RolloutGateReadinessEvaluate.mqh>

#define TEST_EVENT_STORE_FILE       "MLQuantAI_Test_C6_2_RolloutGateReadinessEvaluate.jsonl"
#define TEST_EVENT_STORE_FILE_ISOLATED "MLQuantAI_Test_C6_2_RolloutGateReadinessEvaluate_Isolated.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as C1.3/C2.2/C2.3's own test files.
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
   ctx.context_event_id = "CTX_c62_" + suffix;
   ctx.context_hash      = "test_context_hash_c62_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C6_2_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

void BuildAcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C6_2_V1";
   policy.environment_mode = EXECUTION_ENV_TESTER;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

void ResetAllProjections()
{
   CandidateProjection_Reset();
   FeatureSnapshotProjection_Reset();
   ModelArtifactProjection_Reset();
   AIDecisionProjection_Reset();
   RiskPlanProjection_Reset();
   EligibilityDecisionProjection_Reset();
   ExecutionRequestProjection_Reset();
   DryRunResultProjection_Reset();
   SubmissionAttemptProjection_Reset();
   SubmissionOutcomeProjection_Reset();
   BrokerSubmissionReconciliation_Reset();
}

// Builds AND emits every layer of the real chain through an ACCEPTED
// ExecutionRequest dry-run - identical to C1.3/C2.3's own BuildFullChain.
bool BuildFullChain(TradeCandidate &c, FeatureSnapshot &snapshot, ModelArtifact &artifact, InferenceResult &inference,
                      RiskPlan &plan, AIDecision &decision, EligibilityDecision &eligDecision,
                      ExecutionPolicy &execPolicy, ExecutionRequest &req, DryRunExecutionResult &dryRunResult,
                      string suffix, int dayOffset, float pSuccessValue = 0.90f, double aiThreshold = 0.70)
{
   MarketContext ctx;
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.03.01 00:00:00' + dayOffset * 86400;
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
   aiPolicy.decision_policy_version = "AIPOLICY_C6_2_V1";
   aiPolicy.threshold_version       = "THRESH_C6_2_V1";
   aiPolicy.allow_threshold         = aiThreshold;
   string aiReasonDetail;
   if(!AIDecision_Build(inference, snapshot, aiPolicy, decision, aiReasonDetail)) return false;
   if(!AIDecision_EmitAIDecisionCreated(decision)) return false;

   RiskContext riskCtx; BuildValidRiskContext(riskCtx, suffix);
   if(!Candidate_ToRiskPlan(c, riskCtx, plan)) return false;
   if(!RiskPlan_EmitRiskPlanCreated(plan)) return false;

   EligibilityContext eligContext; BuildHealthyEligibilityContext(eligContext);
   EligibilityPolicy eligPolicy; BuildEnabledEligibilityPolicy(eligPolicy);
   string eligReasonDetail;
   if(!EligibilityDecision_Build(plan, decision, snapshot, eligContext, eligPolicy, eligDecision, eligReasonDetail)) return false;
   if(!EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, eligContext, c)) return false;
   if(eligDecision.decision != ELIGIBILITY_DECISION_ELIGIBLE) return false;

   BuildAcceptingExecutionPolicy(execPolicy);
   string execReasonDetail;
   if(!ExecutionRequest_Build(c, eligDecision, decision, plan, execPolicy, req, execReasonDetail)) return false;

   return ExecutionRequest_EmitAndEvaluate(req, execPolicy, dryRunResult);
}

bool BuildFullChainThroughAttempt(TradeCandidate &c, ExecutionRequest &req, string suffix, int dayOffset)
{
   FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; DryRunExecutionResult dryRunResult;
   if(!BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, dryRunResult, suffix, dayOffset))
      return false;
   if(dryRunResult.decision != SAFETY_GATE_ACCEPTED) return false;
   return BrokerSubmission_RecordAttempt(c, req);
}

// A candidate that goes through CRT detection/genesis only - deliberately
// NEVER gets an ExecutionRequest built for it. Used to test P3's
// execution_request_missing branch: a real terminal transition exists,
// but no ExecutionRequestProjectionRecord ever will.
bool BuildBareCandidate(TradeCandidate &c, string suffix, int dayOffset)
{
   MarketContext ctx;
   BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.03.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx)))
      return false;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;
   return CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits);
}

// Drives a real candidate CREATED -> SUBMITTED -> REJECTED_BY_BROKER via
// the general-purpose sealed EventStore_LogTransition() API directly -
// deliberately NOT through MLQuantAI_BrokerSubmissionAdapter.mqh's own
// RA-43 orchestration, to avoid that path's additional constraints and
// keep this fixture focused purely on producing a real, durable terminal
// lifecycle line for P3 to locate. StateMachine_CanTransition enforces
// state-pair legality only, never the reason code, so REASON_BROKER_REJECT
// is a legitimate, simple choice for both hops.
bool DriveToRejectedByBroker(TradeCandidate &c)
{
   if(!EventStore_LogTransition(c, CANDIDATE_SUBMITTED, REASON_SUBMITTED_OK)) return false;
   return EventStore_LogTransition(c, CANDIDATE_REJECTED_BY_BROKER, REASON_BROKER_REJECT);
}

void MakeFakeTradeResult(MqlTradeResult &tr, uint retcode, ulong order, ulong deal, double price)
{
   MqlTradeResult_ZeroInit(tr);
   tr.retcode = retcode;
   tr.order = order;
   tr.deal = deal;
   tr.price = price;
}

// §1's window anchor line, written directly via the low-level EventStore_
// LogSystem() API (deliberately bypassing RolloutStageTransition_Emit's
// own ladder-legality gate, which has no implemented forward pair reaching
// DEMO_DRY_RUN from NONE/TEST_FIXTURE in this build) - matches the same
// "fabricate the exact durable shape the function-under-test reads"
// convention MLQuantAI_Test_C5_2_Commit2_RolloutStageTransitionCommandProcess.mq5
// already uses for its own hand-built EXECUTION_ROLLOUT_STAGE_CHANGED lines.
// §1 itself is a pure raw-line scan (type + to_stage only) with no
// provenance/legality check of its own.
void EmitDemoDryRunWindowBoundary()
{
   string extraJson = "\"from_stage\":\"TEST_FIXTURE\",\"to_stage\":\"DEMO_DRY_RUN\",\"environment_mode\":\"DEMO\"";
   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_ROLLOUT_STAGE_CHANGED), "test: entering DEMO_DRY_RUN", extraJson);
}

// Opens a fresh observation window (§1 "latest wins") and simulates an EA
// restart within it (P4b) - isolates one scenario group's fixtures from
// every earlier group's, and independently satisfies P4b every time.
void EnterFreshDemoWindowWithRestart(string label)
{
   EmitDemoDryRunWindowBoundary();
   C62_ClearSessionActiveMarkerOnCleanShutdown();
   ENUM_C62_SESSION_ESTABLISHMENT_RESULT r = C62_EstablishSession();
   Check(r == C62_SESSION_ESTABLISHED, "setup(" + label + "): fresh window + simulated restart establishes cleanly");
}

RolloutGateReadinessResult EvaluateFresh()
{
   string lines[];
   EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
   return RolloutGateReadiness_Evaluate(lines);
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI_Test_C5_2_Section6_2_RolloutGateReadinessEvaluate.mq5 ===");

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   FileDelete(TEST_EVENT_STORE_FILE_ISOLATED, FILE_COMMON);
   FileDelete(MLQUANTAI_SESSION_ACTIVE_FILENAME, FILE_COMMON);
   FileDelete(MLQUANTAI_SAFEMODE_WITNESS_FILENAME, FILE_COMMON);
   SafeMode_Clear();
   g_C62IntegrityFatalHalt = false;
   g_C62SessionEstablishmentResult = C62_SESSION_NOT_YET_ESTABLISHED;
   ResetAllProjections();
   BrokerSubmissionGate_Reset();
   Check(EventStore_Open(TEST_EVENT_STORE_FILE), "setup: event store opens");

   //=====================================================================
   Print("--- §7.2: no session ever established -> SESSION_NOT_ESTABLISHED, allow=false ---");
   {
      RolloutGateReadinessResult res = EvaluateFresh();
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_GATE_READINESS_SESSION_NOT_ESTABLISHED, "reason == SESSION_NOT_ESTABLISHED");
   }

   //=====================================================================
   Print("--- establish the FIRST session (pre-window) ---");
   {
      ENUM_C62_SESSION_ESTABLISHMENT_RESULT r = C62_EstablishSession();
      Check(r == C62_SESSION_ESTABLISHED, "first C62_EstablishSession() succeeds (marker was absent)");
   }

   //=====================================================================
   Print("--- §1: session established but no DEMO_DRY_RUN line exists yet -> WINDOW_NOT_FOUND ---");
   {
      RolloutGateReadinessResult res = EvaluateFresh();
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_GATE_READINESS_WINDOW_NOT_FOUND, "reason == WINDOW_NOT_FOUND");
   }

   //=====================================================================
   Print("--- P4b: window now exists, but the only EA_SESSION_STARTED line is BEFORE it -> NO_SESSION_RESTART_EVIDENCE ---");
   EmitDemoDryRunWindowBoundary();
   {
      RolloutGateReadinessResult res = EvaluateFresh();
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_GATE_READINESS_NO_SESSION_RESTART_EVIDENCE, "reason == NO_SESSION_RESTART_EVIDENCE");
   }

   //=====================================================================
   Print("--- trivial ALLOW: fresh window + simulated restart, zero candidates/submissions in-window ---");
   EnterFreshDemoWindowWithRestart("trivial-allow");
   {
      RolloutGateReadinessResult res = EvaluateFresh();
      Check(res.allow, "allow == true");
      Check(res.reason == ROLLOUT_GATE_READINESS_ALLOW, "reason == ALLOW");
   }

   //=====================================================================
   Print("--- P4c: Safe Mode engaged then cleared, both durably in-window -> SAFE_MODE_ENGAGED_IN_WINDOW ('ever engaged' semantics) ---");
   EnterFreshDemoWindowWithRestart("safe-mode-p4c");
   {
      SafeMode_Trip("test-only: P4c ever-engaged coverage");
      Check(SafeMode_IsActive(), "sanity: Safe Mode is active");
      SafeMode_Clear();
      Check(!SafeMode_IsActive(), "sanity: Safe Mode is cleared again");

      RolloutGateReadinessResult res = EvaluateFresh();
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_GATE_READINESS_SAFE_MODE_ENGAGED_IN_WINDOW, "reason == SAFE_MODE_ENGAGED_IN_WINDOW even though it was later cleared");
   }

   //=====================================================================
   Print("--- §2.2: g_C62IntegrityFatalHalt independently rejects, before §2.1 is ever reached ---");
   EnterFreshDemoWindowWithRestart("fatal-halt-2.2");
   {
      g_C62IntegrityFatalHalt = true;
      RolloutGateReadinessResult res = EvaluateFresh();
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_GATE_READINESS_INTEGRITY_FATAL_HALT, "reason == INTEGRITY_FATAL_HALT");
      g_C62IntegrityFatalHalt = false; // cleanup - do not let this leak into later groups
   }

   //=====================================================================
   Print("--- §2.1: a durable write between the snapshot and the call -> EVIDENCE_SNAPSHOT_CHANGED ---");
   EnterFreshDemoWindowWithRestart("snapshot-2.1");
   {
      string staleLines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, staleLines);

      EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SYSTEM_STARTED), "unrelated write to grow the file after the snapshot was taken");

      RolloutGateReadinessResult res = RolloutGateReadiness_Evaluate(staleLines);
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_GATE_READINESS_EVIDENCE_SNAPSHOT_CHANGED, "reason == EVIDENCE_SNAPSHOT_CHANGED");
   }

   //=====================================================================
   Print("--- P1 duplicate_exact: two EXECUTION_SUBMISSION_ATTEMPTED lines in-window, same execution_request_id AND same hash -> DUPLICATE_EXACT ---");
   EnterFreshDemoWindowWithRestart("p1-duplicate-exact");
   {
      TradeCandidate c1; ExecutionRequest req1;
      Check(BuildFullChainThroughAttempt(c1, req1, "P1DUP", 101), "sanity: full chain + one real attempt built");

      // Deliberately re-append a SECOND EXECUTION_SUBMISSION_ATTEMPTED for
      // the SAME execution_request_id/hash/correlation_id - the registry's
      // own frozen "0..N, never deduped" tolerance (a legitimate future
      // retry) means this is accepted as a second valid row, exactly what
      // P1's own evidence-gate criterion must independently catch.
      string dupAttemptJson = ExecutionSubmissionAttempt_ToExtraJson(req1.execution_request_id, req1.execution_request_hash,
                                                                        req1.correlation_id, req1.submit_attempt);
      Check(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED), "duplicate attempt (test fixture)", dupAttemptJson),
            "sanity: duplicate attempt line durably written");

      RolloutGateReadinessResult res = EvaluateFresh();
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_GATE_READINESS_DUPLICATE_EXACT, "reason == DUPLICATE_EXACT");
   }

   //=====================================================================
   Print("--- P2 uncorrelated_broker_fact: a BROKER_TRANSACTION_OBSERVED line whose order_ticket matches nothing -> UNCORRELATED_BROKER_FACT ---");
   EnterFreshDemoWindowWithRestart("p2-uncorrelated");
   {
      string observedJson = "\"transaction_type\":\"TRADE_TRANSACTION_DEAL_ADD\",\"deal_ticket\":0,\"order_ticket\":9999999";
      Check(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_BROKER_TRANSACTION_OBSERVED), "uncorrelated broker fact (test fixture)", observedJson),
            "sanity: broker transaction observed line durably written");

      RolloutGateReadinessResult res = EvaluateFresh();
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_GATE_READINESS_UNCORRELATED_BROKER_FACT, "reason == UNCORRELATED_BROKER_FACT");
   }

   //=====================================================================
   Print("--- P3 execution_request_missing: a real terminal transition with NO matching ExecutionRequestProjection record ---");
   EnterFreshDemoWindowWithRestart("p3-missing");
   {
      TradeCandidate bare;
      Check(BuildBareCandidate(bare, "P3BARE", 102), "sanity: bare candidate created (no ExecutionRequest ever built for it)");
      Check(DriveToRejectedByBroker(bare), "sanity: bare candidate driven to a real terminal REJECTED_BY_BROKER line");

      RolloutGateReadinessResult res = EvaluateFresh();
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_GATE_READINESS_EXECUTION_REQUEST_MISSING, "reason == EXECUTION_REQUEST_MISSING");
   }

   //=====================================================================
   Print("--- Full ALLOW with real evidence: a terminal REJECTED_BY_BROKER candidate WITH a matching ExecutionRequest, plus a correctly-correlated broker fact ---");
   EnterFreshDemoWindowWithRestart("full-allow");
   {
      TradeCandidate c2; ExecutionRequest req2;
      Check(BuildFullChainThroughAttempt(c2, req2, "FULLALLOW", 103), "sanity: full chain + one real attempt built");

      MqlTradeResult tr; MakeFakeTradeResult(tr, TRADE_RETCODE_DONE, 555, 666, 2000.50);
      ExecutionSubmissionResult outcome;
      Check(BrokerSubmission_ProcessSendResult(c2, req2, 2000.55, true, 0, TimeCurrent(), tr, outcome), "sanity: SUBMITTED outcome recorded durably");
      Check(outcome.submission_status == SUBMISSION_STATUS_SUBMITTED, "sanity: outcome is SUBMITTED");

      // Candidate's OWN lifecycle is driven to a terminal state independently
      // of the broker-fact outcome above - P3 only requires the candidate_id
      // to have SOME ExecutionRequestProjection record, not that the outcome
      // and the lifecycle transition agree on the same broker verdict.
      // Deliberately REJECTED_BY_BROKER, not EXECUTED - BrokerReconciliation_
      // CheckAll() (P4a) only ever inspects CANDIDATE_EXECUTED candidates
      // against real MT5 positions, so this avoids a real-position mismatch
      // that CANDIDATE_EXECUTED would trigger in a test/demo account with no
      // matching position.
      //
      // Only ONE hop needed here, NOT DriveToRejectedByBroker()'s usual two:
      // BrokerSubmission_ProcessSendResult() above already durably drove
      // CREATED -> SUBMITTED itself (BrokerSubmissionAdapter.mqh's own
      // real, sealed RA-43 behavior for both the SUBMITTED and REJECTED
      // classifications) - c2 is already at CANDIDATE_SUBMITTED at this
      // point, so only the SUBMITTED -> REJECTED_BY_BROKER hop remains.
      Check(EventStore_LogTransition(c2, CANDIDATE_REJECTED_BY_BROKER, REASON_BROKER_REJECT),
            "sanity: candidate driven to a real terminal REJECTED_BY_BROKER line (already SUBMITTED via ProcessSendResult above)");

      string correlatedJson = "\"transaction_type\":\"TRADE_TRANSACTION_DEAL_ADD\",\"deal_ticket\":666,\"order_ticket\":555";
      Check(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_BROKER_TRANSACTION_OBSERVED), "correlated broker fact (test fixture)", correlatedJson),
            "sanity: correlated broker transaction observed line durably written");

      RolloutGateReadinessResult res = EvaluateFresh();
      Check(res.allow, "allow == true - " + res.diagnostic);
      Check(res.reason == ROLLOUT_GATE_READINESS_ALLOW, "reason == ALLOW despite a real terminal candidate + a real resolved broker fact present in-window");
   }

   EventStore_Close();

   //=====================================================================
   // P1 duplicate_conflicting - CONFIRMED UNREACHABLE via the authoritative
   // path (QA-ratified finding, this checkpoint's Test Authorization round).
   // Run in a SEPARATE, isolated file: the conflicting-hash line below is
   // permanently rejected as tampered by BrokerSubmissionAuditProjection_
   // RebuildFromFile itself, on every future rebuild of this exact file -
   // sharing the main file would poison every later group's evaluation.
   //=====================================================================
   Print("--- P1 duplicate_conflicting: CONFIRMED UNREACHABLE - a conflicting-hash duplicate surfaces as AUDIT_CHAIN_BROKEN, never DUPLICATE_CONFLICTING ---");
   {
      ResetAllProjections();
      BrokerSubmissionGate_Reset();
      Check(EventStore_Open(TEST_EVENT_STORE_FILE_ISOLATED), "setup(isolated): event store opens");

      EmitDemoDryRunWindowBoundary();
      C62_ClearSessionActiveMarkerOnCleanShutdown();
      Check(C62_EstablishSession() == C62_SESSION_ESTABLISHED, "sanity: session established in-window (isolated file)");

      TradeCandidate c3; ExecutionRequest req3;
      Check(BuildFullChainThroughAttempt(c3, req3, "P1CONFLICT", 1), "sanity: full chain + one real attempt built (isolated file)");

      // Same execution_request_id, DELIBERATELY a different hash - this is
      // exactly the shape ExecutionRequestProjection's own referential-
      // integrity check treats as tampering, one full layer before P1 ever
      // runs.
      string conflictingHash = req3.execution_request_hash + "_TAMPERED";
      string conflictJson = ExecutionSubmissionAttempt_ToExtraJson(req3.execution_request_id, conflictingHash,
                                                                      req3.correlation_id, req3.submit_attempt);
      Check(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED), "conflicting-hash attempt (test fixture)", conflictJson),
            "sanity: conflicting-hash attempt line durably written");

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE_ISOLATED, lines);
      RolloutGateReadinessResult res = RolloutGateReadiness_Evaluate(lines);
      Check(!res.allow, "allow == false");
      Check(res.reason == ROLLOUT_GATE_READINESS_AUDIT_CHAIN_BROKEN,
            "reason == AUDIT_CHAIN_BROKEN, NOT DUPLICATE_CONFLICTING - empirically confirms QA's ruling that this P1 branch is unreachable via the authoritative path");

      EventStore_Close();
   }

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
