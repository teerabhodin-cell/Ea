//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BrokerTransactionObservation.mqh |
//| C3.2 implementation (per                                          |
//| Docs/PhaseC_C3_TransactionReconciliationContract.md, sections     |
//| 10-19, frozen): the raw OnTradeTransaction envelope-capture path. |
//| Broker-observation only - NOT reconciliation, NOT fill handling,  |
//| NOT execution authorization. This file is the entirety of the    |
//| authorized C3.2 scope; nothing here may call HistorySelect/       |
//| HistoryDealGet*/HistoryOrderGet*/PositionSelect/OrderSelect/      |
//| OrderSend/CTrade, call EventStore_LogTransition, or otherwise     |
//| mutate a TradeCandidate.                                          |
//|                                                                    |
//| Trust boundary (section 12): `trans` (MqlTradeTransaction) is the |
//| only reliably-populated evidence for every transaction type.      |
//| `request`/`result` are documented as populated only when          |
//| trans.type == TRADE_TRANSACTION_REQUEST - the frozen schema       |
//| (section 13) uses exactly one result-derived field (request_id)   |
//| under that condition; no MqlTradeRequest field is part of the     |
//| frozen schema at all, so `request` is accepted only to match the  |
//| platform's own OnTradeTransaction signature and is never read.    |
//|                                                                    |
//| "source sequence / event identity" and "transaction timestamp"    |
//| (both named in section 13's field list) are satisfied structurally|
//| by the SystemEvent base envelope's own sequence_number/            |
//| log_event_id/ts fields, already populated by EventStore_          |
//| AppendSystem on every line - no separate extra_json field needed   |
//| for either.                                                        |
//|                                                                    |
//| Durability-failure rule (section 17, frozen): EVENT_TYPE_BROKER_  |
//| TRANSACTION_OBSERVED follows the LIFECYCLE-event SafeMode_Trip     |
//| precedent, not the general system-event drop-and-log one - a      |
//| failed append trips Safe Mode and returns immediately. Exactly one |
//| append attempt per callback invocation, no retry.                  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BROKERTRANSACTIONOBSERVATION_MQH__
#define __MLQUANTAI_BROKERTRANSACTIONOBSERVATION_MQH__

#include "../Core/MLQuantAI_Enums.mqh"
#include "../Core/MLQuantAI_CanonicalFormat.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_SafeModeState.mqh"

// Sentinel used for the one result-derived field (request_id) when
// trans.type != TRADE_TRANSACTION_REQUEST - explicit, per section 13's
// "absent or explicitly not_applicable" rule, never a zero value that
// could be misread as an observed fact.
#define BROKER_TX_NOT_APPLICABLE "not_applicable"

// Plain data holder for one raw observation. Every field here is
// sourced directly from `trans` (or, for request_id only, from
// `result` when trans.type == TRADE_TRANSACTION_REQUEST) - nothing
// inferred, nothing looked up.
struct BrokerTransactionEnvelope
{
   string transaction_type;   // EnumToString(trans.type)
   ulong  deal_ticket;        // trans.deal
   ulong  order_ticket;       // trans.order
   ulong  position_ticket;    // trans.position
   ulong  position_by_ticket; // trans.position_by
   string symbol;             // trans.symbol
   string order_type;         // EnumToString(trans.order_type)
   string deal_type;          // EnumToString(trans.deal_type)
   string order_state;        // EnumToString(trans.order_state)
   double price;               // trans.price
   double volume;              // trans.volume
   double price_sl;            // trans.price_sl
   double price_tp;            // trans.price_tp
   string request_id;          // result.request_id if TRADE_TRANSACTION_REQUEST, else BROKER_TX_NOT_APPLICABLE
};

void BrokerTransactionEnvelope_Init(BrokerTransactionEnvelope &e)
{
   e.transaction_type   = "";
   e.deal_ticket         = 0;
   e.order_ticket        = 0;
   e.position_ticket     = 0;
   e.position_by_ticket  = 0;
   e.symbol              = "";
   e.order_type          = "";
   e.deal_type           = "";
   e.order_state         = "";
   e.price               = 0.0;
   e.volume              = 0.0;
   e.price_sl            = 0.0;
   e.price_tp            = 0.0;
   e.request_id          = BROKER_TX_NOT_APPLICABLE;
}

// Pure: no I/O, no global state touched. Fully exercisable by a test
// with a fixture-constructed MqlTradeTransaction/MqlTradeResult - no
// real OnTradeTransaction callback needed (matches section 18's
// test-fixture-seam finding).
void BrokerTransactionEnvelope_Build(const MqlTradeTransaction &trans, const MqlTradeResult &result,
                                       BrokerTransactionEnvelope &out)
{
   BrokerTransactionEnvelope_Init(out);
   out.transaction_type   = EnumToString(trans.type);
   out.deal_ticket         = trans.deal;
   out.order_ticket        = trans.order;
   out.position_ticket     = trans.position;
   out.position_by_ticket  = trans.position_by;
   out.symbol              = trans.symbol;
   out.order_type          = EnumToString(trans.order_type);
   out.deal_type           = EnumToString(trans.deal_type);
   out.order_state         = EnumToString(trans.order_state);
   out.price               = trans.price;
   out.volume              = trans.volume;
   out.price_sl             = trans.price_sl;
   out.price_tp             = trans.price_tp;

   // Trust boundary: result.request_id is documented as populated only
   // for TRADE_TRANSACTION_REQUEST - read it ONLY under that condition,
   // never otherwise (section 12).
   if(trans.type == TRADE_TRANSACTION_REQUEST)
      out.request_id = IntegerToString(result.request_id);
   else
      out.request_id = BROKER_TX_NOT_APPLICABLE;
}

// Matches the extra_json convention already established by every
// derived-artifact event (RiskPlan/FeatureSnapshot/ModelArtifact/
// AIDecision/EligibilityDecision/ExecutionRequest): a caller-supplied,
// already-valid JSON fragment, string fields escaped via
// EventSerializer_Escape, numeric fields written unquoted.
string BrokerTransactionEnvelope_ToExtraJson(const BrokerTransactionEnvelope &e)
{
   string s = "";
   s += "\"transaction_type\":\""    + EventSerializer_Escape(e.transaction_type) + "\",";
   s += "\"deal_ticket\":"            + IntegerToString((long)e.deal_ticket) + ",";
   s += "\"order_ticket\":"           + IntegerToString((long)e.order_ticket) + ",";
   s += "\"position_ticket\":"        + IntegerToString((long)e.position_ticket) + ",";
   s += "\"position_by_ticket\":"     + IntegerToString((long)e.position_by_ticket) + ",";
   s += "\"symbol\":\""               + EventSerializer_Escape(e.symbol) + "\",";
   s += "\"order_type\":\""           + EventSerializer_Escape(e.order_type) + "\",";
   s += "\"deal_type\":\""            + EventSerializer_Escape(e.deal_type) + "\",";
   s += "\"order_state\":\""          + EventSerializer_Escape(e.order_state) + "\",";
   s += "\"price\":"                  + CanonicalDouble(e.price) + ",";
   s += "\"volume\":"                 + CanonicalDouble(e.volume) + ",";
   s += "\"price_sl\":"               + CanonicalDouble(e.price_sl) + ",";
   s += "\"price_tp\":"               + CanonicalDouble(e.price_tp) + ",";
   s += "\"request_id\":\""           + EventSerializer_Escape(e.request_id) + "\"";
   return s;
}

// The ONLY function this file authorizes an OnTradeTransaction handler
// to call. Builds the envelope, attempts exactly ONE durable append,
// and - per section 17's frozen rule - trips Safe Mode immediately on
// failure instead of retrying or continuing silently. Returns true if
// the observation was durably recorded, false if Safe Mode was just
// tripped. Callers (the real callback) must not branch further on the
// return value - both paths already end in "return immediately" per
// the frozen callback shape.
bool BrokerTransactionObservation_RecordAndGuard(const MqlTradeTransaction &trans, const MqlTradeRequest &request,
                                                    const MqlTradeResult &result)
{
   BrokerTransactionEnvelope env;
   BrokerTransactionEnvelope_Build(trans, result, env);
   string extraJson = BrokerTransactionEnvelope_ToExtraJson(env);

   if(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_BROKER_TRANSACTION_OBSERVED),
                             "broker transaction observed", extraJson))
      return true;

   SafeMode_Trip("broker transaction observation append failed");
   return false;
}

#endif // __MLQUANTAI_BROKERTRANSACTIONOBSERVATION_MQH__
