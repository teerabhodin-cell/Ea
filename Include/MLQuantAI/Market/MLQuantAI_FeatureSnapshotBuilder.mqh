//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_FeatureSnapshotBuilder.mqh           |
//| Phase B8.1: Candidate_ToFeatureSnapshot() - the pure, deterministic|
//| copy/identity/hash function frozen in                              |
//| Docs/PhaseB_B8_1_FeatureSnapshotContract.md section 4. Copies      |
//| already-computed MarketContext feature fields verbatim - never     |
//| recomputes an indicator, never touches TimeCurrent()/iATR/iADX/    |
//| iMA or any other broker/history/tick call, never appends an event, |
//| never mutates its inputs. No real feature engineering happens here|
//| - every value already exists on ctx; this file only establishes   |
//| identity/lineage/hash over what B1-B5 already computed.            |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_FEATURESNAPSHOTBUILDER_MQH__
#define __MLQUANTAI_FEATURESNAPSHOTBUILDER_MQH__

#include "MLQuantAI_FeatureSnapshot.mqh"
#include "MLQuantAI_MarketContext.mqh"
#include "../Core/MLQuantAI_TradeCandidate.mqh"

// Fail-closed input validation - contract section 4 step 1. Returns ""
// on success, a reason string on failure, mirroring
// RiskSizing_ValidateInput's own shape (one caller-visible outcome: a
// filled FeatureSnapshot or nothing at all).
string FeatureSnapshotBuilder_ValidateInput(const TradeCandidate &candidate, const MarketContext &ctx)
{
   if(candidate.candidate_id == "") return "empty candidate_id";
   if(candidate.state != CANDIDATE_CREATED) return "candidate.state is not CANDIDATE_CREATED";

   if(candidate.context_event_id != ctx.context_event_id)
      return "candidate.context_event_id does not match the supplied MarketContext - wrong context passed in";
   if(candidate.context_hash != ctx.context_hash)
      return "candidate.context_hash does not match the supplied MarketContext - tamper/mismatch";

   if(!MathIsValidNumber(ctx.atr_m15) || !MathIsValidNumber(ctx.adx_m15) || !MathIsValidNumber(ctx.ema_slope_m15))
      return "atr_m15/adx_m15/ema_slope_m15 contains NaN or Inf";
   if(!MathIsValidNumber(ctx.pdh) || !MathIsValidNumber(ctx.pdl))
      return "pdh/pdl contains NaN or Inf";
   if(!MathIsValidNumber(ctx.asian_range_high) || !MathIsValidNumber(ctx.asian_range_low))
      return "asian_range_high/asian_range_low contains NaN or Inf";
   if(!MathIsValidNumber(ctx.spread_points_at_anchor))
      return "spread_points_at_anchor contains NaN or Inf";

   return "";
}

// The B8.1 entry point. Returns true with outSnapshot fully filled
// (both the Phase B1 and Phase B8.1 field groups) only on success.
// Returns false, with outSnapshot left at FeatureSnapshot_Init()
// defaults, on any fail-closed condition - no partial output, matching
// every other B5/B6/B7 mapping function's own rule.
bool Candidate_ToFeatureSnapshot(const TradeCandidate &candidate, const MarketContext &ctx, FeatureSnapshot &outSnapshot)
{
   FeatureSnapshot_Init(outSnapshot);

   if(FeatureSnapshotBuilder_ValidateInput(candidate, ctx) != "")
      return false;

   // Step 2: copy the 12 Phase B1 feature fields verbatim from ctx -
   // no recomputation, no live read.
   outSnapshot.atr_m15 = ctx.atr_m15;
   outSnapshot.adx_m15 = ctx.adx_m15;
   outSnapshot.ema_slope_m15 = ctx.ema_slope_m15;
   outSnapshot.pdh = ctx.pdh;
   outSnapshot.pdl = ctx.pdl;
   outSnapshot.asian_range_high = ctx.asian_range_high;
   outSnapshot.asian_range_low = ctx.asian_range_low;
   outSnapshot.spread_points_at_anchor = ctx.spread_points_at_anchor;
   outSnapshot.news_count = ctx.news_count;
   outSnapshot.max_news_impact = ctx.max_news_impact;
   outSnapshot.nearest_news_minutes = ctx.nearest_news_minutes;
   outSnapshot.is_kill_zone = ctx.is_kill_zone;

   // Step 3: context_event_id verbatim; feature_schema_version
   // deliberately overwritten with the B8.1-specific constant, NOT
   // FeatureSnapshot_Init()'s generic default - see
   // Docs/PhaseB_B8_1_FeatureSnapshotContract.md's schema-version
   // section for why.
   outSnapshot.context_event_id = ctx.context_event_id;
   outSnapshot.feature_schema_version = MLQUANTAI_FEATURE_SCHEMA_B8_1_V1;

   // Step 4: lineage, all copied verbatim, never recomputed.
   outSnapshot.candidate_id  = candidate.candidate_id;
   outSnapshot.candidate_hash = candidate.candidate_hash;
   outSnapshot.context_hash   = candidate.context_hash;
   outSnapshot.detector_hash  = candidate.detector_hash;

   // Step 5: identity.
   outSnapshot.feature_snapshot_id = Ids_FeatureSnapshotId(candidate.candidate_id);

   // Step 6: feature_vector_hash first (pure content), then
   // feature_snapshot_hash (full record, depends on feature_vector_hash).
   outSnapshot.feature_vector_hash = FeatureSnapshot_ComputeVectorHash(outSnapshot);
   outSnapshot.feature_snapshot_hash = FeatureSnapshot_ComputeHash(outSnapshot);

   return true;
}

#endif // __MLQUANTAI_FEATURESNAPSHOTBUILDER_MQH__
