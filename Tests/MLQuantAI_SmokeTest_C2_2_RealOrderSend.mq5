//+------------------------------------------------------------------+
//| MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5                         |
//| Phase C2.2 - MANUAL, EXPLICITLY OPT-IN ONLY. NOT part of the        |
//| automated regression suite (Tests/MLQuantAI_Test_C2_2_             |
//| BrokerSubmissionGate.mq5) and NEVER run by that suite or by any     |
//| CI/automated process.                                                |
//|                                                                       |
//| *** THIS SCRIPT CALLS THE REAL BrokerSubmission_Submit() / OrderSend |
//| *** AND, IF THE PRE-SUBMIT GATE ACCEPTS, WILL SEND A REAL ORDER TO   |
//| *** WHATEVER ACCOUNT THIS TERMINAL IS CURRENTLY LOGGED INTO.         |
//|                                                                       |
//| The pre-submit gate (BrokerSubmissionGate_Evaluate) independently    |
//| fails closed unless the account is a real ACCOUNT_TRADE_MODE_DEMO    |
//| account AND ExecutionPolicy.environment_mode == EXECUTION_ENV_DEMO - |
//| but this script adds its own separate check and an explicit          |
//| confirmation input BEFORE even attempting, as a second, independent  |
//| layer, never relying on the gate alone.                              |
//|                                                                       |
//| The fixture candidate this script builds derives its planned_sl/     |
//| planned_tp from a synthetic CRT-detection fixture, re-based near     |
//| real XAUUSD price levels (RA-06) with a ~$100.10 stop distance,      |
//| decoupled from entry_hint's own live-price offset (RA-25 - see       |
//| SMOKE_FIXTURE_BASE_PRICE's own comment; RA-22's Fixture Validity     |
//| Report explains why the original ~$1.10 distance, and RA-23's own    |
//| first attempt at widening it, couldn't survive real ceremony timing).|
//| A real OrderSend call may still be broker-rejected                   |
//| (TRADE_RETCODE_INVALID_STOPS/_INVALID_FILL or                        |
//| similar), which remains a SAFE,                                      |
//| EXPECTED, and still fully informative outcome: it proves the real    |
//| gate -> OrderSend -> classify -> event/lifecycle wiring works end-   |
//| to-end without meaningfully risking an actual filled position. If    |
//| the broker DOES accept it (TRADE_RETCODE_DONE/_DONE_PARTIAL), a REAL |
//| POSITION WILL BE OPEN - C2 has no scope to close it. The user must   |
//| close it manually in the terminal.                                   |
//|                                                                       |
//| C2 manual-approval contract, gate integration round (per               |
//| Docs/PhaseC_C2_ManualApprovalContract.md's "A real wiring gap found    |
//| while implementing this round"): BrokerSubmission_Submit() now calls  |
//| BrokerSubmissionEnvironmentLock_Evaluate(), which includes the new     |
//| manual-approval check. This script's fabricated, freshly-generated     |
//| execution_request_id can never have a real, human-granted approval     |
//| for it (that would require a human running                             |
//| MLQuantAI_ManualScript_GrantApproval.mq5 with this exact run's own      |
//| identity fields BEFORE this script executes, which no automated or      |
//| interactive single-script run can do) - so this script is now EXPECTED |
//| to reject at the audit/manual-approval gate (REASON_EXECUTION_AUDIT_    |
//| NOT_READY or REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED) before ever  |
//| reaching OrderSend, same "safe, expected, still informative" category   |
//| as a broker-side rejection.                                             |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

input bool I_Understand_This_May_Open_A_Real_Position = false; // must be set true to run - script aborts otherwise
input double CeremonyReferencePrice = 0.0; // C6.6-RA-06: 0.0 = capture current SYMBOL_BID now and print it as this run's frozen ceremony reference; >0 = reuse the EXACT value printed by an earlier run, unmodified/unrounded, so this run's identity chain matches that earlier run's - required for Manual Approval to ever match a later submission attempt
input double I_ExpectedEABindingNonce = 0.0; // RA-29.1 (QA-frozen contract): copy the EXACT nonce MLQuantAI.mq5 just printed at its own OnInit ("RA-29.1 binding published: ... nonce=...") for the EA instance you intend to observe this ceremony's broker transaction. 0.0 = ABORT (no ceremony may run without proving EA/Script EventStore binding first).

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_ToTradeCandidate.mqh>
#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskSizing.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshotBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_FeatureSnapshotEventEmission.mqh>
#include <MLQuantAI/AI/MLQuantAI_ModelArtifactBuilder.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_ModelArtifactEventEmission.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionBuilder.mqh>
#include <MLQuantAI/AI/MLQuantAI_AIDecisionEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EligibilityEventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_RiskPlanEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestBuilder.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionRequestEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAdapter.mqh>

// C6.6-RA-03 F1 (QA-authorized, ceremony tooling only): the fixture below
// was originally hardcoded at a ~100-104 price scale, unrelated to any
// real _Symbol's actual tradeable price - so a real OrderSend was
// guaranteed-rejected (TRADE_RETCODE_INVALID_STOPS), which can never
// produce a real TRADE_TRANSACTION_DEAL_ADD for the C6.6 empirical
// ceremony to observe. SMOKE_FIXTURE_BASE_PRICE is the ORIGINAL fixture's
// own reference point (the filler bars' own close price, unchanged since
// this script's first version) - every hardcoded fixture price below is
// defined relative to it. BuildAcceptedRequest() computes
// delta = referencePrice - SMOKE_FIXTURE_BASE_PRICE once, and every
// fixture price is shifted by that same delta - a pure additive
// translation that preserves every relative distance in the original CRT
// pattern exactly, so CRT_DetectV1's own detection logic (untouched) sees
// the identical shape, just re-based onto a real, tradeable price level.
// C6.6-RA-06 (QA-authorized): referencePrice is no longer always live
// SYMBOL_BID - see CeremonyReferencePrice's own comment and the RA-06
// block inside BuildAcceptedRequest() for why a live-per-run price broke
// Manual Approval identity matching across two separate ceremony runs.
//
// RA-23 amendment (superseded by RA-25 below - kept for history): RA-21's
// real ceremony runs proved the ORIGINAL geometry (planned_stop_distance
// ~= $1.101) is empirically unusable. RA-23's fix scaled EVERY literal by
// a single fixed factor of 91 around SMOKE_FIXTURE_BASE_PRICE - which
// widened planned_stop_distance to ~$100.10 as intended, but ALSO widened
// the entry_hint-to-live-price offset by the same factor (from ~$3.90 to
// ~$354.90), since a uniform scale around one pivot preserves ratios. RA-24's
// real ceremony proved this: risk_divergence_pct stayed ~350-360%, nearly
// unchanged from before RA-23, because offset/stop_distance is a ratio
// that uniform scaling never changes.
//
// RA-25 amendment (QA-authorized, this file only): decouples the two
// quantities instead of scaling them together. entry_hint is determined
// SOLELY by bar[59].high/bar[61].low (the FVG zone,
// CRT_V1_ToTradeCandidate.mqh's zoneMid formula) - every bar below is back
// to its ORIGINAL, pre-RA-23 literal value, so entry_hint's offset from
// the live ceremony reference price is the original ~$3.90, unchanged.
// planned_stop_distance is controlled independently via ctx.pdl alone
// (CRT_V1_ToTradeCandidate.mqh: sl_hint = swept_level(=ctx.pdl) - point) -
// see BuildBaseContext's own comment for the exact derivation. Neither pdl
// nor bar[59].low is tuned to any live quote read while writing this file -
// pdl is solved algebraically from entry_hint (itself untouched) and the
// target stop distance (100.101, the same target RA-23 already verified
// produces a valid RiskSizing lot/risk_amount); bar[59].low is pdl minus
// the ORIGINAL fixture's own sweep-depth-below-level (100.00-99.50=0.50),
// unscaled, reused unchanged so the sweep candle's own shape/semantics
// (not just its trigger condition) matches the original design's intent -
// not an arbitrary "make it sweep" value.
//
// RA-25 envelope algebra (QA-required correction: BID/ASK quote semantics,
// not a bare "drift" term). CeremonyReferencePrice captures live BID at
// Phase 3 (BID0); a BUY's execution_reference_price at Phase 4.6/Gate time
// is live ASK (ASK1, per C2.4's own BUY=ASK/SELL=BID rule) - these are two
// DIFFERENT quotes, not the same one at two times:
//   entry_hint            = BID0 - 3.90                         (fixed at Phase 3)
//   realized_stop_distance = ASK1 - planned_sl
//   planned_stop_distance  = entry_hint - planned_sl = 100.101
//   realized - planned     = ASK1 - entry_hint
//                           = (ASK1 - BID1) + (BID1 - BID0) + 3.90
//                           = spread1 + drift_bid + 3.90
// where spread1 is the live ask-bid spread at Phase 4.6 time (empirically
// ~$0.18-0.20 for this account's XAUUSD from every Market Watch reading
// taken this session) and drift_bid is the real BID move between Phase 3
// and Phase 4.6. PASS requires |spread1 + drift_bid + 3.90| <= 10.0101,
// i.e. drift_bid in roughly [-14.1, +5.9] after folding in spread1's own
// small, empirically-bounded size - comfortably wider than any single
// real drift this ceremony has measured in its fastest completed windows
// (order of a few dollars over 60-120s), without relying on a calm market
// moment, and without conflating BID and ASK into one quote.
#define SMOKE_FIXTURE_BASE_PRICE 105.00

void MakeBar(MqlRates &r, datetime t, double open, double high, double low, double close, long tickVolume, int spread)
{
   ZeroMemory(r);
   r.time = t; r.open = open; r.high = high; r.low = low; r.close = close;
   r.tick_volume = tickVolume; r.spread = spread;
}

#define PERIOD_SEC_M5 300

void BuildBaseContext(MarketContext &ctx, double delta)
{
   MarketContext_Init(ctx);
   ctx.instrument_id      = "XAUUSD";
   ctx.broker_symbol      = "XAUUSD";
   ctx.trigger_timeframe  = "M5";
   // F1: real digits/point for whatever _Symbol this ceremony run is
   // attached to, instead of a hardcoded assumption - reduces the chance
   // of an unrelated precision mismatch masking the real fill/no-fill
   // result this ceremony needs to observe.
   ctx.symbol_spec.digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   ctx.symbol_spec.point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   // RA-25: swept_level (CRT_V1_Rules.mqh resolves this to ctx.pdl for a
   // bullish setup) is what sl_hint = swept_level - point is anchored to -
   // this is the ONE value that controls planned_stop_distance, entirely
   // independent of entry_hint (which comes from the FVG zone in the bars
   // below, all back to their original literals - see this file's own
   // SMOKE_FIXTURE_BASE_PRICE comment for the full RA-25 derivation).
   // Solved algebraically: entry_hint=101.100 (unchanged), target
   // stop_distance=100.101 (RA-23's already-verified target) =>
   // pdl = entry_hint - stop_distance + point = 101.100 - 100.101 + 0.001
   //     = 1.000. bar[59]'s low (below) is set to pdl - 0.50 so it still
   // sweeps below this new pdl - 0.50 is the ORIGINAL fixture's own
   // unscaled sweep-depth-below-level (100.00 - 99.50), reused as-is.
   // ctx.pdh is back to its original 110.00 - still far above every bar's
   // (unscaled) high, so no accidental bearish-side sweep.
   ctx.pdl = 1.000 + delta;
   ctx.pdh = 110.00 + delta;
   ctx.is_kill_zone = false;
   ctx.max_news_impact = 0;
   ctx.nearest_news_minutes = 9999;
   ctx.atr_m15 = 1.2345; // a volatility magnitude, not a price level - never shifted by delta
   ctx.adx_m15 = 25.5;
   ctx.ema_slope_m15 = 0.05;
   ctx.asian_range_high = 105.50 + delta;
   ctx.asian_range_low  = 104.50 + delta;
   ctx.spread_points_at_anchor = 20.0;
   ctx.news_count = 3;
   ctx.context_event_id = "CTX_smoke_c22";
   ctx.context_hash      = "test_context_hash_smoke_c22";
}

// RA-25: back to the ORIGINAL, pre-RA-23 literals unchanged - these filler
// bars play no role in entry_hint (that's bar[59]/bar[61] only) or in
// planned_stop_distance (that's ctx.pdl alone), so there is no reason to
// touch them at all under RA-25's decoupled design.
void FillFillerBars(MqlRates &window[], datetime t0, double delta)
{
   for(int i = 0; i < 59; i++)
      MakeBar(window[i], t0 + i * PERIOD_SEC_M5, 105.00+delta, 105.20+delta, 104.80+delta, 105.00+delta, 100, 20);
}

// F1: identical bar-by-bar CRT shape as the original fixture - every
// open/high/low/close below is the ORIGINAL hardcoded literal plus the
// same single delta, so every relative distance (sweep depth, rally
// size, wick lengths) is bitwise-preserved. CRT_DetectV1 itself is
// unmodified and untouched by this file.
//
// RA-25: every bar here is back to its ORIGINAL, pre-RA-23 literal value
// EXCEPT bar[59]'s low, which is the only field this amendment touches.
// bar[59].high and bar[61].low (unchanged) are exactly what entry_hint =
// zoneMid(bar[59].high, bar[61].low) uses, so entry_hint stays at its
// original 101.100 - the same ~$3.90 offset from the live ceremony
// reference price as before RA-23. bar[59].low alone moves from 99.50 to
// 0.500 = ctx.pdl(1.000, see BuildBaseContext) minus the ORIGINAL fixture's
// own 0.50 sweep-depth-below-level, unscaled - just deep enough to still
// sweep below the new pdl, using the original design's own margin rather
// than an arbitrary value invented to force this run to pass. Every other
// CRT_V1_Rules.mqh check (close-back-inside, MSS structure level, FVG gap,
// zone-vs-swept-level consistency) reads bar[59].high/close and bars 60-62,
// none of which changed, so they hold exactly as before - verified by real
// run, see this amendment's own evidence trail.
void Fixture_Bullish_Valid(MqlRates &window[], datetime &outAnchor, datetime t0, double delta)
{
   ArrayResize(window, 64);
   FillFillerBars(window, t0, delta);
   MakeBar(window[59], t0 + 59 * PERIOD_SEC_M5, 100.80+delta, 100.90+delta,   0.500+delta, 100.50+delta, 100, 20);
   MakeBar(window[60], t0 + 60 * PERIOD_SEC_M5, 100.50+delta, 101.50+delta, 100.40+delta, 101.40+delta, 100, 20);
   MakeBar(window[61], t0 + 61 * PERIOD_SEC_M5, 101.40+delta, 102.50+delta, 101.30+delta, 102.40+delta, 100, 20);
   MakeBar(window[62], t0 + 62 * PERIOD_SEC_M5, 102.40+delta, 103.50+delta, 102.30+delta, 103.40+delta, 100, 20);
   MakeBar(window[63], t0 + 63 * PERIOD_SEC_M5, 103.40+delta, 104.60+delta, 103.30+delta, 104.50+delta, 100, 20);
   outAnchor = window[63].time;
}

void BuildValidRiskContext(RiskContext &ctx)
{
   RiskContext_Init(ctx);
   ctx.symbol_spec.instrument_id = "XAUUSD";
   ctx.symbol_spec.broker_symbol = "XAUUSD_smoke";
   ctx.symbol_spec.tick_size     = 0.01;
   ctx.symbol_spec.tick_value    = 1.0;
   ctx.symbol_spec.contract_size = 100;
   ctx.symbol_spec.volume_min    = 0.01;
   ctx.symbol_spec.volume_max    = 100.0;
   ctx.symbol_spec.volume_step   = 0.01;
   ctx.symbol_spec.digits        = 2;

   ctx.account.balance = 10000.0;
   ctx.account.equity  = 10000.0;

   // RA-23: raised from 1.0 to 5.0 alongside the fixture-geometry widening
   // above (planned_stop_distance ~$1.101 -> ~$100.10) - unchanged by RA-25,
   // since RA-25 reuses the exact same planned_stop_distance target (only
   // decoupling it from entry_hint's live-price offset, not its magnitude)
   // - a deliberate,
   // still-plausible single-trade risk-context constant, chosen
   // independently of any live quote, purely so RiskSizing's own unmodified
   // formula (Candidate_ToRiskPlan, Step 5-7) keeps producing a lot_size
   // safely clear of symbol_spec.volume_min (0.01) for the wider stop
   // distance, instead of flooring to (or below) the minimum. risk_amount
   // = 10000*0.05 = 500, still well under ExecutionPolicy.
   // max_planned_risk_amount (1000.0, unchanged below) and unconsulted by
   // EligibilityDecision_Build (which only reads eligContext.account.*,
   // all hardcoded to a safe zero-state a few lines below in OnStart -
   // never this field).
   ctx.target_risk_percent  = 5.0;
   ctx.sizing_method        = "FIXED_PERCENT_RISK";
   ctx.sizing_rules_version = MLQUANTAI_RISK_SIZING_RULES_V1;

   ctx.risk_context_hash = RiskContext_ComputeHash(ctx);
}

bool BuildAcceptedRequest(TradeCandidate &c, ExecutionRequest &req, ExecutionPolicy &policy)
{
   // F1 (QA-authorized, C6.6-RA-03): re-base the entire fixture price
   // geometry onto the real current price of _Symbol, so the resulting
   // planned_entry/sl/tp have a real chance of broker acceptance instead
   // of the original hardcoded ~100-104 scale, which was guaranteed to
   // reject and could never produce the real TRADE_TRANSACTION_DEAL_ADD
   // the C6.6 empirical ceremony needs. Single delta computed once here,
   // threaded through every fixture price call below - see
   // SMOKE_FIXTURE_BASE_PRICE's own comment for the full rationale.
   // C6.6-RA-06 (QA-authorized, ceremony tooling only): the live SYMBOL_BID
   // read below is a RUNTIME OBSERVATION only, printed for the operator's
   // own situational awareness (e.g. cross-checking Phase 4.5 broker
   // constraints against the current market) - it is NEVER used as the
   // fixture's price anchor anymore. The anchor is CeremonyReferencePrice:
   // on a first run (input left at 0.0) this run's own live bid is
   // captured once and printed as the frozen reference for a LATER run to
   // paste back in; on a later run (input > 0) that exact value is reused
   // verbatim, unrounded, as the anchor - never re-derived from whatever
   // the market is doing right now. This is what makes two separate
   // script executions produce the IDENTICAL candidate_hash/
   // execution_request_id/execution_request_hash, so a Manual Approval
   // granted against a first run's printed identity can still match a
   // later run's submission attempt. No identity/hash algorithm changed -
   // only which price value feeds the same, unmodified fixture geometry.
   double liveBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double referencePrice = (CeremonyReferencePrice > 0.0) ? CeremonyReferencePrice : liveBid;
   double delta = referencePrice - SMOKE_FIXTURE_BASE_PRICE;

   Print("RA-06 runtime observation (NOT the identity anchor): _Symbol=", _Symbol,
         " current live SYMBOL_BID=", DoubleToString(liveBid, 8));

   if(CeremonyReferencePrice > 0.0)
      Print("RA-06 ceremony reference: REUSING CeremonyReferencePrice input = ", DoubleToString(CeremonyReferencePrice, 8),
            " (unmodified, unrounded) - this run's identity chain should match the run that originally printed this value.");
   else
      Print("RA-06 ceremony reference: CeremonyReferencePrice input was 0.0 - CAPTURED this run's own live bid as the frozen "
            "reference = ", DoubleToString(referencePrice, 8), " . To reproduce the SAME identity chain in a later run "
            "(e.g. after Manual Approval), set input CeremonyReferencePrice to EXACTLY this printed value, unrounded.");

   Print("F1 fixture re-base: SMOKE_FIXTURE_BASE_PRICE=", DoubleToString(SMOKE_FIXTURE_BASE_PRICE, 2),
         " ceremony reference used for delta=", DoubleToString(referencePrice, 8),
         " delta=", DoubleToString(delta, 8));

   MarketContext ctx;
   BuildBaseContext(ctx, delta);
   datetime t0 = D'2026.03.01 00:00:00';
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0, delta);
   ctx.anchor_bar_time = anchor;

   // C6.6-RA-05 (QA-authorized, ceremony tooling only): durable upstream
   // lineage. Mirrors the proven pattern from
   // Tests/MLQuantAI_Test_C3_3_TransactionMatchingProjection.mq5's own
   // BuildDurableSubmittedRequest() - C1.3's ExecutionAuditProjection
   // orphan-check (staged by BrokerSubmissionAuditProjection/
   // ManualApprovalProjection as a black-box gate) requires every
   // upstream layer durably present in this exact event store, not just
   // the final EXECUTION_REQUEST_CREATED (RA-04 alone was not enough).
   // No _Emit*/EventStore/C3.x/ManualApproval/EnvironmentLock/
   // BrokerSubmission_Submit() implementation is touched - every call
   // below is the same, unmodified, already-sealed emitter every other
   // C1/C2 test file already uses, fed this run's own real lineage
   // values (never fabricated IDs).
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx)))
   {
      Print("ABORTED (RA-05): failed to log MARKET_CONTEXT_READY");
      return false;
   }

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) { Print("smoke: CRT fixture did not detect - aborting"); return false; }
   if(!CRT_ToTradeCandidate(ctx, r, c)) { Print("smoke: CRT_ToTradeCandidate failed - aborting"); return false; }
   if(!CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits))
   {
      Print("ABORTED (RA-05): failed to log CANDIDATE_CREATED");
      return false;
   }

   FeatureSnapshot snapshot;
   if(!Candidate_ToFeatureSnapshot(c, ctx, snapshot)) return false;
   if(!FeatureSnapshot_EmitFeatureSnapshotCreated(snapshot))
   {
      Print("ABORTED (RA-05): failed to log FEATURE_SNAPSHOT_CREATED");
      return false;
   }

   ModelArtifact artifact;
   if(!ModelArtifact_Build("MODEL_smoke", "v1", "hash_artifact_smoke",
                             "FEATURES_B8_1_V1", "TDSET_dummy_smoke", "hash_tdset_smoke",
                             "SETUP_QUALITY_V1", "INPUT_SCHEMA_V1", "OUTPUT_SCHEMA_V1",
                             "ONNXRuntime", "1.16.0", MODEL_PROMOTION_PROMOTED, artifact))
      return false;
   if(!ModelArtifact_EmitModelArtifactRegistered(artifact))
   {
      Print("ABORTED (RA-05): failed to log MODEL_ARTIFACT_REGISTERED");
      return false;
   }

   InferenceResult inference;
   InferenceResult_Init(inference);
   inference.model_registry_id   = artifact.model_registry_id;
   inference.model_registry_hash = artifact.model_registry_hash;
   inference.model_artifact_hash = artifact.model_artifact_hash;
   inference.feature_snapshot_id   = snapshot.feature_snapshot_id;
   inference.feature_snapshot_hash = snapshot.feature_snapshot_hash;
   inference.feature_vector_hash   = snapshot.feature_vector_hash;
   inference.output_schema_version = MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1;
   ArrayResize(inference.output_values, 1);
   inference.output_values[0] = 0.90f;
   inference.runtime_framework = "ONNXRuntime";
   inference.runtime_version   = "1.16.0";
   inference.output_hash = InferenceResult_ComputeOutputHash(inference);

   AIDecisionPolicy aiPolicy;
   AIDecisionPolicy_Init(aiPolicy);
   aiPolicy.decision_policy_version = "AIPOLICY_C1_V1";
   aiPolicy.threshold_version       = "THRESH_C1_V1";
   aiPolicy.allow_threshold         = 0.70;
   AIDecision decision; string aiReasonDetail;
   if(!AIDecision_Build(inference, snapshot, aiPolicy, decision, aiReasonDetail)) return false;
   if(!AIDecision_EmitAIDecisionCreated(decision))
   {
      Print("ABORTED (RA-05): failed to log AI_DECISION_CREATED");
      return false;
   }

   RiskContext riskCtx; BuildValidRiskContext(riskCtx);
   RiskPlan plan;
   if(!Candidate_ToRiskPlan(c, riskCtx, plan)) return false;
   if(!RiskPlan_EmitRiskPlanCreated(plan))
   {
      Print("ABORTED (RA-05): failed to log RISK_PLAN_CREATED");
      return false;
   }

   EligibilityContext eligContext;
   EligibilityContext_Init(eligContext);
   eligContext.account.balance = 10000.0;
   eligContext.account.equity = 10000.0;
   eligContext.account.margin_level = 500.0;
   eligContext.account.open_positions_count = 0;
   eligContext.account.open_risk_percent = 0.0;
   eligContext.account.daily_pnl_percent = 0.0;
   eligContext.account.drawdown_from_peak_percent = 0.0;
   eligContext.safe_mode_active = false;
   eligContext.eligibility_context_hash = EligibilityContext_ComputeHash(eligContext);

   EligibilityPolicy eligPolicy;
   EligibilityPolicy_Init(eligPolicy);
   eligPolicy.eligibility_policy_version = "ELIGPOLICY_C1_V1";
   eligPolicy.max_daily_loss_percent = 5.0;
   eligPolicy.max_drawdown_percent = 10.0;
   eligPolicy.max_total_exposure_percent = 20.0;
   eligPolicy.max_open_positions = 5;
   eligPolicy.min_margin_level = 200.0;

   EligibilityDecision eligDecision; string eligReasonDetail;
   if(!EligibilityDecision_Build(plan, decision, snapshot, eligContext, eligPolicy, eligDecision, eligReasonDetail))
      return false;
   if(eligDecision.decision != ELIGIBILITY_DECISION_ELIGIBLE)
   {
      Print("smoke: EligibilityDecision was not ELIGIBLE (", eligReasonDetail, ") - aborting");
      return false;
   }
   if(!EligibilityDecision_EmitDecisionAndWireLifecycle(eligDecision, eligContext, c))
   {
      Print("ABORTED (RA-05): failed to log eligibility decision / lifecycle wiring");
      return false;
   }

   ExecutionPolicy_Init(policy);
   policy.execution_policy_version = "EXECPOLICY_C2_SMOKE_V1";
   policy.environment_mode = EXECUTION_ENV_DEMO;
   policy.dry_run = true;
   policy.manual_approval_required = false;
   policy.account_allowlist = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   policy.symbol_allowlist = _Symbol;
   policy.max_volume = 10.0;
   policy.max_planned_risk_amount = 1000.0;
   policy.max_deviation_points = 20.0;

   string rd;
   if(!ExecutionRequest_Build(c, eligDecision, decision, plan, policy, req, rd))
   {
      Print("ABORTED: ExecutionRequest_Build failed - ", rd);
      return false;
   }

   // RA-05 lineage diagnostic (QA-authorized): every durable ID this
   // chain produced, for cross-reference against the event store after
   // the run.
   Print("RA-05 durable lineage: candidate_id=", c.candidate_id,
         " feature_snapshot_id=", snapshot.feature_snapshot_id,
         " model_registry_id=", artifact.model_registry_id,
         " risk_plan_id=", plan.risk_plan_id,
         " eligibility_decision=", EligibilityDecisionToString(eligDecision.decision));

   return true;
}

void OnStart()
{
   Print("=== MLQuantAI C2.2 REAL-SUBMIT SMOKE TEST ===");
   Print("*** This script can send a REAL order via OrderSend() to whatever account this terminal is logged into. ***");

   if(!I_Understand_This_May_Open_A_Real_Position)
   {
      Print("ABORTED: set input I_Understand_This_May_Open_A_Real_Position = true to run this script.");
      return;
   }

   long tradeMode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   Print("Account login: ", login, "  ACCOUNT_TRADE_MODE: ", EnumToString((ENUM_ACCOUNT_TRADE_MODE)tradeMode));
   if(tradeMode != ACCOUNT_TRADE_MODE_DEMO)
   {
      Print("ABORTED (script-level check): this account is not ACCOUNT_TRADE_MODE_DEMO. "
            "BrokerSubmissionGate_Evaluate would fail-closed here too, but this script refuses even earlier.");
      return;
   }

   // RA-29.1 (QA-frozen contract): Ceremony EventStore Binding Integrity
   // preflight. Must run before EventStore_Open() below and before any
   // Candidate/lineage is built - a mismatch here means this script and
   // whatever EA is (or isn't) attached are not provably looking at the
   // same file, which is exactly the gap RA-28 exposed (L1/L2 landed in
   // this script's file while the real L3 landed in the EA's own,
   // different file). canonicalFile is deliberately the same literal this
   // script has always hardcoded (see the C6.6-RA-05 comment just below) -
   // RA-29.1 does not introduce a filename override, it only proves the
   // EA is bound to this exact, already-fixed name.
   string canonicalFile = "MLQuantAI_SmokeTest_C2_2.jsonl";
   string ra29BindingName = "MLQuantAI_EABinding__" + canonicalFile;
   if(I_ExpectedEABindingNonce <= 0.0)
   {
      Print("ABORTED (RA-29.1 preflight): I_ExpectedEABindingNonce not provided (<=0.0). "
            "Read the EA's own Experts log line 'RA-29.1 binding published: ... nonce=...' for file=",
            canonicalFile, " and copy that exact value into this input before running.");
      return;
   }
   if(!GlobalVariableCheck(ra29BindingName))
   {
      Print("ABORTED (RA-29.1 preflight): no EA binding found for '", ra29BindingName, "' - "
            "no EA instance currently has ", canonicalFile, " open (not attached, or attached to a different file).");
      return;
   }
   double ra29ActualNonce = GlobalVariableGet(ra29BindingName);
   if(ra29ActualNonce != I_ExpectedEABindingNonce)
   {
      Print("ABORTED (RA-29.1 preflight): binding nonce mismatch for '", ra29BindingName, "' - expected=",
            DoubleToString(I_ExpectedEABindingNonce, 0), " actual=", DoubleToString(ra29ActualNonce, 0),
            " (stale binding from a previous/different EA instance, or wrong value copied).");
      return;
   }
   Print("RA-29.1 preflight PASS: EA binding for ", canonicalFile, " matches nonce=", DoubleToString(ra29ActualNonce, 0));

   // C6.6-RA-05 (QA-authorized, ceremony tooling only): EventStore must be
   // OPEN before BuildAcceptedRequest() runs, since that function now
   // durably emits the full upstream lineage chain (RA-05) itself -
   // moved ahead of the fixture-build call below (was previously opened
   // AFTER, back when BuildAcceptedRequest() was still pure/in-memory-only).
   string file = canonicalFile;
   EventStore_Open(file);

   TradeCandidate candidate;
   ExecutionRequest req;
   ExecutionPolicy policy;
   if(!BuildAcceptedRequest(candidate, req, policy))
   {
      Print("ABORTED: could not build a valid ExecutionRequest fixture - see prior Print lines.");
      EventStore_Close();
      return;
   }

   // C6.6-RA-04 (QA-authorized, ceremony tooling only): durably emit the
   // execution request BEFORE any registry rebuild or Manual Approval
   // bootstrap. Without this, ExecutionRequest_Build() above only ever
   // produced an in-memory struct - no EXECUTION_REQUEST_CREATED/
   // EXECUTION_DRY_RUN_COMPLETED line ever reached this event store, so
   // ManualApprovalProjection_ApplyLineWithLineage()'s own orphan-check
   // (ExecutionRequestProjection_TryGet()) could never find this
   // execution_request_id - any grant for it was structurally doomed to
   // reject as "orphan" no matter how many times it was retried. Calls
   // the same, unmodified, already-sealed ExecutionRequest_EmitAndEvaluate()
   // every other C1/C2 test file already uses (e.g.
   // Tests/MLQuantAI_Test_C3_3_TransactionMatchingProjection.mq5's own
   // BuildDurableSubmittedRequest()) - no change to that function, to
   // ManualApprovalProjection/Registry, EnvironmentLock, BrokerSubmission_
   // Submit(), or any C3.x file. Per QA's explicit stop condition: if this
   // does not durably complete with SAFETY_GATE_ACCEPTED, abort here -
   // never proceed toward Manual Approval on an unproven request.
   DryRunExecutionResult dryRunResult;
   bool emitOk = ExecutionRequest_EmitAndEvaluate(req, policy, dryRunResult);
   Print("RA-04 durable execution-request emission: EmitAndEvaluate durability=", (emitOk ? "true" : "false"),
         " dry-run decision=", SafetyGateDecisionToString(dryRunResult.decision),
         " reason_code=", ReasonCodeToString(dryRunResult.reason_code));
   if(!emitOk || dryRunResult.decision != SAFETY_GATE_ACCEPTED)
   {
      Print("ABORTED (RA-04 stop condition): ExecutionRequest_EmitAndEvaluate did not durably complete with "
            "SAFETY_GATE_ACCEPTED - stopping before Manual Approval bootstrap. No registry rebuild, no "
            "BrokerSubmission_Submit() attempt this run.");
      EventStore_Close();
      return;
   }

   // Realistic startup sequence, same calls MLQuantAI.mq5's own OnInit
   // makes - both registries default fail-closed, so without these
   // calls the gate would always reject on readiness alone, never
   // reaching the checks below.
   BrokerSubmissionAuditProjectionReport auditReport = BrokerSubmissionAudit_StartupRebuild(file);
   ManualApprovalProjectionReport approvalReport = ManualApproval_StartupRebuild(file);
   Print("Startup rebuild: submission-audit ready=", BrokerSubmissionAuditReadiness_IsReady(),
         " (", auditReport.first_error, "); manual-approval ready=", ManualApprovalReadiness_IsReady(),
         " (", approvalReport.first_error, ")");

   EnvironmentLockPolicy lockPolicy;
   EnvironmentLockPolicy_Init(lockPolicy);
   lockPolicy.environment_lock_policy_version = "ENVLOCK_C2_SMOKE_V1";
   lockPolicy.trade_server_allowlist = AccountInfoString(ACCOUNT_SERVER);

   // Diagnostic-only addition (C4.4 checkpoint, scenario 10 bootstrap):
   // these identity fields are fully deterministic across repeated runs
   // of this script (BuildAcceptedRequest uses a fixed t0 = D'2026.03.01
   // 00:00:00', never TimeCurrent()), and are exactly what
   // MLQuantAI_ManualScript_GrantApproval.mq5 requires as its
   // I_ExecutionRequestId/I_ExecutionRequestHash/I_CandidateId inputs -
   // printed here because a gate rejection at
   // REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED writes nothing durable
   // for an operator to read them back from afterward. Does not change
   // any existing behavior, event, or return value of this script.
   // F2 (QA-authorized, C6.6-RA-03): correlation_id is the 5th field the
   // frozen 5-field Manual Approval identity binding requires
   // (Docs/PhaseC_C2_ManualApprovalContract.md) - it was missing from this
   // diagnostic line before, leaving a ceremony operator with no way to
   // complete a correctly-bound MLQuantAI_ManualScript_GrantApproval.mq5
   // run. Deterministic like every other field printed here (Ids_
   // CorrelationId(candidate_id, submit_attempt) - a pure function, no
   // TimeCurrent() involved), so printing it changes no behavior.
   Print("DIAGNOSTIC (for MLQuantAI_ManualScript_GrantApproval.mq5 inputs): candidate_id=", candidate.candidate_id,
         " execution_request_id=", req.execution_request_id,
         " execution_request_hash=", req.execution_request_hash,
         " execution_policy_version=", policy.execution_policy_version,
         " correlation_id=", req.correlation_id);

   Print("Submitting real order: symbol=", _Symbol, " side=", (req.side == ORDER_TYPE_BUY ? "BUY" : "SELL"),
         " lot=", DoubleToString(req.lot_size, 2), " correlation_id=", req.correlation_id);
   Print("NOTE (RA-25): planned_sl/planned_tp come from a synthetic fixture with a fixed ~$100.10 stop distance, "
         "entry_hint kept at its original ~$3.90 offset from the live ceremony reference price (decoupled from the "
         "stop distance - RA-23's own first attempt scaled both together and stayed empirically unusable, see "
         "RA-22's Fixture Validity Report). A broker rejection (e.g. TRADE_RETCODE_INVALID_STOPS/_INVALID_FILL) is "
         "still a safe outcome if it happens, but is no longer the only realistically-expected one. A gate "
         "rejection at REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED is ALSO an expected, safe outcome - see this "
         "file's own header.");

   ExecutionSubmissionResult result;
   bool ran = BrokerSubmission_Submit(candidate, req, policy, lockPolicy, result);

   EventStore_Close();

   Print("BrokerSubmission_Submit durability return: ", (ran ? "true (every event write succeeded)" : "false (see prior Print/[FAIL]-style lines)"));
   Print("submission_status: ", SubmissionStatusToString(result.submission_status));
   Print("order_send_returned: ", result.order_send_returned, "  terminal_last_error: ", result.terminal_last_error);
   Print("retcode: ", result.retcode, "  retcode_external: ", result.retcode_external);
   Print("order_ticket: ", result.order_ticket, "  deal_ticket: ", result.deal_ticket);
   Print("requested_price: ", DoubleToString(result.requested_price, 5), "  observed_submit_price: ", DoubleToString(result.observed_submit_price, 5));
   Print("reason_code: ", ReasonCodeToString(result.reason_code));
   Print("candidate.state after submit: ", CandidateStateToString(candidate.state));

   if(result.submission_status == SUBMISSION_STATUS_SUBMITTED)
      Print("*** A REAL POSITION MAY NOW BE OPEN (order_ticket=", result.order_ticket, "). "
            "C2 has no close-position scope - close it manually in the terminal. ***");

   Print("Full event trail written to (Common Files): ", file);
   Print("=== smoke test complete ===");
}
