//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_InferenceOutputValidator.mqh               |
//| Phase B8.4 Commit 1 (Tier A): InferenceOutput_Validate() - checks   |
//| a typed output vector is a well-formed member of its declared       |
//| output schema, per Docs/PhaseB_B8_4_InferenceContract.md. No        |
//| threshold/decision interpretation - a valid p_success of 0.03 and   |
//| one of 0.97 are equally "valid," this function only proves the       |
//| number is well-formed, never that it means ALLOW or REJECT.          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_INFERENCEOUTPUTVALIDATOR_MQH__
#define __MLQUANTAI_INFERENCEOUTPUTVALIDATOR_MQH__

#include "MLQuantAI_InferenceContract.mqh"

// Exactly one output schema is frozen in this commit, as a concrete,
// testable proof of the contract shape - additional schemas are
// additive in later commits, never a redefinition of this one.
bool InferenceOutput_Validate(const float &outputValues[], string outputSchemaVersion,
                                ENUM_INFERENCE_FAIL_REASON &outReasonCode, string &outReasonDetail)
{
   outReasonCode = INFERENCE_FAIL_NONE;
   outReasonDetail = "";

   if(outputSchemaVersion != MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1)
   {
      outReasonCode = OUTPUT_SCHEMA_MISMATCH;
      outReasonDetail = "unrecognized output_schema_version";
      return false;
   }

   // OUTPUT_P_SUCCESS_V1: length 1, range [0.0, 1.0] inclusive.
   if(ArraySize(outputValues) != 1)
   {
      outReasonCode = OUTPUT_SHAPE_MISMATCH;
      outReasonDetail = "OUTPUT_P_SUCCESS_V1 requires exactly 1 value";
      return false;
   }

   if(!MathIsValidNumber((double)outputValues[0]))
   {
      outReasonCode = OUTPUT_NONFINITE;
      outReasonDetail = "output value is NaN or Inf";
      return false;
   }

   if(outputValues[0] < 0.0f || outputValues[0] > 1.0f)
   {
      outReasonCode = OUTPUT_RANGE_INVALID;
      outReasonDetail = "OUTPUT_P_SUCCESS_V1 requires a value in [0.0, 1.0]";
      return false;
   }

   return true;
}

#endif // __MLQUANTAI_INFERENCEOUTPUTVALIDATOR_MQH__
