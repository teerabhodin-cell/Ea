//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_MarginGuard.mqh                   |
//| RA-49 (QA-frozen Pre-Order Broker Constraint & Margin Gate         |
//| Design): BrokerSubmissionMarginGuard_Evaluate() - a proactive,     |
//| pre-OrderSend margin-sufficiency check. RA-48 found the pipeline   |
//| had NO proactive margin guard anywhere - the only protection was   |
//| reactive (TRADE_RETCODE_NO_MONEY -> REASON_INSUFFICIENT_MARGIN,    |
//| classified AFTER a real OrderSend() call already happened).        |
//|                                                                      |
//| Pure evaluation only: OrderCalcMargin() is a read-only calculation  |
//| API - it does not place, modify, or check-through an order at the   |
//| broker, and does not require any trade permission. No OrderSend/    |
//| CTrade/position-mutating call anywhere in this file. Adds no new    |
//| execution authority.                                                 |
//|                                                                      |
//| Per QA's frozen required condition 2: uses the EXACT same symbol,    |
//| direction (request.side), volume (request.lot_size), and price      |
//| (the caller-supplied executionReferencePrice - the SAME bound price |
//| EntryCompatibilityGate captured and that will be submitted verbatim  |
//| via MLQuantAI_BrokerSubmissionBuilder.mqh, per C2.4 AC-10) that the  |
//| real order will use. Never re-reads the market independently, never |
//| normalizes/rounds request.lot_size - a margin shortfall rejects,    |
//| it never silently resizes the position (same reject-only discipline |
//| MLQuantAI_EnvironmentLockGate.mqh's volume_max/volume_step checks    |
//| already follow).                                                     |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MARGINGUARD_MQH__
#define __MLQUANTAI_MARGINGUARD_MQH__

#include "MLQuantAI_ExecutionRequestContract.mqh"
#include "../Logging/MLQuantAI_SystemLogger.mqh"

// Returns true (outRejectReason stays REASON_NONE) iff the account has
// enough free margin, per a fresh OrderCalcMargin() call, for exactly
// this request's side/volume at exactly executionReferencePrice.
//
// Two distinct rejection causes, per QA's frozen requirement that the
// log make them distinguishable even though both currently map to
// existing reason codes:
//  - OrderCalcMargin() itself returns false (margin could not be
//    calculated at all - e.g. a transient symbol/quote issue) ->
//    REASON_ERROR_INTERNAL, with an explicit LogWarn naming this a
//    margin-CALCULATION failure - never silently indistinguishable from
//    every other REASON_ERROR_INTERNAL case elsewhere in this codebase.
//  - OrderCalcMargin() succeeds but marginRequired exceeds the real,
//    live ACCOUNT_MARGIN_FREE -> REASON_INSUFFICIENT_MARGIN, the same
//    reason code BrokerSubmission_ClassifyRetcode already uses for the
//    reactive TRADE_RETCODE_NO_MONEY case - genuinely the same failure
//    class, just caught proactively instead of only after a real
//    OrderSend() call.
bool BrokerSubmissionMarginGuard_Evaluate(const ExecutionRequest &request, double executionReferencePrice,
                                            ENUM_REASON_CODE &outRejectReason)
{
   outRejectReason = REASON_NONE;

   double marginRequired = 0.0;
   if(!OrderCalcMargin(request.side, _Symbol, request.lot_size, executionReferencePrice, marginRequired))
   {
      outRejectReason = REASON_ERROR_INTERNAL;
      LogWarn(StringFormat("RA-49 MarginGuard: OrderCalcMargin() itself failed (a margin-CALCULATION failure, "
                            "NOT an insufficient-margin verdict) for execution_request_id=%s side=%s volume=%s price=%s",
                            request.execution_request_id, EnumToString(request.side),
                            DoubleToString(request.lot_size, 2), DoubleToString(executionReferencePrice, _Digits)));
      return false;
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(marginRequired > freeMargin)
   {
      outRejectReason = REASON_INSUFFICIENT_MARGIN;
      return false;
   }

   return true;
}

#endif // __MLQUANTAI_MARGINGUARD_MQH__
