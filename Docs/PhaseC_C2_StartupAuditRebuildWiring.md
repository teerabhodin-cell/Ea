# C2.2/C2.3 startup audit-rebuild wiring — status

**Status: NOT YET real-MetaEditor-confirmed. Awaiting a compile/run of
`MLQuantAI.mq5` itself (the main EA, not just a `Tests/*.mq5` script)
plus the two amended test suites below.**

Per the user's explicit, frozen scope: wires
`BrokerSubmissionAudit_StartupRebuild()` into `MLQuantAI.mq5`'s
`OnInit`, right after the existing EventStore health/validation, and
makes `BrokerSubmissionGate_Evaluate` fail-closed on
`REASON_EXECUTION_AUDIT_NOT_READY` until that rebuild has actually
succeeded this session.

## What this commit adds

- **`Core/MLQuantAI_ReasonCodes.mqh`**: `REASON_EXECUTION_AUDIT_NOT_READY`
  (append-only, new tail) — the registry could not be consulted at all,
  never confused with `REASON_DUPLICATE_EVENT` (which means the
  registry WAS consulted and found a real prior attempt).
- **`Execution/MLQuantAI_BrokerSubmissionAuditReadiness.mqh`** (new):
  `g_BrokerSubmissionAudit_Ready` (fail-closed default `false`),
  `BrokerSubmissionAuditReadiness_IsReady()`,
  `BrokerSubmissionAuditReadiness_Reset()` (test-only), and the one
  real entry point, `BrokerSubmissionAudit_StartupRebuild(fileName)` —
  calls `BrokerSubmissionAuditProjection_RebuildFromFile()` (which
  itself stages C1.3's own `ExecutionAuditProjection_RebuildFromFile`
  first — no redundant re-parse), sets readiness from THIS call's own
  `report.ok` every time (never OR'd with a stale prior success, so a
  later failed call correctly *revokes* readiness). Logs via
  `LogInfo`/`LogWarn` only — deliberately not a durable EventStore
  write, matching the precedent `MLQuantAI.mq5`'s own "pre-existing
  event store: N lines, health=..." startup line already set.
  Read-only: no `OrderSend`/`CTrade`/broker query/candidate mutation/
  event append/`OnTradeTransaction` anywhere.
- **`Execution/MLQuantAI_BrokerSubmissionGate.mqh`** (amended again):
  `BrokerSubmissionGate_Evaluate` adds a check, evaluated BEFORE both
  the in-session and durable idempotency checks — if
  `BrokerSubmissionAuditReadiness_IsReady()` is false, EVERY request is
  rejected with `REASON_EXECUTION_AUDIT_NOT_READY`, including a request
  that has never been attempted anywhere (the registry might be hiding
  a real prior attempt this process just can't see yet — a blanket
  disablement, not a per-id check).
- **`MLQuantAI.mq5`** (amended): `OnInit` calls
  `BrokerSubmissionAudit_StartupRebuild(g_EventStoreFileName)` once,
  right after the existing `EventStoreHealth_CheckFile`/`EventStore_Open`
  block, before `EVENT_TYPE_SYSTEM_STARTED` is logged. A failed rebuild
  logs a `LogWarn` and does **not** `return INIT_FAILED` — matches this
  file's own existing precedent for the corrupted-store case (the EA
  keeps running its B-phase market-context work; only C2 broker
  submission is disabled for the session). No strategy in this codebase
  calls `BrokerSubmissionGate_Evaluate` yet (execution wiring into
  `OnTick` is a separate, later concern) — this wiring exists so the
  registry is trustworthy before one safely could.

## Exact startup order (required proof item 1)

```
OnInit
  1. FeatureEngine_Init (existing)
  2. News hard gate (existing, tester-only)
  3. EventStoreHealth_CheckFile on the pre-existing file, if any (existing)
  4. EventStore_Open (existing)
  5. Log EVENT_TYPE_SYSTEM_EVENT_STORE_CORRUPTED if step 3 found corruption (existing)
  6. BrokerSubmissionAudit_StartupRebuild(g_EventStoreFileName)  <- NEW
       -> BrokerSubmissionAuditProjection_RebuildFromFile
            -> ExecutionAuditProjection_RebuildFromFile (C1.3, unmodified, staged first)
            -> SubmissionAttemptProjection / SubmissionOutcomeProjection interleaved pass
       -> g_BrokerSubmissionAudit_Ready = report.ok (true or false, always overwritten)
  7. Log EVENT_TYPE_SYSTEM_STARTED (existing)
  8. ReplayEngine_Run - candidate lifecycle replay (existing, unrelated registry)
  9. BrokerReconciliation_CheckAll (existing, unrelated registry)
  10. Step 8.5 lifecycle smoke test (existing, unrelated registry)
```

Failure behavior: step 6 failing does NOT fail `OnInit` (`INIT_SUCCEEDED`
still returned, matching the existing corrupted-store precedent) - it
only leaves `g_BrokerSubmissionAudit_Ready = false` for the rest of the
session, which `BrokerSubmissionGate_Evaluate` then fails closed on for
every request, forever, until a future successful rebuild (there is no
automatic retry).

## New reason code / event/log behavior (required proof item 2)

`REASON_EXECUTION_AUDIT_NOT_READY` (see above). No new `ENUM_EVENT_TYPE`
and no new durable EventStore write - the rebuild's own success/failure
is observable only via the terminal's Experts log (`LogInfo`/`LogWarn`),
same class of fact as the existing "pre-existing event store: N lines,
health=..." line.

## Test suites (amended/new)

- **`Tests/MLQuantAI_Test_C2_BrokerSubmissionGate_DurableIdempotency.mq5`**
  (amended): the three original tests now go through
  `BrokerSubmissionAudit_StartupRebuild` after an explicit
  `ResetAllProjections()`/`BrokerSubmissionAuditReadiness_Reset()` —
  simulating an ACTUAL restart via the real production entry point, not
  a lower-level test-side rebuild call (required proof item 3). Three
  new tests: a brand-new, never-attempted request is still rejected
  `REASON_EXECUTION_AUDIT_NOT_READY` before any rebuild ever ran; a
  corrupted/orphaned store fails the rebuild and blanket-disables an
  entirely unrelated, otherwise-valid request too (required proof item
  4); a successful rebuild followed by a later failed rebuild on a
  different file correctly revokes readiness (re-entrancy, never a
  stale `true`). Structural proof extended to cover the readiness file.
- **`Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5`** (third
  amendment, minimal diff): two new `Check()`s added at the very top of
  `OnStart()` — marks the registry ready ONCE via the real
  `BrokerSubmissionAudit_StartupRebuild` entry point (fed an empty
  store, which trivially succeeds — not a backdoor), since none of this
  suite's own tests exercise the `NOT_READY` path. Every other test in
  this file is otherwise untouched.

## Required proof (per the user's checklist) — outstanding

- [ ] Real MetaEditor compile of `MLQuantAI.mq5` itself (the main EA) —
      **not yet requested from/confirmed by the user**. This is the
      first commit this session to touch the main EA file; a
      `Tests/*.mq5` script compiling cleanly does NOT prove the EA
      compiles, since it's a different program type with a different
      include/global scope.
- [ ] `Tests/MLQuantAI_Test_C2_BrokerSubmissionGate_DurableIdempotency.mq5`
      real MetaEditor run (expected new count: 22 + ~24 new checks
      across the three new tests — exact count only known once real
      output exists).
- [ ] `Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5` re-run (was
      145/145 — expect 147/147 with the two new setup checks).
- [ ] Full regression: C1.2 (128/128), C1.3 (87/87), C2.2 (147/147
      after this amendment), C2.3 (104/104), the durable-idempotency
      integration patch (revised count above) — the user's own
      "Required proof" list this round explicitly asks for C1 alongside
      C2.2/C2.3/integration, a broader ask than this project's own
      established "defer full regression to C2 FULLY SEALED" precedent;
      honored here as asked.
- [ ] Item 6, inspection proof that the startup path stays read-only —
      covered by this doc's own file-by-file description above and by
      each amended file's own structural-proof test; no separate
      artifact produced.
