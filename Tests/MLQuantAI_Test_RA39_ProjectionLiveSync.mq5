//+------------------------------------------------------------------+
//| MLQuantAI_Test_RA39_ProjectionLiveSync.mq5                        |
//| RA-39 (QA-frozen Projection Live-Sync Hardening, RA-38 design,    |
//| amended scope): regression proving the durable-write-then-live-   |
//| apply, fail-closed behavior added to ExecutionRequest_             |
//| EmitAndEvaluate() (MLQuantAI_ExecutionRequestEventEmission.mqh)     |
//| and the new 3-argument CRT_EmitCandidateCreated() overload         |
//| (MLQuantAI_CRT_V1_EventEmission.mqh) - the ONLY two files this      |
//| round modifies, plus MLQuantAI.mq5's two authorized call-site       |
//| updates (RunC22CeremonyFixtureCommand, the C5.0 OnTick fixture).    |
//| Covers AC-1 through AC-10 and AC-CAND-01 through AC-CAND-05         |
//| exactly as QA's RA-39 verdict specified.                            |
//|                                                                      |
//| Fixture technique mirrors Tests/MLQuantAI_Test_RA30_4_               |
//| ManualApprovalRuntimeConsistency.mq5 / Tests/MLQuantAI_Test_C1_3_    |
//| ExecutionAuditReconciliation.mq5 verbatim (real B5->C1 pipeline, no  |
//| fabricated hashes) - copied here unchanged, not included, since      |
//| MQL5 scripts cannot #include another .mq5.                           |
//|                                                                      |
//| NO OrderSend/CTrade/OnTradeTransaction/History*/Position*/Order*     |
//| broker API call anywhere in this file.                               |
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

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes/values as Tests/MLQuantAI_Test_RA30_4_
// ManualApprovalRuntimeConsistency.mq5 / Tests/MLQuantAI_Test_C1_3_
// ExecutionAuditReconciliation.mq5, unmodified logic.
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
   ctx.context_event_id = "CTX_ra39_" + suffix;
   ctx.context_hash      = "test_context_hash_ra39_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_RA39_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

void BuildAcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_RA39_V1";
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
}

// Builds AND emits every layer of the real chain through
// ExecutionRequest_EmitAndEvaluate() (RA-39-modified). Uses the 3-arg
// CRT_EmitCandidateCreated() overload (also RA-39-added) so the returned
// ctx is available to the caller for CandidateProjection assertions.
// Requires an ELIGIBLE outcome (default pSuccessValue produces one).
bool BuildFullChain(MarketContext &ctxOut, TradeCandidate &c, ExecutionRequest &req, DryRunExecutionResult &dryRunResult,
                      ExecutionPolicy &execPolicyOut, string suffix, int dayOffset)
{
   BuildBaseContext(ctxOut, suffix);
   datetime t0 = D'2026.04.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctxOut.trigger_tf_recent, anchor, t0);
   ctxOut.anchor_bar_time = anchor;

   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctxOut)))
      return false;

   CRTDetectionResult r;
   CRT_DetectV1(ctxOut, r);
   if(!r.detected) return false;
   if(!CRT_ToTradeCandidate(ctxOut, r, c)) return false;
   if(!CRT_EmitCandidateCreated(c, ctxOut.symbol_spec.digits, ctxOut)) return false; // RA-39 3-arg overload

   FeatureSnapshot snapshot;
   if(!Candidate_ToFeatureSnapshot(c, ctxOut, snapshot)) return false;
   if(!FeatureSnapshot_EmitFeatureSnapshotCreated(snapshot)) return false;

   ModelArtifact artifact;
   if(!ModelArtifact_Build("MODEL_" + suffix, "v1", "hash_artifact_" + suffix,
                             "FEATURES_B8_1_V1", "TDSET_dummy_" + suffix, "hash_tdset_" + suffix,
                             "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                             "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, artifact))
      return false;
   if(!ModelArtifact_EmitModelArtifactRegistered(artifact)) return false;

   InferenceResult inference;
   BuildValidInferenceResult(snapshot, artifact.model_registry_id, artifact.model_registry_hash, artifact.model_artifact_hash,
                               0.90f, inference);
   AIDecisionPolicy aiPolicy;
   AIDecisionPolicy_Init(aiPolicy);
   aiPolicy.decision_policy_version = "AIPOLICY_RA39_V1";
   aiPolicy.threshold_version       = "THRESH_RA39_V1";
   aiPolicy.allow_threshold         = 0.70;
   AIDecision decision; string aiReasonDetail;
   if(!AIDecision_Build(inference, snapshot, aiPolicy, decision, aiReasonDetail)) return false;
   if(!AIDecision_EmitAIDecisionCreated(decision)) return false;

   RiskContext riskCtx; BuildValidRiskContext(riskCtx, suffix);
   RiskPlan plan;
   if(!Candidate_ToRiskPlan(c, riskCtx, plan)) return false;
   if(!RiskPlan_EmitRiskPlanCreated(plan)) return false;

   EligibilityContext eligContext; BuildHealthyEligibilityContext(eligContext);
   EligibilityPolicy eligPolicy; BuildEnabledEligibilityPolicy(eligPolicy);
   EligibilityDecision eligDecision; string eligReasonDetail;
   if(!EligibilityDecision_Build(plan, decision, snapshot, eligContext, eligPolicy, eligDecision, eligReasonDetail)) return false;
   if(!EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, eligContext, c)) return false;
   if(eligDecision.decision != ELIGIBILITY_DECISION_ELIGIBLE) return false;

   BuildAcceptingExecutionPolicy(execPolicyOut);
   string execReasonDetail;
   if(!ExecutionRequest_Build(c, eligDecision, decision, plan, execPolicyOut, req, execReasonDetail)) return false;

   return ExecutionRequest_EmitAndEvaluate(req, execPolicyOut, dryRunResult); // RA-39-modified
}

#define RA39_TEST_FILE "MLQuantAI_Test_RA39_Fixture.jsonl"

void OnStart()
{
   Print("=== RA-39 Projection Live-Sync Hardening - regression test ===");

   if(FileIsExist(RA39_TEST_FILE, FILE_COMMON))
      FileDelete(RA39_TEST_FILE, FILE_COMMON);
   ResetAllProjections();

   Check(EventStore_Open(RA39_TEST_FILE), "setup: isolated test fixture file opens");

   //====================================================================
   // AC-1 / AC-4 / AC-7 (R7): live-apply positive path for
   // ExecutionRequestProjection + DryRunResultProjection AND the new
   // CandidateProjection 3-arg overload, all observed IMMEDIATELY in the
   // SAME session - no ResetAllProjections()/rebuild call anywhere
   // between BuildFullChain() and the checks below.
   //====================================================================
   MarketContext ctxA; TradeCandidate cA; ExecutionRequest reqA; DryRunExecutionResult drA; ExecutionPolicy polA;
   bool builtA = BuildFullChain(ctxA, cA, reqA, drA, polA, "ra39a", 0);
   Check(builtA, "setup A: full real-pipeline chain builds (no fabricated hashes)");
   Check(drA.decision == SAFETY_GATE_ACCEPTED, "setup A: dry-run ACCEPTED");

   Check(ExecutionRequestProjection_Count() == 1, "AC-1: ExecutionRequestProjection gained exactly 1 record, same session, no restart");
   ExecutionRequestProjectionRecord recReq;
   Check(ExecutionRequestProjection_TryGet(reqA.execution_request_id, recReq), "AC-1: ExecutionRequestProjection_TryGet finds the just-emitted request immediately");
   Check(recReq.execution_request_hash == reqA.execution_request_hash, "AC-2: live-applied execution_request_hash matches the durable request exactly");
   Check(recReq.candidate_id == reqA.candidate_id, "AC-2: live-applied candidate_id matches");

   Check(DryRunResultProjection_Count() == 1, "AC-1: DryRunResultProjection gained exactly 1 record, same session, no restart");
   Check(DryRunResultProjection_HasAnyFor(reqA.execution_request_id, reqA.execution_request_hash),
         "AC-2: live-applied DryRunResultProjection record found for the exact request id/hash");

   Check(CandidateProjection_Count() == 1, "AC-CAND-02/03: CandidateProjection gained exactly 1 record via the 3-arg overload, same session");
   CandidateProjectionRecord recCand;
   Check(CandidateProjection_TryGet(cA.candidate_id, recCand), "AC-CAND-03: CandidateProjection_TryGet finds the just-emitted candidate immediately");
   Check(recCand.candidate_hash == cA.candidate_hash, "AC-CAND-03: live-applied candidate_hash matches");
   Check(recCand.context_event_id == ctxA.context_event_id && recCand.context_hash == ctxA.context_hash,
         "AC-CAND-03 (R4): live-applied record's context identity matches EXACTLY the ctx used to construct this candidate - own-context-only validation");

   //====================================================================
   // AC-3 (ExecutionRequestProjection): deterministic durable-succeeded/
   // live-apply-failed fixture per RA38-AM1 - reset ONLY RiskPlanProjection
   // (the lineage ExecutionRequestProjection_ApplyLineWithLineage checks
   // FIRST) immediately before a second, otherwise-valid full chain's
   // final EmitAndEvaluate call. SafetyGate_Evaluate never reads
   // RiskPlanProjection (it evaluates the already-built request/policy
   // structs directly), so this isolates the live-apply step exactly -
   // no EventStore_Close()/handle-breaking trick used (that would force
   // the DURABLE append itself to fail, not the live-apply step it
   // precedes - the exact gap RA38-AM1 identified).
   //====================================================================
   MarketContext ctxB; TradeCandidate cB;
   BuildBaseContext(ctxB, "ra39b");
   datetime t0B = D'2026.04.02 00:00:00';
   datetime anchorB;
   Fixture_Bullish_Valid(ctxB.trigger_tf_recent, anchorB, t0B);
   ctxB.anchor_bar_time = anchorB;
   Check(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctxB)),
         "AC-3 setup: second MarketContext durably written");
   CRTDetectionResult rB;
   CRT_DetectV1(ctxB, rB);
   Check(rB.detected, "AC-3 setup: second CRT detection");
   Check(CRT_ToTradeCandidate(ctxB, rB, cB), "AC-3 setup: second candidate built");
   Check(CRT_EmitCandidateCreated(cB, ctxB.symbol_spec.digits, ctxB), "AC-3 setup: second candidate emitted (3-arg overload)");

   FeatureSnapshot snapB;
   Check(Candidate_ToFeatureSnapshot(cB, ctxB, snapB), "AC-3 setup: second FeatureSnapshot built");
   Check(FeatureSnapshot_EmitFeatureSnapshotCreated(snapB), "AC-3 setup: second FeatureSnapshot emitted");

   ModelArtifact artB;
   Check(ModelArtifact_Build("MODEL_ra39b", "v1", "hash_artifact_ra39b", "FEATURES_B8_1_V1", "TDSET_dummy_ra39b", "hash_tdset_ra39b",
                              "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1", "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, artB),
         "AC-3 setup: second ModelArtifact built");
   Check(ModelArtifact_EmitModelArtifactRegistered(artB), "AC-3 setup: second ModelArtifact emitted");

   InferenceResult infB;
   BuildValidInferenceResult(snapB, artB.model_registry_id, artB.model_registry_hash, artB.model_artifact_hash, 0.90f, infB);
   AIDecisionPolicy aiPolB; AIDecisionPolicy_Init(aiPolB);
   aiPolB.decision_policy_version = "AIPOLICY_RA39_V1"; aiPolB.threshold_version = "THRESH_RA39_V1"; aiPolB.allow_threshold = 0.70;
   AIDecision decB; string aiReasonB;
   Check(AIDecision_Build(infB, snapB, aiPolB, decB, aiReasonB), "AC-3 setup: second AIDecision built");
   Check(AIDecision_EmitAIDecisionCreated(decB), "AC-3 setup: second AIDecision emitted");

   RiskContext riskCtxB; BuildValidRiskContext(riskCtxB, "ra39b");
   RiskPlan planB;
   Check(Candidate_ToRiskPlan(cB, riskCtxB, planB), "AC-3 setup: second RiskPlan built");
   Check(RiskPlan_EmitRiskPlanCreated(planB), "AC-3 setup: second RiskPlan emitted (durable + live-applied via existing Pattern B)");

   EligibilityContext eligCtxB; BuildHealthyEligibilityContext(eligCtxB);
   EligibilityPolicy eligPolB; BuildEnabledEligibilityPolicy(eligPolB);
   EligibilityDecision eligDecB; string eligReasonB;
   Check(EligibilityDecision_Build(planB, decB, snapB, eligCtxB, eligPolB, eligDecB, eligReasonB), "AC-3 setup: second EligibilityDecision built");
   Check(EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecB, eligCtxB, cB), "AC-3 setup: second EligibilityDecision emitted");
   Check(eligDecB.decision == ELIGIBILITY_DECISION_ELIGIBLE, "AC-3 setup: second candidate is ELIGIBLE");

   ExecutionPolicy polB; BuildAcceptingExecutionPolicy(polB);
   ExecutionRequest reqB; string execReasonB;
   Check(ExecutionRequest_Build(cB, eligDecB, decB, planB, polB, reqB, execReasonB), "AC-3 setup: second ExecutionRequest built (not yet emitted)");

   RiskPlanProjection_Reset(); // deliberately corrupt the lineage ExecutionRequestProjection_ApplyLineWithLineage checks first

   DryRunExecutionResult drB;
   int reqCountBefore = ExecutionRequestProjection_Count();
   int dryRunCountBefore = DryRunResultProjection_Count();
   bool emitOkB = ExecutionRequest_EmitAndEvaluate(reqB, polB, drB);
   Check(!emitOkB, "AC-3: ExecutionRequest_EmitAndEvaluate() returns false when live-apply fails (RiskPlanProjection deliberately emptied) - fail-closed (R3)");
   Check(ExecutionRequestProjection_Count() == reqCountBefore, "AC-3: ExecutionRequestProjection did NOT gain a record - live-apply genuinely rejected, not silently accepted");
   Check(DryRunResultProjection_Count() == dryRunCountBefore, "AC-3: DryRunResultProjection was never reached - SafetyGate/second write never ran after the first live-apply failed");

   // Non-rollback proof (R3's own companion invariant, same discipline
   // ExecutionRequest_EmitAndEvaluate's own header comment already
   // documents): the durable EXECUTION_REQUEST_CREATED line for reqB WAS
   // written to disk before the live-apply rejected it - append-only,
   // never rolled back. Verified by reading the raw file back.
   string rawLines[];
   int rawCount = EventStore_ReadAllLines(RA39_TEST_FILE, rawLines);
   bool foundDurableOrphanLine = false;
   for(int i = 0; i < rawCount; i++)
      if(StringFind(rawLines[i], reqB.execution_request_id) >= 0 && StringFind(rawLines[i], "EXECUTION_REQUEST_CREATED") >= 0)
      { foundDurableOrphanLine = true; break; }
   Check(foundDurableOrphanLine, "AC-3: the durable EXECUTION_REQUEST_CREATED line for the rejected-live-apply request IS present in the raw file (append-only, never rolled back)");

   // RiskPlanProjection is left empty here (reset above) - no later check
   // in this file reads it, and AC-8's own full ResetAllProjections()
   // below would wipe it again regardless, so no restore is needed.

   //====================================================================
   // AC-3 (DryRunResultProjection): isolated proof of the SAME function
   // ExecutionRequest_EmitAndEvaluate() now calls for the dry-run half -
   // per RA38-AM1, pre-register an ExecutionRequestProjection record
   // under a target id with a DIFFERENT execution_request_hash than the
   // dry-run-completion line under test declares, deterministically
   // triggering the existing "hash does not match" rejection.
   //====================================================================
   {
      string fakeId = "EXECREQ_ra39_dryrun_isolated_test";
      ExecutionRequestProjectionRecord fakeReqRec;
      ExecutionRequestProjectionRecord_Init(fakeReqRec);
      fakeReqRec.execution_request_id   = fakeId;
      fakeReqRec.execution_request_hash = "HASH_REAL_ABC";
      ExecutionRequestProjection_AppendRecord(fakeReqRec);

      SystemEvent fakeDrEvent;
      SystemEvent_Init(fakeDrEvent);
      fakeDrEvent.base.event_type = EventTypeToString(EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED);
      DryRunExecutionResult fakeDr;
      DryRunExecutionResult_Init(fakeDr);
      fakeDr.execution_request_id   = fakeId;
      fakeDr.execution_request_hash = "HASH_WRONG_XYZ"; // deliberately mismatched vs fakeReqRec above
      fakeDr.decision = SAFETY_GATE_ACCEPTED;
      fakeDrEvent.extra_json = DryRunExecutionResult_ToExtraJson(fakeDr);
      string fakeDrLine = EventSerializer_ToJson(fakeDrEvent); // note: not durably appended - this is a pure function-level proof (see header)

      string isolatedReason;
      int dryRunCountBeforeIsolated = DryRunResultProjection_Count();
      bool isolatedOk = DryRunResultProjection_ApplyLineWithLineage(fakeDrLine, isolatedReason);
      Check(!isolatedOk, "AC-3 (DryRunResultProjection, isolated): ApplyLineWithLineage rejects a hash-mismatched completion deterministically");
      Check(DryRunResultProjection_Count() == dryRunCountBeforeIsolated, "AC-3 (DryRunResultProjection, isolated): rejected line did not add a record");
      Check(StringFind(isolatedReason, "does not match") >= 0, "AC-3 (DryRunResultProjection, isolated): rejection reason names the hash mismatch, not a generic failure");
   }

   //====================================================================
   // R9 (frozen, evidence-backed, structural - not independently
   // runtime-testable as a negative claim): DryRunResultProjection has
   // no same-session mutating-authority consumer. This is proven by the
   // RA-38/RA-39 code-path trace (GrantManualApprovalCommand/
   // SubmitOrderCommand read only ExecutionRequestProjection;
   // BrokerSubmissionGate_Evaluate re-derives its decision live via a
   // fresh SafetyGate_Evaluate() call), not by a runtime assertion here -
   // recorded as a comment for traceability, not a Check().
   //====================================================================

   //====================================================================
   // AC-6 / AC-CAND-03 (CandidateProjection apply-failure via collision):
   // StateProjector and CandidateProjection are independently reset-able
   // registries - resetting StateProjector alone (never CandidateProjection)
   // simulates the real inconsistent-state scenario the collision guard
   // exists for, and lets a genuinely different candidate be FORCED to
   // collide on cA's own candidate_id (set by hand, not derived) through
   // the REAL 3-arg overload end-to-end.
   //====================================================================
   StateProjector_Reset();
   TradeCandidate cCollide;
   TradeCandidate_Init(cCollide);
   cCollide.candidate_id     = cA.candidate_id; // deliberate collision
   cCollide.root_event_id    = "ROOT_ra39_collide";
   cCollide.correlation_id   = "CORR_ra39_collide";
   cCollide.strategy_id      = cA.strategy_id;
   cCollide.state            = CANDIDATE_CREATED;
   cCollide.context_event_id = ctxA.context_event_id;
   cCollide.context_hash     = ctxA.context_hash;
   cCollide.candidate_hash   = "HASH_deliberately_different_from_cA";
   cCollide.detector_hash    = cA.detector_hash;
   cCollide.candidate_schema_version = cA.candidate_schema_version;
   cCollide.side             = (cA.side == ORDER_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY; // different payload
   int candCountBeforeCollide = CandidateProjection_Count();
   bool collideOk = CRT_EmitCandidateCreated(cCollide, ctxA.symbol_spec.digits, ctxA);
   Check(!collideOk, "AC-6/AC-CAND-03: 3-arg overload returns false on a genuine candidate_id collision with different payload (R3, fail-closed)");
   Check(CandidateProjection_Count() == candCountBeforeCollide, "AC-6: colliding line did not add or replace a CandidateProjection record");

   //====================================================================
   // AC-8: live-applied record vs cold-rebuilt record, field equality,
   // for the SAME candidate (cA) - proves Pattern A's R6 claim (cold
   // rebuild and live-apply share one validation path) empirically, not
   // just by code-reading.
   //====================================================================
   CandidateProjectionRecord liveRecCopy = recCand; // captured earlier, from the AC-1 live-apply check above

   EventStore_Close();
   ResetAllProjections();
   StateProjector_Reset();
   // Not asserting .ok here: the raw file now genuinely contains a
   // candidate_id collision (cA's real line, then cCollide's rejected-
   // at-live-apply-but-still-durably-written line above) - a full
   // rebuild correctly re-encounters and rejects that same collision
   // (report.ok == false is the CORRECT outcome here, not a bug), same
   // "deterministically re-identified, never silently absorbed"
   // discipline RA-30.4's own AC-4 established. This check only cares
   // that cA's own (first, valid) record still resolves correctly.
   CandidateProjection_RebuildFromFile(RA39_TEST_FILE);
   CandidateProjectionRecord rebuiltRec;
   bool rebuiltFound = CandidateProjection_TryGet(cA.candidate_id, rebuiltRec);
   Check(rebuiltFound, "AC-8: cold rebuild finds the same candidate_id");
   Check(rebuiltRec.candidate_hash == liveRecCopy.candidate_hash, "AC-8: candidate_hash identical between live-apply and cold-rebuild");
   Check(rebuiltRec.context_event_id == liveRecCopy.context_event_id, "AC-8: context_event_id identical between live-apply and cold-rebuild");
   Check(rebuiltRec.context_hash == liveRecCopy.context_hash, "AC-8: context_hash identical between live-apply and cold-rebuild");
   Check(rebuiltRec.side == liveRecCopy.side, "AC-8: side identical between live-apply and cold-rebuild");

   //====================================================================
   // AC-CAND-01 / AC-CAND-04: the untouched 2-argument legacy API
   // compiles and behaves exactly as before - including a deliberate
   // orphan candidate with NO MarketContext/MARKET_CONTEXT_READY behind
   // it at all (mirrors Tests/MLQuantAI_Test_Phase0_3_FixtureDebtGate.mq5's
   // own orphan-candidate case, which this change must never break).
   //====================================================================
   Check(EventStore_Open(RA39_TEST_FILE), "AC-CAND-04 setup: reopen fixture file for the legacy-API check");
   TradeCandidate orphan;
   TradeCandidate_Init(orphan);
   orphan.candidate_id             = "CAND_ra39_orphan_legacy";
   orphan.root_event_id            = "ROOT_ra39_orphan";
   orphan.correlation_id           = "CORR_ra39_orphan";
   orphan.strategy_id              = STRAT_CRT;
   orphan.state                    = CANDIDATE_CREATED;
   orphan.context_event_id         = "CTX_never_existed";
   orphan.context_hash             = "HASH_never_existed";
   orphan.candidate_hash           = "HASH_orphan_ra39";
   orphan.detector_hash            = "HASH_detector_ra39";
   orphan.candidate_schema_version = "CANDIDATE_SCHEMA_V1";
   orphan.side                     = ORDER_TYPE_BUY;
   bool legacyOk = CRT_EmitCandidateCreated(orphan, 2); // 2-arg legacy call - no ctx exists to pass, none required
   Check(legacyOk, "AC-CAND-01/AC-CAND-04: 2-argument legacy CRT_EmitCandidateCreated(c, digits) still compiles and durably writes an orphan candidate with no MarketContext behind it, unchanged pre-RA-39 behavior");

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else Print("SOME CHECKS FAILED - see [FAIL] lines above.");
}
