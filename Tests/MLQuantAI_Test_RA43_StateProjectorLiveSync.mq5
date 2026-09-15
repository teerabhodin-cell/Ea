//+------------------------------------------------------------------+
//| MLQuantAI_Test_RA43_StateProjectorLiveSync.mq5                    |
//| RA-43 (QA-frozen StateProjector Live-Sync Remediation Design):     |
//| proves the two new sync points BrokerSubmission_ProcessSendResult |
//| gained (Include/MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAdapter|
//| .mqh - immediately after the durable CANDIDATE_SUBMITTED write,    |
//| and immediately after the durable synchronous                     |
//| CANDIDATE_REJECTED_BY_BROKER write) - specifically:                |
//|   AC-1 ordering:      apply only ever runs after durable success  |
//|   AC-2 equivalence:   live state == a fresh cold rebuild's state,  |
//|                       observed same-session, no restart needed    |
//|   AC-3 failure path:  durable=SUCCESS + live apply=FAILURE ->      |
//|                       SafeMode_Trip (deterministic, candidate_id + |
//|                       transition + underlying error in the        |
//|                       reason), BrokerSubmission_Submit()'s own     |
//|                       return-value contract left UNCHANGED (still  |
//|                       true - QA's frozen ruling: this is a         |
//|                       post-durable read-model failure, not an     |
//|                       RA-31.2 condition B durability failure, so   |
//|                       it must never be reported as one)            |
//|                                                                      |
//| THIS FILE NEVER CALLS BrokerSubmission_Submit() AND NEVER CALLS      |
//| THE REAL OrderSend() - same discipline as                            |
//| Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5 (which this file  |
//| duplicates its fixture-building helpers from verbatim, same shapes,  |
//| same established convention as every other C2.2-family test file -  |
//| exercises BrokerSubmission_RecordAttempt()/ProcessSendResult() only,|
//| both pure, neither calls OrderSend). Running this script on a real   |
//| demo account is therefore safe: no position is ever opened.          |
//|                                                                      |
//| Deterministic apply-failure fixture technique (two DIFFERENT         |
//| failure sub-modes are exercised, one per transition, for broader     |
//| coverage of StateProjector_Apply's/the recovery matchers' own        |
//| failure branches - not because either transition is limited to just |
//| one failure mode):                                                   |
//|  - SUBMITTED: StateProjector is left with NO entry for this          |
//|    candidate_id (genesis never applied) before the real SUBMITTED    |
//|    line is recovered and applied - StateProjector_Apply's own        |
//|    "first event seen is not a CREATED genesis event" rejection       |
//|    fires deterministically (idx<0, isGenesis=false).                 |
//|  - REJECTED_BY_BROKER: genesis IS pre-seeded (so the SUBMITTED sync  |
//|    succeeds cleanly), but a spurious extra SUBMITTED->REJECTED_BY_   |
//|    BROKER line for the SAME candidate_id is durably pre-written      |
//|    before ProcessSendResult runs - once ProcessSendResult writes     |
//|    its OWN real REJECTED_BY_BROKER line, BSA_FindMatchingRejectedBy  |
//|    BrokerLine finds matchCount=2 (ambiguous), the recovery-evidence  |
//|    branch of the RA-43 sync point, not the StateProjector_Apply      |
//|    from_state branch already covered by the SUBMITTED case above.    |
//| Neither technique uses EventStore_Close() before the call under      |
//| test (RA38-AM1: that only breaks the DURABLE step, never the live-   |
//| apply step that runs after it, so it can never reproduce this class  |
//| of failure).                                                          |
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
// Fixture helpers - same shapes as Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5.
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
   ctx.context_event_id = "CTX_ra43_" + suffix;
   ctx.context_hash      = "test_context_hash_ra43_" + suffix;
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
   datetime t0 = D'2026.03.01 00:00:00' + dayOffset * 86400;
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

bool BuildAcceptedRequestWithCandidate(TradeCandidate &outCandidate, ExecutionRequest &req, ExecutionPolicy &policy, string suffix, int dayOffset)
{
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   if(!BuildEligibleChain(outCandidate, plan, decision, eligDecision, suffix, dayOffset)) return false;
   BuildC2AcceptingExecutionPolicy(policy);
   string rd;
   return ExecutionRequest_Build(outCandidate, eligDecision, decision, plan, policy, req, rd);
}

void MakeFakeTradeResult(MqlTradeResult &tr, uint retcode, ulong order, ulong deal, double price)
{
   MqlTradeResult_ZeroInit(tr);
   tr.retcode = retcode;
   tr.order = order;
   tr.deal = deal;
   tr.price = price;
}

int CountLinesOfType(string &lines[], int n, string typeStr)
{
   int count = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"" + typeStr + "\"") >= 0)
         count++;
   return count;
}

// Durably writes AND live-applies the CANDIDATE_CREATED genesis for
// candidate - mirrors exactly what the real production path
// (CRT_EmitCandidateCreated) does: durable write first, then a
// best-effort StateProjector_Apply of the same genesis shape (R5, RA-38/
// RA-39, unchanged - not what RA-43 is remediating). Needed so the file
// this test later cold-rebuilds from actually contains the genesis line
// too, not just an in-memory shortcut - otherwise AC-2's live-vs-cold-
// rebuild comparison would compare against a replay that never saw a
// genesis event at all.
bool SeedGenesisDurableAndLive(TradeCandidate &candidate)
{
   if(!EventStore_LogCandidateCreated(candidate, "")) return false;

   LifecycleEvent genesis;
   LifecycleEvent_Init(genesis);
   genesis.candidate_id  = candidate.candidate_id;
   genesis.root_event_id = candidate.root_event_id;
   genesis.strategy_id   = candidate.strategy_id;
   genesis.from_state     = CANDIDATE_CREATED;
   genesis.to_state       = CANDIDATE_CREATED;
   string genesisErr;
   return StateProjector_Apply(genesis, genesisErr);
}

//=====================================================================
// AC-1/AC-2/AC-3 - CANDIDATE_SUBMITTED sync
//=====================================================================
void Test_Submitted_LiveApply_Success_SameSessionMatchesColdRebuild()
{
   Print("--- RA-43 SUBMITTED: genesis pre-seeded -> live apply succeeds, same-session state visible with no restart, cold rebuild reaches the identical state (AC-1/AC-2) ---");
   StateProjector_Reset();
   SafeMode_Clear();

   TradeCandidate candidate; ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequestWithCandidate(candidate, req, policy, "RA43SUBOK", 1), "sanity: request+candidate built");

   string file = "MLQuantAI_Test_RA43_Submitted_Success.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   Check(SeedGenesisDurableAndLive(candidate), "sanity: genesis CANDIDATE_CREATED durably written and live-applied");
   Check(BrokerSubmission_RecordAttempt(candidate, req), "sanity: RecordAttempt succeeds");

   MqlTradeResult tr; MakeFakeTradeResult(tr, TRADE_RETCODE_DONE, 611, 622, 2100.50);
   ExecutionSubmissionResult result;
   bool ok = BrokerSubmission_ProcessSendResult(candidate, req, 2100.55, true, 0, TimeCurrent(), tr, result);

   Check(ok, "ProcessSendResult returns true (AC-1 durable write path unaffected)");
   Check(!SafeMode_IsActive(), "SafeMode NOT tripped on the clean success path");
   Check(candidate.state == CANDIDATE_SUBMITTED, "local candidate struct transitioned to CANDIDATE_SUBMITTED (pre-existing behavior, unchanged)");

   ENUM_CANDIDATE_STATE liveState;
   Check(StateProjector_TryGetState(candidate.candidate_id, liveState) && liveState == CANDIDATE_SUBMITTED,
         "AC-1/R7: live StateProjector reflects SUBMITTED immediately, same session, with NO restart/replay in between");

   EventStore_Close();
   StateProjector_Reset();
   ReplayReport rr = ReplayEngine_Run(file);
   ENUM_CANDIDATE_STATE rebuiltState;
   Check(rr.ok, "cold rebuild of the same file reports ok=true");
   Check(StateProjector_TryGetState(candidate.candidate_id, rebuiltState) && rebuiltState == CANDIDATE_SUBMITTED,
         "AC-2: cold rebuild independently reaches the SAME CANDIDATE_SUBMITTED state the live apply produced");

   StateProjector_Reset();
}

void Test_Submitted_LiveApply_Failure_SafeModeTripsReturnTrue()
{
   Print("--- RA-43 SUBMITTED: genesis deliberately NOT applied live -> durable write still succeeds, live apply fails deterministically (AC-3) ---");
   StateProjector_Reset();
   SafeMode_Clear();

   TradeCandidate candidate; ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequestWithCandidate(candidate, req, policy, "RA43SUBFAIL", 2), "sanity: request+candidate built");

   string file = "MLQuantAI_Test_RA43_Submitted_Failure.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   // Deliberately skip SeedGenesisDurableAndLive() - StateProjector has
   // NO entry for this candidate_id. The recovered SUBMITTED line
   // (from=CREATED) is not a genesis event (from!=to), so
   // StateProjector_Apply hits idx<0 && !isGenesis and fails
   // deterministically - not EventStore_Close() (RA38-AM1: that would
   // only break the DURABLE step, never this one).
   Check(BrokerSubmission_RecordAttempt(candidate, req), "sanity: RecordAttempt succeeds");

   MqlTradeResult tr; MakeFakeTradeResult(tr, TRADE_RETCODE_DONE, 711, 722, 2101.50);
   ExecutionSubmissionResult result;
   bool ok = BrokerSubmission_ProcessSendResult(candidate, req, 2101.55, true, 0, TimeCurrent(), tr, result);
   EventStore_Close();

   Check(ok, "AC-3 + QA frozen ruling: ProcessSendResult/Submit's return value stays TRUE - this is a post-durable "
             "read-model failure, NOT an RA-31.2 condition B durability failure, and must never be reported as one");
   Check(candidate.state == CANDIDATE_SUBMITTED, "the durable transition and local struct mutation happened exactly as before - unaffected by the live-apply failure");
   Check(SafeMode_IsActive(), "AC-3: SafeMode IS tripped - no silent success");
   string reason = SafeMode_Reason();
   Check(StringFind(reason, candidate.candidate_id) >= 0, "AC-3/R9: SafeMode reason names the candidate_id");
   Check(StringFind(reason, "SUBMITTED") >= 0, "AC-3/R9: SafeMode reason names the SUBMITTED transition specifically");
   Check(StringFind(reason, "genesis") >= 0, "AC-3: SafeMode reason carries the underlying StateProjector_Apply error text (applyErr), not a generic message");

   ENUM_CANDIDATE_STATE liveState;
   Check(!StateProjector_TryGetState(candidate.candidate_id, liveState),
         "live StateProjector correctly still has NO entry for this candidate - the failed apply was never silently partial");

   SafeMode_Clear();
   StateProjector_Reset();
}

//=====================================================================
// AC-1/AC-2/AC-3 - synchronous CANDIDATE_REJECTED_BY_BROKER sync
//=====================================================================
void Test_Rejected_LiveApply_Success_SameSessionMatchesColdRebuild()
{
   Print("--- RA-43 REJECTED_BY_BROKER: genesis pre-seeded -> both syncs succeed in durable-log order, same-session state visible with no restart, cold rebuild matches (AC-1/AC-2) ---");
   StateProjector_Reset();
   SafeMode_Clear();

   TradeCandidate candidate; ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequestWithCandidate(candidate, req, policy, "RA43REJOK", 3), "sanity: request+candidate built");

   string file = "MLQuantAI_Test_RA43_Rejected_Success.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   Check(SeedGenesisDurableAndLive(candidate), "sanity: genesis CANDIDATE_CREATED durably written and live-applied");
   Check(BrokerSubmission_RecordAttempt(candidate, req), "sanity: RecordAttempt succeeds");

   MqlTradeResult tr; MakeFakeTradeResult(tr, TRADE_RETCODE_INVALID_STOPS, 0, 0, 2102.00);
   ExecutionSubmissionResult result;
   bool ok = BrokerSubmission_ProcessSendResult(candidate, req, 2102.05, true, 0, TimeCurrent(), tr, result);

   Check(ok, "ProcessSendResult returns true");
   Check(!SafeMode_IsActive(), "SafeMode NOT tripped on the clean success path");
   Check(candidate.state == CANDIDATE_REJECTED_BY_BROKER, "local candidate struct chains CREATED -> SUBMITTED -> REJECTED_BY_BROKER (pre-existing behavior, unchanged)");

   ENUM_CANDIDATE_STATE liveState;
   Check(StateProjector_TryGetState(candidate.candidate_id, liveState) && liveState == CANDIDATE_REJECTED_BY_BROKER,
         "AC-1/R7: live StateProjector reflects REJECTED_BY_BROKER immediately, same session, with NO restart/replay in between - "
         "both the SUBMITTED and REJECTED_BY_BROKER syncs applied in the same order the durable log records them");

   EventStore_Close();
   StateProjector_Reset();
   ReplayReport rr = ReplayEngine_Run(file);
   ENUM_CANDIDATE_STATE rebuiltState;
   Check(rr.ok, "cold rebuild of the same file reports ok=true");
   Check(StateProjector_TryGetState(candidate.candidate_id, rebuiltState) && rebuiltState == CANDIDATE_REJECTED_BY_BROKER,
         "AC-2: cold rebuild independently reaches the SAME CANDIDATE_REJECTED_BY_BROKER state the live apply produced");

   StateProjector_Reset();
}

void Test_Rejected_LiveApply_Failure_SafeModeTripsReturnTrue()
{
   Print("--- RA-43 REJECTED_BY_BROKER: SUBMITTED sync succeeds, but a pre-existing spurious duplicate REJECTED_BY_BROKER "
         "line makes the second sync's own recovery-evidence step ambiguous (a DIFFERENT failure sub-mode than the "
         "SUBMITTED case above - matchCount>1, not a StateProjector_Apply from_state rejection) (AC-3) ---");
   StateProjector_Reset();
   SafeMode_Clear();

   TradeCandidate candidate; ExecutionRequest req; ExecutionPolicy policy;
   Check(BuildAcceptedRequestWithCandidate(candidate, req, policy, "RA43REJFAIL", 4), "sanity: request+candidate built");

   string file = "MLQuantAI_Test_RA43_Rejected_Failure.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   Check(SeedGenesisDurableAndLive(candidate), "sanity: genesis CANDIDATE_CREATED durably written and live-applied - "
         "so the SUBMITTED sync below succeeds cleanly and only the REJECTED_BY_BROKER sync is under test");

   // Deliberately durably write ONE spurious SUBMITTED->REJECTED_BY_BROKER
   // line for this SAME candidate_id BEFORE the real submission happens,
   // via a disposable local candidate struct that shares only the
   // candidate_id. This does not corrupt the real `candidate` variable's
   // own state (TradeCandidate is passed by value into this local, and
   // EventStore_LogTransition only mutates ITS local copy) - it only
   // pollutes the durable file, which is exactly the condition under
   // test: by the time ProcessSendResult below writes its OWN real
   // REJECTED_BY_BROKER line, BSA_FindMatchingRejectedByBrokerLine finds
   // 2 matching lines for this candidate_id, not 1.
   TradeCandidate spurious = candidate;
   spurious.state = CANDIDATE_SUBMITTED;
   Check(EventStore_LogTransition(spurious, CANDIDATE_REJECTED_BY_BROKER, REASON_BROKER_REJECT, ""),
         "sanity: spurious duplicate REJECTED_BY_BROKER line durably pre-written for the same candidate_id");

   Check(BrokerSubmission_RecordAttempt(candidate, req), "sanity: RecordAttempt succeeds");

   MqlTradeResult tr; MakeFakeTradeResult(tr, TRADE_RETCODE_INVALID_STOPS, 0, 0, 2103.00);
   ExecutionSubmissionResult result;
   bool ok = BrokerSubmission_ProcessSendResult(candidate, req, 2103.05, true, 0, TimeCurrent(), tr, result);
   EventStore_Close();

   Check(ok, "AC-3 + QA frozen ruling: ProcessSendResult/Submit's return value stays TRUE even though the REJECTED_BY_BROKER "
             "live-apply's own evidence-recovery step failed (ambiguous) - still a post-durable read-model failure, not a "
             "durability failure");
   Check(candidate.state == CANDIDATE_REJECTED_BY_BROKER, "the durable transition and local struct mutation happened exactly as before");
   Check(SafeMode_IsActive(), "AC-3: SafeMode IS tripped - no silent success");
   string reason = SafeMode_Reason();
   Check(StringFind(reason, candidate.candidate_id) >= 0, "AC-3/R9: SafeMode reason names the candidate_id");
   Check(StringFind(reason, "REJECTED_BY_BROKER") >= 0, "AC-3/R9: SafeMode reason names the REJECTED_BY_BROKER transition specifically - distinguishable from the SUBMITTED failure case");
   Check(StringFind(reason, "ambiguous") >= 0, "AC-3: SafeMode reason identifies this as the ambiguous-evidence sub-mode, not the genesis/from_state sub-mode");

   ENUM_CANDIDATE_STATE liveState;
   Check(StateProjector_TryGetState(candidate.candidate_id, liveState) && liveState == CANDIDATE_SUBMITTED,
         "live StateProjector correctly stopped at SUBMITTED (the sync that DID succeed) - the failed REJECTED_BY_BROKER "
         "apply was never silently applied on top of ambiguous evidence");

   SafeMode_Clear();
   StateProjector_Reset();
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI RA-43 StateProjector Live-Sync Remediation - regression suite ===");

   Test_Submitted_LiveApply_Success_SameSessionMatchesColdRebuild();
   Test_Submitted_LiveApply_Failure_SafeModeTripsReturnTrue();
   Test_Rejected_LiveApply_Success_SameSessionMatchesColdRebuild();
   Test_Rejected_LiveApply_Failure_SafeModeTripsReturnTrue();

   Print(StringFormat("=== RA-43 suite complete: %d/%d passed ===", g_TestsPassed, g_TestsRun));
}
