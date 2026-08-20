//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_EligibilityEventEmission.mqh      |
//| Phase B9 Commit 2: EligibilityDecision -> EXECUTION_ELIGIBILITY_    |
//| DECIDED -> EventStore append, plus the REJECTED-only consequence:   |
//| CANDIDATE_REJECTED_BY_RISK via the existing, sealed                 |
//| EventStore_LogTransition. Per                                       |
//| Docs/PhaseB_B9_ExecutionEligibilityContract.md's Commit 2 addendum.  |
//| No broker/order/history/tick call, no mutation of the               |
//| EligibilityDecision/EligibilityContext inputs, no referential-       |
//| integrity check against upstream projections here (that's           |
//| EligibilityDecisionProjection_RebuildFromFile's job, on replay -     |
//| this file only durably writes what it's given). ELIGIBLE and        |
//| REJECTED both emit EXECUTION_ELIGIBILITY_DECIDED identically -      |
//| audit evidence only; only REJECTED additionally drives the          |
//| candidate's lifecycle transition, and never before the decision      |
//| event itself is already durable.                                    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ELIGIBILITYEVENTEMISSION_MQH__
#define __MLQUANTAI_ELIGIBILITYEVENTEMISSION_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "MLQuantAI_EligibilityDecisionProjection.mqh"

// Every EligibilityDecision field flattened as top-level JSON keys,
// plus the raw EligibilityContext evidence (account_*/safe_mode_active,
// prefixed account_ to avoid any key collision) - the mechanism that
// makes eligibility_context_hash independently verifiable on replay,
// since EligibilityContext has no upstream event of its own. All 8 real
// AccountSnapshot fields are persisted verbatim, not a selective
// subset. decision/reason_code follow the project's standard
// enum-as-quoted-string convention.
string EligibilityDecision_ToExtraJson(const EligibilityDecision &d, const EligibilityContext &context)
{
   string s = "";
   s += "\"eligibility_decision_schema_version\":\"" + EventSerializer_Escape(d.eligibility_decision_schema_version) + "\",";
   s += "\"eligibility_decision_id\":\""               + EventSerializer_Escape(d.eligibility_decision_id) + "\",";
   s += "\"eligibility_decision_hash\":\""              + EventSerializer_Escape(d.eligibility_decision_hash) + "\",";
   s += "\"candidate_id\":\""                             + EventSerializer_Escape(d.candidate_id) + "\",";
   s += "\"candidate_hash\":\""                            + EventSerializer_Escape(d.candidate_hash) + "\",";
   s += "\"risk_plan_id\":\""                                + EventSerializer_Escape(d.risk_plan_id) + "\",";
   s += "\"plan_hash\":\""                                     + EventSerializer_Escape(d.plan_hash) + "\",";
   s += "\"ai_decision_id\":\""                                  + EventSerializer_Escape(d.ai_decision_id) + "\",";
   s += "\"ai_decision_hash\":\""                                  + EventSerializer_Escape(d.ai_decision_hash) + "\",";
   s += "\"eligibility_context_schema_version\":\""                  + EventSerializer_Escape(context.eligibility_context_schema_version) + "\",";
   s += "\"eligibility_context_hash\":\""                              + EventSerializer_Escape(d.eligibility_context_hash) + "\",";
   s += "\"eligibility_policy_version\":\""                              + EventSerializer_Escape(d.eligibility_policy_version) + "\",";
   s += "\"decision\":\""                                                  + EligibilityDecisionToString(d.decision) + "\",";
   s += "\"reason_code\":\""                                                 + ReasonCodeToString(d.reason_code) + "\",";
   s += "\"account_balance\":"                                                + CanonicalDouble(context.account.balance) + ",";
   s += "\"account_equity\":"                                                  + CanonicalDouble(context.account.equity) + ",";
   s += "\"account_margin_level\":"                                             + CanonicalDouble(context.account.margin_level) + ",";
   s += "\"account_open_positions_count\":"                                       + IntegerToString(context.account.open_positions_count) + ",";
   s += "\"account_open_risk_percent\":"                                            + CanonicalDouble(context.account.open_risk_percent) + ",";
   s += "\"account_daily_pnl_percent\":"                                              + CanonicalDouble(context.account.daily_pnl_percent) + ",";
   s += "\"account_drawdown_from_peak_percent\":"                                        + CanonicalDouble(context.account.drawdown_from_peak_percent) + ",";
   s += "\"account_context_schema_version\":\""                                            + EventSerializer_Escape(context.account.context_schema_version) + "\",";
   s += "\"safe_mode_active\":"                                                              + (context.safe_mode_active ? "true" : "false");
   return s;
}

// The Commit 2 boundary function. Emits EXECUTION_ELIGIBILITY_DECIDED
// for every successfully-built EligibilityDecision (ELIGIBLE and
// REJECTED both, audit evidence only), then - only when
// decision == ELIGIBILITY_DECISION_REJECTED, and only after the
// decision event is already durable - drives the candidate's
// CANDIDATE_REJECTED_BY_RISK lifecycle transition via the existing,
// sealed EventStore_LogTransition. Never the reverse order.
//
// Returns false, with no write attempted, if
// d.eligibility_decision_id == "" (a failed EligibilityDecision_Build) -
// same "no partial record" rule every prior emitter follows. Returns
// false if EligibilityDecisionProjection_TryGet already finds this
// eligibility_decision_id (coarse, live, in-session duplicate guard,
// same as every prior emitter).
//
// Failure-mode rule (frozen in the contract addendum): if the
// EXECUTION_ELIGIBILITY_DECIDED write succeeds but the subsequent
// CANDIDATE_REJECTED_BY_RISK write fails, this function returns false,
// but the already-durable EXECUTION_ELIGIBILITY_DECIDED line is NEVER
// rolled back, rewritten, or deleted - the event store is append-only.
// The caller must treat a false return on the REJECTED path as "the
// eligibility decision is durably recorded, but the candidate's
// lifecycle state may not reflect it yet" - never as "nothing
// happened." EventStore_LogTransition itself already trips Safe Mode
// on its own durable-write failure (unchanged, sealed behavior).
bool EligibilityDecision_EmitDecisionAndWireLifecycle(const EligibilityDecision &d, const EligibilityContext &context, TradeCandidate &candidate)
{
   if(d.eligibility_decision_id == "") return false;

   EligibilityDecisionProjectionRecord existing;
   if(EligibilityDecisionProjection_TryGet(d.eligibility_decision_id, existing)) return false;

   string extraJson = EligibilityDecision_ToExtraJson(d, context);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED), "execution eligibility decided", extraJson))
      return false;

   EligibilityDecisionProjection_ApplyLiveRecord(d, context);

   if(d.decision != ELIGIBILITY_DECISION_REJECTED)
      return true;

   return EventStore_LogTransition(candidate, CANDIDATE_REJECTED_BY_RISK, d.reason_code, extraJson);
}

#endif // __MLQUANTAI_ELIGIBILITYEVENTEMISSION_MQH__
