//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_AIResult.mqh                          |
//| Output of the AI Meta-Filter. Fields default to "no opinion"     |
//| (-1 / allow=true) so a disabled or not-yet-loaded AI filter is    |
//| transparent to the pipeline - rule-based candidates keep working |
//| without it, unlike QuantixFlowEA where the AI was the only        |
//| signal source. Per the spec, the AI can only allow/reject/scale  |
//| risk - it must never flip direction or override a hard risk/news |
//| block; that's enforced in the risk manager and execution engine, |
//| not here, but this struct intentionally has no field that would  |
//| let the AI change direction/SL/TP.                                |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_AIRESULT_MQH__
#define __MLQUANTAI_AIRESULT_MQH__

struct AIResult
{
   bool     allow;
   double   p_success;         // -1 = no model / no opinion
   double   regime_confidence; // -1 = no model / no opinion
   double   uncertainty;       // -1 = no model / no opinion
   double   risk_multiplier;   // 1.0 = no adjustment
};

void AIResult_Init(AIResult &a)
{
   a.allow = true;
   a.p_success = -1;
   a.regime_confidence = -1;
   a.uncertainty = -1;
   a.risk_multiplier = 1.0;
}

#endif // __MLQUANTAI_AIRESULT_MQH__
