//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_EntryCompatibilityDiagnosticEmission.mqh |
//| RA-30.3 (QA-frozen Read-Only Entry Compatibility Diagnostic): the   |
//| durable-evidence side of the EVALUATE_ENTRY_COMPATIBILITY ceremony  |
//| command. Calls MLQuantAI_EntryCompatibilityGate.mqh's own          |
//| EntryCompatibilityGate_Evaluate() (sealed, untouched by this file)  |
//| and records the full result as one ENTRY_COMPATIBILITY_EVALUATED    |
//| SystemEvent.                                                       |
//|                                                                    |
//| Hard invariant (RA-30.3 condition B, QA-frozen): this file NEVER   |
//| calls, and never transitively reaches, any of:                     |
//|   BrokerSubmission_Submit / BrokerSubmission_RecordAttempt /        |
//|   BrokerSubmissionGate_Evaluate / OrderSend / any                   |
//|   SubmissionAttemptRegistry write / CEREMONY_STATE_SUBMISSION_IN_   |
//|   PROGRESS. The only file this includes beyond EventStore/Enums/    |
//|   CanonicalFormat is MLQuantAI_EntryCompatibilityGate.mqh itself -  |
//|   there is no include path from here into                          |
//|   MLQuantAI_BrokerSubmissionAdapter.mqh at all.                     |
//|                                                                    |
//| AC-10 (RA-30.3 condition C, QA-frozen): execution_reference_price   |
//| is read from EntryCompatibilityGate_Evaluate()'s own returned       |
//| EntryCompatibilityResult.execution_reference_price exactly once -   |
//| this file performs NO independent SymbolInfoDouble(SYMBOL_BID/ASK)  |
//| call anywhere. risk_divergence_pct reported below is always         |
//| EntryCompatibilityResult.risk_divergence_pct verbatim, never an      |
//| independently recomputed value - only the money/distance BREAKDOWN  |
//| fields (which the gate itself does not expose) are derived here,    |
//| from the gate's own returned execution_reference_price plus the     |
//| already-fixed planned_entry/planned_sl/lot_size (no live reread of  |
//| any of those either). The one unavoidable independent runtime read  |
//| in this file is SYMBOL_TRADE_TICK_VALUE - a static symbol           |
//| specification constant, not a live quote, and explicitly NOT what   |
//| AC-10 protects (AC-10 is about execution_reference_price only, per  |
//| Docs/PhaseC_C2_4_EntryPriceCompatibilityContract.md and the RA-12    |
//| amendment to Docs/PhaseC_C2_1_BrokerSubmissionContract.md).         |
//|                                                                    |
//| RA-30.3 condition D (QA-frozen): ENTRY_COMPATIBILITY_EVALUATED is a |
//| distinct event type from BROKER_TRANSACTION_OBSERVED - this file    |
//| never writes to that type, never carries a broker transaction, and  |
//| the event's own extra_json carries no ticket/deal/retcode field, so |
//| no parser/replay keyed on transaction fields can mistake it for L3. |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ENTRYCOMPATIBILITYDIAGNOSTICEMISSION_MQH__
#define __MLQUANTAI_ENTRYCOMPATIBILITYDIAGNOSTICEMISSION_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Core/MLQuantAI_Enums.mqh"
#include "../Core/MLQuantAI_CanonicalFormat.mqh"
#include "../Core/MLQuantAI_ReasonCodes.mqh"
#include "MLQuantAI_EntryCompatibilityGate.mqh"

// Full diagnostic outcome - superset of EntryCompatibilityResult, adding
// the lineage fields and the money/distance breakdown QA's RA-30.3
// verdict requires as evidence. ok==false means a STRUCTURAL failure
// (EntryCompatibilityGate_Evaluate itself returned false, i.e. empty
// execution_request_id) - not the same as a gate REJECTED decision,
// which is ok==true with gate_decision==SAFETY_GATE_REJECTED (a valid,
// completed diagnostic outcome, not a failure).
struct EntryCompatibilityDiagnosticResult
{
   bool                        ok;
   string                      structural_failure_reason;

   string                      execution_request_id;
   string                      execution_request_hash;
   string                      correlation_id;
   string                      candidate_id;
   ENUM_ORDER_TYPE             side;
   double                      planned_entry;
   double                      planned_sl;

   double                      execution_reference_price; // EntryCompatibilityResult's own captured value, verbatim
   double                      planned_stop_distance;
   double                      realized_stop_distance;
   double                      planned_risk_money;
   double                      realized_risk_money;
   double                      risk_divergence_pct;        // EntryCompatibilityResult's own value, verbatim - never recomputed
   bool                        directional_constraint_ok;

   ENUM_SAFETY_GATE_DECISION   gate_decision;
   ENUM_REASON_CODE            gate_reason_code;
};

void EntryCompatibilityDiagnosticResult_Init(EntryCompatibilityDiagnosticResult &r)
{
   r.ok = false;
   r.structural_failure_reason = "";
   r.execution_request_id = "";
   r.execution_request_hash = "";
   r.correlation_id = "";
   r.candidate_id = "";
   r.side = ORDER_TYPE_BUY;
   r.planned_entry = 0.0;
   r.planned_sl = 0.0;
   r.execution_reference_price = 0.0;
   r.planned_stop_distance = 0.0;
   r.realized_stop_distance = 0.0;
   r.planned_risk_money = 0.0;
   r.realized_risk_money = 0.0;
   r.risk_divergence_pct = 0.0;
   r.directional_constraint_ok = false;
   r.gate_decision = SAFETY_GATE_NONE;
   r.gate_reason_code = REASON_NONE;
}

// Runs EntryCompatibilityGate_Evaluate() (unmodified, sealed file) and
// fills the full diagnostic result around it. request.candidate_id,
// .correlation_id, .execution_request_id/.execution_request_hash are
// carried through verbatim from the caller's already-reconstructed,
// already-hash-verified ExecutionRequest - this function performs no
// projection lookups and no hash check of its own (that is the caller's
// job, RA-30.3 condition/point 4, done once before this is called).
bool EntryCompatibilityDiagnostic_Evaluate(const ExecutionRequest &request, EntryCompatibilityDiagnosticResult &out)
{
   EntryCompatibilityDiagnosticResult_Init(out);

   out.execution_request_id   = request.execution_request_id;
   out.execution_request_hash = request.execution_request_hash;
   out.correlation_id         = request.correlation_id;
   out.candidate_id           = request.candidate_id;
   out.side                   = request.side;
   out.planned_entry          = request.planned_entry;
   out.planned_sl             = request.planned_sl;

   EntryCompatibilityResult gateResult;
   if(!EntryCompatibilityGate_Evaluate(request, gateResult))
   {
      out.ok = false;
      out.structural_failure_reason = "entry_compatibility_gate_structural_failure";
      return false;
   }

   out.ok             = true;
   out.gate_decision   = gateResult.decision;
   out.gate_reason_code = gateResult.reason_code;
   out.risk_divergence_pct = gateResult.risk_divergence_pct; // verbatim, AC-10/condition C

   if(gateResult.decision == SAFETY_GATE_NONE || gateResult.execution_reference_price <= 0.0)
   {
      // Gate rejected before ever capturing a reference price (invalid
      // side, or bid/ask<=0 Runtime Safety Context failure) - nothing to
      // derive a distance/money breakdown from.
      return true;
   }

   out.execution_reference_price = gateResult.execution_reference_price; // gate's own value, no reread

   // Same directional formula as MLQuantAI_EntryCompatibilityGate.mqh's
   // own (C2.4 §8), applied to the SAME captured price above - never an
   // independent re-derivation of what "correct" means, just evaluated
   // here too so the diagnostic result can carry it as its own field
   // (the gate's own decision/reason_code do not distinguish a
   // directional-constraint rejection from a divergence-exceeded
   // rejection - both use REASON_ENTRY_PRICE_DEVIATION_EXCEEDED).
   out.directional_constraint_ok = (request.side == ORDER_TYPE_BUY)
                                       ? (out.execution_reference_price > request.planned_sl)
                                       : (out.execution_reference_price < request.planned_sl);

   double plannedStopDistance = MathAbs(request.planned_entry - request.planned_sl);
   if(plannedStopDistance <= 0.0 || request.lot_size <= 0.0)
      return true; // same degenerate-input guard as the gate - nothing further to derive

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); // static symbol spec, not a quote - see file header
   if(tickValue <= 0.0)
      return true;

   double realizedStopDistance = MathAbs(out.execution_reference_price - request.planned_sl);

   out.planned_stop_distance  = plannedStopDistance;
   out.realized_stop_distance = realizedStopDistance;
   out.planned_risk_money     = request.lot_size * plannedStopDistance  * tickValue;
   out.realized_risk_money    = request.lot_size * realizedStopDistance * tickValue;

   return true;
}

string EntryCompatibilityDiagnostic_ToExtraJson(string commandId, const EntryCompatibilityDiagnosticResult &r)
{
   string s = "";
   s += "\"command_id\":\""                     + EventSerializer_Escape(commandId) + "\",";
   s += "\"execution_request_id\":\""             + EventSerializer_Escape(r.execution_request_id) + "\",";
   s += "\"execution_request_hash\":\""             + EventSerializer_Escape(r.execution_request_hash) + "\",";
   s += "\"correlation_id\":\""                       + EventSerializer_Escape(r.correlation_id) + "\",";
   s += "\"candidate_id\":\""                           + EventSerializer_Escape(r.candidate_id) + "\",";
   s += "\"side\":\""                                     + (r.side == ORDER_TYPE_BUY ? "BUY" : "SELL") + "\",";
   s += "\"planned_entry\":"                                + CanonicalPrice(r.planned_entry) + ",";
   s += "\"planned_sl\":"                                     + CanonicalPrice(r.planned_sl) + ",";
   s += "\"execution_reference_price\":"                        + CanonicalPrice(r.execution_reference_price) + ",";
   s += "\"planned_stop_distance\":"                              + CanonicalDouble(r.planned_stop_distance) + ",";
   s += "\"realized_stop_distance\":"                               + CanonicalDouble(r.realized_stop_distance) + ",";
   s += "\"planned_risk_money\":"                                     + CanonicalDouble(r.planned_risk_money) + ",";
   s += "\"realized_risk_money\":"                                      + CanonicalDouble(r.realized_risk_money) + ",";
   s += "\"risk_divergence_pct\":"                                        + CanonicalDouble(r.risk_divergence_pct) + ",";
   s += "\"directional_constraint\":"                                       + (r.directional_constraint_ok ? "true" : "false") + ",";
   s += "\"gate_result\":\""                                                  + EventSerializer_Escape(SafetyGateDecisionToString(r.gate_decision)) + "\",";
   s += "\"reason_code\":\""                                                    + EventSerializer_Escape(ReasonCodeToString(r.gate_reason_code)) + "\"";
   return s;
}

// The durable append itself - the only sanctioned writer of
// EVENT_TYPE_ENTRY_COMPATIBILITY_EVALUATED. Caller (EA only, per the
// single-writer architecture) must have already confirmed r.ok before
// calling - this function does not itself branch on r.ok, matching
// every other *_EventEmission.mqh emitter's "caller decides, emitter
// just writes" convention (e.g. MLQuantAI_ManualApprovalEmission.mqh).
bool EventStore_LogEntryCompatibilityEvaluated(string commandId, const EntryCompatibilityDiagnosticResult &r)
{
   string json = EntryCompatibilityDiagnostic_ToExtraJson(commandId, r);
   return EventStore_LogSystem(EventTypeToString(EVENT_TYPE_ENTRY_COMPATIBILITY_EVALUATED),
                                "entry compatibility evaluated", json);
}

#endif // __MLQUANTAI_ENTRYCOMPATIBILITYDIAGNOSTICEMISSION_MQH__
