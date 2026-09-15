//+------------------------------------------------------------------+
//| MLQuantAI - Strategies/MLQuantAI_CRT_V1_EventEmission.mqh         |
//| Phase B B5 Commit 5: the final boundary - TradeCandidate ->       |
//| CANDIDATE_CREATED -> EventStore append. Reuses the existing,      |
//| Phase-A-sealed EventStore_LogCandidateCreated()/                  |
//| StateProjector_TryGetState() machinery (the exact idempotency     |
//| pattern MLQuantAI.mq5's own Step 8.5 smoke test already uses) -   |
//| no new event-store primitive, no new idempotency mechanism.       |
//|                                                                    |
//| Does not touch the CRT detector, the ctx->candidate mapping,       |
//| candidate_hash, root_event_id, or any entry/sl/tp hint - Commit 4  |
//| already sealed all of that. This file's only job is getting an     |
//| already-finished TradeCandidate durably onto the Event Store.      |
//|                                                                    |
//| No RiskPlan, AI score, ExecutionRequest, OrderSend/CTrade, broker  |
//| reconciliation, position/deal/order reads, or candidate state      |
//| transition beyond CANDIDATE_CREATED anywhere in this file.         |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CRT_V1_EVENT_EMISSION_MQH__
#define __MLQUANTAI_CRT_V1_EVENT_EMISSION_MQH__

#include "MLQuantAI_CRT_V1_ToTradeCandidate.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Infrastructure/EventStore/MLQuantAI_StateProjector.mqh"
#include "../Market/MLQuantAI_MarketContext.mqh"
// RA-39 (QA-frozen Projection Live-Sync Hardening, RA-38 design, amended
// scope per QA's CandidateProjection overload ruling): needed only by
// the new 3-argument CRT_EmitCandidateCreated() overload below -
// CandidateProjection_ApplyLineWithContext() is the SAME function
// CandidateProjection_RebuildFromFile() already uses at rebuild time,
// reused here (Pattern A) so cold rebuild and live-apply share one
// validation path (R6).
#include "../Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh"

// Generic string[] -> JSON array, escaped the same way every other
// string field in an event line already is (EventSerializer_Escape) -
// no existing helper covers a plain string[] (NewsSnapshot_ArrayToJson/
// MarketContext_RatesArrayToJson are both struct-array serializers).
string CRT_StringArrayToJson(const string &arr[])
{
   string s = "[";
   for(int i = 0; i < ArraySize(arr); i++)
   {
      if(i > 0) s += ",";
      s += "\"" + EventSerializer_Escape(arr[i]) + "\"";
   }
   s += "]";
   return s;
}

// The extra_json fragment for a CRT CANDIDATE_CREATED event - everything
// LifecycleEvent has no native field for. candidate_id/root_event_id/
// strategy_id are already native LifecycleEvent fields (see
// EventStore_LogCandidateCreated), so they are NOT repeated here.
//
// No separate "event_hash" is introduced here: candidate_hash (Commit 4)
// already is the canonical fingerprint of this exact candidate's
// deterministic content, and BaseEvent's own log_event_id (session_id +
// sequence_number, Phase A sealed) already uniquely identifies this
// specific append. Hashing the event a second time would be redundant,
// not additional signal - the same reasoning candidate_hash itself
// already uses to skip signal_time/expiry_time.
string CRT_CandidateCreatedExtraJson(const TradeCandidate &c, int digits)
{
   string s = "";
   s += "\"context_event_id\":\""       + EventSerializer_Escape(c.context_event_id) + "\",";
   s += "\"context_hash\":\""            + EventSerializer_Escape(c.context_hash) + "\",";
   s += "\"candidate_hash\":\""          + EventSerializer_Escape(c.candidate_hash) + "\",";
   s += "\"detector_hash\":\""           + EventSerializer_Escape(c.detector_hash) + "\",";
   s += "\"candidate_schema_version\":\""+ EventSerializer_Escape(c.candidate_schema_version) + "\",";
   s += "\"side\":\""                    + (c.side == ORDER_TYPE_BUY ? "BUY" : "SELL") + "\",";
   s += "\"setup_anchor_bar_time\":\""   + TimeToString(c.setup_anchor_bar_time, TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"expiry_after_bars\":"         + IntegerToString(c.expiry_after_bars) + ",";
   s += "\"expiry_time\":\""             + TimeToString(c.expiry_time, TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"entry_hint\":"                + DoubleToString(c.entry_hint, digits) + ",";
   s += "\"sl_hint\":"                   + DoubleToString(c.sl_hint, digits) + ",";
   s += "\"tp_hint\":"                   + DoubleToString(c.tp_hint, digits) + ",";
   s += "\"trigger_reason_mask\":"       + IntegerToString((long)c.trigger_reason_mask) + ",";
   s += "\"trigger_reasons\":"           + CRT_StringArrayToJson(c.trigger_reasons);
   return s;
}

// The Commit 5 boundary function. Returns true only if a CANDIDATE_CREATED
// event was durably appended THIS call. Returns false, with no error and
// no write attempted, in two legitimate non-error cases:
//  - c.candidate_id == "" - a non-detection candidate (Commit 4's
//    CRT_ToTradeCandidate returned false) - a non-detection emits no
//    event, same as it produces no candidate.
//  - StateProjector_TryGetState(c.candidate_id, ...) already finds this
//    candidate_id - a duplicate call for the same candidate (this
//    session, or replayed from a prior run) does NOT append a second
//    creation event. StateProjector would correctly flag a second
//    CREATED genesis for the same candidate_id as corruption, so this
//    guard is required, not just tidy - identical reasoning to
//    MLQuantAI.mq5's RunRuntimeLifecycleSmokeTest().
// Returns false (with EventStore_LogCandidateCreated's own SafeMode_Trip
// already having fired) if the write itself failed to become durable.
//
// After a successful durable write, also applies an equivalent genesis
// LifecycleEvent to StateProjector directly (the same StateProjector_Apply
// call ReplayEngine makes per-line) - EventStore_LogCandidateCreated only
// writes to disk, it does not itself update StateProjector, which
// otherwise only reflects reality after an explicit ReplayEngine_Run.
// Without this, two CRT_EmitCandidateCreated calls for the same
// candidate_id inside the same live session - before any replay has ever
// run - would both see StateProjector_TryGetState() return false and both
// durably append a CANDIDATE_CREATED event: a duplicate genesis event
// StateProjector's own Apply() would then reject as corruption on the
// very next replay. This keeps the live in-memory guard correct without
// requiring a replay pass first.
bool CRT_EmitCandidateCreated(const TradeCandidate &c, int digits)
{
   if(c.candidate_id == "") return false;

   ENUM_CANDIDATE_STATE existingState;
   if(StateProjector_TryGetState(c.candidate_id, existingState)) return false;

   string extraJson = CRT_CandidateCreatedExtraJson(c, digits);
   if(!EventStore_LogCandidateCreated(c, extraJson)) return false;

   LifecycleEvent e;
   LifecycleEvent_Init(e);
   e.candidate_id   = c.candidate_id;
   e.root_event_id  = c.root_event_id;
   e.correlation_id = c.correlation_id;
   e.strategy_id    = c.strategy_id;
   e.from_state      = CANDIDATE_CREATED;
   e.to_state        = CANDIDATE_CREATED;
   string projectorError;
   StateProjector_Apply(e, projectorError); // best-effort - the durable write already succeeded; this only keeps live lookups accurate before the next real replay

   return true;
}

// RA-39 (QA-frozen Projection Live-Sync Hardening, RA-38 design, amended
// scope): a SEPARATE 3-argument overload, added alongside the 2-argument
// function above WITHOUT MODIFYING IT AT ALL (AC-CAND-01) - every one of
// the ~30 existing sealed test files calling the 2-argument form keeps
// compiling and keeps its pre-RA-39 behavior exactly, including
// deliberate orphan-candidate fixtures that have no MarketContext to
// supply (AC-CAND-04).
//
// This overload is authorized for use ONLY at the two real production/
// ceremony call sites (MLQuantAI.mq5's RunC22CeremonyFixtureCommand and
// the C5.0 OnTick fixture pipeline) - AC-CAND-02. No other call site is
// migrated to this overload solely to obtain a ctx to pass (AC-CAND-05).
//
// After the same durable append and StateProjector_Apply() the 2-argument
// version already performs (R5: StateProjector_Apply()'s own invocation,
// arguments, and best-effort failure handling are UNCHANGED - copied
// verbatim below, not refactored into a shared helper, to avoid any risk
// of altering the 2-argument function's behavior even indirectly), this
// overload additionally live-applies the SAME LifecycleEvent to
// CandidateProjection via CandidateProjection_ApplyLineWithContext() -
// the identical function CandidateProjection_RebuildFromFile() uses, so
// cold rebuild and live-apply share one validation path (R6).
//
// Per R4 (frozen, re-scoped to this overload only): the live-apply
// context set is restricted to exactly the ONE MarketContext that
// produced this candidate (ctx.context_event_id/context_hash) - never a
// broader scan (AC-CAND-03). A durable-succeeded-but-apply-failed
// outcome returns false (R3, fail-closed), mirroring RA-30.4's pattern.
bool CRT_EmitCandidateCreated(const TradeCandidate &c, int digits, const MarketContext &ctx)
{
   if(c.candidate_id == "") return false;

   ENUM_CANDIDATE_STATE existingState;
   if(StateProjector_TryGetState(c.candidate_id, existingState)) return false;

   string extraJson = CRT_CandidateCreatedExtraJson(c, digits);

   LifecycleEvent e;
   LifecycleEvent_Init(e);
   e.candidate_id     = c.candidate_id;
   e.root_event_id    = c.root_event_id;
   e.correlation_id   = c.correlation_id;
   e.strategy_id      = c.strategy_id;
   e.from_state        = CANDIDATE_CREATED;
   e.to_state          = CANDIDATE_CREATED;
   e.reason             = REASON_NONE;
   e.extra_json         = extraJson;
   e.base.event_type   = EventTypeToString(EVENT_TYPE_CANDIDATE_CREATED);
   if(!EventStore_AppendLifecycle(e))
   {
      SafeMode_Trip(StringFormat("failed to durably write CANDIDATE_CREATED for %s", c.candidate_id));
      return false;
   }

   string candidateLine = EventSerializer_ToJson(e);
   string knownContextIds[1];
   string knownContextHashes[1];
   knownContextIds[0]   = ctx.context_event_id;
   knownContextHashes[0] = ctx.context_hash;
   string applyReason;
   if(!CandidateProjection_ApplyLineWithContext(candidateLine, knownContextIds, knownContextHashes, applyReason))
      return false; // durable append already succeeded (append-only, never rolled back) - fail closed on the live-apply step (R3)

   string projectorError2;
   StateProjector_Apply(e, projectorError2); // best-effort, unchanged (R5) - the durable write already succeeded; this only keeps live lookups accurate before the next real replay

   return true;
}

#endif // __MLQUANTAI_CRT_V1_EVENT_EMISSION_MQH__
