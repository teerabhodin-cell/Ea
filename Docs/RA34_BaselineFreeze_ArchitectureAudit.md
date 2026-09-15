# RA-34 — Baseline Freeze & Architecture Audit

Status: **FROZEN — QA VERIFIED**

Scope: Read-only audit document. No production code, test code, or EventStore schema is touched by this file. This document re-anchors the baseline to the actual Phase-C checkpoint lineage and records the current position as **C6.6 — Ceremony / Real-DEMO Readiness** within the broader C6 track.

This document does not authorize new code, broker submission, live-money activity, commit, or push. It consolidates prior QA verdicts and identifies remaining documentation and observability debt before the baseline can be frozen.

---

## 1. Purpose

RA-34 exists to establish a truthful baseline for the current Phase-C execution stack.

The correct phase lineage is:

```text
C5.0  = DONE
C5.1  = DONE
C6.1  = DONE
C6.2  = DONE
C6.3  = DONE
C6.4  = no commit evidence located
C6.5  = no commit evidence located
C6.6  = IN PROGRESS  ← CURRENT TRACK
C7    = NOT STARTED
```

C6.6 is the current ceremony/readiness sub-track. The `RA-XX` checkpoints are the incremental audit/remediation sequence under that C6.6 track.

The naming convention changed historically: early commits use the explicit `C6.6-RA-XX` convention, while later commits use the shorter `RA-XX` form. The underlying RA counter remains continuous. The frozen C2.4 contract explicitly records its origin as `C6.6-RA-08 → RA-09 → RA-10 → RA-11`.

Therefore the RA sequence must not be interpreted as a separate post-C6 program.

RA-34 does not change behavior. It:

1. records the actual C5/C6/C6.6 lineage;
2. records the accepted RA remediation/validation milestones;
3. distinguishes **VERIFIED**, **KNOWN LIMITATION**, **OPEN TECHNICAL DEBT**, and **NOT EVIDENCED** states;
4. defines the current development boundary;
5. records the remaining documentation gap: no formal `PhaseC_C5_*` or `PhaseC_C6_*` contract document was found for the C5/C6 tracks.

---

## 2. Phase-C Lineage

### 2.1 C5 — Controlled execution path

The git chain records:

```text
feat(c5.0): wire candidate-to-safety-gate pipeline into OnTick
           (Strategy Tester only)

feat(c5.1): raise InpC5MaxVolume default to observe SafetyGate ACCEPTED
```

**Current classification: DONE**

C5 established the controlled candidate-to-safety-gate path in the Strategy Tester and provided the controlled execution precursor used by the later C6 work.

No live-money authority is implied by this classification.

### 2.2 C6.1 — Environment identity

Recorded commit:

```text
feat(c6.1): add advisory environment identity snapshot
```

**Current classification: DONE**

This is advisory identity evidence only and does not grant broker authority.

### 2.3 C6.2 / C6.3 — Execution discovery and lineage observation

Recorded commits include:

```text
feat(c6.2/c6.3): commit ExecutionDiscoveryGuard + ExecutionLineageObservation
test(c6.2/c6.3): W1-AC-N1 forced-failure fixture
fix(c6.3): ModelArtifact/InferenceResult registration order
```

The later readiness-remediation chain also includes:

```text
fix(C6.6-RA-03): ceremony readiness remediation for real-DEMO smoke test
fix(C6.6-RA-05): durable upstream lineage in ceremony smoke test
fix(C6.6-RA-06): freeze ceremony fixture anchor to stable reference price
```

**Current classification: DONE / validated through the later C6.6 ceremony sequence**

### 2.4 C6.4 / C6.5

No commit evidence for `c6.4` or `c6.5` was located in the reviewed git chain.

**Current classification: NOT EVIDENCED BY COMMIT HISTORY**

This is not equivalent to a defect and not equivalent to a confirmed absence of work. The project should avoid silently assigning these checkpoints a status that is not supported by evidence.

### 2.5 C6.6 — Current track

**Current classification: IN PROGRESS**

C6.6 is the ceremony/readiness track for the real-DEMO controlled execution proof.

Its audit/remediation chain is the continuous `RA-XX` sequence, including the later RA-12 onward naming convention.

The project has already reached a real broker round-trip under this track, but C6.6 itself remains the current phase until its remaining baseline/documentation gates are explicitly frozen by QA.

### 2.6 C7

**Current classification: NOT STARTED**

No operational-hardening transition is authorized by RA-34.

---

## 3. RA Naming and Lineage

The checkpoint naming history is:

```text
C6.6-RA-03
C6.6-RA-04
...
C6.6-RA-11
        ↓ naming shortened
RA-12
RA-13
RA-14
...
RA-34
```

This is one continuous RA counter under the C6.6 workstream.

The frozen C2.4 contract explicitly preserves the historical origin chain `C6.6-RA-08 → RA-09 → RA-10 → RA-11`, which is the direct documentary evidence that the shortened `RA-XX` convention did not start a new independent checkpoint series.

---

## 4. Accepted RA Milestones

The following milestones are carried forward from previously accepted QA evidence.

| Checkpoint | Scope | Commit | Status |
|---|---|---|---|
| RA-29.1 | Ceremony EventStore binding handshake / persistent EA nonce | `b6c5776` | VERIFIED / CLOSED / DEPLOYED |
| RA-31 | Single-writer EventStore ownership + ceremony command protocol | `7d86b1b` | VERIFIED / CLOSED / DEPLOYED |
| RA-32.1 | OnTimer control-plane trigger | `85f1ab4` | VERIFIED / CLOSED / DEPLOYED |
| RA-30.3 | Read-only Entry Compatibility diagnostic command | `c7b254f` | VERIFIED / CLOSED / DEPLOYED |
| RA-30.4 | Durable approval write → same-session registry update, fail-closed | `493d04f` | VERIFIED / CLOSED / DEPLOYED |
| RA-30.2 | Live L0–L7 DEMO ceremony | none; live validation | VERIFIED / CLOSED |
| RA-33.1 | `TransactionMatching unmatched=1` root-cause attribution | none; read-only investigation | VERIFIED / CLOSED |
| RA-33.2 | C4.4 row-level recovery evidence emission | `ae250b9` | VERIFIED / CLOSED / DEPLOYED |

All commits listed above were accepted and pushed as part of the reviewed chain.

---

## 5. Verified Baseline Invariants

### 5.1 Single-writer EventStore ownership

RA-31 established the EA as the sole EventStore writer for the ceremony execution path. Scripts use the command/mailbox control plane and do not directly mutate the canonical EventStore.

### 5.2 EA/script binding handshake

RA-29.1 established a persistent, monotonic EA binding nonce so a ceremony script must prove filename + nonce agreement with the currently running EA before command execution.

### 5.3 Control-plane command processing

RA-32.1 added an `OnTimer` trigger path so command processing does not depend exclusively on market ticks. Successful claims record the trigger source diagnostically.

### 5.4 Durable-write-then-registry-update

RA-30.4 established the same-session consistency rule for approval state:

```text
durable append succeeds
        ↓
same event is re-applied to the runtime registry
        ↓
failure to apply => fail closed
```

Regression evidence: `27/27` pass.

### 5.5 Real L1–L7 execution evidence

RA-30.2 produced a real DEMO broker execution with the complete evidence ladder:

```text
L1  EXECUTION_SUBMISSION_ATTEMPTED
L2  ORDER_SUBMITTED
L3  BROKER_TRANSACTION_OBSERVED
L4  Transaction Matching
L5  RECOMMEND_EXECUTED
L6  CANDIDATE_EXECUTED
L7  BrokerReconciliation_CheckAll
```

The critical qualification is temporal:

- L1–L3 were produced during the real submission session.
- A subsequent restart produced the durable L4–L7 matching, lifecycle, and reconciliation evidence.

Therefore the correct baseline statement is:

> **Complete live L0–L7 evidentiary trail across the submission session and the subsequent restart/reconciliation cycle.**

It must not be described as a “same-session” L1–L7 trail.

Reference live order:

```text
order_ticket = 3800463826
```

Standing handling restrictions for this position remain in force (§9).

### 5.6 C4.4 row-level recovery evidence

RA-33.2 established a pure evidence sink for non-clean C4.4 rows. The emission path does not mutate the underlying reconciliation report, does not itself trip Safe Mode, and does not alter the sealed recovery scan.

Regression evidence: `29/29` pass.

Live restart evidence: `5/5` non-clean rows emitted, `0` emission failures.

### 5.7 Provenance discipline

`source_record_discriminator` is carried through verbatim from the recovery evidence source and is not reconstructed. This allowed the RA-33 findings to be attributed from durable evidence rather than inference.

---

## 6. Known Limitations

The following are acknowledged limitations and do not, by themselves, represent a baseline defect.

### 6.1 C4.4 coverage mode

The current reconciliation coverage mode can be `NONE`, producing `WINDOW_INSUFFICIENT` / coverage-evidence-absent findings.

This remains a coverage-attestation limitation rather than evidence of a trade-path failure.

### 6.2 Position-ticket representation

The C4.x recovered history model does not represent a position ticket.

Accordingly RA-33.2 rows use:

```text
position_ticket_known = false
position_ticket       = 0
```

This is explicit UNKNOWN state, not a fabricated ticket.

---

## 7. Open Technical Debt

### 7.1 C4.4 finding-name discrepancy

Production runtime emitted:

```text
UNMAPPABLE_HISTORY_RECORD
```

while the RA-33.2 illustrative test fixture used:

```text
ORPHAN_HISTORY_DEAL
```

The discrepancy is non-blocking and did not invalidate the live evidence, but the documentation/test-fixture mismatch remains open.

### 7.2 Projection staleness — not yet proven live

`ExecutionRequestProjection` and `DryRunResultProjection` were identified as possible staleness points during the RA-30.4 work.

The known RA-30.4 fix was specifically for `ManualApprovalProjection`.

Whether the same staleness behavior exists in the live EA for these two projections has **not** been investigated to the standard required for a verified finding.

Therefore this item remains **OPEN TECHNICAL DEBT**, not a closed known limitation.

### 7.3 Missing formal C5/C6 contract documentation

No formal:

```text
Docs/PhaseC_C5_*.md
Docs/PhaseC_C6_*.md
```

contract document was located for the C5/C6 work represented by the commit chain.

The current project state is therefore asymmetrical:

```text
Phase A / B / C1–C4
    → formal contract documents exist

C5 / C6 / C6.6
    → implementation history is primarily represented by
      git commits + RA checkpoints + run evidence
```

This creates documentation and traceability debt.

It does **not** invalidate already accepted implementation evidence, but it weakens the project's ability to answer, from a single authoritative document:

```text
What was the intended contract?
What was explicitly out of scope?
What are the acceptance criteria?
Which implementation commits satisfy that contract?
```

Recommended disposition: create dedicated, read-only contract documents for C5 and C6 (or an explicitly approved combined C5/C6 contract) before the project expands into C7 or a materially more complex live-money operating model.

This item is documentation debt, not permission to modify the execution path under RA-34.

---

## 8. Attributed Findings — Closed

### 8.1 `TransactionMatching unmatched=1`

Root cause:

```text
deal_ticket  = 3442407998
deal_type    = DEAL_TYPE_BALANCE
order_ticket = 0
```

This is a broker balance transaction, not a trade order, so no trade-order match exists.

### 8.2 `C4.4 block_recommended=1`

Root cause: the same broker record,

```text
deal_ticket = 3442407998
finding     = UNMAPPABLE_HISTORY_RECORD
posture     = BLOCK_RECOMMENDED
```

The production `RECOVERY_RECONCILIATION_ROW_OBSERVED` evidence provided the exact record discriminator required for attribution.

---

## 9. Standing Restrictions

RA-34 does not lift, relax, or modify any existing restriction.

```text
position 3800463826 = DO NOT TOUCH

retry SUBMIT_ORDER  = FORBIDDEN

new OrderSend       = NOT AUTHORIZED
```

No baseline-freeze document should be interpreted as an execution authorization.

> **Amended by §13 (RA-35.1, 2026-09-15):** two additional real DEMO
> tickets not listed above at freeze time — `3798882166` and
> `3799401055` — were investigated and confirmed CLOSED via direct
> broker History evidence. Neither requires a DO-NOT-TOUCH restriction.
> `3800463826` remains the only open position. See §13 for the full
> finding.

---

## 10. Current QA Boundary

The current state is:

```text
C5       = DONE
C6.1     = DONE
C6.2/6.3 = DONE
C6.4/6.5 = NOT EVIDENCED BY COMMIT HISTORY
C6.6     = IN PROGRESS  ← CURRENT
C7       = NOT STARTED
```

RA-34 is therefore a **baseline-freeze candidate for the C6.6 workstream**, not a declaration that all of Phase C is complete.

Before the baseline is frozen, the document must preserve:

1. the correct C6.6 lineage;
2. the temporal qualification of L1–L7 evidence;
3. the distinction between known limitations and uninvestigated technical debt;
4. the formal-documentation gap for C5/C6;
5. the existing execution restrictions.

---

## 11. Development Boundary After Baseline Freeze

Until QA explicitly accepts the corrected RA-34 baseline:

```text
NO new strategy complexity
NO AI decision-layer expansion
NO live-money expansion
NO new OrderSend path
NO retry of the existing SUBMIT_ORDER
NO silent mutation of frozen execution authority
```

The next development boundary should first establish a durable C5/C6 contract layer, then proceed only through explicit checkpointed authorization.

C7 operational hardening remains outside the currently frozen baseline.

---

## 12. Final RA-34 Status

**QA STATUS: VERIFIED — BASELINE FROZEN**

Required corrections embodied by this revision:

- Reclassify the project as currently **C6.6 IN PROGRESS**, not “RA-29 → RA-33 as a standalone stream”.
- Preserve the continuous `C6.6-RA-XX → RA-XX` checkpoint lineage.
- Correct the L1–L7 wording from “same-session” to **“across the submission session and subsequent restart/reconciliation cycle.”**
- Keep `ExecutionRequestProjection` / `DryRunResultProjection` staleness as **OPEN TECHNICAL DEBT**, because live behavior has not been investigated.
- Keep the C4.4 finding-name mismatch as **OPEN, NON-BLOCKING DOCUMENTATION/TEST-FIXTURE DEBT**.
- Add the absence of formal C5/C6 contract documents as **OPEN TECHNICAL DEBT**.
- Preserve the standing no-retry / no-new-OrderSend / DO-NOT-TOUCH restrictions.

**Commit authorization: GRANTED.**

The next QA decision should be based on this corrected document only after the working tree contains exactly this scope and no unrelated source or EventStore changes.

---

## 13. RA-34 Amendment 1 (RA-35 / RA-35.1) — 2026-09-15

### 13.1 Background

RA-35 (read-only) investigated whether any real DEMO order existed that
RA-34's original §9 Standing Restrictions did not account for. A code
comment introduced by RA-31 (`MLQuantAI.mq5`, line ~1095) referenced two
tickets — `3798882166` and `3799401055` — as prior real `OrderSend`
fills, neither of which appeared anywhere in RA-34 as originally frozen.

Git history alone could not establish current disposition: no EventStore
`.jsonl` file is tracked in this repository, and `3799401055` had no
commit-message evidence at all beyond that one code comment.

### 13.2 RA-35 initial ruling (superseded by 13.3 below)

RA-35's first verdict classified `3798882166` as `VERIFIED REAL / STILL
OPEN / DO NOT TOUCH`, based on incident-follow-up evidence available at
that time, and left `3799401055` as `UNRESOLVED`.

### 13.3 RA-35.1 — direct broker verification (supersedes 13.2)

RA-35.1 authorized direct, read-only verification against the live MT5
terminal's History tab — no OrderSend, no close, no modify, no
EventStore write, no code/Docs change during the check itself.

Account identity was independently confirmed via two cross-checks: the
account tree (`Exness-MT5Trial14`, login `416337755: Pro`) and a matching
account Balance figure (`10,689.37 USD`) present in both the History-tab
screenshot and the live Trade-tab screenshot that also showed
`3800463826` open — establishing both screenshots came from the same
account/terminal instance.

Broker History evidence for both tickets:

```text
3798882166
  type/volume = buy / 0.04 xauusd
  open        = 2026.09.10 15:59:27 @ 4367.246 (S/L 4261.602, T/P 4561.905)
  close       = 2026.09.10 16:02:09 @ 4367.275
  profit      = +0.12
  status      = CLOSED (complete round-trip, ~3 minutes held)

3799401055
  type/volume = buy / 0.04 xauusd
  open        = 2026.09.10 17:34:43 @ 4363.830 (S/L 4261.437, T/P 4561.740)
  close       = 2026.09.10 19:11:01 @ 4321.408
  profit      = -169.69
  status      = CLOSED (complete round-trip, ~1h36m held)
```

Neither ticket appears in the account's current Trade tab. The only
position currently open on this account is `3800463826`.

As a side effect, this same History screenshot independently
corroborated the RA-33.1/RA-33.2 attribution: the `3442407998` row shown
(`balance`, 2026.09.10 23:36:24, +1,000.00, comment
`D-trial-USD-1f2b9d87f3684c`) matches the `deal_ticket=3442407998` /
`DEAL_TYPE_BALANCE` record already identified as the root cause of
`TransactionMatching unmatched=1` and `C4.4 block_recommended=1` —
confirming it is a demo balance top-up, not a trade.

### 13.4 Final disposition

```text
3798882166 = CLOSED / HISTORICAL — no restriction required
3799401055 = CLOSED / HISTORICAL — no restriction required
3800463826 = STILL OPEN — DO NOT TOUCH (unchanged, sole standing restriction)
```

The §13.2 "STILL OPEN" classification for `3798882166` is superseded by
this direct broker-evidence finding and must not be relied upon.

### 13.5 Effect on §9 Standing Restrictions

§9's restriction list is **unchanged and remains complete as originally
written** — `3798882166` and `3799401055` are confirmed closed and
require no restriction; `3800463826` was already, and remains, the only
listed restriction. §9's own text is not rewritten by this amendment; see
the cross-reference note added there.

RA-34's baseline content (§§1–12) otherwise remains VALID and is not
reopened by this amendment.
