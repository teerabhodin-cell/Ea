//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_HistorySource.mqh                |
//| C4.2 read-only broker-history acquisition seam. Per                |
//| Docs/PhaseC_C4_RecoveryHistoryPolicy.md §7/§9/§10: HistorySelect() |
//| and its companion getters have never been called anywhere in this |
//| codebase before this file - this is their first, and only         |
//| authorized, call site.                                             |
//|                                                                    |
//| IHistorySource exists purely to make MLQuantAI_RecoveryReconciliation|
//| .mqh's orchestrator testable without a live terminal history        |
//| connection - same precedent MLQuantAI_NewsSource.mqh's INewsSource  |
//| already set for CsvStaticNewsSource/LiveCalendarNewsSource.         |
//| CLiveHistorySource is a direct, unconditional wrapper of the        |
//| selected read-only history APIs - it adds no logic of its own.      |
//|                                                                    |
//| Getter-knownness discipline (frozen, per this checkpoint's QA):    |
//|  - Every integer/double/string property getter uses ONLY the       |
//|    bool-returning, by-reference MQL5 overload                      |
//|    (HistoryOrder/DealGetInteger/Double/String(ticket, prop,        |
//|    &value)). The bool return is the SOLE knownness signal for that |
//|    property - never 0, 0.0, "", or an enum-zero value.              |
//|  - HistoryOrderGetTicket(index)/HistoryDealGetTicket(index)         |
//|    returning 0 is an enumeration boundary (no order/deal at that   |
//|    index - valid tickets are always non-zero), never a fact with a |
//|    fabricated zero ticket.                                          |
//|  - LastError() is diagnostic-only, never a knownness signal.       |
//|    ResetError() is called by the caller immediately before every   |
//|    property getter (not only after a failure), so a stale terminal |
//|    error code from an earlier call can never be misattributed to a |
//|    later, unrelated getter.                                        |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_HISTORYSOURCE_MQH__
#define __MLQUANTAI_HISTORYSOURCE_MQH__

//---------------------------------------------------------------------
// IHistorySource - the only seam MLQuantAI_RecoveryReconciliation.mqh's
// scan orchestrator is authorized to depend on for broker-history
// evidence. Every method here is a direct 1:1 mirror of one read-only
// MQL5 history API - no aggregation, no interpretation, no knownness
// decision is made in this file; those live entirely in the caller,
// per the acquisition-contract QA round that authorized this file.
//---------------------------------------------------------------------
class IHistorySource
{
public:
   virtual bool   Select(datetime from, datetime to) = 0;
   virtual int    OrdersTotal() = 0;
   virtual int    DealsTotal() = 0;

   // Enumeration getters. A return of 0 means "no order/deal at this
   // index" (an MQL5 API convention - valid tickets are always
   // non-zero) - never an identity-bearing record.
   virtual ulong  OrderTicketByIndex(int index) = 0;
   virtual ulong  DealTicketByIndex(int index) = 0;

   // Property getters - bool/out-param overloads only. The bool return
   // is the sole knownness signal for that one property.
   virtual bool   OrderGetInteger(ulong ticket, ENUM_ORDER_PROPERTY_INTEGER prop, long &value) = 0;
   virtual bool   OrderGetDouble(ulong ticket, ENUM_ORDER_PROPERTY_DOUBLE prop, double &value) = 0;
   virtual bool   OrderGetString(ulong ticket, ENUM_ORDER_PROPERTY_STRING prop, string &value) = 0;
   virtual bool   DealGetInteger(ulong ticket, ENUM_DEAL_PROPERTY_INTEGER prop, long &value) = 0;
   virtual bool   DealGetDouble(ulong ticket, ENUM_DEAL_PROPERTY_DOUBLE prop, double &value) = 0;
   virtual bool   DealGetString(ulong ticket, ENUM_DEAL_PROPERTY_STRING prop, string &value) = 0;

   // Diagnostic-only. Never consulted to determine *_known for any
   // field above - the getters' own bool returns already do that.
   virtual int    LastError() = 0;
   virtual void   ResetError() = 0;
};

//---------------------------------------------------------------------
// CLiveHistorySource - the real, terminal-backed implementation. A
// direct wrapper, nothing more: every method is exactly one MQL5 call.
//---------------------------------------------------------------------
class CLiveHistorySource : public IHistorySource
{
public:
   virtual bool Select(datetime from, datetime to)
   {
      return HistorySelect(from, to);
   }

   virtual int OrdersTotal()
   {
      return HistoryOrdersTotal();
   }

   virtual int DealsTotal()
   {
      return HistoryDealsTotal();
   }

   virtual ulong OrderTicketByIndex(int index)
   {
      return HistoryOrderGetTicket(index);
   }

   virtual ulong DealTicketByIndex(int index)
   {
      return HistoryDealGetTicket(index);
   }

   virtual bool OrderGetInteger(ulong ticket, ENUM_ORDER_PROPERTY_INTEGER prop, long &value)
   {
      return HistoryOrderGetInteger(ticket, prop, value);
   }

   virtual bool OrderGetDouble(ulong ticket, ENUM_ORDER_PROPERTY_DOUBLE prop, double &value)
   {
      return HistoryOrderGetDouble(ticket, prop, value);
   }

   virtual bool OrderGetString(ulong ticket, ENUM_ORDER_PROPERTY_STRING prop, string &value)
   {
      return HistoryOrderGetString(ticket, prop, value);
   }

   virtual bool DealGetInteger(ulong ticket, ENUM_DEAL_PROPERTY_INTEGER prop, long &value)
   {
      return HistoryDealGetInteger(ticket, prop, value);
   }

   virtual bool DealGetDouble(ulong ticket, ENUM_DEAL_PROPERTY_DOUBLE prop, double &value)
   {
      return HistoryDealGetDouble(ticket, prop, value);
   }

   virtual bool DealGetString(ulong ticket, ENUM_DEAL_PROPERTY_STRING prop, string &value)
   {
      return HistoryDealGetString(ticket, prop, value);
   }

   virtual int LastError()
   {
      return GetLastError();
   }

   virtual void ResetError()
   {
      ResetLastError();
   }
};

#endif // __MLQUANTAI_HISTORYSOURCE_MQH__
