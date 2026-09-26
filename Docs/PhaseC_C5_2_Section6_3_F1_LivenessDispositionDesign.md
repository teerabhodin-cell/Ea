# PhaseC C5.2 §6.3 — F1 Liveness Design Disposition (F1a / F1b, plus new finding F1c)

**Revision 3 — records QA's ratification of every decision (D1-D9, D4,
D4-b, D4-c). Submitted for QA freeze review. Not frozen until QA says so.**
Recording-only revision: no option, rule or finding was added or changed
beyond writing down QA's decisions. Rev.2 added the D4 source trace (§8);
Rev.1 was opened by QA after Wave 2 closure ("C5.2 §6.3 — F1 Liveness
Design Disposition").

Ratification history:
- **QA review of Rev.1** (CONDITIONAL FREEZE): D1-D3 and D5-D9 RATIFIED;
  D4 left OPEN; extra condition added to B1 (§4.3); C2 NOT authorized.
- **QA review of Rev.2** (D4 source trace confirmed): D4, D4-b and D4-c
  RATIFIED (§8.4-§8.6, §7).

This document does not change the frozen §6.3 Design Contract Rev.14
(commit `6b7e836`). The ratified decisions are **contract requirements
for Rev.15**. Rev.15 is not yet written or frozen, and nothing here
authorizes implementation.

**No `.mqh`/`.mq5` file touched, no compile, no test, no commit, no push,
no `OrderSend`.**

---

## §0. Summary

| Gap | Level | What actually starves | Safety | Ratified disposition |
|---|---|---|---|---|
| F1a | candidate | every candidate behind the first one that is **issuable by state but can never progress** | fail-closed (safe) | A1 static admissibility filter + A2 one automated SUBMIT per request (both amend §2.3.1/§2.3.1a) |
| F1b | mailbox | every candidate, and human ceremonies too | fail-closed (safe) | B1 durable-mirror reconciliation for the provable cases, B0 (pause + human) for the rest; no timeouts, no leases |
| F1c (new) | invocation | nothing starves — the opposite: a **re-issue storm** | resource hazard | C1 pre-flight parity with the sealed pre-E1 guards; GRANT loop per §6.1 option (i); C2 (new durable marker) NOT authorized |

F1c came out of the same source trace as F1a/F1b. QA ratified it as a
separate gap and a Wave 3 blocker (D9). All three rows above are
RATIFIED (§7); fixture requests are excluded by D4 (§8.4).

---

## §1. Correction to the F1a framing (disclosed, evidence-backed)

QA's disposition describes F1a as "the first candidate stays
`SUBMISSION_ISSUED` without progress; discovery stops at it". That is not
the case in the frozen design or in the Wave 2 code:

- `SUBMISSION_ISSUED` candidates are **skipped** (`continue`), not stopped
  at — `MLQuantAI_BoundedAutomationDiscovery.mqh`, `BoundedAutomation_
  SelectCandidate()`, and Wave 2 test B: `[attempted, new_x, approved_y]
  -> index 1 new_x` (25/25, QA run 2026.09.27 02:44).
- A request with an E2 never blocks anyone: SA-1 makes it permanently
  non-issuable and discovery walks past it.

The real F1a is the first candidate whose derived state **issues a
command** (`NOT_YET_APPROVED` or `APPROVED_NOT_SUBMITTED`) but which can
never turn that command into progress. §2.3.1a (R16) selects it every
invocation, and Rev.2/Rev.3's cap rule ("Any cap failing → REJECT for
this candidate this invocation") has no fall-through, so nothing behind
it is ever evaluated. A second, narrower head-of-line case is Wave 2's
own fail-closed decision (an `UNKNOWN` candidate stops the scan).

---

## §2. Source-verified facts

### §2.1 F1b — how the single mailbox slot can stay occupied

| # | Fact | Source |
|---|---|---|
| B-1 | Every command handler writes a terminal mailbox status on every exit path (`CeremonyCommand_Complete()`/`_Fail()`, or the explicit FAILED write on the unresolved path). | `MLQuantAI.mq5` handlers at :878, :1032, :1084, :1120, :1153, :1185, :1223, :1380 — every `return;` checked; the only non-`Fail`/`Complete` return (:1352) writes `FAILED` itself at :1348-1351 |
| B-2 | `CeremonyCommand_Complete()` returns `false` **before** writing the mailbox when its durable write fails; no caller checks the return. The mailbox stays `CLAIMED` while the durable state is whatever was last written. | `MLQuantAI_CeremonyCommandEventEmission.mqh:388-389` |
| B-3 | `Complete()`/`Fail()` ignore `CeremonyCommandMailbox_Write()`'s return, so an I/O failure on the terminal write leaves `CLAIMED`. | same file :392, :403 |
| B-4 | A crash or terminal kill between claim and the terminal write leaves `CLAIMED`. After restart `TryClaim()` ignores anything not `PENDING`, so it stays `CLAIMED` forever. | same file :333-334 |
| B-5 | A stale `PENDING` from before a restart self-heals: the EA nonce increments on every `OnInit`, and `TryClaim()` rejects a stale nonce with a durable `COMMAND_REJECTED` + mailbox `REJECTED` (terminal). | `MLQuantAI.mq5:446-465`; `…EventEmission.mqh:343-344, 350-360` |
| B-6 | A `PENDING` whose `command_id` is already in the durable registry is never claimed and never rewritten — permanently `PENDING`. | `…EventEmission.mqh:339-340` |
| B-7 | A `PENDING` whose durable `COMMAND_RECEIVED` append fails stays `PENDING` and is retried every tick; persistent only while the store keeps failing. | `…EventEmission.mqh:366-369` |
| B-8 | No tool in the repository resets a stuck mailbox; the human issuer scripts abort when the slot is not free. F1b therefore already exists for human ceremonies today (pre-existing RA-31 property), not only for automation. | repo-wide search: no `FileDelete` of the mailbox; `Tests/MLQuantAI_ManualScript_GrantApproval.mq5` `OnStart()` |
| B-9 | A failed system-event write (`EventStore_WriteLine`) logs and returns false; it does **not** trip SafeMode (only candidate-birth and lifecycle writes do). | `MLQuantAI_EventStore.mqh:72-94` vs :178, :216 |

### §2.2 F1a — what "the whole registry" actually contains

| # | Fact | Source |
|---|---|---|
| A-1 | `EXECUTION_REQUEST_CREATED` is appended and live-applied to `ExecutionRequestProjection` **before** the dry-run `SafetyGate_Evaluate()`. A request whose dry-run was REJECTED is still in the registry that §2.3.1 scans. | `MLQuantAI_ExecutionRequestEventEmission.mqh:108-123` (request appended :111-114, live-applied :116-119, `SafetyGate_Evaluate()` only at :122) |
| A-2 | `RUN_C22_CEREMONY_FIXTURE` also creates ExecutionRequests (human ceremony fixtures). They are in the same registry. | `MLQuantAI.mq5:1006` |
| A-3 | `ExecutionRequestProjectionRecord` has no expiry or age field (only `recovery_anchor_time`, the durable creation `ts`). | `MLQuantAI_ExecutionAuditProjection.mqh:41-79` |
| A-4 | The registry is rebuilt from the current EventStore file, which by default is one file per calendar day fixed at `OnInit`; an EA left running across days keeps appending to its start-day file. | `MLQuantAI.mq5:138-143, 329` |
| A-5 | `SubmitOrderCommand()` rejects BEFORE E1 on: unresolved submission (RA-31.2 condition B), missing ExecutionRequest / candidate projection / candidate state. BUD-1: these consume no quota. | `MLQuantAI.mq5:1225-1243`; Rev.14 BUD-1 |
| A-6 | After E1, `BrokerSubmission_Submit()` re-runs SafetyGate, BrokerSubmissionGate, EnvironmentLock, EntryCompatibility, margin guard. A rejection there consumes quota (BUD-1) and leaves no E2, so the request re-derives as `APPROVED_NOT_SUBMITTED` (or `NOT_YET_APPROVED` once the 15-minute grant lapses). | `MLQuantAI.mq5:1312-1331`; Rev.14 BUD-1 |
| A-7 | GRANT commands carry no cap of any kind (all three submission caps count E1 only). | Rev.14 §3.2, BUD-1 |
| A-8 | `CeremonyCommand_Fail()` writes `COMMAND_FAILED` with no `execution_request_id` and no provenance; `COMMAND_RECEIVED` (claim) has neither either. Only E1 (via PROV-1) and the grant event carry automation provenance. | `…EventEmission.mqh:365-368, 397-399`; Rev.14 PROV-1 |

### §2.3 Consequences, stated concretely

- **F1a-1 (static):** a request that no cap can ever admit (lot > 0.01,
  symbol not `_Symbol`) or a dry-run-REJECTED request is selected every
  invocation. Static caps REJECT → nothing behind it is ever evaluated.
- **F1a-2 (quota burn):** a request the C2 gates reject after E1 (e.g.
  the dry-run-REJECTED requests of A-1, deterministically rejected again
  by the fresh SafetyGate, or EntryCompatibility drift on an old request)
  consumes one of the 3 daily submissions per attempt, every 3600 s
  cooldown, forever — the daily budget is spent on a request that can
  never fill.
- **F1a-3 (untrusted record):** an `UNKNOWN` candidate stops the scan
  (Wave 2 implementation decision) — permanent while the data stays
  untrusted.
- **F1c (re-issue storm):** anything rejected before E1 (A-5) or any GRANT
  that fails deterministically (A-7) is re-issued on the next invocation.
  With the RA-32.1 `OnTimer` cadence (2 s), each cycle writes at least two
  durable lines (`COMMAND_RECEIVED`, `COMMAND_FAILED`) — about 86,400
  lines/day. `EventStore_ReadAllLines()` has already crashed once on a
  190k-line store (TD-INFRA-001, `MLQuantAI_EventStore.mqh:263-270`), so
  F1c is a resource hazard, not only a liveness one.

---

## §3. Design principles proposed for both gaps

| Id | Principle | Why |
|---|---|---|
| L-1 | **No wall-clock timeouts, leases, or TTLs.** | `TimeCurrent()` freezes at the last server tick while the market is closed; `TimeLocal()` is not a durable fact; §6.x lineage never trusts a clock for a correctness decision. |
| L-2 | **Only durable EventStore evidence decides "stale" or "exhausted".** | Same rule as §2.3.2 (historical truth = EventStore only). |
| L-3 | **The Decision Engine never writes the EventStore and never overwrites a mailbox it has not confirmed as its own.** | §2.1; §2.3.2a. Any reconciliation of someone else's mailbox record belongs to the EA's claim path, which already owns every write from `CLAIMED` onward. |
| L-4 | **Fail-closed means "automation pauses and a human reconciles"; SafeMode only for integrity violations.** | Liveness gaps are not corruption. PROV-1 already defines the pause-until-reconciled pattern (R15). |
| L-5 | **No new execution authority, no new command type that can reach `OrderSend`.** | §2.5 / §8 of Rev.14. |

---

## §4. F1b — mailbox-level disposition

### §4.1 Options

**B0 — observe and pause (no new behaviour).** Discovery keeps returning
`MAILBOX_OCCUPIED` (Wave 2, frozen). Wave 5 adds a diagnostic log only.
Recovery is a human operator deleting or overwriting the mailbox file,
which RA-31.2's own doctrine already permits ("may be lost, corrupted, or
overwritten without any loss of history"). Liveness depends entirely on a
human. No contract amendment.

**B1 — durable-mirror reconciliation in the EA claim path (recommended
for the provable cases).** Before `TryClaim()`, the EA reads the mailbox
once. If the mailbox shows `CLAIMED` or `PENDING` for a `command_id` that
the **durable** ceremony registry already holds in a
mailbox-terminal-equivalent state, the EA rewrites the mailbox to the
terminal status that `Complete()`/`Fail()` would have written:

| Durable state of that `command_id` | Mailbox rewritten to |
|---|---|
| `APPROVAL_RECORDED`, `ENTRY_COMPATIBILITY_EVALUATED`, `OUTCOME_RECORDED`, `ROLLOUT_STAGE_TRANSITIONED`, `KILL_SWITCH_ENGAGED`, `KILL_SWITCH_CLEARED`, `CEREMONY_READY`, `SUBMISSION_COMPLETE`, `OBSERVATION_COMPLETE` | `COMPLETE` |
| `COMMAND_FAILED` | `FAILED` |
| `COMMAND_REJECTED` | `REJECTED` |
| `SUBMISSION_IN_PROGRESS` (unresolved) | **never touched** — RA-31.2 condition B, human reconciliation |
| `COMMAND_RECEIVED`, `CEREMONY_IN_PROGRESS`, not in the registry, or registry unavailable | **never touched** — B0 |

This covers B-2, B-3, B-4 (after `FailInterruptedCommands()` turns an
interrupted `CEREMONY_IN_PROGRESS` into durable `COMMAND_FAILED` at
`OnInit`) and B-6 when the known id is terminal. Every rewrite follows a
durable fact the EA itself wrote; nothing is inferred from time or
absence. **REQUIRES RATIFICATION as a change to the sealed RA-31 claim
path** (a new EA-side function called at the top of
`RA31_ProcessCeremonyCommand()`, or an amendment inside
`MLQuantAI_CeremonyCommandEventEmission.mqh`). It also frees human
ceremonies (B-8), so it is an RA-31 protocol change, not a §6.3-only one.

**B2 — time-based lease/timeout (not recommended).** Rejected under L-1:
a frozen `TimeCurrent()` over a weekend would either never expire or
expire everything at Monday's first tick, and a timeout lets the Decision
Engine overwrite a command it does not own (violates L-3).

### §4.2 QA's eight questions — F1b

| # | Question | Proposed answer |
|---|---|---|
| 1 | What is "stale"? | Not time. A mailbox record is stale iff its status is `PENDING`/`CLAIMED` **and** the durable registry holds that `command_id` in a mailbox-terminal-equivalent state (§4.1 table). Anything else occupied is "occupied", not stale. |
| 2 | Who has authority to change it? | Only the EA's claim path (it already owns every mailbox write from `CLAIMED` on), only to mirror durable truth. Never the Decision Engine, never a script. |
| 3 | Timeout / lease? | None (L-1). |
| 4 | Skip candidates? | Not applicable at this level: an occupied mailbox stays a whole-invocation no-op (Wave 2 frozen rule, unchanged). |
| 5 | Reclaim the mailbox? | Only B1's mirror rewrite. Never for `SUBMISSION_IN_PROGRESS`, `COMMAND_RECEIVED`, `CEREMONY_IN_PROGRESS`, or an unknown `command_id`. |
| 6 | Crash/restart interpretation | Stale `PENDING` self-heals by nonce (B-5). `CLAIMED` after restart is mirrored once the durable state is terminal (`FailInterruptedCommands()` already makes interrupted ceremonies durable `COMMAND_FAILED`). `SUBMISSION_IN_PROGRESS` stays blocked for human reconciliation, as today. |
| 7 | Durable evidence used | `CEREMONY_COMMAND_STATE_CHANGED` lines via the existing `CeremonyCommandRegistry` (rebuilt at `OnInit`, updated on every append). |
| 8 | Which fail-closed cases enter SafeMode? | None. F1b is transport-level; B0 pauses automation. SafeMode stays reserved for integrity violations (L-4). |

### §4.3 QA condition on B1 (Rev.1 review, recorded)

B1 may rewrite a mailbox only when the durable registry gives **one
clear terminal truth for that exact `command_id`**. Conflicting,
duplicated, unavailable or otherwise ambiguous durable evidence falls
back to B0 (pause + human reconciliation). The recovery routine never
chooses between competing durable states.

---

## §5. F1a — candidate-level disposition

### §5.1 Options

**A0 — accept literal Rev.14 (not recommended).** No mechanism exists to
retire an ExecutionRequest, so a human cannot unblock F1a-1/F1a-2 short of
rolling the stage back. Effective permanent starvation.

**A1 — static admissibility filter inside discovery: skip, not stop
(recommended).** A candidate is *admissible* only if every check that
depends solely on its own immutable, durable record passes:

1. its dry-run result is `ACCEPTED` (`DryRunResultProjection`, durable,
   written right after the request — A-1). The projection has no
   by-id accessor, only `DryRunResultProjection_Count()`/`_GetAt()`
   (records carry `execution_request_id` and `decision`) and
   `_HasAnyFor()`, which only answers existence
   (`MLQuantAI_ExecutionAuditProjection.mqh:156-214`). A request with **no**
   dry-run record (the request append succeeded, the dry-run append did
   not — the case the emission comment at
   `MLQuantAI_ExecutionRequestEventEmission.mqh:80-85` describes) is
   inadmissible (fail-closed);
2. `lot_size <= max_lot_size_per_submission` (R2);
3. symbol and strategy are in `symbol_allowlist` / `strategy_allowlist` (R8).

An inadmissible candidate is skipped exactly like `SUBMISSION_ISSUED`.
Because every input is immutable, its admissibility can never change, so
skipping it cannot flap and cannot change which candidate is "first" for
any admissible one. Invocation-wide caps (daily count, daily volume,
cooldown, exposure, session/day window) are unaffected and still block
the whole invocation. **REQUIRES CONTRACT AMENDMENT** to §2.3.1 and
§2.3.1a (R16 wording: "first eligible" becomes "first admissible and
state-eligible").

Requests created by `RUN_C22_CEREMONY_FIXTURE` (A-2) are human ceremony
fixtures. **RATIFIED (D4, QA review of Rev.2):** they are not automation
candidates. A1 treats them as inadmissible (skip, not stop) under the
exact rule `FIXTURE(X) ⇔ M1(X) OR M2(X)` in §8.4.

**A2 — one automated SUBMIT ceremony per execution_request_id
(recommended).** If the validated snapshot holds an E1 for this request
that PROV-1 classifies AUTOMATION and there is no E2 for it, the request
is **automation-exhausted**: discovery skips it permanently. A human may
still act on it through the normal manual ceremony. Durable (E1 is
already the ratified automation-issuance event, R10), no clock, no new
event type. This closes F1a-2: at most one unit of daily quota is ever
spent on a request that the post-E1 gates reject. **REQUIRES CONTRACT
AMENDMENT**: it tightens BUD-1's "re-issuance after such a rejection is
rate-limited by the cooldown and daily caps" into "no automated
re-issuance".

**A3 — age filter on `recovery_anchor_time` (not recommended as the
primary fix).** Needs a new ratified policy value and a clock (L-1 applies
to the `now` side). Could complement A1/A2 later.

**F1a-3 (`UNKNOWN` stops the scan):** keep as implemented in Wave 2. It
only arises from untrusted data (empty id, registry not ready, bad asOf),
and skipping untrusted data could change which candidate is "first".
Disposition: pause plus human reconciliation, same as L-4. QA may prefer
"skip", which would be a Wave 2 behaviour change.

### §5.2 QA's eight questions — F1a

| # | Question | Proposed answer |
|---|---|---|
| 1 | What is "stale"? | Not time. *Inadmissible* (A1: fails a check on its own immutable record) or *automation-exhausted* (A2: an AUTOMATION E1 exists without an E2). |
| 2 | Who has authority to change it? | Nobody changes the candidate: both are read-only classifications computed from durable evidence during discovery. No candidate state is written. |
| 3 | Timeout / lease? | None (L-1). |
| 4 | Skip candidates? | Yes, for inadmissible and exhausted candidates only (skip = `continue`, identical to `SUBMISSION_ISSUED`). `UNKNOWN` still stops. |
| 5 | Reclaim the mailbox? | Not applicable at candidate level. |
| 6 | Crash/restart interpretation | Identical before and after a restart: both classifications are re-derived from the same durable lines every invocation, with no in-memory state. |
| 7 | Durable evidence used | `EXECUTION_DRY_RUN_COMPLETED` (A1.1), the immutable request record (A1.2-3), E1 with PROV-1 and E2 (A2). |
| 8 | Which fail-closed cases enter SafeMode? | None new. A PROV-1 INVALID E1 already halts automation under R15; A2 reads E1 only through PROV-1, so an INVALID line fails closed the same way. |

---

## §6. F1c — re-issue storm (new finding)

### §6.1 Options

**C1 — pre-flight parity with the sealed pre-E1 guards (recommended).**
Before issuing a SUBMIT, the Decision Engine performs the same read-only
checks `SubmitOrderCommand()` performs before E1, and issues nothing when
one would fail:

- `CeremonyCommandRegistry_HasUnresolvedSubmission()` (RA-31.2 condition
  B, read-only, sealed): when true, issue nothing for the whole invocation;
- the candidate projection and candidate state lookups that
  `SubmitOrderCommand()` performs at :1233-1243.

These reuse sealed read-only functions; no new policy value. Kill switch
and stage × environment are already first in the frozen invocation order,
so Check A/B rejections are already pre-empted.

**C2 — a durable per-invocation issuance budget for all automation
commands (only if QA wants a hard bound).** It would need provenance on a
durable line that every automated command writes even when it fails. No
such line exists today (A-8), so C2 needs a new amendment, e.g. a PROV-1
token on the claim line. That is a third sealed-file change; noted, not
recommended now.

**Failed GRANT loop (A-7):** with A2 in place, an automated GRANT that
succeeds leads to at most one automated SUBMIT. An automated GRANT that
fails deterministically (grant write failure, R13 stage × environment
reject) still loops, and C1 does not cover it. Options:

- (i) accept, since the Decision Engine checks stage × environment before
  issuing, so the R13 rejection is already pre-empted, and a grant *write*
  failure means the EventStore itself is failing;
- (ii) add an A2-style marker for GRANT, which needs provenance on the
  GRANT ceremony's `CEREMONY_IN_PROGRESS` line. That line is written
  inside the R13 function, so it would extend R13 and requires ratification.

RATIFIED (D7): (i) plus an explicit statement that repeated EventStore write
failure is outside liveness scope.

### §6.2 Classification — RATIFIED (D9)

F1c is a **Wave 3 blocker alongside F1a/F1b**: a 2-second retry loop can
grow the store toward the size that already crashed
`EventStore_ReadAllLines()` once. C1 is RATIFIED (D7). C2, a new durable
provenance marker, is **NOT authorized**; it would need a separate
explicit amendment.

---

## §7. Decision register — ALL RATIFIED

| # | Decision | Ratified | When |
|---|---|---|---|
| D1 | F1b disposition | B1 for the provable cases (§4.1 table) + B0 for the rest, **with the §4.3 condition**: one clear terminal durable truth per exact `command_id`, otherwise B0 | QA review of Rev.1 |
| D2 | B1 location | EA claim path, new function called at the top of `RA31_ProcessCeremonyCommand()` (RA-31 protocol change) | QA review of Rev.1 |
| D3 | F1a static filter | A1 (dry-run ACCEPTED, lot ≤ R2, symbol/strategy ∈ R8), skip not stop | QA review of Rev.1 |
| D4 | Ceremony-fixture requests | `FIXTURE(X) ⇔ M1(X) OR M2(X)` → inadmissible → skip (`continue`), never stop (§8.4) | QA review of Rev.2 |
| D4-b | Reserved policy value | `"EXECPOLICY_C2_SMOKE_V1"` is **reserved**: the C5 pipeline must not accept it as `InpC5ExecutionPolicyVersion` (§8.5). This is a Rev.15 contract requirement, not an authorization to edit `MLQuantAI.mq5` now. | QA review of Rev.2 |
| D4-c | C5 stub-pipeline scope | C5 pipeline candidates are in §6.3 scope **for plumbing/control-plane verification only**; `RUN_C22_CEREMONY_FIXTURE` requests are excluded (§8.6) | QA review of Rev.2 |
| D5 | Automated re-issuance after a post-E1 rejection | A2: one automated SUBMIT per request, then exhausted | QA review of Rev.1 |
| D6 | `UNKNOWN` candidate | keep "stop the scan" (Wave 2 as closed) | QA review of Rev.1 |
| D7 | F1c | C1 pre-flight parity; GRANT loop per §6.1 option (i); C2 NOT authorized | QA review of Rev.1 |
| D8 | Contract vehicle | Rev.15 of the §6.3 Design Contract amending §2.3.1, §2.3.1a (R16) and BUD-1, plus an RA-31 amendment note for D1/D2 | QA review of Rev.1 |
| D9 | F1c classification | Wave 3 blocker | QA review of Rev.1 |

---

## §8. D4 source trace — ceremony-fixture requests (Rev.2)

QA's required path: identify a deterministic durable marker → prove it
survives replay/restart → prove normal requests cannot carry it
accidentally → exact rule → ratification. Read-only trace; no code.

### §8.1 Every producer of an ExecutionRequest in the EA's own store

| Producer | Where | `execution_policy_version` |
|---|---|---|
| `RUN_C22_CEREMONY_FIXTURE` handler | `MLQuantAI.mq5:991` (policy), `:1002` (build), `:1006` (emit) | hard-coded literal `"EXECPOLICY_C2_SMOKE_V1"` |
| C5 candidate pipeline (`OnTick`) | `MLQuantAI.mq5:1782` (policy), `:1793` (build), `:1813` (emit) | operator input `InpC5ExecutionPolicyVersion`, default `"C5_0_FIXTURE_EXECUTION_POLICY_V1"` (`:115`) |

There are no other production producers. Every other
`ExecutionRequest_Build()`/`_EmitAndEvaluate()` call is in `Tests/*.mq5`
against the test's own fixture file. The only operator script that opens
the canonical store (`Tests/MLQuantAI_ManualScript_AcknowledgeAudit.mq5:60`)
writes no ExecutionRequest. `MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5`
only issues `RUN_C22`/`SUBMIT_ORDER` mailbox commands (`:145-146`).

The fixture's market context uses the real instrument (`XAUUSD`/`M5`,
`MLQuantAI.mq5:807-812`), so there is no marker at the context level.

### §8.2 Candidate markers

**M1 — policy-version literal.** `X.execution_policy_version ==
"EXECPOLICY_C2_SMOKE_V1"`.
- Durable: it is a field of the `EXECUTION_REQUEST_CREATED` line and of
  `ExecutionRequestProjectionRecord`.
- Immutable: it is an input to `Ids_ExecutionRequestId()`
  (`MLQuantAI_Ids.mqh:247-254`) and to the request hash
  (`MLQuantAI_ExecutionRequestContract.mqh:144`), so it cannot change
  without changing the request's identity.

**M2 — the fixture ceremony's own durable line.** The validated snapshot
contains a `CEREMONY_COMMAND_STATE_CHANGED` line with `command_type ==
"RUN_C22_CEREMONY_FIXTURE"` and `execution_request_id == X`. It is written
by `CeremonyCommand_Complete(..., CEREMONY_READY, "dry_run_accepted",
req.execution_request_id)` at `MLQuantAI.mq5:1018`.

### §8.3 Proofs

| Requirement | M1 | M2 |
|---|---|---|
| Deterministic | pure function of the request record | pure function of one raw line in the validated snapshot |
| Survives replay/restart | projection rebuilt from the append-only `EXECUTION_REQUEST_CREATED` line; no in-memory state | append-only line; `CEREMONY_READY` is never rewritten by restart handling (`FailInterruptedCommands()` only fails `CEREMONY_IN_PROGRESS`, `…EventEmission.mqh:246-259`) |
| Recall (every fixture request has it) | **yes, always**: single code path, literal set before build (`:991` → `:1002` → `:1006`) | **no, not always**: absent when `Complete()`'s durable write fails (F1b fact B-2) although the request exists with dry-run ACCEPTED |
| A normal request can carry it by accident | **yes, but only by deliberate operator input**: `InpC5ExecutionPolicyVersion` is free text (`:115`); setting it to the literal marks C5 requests as fixtures | **no, by construction**: the only line with `command_type` `RUN_C22` and a non-empty ERID is `:1018`. Every other `RUN_C22` line has ERID `""` ("building" `:880-882`; claim/reject in `TryClaim()`; `Fail()` `:399`; `FailInterruptedCommands()`). The C5 pipeline writes no ceremony lines at all. |

Neither marker alone meets every requirement. M1 alone has full recall
but a false positive under operator misconfiguration. M2 alone has no
false positives but misses the B-2 case.

### §8.4 Exact rule — RATIFIED (D4), for Rev.15

```
FIXTURE(X)  <=>  M1(X)  OR  M2(X)

A FIXTURE request is inadmissible for automation (A1, skip - never
stop). Evaluated from the same validated snapshot and the same
ExecutionRequestProjection record the Decision Engine already reads;
no new event, no new field, no clock.
```

Under the union:
- **Recall is complete** because M1 alone is complete.
- **The only error mode is a false exclusion**: a C5 request whose
  operator set the policy input to the fixture literal. That is the
  fail-safe direction: lost liveness for that request, never added
  authority.
- **M2 adds positive durable confirmation**, independent of the literal,
  if the literal is ever renamed in a future change.

### §8.5 D4-b — reserved policy value — RATIFIED

`"EXECPOLICY_C2_SMOKE_V1"` is a **reserved value**. The C5 pipeline must
not accept it as `InpC5ExecutionPolicyVersion`, which removes M1's only
false-positive path (a C5 request carrying the fixture literal). Rev.1/2
proposed deferring this; QA ratified it instead as a **contract requirement
for Rev.15**. The enforcing mechanism (e.g. an `OnInit` input check in
`MLQuantAI.mq5`) is decided with Rev.15 and implemented only under a
later, separate implementation authorization. **No source change is
authorized by this ratification.**

### §8.6 D4-c — C5 stub-pipeline scope — RATIFIED

The only other producer, the C5 pipeline, is itself labelled **"C5.0 TEST
FIXTURE candidate pipeline"** (`MLQuantAI.mq5:102`, `:1583-1585`):
- stub AI inference: `InpC5StubPSuccess = 1.0` (`:105`) with model
  identity `STUB_NO_MODEL_V1` (`:1705-1718`) — every signal passes the AI
  gate by default;
- `C5_0_FIXTURE_*` policy versions throughout (`:104-115`).

C5.2 Commit 2 lets this pipeline run outside the Strategy Tester when
`RolloutStage_PermitsPipelineRun()` allows it (`:1607-1617`). With D4
applied, the automation candidate set is therefore **exactly the C5.0
stub-AI requests**. **QA decision (D4-c):** C5 pipeline candidates are within §6.3 scope for
plumbing/control-plane verification; `RUN_C22_CEREMONY_FIXTURE` requests
are excluded (D4). The evidence boundary is binding:

```
C5 stub candidate  =  proof of automation plumbing / control
                   ≠  proof of real-model AI quality
```

No §6.3 evidence produced from C5 stub-AI candidates may be cited as
evidence of model quality, signal quality or market suitability.

---

## §9. Explicitly NOT authorized by this document

```
Implementation        = NOT AUTHORIZED
Source modification   = NOT AUTHORIZED
Rev.14 modification   = NOT AUTHORIZED (every change above is a proposal)
Tests                 = NOT AUTHORIZED
Commit / Push         = NOT AUTHORIZED

DEMO_BOUNDED_AUTOMATION = NOT UNLOCKED
DEMO_REAL_SUBMIT        = LOCKED
OrderSend               = NOT AUTHORIZED
LIVE                    = FORBIDDEN
3800463826              = DO NOT TOUCH
```
