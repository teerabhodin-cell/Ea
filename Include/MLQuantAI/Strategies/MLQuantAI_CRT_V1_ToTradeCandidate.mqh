//+------------------------------------------------------------------+
//| MLQuantAI - Strategies/MLQuantAI_CRT_V1_ToTradeCandidate.mqh      |
//| Phase B B5 Commit 4: CRT_ToTradeCandidate(ctx, result, out) - the |
//| pure mapping from a CRTDetectionResult (Commit 3's detector       |
//| output) to a TradeCandidate (Core/MLQuantAI_TradeCandidate.mqh),  |
//| per Docs/PhaseB_B5_CRTContract.md section 12's I/O schema and the |
//| Commit 4 boundary spec (copy/map only - never recompute detector  |
//| truth; returns false and leaves out at Init() defaults on         |
//| result.detected == false; no Event Store write, no state-machine  |
//| call, no CANDIDATE_CREATED event - that's Commit 5).              |
//|                                                                    |
//| Still no risk/execution/AI code - this function only ever fills   |
//| fields already on the frozen TradeCandidate struct, from values   |
//| already computed by ctx/result. It calls no CopyRates/iTime/      |
//| broker API of its own.                                            |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CRT_V1_TO_TRADE_CANDIDATE_MQH__
#define __MLQUANTAI_CRT_V1_TO_TRADE_CANDIDATE_MQH__

#include "MLQuantAI_CRT_V1_Rules.mqh"
#include "../Core/MLQuantAI_TradeCandidate.mqh"

// candidate_hash (Commit 4, new - distinct from candidate_id, context_hash,
// and detector_hash): a canonical hash over THIS candidate's own
// deterministic, detection-derived content, computed AFTER every other
// field below is filled - same "hash the finished object" convention
// MarketContext_ComputeHash already uses. Deliberately excludes:
//  - every B6/B7-owned mutable field (score/confidence/compatible_regime/
//    regime_rules_version/state/last_reason/correlation_id/
//    parent_candidate_ids/entry/sl/tp/rr/atr/stop_distance) - none of
//    them exist yet at candidate-creation time.
//  - account/spread/broker runtime state - never touched by this
//    function at all.
//  - signal_time/expiry_time - both are pure derivations of
//    setup_anchor_bar_time + expiry_after_bars + trigger_timeframe,
//    already covered by hashing those inputs directly; hashing the
//    derived values too would be redundant, not additional signal
//    (same reasoning MarketContext_HashPayload uses to skip
//    news_count/max_news_impact/nearest_news_minutes in favor of
//    news_decision_hash alone).
string CRT_CandidateHashPayload(const TradeCandidate &c, int digits)
{
   return c.candidate_id + "|" +
          c.root_event_id + "|" +
          IntegerToString(c.strategy_id) + "|" + c.strategy_name + "|" + c.strategy_version + "|" +
          (c.side == ORDER_TYPE_BUY ? "BUY" : "SELL") + "|" +
          c.context_event_id + "|" + c.context_hash + "|" +
          TimeToString(c.setup_anchor_bar_time, TIME_DATE|TIME_SECONDS) + "|" +
          IntegerToString(c.expiry_after_bars) + "|" +
          DoubleToString(c.entry_hint, digits) + "|" +
          DoubleToString(c.sl_hint, digits) + "|" +
          DoubleToString(c.tp_hint, digits) + "|" +
          IntegerToString((long)c.trigger_reason_mask) + "|" +
          c.detector_hash + "|" +
          c.candidate_schema_version;
}

string CRT_CandidateHash(const TradeCandidate &c, int digits)
{
   return Ids_Sha256Hex(CRT_CandidateHashPayload(c, digits));
}

// Contract section 12's fill list, field-for-field: side, direction,
// root_event_id, candidate_id, context_event_id, context_hash,
// setup_anchor_bar_time, expiry_after_bars, entry_hint/sl_hint/tp_hint,
// trigger_reason_mask, trigger_reasons[], strategy_id/name/version,
// candidate_schema_version, has_liquidity_sweep/has_mss/has_fvg/
// has_order_block (mapped straight from the reason bits). Leaves at
// TradeCandidate_Init() defaults exactly as the contract says: score,
// confidence, compatible_regime, regime_rules_version, state
// (CANDIDATE_CREATED), last_reason (REASON_NONE), entry/sl/tp/rr/atr/
// stop_distance (risk-adjusted values are B6/B7's job, per the
// contract's own Non-goals section), correlation_id/parent_candidate_ids
// (set later, at submission/arbitration time).
//
// Fields the contract's explicit list didn't name but this function
// fills anyway, each independently justified (not new scope - every
// value was already computed by result, this just doesn't throw it away):
//  - detector_hash: copied verbatim from result.detector_hash - the
//    Commit 4 boundary's hard invariant (candidate.detector_hash ==
//    crt.detector_hash), never recomputed here.
//  - candidate_hash: this candidate's own new canonical hash (see
//    CRT_CandidateHash above), computed last.
//  - in_killzone/news_risk: mapped straight from reason bits 6/7, the
//    exact same "mapped straight from the reason bits" rule the
//    contract already applies to has_liquidity_sweep/has_mss/has_fvg/
//    has_order_block (bits 0-5).
//  - signal_time: set to setup_anchor_bar_time - the closed-bar-only
//    discipline this whole project runs on (never TimeCurrent()) applies
//    here exactly as it does everywhere else a timestamp is assigned.
//  - expiry_time: computed via the existing, sealed
//    TradeCandidate_ComputeExpiryTime() - the field's OWN doc comment
//    in Core/MLQuantAI_TradeCandidate.mqh already mandates exactly this
//    ("recompute it from setup_anchor_bar_time + expiry_after_bars"),
//    so leaving it at Init()'s 0 would violate that field's existing
//    contract, not just be incomplete.
//
// Returns false (and leaves out at TradeCandidate_Init() defaults) if
// result.detected == false - a non-detection is silence, not a rejected
// candidate (contract's own wording, end of section 12). Returns true
// with out fully populated otherwise. No Event Store write, no
// StateMachine_Transition call, no CANDIDATE_CREATED event either way -
// that's Commit 5.
bool CRT_ToTradeCandidate(const MarketContext &ctx, const CRTDetectionResult &result, TradeCandidate &out)
{
   TradeCandidate_Init(out);
   if(!result.detected) return false;

   out.side      = result.side;
   out.direction = (result.side == ORDER_TYPE_BUY) ? SIGNAL_BUY : SIGNAL_SELL;

   string eventType = (result.side == ORDER_TYPE_BUY) ? "CRT_SWEEP_LOW" : "CRT_SWEEP_HIGH";
   out.root_event_id = Ids_RootEventId(ctx.instrument_id, ctx.trigger_timeframe, eventType,
                                        result.swept_level, result.mss_confirmation_bar_time,
                                        ctx.symbol_spec.digits);

   out.strategy_id      = STRAT_CRT;
   out.strategy_name    = StrategyIdToString(STRAT_CRT);
   out.strategy_version = MLQUANTAI_CRT_V1_RULES_VERSION;

   out.candidate_id = Ids_CandidateId(out.root_event_id, out.strategy_name, out.strategy_version);

   out.candidate_schema_version = MLQUANTAI_CANDIDATE_SCHEMA_V1;

   out.context_event_id = ctx.context_event_id;
   out.context_hash      = ctx.context_hash;

   out.setup_anchor_bar_time = result.mss_confirmation_bar_time; // contract section 0: setup_anchor_bar_time := mss_confirmation_bar_time
   out.expiry_after_bars     = MLQUANTAI_CRT_V1_EXPIRY_AFTER_BARS;

   // entry/sl/tp hint derivation - contract section 8's frozen formulas,
   // pure functions of already-computed CRT_V1 values and ctx.symbol_spec.
   // Stop reference is ALWAYS crt.swept_level, never resolved_zone_low/
   // high - moving it would be a CRT_V2 semantic change, not this commit's.
   out.entry_hint = (result.resolved_zone_low + result.resolved_zone_high) * 0.5;
   double point = ctx.symbol_spec.point;
   if(result.side == ORDER_TYPE_BUY)
   {
      out.sl_hint = result.swept_level - point;
      out.tp_hint = out.entry_hint + MLQUANTAI_CRT_V1_TP_R_MULTIPLE * (out.entry_hint - out.sl_hint);
   }
   else
   {
      out.sl_hint = result.swept_level + point;
      out.tp_hint = out.entry_hint - MLQUANTAI_CRT_V1_TP_R_MULTIPLE * (out.sl_hint - out.entry_hint);
   }

   out.trigger_reason_mask = result.reason_mask;
   ArrayResize(out.trigger_reasons, ArraySize(result.reason_labels));
   for(int i = 0; i < ArraySize(result.reason_labels); i++)
      out.trigger_reasons[i] = result.reason_labels[i];

   out.has_liquidity_sweep = (result.reason_mask & (CRT_REASON_BIT_SWEEP_LOW | CRT_REASON_BIT_SWEEP_HIGH)) != 0;
   out.has_mss             = (result.reason_mask & CRT_REASON_BIT_MSS_CONFIRMED) != 0;
   out.has_fvg              = (result.reason_mask & CRT_REASON_BIT_FVG_FOUND) != 0;
   out.has_order_block      = (result.reason_mask & CRT_REASON_BIT_OB_FOUND) != 0;
   out.in_killzone           = (result.reason_mask & CRT_REASON_BIT_KILLZONE) != 0;
   out.news_risk             = (result.reason_mask & CRT_REASON_BIT_NEWS_RISK) != 0;

   out.signal_time = out.setup_anchor_bar_time;
   out.expiry_time = TradeCandidate_ComputeExpiryTime(out.setup_anchor_bar_time, out.expiry_after_bars,
                                                        CRT_TimeframeTagToPeriod(ctx.trigger_timeframe));

   out.detector_hash = result.detector_hash; // copied verbatim - never recomputed

   out.candidate_hash = CRT_CandidateHash(out, ctx.symbol_spec.digits); // computed LAST, over the finished candidate

   return true;
}

#endif // __MLQUANTAI_CRT_V1_TO_TRADE_CANDIDATE_MQH__
