//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BrokerSubmissionBuilder.mqh      |
//| Phase C2.2: pure, unit-testable logic only - NO OrderSend call    |
//| anywhere in this file. BrokerSubmission_BuildTradeRequest()       |
//| constructs the MqlTradeRequest per the frozen "Order construction"|
//| section of Docs/PhaseC_C2_1_BrokerSubmissionContract.md.          |
//| BrokerSubmission_ClassifyRetcode() implements the frozen           |
//| accepted-vs-explicit-rejection split from that same doc's          |
//| lifecycle diagram. Both take their market/account inputs as        |
//| ordinary parameters or read-only terminal queries (SymbolInfoDouble|
//| is a read, never a mutation), so both can be exercised by the      |
//| automated regression suite with zero risk of opening a real        |
//| position.                                                          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BROKERSUBMISSIONBUILDER_MQH__
#define __MLQUANTAI_BROKERSUBMISSIONBUILDER_MQH__

#include "MLQuantAI_ExecutionRequestContract.mqh"
#include "../Core/MLQuantAI_VersionRegistry.mqh"
#include "../Core/MLQuantAI_ReasonCodes.mqh"

// MqlTradeRequest contains string members (symbol/comment) - MQL5's
// string type is a reference-counted handle, not raw bytes, so
// ZeroMemory() on a struct containing one does not reliably leave it as
// "" (confirmed by a real MetaEditor run: a rejected build left
// outTradeRequest.symbol non-empty even though it was never assigned).
// Manual field-by-field zero-init avoids that platform pitfall entirely.
void MqlTradeRequest_ZeroInit(MqlTradeRequest &r)
{
   r.action        = (ENUM_TRADE_REQUEST_ACTIONS)0;
   r.magic         = 0;
   r.order         = 0;
   r.symbol        = "";
   r.volume        = 0;
   r.price         = 0;
   r.stoplimit     = 0;
   r.sl            = 0;
   r.tp            = 0;
   r.deviation     = 0;
   r.type          = ORDER_TYPE_BUY;
   r.type_filling  = ORDER_FILLING_FOK;
   r.type_time     = ORDER_TIME_GTC;
   r.expiration    = 0;
   r.comment       = "";
   r.position      = 0;
   r.position_by   = 0;
}

// Builds the MqlTradeRequest for a market TRADE_ACTION_DEAL order from an
// already-ACCEPTED request/policy pair. observedSymbolAtGate is the
// _Symbol value the pre-submit gate (BrokerSubmissionGate_Evaluate)
// observed moments earlier in the same call chain - re-read here and
// compared, so a symbol change racing between gate evaluation and
// request construction is caught rather than silently sent. Returns
// false (outTradeRequest left zeroed) on any freshness/validity
// failure - never partially constructs a request. type_filling/
// type_time are NOT part of C2.1's frozen field list (only symbol/
// volume/type/price/sl/tp/deviation/comment/magic are) - ORDER_FILLING_IOC/
// ORDER_TIME_GTC are a minimal, conservative implementation default
// needed for OrderSend to be well-formed at all, flagged here for
// review rather than silently assumed frozen.
bool BrokerSubmission_BuildTradeRequest(const ExecutionRequest &req, const ExecutionPolicy &policy,
                                          string observedSymbolAtGate,
                                          MqlTradeRequest &outTradeRequest, ENUM_REASON_CODE &outRejectReason)
{
   MqlTradeRequest_ZeroInit(outTradeRequest);
   outRejectReason = REASON_NONE;

   if(req.side != ORDER_TYPE_BUY && req.side != ORDER_TYPE_SELL)
   {
      outRejectReason = REASON_EXECUTION_ORDER_TYPE_NOT_MARKET;
      return false;
   }

   string freshSymbol = _Symbol;
   if(freshSymbol != observedSymbolAtGate)
   {
      outRejectReason = REASON_EXECUTION_SYMBOL_NOT_ALLOWED;
      return false;
   }

   double bid = SymbolInfoDouble(freshSymbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(freshSymbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
   {
      outRejectReason = REASON_ERROR_INTERNAL;
      return false;
   }

   double price = (req.side == ORDER_TYPE_BUY) ? ask : bid;

   outTradeRequest.action      = TRADE_ACTION_DEAL;
   outTradeRequest.symbol      = freshSymbol;
   outTradeRequest.volume      = req.lot_size;
   outTradeRequest.type        = req.side;
   outTradeRequest.price       = price;
   outTradeRequest.sl          = req.planned_sl;
   outTradeRequest.tp          = req.planned_tp;
   outTradeRequest.deviation   = (ulong)policy.max_deviation_points;
   outTradeRequest.magic       = MLQUANTAI_MAGIC_NUMBER;
   outTradeRequest.comment     = req.correlation_id;
   outTradeRequest.type_time   = ORDER_TIME_GTC;
   outTradeRequest.type_filling = ORDER_FILLING_IOC;

   return true;
}

// True = accepted or ambiguous (candidate stays at CANDIDATE_SUBMITTED,
// awaiting later reconciliation) - the frozen contract's DEFAULT for any
// retcode not explicitly classified as a rejection below. False =
// explicit rejection (candidate chains SUBMITTED -> REJECTED_BY_BROKER).
// The reject list below covers the retcodes realistically returned for
// a market TRADE_ACTION_DEAL open-only order (C2 never modifies/closes
// positions) - not an exhaustive enumeration of every ENUM_TRADE_RETCODE
// value ever defined. TRADE_RETCODE_DONE/_DONE_PARTIAL are the two
// retcodes the contract names explicitly as "accepted"; every other
// unlisted code (including transient ones like TRADE_RETCODE_CONNECTION)
// falls through to the same "ambiguous, not explicitly a rejection"
// default per the contract's own stated rule - this file never guesses
// a rejection for a code it wasn't told to.
bool BrokerSubmission_ClassifyRetcode(uint retcode, ENUM_REASON_CODE &outReason)
{
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE:          // 10004
      case TRADE_RETCODE_PRICE_CHANGED:    // 10020
         outReason = REASON_REQUOTE;
         return false;

      case TRADE_RETCODE_INVALID_STOPS:    // 10016
         outReason = REASON_INVALID_STOPS;
         return false;

      case TRADE_RETCODE_NO_MONEY:         // 10019
         outReason = REASON_INSUFFICIENT_MARGIN;
         return false;

      case TRADE_RETCODE_REJECT:           // 10006
      case TRADE_RETCODE_INVALID:          // 10013
      case TRADE_RETCODE_INVALID_VOLUME:   // 10014
      case TRADE_RETCODE_INVALID_PRICE:    // 10015
      case TRADE_RETCODE_TRADE_DISABLED:   // 10017
      case TRADE_RETCODE_MARKET_CLOSED:    // 10018
      case TRADE_RETCODE_PRICE_OFF:        // 10021
      case TRADE_RETCODE_TOO_MANY_REQUESTS:// 10024
      case TRADE_RETCODE_LOCKED:           // 10028
      case TRADE_RETCODE_FROZEN:           // 10029
      case TRADE_RETCODE_INVALID_FILL:     // 10030
      case TRADE_RETCODE_ONLY_REAL:        // 10032
      case TRADE_RETCODE_LIMIT_ORDERS:     // 10033
      case TRADE_RETCODE_LIMIT_VOLUME:     // 10034
      case TRADE_RETCODE_INVALID_ORDER:    // 10035
      case TRADE_RETCODE_LONG_ONLY:        // 10042
      case TRADE_RETCODE_SHORT_ONLY:       // 10043
         outReason = REASON_BROKER_REJECT;
         return false;

      default:
         outReason = REASON_SUBMITTED_OK;
         return true;
   }
}

#endif // __MLQUANTAI_BROKERSUBMISSIONBUILDER_MQH__
