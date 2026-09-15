//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_OutcomeLabelEngine.mqh                   |
//| RA-62 (QA-frozen Outcome Label Methodology V1): the pure,          |
//| deterministic TP/SL/timeout classification engine. Implements       |
//| exactly the algorithm QA froze - never computes anything itself     |
//| about WHERE its input bars come from, and never touches             |
//| CopyRates/iHigh/iLow/TimeCurrent/any broker or terminal call          |
//| anywhere in this file. Bars are supplied by the caller as a plain    |
//| MqlRates array - the SAME struct shape a real MT5 CopyRates() call   |
//| already produces, so this engine is equally usable fed real          |
//| terminal history, an external/offline fixed historical source        |
//| (the RA-62 frozen design's own "never live MT5 history as implicit   |
//| ground truth" requirement), or a synthetic fixture built directly    |
//| by a test - matching this project's established "pure fabricated-    |
//| input" testing convention (BrokerSubmission_ClassifyRetcode,          |
//| EntryCompatibility_PriceContextValid, etc.).                          |
//|                                                                       |
//| bars[] MUST be ordered oldest-first (bars[0] = the bar immediately    |
//| after entry, bars[N-1] = the furthest-forward bar available) and      |
//| MUST be a BID-series (the standard MT5 CopyRates() convention) -       |
//| see OutcomeLabelEngine_Classify's own header for the BUY/SELL price    |
//| basis this implies, per RA-62's frozen "ASK approximation, disclosed   |
//| V1 limitation" decision.                                               |
//|                                                                        |
//| Deterministic by construction: identical (side, plannedSl, plannedTp, |
//| bars[], barsCount, maxLookforwardBars, spreadApproximation) inputs     |
//| always produce a bit-identical OutcomeLabelResult - no TimeCurrent()/  |
//| MathRand()/any non-deterministic call anywhere in this file (RA-62     |
//| acceptance criterion 10).                                              |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_OUTCOMELABELENGINE_MQH__
#define __MLQUANTAI_OUTCOMELABELENGINE_MQH__

#include "MLQuantAI_OutcomeLabelPolicy.mqh"

enum ENUM_OUTCOME_LABEL
{
   OUTCOME_LABEL_NONE,     // never a real classification result - init default only
   OUTCOME_LABEL_TP_HIT,
   OUTCOME_LABEL_SL_HIT,
   OUTCOME_LABEL_TIMEOUT   // distinct third class - neither TP nor SL touched within the lookforward window
};

string OutcomeLabelToString(ENUM_OUTCOME_LABEL label)
{
   switch(label)
   {
      case OUTCOME_LABEL_TP_HIT:  return "TP_HIT";
      case OUTCOME_LABEL_SL_HIT:  return "SL_HIT";
      case OUTCOME_LABEL_TIMEOUT: return "TIMEOUT";
   }
   return "NONE";
}

struct OutcomeLabelResult
{
   ENUM_OUTCOME_LABEL label;
   bool     same_bar_tiebreak_applied; // true iff this exact bar's range touched BOTH tp and sl - resolved SL-first per RA-62's frozen tie-break rule
   int      resolution_bar_index;       // index into bars[] where resolution occurred; -1 for OUTCOME_LABEL_TIMEOUT
   datetime resolution_time;            // bars[resolution_bar_index].time; 0 for OUTCOME_LABEL_TIMEOUT
   int      bars_scanned;               // how many bars were actually examined (<= maxLookforwardBars, <= barsCount)
};

void OutcomeLabelResult_Init(OutcomeLabelResult &r)
{
   r.label = OUTCOME_LABEL_NONE;
   r.same_bar_tiebreak_applied = false;
   r.resolution_bar_index = -1;
   r.resolution_time = 0;
   r.bars_scanned = 0;
}

// Fail-closed input validation - mirrors every other B5-B9 builder's
// own "" == success, reason string == failure convention.
string OutcomeLabelEngine_ValidateInput(ENUM_ORDER_TYPE side, double plannedSl, double plannedTp,
                                          int barsCount, int maxLookforwardBars, double spreadApproximation)
{
   if(side != ORDER_TYPE_BUY && side != ORDER_TYPE_SELL) return "side is not a real market side (BUY/SELL)";
   if(!MathIsValidNumber(plannedSl) || !MathIsValidNumber(plannedTp)) return "plannedSl/plannedTp contains NaN or Inf";
   if(plannedSl <= 0.0 || plannedTp <= 0.0) return "plannedSl/plannedTp is not positive";
   if(barsCount < 0) return "barsCount is negative";
   if(maxLookforwardBars <= 0) return "maxLookforwardBars must be positive";
   if(spreadApproximation < 0.0) return "spreadApproximation must not be negative";
   return "";
}

// The RA-62 frozen entry point. Scans bars[] from index 0 (the bar
// immediately after entry) forward, at most min(barsCount,
// maxLookforwardBars) bars, per this exact, frozen algorithm:
//
//   BUY:  tp touched if bar.high >= plannedTp; sl touched if bar.low <= plannedSl
//   SELL: tp touched if bar.low - spreadApproximation <= plannedTp;
//         sl touched if bar.high + spreadApproximation >= plannedSl
//         (RA-62 frozen V1 disclosed limitation: bars[] is a BID-series,
//         same convention every real MT5 CopyRates() call already uses in
//         this project; a SELL position's own SL/TP triggers are truly
//         evaluated against the broker's live ASK side, which bid-series
//         history does not carry - spreadApproximation is the caller-
//         supplied, explicitly-disclosed approximation for that gap, never
//         silently assumed to be 0.0 unless the caller genuinely passes 0.0)
//
// Same-bar collision (both tp and sl touched within one bar's own
// high/low range): RA-62 frozen tie-break - SL-first, unconditionally,
// with same_bar_tiebreak_applied set true on the result so this can
// never be silently read as a "certain loss" without the flag.
//
// Returns false only on a structural input failure (see
// OutcomeLabelEngine_ValidateInput) - outResult left at
// OutcomeLabelResult_Init() defaults in that case, no partial output.
bool OutcomeLabelEngine_Classify(ENUM_ORDER_TYPE side, double plannedSl, double plannedTp,
                                   const MqlRates &bars[], int barsCount, int maxLookforwardBars,
                                   double spreadApproximation, OutcomeLabelResult &outResult, string &outErrorReason)
{
   OutcomeLabelResult_Init(outResult);
   outErrorReason = OutcomeLabelEngine_ValidateInput(side, plannedSl, plannedTp, barsCount, maxLookforwardBars, spreadApproximation);
   if(outErrorReason != "") return false;

   int scanLimit = MathMin(barsCount, maxLookforwardBars);

   for(int i = 0; i < scanLimit; i++)
   {
      bool tpTouched, slTouched;
      if(side == ORDER_TYPE_BUY)
      {
         tpTouched = bars[i].high >= plannedTp;
         slTouched = bars[i].low  <= plannedSl;
      }
      else // ORDER_TYPE_SELL
      {
         tpTouched = (bars[i].low  - spreadApproximation) <= plannedTp;
         slTouched = (bars[i].high + spreadApproximation) >= plannedSl;
      }

      if(tpTouched && slTouched)
      {
         outResult.label = OUTCOME_LABEL_SL_HIT; // RA-62 frozen tie-break: SL-first
         outResult.same_bar_tiebreak_applied = true;
         outResult.resolution_bar_index = i;
         outResult.resolution_time = bars[i].time;
         outResult.bars_scanned = i + 1;
         return true;
      }
      if(slTouched)
      {
         outResult.label = OUTCOME_LABEL_SL_HIT;
         outResult.resolution_bar_index = i;
         outResult.resolution_time = bars[i].time;
         outResult.bars_scanned = i + 1;
         return true;
      }
      if(tpTouched)
      {
         outResult.label = OUTCOME_LABEL_TP_HIT;
         outResult.resolution_bar_index = i;
         outResult.resolution_time = bars[i].time;
         outResult.bars_scanned = i + 1;
         return true;
      }
   }

   // Exhausted the scan window without a touch - TIMEOUT, a distinct
   // third class, never a directional guess.
   outResult.label = OUTCOME_LABEL_TIMEOUT;
   outResult.bars_scanned = scanLimit;
   return true;
}

#endif // __MLQUANTAI_OUTCOMELABELENGINE_MQH__
