//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_PositionExitObservation.mqh      |
//| RA-65 Slice 2 (QA-frozen, Addendums A/B/C): the live               |
//| OnTradeTransaction-side POSITION_CLOSED emission path, built ONLY  |
//| on top of the RA-65 Slice 1 provenance resolver (unchanged) and     |
//| the already-sealed C3.2 BROKER_TRANSACTION_OBSERVED recorder.       |
//|                                                                      |
//| Two layers, deliberately separated for testability - same "thin      |
//| live wrapper, pure decision core" pattern this project already        |
//| establishes everywhere else:                                           |
//|                                                                         |
//|  - PositionExit_IsReducingDeal / PositionExit_ClassifyCloseKind /        |
//|    PositionClosedFact_CheckIdempotency / PositionClosedFact_ToExtraJson /|
//|    PositionExitObservation_EmitIfNeeded: 100% pure, no live MT5 API,      |
//|    no OrderSend/CTrade - fully unit-testable with fabricated inputs.      |
//|                                                                              |
//|  - PositionExitObservation_Handle: the real OnTradeTransaction-side          |
//|    orchestration. This is the ONLY function in this file that calls           |
//|    PositionSelectByTicket()/PositionGetDouble() (live MT5 Position*            |
//|    read - the same permitted class BrokerReconciliation.mqh already            |
//|    uses, never History*). Matches the existing, accepted precedent              |
//|    that a live-Position*-dependent orchestration function is proven               |
//|    correct via real runtime evidence, not an automated test harness                |
//|    (Tests/MLQuantAI_Test_BrokerReconciliation.mq5's own header comment               |
//|    documents this same boundary for BrokerReconciliation_HasMatchingPosition).         |
//|                                                                                          |
//| Frozen ordering (RA-65 Slice 2 addendum, non-negotiable): this file's                    |
//| entry point must only ever be called AFTER                                                |
//| BrokerTransactionObservation_RecordAndGuard() has already durably                          |
//| recorded the BROKER_TRANSACTION_OBSERVED fact for the SAME transaction.                     |
//| Enforced TWICE, defense-in-depth (per QA's pre-push diff-audit finding):                     |
//| (1) MLQuantAI.mq5's OnTradeTransaction only calls this function when that                     |
//| call's own return value was true, and (2) PositionExitProvenance_Resolve()                    |
//| itself now REQUIRES a matching durable line for the current trans.deal                          |
//| before it will resolve anything - it can no longer be satisfied by a STALE                       |
//| prior observation of the same position_ticket alone (e.g. the opening deal).                       |
//|                                                                                                  |
//| Does not add a CANDIDATE_CLOSED state, does not change CANDIDATE_EXECUTED's                      |
//| terminal semantics, does not implement offline-close recovery (RA-65's                            |
//| own named, deferred gap) - all explicitly out of scope, per RA-65's frozen                          |
//| design.                                                                                                |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_POSITIONEXITOBSERVATION_MQH__
#define __MLQUANTAI_POSITIONEXITOBSERVATION_MQH__

#include "MLQuantAI_PositionExitProvenanceResolver.mqh"
#include "../Core/MLQuantAI_CanonicalFormat.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_SafeModeState.mqh"

enum ENUM_POSITION_CLOSE_KIND
{
   POSITION_CLOSE_KIND_NONE,
   POSITION_CLOSE_KIND_FULL,
   POSITION_CLOSE_KIND_PARTIAL
};

string PositionCloseKindToString(ENUM_POSITION_CLOSE_KIND k)
{
   switch(k)
   {
      case POSITION_CLOSE_KIND_FULL:    return "FULL";
      case POSITION_CLOSE_KIND_PARTIAL: return "PARTIAL";
   }
   return "NONE";
}

// Addendum B, part 1 (frozen): a deal only ever represents a reduction of
// a known position if its own direction is OPPOSITE the candidate's
// original side - same direction means an entry/averaging-in deal, never
// a close, regardless of any other field.
bool PositionExit_IsReducingDeal(ENUM_DEAL_TYPE dealType, ENUM_ORDER_TYPE side)
{
   if(side == ORDER_TYPE_BUY)  return dealType == DEAL_TYPE_SELL;
   if(side == ORDER_TYPE_SELL) return dealType == DEAL_TYPE_BUY;
   return false;
}

// A plain, live-API-free stand-in for "what PositionSelectByTicket() +
// PositionGetDouble(POSITION_VOLUME) found for this position_ticket right
// now" - the only way PositionExit_ClassifyCloseKind() below can be
// exercised by a fixture without a real open position.
struct PositionLiveSnapshot
{
   bool   found;
   double volume; // valid only if found == true
};

void PositionLiveSnapshot_Init(PositionLiveSnapshot &s)
{
   s.found = false;
   s.volume = 0.0;
}

// Addendum B, part 2 (frozen): position not found live -> FULL; still
// found (even with reduced volume) -> PARTIAL. Never a volume-delta
// computation - the mere continued existence of the position is the
// whole signal.
ENUM_POSITION_CLOSE_KIND PositionExit_ClassifyCloseKind(const PositionLiveSnapshot &snapshot)
{
   if(!snapshot.found) return POSITION_CLOSE_KIND_FULL;
   return POSITION_CLOSE_KIND_PARTIAL;
}

// The full durable-fact shape for one POSITION_CLOSED observation.
struct PositionClosedFact
{
   ulong  position_ticket;
   ulong  closing_deal_ticket;
   ulong  order_ticket;
   string execution_request_id;
   string candidate_id;
   string correlation_id;
   ENUM_POSITION_CLOSE_KIND close_kind;
   double volume_closed;      // this closing deal's own volume (trans.volume)
   double volume_remaining;   // live-read remaining volume; 0.0 when close_kind == FULL
   string symbol;
   double price;
};

void PositionClosedFact_Init(PositionClosedFact &f)
{
   f.position_ticket = 0;
   f.closing_deal_ticket = 0;
   f.order_ticket = 0;
   f.execution_request_id = "";
   f.candidate_id = "";
   f.correlation_id = "";
   f.close_kind = POSITION_CLOSE_KIND_NONE;
   f.volume_closed = 0.0;
   f.volume_remaining = 0.0;
   f.symbol = "";
   f.price = 0.0;
}

// Canonical payload equality - every content field, deliberately excluding
// nothing (unlike TransactionDealRecord_SamePayload, this fact has no
// envelope/session field of its own to exclude - source_sequence_number/
// log_event_id belong to the LINE this fact is read back from, not to the
// fact itself).
bool PositionClosedFact_SamePayload(const PositionClosedFact &a, const PositionClosedFact &b)
{
   return a.position_ticket        == b.position_ticket &&
          a.closing_deal_ticket    == b.closing_deal_ticket &&
          a.order_ticket           == b.order_ticket &&
          a.execution_request_id   == b.execution_request_id &&
          a.candidate_id           == b.candidate_id &&
          a.correlation_id         == b.correlation_id &&
          a.close_kind             == b.close_kind &&
          a.volume_closed          == b.volume_closed &&
          a.volume_remaining       == b.volume_remaining &&
          a.symbol                 == b.symbol &&
          a.price                  == b.price;
}

// Same extra_json convention every other derived-artifact event in this
// project already uses (escaped strings, unquoted numbers via
// CanonicalDouble/IntegerToString).
string PositionClosedFact_ToExtraJson(const PositionClosedFact &f)
{
   string s = "";
   s += "\"position_ticket\":"        + IntegerToString((long)f.position_ticket) + ",";
   s += "\"closing_deal_ticket\":"    + IntegerToString((long)f.closing_deal_ticket) + ",";
   s += "\"order_ticket\":"            + IntegerToString((long)f.order_ticket) + ",";
   s += "\"execution_request_id\":\""  + EventSerializer_Escape(f.execution_request_id) + "\",";
   s += "\"candidate_id\":\""          + EventSerializer_Escape(f.candidate_id) + "\",";
   s += "\"correlation_id\":\""        + EventSerializer_Escape(f.correlation_id) + "\",";
   s += "\"close_kind\":\""            + PositionCloseKindToString(f.close_kind) + "\",";
   s += "\"volume_closed\":"           + CanonicalDouble(f.volume_closed) + ",";
   s += "\"volume_remaining\":"        + CanonicalDouble(f.volume_remaining) + ",";
   s += "\"symbol\":\""                + EventSerializer_Escape(f.symbol) + "\",";
   s += "\"price\":"                   + CanonicalDouble(f.price);
   return s;
}

// Re-parses one durable POSITION_CLOSED line back into a PositionClosedFact
// - the exact inverse of _ToExtraJson, used only by the idempotency check
// below. Assumes the caller has already confirmed type == "POSITION_CLOSED".
void PositionClosedFact_FromLine(string line, PositionClosedFact &out)
{
   PositionClosedFact_Init(out);
   out.position_ticket       = (ulong)EventSerializer_GetLong(line, "position_ticket");
   out.closing_deal_ticket   = (ulong)EventSerializer_GetLong(line, "closing_deal_ticket");
   out.order_ticket           = (ulong)EventSerializer_GetLong(line, "order_ticket");
   out.execution_request_id   = EventSerializer_GetStr(line, "execution_request_id");
   out.candidate_id            = EventSerializer_GetStr(line, "candidate_id");
   out.correlation_id          = EventSerializer_GetStr(line, "correlation_id");
   string closeKindStr = EventSerializer_GetStr(line, "close_kind");
   out.close_kind = (closeKindStr == "FULL") ? POSITION_CLOSE_KIND_FULL
                     : (closeKindStr == "PARTIAL") ? POSITION_CLOSE_KIND_PARTIAL
                     : POSITION_CLOSE_KIND_NONE;
   out.volume_closed     = EventSerializer_GetDouble(line, "volume_closed");
   out.volume_remaining  = EventSerializer_GetDouble(line, "volume_remaining");
   out.symbol             = EventSerializer_GetStr(line, "symbol");
   out.price               = EventSerializer_GetDouble(line, "price");
}

enum ENUM_POSITION_CLOSED_IDEMPOTENCY
{
   POSITION_CLOSED_IDEMPOTENCY_NONE_FOUND,
   POSITION_CLOSED_IDEMPOTENCY_DUPLICATE_SAME_PAYLOAD,
   POSITION_CLOSED_IDEMPOTENCY_CONFLICTING_PAYLOAD
};

// Addendum C (frozen): closing_deal_ticket is the idempotency key. Same
// ticket + identical payload = duplicate no-op; same ticket + ANY
// differing field = conflicting payload (structural corruption, never a
// silent overwrite or a "most recent wins" pick).
ENUM_POSITION_CLOSED_IDEMPOTENCY PositionClosedFact_CheckIdempotency(const PositionClosedFact &fact, const string &lines[])
{
   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != "POSITION_CLOSED") continue;
      ulong lineClosingDeal = (ulong)EventSerializer_GetLong(lines[i], "closing_deal_ticket");
      if(lineClosingDeal != fact.closing_deal_ticket) continue;

      PositionClosedFact existing;
      PositionClosedFact_FromLine(lines[i], existing);
      if(PositionClosedFact_SamePayload(fact, existing))
         return POSITION_CLOSED_IDEMPOTENCY_DUPLICATE_SAME_PAYLOAD;
      return POSITION_CLOSED_IDEMPOTENCY_CONFLICTING_PAYLOAD;
   }
   return POSITION_CLOSED_IDEMPOTENCY_NONE_FOUND;
}

// The pure emission core (R6/R8, frozen): idempotency-checks, then either
// no-ops, trips Safe Mode on a payload conflict, attempts exactly one
// durable append and trips Safe Mode on that append's own failure, or
// succeeds. No live MT5 API call anywhere in this function - fully
// unit-testable against a fabricated `lines[]` and a closed/open
// EventStore.
bool PositionExitObservation_EmitIfNeeded(const PositionClosedFact &fact, const string &lines[])
{
   ENUM_POSITION_CLOSED_IDEMPOTENCY idem = PositionClosedFact_CheckIdempotency(fact, lines);
   if(idem == POSITION_CLOSED_IDEMPOTENCY_DUPLICATE_SAME_PAYLOAD)
      return true; // already durably recorded, identical - silent no-op, not an error

   if(idem == POSITION_CLOSED_IDEMPOTENCY_CONFLICTING_PAYLOAD)
   {
      SafeMode_Trip(StringFormat(
         "POSITION_CLOSED conflicting payload for closing_deal_ticket=%s - same ticket already durably "
         "recorded with different fields",
         IntegerToString((long)fact.closing_deal_ticket)));
      return false;
   }

   string extraJson = PositionClosedFact_ToExtraJson(fact);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_POSITION_CLOSED), "position closed", extraJson))
   {
      SafeMode_Trip(StringFormat("POSITION_CLOSED append failed for closing_deal_ticket=%s",
                                   IntegerToString((long)fact.closing_deal_ticket)));
      return false;
   }
   return true;
}

// The real OnTradeTransaction-side orchestration (Addendum ordering,
// frozen). Must be called only for a TRADE_TRANSACTION_DEAL_ADD
// transaction, only AFTER BrokerTransactionObservation_RecordAndGuard()
// has already durably recorded this same transaction.
//
// Silently returns (no emit, no Safe Mode) for every unresolved/ambiguous
// provenance outcome and for every non-reducing deal - per RA-65's frozen
// invariant, "cannot prove this broker fact belongs to MLQuantAI" is not
// itself a fault.
void PositionExitObservation_Handle(const MqlTradeTransaction &trans)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.position == 0) return;

   string lines[];
   EventStore_ReadAllLines(g_EventStore_FileName, lines);

   PositionExitProvenanceResult provenance;
   PositionExitProvenance_Resolve(trans.position, trans.deal, lines, provenance);
   if(!PositionExitProvenance_IsResolved(provenance.status)) return;

   // Addendum A (frozen): an independent, read-only side lookup - never
   // touches MLQuantAI_PositionExitProvenanceResolver.mqh's own frozen
   // struct/contract. Re-derives from the SAME execution_request_id the
   // resolver already proved unique, as a defensive re-verification
   // (matches this project's existing "structurally unreachable - fail
   // closed, never assume" precedent) rather than trusting a second read
   // to agree without checking.
   ENUM_ORDER_TYPE side = ORDER_TYPE_BUY;
   int sideMatches = 0;
   int totalExecReq = ExecutionRequestProjection_Count();
   for(int i = 0; i < totalExecReq; i++)
   {
      ExecutionRequestProjectionRecord rec;
      if(!ExecutionRequestProjection_GetAt(i, rec)) continue;
      if(rec.execution_request_id != provenance.execution_request_id) continue;
      side = rec.side;
      sideMatches++;
   }
   if(sideMatches != 1) return; // re-verification disagreed with the resolver - treat as unresolved, never guess

   // Addendum B: skip entirely for an entry/averaging-in deal.
   if(!PositionExit_IsReducingDeal(trans.deal_type, side)) return;

   PositionLiveSnapshot snapshot;
   PositionLiveSnapshot_Init(snapshot);
   if(PositionSelectByTicket(trans.position))
   {
      snapshot.found = true;
      snapshot.volume = PositionGetDouble(POSITION_VOLUME);
   }
   ENUM_POSITION_CLOSE_KIND closeKind = PositionExit_ClassifyCloseKind(snapshot);

   PositionClosedFact fact;
   PositionClosedFact_Init(fact);
   fact.position_ticket       = trans.position;
   fact.closing_deal_ticket   = trans.deal;
   fact.order_ticket            = provenance.order_ticket;
   fact.execution_request_id    = provenance.execution_request_id;
   fact.candidate_id             = provenance.candidate_id;
   fact.correlation_id           = provenance.correlation_id;
   fact.close_kind                = closeKind;
   fact.volume_closed              = trans.volume;
   fact.volume_remaining           = (closeKind == POSITION_CLOSE_KIND_PARTIAL) ? snapshot.volume : 0.0;
   fact.symbol                      = trans.symbol;
   fact.price                        = trans.price;

   PositionExitObservation_EmitIfNeeded(fact, lines);
}

#endif // __MLQUANTAI_POSITIONEXITOBSERVATION_MQH__
