# Phase 0.3 fixture-debt gate decision contract (documentation only)

**Status**: DESIGN ONLY, frozen as a decision. No fixture file, no test
file, no `.mqh`/`.mq5` source, no sealed-file edit, no new
`ENUM_EVENT_TYPE` value, no `EventStore_LogTransition` call, no
`OnTick`/`OnTradeTransaction` change, no `History*`/`Position*`/`Order*`
API, no `OrderSend`/`CTrade`, no candidate-lifecycle transition, and no
C3.6 `DeferredTransactionProcessor` code is authorized by this document.
This contract freezes the plan and the gate boundary only.

**Baseline**: `mlquantai@b75ce34` (B5–B9, C1–C2, C3.1–C3.4 sealed; C3.5
deferred-authority contract frozen). Phase 0.3 is the open gate sitting
between the C3.5 contract and any C3.6 implementation branch.

---

## 1. Objective

Split "historical data debt" from "positive-path proof fixtures" so the
future C3.6 recommendation processor is built and tested against a
clean, deterministic evidence chain — without rewriting, normalizing, or
even opening the historical daily store that carries the pre-fix orphan
condition.

The two fixtures are deliberately separate concerns:

```
A. Historical Negative Fixture
   - the pre-fix orphan condition, as durable historical evidence
   - read-only, never repaired
   - proves the system still reports the expected failure correctly

B. Canonical Positive Fixture
   - a clean, deterministic, source-reconstructable event chain
   - generated at test start into a dedicated test store
   - proves the C3.5 eligibility chain can be read end-to-end and
     produces the expected recommendation (RECOMMEND_EXECUTED)
```

**This document freezes the plan. It does not close the gate.** The gate
closes only later, when both the negative diagnostic test and the
canonical positive fixture test exist and pass (section 11).

---

## 2. Scope guard (frozen)

```
Docs only. One new decision doc. One CHANGELOG entry. No Tests/*.mq5,
no Tests/Fixtures/*, no .mqh/.mq5 source, no sealed file touched, no
new ENUM_EVENT_TYPE value, no EventStore_LogTransition call, no
OnTick/OnTradeTransaction change, no History*/Position*/Order* API,
no OrderSend/CTrade, no candidate-lifecycle transition, no C3.6
DeferredTransactionProcessor code, no C3.3/C3.4 semantic change, no
production EA behavior change.
```

---

## 3. Negative historical evidence policy (frozen)

```
MLQuantAI_events_2026-08-21.jsonl
  = the pre-fix daily store containing the historical orphan
    CANDIDATE_CREATED line (context lineage absent).
  = READ-ONLY historical evidence.
  = NEVER renamed, deleted, truncated, appended to, normalized,
    archived, moved, or opened for read or write by any automated
    test or by the Phase 0.3 implementation.
```

The original daily store is **not** an automated-test input. Automated
negative testing must use one of these two **separate** sources instead:

```
A1. A source-controlled COPY under a dedicated fixture name in
    Tests/Fixtures/, with provenance (origin path) and a recorded
    SHA-256 hash in the test header, so tampering with the copy is
    detectable; OR
A2. A minimal orphan fixture GENERATED at test start from a documented
    bad-line pattern (a CANDIDATE_CREATED line whose context_event_id
    has no matching MARKET_CONTEXT_READY in the same store), matching
    the exact failure shape the historical store exhibits.
```

Either source is a **dedicated fixture**, not the live daily store. For
A1, the copy must come from an explicitly approved snapshot/provided
artifact created by a human-in-the-loop copy of the original — automated
tests must never read the live daily store to produce the copy. The
choice between A1 and A2 is frozen at the Phase 0.3 implementation
contract time, not here; this decision records that both are valid and
that the original file is permanently out of scope for any test.

---

## 4. Negative assertion contract (frozen)

The negative test asserts the **failure boundary and cause**, never
brittle timestamp/session/sequence/line-number equality.

```
rebuild returns ok == false
AND lines_failed > 0
AND the diagnostic (first_error / classified reason category) contains a
    STABLE orphan-candidate cause: the candidate's context_event_id is
    missing or does not match any MARKET_CONTEXT_READY line in the same
    store
AND the failure occurs at CandidateProjection, or at a downstream
    rebuild stage that gates through CandidateProjection
    (BrokerSubmissionAudit / ManualApproval / TransactionMatching
    startup rebuild whose own .ok depends on the candidate projection)
```

**Frozen prohibitions on the assertion**:

```
No assertion on an exact session_id, timestamp, line number, or
  whole-message equality, unless that exact diagnostic string is itself
  frozen by a separate contract.
No assertion that the historical store is opened, read, or even exists
  at test time — the negative test uses a dedicated fixture (section 3).
No "generic failed" assertion — the cause MUST be the orphan-candidate
  condition, not a catch-all.
No production parser or CandidateProjection validation rule may be
  relaxed to make a historical fixture pass; the test must fail for the
  same reason it fails today.
```

---

## 5. Canonical positive fixture contract (frozen)

The positive fixture is a **generated-at-test-start dedicated `.jsonl`
store**, matching the established convention of every C1/C2/C3 test file
(e.g. `Tests/MLQuantAI_Test_C3_3_TransactionMatchingProjection.mq5`:
`#define TEST_FILE "...jsonl"`, `FileDelete` if it exists,
`EventStore_Open`, build the chain via the EventStore public API and
`BrokerTransactionObservation_RecordAndGuard` fed deterministic fixture
`MqlTradeTransaction` structs).

### 5.1 Minimum event chain (frozen)

```
MARKET_CONTEXT_READY              (synthetic context, namespaced)
  -> CANDIDATE_CREATED            (full extra_json, schema-conformant)
  -> EXECUTION_REQUEST_CREATED   (C1.3, execution_request_id + hash)
  -> EXECUTION_DRY_RUN_COMPLETED  (result == ACCEPTED — C2.3 will reject
                                    a submission attempt whose request has
                                    no ACCEPTED dry-run)
  -> EXECUTION_SUBMISSION_ATTEMPTED (durable attempt before outcome;
                                    ordering matters: attempt precedes
                                    outcome, per the C2.3 ordering rule)
  -> ORDER_SUBMITTED / submission outcome
       (SUBMISSION_STATUS_SUBMITTED, order_ticket/deal_ticket stamped)
  -> BROKER_TRANSACTION_OBSERVED DEAL_ADD
       (deterministic deal_ticket/order_ticket/volume/price)
  -> C3.3 build -> OrderAggregateRecord.match_status
       == MATCHED_VOLUME_REACHED
  -> (C3.6, future) read-only recommendation -> RECOMMEND_EXECUTED
```

The chain deliberately ends at the C3.3 read model + a future C3.6
recommendation. Phase 0.3 builds the **fixture and the read-chain proof
only**; the C3.6 recommendation itself is implemented in C3.6, not here.
This is the **full** sequence the real C2.3 / C3.3 rebuild requires, not
just its endpoints: C2.3 rejects a submission attempt whose execution
request has no ACCEPTED dry-run, and the outcome ordering depends on a
durable attempt preceding its outcome, so every line above is required
for the chain to rebuild cleanly.

### 5.2 Determinism / replay stability (frozen)

```
IDs, tickets, timestamps, prices, volumes, and sequence come from FIXED
  constants and deterministic helper inputs — never from TimeCurrent(),
  MathRand(), a live quote, or an account-specific value.
The store is rebuilt fresh (FileDelete + EventStore_Open) at test start.
A cold rebuild (TransactionMatching_RebuildFromFile / the relevant
  startup rebuilds) from the same store yields identical projection
  state and identical match_status every run.
```

### 5.3 action_id identity (frozen, design-only — for C3.6)

The future C3.6 `action_id` must derive from **semantic immutable
evidence** first, not from `EventStore` `session_id` or append sequence
number:

```
candidate_id
execution_request_id
action_type (RECOMMEND_EXECUTED / BLOCKED / NONE)
order_ticket
terminal match_status (MATCHED_VOLUME_REACHED)
deterministic, sorted deal_ticket set
```

Source log-event IDs / sequence numbers may be recorded as **evidence
metadata** in the recommendation record, but must not be a required
input for deterministic `action_id` identity unless they are themselves
generated deterministically in the fixture. A replay/re-run observing the
same semantic evidence yields the same `action_id` and the same
recommendation.

---

## 6. Fixture ownership and location (frozen)

```
Negative fixture (A1 copy or A2 generated):
  dedicated test store filename under the test's own TEST_FILE define
  (e.g. MLQuantAI_Test_Phase0_3_NegativeOrphanFixture.jsonl), OR a
  source-controlled copy under Tests/Fixtures/ with recorded provenance
  + SHA-256.
  Owner: the dedicated Phase 0.3 negative test file only.

Positive fixture:
  generated at test start into a dedicated TEST_FILE
  (e.g. MLQuantAI_Test_Phase0_3_CanonicalPositiveFixture.jsonl).
  Owner: the dedicated Phase 0.3 positive test file only.

Each fixture has exactly one owning test file. No shared mutable
fixture store between test files. No test reads or writes another
test's dedicated store.
```

---

## 7. Isolation and cleanup policy (frozen)

```
Every test uses a dedicated test filename (TEST_FILE) or a generated
  store, never a daily production-named store.
No test opens, reads, writes, deletes, renames, or truncates
  MLQuantAI_events_2026-08-21.jsonl or any MLQuantAI_events_*.jsonl
  daily store.
Cleanup (FileDelete of the dedicated TEST_FILE) never touches the
  negative historical evidence. If A1 (source-controlled copy) is used,
  the copy in Tests/Fixtures/ is never deleted or overwritten by a test;
  only the test's own generated working store is cleaned up.
No fixture debt from one test leaks into another — each test is
  self-contained and rebuilds its own store.
```

---

## 8. C3.6 readiness contract (frozen)

The positive fixture must reconstruct the full upstream read-model chain
the future C3.6 processor will consume, so C3.6 can be written against a
known-good evidence base:

```
CandidateProjection           (candidate_id -> state == SUBMITTED)
ExecutionAuditProjection      (execution_request_id -> candidate_id)
BrokerSubmissionAuditProjection (submission outcome SUBMISSION_STATUS_SUBMITTED,
                                order_ticket/deal_ticket, attempt_count)
TransactionMatchingProjection (OrderAggregateRecord: order_ticket,
                                matched_execution_request_id,
                                match_status == MATCHED_VOLUME_REACHED,
                                running_filled_volume, deal_count)
```

The positive fixture must support, at minimum, these case shapes (some
may be promoted to dedicated C3.6 fixtures later, but the Phase 0.3
positive fixture must make the full-match case real):

```
full-match  -> MATCHED_VOLUME_REACHED -> (future) RECOMMEND_EXECUTED
partial     -> MATCHED_PARTIAL        -> (future) no recommendation
unmatched   -> UNMATCHED             -> (future) no recommendation
ambiguous/collision -> AMBIGUOUS     -> (future) BLOCKED, observable
```

Phase 0.3 must prove the **read chain** (rebuild -> projection state ->
match_status) is correct for at least the full-match case and document
which cases are deferred to C3.6-specific fixtures.

---

## 9. Required future test matrix (design-only — no test file authorized here)

At minimum, the future Phase 0.3 test files must prove:

```
NEGATIVE (historical debt, dedicated fixture — NOT the daily store):
  N1. orphan CANDIDATE_CREATED (no matching MARKET_CONTEXT_READY) ->
      rebuild ok=false, lines_failed>0, first_error names the
      orphan-candidate cause.
  N2. the failure is stable across re-runs (same cause, not a
      catch-all).
  N3. no production parser/contract was relaxed to make it pass.

POSITIVE (canonical, generated at test start, dedicated store):
  P1. full chain builds and validates (C1.3 -> C2.3 -> C3.3 -> C3.4
      startup rebuilds all .ok, zero failed lines).
  P2. full-match -> MATCHED_VOLUME_REACHED.
  P3. cold rebuild -> identical projection state and match_status.
  P4. replay/re-run -> same semantic evidence -> same action_id (once
      C3.6 exists; until then, same projection state).

ISOLATION:
  I1. no test opens/reads/writes/deletes the daily store.
  I2. each test owns exactly one dedicated store; no cross-test
      leakage.
  I3. cleanup never touches negative historical evidence.
```

---

## 10. Explicit prohibitions (frozen)

```
Rewrite, truncate, rename, archive, move, or delete
  MLQuantAI_events_2026-08-21.jsonl.
Open the daily store for read or write from any automated test.
C3.6 DeferredTransactionProcessor code.
Any candidate-lifecycle transition or event append from Phase 0.3.
C3.3 / C3.4 semantic changes.
Production EA behavior changes.
Broker APIs, history APIs (HistorySelect/HistoryDealGet*/HistoryOrderGet*).
OnTick, OnTradeTransaction.
OrderSend / CTrade, demo smoke, live execution.
Relaxing a production parser or validation rule to make a historical
  fixture pass.
Mixing the negative historical fixture with the canonical positive
  fixture path.
Closing the gate merely because a fixture file was created.
```

---

## 11. Definition of Done / unblock criteria (frozen)

```
Phase 0.3 is NOT closed by this decision doc. The gate closes only
when BOTH exist and pass:

A — Historical negative fixture (dedicated, not the daily store):
    -> expected failure + stable orphan-candidate diagnostic     PASS
    -> failure cause unchanged across re-runs                    PASS

B — Canonical positive fixture (generated, dedicated store):
    -> valid event-store validation (C1.3->C2.3->C3.3->C3.4 .ok)  PASS
    -> C3.3 matching (full-match -> MATCHED_VOLUME_REACHED)       PASS
    -> cold rebuild -> identical projection state                 PASS

Replay (positive fixture):
    -> same semantic evidence -> same action_id (C3.6) /
       same projection state (until C3.6)                         PASS

No mutation:
    -> source event store (daily store) unchanged                 PASS
    -> candidate state unchanged (no lifecycle transition)        PASS
    -> no broker / history / order API                            PASS
```

```
If A passes but B is not ready            -> Phase 0.3 stays OPEN.
If B passes but A's diagnostic changed
   without a contract decision             -> Phase 0.3 stays OPEN.
Only when A AND B both pass                -> Phase 0.3  🔒 CLOSED
                                              C3.6        🟢 UNBLOCKED
```

Until both pass, C3.6 implementation remains blocked per the C3.5
contract (section 13).

---

## 12. File allowlist for this branch (frozen)

```
Docs/Phase0_3_FixtureDebtGate.md   (this document)
CHANGELOG.md
```

No `Tests/*.mq5`, no `Tests/Fixtures/*`, no `.mqh`/`.mq5` source, no
sealed file. The Phase 0.3 **implementation** (the actual negative and
positive test files + any fixture copies) is a separate, later branch
authorized only after this decision is merged and the C3.6 readiness
shape is confirmed against the real EventStore / projection APIs.

---

## 13. Acceptance criteria for this docs-only merge (frozen)

```
1. This document added under Docs/.
2. A CHANGELOG entry marked DESIGN ONLY / docs-only.
3. Diff is exactly two files: this doc + CHANGELOG.md.
4. No .mqh/.mq5 source file changed.
5. No sealed file touched.
6. No new ENUM_EVENT_TYPE value.
7. advisor final review confirms the A+B split, the negative-evidence
   policy (original daily store permanently out of scope for tests),
   the negative assertion contract (cause, not timestamp), the
   positive fixture determinism/replay rules, the action_id identity
   rule, the isolation/cleanup policy, and the DoD (gate not closed by
   the doc) are each frozen and internally consistent with the sealed
   codebase and the C3.5 contract.
8. Explicit user merge authorization (no auto-merge).
```

---

## Appendix A — Implementation status (branch phase0.3-fixture-implementation)

**Status**: IMPLEMENTATION DRAFT (not yet compiled/verified by the user).

- Test file: `Tests/MLQuantAI_Test_Phase0_3_FixtureDebtGate.mq5` (single file,
  per the authorized allowlist). No `Tests/Fixtures/*` helper was needed.
- A (negative): in-memory valid candidate via `CRT_DetectV1` +
  `CRT_ToTradeCandidate` (suffix `NEGORPHAN`), only `CRT_EmitCandidateCreated`
  emitted into a dedicated store with no `MARKET_CONTEXT_READY`. Asserts
  `ok=false`, `lines_failed>0`, `lines_applied==0`, `first_error` contains
  `orphan candidate:`, `first_error_code == CANDPROJ_REASON_ORPHAN_CONTEXT`,
  and the fixture file (line count + byte size) is unchanged by the rebuild.
- B (positive): generated-at-test-start dedicated store carrying the full
  chain. Fixed `submittedAt = D'2026.07.15 12:00:00' + dayOffset*86400`
  (NOT `TimeCurrent()`). Proves all three rebuilds are clean (zero failed
  lines), `MATCHED_VOLUME_REACHED`, the join chain
  `deal_ticket -> order_ticket -> execution_request_id -> candidate_id ->
  CANDIDATE_SUBMITTED`, and determinism across two cold rebuilds.
- C (readiness only): local read-only `future_action_id_input_key` over the
  immutable semantic facts, asserted identical across two rebuilds. No
  processor, no `RECOMMEND_EXECUTED`, no action-event write, no DIRECT
  `EventStore_LogTransition`, no new C3.6 transition.

**Gate not closed.** Closes only after the user compiles the new test in
MetaEditor (0 errors / 0 warnings) and the full regression gate passes:
new Phase 0.3 suite ALL PASS, C3.3 109/109, C3.4 57/57, C2.3 104/104,
C2 448/448, main EA 0/0. Until then C3.6 remains blocked.
