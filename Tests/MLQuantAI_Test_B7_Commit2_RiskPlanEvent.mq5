//+------------------------------------------------------------------+
//| MLQuantAI_Test_B7_Commit2_RiskPlanEvent.mq5                       |
//| Phase B7 Commit 2 DoD (B7.4 + B7.5): RISK_PLAN_CREATED event      |
//| emission + RiskPlanProjection replay, per                          |
//| Docs/PhaseB_B7_RiskPlanContract.md's B7 Commit 2 addendum. Uses    |
//| the real B5/B7 pipeline (CRT_DetectV1 -> CRT_ToTradeCandidate ->   |
//| CRT_EmitCandidateCreated -> Candidate_ToRiskPlan ->                 |
//| RiskPlan_EmitRiskPlanCreated) plus real MARKET_CONTEXT_READY        |
//| events, so referential-integrity checks have genuine data to check |
//| against. No B5/B6/B7-Commit-1 sealed file modified.                |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RiskPlanEventEmission.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_B7_Commit2_RiskPlanEvent.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

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
   ctx.context_event_id = "CTX_test_" + suffix;
   ctx.context_hash      = "test_context_hash_" + suffix;
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

// dayOffset must be globally unique across the whole file (candidate_id
// depends only on symbol/timeframe/eventType/swept_level/
// mss_confirmation_bar_time, never on the suffix) - see the same lesson
// learned in Test_CandidateDatasetExport.mq5's own history.
bool BuildAndEmitCandidate(TradeCandidate &c, string suffix, int dayOffset, bool logContext = true)
{
   MarketContext ctx; BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.01.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   if(logContext)
      EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx));

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;
   return CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits);
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

// Builds a real candidate (via the real B5 pipeline) and a real RiskPlan
// (via the real B7 Commit 1 Candidate_ToRiskPlan), but does NOT emit
// either - callers decide when to call CRT_EmitCandidateCreated/
// RiskPlan_EmitRiskPlanCreated themselves, so tests can control ordering.
bool BuildCandidateAndPlan(TradeCandidate &c, RiskPlan &plan, string suffix, int dayOffset)
{
   MarketContext ctx; BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.01.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx));

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;
   if(!CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits)) return false;

   RiskContext riskCtx; BuildValidRiskContext(riskCtx, suffix);
   return Candidate_ToRiskPlan(c, riskCtx, plan);
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

// Arithmetic-derived doubles (division/multiplication) can carry
// floating-point noise below CanonicalDouble's 8-decimal persisted
// precision - the round trip through RiskPlan_ToExtraJson's canonical
// string and back is correctly lossy at that precision (plan_hash
// itself is computed from the SAME canonical string, so plan_hash
// matching already proves canonical fidelity exactly). An exact `==`
// against the raw, unrounded in-memory double is stricter than that
// contract promises, so field-fidelity checks on these fields use a
// tolerance comfortably above the ~5e-9 worst-case 8-decimal rounding
// bound and far below any real field-mapping bug's magnitude.
#define MLQUANTAI_TEST_B7C2_EPS 0.000001
bool DoubleClose(double a, double b) { return MathAbs(a - b) < MLQUANTAI_TEST_B7C2_EPS; }

void ResetProjections()
{
   CandidateProjection_Reset();
   RiskPlanProjection_Reset();
}

//=====================================================================
void Test_ExactlyOneEmission()
{
   Print("--- a valid RiskPlan emits exactly one RISK_PLAN_CREATED event ---");
   ResetProjections();
   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   EventStore_Open(TEST_EVENT_STORE_FILE);

   TradeCandidate c; RiskPlan plan;
   Check(BuildCandidateAndPlan(c, plan, "ONE", 1), "sanity: candidate + plan built");
   Check(RiskPlan_EmitRiskPlanCreated(plan), "emission succeeds");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
   int riskPlanLines = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"RISK_PLAN_CREATED\"") >= 0) riskPlanLines++;
   Check(riskPlanLines == 1, "exactly one RISK_PLAN_CREATED line written");
}

void Test_DuplicateEmission_SameSession_NoOp()
{
   Print("--- re-emitting the identical plan live, same session, is a no-op ---");
   ResetProjections();
   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   EventStore_Open(TEST_EVENT_STORE_FILE);

   TradeCandidate c; RiskPlan plan;
   Check(BuildCandidateAndPlan(c, plan, "DUPSESSION", 2), "sanity: candidate + plan built");
   Check(RiskPlan_EmitRiskPlanCreated(plan), "first emission succeeds");
   Check(!RiskPlan_EmitRiskPlanCreated(plan), "second emission of the identical plan returns false (no-op)");
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
   int riskPlanLines = 0;
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"RISK_PLAN_CREATED\"") >= 0) riskPlanLines++;
   Check(riskPlanLines == 1, "still only one RISK_PLAN_CREATED line written - no second event");
}

void Test_RejectedPlan_EmitsNothing()
{
   Print("--- a rejected (not allowed) plan emits no event ---");
   ResetProjections();
   RiskPlan rejected; RiskPlan_Init(rejected);
   Check(!rejected.allowed, "sanity: Init() plan is not allowed");
   Check(!RiskPlan_EmitRiskPlanCreated(rejected), "emitting an unfilled/rejected plan returns false");
}

void Test_Replay_DuplicateSameHash_NoOp()
{
   Print("--- replay: same risk_plan_id + same plan_hash = duplicate no-op ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B7_Commit2_Duplicate.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; RiskPlan plan;
   Check(BuildCandidateAndPlan(c, plan, "REPLAYDUP", 3), "sanity: candidate + plan built");
   Check(RiskPlan_EmitRiskPlanCreated(plan), "emission succeeds");
   EventStore_Close();

   // Emit the EXACT SAME plan again under a fresh session (a raw
   // byte-copy of the persisted line would carry the SAME seq number,
   // which EventStoreValidator's own duplicate-seq check would reject
   // before ever reaching RiskPlanProjection's own duplicate/collision
   // logic - reopening genuinely advances seq/session_id, simulating
   // two independent sessions/processes both durably emitting the
   // identical plan, which is what this test actually means to prove).
   RiskPlanProjection_Reset(); // clears the live emission guard so re-emission isn't blocked live
   EventStore_Open(file);
   Check(RiskPlan_EmitRiskPlanCreated(plan), "sanity: the identical plan re-emits under a fresh session");
   EventStore_Close();

   RiskPlanProjectionReport report = RiskPlanProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds despite the duplicate line");
   Check(RiskPlanProjection_Count() == 1, "registry has exactly one record - the duplicate was a no-op");
}

void Test_Replay_CollisionDifferentHash_Rejected()
{
   Print("--- replay: same risk_plan_id + DIFFERENT plan_hash = collision, rejected ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B7_Commit2_Collision.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; RiskPlan plan;
   Check(BuildCandidateAndPlan(c, plan, "REPLAYCOLL", 4), "sanity: candidate + plan built");
   Check(RiskPlan_EmitRiskPlanCreated(plan), "emission succeeds");
   EventStore_Close();

   // Same risk_plan_id (unaffected by lot_size), DIFFERENT plan_hash
   // (lot_size IS in the payload) - emitted under a fresh session so
   // EventStoreValidator sees a valid, non-duplicate seq (see the note
   // in Test_Replay_DuplicateSameHash_NoOp above for why a raw
   // byte-copy append would be rejected before ever reaching this
   // test's actual target: RiskPlanProjection's own collision logic).
   RiskPlan collidingPlan = plan;
   collidingPlan.lot_size += 0.01;
   collidingPlan.plan_hash = RiskPlan_ComputeHash(collidingPlan);
   Check(collidingPlan.risk_plan_id == plan.risk_plan_id, "sanity: risk_plan_id unaffected by lot_size");
   Check(collidingPlan.plan_hash != plan.plan_hash, "sanity: plan_hash DOES move with lot_size");

   RiskPlanProjection_Reset(); // clears the live emission guard so the colliding plan isn't blocked live
   EventStore_Open(file);
   Check(RiskPlan_EmitRiskPlanCreated(collidingPlan), "sanity: the colliding plan emits under a fresh session");
   EventStore_Close();

   RiskPlanProjectionReport report = RiskPlanProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on a risk_plan_id collision");
   Check(StringFind(report.first_error, "collision") >= 0, "first_error mentions the collision, not a duplicate no-op");
}

void Test_Replay_OrphanCandidate_Rejected()
{
   Print("--- replay: a RISK_PLAN_CREATED referencing an unknown candidate_id is an orphan, rejected ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B7_Commit2_Orphan.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; RiskPlan plan;
   Check(BuildCandidateAndPlan(c, plan, "ORPHANRP", 5), "sanity: candidate + plan built");
   plan.candidate_id = "CND_DOES_NOT_EXIST";
   plan.plan_hash = RiskPlan_ComputeHash(plan); // recompute so plan_hash isn't stale after tampering candidate_id
   Check(RiskPlan_EmitRiskPlanCreated(plan), "sanity: emission of the (now-orphaned) plan itself succeeds");
   EventStore_Close();

   RiskPlanProjectionReport report = RiskPlanProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on an orphan candidate reference");
   Check(StringFind(report.first_error, "orphan") >= 0, "first_error mentions the orphan");
}

void Test_Replay_CandidateHashMismatch_Rejected()
{
   Print("--- replay: a RISK_PLAN_CREATED whose candidate_hash mismatches the real candidate is rejected ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B7_Commit2_HashMismatch.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; RiskPlan plan;
   Check(BuildCandidateAndPlan(c, plan, "HASHMISMATCH", 6), "sanity: candidate + plan built");
   Check(RiskPlan_EmitRiskPlanCreated(plan), "sanity: emission succeeds"); // must happen BEFORE Close - appending to a closed store fails
   EventStore_Close();

   string lines[];
   int n = EventStore_ReadAllLines(file, lines);
   string riskPlanLine = "";
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], "\"type\":\"RISK_PLAN_CREATED\"") >= 0) riskPlanLine = lines[i];
   Check(riskPlanLine != "", "sanity: the real RISK_PLAN_CREATED line was found");

   string tampered = TamperStringField(riskPlanLine, "candidate_hash", "TAMPERED_CANDIDATE_HASH");
   FileDelete(file, FILE_COMMON);
   int h = FileOpen(file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
   {
      string toWrite = (lines[i] == riskPlanLine) ? tampered : lines[i];
      FileWriteString(h, toWrite + "\r\n");
   }
   FileClose(h);

   RiskPlanProjectionReport report = RiskPlanProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on a candidate_hash mismatch");
   Check(StringFind(report.first_error, "mismatch") >= 0, "first_error mentions the mismatch");
}

void Test_MalformedLine_BlocksWholeRebuild()
{
   Print("--- a truncated/malformed line anywhere blocks the WHOLE rebuild ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B7_Commit2_Malformed.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; RiskPlan plan;
   Check(BuildCandidateAndPlan(c, plan, "MALFORMED", 7), "sanity: candidate + plan built");
   Check(RiskPlan_EmitRiskPlanCreated(plan), "sanity: emission succeeds");
   EventStore_Close();

   int h = FileOpen(file, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, "{\"schema_version\":\"EVENTS_V1\",\"type\":\"RISK_PLAN_CREATED\",truncated_garbage");
   FileClose(h);

   // Not necessarily 0: RiskPlan_EmitRiskPlanCreated's own live-sync
   // (RiskPlanProjection_ApplyLiveRecord) already put one record into
   // this SAME global registry the moment it was called above, before
   // this rebuild was ever attempted. The actual documented contract
   // (see RiskPlanProjection_RebuildFromFile's own header comment) is
   // "left completely untouched" on failure, not "empty" - so this
   // test asserts the count is unchanged by the failed rebuild,
   // whatever it was beforehand, rather than assuming it was 0.
   int countBefore = RiskPlanProjection_Count();
   RiskPlanProjectionReport report = RiskPlanProjection_RebuildFromFile(file);
   Check(!report.ok, "rebuild fails entirely on the truncated line");
   Check(RiskPlanProjection_Count() == countBefore, "registry is left completely untouched by a failed rebuild");
}

void Test_RestartCrashSimulation()
{
   Print("--- repeated rebuilds of the same store reconstruct byte-identical records ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B7_Commit2_Restart.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c1, c2; RiskPlan plan1, plan2;
   Check(BuildCandidateAndPlan(c1, plan1, "RESTART1", 8), "sanity: candidate 1 + plan built");
   Check(RiskPlan_EmitRiskPlanCreated(plan1), "sanity: emission 1 succeeds");
   Check(BuildCandidateAndPlan(c2, plan2, "RESTART2", 9), "sanity: candidate 2 + plan built");
   Check(RiskPlan_EmitRiskPlanCreated(plan2), "sanity: emission 2 succeeds");
   EventStore_Close();

   RiskPlanProjectionReport report1 = RiskPlanProjection_RebuildFromFile(file);
   Check(report1.ok && RiskPlanProjection_Count() == 2, "first rebuild: 2 records");
   RiskPlanProjectionRecord rec1a, rec1b;
   RiskPlanProjection_TryGet(plan1.risk_plan_id, rec1a);
   RiskPlanProjection_TryGet(plan2.risk_plan_id, rec1b);

   RiskPlanProjectionReport report2 = RiskPlanProjection_RebuildFromFile(file); // simulate a restart: rebuild again
   Check(report2.ok && RiskPlanProjection_Count() == 2, "second rebuild (simulated restart): still 2 records");
   RiskPlanProjectionRecord rec2a, rec2b;
   RiskPlanProjection_TryGet(plan1.risk_plan_id, rec2a);
   RiskPlanProjection_TryGet(plan2.risk_plan_id, rec2b);

   Check(rec1a.plan_hash == rec2a.plan_hash && rec1a.lot_size == rec2a.lot_size, "record 1 identical across both rebuilds");
   Check(rec1b.plan_hash == rec2b.plan_hash && rec1b.lot_size == rec2b.lot_size, "record 2 identical across both rebuilds");
}

void Test_MultiSession()
{
   Print("--- a store spanning multiple sessions rebuilds correctly ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B7_Commit2_MultiSession.jsonl";
   FileDelete(file, FILE_COMMON);

   EventStore_Open(file);
   TradeCandidate c1; RiskPlan plan1;
   Check(BuildCandidateAndPlan(c1, plan1, "SESSA", 10), "sanity: session A candidate + plan built");
   Check(RiskPlan_EmitRiskPlanCreated(plan1), "sanity: session A emission succeeds");
   EventStore_Close();

   EventStore_Open(file); // simulates a second EA run appending to the same file
   TradeCandidate c2; RiskPlan plan2;
   Check(BuildCandidateAndPlan(c2, plan2, "SESSB", 11), "sanity: session B candidate + plan built");
   Check(RiskPlan_EmitRiskPlanCreated(plan2), "sanity: session B emission succeeds");
   EventStore_Close();

   RiskPlanProjectionReport report = RiskPlanProjection_RebuildFromFile(file);
   Check(report.ok, "multi-session rebuild succeeds");
   Check(RiskPlanProjection_Count() == 2, "both sessions' plans are present after rebuild");
}

void Test_ReplayFieldsMatchOriginal()
{
   Print("--- every field on a rebuilt record matches the original RiskPlan exactly ---");
   ResetProjections();
   string file = "MLQuantAI_Test_B7_Commit2_FieldMatch.jsonl";
   FileDelete(file, FILE_COMMON);
   EventStore_Open(file);

   TradeCandidate c; RiskPlan plan;
   Check(BuildCandidateAndPlan(c, plan, "FIELDMATCH", 12), "sanity: candidate + plan built");
   Check(RiskPlan_EmitRiskPlanCreated(plan), "sanity: emission succeeds");
   EventStore_Close();

   RiskPlanProjectionReport report = RiskPlanProjection_RebuildFromFile(file);
   Check(report.ok, "rebuild succeeds");
   RiskPlanProjectionRecord rec;
   Check(RiskPlanProjection_TryGet(plan.risk_plan_id, rec), "the plan is found in the rebuilt registry");

   Check(rec.risk_plan_id == plan.risk_plan_id, "risk_plan_id matches");
   Check(rec.candidate_id == plan.candidate_id, "candidate_id matches");
   Check(rec.candidate_hash == plan.candidate_hash, "candidate_hash matches");
   Check(rec.risk_context_hash == plan.risk_context_hash, "risk_context_hash matches");
   Check(rec.planned_entry == plan.planned_entry && rec.planned_sl == plan.planned_sl && rec.planned_tp == plan.planned_tp,
         "planned_entry/sl/tp match");
   Check(DoubleClose(rec.stop_distance_points, plan.stop_distance_points), "stop_distance_points matches");
   Check(DoubleClose(rec.rr_ratio, plan.rr_ratio), "rr_ratio matches");
   Check(rec.risk_percent == plan.risk_percent, "risk_percent matches");
   Check(DoubleClose(rec.risk_amount, plan.risk_amount), "risk_amount matches");
   Check(DoubleClose(rec.lot_size, plan.lot_size), "lot_size matches");
   Check(rec.sizing_method == plan.sizing_method, "sizing_method matches");
   Check(rec.sizing_rules_version == plan.sizing_rules_version, "sizing_rules_version matches");
   Check(rec.plan_hash == plan.plan_hash, "plan_hash matches - no drift between emission and replay");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B7 Commit 2 - RISK_PLAN_CREATED Event + Projection ===");

   Test_ExactlyOneEmission();
   Test_DuplicateEmission_SameSession_NoOp();
   Test_RejectedPlan_EmitsNothing();
   Test_Replay_DuplicateSameHash_NoOp();
   Test_Replay_CollisionDifferentHash_Rejected();
   Test_Replay_OrphanCandidate_Rejected();
   Test_Replay_CandidateHashMismatch_Rejected();
   Test_MalformedLine_BlocksWholeRebuild();
   Test_RestartCrashSimulation();
   Test_MultiSession();
   Test_ReplayFieldsMatchOriginal();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
