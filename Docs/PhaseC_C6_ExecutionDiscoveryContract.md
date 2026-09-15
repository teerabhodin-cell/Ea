# Phase C6 — Execution Discovery Contract (C6.1 / C6.2 / C6.3)

> **RETROSPECTIVE DOCUMENT** — reconstructed after implementation from
> surviving repository evidence (commit messages, code comments, test
> evidence) and accepted checkpoint records (RA-34, RA-36). This is
> **not** a claim that a formal contract document existed at the time
> C6.1/C6.2/C6.3 were implemented. The code itself repeatedly states its
> own authorization was "frozen chat-history contracts, no separate
> Docs/ file yet" — that original chat-based contract is not present in
> this repository and is not recoverable from it. Every numbered
> section this document cites from code comments (e.g. "C6.3 section
> 5") is flagged explicitly below as **ORIGINAL SECTION CONTENT: NOT
> RECOVERABLE** — what follows in this document is a reconstruction
> from the resulting code and tests, not a recovery of that original
> text.

Status: **DRAFT — pending QA review (RA-36.2)**

Scope: read-only reconstruction. Introduces no new code, no new
behavior, no new acceptance criteria beyond what the cited evidence
already establishes.

---

## 1. Source evidence

```text
c6.1        (605e9c1a) 2026-09-08  feat(c6.1): add advisory environment
                                    identity snapshot (no broker authority)
c6.2/c6.3   (5d5b22f0) 2026-09-09  feat(c6.2/c6.3): commit
                                    ExecutionDiscoveryGuard +
                                    ExecutionLineageObservation
                                    (repo integrity gap)
c6.2/c6.3   (342bae25) 2026-09-09  test(c6.2/c6.3): add W1-AC-N1
                                    forced-failure fixture for Layer A
                                    registration invariant
c6.3        (6872a8d5) 2026-09-09  fix(c6.3): register ModelArtifact
                                    before InferenceResult
```

Plus the two Include files these commits produced, both still present
and both self-describing as retrospective evidence in their own right:

```text
Include/MLQuantAI/Execution/MLQuantAI_ExecutionDiscoveryGuard.mqh       (C6.2)
Include/MLQuantAI/Execution/MLQuantAI_ExecutionLineageObservation.mqh   (C6.3)
```

---

## 2. C6.1 — advisory environment identity snapshot

**Purpose:** a pure, read-only observation of environment/identity/
authority runtime facts, built and logged once at `OnInit()`, before
`FeatureEngine_Init`.

**Facts captured** (verbatim from the c6.1 commit message):
`ACCOUNT_TRADE_MODE`, `ACCOUNT_LOGIN`, `ACCOUNT_SERVER`,
`TERMINAL_TRADE_ALLOWED`, `MQL_TRADE_ALLOWED`, `ACCOUNT_TRADE_ALLOWED`,
`ACCOUNT_TRADE_EXPERT`, `TERMINAL_CONNECTED`.

**Authority: none.** Never calls `OrderSend`/`BrokerSubmission_Submit`/
`EventStore_Log*`/`ManualApprovalRegistry_Grant*`/`SafeMode_*`, never
replaces a sealed gate's own fresh runtime read, never suppresses the
pipeline.

**Configuration** (three new EA inputs, blank default):
```text
InpC6AccountAllowlist = ""  // comma-separated ACCOUNT_LOGIN values
InpC6ServerAllowlist  = ""  // comma-separated ACCOUNT_SERVER values
InpC6SymbolAllowlist  = ""  // comma-separated symbols
```
Empty = unconfigured, fails closed (diagnostic only). Reuses the
existing, unmodified `SafetyGate_AllowlistContains()` for the
comparison logic — no new allowlist-matching code was written for C6.1.

**Verification evidence** (from the commit message): real MetaEditor
compile (0 errors/0 warnings) and a run on a live MetaQuotes-Demo chart
(not Strategy Tester) — the snapshot correctly reported `is_demo=true`
and all positive authority facts, and correctly produced the
"allowlist is empty" negative diagnostic on all three unconfigured
allowlist fields. A static grep audit confirmed zero forbidden calls in
the new file.

No numbered section is cited anywhere in C6.1's code or commit message
— unlike C6.2/C6.3 below, there is no evidence C6.1 had a separate
structured chat-contract.

---

## 3. C6.2 / C6.3 — the Two-Layer Discovery Model ("Wave 1" / `W1`)

### 3.1 Why it exists

Quoting `MLQuantAI_ExecutionDiscoveryGuard.mqh` directly:

> "Layer A (session registry, memory-only) exists because Model B is
> confirmed: `EventStore_LogSystem()` never touches projection arrays
> live — Layer B alone cannot see this session's own writes. Layer B
> (`ExecutionRequestProjection`, durable) exists because Layer A is
> memory-only and vanishes on restart. Neither substitutes for the
> other."

### 3.2 Naming — resolved (RA-36)

```text
"Wave 1" / "W1"  = the first implementation wave of the C6.2/C6.3
                    Two-Layer Discovery Model contract. No "Wave 2" /
                    "W2" exists anywhere in the repository (searched
                    exhaustively across all tracked files and commit
                    history — zero hits).
"AC"             = Acceptance Criterion (e.g. AC-N1).
"AC-N1"          = the exact meaning of the "N" prefix is NOT
                    EVIDENCED anywhere in the repository. It is left
                    unresolved by design — do not infer or assert a
                    meaning for it.
```

### 3.3 The two layers

```text
Layer A — g_ExecDiscovery_SessionIds[] (in-memory array)
          Reset every OnInit(). Carries this session's own emissions
          only. Registered via ExecutionDiscoverySession_Register(),
          idempotent (empty id or already-present id = no-op).

Layer B — ExecutionRequestProjection (durable, sealed C1.2 projection)
          Carries history across restart. Read via
          ExecutionRequestProjection_TryGet().
```

### 3.4 Resolution / emission API

```mql5
enum ENUM_EXEC_DISCOVERY_RESOLUTION
{
   EXEC_DISCOVERY_FOUND_SESSION,   // Layer A hit
   EXEC_DISCOVERY_FOUND_DURABLE,   // Layer B hit
   EXEC_DISCOVERY_MISSING          // neither — eligible to emit
};

void ExecutionDiscovery_Resolve(string executionRequestId, ExecutionDiscoveryResult &out);
bool ExecutionDiscovery_EmitAndRegister(const ExecutionRequest &request,
                                          const ExecutionPolicy &policy,
                                          DryRunExecutionResult &outResult);
```

`ExecutionDiscovery_Resolve()` checks Layer A first (cheapest,
in-memory), then Layer B only if Layer A misses. It is a pure read — no
EventStore write.

`ExecutionDiscovery_EmitAndRegister()` is, per the code comment, **"the
ONLY authorized wrapper around `ExecutionRequest_EmitAndEvaluate` in
this project"** — every call site must go through `Resolve()` first,
and only call this on `EXEC_DISCOVERY_MISSING`. It wraps the sealed
C1.2 `ExecutionRequest_EmitAndEvaluate()` exactly once, then registers
into Layer A **unconditionally, regardless of the emit call's return
value** — because a `false` return does not necessarily mean nothing
was durably written (`EXECUTION_REQUEST_CREATED` can already be durable
even when a subsequent write in the same call fails).

### 3.5 ORIGINAL SECTION CONTENT: NOT RECOVERABLE

The following sections are cited by the actual shipped code as the
source of specific invariants. **Their original text is not present in
this repository and cannot be recovered from it.** The description
given for each below is this document's own reconstruction from the
resulting code and test behavior — not a recovery of what those
sections actually said.

```text
C6.2 §3   — cited alongside C6.3 §2 as the source of the rule that
            executionRequestId must be derived via the pure Ids_*
            identity chain (candidate/eligibility/AI/risk-plan identity
            + policy-version strings only) BEFORE calling
            ExecutionDiscovery_Resolve() — no live balance read, no
            content-struct build, required to resolve discovery.
            RECONSTRUCTED DESCRIPTION ONLY — original §3 text unknown.

C6.2 §5   — cited as the source of the rule that Layer A registration
            must be unconditional after EmitAndEvaluate(), specifically
            to prevent a same-ID-different-hash collision that would
            fail BrokerSubmissionAuditReadiness for the whole session.
            RECONSTRUCTED DESCRIPTION ONLY — original §5 text unknown.

C6.3 §2   — see C6.2 §3 above (cited together).
            RECONSTRUCTED DESCRIPTION ONLY — original §2 text unknown.

C6.3 §3   — cited as the source of the rule that Layer B is what
            carries history across restart, and that a fresh process
            has no prior-session Layer A knowledge.
            RECONSTRUCTED DESCRIPTION ONLY — original §3 text unknown.

C6.3 §4   — cited as the source of "discover-before-emit" as a named
            pattern, and that ExecutionDiscovery_Resolve() is a pure
            read with no EventStore write.
            RECONSTRUCTED DESCRIPTION ONLY — original §4 text unknown.

C6.3 §5, invariant 3
          — cited as the source of the rule that
            ExecutionDiscovery_EmitAndRegister() must only be reached
            after a MISSING resolution, and never called a second time
            for the same identity within the same session. This
            specific invariant (invariant 3) is directly proven by the
            W1-AC-N1 forced-failure regression test (commit 342bae2,
            9/9 PASS) — see §4 below.
            RECONSTRUCTED DESCRIPTION ONLY — original §5 text (and any
            invariants 1/2/4+ it may have listed) unknown.

C6.3 §6   — cited as the source of the OnInit-only "discover the past"
            entry point (ExecutionLineageObservation_LogAll(), §5
            below).
            RECONSTRUCTED DESCRIPTION ONLY — original §6 text unknown.
```

---

## 4. C6.2 evidence — W1-AC-N1 forced-failure regression

`Tests/MLQuantAI_Test_W1_AC_N1_ForcedFailure.mq5` (commit `342bae2`,
9/9 PASS) proves `ExecutionDiscovery_EmitAndRegister()` registers
`execution_request_id` into Layer A unconditionally, **even when the
underlying `EventStore` write fails outright** and nothing is ever
durably recorded — not just when it partially succeeds.

The failure is forced deterministically by opening then immediately
closing the EventStore handle before the emission call, so
`EventStore_WriteLine()`'s own `INVALID_HANDLE` guard fires — no disk
I/O, no partial write. Per the commit message, this is "the only
reproducible way to force this failure": a bad
`EventStoreFileNameOverride` fails `OnInit()` itself (the EA never
reaches `OnTick()`), and a genuine disk-full condition would fail every
other same-tick emission too, not just this one.

The test also confirms the practical consequence: the next
`ExecutionDiscovery_Resolve()` call for the same id returns
`EXEC_DISCOVERY_FOUND_SESSION` — proving no second emitter call would
ever be attempted within the same session, regardless of the first
call's durability outcome.

---

## 5. C6.3 — "discover the past" (`ExecutionLineageObservation`)

**Purpose:** an `OnInit()`-only, strictly read-only correlation pass —
per §3.5 above, its OnInit entry point is cited as originating from
"C6.3 section 6."

```mql5
void ExecutionLineageObservation_LogAll();      // OnInit entry point
void ExecutionLineageObservation_LogOne(const ExecutionRequestProjectionRecord &rec);
```

For each durable `ExecutionRequestProjection` record, correlates
against `DryRunResultProjection`, `ManualApprovalProjection` (via
`ManualApprovalRegistry_HasValidApproval()`), and
`SubmissionAttemptProjection` (via `SubmissionAttemptRegistry_HasAttempt()`/
`_IsUnresolved()`) — `LogInfo()` only. No EventStore write, no
lifecycle mutation, no submission authority anywhere in the file. Never
gates EA initialization, never trips Safe Mode.

**Caller ordering requirement:** `MLQuantAI.mq5`'s `OnInit()` must call
this **after** both `BrokerSubmissionAudit_StartupRebuild()` and
`ManualApproval_StartupRebuild()` have already run in the same session
— this file never triggers a rebuild of anything itself.

---

## 6. C6.3 fix — ModelArtifact/InferenceResult registration order

Commit `6872a8d` (2026-09-09, `fix(c6.3)`) fixed two restart-only
failures, tracked as `INV-C6-W1-RST-001`:

```text
1. ModelArtifactProjection rejecting the record for a missing required
   field (feature_schema_version).
2. AIDecisionProjection's model-registry lineage check rejecting the AI
   decision once (1) was fixed, because the AI decision's declared
   model_registry_hash was a hardcoded literal that never matched the
   real computed ModelArtifact hash.
```

Fix: the synthetic `ModelArtifact` (`c5StubModel`) now builds and
registers **before** the synthetic `InferenceResult` (`c5StubInference`),
which reuses `model_registry_id`/`model_registry_hash`/
`model_artifact_hash`/`output_schema_version`/`runtime_framework`/
`runtime_version` directly from the registered `ModelArtifact` instead
of duplicating them as separate hardcoded literals. Both failures were
invisible on a fresh run (the live-emission path skips required-field/
lineage validation) and only ever surfaced on restart-rebuild.

Verified via fresh Stage 2 + restart Stage 3 runs against a real event
store, including an exact byte-for-byte match of `model_registry_hash`
between the `MODEL_ARTIFACT_REGISTERED` and `AI_DECISION_CREATED`
records.

---

## 7. Repo-integrity gap noted at commit time

Commit `5d5b22f`'s own message discloses that `MLQuantAI.mq5` had
already been calling both `MLQuantAI_ExecutionDiscoveryGuard.mqh` and
`MLQuantAI_ExecutionLineageObservation.mqh` since commit `6872a8d`, but
neither Include file had itself been committed — a fresh clone of the
branch could not compile in that window. Both files were reviewed under
a checkpoint labeled `W1-C6.2-C6.3-F3` (classified "A" — required for
C6.2/C6.3) and committed as-is, with no content changes at commit time.

Also noted in that same commit message: a pending `MLQuantAI_EventStore.mqh`
scalability diff was explicitly excluded from this commit and tracked
separately as `TD-INFRA-001`. This document makes no claim about that
item's current status — it is out of scope here and not investigated
by RA-36.

---

## 8. Explicit non-goals / what C6.1–C6.3 do not cover

- No broker submission authority anywhere in C6.1, C6.2, or C6.3 — no
  file in this scope calls `OrderSend`/`CTrade`/`BrokerSubmission_Submit`.
- No candidate-lifecycle transition in any file described here.
- No coverage of C6.6 (ceremony/real-DEMO readiness) — that track is
  already documented at `Docs/RA34_BaselineFreeze_ArchitectureAudit.md`
  §§2.5, 3, and is deliberately not duplicated here (RA-36 decision: no
  third C6.6 contract document).
- No coverage of C5 — see `Docs/PhaseC_C5_ControlledExecutionContract.md`.

---

## 9. Status

```text
C6.1     = DONE (RA-34 §2.2)
C6.2/6.3 = DONE / validated through the later C6.6 ceremony sequence (RA-34 §2.3)
C6.4/6.5 = NOT EVIDENCED BY COMMIT HISTORY (RA-34 §2.4) — out of scope here, unchanged
C6.6     = IN PROGRESS — see Docs/RA34_BaselineFreeze_ArchitectureAudit.md, not duplicated here
```

This document does not reopen, alter, or reinterpret that
classification — it records the evidence behind C6.1/C6.2/C6.3
specifically.

**QA STATUS: DRAFT — awaiting review (RA-36.2).** Not yet staged, not
committed, not pushed.
