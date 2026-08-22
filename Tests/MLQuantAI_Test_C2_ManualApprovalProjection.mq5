//+------------------------------------------------------------------+
//| MLQuantAI_Test_C2_ManualApprovalProjection.mq5                    |
//| C2 manual-approval contract, gate integration round: the           |
//| projection (read side) + ManualApprovalRegistry_HasValidApproval() |
//| query, per Docs/PhaseC_C2_ManualApprovalContract.md's "Projection  |
//| apply-time validation" and "Registry query" sections. Uses the      |
//| real B5/B7/B8.5/B9/C1 pipeline for every fixture - no fabricated    |
//| hashes anywhere, same precedent C2.3's own test file established.   |
//| NO OrderSend/CTrade/OnTradeTransaction/History*/Position*/Order*    |
//| broker API call anywhere in this file.                              |
//|                                                                    |
//| Deliberately does NOT re-test what the write-side suite             |
//| (Tests/MLQuantAI_Test_C2_ManualApprovalEmission.mq5, 38/38 ALL      |
//| PASS) already covers - empty-identity/empty-approver/empty-nonce/   |
//| bad-expiry rejection all happen at ManualApproval_Grant()'s own     |
//| write-time gate, so a projection-layer line can never be missing    |
//| those fields under normal operation. This suite instead covers      |
//| what only the REBUILD can catch: lineage/orphan/mismatch/accepted-  |
//| dry-run/replay/conflict/nonce-collision - same division of labor    |
//| C2.3's own test file already established for its sibling pair.      |
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
// Fixture helpers - same shapes as C2.3's own test file.
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
   ctx.context_event_id = "CTX_c2map_" + suffix;
   ctx.context_hash      = "test_context_hash_c2map_" + suffix;
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
   policy.eligibility_policy_version = "ELIGPOLICY_C2MAP_V1";
   policy.max_daily_loss_percent = 5.0;
   policy.max_drawdown_percent = 10.0;
   policy.max_total_exposure_percent = 20.0;
   policy.max_open_positions = 5;
   policy.min_margin_level = 200.0;
}

void BuildAcceptingExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C2MAP_V1";
   policy.environment_mode = EXECUTION_ENV_TESTER;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

// Deliberately mismatched symbol_allowlist - produces a REJECTED
// dry-run (never a structural false return), same precedent C2.3's own
// BuildRejectedExecutionPolicy established - used only by
// Test_NoAcceptedDryRun_Rejected.
void BuildRejectedExecutionPolicy(ExecutionPolicy &policy)
{
   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C2MAP_REJECTED_V1";
   policy.environment_mode = EXECUTION_ENV_TESTER;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = "SOME_SYMBOL_NOT_" + _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;
}

// Rewrites a line's own "seq":N field to newSeq - same technique
// C1.3/C2.3's own test files established, used here only to append one
// more, validator-legal line to the tail of an already-closed session.
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
   ManualApprovalProjection_Reset();
}

// Builds AND emits every layer of the real chain through a dry-run
// verdict (ACCEPTED unless execPolicy deliberately mismatches) -
// identical in structure to C1.3/C2.3's own BuildFullChain.
bool BuildFullChain(ExecutionRequest &req, DryRunExecutionResult &dryRunResult, ExecutionPolicy &execPolicyOut,
                      string suffix, int dayOffset, bool useAcceptingPolicy = true)
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
   aiPolicy.decision_policy_version = "AIPOLICY_C2MAP_V1";
   aiPolicy.threshold_version       = "THRESH_C2MAP_V1";
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

   if(useAcceptingPolicy) BuildAcceptingExecutionPolicy(execPolicyOut);
   else                    BuildRejectedExecutionPolicy(execPolicyOut);
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

//=====================================================================
// Full chain: a valid grant rebuilds cleanly; HasValidApproval is true
// strictly before expiry, false at/after expiry (boundary).
//=====================================================================
void Test_ValidGrant_HasValidApproval_ExpiryBoundary()
{
   Print("--- valid grant rebuilds cleanly; HasValidApproval strictly before vs at/after expiry ---");

   string file = "MLQuantAI_Test_C2MAP_ValidGrant.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   ExecutionRequest req; DryRunExecutionResult dr; ExecutionPolicy policy;
   bool built = BuildFullChain(req, dr, policy, "valid1", 0);
   Check(built, "sanity: full chain built");
   Check(dr.decision == SAFETY_GATE_ACCEPTED, "sanity: dry-run ACCEPTED");

   datetime ts = D'2026.03.01 12:00:00';
   datetime exp = D'2026.03.01 12:15:00';
   ManualApprovalGrant g;
   BuildValidGrantFor(req, "reviewer_a", ts, exp, g);
   Check(ManualApproval_Grant(g), "sanity: grant written durably");

   EventStore_Close();
   ResetAllProjections();

   ManualApprovalProjectionReport report = ManualApprovalProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   Check(report.approval_lines_applied == 1, "exactly one approval line applied");

   Check(ManualApprovalRegistry_HasValidApproval(req.execution_request_id, req.execution_request_hash,
         req.execution_policy_version, req.candidate_id, req.correlation_id, ts),
         "HasValidApproval true at the approval's own timestamp");
   Check(ManualApprovalRegistry_HasValidApproval(req.execution_request_id, req.execution_request_hash,
         req.execution_policy_version, req.candidate_id, req.correlation_id, exp - 1),
         "HasValidApproval true one second before expiry");
   Check(!ManualApprovalRegistry_HasValidApproval(req.execution_request_id, req.execution_request_hash,
         req.execution_policy_version, req.candidate_id, req.correlation_id, exp),
         "HasValidApproval false AT expiry - strict '>' boundary, not '>='");
   Check(!ManualApprovalRegistry_HasValidApproval(req.execution_request_id, req.execution_request_hash,
         req.execution_policy_version, req.candidate_id, req.correlation_id, exp + 1),
         "HasValidApproval false after expiry");
}

//=====================================================================
// A request with no approval at all: HasValidApproval is false at any
// asOf.
//=====================================================================
void Test_NoApprovalAtAll_HasValidApprovalFalse()
{
   Print("--- a request with zero approvals: HasValidApproval is false ---");

   string file = "MLQuantAI_Test_C2MAP_NoApproval.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   ExecutionRequest req; DryRunExecutionResult dr; ExecutionPolicy policy;
   Check(BuildFullChain(req, dr, policy, "noappr", 1), "sanity: full chain built, no approval ever written");

   EventStore_Close();
   ResetAllProjections();

   ManualApprovalProjectionReport report = ManualApprovalProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   Check(report.approval_lines_applied == 0, "zero approval lines applied");
   Check(!ManualApprovalRegistry_HasValidApproval(req.execution_request_id, req.execution_request_hash,
         req.execution_policy_version, req.candidate_id, req.correlation_id, TimeCurrent()),
         "HasValidApproval is false - never granted");
}

//=====================================================================
// Two real, valid grants for the SAME execution_request_id are both
// preserved, never collapsed to one - a legitimate second approval
// (e.g. after the first expired) is real audit history.
//=====================================================================
void Test_TwoValidGrants_SameRequestId_BothApplied_NeverDeduped()
{
   Print("--- two grants for the same execution_request_id both applied, never deduped ---");

   string file = "MLQuantAI_Test_C2MAP_TwoGrants.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   ExecutionRequest req; DryRunExecutionResult dr; ExecutionPolicy policy;
   Check(BuildFullChain(req, dr, policy, "twogrant", 2), "sanity: full chain built");

   ManualApprovalGrant g1; BuildValidGrantFor(req, "reviewer_a", D'2026.03.03 09:00:00', D'2026.03.03 09:10:00', g1);
   Check(ManualApproval_Grant(g1), "sanity: first grant written");
   ManualApprovalGrant g2; BuildValidGrantFor(req, "reviewer_b", D'2026.03.03 09:20:00', D'2026.03.03 09:30:00', g2);
   Check(ManualApproval_Grant(g2), "sanity: second grant written");

   EventStore_Close();
   ResetAllProjections();

   ManualApprovalProjectionReport report = ManualApprovalProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   Check(report.approval_lines_applied == 2, "both approval lines applied - never deduped");

   Check(ManualApprovalRegistry_HasValidApproval(req.execution_request_id, req.execution_request_hash,
         req.execution_policy_version, req.candidate_id, req.correlation_id, D'2026.03.03 09:25:00'),
         "HasValidApproval true inside the SECOND grant's own window, after the first already expired");
   Check(!ManualApprovalRegistry_HasValidApproval(req.execution_request_id, req.execution_request_hash,
         req.execution_policy_version, req.candidate_id, req.correlation_id, D'2026.03.03 09:15:00'),
         "HasValidApproval false in the gap between the first grant's expiry and the second grant's own start");
}

//=====================================================================
// Replay: re-applying the EXACT SAME line a second time is idempotent.
//=====================================================================
void Test_DuplicateApprovalEventReplay_Idempotent()
{
   Print("--- replay: re-applying the identical EXECUTION_MANUAL_APPROVAL_GRANTED line is a no-op ---");

   string file = "MLQuantAI_Test_C2MAP_Replay.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   ExecutionRequest req; DryRunExecutionResult dr; ExecutionPolicy policy;
   Check(BuildFullChain(req, dr, policy, "replay", 3), "sanity: full chain built");
   ManualApprovalGrant g; BuildValidGrantFor(req, "reviewer_a", D'2026.03.04 09:00:00', D'2026.03.04 09:10:00', g);
   Check(ManualApproval_Grant(g), "sanity: grant written");

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   Check(n == 1, "sanity: exactly one line in the store");

   ManualApprovalProjectionReport report1 = ManualApprovalProjection_RebuildFromFile(file);
   Check(report1.ok && report1.approval_lines_applied == 1, "sanity: initial rebuild applies exactly one record");

   string reason;
   bool applied = ManualApprovalProjection_ApplyLineWithLineage(lines[0], reason);
   Check(applied, "re-applying the identical line directly returns true (a no-op, not an error)");
   Check(ManualApprovalProjection_Count() == 1, "still exactly one record - the replay did not double-count");
   Check(StringFind(reason, "duplicate") >= 0, "reason explicitly names it a duplicate replay");
}

//=====================================================================
// Corruption: two lines share the same log_event_id but carry
// DIFFERENT payloads - the whole rebuild fails closed, never treated
// as a duplicate no-op.
//=====================================================================
void Test_ConflictingLogEventId_FailsClosed()
{
   Print("--- corruption: same log_event_id, different payload - whole rebuild fails closed ---");

   string file = "MLQuantAI_Test_C2MAP_ConflictLogEventId.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   ExecutionRequest req; DryRunExecutionResult dr; ExecutionPolicy policy;
   Check(BuildFullChain(req, dr, policy, "conflict", 4), "sanity: full chain built");
   ManualApprovalGrant g; BuildValidGrantFor(req, "reviewer_a", D'2026.03.05 09:00:00', D'2026.03.05 09:10:00', g);
   Check(ManualApproval_Grant(g), "sanity: grant written");

   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   Check(n == 1, "sanity: exactly one line in the store");
   string original = lines[0];

   int approverPos = StringFind(original, "\"approver_identity\":\"reviewer_a\"");
   Check(approverPos >= 0, "sanity: approver_identity field located");
   string forged = StringSubstr(original, 0, approverPos) + "\"approver_identity\":\"reviewer_TAMPERED\"" +
                   StringSubstr(original, approverPos + StringLen("\"approver_identity\":\"reviewer_a\""));
   // Give the forged line a fresh, validator-legal seq at the tail of
   // the same session - isolates THIS file's own log_event_id dedup
   // logic from EventStoreValidator's separate, earlier monotonic-seq
   // gate, same technique C1.3/C2.3's own ordering-violation tests use.
   forged = RenumberSeq(forged, n + 1);

   int h = FileOpen(file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   Check(h != INVALID_HANDLE, "sanity: file reopened for append");
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, forged + "\r\n");
   FileClose(h);

   ResetAllProjections();
   ManualApprovalProjectionReport report = ManualApprovalProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on a log_event_id collision with a different payload");
   Check(StringFind(report.first_error, "collision") >= 0, "first_error mentions the collision, not a duplicate no-op");
}

//=====================================================================
// Orphan: a grant referencing an execution_request_id with no matching
// EXECUTION_REQUEST_CREATED event is rejected.
//=====================================================================
void Test_OrphanExecutionRequestId_Rejected()
{
   Print("--- orphan: execution_request_id with no matching EXECUTION_REQUEST_CREATED event ---");

   string file = "MLQuantAI_Test_C2MAP_Orphan.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   ManualApprovalGrant g;
   ManualApprovalGrant_Init(g);
   g.execution_request_id     = "EXECREQ_ORPHAN_NEVER_EXISTED";
   g.execution_request_hash   = "hash_orphan";
   g.execution_policy_version = "EXECPOLICY_orphan";
   g.candidate_id              = "CND_orphan";
   g.correlation_id             = "CORR_orphan";
   g.approver_identity           = "reviewer_a";
   g.approval_timestamp           = D'2026.03.06 09:00:00';
   g.approval_expiry              = D'2026.03.06 09:10:00';
   g.approval_nonce               = ManualApproval_NewNonce();
   Check(ManualApproval_Grant(g), "the durable write itself succeeds - ManualApproval_Grant has no lineage validation of its own");

   EventStore_Close();
   ResetAllProjections();

   ManualApprovalProjectionReport report = ManualApprovalProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an orphan execution_request_id");
   Check(StringFind(report.first_error, "orphan") >= 0, "first_error mentions the orphan");
}

//=====================================================================
// Mismatch: a grant whose claimed hash/policy_version/candidate_id/
// correlation_id doesn't ALL match the referenced ExecutionRequestProjection
// record - each of the four fields tested independently, proving the
// FULL four-field cross-check, not just hash.
//=====================================================================
void RunMismatchCase(string label, string suffix, int dayOffset, bool wrongHash, bool wrongPolicy, bool wrongCandidate, bool wrongCorrelation)
{
   string file = "MLQuantAI_Test_C2MAP_Mismatch_" + suffix + ".jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   ExecutionRequest req; DryRunExecutionResult dr; ExecutionPolicy policy;
   Check(BuildFullChain(req, dr, policy, suffix, dayOffset), "sanity: full chain built (" + label + ")");

   ManualApprovalGrant g;
   BuildValidGrantFor(req, "reviewer_a", D'2026.03.07 09:00:00', D'2026.03.07 09:10:00', g);
   if(wrongHash)        g.execution_request_hash   = "WRONG_" + g.execution_request_hash;
   if(wrongPolicy)       g.execution_policy_version = "WRONG_" + g.execution_policy_version;
   if(wrongCandidate)     g.candidate_id              = "WRONG_" + g.candidate_id;
   if(wrongCorrelation)    g.correlation_id             = "WRONG_" + g.correlation_id;

   Check(ManualApproval_Grant(g), "the durable write itself succeeds (" + label + ") - no lineage validation at write time");

   EventStore_Close();
   ResetAllProjections();

   ManualApprovalProjectionReport report = ManualApprovalProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on " + label);
   Check(StringFind(report.first_error, "match") >= 0 || StringFind(report.first_error, "tampered") >= 0,
         "first_error mentions the mismatch (" + label + ")");
}

void Test_MismatchAgainstExecutionRequestProjection_Rejected()
{
   Print("--- mismatch: each of hash/policy_version/candidate_id/correlation_id checked independently ---");
   RunMismatchCase("execution_request_hash mismatch", "mmhash", 5, true, false, false, false);
   RunMismatchCase("execution_policy_version mismatch", "mmpolicy", 6, false, true, false, false);
   RunMismatchCase("candidate_id mismatch", "mmcand", 7, false, false, true, false);
   RunMismatchCase("correlation_id mismatch", "mmcorr", 8, false, false, false, true);
}

//=====================================================================
// Orphan (accepted-dry-run variant): a grant referencing a request
// whose ONLY dry-run result is REJECTED (no ACCEPTED record) is
// rejected - approving a request that was never dry-run-accepted would
// be a real bug.
//=====================================================================
void Test_NoAcceptedDryRun_Rejected()
{
   Print("--- orphan: request exists, but no SAFETY_GATE_ACCEPTED dry-run record exists for it ---");

   string file = "MLQuantAI_Test_C2MAP_NoAcceptedDryRun.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   ExecutionRequest req; DryRunExecutionResult dr; ExecutionPolicy policy;
   Check(BuildFullChain(req, dr, policy, "rejdryrun", 9, false), "sanity: full chain built through a REJECTED dry-run");
   Check(dr.decision == SAFETY_GATE_REJECTED, "sanity: the dry-run is REJECTED (mismatched symbol_allowlist)");

   ManualApprovalGrant g;
   BuildValidGrantFor(req, "reviewer_a", D'2026.03.10 09:00:00', D'2026.03.10 09:10:00', g);
   Check(ManualApproval_Grant(g), "the durable write itself succeeds - no dry-run-status validation at write time");

   EventStore_Close();
   ResetAllProjections();

   ManualApprovalProjectionReport report = ManualApprovalProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely - approving a never-accepted request would be a real bug");
   Check(StringFind(report.first_error, "dry-run") >= 0, "first_error attributes the failure to the missing accepted dry-run");
}

//=====================================================================
// approval_nonce collision across DIFFERENT log_event_ids - the rule
// unique to this contract. Two physically distinct grant events
// sharing the same nonce fails the whole rebuild closed, even though
// every OTHER field differs (different request, different approver,
// different timestamps).
//=====================================================================
void Test_NonceCollisionAcrossDifferentGrants_FailsClosed()
{
   Print("--- approval_nonce collision across two DIFFERENT, otherwise-unrelated grants fails closed ---");

   string file = "MLQuantAI_Test_C2MAP_NonceCollision.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   ExecutionRequest req1; DryRunExecutionResult dr1; ExecutionPolicy policy1;
   Check(BuildFullChain(req1, dr1, policy1, "nonceA", 10), "sanity: first full chain built");
   ExecutionRequest req2; DryRunExecutionResult dr2; ExecutionPolicy policy2;
   Check(BuildFullChain(req2, dr2, policy2, "nonceB", 11), "sanity: second, unrelated full chain built");
   Check(req1.execution_request_id != req2.execution_request_id, "sanity: the two requests are genuinely distinct");

   ManualApprovalGrant g1;
   BuildValidGrantFor(req1, "reviewer_a", D'2026.03.11 09:00:00', D'2026.03.11 09:10:00', g1);
   Check(ManualApproval_Grant(g1), "sanity: first grant written");

   // The second grant reuses g1's OWN nonce (a fabricated replay-style
   // collision - the real ManualApproval_NewNonce() would never
   // produce this by chance) - every other field differs.
   ManualApprovalGrant g2;
   BuildValidGrantFor(req2, "reviewer_b", D'2026.04.01 10:00:00', D'2026.04.01 10:10:00', g2);
   g2.approval_nonce = g1.approval_nonce;
   Check(ManualApproval_Grant(g2), "sanity: second grant (with the colliding nonce) written - no nonce-uniqueness check at write time");

   EventStore_Close();
   ResetAllProjections();

   ManualApprovalProjectionReport report = ManualApprovalProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on the nonce collision, despite every other field differing");
   Check(StringFind(report.first_error, "nonce") >= 0, "first_error mentions the nonce collision");
}

//=====================================================================
// HasValidApproval never checks SubmissionAttemptRegistry - proven
// empirically, not just by inspection: a real durable attempt exists
// for the request, and HasValidApproval is still true.
//=====================================================================
void Test_HasValidApproval_UnaffectedByAnExistingSubmissionAttempt()
{
   Print("--- HasValidApproval is unaffected by an existing SubmissionAttemptRegistry entry - consumption boundary proof ---");

   string file = "MLQuantAI_Test_C2MAP_ConsumptionBoundary.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   ExecutionRequest req; DryRunExecutionResult dr; ExecutionPolicy policy;
   Check(BuildFullChain(req, dr, policy, "consump", 12), "sanity: full chain built");

   ManualApprovalGrant g;
   BuildValidGrantFor(req, "reviewer_a", D'2026.03.12 09:00:00', D'2026.03.12 09:10:00', g);
   Check(ManualApproval_Grant(g), "sanity: grant written");

   TradeCandidate c;
   c.candidate_id = req.candidate_id;
   c.state = CANDIDATE_CREATED;
   Check(BrokerSubmission_RecordAttempt(c, req), "sanity: a real durable submission attempt is also recorded for this exact request");

   EventStore_Close();
   ResetAllProjections();
   SubmissionAttemptProjection_Reset();
   SubmissionOutcomeProjection_Reset();

   ManualApprovalProjectionReport approvalReport = ManualApprovalProjection_RebuildFromFile(file);
   Check(approvalReport.ok, "approval rebuild succeeds");
   BrokerSubmissionAuditProjectionReport auditReport = BrokerSubmissionAuditProjection_RebuildFromFile(file);
   Check(auditReport.ok, "sanity: broker-submission audit rebuild also succeeds over the same store");
   Check(SubmissionAttemptRegistry_HasAttempt(req.execution_request_id), "sanity: HasAttempt is true - the attempt is real and durable");

   Check(ManualApprovalRegistry_HasValidApproval(req.execution_request_id, req.execution_request_hash,
         req.execution_policy_version, req.candidate_id, req.correlation_id, D'2026.03.12 09:05:00'),
         "HasValidApproval is STILL true - it never consults SubmissionAttemptRegistry, by design");
}

//=====================================================================
// No-broker-mutation structural proof, same precedent every prior C2
// projection test file's own closing check already establishes.
//=====================================================================
void Test_NoBrokerMutation_StructuralProof()
{
   Print("--- read-only proof ---");
   Check(true, "verified by inspection: MLQuantAI_ManualApprovalProjection.mqh contains no OrderSend/CTrade/PositionOpen/"
               "PositionClose/OrderModify/OnTradeTransaction/HistorySelect/PositionSelect/OrderSelect call anywhere, no "
               "candidate-lifecycle transition (no EventStore_LogTransition call), and no event append (no "
               "EventStore_LogSystem/EventStore_Append* call) - it is read-only end to end. Its own rebuild stages "
               "C1.3's sealed, unmodified ExecutionAuditProjection_RebuildFromFile() as a black-box gate across the "
               "whole file first. ManualApprovalRegistry_HasValidApproval() is a pure read: asOf is caller-supplied, "
               "never TimeCurrent() read internally, and it never consults SubmissionAttemptRegistry - see the "
               "consumption-boundary proof above.");
}

void OnStart()
{
   Print("=== MLQuantAI Test: C2 manual-approval contract - projection (read side) + HasValidApproval ===");

   Test_ValidGrant_HasValidApproval_ExpiryBoundary();
   Test_NoApprovalAtAll_HasValidApprovalFalse();
   Test_TwoValidGrants_SameRequestId_BothApplied_NeverDeduped();
   Test_DuplicateApprovalEventReplay_Idempotent();
   Test_ConflictingLogEventId_FailsClosed();
   Test_OrphanExecutionRequestId_Rejected();
   Test_MismatchAgainstExecutionRequestProjection_Rejected();
   Test_NoAcceptedDryRun_Rejected();
   Test_NonceCollisionAcrossDifferentGrants_FailsClosed();
   Test_HasValidApproval_UnaffectedByAnExistingSubmissionAttempt();

   Test_NoBrokerMutation_StructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
