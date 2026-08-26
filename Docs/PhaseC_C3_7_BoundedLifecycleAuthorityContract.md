# C3.7 bounded lifecycle authority design contract (documentation only)

**Status**: DESIGN ONLY, docs-only, frozen. No `.mqh`/`.mq5` file, no test
file, no `MLQuantAI.mq5` wiring, no new `ENUM_EVENT_TYPE` value, no new
`ENUM_REASON_CODE` value, no new projection struct/API, no edit to any
sealed file (`StateMachine.mqh`, `EventStore.mqh`, `StateProjector.mqh`,
`ReplayEngine.mqh`, `CandidateProjection.mqh`,
`TransactionMatchingProjection.mqh`, `MLQuantAI_DeferredTransactionProcessor.mqh`,
`BrokerReconciliation.mqh`), no `History*`/`Position*`/`Order*` API, no
`OrderSend`/`CTrade`, no compile, no test run, no regression. Each of
those remains its own, separately authorized future step (C3.7
implementation Commit 2, C3.8 reconciliation integration, C4
recovery/history policy).

**Baseline**: `mlquantai@b2751c9` (C1–C3.6 sealed; C3.6
`DeferredTransactionProcessor` produces `RECOMMEND_EXECUTED` /
`RECOMMEND_NONE` / `RECOMMEND_BLOCKED` read-only recommendation rows
only — zero lifecycle authority, zero event append, zero projection
mutation).

**Predecessor**: this contract refines, and does not contradict, the
frozen C3.5 deferred-transaction-authority design contract
(`Docs/PhaseC_C3_5_DeferredAuthorityContract.md`) and the frozen C3.6
deferred-transaction-processor contract
(`Docs/PhaseC_C3_6_DeferredTransactionProcessorContract.md`). Where this
document is silent, C3.5/C3.6 govern. One explicit, frozen deviation
from C3.5 §9's own default assumption is recorded in section 9 below.

---

## 1. Purpose and the boundary this contract freezes

C3.6 turns sealed transaction-matching evidence into a read-only
`RECOMMEND_EXECUTED` / `RECOMMEND_NONE` / `RECOMMEND_BLOCKED`
recommendation row. It has no lifecycle authority. C3.7 is the **sole**
component authorized to turn a `RECOMMEND_EXECUTED` row into a real,
durable `CANDIDATE_SUBMITTED → CANDIDATE_EXECUTED` lifecycle transition,
via the existing sealed `EventStore_LogTransition()` — the same
production write path C2.2's `BrokerSubmissionAdapter` already uses for
`CANDIDATE_SUBMITTED`/`CANDIDATE_REJECTED_BY_BROKER`.

```
C3.6                                C3.7
RECOMMEND_EXECUTED  ---evidence--->  re-validate live state
(recommendation row,                 EventStore_LogTransition(
 NOT an authority)                     CANDIDATE_SUBMITTED -> CANDIDATE_EXECUTED)
```

**Frozen**: `RECOMMEND_EXECUTED` is **necessary input evidence only**,
never write-time authority on its own. Before calling
`EventStore_LogTransition`, C3.7 must independently re-validate:

```
1. upstream readiness is still the same clean scan C3.6 itself gated on
   (no re-derivation, no *_RebuildFromFile call - C3.7 reads the same
   already-built readiness snapshot C3.6 already validated this pass)
2. current StateProjector state for this candidate_id == CANDIDATE_SUBMITTED
   (a FRESH StateProjector_TryGetState() call - never
   DeferredRecommendationRecord.candidate_state_evidence, which is a
   C3.6-scan-time snapshot, not a write-time authority)
3. a CandidateProjection record exists for this candidate_id
4. the recommendation row's candidate_id / execution_request_id /
   order_ticket / deal_tickets[] provenance is structurally complete
   (non-empty action_id, non-empty execution_request_id, order_ticket != 0)
```

If any of these four fail, C3.7 skips the row - no transition, no
error, no Safe Mode (see section 10).

---

## 2. Scope guard (frozen)

```
Docs only. This commit changes exactly two files:
  - Docs/PhaseC_C3_7_BoundedLifecycleAuthorityContract.md (this file, new)
  - CHANGELOG.md (docs-only entry, DESIGN ONLY)
No new .mqh/.mq5 file. No test file. No MLQuantAI.mq5 wiring. No edit to
any sealed file (StateMachine, EventStore, StateProjector, ReplayEngine,
CandidateProjection, TransactionMatchingProjection,
MLQuantAI_DeferredTransactionProcessor.mqh, BrokerReconciliation.mqh,
BrokerSubmissionAdapter). No new ENUM_EVENT_TYPE value. No new
ENUM_REASON_CODE value. No new projection struct field or query API. No
OnTick/OnTradeTransaction change. No History*/Position*/Order* API. No
OrderSend/CTrade. No compile, no test run, no regression.
```

The implementation round (C3.7 Commit 2) is a separately authorized
step. This document freezes the contract and the handoff boundary to
that round only.

---

## 3. Startup placement (frozen — adopts synchronous `StateProjector` sync)

C3.5 §10 and C3.6 §3 both fix C3.6 as an `OnInit`-only scan running after
`ReplayEngine_Run`. C3.7 extends the same `OnInit` chain, immediately
after C3.6, with one explicit new element: a successful durable
transition is synchronously applied to the in-memory `StateProjector` so
that `BrokerReconciliation_CheckAll()` — which reads `StateProjector`'s
own registry directly — sees this session's own fresh `EXECUTED`
candidates, rather than waiting a full restart cycle to reconcile them
against the real broker position.

```
OnInit:
  TransactionMatching_StartupRebuild(g_EventStoreFileName)        // existing — C3.4
        v
  EventStore_LogSystem(SYSTEM_STARTED, ...)                       // existing
        v
  ReplayEngine_Run(g_EventStoreFileName)                          // existing — populates StateProjector
        v
  DeferredTransactionProcessor_StartupScan(g_EventStoreFileName)  // existing — C3.6
        v
  LifecycleAuthority_StartupApply(g_EventStoreFileName)           // NEW — C3.7 (Commit 2)
        v
  BrokerReconciliation_CheckAll()                                   // existing — now also sees THIS
                                                                       session's fresh EXECUTED candidates
```

**Frozen sequence inside the new C3.7 step, per recommendation row**:

```
1. EventStore_LogTransition(candidate, CANDIDATE_EXECUTED, REASON_EXECUTED_OK, extraJson)
2. IF step 1 fails (durable write failure):
     - do NOT apply anything locally
     - candidate's in-memory state is left untouched by EventStore_LogTransition
       itself (sealed behavior, unchanged)
     - inherited SafeMode behavior applies (EventStore_LogTransition's own
       SafeMode_Trip call on durable-write failure - unchanged, unmodified)
     - continue to the NEXT recommendation row (this row's failure does not
       abort the whole scan - see section 10)
3. IF step 1 succeeds:
     - StateProjector_Apply(the exact same LifecycleEvent EventStore_LogTransition
       just wrote) — keeps the in-memory read model consistent with the
       durable log within this same session
4. IF step 3 fails after step 1 already succeeded (durably written but the
   local projector could not apply it):
     - engage Safe Mode immediately (SafeMode_Trip - a genuine event-log/
       read-model divergence, the exact class of inconsistency Safe Mode
       exists to catch)
     - STOP processing further recommendation rows in this scan
     - do NOT run BrokerReconciliation_CheckAll() this session (the
       StateProjector this reconciliation pass would read is now known to
       be inconsistent with the durable log - reconciling against a
       provably wrong read model would be worse than skipping it, matching
       the existing project-wide principle "never trade/reconcile on a
       belief that might be wrong")
```

**Frozen**: C3.7 does **not** edit `BrokerReconciliation.mqh`. Its only
effect on reconciliation is (a) where in `OnInit` it sits relative to it,
and (b) whether it lets that step run at all after a local
`StateProjector_Apply` failure (case 4 above). This is a placement/order
decision made in `MLQuantAI.mq5`'s `OnInit`, not a change to
`BrokerReconciliation.mqh` itself — but it is a real, explicit expansion
of what `BrokerReconciliation_CheckAll()` effectively sees this session,
and the C3.7 implementation's own header comment must say so plainly, so
a future reader auditing `BrokerReconciliation.mqh` in isolation does not
miss it.

---

## 4. Read-model dependencies (frozen)

C3.7 consumes only existing sealed read models and the C3.6 recommendation
registry produced earlier in the same `OnInit` pass. It adds no new query
API and edits no sealed projection.

| Read model | What C3.7 reads | Purpose |
|---|---|---|
| `MLQuantAI_DeferredTransactionProcessor` (C3.6) | `DeferredTransactionProcessor_Count()/GetAt()` | source recommendation rows; act only on `RECOMMEND_EXECUTED` |
| `StateProjector` | `StateProjector_TryGetState(candidateId, out)` | sole authoritative live-state source (section 1, clause 2) |
| `CandidateProjection` | `CandidateProjection_TryGet(candidateId, out)` | identity/lineage fields for `TradeCandidate` assembly (section 6) — **never** its `.state` field, which is always `CANDIDATE_CREATED` in this B6-only projection |

**Frozen**: C3.7 must not reparse the event store or rebuild any
upstream projection at runtime (no `*_RebuildFromFile` call of any kind),
matching C3.6's own established discipline.

---

## 5. Action selection (frozen)

```
for each row in DeferredTransactionProcessor's registry (C3.6 output):
   if row.recommended_action != RECOMMEND_EXECUTED: skip, no transition call
   else: attempt the transition (section 1's four re-validation clauses,
         then section 3's transition sequence)
```

`RECOMMEND_NONE` and `RECOMMEND_BLOCKED` rows are never passed to
`EventStore_LogTransition` under any circumstance. This is a structural
guarantee, not a runtime check to get wrong: the loop itself only enters
the transition path for `RECOMMEND_EXECUTED` rows.

---

## 6. Candidate assembly (frozen — two-source reconstruction)

`EventStore_LogTransition(TradeCandidate &c, to, reason, extraJson)`
derives its own legality check from `c.state` — the **caller-supplied**
value, not an authoritative source of its own (verified directly in
`MLQuantAI_EventStore.mqh`). Unlike the C2.2 precedent (where the
`TradeCandidate` object is held continuously in memory from its own
`CANDIDATE_CREATED` genesis through submission, all within one session),
C3.7's candidate may have reached `CANDIDATE_SUBMITTED` in an *earlier*
session. There is no live object to reuse — C3.7 must assemble a fresh
`TradeCandidate` from two separate sealed sources, joined by
`candidate_id`:

```
candidate_id / root_event_id / correlation_id / strategy_id
   <- CandidateProjection_TryGet(candidateId, out)

.state
   <- StateProjector_TryGetState(candidateId, out)   (section 1, clause 2 -
      the ONLY authoritative source; CandidateProjectionRecord.state is
      NEVER used for this purpose - it is always CANDIDATE_CREATED)
```

**Frozen prohibition**: no field of the assembled `TradeCandidate` other
than `.state` may be sourced from anything other than
`CandidateProjection` (no inference, no fallback, no reuse of a stale
in-memory object across a restart boundary).

---

## 7. Transition call contract (frozen)

```
EventStore_LogTransition(
   candidate,                    // assembled per section 6
   CANDIDATE_EXECUTED,           // existing, sealed ENUM_CANDIDATE_STATE
   REASON_EXECUTED_OK,           // existing, sealed ENUM_REASON_CODE -
                                  // currently unused by any production
                                  // emitter; C3.7 is its first real caller
   extraJson                     // frozen shape below
)
```

No new `ENUM_EVENT_TYPE` value is needed:
`EventTypeForCandidateState(CANDIDATE_EXECUTED)` already resolves to the
existing, sealed `EVENT_TYPE_CANDIDATE_EXECUTED`.

**Frozen `extra_json` field set** (provenance promise — the durable
audit trail for *why* this transition happened, per this codebase's
established "extra_json is the only place non-native fields live"
convention):

```
c3_7_schema_version
c3_6_action_id
execution_request_id
order_ticket
deal_tickets_sorted
terminal_match_status                      // == "MATCHED_VOLUME_REACHED"
running_filled_volume
intended_lot_size
execution_request_source_log_event_id
execution_request_source_sequence_number
deal_source_log_event_ids_sorted
deal_source_sequence_numbers_sorted
```

Every field on this list is already present on C3.6's own
`DeferredRecommendationRecord` for an `RECOMMEND_EXECUTED` row — C3.7
copies them through verbatim, it does not recompute or re-derive any of
them.

---

## 8. Idempotency (frozen — explicit deviation from C3.5 §9's default)

**Frozen decision: no new durable idempotency registry.** C3.5 §9 sketched
mirroring the C2.3 `BrokerSubmissionAuditProjection` registry precedent
(`*Registry_HasAttempt()`-style durable dedup) as the default assumption
for a future lifecycle-authority round. This contract explicitly
supersedes that default: **the sealed terminal-state guard, combined
with C3.6's own upstream guarantees, is a complete idempotency story for
this specific transition**, and adding a parallel durable registry would
be redundant machinery, not defense-in-depth.

```
C3.6 (sealed, already tested):
   at most one RECOMMEND_EXECUTED row per candidate_id per scan
   (action_id embeds candidate_id; CandidateProjection's own sealed
   genesis-uniqueness guard prevents a duplicate candidate_id from ever
   appearing twice in one scan)

C3.7 (this contract):
   fresh StateProjector state must equal CANDIDATE_SUBMITTED
   immediately before the transition call (section 1, clause 2)

StateMachine (sealed, unchanged):
   CANDIDATE_SUBMITTED -> CANDIDATE_EXECUTED is legal exactly once
   CANDIDATE_EXECUTED is terminal - StateMachine_CanTransition(EXECUTED, *)
   is always false, for every possible target including EXECUTED itself

Restart:
   ReplayEngine_Run correctly reconstructs CANDIDATE_EXECUTED from the
   durable log
   C3.6's next scan sees state == CANDIDATE_EXECUTED (not SUBMITTED),
   fails its own clause 1, emits RECOMMEND_NONE (candidate_not_submitted)
   C3.7 therefore never receives a RECOMMEND_EXECUTED row for this
   candidate_id again - there is nothing left to transition
```

**Frozen scope note**: this reasoning is a property of **this specific,
terminal transition** (`SUBMITTED → EXECUTED`), not a generic,
reusable idempotency abstraction. A future round introducing a
**non-terminal** lifecycle authority (there is none currently
authorized or contemplated) would need its own idempotency analysis from
first principles — this contract's conclusion must not be cited as
precedent for a transition that does not terminate the state machine.

---

## 9. Failure semantics (frozen)

| Condition | Required behavior |
|---|---|
| C3.6 row is `RECOMMEND_NONE` / `RECOMMEND_BLOCKED` | Skip; `EventStore_LogTransition` is never called for this row |
| Section 1's re-validation fails (state absent, not `SUBMITTED`, `CandidateProjection` missing, or provenance incomplete) | Skip; no transition call; move to the next row |
| `EventStore_LogTransition` returns `false` (durable write failure) | Candidate's in-memory state is left untouched (sealed `EventStore_LogTransition` behavior, unchanged); inherited `SafeMode_Trip` already fires inside `EventStore_LogTransition` itself; C3.7 continues to the next row (this row's failure alone does not abort the whole scan) |
| `EventStore_LogTransition` returns `true` but the subsequent `StateProjector_Apply` fails | Engage Safe Mode immediately (a genuine event-log/read-model divergence); **stop** processing further rows this scan; do **not** run `BrokerReconciliation_CheckAll()` this session (section 3) |
| Every attempted transition + local apply succeeds (including the case of zero `RECOMMEND_EXECUTED` rows this scan) | `BrokerReconciliation_CheckAll()` runs as usual, immediately after |

**Frozen**: unlike C3.6 (which never engages Safe Mode and never blocks
EA initialization — it has zero lifecycle authority, so a scan-level
failure there is diagnostic-only), C3.7 **can** engage Safe Mode as a
normal, expected consequence of its own operation, because it is the
first component in the C3.2→C3.6 chain that calls a real, durably
mutating API. This is an inherited property of `EventStore_LogTransition`
itself (unchanged, unmodified), not a new decision this contract
introduces — but it must be stated explicitly here so it is never
mistaken for a regression of C3.6's "fails closed on itself only"
guarantee.

---

## 10. Observability (frozen)

```
If, after C3.6's scan, blocked_count > 0:
   LogWarn("C3.7 lifecycle authority: <N> recommendation(s) blocked; "
           "no blocked row was transitioned.")
```

Exactly one summary `LogWarn`, never per-row detail (matching the
established C3.4 AMBIGUOUS-summary / C3.6 blocked-count-in-LogInfo
pattern). `RECOMMEND_NONE` rows never produce a warning - `NONE` is an
expected, non-terminal condition (partial fill, no fill yet, wrong
state), not an anomaly. This warning is diagnostic only: it does not
engage Safe Mode, does not block EA initialization, and does not read
any broker/History/Position/Order API.

A lightweight, session-scope, **in-memory** report struct (mirroring
`DeferredTransactionProcessorReport`'s own shape: counts of
attempted/succeeded/skipped rows) is the natural observability surface
for this step. It is not a new durable read model or registry (section
8) — purely a diagnostic snapshot, discarded at the next restart, same
"stale after OnInit" posture as every other C3.x read model in this
chain.

---

## 11. Hard prohibitions (frozen — Commit 2 must not)

```
Reparse the event store or rebuild any upstream projection at runtime
  (no *_RebuildFromFile call of any kind).
Open the daily/historical store directly.
Call any History*/Position*/Order*/OrderSend/CTrade API.
Add any OnTick/OnTradeTransaction logic.
Introduce a new ENUM_EVENT_TYPE value.
Introduce a new ENUM_REASON_CODE value.
Add RECOMMEND_REJECTED handling of any kind - it remains a C3.5 §7 /
  C3.6 §9 reserved, non-emittable status under current inputs.
Edit BrokerReconciliation.mqh, CandidateProjection.mqh, StateProjector.mqh,
  StateMachine.mqh, EventStore.mqh, ReplayEngine.mqh, or
  MLQuantAI_DeferredTransactionProcessor.mqh in any way.
Add a durable idempotency registry (section 8's frozen deviation from
  the C3.5 §9 default).
Act on a RECOMMEND_NONE or RECOMMEND_BLOCKED row.
Trust DeferredRecommendationRecord.candidate_state_evidence as write-time
  authority - a fresh StateProjector_TryGetState() call is mandatory
  immediately before every transition attempt.
```

---

## 12. Required test matrix for Commit 2 (design-only — no test file authorized here)

At minimum, the future C3.7 suite must prove:

```
1.  a fully eligible RECOMMEND_EXECUTED row -> real CANDIDATE_EXECUTED
    transition durably written, correctly replayable, extra_json carries
    every frozen provenance field
2.  RECOMMEND_NONE / RECOMMEND_BLOCKED rows -> EventStore_LogTransition
    is never called (structural proof + a behavioral assertion: zero new
    lifecycle lines beyond the expected EXECUTED ones)
3.  candidate already CANDIDATE_EXECUTED at write time (defensive,
    structurally near-unreachable given C3.6's own clause 1 - still
    proven fail-closed, no duplicate transition, no Safe Mode)
4.  candidate state missing / not SUBMITTED at write time -> skip, no
    transition, no Safe Mode
5.  CandidateProjection record missing for a would-be-EXECUTED row ->
    skip, no transition, no Safe Mode
6.  durable write failure (EventStore_LogTransition returns false) ->
    inherited SafeMode_Trip, candidate state untouched, scan continues to
    the next row
7.  StateProjector_Apply failure after a successful durable write ->
    SafeMode_Trip, scan stops immediately, BrokerReconciliation_CheckAll
    is NOT invoked that session
8.  cold restart idempotency: run the full OnInit chain (through C3.7)
    twice against the same store - the second pass produces ZERO new
    lifecycle transitions for any already-EXECUTED candidate
9.  BrokerReconciliation_CheckAll, run AFTER a successful C3.7 pass, sees
    this session's own freshly-EXECUTED candidate (via the synchronous
    StateProjector_Apply, section 3) - not just prior-session EXECUTED
    candidates
10. blocked_count > 0 -> exactly one summary LogWarn, never per-row
11. no forbidden API anywhere in the new processor file (static scan:
    OrderSend/CTrade/History*/Position*/OnTick/OnTradeTransaction)
12. no RECOMMEND_REJECTED handling anywhere (static scan)
13. extra_json round-trips every frozen provenance field exactly
    (execution_request_id/order_ticket/deal_tickets_sorted/
    terminal_match_status/running_filled_volume/intended_lot_size/
    source log-event-id and sequence-number fields)
```

Validation gate for the future Commit 2 merge (frozen, mirroring C3.6's
own §16): new C3.7 suite + C3.6 suite (146/146) + C3.3 suite (109/109) +
C3.4 suite (57/57) + full C2 regression baseline (448/448) +
`MLQuantAI.mq5` compile 0 errors/0 warnings + new C3.7 test compile 0
errors/0 warnings + static prohibited-API scan of the new processor file,
with two identical all-pass runs.

---

## 13. Implementation allowlist (frozen — for the separately authorized Commit 2)

```
Include/MLQuantAI/Execution/MLQuantAI_LifecycleAuthorityProcessor.mqh (new file)
Tests/MLQuantAI_Test_C3_7_LifecycleAuthorityProcessor.mq5 (new file)
Edit MLQuantAI.mq5 OnInit wiring ONLY:
  insert one LifecycleAuthority_StartupApply(g_EventStoreFileName) call
  between DeferredTransactionProcessor_StartupScan and
  BrokerReconciliation_CheckAll (section 3's frozen placement).
Read only from sealed read models (no struct/API edit):
  Include/MLQuantAI/Execution/MLQuantAI_DeferredTransactionProcessor.mqh,
  Include/MLQuantAI/Infrastructure/EventStore/MLQuantAI_StateProjector.mqh,
  Include/MLQuantAI/Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh.
Call only these existing sealed write/apply functions (no wrapper, no
  reimplementation):
  EventStore_LogTransition() (Infrastructure/EventStore/MLQuantAI_EventStore.mqh),
  StateProjector_Apply() (Infrastructure/EventStore/MLQuantAI_StateProjector.mqh).
```

The name `MLQuantAI_LifecycleAuthorityProcessor.mqh` is deliberate: it
names the file by its role (the sole component holding bounded lifecycle
authority), not by its phase number, matching how
`MLQuantAI_BrokerReconciliation.mqh`/`MLQuantAI_StateProjector.mqh` are
already named by role rather than phase.

---

## 14. Future gates (deferred — not authorized here)

```
C3.8 - reconciliation integration: preserve the three-way ownership
       separation established since C3.5 (BrokerReconciliation /
       TransactionMatchingProjection / the lifecycle-authority
       processor); add submitted-candidate visibility (matching status +
       recommendation + age/unresolved diagnostic); absence of a live
       position is never a broker rejection; restart-scenario fixture
       coverage (before deal observation, after partial fill, after
       full-fill observation before action, after action emission,
       duplicate/reordered raw facts, current-day vs archived store).
C4   - recovery / broker-history policy: decide recovery authority
       (recommended: EventStore authoritative, history diagnostic-only).
       No silent overwrite of C3.2 raw facts; recovered-fact provenance;
       no lifecycle authority until recovered-fact semantics are sealed.
C5   - controlled execution rollout.
C6   - position/exit lifecycle.
C7   - operational hardening.
```

---

## 15. Acceptance criteria for this docs-only commit (frozen)

```
1. This document added under Docs/.
2. A CHANGELOG entry marked DESIGN ONLY / docs-only.
3. Diff is exactly two files: this doc + CHANGELOG.md.
4. No .mqh/.mq5 source file changed.
5. No sealed file touched.
6. No new ENUM_EVENT_TYPE value. No new ENUM_REASON_CODE value.
7. No implementation, no test, no MLQuantAI.mq5 wiring, no compile, no run.
8. Reviewer confirms: the authority-boundary/re-validation clauses
   (section 1), the startup placement + synchronous StateProjector-apply
   ordering (section 3), the candidate-assembly rule (section 6), the
   transition call contract + extra_json field set (section 7), the
   idempotency deviation from C3.5 §9's default (section 8), the failure
   semantics table (section 9), the observability rule (section 10), and
   the RECOMMEND_REJECTED prohibition are each frozen and internally
   consistent with the sealed C1–C3.6 codebase and the frozen C3.5/C3.6
   contracts.
9. Explicit user merge authorization (no auto-merge).
```

---

## Hard safety rules carried forward (frozen, unchanged from C3.5/C3.6)

```
No lifecycle transition from UNMATCHED, AMBIGUOUS, or PARTIAL evidence.
OrderSend success is never proof of fill.
No position-ticket identity inference for deal/order matching.
No silent history backfill.
No full-file periodic OnTick rebuild.
No raw callback becoming business authority.
RECOMMEND_EXECUTED is a recommendation; the transition it authorizes is
  written exactly once, by C3.7 alone, per the rules in this document.
DeferredRecommendationRecord.candidate_state_evidence is evidence, never
  write-time authority - StateProjector_TryGetState() is re-checked fresh
  immediately before every transition attempt.
"Already applied" (C3.6's own idempotency scoping, section 12 of the
  C3.6 contract) means "already output within that scan" - it is a
  DIFFERENT guarantee from C3.7's own idempotency story (section 8 of
  this document), which rests on the sealed terminal-state guard, not on
  a scan-scoped in-memory dedup.
No merge without contract, scope allowlist, tests, compile clean, and
  post-merge verification.
```
