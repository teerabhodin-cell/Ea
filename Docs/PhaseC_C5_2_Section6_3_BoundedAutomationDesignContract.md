# PhaseC C5.2 §6.3 — `DEMO_REAL_SUBMIT -> DEMO_BOUNDED_AUTOMATION` Design Contract

**Revision 15 — contract amendment from the frozen Rev.14 (commit
`6b7e836`). It carries exactly the decisions ratified in the frozen F1
Liveness Disposition Rev.3 (`Docs/PhaseC_C5_2_Section6_3_F1_Liveness
DispositionDesign.md`, commit `16189be`): D1-D9, D4-b and D4-c. No other
design change is made, and no ratified meaning is altered. Rev.14 stays
the frozen baseline in git history; Rev.15 amends it and does not rewrite
that history. Each Rev.15 change is marked `[Rev.15 AMENDMENT — Dn]` in
place, and the Rev.14 text it amends is kept. Where writing a ratified
decision as contract text required a precision the decision did not
state, the choice is listed in §7 "Rev.15 precision notes" (P-1..P-4)
for QA's explicit confirmation. Submitted for QA amendment-freeze review.
Not frozen.**

Governing documents: `Docs/PhaseC_C5_2_ControlledExecutionEnvironmentLadderContract.md`
and, as pattern precedent, the frozen `Docs/PhaseC_C5_2_Section6_2_
EvidenceGateDesignContract.md`.

**Revision history**: Rev.1 (6 blockers) → Rev.2 (closed all 6, 8 new) →
Rev.3 (closed all 8, 4 new) → Rev.4 (closed all 4, proposed ratifiable
values) → Rev.5 (closed all 5, but introduced a genuine ordering bug of
its own — `APPROVAL_QUEUED` unreachable) → Rev.6 (closed all 4, but left 3
mechanisms it newly relied on under-specified — LOST accounting,
`EventStore_ReadAllLines()` failure semantics, exposure reference-price
semantics) → Rev.7 (closed all 3, but in the process introduced an
undisclosed cap-scope regression, and left two further gaps — the
system-issued-GRANT rollback leak, and an unproven duplicate-safety
claim) → Rev.8 (closed all 4 — system-issued-GRANT leak, duplicate-safety
citation, exposure directionality, cap-scope revert — but the duplicate-
safety citation and the GRANT-provenance mechanism both leaned on
un-re-verified assumptions) → Rev.9 (closed all 3 Round 8 blockers, each
via source trace — corrected a real event-type-name and duration/
timestamp bug of Rev.8's own along the way — but the duplicate-safety
proof still had a gap QA found: the `candidate.state` precondition does
not protect the "OrderSend succeeded, durable transition write failed"
case, and the GRANT-provenance mechanism's own freshness relative to the
validated EventStore snapshot had not been proven, only assumed) → Rev.10
(closed both via source trace — found the durable
`SubmissionAttemptRegistry_HasAttempt()` guard, and argued registry
freshness from single-producer/single-threaded structure — but stated
both as proof narratives rather than frozen invariants, attributed the
in-session duplicate case to the wrong check, and overstated freshness as
unconditional) → Rev.11 (closed Round 10's 2 blockers
by freezing SA-1 and MA-1 as formal invariants and correcting Rev.9/Rev.10
statements, but left the caps' meaning ambiguous between E1 and E2, and
§1 unreconciled) → Rev.12: closes Round 11's 2
blockers (BUD-1; §1 restored and reconciled) and turns the narrowed
Check B predicate into frozen invariant SG-1 (but left E1 provenance
classification and SG-1's authoritative source open) → Rev.13: closes Round 12's 2 blockers (PROV-1; SG-1 authoritative
source = validated durable snapshot ∪ projection) → Rev.14 (FROZEN,
`6b7e836`): records QA's ratification of R1–R15 (all approved as
proposed), then, after the Final Design Freeze Review, of R16 (§2.3.1a)
and R17 (§2.3.4); status wording only, plus stale E1-classifier text
corrections to PROV-1 (§2.3.2a, §3.2, BUD-1, Rev.9 historical marker),
no design change → **Rev.15 (this revision)**: amendment carrying the
F1 Liveness Disposition Rev.3 decisions (D1-D9, D4-b, D4-c) into
§1.4, §2.3.1, §2.3.1a, §2.3.2, §2.3.2b, SA-1 (note), §3.2/BUD-1, §2.5,
§2.6 (RA-31 amendment note), §4 and §7.

**No `.mqh`/`.mq5` file touched, no compile, no test run, no `OrderSend`, no
live execution.** This document is a design artifact only.

---

## §0. What this transition actually unlocks (unchanged since Rev.1)

```
DEMO_REAL_SUBMIT (current)                  DEMO_BOUNDED_AUTOMATION (target)
--------------------------------------------------------------------------------
Candidate pipeline runs        YES          Candidate pipeline runs        YES  (unchanged)
Reaches dry-run                YES          Reaches dry-run                YES  (unchanged)
SUBMIT_ORDER reachable         YES, via     SUBMIT_ORDER reachable         YES, via
                                existing C2                                 existing C2
                                boundary                                    boundary (unchanged)
Manual approval per-submission MANDATORY    Manual approval per-submission NO
Automatic submission           NO           Automatic submission           YES, within
                                                                             frozen caps
```

**Governing principle (inherited, non-negotiable)**: unchanged. The two
sealed-file (Class 2) amendments, `GrantManualApprovalCommand()` (§2.4)
and `SubmitOrderCommand()` (§2.3.3, §3.2), are RATIFIED as design (R13,
R14; Rev.14). Ratification covers the design only: implementation
remains NOT AUTHORIZED (§8). [Rev.15 AMENDMENT — D2, D4-b: two further
change areas are ratified as contract requirements through F1 Rev.3 —
the RA-31 claim-path reconciliation function (§2.6), which is a change
to sealed RA-31 code, and the reserved-policy input check for the C5
pipeline in `MLQuantAI.mq5` (§2.3.1). Neither is authorized for
implementation by this revision.]

---

## §1. §6.3 Transition Acceptance Criteria — full text restored and reconciled (Rev.12, closing Round 11 Blocker 2)

**Why this section is rewritten in full**: from Rev.4 through Rev.11 this
section was a pointer ("see Rev.3 text"). That text was never in this
file: the document has not been committed, so the only surviving copy of
P1-P8 was in this session's transcript (Rev.1 for P2-P7, Rev.2 for P8,
Rev.3 for P1). It is reproduced here in full, reconciled predicate by
predicate against the E1/E2 split and against the source, so an
implementer never has to reconstruct it from history. Each predicate names
exactly one canonical evidence source.

**Reconciliation findings (source-traced this revision)**:

```
1. WRONG EVENT NAME, in P1 (Rev.1/Rev.2 text) and P8 (Rev.2 text):
   "EVENT_TYPE_MANUAL_APPROVAL_GRANTED" does not exist (0 matches in
   Include/ and MLQuantAI.mq5). The real type is EVENT_TYPE_EXECUTION_
   MANUAL_APPROVAL_GRANTED (MLQuantAI_ManualApprovalEmission.mqh:113) -
   the same error Rev.9 corrected in §2.3.3, never propagated to §1.

2. P2 and P8 already meant E2, and still do: P2 reuses §6.2's own P1,
   which iterates SubmissionAttemptProjection (E2) - confirmed,
   MLQuantAI_RolloutGateReadinessEvaluate.mqh:190-193. P8 read E2 via
   SubmissionAttemptProjectionRecord. Now pinned by name.

3. No predicate used E1. P8b (below, NEW Rev.12, RATIFIED R12) is the first to.

4. P1's retcode rule had two dead entries and one uncovered path:
   - TRADE_RETCODE_CONNECTION and TRADE_RETCODE_TIMEOUT fall to the
     sealed classifier's default -> SUBMISSION_STATUS_UNKNOWN, and "the
     candidate is NEVER transitioned for UNKNOWN" (MLQuantAI_Broker
     SubmissionBuilder.mqh:165-172, 219-221). They can never produce
     CANDIDATE_REJECTED_BY_BROKER, so listing them as P1-qualifying was
     dead text.
   - CANDIDATE_REJECTED_BY_BROKER has TWO producers: the synchronous one
     (MLQuantAI_BrokerSubmissionAdapter.mqh:352, driven by the
     classifier) and the asynchronous C3.10B one (MLQuantAI_AsyncTerminal
     RejectionAuthority.mqh:425), which transitions a candidate that was
     first acknowledged (outcome retcode DONE/DONE_PARTIAL). Rev.3's rule
     read the outcome retcode for both, so an async rejection was
     classified by "DONE" - silently falling to the default. §1.2a now
     classifies the async path explicitly.

5. Every other identifier §1 uses exists: CANDIDATE_EXECUTED,
   CANDIDATE_REJECTED_BY_BROKER, EVENT_TYPE_KILL_SWITCH_ENGAGED,
   EVENT_TYPE_EA_SESSION_STARTED, SafeModeProjection_ReplayEngaged
   DuringWindow, BrokerFactCorrelation_VerifyWindow, CandidateTerminal
   Transition_FindLineIndex, RolloutStageObservationWindow_FindStart,
   ReplayEngine_Run, BrokerReconciliation_CheckAll.
```

**Canonical evidence source per predicate (frozen)**:

| Predicate | Canonical source | Event identity |
|---|---|---|
| P1 | in-window lifecycle transition to `CANDIDATE_EXECUTED` / `CANDIDATE_REJECTED_BY_BROKER`, joined via `ExecutionRequestProjection` to an E2 that passes P8; outcome record for classification | lifecycle + **E2** + outcome record |
| P2 | `SubmissionAttemptProjection` (§6.2 P1 verbatim) | **E2** |
| P3 | `BrokerFactCorrelation_VerifyWindow()` | broker-transaction facts (no E1/E2) |
| P4 | `CandidateTerminalTransition_FindLineIndex()` | lifecycle (no E1/E2) |
| P5 | `ReplayEngine_Run` + `BrokerReconciliation_CheckAll` + `EVENT_TYPE_EA_SESSION_STARTED` | no E1/E2 |
| P6 | `SafeModeProjection_ReplayEngagedDuringWindow` + quarantine witness | no E1/E2 |
| P7 | `EVENT_TYPE_KILL_SWITCH_ENGAGED` (DEMO) | no E1/E2 |
| P8 | every in-window **E2**, bound to `EVENT_TYPE_EXECUTION_MANUAL_APPROVAL_GRANTED` | **E2** + grant |
| P8b (new Rev.12; RATIFIED R12) | every in-window **E1**, classified by PROV-1 (`submission_provenance`) | **E1** |

### §1.1 Evidence window (unchanged since Rev.1)

```
window_start = the index of the LATEST EXECUTION_ROLLOUT_STAGE_CHANGED line
               whose own to_stage == ROLLOUT_STAGE_DEMO_REAL_SUBMIT
               (RolloutStageObservationWindow_FindStart(), sealed, reused
               exactly as §6.1/§6.2 reuse it)
window_end   = the evaluator's own fresh evidence snapshot's final line
Not found -> hard REJECT, window_not_found.
```

### §1.2 Predicates (all must independently hold)

**P1 — minimum proven, human-supervised submission track record.** `>= N`
distinct `candidate_id` values `c` such that ALL of:

```
(i)   an in-window lifecycle transition exists for c to CANDIDATE_EXECUTED
      or CANDIDATE_REJECTED_BY_BROKER;
(ii)  an E2 line exists for an execution_request_id whose
      ExecutionRequestProjection record has candidate_id == c, and that
      E2 passes P8's binding with a human (non-reserved) approver_identity;
(iii) the terminal outcome qualifies under §1.2a.
```

`N = 5` — RATIFIED (R1, Rev.14). Reasoning unchanged since Rev.1: a
stricter bar than §6.1's `>= 3`, since §6.3 removes the last human
checkpoint.

#### §1.2a Terminal-outcome classification for P1 (exhaustive; Rev.12)

```
CANDIDATE_EXECUTED -> QUALIFIES.

CANDIDATE_REJECTED_BY_BROKER -> classify by the SubmissionOutcomeProjection
record for the E2's execution_request_id:

  submission_status == REJECTED (the SYNCHRONOUS path) -> by retcode.
  The sealed classifier can emit exactly 21 REJECTED retcodes (MLQuantAI_
  BrokerSubmissionBuilder.mqh:186-217); every one is bucketed here:

    QUALIFYING (RATIFIED, R9) - price moved between request and fill; the
    request itself was well-formed:
      REQUOTE, PRICE_CHANGED, PRICE_OFF

    NON-QUALIFYING (RATIFIED, R9) - the request was defective, OR the cause
    plausibly lies in this pipeline's own behaviour, OR it is not clean
    evidence of the human-supervised process working:
      INVALID_STOPS, INVALID, INVALID_VOLUME, INVALID_PRICE, INVALID_FILL,
      INVALID_ORDER, TRADE_DISABLED, REJECT, LOCKED, FROZEN, ONLY_REAL,
      LIMIT_ORDERS, LIMIT_VOLUME, LONG_ONLY, SHORT_ONLY,
      NO_MONEY          - the pre-send margin guard (RA-49) already passed,
                          so a broker NO_MONEY means our own margin check
                          disagreed with the broker's: a pipeline-accuracy
                          defect, not a clean outcome;
      TOO_MANY_REQUESTS - a request-rate condition this pipeline itself
                          can cause;
      MARKET_CLOSED     - CHANGED from Rev.3 (was qualifying): submitting
                          into a closed market points at this pipeline's
                          own session handling; conservative, and only
                          makes P1 harder to meet, never unsafe.

  submission_status == SUBMITTED, later CANDIDATE_REJECTED_BY_BROKER (the
  ASYNCHRONOUS C3.10B path: acknowledged, then rejected/cancelled/expired
  server-side) -> NON-QUALIFYING (RATIFIED, R9): the outcome retcode is DONE,
  so there is no rejection retcode to classify, and an async rejection of
  a market DEAL order is itself anomalous rather than clean evidence.

  Any other shape (no outcome record, status UNKNOWN/ERROR, a retcode not
  listed above) -> NON-QUALIFYING (fail-closed default, unchanged since
  Rev.3).

TRADE_RETCODE_CONNECTION / TRADE_RETCODE_TIMEOUT - REMOVED from the
qualifying bucket: unreachable, as they never produce CANDIDATE_REJECTED_
BY_BROKER (finding 4 above).
```

This answers QA's open question from Round 4 on `NO_MONEY`/`TIMEOUT`/
`CONNECTION`/`TOO_MANY_REQUESTS` with source evidence: two are
unreachable for P1 and are removed; two are reachable and are
non-qualifying. The whole mapping is RATIFIED (R9, Rev.14).

**P2 — 0 duplicate submission attempts in-window.** Reuses §6.2's own P1
verbatim: E2 via `SubmissionAttemptProjection`, dedup key
`execution_request_id`, identical-hash and conflicting-hash duplicates
both REJECT. E1 is NOT used: a gate-rejected SUBMIT followed by a later
successful SUBMIT for the same `execution_request_id` produces two E1
lines legitimately, and is not a duplicate submission.

**P3 — 0 uncorrelated broker facts in-window.** Reuses §6.2's own P2
verbatim — `BrokerFactCorrelation_VerifyWindow()` (sealed, covers every
`transaction_type`).

**P4 — 100% durable audit linkage for every in-window terminal candidate.**
Reuses §6.2's own P3 verbatim — `CandidateTerminalTransition_FindLineIndex()`
(sealed, tri-state 0/1/>1).

**P5 — restart/replay integrity.** Reuses §6.2's own P4a/P4b verbatim:
fresh `ReplayEngine_Run` + `BrokerReconciliation_CheckAll` both `.ok`,
`>= 1` `EVENT_TYPE_EA_SESSION_STARTED` in-window.

**P6 — Safe Mode clean.** Reuses §6.2's own P4c verbatim: no durable Safe
Mode engagement in-window (`SafeModeProjection_ReplayEngagedDuringWindow`,
"ever engaged") and no quarantine witness file present.

**P7 — kill switch never engaged in-window for `EXECUTION_ENV_DEMO`.** No
`EVENT_TYPE_KILL_SWITCH_ENGAGED` line for DEMO anywhere in-window, even if
later cleared. Reject reason: `kill_switch_engaged_in_window`.

**P8 — every in-window E2 is bound to a genuine, human, temporally-prior
approval for that exact `execution_request_id`.** For every in-window E2
line (raw scan of the evaluator's own snapshot, same style as §6.2's P1):

```
1. read the E2 line's own execution_request_id;
2. scan durable EVENT_TYPE_EXECUTION_MANUAL_APPROVAL_GRANTED lines (whole
   file - a grant may predate window_start) for one whose own
   execution_request_id EXACTLY equals it;
3. none found -> REJECT, unexpected_unapproved_submission_attempt;
4. found, but its approval_timestamp (an ABSOLUTE timestamp - see §2.3.3
   Rev.9) is not strictly before the E2 line's own event timestamp ->
   REJECT, approval_not_prior_to_attempt;
5. found, prior, but approver_identity == the reserved system string ->
   REJECT, unexpected_automated_approval_in_window (a system grant cannot
   exist inside a window anchored on the latest DEMO_REAL_SUBMIT entry,
   by §2.4's own stage-scoped rejection) - and the E2 does not count
   toward P1.
```

The binding key is `execution_request_id`, never "any approval of this
candidate or account." Unchanged in substance since Rev.2; the event
name is corrected and E2 is named explicitly.

**P8b — no automation-issued submission ceremony in-window (NEW, Rev.12;
RATIFIED R12, Rev.14).** For every in-window E1 line: if its provenance (PROV-1) is the
reserved system token -> REJECT, `unexpected_automated_submission_in_
window`. Rationale: Check B (§2.3.3) runs before E1 is written in
`SubmitOrderCommand()`, and rejects any system-issued SUBMIT outside
`DEMO_BOUNDED_AUTOMATION`; an in-window E1 with the reserved identity
means that check was bypassed. It is the E1 counterpart of P8 step 5,
catching an automated ceremony even when a C2 gate rejected it before any
E2 existed. [Rev.13: classification is INVARIANT PROV-1 (§3.2): an
in-window E1 classified AUTOMATION -> REJECT `unexpected_automated_
submission_in_window`; classified INVALID -> REJECT `e1_provenance_
invalid_in_window`; HUMAN or pre-cutoff -> passes P8b.]

### §1.3 Evidence snapshot consistency and integrity-fatal-halt (unchanged since Rev.1)

Immediately before the single `ALLOW` return: the `g_RolloutIntegrity
FatalHalt` check, then a fresh `EventStore_ReadAllLines()`, size-check
first, then byte-compare against the original snapshot — identical
mechanism to §6.1/§6.2.

### §1.4 Evidence boundary — [Rev.15 AMENDMENT — D4-c]

The only candidate source left in scope after D4 is the C5 candidate
pipeline, which is the "C5.0 TEST FIXTURE candidate pipeline" with stub AI
inference (`MLQuantAI.mq5:102-115`, `:1705-1718`). C5 pipeline candidates
are in §6.3 scope **for plumbing / control-plane verification only**.
`RUN_C22_CEREMONY_FIXTURE` requests are excluded (§2.3.1, D4). Binding
evidence boundary:

```
C5 stub candidate  =  proof of automation plumbing / control
                   ≠  proof of real-model AI quality
```

No evidence produced under §6.3 from C5 stub-AI candidates may be cited as
evidence of model quality, signal quality or market suitability.

---

## §2. The Automatic Submission Mechanism — "Bounded-Automation Decision Engine"

### §2.1 The one sentence that governs everything below (unchanged)

**The Bounded-Automation Decision Engine never calls `OrderSend`, never
calls any C2 gate function directly, and never introduces a new dispatch
path. It only ever durably issues the SAME two ceremony commands
(`GRANT_MANUAL_APPROVAL` then `SUBMIT_ORDER`) that a human operator's own
ceremony script already issues today, through the SAME `CeremonyCommand`
mailbox/dispatch mechanism, with a distinguishable, reserved
`approver_identity` string (§2.4).**

### §2.2 Pipeline (unchanged shape)

```
ExecutionRequestProjection (sealed) -> Candidate Discovery (§2.3.1) ->
Bounded-Automation Decision (§2.3.3) -> Automatic Submission Trigger ->
existing C2 gates, unchanged -> BrokerSubmission_Submit -> the ONE
sealed OrderSend() call site
```

### §2.3 The Decision Engine, Trigger, and idempotency protocol, precisely

#### §2.3.1 Candidate discovery (Rev.2 text unchanged; static admissibility added Rev.15)

The discovery source is unchanged from Rev.2: the sealed
`ExecutionRequestProjection_Count()`/`_GetAt()`, the whole registry, with
state re-derived from durable evidence every invocation and no in-memory
flag, cache or "already processed" marker.

**[Rev.15 AMENDMENT — D3, D4, D4-b] Static admissibility.** One pure
predicate over each request's immutable durable data:

```
ADMISSIBLE(X) iff ALL of:

 (a) DRY-RUN ACCEPTED - DryRunResultProjection holds at least one record
     for X.execution_request_id, and every such record has
     decision == SAFETY_GATE_ACCEPTED. Read through the sealed
     DryRunResultProjection_Count()/_GetAt() (no by-id accessor exists).
     No record (request written, dry-run write failed) -> not admissible.
 (b) LOT - X.lot_size <= max_lot_size_per_submission (R2 = 0.01).
 (c) SYMBOL - the observed_symbol of the record(s) in (a) is in
     symbol_allowlist (R8 = _Symbol). [precision note P-1]
 (d) STRATEGY - if strategy_allowlist is non-empty, the candidate's
     strategy_id (CandidateProjection_TryGet(X.candidate_id)) is in it;
     a failed lookup -> not admissible. R8 = "" admits every strategy_id
     (already gated upstream) and needs no lookup. [precision note P-2]
 (e) NOT FIXTURE (D4) - NOT ( M1(X) OR M2(X) ), where
       M1(X): X.execution_policy_version == "EXECPOLICY_C2_SMOKE_V1"
       M2(X): the validated snapshot holds a CEREMONY_COMMAND_STATE_CHANGED
              line with command_type == "RUN_C22_CEREMONY_FIXTURE" and
              execution_request_id == X.execution_request_id.

Not ADMISSIBLE -> skip (continue), never stop. Every input is immutable
durable data, so X's admissibility never changes and skipping it cannot
flap or change which admissible candidate is "first".
```

**[Rev.15 AMENDMENT — D4-b] Reserved policy value.**
`"EXECPOLICY_C2_SMOKE_V1"` is reserved for `RUN_C22_CEREMONY_FIXTURE`
(`MLQuantAI.mq5:991`). The C5 pipeline must not accept it as
`InpC5ExecutionPolicyVersion` (`MLQuantAI.mq5:115`), which removes M1's
only false-positive path. This is a contract requirement. The enforcing
mechanism (e.g. an `OnInit` input check) is an implementation item that
needs its own authorization; this amendment authorizes no source change.

#### §2.3.1a Deterministic candidate scan order — FROZEN Rev.6, per QA's Round 5 request; RATIFIED R16, Rev.14

Previously carried as an open, "not architecturally load-bearing" item
(§7 item 3, Rev.4/Rev.5). QA's Round 5 verdict asked this be frozen before
implementation specifically, since it is what determines WHICH candidate
gets the single mailbox slot when more than one is eligible in the same
invocation — this document now commits to it as a frozen rule, not merely
a proposal:

```
The Decision Engine's own candidate-discovery loop (§2.3.1) iterates
ExecutionRequestProjection's own registry in its NATIVE order - the same
order ExecutionRequestProjection_GetAt(0..Count()-1) already exposes it
in, which is insertion/append order (stable, deterministic by
construction, since the registry is itself an append-only projection
replayed from an append-only EventStore - never re-sorted, never
re-ordered, by any existing sealed code this document has read).

FROZEN RULE: the Decision Engine evaluates candidates via
ExecutionRequestProjection_GetAt(0), then GetAt(1), ... in that exact
index order, every invocation, with no re-ordering, filtering-then-
re-ordering, or priority scheme of any kind. The FIRST candidate (in this
fixed order) found eligible for an issuance (APPROVED_NOT_SUBMITTED or
NOT_YET_APPROVED, per §2.3.2's derivation) is the one acted on this
invocation, if the mailbox is free. This is not a placeholder for a
future priority/scoring scheme - this document does not propose one, and
none is authorized.
```

This is a genuinely simple, deterministic, already-available ordering -
no new sort, no new index, no new state - the registry's own existing
enumeration order, frozen as the tie-breaker for single-slot contention
rather than left unspecified.

**[Rev.15 AMENDMENT — D3, D4, D5, D6] R16 as amended.** The index order
is unchanged. What "eligible" means, and what each outcome does to the
scan, is now explicit:

```
For each index i = 0, 1, ... (native order, unchanged), in this order:
  1. record untrusted (empty execution_request_id)     -> STOP the scan,
                                                          issue nothing (D6)
  2. not ADMISSIBLE (§2.3.1, Rev.15)                   -> skip   (D3, D4)
  3. §2.3.2 state:
       SUBMISSION_ISSUED                               -> skip
       AUTOMATION_EXHAUSTED (step 1b, Rev.15)          -> skip   (D5)
       UNKNOWN (registry not ready, asOf untrusted)    -> STOP the scan,
                                                          issue nothing (D6)
       APPROVED_NOT_SUBMITTED / NOT_YET_APPROVED       -> SELECT, stop

The FIRST admissible, state-eligible candidate is the one acted on this
invocation. "Skip" never changes which later candidate is first, because
every skip reason is durable and monotonic. [precision note P-3 on the
order of steps 1-3]
```

#### §2.3.2 The real architecture, traced — closes Blockers 1 and 2 together

**Rev.3's error, disclosed plainly**: Rev.3 assumed `EventStore_
LogCeremonyCommandState(..., CEREMONY_STATE_COMMAND_RECEIVED, ...)` was
written at command-**append** time. Tracing the actual source
(`MLQuantAI_CeremonyCommandMailbox.mqh`'s own header comment, and
`MLQuantAI_CeremonyCommandEventEmission.mqh`'s `CeremonyCommand_TryClaim()`)
shows this is wrong: **that durable EventStore append happens as part of
CLAIMING** ("`CeremonyCommand_TryClaim()`... durably appends
`COMMAND_RECEIVED` to the EventStore FIRST and only writes `CLAIMED` to
[the mailbox] file if that durable append succeeded"). Between a command
being **written to the mailbox** (status `PENDING`) and being **claimed**,
there is genuinely no EventStore evidence at all — QA's Blocker 1 is
correct as stated.

**The fact that resolves this, and Blocker 2 together**: the ceremony
mailbox (`MLQuantAI_CeremonyCommand.json`) is explicitly documented as **"a
small, ephemeral, single-slot file"** — not a queue. At any moment, **at
most one ceremony command, from any source (human script or this
automation), can be `PENDING` or `CLAIMED` system-wide.** This is a
pre-existing, sealed, RA-31.2-frozen architectural constraint — this
document does not invent it, it discovers and relies on it.

**Two distinct uses of the mailbox, kept explicitly separate (the file's
own header warns against conflating them)**:

```
Historical truth ("did X definitely happen, ever, even across a crash?")
   -> EventStore ONLY, never the mailbox (the mailbox "may be lost,
      corrupted, or overwritten without any loss of history" - its own
      frozen documentation). Used for SUBMISSION_ISSUED/APPROVED_NOT_
      SUBMITTED/NOT_YET_APPROVED below, exactly as Rev.2/Rev.3 already
      established for those three states - UNCHANGED.

Live occupancy ("is the single slot free for ME to write into, right
now, this instant?")
   -> the mailbox file itself, read fresh, every invocation - the ONLY
      place this fact exists at all, by construction (there is no other
      representation of "a command is currently PENDING/CLAIMED" -
      EventStore does not get that evidence until claim time, which is
      exactly the gap Blocker 1 named). This is a transport-layer,
      point-in-time check, not a historical-truth claim - the distinction
      the mailbox's own header draws, respected here rather than
      violated.
```

**Revised state derivation, per `execution_request_id`, in this exact
order — Rev.6 fixes a genuine ordering bug QA's Round 5 review found**:
Rev.5's own version below checked "mailbox occupied by own SUBMIT else
MAILBOX_BUSY" (step 2) BEFORE ever reaching a dedicated own-GRANT check
(the old step 4) — meaning a mailbox occupied by this candidate's own
queued GRANT was already caught and classified `MAILBOX_BUSY` by step 2b
("any other occupancy"), so the old step 4's own condition ("mailbox
occupied by own GRANT") could never be true by the time execution reached
it: `APPROVAL_QUEUED` was dead, unreachable code, exactly as QA's Blocker
1 states. **Fixed by making the mailbox read a single three-way branch,
evaluated once, with own-SUBMIT/own-GRANT/anything-else as three sibling
cases of the SAME check — not own-SUBMIT-vs-everything-else followed by a
later, separate, now-unreachable own-GRANT special case:**

```
1. SUBMISSION_ISSUED : >= 1 EXECUTION_SUBMISSION_ATTEMPTED line exists in
   EventStore for this execution_request_id (unchanged since Rev.2/Rev.3 -
   durable, historical, permanent, keyed exactly as §6.2's own P1 dedup
   key already is). Checked FIRST, unconditionally, before any mailbox
   read - historical, permanent evidence always outranks a mailbox read.
   [Made precise Rev.11: this is event E2 - EVENT_TYPE_EXECUTION_
   SUBMISSION_ATTEMPTED, sole producer BrokerSubmission_RecordAttempt() -
   NOT the ceremony's own SUBMISSION_IN_PROGRESS line E1 (§2.3.2a, "E1/E2").
   Evaluated by a raw scan of the Decision Engine's own fresh EventStore
   read, never via SubmissionAttemptRegistry_HasAttempt() (rebuild-only,
   can lag in-session). That read follows the same discipline as Check A:
   ArraySize(lines) == 0 or EventStoreValidator_ValidateLines().ok ==
   false -> the Decision Engine issues nothing this invocation.]

2. Else, read the mailbox fresh ONCE (brief open -> read -> close, same
   pattern its own file already uses for every other reader), and branch
   three ways over that SAME single read - not two separate checks run
   at two separate points in the derivation:
   a. Mailbox is occupied (status PENDING or CLAIMED, i.e. NOT
      CeremonyMailboxStatus_IsTerminal()) AND its own command_type ==
      SUBMIT_ORDER AND target_execution_request_id == this
      execution_request_id
      -> SUBMISSION_ISSUED (the in-flight command IS this candidate's own
         SUBMIT, just not yet visible in EventStore - treated identically
         to case 1).
   b. Mailbox is occupied (PENDING/CLAIMED) AND its own command_type ==
      GRANT_MANUAL_APPROVAL AND target_execution_request_id == this
      execution_request_id - a SIBLING case of 2a, not a later fallback
      -> APPROVAL_QUEUED (mailbox-sourced - now genuinely reachable,
         Rev.6's fix).
   c. Mailbox is occupied (PENDING/CLAIMED) and neither 2a nor 2b applies
      (a different candidate's command, a human-issued command of any
      other type, or a command targeting a different execution_request_id
      entirely)
      -> MAILBOX_BUSY (the single slot is held by something else. This
         candidate cannot be acted on THIS invocation, full stop,
         regardless of what its own EventStore-derived state would
         otherwise be.)
   d. Mailbox is free (empty, or terminal status only) -> proceed to
      step 3. This is now the ONLY way to reach step 3/4 below - the
      registry-based checks are never consulted while the mailbox is
      occupied by anything, own or otherwise, since 2a/2b/2c already
      fully classify every occupied case.

3. APPROVED_NOT_SUBMITTED : (only reached via step 2d, mailbox confirmed
   free) a valid, unexpired ManualApprovalGrant exists right now
   (ManualApprovalRegistry_HasValidApproval(), sealed, fresh asOf) -
   unchanged since Rev.2.

4. Else : NOT_YET_APPROVED (only reached via step 2d) - unchanged since
   Rev.2/Rev.3, including the "a prior GRANT command durably FAILED" case
   falling through here.
```

**[Rev.15 AMENDMENT — D5 (A2)] Step 1b, evaluated immediately after
step 1 and before step 2:**

```
1b. AUTOMATION_EXHAUSTED : not SUBMISSION_ISSUED, AND the same validated
    snapshot holds >= 1 E1 line for this execution_request_id that
    INVARIANT PROV-1 classifies AUTOMATION.
    -> do nothing for this candidate, permanently: automation gets ONE
       SUBMIT ceremony per execution_request_id. A human may still act on
       it through the normal manual ceremony.
    - A pre-cutoff E1 (PROV-1 Case A) is not AUTOMATION and does not
      exhaust.
    - An E1 PROV-1 classifies INVALID fails closed exactly as R15 already
      requires: automatic issuance halts until human reconciliation.
    - Durable, clock-free, no new event and no new field: E1 is already
      the ratified automation-issuance event (R10).
```

Frozen transition rule, amended: `AUTOMATION_EXHAUSTED` joins
`SUBMISSION_ISSUED` / `MAILBOX_BUSY` / `APPROVAL_QUEUED` as "do nothing
for this candidate". Within the discovery scan it is a skip (§2.3.1a as
amended).

**Frozen transition rule**:

```
SUBMISSION_ISSUED / MAILBOX_BUSY / APPROVAL_QUEUED
                        -> do nothing this invocation, for this candidate.
                           All three are now genuinely reachable states
                           (Rev.6 fixes APPROVAL_QUEUED specifically -
                           Rev.5's own version made it dead code, per
                           QA's Round 5 Blocker 1).
                           MAILBOX_BUSY additionally means: do not attempt
                           ANY OTHER candidate this invocation either - the
                           single slot is occupied, full stop - a DIRECT,
                           unavoidable consequence of the mailbox's own
                           single-slot architecture. The Decision Engine's
                           own loop over the whole ExecutionRequestProjection
                           registry (§2.3.1) checks mailbox occupancy ONCE,
                           at the start of the invocation, before evaluating
                           any individual candidate - if occupied, the
                           entire invocation is a no-op; if free, at most
                           ONE candidate (the first one found eligible, in
                           registry scan order - deterministic and FROZEN
                           this revision, §2.3.1a) may have a command
                           issued for it, which IMMEDIATELY occupies the
                           slot again for every subsequent candidate in the
                           SAME pass.

APPROVED_NOT_SUBMITTED  -> issue SUBMIT_ORDER (only reached via step 2d -
                           mailbox confirmed free at the top of this
                           invocation). This document's own SUBMIT_ORDER
                           issuance ALSO sets cmd.approver_identity =
                           MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY on
                           the command itself - see §2.3.3 Check B.

NOT_YET_APPROVED        -> issue GRANT_MANUAL_APPROVAL (only reached via
                           step 2d - mailbox confirmed free), with
                           approver_identity set to the same reserved
                           string, unchanged since Rev.3.
```

**Re-verified crash/interruption scenarios**:

```
GRANT written to mailbox (PENDING), not yet claimed, new invocation runs
  -> mailbox read: occupied, GRANT, this execution_request_id
  -> APPROVAL_QUEUED -> no re-issue. (Closes Blocker 1, GRANT half.)

SUBMIT written to mailbox (PENDING), not yet claimed, new invocation runs
  -> mailbox read: occupied, SUBMIT_ORDER, this execution_request_id
  -> SUBMISSION_ISSUED -> no re-issue. (Closes Blocker 1, SUBMIT half.)

Mailbox occupied by a DIFFERENT candidate's command (or a human-issued
command of any type) when the Decision Engine runs
  -> MAILBOX_BUSY for every candidate this invocation -> nothing issued
     for anyone. (Closes Blocker 2 - structurally, not by convention.)

Command reaches a TERMINAL mailbox status (COMPLETE/REJECTED/FAILED) but
the corresponding EventStore outcome line has not yet been separately
confirmed by THIS invocation's own read
  -> irrelevant to correctness: step 1/step 3's own EventStore-sourced
     checks are the ONLY ones that ever produce a PERMANENT state
     (SUBMISSION_ISSUED/APPROVED_NOT_SUBMITTED); a terminal mailbox status
     alone (2c: "terminal status only") is treated as FREE, exactly as
     RA-31.2's own protocol intends ("the Script may now read the result
     fields, and is then free to overwrite with a new command") - the
     Decision Engine plays the same "Script" role here.
```

**Defense in depth, unchanged**: `CeremonyCommandRegistry_
HasUnresolvedSubmission()`'s own existing global guard remains an
independent second layer specific to `SUBMIT_ORDER`, on top of the
mailbox-occupancy check above (which is more general — it covers GRANT
occupancy too, and any other command type).

#### §2.3.2a Issuance write protocol — closes Blocker 1 (the check-then-act window between "read mailbox = free" and "write to mailbox")

Traced against the actual sealed I/O (`MLQuantAI_CeremonyCommandMailbox.mqh`,
confirmed by direct read this revision):

```
CeremonyCommandMailbox_IsFreeForNewCommand()  -- the EXISTING, sealed,
   RA-31.2-frozen occupancy guard (reads the mailbox, true iff no command
   has ever existed or the last one reached a terminal status). The
   Decision Engine calls THIS function for its own "is the slot free"
   check in §2.3.2 step 2 - it does not reimplement occupancy logic.

CeremonyCommandMailbox_Write(cmd)  -- returns false ONLY on a FileOpen/
   FileWrite I/O failure ("try again next poll" per the file's own header
   doctrine - never a fatal/durable failure). It performs no compare-
   and-swap: a successful return means THIS write reached the file, not
   that no OTHER write raced in immediately before or after it.
```

**Two distinct races, kept explicitly separate**:

```
1. INTERNAL race (another code path in THIS SAME EA process writes the
   mailbox between the Decision Engine's own occupancy read and its own
   write)
   -> CANNOT HAPPEN, by construction. MQL5 EA execution is single-
      threaded and non-preemptive (the same invariant §6.2's own frozen
      text already relies on, cited again here) - no other function in
      this EA can execute, let alone write the mailbox, while the
      Decision Engine's own occupancy-check-then-write sequence is
      running. RA-31.2's own single-writer-per-process design is the
      authority that closes this half of Blocker 1 - not something this
      document invents, something it correctly relies on.

2. EXTERNAL race (a human operator's ceremony script - a SEPARATE OS
   process - writes the same MLQUANTAI_CEREMONY_MAILBOX_FILENAME
   between the Decision Engine's read and its write). This is genuinely
   possible: FILE_COMMON places the mailbox in the shared Common\Files
   folder, and MQL5's own FileOpen handle-level exclusivity does not
   bind a non-MQL5 process. This half of Blocker 1 is real and is closed
   by an explicit write-time confirmation protocol, not assumed away:
```

```cpp
// Decision Engine's own issuance step (GRANT or SUBMIT), replacing a
// bare "write and assume success":
if(!CeremonyCommandMailbox_IsFreeForNewCommand())
   return; // MAILBOX_BUSY per §2.3.2 step 2b - nothing issued.

CeremonyCommand cmd;
CeremonyCommand_Init(cmd);
cmd.command_id = <fresh unique id>;
// ... populate command_type / target_execution_request_id / etc,
// including approver_identity for BOTH command types - see Blocker 2 fix
// below, §2.3.3.

if(!CeremonyCommandMailbox_Write(cmd))
   return; // I/O failure - "try again next poll", per the file's own
           // doctrine. No partial state: nothing was durably committed,
           // next invocation's own IsFreeForNewCommand() check starts
           // clean.

// Read-your-own-write: the ONLY way to confirm the write this document's
// own automation just performed was not immediately overwritten by a
// concurrent external writer, since CeremonyCommandMailbox_Write() itself
// provides no compare-and-swap.
CeremonyCommand confirmCmd;
if(!CeremonyCommandMailbox_Read(confirmCmd) || confirmCmd.command_id != cmd.command_id)
{
   // Someone else's write is now occupying the slot (or the mailbox
   // became unreadable a moment later) - this invocation's own issuance
   // is UNCONFIRMED. Take no further action, make no assumption of
   // success, do not retry within this invocation.
   return;
}
// confirmCmd.command_id == cmd.command_id: this invocation's own write
// is confirmed to be what currently occupies the slot. Nothing further
// to do this invocation - claiming happens on the existing, unchanged
// RA-31.2.1 OnTimer cadence.
```

**Round 5 Blocker 2 — QA correctly noted this protocol DETECTS but does
not PREVENT an external overwrite, and asked this document to freeze one
of: (A) a cooperative single-writer protocol binding all writers, (B) an
atomic/exclusive write mechanism, or (C) an explicitly accepted residual
race with frozen liveness semantics. This document freezes (A) + (C)
together — not (B), since an atomic-write mechanism would require
modifying `CeremonyCommandMailbox_Write()` itself, a THIRD sealed-file
amendment beyond this document's own committed scope of exactly two
(`GrantManualApprovalCommand`, `SubmitOrderCommand`) — and grounds both in
evidence already read from the sealed source, not invented rules:**

```
(A) GOVERNING AUTHORITY, already existing, not invented here:
    CeremonyCommandMailbox_IsFreeForNewCommand()'s own header comment
    (confirmed by direct read, MLQuantAI_CeremonyCommandMailbox.mqh) -
    "RA-31.2 condition A's own core guard: the Script MUST call this
    before ever writing a new command." This is a PRE-EXISTING,
    RA-31.2-frozen cooperative protocol that ALREADY binds the human
    ceremony script today - §6.3 does not invent a new rule, it adds a
    SECOND compliant writer (the Decision Engine) to an already-
    cooperative multi-writer system. §2.3.2a's own protocol (occupancy
    check -> write -> read-your-own-write confirm) is this document's
    OWN compliance with that pre-existing authority, not a substitute
    for it.

(C) RESIDUAL RACE, frozen liveness semantics for when (A) is respected by
    both writers but the check-then-write window still overlaps (IsFree()
    -> Write() is not atomic even under a cooperative protocol):
    - The mailbox file itself is the sole arbiter: FileOpen(FILE_WRITE)
      overwrites/truncates, so exactly one of two racing writes survives
      - "last write wins" at the OS file level, not a policy choice this
        document makes.
    - Each writer INDEPENDENTLY discovers its own outcome via §2.3.2a's
      own read-your-own-write confirmation - there is no shared
      "referee," each writer's own confirmation read is authoritative
      for ITSELF only.
    - FROZEN LIVENESS RULE: the writer whose own write did NOT survive
      (confirmation mismatch) treats its own issuance as LOST -
      permanently, for this invocation. No in-invocation retry. For the
      Decision Engine specifically: a lost issuance means this invocation
      issued nothing for this candidate; §2.3.2's own state derivation is
      RE-EVALUATED FRESH, from scratch, on the NEXT invocation, with no
      memory of "attempted and lost" carried forward. This is what
      supplies the liveness QA asked for: retry is IMPLICIT via the next
      invocation's own fresh state derivation, not an explicit retry
      counter or backoff this document needs to design. If the winning
      write belongs to a human operator, the Decision Engine's next
      invocation observes that occupancy via §2.3.2's own mailbox read
      (APPROVAL_QUEUED/SUBMISSION_ISSUED/MAILBOX_BUSY as appropriate) and
      behaves correctly - at most a one-invocation delay, never a
      correctness gap.
    - AUTHORITY FOR "NO GAP": RA-31.2's own frozen documentation already
      states the mailbox "may be lost, corrupted, or overwritten without
      any loss of history" - this is PRECISELY the scenario that sentence
      exists to describe. No durable record is ever lost, because nothing
      is durably recorded before CLAIM time (CeremonyCommand_TryClaim()'s
      own append) regardless of which write physically wins - this
      document relies on that existing guarantee rather than building a
      new one.
```

**Worst case under a genuine simultaneous race**: at most ONE duplicate
command is issued by BOTH parties for the same intent (the case where
BOTH writes happen to target the SAME `execution_request_id` with the SAME
command type - the more common case is two DIFFERENT commands racing, in
which case one is simply lost per the liveness rule above, no duplicate at
all). A genuine duplicate is bounded and already handled by EXISTING,
unchanged mechanisms, not by anything new this document adds: a duplicate
`GRANT_MANUAL_APPROVAL` simply produces a second valid grant for the same
`execution_request_id`, which `ManualApprovalRegistry_HasValidApproval()`'s
own has-any-valid-grant semantics already tolerate without any safety
consequence.

**Rev.8, closing Round 7 Blocker 2 — proving duplicate-SUBMIT safety with
real evidence, not asserting it**: QA correctly pushed back that
`CeremonyCommandRegistry_HasUnresolvedSubmission()` only guards an
UNRESOLVED (still in-flight) duplicate — it says nothing about a "lost"
duplicate that only surfaces AFTER the winning submission has already gone
terminal (completed, durably recorded). Traced this revision:
`BrokerSubmission_Submit()`'s own sealed structural precondition
(confirmed by direct read, `MLQuantAI_BrokerSubmissionAdapter.
mqh:405-408`) is the answer -

```cpp
// Only a CREATED candidate may legally reach SUBMITTED - a structural
// precondition, not itself part of the frozen retcode/event lifecycle.
if(candidate.candidate_id != request.candidate_id || candidate.state != CANDIDATE_CREATED)
   return false;
```

- this is checked BEFORE any gate, any event, any OrderSend, on EVERY call
to `BrokerSubmission_Submit()`, for ANY caller, human or automated.

**Rev.9, closing Round 8 Blocker 1 — the exact timing this precondition
relies on, traced source-to-source, not merely asserted**: QA's Round 8
review correctly pointed out that citing the precondition alone does not
prove WHEN `candidate.state` actually leaves `CANDIDATE_CREATED` relative
to a duplicate's own reachability. Traced this revision:

```
1. candidate.state transitions to CANDIDATE_SUBMITTED via EXACTLY ONE
   statement in the entire codebase: EventStore_LogTransition(candidate,
   CANDIDATE_SUBMITTED, REASON_SUBMITTED_OK, "") at MLQuantAI_
   BrokerSubmissionAdapter.mqh:296, inside BrokerSubmission_
   ProcessSendResult() - confirmed by direct read, and confirmed to be
   called ONLY on the classified-success path, AFTER OrderSend() itself
   (MLQuantAI_BrokerSubmissionAdapter.mqh:468) has already returned. On
   the orderSendReturned==false path, the function's own comment is
   explicit: "candidate.state stays CANDIDATE_CREATED - untouched...
   retry-ability is preserved" (line 262-264). [CORRECTED Rev.11: Rev.9
   said "a second attempt is INTENTIONALLY permitted in that case." That
   is true of the candidate.state precondition only. SA-1 (below) still
   blocks any resubmission of the SAME execution_request_id after
   OrderSend()==false, because BrokerSubmission_RecordAttempt() already
   ran before OrderSend(). The "retry-ability" the sealed comment refers
   to is a retry under a NEW execution_request_id - "only a brand-new
   execution_request_id, never a reused one, may ever pass this check"
   (MLQuantAI_BrokerSubmissionGate.mqh:175-177) - which this document
   neither creates nor authorizes.]

2. This entire sequence - precondition check, every gate, RecordAttempt,
   OrderSend, ProcessSendResult, and (on success) the candidate.state
   mutation itself - executes inside ONE synchronous call to
   SubmitOrderCommand(), which is itself dispatched synchronously from
   RA31_ProcessCeremonyCommand() (confirmed, MLQuantAI.mq5:1464-1487):
   CeremonyCommand_TryClaim() and the command-type switch that calls
   SubmitOrderCommand(cmd) happen in the SAME function, with nothing else
   able to run in between - claim and dispatch are not split across two
   separate steps that could straddle a tick boundary.

3. RA31_ProcessCeremonyCommand() is called from BOTH OnTick() and
   OnTimer() (MLQuantAI.mq5:1507, :1560), and the codebase's own existing,
   already-QA-frozen comment at the OnTimer() definition (MLQuantAI.
   mq5:1501-1502) states this exactly: "MQL5 itself never runs OnTick()/
   OnTimer() concurrently on the same program (single-threaded event
   dispatch) - so there is not even a race to guard against." This
   document did not need to establish this invariant - it was already
   established and QA-approved for a different purpose (RA-32.1), and
   applies identically here.

CONCLUSION: a second SubmitOrderCommand() call for the same candidate -
whether from a "lost" write resurfacing later, or an independent human
resubmission - cannot begin executing, let alone reach BrokerSubmission_
Submit()'s own precondition check, until the FIRST call has run to
complete, uninterrupted completion, INCLUDING its own candidate.state
mutation if the first attempt succeeded. There is no interleaving window
in which the second call could observe an intermediate state, because
nothing can execute "in between" a single synchronous call on a
single-threaded event dispatcher. The precondition the second call
observes is always the FINAL state left by the first call, never a
partial one.
```

A later duplicate (B) - whether it is the "lost" write resurfacing, or an
entirely independent human resubmission attempt - reaches this SAME
precondition on its own `SubmitOrderCommand()` invocation and is rejected
IMMEDIATELY: no OrderSend, no event, no state change, before `B` ever
reaches the retcode surface. This is QA's own option (B) - "a durable
per-candidate terminal-submission idempotency check that prevents a
duplicate even after the prior submission is complete" - already present,
sealed, and unconditional; this document did not need to add it, only to
trace and cite it, which Rev.7 had not yet done.

**Rev.10, closing Round 9 Blocker 1 — the ONE case where `candidate.state`
alone genuinely does NOT protect, and what actually does**: QA's Round 9
review correctly identified a gap the timing proof above does not cover:
`OrderSend()` succeeds, but the LATER durable write that would advance
`candidate.state` to `CANDIDATE_SUBMITTED` itself FAILS. Traced this
revision, `EventStore_LogTransition()` (confirmed, `MLQuantAI_
EventStore.mqh:192-227`) makes this scenario's own consequence explicit:

```
if(!EventStore_AppendLifecycle(e))
{
   SafeMode_Trip(StringFormat("failed to durably write lifecycle event for %s (%s -> %s) - "
                               "in-memory state left at %s, NOT advanced to %s", ...));
   return false;
}
// Only now, with the event durably on disk, commit the in-memory change.
c.state = to;
```

So in this exact scenario: `candidate.state` REMAINS `CANDIDATE_CREATED`
(confirmed, the function's own comment: "in-memory state left at...NOT
advanced"), even though a REAL broker order was already placed. QA is
right that the `candidate.state != CANDIDATE_CREATED` precondition, taken
alone, would NOT reject a later duplicate attempt in this specific case -
the guard this document leaned on for Round 8 Blocker 2 has exactly one
blind spot, and this is it.

**What actually closes it - a SEPARATE, already-sealed, already-frozen
guard this document had not yet traced**: `BrokerSubmissionGate_
Evaluate()` (confirmed, `MLQuantAI_BrokerSubmissionGate.mqh:113-188`,
called via `BrokerSubmissionEnvironmentLock_Evaluate` - the FIRST real
gate `BrokerSubmission_Submit()` calls, immediately after the `candidate.
state` precondition) checks `SubmissionAttemptRegistry_HasAttempt()`
(line 180-185) - durable, EventStore-backed, built from `EXECUTION_
SUBMISSION_ATTEMPTED` lines, independent of `candidate.state` entirely.
Its own frozen comment states the exact property needed: "A RESOLVED
prior attempt (SUBMITTED/REJECTED/ERROR/UNKNOWN) still blocks automatic
resubmission here...only a brand-new execution_request_id, never a
reused one, may ever pass this check." Critically, `EXECUTION_SUBMISSION_
ATTEMPTED` is durably logged by `BrokerSubmission_RecordAttempt()` -
confirmed, `MLQuantAI_BrokerSubmissionAdapter.mqh:148-158` - BEFORE
`OrderSend()` is ever called (the pre-existing, frozen C2.1 "durable
pre-commit marker BEFORE OrderSend" rule). So by the exact moment the
scenario QA names could even begin (`OrderSend()` about to run), this
durable line ALREADY exists - meaning `BrokerSubmissionGate_Evaluate()`'s
own `SubmissionAttemptRegistry_HasAttempt()` check will ALREADY reject
any later duplicate attempt for this SAME `execution_request_id`, for
ANY caller, human or automated, REGARDLESS of what happened to `candidate.
state` afterward. [CORRECTED Rev.11: the conclusion stands, but the
attribution was imprecise for the same-session case. `SubmissionAttempt
Registry_HasAttempt()` reads `g_SubAttemptProj_Records[]`, which is
populated only by a rebuild from file - `BrokerSubmission_RecordAttempt()`
does NOT update it in-session. What rejects a same-session duplicate is
the IN-SESSION check `BrokerSubmissionGate_HasAlreadyAttempted()` (line
151), which `RecordAttempt()` sets immediately after the durable write
and before `OrderSend()`. See INVARIANT SA-1 below for the exact,
combined guard.]

**Answering QA's own explicit checklist directly**:

```
SafeMode?           -> Tripped (confirmed, EventStore_LogTransition's own
                        SafeMode_Trip() call), but SafeMode does NOT itself
                        gate RA31_ProcessCeremonyCommand()'s own claim/
                        dispatch loop (confirmed: the only SafeMode_
                        IsActive() call site in MLQuantAI.mq5 is inside
                        the C5.0/C5.2 NEW-CANDIDATE EligibilityContext
                        construction, MLQuantAI.mq5:1755 - a different
                        gate for a different purpose, not what closes
                        this scenario).

candidate in-memory
state?               -> Stays CANDIDATE_CREATED (confirmed above) - does
                        NOT, by itself, prevent a later duplicate. QA's
                        own concern here is correct and this document no
                        longer relies on this guard alone.

later automation
invocation?          -> Also safe, independently: §2.3.2's own state
                        derivation step 1 (">= 1 EXECUTION_SUBMISSION_
                        ATTEMPTED line exists") already sees the SAME
                        durable line and classifies this candidate
                        SUBMISSION_ISSUED, refusing to re-issue - but this
                        is defense-in-depth, not the primary guard.

later manual SUBMIT? -> Closed by the SAME BrokerSubmissionGate_Evaluate()
                        check below - applies uniformly to every caller.

BrokerSubmission
guard?               -> THE ANSWER: BrokerSubmissionGate_Evaluate()'s own
                        idempotency checks - precisely, per INVARIANT SA-1
                        below (Rev.11): the in-session
                        BrokerSubmissionGate_HasAlreadyAttempted() for the
                        current session, and SubmissionAttemptRegistry_
                        HasAttempt() (with its _IsUnresolved() sub-case)
                        for every earlier session.
```

The claim "no correctness gap" is now evidenced by the CORRECT mechanism,
not the one this document had previously (incompletely) cited.

#### INVARIANT SA-1 — submission-attempt idempotency, exact identity semantics (FROZEN, Rev.11, closing Round 10 Blocker 1)

QA's Round 10 review asked for the guard's exact semantics to be written
as a contract invariant — which key it uses, that it is not merely an
account-wide or global "unresolved" check, and that every outcome still
blocks. Each clause below is traced to sealed source this revision.

```
SA-1. For any ExecutionRequest R that reaches BrokerSubmission_Submit()
(sole production caller: SubmitOrderCommand(), MLQuantAI.mq5:1323),
BrokerSubmissionGate_Evaluate() - reached as the first gate inside
BrokerSubmission_Submit(), via BrokerSubmissionEnvironmentLock_Evaluate()
- REJECTS R with REASON_DUPLICATE_EVENT, BEFORE BrokerSubmission_
RecordAttempt() and BEFORE OrderSend(), whenever R.execution_request_id
has ANY prior EXECUTION_SUBMISSION_ATTEMPTED record, through:

  KEY: exact string equality on execution_request_id. Not candidate_id,
       not account, not "any unresolved submission anywhere" - that last
       one is a DIFFERENT, separate guard (CeremonyCommandRegistry_
       HasUnresolvedSubmission(), RA-31.2 condition B, at the top of
       SubmitOrderCommand()), which SA-1 does not rely on.

  (0) READINESS PRECONDITION (MLQuantAI_BrokerSubmissionGate.mqh:144-149):
      if BrokerSubmissionAuditReadiness_IsReady() is false, EVERY request
      is rejected (REASON_EXECUTION_AUDIT_NOT_READY) - so (c) is never
      consulted over a registry that has not successfully rebuilt this
      session.

  (a) IN-SESSION (line 151): BrokerSubmissionGate_HasAlreadyAttempted(ERID).
      Set by BrokerSubmissionGate_MarkAttempted(ERID), called only inside
      BrokerSubmission_RecordAttempt() (MLQuantAI_BrokerSubmissionAdapter.
      mqh:156), immediately after the durable EXECUTION_SUBMISSION_ATTEMPTED
      write succeeds and before OrderSend(). Never cleared by any rebuild.
      COVERS: every attempt made in the current EA session.

  (b) DURABLE, UNRESOLVED (line 163): SubmissionAttemptRegistry_
      IsUnresolved(ERID). A sub-case of (c) (it requires HasAttempt),
      kept explicit per RA-16.1 - adds no coverage (c) lacks.

  (c) DURABLE, ANY OUTCOME (line 180): SubmissionAttemptRegistry_
      HasAttempt(ERID). Body (MLQuantAI_BrokerSubmissionAuditProjection.
      mqh:505-511) compares execution_request_id ONLY - no outcome filter
      exists. Populated from every EXECUTION_SUBMISSION_ATTEMPTED line by
      BrokerSubmissionAuditProjection_RebuildFromFile(), run at OnInit via
      BrokerSubmissionAudit_StartupRebuild() (MLQuantAI.mq5:488).
      COVERS: every attempt made in any earlier session.

  OUTCOME COVERAGE: neither (a) nor (c) consults outcome. An attempt with
  no outcome yet, or with outcome SUBMITTED, REJECTED, ERROR (including
  OrderSend()==false), or UNKNOWN, blocks resubmission of the SAME
  execution_request_id equally. The sealed comment names this exactly: "A
  RESOLVED prior attempt (SUBMITTED/REJECTED/ERROR/UNKNOWN) still blocks
  automatic resubmission here... only a brand-new execution_request_id,
  never a reused one, may ever pass this check" (MLQuantAI_Broker
  SubmissionGate.mqh:173-177).

  NOT AN ATTEMPT: a rejection by any gate that runs BEFORE RecordAttempt()
  (EnvironmentLock checks, EntryCompatibilityGate, margin guard, trade-
  request construction) records nothing and marks nothing - "a gate
  rejection must never mark an id as attempted, since nothing was
  attempted" (MLQuantAI_BrokerSubmissionGate.mqh:90-92). The same
  execution_request_id may be submitted again later. This is correct
  (nothing reached the broker) and, for automation, is rate-limited by
  §3.2's own cap accounting, which counts the ceremony line E1 that is
  written BEFORE these gates run (see "E1/E2" below).
  [Rev.15 AMENDMENT — D5: for automation, that E1 also makes the request
  AUTOMATION_EXHAUSTED (§2.3.2 step 1b), so no automated re-submission
  follows at all. The cap accounting remains a second, independent
  bound. SA-1 itself is unchanged.]
```

**Mid-session rebuild, analyzed and disclosed — no change proposed**:
§6.2's own evaluator calls the raw `BrokerSubmissionAuditProjection_
RebuildFromFile()` directly (`MLQuantAI_RolloutGateReadinessEvaluate.
mqh:374`), not the readiness-managing startup wrapper. Traced: the
function either returns BEFORE its reset when the C1.3 prerequisite
rebuild fails ("rebuild refused, registry left unchanged", `MLQuantAI_
BrokerSubmissionAuditProjection.mqh:567-572`), or resets and then
re-applies every attempt line of the append-only file in file order,
continuing past any failing line (lines 574-628). Given readiness is true
(the startup rebuild applied every line cleanly), the re-applied prefix
reproduces every prior record, and lines appended since only add. So a
mid-session rebuild can leave (c)'s blocked set unchanged or larger,
never smaller - and (a) is not touched by any rebuild regardless. §6.2 is
CLOSED/VERIFIED; this document proposes no change to it.

**Machine-checked evidence already in the repository (existing,
QA-accepted tests)**:

```
(a) exact key, in-session:
    Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5:348-353
      "the same id now reports already-attempted" / "a different id is
      unaffected"
    Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5:640-650
      "idempotency guard marked only after the durable write succeeded"

(c) durable, cross-session:
    Tests/MLQuantAI_Test_C2_BrokerSubmissionGate_DurableIdempotency.mq5
      :297  prior attempt recovered by an actual simulated restart blocks
            the gate, even with a FRESH in-session guard
      :341  unresolved durable attempt caught by IsUnresolved()
      :378  RESOLVED (SUBMITTED) attempt still blocks - "HasAttempt is
            consulted, not IsUnresolved"
      :414  no false positive - a DIFFERENT request's attempt does not
            block this one (exact per-execution_request_id key)
(0) readiness:
      :456  before any rebuild, even a brand-new request is rejected
      :496  corrupted store -> readiness false -> every request rejected
      :548  a later failed rebuild REVOKES readiness
```

Not yet covered by a dedicated test (named here for the future Test
Authorization phase, not authorized now): REJECTED- and ERROR-outcome
variants of `:378`. They exercise the same code path (`HasAttempt()` has
no outcome branch), so this is a coverage gap, not a behavioral one.

**E1/E2 — a naming imprecision in this document, disclosed and resolved**:
while tracing SA-1, it became clear this document has used
"EXECUTION_SUBMISSION_ATTEMPTED" loosely, since Rev.2, for two DIFFERENT
durable events:

```
E1 = EVENT_TYPE_CEREMONY_COMMAND_STATE_CHANGED with to_state =
     SUBMISSION_IN_PROGRESS. Sole producer: SubmitOrderCommand()
     (MLQuantAI.mq5:1312-1314), written after SubmitOrderCommand()'s own
     checks and BEFORE BrokerSubmission_Submit() - so it exists even when
     a C2 gate later rejects. Carries command_id, command_type,
     execution_request_id; carries provenance ONLY via this document's
     own amendment (extraJson key "submission_provenance", two fixed
     tokens - INVARIANT PROV-1, Rev.13). Watched by RA-31.2
     condition B.

E2 = EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED. Sole producer: the sealed
     BrokerSubmission_RecordAttempt() (MLQuantAI_BrokerSubmissionAdapter.
     mqh:152), written only after EVERY C2 gate passes, BEFORE OrderSend().
     Carries execution_request_id, hash, correlation_id, submit_attempt -
     NO approver_identity. The source of SA-1 (c) and of §6.2's P1.

For automation-issued submissions, every E2 is preceded by its own E1 in
the same synchronous SubmitOrderCommand() call - BrokerSubmission_Submit()
has exactly one production caller, which writes E1 first (MLQuantAI.
mq5:1312-1323).
```

Each use in this document is now pinned to exactly one of them:

```
§2.3.2 step 1 (SUBMISSION_ISSUED)  -> E2. Unchanged in meaning - "keyed
   exactly as §6.2's own P1 dedup key" already meant E2. Made precise:
   evaluated by a raw scan of the Decision Engine's own fresh read for
   type == "EXECUTION_SUBMISSION_ATTEMPTED" AND execution_request_id ==
   this one - NOT via SubmissionAttemptRegistry_HasAttempt(), whose
   registry is rebuild-only and can lag in-session (the same distinction
   SA-1 draws between (a) and (c)).

§3.2 cap accounting                 -> E1, classified by INVARIANT
   PROV-1 (§3.2): the fixed "submission_provenance" token, not
   approver_identity. [Rev.14 correction: until Rev.13 this line still
   said "filtered by E1's own approver_identity"; that wording was
   superseded by PROV-1 in Rev.13 and is corrected here, no design
   change.] E1 as the source is RATIFIED (R10, Rev.14). It was
   disclosed as a proposal, not a silent substitution: QA's Round 8 verdict named
   EXECUTION_SUBMISSION_ATTEMPTED (E2) as the canonical cap source, but
   provenance can live only on E1 within this document's two-sealed-
   function scope.
```

**Single-EA-instance assumption, stated explicitly**: this protocol, like
every other RA-31.2 assumption this document relies on, assumes exactly
one running instance of this EA process against a given `EventStoreFile`/
mailbox pair - the same assumption the whole single-writer EventStore
architecture already makes elsewhere in this codebase, not a new
assumption introduced here.

#### §2.3.2b LOST issuance — deterministic accounting semantics, closing Round 6 Blocker 1

QA's Round 6 review accepted the LOST/retry-next-invocation mechanism for
correctness, but required this document to freeze how a LOST issuance is
accounted for against §3's caps (`max_submissions_per_day`,
`max_daily_volume_lots`, `min_seconds_between_submissions`), rather than
leaving that to a future implementer's own judgment. QA named four
candidate labels — `ISSUED? NOT ISSUED? LOST? RETRY-ELIGIBLE?` — this
section freezes exactly which apply and what each means for accounting.

**The four-state taxonomy, frozen**:

```
WRITE_FAILED : CeremonyCommandMailbox_Write() itself returned false (an
   I/O failure - the write never reached the file at all).

LOST (= WRITE UNCONFIRMED) : CeremonyCommandMailbox_Write() returned
   true, but the read-your-own-write confirmation (§2.3.2a) found a
   different command_id (or found the mailbox unreadable) - this
   invocation's own command is NOT confirmed to be the current occupant
   of the slot. This covers BOTH "a racing external write overwrote it a
   moment later" and "the confirmation read itself transiently failed
   while the write actually survived" - Rev.6/Rev.7 do not attempt to
   distinguish these two sub-cases, because the accounting answer below
   is identical either way (see "why this needs no sub-case split").

ISSUED (CONFIRMED) : write succeeded AND the confirmation read matches -
   this command IS, at this instant, the confirmed occupant of the
   mailbox slot. This is NOT yet "submitted" or "granted" - it is
   PENDING, awaiting the existing, unchanged RA-31.2.1 OnTimer claim
   cycle.

RETRY-ELIGIBLE : not a fourth state - it is the NATURAL CONSEQUENCE of
   WRITE_FAILED or LOST, not a separate status this document tracks. Since
   neither WRITE_FAILED nor LOST ever produces a durable EventStore
   record (nothing was ever claimed), §2.3.2's own state derivation simply
   re-derives the SAME state (NOT_YET_APPROVED or APPROVED_NOT_SUBMITTED)
   from scratch on the next invocation, with no memory of the prior
   attempt - "retry eligibility" is not a flag this document sets, it is
   what re-evaluating fresh state from durable evidence ALWAYS does when
   no new durable evidence was produced.
```

**FROZEN ACCOUNTING RULE**: every §3 cap that counts submissions/grants
(`max_submissions_per_day`, `max_daily_volume_lots`,
`min_seconds_between_submissions`) is evaluated EXCLUSIVELY from durable
EventStore evidence - specifically, a durable E1 line (the ceremony's own
`SUBMISSION_IN_PROGRESS` state change carrying `submission_provenance`,
classified per INVARIANT PROV-1; Rev.12
correction - this sentence said `EXECUTION_SUBMISSION_ATTEMPTED` (E2)
until Rev.11, contradicting §3.2; see INVARIANT BUD-1) for the
submission-counting caps, or a durable
`EVENT_TYPE_EXECUTION_MANUAL_APPROVAL_GRANTED` line (for any grant-scoped
accounting; exact name corrected Rev.9 - see §2.3.3's own Round 8 Blocker
2 fix) - never from any in-memory counter, log, or ledger the
Decision Engine itself keeps of its own issuance attempts. **This document
freezes that no such in-memory ledger exists or is authorized** - §3's
caps read ONLY durable state, fresh, every invocation, exactly as §3.2
(below) specifies.

**Why `WRITE_FAILED` and `LOST` structurally cannot and do not count,
without needing an exclusion rule bolted on**: a command only ever
produces a durable EventStore line via `CeremonyCommand_TryClaim()`'s own
append, which only ever runs against a command that is CONFIRMED occupying
the mailbox slot at claim time (the OnTimer cycle reads the mailbox, finds
a `PENDING` command, and claims it). A `WRITE_FAILED` command never
reached the mailbox file at all - there is nothing there to claim. A
`LOST` command's own write was overwritten (or its confirmation merely
failed while a survived write sits there un-owned by the Decision Engine's
own knowledge) - in the "genuinely overwritten" case, nothing of this
invocation's own command remains in the mailbox to claim; in the
"confirmation read merely failed" case, the command IS still sitting
there and WILL still be claimed normally by the OnTimer cycle in the
ordinary course - producing durable evidence attributed to that ACTUAL
claim event, not to this invocation's own (mistaken) belief that it was
lost. Either way, **this document's own accounting never needs to
special-case LOST at all**: caps count claimed/durable evidence, LOST
commands either produce none (true loss) or eventually produce EXACTLY
ONE normal, correctly-attributed claim event (false-negative confirmation)
- never a duplicate, never an undercounted "phantom" attempt, because
there is no separate ledger tracking "attempts" as distinct from "claims"
for this document to keep synchronized in the first place.

**Why this needs no sub-case split (the two flavors of LOST collapse to
one accounting answer)**: whether the confirmation mismatch was caused by
a genuine external overwrite or a transient confirmation-read failure over
a write that actually survived, the ACCOUNTING outcome is identical from
this document's perspective - in neither case does THIS INVOCATION durably
record anything, and in neither case does this document's own logic
attempt a same-invocation retry. The only difference between the two
sub-cases is whether SOME command (this one, or the external one that won)
eventually gets claimed and durably recorded later - and in both sub-cases,
that later claim event is counted correctly and exactly once, by the
SAME existing claim-time mechanism, regardless of which sub-case produced
it. This document does not need to know which sub-case occurred to get
the accounting right.

Unchanged ordering (kill switch → rollout stage/capability → cross-validity
→ this candidate's own state (§2.3.2, now including the mailbox-occupancy
check) → §3 caps), evaluated fresh, every invocation.

**[Rev.15 AMENDMENT — D7 (C1), D9] Pre-flight parity, the last step
before issuing a SUBMIT_ORDER.** Amended ordering: kill switch → rollout
stage/capability → cross-validity → mailbox occupancy (read once) →
discovery (§2.3.1a as amended: admissibility, state) → §3 caps →
**pre-flight parity** → issuance (§2.3.2a).

```
PRE-FLIGHT PARITY (SUBMIT_ORDER only; read-only; sealed functions only):
  CeremonyCommandRegistry_HasUnresolvedSubmission() == true
      -> issue nothing this invocation (RA-31.2 condition B).
  CandidateProjection_TryGet(X.candidate_id) fails, or
  StateProjector_TryGetState(X.candidate_id) fails
      -> issue nothing this invocation.

These are exactly the checks SubmitOrderCommand() makes BEFORE E1
(MLQuantAI.mq5:1225-1243). A SUBMIT the Decision Engine issues therefore
cannot be rejected by them, which removes the pre-E1 re-issue loop (F1c):
without it, each 2 s OnTimer cycle would write >= 2 durable lines.
Check A (kill switch) and Check B (stage x environment) are already
pre-empted by the first steps of the ordering.
```

GRANT loop (D7, option (i)): no GRANT-specific guard is added. Stage ×
environment is checked before any issuance, so R13's rejection is
pre-empted. A GRANT that fails because the EventStore write itself fails
is outside liveness scope: repeated EventStore write failure is an
operational fault, not a design liveness path. F1c is a Wave 3 blocker
(D9). A new durable provenance marker for all automation commands (F1
Rev.3 option C2) is **not** part of this amendment and is not authorized.

**Blocker 4 — the claim-time kill-switch check must be tri-state, not
fail-open on a read/replay problem.**

```
CONFIRMED_INACTIVE / CONFIRMED_ACTIVE / CHECK_FAILED, CHECK_FAILED -> REJECT.
```

**The fix (Rev.4) — a genuine precondition check, using the sealed, PURE,
side-effect-free validator this checkpoint's whole evidence-gate lineage
already relies on for exactly this kind of "can this read be trusted"
question** (`EventStoreValidator_ValidateFile()`, confirmed present,
`MLQuantAI_EventStoreValidator.mqh` — **not** `EventStoreHealth_CheckFile()`,
which is a heavier wrapper that TRIPS SAFE MODE as a side effect on
corruption; deliberately not reused here, since a claim-time gate check
must not itself cause a Safe Mode engagement merely by running).

**Rev.5 fix, still valid — closed Round 4 Blocker 5**: Rev.4's own version
validated the FILE, then performed a SEPARATE, later `EventStore_
ReadAllLines()` call — two distinct file reads. `EventStoreValidator_
ValidateFile()`'s own body (confirmed by direct read, `MLQuantAI_
EventStoreValidator.mqh:139-144`) is nothing but `EventStore_ReadAllLines()`
followed by the PURE, already-separately-exposed `EventStoreValidator_
ValidateLines(const string &lines[])` (`MLQuantAI_EventStoreValidator.
mqh:37`). Both `RolloutStageProjection_ReplayCurrent()` and
`KillSwitchProjection_ReplayActive()` already take `lines[]` directly. So
Check A reads the file exactly ONCE, and validates + replays off that SAME
in-memory array.

**Rev.6 extension, closing Round 5 Blockers 3 and 4 together**: QA's
Round 5 review found two related gaps: (Blocker 3) Check B only re-checked
`rollout_stage`, never `environment_mode`, so a queued system-issued
SUBMIT could theoretically survive an `environment_mode` change the
durable `rollout_stage` history hasn't caught up to yet; (Blocker 4) the
EventStore snapshot (`liveLines[]`) and the live environment read
(`EnvironmentMode_ReadLive()`) are two independent sources with no frozen
relationship between them. **Traced this revision**: `EnvironmentMode_
ReadLive()` (confirmed by direct read, `MLQuantAI_EnvironmentModeReader.
mqh:33`) is a PURE, file-free, single live terminal call
(`MQLInfoInteger(MQL_TESTER)` then `AccountInfoInteger(ACCOUNT_TRADE_
MODE)`) — unlike the mailbox, there is no separate OS process or file that
can race it; combined with the EventStore being single-writer (this same
EA process only) and MQL5's own single-threaded, non-preemptive execution,
reading `liveLines[]` once and calling `EnvironmentMode_ReadLive()` once,
back-to-back, within the same Check A block gives a snapshot pair nothing
else in this system can invalidate mid-read — a materially different,
stronger guarantee than the external-writer mailbox race (Blocker 2), not
the same kind of gap. This pair (`liveLines[]`, `liveEnvMode`) is now
**read exactly once per `SubmitOrderCommand()` invocation, at the top of
Check A, and reused verbatim by every subsequent check in the same
invocation — never re-read**.

**Rev.7 fix, closing Round 6 Blocker 2 — `EventStore_ReadAllLines()`'s own
undistinguished failure mode**: traced this revision (`MLQuantAI_
EventStore.mqh:250-258`, confirmed by direct read): `EventStore_
ReadAllLines()` returns `0` with `outLines` left empty (`ArrayResize(
outLines, 0)`, then an immediate `return 0`) whenever `FileOpen()` itself
fails — for ANY reason (missing file, permissions, disk error, a second
concurrent handle failing to open) — and this is **indistinguishable** from
a genuinely empty, healthy, zero-line file, which would ALSO produce
`count=0`. A pre-existing comment already documents this exact fact
independently (`MLQuantAI_ExecutionProvenanceConflictAuditor.mqh:362-366`
— "no distinct error signal exists at that layer"). Worse:
`EventStoreValidator_ValidateLines([])` on a zero-length array returns
`ok=true` **vacuously** (its own loop over `ArraySize(lines)==0` iterations
never runs, so `report.ok` never gets set to `false`) — meaning Rev.6's own
Check A, as written, would treat "the EventStore could not even be
opened" identically to "the EventStore validated clean and is empty," and
`KillSwitchProjection_ReplayActive([], ...)` would then report "no engaged
event found -> not active," **letting a submission through on a read
failure** — a genuine fail-open gap, not a cosmetic one.

**The fix**: freeze that `ArraySize(liveLines) == 0` is ITSELF an explicit
`CHECK_FAILED` precondition for this specific claim-time context, checked
BEFORE validation. This is not an arbitrary threshold — it is grounded in
a structural fact about WHEN this code path can ever run: `SubmitOrderCommand()`
only executes against a `CeremonyCommand` that has already been CLAIMED,
which itself only happens after `CeremonyCommand_TryClaim()` has ALREADY
durably appended a `COMMAND_RECEIVED` line to this SAME EventStore file
(§2.3.2's own traced fact, unchanged since Rev.4) — meaning by the time
`SubmitOrderCommand()`'s own body runs and re-reads the store, AT MINIMUM
that one line must already exist. Reaching `DEMO_BOUNDED_AUTOMATION` in
the first place additionally requires the full prior `EXECUTION_ROLLOUT_
STAGE_CHANGED` transition history through every earlier rung of the
ladder. A genuinely healthy, running system at this point in its life
CANNOT have a zero-line EventStore — so `ArraySize(liveLines) == 0` is
never a legitimate state here, only ever a read failure, and treating it
as `CHECK_FAILED` costs nothing while closing the fail-open gap completely:

```cpp
// ratified (R14) amendment to SubmitOrderCommand() - Check A (Rev.7)
{
   string liveLines[];
   EventStore_ReadAllLines(g_EventStoreFileName, liveLines);
   ENUM_EXECUTION_ENVIRONMENT_MODE liveEnvMode = EnvironmentMode_ReadLive();
   // liveLines[] and liveEnvMode: ONE read of each, right here, reused by
   // Check A below AND by Check B (§2.3.3 continued) - never re-read.

   if(ArraySize(liveLines) == 0)
   {
      CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED,
                            "kill_switch_check_failed", "event store read returned zero lines - unopenable or corrupted, never legitimate at DEMO_BOUNDED_AUTOMATION");
      return;   // CHECK_FAILED -> REJECT, unconditional - closes Round 6
                // Blocker 2: a read failure can no longer be silently
                // mistaken for a genuinely empty, healthy store.
   }

   EventStoreValidationReport validation = EventStoreValidator_ValidateLines(liveLines);
   if(!validation.ok)
   {
      CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED,
                            "kill_switch_check_failed", validation.first_error);
      return;   // CHECK_FAILED -> REJECT, unconditional
   }

   // validation.ok == true, computed over THIS EXACT liveLines[] array -
   // this replay is now trustworthy by construction.
   bool liveKillSwitchActive;
   KillSwitchProjection_ReplayActive(liveLines, liveEnvMode, liveKillSwitchActive);
   if(liveKillSwitchActive)
   {
      CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED, "kill_switch_active", "");
      return;
   }
}
```

This closes Round 4 Blocker 4 (kill-switch tri-state) and Round 4 Blocker
5 (TOCTOU) exactly as before, and now also lays the groundwork for closing
Round 5 Blockers 3/4 in Check B below, by making `liveEnvMode` available
as an already-fresh, already-adjacent-in-time value alongside `liveLines[]`
— not a separately-timed third read.

**Blocker 3 (Rev.4) — claim-time stage re-check for a queued
system-issued `SUBMIT_ORDER` surviving a rollback. Blocker 2 (Rev.4,
closed this revision) — the Rev.4 version below looked up "the LATEST
grant" for `cmd.target_execution_request_id`, which QA showed is
ambiguous: system GRANT -> system SUBMIT queued -> rollback -> a NEW
human GRANT issued for the SAME execution_request_id -> queued SUBMIT
claimed -> "latest" now returns the human grant, so this check never
fires even though the SUBMIT was originally system-issued.**

**The fix, traced against the real `CeremonyCommand` struct this
revision**: `approver_identity` is a free-text field already present on
`CeremonyCommand` (confirmed by direct read, `MLQuantAI_
CeremonyCommandMailbox.mqh`), documented as used for `GRANT_MANUAL_
APPROVAL` commands only — nothing in the sealed `SubmitOrderCommand()`
reads `cmd.approver_identity` for a `SUBMIT_ORDER` command today. Rather
than asking "what does the CURRENT grant state say" (a question whose
answer can change out from under a queued command, exactly as QA's
scenario shows), Check B now asks a strictly simpler, non-ambiguous
question: **"what does THIS command's own provenance, fixed at the moment
this document's own Decision Engine issued it, say?"** — read directly off
`cmd` itself, the exact object being claimed, never off a separate,
mutable lookup:

```cpp
// same amendment to SubmitOrderCommand() - Check B, immediately after
// Check A above, still before any ExecutionRequestProjection lookup:
{
   // cmd.approver_identity was set at ISSUANCE time (§2.3.2's own
   // "Frozen transition rule" -> issue SUBMIT_ORDER step, Rev.5): this
   // document's own automation sets it to the reserved string on every
   // SUBMIT_ORDER it issues; a human ceremony script issuing a
   // SUBMIT_ORDER leaves it at its existing default (empty/unused,
   // matching today's unmodified behavior byte-for-byte). No lookup of
   // "the current/latest grant" is performed at all - this is direct,
   // immutable-once-claimed provenance on the command being processed,
   // not a derived fact that can drift after issuance.
   if(cmd.approver_identity == MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY)
   {
      // Reuses the SAME validated liveLines[] AND the SAME liveEnvMode
      // from Check A above - both read exactly once, at the top of this
      // invocation, reused here rather than re-read for a second purpose.
      ENUM_EXECUTION_ROLLOUT_STAGE liveCurrentStage;
      RolloutStageProjection_ReplayCurrent(liveLines, liveCurrentStage);

      // Round 5 Blocker 3 fix: stage alone is no longer sufficient - the
      // fresh (stage, environment_mode) PAIR must itself be cross-valid,
      // using the SAME sealed, frozen predicate §6.1's own crossing gate
      // already relies on (RolloutStage_IsValidForEnvironment(),
      // MLQuantAI_RolloutStageCrossValidity.mqh, confirmed present) -
      // this document does not invent a new cross-validity rule, it
      // reuses the one that already exists and is already authoritative
      // for every other C5.2 enforcement point.
      if(liveCurrentStage != ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION ||
         !RolloutStage_IsValidForEnvironment(liveCurrentStage, liveEnvMode))
      {
         CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED,
                               "automated_submission_stage_no_longer_bounded_automation", "");
         return;
      }
   }
   // Human-issued submissions (approver_identity != the reserved string,
   // including today's existing empty/unset value) are NOT subject to
   // THIS particular re-check - unchanged behavior, matching how a human
   // approval already carries no rollout_stage binding today, byte-for-
   // byte. See the SEPARATE, second condition immediately below (Rev.8)
   // for why a human-issued SUBMIT can still be caught.
}
```

**Rev.8 addition, closing Round 7 Blocker 1 — the system-issued-GRANT
rollback leak**: QA's Round 7 review found a DIFFERENT path around the
check above: `DEMO_BOUNDED_AUTOMATION` -> automation issues and claims a
GRANT (reserved `approver_identity`, valid for its own `approval_expiry`,
up to 15 minutes) -> rollback to `DEMO_REAL_SUBMIT` -> a HUMAN issues
`SUBMIT_ORDER` for the SAME `execution_request_id`, within the grant's
still-valid window. This `SUBMIT_ORDER` command is human-issued, so
`cmd.approver_identity` is NOT the reserved string, and the check above
never runs — yet the underlying `ManualApprovalRegistry_HasValidApproval()`
gate (sealed, C2, downstream) does not care WHO issued the grant, only
that a valid one exists, and approves the submission anyway. This lets a
`DEMO_REAL_SUBMIT`-stage submission proceed on the strength of an approval
that was only ever supposed to be valid under `DEMO_BOUNDED_AUTOMATION`'s
own automatic-submission privilege — `DEMO_REAL_SUBMIT`'s own frozen rule
("manual approval per-submission MANDATORY," §0) is not fully enforced in
this specific path.

**The fix**: Check B's condition was asking the wrong question — "was the
SUBMIT command itself system-issued" — when the actual vulnerability is
about the GRANT's own provenance, independent of who later spends it. A
SECOND, independent condition is added, checking the provenance of THE
APPROVAL BEING CONSUMED.

**Rev.9, closing Round 8 Blocker 2 — Rev.8's own mechanism traced against
real source, and corrected**: Rev.8 proposed a raw-scan over `liveLines[]`
using an invented, unverified parse helper (`EventSerializer_
ParseManualApprovalGranted`) and an event-type name
(`EVENT_TYPE_MANUAL_APPROVAL_GRANTED`) that turned out not to be the real
one. Traced this revision, `MLQuantAI_ManualApprovalEmission.mqh:113`
confirms the actual durable event type is `EVENT_TYPE_EXECUTION_MANUAL_
APPROVAL_GRANTED`, and `MLQuantAI_ManualApprovalProjection.mqh:172-177`
confirms `approval_expiry` is an ABSOLUTE timestamp, not a duration
(`grant.approval_expiry <= grant.approval_timestamp` is itself the
write-time rejection rule) — Rev.8's own `g.approval_timestamp + g.
approval_expiry * 60` was a genuine bug, never merely a naming detail.

**The corrected fix does not parse `liveLines[]` for this purpose at
all**: `MLQuantAI_ManualApprovalProjection.mqh` already maintains a
live, validated, write-then-update registry (`g_ManualApprovalProj_
Records[]`, confirmed present, exposed via `ManualApprovalProjection_
Count()`/`ManualApprovalProjection_GetAt()`) that is kept synchronously
current with every durable grant (RA-30.4's own frozen design, confirmed
by direct read of `MLQuantAI_ManualApprovalEmission.mqh`'s own header:
"the registry it reads from reflects this write immediately, same
session, no restart required"). Because `GRANT_MANUAL_APPROVAL` and
`SUBMIT_ORDER` commands are BOTH dispatched through the SAME single-
threaded `RA31_ProcessCeremonyCommand()` path (§2.3.2a's own Rev.9 proof,
above), this registry cannot be stale relative to `SubmitOrderCommand()`'s
own claim-time invocation - it is a STRONGER source than a fresh raw parse
of `liveLines[]` would have been, not a weaker one, and it is already
validated by the FULL lineage-check chain `ManualApprovalProjection_
ApplyLineWithLineage()` performs at write time (schema, required fields,
lineage-matching, nonce-collision), not merely a bare parse:

```cpp
// Check B, second condition - Rev.11 predicate (narrowed from Rev.9/
// Rev.10; see INVARIANT MA-1 below for why), immediately after the
// cmd.approver_identity check above. Rev.13: the authoritative source is
// the validated durable snapshot liveLines[] (INVARIANT SG-1), unioned
// with the projection - see the first loop.
{
   bool anySystemGrant = false;

   // (F) AUTHORITATIVE - durable history, the SAME validated, non-empty
   // liveLines[] Check A already read in this invocation. No lineage
   // validation is applied, deliberately: this predicate can only BLOCK,
   // so accepting a line the projection would reject only blocks more.
   string grantType   = EventTypeToString(EVENT_TYPE_EXECUTION_MANUAL_APPROVAL_GRANTED);
   string systemToken = "\"approver_identity\":\"" + MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY + "\"";
   for(int i = 0; i < ArraySize(liveLines) && !anySystemGrant; i++)
   {
      if(EventSerializer_GetStr(liveLines[i], "type") != grantType) continue;
      if(EventSerializer_GetStr(liveLines[i], "execution_request_id") != cmd.target_execution_request_id) continue;
      if(StringFind(liveLines[i], systemToken) >= 0) // ANY occurrence counts, even a duplicated key
         anySystemGrant = true;
   }

   // (R) DEFENSE IN DEPTH - the projection C2 itself reads. Kept so that
   // SG-1's set contains R unconditionally (MA-1 clause 3), without
   // depending on the R-is-a-subset-of-F lemma.
   for(int i = 0; i < ManualApprovalProjection_Count() && !anySystemGrant; i++)
   {
      ManualApprovalProjectionRecord g;
      if(!ManualApprovalProjection_GetAt(i, g)) continue;
      if(g.execution_request_id != cmd.target_execution_request_id) continue;
      // Rev.11: NO time-window filter. Rev.9/Rev.10 filtered on
      // TimeCurrent() >= approval_timestamp && approval_expiry >
      // TimeCurrent(). That made MA-1 depend on the ordering between
      // this TimeCurrent() and the C2 gate's own later, separately
      // captured asOf (MLQuantAI_EnvironmentLockGate.mqh:176), which this
      // document cannot pass in (the gate is sealed). Any system-issued
      // grant for this execution_request_id, expired or not, triggers the
      // stage x environment check.
      if(g.approver_identity == MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY)
      {
         anySystemGrant = true;
         break;
      }
   }

   if(anySystemGrant)
   {
      // SAME stage x environment cross-validity check as above - applies
      // regardless of who issued THIS SUBMIT command, because what is
      // being protected is the SYSTEM-ISSUED APPROVAL's own scope, not
      // the submitter's identity.
      ENUM_EXECUTION_ROLLOUT_STAGE liveCurrentStage;
      RolloutStageProjection_ReplayCurrent(liveLines, liveCurrentStage);
      if(liveCurrentStage != ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION ||
         !RolloutStage_IsValidForEnvironment(liveCurrentStage, liveEnvMode))
      {
         CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED,
                               "automated_submission_stage_no_longer_bounded_automation", "");
         return;
      }
   }
}
```

**Rev.10, closing Round 9 Blocker 2 — proving `ManualApprovalProjection`
cannot lag the validated `liveLines[]` snapshot, not merely assuming it**:
QA's Round 9 review correctly noted that switching to `g_
ManualApprovalProj_Records[]` (Round 8's own fix) solved the
schema/correctness problem but left a NEW question open: is this registry
proven to reflect AT LEAST everything `liveLines[]` (read and validated by
Check A, moments earlier in the SAME invocation) would show, or could it
lag behind? Traced this revision, in three parts:

```
1. EVENT_TYPE_EXECUTION_MANUAL_APPROVAL_GRANTED has EXACTLY ONE producer
   in the entire codebase - confirmed by an exhaustive grep of every
   occurrence of this event type: the sole place anything is EVER
   assigned this type for a durable WRITE is ManualApproval_Grant()
   (MLQuantAI_ManualApprovalEmission.mqh:113). Every other occurrence is
   the enum definition/string-mapping (Core/MLQuantAI_Enums.mqh) or a
   READ-side consumer (the projection rebuild, this document's own Check
   B, test files). There is no second write path for a "the file has it,
   the registry doesn't yet" scenario to arise from.

2. ManualApproval_Grant() (confirmed, MLQuantAI_ManualApprovalEmission.
   mqh:100-150) writes durably FIRST (EventStore_AppendSystem(e)), and
   ONLY IF THAT SUCCEEDS, synchronously updates the live registry SECOND
   (ManualApprovalProjection_ApplyLineWithLineage(line, applyReason)) -
   both steps inside ONE function call, with RA-30.4's own frozen header
   comment stating the guarantee directly: "the registry it reads from
   reflects this write immediately, same session, no restart required."

3. GRANT_MANUAL_APPROVAL and SUBMIT_ORDER commands are BOTH dispatched
   through the SAME single-threaded RA31_ProcessCeremonyCommand() path
   (§2.3.2a's own Rev.9 proof, above) - and the single-slot mailbox
   architecture (§2.3.2) guarantees they are never claimed/processed
   concurrently with each other either. So by the time ANY SubmitOrderCommand()
   invocation reads liveLines[] and separately consults the registry,
   every GRANT-processing call that has EVER run has ALREADY completed
   BOTH its durable write AND its registry update (or, if the durable
   write itself failed, NEITHER happened - ManualApproval_Grant() returns
   false before ever touching the registry) - there is no third,
   in-between state a later call could observe.

CONCLUSION: liveLines[] and g_ManualApprovalProj_Records[] are not
"usually in sync" or "believed fresh" - for GRANT content specifically,
they are STRUCTURALLY GUARANTEED identical at any point a later
SubmitOrderCommand() invocation could consult them, because there is
exactly one producer, that producer updates both under one uninterruptible
call, and nothing else can interleave on a single-threaded dispatcher.
This is the same class of proof §2.3.2a's own Rev.9 fix already
established for candidate.state visibility - applied here to a second
piece of shared state.
```

[CORRECTED Rev.11: the conclusion above overstates. RA-30.4's own sealed
code documents one branch where the registry DOES lag the file:
`ManualApproval_Grant()`'s durable write succeeds, then the registry
apply fails - "durable/runtime are now inconsistent for this grant until
the next EA restart rebuilds the registry. Human reconciliation required"
(`MLQuantAI_ManualApprovalEmission.mqh:131-147`). The branch is described
there as "effectively unreachable in practice," but it exists. So
freshness is NOT unconditional, and this document no longer rests Check
B's safety on it. INVARIANT MA-1 below replaces it as the safety basis.]

#### INVARIANT MA-1 — Check B's grant view is the C2 spend gate's own view (FROZEN, Rev.11, closing Round 10 Blocker 2)

QA's Round 10 review asked for a formal invariant binding Check B's grant
evidence to the state used for the claim, offering three acceptable
forms. This document chooses a fourth that is strictly stronger for
safety than all three, and explains why each offered form was not chosen
as the primary basis.

```
MA-1. Within ONE SubmitOrderCommand() invocation, let R be the global
registry g_ManualApprovalProj_Records[].

  (1) SAME DATA. Check B condition 2 iterates R. The C2 approval gate -
      ManualApprovalRegistry_HasValidApproval(), called at MLQuantAI_
      EnvironmentLockGate.mqh:189 and reached LATER in the same call via
      BrokerSubmission_Submit() -> BrokerSubmissionEnvironmentLock_
      Evaluate() -> EnvironmentLock_EvaluateNewChecks() - also iterates
      R (MLQuantAI_ManualApprovalProjection.mqh:356-373).

  (2) NO WRITER IN BETWEEN. R has exactly two writers in production code:
      ManualApprovalProjection_AppendRecord() - reachable only via
      ManualApprovalProjection_ApplyLineWithLineage(), whose production
      callers are ManualApproval_Grant() (sole production caller:
      GrantManualApprovalCommand(), MLQuantAI.mq5:1058) and
      ManualApprovalProjection_RebuildFromFile() - and ManualApproval
      Projection_Reset(), reachable only via RebuildFromFile(), whose only
      production caller is ManualApproval_StartupRebuild() (MLQuantAI_
      ManualApprovalReadiness.mqh:37), called only from OnInit (MLQuantAI.
      mq5:502). Neither GrantManualApprovalCommand() nor OnInit can run
      during a SubmitOrderCommand() call on MQL5's single-threaded
      dispatcher (§2.3.2a). Nothing in SubmitOrderCommand()'s own body
      between Check B and BrokerSubmission_Submit() writes R (it performs
      projection lookups, builds structs, writes E1 via EventStore_
      LogCeremonyCommandState() - a CEREMONY_COMMAND_STATE_CHANGED event,
      not a grant - and writes the mailbox; MLQuantAI.mq5:1233-1320).
      So R is identical at both reads.

  (3) PREDICATE CONTAINMENT. The C2 gate accepts record r iff r matches
      the request on five identity fields (execution_request_id, hash,
      policy version, candidate_id, correlation_id) AND asOf >= r.
      approval_timestamp AND r.approval_expiry > asOf. Check B condition 2
      (Rev.11) treats r as relevant iff r.execution_request_id == cmd.
      target_execution_request_id AND r.approver_identity == the reserved
      string. The request's execution_request_id IS cmd.target_execution_
      request_id (req is built from ExecutionRequestProjection_TryGet(cmd.
      target_execution_request_id), MLQuantAI.mq5:1233-1264). So every
      system-issued r the C2 gate could accept is relevant to Check B -
      with no dependence on either time value.

  CONSEQUENCE. A submission can pass the C2 approval gate on the strength
  of a system-issued grant only if Check B condition 2 has already seen
  that same grant in the same R and enforced stage x environment. If R
  lacks a system grant that the EventStore file contains (the RA-30.4
  branch above), the C2 gate cannot see it either, so it cannot be spent -
  the submission fails the C2 gate (REASON_EXECUTION_MANUAL_APPROVAL_NOT_
  GRANTED) unless a valid human-issued grant exists, in which case the
  submission is genuinely human-approved and DEMO_REAL_SUBMIT's own rule
  is satisfied. MA-1 therefore holds whether or not R is fresh.
```

**Why each of QA's three offered forms was not chosen as the primary
basis**:

```
(i) "projection source_sequence >= snapshot cutoff" - sequence numbers
    in this EventStore reset to 1 on every EventStore_Open() (documented,
    MLQuantAI_CandidateTerminalTransitionLocator.mqh:13-14), so a single
    cutoff across sessions is not well-defined without additionally
    keying on runtime_session_id. More importantly, it would still be a
    freshness claim, which the RA-30.4 branch shows can fail.

(ii) "derive grant provenance from the same validated liveLines[]" - this
    would need a second, parallel implementation of the grant validation
    ManualApprovalProjection_ApplyLineWithLineage() already performs,
    which RA-30.4's own design explicitly avoids ("no second, parallel
    validation implementation to drift from it"). It would also make
    Check B read a DIFFERENT representation from the one the C2 gate
    reads - reintroducing exactly the two-representation mismatch this
    blocker is about, in the opposite direction.

(iii) "freeze the synchronous invariant with explicit post-restart
    semantics" - adopted below as MA-2, but only as a documented relation,
    not as the safety basis, because of the RA-30.4 exception.
```

**MA-2 — freshness relation (documented, NOT relied on for safety)**:

```
MA-2. After a successful ManualApproval_StartupRebuild() (readiness true),
for this EA's EventStore file F: every grant line in F that
ManualApprovalProjection_ApplyLineWithLineage() accepts has a record in R
(keyed by source_log_event_id). It is maintained because the sole
production producer, ManualApproval_Grant(), applies to R synchronously
right after its durable write, on the single-threaded dispatcher - and the
human grant path no longer writes the EventStore directly (Tests/MLQuantAI_
ManualScript_GrantApproval.mq5 now only writes the ceremony mailbox, line
121; the grant itself is written by the EA's own GrantManualApprovalCommand()).

EXCEPTION: the RA-30.4 branch (durable write succeeded, registry apply
failed) - F has a grant R lacks, until restart. Covered by MA-1: that
grant is unspendable.

POST-RESTART: ManualApproval_StartupRebuild() rebuilds R from F and sets
readiness := report.ok (MLQuantAI_ManualApprovalReadiness.mqh:38). If the
rebuild fails, readiness is false and the C2 gate rejects EVERY submission
(REASON_EXECUTION_AUDIT_NOT_READY, MLQuantAI_EnvironmentLockGate.mqh:
169-174). If it succeeds, MA-2 holds fully again.
```

#### INVARIANT SG-1 — system-granted execution requests are stage-bound (FROZEN Rev.12; authoritative source fixed Rev.13; RATIFIED R11, Rev.14)

QA's Round 11 review asked for this behaviour change to be stated as a
frozen invariant. QA's Round 12 review then pointed out that Rev.12's
wording, "the registry holds ANY system-issued record", could not honour
the word ANY: MA-1 itself documents the RA-30.4 branch where a system
grant is durable in the EventStore but absent from the projection. Rev.13
chooses QA's option B.

```
SG-1 AUTHORITATIVE SOURCE (Rev.13). "A system-issued record for X exists"
means: the validated, non-empty snapshot liveLines[] that Check A read in
this same SubmitOrderCommand() invocation contains at least one line L
with
   EventSerializer_GetStr(L, "type") == EventTypeToString(
       EVENT_TYPE_EXECUTION_MANUAL_APPROVAL_GRANTED)
   AND EventSerializer_GetStr(L, "execution_request_id") == X
   AND L contains the exact substring
       "approver_identity":"SYSTEM_BOUNDED_AUTOMATION_V1"
       (any occurrence - a duplicated key cannot hide it)
OR the projection g_ManualApprovalProj_Records[] holds such a record.

No lineage validation is applied to snapshot lines, deliberately: SG-1 can
only block, so a line the projection would reject (orphan, nonce
collision, the RA-30.4 branch) can only cause MORE blocking, never less.
This does not conflict with Rev.11's reason for rejecting a raw-parse
source (MA-1 note (ii)): that objection was to replacing the projection
C2 reads with a second validator. Here the projection is still included,
so MA-1's containment is untouched, and the snapshot only adds.

WHY THE SNAPSHOT IS COMPLETE: every durable append calls FileFlush()
(MLQuantAI_EventStore.mqh:86), and EventStore_ReadAllLines() on the
session's own file reuses the open handle and reads from offset 0
(MLQuantAI_EventStore.mqh:250-261). So liveLines[] contains every grant
durably written before this call, in this session or any earlier one.
And every projection record originates from a durable line written
before this call (AppendRecord runs only after a successful durable
append, or during a rebuild from the file), so in practice the union adds
nothing beyond the snapshot; R is kept so the containment holds without
relying on that argument.

SG-1. If a system-issued record for X exists in this sense - whether that
grant is valid, expired, or long superseded - then
every SUBMIT_ORDER for X, from any issuer, human or automation, is
rejected at claim time (Check B condition 2, CEREMONY failure
automated_submission_stage_no_longer_bounded_automation, before any E1
is written) unless fresh rollout_stage x environment_mode is
DEMO_BOUNDED_AUTOMATION x EXECUTION_ENV_DEMO.

CONSEQUENCES, stated so no implementer has to infer them:
  - In DEMO_BOUNDED_AUTOMATION x DEMO, SG-1 changes nothing.
  - After a rollback, X cannot be submitted, even with a fresh, valid
    human grant. A manual trade on that candidate requires a new
    ExecutionRequest (new execution_request_id). This document does not
    create one.
  - X becomes submittable again only if the stage returns to
    DEMO_BOUNDED_AUTOMATION.
  - SG-1 has no clock dependency: it does not read TimeCurrent(), so
    MA-1's predicate containment (clause 3) holds regardless of the
    ordering between Check B and the C2 gate's own asOf capture.
  - SG-1 now detects the RA-30.4 branch itself (durable system grant,
    projection miss): X is blocked by SG-1 directly, not only by C2's
    inability to spend the grant - the converse QA asked for.
```

If QA rejects SG-1, the only alternative this document offers is: keep a
filter `approval_expiry > T_B` (no lower bound), with the invariant then
stating its reliance on `TimeCurrent()` not moving backwards between
Check B and `MLQuantAI_EnvironmentLockGate.mqh:176` within one call. That
choice would replace SG-1, not coexist with it.

**Machine-checkable at the future Test Authorization phase (proposed, not
authorized now)**: (a) system grant exists for X, stage rolled back to
`DEMO_REAL_SUBMIT`, human `SUBMIT_ORDER` for X → CEREMONY fails
`automated_submission_stage_no_longer_bounded_automation` with no
`EXECUTION_SUBMISSION_ATTEMPTED` line written; (b) simulate the RA-30.4
branch (grant line in F, absent from R), no human grant → the C2 gate
rejects with `REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED`, never
ACCEPTED; (c) a structural check, following this codebase's own
structural-review-gate precedent, that the writers of
`g_ManualApprovalProj_Records[]` and their production callers are exactly
those listed in MA-1 (2).

**Why both conditions are necessary, not redundant**: the FIRST condition
(`cmd.approver_identity`) protects against automation itself acting
(pulling the SUBMIT trigger) after its own authority has rolled back,
REGARDLESS of which grant it relies on (even a human-issued one) — because
automatic triggering itself is the privilege that may have lapsed. The
SECOND condition (this one) protects against ANY submitter — human or
automated — spending a system-issued approval OUTSIDE the stage that
authorized issuing it — because the approval's own provenance, not the
submitter's, is what makes it exempt from `DEMO_REAL_SUBMIT`'s own
mandatory-manual-approval rule in the first place. Rev.7's fix closed only
the first; Rev.8 closes both, together, using the same mechanism twice
rather than inventing two different ones.

**Why the added `RolloutStage_IsValidForEnvironment()` clause closes
Round 5 Blocker 3 without a race of its own (closing Round 5 Blocker 4)**:
per the ladder document's own frozen cross-validity table (confirmed via
`Tests/MLQuantAI_Test_C5_2_RolloutStageCrossValidity.mq5`),
`ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION` is valid under `EXECUTION_ENV_DEMO`
only — so this clause is, in practice, equivalent to also requiring
`liveEnvMode == EXECUTION_ENV_DEMO`, expressed via the existing sealed
predicate rather than a second, hand-rolled equality check, for
consistency with how every other C5.2 enforcement point performs this
exact check. Because `liveEnvMode` is the SAME value Check A already
computed (not a fresh, separately-timed read), and `EnvironmentMode_
ReadLive()` has no external-process race surface (unlike the mailbox),
this closes Blocker 4 as well: there is exactly one snapshot pair per
invocation, computed adjacently, consumed by both checks, never drifting
between them within the same `SubmitOrderCommand()` call.

**Why this closes both gaps precisely**: Round 3 Blocker 3 — a queued
`SUBMIT_ORDER` backed by a system-issued approval is the ONE case this
document's own automation created; it is the one case this document is
responsible for keeping safe across a rollback. A human-approved
submission's own
existing behavior (valid until its own `approval_expiry`, regardless of
subsequent `rollout_stage` changes) is **not** touched — touching it would
be a change to `DEMO_REAL_SUBMIT`'s own, already-frozen, already-sealed
behavior, outside this document's authorized scope entirely. Blocker 2 —
the check now reads a value fixed at issuance time on the command itself,
which cannot be altered by any LATER grant activity for the same
`execution_request_id` (a subsequent human grant, a rollback, a second
system grant) — QA's exact scenario no longer changes Check B's answer,
because Check B no longer asks a question whose answer depends on
"current" state at all. No `ManualApprovalProjection_TryGetLatestForRequest`
lookup is needed any more — §7's item naming that function as TBD is
removed this revision, since the design no longer depends on it existing.
Combined with Check A (kill switch, unconditional, every submission), the
rollback-without-kill-switch scenario QA named remains closed: a rollback
FROM `DEMO_BOUNDED_AUTOMATION` immediately fails this check for any
already-queued system-issued command the next time it is claimed,
regardless of kill-switch state.

**Fail-closed proof, reused from Rev.3/Rev.4, still valid**: a read/replay
failure inside Check B (were it to occur despite Check A's own
precondition having already passed over the SAME `liveLines[]`) still
collapses to `ROLLOUT_STAGE_NONE` (the ladder document's own frozen
default), which is `!= DEMO_BOUNDED_AUTOMATION`, so Check B fails closed
by the same construction Rev.3 already proved for §2.4's own stage-read
check. **Extended, Rev.6**: `EnvironmentMode_ReadLive()` itself has no
"failure" return - if it cannot determine DEMO or LIVE, it returns
`EXECUTION_ENV_NONE` by construction (its own confirmed source,
`MLQuantAI_EnvironmentModeReader.mqh:41`), and `RolloutStage_
IsValidForEnvironment(ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION,
EXECUTION_ENV_NONE)` is `false` per the frozen cross-validity table (only
`ROLLOUT_STAGE_NONE` is valid under every environment) - so an
undetermined live environment reads as fail-closed through the same
added clause, not a separate case this document needs to handle.

**This is the SAME single sealed-file amendment as Rev.3's own §2.3.3
proposal (`SubmitOrderCommand()`), now with two checks (A and B) instead
of one — still exactly two sealed functions touched by this whole document
(`GrantManualApprovalCommand`, `SubmitOrderCommand`), not three.**

#### §2.3.4 Fresh exposure read — closes Blocker 4 (unit-corrected Rev.5); reference price entry → current SL RATIFIED R17, Rev.14

`BoundedAutomation_ReadFreshExposure()` — a new, pure-ish, read-only
function, called fresh every Decision Engine invocation (never reused from
an earlier pipeline stage's `EligibilityContext`, since `open_risk_percent`
is confirmed hard-coded 0 there today — `MLQuantAI_EligibilityContract.
mqh:77`'s own disclosed comment):

```cpp
struct FreshExposureReading
{
   bool   ok;
   int    open_positions_count;
   double open_risk_percent;   // percent of current ACCOUNT_EQUITY
   string first_error;
};
```

**Scope (unchanged since Rev.2/Rev.3)**: ALL currently open positions,
account-wide, every symbol, every source (this EA's own positions AND any
manually-opened position sharing the account) — `max_concurrent_open_risk_
percent` is a whole-account hard cap, not scoped to this EA's own
candidates only.

**Rev.5's unit correction, still valid**: the formula's dimensional
analysis (tick_size-normalize the price distance BEFORE multiplying by
tick_value, mirroring `MLQuantAI_RiskSizing.mqh`'s own `Candidate_
ToRiskPlan()`, lines 77-94) is unchanged. What Round 6 Blocker 3 correctly
challenged was not the units but the REFERENCE PRICE choice itself —
Rev.5/Rev.6 picked entry price by citing RiskSizing's own convention,
without independently justifying why that convention is the economically
correct one to reuse HERE, for a currently-open position, as opposed to
merely being consistent with a DIFFERENT function's own (pre-trade
sizing) convention. QA is right that consistency-with-another-function is
not, by itself, a semantic justification.

**Rev.7 — frozen with an economic argument, not a convention citation**:
`max_concurrent_open_risk_percent` is defined to measure **the sum, across
every open position in scope, of the money that would be realized as a
loss if that position's CURRENT stop-loss order is triggered** — i.e. a
hard bound on "how much can this account still lose from positions
already open," expressed as a percentage of current equity.

**Why entry-to-SL is the ONLY correct measure of this, not "current
market price"-to-SL**: for ANY position with a static (non-trailing) stop,
the realized profit/loss if that stop is hit is `(SL_price - Entry_price)
* volume * contract factors` — a quantity determined ENTIRELY by entry
price and stop price, with the CURRENT market price appearing nowhere in
the calculation. This is not a modeling choice, it is how trade P&L is
defined: closing a position realizes the difference between its own entry
and its own exit (here, the stop price), period. The current floating
market price only determines the position's UNREALIZED P&L right now, a
different quantity from "loss upon stop-hit," which is fixed the moment
entry and stop are both known and does not change as price moves between
them. If the stop is a TRAILING stop, `POSITION_SL` itself moves over
time - but this formula already reads `POSITION_SL` FRESH every
invocation, so a trailing stop's current value is exactly what gets used;
no separate current-price term is needed to capture that movement.

**Why current-price-to-SL was considered and rejected**: that quantity
answers a DIFFERENT question - "how far is price from triggering the
stop right now" (a proximity/likelihood signal) - not "how much money is
at risk." Using it as a risk FIGURE would actively mislead a hard cap: for
a position currently sitting in PROFIT (price has moved favorably away
from a static stop), current-price-to-SL distance is LARGER than
entry-to-SL distance, so this alternative would OVERSTATE the cap's own
risk consumption for winning positions - counting against
`max_concurrent_open_risk_percent` more than the position could actually
ever lose. A hard safety cap must not systematically overstate a
DIFFERENT, unrelated quantity (proximity) as if it were the bounded one
(loss magnitude).

**Rev.8, closing Round 7 Blocker 3 — a genuine directional bug in Rev.7's
own formula, not a units bug this time**: QA's Round 7 review found that
`MathAbs(POSITION_PRICE_OPEN - POSITION_SL)` computes the SAME positive
number whether `POSITION_SL` sits on the LOSING side of entry (a genuine
downside stop) or the WINNING side (a trailing stop that has locked in
profit) - e.g. a BUY with Entry 4300/SL 4250 (50 units of genuine downside
risk) and a BUY with Entry 4300/SL 4350 (triggering this stop would
realize a 50-unit PROFIT, not a loss) both produce `MathAbs(...) = 50`.
This directly contradicts THIS document's own just-frozen definition
("the money that would be realized as a LOSS") - `MathAbs()` measures
undirected STOP-DISTANCE, not DOWNSIDE RISK, and Rev.7 conflated the two
despite having just distinguished "loss magnitude" from "proximity" one
paragraph above. **Fixed by making the formula direction-aware and floored
at zero** - a stop on the winning side of entry contributes exactly ZERO
to `max_concurrent_open_risk_percent`, because triggering it is not a loss
at all, matching the frozen definition exactly rather than a conservative
over-approximation of it (a second such approximation, after
current-price-to-SL, was rejected in the paragraph above for the same
reason: it would measure something other than the thing actually
defined):

```
FROZEN FORMULA (Rev.8 - direction-aware, floored at zero; unit conversion
unchanged since Rev.5; reference price unchanged since Rev.7):
   ENUM_POSITION_TYPE positionType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double downsideDistancePrice;
   if(positionType == POSITION_TYPE_BUY)
      downsideDistancePrice = MathMax(POSITION_PRICE_OPEN - POSITION_SL, 0.0);
      -- BUY: only a stop BELOW entry is downside risk. A stop AT or ABOVE
         entry (break-even or locked-in-profit trail) contributes 0.
   else // POSITION_TYPE_SELL
      downsideDistancePrice = MathMax(POSITION_SL - POSITION_PRICE_OPEN, 0.0);
      -- SELL: only a stop ABOVE entry is downside risk, mirrored.
   stop_loss_distance_price  = downsideDistancePrice
      -- entry price to CURRENT stop price (fresh POSITION_SL read, so a
         trailing stop's own movement is already captured). This is the
         ONLY economically correct measure of "money lost if this
         position's current stop is triggered" - see justification above,
         not a convention borrowed from RiskSizing.mqh's own unrelated
         pre-trade-sizing use case.
   stop_loss_distance_points = stop_loss_distance_price / SYMBOL_TRADE_TICK_SIZE
      -- tick_size normalization, same pattern RiskSizing.mqh's own Step 3
         uses, reused here because it is the correct unit conversion, not
         because RiskSizing uses it.
   position_risk_money       = stop_loss_distance_points * SYMBOL_TRADE_TICK_VALUE * POSITION_VOLUME
   open_risk_percent        += (position_risk_money / AccountInfoDouble(ACCOUNT_EQUITY)) * 100.0
      -- summed across every open position in scope, current equity used
         fresh every invocation.
```

**Fail-closed conditions (unchanged since Rev.2/Rev.3), restated against
the corrected formula**: ANY of the following causes the WHOLE invocation
to REJECT (no partial/best-effort exposure figure is ever used for a hard
cap decision) —
```
- any PositionGetDouble/PositionGetString field read fails for any open
  position in scope
- AccountInfoDouble(ACCOUNT_EQUITY) <= 0
- any in-scope position has POSITION_SL == 0 (no stop-loss - its true
  risk is unbounded/unknown, not zero; this function refuses to silently
  treat an unprotected position as contributing 0% risk)
- SYMBOL_TRADE_TICK_SIZE or SYMBOL_TRADE_TICK_VALUE for that position's
  own symbol is not positive - mirrors RiskSizing_ValidateInput()'s own
  identical guard, byte-for-byte
```

`ok == false` on any of the above -> the Decision Engine treats this
exactly like Check A/Check B's own `CHECK_FAILED` -> REJECT, for the
`max_concurrent_open_risk_percent` cap specifically (§3.2, unchanged) -
never silently substitutes a stale or partial figure.

---

### §2.4 The reserved system-automation identity — Rev.5 closed the partial-read gap; Rev.6 adds the environment_mode cross-check for symmetry with Check B

Unchanged since Rev.3: the reserved identity string
`MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY`, the amendment
scope (RATIFIED R13, Rev.14) (`GrantManualApprovalCommand()` only, DEMO-only since Rev.3, never
`LIVE_BOUNDED_AUTOMATION`), and the general shape of the stage-scoped
rejection (reject if `approver_identity == ` the reserved string AND fresh
`rollout_stage != DEMO_BOUNDED_AUTOMATION`).

**Blocker 3, exact gap**: Rev.3's own fail-closed proof covered TOTAL read
failure (`EventStore_ReadAllLines()` returning nothing, or a truncated
file with no `EXECUTION_ROLLOUT_STAGE_CHANGED` line at all) collapsing to
`ROLLOUT_STAGE_NONE`. It did **not** cover a genuinely PARTIAL read — a
file that IS internally corrupted (a malformed line, a sequence gap) but
still happens to CONTAIN a later, well-formed-looking `DEMO_BOUNDED_
AUTOMATION` transition line that `RolloutStageProjection_ReplayCurrent()`
would happily replay as current, with no way for that replay function
itself to know the file around it is untrustworthy.

**The fix, Rev.5 — the identical validated-single-read discipline §2.3.3
Check A already uses, applied here for consistency and because it
genuinely closes the gap**:

```cpp
// ratified (R13) amendment to GrantManualApprovalCommand() - stage
// check, Rev.7:
{
   string liveLines[];
   EventStore_ReadAllLines(g_EventStoreFileName, liveLines);
   ENUM_EXECUTION_ENVIRONMENT_MODE liveEnvMode = EnvironmentMode_ReadLive();
   // Same one-read-of-each discipline as SubmitOrderCommand's own Check A
   // (§2.3.3) - liveLines[] and liveEnvMode read once, together, reused
   // below - not a separate, differently-timed pair.

   if(ArraySize(liveLines) == 0)
   {
      CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED,
                            "reserved_identity_stage_check_failed", "event store read returned zero lines - unopenable or corrupted, never legitimate at DEMO_BOUNDED_AUTOMATION");
      return;   // Rev.7 fix, same as Check A (§2.3.3) - closes Round 6
                // Blocker 2 at this call site too, for the same reason:
                // a read failure and a genuinely empty store are
                // otherwise indistinguishable.
   }

   EventStoreValidationReport validation = EventStoreValidator_ValidateLines(liveLines);
   if(!validation.ok)
   {
      CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED,
                            "reserved_identity_stage_check_failed", validation.first_error);
      return;   // fail closed, unconditional - a malformed/partial store
                // is never trusted to authorize a system-issued grant,
                // even if a later line in it looks like a valid
                // DEMO_BOUNDED_AUTOMATION transition.
   }

   if(cmd.approver_identity == MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY)
   {
      ENUM_EXECUTION_ROLLOUT_STAGE liveCurrentStage;
      RolloutStageProjection_ReplayCurrent(liveLines, liveCurrentStage);
      // validation.ok == true was computed over this SAME liveLines[] -
      // no partial-read gap: a corrupted file with a stray later-looking
      // valid line now fails validation.ok before this replay ever runs.
      //
      // Rev.6, applied here for symmetry with SubmitOrderCommand's own
      // Check B (§2.3.3) - not explicitly named by QA against THIS
      // function in Round 5, but the identical stage-only gap QA found
      // in Check B applies equally here, and leaving this check
      // asymmetric would reintroduce the same class of gap at a second
      // call site.
      if(liveCurrentStage != ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION ||
         !RolloutStage_IsValidForEnvironment(liveCurrentStage, liveEnvMode))
      {
         CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED,
                               "reserved_identity_stage_not_bounded_automation", "");
         return;
      }
   }
   // Human-issued GRANT commands (approver_identity != the reserved
   // string) are unaffected - unchanged since Rev.3.
}
```

**Why this closes the gap precisely**: `EventStoreValidator_ValidateLines()`
checks every line's own parse validity, terminal-brace well-formedness,
schema version, AND per-session sequence contiguity (gaps/duplicates) over
the WHOLE array — a file with a corrupted/malformed EARLIER line now fails
`validation.ok` regardless of what a LATER line in the same array happens
to contain, closing exactly the Round 4 partial-read scenario QA named.
This mirrors Check A's own fix (§2.3.3) exactly, and inherits the same
"one read, validate the array you then replay" discipline. The added
`RolloutStage_IsValidForEnvironment(liveCurrentStage, liveEnvMode)` clause
(Rev.6) closes the same class of gap Round 5 Blocker 3 found in Check B —
stage alone is insufficient, the fresh (stage, environment_mode) pair must
itself be cross-valid — using the SAME one-read-of-each-source,
never-re-read discipline Round 5 Blocker 4 required, and the SAME already-
sealed cross-validity predicate, not a new one.

### §2.5 What this design explicitly does NOT grant (unchanged)

[Rev.15 AMENDMENT — D4-c: also not granted — any claim about model,
signal or market quality from C5 stub-AI candidates (§1.4).]

### §2.6 RA-31 amendment note — [Rev.15 AMENDMENT — D1, D2, F1 Rev.3 §4.3]

F1b (a mailbox left `PENDING`/`CLAIMED` while durable truth says the
command is finished) is a property of the sealed RA-31 protocol and
affects human ceremonies as well as automation. It is addressed by an
RA-31 amendment, not by the Decision Engine:

```
WHERE (D2): a new EA-side function in the claim path, called at the top
  of RA31_ProcessCeremonyCommand(), before CeremonyCommand_TryClaim().
  The Decision Engine never rewrites a mailbox it has not confirmed as
  its own (§2.3.2a is unchanged).

B1 - durable-mirror reconciliation (D1). Read the mailbox once. If its
  status is PENDING or CLAIMED for a command_id that the durable
  CeremonyCommandRegistry holds in a mailbox-terminal-equivalent state,
  rewrite the mailbox to the status Complete()/Fail() would have written:
    APPROVAL_RECORDED, ENTRY_COMPATIBILITY_EVALUATED, OUTCOME_RECORDED,
    ROLLOUT_STAGE_TRANSITIONED, KILL_SWITCH_ENGAGED, KILL_SWITCH_CLEARED,
    CEREMONY_READY, SUBMISSION_COMPLETE, OBSERVATION_COMPLETE -> COMPLETE
    COMMAND_FAILED                                           -> FAILED
    COMMAND_REJECTED                                         -> REJECTED
  Never touched: SUBMISSION_IN_PROGRESS (RA-31.2 condition B, human
  reconciliation), COMMAND_RECEIVED, CEREMONY_IN_PROGRESS, a command_id
  not in the registry, or an unavailable registry.

UNAMBIGUITY CONDITION (QA, F1 Rev.3 §4.3): a rewrite is allowed only
  when the durable registry gives ONE clear terminal truth for that exact
  command_id. Conflicting, duplicated, unavailable or otherwise ambiguous
  durable evidence -> B0. The routine never chooses between competing
  durable states.

B0 - everything else: automation pauses (discovery keeps returning
  MAILBOX_OCCUPIED) until a human reconciles the mailbox file, which
  RA-31.2's own doctrine already permits. No timeout, no lease, no TTL
  (a frozen TimeCurrent() while the market is closed makes any clock rule
  unsound). No SafeMode: F1b is transport-level.
```

This note fixes the contract requirement only. It is a change to sealed
RA-31 code and needs its own implementation authorization.

---

## §3. Bounded-Automation Caps — parameter/control model

### §3.1 Frozen shape, WITH RATIFIED starting values (R1–R9, Rev.14)

QA's Round 3 verdict asked for `N`, every `BoundedAutomationPolicy` value,
and the retcode mapping to be ratified before Freeze. Rev.4–Rev.13
proposed the values below; QA ratified every one exactly as proposed
(QA Round 13 / Ratification, recorded Rev.14). QA's scope note applies:
the ratification approves the policy/control contract, not the market
suitability of these values. Changing any of them later is a policy
amendment requiring QA's own explicit ratification, never an in-place
edit:

```cpp
struct BoundedAutomationPolicy
{
   string bounded_automation_policy_version;      // e.g. "BOUNDEDAUTO_C6_3_V1"

   double max_lot_size_per_submission;             // RATIFIED (R2): 0.01 (the broker's
                                                     // typical minimum - the smallest
                                                     // possible real-money exposure
                                                     // for a first automated rung)
   double max_daily_volume_lots;                   // RATIFIED (R3): 0.05 (5x the per-
                                                     // submission ceiling)
   int    max_submissions_per_day;                 // RATIFIED (R4): 3
   int    min_seconds_between_submissions;          // RATIFIED (R5): 3600 (1 hour cooldown -
                                                      // deliberately slow, first rung)
   double max_concurrent_open_risk_percent;         // RATIFIED (R6): 2.0 (2% of equity,
                                                      // account-wide, §2.3.4's scope)
   int    max_concurrent_open_positions;            // RATIFIED (R7): 2
   string symbol_allowlist;                          // RATIFIED (R8): the single symbol
                                                        // this EA already trades
                                                        // (_Symbol) - no multi-symbol
                                                        // automation until a future
                                                        // amendment explicitly widens it
   string strategy_allowlist;                          // RATIFIED (R8): empty (all frozen
                                                          // strategy_id values already
                                                          // gated by SafetyGate/
                                                          // EligibilityPolicy upstream)
   string session_window_server_time;                   // RATIFIED (R8): "" (no time-of-day
                                                           // restriction). This document
                                                           // does not design a restricted-
                                                           // hours shape; adding one later
                                                           // is a policy amendment needing
                                                           // QA's own explicit ratification
   string day_of_week_allowlist;                         // RATIFIED (R8): "" (same as above)
};
```

**`N` (§1.2/P1)**: RATIFIED `N = 5` (R1, Rev.14), with Rev.1's original
reasoning unchanged (a stricter bar than §6.1's `>= 3`, since §6.3
removes the last human checkpoint before automation).

**Retcode mapping**: superseded by §1.2a (Rev.12), which is now
exhaustive over the 21 retcodes the sealed classifier can map to
REJECTED, and classifies the asynchronous rejection path explicitly.
Changes from the Rev.3 proposal: `TIMEOUT` and `CONNECTION` removed
(unreachable - they never produce `CANDIDATE_REJECTED_BY_BROKER`);
`NO_MONEY`, `TOO_MANY_REQUESTS` and `MARKET_CLOSED` moved to
non-qualifying. Qualifying set RATIFIED (R9, Rev.14): `REQUOTE`,
`PRICE_CHANGED`, `PRICE_OFF`; the async path non-qualifying; every other
shape fail-closed.

### §3.2 Evaluation discipline — made explicit Rev.7 (closing Round 6 Blocker 1), scope regression reverted Rev.8 (closing Round 7 Blocker 4)

**Disclosure**: when §3.2 was filled in for the first time in Rev.7 (it
had been an unwritten "unchanged since Rev.3" placeholder through Rev.4-6),
it stated the three submission-counting caps below count "system-issued
AND human-issued both." This was **not a deliberate proposal** - it was
written without checking what scope Rev.2 had actually established, and
QA's Round 7 review correctly caught that this silently reversed Rev.2's
own decision (confirmed by QA's Round 2 verdict, which explicitly listed
"daily-cap automated-only scope" among what Rev.2 correctly closed).
**Reverted this revision** to the original automation-only scope:

```
max_submissions_per_day        : count of durable E1 lines (EVENT_TYPE_
                                  CEREMONY_COMMAND_STATE_CHANGED, to_state
                                  = SUBMISSION_IN_PROGRESS) whose own
                                  timestamp falls within the current
                                  calendar day (server time) AND whose
                                  INVARIANT PROV-1 classification is
                                  AUTOMATION (exactly one
                                  "submission_provenance" key, value
                                  exactly "SYSTEM_BOUNDED_AUTOMATION_V1") -
                                  AUTOMATION-ONLY, restored to Rev.2's own
                                  original scope. A human-issued submission
                                  (PROV-1 HUMAN) in DEMO_REAL_SUBMIT does
                                  NOT consume this cap's quota.

max_daily_volume_lots          : sum of volume across those SAME PROV-1
                                  AUTOMATION E1 lines, same day-window.

min_seconds_between_submissions: server-time gap since the MOST RECENT
                                  PROV-1 AUTOMATION E1 line's own
                                  timestamp - evaluated fresh, every
                                  invocation.

All three: one post-cutoff E1 that PROV-1 classifies INVALID makes the
whole cap evaluation CHECK_FAILED (PROV-1, R15). The classifier is
PROV-1 only; E1 carries no approver_identity key.

[Rev.14 text correction, no design change: until Rev.14 the first entry
above said "whose own recorded approver_identity (Rev.8 addition, below)
is the reserved system string". PROV-1 (Rev.13) withdrew that E1 key and
fixed the classifier as "submission_provenance"; the text now names
PROV-1.]

[MADE PRECISE Rev.11 - see §2.3.2a "E1/E2". "Submission-attempt line"
above means E1: EVENT_TYPE_CEREMONY_COMMAND_STATE_CHANGED with to_state =
SUBMISSION_IN_PROGRESS, the only line that carries provenance (the
"submission_provenance" token, INVARIANT PROV-1). It does NOT mean E2
(EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED), which carries no provenance.

Why E1 is the canonical source (RATIFIED R10, Rev.14):
  - provenance can only live on E1 without amending a third sealed file
    (E2 is written by the sealed BrokerSubmission_RecordAttempt(), outside
    this document's two-function scope);
  - it never undercounts automation's real broker attempts: for an
    automation-issued submission, every E2 is preceded by its own E1 in
    the same SubmitOrderCommand() call (MLQuantAI.mq5:1312-1323);
  - it additionally counts automation ceremonies a C2 gate rejected
    before any broker attempt (E1 is written before those gates run), so
    re-issuance after such a rejection is rate-limited by the cooldown
    and daily caps rather than retried every invocation - conservative.
    [Rev.15 AMENDMENT — D5: re-issuance after such a rejection no longer
    happens at all. The E1 makes the request AUTOMATION_EXHAUSTED
    (§2.3.2 step 1b), so at most one unit of daily quota is ever spent on
    a request that the post-E1 gates reject. The quota rule itself (what
    consumes quota, what does not) is unchanged.]

VOLUME: neither E1 nor E2 carries a lot size. max_daily_volume_lots uses,
for each counted E1 line, ExecutionRequestProjection_TryGet(<that line's
execution_request_id>).lot_size. If that lookup fails for any counted
line, the WHOLE cap evaluation this invocation is untrustworthy -> REJECT,
same disposition as Case B below (automation_cap_provenance_integrity_
violation) - never a guessed or zero volume.

Alternatives QA may prefer instead, each NOT silently adopted here: (i)
make E2 canonical, attributing provenance by joining each E2 to the E1
written immediately before it in the same call (no third sealed
amendment, more complex, and does not rate-limit gate-rejected
re-issuance); (ii) add provenance to E2 itself, which requires amending
BrokerSubmission_RecordAttempt() - a third sealed-file amendment outside
this document's current scope.]

#### INVARIANT BUD-1 — what the three submission caps limit (FROZEN, Rev.12, closing Round 11 Blocker 1; RATIFIED R10, Rev.14)

QA's Round 11 review pointed out that E1 and E2 mean different things,
while the cap names read as if they counted broker submissions. They do
not. This invariant states exactly what they count. [Rev.14: it was
conditional on QA ratifying E1 as the source (§7 item 18); E1 is now
RATIFIED (R10), so BUD-1 holds unconditionally.]

```
BUD-1. max_submissions_per_day, max_daily_volume_lots and
min_seconds_between_submissions limit AUTOMATION ISSUANCE, not broker
attempts. Their unit is the E1 line, and nothing else:

  UNIT: one E1 line (EVENT_TYPE_CEREMONY_COMMAND_STATE_CHANGED, to_state =
  SUBMISSION_IN_PROGRESS) that INVARIANT PROV-1 classifies AUTOMATION.
  Any INVALID E1 fails the whole evaluation (PROV-1). E1 is the canonical automation-issuance budget event. It is NOT
  a broker-attempt event.

  CONSUMES QUOTA - an automation-issued SUBMIT_ORDER that was claimed and
  got past SubmitOrderCommand()'s own checks up to the E1 write
  (MLQuantAI.mq5:1312), whatever happens after:
    - a C2 gate (SafetyGate, BrokerSubmissionGate incl. SA-1,
      EnvironmentLock, EntryCompatibility, margin guard, request build)
      rejects it before any E2 -> quota consumed, no broker attempt;
    - it reaches E2 and OrderSend(), with any outcome -> quota consumed.

  DOES NOT CONSUME QUOTA - no E1 was ever written:
    - WRITE_FAILED / LOST issuance (§2.3.2b): never claimed;
    - claimed, but rejected before E1 by Check A (kill switch), Check B
      (stage x environment), RA-31.2 condition B (unresolved submission),
      or an ExecutionRequest/candidate lookup failure;
    - claimed, but the E1 write itself failed (submission_in_progress_
      log_failed, MLQuantAI.mq5:1316) - nothing durable was produced;
    - any human-issued SUBMIT_ORDER (its E1 is classified HUMAN by
      PROV-1: "submission_provenance" == "HUMAN") - automation-only
      scope, restored in Rev.8. [Rev.14 text correction: until Rev.14
      this line said "its E1 carries a non-reserved approver_identity";
      superseded by PROV-1 (Rev.13), no design change.]

  VOLUME: per counted E1, ExecutionRequestProjection_TryGet(<its
  execution_request_id>).lot_size = volume REQUESTED by an automation
  ceremony, not volume filled. Lookup failure -> whole cap evaluation
  REJECT (automation_cap_provenance_integrity_violation).

  COOLDOWN: min_seconds_between_submissions is measured from the most
  recent counted E1's own timestamp.

  BOUND ON BROKER ATTEMPTS: for automation, every E2 is preceded by its
  own E1 in the same SubmitOrderCommand() call (BrokerSubmission_Submit()
  has one production caller, which writes E1 first, MLQuantAI.mq5:
  1312-1323). So automation's actual broker attempts per day <= the E1
  count <= max_submissions_per_day, and the same holds for requested
  volume. The caps are therefore also a strict upper bound on broker-
  facing activity - conservative by construction.
```

**If QA instead wants the caps to limit actual broker attempts**, the
unit must be E2, and E2 must carry provenance. That requires either a
join from each E2 to the E1 immediately preceding it in the same call, or
a third sealed-file amendment to `BrokerSubmission_RecordAttempt()`
(§3.2's alternatives (i)/(ii)). The cap names would then mean "broker
attempts," and gate-rejected re-issuance would no longer be rate-limited
by them. BUD-1 is frozen only for the E1 choice; the E2 choice would
replace it.

max_concurrent_open_positions /
max_concurrent_open_risk_percent : NOT EventStore-sourced at all - read
                                  fresh from live broker state every
                                  invocation via §2.3.4's own
                                  BoundedAutomation_ReadFreshExposure()
                                  (PositionsTotal()/PositionGetDouble() -
                                  unchanged since Rev.2/Rev.3; account-wide,
                                  so this pair is NOT automation-scoped -
                                  a deliberately different, wider scope
                                  than the three submission-counting caps
                                  above, unchanged since Rev.2/Rev.3).
```

**The mechanism this scope restoration now requires, traced this
revision**: distinguishing "automation-only" durably requires the
submission-attempt line itself to carry provenance - which it does not
today. `EventStore_LogCeremonyCommandState()`'s own call site inside
`SubmitOrderCommand()` (confirmed by direct read, `MLQuantAI.mq5:1312-1314`)
passes 6 of the function's 7 parameters, omitting the trailing, already-
optional `extraJson` parameter (confirmed present in the sealed function's
own signature, `MLQuantAI_CeremonyCommandEventEmission.mqh:280-282`,
`string extraJson = ""`, appended verbatim into the durable event's own
JSON body when non-empty). **Rev.8 proposes threading `cmd.approver_
identity` through this EXISTING, already-optional parameter at this ONE
call site** - not a change to the sealed function's own signature or
logic, only to what this document's own already-in-scope `SubmitOrderCommand()`
amendment passes into an existing extension point:

```cpp
// amendment to SubmitOrderCommand()'s own existing durable pre-commit
// marker call (MLQuantAI.mq5:1312-1314) - Rev.8, closing Round 7 Blocker 4;
// field REPLACED Rev.13 by a canonical two-token class (INVARIANT PROV-1).
// cmd.approver_identity is NEVER copied through: only one of two fixed
// tokens is ever written.
string provenanceToken = (cmd.approver_identity == MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY)
                            ? MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY
                            : "HUMAN";
if(!EventStore_LogCeremonyCommandState(cmd.command_id, cmd.command_type,
                                        CEREMONY_STATE_COMMAND_RECEIVED, CEREMONY_STATE_SUBMISSION_IN_PROGRESS,
                                        "submitting", rec.execution_request_id,
                                        "\"submission_provenance\":\"" + provenanceToken + "\""))
{
   CeremonyCommand_Fail(cmd, CEREMONY_STATE_COMMAND_RECEIVED, "submission_in_progress_log_failed", "");
   return;
}
```

§3.2's own cap-counting scan (above) then classifies this SAME durably-
recorded `submission_provenance` field per INVARIANT PROV-1 (Rev.13 -
formerly `approver_identity`) when counting toward the three
submission-scoped caps - the same raw-scan-a-JSON-field technique already
used throughout this document (§1's P8, Rev.8's own Check B addition
above), applied at a third call site for a third purpose.

**FROZEN RULE (closing Round 6 Blocker 1, unchanged in spirit this
revision)**: every durable-evidence-sourced cap above counts ONLY lines
that actually exist in the EventStore, matching the scope frozen above -
a command that was `WRITE_FAILED` or `LOST` (§2.3.2b) produces no such
line and is therefore invisible to, and never counted by, any of these
caps. No in-memory "attempted issuance" counter is read by, added to, or
consulted by any cap evaluation in this design - caps are pure functions
of durable EventStore content (plus, for the concurrent-exposure caps,
fresh live broker state), re-evaluated from scratch every invocation,
never of any Decision-Engine-internal bookkeeping.

**[HISTORICAL — the classifier below is SUPERSEDED by INVARIANT PROV-1
(Rev.13, ratified R14/R15). E1 carries no `approver_identity` key; the
only authoritative classifier is PROV-1's `submission_provenance`. The
Rev.9 text is kept for the audit trail; Case A survives inside PROV-1
unchanged.]**

**Rev.9, closing Round 8 Blocker 3 — `approver_identity` frozen as
canonical automation-cap provenance, with explicit fail-closed semantics
for missing/malformed provenance**: QA's own concern, stated precisely -
if a future implementation silently treats an ambiguous/missing
`approver_identity` as "human" (excluded from the cap), that is FAIL-OPEN
for the cap, because a genuinely system-issued submission whose own
provenance field was somehow lost would then escape being counted against
automation's own daily budget entirely. This document must not leave that
choice to implementation.

**The freeze, in two cases, distinguished by evidence, not by guess**:

```
CASE A - the line PRE-DATES this mechanism (its own timestamp is EARLIER
than the FIRST-EVER EXECUTION_ROLLOUT_STAGE_CHANGED(to_stage=DEMO_
BOUNDED_AUTOMATION) line in this SAME EventStore - found via a raw scan
of the SAME liveLines[]/durable history already available, no new read):
   -> a MISSING approver_identity field on such a line is EXPECTED, not
      an anomaly - this document's own SubmitOrderCommand() amendment is
      the ONLY code path that has ever populated this field, and that
      amendment cannot have run before DEMO_BOUNDED_AUTOMATION was first
      reached (nothing in this whole document is authorized before then).
      A line predating that point could not possibly be automation-
      issued, REGARDLESS of whether its own field is present - excluded
      from the automation-only cap count. Not a guess: a structural
      impossibility ruled out by construction, not by trusting an absent
      field's own honesty.

CASE B - the line POST-DATES that first transition (§7 item 3's own
frozen candidate-scan-order precedent already establishes durable event
ordering as reliable for exactly this kind of "before/after" comparison):
   -> a MISSING or MALFORMED approver_identity field here IS a genuine
      anomaly - by this document's own frozen invariant (§3.2, above),
      EVERY SubmitOrderCommand() call from this point forward
      unconditionally populates this field (empty string for a
      human-issued command, the reserved string for a system-issued one -
      never omitted). A line in this window lacking it, or carrying a
      value that fails to parse as a plain string, means something has
      violated that invariant (a future refactor error, corruption, or a
      genuinely unexpected condition this document has not anticipated) -
      NOT classified as human, NOT classified as system, NOT silently
      excluded. The WHOLE cap evaluation for max_submissions_per_day /
      max_daily_volume_lots / min_seconds_between_submissions this
      invocation is treated as untrustworthy -> REJECT (no automatic
      issuance this invocation), with an explicit diagnostic reason code
      (proposed: automation_cap_provenance_integrity_violation),
      matching the SAME CHECK_FAILED discipline already established for
      every other "cannot trust this data" condition in this document
      (Check A/B's own zero-lines and validation-failure rows, §4).
```

**Why this is not fail-open in either direction**: Case A never silently
trusts an absent field to mean "not automation" - it independently proves
automation could not have produced the line, using durable ordering
evidence, not the field's own (missing) content. Case B never guesses a
classification for a field that should exist but doesn't - it refuses to
compute the cap at all rather than pick a side, exactly mirroring how
Check A/B already refuse to trust `KillSwitchProjection_ReplayActive()`'s
own replay over unvalidated data. A value that IS present but is simply
NOT the reserved string (the ordinary human-submission case, `cmd.
approver_identity == ""` by today's existing default) is neither of the
above - it is definitively classified as non-automation, unambiguously,
with no fail-closed concern at all.

[SUPERSEDED Rev.13 by INVARIANT PROV-1, below. Two flaws in the Case B
text above, found while closing Round 12 Blocker 1: (1) it relied on a
human E1 carrying an EMPTY string, but EventSerializer_GetStr() returns ""
both for an empty value and for a MISSING key (MLQuantAI_EventSerializer.
mqh:61-64), so "human" and "missing" were indistinguishable; (2) it
classified any present, non-reserved value as human, so an unknown or
garbled value silently counted as human - the fail-open case QA named.
Case A (pre-cutoff lines) is kept unchanged inside PROV-1.]

#### INVARIANT PROV-1 — canonical E1 provenance and its deterministic classification (FROZEN, Rev.13, closing Round 12 Blocker 1; writer RATIFIED R14, halt semantics RATIFIED R15, Rev.14)

```
PROV-1 (WRITER). Every E1 written by SubmitOrderCommand() carries exactly
one extraJson key, "submission_provenance", whose value is exactly one of
two fixed tokens:
   "SYSTEM_BOUNDED_AUTOMATION_V1"  iff cmd.approver_identity is exactly the
                                   reserved string;
   "HUMAN"                         otherwise.
The issuer's free text is never copied into E1. This matters because no
human SUBMIT_ORDER issuer exists in this repository (only GrantApproval,
EvaluateEntryCompatibility and AcknowledgeAudit manual scripts exist), so
the content of a human command's approver_identity is uncontrolled; the
writer, not the issuer, fixes the value set. The old "approver_identity"
E1 key (Rev.8-Rev.12 proposal, never implemented) is withdrawn.

PROV-1 (READER). The cap evaluation (BUD-1) and P8b classify each E1 line
L - type == CEREMONY_COMMAND_STATE_CHANGED and to_state ==
"SUBMISSION_IN_PROGRESS" - read from the same validated, non-empty
snapshot (a structurally malformed line already fails
EventStoreValidator_ValidateLines() -> the invocation issues nothing):

  CASE A: L's timestamp is earlier than the first-ever
    EXECUTION_ROLLOUT_STAGE_CHANGED(to_stage = DEMO_BOUNDED_AUTOMATION) in
    the snapshot -> PRE-MECHANISM: not counted, whatever it contains
    (unchanged from Rev.9: automation cannot have produced it).

  CASE B: otherwise, let k = number of occurrences of the exact substring
    "\"submission_provenance\":" in L, and v = EventSerializer_GetStr(L,
    "submission_provenance"):
      k == 1 AND v == "SYSTEM_BOUNDED_AUTOMATION_V1"  -> AUTOMATION
      k == 1 AND v == "HUMAN"                        -> HUMAN
      anything else - k == 0 (missing), k >= 2 (duplicate field), any
      other v including "" (unknown/garbled)          -> INVALID
    Additionally, EventSerializer_GetStr(L, "execution_request_id") must
    be non-empty, else INVALID; and for an AUTOMATION line,
    ExecutionRequestProjection_TryGet(<that id>) must succeed (BUD-1's
    volume lookup), else INVALID.

  INVALID is neither HUMAN nor AUTOMATION. One INVALID E1 anywhere at or
  after the cutoff makes the WHOLE cap evaluation CHECK_FAILED -> REJECT,
  no automatic issuance, reason automation_cap_provenance_integrity_
  violation. The scope is deliberately "every post-cutoff E1", not "today
  only", because min_seconds_between_submissions may depend on an E1 from
  an earlier day: an unreadable line could hide the most recent
  automation issuance. Consequence, stated explicitly: one INVALID E1
  halts automatic issuance until a human reconciles the EventStore - no
  automatic recovery is defined or authorized.

  No implementer may "ignore the line", "treat it as human" or "treat it
  as automation": INVALID has exactly one outcome.

  IMPLEMENTATION CONSTRAINT (added after QA Round 13): the classification
  MUST compute k by counting occurrences of the exact substring
  "\"submission_provenance\":" in L. EventSerializer_HasKey() alone
  (a single StringFind >= 0, MLQuantAI_EventSerializer.mqh:111-114) and
  EventSerializer_GetStr() alone (first occurrence only) are both
  FORBIDDEN as the classifier - either would reintroduce the
  duplicate-key case. Validity is exactly: k == 1 AND v is one of the two
  tokens.
```

### §3.3 Interaction with existing controls (unchanged)

---

## §4. Fail-Closed table (Rev.11–Rev.13 new/changed rows)

| Situation | Outcome |
|---|---|
| Any `SUBMIT_ORDER` (any caller) for an `execution_request_id` with a prior attempt made in the CURRENT session, whatever that attempt's outcome | rejected `REASON_DUPLICATE_EVENT` by SA-1 (a), `BrokerSubmissionGate_HasAlreadyAttempted()`, before `RecordAttempt()`/`OrderSend()` **(attribution corrected Rev.11 — Rev.10 named SA-1 (c))** |
| Same, for a prior attempt made in any EARLIER session | rejected `REASON_DUPLICATE_EVENT` by SA-1 (c), `SubmissionAttemptRegistry_HasAttempt()` **(SA-1, Rev.11)** |
| Audit registry not successfully rebuilt this session | EVERY submission rejected `REASON_EXECUTION_AUDIT_NOT_READY` — SA-1 (0) |
| `OrderSend()==false` (ERROR), then a resubmission of the SAME `execution_request_id` | rejected by SA-1 — `candidate.state` still permits it, SA-1 does not; a retry needs a NEW `execution_request_id`, not created or authorized here **(Rev.9 statement corrected, Rev.11)** |
| `SubmitOrderCommand` Check B, condition 2: ANY system-issued grant record (no time filter) for this `execution_request_id`, AND stage × environment fails | `CEREMONY` fails — `automated_submission_stage_no_longer_bounded_automation` **(predicate narrowed Rev.11, MA-1)** |
| A system-issued grant is durably in the EventStore but absent from the registry (the RA-30.4 branch) | it is unspendable: the C2 gate reads the same registry, so it rejects `REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED` unless a valid human grant exists **(MA-1, Rev.11 — replaces Rev.10's unconditional-freshness claim)** |
| Manual-approval registry startup rebuild fails | readiness false → the C2 gate rejects EVERY submission (`REASON_EXECUTION_AUDIT_NOT_READY`) — MA-2 post-restart semantics |
| Decision Engine's own step-1 read: zero lines, or `EventStoreValidator_ValidateLines().ok == false` | Decision Engine issues nothing this invocation **(new, Rev.11)** |
| Counted E1 line whose `execution_request_id` has no `ExecutionRequestProjection` record (volume unobtainable) | WHOLE cap evaluation this invocation → REJECT (`automation_cap_provenance_integrity_violation`), never a guessed or zero volume **(new, Rev.11)** |
| `OrderSend()` succeeds AND the durable `CANDIDATE_SUBMITTED` transition write fails | SafeMode trips, `candidate.state` stays `CANDIDATE_CREATED`; any later duplicate is rejected by SA-1 (Rev.10) |
| Automation-issued `SUBMIT_ORDER` reaches the E1 write, then any C2 gate rejects it before E2 | no broker attempt; one unit of `max_submissions_per_day` quota consumed, cooldown restarts **(BUD-1, Rev.12)** |
| Automation-issued `SUBMIT_ORDER` rejected before E1 (Check A/B, RA-31.2 condition B, lookup failure, failed E1 write) | no quota consumed **(BUD-1, Rev.12)** |
| In-window E1 classified AUTOMATION by PROV-1 (§6.3 evidence gate) | REJECT `unexpected_automated_submission_in_window` **(P8b, new Rev.12; RATIFIED R12)** |
| In-window `CANDIDATE_REJECTED_BY_BROKER` whose outcome record shows `submission_status == SUBMITTED` (async C3.10B path) | does NOT count toward P1 **(§1.2a, Rev.12)** |
| In-window sync rejection with a retcode outside `REQUOTE`/`PRICE_CHANGED`/`PRICE_OFF`, or no/unknown outcome record | does NOT count toward P1 (fail-closed default) **(§1.2a, Rev.12)** |
| Post-cutoff E1 with `submission_provenance` missing, duplicated, or any value other than the two tokens, or with an empty `execution_request_id` | INVALID → whole cap evaluation CHECK_FAILED → no automatic issuance (`automation_cap_provenance_integrity_violation`); automation stays halted until human reconciliation **(PROV-1, Rev.13)** |
| In-window E1 classified INVALID (§6.3 evidence gate) | REJECT `e1_provenance_invalid_in_window` **(P8b via PROV-1, Rev.13)** |
| System grant for X durable in the EventStore but absent from the projection (RA-30.4 branch), any `SUBMIT_ORDER` for X outside `DEMO_BOUNDED_AUTOMATION × DEMO` | rejected by SG-1 itself at claim time, before E1 **(SG-1 source, Rev.13)** |
| Request not ADMISSIBLE (no/any non-ACCEPTED dry-run record, lot > R2, symbol or strategy not allowlisted, or FIXTURE per M1 ∨ M2) | skipped by discovery, never selected **(Rev.15, D3/D4)** |
| Request with an AUTOMATION E1 and no E2 | AUTOMATION_EXHAUSTED → skipped permanently by automation; human manual ceremony unaffected **(Rev.15, D5)** |
| Record with an empty `execution_request_id`, or a candidate whose §2.3.2 state is UNKNOWN | scan stops, nothing issued this invocation **(Rev.15, D6)** |
| `CeremonyCommandRegistry_HasUnresolvedSubmission()` true, or candidate / candidate-state lookup fails for the selected request | no SUBMIT_ORDER issued this invocation (pre-flight parity) **(Rev.15, D7)** |
| Mailbox `PENDING`/`CLAIMED` with one unambiguous terminal durable state for that `command_id` | EA claim path rewrites the mailbox to the mirrored terminal status (B1) **(Rev.15, D1/D2)** |
| Mailbox occupied in any other way, or ambiguous durable evidence | B0: automation pauses until human reconciliation; no timeout, no SafeMode **(Rev.15, D1)** |
| C5 pipeline started with `InpC5ExecutionPolicyVersion` == `"EXECPOLICY_C2_SMOKE_V1"` | not permitted (reserved value); enforcing mechanism is an implementation item **(Rev.15, D4-b)** |
| All Rev.1–Rev.10 rows not listed above | unchanged |

---

## §5. Authority Boundary (unchanged)

## §6. Interaction with §6.1/§6.2 (unchanged)

---

## §7. Open items

1. ~~**`N`**~~ — **RATIFIED `N = 5` (R1, Rev.14).**
2. ~~**`BoundedAutomationPolicy` values**~~ — **RATIFIED as proposed
   (R2–R8, Rev.14)**: 0.01 / 0.05 / 3 / 3600 / 2.0 / 2 / `_Symbol` /
   "" / "" / "".
3. ~~Deterministic candidate scan order~~ — **RESOLVED Rev.6**:
   moved out of open items and FROZEN as §2.3.1a, per QA's Round 5
   request ("ผมแนะนำให้ Freeze ก่อน implementation ด้วย"). Until Rev.14
   it still required QA's own explicit ratification.
   **RATIFIED (R16, Rev.14)**: QA's Final Design Freeze Review named
   it as a separate item and ratified it as a design-shape decision
   (which eligible candidate claims the single mailbox slot); the
   defined ordering is unchanged.
4. Exact OnTick/OnTimer call-site placement — implementation detail.
5. Exact function/field names not yet independently verified against the
   real sealed surface: `MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY`'s
   own constant name/location; the fresh `command_id` generation helper
   used in §2.3.2a. **Narrowed this revision**: the former concern about
   Check B condition 2's own GRANT-event parse helper is resolved (item
   14, below) - it no longer parses `liveLines[]` at all, so no such
   helper is needed.
6. Dedicated event-type marker — still optional, not required.
7. ~~Rejected-candidate re-evaluation cadence~~ — **RESOLVED by Rev.15**:
   a request rejected after E1 is AUTOMATION_EXHAUSTED (D5); a request
   rejected before E1 is prevented by pre-flight parity (D7); a statically
   inadmissible request is skipped (D3/D4).
8. ~~**§2.4's `GrantManualApprovalCommand` amendment**~~ — **RATIFIED
   (R13, Rev.14)** as a Class 2 amendment to sealed code: three checks
   (validated-read precondition, stage-scoped rejection, environment_mode
   cross-validity added Rev.6). Ratified as design only; implementation
   NOT AUTHORIZED (§8).
9. ~~**§2.3.3's `SubmitOrderCommand` amendment (Checks A and B together,
   plus the E1 `extraJson` provenance field)**~~ — **RATIFIED (R14,
   Rev.14)** as a Class 2 amendment to sealed code, design only,
   implementation NOT AUTHORIZED (§8);
   Check A unchanged since Rev.7 (single validated read of `liveLines[]` +
   `liveEnvMode`, zero-lines fail-closed); Check B condition 1 unchanged
   since Rev.6; Check B condition 2's predicate narrowed Rev.11 (item 19);
   the E1 provenance field replaced Rev.13 by `submission_provenance`
   (INVARIANT PROV-1, two fixed tokens).
10. ~~Exhaustive retcode mapping~~ — exhaustive and source-evidenced
    (§1.2a, Rev.12), **RATIFIED (R9, Rev.14)**. QA's Round 4 question is
    answered: `TIMEOUT`/`CONNECTION` are unreachable for P1 and removed;
    `NO_MONEY`/`TOO_MANY_REQUESTS` are reachable and non-qualifying;
    `MARKET_CLOSED` is non-qualifying (a change from Rev.3); the async
    rejection path is non-qualifying; every other shape is fail-closed.
11. **§2.3.2a's write-time confirmation protocol** — the fresh
    `command_id` uniqueness mechanism and the exact
    `CeremonyCommand_Init()`/field-population call sequence are
    implementation detail, not yet written out statement-by-statement;
    the PROTOCOL shape (occupancy check -> write -> read-your-own-write
    confirm, with §2.3.2b's own frozen liveness/accounting semantics for
    the losing side of a race) is the frozen part of this proposal.
12. ~~`BoundedAutomation_ReadFreshExposure()`'s exact reference price~~ —
    **RESOLVED Rev.7 (§2.3.4)**: frozen as entry-to-current-SL,
    with an economic justification (Round 6 Blocker 3), not merely a
    convention citation. Until Rev.14 it still required QA's own
    explicit ratification.
    **RATIFIED (R17, Rev.14)**: QA's Final Design Freeze Review named
    it as a separate item and ratified the existing shape: reference
    price entry → current SL, the already-described directional formula,
    fresh `POSITION_SL`. No change to the formula or its justification.
13. **The residual, non-atomic check-then-write window in §2.3.2a** —
    explicitly accepted as a bounded, liveness-safe residual risk
    (option C, per QA's own Round 5 framing), not eliminated. Narrowed by
    Round 7/8/9's own resolution: the race can still determine WHICH of
    two commands gets claimed first (a liveness/ordering question), but
    can no longer produce a DUPLICATE broker submission (a correctness
    question) - INVARIANT SA-1 (§2.3.2a, Rev.11) closes that half
    unconditionally, for every outcome and across sessions, independent
    of `candidate.state`; the `candidate.state != CANDIDATE_CREATED`
    precondition remains an additional, earlier layer for the ordinary
    case. If QA
    still prefers option (B) - an atomic/exclusive mailbox write mechanism
    - for the ordering question specifically, that would require a THIRD
    sealed-file amendment (`CeremonyCommandMailbox_Write()` itself)
    outside this document's current scope.
14. ~~`ManualApprovalGrantedEvent`'s exact field list~~ — **RESOLVED this
    revision**: Check B condition 2 (§2.3.3) no longer parses raw
    EventStore lines at all - it reads `ManualApprovalProjectionRecord`
    via the already-existing, already-verified `ManualApprovalProjection_
    Count()`/`_GetAt()` accessors (confirmed present, `MLQuantAI_
    ManualApprovalProjection.mqh:76-100`), whose own field list
    (`execution_request_id`, `approver_identity`, `approval_timestamp`,
    `approval_expiry`, confirmed present, same file lines 41-58) is
    independently verified this revision, not assumed.
15. **`ManualApprovalProjection_GetAt()`'s own iteration cost** (new,
    Rev.9) — Check B condition 2 now iterates `ManualApprovalProjection_
    Count()` on every `SUBMIT_ORDER` claim; this registry's own typical
    size (bounded by how many grants have ever been issued, across the
    whole EventStore's lifetime) has not been characterized against
    realistic volumes - implementation detail, not architecturally
    load-bearing, but named explicitly since Rev.8's own version would
    have iterated `liveLines[]` (the WHOLE EventStore) instead, which is
    strictly larger - this revision's approach is a performance
    improvement over Rev.8's, not a new cost.
16. **`automation_cap_provenance_integrity_violation`'s exact reason-code
    string and where it surfaces** (new, Rev.9, §3.2) — the diagnostic
    condition itself is frozen (Round 8 Blocker 3); the precise
    string constant and whether it is logged via `CeremonyCommand_Fail`
    or a separate diagnostic path (since cap evaluation is not itself a
    `CeremonyCommand`-scoped check the way Check A/B are) is
    implementation detail.
17. **`SafeMode` does not gate ceremony-command dispatch itself** (new,
    Rev.10, observed while closing Round 9 Blocker 1) — confirmed the
    only `SafeMode_IsActive()` call site in `MLQuantAI.mq5` gates NEW
    candidate eligibility (`MLQuantAI.mq5:1755`), not `RA31_
    ProcessCeremonyCommand()`'s own claim/dispatch loop. This document's
    own duplicate-safety proof does not depend on SafeMode blocking
    further dispatch - SA-1 is sufficient on its own - but a human
    operator relying on "SafeMode tripped, so nothing else will happen"
    as an OPERATIONAL assumption would be wrong. Not a blocker; named so
    it is not silently assumed elsewhere.
18. ~~**E1 as the canonical cap-accounting source**~~ (new, Rev.11;
    semantics frozen Rev.12 as INVARIANT BUD-1, §3.2) — **RATIFIED (R10,
    Rev.14)**, and with it BUD-1: E1 is an automation-issuance budget
    event, not a broker-attempt event, and the caps limit automation
    issuance, not broker attempts. QA's Round 8 verdict named
    `EXECUTION_SUBMISSION_ATTEMPTED` (E2) as canonical; this document
    proposes E1 instead because provenance can only live on E1 within the
    two-sealed-function scope, and explains two alternatives (§3.2). This
    is a disclosed correction of this document's own loose naming since
    Rev.2, not a silent substitution.
19. ~~**INVARIANT SG-1**~~ (predicate new Rev.11; frozen as an invariant
    Rev.12, §2.3.3) — **RATIFIED (R11, Rev.14)**, including its Rev.13
    authoritative source: the validated durable snapshot ∪ the
    projection. The time-filtered alternative in §2.3.3 is therefore
    not adopted.
20. ~~§1's text not reproduced in this file~~ — **RESOLVED Rev.12**: §1 is
    restored in full and reconciled; each predicate names one canonical
    source. New P8b (E1 check) is **RATIFIED (R12, Rev.14)**.
21. **Regression tests proposed for the future Test Authorization phase**
    (not authorized now): REJECTED- and ERROR-outcome variants of
    `MLQuantAI_Test_C2_BrokerSubmissionGate_DurableIdempotency.mq5:378`
    (SA-1); the three MA-1 tests listed in §2.3.3 (rollback + human
    SUBMIT; RA-30.4 lag branch; structural writer check); an E1/E2
    attribution test for the automation-only caps (§3.2); BUD-1 cases (a
    gate-rejected automation SUBMIT consumes quota; a Check-B-rejected one
    does not); §1.2a cases (sync REJECTED per bucket; async
    REJECTED_BY_BROKER non-qualifying); P8b.

**Ratification register — ALL RATIFIED, R1–R17** (R1–R15: QA Round 13 /
Ratification, "RATIFICATION COMPLETE — ALL R1–R15 APPROVED"; R16–R17:
QA §6.3 Final Design Freeze Review of Rev.14; recorded Rev.14,
2026-09-26). Every decision is ratified exactly as already written;
none changes design content.

| # | Decision | Ratified | Where | Status |
|---|---|---|---|---|
| R1 | `N` for P1 | 5 | §1.2, §3.1 | **RATIFIED** |
| R2 | `max_lot_size_per_submission` | 0.01 | §3.1 | **RATIFIED** |
| R3 | `max_daily_volume_lots` | 0.05 | §3.1 | **RATIFIED** |
| R4 | `max_submissions_per_day` | 3 | §3.1 | **RATIFIED** |
| R5 | `min_seconds_between_submissions` | 3600 | §3.1 | **RATIFIED** |
| R6 | `max_concurrent_open_risk_percent` | 2.0 | §3.1 | **RATIFIED** |
| R7 | `max_concurrent_open_positions` | 2 | §3.1 | **RATIFIED** |
| R8 | `symbol_allowlist` / `strategy_allowlist` / `session_window_server_time` / `day_of_week_allowlist` | `_Symbol` / "" / "" / "" | §3.1 | **RATIFIED** |
| R9 | P1 retcode mapping + async-path classification | qualifying = `REQUOTE`, `PRICE_CHANGED`, `PRICE_OFF` only; async path non-qualifying; every other shape fail-closed | §1.2a | **RATIFIED** |
| R10 | E1 as cap source (= BUD-1) | E1 = automation-issuance budget event, not a broker-attempt event | §3.2 | **RATIFIED** |
| R11 | SG-1, including its Rev.13 authoritative source | validated durable snapshot ∪ projection | §2.3.3 | **RATIFIED** |
| R12 | P8b | as written | §1.2 | **RATIFIED** |
| R13 | Class 2 amendment: `GrantManualApprovalCommand()` | §2.4 as written | §2.4 | **RATIFIED** (design only) |
| R14 | Class 2 amendment: `SubmitOrderCommand()` (Checks A/B incl. the SG-1 snapshot scan; E1 `submission_provenance` per PROV-1) | §2.3.3, §3.2 as written | §2.3.3, §3.2 | **RATIFIED** (design only) |
| R15 | PROV-1 halt semantics | one INVALID post-cutoff E1 halts automatic issuance until human reconciliation; no automatic recovery | §3.2 | **RATIFIED** |
| R16 | Deterministic candidate scan order (which eligible candidate claims the single mailbox slot) | as written, ordering unchanged | §2.3.1a | **RATIFIED** (Final Design Freeze Review) |
| R17 | `BoundedAutomation_ReadFreshExposure()` reference price | entry price → current SL, the already-described directional formula, fresh `POSITION_SL` | §2.3.4 | **RATIFIED** (Final Design Freeze Review) |

**Scope of the ratification (QA's note, recorded)**: R1–R17 approve the
policy/control contract only. They do not assert that the values are
suitable for the market. R13 and R14 ratify the design of two Class 2
amendments to sealed code; they authorize no source change, compile,
test, commit or push (§8). R16 and R17 (§7 items 3 and 12) ratify
existing frozen shapes, not new implementation requirements.

**Rev.15 amendment register** — every item is already RATIFIED in F1
Liveness Disposition Rev.3 (FROZEN, `16189be`). Rev.15 only writes them
into this contract. The Rev.15 text itself awaits QA's amendment freeze.

| # | Ratified in F1 Rev.3 | Where in Rev.15 |
|---|---|---|
| D1 | B1 durable-mirror + B0, with the unambiguity condition | §2.6, §4 |
| D2 | B1 in the EA claim path | §2.6 |
| D3 | A1 static admissibility — skip, not stop | §2.3.1 (a)-(d), §2.3.1a, §4 |
| D4 | FIXTURE(X) ⇔ M1(X) OR M2(X) → inadmissible → skip | §2.3.1 (e), §4 |
| D4-b | `"EXECPOLICY_C2_SMOKE_V1"` reserved; C5 must not accept it | §2.3.1, §4 |
| D4-c | C5 stub candidates = plumbing/control evidence only | §1.4, §2.5 |
| D5 | A2 one automated SUBMIT per request → AUTOMATION_EXHAUSTED | §2.3.2 step 1b, SA-1 note, BUD-1 note, §4 |
| D6 | UNKNOWN stops the scan | §2.3.1a, §4 |
| D7 | C1 pre-flight parity; GRANT option (i); C2 not authorized | §2.3.2b, §4 |
| D8 | Rev.15 + RA-31 amendment note as the vehicle | this revision, §2.6 |
| D9 | F1c is a Wave 3 blocker | §2.3.2b |

**Rev.15 precision notes — for QA's explicit confirmation.** Writing the
ratified decisions as contract text needed these choices, which the
decisions did not state:

- **P-1 (symbol source for D3).** Neither `ExecutionRequestProjectionRecord`
  nor `CandidateProjectionRecord` carries a symbol. The only durable
  per-request symbol is `DryRunResultProjectionRecord.observed_symbol`
  (`MLQuantAI_ExecutionAuditProjection.mqh:166`), taken from the same
  dry-run record that (a) already requires. Rev.15 uses it.
- **P-2 (strategy lookup for D3).** R8's `strategy_allowlist = ""` admits
  every `strategy_id`, so (d) needs no lookup under the ratified values.
  A lookup failure matters only for a non-empty allowlist, where it makes
  the request inadmissible (skip). Pre-flight parity (D7) separately stops
  the invocation if the SELECTED request's candidate lookup fails.
- **P-3 (order inside one index).** Record integrity first (empty id →
  stop, D6), then admissibility (skip), then §2.3.2 state. So an
  inadmissible request is skipped even when the approval registry is not
  ready, instead of stopping the scan. Stopping remains for untrusted
  data (D6).
- **P-4 (multiple dry-run records).** (a) requires every dry-run record
  for X to be ACCEPTED. Any non-ACCEPTED record makes X inadmissible, so
  disagreeing records never admit a request.

**Implementation reconciliation note (informational, not an
authorization).** The closed Wave 1 and Wave 2 code implements Rev.14,
not Rev.15. Rev.15 will require:
- Wave 1 (`MLQuantAI_BoundedAutomationIssuance.mqh`): the step 1b
  AUTOMATION_EXHAUSTED state (PROV-1 classification of E1).
- Wave 2 (`MLQuantAI_BoundedAutomationDiscovery.mqh`): admissibility skip,
  exhausted skip, and the step order of §2.3.1a as amended.
- Later waves: pre-flight parity (D7), the RA-31 claim-path function (D1/D2),
  and the D4-b input check.

Each needs a separate Implementation Reconciliation checkpoint after the
Rev.15 freeze.

---

## §8. Explicitly NOT authorized by this document (unchanged)

```
Implementation        = NOT AUTHORIZED
Source modification   = NOT AUTHORIZED
Tests                 = NOT AUTHORIZED
Commit                = NOT AUTHORIZED
Push                  = NOT AUTHORIZED

DEMO_BOUNDED_AUTOMATION = NOT UNLOCKED
DEMO_REAL_SUBMIT        = LOCKED (unchanged)
OrderSend               = NOT AUTHORIZED
LIVE                    = FORBIDDEN
3800463826              = DO NOT TOUCH
```

This document is submitted for QA design review only.
