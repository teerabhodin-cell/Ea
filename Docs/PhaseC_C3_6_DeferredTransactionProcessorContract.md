# C3.6 deferred-transaction-processor design contract (documentation only)

**Status**: DESIGN ONLY, docs-only, frozen. No `.mqh`/`.mq5` file, no test
file, no `MLQuantAI.mq5` wiring, no new `ENUM_EVENT_TYPE` value, no new
projection struct/API, no `EventStore_LogTransition` integration, no
`BrokerReconciliation.mqh` change, no `History*`/`Position*`/`Order*` API, no
`OrderSend`/`CTrade`, no candidate-lifecycle transition, and no event-schema
change is authorized by this document. Each of those remains its own,
separately approved future step (C3.6 implementation Commit 2, C3.7 lifecycle
authority, C3.8 reconciliation integration, C4 recovery/history policy).

**Baseline**: `mlquantai@f9d3ade` (C1–C3.4 sealed; C3.5 deferred-authority
contract frozen at `b75ce34`; Phase 0.3 fixture-debt gate CLOSED at
`e137bb8`; C3.6 UNLOCKED).

**Predecessor**: this contract refines, and does not contradict, the frozen
C3.5 deferred-transaction-authority design contract
(`Docs/PhaseC_C3_5_DeferredAuthorityContract.md`). Where this document is
silent, C3.5 governs.

---

## 1. Purpose and the boundary this contract freezes

C3.6 turns already-sealed transaction-matching evidence into a **read-only
recommendation read model**. It produces a `DeferredRecommendationRecord` /
report only. It does **not** transition `SUBMITTED → EXECUTED`, does **not**
emit any lifecycle event, and does **not** mutate any projection or any
candidate state.

```
C3.6
  ↓
RECOMMEND_EXECUTED   (a recommendation row in a read model — NOT a transition)
```

Lifecycle authority — turning a recommendation into a real
`SUBMITTED → EXECUTED` transition — is **C3.7**, a separately authorized
contract. `RECOMMEND_EXECUTED` is not an event, not a transition, not a
durable action application, and carries no side effect in this round.

---

## 2. Scope guard (frozen)

```
Docs only. This commit changes exactly two files:
  - Docs/PhaseC_C3_6_DeferredTransactionProcessorContract.md (this file, new)
  - CHANGELOG.md (docs-only entry, DESIGN ONLY)
No new .mqh/.mq5 file. No test file. No MLQuantAI.mq5 wiring. No edit to any
sealed file (CandidateProjection, TransactionMatchingProjection,
BrokerSubmissionAuditProjection, ExecutionAuditProjection, StateProjector,
ReplayEngine, StateMachine, BrokerReconciliation.mqh, BrokerSubmissionAdapter,
BrokerTransactionObservation). No new ENUM_EVENT_TYPE value. No new projection
struct field or query API. No EventStore_LogTransition call. No
OnTick/OnTradeTransaction change. No History*/Position*/Order* API. No
OrderSend/CTrade. No candidate-lifecycle transition. No event-schema/struct
addition. No compile, no test run, no regression.
```

The implementation round (C3.6 Commit 2) is a separately authorized step.
This document freezes the contract and the handoff boundary to that round
only.

---

## 3. Startup placement (frozen — refines C3.5 §10)

C3.5 §10 states the processor "runs after the C3.4 startup rebuild, reads
the already-built C3.3 read model". This contract refines that to the exact
`OnInit` chain, because the eligibility predicate requires
`candidate.state == CANDIDATE_SUBMITTED`, and candidate state is **not** held
by `CandidateProjection` (B6-only projection, always `CANDIDATE_CREATED`).
The real candidate state comes from `StateProjector`, which is populated by
`ReplayEngine_Run`. C3.6 therefore must run **after** `ReplayEngine_Run` so it
sees both durable matching evidence **and** replayed candidate lifecycle
state.

```
OnInit:
  BrokerSubmissionAudit_StartupRebuild(g_EventStoreFileName)   // existing — C2.3
        ↓
  ManualApproval_StartupRebuild(g_EventStoreFileName)            // existing — C2 manual approval
        ↓
  TransactionMatching_StartupRebuild(g_EventStoreFileName)       // existing — C3.4
        ↓
  EventStore_LogSystem(SYSTEM_STARTED, ...)                      // existing
        ↓
  ReplayEngine_Run(g_EventStoreFileName)                         // existing — populates StateProjector
        ↓
  DeferredTransactionProcessor_StartupScan(g_EventStoreFileName) // NEW — C3.6 (Commit 2)
        ↓
  BrokerReconciliation_CheckAll()                                  // existing — runs on already-EXECUTED candidates
```

**Frozen**: C3.6 is a thin `OnInit`-only scan that slots between
`ReplayEngine_Run` and `BrokerReconciliation_CheckAll`. It is read-only over
the already-built read models; it does **not** re-parse the event store, does
**not** rebuild any upstream projection at runtime, and does **not** open the
daily/historical store itself. The `g_EventStoreFileName` argument is passed
for provenance/diagnostic context only; C3.6 reads from the in-memory read
models and readiness snapshots, not from the file.

---

## 4. Read-model dependencies (frozen)

C3.6 consumes only existing sealed read models and readiness snapshots. It
adds no new query API and edits no sealed projection.

| Read model | What C3.6 reads | Deterministic iteration | Readiness gate |
|---|---|---|---|
| `TransactionMatchingProjection` (C3.3) | `OrderAggregateRegistry_Count()/GetAt()` over matched orders; `TransactionDealRegistry_Count()/GetAt()` over deals; `TransactionMatching_TryGetOrderStatus(orderTicket, out)` | `Count()+GetAt()` — stable across cold rebuilds | `TransactionMatchingReadiness_IsReady()` + `TransactionMatchingReadiness_LastReport()` |
| `ExecutionRequestProjection` (C1.3) | `ExecutionRequestProjection_Count()/GetAt()` + `TryGet(execReqId, out)` → `candidate_id`, `lot_size`, provenance | `Count()+GetAt()` | staged as TransactionMatching's own upstream gate |
| `CandidateProjection` (B6) | `CandidateProjection_TryGet(candidateId, out)` → identity/lineage only (`candidate_id`, `context_event_id`, `correlation_id`) | `Count()+GetAt()` exists | `CandidateProjectionReport.ok && lines_failed==0` |
| `StateProjector` (via `ReplayEngine_Run`) | `StateProjector_TryGetState(candidateId, outState)` → sole source of `CANDIDATE_SUBMITTED` | (single lookups) | `ReplayReport.ok` (replay must have succeeded) |
| `BrokerSubmissionAuditProjection` / `ExecutionAuditProjection` | readiness only (staged as upstream gates) | — | report `.ok` with zero failed lines |

**Frozen**: C3.6 must not reparse the event store or rebuild upstream
projections at runtime. It reads the already-built in-memory read models and
the readiness snapshots those rebuilds produced.

---

## 5. Replay-failure / SafeMode semantics (frozen)

If `ReplayEngine_Run` did not succeed, or SafeMode is already engaged at the
point C3.6 would run:

```
upstream_replay_not_ready
        ↓
0 recommendations emitted
NO new SafeMode action introduced by C3.6
NO EA-initialization block introduced by C3.6
```

C3.6 fails closed on itself only. It logs a diagnostic
(`upstream_replay_not_ready`) and emits an empty recommendation set. It does
not trip SafeMode (replay already did what it needed to), does not block EA
init, and does not attempt to reinterpret or recover from a replay failure.
Candidate states are unreliable without a clean replay, so no recommendation
may be derived. This is a hard input boundary, not a tuning parameter.

---

## 6. Candidate → execution_request_id reverse index (frozen — contract, not implementation detail)

`CandidateProjectionRecord` does not carry `execution_request_id`. The
candidate→execution_request_id mapping lives on
`ExecutionRequestProjectionRecord` (`execution_request_id → candidate_id`). To
evaluate the identity-round-trip eligibility clause (§7 #4), C3.6 builds an
internal, read-only index `candidate_id → execution_request_id` from
`ExecutionRequestProjection` only.

```
ExecutionRequestProjection (sealed, read-only)
        ↓
candidate_id → execution_request_id index (internal to the new processor file)

0 mappings for a candidate  → RECOMMEND_BLOCKED
1 mapping                   → usable
>1 mappings                 → RECOMMEND_BLOCKED (collision)
```

**Frozen prohibitions**: no fallback from symbol, time, order insertion
order, or correlation inference. No sealed projection struct or API edit is
authorized to build this index — it lives entirely inside the new processor
file (per C3.5 §11). If a future round proves this internal index insufficient,
a read-only accessor may be added inside the processor file only — never to a
sealed projection.

---

## 7. Eligibility predicate (frozen — the 7 C3.5 §5 clauses, mapped to exact checks)

C3.6 may emit `RECOMMEND_EXECUTED` for a candidate **only** when every clause
holds simultaneously. These are the frozen C3.5 §5 predicates; this contract
maps each to the exact code-level check against the sealed read models.

```
1. candidate.state == CANDIDATE_SUBMITTED
   → StateProjector_TryGetState(candidateId, state) && state == CANDIDATE_SUBMITTED
   (StateProjector is the sole source; CandidateProjection only holds CREATED)

2. the candidate's execution_request_id resolved to exactly one
   OrderAggregateRecord (unique mapping, no collision)
   → the matched order's matched_execution_request_id is non-empty, AND no
     other OrderAggregateRecord has the same matched_execution_request_id

3. that OrderAggregateRecord.match_status == MATCHED_VOLUME_REACHED
   → agg.match_status == TX_MATCH_VOLUME_REACHED

4. matched_execution_request_id == candidate's execution_request_id
   (identity round-trips, NOT a fallback match)
   → build the §6 reverse index; require
     agg.matched_execution_request_id == index[candidateId]

5. no conflicting deal/order mapping for the same execution_request_id
   → re-verify no other OrderAggregateRecord resolves to the same
     matched_execution_request_id (same check as clause 2's collision guard)

6. the resolved order/volume evidence is internally consistent
   → collect all TransactionDealRecord for order_ticket; require
     count == agg.deal_count AND sum(volume) == agg.running_filled_volume
     using C3.3's existing comparison semantics (NO new epsilon unless a
     later contract freezes one); re-confirm
     running_filled_volume >= execReq.lot_size (already implied by
     MATCHED_VOLUME_REACHED, re-checked as consistency evidence)

7. no action for this candidate+terminal-action has already been applied
   (idempotency — see §11; "already applied" is scoped to "already output
   within this scan", NOT a lifecycle action)

+  upstream projections all report readiness .ok with zero failed lines
   → C3.6's DIRECT gate is TransactionMatchingReadiness_IsReady()
     && TransactionMatchingReadiness_LastReport().base.ok
     && TransactionMatchingReadiness_LastReport().base.deals_failed == 0.
     That readiness snapshot transitively proves the staged upstream
     rebuild chain (BrokerSubmissionAuditProjection_RebuildFromFile,
     which itself stages C1.3 ExecutionAuditProjection_RebuildFromFile)
     already succeeded with zero failed lines — C3.6 does NOT re-verify
     those reports individually.
   → plus ReplayReport.ok (replay must have succeeded — §5) and SafeMode
     clear (no upstream inconsistency) for candidate-state readiness.
   → C3.6 must NOT call *_RebuildFromFile() to recover individual upstream
     reports at runtime; it consumes the already-built readiness snapshots
     only.
```

**Frozen**: `candidate.state` (StateProjector) and `match_status`
(OrderAggregateRecord) are **separate immutable facts**. C3.6 must check
both; it must not conflate them, and must not infer one from the other.

If any clause fails, the result is `RECOMMEND_NONE` or `RECOMMEND_BLOCKED`
(§8), never a partial or speculative recommendation.

---

## 8. No-action / blocked predicates (frozen)

The following produce **no** `RECOMMEND_EXECUTED` and **no** lifecycle
action, unconditionally:

```
UNMATCHED                  → matched_execution_request_id == "" → RECOMMEND_NONE
AMBIGUOUS                  → multiple/uncertain mapping → RECOMMEND_BLOCKED
MATCHED_PARTIAL            → volume not yet reached → RECOMMEND_NONE (stays SUBMITTED)
MATCHED_ORDER_TERMINAL     → reserved; never acted on (C3.5 §4) → RECOMMEND_NONE
candidate.state != SUBMITTED (CREATED/terminal) → RECOMMEND_NONE
candidate.state == EXECUTED/REJECTED_BY_BROKER/ERROR → already terminal → RECOMMEND_NONE
missing or failed upstream projection readiness → RECOMMEND_BLOCKED (fail closed)
replay not ok / SafeMode engaged → scan-level failure (§5): zero output
                          rows emitted, report/log upstream_replay_not_ready; NOT modeled as a RECOMMEND_NONE row
duplicate or conflicting execution_request_id mapping → RECOMMEND_BLOCKED
candidate → execution_request_id index: 0 or >1 mappings → RECOMMEND_BLOCKED (§6)
same action_id + different payload (collision) → RECOMMEND_BLOCKED (fail closed, §11)
```

No absence of evidence (no fill yet, delay, timeout, no live position, stale
snapshot) may ever be interpreted as a rejection or as `RECOMMEND_EXECUTED`.

---

## 9. Recommendation vocabulary (frozen)

C3.6 has exactly three recommendation outcomes:

```
RECOMMEND_NONE        — eligible path not reached (partial, unmatched, wrong state)
RECOMMEND_EXECUTED    — all 7 eligibility clauses hold; a recommendation row only
RECOMMEND_BLOCKED     — fail-closed: collision, ambiguity, missing readiness,
                        inconsistent evidence, index conflict
```

**Frozen prohibition**: `RECOMMEND_REJECTED` must **not** exist in this round
as an enum member, an output row, an event, a side effect, or a reserved
emitted value. It remains a C3.5 §7 reserved, non-emittable status under
current inputs. A deferred rejection authority, if ever needed, requires a
later terminal-order and/or recovery contract (C4) that freezes a durable,
sealed rejection-evidence source first.

---

## 10. DeferredRecommendationRecord (frozen — exact field set)

```
struct DeferredRecommendationRecord
{
   string action_id;                          // §11 deterministic identity (EXECUTED rows only)
   string candidate_id;
   string execution_request_id;
   ulong  order_ticket;
   ulong  deal_tickets[];                     // sorted ascending, for this order_ticket
   ENUM_TX_MATCH_STATUS terminal_match_status; // == TX_MATCH_VOLUME_REACHED for EXECUTED rows
   ENUM_CANDIDATE_STATE candidate_state_evidence; // == CANDIDATE_SUBMITTED for EXECUTED rows
   double running_filled_volume;              // consistency evidence (clause 6)
   int    deal_count;                         // consistency evidence (clause 6)
   double intended_lot_size;                 // from ExecutionRequestProjection
   ENUM_RECOMMENDATION recommended_action;     // NONE | RECOMMEND_EXECUTED | RECOMMEND_BLOCKED
   string reason_code;                        // stable reason for NONE/BLOCKED
   // provenance — execution-request source (where the read-model API exposes them):
   long   execution_request_source_sequence_number; // from ExecutionRequestProjection record
   string execution_request_source_log_event_id;    // from ExecutionRequestProjection record
   // provenance — per-deal source, aligned 1:1 with sorted deal_tickets[]:
   long   deal_source_sequence_numbers[];            // from TransactionDealRecord, per deal_ticket
   string deal_source_log_event_ids[];               // from TransactionDealRecord, per deal_ticket
   // candidate lineage (provenance promise, from CandidateProjection):
   string candidate_root_event_id;                  // CandidateProjectionRecord.root_event_id
   string context_event_id;                         // CandidateProjectionRecord.context_event_id
   // session-scope diagnostic (stale-after-OnInit marker, NOT an action_id input):
   datetime evaluated_at;                     // TimeCurrent() at scan — diagnostic only
   bool   stale_after_startup;                // always true under Option A (C3.5 §10)
};
```

`ENUM_RECOMMENDATION` members are exactly `RECOMMEND_NONE`,
`RECOMMEND_EXECUTED`, `RECOMMEND_BLOCKED`. `RECOMMEND_REJECTED` is not a
member (§9). `action_id` is populated for `RECOMMEND_EXECUTED` rows only; for
`NONE`/`BLOCKED` rows it is empty. No wall-clock, session ID, line number, or
log text enters `action_id`.

---

## 11. Deterministic action identity (frozen)

`action_id` must be derived from immutable evidence identity only — never from
a wall-clock, session ID, registry counter, file line number, rebuild order,
log text, or `rebuilt_at`.

```
action_id =
   "C36|EXECUTED|"
   + candidate_id + "|"
   + execution_request_id + "|"
   + IntegerToString(order_ticket) + "|"
   + "MATCHED_VOLUME_REACHED|"
   + "[" + join(sorted_asc(deal_tickets), ",") + "]"
   + "|v1"
```

The `v1` suffix is a contract-version prefix, stable until a contract change
explicitly bumps it. The sorted deal-ticket set is derived by filtering
`TransactionDealRegistry` by `order_ticket` and sorting ascending —
deterministic across cold rebuilds.

**Frozen exclusions**: no `TimeCurrent()`, no session ID, no array insertion
order, no rebuild line number, no log text, no `rebuilt_at`
(`TransactionMatchingReadinessReport.rebuilt_at` is `TimeCurrent()` and is
correctly excluded).

---

## 12. Idempotency, duplicates, and collision (frozen — adjusted from C3.5 §9)

C3.6 is a **from-scratch startup scan** that resets its internal
recommendation registry before every scan. The contract distinguishes:

```
duplicates WITHIN the same scan:
  same action_id + identical payload
    → collapse to ONE output row
    → increment a duplicate-input/recommendation evidence counter
    → NOT a second recommendation

across cold scans (restart):
  registry resets before each scan
    → the same semantic output is reconstructed once
    → NOT treated as a durable already-applied action

collision (same action_id + DIFFERENT payload):
  → fail closed → RECOMMEND_BLOCKED
  → no recommendation emitted for that candidate
  → reported in the C3.6 report's first_error
```

**Frozen**: the word "already applied" must **not** mean a lifecycle action in
C3.6. C3.6 emits no action event and performs no transition; "already
applied" is scoped strictly to "already output within this scan". This prevents
accidentally importing C3.7 lifecycle-authority semantics into C3.6. A
duplicate run/replay that observes the same evidence must yield the same
`action_id` and must not produce a second recommendation row — mirroring the
C2.3 `BrokerSubmissionAuditProjection` idempotency precedent (exact-duplicate
line replay = no-op; hash collision with differing payload = fail-closed
rebuild).

---

## 13. Semantic output ordering (frozen)

The recommendation registry's `Count()/GetAt()` iteration order is a frozen
semantic sort. C3.6 must **not** rely on file order or projection insertion
order for output ordering:

```
candidate_id ASC
  → execution_request_id ASC
    → order_ticket ASC
      → sorted deal-ticket set / action_id ASC
```

This makes the cold-rebuild determinism test (test #8: cold rebuild from the
same store → identical result set **and** identical order) provable.

---

## 14. Stale-after-OnInit (frozen — reaffirms C3.5 §10)

C3.4's read model is an `OnInit`-only startup snapshot, explicitly stale after
`OnInit` (Phase C contract §26). C3.6 inherits this exactly:

```
No periodic full-file rebuild inside OnTick.
No incremental update triggered from OnTradeTransaction.
No timer, no background queue, no incremental matching update.
```

The recommendation read model is a snapshot produced once at startup and never
updated until the next restart. This is the same trigger model C3.5 §10 froze
as Option A. Options B (operator-triggered diagnostic scan) and C (a future
incremental processor event queue) remain explicitly deferred and require
separate authorization.

---

## 15. Implementation allowlist (frozen — for the separately authorized Commit 2)

The C3.6 implementation round (Commit 2) is authorized only to:

```
Add Include/MLQuantAI/Execution/MLQuantAI_DeferredTransactionProcessor.mqh (new file).
Add Tests/MLQuantAI_Test_C3_6_DeferredTransactionProcessor.mq5 (new file).
Edit MLQuantAI.mq5 OnInit wiring ONLY:
  insert one DeferredTransactionProcessor_StartupScan(g_EventStoreFileName)
  call between ReplayEngine_Run and BrokerReconciliation_CheckAll.
Read only from sealed projections (no struct/API edit):
  Include/MLQuantAI/Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh,
  Include/MLQuantAI/Execution/MLQuantAI_ExecutionAuditProjection.mqh,
  Include/MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAuditProjection.mqh,
  Include/MLQuantAI/Execution/MLQuantAI_TransactionMatchingProjection.mqh,
  Include/MLQuantAI/Infrastructure/EventStore/MLQuantAI_StateProjector.mqh
  (via Include/MLQuantAI/Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh),
  Include/MLQuantAI/Execution/MLQuantAI_TransactionMatchingReadiness.mqh.
Build the internal candidate_id → execution_request_id index inside the
  new processor file only (per C3.5 §11 and §6 of this contract).
Produce a read-only DeferredRecommendationRecord / report only.
```

**Frozen prohibitions (Commit 2 must not)**: append any lifecycle event; call
`EventStore_LogTransition`; mutate any sealed projection's state; introduce a
new `ENUM_EVENT_TYPE` value; add `RECOMMEND_REJECTED`; reparse the event store
or rebuild upstream projections at runtime; open the daily/historical store
directly; add any `OnTick`/`OnTradeTransaction` logic; call any
`History*`/`Position*`/`Order*`/`OrderSend`/`CTrade` API.

---

## 16. Validation matrix (frozen — for Commit 2, design-only here)

The Commit 2 merge gate must pass, with two identical all-pass runs:

```
new C3.6 suite (Tests/MLQuantAI_Test_C3_6_DeferredTransactionProcessor.mq5) — ALL PASS
C3.3 TransactionMatchingProjection suite: 109/109
C3.4 TransactionMatchingReadiness suite:  57/57
C2.3 BrokerSubmissionAuditProjection suite: 104/104
C2 baseline (6 suites): 448/448
main EA (MLQuantAI.mq5) compile: 0 errors / 0 warnings
new C3.6 test compile: 0 errors / 0 warnings
static prohibited-API scan of Execution/MLQuantAI_DeferredTransactionProcessor.mqh:
  zero hits for EventStore_LogTransition, OrderSend, CTrade, HistorySelect,
  PositionSelect, OrderSelect, OnTick, OnTradeTransaction, RECOMMEND_REJECTED
```

After C3.6 Commit 2 merge: no candidate transition and no action event exist.
C3.7 remains blocked until C3.6 evidence is clean.

---

## 17. Required test matrix for Commit 2 (design-only — no test file authorized here)

At minimum, the future C3.6 suite must prove:

```
1.  full match + SUBMITTED candidate → RECOMMEND_EXECUTED
2.  partial fill → RECOMMEND_NONE (no terminal recommendation)
3.  unmatched → RECOMMEND_NONE
4.  ambiguous → RECOMMEND_BLOCKED, observable
5.  candidate no longer SUBMITTED (CREATED/terminal) → RECOMMEND_NONE
6.  outcome maps to wrong/multiple candidates → RECOMMEND_BLOCKED (fail closed)
7.  duplicate rerun within same scan → same action_id, collapsed to one row
8.  cold rebuild from same store → identical result set AND order
9.  missing upstream projection readiness → RECOMMEND_BLOCKED (fail closed)
10. replay not ok / SafeMode engaged → zero recommendations (upstream_replay_not_ready)
11. candidate→exec-request index: 0 mappings → RECOMMEND_BLOCKED
12. candidate→exec-request index: >1 mappings → RECOMMEND_BLOCKED
13. same action_id + different payload (collision) → RECOMMEND_BLOCKED, reported
14. MATCHED_ORDER_TERMINAL input → RECOMMEND_NONE (reserved, never acted on)
15. RECOMMEND_REJECTED is not an enum member, not an output row, not emitted
16. no forbidden API anywhere in the new processor file (static scan)
17. deterministic output ordering across two cold rebuilds
18. stale-after-OnInit: no OnTick/OnTradeTransaction update path exists
```

---

## 18. Acceptance criteria for this docs-only commit (frozen)

```
1. This document added under Docs/.
2. A CHANGELOG entry marked DESIGN ONLY / docs-only.
3. Diff is exactly two files: this doc + CHANGELOG.md.
4. No .mqh/.mq5 source file changed.
5. No sealed file touched.
6. No new ENUM_EVENT_TYPE value.
7. No implementation, no test, no MLQuantAI.mq5 wiring, no compile, no run.
8. advisor final review confirms: the startup placement, the replay-failure
   semantics, the 7 eligibility predicates, the candidate→exec-request
   reverse-index rules, the recommendation vocabulary, the action_id
   algorithm, the idempotency/duplicate/collision behavior, the output
   ordering, the stale-after-OnInit boundary, the zero-authority/zero-
   mutation boundary, and the RECOMMEND_REJECTED prohibition are each frozen
   and internally consistent with the sealed C1–C3.4 codebase and the frozen
   C3.5 contract.
9. Explicit user merge authorization (no auto-merge).
```

---

## 19. Future gates (deferred — not authorized here)

```
C3.7 - bounded lifecycle authority: contract-first freeze of the event type
       (new vs reuse EventStore_LogTransition), idempotency key bound to
       candidate + terminal action + immutable broker evidence identity,
       replay behavior (no duplicate transition on restart), action audit
       trail, conflict policy, fail-closed behavior, and Safe Mode policy
       (ambiguity alone is not an auto Safe Mode trigger unless a new
       integrity-violation category is frozen). Authorized only after C3.6
       evidence is clean. C3.7 is the SOLE round permitted to turn a C3.6
       RECOMMEND_EXECUTED into a real SUBMITTED → EXECUTED transition.
C3.8 - reconciliation integration.
C4   - recovery / broker-history policy.
C5   - controlled execution rollout.
C6   - position/exit lifecycle.
C7   - operational hardening.
```

---

## Hard safety rules carried forward (frozen, unchanged from C3.5)

```
No lifecycle transition from UNMATCHED, AMBIGUOUS, or PARTIAL evidence.
OrderSend success is never proof of fill.
No position-ticket identity inference for deal/order matching.
No silent history backfill.
No full-file periodic OnTick rebuild.
No raw callback becoming business authority.
RECOMMEND_EXECUTED is a recommendation, not a transition.
"Already applied" means "already output within this scan", not a lifecycle action.
No merge without contract, scope allowlist, tests, compile clean, and
  post-merge verification.
```
