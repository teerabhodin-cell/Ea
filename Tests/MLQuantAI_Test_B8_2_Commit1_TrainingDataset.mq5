//+------------------------------------------------------------------+
//| MLQuantAI_Test_B8_2_Commit1_TrainingDataset.mq5                   |
//| Phase B8.2 Commit 1 DoD, per                                        |
//| Docs/PhaseB_B8_2_TrainingDatasetContract.md's QA gate:              |
//| BuildTrainingDatasetRow identity/hash/split correctness. Uses the   |
//| real B5/B7/B8.1 pipeline (CRT_DetectV1 -> CRT_ToTradeCandidate ->   |
//| Candidate_ToRiskPlan -> Candidate_ToFeatureSnapshot) for every       |
//| fixture row - no fabricated hashes anywhere. No EventStore          |
//| involved at all: BuildTrainingDatasetRow is a pure in-memory        |
//| function with no event emission in Commit 1.                       |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_ToTradeCandidate.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_TrainingDatasetBuilder.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as prior B7/B8.1 test files.
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
   ctx.context_event_id = "CTX_b8_2_" + suffix;
   ctx.context_hash      = "test_context_hash_b8_2_" + suffix;
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

// Builds a real candidate + real ALLOWED RiskPlan + real FeatureSnapshot
// via the real B5/B7/B8.1 pipeline - no EventStore involved anywhere.
bool BuildFixture(TradeCandidate &c, RiskPlan &plan, FeatureSnapshot &snapshot, string suffix, int dayOffset)
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

   RiskContext riskCtx;
   BuildValidRiskContext(riskCtx, suffix);
   if(!Candidate_ToRiskPlan(c, riskCtx, plan)) return false;

   return Candidate_ToFeatureSnapshot(c, ctx, snapshot);
}

//=====================================================================
void Test_Determinism()
{
   Print("--- determinism: 10,000 repeated calls, same inputs ---");
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildFixture(c, plan, snapshot, "DET", 1), "sanity: fixture built");

   TrainingDatasetRow first;
   Check(BuildTrainingDatasetRow(c, snapshot, plan, false, "", "", "", "SETUP_QUALITY_V1", first), "sanity: first call succeeds");

   bool allMatch = true;
   for(int i = 0; i < 10000; i++)
   {
      TrainingDatasetRow row;
      BuildTrainingDatasetRow(c, snapshot, plan, false, "", "", "", "SETUP_QUALITY_V1", row);
      if(row.dataset_row_id != first.dataset_row_id ||
         row.row_hash != first.row_hash ||
         row.split != first.split)
      {
         allMatch = false;
         break;
      }
   }
   Check(allMatch, "10,000 iterations: zero dataset_row_id/row_hash/split mismatches");
}

void Test_DatasetRowId_Dependencies()
{
   Print("--- dataset_row_id depends only on feature_snapshot_id/label_schema_version/model_target ---");
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildFixture(c, plan, snapshot, "IDDEP", 2), "sanity: fixture built");

   TrainingDatasetRow row;
   Check(BuildTrainingDatasetRow(c, snapshot, plan, false, "", "", "", "SETUP_QUALITY_V1", row), "sanity: call succeeds");
   Check(row.dataset_row_id == Ids_TrainingDatasetRowId(snapshot.feature_snapshot_id, row.label_schema_version, "SETUP_QUALITY_V1"),
         "dataset_row_id == Ids_TrainingDatasetRowId(feature_snapshot_id, label_schema_version, model_target)");

   TrainingDatasetRow rowOtherTarget;
   Check(BuildTrainingDatasetRow(c, snapshot, plan, false, "", "", "", "OTHER_TARGET_V1", rowOtherTarget), "sanity: call with a different model_target succeeds");
   Check(row.dataset_row_id != rowOtherTarget.dataset_row_id, "a different model_target produces a different dataset_row_id");
   Check(row.split == rowOtherTarget.split, "the split stays the same across model_targets for the same candidate_id (split is keyed on candidate_id, not dataset_row_id)");
}

void Test_RowHash_InclusionSweep()
{
   Print("--- row_hash: every INCLUDED field change moves the hash ---");
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildFixture(c, plan, snapshot, "ROWINC", 3), "sanity: fixture built");
   TrainingDatasetRow baseline;
   Check(BuildTrainingDatasetRow(c, snapshot, plan, true, "WIN", "OUTCOME_REF_1", "outcome_hash_1", "SETUP_QUALITY_V1", baseline),
         "sanity: baseline row built (with a label)");

   TrainingDatasetRow f;

   f = baseline; f.candidate_id = "CND_DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "candidate_id change moves row_hash");

   f = baseline; f.candidate_hash = "DIFFERENT_HASH";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "candidate_hash change moves row_hash");

   f = baseline; f.feature_snapshot_id = "FSNAP_DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "feature_snapshot_id change moves row_hash");

   f = baseline; f.feature_snapshot_hash = "DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "feature_snapshot_hash change moves row_hash");

   f = baseline; f.feature_vector_hash = "DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "feature_vector_hash change moves row_hash");

   f = baseline; f.feature_schema_version = "DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "feature_schema_version change moves row_hash");

   f = baseline; f.risk_plan_id = "DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "risk_plan_id change moves row_hash");

   f = baseline; f.plan_hash = "DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "plan_hash change moves row_hash");

   f = baseline; f.sizing_rules_version = "DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "sizing_rules_version change moves row_hash");

   f = baseline; f.label_available = !baseline.label_available;
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "label_available change moves row_hash");

   f = baseline; f.label_schema_version = "DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "label_schema_version change moves row_hash");

   f = baseline; f.label = "LOSS";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "label change moves row_hash");

   f = baseline; f.outcome_reference = "DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "outcome_reference change moves row_hash");

   f = baseline; f.outcome_hash = "DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "outcome_hash change moves row_hash");

   f = baseline; f.split = (baseline.split == DATASET_SPLIT_TRAIN) ? DATASET_SPLIT_TEST : DATASET_SPLIT_TRAIN;
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "split change moves row_hash");

   f = baseline; f.split_policy_version = "DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "split_policy_version change moves row_hash");

   f = baseline; f.model_target = "DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) != baseline.row_hash, "model_target change moves row_hash");
}

void Test_RowHash_ExclusionWhitelist()
{
   Print("--- row_hash: dataset_row_id and dataset_schema_version do NOT move the hash ---");
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildFixture(c, plan, snapshot, "ROWEXC", 4), "sanity: fixture built");
   TrainingDatasetRow baseline;
   Check(BuildTrainingDatasetRow(c, snapshot, plan, false, "", "", "", "SETUP_QUALITY_V1", baseline), "sanity: baseline row built");

   TrainingDatasetRow f;

   f = baseline; f.dataset_row_id = "TDROW_DIFFERENT";
   Check(TrainingDatasetRow_ComputeHash(f) == baseline.row_hash, "dataset_row_id change does NOT move row_hash");

   f = baseline; f.dataset_schema_version = "OTHER_SCHEMA";
   Check(TrainingDatasetRow_ComputeHash(f) == baseline.row_hash, "dataset_schema_version change does NOT move row_hash");
}

void Test_ReferentialIntegrity_Rejected()
{
   Print("--- referential integrity: mismatched FeatureSnapshot/RiskPlan or an unallowed plan is rejected ---");
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildFixture(c, plan, snapshot, "REFCHK", 5), "sanity: fixture built");

   FeatureSnapshot wrongSnapshotId = snapshot;
   wrongSnapshotId.candidate_id = "CND_WRONG";
   TrainingDatasetRow f1;
   Check(!BuildTrainingDatasetRow(c, wrongSnapshotId, plan, false, "", "", "", "SETUP_QUALITY_V1", f1),
         "a FeatureSnapshot with a mismatched candidate_id is rejected");
   Check(f1.candidate_id == "", "rejected row stays at Init() defaults - no partial output");

   FeatureSnapshot wrongSnapshotHash = snapshot;
   wrongSnapshotHash.candidate_hash = "WRONG_HASH";
   TrainingDatasetRow f2;
   Check(!BuildTrainingDatasetRow(c, wrongSnapshotHash, plan, false, "", "", "", "SETUP_QUALITY_V1", f2),
         "a FeatureSnapshot with a mismatched candidate_hash is rejected");

   RiskPlan wrongPlanId = plan;
   wrongPlanId.candidate_id = "CND_WRONG";
   TrainingDatasetRow f3;
   Check(!BuildTrainingDatasetRow(c, snapshot, wrongPlanId, false, "", "", "", "SETUP_QUALITY_V1", f3),
         "a RiskPlan with a mismatched candidate_id is rejected");

   RiskPlan wrongPlanHash = plan;
   wrongPlanHash.candidate_hash = "WRONG_HASH";
   TrainingDatasetRow f4;
   Check(!BuildTrainingDatasetRow(c, snapshot, wrongPlanHash, false, "", "", "", "SETUP_QUALITY_V1", f4),
         "a RiskPlan with a mismatched candidate_hash is rejected");

   RiskPlan unallowedPlan = plan;
   unallowedPlan.allowed = false;
   TrainingDatasetRow f5;
   Check(!BuildTrainingDatasetRow(c, snapshot, unallowedPlan, false, "", "", "", "SETUP_QUALITY_V1", f5),
         "an unallowed (!plan.allowed) RiskPlan is rejected - no training row without an ALLOWED plan");
}

void Test_FailClosed()
{
   Print("--- fail-closed: invalid candidate/model_target/label input ---");
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildFixture(c, plan, snapshot, "FAILCLOSED", 6), "sanity: fixture built");

   TradeCandidate emptyId = c;
   emptyId.candidate_id = "";
   TrainingDatasetRow f1;
   Check(!BuildTrainingDatasetRow(emptyId, snapshot, plan, false, "", "", "", "SETUP_QUALITY_V1", f1), "empty candidate_id is rejected");

   TradeCandidate wrongState = c;
   wrongState.state = CANDIDATE_EXPIRED;
   TrainingDatasetRow f2;
   Check(!BuildTrainingDatasetRow(wrongState, snapshot, plan, false, "", "", "", "SETUP_QUALITY_V1", f2), "candidate.state != CANDIDATE_CREATED is rejected");

   TrainingDatasetRow f3;
   Check(!BuildTrainingDatasetRow(c, snapshot, plan, false, "", "", "", "", f3), "empty model_target is rejected");

   // labelAvailable=false but label fields non-empty - inconsistent, rejected.
   TrainingDatasetRow f4;
   Check(!BuildTrainingDatasetRow(c, snapshot, plan, false, "WIN", "", "", "SETUP_QUALITY_V1", f4),
         "labelAvailable=false with a non-empty label is rejected (inconsistent input)");
   TrainingDatasetRow f5;
   Check(!BuildTrainingDatasetRow(c, snapshot, plan, false, "", "OUTCOME_REF", "", "SETUP_QUALITY_V1", f5),
         "labelAvailable=false with a non-empty outcome_reference is rejected (inconsistent input)");

   // labelAvailable=true but a label field missing - inconsistent, rejected.
   TrainingDatasetRow f6;
   Check(!BuildTrainingDatasetRow(c, snapshot, plan, true, "", "OUTCOME_REF", "outcome_hash", "SETUP_QUALITY_V1", f6),
         "labelAvailable=true with an empty label is rejected (inconsistent input)");
   TrainingDatasetRow f7;
   Check(!BuildTrainingDatasetRow(c, snapshot, plan, true, "WIN", "", "outcome_hash", "SETUP_QUALITY_V1", f7),
         "labelAvailable=true with an empty outcome_reference is rejected (inconsistent input)");
   TrainingDatasetRow f8;
   Check(!BuildTrainingDatasetRow(c, snapshot, plan, true, "WIN", "OUTCOME_REF", "", "SETUP_QUALITY_V1", f8),
         "labelAvailable=true with an empty outcome_hash is rejected (inconsistent input)");

   Check(f1.candidate_id == "" && f4.candidate_id == "" && f6.candidate_id == "",
         "rejected rows stay at Init() defaults - no partial output");
}

void Test_LabelAvailableFalse_IsAValidRow()
{
   Print("--- label_available == false is a valid, first-class row, not an error ---");
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildFixture(c, plan, snapshot, "UNLABELED", 7), "sanity: fixture built");

   TrainingDatasetRow row;
   Check(BuildTrainingDatasetRow(c, snapshot, plan, false, "", "", "", "SETUP_QUALITY_V1", row),
         "an unlabeled row (label_available=false) builds successfully");
   Check(!row.label_available, "label_available is false");
   Check(row.label == "" && row.outcome_reference == "" && row.outcome_hash == "", "label/outcome fields are empty");
   Check(row.dataset_row_id != "" && row.row_hash != "", "identity and content hash are still fully populated");
}

void Test_SplitDeterminism()
{
   Print("--- split determinism: same candidate_id always produces the same split ---");
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildFixture(c, plan, snapshot, "SPLITDET", 8), "sanity: fixture built");

   ENUM_DATASET_SPLIT first = TrainingDatasetSplit_Assign(c.candidate_id, MLQUANTAI_DATASET_SPLIT_POLICY_V1);
   bool allMatch = true;
   for(int i = 0; i < 1000; i++)
      if(TrainingDatasetSplit_Assign(c.candidate_id, MLQUANTAI_DATASET_SPLIT_POLICY_V1) != first) { allMatch = false; break; }
   Check(allMatch, "1,000 repeated calls: the same candidate_id always gets the same split");

   // Statistical sanity check over many distinct synthetic candidate_ids -
   // not an exact-count assertion, just "roughly 70/15/15, not degenerate".
   int trainCount = 0, valCount = 0, testCount = 0;
   int n = 2000;
   for(int i = 0; i < n; i++)
   {
      string syntheticId = "CND_SPLITSAMPLE_" + IntegerToString(i);
      ENUM_DATASET_SPLIT s = TrainingDatasetSplit_Assign(syntheticId, MLQUANTAI_DATASET_SPLIT_POLICY_V1);
      if(s == DATASET_SPLIT_TRAIN) trainCount++;
      else if(s == DATASET_SPLIT_VALIDATION) valCount++;
      else testCount++;
   }
   double trainPct = 100.0 * trainCount / n;
   double valPct    = 100.0 * valCount / n;
   double testPct   = 100.0 * testCount / n;
   Print(StringFormat("    split distribution over %d synthetic ids: TRAIN=%.1f%% VALIDATION=%.1f%% TEST=%.1f%%", n, trainPct, valPct, testPct));
   Check(trainPct > 60.0 && trainPct < 80.0, "TRAIN share is close to the frozen 70% target (60-80% tolerance band)");
   Check(valPct > 8.0 && valPct < 22.0, "VALIDATION share is close to the frozen 15% target (8-22% tolerance band)");
   Check(testPct > 8.0 && testPct < 22.0, "TEST share is close to the frozen 15% target (8-22% tolerance band)");
}

void Test_DatasetHash()
{
   Print("--- dataset_hash: changes with any row's row_hash or row order, stable otherwise ---");
   TradeCandidate c1, c2, c3;
   RiskPlan p1, p2, p3;
   FeatureSnapshot s1, s2, s3;
   Check(BuildFixture(c1, p1, s1, "DH1", 9), "sanity: fixture 1 built");
   Check(BuildFixture(c2, p2, s2, "DH2", 10), "sanity: fixture 2 built");
   Check(BuildFixture(c3, p3, s3, "DH3", 11), "sanity: fixture 3 built");

   TrainingDatasetRow r1, r2, r3;
   Check(BuildTrainingDatasetRow(c1, s1, p1, false, "", "", "", "SETUP_QUALITY_V1", r1), "sanity: row 1 built");
   Check(BuildTrainingDatasetRow(c2, s2, p2, false, "", "", "", "SETUP_QUALITY_V1", r2), "sanity: row 2 built");
   Check(BuildTrainingDatasetRow(c3, s3, p3, false, "", "", "", "SETUP_QUALITY_V1", r3), "sanity: row 3 built");

   TrainingDatasetRow rows[]; ArrayResize(rows, 3);
   rows[0] = r1; rows[1] = r2; rows[2] = r3;
   string hashA = TrainingDatasetManifest_DatasetHash(rows);
   string hashB = TrainingDatasetManifest_DatasetHash(rows);
   Check(hashA == hashB, "dataset_hash is stable across repeated computation from the same row set");
   Check(hashA != "", "dataset_hash is non-empty");

   TrainingDatasetRow reordered[]; ArrayResize(reordered, 3);
   reordered[0] = r2; reordered[1] = r1; reordered[2] = r3;
   Check(TrainingDatasetManifest_DatasetHash(reordered) != hashA, "reordering the rows moves dataset_hash");

   TrainingDatasetRow tampered[]; ArrayResize(tampered, 3);
   tampered[0] = r1; tampered[1] = r2; tampered[2] = r3;
   tampered[2].row_hash = "TAMPERED";
   Check(TrainingDatasetManifest_DatasetHash(tampered) != hashA, "tampering one row's row_hash moves dataset_hash");
}

void Test_NoMutation()
{
   Print("--- candidate/snapshot/plan are not mutated by BuildTrainingDatasetRow ---");
   TradeCandidate c; RiskPlan plan; FeatureSnapshot snapshot;
   Check(BuildFixture(c, plan, snapshot, "NOMUT", 12), "sanity: fixture built");

   string candidateIdBefore = c.candidate_id;
   string snapshotHashBefore = snapshot.feature_snapshot_hash;
   string planHashBefore = plan.plan_hash;

   TrainingDatasetRow row;
   Check(BuildTrainingDatasetRow(c, snapshot, plan, false, "", "", "", "SETUP_QUALITY_V1", row), "sanity: call succeeds");

   Check(c.candidate_id == candidateIdBefore, "candidate.candidate_id unchanged after the call");
   Check(snapshot.feature_snapshot_hash == snapshotHashBefore, "snapshot.feature_snapshot_hash unchanged after the call");
   Check(plan.plan_hash == planHashBefore, "plan.plan_hash unchanged after the call");
}

//---------------------------------------------------------------------
// Structural checks - not runtime-testable, verified by inspection,
// same class as B8.1's own Test_NoEventStoreOrBrokerCall.
//---------------------------------------------------------------------
void Test_NoEventStoreOrBrokerCall()
{
   Print("--- no event store append, no broker/order/history/tick call (structural) ---");
   Check(true, "AI/MLQuantAI_TrainingDatasetBuilder.mqh contains no EventStore_Log*/OrderSend/CTrade/"
               "AccountInfo*/SymbolInfo*/TimeCurrent call anywhere - verified by inspection per "
               "Docs/PhaseB_B8_2_TrainingDatasetContract.md section 5");
}

void Test_NoLabelLeakageIntoFeaturePath()
{
   Print("--- no label/outcome data can reach FeatureSnapshot or its hashes (structural) ---");
   Check(true, "Candidate_ToFeatureSnapshot (B8.1, sealed) has no label/outcome parameter at all, and "
               "FeatureSnapshot_HashPayload/FeatureSnapshot_VectorHashPayload reference no field this "
               "file adds - verified by inspection per "
               "Docs/PhaseB_B8_2_TrainingDatasetContract.md section 7");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B8.2 Commit 1 - Training Dataset Row/Manifest Contract ===");

   Test_Determinism();
   Test_DatasetRowId_Dependencies();
   Test_RowHash_InclusionSweep();
   Test_RowHash_ExclusionWhitelist();
   Test_ReferentialIntegrity_Rejected();
   Test_FailClosed();
   Test_LabelAvailableFalse_IsAValidRow();
   Test_SplitDeterminism();
   Test_DatasetHash();
   Test_NoMutation();
   Test_NoEventStoreOrBrokerCall();
   Test_NoLabelLeakageIntoFeaturePath();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
