//+------------------------------------------------------------------+
//| MLQuantAI_Test_B7_Commit1_RiskPlan.mq5                            |
//| Phase B7 Commit 1 DoD: RiskContext (B7.1) + RiskPlan (B7.2) +      |
//| Candidate_ToRiskPlan (B7.3), per Docs/PhaseB_B7_RiskPlanContract.md|
//| Pure-function tests only - no event store I/O, no broker call.     |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//=====================================================================
// Fixtures - a clean, hand-verifiable baseline: stop_distance_points=100,
// rr_ratio=3.0, risk_amount=100.0, lot_size=1.0 (see the test that
// asserts these exact numbers).
//=====================================================================
void BuildValidCandidate(TradeCandidate &c, string suffix)
{
   TradeCandidate_Init(c);
   c.candidate_id   = "CND_" + suffix;
   c.candidate_hash = "candhash_" + suffix;
   c.side  = ORDER_TYPE_BUY;
   c.state = CANDIDATE_CREATED;
   c.entry_hint = 100.00;
   c.sl_hint    = 99.00;
   c.tp_hint    = 103.00;
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

//=====================================================================
// Part 1: sizing formula correctness (hand-verified numbers)
//=====================================================================
void Test_SizingFormula_ExactNumbers()
{
   Print("--- sizing formula: hand-verified exact output on a clean fixture ---");
   TradeCandidate c; BuildValidCandidate(c, "SIZING");
   RiskContext ctx; BuildValidRiskContext(ctx, "SIZING");

   RiskPlan plan;
   Check(Candidate_ToRiskPlan(c, ctx, plan), "sizing succeeds on a valid fixture");

   Check(plan.stop_distance_points == 100.0, "stop_distance_points == 100 (|100.00-99.00|/0.01)");
   Check(plan.rr_ratio == 3.0, "rr_ratio == 3.0 (|103.00-100.00|/|100.00-99.00|)");
   Check(plan.risk_amount == 100.0, "risk_amount == 100.0 (10000 * 1%)");
   Check(plan.lot_size == 1.0, "lot_size == 1.0 (100 / (100 points * 1.0 tick_value), stepped to 0.01)");

   Check(plan.planned_entry == 100.00 && plan.planned_sl == 99.00 && plan.planned_tp == 103.00,
         "planned_entry/sl/tp copied verbatim from candidate.entry_hint/sl_hint/tp_hint");

   Check(plan.risk_money == plan.risk_amount, "risk_money (Phase A field) == risk_amount (B7 field)");
   Check(plan.lot == plan.lot_size, "lot (Phase A field) == lot_size (B7 field)");
   Check(plan.decision == RISK_DECISION_ALLOW, "decision == RISK_DECISION_ALLOW on success");
   Check(plan.allowed, "allowed == true on success");
   Check(plan.reject_reason == REASON_NONE, "reject_reason == REASON_NONE on success");

   Check(plan.candidate_id == c.candidate_id, "candidate_id copied verbatim");
   Check(plan.candidate_hash == c.candidate_hash, "candidate_hash copied verbatim, never recomputed");
   Check(plan.risk_context_hash == ctx.risk_context_hash, "risk_context_hash copied verbatim, never recomputed");
   Check(plan.sizing_method == ctx.sizing_method, "sizing_method copied verbatim");
   Check(plan.sizing_rules_version == ctx.sizing_rules_version, "sizing_rules_version copied verbatim");

   Check(plan.risk_plan_id == Ids_RiskPlanId(c.candidate_id, ctx.sizing_rules_version),
         "risk_plan_id == Ids_RiskPlanId(candidate_id, sizing_rules_version)");
   Check(plan.plan_hash != "", "plan_hash is non-empty");
   Check(plan.plan_hash == RiskPlan_ComputeHash(plan), "plan_hash is reproducible from the plan's own content");
}

//=====================================================================
// Part 2: risk_plan_id vs plan_hash identity/content independence
//=====================================================================
void Test_RiskPlanId_IndependentOfContent()
{
   Print("--- risk_plan_id depends only on candidate_id + sizing_rules_version ---");
   TradeCandidate c; BuildValidCandidate(c, "IDTEST");

   RiskContext ctxA; BuildValidRiskContext(ctxA, "IDTEST_A");
   RiskContext ctxB; BuildValidRiskContext(ctxB, "IDTEST_B");
   ctxB.account.balance = 50000.0; // different balance -> different sizing output
   ctxB.risk_context_hash = RiskContext_ComputeHash(ctxB);

   RiskPlan planA, planB;
   Check(Candidate_ToRiskPlan(c, ctxA, planA), "sizing succeeds with ctxA");
   Check(Candidate_ToRiskPlan(c, ctxB, planB), "sizing succeeds with ctxB (different balance)");

   Check(planA.risk_plan_id == planB.risk_plan_id,
         "same candidate + same sizing_rules_version -> identical risk_plan_id, even with different balance");
   Check(planA.plan_hash != planB.plan_hash,
         "different balance produces a different plan_hash (via risk_amount/lot_size)");
   Check(planA.risk_amount != planB.risk_amount, "different balance produces different risk_amount");
   Check(planA.lot_size != planB.lot_size, "different balance produces different lot_size");
}

void Test_RiskPlanId_ChangesWithSizingRulesVersion()
{
   Print("--- risk_plan_id changes when sizing_rules_version changes ---");
   TradeCandidate c; BuildValidCandidate(c, "VERTEST");
   RiskContext ctxA; BuildValidRiskContext(ctxA, "VERTEST_A");
   RiskContext ctxB; BuildValidRiskContext(ctxB, "VERTEST_B");
   ctxB.sizing_rules_version = "FIXED_PERCENT_RISK_V2";
   ctxB.risk_context_hash = RiskContext_ComputeHash(ctxB);

   RiskPlan planA, planB;
   Check(Candidate_ToRiskPlan(c, ctxA, planA), "sizing succeeds with ctxA");
   Check(Candidate_ToRiskPlan(c, ctxB, planB), "sizing succeeds with ctxB (different sizing_rules_version)");

   Check(planA.risk_plan_id != planB.risk_plan_id, "different sizing_rules_version -> different risk_plan_id");
   Check(planA.risk_context_hash != planB.risk_context_hash, "different sizing_rules_version -> different risk_context_hash (it's in the payload)");
   Check(planA.plan_hash != planB.plan_hash, "different sizing_rules_version -> different plan_hash");
}

//=====================================================================
// Part 3: risk_context_hash inclusion/exclusion mutation sweep
//=====================================================================
void Test_RiskContextHash_IncludedFieldsMoveHash()
{
   Print("--- risk_context_hash: every INCLUDED field change moves the hash ---");
   RiskContext baseline; BuildValidRiskContext(baseline, "CTXHASH");
   string baseHash = baseline.risk_context_hash;
   RiskContext m;

   m = baseline; m.symbol_spec.instrument_id = "EURUSD";
   Check(RiskContext_ComputeHash(m) != baseHash, "symbol_spec.instrument_id change moves risk_context_hash");

   m = baseline; m.symbol_spec.broker_symbol = "OTHER_BROKER_SYM";
   Check(RiskContext_ComputeHash(m) != baseHash, "symbol_spec.broker_symbol change moves risk_context_hash");

   m = baseline; m.symbol_spec.tick_size += 0.001;
   Check(RiskContext_ComputeHash(m) != baseHash, "symbol_spec.tick_size change moves risk_context_hash");

   m = baseline; m.symbol_spec.tick_value += 0.1;
   Check(RiskContext_ComputeHash(m) != baseHash, "symbol_spec.tick_value change moves risk_context_hash");

   m = baseline; m.symbol_spec.contract_size += 1;
   Check(RiskContext_ComputeHash(m) != baseHash, "symbol_spec.contract_size change moves risk_context_hash");

   m = baseline; m.symbol_spec.volume_min += 0.01;
   Check(RiskContext_ComputeHash(m) != baseHash, "symbol_spec.volume_min change moves risk_context_hash");

   m = baseline; m.symbol_spec.volume_max += 1;
   Check(RiskContext_ComputeHash(m) != baseHash, "symbol_spec.volume_max change moves risk_context_hash");

   m = baseline; m.symbol_spec.volume_step += 0.001;
   Check(RiskContext_ComputeHash(m) != baseHash, "symbol_spec.volume_step change moves risk_context_hash");

   m = baseline; m.symbol_spec.digits = 5;
   Check(RiskContext_ComputeHash(m) != baseHash, "symbol_spec.digits change moves risk_context_hash");

   m = baseline; m.target_risk_percent += 0.5;
   Check(RiskContext_ComputeHash(m) != baseHash, "target_risk_percent change moves risk_context_hash");

   m = baseline; m.sizing_method = "OTHER_METHOD";
   Check(RiskContext_ComputeHash(m) != baseHash, "sizing_method change moves risk_context_hash");

   m = baseline; m.sizing_rules_version = "OTHER_VERSION";
   Check(RiskContext_ComputeHash(m) != baseHash, "sizing_rules_version change moves risk_context_hash");
}

void Test_RiskContextHash_ExcludedFieldsDoNotMoveHash()
{
   Print("--- risk_context_hash: whitelist of fields that must NOT move the hash ---");
   RiskContext baseline; BuildValidRiskContext(baseline, "CTXEXCL");
   string baseHash = baseline.risk_context_hash;
   RiskContext m;

   m = baseline; m.account.balance += 5000.0;
   Check(RiskContext_ComputeHash(m) == baseHash, "account.balance change does NOT move risk_context_hash");

   m = baseline; m.account.equity += 5000.0;
   Check(RiskContext_ComputeHash(m) == baseHash, "account.equity change does NOT move risk_context_hash");

   m = baseline; m.account.margin_level += 100.0;
   Check(RiskContext_ComputeHash(m) == baseHash, "account.margin_level change does NOT move risk_context_hash");

   m = baseline; m.symbol_spec.currency_base = "OTHER";
   Check(RiskContext_ComputeHash(m) == baseHash, "symbol_spec.currency_base change does NOT move risk_context_hash");

   m = baseline; m.symbol_spec.currency_profit = "OTHER";
   Check(RiskContext_ComputeHash(m) == baseHash, "symbol_spec.currency_profit change does NOT move risk_context_hash");

   m = baseline; m.symbol_spec.currency_margin = "OTHER";
   Check(RiskContext_ComputeHash(m) == baseHash, "symbol_spec.currency_margin change does NOT move risk_context_hash");

   m = baseline; m.symbol_spec.point += 0.001;
   Check(RiskContext_ComputeHash(m) == baseHash, "symbol_spec.point change does NOT move risk_context_hash");

   m = baseline; m.symbol_spec.stops_level_points += 10;
   Check(RiskContext_ComputeHash(m) == baseHash, "symbol_spec.stops_level_points change does NOT move risk_context_hash");

   m = baseline; m.symbol_spec.freeze_level_points += 10;
   Check(RiskContext_ComputeHash(m) == baseHash, "symbol_spec.freeze_level_points change does NOT move risk_context_hash");

   m = baseline; m.symbol_spec.symbol = "OTHER_RAW_SYMBOL";
   Check(RiskContext_ComputeHash(m) == baseHash, "symbol_spec.symbol change does NOT move risk_context_hash");

   m = baseline; m.risk_context_schema_version = "OTHER_SCHEMA";
   Check(RiskContext_ComputeHash(m) == baseHash, "risk_context_schema_version change does NOT move risk_context_hash");
}

//=====================================================================
// Part 4: plan_hash inclusion/exclusion mutation sweep
//=====================================================================
void Test_PlanHash_IncludedFieldsMoveHash()
{
   Print("--- plan_hash: every INCLUDED field change moves the hash ---");
   TradeCandidate c; BuildValidCandidate(c, "PLANHASH");
   RiskContext ctx; BuildValidRiskContext(ctx, "PLANHASH");
   RiskPlan baseline;
   Check(Candidate_ToRiskPlan(c, ctx, baseline), "sanity: baseline plan built");
   string baseHash = baseline.plan_hash;
   RiskPlan m;

   m = baseline; m.candidate_id = "OTHER_CANDIDATE_ID";
   Check(RiskPlan_ComputeHash(m) != baseHash, "candidate_id change moves plan_hash");

   m = baseline; m.candidate_hash = "OTHER_CANDIDATE_HASH";
   Check(RiskPlan_ComputeHash(m) != baseHash, "candidate_hash change moves plan_hash");

   m = baseline; m.risk_context_hash = "OTHER_RISK_CONTEXT_HASH";
   Check(RiskPlan_ComputeHash(m) != baseHash, "risk_context_hash change moves plan_hash");

   m = baseline; m.planned_entry += 0.01;
   Check(RiskPlan_ComputeHash(m) != baseHash, "planned_entry change moves plan_hash");

   m = baseline; m.planned_sl += 0.01;
   Check(RiskPlan_ComputeHash(m) != baseHash, "planned_sl change moves plan_hash");

   m = baseline; m.planned_tp += 0.01;
   Check(RiskPlan_ComputeHash(m) != baseHash, "planned_tp change moves plan_hash");

   m = baseline; m.stop_distance_points += 1;
   Check(RiskPlan_ComputeHash(m) != baseHash, "stop_distance_points change moves plan_hash");

   m = baseline; m.rr_ratio += 0.1;
   Check(RiskPlan_ComputeHash(m) != baseHash, "rr_ratio change moves plan_hash");

   m = baseline; m.risk_percent += 0.1;
   Check(RiskPlan_ComputeHash(m) != baseHash, "risk_percent change moves plan_hash");

   m = baseline; m.risk_amount += 1;
   Check(RiskPlan_ComputeHash(m) != baseHash, "risk_amount change moves plan_hash");

   m = baseline; m.lot_size += 0.01;
   Check(RiskPlan_ComputeHash(m) != baseHash, "lot_size change moves plan_hash");

   m = baseline; m.sizing_method = "OTHER_METHOD";
   Check(RiskPlan_ComputeHash(m) != baseHash, "sizing_method change moves plan_hash");

   m = baseline; m.sizing_rules_version = "OTHER_VERSION";
   Check(RiskPlan_ComputeHash(m) != baseHash, "sizing_rules_version change moves plan_hash");
}

void Test_PlanHash_ExcludedFieldsDoNotMoveHash()
{
   Print("--- plan_hash: whitelist of fields that must NOT move the hash ---");
   TradeCandidate c; BuildValidCandidate(c, "PLANEXCL");
   RiskContext ctx; BuildValidRiskContext(ctx, "PLANEXCL");
   RiskPlan baseline;
   Check(Candidate_ToRiskPlan(c, ctx, baseline), "sanity: baseline plan built");
   string baseHash = baseline.plan_hash;
   RiskPlan m;

   m = baseline; m.risk_plan_id = "OTHER_RISK_PLAN_ID";
   Check(RiskPlan_ComputeHash(m) == baseHash, "risk_plan_id change does NOT move plan_hash");

   m = baseline; m.risk_plan_schema_version = "OTHER_SCHEMA";
   Check(RiskPlan_ComputeHash(m) == baseHash, "risk_plan_schema_version change does NOT move plan_hash");

   m = baseline; m.decision = RISK_DECISION_BLOCK;
   Check(RiskPlan_ComputeHash(m) == baseHash, "decision change does NOT move plan_hash");

   m = baseline; m.allowed = false;
   Check(RiskPlan_ComputeHash(m) == baseHash, "allowed change does NOT move plan_hash");

   m = baseline; m.reject_reason = REASON_RISK_MAX_PER_TRADE;
   Check(RiskPlan_ComputeHash(m) == baseHash, "reject_reason change does NOT move plan_hash");

   m = baseline; m.risk_schema_version = "OTHER_SCHEMA";
   Check(RiskPlan_ComputeHash(m) == baseHash, "risk_schema_version (Phase A) change does NOT move plan_hash");

   m = baseline; m.lot += 0.5; // deliberately diverge from lot_size - lot itself is excluded
   Check(RiskPlan_ComputeHash(m) == baseHash, "lot (Phase A field) change alone does NOT move plan_hash");

   m = baseline; m.risk_money += 50; // deliberately diverge from risk_amount - risk_money itself is excluded
   Check(RiskPlan_ComputeHash(m) == baseHash, "risk_money (Phase A field) change alone does NOT move plan_hash");
}

//=====================================================================
// Part 5: fail-closed validation
//=====================================================================
void Test_FailClosed_InvalidCandidate()
{
   Print("--- fail-closed: candidate-side invalid input ---");
   RiskContext ctx; BuildValidRiskContext(ctx, "FAILCAND");

   TradeCandidate empty; TradeCandidate_Init(empty);
   RiskPlan plan1;
   Check(!Candidate_ToRiskPlan(empty, ctx, plan1), "empty candidate_id is rejected");
   Check(!plan1.allowed && plan1.plan_hash == "", "rejected plan stays at Init() defaults - no partial output");

   TradeCandidate notCreated; BuildValidCandidate(notCreated, "NOTCREATED");
   notCreated.state = CANDIDATE_SUBMITTED;
   RiskPlan plan2;
   Check(!Candidate_ToRiskPlan(notCreated, ctx, plan2), "candidate.state != CANDIDATE_CREATED is rejected");

   TradeCandidate nanEntry; BuildValidCandidate(nanEntry, "NANENTRY");
   double zeroForNan = 0.0;
   nanEntry.entry_hint = zeroForNan / zeroForNan; // IEEE754 float division, not integer - yields NaN, not a runtime error
   RiskPlan plan3;
   Check(!Candidate_ToRiskPlan(nanEntry, ctx, plan3), "NaN entry_hint is rejected");

   TradeCandidate zeroSl; BuildValidCandidate(zeroSl, "ZEROSL");
   zeroSl.sl_hint = 0;
   RiskPlan plan4;
   Check(!Candidate_ToRiskPlan(zeroSl, ctx, plan4), "zero sl_hint is rejected");

   TradeCandidate badOrderBuy; BuildValidCandidate(badOrderBuy, "BADORDERBUY");
   badOrderBuy.side = ORDER_TYPE_BUY;
   badOrderBuy.sl_hint = 101.00; // sl above entry - violates BUY semantics
   RiskPlan plan5;
   Check(!Candidate_ToRiskPlan(badOrderBuy, ctx, plan5), "BUY with sl_hint > entry_hint is rejected");

   TradeCandidate badOrderSell; BuildValidCandidate(badOrderSell, "BADORDERSELL");
   badOrderSell.side = ORDER_TYPE_SELL;
   badOrderSell.entry_hint = 100.00; badOrderSell.sl_hint = 99.00; badOrderSell.tp_hint = 97.00; // sl below entry - violates SELL semantics
   RiskPlan plan6;
   Check(!Candidate_ToRiskPlan(badOrderSell, ctx, plan6), "SELL with sl_hint < entry_hint is rejected");
}

void Test_FailClosed_InvalidRiskContext()
{
   Print("--- fail-closed: RiskContext-side invalid input ---");
   TradeCandidate c; BuildValidCandidate(c, "FAILCTX");

   RiskContext zeroTick; BuildValidRiskContext(zeroTick, "ZEROTICK"); zeroTick.symbol_spec.tick_size = 0;
   RiskPlan plan1;
   Check(!Candidate_ToRiskPlan(c, zeroTick, plan1), "tick_size <= 0 is rejected");

   RiskContext zeroTickValue; BuildValidRiskContext(zeroTickValue, "ZEROTICKVAL"); zeroTickValue.symbol_spec.tick_value = 0;
   RiskPlan plan2;
   Check(!Candidate_ToRiskPlan(c, zeroTickValue, plan2), "tick_value <= 0 is rejected");

   RiskContext zeroStep; BuildValidRiskContext(zeroStep, "ZEROSTEP"); zeroStep.symbol_spec.volume_step = 0;
   RiskPlan plan3;
   Check(!Candidate_ToRiskPlan(c, zeroStep, plan3), "volume_step <= 0 is rejected");

   RiskContext zeroPercent; BuildValidRiskContext(zeroPercent, "ZEROPCT"); zeroPercent.target_risk_percent = 0;
   RiskPlan plan4;
   Check(!Candidate_ToRiskPlan(c, zeroPercent, plan4), "target_risk_percent <= 0 is rejected");

   RiskContext zeroBalance; BuildValidRiskContext(zeroBalance, "ZEROBAL"); zeroBalance.account.balance = 0;
   RiskPlan plan5;
   Check(!Candidate_ToRiskPlan(c, zeroBalance, plan5), "account.balance <= 0 is rejected");
}

void Test_FailClosed_BelowVolumeMin_ClampAtVolumeMax()
{
   Print("--- volume normalization edge cases: below min rejects, above max clamps ---");
   TradeCandidate c; BuildValidCandidate(c, "VOLEDGE");

   // Tiny target_risk_percent -> raw lot rounds to 0, below volume_min -> reject.
   RiskContext tinyRisk; BuildValidRiskContext(tinyRisk, "TINYRISK");
   tinyRisk.target_risk_percent = 0.001;
   tinyRisk.risk_context_hash = RiskContext_ComputeHash(tinyRisk);
   RiskPlan plan1;
   Check(!Candidate_ToRiskPlan(c, tinyRisk, plan1), "a stepped lot below volume_min is rejected, not bumped up");

   // volume_max lower than the computed raw lot -> clamp down, still succeed.
   RiskContext lowMax; BuildValidRiskContext(lowMax, "LOWMAX");
   lowMax.symbol_spec.volume_max = 0.5;
   lowMax.risk_context_hash = RiskContext_ComputeHash(lowMax);
   RiskPlan plan2;
   Check(Candidate_ToRiskPlan(c, lowMax, plan2), "a computed lot above volume_max still succeeds (clamped)");
   Check(plan2.lot_size == 0.5, "lot_size is clamped down to volume_max, not rejected");
}

//=====================================================================
// Part 6: determinism (10,000-iteration loop - cheap, pure in-memory function)
//=====================================================================
void Test_Determinism_10000Iterations()
{
   Print("--- determinism: 10,000 repeated calls, same candidate + same RiskContext ---");
   TradeCandidate c; BuildValidCandidate(c, "DETERM");
   RiskContext ctx; BuildValidRiskContext(ctx, "DETERM");

   RiskPlan first;
   Check(Candidate_ToRiskPlan(c, ctx, first), "sanity: first call succeeds");

   int mismatches = 0;
   for(int i = 0; i < 10000; i++)
   {
      RiskPlan plan;
      if(!Candidate_ToRiskPlan(c, ctx, plan)) { mismatches++; continue; }
      if(plan.risk_plan_id != first.risk_plan_id) mismatches++;
      else if(plan.plan_hash != first.plan_hash) mismatches++;
   }
   Check(mismatches == 0, "10,000 iterations: zero risk_plan_id/plan_hash mismatches");
}

//=====================================================================
// Part 7: input immutability (compiler-enforced via const&, verified explicitly)
//=====================================================================
void Test_InputsNotMutated()
{
   Print("--- candidate/ctx are not mutated by Candidate_ToRiskPlan ---");
   TradeCandidate c; BuildValidCandidate(c, "IMMUT");
   RiskContext ctx; BuildValidRiskContext(ctx, "IMMUT");

   string candidateIdBefore = c.candidate_id;
   double entryBefore = c.entry_hint, slBefore = c.sl_hint, tpBefore = c.tp_hint;
   double balanceBefore = ctx.account.balance;
   string ctxHashBefore = ctx.risk_context_hash;

   RiskPlan plan;
   Check(Candidate_ToRiskPlan(c, ctx, plan), "sanity: call succeeds");

   Check(c.candidate_id == candidateIdBefore, "candidate.candidate_id unchanged after the call");
   Check(c.entry_hint == entryBefore && c.sl_hint == slBefore && c.tp_hint == tpBefore,
         "candidate.entry_hint/sl_hint/tp_hint unchanged after the call");
   Check(ctx.account.balance == balanceBefore, "ctx.account.balance unchanged after the call");
   Check(ctx.risk_context_hash == ctxHashBefore, "ctx.risk_context_hash unchanged after the call");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B7 Commit 1 - RiskContext/RiskPlan/Candidate_ToRiskPlan ===");

   Test_SizingFormula_ExactNumbers();
   Test_RiskPlanId_IndependentOfContent();
   Test_RiskPlanId_ChangesWithSizingRulesVersion();
   Test_RiskContextHash_IncludedFieldsMoveHash();
   Test_RiskContextHash_ExcludedFieldsDoNotMoveHash();
   Test_PlanHash_IncludedFieldsMoveHash();
   Test_PlanHash_ExcludedFieldsDoNotMoveHash();
   Test_FailClosed_InvalidCandidate();
   Test_FailClosed_InvalidRiskContext();
   Test_FailClosed_BelowVolumeMin_ClampAtVolumeMax();
   Test_Determinism_10000Iterations();
   Test_InputsNotMutated();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
