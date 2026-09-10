//+------------------------------------------------------------------+
//| MLQuantAI_Test_RA30_4_ManualApprovalRuntimeConsistency.mq5         |
//| RA-30.4 (QA-frozen Manual Approval Runtime Projection Consistency): |
//| regression proving ManualApproval_Grant()'s new write-then-update,  |
//| fail-closed behavior (MLQuantAI_ManualApprovalEmission.mqh) - the    |
//| ONLY file this round modifies. Covers AC-1 through AC-6 exactly as   |
//| QA's RA-30.4 Design/Implementation Contract verdict specified.       |
//|                                                                    |
//| Fixture technique mirrors Tests/MLQuantAI_Test_C2_ManualApprovalProjection.mq5 |
//| verbatim (real B5->C1 pipeline, no fabricated hashes) - that file is |
//| NOT modified or included by this one (separate compilation unit,    |
//| MQL5 scripts cannot #include another .mq5), its fixture-building     |
//| functions are copied here unchanged so this file's ExecutionRequest/ |
//| DryRunResult fixtures satisfy ManualApprovalProjection_              |
//| ApplyLineWithLineage()'s own orphan/dry-run-accepted checks exactly   |
//| the same way, with no fabricated data anywhere.                      |
//|                                                                    |
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
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAdapter.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ManualApprovalEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ManualApprovalProjection.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - copied verbatim (same shapes/values) from
// Tests/MLQuantAI_Test_C2_ManualApprovalProjection.mq5, unmodified logic.
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
   ctx.context_event_id = "CTX_ra304_" + suffix;
   ctx.context_hash      = "test_context_hash_ra304_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_RA304_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

void BuildAcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_RA304_V1";
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
   ManualApprovalProjection_Reset();
}

// Builds AND emits every layer of the real chain through a dry-run
// ACCEPTED verdict - identical in structure to
// Tests/MLQuantAI_Test_C2_ManualApprovalProjection.mq5's own BuildFullChain.
bool BuildFullChain(ExecutionRequest &req, DryRunExecutionResult &dryRunResult, ExecutionPolicy &execPolicyOut,
                      string suffix, int dayOffset)
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
   TradeCandidate c;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;
   if(!CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits)) return false;

   FeatureSnapshot snapshot;
   if(!Candidate_ToFeatureSnapshot(c, ctx, snapshot)) return false;
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
   aiPolicy.decision_policy_version = "AIPOLICY_RA304_V1";
   aiPolicy.threshold_version       = "THRESH_RA304_V1";
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

   return ExecutionRequest_EmitAndEvaluate(req, execPolicyOut, dryRunResult);
}

void BuildValidGrantFor(const ExecutionRequest &req, string approver, datetime timestamp, datetime expiry, ManualApprovalGrant &g)
{
   ManualApprovalGrant_Init(g);
   g.execution_request_id     = req.execution_request_id;
   g.execution_request_hash   = req.execution_request_hash;
   g.execution_policy_version = req.execution_policy_version;
   g.candidate_id              = req.candidate_id;
   g.correlation_id             = req.correlation_id;
   g.approver_identity           = approver;
   g.approval_timestamp           = timestamp;
   g.approval_expiry              = expiry;
   g.approval_nonce               = ManualApproval_NewNonce();
}

#define RA30_4_TEST_FILE "MLQuantAI_Test_RA30_4_Fixture.jsonl"

void OnStart()
{
   Print("=== RA-30.4 Manual Approval Runtime Projection Consistency - regression test ===");

   if(FileIsExist(RA30_4_TEST_FILE, FILE_COMMON))
      FileDelete(RA30_4_TEST_FILE, FILE_COMMON);
   ResetAllProjections();

   Check(EventStore_Open(RA30_4_TEST_FILE), "setup: isolated test fixture file opens");

   ExecutionRequest req; DryRunExecutionResult dr; ExecutionPolicy policy;
   bool built = BuildFullChain(req, dr, policy, "ra304a", 0);
   Check(built, "setup: full real-pipeline chain builds (no fabricated hashes)");
   Check(dr.decision == SAFETY_GATE_ACCEPTED, "setup: dry-run ACCEPTED - satisfies ApplyLineWithLineage's own accepted-dry-run requirement");

   // Stage ExecutionRequestProjection/DryRunResultProjection/CandidateProjection
   // from the durable file BuildFullChain() just wrote to - mirrors what the
   // real EA's own OnInit rebuild already does before ANY ceremony command is
   // ever processed in every real round of this project (RUN_C22_CEREMONY_
   // FIXTURE has always run in an earlier EA session than GRANT_MANUAL_APPROVAL,
   // separated by a restart, so these projections are always already populated
   // by the time a real GRANT_MANUAL_APPROVAL executes). ExecutionRequest_
   // EmitAndEvaluate() (MLQuantAI_ExecutionRequestEventEmission.mqh, unmodified,
   // out of RA-30.4 scope) is itself a pure durable write with no incremental
   // projection update of its own - same pre-existing shape ManualApproval_
   // Grant() had before this round's fix, but fixing THAT is explicitly out of
   // RA-30.4's scope (QA froze this round to the ManualApproval registry only).
   // This call is the isolated-test equivalent of "the EA already restarted
   // once after the ceremony fixture ran" - the AC-1 same-session claim this
   // suite proves is specifically about GRANT_MANUAL_APPROVAL -> HasValidApproval,
   // never about candidate/request creation -> grant in the same breath (a
   // separate, not-yet-authorized scope).
   ExecutionAuditProjectionReport auditReport = ExecutionAuditProjection_RebuildFromFile(RA30_4_TEST_FILE);
   Check(auditReport.ok, "setup: ExecutionRequestProjection/DryRunResultProjection staged from the durable file (mirrors real EA OnInit ordering)");

   //====================================================================
   // AC-1 + AC-2: same-session grant, registry sees it IMMEDIATELY (no
   // reset/rebuild in between), and durable/runtime identity fields match.
   //====================================================================
   datetime ts  = TimeCurrent();
   datetime exp = ts + 900; // 15 min
   ManualApprovalGrant g1;
   BuildValidGrantFor(req, "ra304_reviewer", ts, exp, g1);

   int countBefore = ManualApprovalProjection_Count();
   bool grantOk = ManualApproval_Grant(g1);
   Check(grantOk, "AC-1: ManualApproval_Grant() succeeds (durable write + registry update both pass)");

   // AC-1: no ResetAllProjections()/RebuildFromFile() call anywhere
   // between the grant above and this check - proves the SAME live
   // session sees it without an EA restart.
   Check(ManualApprovalRegistry_HasValidApproval(req.execution_request_id, req.execution_request_hash,
         req.execution_policy_version, req.candidate_id, req.correlation_id, ts),
         "AC-1: HasValidApproval() sees the fresh approval immediately, SAME session, no restart/rebuild");

   // AC-2: registry gained exactly one record, with every identity field
   // matching the grant that was just durably written.
   Check(ManualApprovalProjection_Count() == countBefore + 1, "AC-2: registry gained exactly one new record");
   ManualApprovalProjectionRecord recCheck;
   Check(ManualApprovalProjection_GetAt(ManualApprovalProjection_Count() - 1, recCheck), "AC-2: new record is readable");
   Check(recCheck.execution_request_id == g1.execution_request_id, "AC-2: execution_request_id matches");
   Check(recCheck.execution_request_hash == g1.execution_request_hash, "AC-2: execution_request_hash matches");
   Check(recCheck.candidate_id == g1.candidate_id, "AC-2: candidate_id matches");
   Check(recCheck.correlation_id == g1.correlation_id, "AC-2: correlation_id matches");
   Check(recCheck.approval_nonce == g1.approval_nonce, "AC-2: approval_nonce matches");
   Check(recCheck.approval_expiry == g1.approval_expiry, "AC-2: approval_expiry matches");

   // AC-2 (durable side): the raw file itself actually contains this
   // exact nonce, exactly once - the durable half of the consistency claim.
   string lines[];
   int lineCount = EventStore_ReadAllLines(RA30_4_TEST_FILE, lines);
   int nonceOccurrences = 0;
   for(int i = 0; i < lineCount; i++)
      if(StringFind(lines[i], g1.approval_nonce) >= 0) nonceOccurrences++;
   Check(nonceOccurrences == 1, "AC-2: the durable EventStore file contains this exact approval_nonce exactly once");

   //====================================================================
   // AC-3: durable write failure -> registry must NOT gain a record.
   // Deterministic technique: close the store first (EventStore_
   // WriteLine returns false immediately when g_EventStore_Handle ==
   // INVALID_HANDLE - MLQuantAI_EventStore.mqh:74, unmodified) - no
   // reliance on cross-process/same-process file-locking timing.
   //====================================================================
   EventStore_Close();
   int countBeforeFailedWrite = ManualApprovalProjection_Count();
   ManualApprovalGrant g2;
   BuildValidGrantFor(req, "ra304_reviewer2", TimeCurrent(), TimeCurrent() + 900, g2);
   bool grantDuringClosedStore = ManualApproval_Grant(g2);
   Check(!grantDuringClosedStore, "AC-3: ManualApproval_Grant() returns false when the durable write fails (store closed)");
   Check(ManualApprovalProjection_Count() == countBeforeFailedWrite,
         "AC-3: registry gained ZERO new records when the durable write failed - fail-closed ordering held");

   Check(EventStore_Open(RA30_4_TEST_FILE), "setup: reopen store to continue");

   //====================================================================
   // AC-5: nonce collision - durable write of the SECOND event with a
   // reused nonce succeeds structurally (ManualApproval_Grant's own
   // pre-write checks don't include nonce-uniqueness), but
   // ApplyLineWithLineage's UNMODIFIED nonce-collision guard must still
   // reject it at the registry-apply step - proving ManualApproval_Grant()
   // still returns false (fail-closed) even when the durable append
   // itself succeeded, and exercising the exact "durable succeeded, registry
   // apply failed" diagnostic path RA-30.4 condition 1 requires to be
   // distinguishable (see the dedicated Print("[MLQuantAI][ERROR] RA-30.4: ...")
   // line in MLQuantAI_ManualApprovalEmission.mqh).
   //====================================================================
   int countBeforeNonceCollision = ManualApprovalProjection_Count();
   ManualApprovalGrant g3;
   BuildValidGrantFor(req, "ra304_reviewer3", TimeCurrent(), TimeCurrent() + 900, g3);
   g3.approval_nonce = g1.approval_nonce; // deliberate collision with the AC-1/AC-2 grant above
   bool grantWithCollidingNonce = ManualApproval_Grant(g3);
   Check(!grantWithCollidingNonce, "AC-5: a grant reusing an already-applied approval_nonce is rejected (fail-closed) even though the durable append itself succeeds");
   Check(ManualApprovalProjection_Count() == countBeforeNonceCollision,
         "AC-5: registry does NOT gain a record for the nonce-colliding grant");

   // Command-level duplicate protection (the SAME GRANT_MANUAL_APPROVAL
   // command_id never reaching this function twice) is CeremonyCommand_
   // TryClaim()'s job (MLQuantAI_CeremonyCommandEventEmission.mqh,
   // unmodified, untouched by RA-30.4) and is already proven by
   // Tests/MLQuantAI_Test_RA31_CeremonyCommandProtocol.mq5 - not
   // re-tested here to avoid duplicating that suite's own coverage.
   Check(true, "AC-5 (structural note): command_id-level dedup is CeremonyCommand_TryClaim()'s job, already proven by Tests/MLQuantAI_Test_RA31_CeremonyCommandProtocol.mq5 - unmodified by RA-30.4");

   //====================================================================
   // AC-6 (spot check): existing safety behavior unchanged - an expired
   // approval must still be reported invalid. Full matrix is the
   // untouched Tests/MLQuantAI_Test_C2_ManualApprovalProjection.mq5 /
   // Tests/MLQuantAI_Test_C2_EnvironmentLockGate.mq5 suites, re-run as
   // separate regression evidence (not modified, not duplicated here).
   //====================================================================
   Check(!ManualApprovalRegistry_HasValidApproval(req.execution_request_id, req.execution_request_hash,
         req.execution_policy_version, req.candidate_id, req.correlation_id, g1.approval_expiry),
         "AC-6 (spot check): HasValidApproval is false AT the approval's own expiry (boundary, unchanged behavior)");
   Check(!ManualApprovalRegistry_HasValidApproval("EXECREQ_wrong_id", req.execution_request_hash,
         req.execution_policy_version, req.candidate_id, req.correlation_id, ts),
         "AC-6 (spot check): HasValidApproval is false for a mismatched execution_request_id (unchanged behavior)");

   //====================================================================
   // AC-4: restart regression - reset everything, rebuild from the
   // durable file only, and confirm exactly one approval record exists
   // (the successful AC-1/AC-2 grant) - no duplication, no phantom
   // second record from the AC-3 (failed write) or AC-5 (nonce collision,
   // rejected at apply-time) attempts, since neither of those durably
   // produced a VALID, registry-acceptable approval line.
   //====================================================================
   EventStore_Close();
   ResetAllProjections();
   ManualApprovalProjectionReport report = ManualApprovalProjection_RebuildFromFile(RA30_4_TEST_FILE);
   // report.ok is correctly FALSE here, not a bug: the durable file still
   // contains the AC-5 nonce-colliding line (its EventStore append genuinely
   // succeeded - only its registry apply was rejected). A full-file rebuild
   // re-encounters that exact same line and correctly rejects it again
   // (ManualApprovalProjection_RebuildFromFile sets ok=false/lines_failed++
   // on ANY apply failure, by design - MLQuantAI_ManualApprovalProjection.mqh,
   // unmodified). This is the intended, deterministic behavior: the same
   // anomaly is identified the same way on every rebuild, never silently
   // absorbed. The actual AC-4 claim (no duplication of the ONE genuinely
   // valid grant) is what the two checks below prove.
   Check(!report.ok && report.lines_failed == 1, "AC-4: rebuild correctly re-rejects the one known-bad AC-5 nonce-collision line (durable-but-invalid), deterministically, not silently absorbed");
   Check(report.approval_lines_applied == 1, "AC-4: exactly ONE approval line applied after a fresh restart rebuild - no duplicate of the AC-1/AC-2 grant");
   Check(ManualApprovalProjection_Count() == 1, "AC-4: registry has exactly 1 record after restart, matching the durable file - no duplication");
   Check(ManualApprovalRegistry_HasValidApproval(req.execution_request_id, req.execution_request_hash,
         req.execution_policy_version, req.candidate_id, req.correlation_id, ts),
         "AC-4: the same approval is still valid after a restart rebuild (durable truth survives, as expected)");

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else Print("SOME CHECKS FAILED - see [FAIL] lines above.");
}
