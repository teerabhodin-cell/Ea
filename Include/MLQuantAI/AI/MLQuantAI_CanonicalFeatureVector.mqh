//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_CanonicalFeatureVector.mqh                 |
//| Phase B8.4 Commit 1 (Tier A): CanonicalFeatureVector_FromSnapshot -  |
//| converts a FeatureSnapshot into the frozen 12-element float[]        |
//| tensor layout, per Docs/PhaseB_B8_4_InferenceContract.md. Field      |
//| order is IDENTICAL to B8.1's own sealed                              |
//| FeatureSnapshot_VectorHashPayload order - reused, not reinvented.    |
//| No implicit missing-value fill, no reordering, no normalization -    |
//| the schema defines none, so none is applied here.                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CANONICALFEATUREVECTOR_MQH__
#define __MLQUANTAI_CANONICALFEATUREVECTOR_MQH__

#include "MLQuantAI_InferenceContract.mqh"
#include "../Market/MLQuantAI_FeatureSnapshot.mqh"

bool CanonicalFeatureVector_FromSnapshot(const FeatureSnapshot &snapshot, string requestedFeatureSchemaVersion,
                                           float &outVector[], ENUM_INFERENCE_FAIL_REASON &outReasonCode, string &outReasonDetail)
{
   ArrayResize(outVector, 0);
   outReasonCode = INFERENCE_FAIL_NONE;
   outReasonDetail = "";

   // Today the only recognized feature schema is FEATURES_B8_1_V1 -
   // any other requested value is rejected, since no other layout is
   // frozen yet (see MLQUANTAI_FEATURE_SCHEMA_B8_1_V1).
   if(requestedFeatureSchemaVersion != MLQUANTAI_FEATURE_SCHEMA_B8_1_V1 ||
      snapshot.feature_schema_version != requestedFeatureSchemaVersion)
   {
      outReasonCode = INPUT_SCHEMA_MISMATCH;
      outReasonDetail = "requested feature_schema_version is not FEATURES_B8_1_V1, or does not match the snapshot's own";
      return false;
   }

   if(!MathIsValidNumber(snapshot.atr_m15) || !MathIsValidNumber(snapshot.adx_m15) ||
      !MathIsValidNumber(snapshot.ema_slope_m15) || !MathIsValidNumber(snapshot.pdh) ||
      !MathIsValidNumber(snapshot.pdl) || !MathIsValidNumber(snapshot.asian_range_high) ||
      !MathIsValidNumber(snapshot.asian_range_low) || !MathIsValidNumber(snapshot.spread_points_at_anchor))
   {
      outReasonCode = INPUT_NONFINITE;
      outReasonDetail = "one or more source feature fields is NaN or Inf";
      return false;
   }

   ArrayResize(outVector, MLQUANTAI_INFERENCE_INPUT_LENGTH_B8_1_V1);
   outVector[0]  = (float)snapshot.atr_m15;
   outVector[1]  = (float)snapshot.adx_m15;
   outVector[2]  = (float)snapshot.ema_slope_m15;
   outVector[3]  = (float)snapshot.pdh;
   outVector[4]  = (float)snapshot.pdl;
   outVector[5]  = (float)snapshot.asian_range_high;
   outVector[6]  = (float)snapshot.asian_range_low;
   outVector[7]  = (float)snapshot.spread_points_at_anchor;
   outVector[8]  = (float)(double)snapshot.news_count;
   outVector[9]  = (float)(double)snapshot.max_news_impact;
   outVector[10] = (float)(double)snapshot.nearest_news_minutes;
   outVector[11] = snapshot.is_kill_zone ? 1.0f : 0.0f;

   return true;
}

#endif // __MLQUANTAI_CANONICALFEATUREVECTOR_MQH__
