//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_CanonicalFormat.mqh                   |
//| Phase B7: fixed-precision numeric formatting for hash payloads    |
//| only - display formatting is a separate concern and must never    |
//| share these helpers. Every double that participates in            |
//| RiskContext_HashPayload/RiskPlan_HashPayload goes through exactly |
//| one of these three, never a raw DoubleToString call with a        |
//| caller-supplied digit count, and never Digits()/_Digits (those     |
//| read the ACTIVE CHART's symbol at call time, not a value carried   |
//| on the object being hashed - see Docs/PhaseB_B7_RiskPlanContract.md|
//| section 2, the hard rule this file exists to enforce).             |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CANONICALFORMAT_MQH__
#define __MLQUANTAI_CANONICALFORMAT_MQH__

// Price-like values (entry/sl/tp/tick_size) - same fixed literal
// precision context_hash's own price fields already use
// (MarketContext_HashPayload's DoubleToString(x, 5) calls).
string CanonicalPrice(double x)
{
   return DoubleToString(x, 5);
}

// Generic amount/ratio/lot_size - deliberately more precision than any
// real lot step needs (a volume_step as fine as 0.001, or finer, never
// loses precision here).
string CanonicalDouble(double x)
{
   return DoubleToString(x, 8);
}

// Percent-like values (risk_percent/target_risk_percent).
string CanonicalPercent(double x)
{
   return DoubleToString(x, 4);
}

#endif // __MLQUANTAI_CANONICALFORMAT_MQH__
