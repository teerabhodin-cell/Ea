//+------------------------------------------------------------------+
//| MLQuantAI_Test_B7_Commit3_IntegrationRegression.mq5                |
//| Phase B7 Commit 3 DoD, per Docs/PhaseB_B7_RiskPlanContract.md's    |
//| B7 Commit 3 addendum: proves the full MARKET_CONTEXT_READY ->      |
//| CANDIDATE_CREATED -> CandidateProjection -> Candidate_ToRiskPlan   |
//| -> RISK_PLAN_CREATED -> RiskPlanProjection -> Restart/Replay chain |
//| composes correctly end to end. Adds ZERO new production behavior  |
//| - no B5/B6/B7 sealed file touched. Does NOT re-prove anything      |
//| already covered by Test_B7_Commit2_RiskPlanEvent.mq5's own suite   |
//| (its own restart/multi-session/duplicate/collision/orphan/hash-    |
//| mismatch/field-fidelity tests) - see the addendum for exactly what |
//| is genuinely new here: end-to-end linkage in one place, cross-     |
//| layer failure propagation, full-chain multi-candidate restart, and |
//| multi-candidate cross-linking.                                     |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RiskPlanEventEmission.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_B7_Commit3_IntegrationRegression.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - same shapes as Test_B7_Commit2_RiskPlanEvent.mq5
// (each .mq5 test script in this project is standalone; no shared
// fixture include exists, matching every prior test file's own
// convention).
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
   ctx.context_event_id = "CTX_b7c3_" + suffix;
   ctx.context_hash      = "test_context_hash_b7c3_" + suffix;
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

string TamperStringField(string line, string key, string newValue)
{
   string needle = "\"" + key + "\":\"";
   int p = StringFind(line, needle);
   if(p < 0) return line;
   int start = p + StringLen(needle);
   int n = StringLen(line);
   int end = start;
   while(end < n && StringGetCharacter(line, end) != '"') end++;
   return StringSubstr(line, 0, start) + newValue + StringSubstr(line, end);
}

void ResetProjections()
{
   CandidateProjection_Reset();
   RiskPlanProjection_Reset();
}

// The one new fixture primitive this file adds: builds AND emits every
// layer of the real chain for one candidate, returning the MarketContext
// used (unlike Test_B7_Commit2's BuildCandidateAndPlan, which discarded
// it) - Commit 3's whole point is checking each layer's persisted state
// against what was actually fed into the layer before it, so the caller
// needs ctx, not just the final RiskPlan.
// dayOffset must be unique within one event store file (see the same
// lesson from Test_CandidateDatasetExport.mq5's own history, restated
// in Test_B7_Commit2_RiskPlanEvent.mq5).
bool BuildFullChain(MarketContext &ctx, TradeCandidate &c, RiskPlan &plan, string suffix, int dayOffset)
{
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

   RiskContext riskCtx; BuildValidRiskContext(riskCtx, suffix);
   if(!Candidate_ToRiskPlan(c, riskCtx, plan)) return false;
   return RiskPlan_EmitRiskPlanCreated(plan);
}

bool BuildThreeChains(TradeCandidate &candidates[], RiskPlan &plans[], MarketContext &ctxs[], string suffixPrefix, int baseDayOffset)
{
   ArrayResize(candidates, 3);
   ArrayResize(plans, 3);
   ArrayResize(ctxs, 3);
   for(int i = 0; i < 3; i++)
   {
      if(!BuildFullChain(ctxs[i], candidates[i], plans[i], suffixPrefix + IntegerToString(i), baseDayOffset + i))
         return false;
   }
   return true;
}

bool CandidateRecordsEqual(const CandidateProjectionRecord &a, const CandidateProjectionRecord &b)
{
   return a.candidate_id == b.candidate_id &&
          a.candidate_hash == b.candidate_hash &&
          a.context_hash == b.context_hash &&
          a.context_event_id == b.context_event_id &&
          a.detector_hash == b.detector_hash &&
          a.entry_hint == b.entry_hint &&
          a.sl_hint == b.sl_hint &&
          a.tp_hint == b.tp_hint &&
          a.side == b.side &&
          a.setup_anchor_bar_time == b.setup_anchor_bar_time &&
          a.expiry_time == b.expiry_time;
}

bool RiskPlanRecordsEqual(const RiskPlanProjectionRecord &a, const RiskPlanProjectionRecord &b)
{
   return a.risk_plan_id == b.risk_plan_id &&
          a.candidate_id == b.candidate_id &&
          a.candidate_hash == b.candidate_hash &&
          a.risk_context_hash == b.risk_context_hash &&
          a.plan_hash == b.plan_hash &&
          a.lot_size == b.lot_size &&
          a.risk_amount == b.risk_amount;
}

//=====================================================================
void Test_EndToEndLinkage_SingleCandidate()
{
   Print("--- end-to-end: context -> candidate -> plan hash/ID linkage matches at every hop ---");
   ResetProjections();
   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   EventStore_Open(TEST_EVENT_STORE_FILE);

   MarketContext ctx; TradeCandidate c; RiskPlan plan;
   Check(BuildFullChain(ctx, c, plan, "E2E", 200), "sanity: full chain built and emitted");
   EventStore_Close();

   RiskPlanProjectionReport report = RiskPlanProjection_RebuildFromFile(TEST_EVENT_STORE_FILE);
   Check(report.ok, "full chain rebuilds from the store alone");

   CandidateProjectionRecord candRec;
   Check(CandidateProjection_TryGet(c.candidate_id, candRec), "candidate is present in the rebuilt CandidateProjection");
   Check(candRec.context_hash == ctx.context_hash, "candidate's persisted context_hash matches the real MarketContext's own context_hash");
   Check(candRec.context_event_id == ctx.context_event_id, "candidate's persisted context_event_id matches the real MarketContext's own id");
   Check(candRec.candidate_hash == c.candidate_hash, "candidate's persisted candidate_hash matches the in-memory TradeCandidate's own hash");
   Check(candRec.detector_hash == c.detector_hash, "candidate's persisted detector_hash matches the in-memory TradeCandidate's own detector_hash");

   RiskPlanProjectionRecord planRec;
   Check(RiskPlanProjection_TryGet(plan.risk_plan_id, planRec), "plan is present in the rebuilt RiskPlanProjection");
   Check(planRec.candidate_id == c.candidate_id, "plan's persisted candidate_id matches the real candidate's own id");
   Check(planRec.candidate_hash == c.candidate_hash, "plan's persisted candidate_hash matches the real candidate's own hash");
   Check(planRec.candidate_hash == candRec.candidate_hash, "plan and candidate agree on candidate_hash across BOTH projections");
   Check(plan.risk_plan_id == Ids_RiskPlanId(c.candidate_id, plan.sizing_rules_version),
         "risk_plan_id is deterministically derived from this exact candidate_id + sizing_rules_version");
}

void Test_CrossLayerFailure_BlocksRiskPlanRebuild()
{
   Print("--- cross-layer: a corrupted CANDIDATE_CREATED line blocks RiskPlanProjection's rebuild too ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B7_Commit3_CandLayerFailure.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   MarketContext ctx; TradeCandidate c; RiskPlan plan;
   Check(BuildFullChain(ctx, c, plan, "CANDFAIL", 210), "sanity: full chain built and emitted");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string candidateLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"CANDIDATE_CREATED\"") >= 0) candidateLine = lines[i];
   Check(candidateLine != "", "sanity: the real CANDIDATE_CREATED line was found");

   // Empties candidate_id - stays syntactically valid JSON (so
   // EventStoreValidator's own generic line-shape/sequence checks still
   // pass this line through), but is a structural corruption
   // CandidateProjection_ApplyLine itself rejects - this specifically
   // exercises RiskPlanProjection_RebuildFromFile's SECOND gate (its
   // CandidateProjection_RebuildFromFile prerequisite call), not the
   // first (EventStoreValidator), which a plain truncated-line test
   // (already covered in Commit 2's own suite) would have hit instead.
   string tampered = TamperStringField(candidateLine, "candidate_id", "");
   Check(tampered != candidateLine, "sanity: candidate_id was actually tampered");
   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == candidateLine) ? tampered : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);

   int countBefore = RiskPlanProjection_Count();
   RiskPlanProjectionReport report = RiskPlanProjection_RebuildFromFile(file);
   Check(!report.ok, "RiskPlanProjection rebuild fails entirely when the candidate layer is corrupted");
   Check(StringFind(report.first_error, "candidate registry") >= 0,
         "first_error attributes the failure to the candidate registry, not the plan layer");
   Check(RiskPlanProjection_Count() == countBefore, "RiskPlanProjection's own registry is left untouched by a candidate-layer failure");
}

void Test_FullChainRestartSimulation_MultiCandidate()
{
   Print("--- full-chain restart: repeated rebuilds of a multi-candidate store reconstruct byte-identical state in BOTH projections ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B7_Commit3_MultiRestart.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate candidates[]; RiskPlan plans[]; MarketContext ctxs[];
   Check(BuildThreeChains(candidates, plans, ctxs, "RESTART", 220), "sanity: three full chains built and emitted");
   EventStore_Close();

   RiskPlanProjectionReport report1 = RiskPlanProjection_RebuildFromFile(file);
   Check(report1.ok && CandidateProjection_Count() == 3 && RiskPlanProjection_Count() == 3,
         "first rebuild: 3 candidates + 3 plans");

   CandidateProjectionRecord candBefore[3];
   RiskPlanProjectionRecord   planBefore[3];
   for(int i = 0; i < 3; i++)
   {
      CandidateProjection_TryGet(candidates[i].candidate_id, candBefore[i]);
      RiskPlanProjection_TryGet(plans[i].risk_plan_id, planBefore[i]);
   }

   RiskPlanProjectionReport report2 = RiskPlanProjection_RebuildFromFile(file); // simulate a restart: rebuild again
   Check(report2.ok && CandidateProjection_Count() == 3 && RiskPlanProjection_Count() == 3,
         "second rebuild (simulated restart): still 3 candidates + 3 plans");

   bool allCandidatesMatch = true;
   bool allPlansMatch = true;
   for(int i = 0; i < 3; i++)
   {
      CandidateProjectionRecord candAfter;
      RiskPlanProjectionRecord   planAfter;
      CandidateProjection_TryGet(candidates[i].candidate_id, candAfter);
      RiskPlanProjection_TryGet(plans[i].risk_plan_id, planAfter);
      if(!CandidateRecordsEqual(candBefore[i], candAfter)) allCandidatesMatch = false;
      if(!RiskPlanRecordsEqual(planBefore[i], planAfter))   allPlansMatch = false;
   }
   Check(allCandidatesMatch, "every CandidateProjection record is byte-identical across both rebuilds");
   Check(allPlansMatch, "every RiskPlanProjection record is byte-identical across both rebuilds");
}

void Test_MultiCandidateCrossLinking()
{
   Print("--- multi-candidate: every plan links to exactly its own candidate, never a neighbor's ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B7_Commit3_CrossLink.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate candidates[]; RiskPlan plans[]; MarketContext ctxs[];
   Check(BuildThreeChains(candidates, plans, ctxs, "XLINK", 230), "sanity: three full chains built and emitted");
   EventStore_Close();

   RiskPlanProjectionReport report = RiskPlanProjection_RebuildFromFile(file);
   Check(report.ok, "multi-candidate rebuild succeeds");

   for(int i = 0; i < 3; i++)
   {
      RiskPlanProjectionRecord planRec;
      Check(RiskPlanProjection_TryGet(plans[i].risk_plan_id, planRec), StringFormat("plan %d found in the rebuilt registry", i));
      Check(planRec.candidate_id == candidates[i].candidate_id, StringFormat("plan %d links to its OWN candidate_id", i));
      Check(planRec.candidate_hash == candidates[i].candidate_hash, StringFormat("plan %d links to its OWN candidate_hash", i));

      for(int j = 0; j < 3; j++)
      {
         if(j == i) continue;
         Check(planRec.candidate_id != candidates[j].candidate_id, StringFormat("plan %d does NOT link to candidate %d", i, j));
      }
   }
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B7 Commit 3 - Full-Chain Integration + Regression Proof ===");

   Test_EndToEndLinkage_SingleCandidate();
   Test_CrossLayerFailure_BlocksRiskPlanRebuild();
   Test_FullChainRestartSimulation_MultiCandidate();
   Test_MultiCandidateCrossLinking();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");

   Print("=== Manual regression checklist (per the B7 Commit 3 addendum) - re-run each of these in the same MetaEditor session and confirm ALL PASS: ===");
   Print("  Test_CandidateProjection.mq5");
   Print("  Test_CandidateDatasetExport.mq5");
   Print("  Test_B6_3_HashContract.mq5");
   Print("  Test_B7_Commit1_RiskPlan.mq5");
   Print("  Test_B7_Commit2_RiskPlanEvent.mq5");
}
