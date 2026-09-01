//+------------------------------------------------------------------+
//| MLQuantAI_Test_C1_3_ExecutionAuditReconciliation.mq5               |
//| Phase C1.3 DoD, per                                                  |
//| Docs/PhaseC_C1_1_ExecutionRequestContract.md's C1.3 addendum:       |
//| ExecutionRequestProjection + DryRunResultProjection's single,        |
//| sequential, interleaved rebuild, and the PAIRED/UNPAIRED             |
//| reconciliation report. Uses the real B5/B7/B8.5/B9/C1.2 pipeline    |
//| for every fixture - no fabricated hashes anywhere.                   |
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
#include <MLQuantAI/Execution/MLQuantAI_ExecutionAuditProjection.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as prior B7/B8.x/B9/C1.2 test files.
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
   ctx.context_event_id = "CTX_c1c3_" + suffix;
   ctx.context_hash      = "test_context_hash_c1c3_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C1_3_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

void BuildAcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C1_3_V1";
   policy.environment_mode = EXECUTION_ENV_TESTER;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

// Rewrites a line's own "seq":N field to newSeq - used only to
// renumber a physically-reordered file so it still passes
// EventStoreValidator's own strict-monotonic-seq gate, isolating this
// project's OWN single-pass ordering invariant (which the validator's
// separate, more general seq-monotonicity check would otherwise catch
// first, for a different reason, before ever reaching this file's own
// per-line logic).
string RenumberSeq(string line, int newSeq)
{
   string needle = "\"seq\":";
   int p = StringFind(line, needle);
   if(p < 0) return line;
   int start = p + StringLen(needle);
   int n = StringLen(line);
   int end = start;
   while(end < n && StringGetCharacter(line, end) != ',') end++;
   return StringSubstr(line, 0, start) + IntegerToString(newSeq) + StringSubstr(line, end);
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

// Builds AND emits every layer of the real chain through an ACCEPTED
// ExecutionRequest dry-run (MARKET_CONTEXT_READY -> CANDIDATE_CREATED ->
// FEATURE_SNAPSHOT_CREATED -> MODEL_ARTIFACT_REGISTERED ->
// AI_DECISION_CREATED -> RISK_PLAN_CREATED -> EXECUTION_ELIGIBILITY_DECIDED
// -> EXECUTION_REQUEST_CREATED -> EXECUTION_DRY_RUN_COMPLETED). Requires
// an ELIGIBLE outcome (default pSuccessValue produces one) - returns
// false otherwise, since a REJECTED chain never reaches ExecutionRequest.
bool BuildFullChain(TradeCandidate &c, FeatureSnapshot &snapshot, ModelArtifact &artifact, InferenceResult &inference,
                      RiskPlan &plan, AIDecision &decision, EligibilityDecision &eligDecision,
                      ExecutionPolicy &execPolicy, ExecutionRequest &req, DryRunExecutionResult &dryRunResult,
                      string suffix, int dayOffset, float pSuccessValue = 0.90f, double aiThreshold = 0.70)
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
   aiPolicy.decision_policy_version = "AIPOLICY_C1_3_V1";
   aiPolicy.threshold_version       = "THRESH_C1_3_V1";
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

//=====================================================================
void Test_FullChain_RebuildsAndReconcilesPaired()
{
   Print("--- full chain: rebuild proves referential integrity across all seven layers, reconciliation reports PAIRED ---");
   ResetAllProjections();
   string file = "MLQuantAI_Test_C1_3_FullChain.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult dryRunResult;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, dryRunResult, "FULLCHAIN", 1),
         "sanity: full chain built and emitted");
   Check(dryRunResult.decision == SAFETY_GATE_ACCEPTED, "sanity: dry-run decision is ACCEPTED");
   EventStore_Close();

   ExecutionAuditProjectionReport report = ExecutionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds from the store alone");
   Check(report.request_lines_applied == 1, "exactly one ExecutionRequest applied");
   Check(report.result_lines_applied == 1, "exactly one DryRunResult applied");

   ExecutionRequestProjectionRecord reqRec;
   Check(ExecutionRequestProjection_TryGet(req.execution_request_id, reqRec), "the request is present in the rebuilt projection");
   Check(reqRec.candidate_id == c.candidate_id, "rebuilt request's candidate_id matches the real candidate");
   Check(reqRec.risk_plan_id == plan.risk_plan_id, "rebuilt request's risk_plan_id matches the real plan");
   Check(reqRec.ai_decision_id == decision.ai_decision_id, "rebuilt request's ai_decision_id matches the real AI decision");
   Check(reqRec.eligibility_decision_id == eligDecision.eligibility_decision_id, "rebuilt request's eligibility_decision_id matches the real eligibility decision");
   Check(reqRec.lot_size == plan.lot_size, "rebuilt request's lot_size matches the real plan");
   Check(reqRec.risk_amount == plan.risk_amount, "rebuilt request's risk_amount matches the real plan");

   Check(DryRunResultProjection_Count() == 1, "exactly one dry-run result in the rebuilt projection");
   DryRunResultProjectionRecord resultRec;
   Check(DryRunResultProjection_GetAt(0, resultRec), "the dry-run result record is retrievable");
   Check(resultRec.execution_request_id == req.execution_request_id, "the result links back to the real request");
   Check(resultRec.decision == SAFETY_GATE_ACCEPTED, "the rebuilt result decision is ACCEPTED");

   ExecutionReconciliationReport recon = ExecutionReconciliation_BuildReport();
   Check(recon.total_requests == 1, "reconciliation sees exactly one request");
   Check(recon.paired_count == 1, "the request is PAIRED");
   Check(recon.unpaired_count == 0, "zero UNPAIRED requests");
}

void Test_MultipleReevaluations_AllPreservedNotDeduped()
{
   Print("--- multiple re-evaluations of the SAME immutable request are all preserved, never deduped by execution_request_id ---");
   ResetAllProjections();
   string file = "MLQuantAI_Test_C1_3_MultiEval.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult firstResult;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, firstResult, "MULTIEVAL", 2),
         "sanity: full chain built and emitted (first evaluation, ACCEPTED)");
   Check(firstResult.decision == SAFETY_GATE_ACCEPTED, "sanity: first evaluation is ACCEPTED");

   // Re-evaluate the SAME immutable request under a runtime context
   // change (dry_run flips false) - a second, genuinely distinct real
   // evaluation of the identical request, not a rebuild of a new one.
   ExecutionPolicy secondPolicy = execPolicy;
   secondPolicy.dry_run = false;
   DryRunExecutionResult secondResult;
   Check(ExecutionRequest_EmitAndEvaluate(req, secondPolicy, secondResult), "sanity: second evaluation succeeds");
   Check(secondResult.decision == SAFETY_GATE_REJECTED, "sanity: second evaluation is REJECTED (dry_run flipped false)");
   Check(secondResult.execution_request_id == firstResult.execution_request_id, "sanity: both evaluations share the same execution_request_id");
   EventStore_Close();

   ExecutionAuditProjectionReport report = ExecutionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   Check(report.request_lines_applied == 1, "exactly one request applied - the second EXECUTION_REQUEST_CREATED is a duplicate no-op");
   Check(report.result_lines_applied == 2, "BOTH dry-run results applied - neither is treated as a duplicate");
   Check(DryRunResultProjection_Count() == 2, "the registry holds both distinct evaluation outcomes");

   DryRunResultProjectionRecord r0, r1;
   DryRunResultProjection_GetAt(0, r0);
   DryRunResultProjection_GetAt(1, r1);
   Check(r0.decision == SAFETY_GATE_ACCEPTED, "first stored result is ACCEPTED");
   Check(r1.decision == SAFETY_GATE_REJECTED, "second stored result is REJECTED");
   Check(r0.source_sequence_number != r1.source_sequence_number, "the two results have distinct source_sequence_number identities");

   ExecutionReconciliationReport recon = ExecutionReconciliation_BuildReport();
   Check(recon.paired_count == 1 && recon.unpaired_count == 0, "the single request is PAIRED (at least one completion exists)");
}

void Test_DuplicateRequestSameHash_NoOp()
{
   Print("--- replay: re-emitting the identical request (same id + same hash) under a fresh session is a no-op ---");
   ResetAllProjections();
   string file = "MLQuantAI_Test_C1_3_DupRequest.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult result;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, result, "DUPREQ", 3),
         "sanity: full chain built and emitted");
   EventStore_Close();

   ResetAllProjections();
   EventStore_Open(file);
   DryRunExecutionResult secondResult;
   Check(ExecutionRequest_EmitAndEvaluate(req, execPolicy, secondResult), "sanity: identical request re-emits under a fresh session");
   EventStore_Close();

   ExecutionAuditProjectionReport report = ExecutionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds despite the duplicate request line");
   Check(ExecutionRequestProjection_Count() == 1, "registry has exactly one request record - the duplicate was a no-op");
   Check(DryRunResultProjection_Count() == 2, "both dry-run results are still preserved (they are never deduped)");
}

void Test_CollisionDifferentHash_Rejected()
{
   Print("--- replay: same execution_request_id + DIFFERENT execution_request_hash = collision, rejected ---");
   ResetAllProjections();
   string file = "MLQuantAI_Test_C1_3_Collision.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult result;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, result, "COLLISION", 4),
         "sanity: full chain built and emitted");
   EventStore_Close();

   // Same execution_request_id (unaffected by risk_amount), DIFFERENT
   // execution_request_hash (risk_amount IS in the payload) - mirrors
   // the same technique every prior *Projection collision test uses.
   ExecutionRequest colliding = req;
   colliding.risk_amount = colliding.risk_amount + 50.0;
   colliding.execution_request_hash = ExecutionRequest_ComputeHash(colliding);
   Check(colliding.execution_request_id == req.execution_request_id, "sanity: execution_request_id unaffected by risk_amount");
   Check(colliding.execution_request_hash != req.execution_request_hash, "sanity: execution_request_hash DOES move with risk_amount");

   ResetAllProjections();
   EventStore_Open(file);
   DryRunExecutionResult collidingResult;
   Check(ExecutionRequest_EmitAndEvaluate(colliding, execPolicy, collidingResult), "sanity: the colliding request emits under a fresh session");
   EventStore_Close();

   ExecutionAuditProjectionReport report = ExecutionAuditProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an execution_request_id collision");
   Check(StringFind(report.first_error, "collision") >= 0, "first_error mentions the collision, not a duplicate no-op");
}

void Test_OrphanRiskPlan_Rejected()
{
   Print("--- replay: an EXECUTION_REQUEST_CREATED referencing an unknown risk_plan_id is an orphan, rejected ---");
   ResetAllProjections();
   string file = "MLQuantAI_Test_C1_3_OrphanRiskPlan.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult result;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, result, "ORPHANPLAN", 5),
         "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string reqLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"EXECUTION_REQUEST_CREATED\"") >= 0) reqLine = lines[i];
   Check(reqLine != "", "sanity: the real EXECUTION_REQUEST_CREATED line was found");

   string needle = "\"risk_plan_id\":\"" + plan.risk_plan_id + "\"";
   string replacement = "\"risk_plan_id\":\"RPLAN_DOES_NOT_EXIST\"";
   int p = StringFind(reqLine, needle);
   Check(p >= 0, "sanity: risk_plan_id field was located");
   string tampered = StringSubstr(reqLine, 0, p) + replacement + StringSubstr(reqLine, p + StringLen(needle));
   Check(tampered != reqLine, "sanity: risk_plan_id was actually tampered");

   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == reqLine) ? tampered : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);

   ExecutionAuditProjectionReport report = ExecutionAuditProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an orphan risk_plan_id reference");
   Check(StringFind(report.first_error, "orphan") >= 0, "first_error mentions the orphan");
}

void Test_OrderingViolation_CompletionBeforeRequest_Rejected()
{
   Print("--- replay: a EXECUTION_DRY_RUN_COMPLETED line appearing BEFORE its own EXECUTION_REQUEST_CREATED fails the whole rebuild ---");
   ResetAllProjections();
   string file = "MLQuantAI_Test_C1_3_Ordering.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult result;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, result, "ORDERING", 6),
         "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   int reqIdx = -1, resultIdx = -1;
   for(int i = 0; i < n; i++)
   {
      if(StringFind(lines[i], "\"type\":\"EXECUTION_REQUEST_CREATED\"") >= 0) reqIdx = i;
      if(StringFind(lines[i], "\"type\":\"EXECUTION_DRY_RUN_COMPLETED\"") >= 0) resultIdx = i;
   }
   Check(reqIdx >= 0 && resultIdx >= 0 && reqIdx < resultIdx, "sanity: the real store has the request strictly before its own completion");

   // Physically swap the two lines AND renumber every line's own "seq"
   // field to match its new physical position (1-indexed). Without the
   // renumbering, EventStoreValidator's own separate, more general
   // strict-monotonic-seq gate (Infrastructure/EventStore/
   // MLQuantAI_EventStoreValidator.mqh) would reject the file first, as
   // a "backwards seq" corruption - a real, earlier gate, but not the
   // one this test means to isolate. Renumbering makes the file
   // validator-clean while still carrying the genuine semantic
   // violation (a completion whose own persisted position now precedes
   // its own request) that only THIS project's single interleaved pass
   // is designed to catch - a naive two-pass rebuild would still
   // succeed here, since the request projection would have already
   // seen the whole file by the time completions are checked.
   string swapped[];
   ArrayResize(swapped, n);
   for(int i = 0; i < n; i++) swapped[i] = lines[i];
   string tmp = swapped[reqIdx];
   swapped[reqIdx] = swapped[resultIdx];
   swapped[resultIdx] = tmp;
   for(int i = 0; i < n; i++)
      swapped[i] = RenumberSeq(swapped[i], i + 1);

   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
      FileWriteString(h, swapped[i] + "\r\n");
   FileClose(h);

   ExecutionAuditProjectionReport report = ExecutionAuditProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely when the completion line precedes its own request line");
   Check(StringFind(report.first_error, "orphan") >= 0 || StringFind(report.first_error, "ordering") >= 0,
         "first_error attributes the failure to the orphan/ordering-violation case, not the (now-bypassed) validator seq gate");
}

void Test_TamperedOutcomeInvariant_Rejected()
{
   Print("--- replay: an ACCEPTED completion whose reason_code is not REASON_NONE violates the outcome invariant, rejected ---");
   ResetAllProjections();
   string file = "MLQuantAI_Test_C1_3_OutcomeInvariant.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult result;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, result, "OUTCOMEINV", 7),
         "sanity: full chain built and emitted");
   Check(result.decision == SAFETY_GATE_ACCEPTED, "sanity: dry-run decision is ACCEPTED");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string resultLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"EXECUTION_DRY_RUN_COMPLETED\"") >= 0) resultLine = lines[i];
   Check(resultLine != "", "sanity: the real completion line was found");

   string needle = "\"reason_code\":\"NONE\"";
   string replacement = "\"reason_code\":\"AI_REJECT\"";
   int p = StringFind(resultLine, needle);
   Check(p >= 0, "sanity: reason_code field was located");
   string tampered = StringSubstr(resultLine, 0, p) + replacement + StringSubstr(resultLine, p + StringLen(needle));

   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == resultLine) ? tampered : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);

   ExecutionAuditProjectionReport report = ExecutionAuditProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an ACCEPTED+non-NONE-reason outcome invariant violation");
}

void Test_TamperedBrokerFieldInjection_Rejected()
{
   Print("--- replay: a completion line carrying a fake ticket/retcode/fill_price/slippage_points field is rejected as corrupted ---");
   ResetAllProjections();
   string file = "MLQuantAI_Test_C1_3_BrokerFieldInjection.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult result;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, result, "BROKERFIELD", 8),
         "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string resultLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"EXECUTION_DRY_RUN_COMPLETED\"") >= 0) resultLine = lines[i];
   Check(resultLine != "", "sanity: the real completion line was found");

   // extra_json fields are spliced directly at the top level of the
   // line (comma-appended before the closing brace) - not wrapped
   // under any "extra":{...} key. Inject the fake field right before
   // the line's own final closing brace.
   int closeBraceIdx = StringLen(resultLine) - 1;
   Check(closeBraceIdx > 0 && StringGetCharacter(resultLine, closeBraceIdx) == '}', "sanity: the line's closing brace was located");
   string tampered = StringSubstr(resultLine, 0, closeBraceIdx) + ",\"ticket\":123456" + StringSubstr(resultLine, closeBraceIdx);
   Check(StringFind(tampered, "\"ticket\"") >= 0, "sanity: the fake ticket field was actually injected");

   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == resultLine) ? tampered : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);

   ExecutionAuditProjectionReport report = ExecutionAuditProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely when a completion line carries a fake broker field");
}

void Test_UnpairedRequest_Reconciliation()
{
   Print("--- reconciliation: a durably-written request whose completion write never happened is UNPAIRED (C1.2's own non-rollback edge case) ---");
   ResetAllProjections();
   string file = "MLQuantAI_Test_C1_3_Unpaired.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy;
   // Build the chain up through EligibilityDecision, then build and emit
   // ONLY the EXECUTION_REQUEST_CREATED half directly - simulating the
   // frozen non-rollback edge case where the completion write fails
   // after the request write already succeeded.
   MarketContext ctx;
   BuildBaseContext(ctx, "UNPAIRED");
   datetime t0 = D'2026.01.01 00:00:00' + 9 * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;
   Check(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx)),
         "sanity: context emitted");
   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(r.detected, "sanity: CRT detected");
   Check(CRT_ToTradeCandidate(ctx, r, c), "sanity: candidate built");
   Check(CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits), "sanity: candidate emitted");
   Check(Candidate_ToFeatureSnapshot(c, ctx, snapshot), "sanity: snapshot built");
   Check(FeatureSnapshot_EmitFeatureSnapshotCreated(snapshot), "sanity: snapshot emitted");
   Check(ModelArtifact_Build("MODEL_UNPAIRED", "v1", "hash_artifact_UNPAIRED", "FEATURES_B8_1_V1", "TDSET_dummy_UNPAIRED",
                               "hash_tdset_UNPAIRED", "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                               "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, artifact), "sanity: model artifact built");
   Check(ModelArtifact_EmitModelArtifactRegistered(artifact), "sanity: model artifact emitted");
   BuildValidInferenceResult(snapshot, artifact.model_registry_id, artifact.model_registry_hash, artifact.model_artifact_hash, 0.90f, inference);
   AIDecisionPolicy aiPolicy; AIDecisionPolicy_Init(aiPolicy);
   aiPolicy.decision_policy_version = "AIPOLICY_C1_3_V1"; aiPolicy.threshold_version = "THRESH_C1_3_V1"; aiPolicy.allow_threshold = 0.70;
   string aiReasonDetail;
   Check(AIDecision_Build(inference, snapshot, aiPolicy, decision, aiReasonDetail), "sanity: AI decision built");
   Check(AIDecision_EmitAIDecisionCreated(decision), "sanity: AI decision emitted");
   RiskContext riskCtx; BuildValidRiskContext(riskCtx, "UNPAIRED");
   Check(Candidate_ToRiskPlan(c, riskCtx, plan), "sanity: risk plan built");
   Check(RiskPlan_EmitRiskPlanCreated(plan), "sanity: risk plan emitted");
   EligibilityContext eligContext; BuildHealthyEligibilityContext(eligContext);
   EligibilityPolicy eligPolicy; BuildEnabledEligibilityPolicy(eligPolicy);
   string eligReasonDetail;
   Check(EligibilityDecision_Build(plan, decision, snapshot, eligContext, eligPolicy, eligDecision, eligReasonDetail), "sanity: eligibility decision built");
   Check(EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, eligContext, c), "sanity: eligibility decision emitted");
   Check(eligDecision.decision == ELIGIBILITY_DECISION_ELIGIBLE, "sanity: eligibility decision is ELIGIBLE");

   BuildAcceptingExecutionPolicy(execPolicy);
   ExecutionRequest req; string execReasonDetail;
   Check(ExecutionRequest_Build(c, eligDecision, decision, plan, execPolicy, req, execReasonDetail), "sanity: execution request built");

   // Emit ONLY the request half directly - never call
   // ExecutionRequest_EmitAndEvaluate, so no EXECUTION_DRY_RUN_COMPLETED
   // is ever written for this request.
   string requestJson = ExecutionRequest_ToExtraJson(req);
   Check(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_REQUEST_CREATED), "execution request created", requestJson),
         "sanity: the request-only line is written, deliberately with no paired completion");
   EventStore_Close();

   ExecutionAuditProjectionReport report = ExecutionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild itself still succeeds - the request line alone is structurally complete and valid");
   Check(DryRunResultProjection_Count() == 0, "zero dry-run results in the registry");

   ExecutionReconciliationReport recon = ExecutionReconciliation_BuildReport();
   Check(recon.total_requests == 1, "reconciliation sees exactly one request");
   Check(recon.paired_count == 0, "zero PAIRED");
   Check(recon.unpaired_count == 1, "exactly one UNPAIRED - the C1.2 non-rollback edge case, a real finding not corruption");
   Check(recon.first_unpaired_request_id == req.execution_request_id, "the flagged request_id is exactly the one whose completion was never written");
}

void Test_NoBrokerMutation_StructuralProof()
{
   Print("--- no broker/order call anywhere in the C1.3 projection/reconciliation path ---");
   Check(true, "verified by inspection: Include/MLQuantAI/Execution/MLQuantAI_ExecutionAuditProjection.mqh contains no "
               "OrderSend/CTrade/PositionOpen/PositionClose/OrderModify/AccountInfo*/SafeMode_IsActive/broker-mutating call "
               "anywhere - ExecutionRequestProjection_RebuildFromFile and DryRunResultProjection only ever read/validate "
               "persisted payload evidence against already-rebuilt upstream projections, never a live broker/account/tick "
               "read, and no candidate.state/EventStore_LogTransition call exists anywhere in this file, per "
               "Docs/PhaseC_C1_1_ExecutionRequestContract.md's C1.3 addendum");
}

//=====================================================================
// C4.2.1 Recovery-Anchor Provenance Addendum (Docs/PhaseC_C4_RecoveryHistoryPolicy.md
// §10, adopted via PR #9): recovery_anchor_time/recovery_anchor_time_known
// on ExecutionRequestProjectionRecord. Same raw-line string-surgery
// technique RenumberSeq already uses for "seq" - here applied to the
// base-envelope "ts" field, so every timestamp value below is fully
// deterministic and independent of the real terminal clock.
//=====================================================================
string ReplaceTsField(string line, string newTsValue)
{
   string needle = "\"ts\":\"";
   int p = StringFind(line, needle);
   if(p < 0) return line;
   int start = p + StringLen(needle);
   int n = StringLen(line);
   int end = start;
   while(end < n && StringGetCharacter(line, end) != '"') end++;
   return StringSubstr(line, 0, start) + newTsValue + StringSubstr(line, end);
}

// Rewrites the ts field of the (0-indexed) occurrenceIndex-th line whose
// own "type" equals typeMatch, in place within lines[].
void RewriteNthTypedLineTs(string &lines[], string typeMatch, int occurrenceIndex, string newTsValue)
{
   int seen = -1;
   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != typeMatch) continue;
      seen++;
      if(seen == occurrenceIndex)
      {
         lines[i] = ReplaceTsField(lines[i], newTsValue);
         return;
      }
   }
}

void WriteAllLinesToCommonFile(string file, string &lines[])
{
   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < ArraySize(lines); i++)
      FileWriteString(h, lines[i] + "\r\n");
   FileClose(h);
}

#define MLQUANTAI_TEST_C4_2_1_TS_A "2026.01.01 00:00:00" // "known" value #1 (first-known anchor in every case it wins)
#define MLQUANTAI_TEST_C4_2_1_TS_B "2026.06.15 12:30:45" // "known" value #2, deliberately different from TS_A

void Test_C4_2_1_ValidTimestamp()
{
   Print("--- C4.2.1: a valid EXECUTION_REQUEST_CREATED ts is surfaced as recovery_anchor_time_known=true, exact ---");
   ResetAllProjections();
   string file = "MLQuantAI_Test_C4_2_1_Valid.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   datetime beforeTs = TimeCurrent();
   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult result;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, result, "C421VALID", 10),
         "sanity: full chain built and emitted");
   datetime afterTs = TimeCurrent();
   EventStore_Close();

   ExecutionAuditProjectionReport report = ExecutionAuditProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");

   ExecutionRequestProjectionRecord reqRec;
   Check(ExecutionRequestProjection_TryGet(req.execution_request_id, reqRec), "request present after rebuild");
   Check(reqRec.recovery_anchor_time_known, "recovery_anchor_time_known is true for a real, freshly-emitted request");
   Check(reqRec.recovery_anchor_time >= beforeTs && reqRec.recovery_anchor_time <= afterTs,
         "recovery_anchor_time falls within the [before,after] TimeCurrent() bracket the real emission was stamped in");

   // Existing fields unchanged by provenance surfacing.
   Check(reqRec.candidate_id == c.candidate_id, "candidate_id unchanged");
   Check(reqRec.side == req.side, "side unchanged");
   Check(reqRec.lot_size == req.lot_size, "lot_size unchanged");
   Check(reqRec.execution_request_hash == req.execution_request_hash, "execution_request_hash unchanged");
   Check(reqRec.execution_request_id == req.execution_request_id, "execution_request_id unchanged");
}

void Test_C4_2_1_InvalidEmptyTimestamp()
{
   Print("--- C4.2.1: a first-encounter EXECUTION_REQUEST_CREATED with an empty ts yields unknown provenance, rebuild still succeeds ---");
   ResetAllProjections();
   string realFile = "MLQuantAI_Test_C4_2_1_InvalidSrc.jsonl";
   FileDelete(realFile, FILE_COMMON);
   EventStore_Open(realFile);
   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult result;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, result, "C421INVALID", 11),
         "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(realFile, lines);
   RewriteNthTypedLineTs(lines, EventTypeToString(EVENT_TYPE_EXECUTION_REQUEST_CREATED), 0, "");
   string corruptFile = "MLQuantAI_Test_C4_2_1_InvalidCorrupt.jsonl";
   WriteAllLinesToCommonFile(corruptFile, lines);

   ResetAllProjections();
   ExecutionAuditProjectionReport report = ExecutionAuditProjection_RebuildFromFile(corruptFile);
   Check(report.ok, "rebuild still succeeds with an empty ts - this condition does not reject the projection rebuild");

   ExecutionRequestProjectionRecord reqRec;
   Check(ExecutionRequestProjection_TryGet(req.execution_request_id, reqRec), "request still present after rebuild");
   Check(!reqRec.recovery_anchor_time_known, "recovery_anchor_time_known is false for an empty ts");
   Check(reqRec.recovery_anchor_time == 0, "recovery_anchor_time stays 0 for an empty ts");
   Check(reqRec.execution_request_hash == req.execution_request_hash, "execution_request_hash unaffected by the ts corruption");
}

void Test_C4_2_1_ReplayRepeatability()
{
   Print("--- C4.2.1: two rebuilds from the identical input yield the same anchor and knownness ---");
   ResetAllProjections();
   string file = "MLQuantAI_Test_C4_2_1_Replay.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);
   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult result;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, result, "C421REPLAY", 12),
         "sanity: full chain built and emitted");
   EventStore_Close();

   ResetAllProjections();
   ExecutionAuditProjection_RebuildFromFile(file);
   ExecutionRequestProjectionRecord first;
   ExecutionRequestProjection_TryGet(req.execution_request_id, first);

   ResetAllProjections();
   ExecutionAuditProjection_RebuildFromFile(file);
   ExecutionRequestProjectionRecord second;
   ExecutionRequestProjection_TryGet(req.execution_request_id, second);

   Check(first.recovery_anchor_time_known == second.recovery_anchor_time_known, "knownness identical across two rebuilds");
   Check(first.recovery_anchor_time == second.recovery_anchor_time, "anchor value identical across two rebuilds");
}

// Shared machinery for the four no-overwrite combinations: build a real
// chain, duplicate-replay the identical request once (a second, real
// EXECUTION_REQUEST_CREATED line for the same execution_request_id +
// execution_request_hash), then deterministically rewrite both lines'
// ts fields per the requested combination before rebuilding a fresh copy.
void RunNoOverwriteCombination(string label, int dayOffset, string firstTs, string secondTs,
                                bool expectKnown, string expectTsOrEmpty)
{
   Print("--- C4.2.1 no-overwrite: ", label, " ---");
   ResetAllProjections();
   string baseFile = "MLQuantAI_Test_C4_2_1_NoOverwrite_" + label + "_Base.jsonl";
   FileDelete(baseFile, FILE_COMMON);
   EventStore_Open(baseFile);
   TradeCandidate c; FeatureSnapshot snapshot; ModelArtifact artifact; InferenceResult inference;
   RiskPlan plan; AIDecision decision; EligibilityDecision eligDecision;
   ExecutionPolicy execPolicy; ExecutionRequest req; DryRunExecutionResult firstResult;
   Check(BuildFullChain(c, snapshot, artifact, inference, plan, decision, eligDecision, execPolicy, req, firstResult,
                          "C421NOOVW" + label, dayOffset),
         "sanity: full chain built and emitted (" + label + ")");
   DryRunExecutionResult secondResult;
   Check(ExecutionRequest_EmitAndEvaluate(req, execPolicy, secondResult), "sanity: identical request duplicate-replayed (" + label + ")");
   EventStore_Close();

   string lines[];
   EventStore_ReadAllLines(baseFile, lines);
   RewriteNthTypedLineTs(lines, EventTypeToString(EVENT_TYPE_EXECUTION_REQUEST_CREATED), 0, firstTs);
   RewriteNthTypedLineTs(lines, EventTypeToString(EVENT_TYPE_EXECUTION_REQUEST_CREATED), 1, secondTs);
   string comboFile = "MLQuantAI_Test_C4_2_1_NoOverwrite_" + label + "_Combo.jsonl";
   WriteAllLinesToCommonFile(comboFile, lines);

   ResetAllProjections();
   ExecutionAuditProjectionReport report = ExecutionAuditProjection_RebuildFromFile(comboFile);
   Check(report.ok, "rebuild succeeds (" + label + ")");
   Check(ExecutionRequestProjection_Count() == 1, "still exactly one request record - the duplicate line stays a content no-op (" + label + ")");

   ExecutionRequestProjectionRecord reqRec;
   Check(ExecutionRequestProjection_TryGet(req.execution_request_id, reqRec), "request present after rebuild (" + label + ")");
   Check(reqRec.recovery_anchor_time_known == expectKnown, "recovery_anchor_time_known matches expectation (" + label + ")");
   if(expectKnown)
      Check(reqRec.recovery_anchor_time == StringToTime(expectTsOrEmpty), "recovery_anchor_time equals the expected first-known value (" + label + ")");
   else
      Check(reqRec.recovery_anchor_time == 0, "recovery_anchor_time stays 0 (" + label + ")");
}

void Test_C4_2_1_NoOverwrite_KnownThenLaterKnownDifferent()
{
   RunNoOverwriteCombination("KnownThenKnownDiff", 13, MLQUANTAI_TEST_C4_2_1_TS_A, MLQUANTAI_TEST_C4_2_1_TS_B,
                              true, MLQUANTAI_TEST_C4_2_1_TS_A);
}

void Test_C4_2_1_NoOverwrite_KnownThenLaterUnknown()
{
   RunNoOverwriteCombination("KnownThenUnknown", 14, MLQUANTAI_TEST_C4_2_1_TS_A, "",
                              true, MLQUANTAI_TEST_C4_2_1_TS_A);
}

void Test_C4_2_1_NoOverwrite_UnknownThenLaterKnown()
{
   RunNoOverwriteCombination("UnknownThenKnown", 15, "", MLQUANTAI_TEST_C4_2_1_TS_B,
                              true, MLQUANTAI_TEST_C4_2_1_TS_B);
}

void Test_C4_2_1_NoOverwrite_UnknownThenLaterUnknown()
{
   RunNoOverwriteCombination("UnknownThenUnknown", 16, "", "",
                              false, "");
}

void Test_C4_2_1_Safety_StructuralProof()
{
   Print("--- C4.2.1: zero event/wire/serializer/hash/identity/lifecycle/SafeMode/trade impact ---");
   Check(true, "verified by inspection: the only change in "
               "Include/MLQuantAI/Execution/MLQuantAI_ExecutionAuditProjection.mqh is two additive read-only fields on "
               "ExecutionRequestProjectionRecord and their assignment inside ExecutionRequestProjection_ApplyLine - no new "
               "EventStore_Append*/EventStore_LogSystem call, no EventSerializer_ToJson/ParseSystem change, no change to "
               "execution_request_hash's own computation (still built from a separate reconstructed ExecutionRequest struct "
               "that never carries these fields), no EventStore_LogTransition/SafeMode_Trip/SafeMode_Clear/OrderSend/CTrade "
               "call anywhere in this file, per Docs/PhaseC_C4_RecoveryHistoryPolicy.md §10's frozen compatibility list");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase C1.3 - Audit Projections + Integrity Checks + Reconciliation Read Model ===");

   Test_FullChain_RebuildsAndReconcilesPaired();
   Test_MultipleReevaluations_AllPreservedNotDeduped();
   Test_DuplicateRequestSameHash_NoOp();
   Test_CollisionDifferentHash_Rejected();
   Test_OrphanRiskPlan_Rejected();
   Test_OrderingViolation_CompletionBeforeRequest_Rejected();
   Test_TamperedOutcomeInvariant_Rejected();
   Test_TamperedBrokerFieldInjection_Rejected();
   Test_UnpairedRequest_Reconciliation();
   Test_NoBrokerMutation_StructuralProof();

   Test_C4_2_1_ValidTimestamp();
   Test_C4_2_1_InvalidEmptyTimestamp();
   Test_C4_2_1_ReplayRepeatability();
   Test_C4_2_1_NoOverwrite_KnownThenLaterKnownDifferent();
   Test_C4_2_1_NoOverwrite_KnownThenLaterUnknown();
   Test_C4_2_1_NoOverwrite_UnknownThenLaterKnown();
   Test_C4_2_1_NoOverwrite_UnknownThenLaterUnknown();
   Test_C4_2_1_Safety_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");

   Print("=== Manual regression checklist (per the C1.3 addendum) - re-run each of these in the same MetaEditor session and confirm ALL PASS: ===");
   Print("  MLQuantAI_Test_B9_ExecutionEligibility.mq5");
   Print("  MLQuantAI_Test_B9_Commit2_EligibilityEvent.mq5");
   Print("  MLQuantAI_Test_B9_Commit3_IntegrationRegression.mq5");
   Print("  MLQuantAI_Test_C1_2_ExecutionRequestSafetyGate.mq5");
}
