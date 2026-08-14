//+------------------------------------------------------------------+
//| MLQuantAI - Strategies/MLQuantAI_CRT_V1_Contract.mqh              |
//| Phase B B5 Commit 2: the frozen CRT_V1 parameters, reason-mask bit |
//| layout, CRTDetectionResult (the detector's pure output shape),     |
//| and detector_hash - domain models and canonical utilities only.    |
//| NO detection rule logic here (no CRT_IsSweepLow/CRT_ConfirmMSS/    |
//| CRT_FindFVG/CRT_FindOrderBlock) - that's Commit 3+, in a separate   |
//| file that includes this one. See Docs/PhaseB_B5_CRTContract.md for |
//| the full reasoning behind every constant/field below - this file   |
//| is that contract's implementation, not a restatement of it.        |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CRT_V1_CONTRACT_MQH__
#define __MLQUANTAI_CRT_V1_CONTRACT_MQH__

#include "../Core/MLQuantAI_Ids.mqh"
#include "../Core/MLQuantAI_ContractVersions.mqh"

//---------------------------------------------------------------------
// Frozen parameters (contract sections 8/9) - conservative defaults
// chosen to unblock implementation. Changing any of these is a CRT_V2,
// never an in-place edit - candidate_id (via MLQUANTAI_CRT_V1_RULES_
// VERSION) is what actually namespaces "which rule version produced
// this", not these #defines by themselves.
//---------------------------------------------------------------------
#define MLQUANTAI_CRT_V1_LOOKBACK_BARS      64    // size of MarketContext.trigger_tf_recent[]
#define MLQUANTAI_CRT_V1_EXPIRY_AFTER_BARS  12    // TradeCandidate_ComputeExpiryTime's expiry_after_bars
#define MLQUANTAI_CRT_V1_MIN_FVG_GAP        0.0   // a qualifying FVG's gap must be strictly greater than this
#define MLQUANTAI_CRT_V1_TP_R_MULTIPLE      2.0   // tp_hint = entry_hint +/- this many R (see contract section 8)
#define MLQUANTAI_CRT_V1_ZONE_POLICY        "FVG_PRIORITY_THEN_OB_FALLBACK" // contract section 7A - NOT "dual evidence"

//---------------------------------------------------------------------
// trigger_reason_mask bit layout (contract section 2, ulong, frozen
// indices). Bits 0-5 always satisfy (bit0 XOR bit1) AND bit2 AND bit3
// AND (bit4 XOR bit5) on any TradeCandidate this module produces - see
// CRT_ReasonMaskFromBits() below for the actual construction, which
// enforces the same invariant at the type level (only one sweep
// direction, only one resolved zone kind can ever be passed in).
//---------------------------------------------------------------------
#define CRT_REASON_BIT_SWEEP_LOW          0x01 // swept a prior low (bullish precondition)
#define CRT_REASON_BIT_SWEEP_HIGH         0x02 // swept a prior high (bearish precondition)
#define CRT_REASON_BIT_CLOSE_BACK_INSIDE  0x04 // closed back inside the swept range
#define CRT_REASON_BIT_MSS_CONFIRMED      0x08 // market structure shift confirmed
#define CRT_REASON_BIT_FVG_FOUND          0x10 // a qualifying Fair Value Gap resolved the setup
#define CRT_REASON_BIT_OB_FOUND           0x20 // a qualifying Order Block resolved the setup
#define CRT_REASON_BIT_KILLZONE           0x40 // anchor bar fell inside a kill zone session window (informational only)
#define CRT_REASON_BIT_NEWS_RISK          0x80 // high-impact news was near the anchor bar (informational only)

// Frozen label vocabulary (contract section 3) - ascending bit-index
// order, one label per set bit only. Callers build trigger_reasons[] by
// scanning bits 0..7 in order and appending the label for each set bit;
// this function is the single source of truth for what each bit means
// in human-readable form, so that scan never needs its own copy of the
// vocabulary.
string CRT_ReasonBitLabel(int bitIndex)
{
   switch(bitIndex)
   {
      case 0: return "liquidity_sweep_low";
      case 1: return "liquidity_sweep_high";
      case 2: return "close_back_inside";
      case 3: return "mss_confirmed";
      case 4: return "fvg_found";
      case 5: return "order_block_found";
      case 6: return "in_killzone";
      case 7: return "news_risk_near";
   }
   return "unknown";
}

// Builds trigger_reasons[] from a reason_mask by scanning bits 0..7 in
// ascending order - the one place this scan happens, so every caller
// (CRT_ToTradeCandidate in Commit 4, tests) gets identically-ordered
// output.
void CRT_ReasonLabelsFromMask(ulong reasonMask, string &outLabels[])
{
   ArrayResize(outLabels, 0);
   for(int bit = 0; bit < 8; bit++)
   {
      ulong bitValue = (ulong)1 << bit;
      if((reasonMask & bitValue) != 0)
      {
         int n = ArraySize(outLabels);
         ArrayResize(outLabels, n + 1);
         outLabels[n] = CRT_ReasonBitLabel(bit);
      }
   }
}

//---------------------------------------------------------------------
// CRTDetectionResult (contract section 12) - the detector's pure output
// shape. detected == false means every other field is meaningless (no
// TradeCandidate is ever built from it) - see CRT_ToTradeCandidate in
// Commit 4.
//---------------------------------------------------------------------
struct CRTDetectionResult
{
   bool         detected;
   ENUM_ORDER_TYPE side;                   // meaningless if !detected

   double       swept_level;
   double       mss_confirmation_price;
   datetime     mss_confirmation_bar_time; // == setup_anchor_bar_time, contract section 0

   string       resolved_zone_kind;        // "FVG" | "OB" | "" if !detected
   double       resolved_zone_high;
   double       resolved_zone_low;

   ulong        reason_mask;
   string       reason_labels[];
   string       detector_hash;
};

void CRTDetectionResult_Init(CRTDetectionResult &r)
{
   r.detected = false;
   r.side = ORDER_TYPE_BUY; // meaningless until detected == true, same "0 means not ready" convention as TradeCandidate.side

   r.swept_level = 0;
   r.mss_confirmation_price = 0;
   r.mss_confirmation_bar_time = 0;

   r.resolved_zone_kind = "";
   r.resolved_zone_high = 0;
   r.resolved_zone_low = 0;

   r.reason_mask = 0;
   ArrayResize(r.reason_labels, 0);
   r.detector_hash = "";
}

// detector_hash (contract section 7): Ids_Sha256Hex over a frozen,
// |-joined field order. Distinct from candidate_id (namespaced by
// root_event_id + strategy version) and from context_hash (the whole
// MarketContext's identity) - this is "did the same detection inputs
// produce the same detector output", independent of both. Every price
// is formatted via DoubleToString(value, digits) - never a fixed
// literal decimal count - so this stays correct across instruments with
// different digit counts, not just XAUUSD.
//
// NOTE (contract section 7): this payload does not directly hash
// MLQUANTAI_CRT_V1_LOOKBACK_BARS/EXPIRY_AFTER_BARS/the FVG threshold/the
// zone policy - it only covers THIS detection's outputs. Validity across
// rule-version changes is candidate_id's job (via
// MLQUANTAI_CRT_V1_RULES_VERSION), not detector_hash's.
string CRT_DetectorHash(string instrumentId, string triggerTimeframe, datetime setupAnchorBarTime,
                         ENUM_ORDER_TYPE side, double sweptLevel, double mssConfirmationPrice,
                         datetime mssConfirmationBarTime, string resolvedZoneKind,
                         double resolvedZoneHigh, double resolvedZoneLow, ulong reasonMask, int digits)
{
   string payload = instrumentId + "|" +
                     triggerTimeframe + "|" +
                     TimeToString(setupAnchorBarTime, TIME_DATE|TIME_SECONDS) + "|" +
                     (side == ORDER_TYPE_BUY ? "BUY" : "SELL") + "|" +
                     DoubleToString(sweptLevel, digits) + "|" +
                     DoubleToString(mssConfirmationPrice, digits) + "|" +
                     TimeToString(mssConfirmationBarTime, TIME_DATE|TIME_SECONDS) + "|" +
                     resolvedZoneKind + "|" +
                     DoubleToString(resolvedZoneHigh, digits) + "|" +
                     DoubleToString(resolvedZoneLow, digits) + "|" +
                     IntegerToString((long)reasonMask);
   return Ids_Sha256Hex(payload);
}

#endif // __MLQUANTAI_CRT_V1_CONTRACT_MQH__
