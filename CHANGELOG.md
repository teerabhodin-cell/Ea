# Changelog

All notable changes to MLQuantAI. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); versions follow
`MLQUANTAI_EA_VERSION` in `Include/MLQuantAI/Core/MLQuantAI_VersionRegistry.mqh`.

## [Unreleased] - C4.3 v1 implementation: recovery coverage attestation evaluation (PASSED 57/57, real MetaEditor run, merged to mlquantai via PR #12, 2026-09-02)

Implements the C4.3 §11 contract (adopted via PR #11) as a first,
parameter-source-only checkpoint. Delivers:
`Include/MLQuantAI/Execution/MLQuantAI_CoverageAttestation.mqh`
(`RecoveryCoverageAttestation` struct,
`ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS`,
`ICoverageAttestationSource`, `NullCoverageAttestationSource`);
`MLQuantAI_ParameterCoverageAttestationSource.mqh`
(`ParameterCoverageAttestationSource`, v1's only implemented concrete
source, with presence-only validation at its frozen source boundary);
`MLQuantAI_RecoveryCoverageEvaluator.mqh` (the two pure §11.6
evaluator functions plus the additive `RecoveryCoverage_DetailToken`
report-detail helper); and a new five-argument
`RecoveryReconciliation_ScanLive` overload in
`MLQuantAI_RecoveryReconciliation.mqh`, with the original
four-argument signature preserved as a behavior-identical wrapper.

`CsvStaticCoverageAttestationSource`, though already authorized by
§11.5, was deliberately excluded from this checkpoint's scope and is
deferred to a separate C4.3.1 implementation checkpoint. No
`MLQuantAI.mq5` call site is wired to construct or configure any
attestation source; that remains reserved for a future checkpoint.

Validation (real MetaEditor compile/run; no compiler access in this
session): C4.3 suite — 0 errors, 0 warnings, 57/57 checks passed.
C4.2 regression suite
(`MLQuantAI_Test_C4_2_RecoveryReconciliation.mq5`, unmodified) —
0 errors, 0 warnings, 143/143 checks passed, matching the original
sealed baseline.

Implementation commit `beb60db`. PR #12. Integration merge commit
`5ab1cf0`.

## [Unreleased] - C4.3 Recovery Window-Adequacy Evidence Contract (ADOPTED, docs-only, merged to mlquantai via PR #11, 2026-09-01)

C4.3 Recovery Window-Adequacy Evidence Contract
ADOPTED — docs-only — merged to mlquantai via PR #11, 2026-09-01.

Proposes a deterministic, fail-closed contract for resolving
`RECOVERY_WINDOW_ADEQUACY_UNASSESSED` to `PROVEN` or `INSUFFICIENT`
per local fact, using a locally supplied (never live-fetched)
coverage attestation compared against the broker-history query window
actually used for that fact. No source file, test file, live
broker/history call, network activity, EventStore write, serializer
change, or C4.2/C4.2.1 implementation change is included. This
checkpoint is documentation only.

Adds §11 "C4.3 Recovery Window-Adequacy Evidence Contract (PROPOSED -
not yet adopted)" to `Docs/PhaseC_C4_RecoveryHistoryPolicy.md`,
defining: the `RecoveryCoverageAttestation` schema and its
byte-exact identity/time-basis/integrity-marker comparison rules; the
non-live `ICoverageAttestationSource` boundary (authorized v1 sources
are static-file/parameter-only; any live or network implementation is
explicitly forbidden); the two pure evaluator functions
`RecoveryCoverage_ClassifyEvidence` and `RecoveryCoverage_Evaluate`
and their frozen decision orders; the per-local-fact (never
scan-wide) evaluation rule with a worked two-fact example;
compatibility/non-mutation guarantees against the existing
`ENUM_RECOVERY_FINDING` taxonomy, §9.4 schema, and §9.9 collapse
rule; a 25-case required test matrix; and explicit v1 exclusions
(symbol-scoped coverage, any live attestation source, terminal-only
retention inference, scan-level aggregation, cryptographic
attestation integrity).

Baseline `mlquantai@c997c63b71543f18754bfb020e87b5e4115eddef` (the
C4.2 Recovery Reconciliation merge commit, PR #10).

Adopting this addendum alone authorized no implementation work. At the
time PR #11 merged this documentation-only addendum into `mlquantai`,
no `RecoveryCoverageAttestation`, `ICoverageAttestationSource`,
`RecoveryCoverage_ClassifyEvidence`, `RecoveryCoverage_Evaluate`, or
`ENUM_RECOVERY_COVERAGE_EVIDENCE_STATUS` symbol existed in the
codebase. This addendum defined the contract those symbols would later
need to satisfy. A separately authorized C4.3 v1 implementation
checkpoint subsequently delivered all five symbols; see the C4.3 v1
implementation entry above.

## [Unreleased] - C4.2.1 Recovery-Anchor Provenance Addendum (PROPOSED, docs-only, not adopted, 2026-08-29)

C4.2.1 Recovery-Anchor Provenance Addendum
PROPOSED — docs-only — not adopted.

Proposes surfacing the existing `EXECUTION_REQUEST_CREATED`
base-envelope timestamp into `ExecutionRequestProjectionRecord` as
read-only recovery-window provenance. No event format, EventStore
write, serializer, hash, identity, lifecycle, SafeMode, trade, or C4.2
implementation change is included.

Adds §10 "C4.2.1 Recovery-Anchor Provenance Addendum (PROPOSED)" to
`Docs/PhaseC_C4_RecoveryHistoryPolicy.md`, on
`docs/c4-2-1-recovery-anchor-provenance-addendum`. Baseline
`mlquantai@7315bdc1f08186133c1e6e2c3665716280fdd7de` (the C4.1
Checkpoint 1 adoption merge commit, PR #8).

Found during C4.2 Contract-Reconciliation Implementation Checkpoint 1
research: C4.2 cannot construct the C4.1-frozen per-fact recovery
window without a durable local anchor timestamp, and
`ExecutionRequestProjectionRecord` - the only local-fact source C4.2's
design may depend on - carries no such field. Research confirmed the
data already exists: `EventStore_AppendSystem` stamps
`e.base.ts = TimeCurrent()` on every `EXECUTION_REQUEST_CREATED`
event, and `ExecutionRequestProjection_ApplyLine` already parses it
back via `EventSerializer_ParseSystem` - it is simply never copied
into the projection record. This addendum proposes copying that
already-durable, already-parsed value forward as two new read-only
fields (`recovery_anchor_time`/`recovery_anchor_time_known`), with an
explicit no-overwrite rule and a defensive unknown-on-corruption rule.
Zero event/wire/hash/serializer impact - `execution_request_hash` is
computed from a separate struct that never sees these fields.

`ExecutionRequestProjectionRecord`, its `_Init` function, and
`ExecutionRequestProjection_ApplyLine` remain unmodified until this
addendum is reviewed and adopted. Adopting this addendum alone does
not reinstate C4.2's separately-paused implementation authorization -
a revised code/test allowlist authorization is still required before
any C4.2 file may be touched.

## [Unreleased] - C4.1 Contract-Reconciliation Checkpoint 1 (ADOPTED, docs-only, non-authoritative, merged to mlquantai via PR #8, 2026-08-29)

C4.1 Contract-Reconciliation Checkpoint 1
ADOPTED — docs-only — non-authoritative — merged to mlquantai via PR #8, 2026-08-29
No broker-history acquisition or C4 implementation authorized.

Adds §9 "C4.1 Design Addendum (PROPOSED)" to
`Docs/PhaseC_C4_RecoveryHistoryPolicy.md`, on
`docs/c4-1-recovery-reconciliation-addendum`. Baseline
`mlquantai@168d3316a4e1d926fd85d92d0f051df40b1b2aa3` (the C4.0
adoption merge commit, PR #7).

This proposed addendum freezes the comparison, evidence-window,
knownness, identity, disposition, ordering, and non-authoritative
reporting semantics required before C4.2 read-only implementation may
be considered:

- A 60-minute frozen default overlap allowance (planned identifier
  `MLQUANTAI_C4_RECOVERY_OVERLAP_MINUTES_DEFAULT`, not yet implemented
  in source), an implementation-phase operator override whose
  semantics (not declaration) are frozen here, and a fail-closed rule
  for an invalid (`<= 0`) override - a whole-scan failure evaluated
  once, before any per-row finding, never silently replaced with the
  default and never producing a per-row finding of its own.
- A scan-time-snapshot rule: `history_query_server_time` is captured
  once per reconciliation scan, not once per record.
- A knownness discipline covering both sides of every comparison:
  every broker-derived comparable field carries its own `<field>_known`
  flag, and an explicit local-side knownness rule (a local value is
  known only when its source fact exists, its schema is supported, and
  the field was actually recorded) - a zero/empty value is never an
  implicit "unknown" sentinel on either side.
- Full recovered order/deal fact schemas
  (`RecoveredOrderHistoryFact`/`RecoveredDealHistoryFact`, planned
  shapes, not yet implemented), each carrying an explicit
  `schema_version` and a knownness flag per comparable field.
- Exact-equality-only comparison rules for v1 (no tolerance/epsilon),
  including a deliberate split from C3.3's
  `running_filled_volume >= lot_size` threshold rule; an indeterminate
  aggregate-volume group (any contributing deal with
  `volume_known=false`) cannot produce CORROBORATED or CONFLICT; and
  duplicate recovered order or deal evidence (same known ticket within
  one scan) is a terminal normalization failure for that group -
  `RECOVERY_DUPLICATE_HISTORY_RECORD`/`BLOCK_RECOMMENDED`, with no
  arbitrary duplicate ever treated as canonical.
- An identity-mapping rule: C4.1 v1 is `source_order_ticket`-only, with
  no secondary key (no correlation ID, magic number, symbol,
  order/deal type, volume, price, time, or field-similarity fallback).
- Explicit comparison-unit cardinality and diagnostic-row cardinality
  (§9.6): ORDER (one recovered order fact vs. one local order fact)
  and AGGREGATE_DEAL_VOLUME (the summed recovered-deal volume for one
  order ticket vs. local `running_filled_volume`) are the only two
  comparison units in v1, each emitting at most one *successful-
  comparison* row (CORROBORATED/CONFLICT/NO_CORROBORATING_HISTORY) per
  known order ticket. No standalone DEAL comparison unit exists in v1
  - C4.1 defines no durable local deal-level identity to compare
  against, so a recovered deal's fields are carried for
  provenance/aggregation/orphan detection only, never as their own
  corroboration/conflict row (§9.5 revised accordingly - the prior
  draft's "deal vs. local" line is removed). The four terminal
  diagnostic findings (`RECOVERY_UNMAPPABLE_HISTORY_RECORD`,
  `RECOVERY_ORPHAN_HISTORY_ORDER`, `RECOVERY_ORPHAN_HISTORY_DEAL`,
  `RECOVERY_DUPLICATE_HISTORY_RECORD`) have their own independent,
  explicitly frozen row-cardinality rule (one row per recovered
  record, or per duplicate-ticket group, as applicable) - a single
  order-ticket group may legitimately produce multiple diagnostic
  rows even though at most one successful-comparison row is ever
  emitted for that group.
- A full 10-row finding-taxonomy table covering every adopted C4.0 §4
  `ENUM_RECOVERY_FINDING` value with its trigger, comparison unit, and
  posture (verified by direct inspection against §4's enum
  declaration, exact name and order match), a frozen per-unit
  precedence rule (first matching condition wins, evaluated in a fixed
  order), and an explicit orphan-vs-unmappable distinction (ambiguous
  multi-match → `RECOVERY_UNMAPPABLE_HISTORY_RECORD`; zero eligible
  matches → `RECOVERY_ORPHAN_HISTORY_ORDER`; all-fields-unknown
  recovered record → `RECOVERY_NO_CORROBORATING_HISTORY`, always
  outranked by
  `RECOVERY_WINDOW_INSUFFICIENT`/`RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE`
  where applicable).
- An explicit reconciliation-population rule (§9.7): C4.1 v1 evaluates
  three directions - local-fact-driven (an eligible local fact with no
  recovered match owns `RECOVERY_NO_CORROBORATING_HISTORY`),
  recovered-order-driven (an unmatched recovered order owns an orphan
  or unmappable finding), and recovered-deal-driven (a deal that can't
  attach to its order owns `RECOVERY_ORPHAN_HISTORY_DEAL`) - with an
  explicit rule that no single discrepancy may be emitted as more than
  one row across directions.
- A frozen disposition model for `report.ok`: every finding has an
  explicit posture (`INFORMATIONAL`/`DEGRADED`/`BLOCK_RECOMMENDED`)
  from the taxonomy table - `RECOVERY_FACT_CORROBORATED` is always
  `INFORMATIONAL`, `RECOVERY_FACT_CONFLICT` is always
  `BLOCK_RECOMMENDED` - and `report.ok=true` requires no final row
  carrying `DEGRADED` or `BLOCK_RECOMMENDED`.
- A six-key deterministic sort order (order ticket, then deal ticket,
  then a new `comparison_scope` field - `ORDER` before
  `AGGREGATE_DEAL_VOLUME` - then candidate id, then finding enum
  ordinal, then a deterministic non-durable provenance discriminator
  as the last ordering tiebreaker) guaranteeing no two rows remain
  indistinguishable, and `first_error` selection from that final
  order. The discriminator is derived solely from frozen recovered-fact
  fields in canonical order and is explicitly not an id, hash,
  persistence key, or durable trace - it exists only to break ties
  among diagnostic rows that share every other sort key (e.g. two
  unmappable records with no known ticket and no candidate id); if two
  rows remain identical after all six keys, they represent the same
  canonical diagnostic record and only one row is emitted.
- An explicit deferral: no `RecoveryReconciliationRow` identity hash is
  minted in C4.1; that is left to any future, separately adopted
  durable-trace amendment. Standalone deal-vs-local comparison is
  likewise deferred to a future amendment that would define a durable
  local deal-level identity.

Every identifier, `#define`, and `struct` in §9 is labeled planned
pseudocode ("the future C4.2 implementation SHALL expose... this
addendum does not create it in source code"). No `.mqh`/`.mq5` header,
macro, input declaration, report struct, or test exists as a result of
this entry. C4.1 remains unauthorized until this addendum itself is
reviewed and adopted; C4.2 (read-only broker-history
acquisition/report implementation) remains gated behind that adoption.

## [Unreleased] - C4.0 recovery/broker-history policy contract (ADOPTED, docs-only, merged to mlquantai via PR #7, 2026-08-28)

`Docs/PhaseC_C4_RecoveryHistoryPolicy.md` (new), on
`docs/c4-recovery-history-policy-contract`. Baseline
`mlquantai@81a000b583661099d077225be99d030cea65eff5` (the C3.8
phase-close merge commit). Predecessor:
`Docs/PhaseC_C3_8_ReconciliationIntegrationContract.md`.

This is a design-contract document only - no `.mqh`/`.mq5` source, no
`HistorySelect()` code, no `HistoryDeal*`/`HistoryOrder*` code, and no
implementation of any kind accompanies it. It defines, ahead of any C4
implementation work, the policy for reconciling durable local
event-store evidence against recovered MT5 broker order/deal history:

- A four-record evidence model (C3.2 live-submission fact; recovered
  order-history fact; recovered deal-history fact; derived
  reconciliation finding), each recovered record carrying a frozen
  minimum provenance field set (`provenance_kind`,
  `history_select_from`, `history_select_to`,
  `history_query_server_time`, `source_order_ticket`,
  `source_deal_ticket`, `recovery_session_identity`) and a frozen
  non-overwrite invariant against existing durable local evidence.
- A three-state `HistorySelect()` query policy (query fails /
  query succeeds empty / query succeeds with an evidentially-adequate
  but still-empty window), so absence of history is never conflated
  with query failure.
- A ten-value `ENUM_RECOVERY_FINDING` reconciliation-finding vocabulary
  covering evidence-unavailable, window-insufficient,
  no-corroborating-history, fact-corroborated, fact-conflict, orphan
  history order/deal, duplicate history record, and unmappable history
  record outcomes.
- An explicit statement that findings are read-only recommendations,
  never actions, via a separate `ENUM_RECOVERY_POSTURE`
  (`INFORMATIONAL`/`DEGRADED`/`BLOCK_RECOMMENDED`) that a finding may
  carry but that never itself triggers a write, a SafeMode trip, or any
  other side effect from within C4.0's scope.
- A matching-key hierarchy (primary/secondary) and a conflict-category
  taxonomy governing when a recovered record is treated as
  corroborating versus conflicting versus unmappable.
- An explicit ownership map and write-authorization freeze: C4.0
  authorizes no writes of any kind; the first implementation gate
  (C4.1) it anticipates is read-only and may emit only an in-memory
  report, never a durable write, a lifecycle transition, or an
  EventStore/StateProjector mutation.

Amended after Checkpoint 2 QA re-review (still pre-adoption, same
draft): (1) baseline wording corrected so it no longer implies every
C3 docs artifact was merged - the adopted C3.8 contract's docs-lineage
authority is unaffected by C3's implementation merges; (2)
`HistorySelect()` window construction and its adequacy predicate are
now frozen in §3 (start = earliest relevant local timestamp minus a
named overlap-allowance constant, end = `TimeCurrent()`, both bounds
inclusive) - only the constant's numeric default is deferred, to a
required C4.1 addendum; (3) §6 now explicitly gates
`RECOVERY_FACT_CORROBORATED`/`RECOVERY_FACT_CONFLICT` emission behind
an adopted C4.1 comparison-semantics addendum - a matched identity
alone yields only an informational finding until that addendum exists;
(4) `RECOVERY_DUPLICATE_HISTORY_RECORD`'s scope is now frozen to one
normalized snapshot within a single query, explicitly not a ticket
recurring across separate `recovery_session_identity` scans; (5) §7
now carries an explicit C4.1 implementation-authorization checklist
tying together all of the above gates.

Status: proposed for adoption. Per the governance model this project
already follows (established at C3.8's closure), adoption of this
contract will be a docs-lineage event on
`docs/c4-recovery-history-policy-contract` and does not require merging
this branch into `mlquantai`. No C4 implementation work (including any
`HistorySelect()` call) is authorized until this contract is reviewed
and adopted, and no C4.1 code may be written until the further,
separately-adopted C4.1 addendum(s) required by §7 exist.

## [Unreleased] - C3.8 phase CLOSED (2026-08-28)

C3.8 (reconciliation integration / submitted-candidate visibility) is
closed. Its implementation components are merged on `mlquantai`; its
authoritative contract is adopted and retained on its dedicated docs
lineage.

Closure record:

```
Contract (§§1-13 + §§14-18 amendment)
  Adopted on its dedicated docs lineage
  (docs/c3-8-reconciliation-integration-contract, commit b6b298e)
  - per the governance model this phase established, contract
    adoption is a docs-lineage event, not a merge-to-mlquantai event.

C3.8.0 - StateProjector enumeration accessors
  Merged: PR #3, merge commit 9903267ae2d50da239d5fec8bc45656e7d09199c

C3.8.1 - Submitted candidate visibility projection
  Merged: PR #5, merge commit d311d875366d0ef7645ceecdf6a5410365c41774
  Real MetaEditor run: 32/32 test functions executed, 107/107
  assertions passed, 0 failures, 0 skipped - including deterministic
  source-tuple attribution (contract §14 "Per-row error selection"),
  anomaly-precedence, full row ordering (§16), and full-domain `ulong`
  ticket formatting (`%I64u`, no narrowing cast) coverage.
```

`origin/mlquantai` now contains both C3.8.0 and C3.8.1 in full. Both
feature branches (`c3-8-0-stateprojector-enumeration`,
`c3-8-1-submitted-candidate-visibility`) are retained after their
respective merges, preserving the feature-branch history. The C3.8.1
implementation went through three corrective
passes at Implementation Checkpoint 3 (QA re-review) before the real
MetaEditor run: (1) added per-row lineage-anomaly attribution to
`report.first_error`, initially missing; (2) corrected the
`MULTIPLE_EXECUTION_REQUESTS`/`AMBIGUOUS_TICKETS` attribution from a
detection-witness tuple to the contract-required earliest positive
qualifying tuple; (3) replaced a `(long)`-narrowing ulong-to-string
conversion with `%I64u` for full-domain-safe ticket formatting. All
three are captured in the merged commit history, not left as
uncommitted worktree state.

## [Unreleased] - C3.8.1 implementation: submitted-candidate visibility diagnostic (IMPLEMENTING, awaiting real MetaEditor run, 2026-08-28)

`Include/MLQuantAI/Execution/MLQuantAI_SubmittedCandidateVisibility.mqh`
(new) + `Tests/MLQuantAI_Test_C3_8_1_SubmittedCandidateVisibility.mq5`
(new). Baseline `mlquantai@9903267ae2d50da239d5fec8bc45656e7d09199c`
(the C3.8.0 merge commit). Implements the lineage-resolution/evidence-
gating contract frozen at Docs/PhaseC_C3_8_ReconciliationIntegrationContract.md
§§14-18 (on `docs/c3-8-reconciliation-integration-contract`, committed
`b6b298e`, not yet merged to `mlquantai`).

A pure, read-only diagnostic: for every candidate currently at
`CANDIDATE_SUBMITTED` (enumerated via C3.8.0's own
`StateProjector_Count()`/`_GetAt()` - the only sanctioned path into that
registry per §18), reports whatever real, already-durable evidence
exists - submission timing/sequence, ticket lineage, C3.3 terminal match
status, and C3.6 recommendation visibility - as a
`SubmittedCandidateVisibilityRow`/`Report` pair via
`SubmittedCandidateVisibility_ScanLines()`/`_ScanFile()`.

Absence of qualifying evidence is never an anomaly (§14 outcome 5,
`LINEAGE_ANOMALY_NONE`). A malformed/ambiguous ticket lineage is reported
as an integrity finding (`report.ok=false`, `lineage_anomaly` set) in a
frozen six-outcome precedence order (`NONPOSITIVE_TICKET` >
`DUPLICATE_TRIPLE` > `MULTIPLE_EXECUTION_REQUESTS` > `AMBIGUOUS_TICKETS`
> no-qualifying-outcome > clean resolution), never silently dropped or
guessed at. `terminal_evidence_observed` is true only for
`TX_MATCH_VOLUME_REACHED` (§15) - `TX_MATCH_ORDER_TERMINAL` is never
terminal evidence here, matching C3.3's own reservation of that status.
Row ordering is known-sequence-number-ascending, then unknown rows by
`candidate_id` ascending (§16); `report.first_error` follows that same
final row order, not insertion order.

Reads only via `StateProjector_Count/_GetAt`,
`ExecutionRequestProjection_Count/_GetAt`,
`SubmissionOutcomeProjection_Count/_GetAt`,
`TransactionMatching_TryGetOrderStatus`,
`DeferredTransactionProcessor_TryGet`,
`EventSerializer_PeekCategory/_ParseLifecycle`, `EventStore_ReadAllLines`,
and `TimeCurrent()` - the exact permitted-sources table at §18. No
`BrokerReconciliation_CheckAll`/`_HasMatchingPosition`,
`EventStoreValidator`, `ReplayEngine`, `History*`/`OrderSend`/`CTrade`/
`PositionSelect`, `AsyncTerminalOrderMatcher` scan, or
`SafeMode_Trip`/`_Clear` call anywhere - C3.10A is excluded from this
evidence graph entirely (§17, it returns its report by value with no
persistent registry). No lifecycle authority, no event append, no
broker/terminal query, no write of any kind.

Test suite (`MLQuantAI_Test_C3_8_1_SubmittedCandidateVisibility.mq5`, 26
test functions + 1 structural-proof check) seeds every upstream
projection directly via the real, already-public
`*_Reset()`/`StateProjector_Apply()`/`*_AppendRecord()`/`C36_AppendRow()`
functions those sealed modules already expose - same precedent
`MLQuantAI_Test_C3_10A_AsyncTerminalOrderObservationMatcher.mq5` already
established - never a direct internal-array write. The one raw JSONL
fixture line hand-built is the `CANDIDATE_SUBMITTED` lifecycle line
`SCV_FindSubmittedLine()` itself parses. Covers: non-SUBMITTED exclusion,
zero-qualifying-outcome non-anomaly, non-SUBMITTED-outcome exclusion,
clean single-ticket resolution, all four anomaly types individually, the
NONPOSITIVE_TICKET-precedes-others precedence collision, first_error
following final sorted row order (not insertion order), full row
ordering, VOLUME_REACHED/PARTIAL/unknown terminal-evidence gating,
recommendation-visibility independence from lineage/evidence state,
unresolved-beyond-threshold flagging and its negative-threshold input-
validation error path, future-dated and duplicate CANDIDATE_SUBMITTED
lines failing closed, `_ScanFile`/`_ScanLines` parity, missing-file and
`n`-clamping safety, cross-run determinism, and no-silent-omission
row-count fidelity.

**Corrective revision (Implementation Checkpoint 3, QA finding A)**: the
initial draft's `report.first_error` cited only `candidate_id` and the
anomaly type name, with no source attribution - §14's "Per-row error
selection" specifies `first_error` is "built from the earliest `(i, j)`
scan-index pair... whose outcome triggered that specific anomaly
category," implying the triggering tuple itself should be attributable.
Added `SCV_AnomalyTrigger` (`execution_request_id` + raw `order_ticket`,
local scratch state only - not part of the frozen row/report shape) to
capture the trigger tuple for each of outcomes 1-4, and
`SCV_RowWithTrigger` to carry it through the existing `§16` sort in
lockstep. `report.first_error` now reads `"candidate %s: lineage anomaly
%s (execution_request_id=%s, order_ticket=%s)"`, citing the real source
tuple - never derived from `row.order_ticket`, which stays semantically
undefined on every anomalous row.

**Second corrective pass (same checkpoint, QA re-review)**: the first
pass above selected outcomes 3/4's trigger from the entry whose scan
position first made the anomaly *detectable* (the second distinct
`execution_request_id`/ticket observed) - a detection witness, not
necessarily the earliest `(i, j)` pair the contract specifies. Corrected:
for `NONPOSITIVE_TICKET` and `DUPLICATE_TRIPLE` (unchanged, already
correct), and now for `MULTIPLE_EXECUTION_REQUESTS`/`AMBIGUOUS_TICKETS`
too, the attributed tuple is the earliest category-relevant source tuple
by ascending `(i,j)` - `positive[0]`, the first positive qualifying entry
across the whole candidate, regardless of which distinct
request/ticket it happens to belong to.

**Third corrective pass (same checkpoint, QA re-review)**: the ulong
ticket formatting from the first pass, `IntegerToString((long)
trigger.order_ticket)`, was not full-domain safe - the `(long)` cast
reinterprets any raw `ulong` value above `LONG_MAX`
(9223372036854775807) as negative before it is ever stringified,
corrupting the attributed ticket for that range. Replaced with
`StringFormat("%I64u", trigger.order_ticket)` applied directly to the
raw `ulong`, no narrowing cast at all - the same `%I64u`-on-a-raw-`ulong`
idiom `MLQuantAI_AsyncTerminalRejectionAuthority.mqh` (sealed) already
uses for its own `order_ticket` field. The resulting text is still a
genuine `string` by the time it reaches the outer `first_error`
`StringFormat()` call's `%s` placeholder - no raw `ulong` is ever passed
to a `%s` placeholder at any point.

Precedence and determinism hold under the corrected selection too: a
higher-precedence anomaly's trigger always wins over a lower one's, and
the same fixture reproduces the identical `first_error` string every
run. Test suite extended across these passes with: two dedicated
fixtures proving "earliest tuple" differs from "detection witness" for
`MULTIPLE_EXECUTION_REQUESTS`/`AMBIGUOUS_TICKETS`, an exact-decimal-value
formatting proof cross-checked against `%I64u` on the same raw value, and
a full-domain proof using a ticket one past `LONG_MAX`
(9223372036854775808) asserting the exact positive decimal string
appears with no negative sign - plus corrected assertions (to the new
earliest-tuple values) on every existing anomaly-type test, the
precedence-collision test, the final-row-order test, and the
attribution-determinism test. 32 `Test_*` functions total in the file
now (27 before Checkpoint 3's corrective passes began). Still docs-only-
adjacent code: no compile, no test run, no stage, no commit.

Status: implementation staged on branch
`c3-8-1-submitted-candidate-visibility`, awaiting a real MetaEditor
compile/run before any PASSED claim - matching the exact verification
discipline C3.8.0 followed.

## [Unreleased] - C3.8.0 implementation: StateProjector enumeration accessors (PASSED 928/928, real MetaEditor run, 2026-08-27)

`Include/MLQuantAI/Infrastructure/EventStore/MLQuantAI_StateProjector.mqh`
(amended) + `Tests/MLQuantAI_Test_C3_8_0_StateProjectorEnumeration.mq5`
(new). Adds the one enumeration primitive `StateProjector.mqh` was
missing relative to every other sealed projection in this codebase
(`ExecutionRequestProjection`, `SubmissionOutcomeProjection`,
`OrderAggregateRegistry`, `DeferredTransactionProcessor`,
`TransactionDealRegistry`, all already expose `_Count`/`_GetAt`):

```
int  StateProjector_Count();
bool StateProjector_GetAt(int index, ProjectedCandidate &out);
```

Placed immediately after `StateProjector_TryGetState()` and before
`StateProjector_Apply()`'s doc comment. `StateProjector_Count()` returns
`g_Proj_Count` with no side effect. `StateProjector_GetAt()` performs one
bounds check (`index < 0 || index >= g_Proj_Count`) and one value copy
(`out = g_Proj_Candidates[index]`) - `ProjectedCandidate`'s five fields
(three `string`, one `ENUM_CANDIDATE_STATE`, one `int`) contain no nested
arrays, pointers, or class handles, so the copy is snapshot-safe: caller
mutation of the returned struct cannot alter the stored registry record
(proven directly by test, not just assumed).

No behavior change to `StateProjector_Reset`/`_FindIndex`/`_TryGetState`/
`_Apply`/`_ApplySystem` - all five keep their exact existing signatures
and semantics. This is the only edit to `StateProjector.mqh` this round
makes.

Purely additive read-only surface for a future C3.8.1 (submitted-
candidate visibility diagnostic, currently a nonbinding, uncommitted
draft on a separate docs branch - not part of this round's scope) to
enumerate `(candidate_id, current_state)` pairs without reaching into
`g_Proj_Candidates[]`/`g_Proj_Count` directly, the way
`BrokerReconciliation_CheckAll()` (unchanged by this commit) already
does as undocumented file-scope access. No `OnInit`/`OnTick`/
`OnTradeTransaction` wiring, no event append, no Safe Mode change, no
candidate-lifecycle transition, no broker/terminal query, anywhere in
this round.

Test suite (`MLQuantAI_Test_C3_8_0_StateProjectorEnumeration.mq5`) builds
every fixture through the existing, sealed `StateProjector_Apply()` entry
point only - never writes `g_Proj_Candidates[]`/`g_Proj_Count` directly,
so it exercises the public state-projector contract, not internal
storage. Every test function calls `StateProjector_Reset()` at its own
start and end, preventing cross-test state leakage. Covers: empty
registry, bounds at -1/0/N-1/N/a large positive index, `Count()` tracking
real applied records (and staying unchanged across a same-candidate
transition), stable insertion ordering, full five-field record fidelity
cross-checked against `StateProjector_TryGetState()`, caller-mutation
non-aliasing, live transition visibility at a fixed index, and
`Reset()` clearing the enumeration surface. This test proves behavior
through the public API only - it does not attempt to byte-diff sealed
files from within MQL5 (that proof is external/git-based, delivered
separately as Checkpoint 3 evidence).

Sealed files untouched (confirmed via `git diff --check`/`git diff
--name-only`, external evidence, not an in-test claim): `MLQuantAI.mq5`;
`EventStore.mqh`, `EventSerializer.mqh`, `EventStoreValidator.mqh`,
`ReplayEngine.mqh`, `EventStoreHealth.mqh`, `CandidateProjection.mqh`;
`Core/MLQuantAI_StateMachine.mqh`; `BrokerReconciliation.mqh`,
`DeferredTransactionProcessor.mqh`, `LifecycleAuthorityProcessor.mqh`,
`ExecutionProvenanceConflictAuditor.mqh`; every C3.10 A/B/C/D/E1 module.

**C3.8.0 verification complete.** Real MetaEditor run:

- 14 suites passed
- 928/928 assertions passed
- `MLQuantAI.mq5` compiled with 0 errors and 0 warnings

The 14 suites: `MLQuantAI_Test_C3_8_0_StateProjectorEnumeration` (43/43,
the new suite itself) plus the full transitive-consumer regression set -
`MLQuantAI_Test_ReplayIntegrity` (16/16), `MLQuantAI_Test_EventStoreRecovery`
(14/14), `MLQuantAI_Test_BrokerReconciliation` (5/5),
`MLQuantAI_Test_C3_7_LifecycleAuthorityProcessor` (125/125),
`MLQuantAI_Test_C3_9_ExecutionProvenanceConflictAuditor` (101/101),
`MLQuantAI_Test_C3_10F_StackedIntegrationAudit` (33/33),
`MLQuantAI_Test_C3_10E_AsyncTerminalRejectionHealthTrend` (28/28),
`MLQuantAI_Test_C3_10D_AsyncTerminalRejectionStartupDiagnostics` (49/49),
`MLQuantAI_Test_C3_10C_AsyncTerminalRejectionAudit` (95/95),
`MLQuantAI_Test_C3_10B_AsyncTerminalRejectionAuthority` (177/177),
`MLQuantAI_Test_C3_10A_AsyncTerminalOrderObservationMatcher` (79/79),
`MLQuantAI_Test_B9_Commit2_EligibilityEvent` (84/84), and
`MLQuantAI_Test_B9_Commit3_IntegrationRegression` (79/79) - zero
failures anywhere. This entry records verification results only; it
does not claim a PR review, merge, release, production deployment, or
C3.8.1 authorization.

## [Unreleased] - C3.10E2 implementation: terminal rejection audit acknowledgement (IMPLEMENTING, awaiting real MetaEditor run, 2026-08-27)

New `EVENT_TYPE_TERMINAL_REJECTION_AUDIT_ACKNOWLEDGED` (appended at the tail
of `ENUM_EVENT_TYPE`) +
`Include/MLQuantAI/Execution/MLQuantAI_TerminalRejectionAuditAcknowledgement.mqh`
(new) + `Tests/MLQuantAI_ManualScript_AcknowledgeAudit.mq5` (new) +
`Tests/MLQuantAI_Test_C3_10E2_TerminalRejectionAuditAcknowledgement.mq5`
(new). Durable, append-only accountability record: a human operator
acknowledges a specific C3.10C audit-report snapshot, identified by
`diagnostic_fingerprint` alone, never raw evidence. Explicitly not
repair, not override, not a Safe Mode clear, not an unblock of C3.10B,
and no effect on trade permission - an audit trail only.

Standalone, manually-run script (`Tests/MLQuantAI_ManualScript_
AcknowledgeAudit.mq5`, mirroring `ManualScript_GrantApproval.mq5`'s
established shape exactly): `#property script_show_inputs`, refuses a
missing event-store file via `FileIsExist(fileName, FILE_COMMON)` rather
than creating one, and takes `diagnostic_fingerprint` as a required
operator-typed input - this scope does not auto-read or recompute the
current audit report, preserving the trust boundary. No integration call
in `MLQuantAI.mq5`, no runtime UI/input path, no wiring to C3.10A-F at
all this round.

Idempotency key is `(operator_id, diagnostic_fingerprint)`, enforced via
a read-before-write duplicate scan
(`EventStore_ReadAllLines` before `EventStore_LogSystem`) - idempotent
only under the existing single-terminal/single-writer operational model;
this is explicitly not an atomic cross-process claim primitive. A
pre-existing durable record carrying an unrecognized
`diagnostic_fingerprint_version`, or a blank identity field, makes the
whole scan fail closed (`ok=false`, no append) rather than risk a
silently-missed duplicate. No caller-supplied acknowledgement ID or
timestamp: the event store's own `log_event_id`/`sequence_number`
(assigned internally, exactly like every other event type in this
codebase) are the durable identity/timing authority.

A durable write failure returns `ok=false` with `first_error` set and
never calls `SafeMode_Trip` - verified against the real
`EventStore_LogSystem`/`EventStore_WriteLine` implementation, which
(despite a stale comment elsewhere in this codebase claiming otherwise)
never trips Safe Mode itself; only specific higher-level callers like
`EventStore_LogTransition` do that. An acknowledgement write's own
failure carries no trading-safety consequence, so none is asserted here.

Zero dependency on any C3.10A/B/C/D/E1/F header or type - the frozen
canonical-string/hash formula that would compute a `diagnostic_fingerprint`
from a real `AsyncTerminalRejectionAuditReport`
(`Ids_Deterministic("AUDITFP", ...)`) is documented in the contract but
not implemented in this module, keeping this round's structural-purity
proof unqualified.

## [Unreleased] - C3.10F implementation: stacked integration audit (IMPLEMENTING, awaiting real MetaEditor run, 2026-08-27)

`Tests/MLQuantAI_Test_C3_10F_StackedIntegrationAudit.mq5` (new). Test-only,
read-only integration audit of the combined C3.10B->C3.10E1 head
(`de929f0`) - not a new runtime feature. Proves that C3.10A/B/C/D/E1
compose correctly as a stack using hand-built, in-memory report fixtures
only: no event-store file, no broker/terminal API, no `OnInit`, no Safe
Mode mutation, no durable write of any kind.

Verifies A->B->C->D report propagation faithfully preserves upstream truth
(`atom_ok`, `authority_ok`, `audit_ok`, `lifecycle_and_reconciliation_ran`,
`confirmations_written`, `authority_stop_reason`, `audit_findings_total`
all traced through `AsyncTerminalRejectionStartupDiagnostics_Build`
unaltered); that a C3.10B authority hold never causes C3.10C's own audit
signal to be skipped or misreported - C3.10C runs unconditionally per its
own frozen integration contract, and D reports both signals independently;
a fully clean composition path; and that C3.10E1's comparator accepts two
diagnostics values built entirely from this composition with no EA/`OnInit`
dependency at all.

Also proves, by inspection (a `Tests/*.mq5` script's `FileOpen` is
sandboxed to `MQL5\Files` and cannot read `MLQuantAI.mq5`'s own source
from the Experts tree, so this is backed by an external offset-based
`grep` token comparison reported separately as Checkpoint 3 evidence, not
runtime file I/O): that C3.10E1 remains unwired (`MLQuantAI.mq5` neither
includes `MLQuantAI_AsyncTerminalRejectionHealthTrend.mqh` nor calls
`AsyncTerminalRejectionHealthTrend_Compare` anywhere), and that the
locked startup order - A scan -> B authority -> the existing
C3.7/`BrokerReconciliation` block -> C audit scan -> D log - is unchanged
since C3.10B first established it.

Sealed files untouched: `MLQuantAI.mq5`; all C3.10A/B/C/D/E1 headers and
their existing test suites; `Enums.mqh`/`ReasonCodes.mqh`;
`EventSerializer.mqh`/`StateProjector.mqh`/`CandidateProjection.mqh`/
`EventStore.mqh`/`EventStoreHealth.mqh`. No new event type, reason code,
serialization schema, state machine, projection, event-store, or Safe Mode
change; no `OnTick`/`OnTradeTransaction` change; no new include or startup
call added to the EA.

## [Unreleased] - C3.10E1 implementation: async terminal rejection health trend (IMPLEMENTING, awaiting real MetaEditor run, 2026-08-27)

`Include/MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionHealthTrend.mqh`
(new) + `Tests/MLQuantAI_Test_C3_10E_AsyncTerminalRejectionHealthTrend.mq5`
(new). Pure, read-only trend classifier over two already-built C3.10D
`AsyncTerminalRejectionStartupDiagnostics` snapshots - lets an operator see
whether the current startup is degraded, improved, unchanged, or unknown
relative to the previous one. Reads nothing (no event store, no
persistence, no snapshot caching of any kind), touches no Safe Mode,
`StateProjector`, `CandidateProjection`, or broker/terminal API, and is
deliberately unwired this round - not called from `MLQuantAI.mq5` or from
C3.10D's own `_Build`/`_Log`. Split from a broader C3.10E "startup
diagnostic history and operator acknowledgement" proposal specifically so
this log-only, non-authoritative trend classifier could not accidentally
become a durable authority; the durable-acknowledgement half (a new
`EVENT_TYPE_TERMINAL_REJECTION_AUDIT_ACKNOWLEDGED` SystemEvent with its own
schema, idempotency, and Safe Mode/gating implications) is deferred to a
later, separately-contracted slice.

New `ENUM_ASYNC_TERMINAL_REJECTION_HEALTH_TREND` (local to this header, not
a persistent/serialized enum) with four members: `UNKNOWN`, `UNCHANGED`,
`IMPROVED`, `DEGRADED`. `AsyncTerminalRejectionHealthTrend_Compare(previous,
current, hasPreviousSnapshot)` takes an explicit `hasPreviousSnapshot` bool
rather than inferring "no previous data" from `previous`'s field values -
a default-constructed `AsyncTerminalRejectionStartupDiagnostics` has every
bool false, which would otherwise be indistinguishable from a genuine
triple-failure prior run. `hasPreviousSnapshot==false` short-circuits to
`UNKNOWN` before either struct is read at all.

Frozen scoring rule, symmetric across all five of C3.10D's boolean health
dimensions (`atom_ok`, `authority_ok`, `audit_ok`,
`lifecycle_and_reconciliation_ran`, `safe_mode_active`): a dimension is
"bad" per the frozen `bad_atom`/`bad_authority`/`bad_audit`/
`bad_lifecycle`/`bad_safe_mode` definitions; `newly_bad` and `newly_good`
are tallied by comparing bad-state per dimension between `previous` and
`current`; any `newly_bad > 0` returns `DEGRADED` outright, otherwise any
`newly_good > 0` returns `IMPROVED`, otherwise `UNCHANGED`. Negative change
wins over positive change purely by this rule ordering, not as a
special-cased branch. The test suite includes fixtures where
`authority_ok` and `lifecycle_and_reconciliation_ran` are deliberately
decoupled (a combination the one real production call site never
produces, since there `lifecycle_and_reconciliation_ran` is always exactly
`rejAuth.ok`), proving the comparator genuinely evaluates all five
dimensions independently rather than relying on that accidental
correlation.

Sealed files untouched: `MLQuantAI.mq5` and all C3.10A/B/C/D modules
(`AsyncTerminalOrderObservationMatcher.mqh`,
`AsyncTerminalRejectionAuthority.mqh`, `AsyncTerminalRejectionAudit.mqh`,
`AsyncTerminalRejectionStartupDiagnostics.mqh`). No new persistent event
type or schema, no `OnTick`/`OnTradeTransaction` change, no `SafeMode_Trip`/
`SafeMode_Clear` call, no forbidden broker/terminal API anywhere in the new
file.

## [Unreleased] - C3.10D implementation: async terminal rejection startup diagnostics (IMPLEMENTING, awaiting real MetaEditor run, 2026-08-27)

`Include/MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionStartupDiagnostics.mqh`
(new) + `Tests/MLQuantAI_Test_C3_10D_AsyncTerminalRejectionStartupDiagnostics.mq5`
(new). Operator-facing startup diagnostic summary - turns the already-built
C3.10A/C3.10B/C3.10C report objects into one six-line log block. Reads
nothing (no `EventStore_ReadAllLines`, no `StateProjector`, no
`CandidateProjection`), appends nothing, and never fails EA initialization
on its own.

**Pure/logging split, settling the Checkpoint 1 design question directly:**
MQL5's `Print()` (which `LogInfo`/`LogWarn`/`LogError` wrap) writes to the
Expert Journal with no corresponding read-back API anywhere in the
standard library, so "capture log text and assert on it" isn't a testable
strategy from inside a `Tests/*.mq5` script. The module therefore splits
into `AsyncTerminalRejectionStartupDiagnostics_Build` (pure - no I/O
beyond the one read-only `SafeMode_IsActive()` call, never mutates its
inputs, exhaustively unit-tested field-by-field) and
`AsyncTerminalRejectionStartupDiagnostics_Log` (thin - calls `_Build`
then emits the frozen six-line block, tested only by structural proof and
a no-crash/no-mutation smoke check, never by exact log text).

`lifecycle_and_reconciliation_ran` is never re-derived from
`authorityReport.ok` - it is exactly the caller-supplied signal
(`rejAuth.ok` at the real `MLQuantAI.mq5` call site), since that is the
one value that actually gated the C3.7/`BrokerReconciliation` control
flow; a dedicated test proves `_Build` reflects the passed value even
when it diverges from what `authorityReport.ok` alone would imply.
`audit_findings_total` is computed as the sum of `AsyncTerminalRejection
AuditReport`'s 6 finding counters here only - never written back into the
audit report itself.

`MLQuantAI.mq5` integration is purely additive: the call is inserted
strictly *after* the existing C3.10C block (verified via `git diff`
against `feat/c3-10c-async-terminal-rejection-audit@68d21c9` - zero lines
of the prior C3.10B/C3.7/`BrokerReconciliation`/C3.10C control flow
touched, one new `#include` plus one new call block only).

Sealed files untouched: `Enums.mqh`, `ReasonCodes.mqh`,
`AsyncTerminalOrderObservationMatcher.mqh`,
`AsyncTerminalRejectionAuthority.mqh`, `AsyncTerminalRejectionAudit.mqh`,
`EventSerializer.mqh`, `StateProjector.mqh`, `CandidateProjection.mqh`. No
new `ENUM_EVENT_TYPE`/`ENUM_REASON_CODE`/persistent schema, no
`OnTick`/`OnTradeTransaction` change, no `SafeMode_Trip` call, no forbidden
broker/terminal API anywhere in the new file.

## [Unreleased] - C3.10C implementation: async terminal rejection audit (IMPLEMENTING, awaiting real MetaEditor run, 2026-08-27)

`Include/MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionAudit.mqh`
(new) + `Tests/MLQuantAI_Test_C3_10C_AsyncTerminalRejectionAudit.mq5`
(new). Strictly read-only, non-blocking startup audit - a post-condition
observer, not a new lifecycle authority. Verifies that every durable
`EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED` SystemEvent C3.10B ever wrote
is internally consistent with the candidate's current `StateProjector`
state, its own linked lifecycle transition, `CandidateProjection`
lineage, and the terminal-observation evidence the SAME `atomReport`
instance C3.10B consumed resolves it to. Never appends, repairs,
transitions state, or trips Safe Mode.

**Central design point: distinguishing C2.2's synchronous rejection from
C3.10B's async one.** `CANDIDATE_REJECTED_BY_BROKER` has two legitimate
writers - C2.2's synchronous path (`BrokerSubmissionAdapter.mqh:237`,
which always passes `extraJson=""`) and C3.10B's async path (which always
writes a non-empty `confirmation_log_event_id`/`confirmation_sequence_
number` pair). Reason codes can't cleanly separate them (`REASON_BROKER_
REJECT` is plausibly reachable from both paths), so the audit uses the
structural presence of a non-empty `confirmation_log_event_id` in the
transition's own `extra_json` as the sole classification signal - a
transition without one is definitionally C2.2's territory and never
scanned or flagged, regardless of reason code. A non-empty event ID with
a missing/zero/invalid `confirmation_sequence_number` is still treated as
a malformed C3.10B link (`missing_confirmation_count`), never silently
reclassified as C2.2 - no special-case code needed for this, since no
real durable confirmation ever has `seq==0` (`EventStore_NextSequence`
always starts at 1), so the identity lookup simply never finds a match.

Two-pass traversal, never short-circuits (always tallies every finding
across the whole store): a forward chronological pass over confirmation
events checks `CandidateProjection` lineage, current-state + linked-
transition existence (`missing_transition_count`), and source evidence
against `atomReport.matches[]` (`source_evidence_missing_count` /
`source_evidence_ambiguous_count` / `provenance_mismatch_count`), while
tallying duplicate `candidate_id`s (`duplicate_confirmation_count`,
counted once per distinct candidate - broader than C3.10B's own 6-field
write-time idempotency key, since a candidate's terminal transition can
only legitimately happen once ever). A backward pass over C3.10B-linked
`REJECTED_BY_BROKER` transitions checks each against the confirmations
already collected in pass 1 (`missing_confirmation_count`). `first_error`
records only the first finding in that ordering.

`MLQuantAI.mq5` integration is purely additive: the call is inserted
strictly *after* the existing, byte-for-byte-unchanged C3.10B/C3.7/
`BrokerReconciliation` control-flow block (verified via `git diff` against
`feat/c3-10b-async-terminal-rejection-authority@ff717b9` - zero lines of
that block touched). `ok==false` only `LogError`s the full counter
summary; it never returns `INIT_FAILED` and never alters `rejAuth`/C3.7/
`BrokerReconciliation` outcomes - an earlier draft of the integration
snippet would have made a C3.10B `ok==false` scan fail EA initialization
entirely, which was caught and corrected before implementation: the
already-locked C3.10B contract only skips C3.7/reconciliation for that
session, and this audit slice must never change that.

Sealed files untouched: `Enums.mqh`, `ReasonCodes.mqh`,
`AsyncTerminalOrderObservationMatcher.mqh`,
`AsyncTerminalRejectionAuthority.mqh`, `EventSerializer.mqh`,
`StateProjector.mqh`, `CandidateProjection.mqh`. No `OnTick`/
`OnTradeTransaction` change, no forbidden broker API, no durable write or
`SafeMode_Trip` call anywhere in the new file.

## [Unreleased] - C3.10B implementation: async terminal rejection authority (IMPLEMENTING, awaiting real MetaEditor run, 2026-08-27)

`Include/MLQuantAI/Execution/MLQuantAI_AsyncTerminalRejectionAuthority.mqh`
(new) + `Tests/MLQuantAI_Test_C3_10B_AsyncTerminalRejectionAuthority.mq5`
(new). The write-side authority C3.10A deliberately stopped short of: the
sole component authorized to turn a C3.10A `ATOM_MATCHED` async
terminal-order observation into a durable
`EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED` SystemEvent followed by a
real `CANDIDATE_SUBMITTED` -> `CANDIDATE_REJECTED_BY_BROKER` lifecycle
transition, via the same production write paths (`EventStore_LogSystem`
then `EventStore_LogTransition`) C2.2's own synchronous-rejection path
already uses live. One new `ENUM_EVENT_TYPE` member
(`EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED`) and one new
`ENUM_REASON_CODE` member (`REASON_ORDER_CANCELLED`); `REASON_BROKER_REJECT`
and `REASON_EXPIRED` are reused as-is for the other two observed kinds.

**Two fail-closed gates locked ahead of any durable write, both correcting
an earlier draft of this design:**
1. Any `ATOM_AMBIGUOUS` entry anywhere in a scan's `AsyncTerminalOrderMatchReport`
   (i.e. `atomReport.ok==false`) stops the ENTIRE authority pass before any
   write, not just the directly-implicated entry. Unlike C3.6's
   `RECOMMEND_BLOCKED` rows (a pure, side-effect-free, freely-recomputed
   read model skip on already-trusted evidence), C3.10A ambiguity means
   the raw broker evidence itself is contradictory - C3.10B performs
   irreversible durable writes, so it cannot write confidently for "clean"
   entries in a batch known to contain unresolved evidentiary
   contradictions elsewhere. Deliberately does NOT trip Safe Mode - an
   upstream data-quality signal, not proof the durable event store itself
   is inconsistent.
2. Every `ATOM_MATCHED` entry must carry a non-empty `source_log_event_id`
   and a positive `source_sequence_number` before any write - C3.10A
   permits an empty `source_log_event_id` as a non-fatal read-only
   diagnostic, but C3.10B, which creates durable identity and lifecycle
   effect from it, cannot. Trips Safe Mode and stops the whole scan
   immediately.

**Idempotency requires a durable full-log lookup, not just a fresh-state
recheck.** A fresh `StateProjector_TryGetState()` recheck alone (C3.7's own
pattern) prevents a duplicate LIFECYCLE transition but not a duplicate
CONFIRMATION write in a partial-write/restart scenario (confirmation
write succeeds, transition write fails, state stays `SUBMITTED`; a naive
restart would re-attempt and write a second confirmation).
`C310B_FindMatchingRejectionConfirmation` (real reference shape: C3.7's own
`C37_FindMatchingExecutedLine` - backward scan, caller-supplied `lines[]`/`n`,
returns match count directly) closes this gap: filters on
`category==SYSTEM`, `type=="TRANSACTION_REJECTION_CONFIRMED"` (the real
serialized value strips the `EVENT_TYPE_` prefix - `EventTypeToString`,
every case), and `c3_10b_schema_version=="C310B_V1"`, then compares 6
typed fields directly (never a concatenated string - `confirmation_key` in
the written JSON is display-only). 0 matches -> proceed; 1 match -> Safe
Mode (partial write, refuse to auto-complete); >1 matches -> Safe Mode
(duplicate confirmations). The SAME lookup, called again after a
successful confirmation write, recovers the real just-written evidence
(never fabricated) - the transition's own `extra_json` carries
`confirmation_log_event_id`/`confirmation_sequence_number` naming the
confirmation event's OWN identity, kept unambiguously distinct from the
confirmation event's own `source_log_event_id`/`source_sequence_number`
(which reference the original `BROKER_TRANSACTION_OBSERVED` line one level
further back).

`MLQuantAI.mq5` OnInit wiring: `AsyncTerminalOrderMatcher_ScanFile` (C3.10A
is a pure function with no global registry, so it is called directly
rather than through a `*_StartupScan`-populated one) then
`AsyncTerminalRejectionAuthority_StartupApply`, slotted between C3.6's
`DeferredTransactionProcessor_StartupScan` and C3.7's
`LifecycleAuthority_StartupApply`. On `ok==false`, both C3.7 and
`BrokerReconciliation_CheckAll` are skipped for the session (the existing
`lar`/`brr` block is nested one level deeper, inside `if(rejAuth.ok)`) -
same "reconciling/transitioning against a provably-uncertain state would
be worse than skipping it" rationale C3.7's own cascade to
`BrokerReconciliation_CheckAll` already established.

Mutual exclusivity against C2.2's synchronous rejection and C3.7's
`CANDIDATE_EXECUTED` needs no new conflict-detection code: the same fresh
`StateProjector_TryGetState()`-immediately-before-every-write discipline
C3.7 already established, reused a third time, is sufficient - any
candidate already moved to a terminal state by another writer is excluded
via `skipped_not_submitted` before any lookup or write is attempted.

**Real bug found via the first real MetaEditor test run, fixed before
Checkpoint 3 sign-off.** All three happy-path tests
(`Test_HappyPath_Rejected/Canceled/Expired`) failed on
`StateProjector reports REJECTED_BY_BROKER immediately after C3.10B` -
the durable transition line was written correctly every time, but
`EventStore_LogTransition`'s own `c.state = to` mutation only updates the
LOCAL `TradeCandidate` variable, never the global `StateProjector`
registry `StateProjector_TryGetState()` reads from. C3.7's own real
production code (`LifecycleAuthorityProcessor.mqh`) already does the
correct thing after every successful transition write - re-read the
store, recover the REAL just-appended line (never fabricate), and call
`StateProjector_Apply` on it - and this file simply omitted that step.
Fixed by adding `C310B_FindMatchingRejectionTransition` (same backward-
scan shape as `C310B_FindMatchingRejectionConfirmation`/
`C37_FindMatchingExecutedLine`) plus the same 0/>1/apply-failure Safe
Mode branches C3.7 already established
(`transition_evidence_not_recovered`/`transition_evidence_ambiguous`/
`projector_apply_failed`), run immediately after every successful
`EventStore_LogTransition`.

Sealed files untouched:
`AsyncTerminalOrderObservationMatcher.mqh`, `BrokerTransactionObservation.mqh`,
`TransactionMatchingProjection.mqh`, `BrokerSubmissionAuditProjection.mqh`,
`BrokerSubmissionAuditReadiness.mqh`, `ExecutionAuditProjection.mqh`,
`LifecycleAuthorityProcessor.mqh`, `BrokerSubmissionAdapter.mqh`,
`DeferredTransactionProcessor.mqh`, `EventSerializer.mqh`, `EventStore.mqh`,
`EventStoreValidator.mqh`, `StateProjector.mqh`, `CandidateProjection.mqh`,
`BrokerReconciliation.mqh`, `StateMachine.mqh`. No `OnTick`/`OnTradeTransaction`
change, no forbidden broker API anywhere in the new file.

## [Unreleased] - C3.10A implementation: async terminal order observation matcher (IMPLEMENTING, awaiting real MetaEditor run, 2026-08-27)

`Include/MLQuantAI/Execution/MLQuantAI_AsyncTerminalOrderObservationMatcher.mqh`
(new) + `Tests/MLQuantAI_Test_C3_10A_AsyncTerminalOrderObservationMatcher.mq5`
(new). Read-only diagnostic, not wired into `OnInit`: scans the durable
`BROKER_TRANSACTION_OBSERVED` log for asynchronous, order-object-level
terminal outcomes (rejected/cancelled/expired - the arrive-later
counterpart to C2.2's own synchronous `OrderSend()`-time rejection) and
matches each to a submitted execution request / candidate via the
already-sealed `SubmissionOutcomeProjection` → `ExecutionRequestProjection`
lookup chain.

**Classification is real-demo-evidence-backed, not documentation-derived.**
The original design assumption (`TRADE_TRANSACTION_ORDER_UPDATE` carries
the terminal `order_state`) was captured live on a demo account and found
wrong: `ORDER_UPDATE` only ever carried transient states (`PLACED`,
`REQUEST_CANCEL`) in the captured evidence - all three real terminal
states (`ORDER_STATE_REJECTED`, `ORDER_STATE_CANCELED`,
`ORDER_STATE_EXPIRED`) appeared exclusively on
`TRADE_TRANSACTION_ORDER_DELETE`, with `TRADE_TRANSACTION_HISTORY_ADD`
mirroring the same terminal state on a second channel (deliberately
ignored in this slice, not deduped against `ORDER_DELETE`). The
`REJECTED` case specifically required a second, harder-to-construct demo
scenario (an accepted pending order later rejected at trigger time due to
insufficient margin) - a synchronous send-time rejection (`OrderSend()`
"No money" on a market order) was captured first and found to produce an
uninformative `TRADE_TRANSACTION_REQUEST` envelope with no order object
and no distinguishing field at all (the raw observation schema never
captures `result.retcode`), confirming that case is C2.2's own domain,
not this matcher's.

Matching hierarchy deliberately improves on one characteristic of C3.3's
own `TransactionMatching_ResolveExecutionRequestId`: multiple `SUBMITTED`
outcomes matching the same `order_ticket` resolve to `ATOM_AMBIGUOUS`,
never first-match-wins. A raw `order_ticket` seen on more than one
qualifying `ORDER_DELETE` terminal line within one scan escalates every
match for that ticket to `ATOM_AMBIGUOUS` in a deterministic post-pass,
with all three status counters recomputed from `matches[].status` alone
afterward (never incrementally patched during escalation, so there is no
drift).

`seq` validation (`ATOM_ValidateSeqToken`, file-local) validates the raw
token string via `EventSerializer_GetRawNumber` - an existing, sealed
parser surface - before any call to `StringToInteger`, whose behavior on
an oversized digit string is unspecified; same overflow-risk class C3.9's
`EPCA_GetLongArray` already guards against, applied here to a scalar
field instead of an array element.

Sealed files untouched: `MLQuantAI.mq5`,
`BrokerTransactionObservation.mqh`, `TransactionMatchingProjection.mqh`,
`BrokerSubmissionAuditProjection.mqh`, `BrokerSubmissionAuditReadiness.mqh`,
`ExecutionAuditProjection.mqh`, `LifecycleAuthorityProcessor.mqh`,
`DeferredTransactionProcessor.mqh`, `EventSerializer.mqh`, `EventStore.mqh`,
`EventStoreValidator.mqh`, `StateProjector.mqh`, `CandidateProjection.mqh`,
`BrokerReconciliation.mqh`, `StateMachine.mqh`. No `OnInit` wiring, no
`EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED`, no
`CANDIDATE_REJECTED_BY_BROKER` transition, no durable write in this
round.

## [Unreleased] - C3.9 implementation: cross-candidate execution provenance conflict auditor (IMPLEMENTING, awaiting real MetaEditor run, 2026-08-26)

`Include/MLQuantAI/Infrastructure/EventStore/MLQuantAI_ExecutionProvenanceConflictAuditor.mqh`
(new) + `Tests/MLQuantAI_Test_C3_9_ExecutionProvenanceConflictAuditor.mq5` (new).
Read-only diagnostic, not wired into `OnInit`: scans the full durable
lifecycle log for `CANDIDATE_EXECUTED` events and flags any broker-side
identifier (`execution_request_id`, `order_ticket`, or an individual
`deal_tickets_sorted` entry) claimed by more than one distinct
`candidate_id` - two different candidates both durably claiming the same
real broker fill.

**Planning history (same round)**: this started as C3.8A, a proposed
"Submission Idempotency Guard" sitting in front of C3.7's
`LifecycleAuthority_StartupApply()`. Investigation found no authentic
integration seam for it - that function takes only a `fileName`, is
called once per `OnInit`, and already performs a fresh
`StateProjector_TryGetState()` re-check per row that skips any
non-`SUBMITTED` candidate (including already-`EXECUTED` ones), so the
proposed guard would have duplicated existing, sealed, already-tested
behavior. C3.8A was cancelled; its planning branch
(`feat/c3-8-submission-idempotency-guard`) was abandoned, never merged.
The next candidate, an initial C3.9 "Semantic Lifecycle Integrity
Auditor" (full-log genesis-uniqueness / chain-continuity / transition-
legality checking), was found to have the identical problem:
`ReplayEngine_Run()` already folds every lifecycle line through
`StateProjector_Apply()` on every startup, which already enforces all
three of those rules and already trips Safe Mode
(`EventStoreHealth_TripSafeMode`, wired at `MLQuantAI.mq5:357-361`) on
any violation found anywhere in the durable history. C3.9 was narrowed to
the one genuinely non-overlapping gap: `StateProjector` only tracks state
per single `candidate_id` and never reads `extra_json` back, so nothing
in the sealed pipeline checks whether two *different* candidates'
provenance overlaps.

Public surface: `ExecutionProvenanceConflictAuditor_ScanLines(lines[], n)`
(pure - same `lines[]`-direct split `EventStoreValidator_ValidateLines`/
`_ValidateFile` and C3.7's own `C37_FindMatchingExecutedLine` already
establish) and `ExecutionProvenanceConflictAuditor_ScanFile(fileName)`
(thin wrapper). Identifier matching uses a typed pair
`(id_type, canonical_value)`, never a concatenated display string, so an
`execution_request_id` value that happens to look like `"order:123"` can
never collide with a real `order_ticket` of `123`. A file-local helper,
`EPCA_GetLongArray()`, parses `deal_tickets_sorted`'s unquoted-integer
array shape - not exported as a general `EventSerializer` API, since
`EventSerializer_GetStringArray` only ever decoded quoted-string arrays
and this is the only unquoted-integer array field the codebase writes.
Its parser validates a 19-digit token's magnitude against the exact
int64 bounds via string comparison before any numeric conversion (digit
count alone is insufficient - a 19-digit token can still exceed int64
max), and assigns the exact `INT64_MIN` boundary from the compiler's own
signed literal rather than a positive-magnitude-then-negate path, since
that value's magnitude cannot be represented as a positive `long` en
route to negation.

Memory growth is proportional to durable `CANDIDATE_EXECUTED` provenance
observed during the scan and is intentionally uncapped, consistent with
existing replay/validator conventions - no cap/limit pattern exists
anywhere else in this repository for this class of problem, and nothing
is ever silently truncated.

Sealed files untouched (confirmed by diff proof below):
`MLQuantAI.mq5`, `LifecycleAuthorityProcessor.mqh`, `EventSerializer.mqh`,
`EventStore.mqh`, `EventStoreValidator.mqh`, `StateMachine.mqh` (`Core/`,
not `Infrastructure/EventStore/` - a stale path in this round's earlier
sealed-file lists, corrected and reconfirmed against the real path),
`StateProjector.mqh`, `CandidateProjection.mqh`,
`DeferredTransactionProcessor.mqh`, `BrokerReconciliation.mqh`. No
`OnInit` wiring, no Safe Mode trip, no durable write in this round.

## [Unreleased] - C3.7 implementation: bounded lifecycle authority processor (IMPLEMENTING, awaiting real MetaEditor run, 2026-08-26)

**Amendment 3 (same round)**: adds a dedicated regression suite,
`Tests/MLQuantAI_Test_EventSerializer_ExtraJson.mq5`, testing
`EventSerializer_ParseLifecycle()`'s `extra_json` extraction directly -
required before merge given the fix lives in shared, sealed event-store
serialization code, not just C3.7's own boundary. 9 test functions, all
against hand-built raw JSONL lines mirroring `EventSerializer_ToJson()`'s
real field order (or the real `ToJson()` call itself for the round-trip
case), covering: a legacy line with no spliced fragment parses
`extra_json == ""` identically to pre-fix behavior; a simple flat
fragment extracts to the exact expected substring; a deliberately
escaped-quote/backslash `reason` value (synthetic - no current emitter
produces one, but the scanner itself must be correct regardless) still
lets the fragment extract correctly; a fragment containing its own
nested quotes/braces/brackets/arrays is preserved byte-for-byte; a real
`LifecycleEvent` round-trips through the real `ToJson()`/`ParseLifecycle()`
pair losslessly, `extra_json` included; three malformed-input cases
(missing closing quote on `reason`, missing final closing brace,
a dangling escape at end-of-line) each prove the required fail-closed
invariant - `extra_json` stays empty, never a truncated partial
fragment exposed as valid data; and a real C3.7-shaped fragment
(mirroring `C37_BuildExtraJson`'s frozen field set) parses correctly and
lets `C37_FindMatchingExecutedLine()` identify its own `action_id`
unambiguously, closing the loop between this fix and what C3.7 actually
depends on.

**Amendment (same round)**: real MetaEditor runs surfaced a genuine,
previously-latent bug in the sealed
`Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh` -
`EventSerializer_ParseLifecycle()` parsed every fixed `LifecycleEvent`
field (`candidate_id`, `from_state`/`to_state`, `reason`,
`sequence_number`, `log_event_id`, ...) but never populated
`out.extra_json` at all, leaving it at its `LifecycleEvent_Init()`
default (`""`). `EventSerializer_ToJson()`'s own write side splices
`extra_json` in as raw trailing key:value pairs after `"reason"` and
before the closing `}` (never nested under its own key) - the read side
simply never reversed that splice, because no consumer before C3.7 ever
needed a parsed event's `extra_json` back (`ReplayEngine_Run`,
`StateProjector`, `EventStoreValidator` only ever need the fixed replay
fields). C3.7's own `C37_FindMatchingExecutedLine()` is the first
caller in the codebase to require it, so every durable-evidence
recovery attempt failed with `evidence_not_recovered` until this was
found and fixed - diagnosed via a temporary log statement (added, run,
then removed within this same round) that proved the read-back itself
was correct (`n=14` lines, the right line present as raw text) while the
*parsed* `extra_json` field was empty.

Fix (`EventSerializer_ParseLifecycle`, minimal and additive): after
parsing `reason` (always the last fixed field), locate the end of its
value and, if a comma follows rather than the closing brace, capture
everything from there to the line's final `}` as `out.extra_json` -
mirroring the write side's own splice convention exactly. Verified no
other caller anywhere in `Include/` reads a parsed event's
`.extra_json`, so this is a pure bug fix with no behavior change for
any existing consumer.

This is the one file outside C3.7's original allowlist touched this
round, added with the user's explicit authorization once the root cause
was isolated and a minimal fix proposed.

**Amendment 2 (same round)**: with the `extra_json` fix in place, a real
MetaEditor run reached 128/133, with every remaining failure isolated to
`Test_ProjectorApplyFailure_SafeModeStopsScan`. Its fixture (pre-corrupt
`StateProjector`'s state for the candidate to `CANDIDATE_ERROR`, then
call `LifecycleAuthority_StartupApply`) does not reach the
`projector_apply_failed` branch at all: the same run showed
`skipped_not_submitted=1` and `report.ok=true` - the function's own
fresh `StateProjector_TryGetState()` re-check reads that exact corrupted
state *first* and defensively skips the row, before either the durable
write or the later `StateProjector_Apply(recovered, ...)` call is ever
reached. Since nothing mutates `StateProjector`'s registry between that
fresh check and the later apply within one synchronous,
single-threaded loop iteration, `StateProjector_Apply`'s own
`current != e.from_state` branch cannot be triggered through
`LifecycleAuthority_StartupApply`'s public entry point at all - real,
run-confirmed evidence of the same structural-unreachability category as
item 5's `CandidateProjection`-missing guard.

Per the user's authorization, `Test_ProjectorApplyFailure_SafeModeStopsScan`
is converted from an injected-fixture attempt to a structural-inspection
proof (matching `Test_CandidateProjectionLineage_StructuralInvariant`'s
own pattern): the `projector_apply_failed` branch remains real, compiled,
frozen-contract-required defense-in-depth, kept for a divergence that can
only arise from a future change to `StateProjector_Apply`'s own
consistency rule or a non-single-threaded execution model - not dead
code, not removed, just proven unreachable-by-design rather than
constructed.

Implements the C3.7 contract frozen below
(`Docs/PhaseC_C3_7_BoundedLifecycleAuthorityContract.md`) on baseline
`mlquantai@dd9f2aa`. Not yet merged; not yet compiled or run by the
author (no compiler available in this environment) - pending the user's
own real MetaEditor compile + test evidence before any merge.

New `Execution/MLQuantAI_LifecycleAuthorityProcessor.mqh`:
- `LifecycleAuthorityReport` (tallies + `scan_stopped_early`/`stop_reason`
  observability fields) and `LifecycleAuthority_StartupApply(fileName)`,
  the sole `OnInit`-time entry point.
- First pass tallies every C3.6 `DeferredRecommendationRecord` row
  (`blocked_count`/`none_count`/`eligible_count`) over the complete
  registry and emits at most one summary `LogWarn` if any row is
  `RECOMMEND_BLOCKED` - never per-row.
- Second pass attempts a real `EventStore_LogTransition(...,
  CANDIDATE_EXECUTED, REASON_EXECUTED_OK, extraJson)` for every
  `RECOMMEND_EXECUTED` row, after re-checking a *fresh*
  `StateProjector_TryGetState() == CANDIDATE_SUBMITTED` and reconstructing
  the `TradeCandidate` from `CandidateProjection_TryGet()` +
  `StateProjector_TryGetState()` (never `CandidateProjectionRecord.state`).
- Never fabricates the `LifecycleEvent` fed to `StateProjector_Apply()`.
  After a successful durable write, `C37_FindMatchingExecutedLine()` reads
  the store back via the existing sealed `EventStore_ReadAllLines()` and
  scans backward through `EventSerializer_ParseLifecycle()`-parsed lines,
  matching every field explicitly (candidate_id, from/to state, reason,
  and the row's own `c3_6_action_id` inside `extra_json`) - never assuming
  the last line is the just-written one. Exactly one match is required:
  zero or multiple matches both `SafeMode_Trip()` and stop the scan.
- **Corrects the merged design contract's §3/§9 failure semantics**: on a
  durable-write failure, the scan now **stops immediately** (`SafeMode_Trip`
  already fires inside `EventStore_LogTransition`; this file additionally
  returns without attempting any further row), rather than the contract
  document's original "continue to the next row" text - a correction the
  user gave after the docs-only contract had already been merged, on the
  reasoning that continuing after Safe Mode engages would violate
  fail-closed semantics. The contract document itself is unchanged this
  round; this note is the record of the supersession pending a future
  doc-amendment round.
- No new `ENUM_EVENT_TYPE`/`ENUM_REASON_CODE` value. No `RECOMMEND_REJECTED`
  handling (remains reserved, non-emittable - not a member of
  `ENUM_RECOMMENDED_ACTION` at all). No durable idempotency registry - relies
  on the sealed terminal-state guard (`CANDIDATE_EXECUTED` is terminal) plus
  C3.6's own proven at-most-one-`RECOMMEND_EXECUTED`-row-per-candidate
  guarantee.

`MLQuantAI.mq5`: adds the new include; replaces the previously
unconditional `BrokerReconciliation_CheckAll()` call in `OnInit` with a
call gated on `LifecycleAuthority_StartupApply()`'s own `report.ok`, so a
scan that stopped early (durable-write failure, evidence not recovered,
ambiguous evidence, or a `StateProjector_Apply` failure) skips reconciling
against a provably-diverged read model this session. `BrokerReconciliation.mqh`
itself is not edited.

New `Tests/MLQuantAI_Test_C3_7_LifecycleAuthorityProcessor.mq5`: 13 test
functions covering the full frozen test matrix, including structural-only
proofs (no injected C3.6 registry row, no fabricated MT5 position, no real
`BrokerReconciliation_CheckAll()` call from this suite) for the two items
the user required to be proven that way, an isolated-helper technique for
the zero-match/multiple-match evidence-recovery cases, and a two-candidate
fixture (`Test_DurableWriteFailure_SafeModeStopsScan`) proving the second
candidate is never even attempted after the first candidate's durable
write fails.

## [Unreleased] - C3.7 bounded lifecycle authority design contract (DESIGN ONLY, docs-only, 2026-08-26)

Docs-only design contract on baseline `mlquantai@b2751c9` (C1–C3.6
sealed; C3.6 `DeferredTransactionProcessor` produces read-only
`RECOMMEND_EXECUTED`/`RECOMMEND_NONE`/`RECOMMEND_BLOCKED` recommendation
rows, zero lifecycle authority). No `.mqh`/`.mq5` file, no test file, no
`MLQuantAI.mq5` wiring, no new `ENUM_EVENT_TYPE`/`ENUM_REASON_CODE`
value, no compile, no test run.

C3.7 is frozen as the **sole** component authorized to turn a C3.6
`RECOMMEND_EXECUTED` row into a real `CANDIDATE_SUBMITTED →
CANDIDATE_EXECUTED` transition, via the existing sealed
`EventStore_LogTransition()` - the same production write path C2.2's
`BrokerSubmissionAdapter` already uses. No new `ENUM_EVENT_TYPE`
(`EVENT_TYPE_CANDIDATE_EXECUTED` already exists, sealed) and no new
`ENUM_REASON_CODE` (`REASON_EXECUTED_OK` already exists, sealed,
currently unused by any production emitter) are needed.

Freezes, per the user's explicit decisions on 4 points plus the
supporting research findings:

**`RECOMMEND_EXECUTED` is evidence, never write-time authority**: before
transitioning, C3.7 must re-validate upstream readiness, a *fresh*
`StateProjector_TryGetState() == CANDIDATE_SUBMITTED` (never
`DeferredRecommendationRecord.candidate_state_evidence`, a C3.6-scan-time
snapshot), that a `CandidateProjection` record exists, and that the
recommendation's provenance is structurally complete.

**Startup placement, adopts synchronous `StateProjector` sync**: C3.7
slots into `OnInit` between `DeferredTransactionProcessor_StartupScan`
(C3.6) and `BrokerReconciliation_CheckAll`. On a successful durable
transition, `StateProjector_Apply()` is called synchronously so
`BrokerReconciliation_CheckAll()` - which reads `StateProjector`'s own
registry directly - sees this session's own fresh `EXECUTED` candidates
immediately, rather than waiting a full restart. If the durable write
fails: inherited `SafeMode_Trip` (unchanged `EventStore_LogTransition`
behavior), continue to the next row. If the durable write succeeds but
the local `StateProjector_Apply` fails: `SafeMode_Trip` immediately, stop
processing further rows, and skip `BrokerReconciliation_CheckAll()`
entirely this session (reconciling against a provably-diverged read
model would be worse than skipping it). `BrokerReconciliation.mqh`
itself is never edited - only its effective position/scope in `OnInit`.

**Candidate assembly, two-source reconstruction**: `candidate_id` /
`root_event_id` / `correlation_id` / `strategy_id` from
`CandidateProjection_TryGet()`; `.state` *only* from
`StateProjector_TryGetState()` (never `CandidateProjectionRecord.state`,
which is always `CANDIDATE_CREATED` in that B6-only projection) - because
unlike C2.2's continuously-held in-session `TradeCandidate` object, C3.7's
candidate may have reached `SUBMITTED` in an *earlier* session and there
is no live object to reuse.

**No new durable idempotency registry - explicit deviation from C3.5
§9's own default assumption** (which sketched mirroring C2.3's
`BrokerSubmissionAuditProjection` registry precedent): the sealed
terminal-state guard (`CANDIDATE_EXECUTED` is terminal;
`StateMachine_CanTransition(EXECUTED, *)` is always `false`) combined
with C3.6's own already-tested guarantee (at most one
`RECOMMEND_EXECUTED` row per `candidate_id` per scan) is a complete
idempotency story for this specific terminal transition - a parallel
durable registry would be redundant machinery. Explicitly scoped: this
reasoning is a property of *this* terminal transition, not a reusable
abstraction for any future non-terminal lifecycle authority.

**One summary observability `LogWarn`** if `blocked_count > 0` after
C3.6's scan ("C3.7 lifecycle authority: N recommendation(s) blocked; no
blocked row was transitioned.") - never per-row, no Safe Mode, no broker
read. `RECOMMEND_NONE` rows produce no warning (expected, non-terminal
condition).

**`extra_json` provenance contract** (frozen field set, copied verbatim
from the `RECOMMEND_EXECUTED` row, never recomputed): schema version,
`c3_6_action_id`, `execution_request_id`, `order_ticket`, sorted
`deal_tickets`, `terminal_match_status`, `running_filled_volume`,
`intended_lot_size`, and source log-event-id/sequence-number provenance
for both the execution request and every deal.

**File naming**: `MLQuantAI_LifecycleAuthorityProcessor.mqh` /
`MLQuantAI_Test_C3_7_LifecycleAuthorityProcessor.mq5` - named by role
(the sole bounded-lifecycle-authority holder), not by phase number,
matching `MLQuantAI_BrokerReconciliation.mqh`/`MLQuantAI_StateProjector.mqh`'s
own naming convention.

Also freezes an 18-item required test matrix (design-only, no test file
authorized here) and the implementation-round file allowlist. Still not
authorized: any `.mqh`/`.mq5` file, any `MLQuantAI.mq5` wiring, any
compile or test run, any edit to `BrokerReconciliation.mqh` or any other
sealed file, and any `RECOMMEND_REJECTED` handling (remains reserved,
non-emittable).

## [Unreleased] - C3.6 implementation: deferred-transaction-processor (PASSED 760/760, real MetaEditor run, 2026-08-26)

Implements the C3.6 contract frozen below
(`Docs/PhaseC_C3_6_DeferredTransactionProcessorContract.md`) - an
`OnInit`-only, read-only recommendation read model over already-sealed
C3.3 transaction-matching evidence + replayed candidate state. Produces
`DeferredRecommendationRecord` rows only: `RECOMMEND_NONE` /
`RECOMMEND_EXECUTED` / `RECOMMEND_BLOCKED`. NOT a lifecycle transition,
NOT an event, NOT a mutation of any sealed projection.
`RECOMMEND_EXECUTED` is a recommendation row only - turning it into a
real `SUBMITTED → EXECUTED` transition is C3.7, a separately authorized
future contract.

New `Execution/MLQuantAI_DeferredTransactionProcessor.mqh`:
- `DeferredRecommendationRecord` (frozen field set, contract §10):
  identity/evidence fields, per-deal/execution-request provenance,
  candidate lineage, and a `stale_after_startup` session-scope marker.
- Internal `candidate_id → execution_request_id` reverse index (contract
  §6), built from `ExecutionRequestProjection` only, entirely inside this
  file - no sealed-projection edit. 0 mappings → `RECOMMEND_BLOCKED`; 1 →
  usable; >1 → `RECOMMEND_BLOCKED`.
- An ambiguous-implicated set: since C3.3 clears
  `matched_execution_request_id` for `AMBIGUOUS` orders, a candidate
  whose execution request is implicated in an ambiguous order is
  independently detected and `RECOMMEND_BLOCKED`, rather than silently
  falling through to `RECOMMEND_NONE`.
- The 7 eligibility clauses (contract §7), evaluated in order:
  `candidate.state == CANDIDATE_SUBMITTED` (sole source: `StateProjector`,
  populated by `ReplayEngine_Run` - not `CandidateProjection`, which only
  ever holds `CREATED`); unique reverse-index mapping; unique matching
  `OrderAggregateRecord`; `match_status == MATCHED_VOLUME_REACHED`;
  identity round-trip re-verification; volume evidence recomputed and
  compared with exact equality (no new epsilon, per contract); running
  filled volume re-confirmed against `intended_lot_size`.
- Deterministic `action_id` (contract §11): `candidate_id` +
  `execution_request_id` + `order_ticket` + `MATCHED_VOLUME_REACHED` +
  sorted deal-ticket set + a `v1` contract-version suffix - never a
  wall-clock, session ID, or file line number.
- Within-scan duplicate/collision guard (contract §12) and semantic
  output ordering (contract §13: `candidate_id` ASC → `execution_request_id`
  ASC → `order_ticket` ASC → `action_id` ASC), re-sorted after every scan
  so no caller can rely on file/insertion order.
- Two scan-level fail-closed gates (contract §5/§7, zero rows emitted,
  never a row-level `RECOMMEND_BLOCKED`): `EventStoreHealth_IsSafeMode()`
  (`upstream_replay_not_ready`) and `TransactionMatchingReadiness`
  (`upstream_readiness_not_ready`). Neither trips Safe Mode nor blocks EA
  initialization - C3.6 fails closed on itself only.

`MLQuantAI.mq5`: adds the include and one `OnInit` call site -
`DeferredTransactionProcessor_StartupScan(g_EventStoreFileName);` -
placed after `ReplayEngine_Run` and before `BrokerReconciliation_CheckAll`,
per the frozen contract §3 ordering (candidate state requires the
replayed `StateProjector`, not just the C3.3/C3.4 read model alone).

New `Tests/MLQuantAI_Test_C3_6_DeferredTransactionProcessor.mq5`:
14 fixture-only test functions (146 checks) covering the full contract §17
matrix - full match → `RECOMMEND_EXECUTED`; partial fill / no fill /
candidate-not-submitted → `RECOMMEND_NONE`; ambiguous-implicated / >1
execution-request mappings / 0 execution-request mappings →
`RECOMMEND_BLOCKED`; scan-level replay-not-ready and readiness-not-ready
→ zero rows; cold-rebuild and repeated-scan determinism; deal-ticket
emission-order independence; semantic output ordering; and a combined
structural-proof test covering: within-scan duplicate/collision on the
same `action_id` (proven structurally unreachable, since `action_id`
embeds `candidate_id` and each candidate is visited exactly once per
scan - same "verified by inspection, not independently reproducible"
category as C2.2's own `bid<=0.0` branch precedent), `RECOMMEND_REJECTED`
absence (real `RecommendationToString` round-trip plus enum-membership
inspection), no forbidden API (static scan), and stale-after-OnInit (no
`OnTick`/`OnTradeTransaction` path exists).

Source-text scan (zero non-comment hits) confirms no
`OrderSend`/`CTrade`/`History*`/`Position*`/`OrderGetTicket`/
`EventStore_LogTransition` call, and no `RECOMMEND_REJECTED`, anywhere in
the new processor or test file.

Full regression, real MetaEditor run, zero regressions - `MLQuantAI.mq5`
compile 0 errors/0 warnings, new test compile 0 errors/0 warnings:
new C3.6 suite 146/146, `Test_C3_3_TransactionMatchingProjection` 109/109,
`Test_C3_4_TransactionMatchingReadiness` 57/57,
`Test_C2_2_BrokerSubmissionGate` 147/147,
`Test_C2_3_BrokerSubmissionAuditProjection` 104/104,
`Test_C2_BrokerSubmissionGate_DurableIdempotency` 41/41,
`Test_C2_EnvironmentLockGate` 45/45, `Test_C2_ManualApprovalEmission`
38/38, `Test_C2_ManualApprovalProjection` 73/73 - C2 baseline 448/448
matching the pre-existing baseline exactly. Combined total this round:
448 + 109 + 57 + 146 = **760/760**.

After this merge: no candidate transition and no action event exist
anywhere in the codebase. C3.7 (bounded lifecycle authority - the sole
round permitted to turn a `RECOMMEND_EXECUTED` row into a real
`SUBMITTED → EXECUTED` transition) remains blocked until this evidence is
reviewed and merge is explicitly authorized.

## [Unreleased] - C3.6 deferred-transaction-processor design contract (DESIGN ONLY, docs-only, 2026-08-23)

Docs-only design contract on baseline `mlquantai@f9d3ade` (C1–C3.4 sealed;
C3.5 frozen; Phase 0.3 gate CLOSED; C3.6 UNLOCKED). No `.mqh`/`.mq5` file,
no test file, no `MLQuantAI.mq5` wiring, no new `ENUM_EVENT_TYPE` value, no
new projection struct/API, no `EventStore_LogTransition`, no lifecycle
transition, no broker API, no compile, no test run.

- **Purpose**: C3.6 turns sealed transaction-matching evidence into a
  read-only recommendation read model. `RECOMMEND_EXECUTED` is a
  recommendation row, NOT a `SUBMITTED → EXECUTED` transition. Lifecycle
  authority is C3.7 (separately authorized).
- **Startup placement (refines C3.5 §10)**: `DeferredTransactionProcessor_
  StartupScan` slots in `OnInit` between `ReplayEngine_Run` and
  `BrokerReconciliation_CheckAll`, because `CANDIDATE_SUBMITTED` comes from
  `StateProjector` (populated by `ReplayEngine_Run`), not `CandidateProjection`.
- **Replay-failure semantics**: replay not ok / SafeMode engaged → zero
  recommendations, `upstream_replay_not_ready` diagnostic, no new SafeMode
  action, no EA-init block from C3.6.
- **Candidate → execution_request_id reverse index** (contract, not impl
  detail): built from `ExecutionRequestProjection` only; 0 mappings →
  `RECOMMEND_BLOCKED`; 1 → usable; >1 → `RECOMMEND_BLOCKED`. No symbol/time/
  order/correlation fallback. No sealed-projection edit.
- **Recommendation vocabulary**: only `RECOMMEND_NONE`, `RECOMMEND_EXECUTED`,
  `RECOMMEND_BLOCKED`. `RECOMMEND_REJECTED` must not exist as enum member,
  output row, event, or side effect.
- **Deterministic action_id**: `C36|EXECUTED|candidate_id|execution_request_id|
  order_ticket|MATCHED_VOLUME_REACHED|[sorted deal_tickets]|v1`. No session ID,
  wall-clock, line number, rebuild order, log text, or `rebuilt_at`.
- **Semantic output ordering**: `candidate_id ASC → execution_request_id ASC
  → order_ticket ASC → sorted deal-ticket set / action_id ASC`. No file-order
  reliance.
- **Idempotency/duplicates (adjusted)**: registry resets every scan;
  within-scan duplicate (same action_id + identical payload) collapses to one
  row; across cold scans the same semantic output is reconstructed once, not a
  durable already-applied action; collision (same action_id + different
  payload) → `RECOMMEND_BLOCKED`. "Already applied" must not mean lifecycle
  action in C3.6.
- **Stale-after-OnInit**: snapshot only; no `OnTick`/`OnTradeTransaction`
  update, no timer, no incremental queue.
- **Implementation allowlist** (for separately authorized Commit 2): new
  `Execution/MLQuantAI_DeferredTransactionProcessor.mqh` + new test + one
  `OnInit` wiring line in `MLQuantAI.mq5`. Existing projections read-only.

The contract is not the implementation. C3.6 Commit 2 (implementation) and
C3.7 (lifecycle authority) remain separately authorized, in order.

## [Unreleased] - Phase 0.3 fixture implementation: A negative + B positive test (2026-08-23)

Implementation of the Phase 0.3 fixture-debt gate decision on branch
`phase0.3-fixture-implementation` from `mlquantai@6851ac0`. One new test
file only: `Tests/MLQuantAI_Test_Phase0_3_FixtureDebtGate.mq5` (+ docs
status). No production `.mqh`/`.mq5` source, no sealed file, no
`MLQuantAI.mq5`, no C3.3/C3.4/C3.5 semantics change, no new
`ENUM_EVENT_TYPE` value, no `DeferredTransactionProcessor`, no
`RECOMMEND_EXECUTED` emission, no action-event write, no new lifecycle
transition (no `EXECUTED`), no `OnTick`/`OnTradeTransaction` change, no
`History*`/`Position*`/`Order*` API, no `OrderSend`/`CTrade`, no
daily/historical store access.

- **A — Negative diagnostic fixture**: builds a fully valid candidate
  struct in memory (via `CRT_DetectV1` + `CRT_ToTradeCandidate`, suffix
  `NEGORPHAN`, non-empty `context_event_id`) and emits ONLY
  `CRT_EmitCandidateCreated` into a dedicated store
  (`MLQuantAI_Test_Phase0_3_NegativeOrphanFixture.jsonl`) with NO
  `MARKET_CONTEXT_READY`. `CandidateProjection_RebuildFromFile` returns
  `ok=false`, `lines_failed>0`, `lines_applied==0`, `first_error` contains
  the stable `orphan candidate:` cause, and `first_error_code ==
  CANDPROJ_REASON_ORPHAN_CONTEXT` — NOT a timestamp/session/line-number
  fluke. The negative fixture file (line count + byte size) is asserted
  unchanged by the read-only rebuild.
- **B — Canonical positive fixture**: generated-at-test-start dedicated
  store (`MLQuantAI_Test_Phase0_3_CanonicalPositiveFixture.jsonl`) carrying
  the full chain the real C2.3/C3.3 rebuild requires: `MARKET_CONTEXT_READY
  → CANDIDATE_CREATED → EXECUTION_REQUEST_CREATED →
  EXECUTION_DRY_RUN_COMPLETED(ACCEPTED) → EXECUTION_SUBMISSION_ATTEMPTED
  → ORDER_SUBMITTED → BROKER_TRANSACTION_OBSERVED(DEAL_ADD) →
  MATCHED_VOLUME_REACHED`. Fixed constants for IDs/tickets/timestamps
  (`submittedAt = D'2026.07.15 12:00:00' + dayOffset*86400`, NOT
  `TimeCurrent()`). Proves `CandidateProjection` +
  `BrokerSubmissionAuditProjection` + `TransactionMatching` rebuilds are
  all clean (zero failed lines), the order resolves to
  `MATCHED_VOLUME_REACHED`, and the join chain resolves uniquely:
  `deal_ticket → order_ticket → execution_request_id → candidate_id →
  CANDIDATE_SUBMITTED` (the sealed SUBMITTED waypoint; no `EXECUTED`,
  C3.6 does not exist yet). Deterministic across two cold rebuilds.
- **C — C3.5 readiness evidence ONLY**: asserts the fixture exposes the
  immutable semantic facts a future C3.6 `action_id` would consume
  (`candidate_id`, `execution_request_id`, `order_ticket`, terminal
  `MATCHED_VOLUME_REACHED`, sorted `deal_ticket` set) and that a local
  read-only `future_action_id_input_key` over those facts is identical
  across two rebuilds. Does NOT create the processor, does NOT emit
  `RECOMMEND_EXECUTED`, does NOT write an action event, makes no DIRECT
  `EventStore_LogTransition` call, performs no new C3.6 transition.
- **Isolation**: every fixture is a dedicated test-owned store; no test
  opens/reads/writes/deletes/renames/truncates
  `MLQuantAI_events_2026-08-21.jsonl` or any `MLQuantAI_events_*.jsonl`
  daily/historical store.

The gate is NOT closed by this commit alone. It closes only when the user
compiles the new test in MetaEditor (0 errors / 0 warnings), the new Phase
0.3 suite passes, and the full regression baseline still passes (C3.3
109/109, C3.4 57/57, C2.3 104/104, C2 448/448, main EA 0/0).

## [Unreleased] - Phase 0.3 fixture-debt gate decision contract (DESIGN ONLY, docs-only, 2026-08-23)

Docs-only decision on baseline `mlquantai@b75ce34` (B5–B9, C1–C2, C3.1–C3.4
sealed; C3.5 contract frozen). No fixture file, no test file, no
`.mqh`/`.mq5` source, no sealed file touched, no new `ENUM_EVENT_TYPE`
value, no `EventStore_LogTransition` call, no `OnTick`/
`OnTradeTransaction` change, no `History*`/`Position*`/`Order*` API, no
`OrderSend`/`CTrade`, no candidate-lifecycle transition, no C3.6
`DeferredTransactionProcessor` code.

Freezes the A+B fixture split that unblocks C3.6:

- **A — Historical negative fixture**: `MLQuantAI_events_2026-08-21.jsonl`
  is permanently READ-ONLY historical evidence — never renamed, deleted,
  truncated, appended, normalized, or opened for read or write by any
  automated test. Automated negative testing uses a **dedicated**
  fixture (a source-controlled copy in `Tests/Fixtures/` with recorded
  provenance + SHA-256, or a minimal orphan fixture generated at test
  start from a documented bad-line pattern), never the live daily store.
- **B — Canonical positive fixture**: a generated-at-test-start
  dedicated `.jsonl` store (existing `TEST_FILE` + `FileDelete` +
  `EventStore_Open` convention) carrying the full chain the real
  C2.3/C3.3 rebuild requires: `MARKET_CONTEXT_READY →
  CANDIDATE_CREATED → EXECUTION_REQUEST_CREATED →
  EXECUTION_DRY_RUN_COMPLETED (ACCEPTED) →
  EXECUTION_SUBMISSION_ATTEMPTED → ORDER_SUBMITTED /
  SUBMISSION_STATUS_SUBMITTED → BROKER_TRANSACTION_OBSERVED DEAL_ADD
  → C3.3 MATCHED_VOLUME_REACHED → (future C3.6) RECOMMEND_EXECUTED`.
  IDs/tickets/timestamps/prices/volumes from fixed constants; cold
  rebuild yields identical projection state and `match_status`.
- **Negative assertion**: asserts the failure boundary and cause
  (rebuild `ok=false`, `lines_failed>0`, diagnostic names the stable
  orphan-candidate cause at CandidateProjection or a downstream stage
  gating through it) — never brittle timestamp/session/sequence/
  line-number equality, never a catch-all "failed".
- **action_id identity** (for C3.6): derives from semantic immutable
  evidence first (`candidate_id`, `execution_request_id`, `action_type`,
  `order_ticket`, terminal `MATCHED_VOLUME_REACHED`, sorted
  `deal_ticket` set) — not from `EventStore` `session_id` or append
  sequence unless those are deterministic in the fixture.
- **Isolation**: every test uses a dedicated store; no test touches any
  daily production-named store; cleanup never touches negative
  historical evidence; each fixture has exactly one owning test.
- **C3.6 readiness**: positive fixture reconstructs
  `CandidateProjection → ExecutionAuditProjection →
  BrokerSubmissionAuditProjection → TransactionMatchingProjection`;
  covers full-match, partial, unmatched, ambiguous/collision cases
  (some promotable to C3.6-specific fixtures).
- **Definition of Done**: the gate is NOT closed by this doc. It closes
  only when both the negative diagnostic test and the canonical positive
  fixture test exist and pass; until then C3.6 remains blocked per the
  C3.5 contract.

Full frozen decision: `Docs/Phase0_3_FixtureDebtGate.md`. The Phase 0.3
implementation (actual negative + positive test files and any fixture
copies) is a separate, later branch authorized only after this decision
is merged.

## [Unreleased] - C3.5 deferred-transaction-authority design contract (DESIGN ONLY, docs-only, 2026-08-23)

Docs-only contract on baseline `mlquantai@8321448` (C1–C3.4 sealed). No
new code, no `.mqh`/`.mq5` file, no sealed file touched, no new
`ENUM_EVENT_TYPE` value, no `EventStore_LogTransition` call, no
`OnTick`/`OnTradeTransaction` change, no `History*`/`Position*`/`Order*`
API, no `OrderSend`/`CTrade`, no candidate-lifecycle transition.

Freezes the authority boundary before any processor is built:

- **Sole owner**: the future `DeferredTransactionProcessor` is the only
  component permitted to propose/process broker-fact-derived candidate
  lifecycle actions. Every projection, readiness wrapper, callback, and
  reconciliation component keeps its current role unchanged; only the
  future processor gains (in C3.7, separately authorized) lifecycle
  authority.
- **Authority gap, frozen**: no production broker-fill evidence consumer
  currently emits `CANDIDATE_EXECUTED`. Excluding synthetic smoke/test
  fixtures, the normal submission path only moves candidates to
  `SUBMITTED` or immediate `REJECTED_BY_BROKER` from
  `BrokerSubmissionAdapter`. `CANDIDATE_EXECUTED` is legal-but-unused.
- **Evidence chain**: `deal_ticket` -> C3.3 `ResolveExecutionRequestId`
  (matches only `SUBMISSION_STATUS_SUBMITTED` outcomes) ->
  `execution_request_id` -> C1.3 -> `candidate_id` -> CandidateProjection
  `state`.
- **Eligibility predicate** (`SUBMITTED -> EXECUTED`, design-only):
  candidate `SUBMITTED` + unique `execution_request_id` mapping +
  `MATCHED_VOLUME_REACHED` + identity round-trip + no conflicting mapping
  + internally consistent volume/order/deal evidence + no prior applied
  action + all upstream projections `.ok`.
- **Rejection separation**: deferred `RECOMMEND_REJECTED` is reserved and
  non-emittable under current C3.3 inputs; no rejection from no-fill,
  delay, timeout, `UNMATCHED`, absence of a live position, or stale
  snapshot.
- **Partial-fill**: stays `SUBMITTED` + recommendation `NONE`; reuses
  C3.3's existing `MATCHED_VOLUME_REACHED` semantics exactly.
- **Trigger model**: C3.6 starts as `OnInit`-only read-only
  recommendation scan (Option A); no `OnTick` full rebuild, no incremental
  `OnTradeTransaction` update.
- **Idempotency**: deterministic, replay-stable `action_id` derived from
  immutable evidence (candidate + request + action type + order ticket +
  terminal match status + sorted source deal/event identity).
- **Frozen constraint**: `TX_MATCH_ORDER_TERMINAL` is reserved/never
  assigned by C3.3, so only `MATCHED_VOLUME_REACHED` is a fill signal.
- **Fixture-debt boundary**: old daily store stays read-only evidence;
  clean canonical positive + negative fixtures are required before C3.6
  implementation acceptance (separate test-data-only decision, not this
  merge).

Full frozen contract: `Docs/PhaseC_C3_5_DeferredAuthorityContract.md`.
Implementation (C3.6), lifecycle authority (C3.7), reconciliation
integration (C3.8), recovery/history (C4), controlled execution (C5),
position/exit lifecycle (C6), and operational hardening (C7) remain
separately-authorized future steps.

## [Unreleased] - Step 8.5 smoke-test fixture fix: no longer orphans itself (PASSED 626/626, real MetaEditor run, 2026-08-23)

Test-only fix, scoped entirely to `RunRuntimeLifecycleSmokeTest()` and
its own new helper functions in `MLQuantAI.mq5` - no production
candidate-creation path, no `CandidateProjection` validation rule, no
other file, touched.

**Finding**: the smoke-test candidate has never actually been schema-
conformant with `CandidateProjection` (`Infrastructure/EventStore/
MLQuantAI_CandidateProjection.mqh`) since B6.1 introduced its validation
chain - it called `EventStore_LogCandidateCreated(smoke)` with no
`extra_json` at all, so `candidate_schema_version`/`context_event_id`/
`context_hash`/`candidate_hash`/`detector_hash`/`side`/
`setup_anchor_bar_time`/`expiry_time`/`expiry_after_bars`/
`entry_hint`/`sl_hint`/`tp_hint`/`trigger_reason_mask`/
`trigger_reasons[]` were all absent - a much larger gap than the
originally-suspected "missing `MARKET_CONTEXT_READY`" alone.

**Fix**: `RunRuntimeLifecycleSmokeTest()` now durably logs its own
synthetic `MARKET_CONTEXT_READY` line first (`BuildSmokeTestContext()`,
namespaced `instrument_id`/`trigger_timeframe` = `"SMOKE"` so it can
never collide with a real `MarketContext`), then supplies every field
`CandidateProjection_ApplyLine` requires via a new
`SmokeTestCandidateCreatedExtraJson()` fragment - including a
deterministic, synthetic `trigger_reason_mask`
(`SMOKE_TEST_REASON_MASK`) that satisfies
`CandidateProjection_ValidateReasonConsistency`'s CRT_V1-derived XOR/
required-bit rules, since that check runs unconditionally against the
same shared vocabulary regardless of which strategy produced the line.
This candidate is explicitly tagged synthetic to every other consumer
(`strategy_id = -1`, `strategy_name = "RuntimeLifecycleSmokeTest"`,
`candidate_hash`/`detector_hash` prefixed `SMOKE_`) - it does not claim
a real CRT_V1 detection happened.

**Scope boundary, explicit**: this fix prevents *future* smoke-test
candidates (in *new*, not-yet-created event store files) from becoming
orphans. It does **not** retroactively repair whatever already-orphaned
line exists in a pre-existing event store file written before this fix -
only a fresh, date-stamped file (the default naming convention) or
explicit manual cleanup addresses that pre-existing condition.

**Verification (real MetaEditor run, 2026-08-23)**: `MLQuantAI.mq5` compiles
with 0 errors / 0 warnings, and the full regression gate passes:

- Isolated forward-behavior test (`Tests/MLQuantAI_Test_SmokeOrphanFixtureFix.mq5`,
  dedicated test store, 12/12): the smoke candidate now carries full
  `MARKET_CONTEXT_READY` -> `CANDIDATE_CREATED` lineage and replays cleanly
  through `CandidateProjection` -> `BrokerSubmissionAudit` ->
  `ManualApproval` -> `TransactionMatching` startup-rebuild chain with zero
  `orphan candidate` errors and zero failed lines.
- C2 regression (448/448): EnvironmentLockGate 45/45,
  BrokerSubmissionGate_DurableIdempotency 41/41, ManualApprovalEmission
  38/38, ManualApprovalProjection 73/73, C2.2 BrokerSubmissionGate 147/147,
  C2.3 BrokerSubmissionAuditProjection 104/104.
- C3.3 TransactionMatchingProjection 109/109.
- C3.4 TransactionMatchingReadiness 57/57.

Total: 626/626. The real-`OrderSend` smoke script
(`MLQuantAI_SmokeTest_C2_2_RealOrderSend`) correctly remains ABORTED under
its opt-in flag and is not part of this gate.

## [Unreleased] - C3.4 implementation: startup-readiness wrapper (IMPLEMENTING, awaiting real MetaEditor run)

Implements the C3.4 design contract frozen below (sections 25-27 of
`Docs/PhaseC_C3_TransactionReconciliationContract.md`) - strictly the
`TransactionMatching_StartupRebuild` startup-readiness wrapper. NOT an
`OnTick`/`OnTradeTransaction` incremental update, NOT a C3.3 matching-
semantic change, NOT a candidate-lifecycle action, NOT a
`BrokerReconciliation.mqh` change.

New `Execution/MLQuantAI_TransactionMatchingReadiness.mqh`:
- `TransactionMatchingReadinessReport`: wraps C3.3's sealed
  `TransactionMatchingReport` plus the six section-28 order-status
  counters (`orders_total`/`orders_unmatched`/`orders_ambiguous`/
  `orders_matched_partial`/`orders_matched_volume_reached`/
  `orders_matched_order_terminal`, the last frozen at 0) and a `rebuilt_at`
  staleness marker.
- `g_TransactionMatching_Ready` / `TransactionMatchingReadiness_IsReady()`
  / `_Reset()`: fail-closed-by-default readiness flag, same discipline as
  every prior C1.3/C2.3/manual-approval readiness wrapper - set fresh
  from each call's own `report.ok`, never OR'd with a stale prior success.
- `TransactionMatchingReadiness_LastReport()`: diagnostics-only accessor;
  the report is never treated as authoritative state.
- `TransactionMatching_StartupRebuild(fileName)`: the one frozen entry
  point (section 25). Calls the sealed C3.3
  `TransactionMatching_RebuildFromFile()` unmodified, stamps `rebuilt_at`,
  tallies the six counters only on success, logs one `LogInfo` summary
  plus exactly one `LogWarn` if `orders_ambiguous > 0` (never per-ticket
  spam). On failure: logs `deals_applied`/`deals_failed`/`first_error` via
  `LogWarn` only - deliberately does **not** call `SafeMode_Trip` and does
  **not** gate EA initialization, per section 27's explicit rule that C3.3
  carries no lifecycle authority yet (unlike the C2.3/manual-approval
  wrappers this file's shape is otherwise copied from).

`MLQuantAI.mq5`: adds the include and one `OnInit` call site -
`TransactionMatching_StartupRebuild(g_EventStoreFileName);` - placed after
`ManualApproval_StartupRebuild(...)` and before
`EventStore_LogSystem(EVENT_TYPE_SYSTEM_STARTED, ...)`, per the frozen
section 25 ordering.

New `Tests/MLQuantAI_Test_C3_4_TransactionMatchingReadiness.mq5`:
fixture-only (no real `OnTradeTransaction` callback), covering: a clean
success path (ready, report persisted, counters correct, `rebuilt_at`
stamped, Safe Mode untouched); a failure path (not ready, Safe Mode still
untouched, failure report retained, a later call still sets readiness
fresh from its own result); staleness metadata (`rebuilt_at` re-stamped
on every call, never silently reused); the six-counter invariant
(fixtures producing `UNMATCHED`/`AMBIGUOUS`/`MATCHED_PARTIAL`/
`MATCHED_VOLUME_REACHED` each, asserting the sum of all six counters
always equals `orders_total`); and a structural no-broker-mutation proof.

Still NOT authorized this round (explicit user scope limit): `OnTick`/
`OnTradeTransaction` incremental updates, any C3.3 matching-semantic
change, any candidate-lifecycle action, any new event/enum,
`BrokerReconciliation.mqh` changes, `History*`/`Position*`/`Order*` broker
API calls, the demo smoke protocol, or live execution.

## [Unreleased] - C3.4 wiring/rebuild-policy design contract (documentation only)

`Docs/PhaseC_C3_TransactionReconciliationContract.md` sections 25-29 -
freezes the C3.4 design contract after a read-only research pass across
5 areas (wiring boundary, replay timing, projection rebuild policy,
unresolved-observation visibility, and the relationship between C3.3's
durable read model and the existing live `BrokerReconciliation`).
**Design-only: no code, no wiring, no readiness-wrapper file, no C3.3
projection change, no test, no `MLQuantAI.mq5` edit.**

Freezes, per the user's explicit decisions on all 5 points:

**Wiring boundary**: `TransactionMatching_StartupRebuild` (not yet
written) slots into `OnInit` immediately after the two existing C2
startup rebuilds, before `SYSTEM_STARTED` is logged - required because
`TransactionMatching_RebuildFromFile` (C3.3, sealed) stages
`BrokerSubmissionAuditProjection_RebuildFromFile` as its own black-box
gate. The wrapper's shape is frozen as a thin readiness wrapper (clear
readiness, call the sealed C3.3 rebuild unmodified, persist the report,
set readiness only on success, log a summary) - exactly mirroring
`BrokerSubmissionAuditReadiness.mqh`/`ManualApprovalReadiness.mqh`'s own
established pattern.

**Replay timing**: `OnInit`-only startup snapshot. Both a periodic
`OnTick` re-rebuild and a true incremental update from
`OnTradeTransaction` are explicitly rejected this round - the former
turns a full-file scan into hidden runtime behavior, the latter needs an
incremental-state/idempotency contract that doesn't exist yet. The read
model is therefore explicitly stale immediately after `OnInit` - this
must be surfaced in readiness/report metadata, never assumed current.

**Rebuild policy**: `OnInit`-only trigger, `EventStore_ReadAllLines`-only
source, full deterministic rebuild each time, and on failure: log
`deals_applied`/`deals_failed`/`first_error`, but do NOT engage Safe
Mode and do NOT block EA initialization from this failure alone - C3.3
carries no lifecycle authority, so a failed diagnostic rebuild isn't a
safety event the way a failed C2.3/manual-approval rebuild is.

**Unresolved-order visibility**: six new report-level counters
(`orders_total`/`orders_unmatched`/`orders_ambiguous`/
`orders_matched_partial`/`orders_matched_volume_reached`/
`orders_matched_order_terminal`, the last frozen at 0 until a terminal-
state contract exists), each counting `OrderAggregateRecord`s once per
`order_ticket`, summing to `orders_total`. Logging policy: summary-only
for every status except `AMBIGUOUS`, which gets exactly one startup WARN
with the count - never per-ticket detail, never Safe Mode or a
lifecycle/reconciliation action from any status.

**BrokerReconciliation relationship**: strict three-way ownership
separation - `BrokerReconciliation` (live-position consistency for
`CANDIDATE_EXECUTED` only), `TransactionMatching` (durable diagnostic
projection only), and the still-unbuilt deferred processor (future sole
owner of any lifecycle action derived from broker facts).
`MATCHED_VOLUME_REACHED` is frozen as evidence, never authorization - no
`BrokerReconciliation.mqh` change and no `CANDIDATE_SUBMITTED`
second-pass is authorized by this document.

## [Unreleased] - C3.3 implementation: deferred matching / transaction projection (PASSED 109/109, real MetaEditor run, 2026-08-22)

Implements the C3.3 contract frozen below (sections 20-24 of
`Docs/PhaseC_C3_TransactionReconciliationContract.md`) - EventStore-only
replay, strict ticket-only matching, order-ticket volume aggregation.
NOT reconciliation, NOT fill handling, NOT execution authorization; no
candidate transition, no `ORDER_FILLED`/`TRANSACTION_REJECTION_
CONFIRMED`, no `BrokerReconciliation.mqh` change.

New `Execution/MLQuantAI_TransactionMatchingProjection.mqh`:
- `TransactionDealRecord`/`TransactionDealRegistry_*`: one record per
  unique `deal_ticket` observed via a `TRADE_TRANSACTION_DEAL_ADD`-typed
  `BROKER_TRANSACTION_OBSERVED` line - the only transaction type C3.3
  actively ingests this round. Idempotent by `deal_ticket` itself
  (deliberate departure from the `log_event_id`-keyed precedent every
  other projection uses): identical canonical payload on a repeat
  `deal_ticket` is a no-op; a DIFFERENT canonical payload on the same
  `deal_ticket` fails the whole rebuild closed as a collision.
- `OrderAggregateRecord`/`OrderAggregateRegistry_*`: one derived record
  per `order_ticket`, summing `running_filled_volume` across its deals.
  `match_status` is `UNMATCHED`/`AMBIGUOUS`/`MATCHED_PARTIAL`/
  `MATCHED_VOLUME_REACHED`/`MATCHED_ORDER_TERMINAL` (the last reserved,
  never assigned this round - the `ORDER_STATE` terminal criterion isn't
  frozen).
- `TransactionMatching_ResolveExecutionRequestId`: per-deal matching -
  `deal_ticket` against a durable, `SUBMISSION_STATUS_SUBMITTED`
  `SubmissionOutcome` first, then `order_ticket`; a
  `REJECTED`/`ERROR`/`UNKNOWN` outcome is never a valid match target.
  Deals under one `order_ticket` resolving to more than one distinct
  `execution_request_id` flip that order to `AMBIGUOUS`, clearing any
  provisional match.
- `TransactionMatching_RebuildFromFile`: stages
  `BrokerSubmissionAuditProjection_RebuildFromFile` (which itself
  transitively stages C1.3's `ExecutionAuditProjection_RebuildFromFile`)
  unmodified as a black-box gate first - fails closed if that upstream
  rebuild fails. Pure read-model output; zero durable writes, zero
  events, zero `ENUM_EVENT_TYPE` additions.

New `Tests/MLQuantAI_Test_C3_3_TransactionMatchingProjection.mq5`:
fixture-only suite (11 cases per section 24) - exact deal_ticket match,
exact order_ticket fallback match, duplicate-deal replay vs conflicting-
payload collision, multi-deal partial-fill aggregation reaching
`MATCHED_VOLUME_REACHED`, zero-ticket malformed observation, ambiguous
order-ticket-to-multiple-requests mapping, unmatched observation,
rejected-outcome-never-a-match-target, cold-rebuild determinism, and a
behavioral no-broker-mutation/no-candidate-transition proof.

Source-text scan (zero non-comment hits) confirms no History*/
Position*/Order*/OrderSend/CTrade/EventStore_LogTransition/
EventStore_LogSystem/EventStore_Append* call anywhere in the new
projection file.

Full existing regression, real MetaEditor run, zero regressions (this
branch touches only 3 files - CHANGELOG.md, the new projection file, and
its own test file - no shared/production file is touched, so this is
confirmation, not a required gate):
`Test_C2_ManualApprovalEmission` 38/38, `Test_C2_ManualApprovalProjection`
73/73, `Test_C2_EnvironmentLockGate` 45/45, `Test_C2_2_BrokerSubmissionGate`
147/147, `Test_C2_3_BrokerSubmissionAuditProjection` 104/104,
`Test_C2_BrokerSubmissionGate_DurableIdempotency` 41/41 - total 448/448,
matching the pre-existing baseline exactly. Combined total this round:
557/557.

**Test-fixture bug found and fixed via the user's real first run (98/109,
11 failures)**: every test past the first that reused `dayOffset=0`
failed at its own `BuildDurableSubmittedRequest` sanity check.
`CRT_ToTradeCandidate`'s `candidate_id` is derived from the real
detector inputs (`instrument_id`/`trigger_timeframe`/`anchor_bar_time`/
detector output) - none of which vary with the test's own `suffix`
string, since the shared `BuildBaseContext` hardcodes `instrument_id`/
`broker_symbol` to `"XAUUSD"` regardless of suffix (`suffix` only feeds
the cosmetic `context_event_id`/`context_hash` fields). Because
`StateProjector`'s in-memory state accumulates across the whole
`OnStart()` run (never reset between test functions), every later test
reusing `dayOffset=0` produced the SAME `candidate_id` as the first
test, so `CRT_EmitCandidateCreated`'s duplicate-genesis guard correctly
(if confusingly) rejected it. Fixed by giving every test function its
own unique `dayOffset` (0-9, no reuse) - a test-fixture bug only, no
change to `MLQuantAI_TransactionMatchingProjection.mqh` itself.

## [Unreleased] - C3.3 deferred-matching/transaction-projection contract (documentation only)

`Docs/PhaseC_C3_TransactionReconciliationContract.md` sections 20-24 -
freezes the C3.3 contract after a read-only research pass across 8 areas
(payload shape, replay integration point, existing execution-request/
submission projections, candidate-projection/state-machine
prerequisites, ticket-idempotency precedent, partial-fill aggregation
model, C2.2 ticket/correlation fields, `BrokerReconciliation` extension
seam). No code, no projection file, no raw-callback change, no
`BrokerReconciliation.mqh` edit.

Freezes, per the user's explicit decisions on three semantic points:

**Matching authority, strict this round**: positive ticket evidence
only - `deal_ticket` match, then `order_ticket` match. The
`correlation_id`/`comment`+`magic`+`symbol` fallback (section 1,
priority 2/5) is explicitly NOT implemented in C3.3, since the sealed
C3.2 envelope schema carries no `magic` number and no broker `comment`
field to support it - inferring identity from fields the envelope
doesn't carry would be worse than not matching. No matching ticket ->
`UNMATCHED`; conflicting ticket mappings -> `AMBIGUOUS`; neither ever
transitions a candidate.

**Partial-fill lifecycle, projection/aggregation only**: a deal-ticket
registry (idempotent by `deal_ticket` itself - a deliberate, explicit
departure from every other projection's `log_event_id`-keyed dedup,
required because `OnTradeTransaction` has no documented 1:1 request-to-
event guarantee) feeding an order-ticket aggregate exposing
`UNMATCHED`/`AMBIGUOUS`/`MATCHED_PARTIAL`/`MATCHED_VOLUME_REACHED`/
`MATCHED_ORDER_TERMINAL` read-model status - the last one named but
never populated this round, since the `ORDER_STATE` terminal criterion
isn't frozen yet and C3.3 only actively ingests `TRADE_TRANSACTION_
DEAL_ADD` lines. No status drives `EventStore_LogTransition`; no
`ORDER_FILLED`/`TRANSACTION_REJECTION_CONFIRMED` emission.

**`BrokerReconciliation.mqh` untouched**: C3.3's durable projection stays
complementary to, and read-only with respect to, the existing live
`PositionsTotal()`/comment-scan reconciliation pass. Integrating the two
is explicitly deferred to a later, separately-approved C3.4/C4 recovery
contract.

Also freezes required integrity rules (zero-ticket malformed observation
fails the whole rebuild closed; same-deal-ticket replay-vs-collision;
ambiguous order-to-multiple-request mapping; no buffering across a
temporal gap; `position_ticket` never identity; only `SUBMITTED`
outcomes are match targets) and an 11-case required test matrix (design
only, no test file written by this entry).

Still not authorized: any projection code, any change to the raw
`OnTradeTransaction`/envelope path, any `ENUM_EVENT_TYPE` addition, any
candidate-lifecycle transition, any `BrokerReconciliation.mqh` edit, and
the controlled demo smoke protocol.

## [Unreleased] - C3.2 implementation: raw broker-transaction observation (PASSED 471/471, real MetaEditor run, 2026-08-22)

Implements the C3.2 micro-contract frozen below (sections 10-19 of
`Docs/PhaseC_C3_TransactionReconciliationContract.md`) - broker-
observation only, NOT reconciliation, NOT fill handling, NOT execution
authorization:

- `Core/MLQuantAI_Enums.mqh`: appends `EVENT_TYPE_BROKER_TRANSACTION_
  OBSERVED` as the new last `ENUM_EVENT_TYPE` value, with matching
  `EventTypeToString`/`EventTypeFromString` cases added in the same pass.
- New `Execution/MLQuantAI_BrokerTransactionObservation.mqh`:
  `BrokerTransactionEnvelope` (the raw fact struct, sourced entirely from
  `MqlTradeTransaction`, plus `request_id` from `MqlTradeResult` ONLY
  when `trans.type == TRADE_TRANSACTION_REQUEST` - the frozen trust
  boundary) and `BrokerTransactionObservation_RecordAndGuard()`, the
  single function an `OnTradeTransaction` handler is authorized to call:
  builds the envelope, attempts exactly one durable
  `EventStore_LogSystem` append, and on failure calls
  `SafeMode_Trip("broker transaction observation append failed")` per
  the frozen durability rule - no retry, no history/candidate/broker
  call anywhere in this file (verified this round via source-text scan,
  zero non-comment hits for any prohibited API).
- `MLQuantAI.mq5`: adds the new include and a minimal `OnTradeTransaction`
  handler whose entire body is one call to
  `BrokerTransactionObservation_RecordAndGuard`.
- New `Tests/MLQuantAI_Test_C3_2_BrokerTransactionObservation.mq5`:
  fixture-only suite (a real `OnTradeTransaction` callback cannot be
  synthesized under any MQL5 test harness, per section 18's finding) -
  proves the enum is appended at the end with correct ToString/FromString
  round-trip, the trust boundary (`request_id` populated only for
  `TRADE_TRANSACTION_REQUEST`, the explicit `not_applicable` sentinel
  otherwise - never a fabricated zero), a successful append leaves Safe
  Mode untouched and writes exactly one line, and a failed/unopened-
  EventStore append trips Safe Mode with the exact frozen reason string
  and does not retry on a second, independent call.

New suite: `Test_C3_2_BrokerTransactionObservation` 23/23. Full existing
regression, real MetaEditor run, zero regressions from the enum
insertion or the new `MLQuantAI.mq5` handler:
`Test_C2_ManualApprovalEmission` 38/38, `Test_C2_ManualApprovalProjection`
73/73, `Test_C2_EnvironmentLockGate` 45/45, `Test_C2_2_BrokerSubmissionGate`
147/147, `Test_C2_3_BrokerSubmissionAuditProjection` 104/104,
`Test_C2_BrokerSubmissionGate_DurableIdempotency` 41/41 - total 448/448,
matching the pre-C3.2 baseline exactly. Combined total this round:
471/471.

Live EA startup log (same session) shows zero symptom tied to
`BROKER_TRANSACTION_OBSERVED`/`OnTradeTransaction` - the only warnings
present are the already-known, pre-existing "orphan candidate" startup-
rebuild-failure warning from the dormant Phase A/B Runtime Lifecycle
Smoke Test (flagged earlier this session, unrelated to and unchanged by
this round).

Awaiting a real MetaEditor compile + test run before this entry is
marked PASSED.

## [Unreleased] - C3.2 implementation micro-contract (documentation only, contract amendment)

`Docs/PhaseC_C3_TransactionReconciliationContract.md` sections 17-19 -
freezes the C3.2 implementation micro-contract after a read-only
implementation collision-check (entry point, `ENUM_EVENT_TYPE` insertion
point, event-serializer convention, `EventStore` append/error-handling
path, test-fixture seam, callback runtime budget, and a behavioral proof
plan for "no history/candidate/broker call" inside the raw callback - no
code, no handler, no enum change).

The collision-check found a real inconsistency: `EventStore_LogSystem`
does not trip Safe Mode on a failed durable write, unlike
`EventStore_LogCandidateCreated`/`EventStore_LogTransition`. **Frozen,
per the user's explicit decision: `EVENT_TYPE_BROKER_TRANSACTION_
OBSERVED` follows the lifecycle-event precedent, not the general
system-event one** - a failed append trips Safe Mode
(`SafeMode_Trip("broker transaction observation append failed")`) and
returns immediately, no retry, no history call, no candidate transition,
no broker mutation. Rationale: this callback is the primary channel
recording broker-fact evidence that matching, partial-fill handling, and
restart reconciliation all depend on; combined with the platform's
documented, bounded transaction-queue overwrite risk, a durability
failure must freeze new authority rather than let execution continue as
though the audit stream remains complete.

Also freezes the consolidated collision-check findings as implementation
constraints (append point, serializer shape, fixture seam, no-numeric-
runtime-budget, behavioral-not-syntactic proof plan) and a further set of
test-case additions (append-success, append-failure, unhealthy-
`EventStore`, trust-boundary-per-transaction-type, and single-attempt-
bounded-path assertions).

Still not authorized: implementing `OnTradeTransaction`, calling
`HistorySelect`/`HistoryDealGet*`/`HistoryOrderGet*`, adding
`EVENT_TYPE_BROKER_TRANSACTION_OBSERVED` or any other value to
`ENUM_EVENT_TYPE`, any candidate-lifecycle transition or broker-side
query/mutation, and the controlled demo smoke protocol.

## [Unreleased] - C3.2 transaction-reconciliation sub-contract (documentation only, contract amendment)

`Docs/PhaseC_C3_TransactionReconciliationContract.md` sections 10-16 -
freezes the `C3.2` sub-contract after a read-only "C3 implementation
collision-check" against real MQL5 platform docs (no code, no
`OnTradeTransaction` handler, no `History*`/`PositionSelect` call).
Adds: a defensive rule resolving the open `HistorySelect` same-callback
visibility question as a design constraint rather than an empirical
prerequisite (envelope-only persist, no inferred fact, no candidate
transition, on any lookup failure); a callback-durability rule keeping
`OnTradeTransaction` itself small and non-blocking (validate envelope,
append immutable event, return - no history scan/aggregation/mutation/
lifecycle transition inside the callback, given the platform's
documented 1,024-item transaction-queue overwrite risk); a trust
boundary treating `trans` as the only reliable evidence for every
transaction type, with `request`/`result` read only when
`trans.type == TRADE_TRANSACTION_REQUEST` (both documented as populated
for that type only), and confirming `MqlTradeResult` never carries a
position ticket at submit time (`ExecutionSubmissionResult` stays
unchanged); a new raw envelope event name,
`EVENT_TYPE_BROKER_TRANSACTION_OBSERVED` (name/field-list only, not
added to `ENUM_EVENT_TYPE` by this document), that records what `trans`
said with no matching-hierarchy verdict and no lifecycle transition;
confirmation that matching/lifecycle-transition logic stays entirely in
the already-frozen deferred processor (sections 6-8), never the raw
callback; and test-design additions extending section 9's fixture-only
approach to cover the lookup-failure path, the trust-boundary field
population, and the deferred processor's fail-closed behavior on
unmatched envelopes.

Also corrects a minor miscount from the original C3.1 entry below: the
real MQL5 reference documents **eleven** `ENUM_TRADE_TRANSACTION_TYPE`
values, not ten. Documentation-only - does not alter any previously
frozen matching semantics.

Still not authorized: implementing `OnTradeTransaction`, calling
`HistorySelect`/`HistoryDealGet*`/`HistoryOrderGet*`, adding
`EVENT_TYPE_BROKER_TRANSACTION_OBSERVED` or any other value to
`ENUM_EVENT_TYPE`, any candidate-lifecycle transition or broker-side
query/mutation, and the controlled demo smoke protocol.

## [Unreleased] - C3 transaction-reconciliation contract (documentation only, collision check)

`Docs/PhaseC_C3_TransactionReconciliationContract.md` - a
documentation-only collision check for the future `OnTradeTransaction`
reconciliation work, per the user's explicit "C3.1" scope: no handler,
no `History*`/`PositionSelect` call, no code change of any kind. Every
platform-behavior claim was verified directly against the real MQL5
reference this round (`WebFetch`, not recalled from memory): the
`MqlTradeTransaction` field set and the eleven `ENUM_TRADE_TRANSACTION_TYPE`
values (corrected from an earlier "ten" miscount - see the C3.2
sub-contract entry below); `OnTradeTransaction`'s own documented lack of ordering/
one-request-one-event guarantees; `ACCOUNT_MARGIN_MODE`'s netting
(one position per symbol) vs. hedging (multiple positions per symbol)
semantics; and the absence of any documented length/round-trip
guarantee on `MqlTradeRequest.comment`/`POSITION_COMMENT`.

Freezes: a five-priority matching hierarchy (magic number ->
comment-substring-match on `correlation_id` -> symbol ->
order/deal-ticket grouping -> account/server as audit evidence only);
why comment matching must stay a substring match, never exact equality
(no documented round-trip guarantee); why the matching rule must be
netting-safe (a position ticket is not a reliable 1:1 key under
`ACCOUNT_MARGIN_MODE_RETAIL_NETTING`); partial-fill aggregation and its
terminal criterion; why a durable, replay-from-file read model is
required (restart-replay of missed `OnTradeTransaction` callbacks is
NOT documented as guaranteed) and why the existing, separate
`Infrastructure/MLQuantAI_BrokerReconciliation.mqh` mechanism remains
necessary rather than superseded; the fail-closed "no transition on an
unmatched/ambiguous fact" rule; and the required testing approach
(fixture-fed `MqlTradeTransaction` structs against the future pure
matching function - no real callback can be synthesized under a test
harness).

**A genuine collision was found, and resolved by the user's explicit
follow-up instruction**: `EVENT_TYPE_ORDER_REJECTED` is already claimed
by C2.2 for a synchronous, `OrderSend()`-return-time rejection - a LATE
rejection/cancellation observed only via `OnTradeTransaction` (which
can only happen strictly after C2.2's own `ORDER_SUBMITTED`) is a
different fact and cannot reuse that name without breaking C2.3's own
outcome-invariant checks. Resolution, now frozen: `EVENT_TYPE_ORDER_REJECTED`
stays scoped to the synchronous case only (unchanged); a new,
separately-namespaced `EVENT_TYPE_TRANSACTION_REJECTION_CONFIRMED`
(name frozen, not yet added to `ENUM_EVENT_TYPE` - still C3.2's job)
covers the asynchronous, transaction-derived case, and can never itself
drive a candidate-lifecycle transition until deterministically matched
to its owning `ExecutionRequest` via the matching hierarchy - an
unmatched/ambiguous rejection fact stays a diagnostic/reconciliation
finding only. `EVENT_TYPE_ORDER_FILLED` and `EVENT_TYPE_CANDIDATE_EXECUTED`
(Phase A, dormant) remain cleanly reserved for the real fill-confirmation
case - no collision there.

Implementation (the real handler + `History*` calls) is explicitly
separate approval, not authorized by this document. No sealed file
touched, no code changed anywhere.

## [Unreleased] - C2 manual-approval gate integration (PASSED 448/448, real MetaEditor run, 2026-08-22)

The read side of the manual-approval contract, plus a real wiring gap
found and fixed while implementing it. Per
`Docs/PhaseC_C2_ManualApprovalContract.md`'s round-2 sections, frozen
with two user-added rules before any code was written: an **approval
timing boundary** (a single `asOf = TimeCurrent()` captured once per
gate evaluation, fail-closed on `asOf <= 0`, `HasValidApproval()`
placed as the LAST check before `ACCEPTED` so there is no window for
an approval to expire between the gate and `RecordAttempt()`), and an
**approval scope** rule (the gate order is now fully documented -
`HasValidApproval()` never re-checks `SubmissionAttemptRegistry_HasAttempt()`,
since that check already runs earlier in the same evaluation, inherited
from `BrokerSubmissionGate_Evaluate`).

New `Execution/MLQuantAI_ManualApprovalProjection.mqh`: the projection
(0..N records per `execution_request_id`, never deduped), staging
C1.3's `ExecutionAuditProjection_RebuildFromFile` first, then its own
pass validating every rule the round-1 contract froze - orphan/mismatch
against the full five identity fields, no `SAFETY_GATE_ACCEPTED`
dry-run record, `log_event_id` collision, and `approval_nonce`
collision across DIFFERENT `log_event_id`s (fails the whole rebuild
closed even when every other field differs - the rule unique to this
contract). Plus the pure `ManualApprovalRegistry_HasValidApproval()`
query (caller-supplied `asOf`, never `TimeCurrent()` internally) - it
never consults `SubmissionAttemptRegistry`, proven empirically in the
test suite, not just by inspection.

New `Execution/MLQuantAI_ManualApprovalReadiness.mqh`: mirrors
`MLQuantAI_BrokerSubmissionAuditReadiness.mqh` exactly -
`ManualApprovalReadiness_IsReady()`/`ManualApproval_StartupRebuild()`,
fail-closed default, re-entrant. Wired into `MLQuantAI.mq5`'s `OnInit`
alongside the existing `BrokerSubmissionAudit_StartupRebuild` call.

`Execution/MLQuantAI_EnvironmentLockGate.mqh`'s third amendment: a
sixth check inside `EnvironmentLock_EvaluateNewChecks`, after the
existing five - manual-approval registry readiness, then the single
captured `asOf`, then `HasValidApproval()` against all five identity
fields. New append-only `REASON_EXECUTION_MANUAL_APPROVAL_NOT_GRANTED`
(the wording bug in the earlier draft - "two new reason codes" - is
now corrected: only this one is genuinely new).

**A real wiring gap, found while implementing this round**:
`BrokerSubmission_Submit()` (`MLQuantAI_BrokerSubmissionAdapter.mqh` -
the only function anywhere in this codebase that calls the real
`OrderSend()`) called `BrokerSubmissionGate_Evaluate()` directly, never
`BrokerSubmissionEnvironmentLock_Evaluate()` - meaning neither the
environment-lock round's five checks nor this round's manual-approval
check had ever actually gated a real submission. This predates this
round (a gap from the environment-lock round itself, only surfaced
now). Fixed, per the user's explicit authorization: `BrokerSubmission_Submit()`
now takes an `EnvironmentLockPolicy` parameter and calls
`BrokerSubmissionEnvironmentLock_Evaluate()` instead - its third
amendment. Both existing call sites updated
(`Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5` never called
`Submit()` directly, so needed no change;
`Tests/MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5` now builds a real
`EnvironmentLockPolicy` and calls both startup-rebuild functions before
submitting - it was ALSO found, while making this fix, to have never
called `BrokerSubmissionAudit_StartupRebuild()` either, so it has
always fail-closed on `REASON_EXECUTION_AUDIT_NOT_READY` since the
C2.2/C2.3 integration round shipped; also fixed here).

Incidental fix while extending `Core/MLQuantAI_ReasonCodes.mqh`: the
five environment-lock reason codes were present in `ReasonCodeToString`
but missing from `ReasonCodeFromString` - a real, pre-existing gap (a
stored line carrying one of these would have silently round-tripped to
`REASON_NONE`), found and fixed alongside the new reason code.

New test suites: `Tests/MLQuantAI_Test_C2_ManualApprovalProjection.mq5`
(rebuild validation - valid grant/expiry boundary, never-deduped,
replay/conflict, orphan, four-field mismatch, no-accepted-dry-run,
nonce collision, consumption-boundary proof) and four new cases added
to `Tests/MLQuantAI_Test_C2_EnvironmentLockGate.mq5` (registry not
ready, ready-but-not-granted, ready-with-valid-approval stays ACCEPTED,
precedence).

**Confirmed by real MetaEditor runs, with real bugs found and fixed
along the way (none in the shipped registry/gate logic's own frozen
rules, except one - see below)**:
- Two identifiers over MQL5's 63-char limit (72 and 80 chars) -
  compile error, renamed.
- `Tests/MLQuantAI_Test_C2_EnvironmentLockGate.mq5`'s own
  `BuildAndEmitAcceptedRequest` durably emitted only the final
  `EXECUTION_REQUEST_CREATED`/`EXECUTION_DRY_RUN_COMPLETED` pair,
  never the upstream `CANDIDATE_CREATED`/`FEATURE_SNAPSHOT_CREATED`/
  `MODEL_ARTIFACT_REGISTERED`/`AI_DECISION_CREATED`/`RISK_PLAN_CREATED`/
  eligibility-lifecycle events those reference - C1.3's own orphan
  check correctly rejected the incomplete fixture (3 test failures);
  rewritten to emit the full chain.
- A genuine gap in the ORIGINALLY frozen `HasValidApproval()` shape:
  it checked only `approval_expiry > asOf`, no lower bound against
  `approval_timestamp` - meaning a query for an `asOf` strictly BEFORE
  a grant was ever made could still return `true`. Found by this
  round's own test suite, confirmed by the user: added
  `asOf >= record.approval_timestamp` as a second required condition,
  contract doc amended.
- Two more test-fixture bugs in `Tests/MLQuantAI_Test_C2_ManualApprovalProjection.mq5`
  wrongly assumed the approval-grant line sat at `lines[0]`, when
  `BuildFullChain` durably writes several upstream lines first - fixed
  to locate the grant line by type.

Full regression suite ALL PASS, no regression from the
`BrokerSubmission_Submit()` signature change: `Test_C2_ManualApprovalEmission`
38/38, `Test_C2_ManualApprovalProjection` 73/73,
`Test_C2_EnvironmentLockGate` 45/45, `Test_C2_2_BrokerSubmissionGate`
147/147, `Test_C2_3_BrokerSubmissionAuditProjection` 104/104,
`Test_C2_BrokerSubmissionGate_DurableIdempotency` 41/41 - total
448/448.

No sealed file touched (`MLQuantAI_SafetyGate.mqh`,
`MLQuantAI_BrokerSubmissionGate.mqh`,
`MLQuantAI_BrokerSubmissionAuditProjection.mqh`,
`MLQuantAI_BrokerSubmissionAuditReadiness.mqh` all untouched). Still
out of scope: `OrderSend`/`CTrade`/smoke-test opt-in enablement,
`OnTradeTransaction`, any `History*`/`Position*`/`Order*` broker query,
any candidate-lifecycle transition driven by broker facts.

## [Unreleased] - C2 manual-approval contract + dry code (PASSED 38/38, real MetaEditor run, 2026-08-22)

Frozen design doc, `Docs/PhaseC_C2_ManualApprovalContract.md`, resolving
the real architectural tension found before any code was written:
`SafetyGate_Evaluate`'s sealed `manual_approval_required` check stays
unchanged (an unconditional C1 rejection when `true` - never becomes
the live approval mechanism); real approval is instead a new,
C2-owned, always-mandatory gate, independent of that field's value.
Per the user's explicit consumption-boundary instruction, the new
`ManualApprovalRegistry` will expose a pure `HasValidApproval()` read
only and never itself track single-use - `SubmissionAttemptRegistry_
HasAttempt()` (already frozen, C2.3) remains the sole consumption
boundary.

Only the write side is implemented as code this round ("dry code" -
no broker mutation, no decision-making): new
`Execution/MLQuantAI_ManualApprovalContract.mqh` (`ManualApprovalGrant`
struct, binding all FIVE identity fields - execution_request_id/hash/
policy_version/candidate_id/correlation_id, not just id+hash, per the
user's "collision-check" instruction), new
`Execution/MLQuantAI_ManualApprovalEmission.mqh`
(`ManualApproval_NewNonce()`, mirroring `Ids_NewRuntimeSessionId()`'s
own counter+microsecond+random technique with an `APPR_` prefix and
its own dedicated counter; `ManualApproval_Grant()`, a pure durable
write with only structural validation - no lineage/projection checks,
which stay the deferred read side's job), and the standalone, human-run
`Tests/MLQuantAI_ManualScript_GrantApproval.mq5` (never calls OrderSend/
CTrade/any broker API - its only side effect is one durable event
write). New append-only `EVENT_TYPE_EXECUTION_MANUAL_APPROVAL_GRANTED`
and `MLQUANTAI_MANUAL_APPROVAL_SCHEMA_C2_V1`. Write-side-only test
suite, `Tests/MLQuantAI_Test_C2_ManualApprovalEmission.mq5` (nonce
uniqueness, JSON round-trip, structural-rejection/no-partial-write
cases, never-deduped-at-write-time).

Explicitly deferred, pending its own separate contract review: the
projection (read side), `ManualApprovalRegistry_HasValidApproval()`,
readiness wiring, and the C2 gate integration into
`BrokerSubmissionEnvironmentLock_Evaluate` (its third amendment) plus
`MLQuantAI.mq5`'s `OnInit` wiring. No sealed file touched.

Confirmed by a real MetaEditor run: both new files compile with 0
errors/0 warnings; `Tests/MLQuantAI_Test_C2_ManualApprovalEmission.mq5`
is 38/38 ALL PASS (nonce uniqueness, JSON round-trip, structural
rejection/no-partial-write for all nine invalid-field/invalid-expiry
cases, never-deduped-at-write-time, no-broker-mutation proof); the
standalone `Tests/MLQuantAI_ManualScript_GrantApproval.mq5` correctly
aborts with no write attempted when run with its required inputs left
blank. Zero regression: `Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5`
147/147, `Tests/MLQuantAI_Test_C2_3_BrokerSubmissionAuditProjection.mq5`
104/104, `Tests/MLQuantAI_Test_C2_BrokerSubmissionGate_DurableIdempotency.mq5`
41/41 - all still ALL PASS, unchanged from their own sealed counts.

## [Unreleased] - C2 environment-lock checklist (PASSED 26/26, real MetaEditor run, 2026-08-22)

The final, read-only, consolidated re-verification pass before a real
`OrderSend()` would ever be authorized, per the user's explicit 18-item
checklist. New `Execution/MLQuantAI_EnvironmentLockContract.mqh`
(`EnvironmentLockPolicy` - `trade_server_allowlist`, a new struct rather
than editing the frozen `ExecutionPolicy`) and
`Execution/MLQuantAI_EnvironmentLockGate.mqh`
(`BrokerSubmissionEnvironmentLock_Evaluate`, chaining the already-sealed
`BrokerSubmissionGate_Evaluate` first, then five genuinely new checks:
trade-server allowlist, `TERMINAL_TRADE_ALLOWED`, `ACCOUNT_TRADE_ALLOWED`,
`ACCOUNT_TRADE_EXPERT`, and a fresh `SYMBOL_VOLUME_MIN` floor re-check -
all four new platform facts verified directly against the real MQL5
reference, not recalled from memory). Five new append-only reason
codes. The five new checks live in their own directly-testable
function, `EnvironmentLock_EvaluateNewChecks`, split out for the same
reason `BrokerSubmission_ProcessSendResult` was split in C2.2's own
first amendment - a non-DEMO test terminal would otherwise always
reject on environment before ever reaching these checks through the
full chained entry point. Every other checklist item was either already
covered by an earlier sealed gate (cited, not duplicated) or explicitly
deferred: "manual approval bound to request ID+hash, single-use"
describes a real, not-yet-designed approval mechanism, not a runtime
assertion this gate can check from existing data - stays out of scope
pending its own separate freeze. See
`Docs/PhaseC_C2_EnvironmentLockChecklist.md` for the full item-by-item
mapping. Confirmed by a real MetaEditor run: 26/26 ALL PASS. No sealed
file was touched (only new, additive files plus an append-only
`ENUM_REASON_CODE` addition), so no regression re-run was required.

## [Unreleased] - Phase C2: FULLY SEALED (2026-08-22)

**C2.2 147/147 + C2.3 104/104 + C2.2/C2.3 integration + startup-rebuild
wiring 41/41 = 292/292, all real MetaEditor runs**, plus a full manual
regression re-run of the entire C1 + B9 chain in the same session
confirming no regression anywhere upstream: `Test_C1_2_
ExecutionRequestSafetyGate.mq5` 128/128, `Test_C1_3_
ExecutionAuditReconciliation.mq5` 87/87, `Test_B9_ExecutionEligibility.mq5`
120/120, `Test_B9_Commit2_EligibilityEvent.mq5` 84/84, and
`Test_B9_Commit3_IntegrationRegression.mq5` 79/79. Combined with C2.1's
frozen contract (no code), C2 (Broker Submission + Audit + Durable
Idempotency) is fully sealed.

Three real issues surfaced by the user's actual MetaEditor runs and
fixed across this phase: a classification bug
(`REASON_SUBMITTED_OK` falsely claimed for ambiguous retcodes), a
self-introduced regression (the durable attempt write moved to *after*
`OrderSend()` instead of before), and two test-assertion bugs in the
newest suite (missing the account-mode branch the file's own other
tests already used). This phase is also the first to touch
`MLQuantAI.mq5` itself (the main EA) - its own compile/run confirmed
the new startup audit-rebuild wiring fails closed correctly against
real, imperfect legacy event-store data, disabling C2 broker
submission for that session while every other subsystem kept running
normally. See `Docs/PhaseC_C2_StartupAuditRebuildWiring.md` for full
evidence.

**Real-submit capability remains explicitly disabled** (the opt-in
smoke test's confirmation input stays `false`) - it requires the
still-pending environment-lock checklist, one-time manual approval,
named allowlisted demo account/server, and separate explicit user
authorization for each individual smoke run, per the protocol the user
has laid out.

## [Unreleased] - C2.2/C2.3 startup audit-rebuild wiring (PASSED, real MetaEditor run, 2026-08-22)

Wires `BrokerSubmissionAudit_StartupRebuild()` into `MLQuantAI.mq5`'s
`OnInit`, right after the existing EventStore health/validation, and
makes `BrokerSubmissionGate_Evaluate` fail-closed with the new
`REASON_EXECUTION_AUDIT_NOT_READY` (`Core/MLQuantAI_ReasonCodes.mqh`,
append-only) until that rebuild has actually succeeded this session -
including for a request that has never been attempted anywhere (a
blanket disablement, since an unready registry might be hiding a real
prior attempt). New `Execution/MLQuantAI_BrokerSubmissionAuditReadiness.mqh`:
fail-closed-by-default readiness flag + the one real entry point,
re-entrant (a later failed rebuild correctly revokes a stale `true`).
Strictly read-only end to end - no `OrderSend`/broker query/candidate
mutation/event append/`OnTradeTransaction` anywhere. Both
`Tests/MLQuantAI_Test_C2_BrokerSubmissionGate_DurableIdempotency.mq5`
(three new tests: not-ready blocks a brand-new request, a failed
rebuild blanket-disables an unrelated request too, re-entrancy revokes
readiness) and `Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5`
(minimal setup-only amendment) updated accordingly. See
`Docs/PhaseC_C2_StartupAuditRebuildWiring.md`.

Real MetaEditor confirmation: `MLQuantAI.mq5` itself (the main EA, not
just a `Tests/*.mq5` script) compiled and ran cleanly - its own real
event store had pre-existing legacy data with an orphan lineage
reference, so the startup rebuild correctly failed closed and logged a
warning, disabling C2 broker submission for that session while every
other B-phase subsystem kept running normally - the fail-closed design
working exactly as intended on real, imperfect data. Integration test
suite: found 2 real `[FAIL]`s on first run (39/41), both in this
commit's own new test assertions (a missing DEMO/non-DEMO branch, same
pattern the file's other tests already use), not production code;
fixed, re-confirmed 41/41 ALL PASS. `Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5`
re-confirmed 147/147 ALL PASS (was 145/145). Full regression re-run in
the same session, per the user's explicit ask: `MLQuantAI_Test_C1_2_
ExecutionRequestSafetyGate.mq5` 128/128, `MLQuantAI_Test_C1_3_
ExecutionAuditReconciliation.mq5` 87/87, `MLQuantAI_Test_C2_3_
BrokerSubmissionAuditProjection.mq5` 104/104 - ALL PASS, no regression.

## [Unreleased] - C2.2/C2.3 durable idempotency integration patch (PASSED 22/22, real MetaEditor run, 2026-08-22)

The previously-deferred follow-up: `BrokerSubmissionGate_Evaluate`
(`Execution/MLQuantAI_BrokerSubmissionGate.mqh`) now consults C2.3's
frozen `SubmissionAttemptRegistry_HasAttempt()` interface as a third
check, after the in-session guard - no parsing/replay logic duplicated,
just a call into the interface. Per the frozen "simplest policy" this
checks `HasAttempt`, not `IsUnresolved`, so a fully **resolved** prior
attempt (e.g. `SUBMITTED`) still blocks resubmission of that exact
`execution_request_id`. New test suite
(`Tests/MLQuantAI_Test_C2_BrokerSubmissionGate_DurableIdempotency.mq5`,
real B5-C1/C2.2/C2.3 pipeline): proves the durable check works purely
from EventStore replay with a fresh in-session guard, proves a resolved
attempt still blocks resubmission, and proves isolation between
distinct `execution_request_id`s. Confirmed 22/22 ALL PASS. The
original, sealed C2.2 gate suite (145/145) was re-run in full and
confirmed unchanged - no regression. Real-submit capability is still
NOT considered safe to exercise: the registry must actually be rebuilt
from the event store at EA startup for this check to be restart-safe in
practice, and that rebuild wiring is a separate, not-yet-done
integration concern (no projection in this codebase is wired into
`MLQuantAI.mq5`'s `OnInit` yet) - flagged explicitly in the amended
file's own header comment. See
`Docs/PhaseC_C2_2_BrokerSubmissionAdapterStatus.md`'s "C2.2/C2.3
durable idempotency integration patch" section.

## [Unreleased] - Phase C2.3: Broker Submission Audit Projection + durable idempotency registry (PASSED 104/104, real MetaEditor run, 2026-08-22)

C2.3's first deliverable, per the sequencing agreed with the user in
C2.2's second amendment: `Execution/MLQuantAI_BrokerSubmissionAuditProjection.mqh`
adds `SubmissionAttemptProjection`/`SubmissionOutcomeProjection` (a
single, genuinely interleaved rebuild pass over C2.2's own
`EXECUTION_SUBMISSION_ATTEMPTED`/outcome-quartet events, staged on top
of C1.3's sealed, unmodified `ExecutionAuditProjection_RebuildFromFile()`
as a black-box gate — no sealed file edited anywhere), the frozen
`SubmissionAttemptRegistry_HasAttempt`/`_IsUnresolved` durable
idempotency interface (proves restart-safety purely from EventStore
replay — an attempt with no recorded outcome reads `HasAttempt=true`/
`IsUnresolved=true` from a cold rebuild alone, zero in-memory state
required), and `BrokerSubmissionReconciliation_Build()` (one row per
`execution_request_id` with ≥1 attempt, status computed from the latest
matching outcome: `NO_OUTCOME`/`ERROR`/`REJECTED`/`SUBMITTED`/`UNKNOWN`).
Strictly read-only: no `OrderSend`/broker query/broker mutation/
candidate-lifecycle transition/event append anywhere in this file.
Test suite drives the real B5-C1/C2.2 pipeline for every fixture and
covers 0..N never-deduped attempts, idempotent duplicate-event replay,
a `log_event_id` collision with a different payload failing the whole
rebuild closed, and every orphan/hash-mismatch/ordering-violation/
outcome-invariant rejection the frozen contract specifies. One real
compile error found on the user's first MetaEditor run (a test function
name over MQL5's 63-character identifier limit) — fixed, then confirmed
104/104 ALL PASS. See `Docs/PhaseC_C2_3_BrokerSubmissionAuditProjectionStatus.md`.
The C2.2 integration follow-up patch (wiring `BrokerSubmissionGate` to
this registry) is not yet started — real-submit capability, and the
opt-in smoke test, stay disabled/unauthorized until it lands.

## [Unreleased] - Phase C2.2 second amendment: attempt-before-send fix + SUBMISSION_STATUS_UNKNOWN (PASSED 145/145, real MetaEditor run, 2026-08-21)

Found via a second real user review of the merged, PASSED (121/121)
first amendment: (1) a real regression the first amendment itself
introduced - `EXECUTION_SUBMISSION_ATTEMPTED` moved to run *after* the
real `OrderSend()` call instead of before, violating the frozen C2.1
lifecycle's own ordering. Fixed by extracting `BrokerSubmission_RecordAttempt()`,
called by the thin `BrokerSubmission_Submit()` wrapper strictly before
`OrderSend()` - if it fails, `OrderSend()` is never called. (2) A real
semantic gap: `TRADE_RETCODE_CONNECTION` (and other ambiguous/
unrecognized retcodes) still transitioned the candidate to
`CANDIDATE_SUBMITTED`, implying an acknowledgment that never happened.
Added `SUBMISSION_STATUS_UNKNOWN` + `EVENT_TYPE_EXECUTION_SUBMISSION_UNKNOWN`
(`Core/MLQuantAI_Enums.mqh`) - `BrokerSubmission_ClassifyRetcode` now
returns a real 3-way `ENUM_SUBMISSION_STATUS`; the candidate is never
transitioned for `UNKNOWN`, reusing the existing "stays CREATED"
resting place rather than adding a new `ENUM_CANDIDATE_STATE` value.
`OrderSend()==false` stays `ERROR` (not downgraded to `UNKNOWN`) since
`GetLastError()` already provides real proof of a local/pre-dispatch
failure. Durable, restart-safe idempotency was agreed as a real gap but
deliberately deferred: C2.3 will build the canonical
`SubmissionAttemptRegistry` query interface first, and a small,
separately-scoped C2.2 integration patch will wire the gate to it
afterward - real-submit capability isn't considered safe until then.
`OrderSend()==false`'s `ERROR` classification was challenged a third
time and re-verified directly against the real MQL5 `OrderSend()`
reference page (fetched, not recalled from memory): confirmed `false`
means a failed basic structural check - the request never dispatched
at all, a bounded local condition - so `ERROR` stands unchanged. See
`Docs/PhaseC_C2_1_BrokerSubmissionContract.md`'s "C2.2 second
amendment" and "Durable idempotency" sections, and
`Docs/PhaseC_C2_2_BrokerSubmissionAdapterStatus.md`'s "C2.2 second
amendment" section, for full reasoning. Confirmed by a real MetaEditor
run: 145/145 ALL PASS. Real-submit smoke test stays disabled regardless
- per the user's own laid-out operational gate (durable idempotency
from C2.3 first, then a full pre-send environment/approval checklist,
then separate explicit authorization every time before any real demo
`OrderSend` is ever exercised).

## [Unreleased] - Phase C2.2 amendment: ambiguous-retcode fix + testable orchestration (PASSED 121/121, real MetaEditor run, 2026-08-21)

Found via real user review after C2.2's first 73/73 PASSED run (not
self-review): (1) `BrokerSubmission_ClassifyRetcode` classified
`TRADE_RETCODE_CONNECTION` and every other unlisted retcode as
`REASON_SUBMITTED_OK` - a false positive-acknowledgment claim for a
retcode where `OrderSend()` returned `true` but the terminal itself
detected no connection to the trade server. Fixed by adding
`REASON_EXECUTION_SUBMISSION_AMBIGUOUS` (`Core/MLQuantAI_ReasonCodes.mqh`)
and reserving `REASON_SUBMITTED_OK` for `TRADE_RETCODE_DONE`/
`_DONE_PARTIAL` only - the candidate's state transition is unchanged
(still legally `CANDIDATE_SUBMITTED` either way). (2) The event-
sequencing/state-transition orchestration around `OrderSend()` had zero
automated test coverage, since it lived entirely inside the one
function the automated suite may never call. Split into pure
`BrokerSubmission_ProcessSendResult` (takes `orderSendReturned`/
`tradeResult` as input, never calls `OrderSend`, fully testable) plus a
thin `BrokerSubmission_Submit` wrapper that now only makes the real
call. Six new branch-coverage tests added (`true+DONE`,
`true+DONE_PARTIAL`, `true+`explicit-rejection, `false+`error,
`true+CONNECTION`, `true+`unknown retcode) - none call real `OrderSend`.
One proposed change ("no `CANDIDATE_SUBMITTED` until positive
acknowledgment") was evaluated and rejected as illegal under the
sealed state machine - see `Docs/PhaseC_C2_2_BrokerSubmissionAdapterStatus.md`'s
"C2.2 amendment" section for the full reasoning. Confirmed by a real
MetaEditor run: 121/121 ALL PASS.

## [Unreleased] - Phase C2.2: Broker Submission Adapter (PASSED 73/73, real MetaEditor run, 2026-08-21)

Implements `Docs/PhaseC_C2_1_BrokerSubmissionContract.md`. Adds
`MLQUANTAI_MAGIC_NUMBER` (`Core/MLQuantAI_VersionRegistry.mqh`),
`ExecutionSubmissionResult` (`Execution/MLQuantAI_ExecutionSubmissionContract.mqh`),
`BrokerSubmissionGate_Evaluate` (`Execution/MLQuantAI_BrokerSubmissionGate.mqh`
- every C1.2 gate re-run fresh via the sealed, unmodified
`SafetyGate_Evaluate`, plus a real `ACCOUNT_TRADE_MODE_DEMO` cross-check
paired with `ExecutionPolicy.environment_mode == EXECUTION_ENV_DEMO`,
plus an in-session idempotency registry - zero new reason codes,
reuses `REASON_EXECUTION_ENVIRONMENT_NOT_PERMITTED`/`REASON_DUPLICATE_EVENT`),
`BrokerSubmission_BuildTradeRequest`/`BrokerSubmission_ClassifyRetcode`
(`Execution/MLQuantAI_BrokerSubmissionBuilder.mqh` - pure, no `OrderSend`
call anywhere), and `BrokerSubmission_Submit`
(`Execution/MLQuantAI_BrokerSubmissionAdapter.mqh` - the only place in
this codebase that calls the real `OrderSend`, implementing the frozen
lifecycle exactly: pre-submit gate → `EXECUTION_SUBMISSION_ATTEMPTED`
→ `OrderSend` → branch on its return value per the sealed state
machine).

Per the user's explicit instruction ("แยก unit test (gate/construction
logic) ออกจาก real-submit smoke test"), the automated regression suite
(`Tests/MLQuantAI_Test_C2_2_BrokerSubmissionGate.mq5`) never calls
`BrokerSubmission_Submit`/`OrderSend` - a separate, explicitly opt-in,
manual-only script (`Tests/MLQuantAI_SmokeTest_C2_2_RealOrderSend.mq5`,
gated behind an unchecked-by-default confirmation input plus its own
independent `ACCOUNT_TRADE_MODE_DEMO` check) is the only place a real
order may actually be sent.

One real bug found and fixed via the user's actual MetaEditor run (not
self-review): `ZeroMemory()` on `MqlTradeRequest`/`MqlTradeResult` does
not reliably zero their `string` members (`symbol`/`comment`) - MQL5
strings are reference-counted handles, not raw bytes. Fixed with manual
field-by-field zero-init helpers. After the fix: 73/73 ALL PASS,
reproduced twice. See
`Docs/PhaseC_C2_2_BrokerSubmissionAdapterStatus.md`.

## [Unreleased] - Phase C2.1: Broker Submission Contract (frozen, no code)

Opens after C1 FULLY SEALED (215/215, all real MetaEditor runs). First
phase in this project that will eventually call a real broker-mutating
MT5 API (`OrderSend`). **C2.1 itself is documentation only** - no
`OrderSend` call, no `OnTradeTransaction` handler, no broker-mutating
test run anywhere. Froze `Docs/PhaseC_C2_1_BrokerSubmissionContract.md`
after resolving a real architectural conflict found before any code
existed: the originally-proposed "local `OrderSend()` failure ->
`CANDIDATE_ERROR` directly" is illegal under the already-sealed
`StateMachine_CanTransition` (`ERROR` is reachable only from
`SUBMITTED`, never `CREATED`) - resolved by keying the lifecycle off
what `OrderSend()`'s own return value actually means (`false` = never
reached the server, candidate stays `CREATED`; `true` = reached the
server, always transitions through `SUBMITTED` first) rather than
bending the sealed contract.

Adds two new, append-only event types
(`EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED`/
`EVENT_TYPE_ORDER_SUBMISSION_ERROR`), reuses the dormant
`EVENT_TYPE_ORDER_SUBMITTED`/`_ORDER_REJECTED` as-is (confirmed no
conflicting semantics), and needs **zero new reason codes** - Phase
A's own dormant "execution" `ENUM_REASON_CODE` block
(`REASON_SUBMITTED_OK`/`REASON_BROKER_REJECT`/`REASON_INVALID_STOPS`/
`REASON_INSUFFICIENT_MARGIN`/`REASON_REQUOTE`/`REASON_ERROR_INTERNAL`)
already anticipated exactly this moment. Freezes a new
`ExecutionSubmissionResult` struct (not a reuse of the dormant
`ExecutionResult` - lacks lineage fields and conflates submit-
acknowledgement with fill truth; `fill_price`/`slippage_points` stay
out of scope, owned by a later `OnTradeTransaction` reconciliation
commit). Environment authorization tightened per explicit user
confirmation: only a real `AccountInfoInteger(ACCOUNT_TRADE_MODE) ==
ACCOUNT_TRADE_MODE_DEMO` account may receive an `OrderSend` call in
C2.2 - `REAL` and `CONTEST` both rejected, Strategy Tester support
held pending separate verification. See
`Docs/PhaseC_C2_1_BrokerSubmissionContract.md`.

C2.2 (implementation) requires a separate, explicit confirmation
naming the resolved permitted environment before any code is written.

## [Unreleased] - Phase C1: FULLY SEALED (2026-08-21)

**C1.2 (128/128) + C1.3 (87/87) = 215/215, all real MetaEditor runs**,
plus a full manual regression re-run of the entire B9 chain in the
same session confirming no regression anywhere in B9:
`Test_B9_ExecutionEligibility.mq5` 120/120,
`Test_B9_Commit2_EligibilityEvent.mq5` 84/84,
`Test_B9_Commit3_IntegrationRegression.mq5` 79/79. Combined with
C1.1's frozen contract (no code), C1 (ExecutionRequest + Safety Gate +
Dry-Run, contract through audit/reconciliation) is fully sealed - zero
broker mutation anywhere across all of C1. Two real issues surfaced by
the user's actual MetaEditor runs and fixed: a compile error
(`ExecutionRequestProjectionRecord` passed where the real
`ExecutionRequest` type was required) and a test-construction bug (a
line-swap test also tripped `EventStoreValidator`'s own separate
strict-monotonic-`seq` gate before this file's own ordering check
could run - fixed by renumbering `seq` after the swap). See
`Docs/PhaseC_C1_3_ExecutionAuditReconciliationStatus.md`. C2 (real
broker submit) stays explicitly held pending separate, explicit user
authorization.

## [Unreleased] - Phase C1.3: Audit Projections + Integrity Checks + Reconciliation Read Model (PASSED 2026-08-21)

Opens after C1.2 PASSED (128/128, real MetaEditor run, 2026-08-21).
Implements `Docs/PhaseC_C1_1_ExecutionRequestContract.md`'s C1.3
addendum. Strictly read-only over the event data C1.2 already durably
writes - no broker query, no broker mutation, no candidate-lifecycle
transition, no retry mechanism, no C2 event type.

Two corrections to this project's own established projection
precedent, made before any code existed: (1) an orphan
`EXECUTION_DRY_RUN_COMPLETED` (referencing a request not yet seen)
fails the whole rebuild closed - it can never surface as a soft
reconciliation status alongside `PAIRED`/`UNPAIRED`; (2)
`ExecutionRequestProjection`/`DryRunResultProjection` are built
together in ONE single, sequential, interleaved pass over the file -
unlike every prior `*Projection.mqh`'s two-pass design - since a naive
two-pass rebuild would silently fail to catch a completion event
appearing before its own request in file order.

### Added
- `Execution/MLQuantAI_ExecutionAuditProjection.mqh` (new):
  `ExecutionRequestProjection` (1 per `execution_request_id`, same
  duplicate-vs-collision rule every prior projection uses),
  `DryRunResultProjection` (0..N per request, keyed by the event's own
  `source_sequence_number`, never deduped by `execution_request_id`
  alone - a legitimate re-evaluation after runtime context changes is
  real audit history, not a duplicate), `ExecutionReconciliation_BuildReport`
  (`PAIRED`/`UNPAIRED`, computed only after both projections rebuild
  cleanly).
- `Tests/MLQuantAI_Test_C1_3_ExecutionAuditReconciliation.mq5` (new,
  10 test functions).

Real MetaEditor run: **87/87 checks passed, ALL PASS**, plus the
manual regression re-run in the same session:
`Test_B9_ExecutionEligibility.mq5` 120/120,
`Test_B9_Commit2_EligibilityEvent.mq5` 84/84,
`Test_B9_Commit3_IntegrationRegression.mq5` 79/79, and
`Test_C1_2_ExecutionRequestSafetyGate.mq5` 128/128, all real, all ALL
PASS. C1.3 is PASSED and merged to `mlquantai` - **C1 is FULLY SEALED
at 215/215** (C1.2 + C1.3).

## [Unreleased] - Phase C1.2: ExecutionRequest Build + SafetyGate + Dry-Run Emission (PASSED 2026-08-21)

Opens after C1.1's contract freeze was confirmed. Implements
`Docs/PhaseC_C1_1_ExecutionRequestContract.md`'s C1.2 addendum: the
frozen 12-step, first-match-wins `SafetyGate_Evaluate` gate order,
`ExecutionRequest_Build`'s fail-closed ladder (ELIGIBLE-only gate, a
`REJECTED` `EligibilityDecision` never produces a request), and
`ExecutionRequest_EmitAndEvaluate`'s dual-event emission
(`EXECUTION_REQUEST_CREATED` always first, then
`EXECUTION_DRY_RUN_COMPLETED` always - `ACCEPTED` and `REJECTED` both).
Still zero broker mutation anywhere - no `OrderSend`/`CTrade`/pending-
order API, no `CANDIDATE_SUBMITTED` transition, no dormant
`EVENT_TYPE_ORDER_*` use. See
`Docs/PhaseC_C1_2_ExecutionRequestSafetyGateStatus.md`.

Two small amendments made to the C1.1 struct freeze before any code
shipped (documented in the C1.2 addendum, not a later correction):
`ExecutionRequest` gained a `risk_amount` field (needed for the
exposure cap to have something to check without a separate `RiskPlan`
dependency), and `ExecutionPolicy.max_exposure` was renamed
`max_planned_risk_amount` (per-trade planned monetary risk at the
planned stop, deliberately NOT notional value).

### Added
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_EXECUTION_REQUEST_SCHEMA_C1_V1`/
  `MLQUANTAI_EXECUTION_POLICY_SCHEMA_C1_V1`/
  `MLQUANTAI_DRY_RUN_RESULT_SCHEMA_C1_V1`.
- `Core/MLQuantAI_ReasonCodes.mqh` (additive): 11 new execution-gate
  `ENUM_REASON_CODE` values (Safe Mode reuses
  `REASON_RISK_CIRCUIT_BREAKER` rather than a duplicate).
- `Core/MLQuantAI_Enums.mqh` (additive):
  `EVENT_TYPE_EXECUTION_REQUEST_CREATED`/`EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED`,
  `ENUM_EXECUTION_ENVIRONMENT_MODE`, `ENUM_SAFETY_GATE_DECISION`.
- `Core/MLQuantAI_Ids.mqh` (additive): `Ids_ExecutionRequestId`.
- `Execution/MLQuantAI_ExecutionRequestContract.mqh` (new):
  `ExecutionPolicy`/`ExecutionRequest`/`DryRunExecutionResult` -
  deliberately NOT a reuse of the dormant Phase-A/pre-B
  `ExecutionResult`/`ExecutionEvent` structs (those assume a real
  broker response C1's dry-run never has).
- `Execution/MLQuantAI_ExecutionRequestBuilder.mqh` (new):
  `ExecutionRequest_Build`.
- `Execution/MLQuantAI_SafetyGate.mqh` (new): `SafetyGate_Evaluate`.
- `Execution/MLQuantAI_ExecutionRequestEventEmission.mqh` (new):
  `ExecutionRequest_EmitAndEvaluate`.
- `Tests/MLQuantAI_Test_C1_2_ExecutionRequestSafetyGate.mq5` (new, 20
  test functions).

Real MetaEditor run: **128/128 checks passed, ALL PASS.** C1.2 is
PASSED and merged to `mlquantai`.

## [Unreleased] - Phase C1.1: ExecutionRequest + Safety Gate + Dry-Run contract (frozen, no code yet)

Opens after B9 FULLY SEALED (283/283, all real MetaEditor runs).
First Phase C commit - and the first phase in this project that will
eventually call real broker-mutating MT5 APIs (C2, held pending
explicit authorization). Froze
`Docs/PhaseC_C1_1_ExecutionRequestContract.md` after a read-only
collision check against `ExecutionResult`/`ExecutionEvent` (dormant
Phase-A/pre-B contract structs - superseded, not reused, since C1's
dry-run has no real broker response to report), the existing live
`correlation_id`/`Ids_CorrelationId` concept (reused, carried
alongside a new, distinct `execution_request_id`), `SafeModeState.mqh`
(reused directly), `RiskPlan`/`EligibilityDecision`'s exact canonical
field names, the fully-specified-but-undriven `CREATED -> SUBMITTED ->
{EXECUTED, REJECTED_BY_BROKER, ERROR}` state machine transition, and
the dormant, reserved `EVENT_TYPE_ORDER_SUBMITTED`/`_ORDER_FILLED`/
`_ORDER_REJECTED`/`_POSITION_CLOSED` event types (left untouched,
reserved for C2 - C1 mints two new event types instead).

**C1 non-negotiable, frozen for every C1 commit**: C1 must never call
a broker-mutating API, under any input or flag - a `dry_run=false`
value must be rejected fail-closed (`REASON_EXECUTION_SUBMIT_DISABLED`,
a new, tail-appended `ENUM_REASON_CODE` value), never silently
switched to a real submit path. C1's dry-run is purely observational:
it never transitions `CANDIDATE_SUBMITTED` or any other candidate
state - only an `ELIGIBLE` `EligibilityDecision` may become an
`ExecutionRequest`, and the candidate stays at `CANDIDATE_CREATED`
throughout C1.

### Added (contract only - no `.mqh`/`.mq5` code yet)
- `ExecutionPolicy`, `ExecutionRequest`, `DryRunExecutionResult` struct
  shapes (`ExecutionAuditRecord`'s exact payload deferred to C1.3,
  once C1.2's real structs exist to reference).
- `Ids_ExecutionRequestId(candidateId, eligibilityDecisionId,
  aiDecisionId, riskPlanId, executionPolicyVersion)` - new deterministic
  ID, following the sealed `Ids_Deterministic` pattern.
- `SafetyGate_Evaluate` behavior spec: fail-closed on a malformed
  request, fail-closed on `dry_run == false`, reuses `SafeMode_IsActive()`/
  `SafeMode_AllowNewCandidates()` directly, otherwise `SAFETY_GATE_ACCEPTED`.
- `EVENT_TYPE_EXECUTION_REQUEST_CREATED`/`EVENT_TYPE_EXECUTION_DRY_RUN_COMPLETED`
  reserved (append-only, after `EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED`,
  the current true tail) - not yet added to `ENUM_EVENT_TYPE`, that
  happens in C1.3 when they're first actually emitted.

C1.2 (implementation) and C1.3 (audit event/projection/reconciliation/
regression/seal) come next, same three-commit shape every prior
B-phase has used. C2 (real broker submit) stays explicitly held
pending separate, explicit user authorization.

## [Unreleased] - Phase B9: FULLY SEALED (2026-08-21)

**283/283, all real MetaEditor runs**: Commit 1 (pure eligibility
mapping) 120/120, Commit 2 (`EXECUTION_ELIGIBILITY_DECIDED` event +
`CANDIDATE_REJECTED_BY_RISK` lifecycle wiring + replay) 84/84, Commit 3
(full-chain integration + regression proof) 79/79 - Commit 3's own
manual regression re-run of Commit 1 (120/120) and Commit 2 (84/84) in
the same MetaEditor session, both real, both ALL PASS.

B9 is the last policy authority before Phase C: `RiskPlan` (B7, sealed)
+ `AIDecision` (B8.5, sealed) + operational constraints (daily loss,
drawdown, total exposure, open positions, margin, safe-mode/circuit-
breaker) combine into `ELIGIBLE`/`REJECTED`, with `REJECTED` driving
the candidate's `CANDIDATE_REJECTED_BY_RISK` lifecycle transition -
still without any broker/order/execution authority of its own, which
stays Phase C's exclusive job. See
`Docs/PhaseB_B9_Commit3_IntegrationRegressionStatus.md`. Phase C
(broker execution) opens next.

## [Unreleased] - Phase B9 Commit 3: Full-Chain Integration + Regression Proof, Seal (PASSED 2026-08-21)

Opens after B9 Commit 2 PASSED (84/84, real MetaEditor run,
2026-08-20). Implements the Commit 3 addendum in
`Docs/PhaseB_B9_ExecutionEligibilityContract.md` (frozen before code).
Adds **zero new production behavior** - purely a test-suite commit
proving Commit 1 + Commit 2's already-shipped pieces compose correctly
end to end, across all three independent upstream chains
(`RiskPlanProjection`, `AIDecisionProjection`, `FeatureSnapshotProjection`)
feeding `EligibilityDecisionProjection`. See
`Docs/PhaseB_B9_Commit3_IntegrationRegressionStatus.md`.

### Added
- `Tests/MLQuantAI_Test_B9_Commit3_IntegrationRegression.mq5` (new, 7
  test functions): end-to-end linkage across all five upstream layers
  in one place; cross-layer failure propagation proven independently
  for the candidate, risk-plan, and model-artifact chains; full-chain
  restart simulation across all six projections for a mixed
  `ELIGIBLE`/`REJECTED` multi-candidate store; multi-candidate
  cross-linking; and a new test-only reconciliation helper detecting a
  `REJECTED` decision whose `CANDIDATE_REJECTED_BY_RISK` consequence
  never made it into the store - the non-rollback edge case Commit 2's
  own contract explicitly deferred.

Real MetaEditor run: **79/79 checks passed, ALL PASS**, plus the manual
regression re-run in the same session: `Test_B9_ExecutionEligibility.mq5`
120/120 and `Test_B9_Commit2_EligibilityEvent.mq5` 84/84, both real, both
ALL PASS. B9 Commit 3 is PASSED and merged to `mlquantai` - **B9 is
FULLY SEALED at 283/283.**

## [Unreleased] - Phase B9 Commit 2: EXECUTION_ELIGIBILITY_DECIDED Event + Lifecycle Wiring (PASSED 2026-08-20)

Opens after B9 Commit 1 PASSED (120/120, real MetaEditor run,
2026-08-20). Implements the Commit 2 addendum in
`Docs/PhaseB_B9_ExecutionEligibilityContract.md` (frozen before code),
after a collision check confirming `ENUM_EVENT_TYPE`'s true tail was
still `EVENT_TYPE_AI_DECISION_CREATED`, that `EXECUTION_ELIGIBILITY_DECIDED`
must be a `SystemEvent` (same family as `RISK_PLAN_CREATED`/
`AI_DECISION_CREATED`) while `CANDIDATE_REJECTED_BY_RISK` is a real
`LifecycleEvent` via the existing, sealed `EventStore_LogTransition` -
the first B-phase commit needing two distinct event families in one
commit - and resolving the design gap that `EligibilityContext` has no
upstream event of its own by persisting its raw account/safe-mode
evidence verbatim inside `EXECUTION_ELIGIBILITY_DECIDED`'s own payload,
so replay can independently recompute and verify
`eligibility_context_hash`. See
`Docs/PhaseB_B9_Commit2_EligibilityEventStatus.md`.

Event ordering is frozen: `EXECUTION_ELIGIBILITY_DECIDED` always first
(`ELIGIBLE` and `REJECTED` both - audit evidence either way);
`CANDIDATE_REJECTED_BY_RISK` only on `REJECTED`, only strictly after
the decision event is already durable. `ELIGIBLE` never emits a
lifecycle transition and never touches submission/order/broker in any
way. Non-rollback failure-mode rule: if the decision write succeeds but
the lifecycle write then fails, the already-durable decision event is
never rewritten or deleted (append-only store) - the function returns
`false`, meaning "decision durably recorded, lifecycle state may not
reflect it yet," never "nothing happened."

### Added
- `Core/MLQuantAI_Enums.mqh` (additive):
  `EVENT_TYPE_EXECUTION_ELIGIBILITY_DECIDED` + matching
  `EventTypeToString`/`EventTypeFromString` cases.
- `Execution/MLQuantAI_EligibilityEventEmission.mqh` (new):
  `EligibilityDecision_ToExtraJson` (every `EligibilityDecision` field +
  all 8 raw `AccountSnapshot` fields, prefixed `account_`, +
  `safe_mode_active`) and
  `EligibilityDecision_EmitDecisionAndWireLifecycle` - the Commit 2
  boundary function implementing the frozen dual-emitter ordering and
  non-rollback rule above.
- `Execution/MLQuantAI_EligibilityDecisionProjection.mqh` (new): a
  read-only registry that rebuilds and cross-verifies **three**
  independent upstream chains (`RiskPlanProjection`,
  `AIDecisionProjection`, `FeatureSnapshotProjection`, the last reached
  both directly and via the AIDecision record) and reconstructs +
  verifies each record's own `eligibility_context_hash` from its
  persisted raw evidence - the mechanism that makes that evidence
  protective, not merely informational.
- `Tests/MLQuantAI_Test_B9_Commit2_EligibilityEvent.mq5` (new, 10 test
  functions).

Real MetaEditor run: **84/84 checks passed, ALL PASS.** B9 Commit 2 is
PASSED and merged to `mlquantai`.

## [Unreleased] - Phase B9 Commit 1: Execution Eligibility Pure Mapping (PASSED 2026-08-20)

Opens after B8.5 SEALED (254/254, all real MetaEditor runs).
Implements `Docs/PhaseB_B9_ExecutionEligibilityContract.md` (frozen
before code, after a collision check against `ENUM_RISK_DECISION`,
`RiskPlan`'s Phase A shadow fields, the dormant `RiskDecision` struct
(Phase B1, contract-only - not reused, same fate as `AIResult` at
B8.5's own freeze), the candidate lifecycle state machine
(`CANDIDATE_SUBMITTED`/`_EXECUTED`/`_REJECTED_BY_RISK` - real, sealed,
but zero production call sites today), `SafeMode_IsActive()`/
`SafeMode_AllowNewCandidates()`, `AIResult` (still dormant), the
existing dormant `REASON_RISK_*` reason-code vocabulary, and
`AccountSnapshot` (Phase A, already embedded in B7's `RiskContext`,
already live-populated for `balance`/`equity`/`margin_level`/
`open_positions_count` - `open_risk_percent`/`daily_pnl_percent`/
`drawdown_from_peak_percent` stay hard-coded `0` today, accepted as
inputs exactly as currently populated per this commit's own scope).
See `Docs/PhaseB_B9_Commit1_ExecutionEligibilityStatus.md`. Not yet
compiled/run by the user - status is Implemented, not PASSED.

Pure mapping only: no event emission, no
`CANDIDATE_REJECTED_BY_RISK` or any state-machine transition, no live
account/tick/broker/`SafeMode` call inside the builder, no
spread/news/kill-zone re-evaluation (B5's job already), no mutation of
any input.

### Added
- `Core/MLQuantAI_Enums.mqh` (additive): `ENUM_ELIGIBILITY_DECISION`
  (`NONE`/`ELIGIBLE`/`REJECTED`) + `EligibilityDecisionToString`/
  `EligibilityDecisionFromString` - a new enum, not a reuse of
  `ENUM_RISK_DECISION` (B7's sizing-success axis) or
  `ENUM_AI_DECISION_OUTCOME` (B8.5's AI-only axis).
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_ELIGIBILITY_CONTEXT_SCHEMA_B9_V1`,
  `MLQUANTAI_ELIGIBILITY_DECISION_SCHEMA_B9_V1`.
- `Core/MLQuantAI_Ids.mqh` (additive):
  `Ids_EligibilityDecisionId(candidateId, eligibilityPolicyVersion)`.
- `Execution/MLQuantAI_EligibilityContract.mqh` (new):
  `EligibilityContext` (embeds `AccountSnapshot` verbatim, no separate
  identity - only a content hash, since the same candidate can be
  legitimately re-evaluated multiple times with different account
  state each time), `EligibilityPolicy` (explicit, versioned
  thresholds, `0` = gate disabled), `EligibilityDecision` (frozen
  output record).
- `Execution/MLQuantAI_EligibilityBuilder.mqh` (new):
  `EligibilityDecision_Build` - the fail-closed ladder frozen in the
  contract, deciding in a frozen precedence order (AI veto first, then
  each operational gate, then `ELIGIBLE`).
- `Tests/MLQuantAI_Test_B9_ExecutionEligibility.mq5` (new, 22 test
  functions).

Real MetaEditor run 1: 6 compile errors, all `undeclared identifier
'Ids_EligibilityDecisionId'` - root cause was a stale local
`MLQuantAI_Ids.mqh` (the sent file already had the function), not a
code bug. Real MetaEditor run 2, after re-copying the file: **120/120
checks passed, ALL PASS.** B9 Commit 1 is PASSED and merged to
`mlquantai`.

## [Unreleased] - Phase B8.5: FULLY SEALED (2026-08-20)

**254/254, all real MetaEditor runs**: Commit 1 (threshold-policy pure
mapping) 72/72, Commit 2 (`AI_DECISION_CREATED` event +
`AIDecisionProjection`) 123/123, Commit 3 (full-chain integration +
regression) 59/59. Commit 3's own manual regression re-run - required
by its Definition of Done, not a separate step - also confirmed clean
in the same MetaEditor session: `Test_B8_1_FeatureSnapshot.mq5` 66/66,
`Test_B8_3_ModelRegistry.mq5` 106/106, `Test_B8_5_AIDecision.mq5`
72/72, `Test_B8_5_Commit2_AIDecisionEvent.mq5` 123/123 - no regression
anywhere in the B8.1/B8.3/B8.5 chain. Full evidence in
`Docs/PhaseB_B8_5_Commit3_IntegrationRegressionStatus.md`.

B8.5 is the first layer with authority to interpret `p_success` as
`ALLOW`/`REJECT`/`ABSTAIN` (still unreachable this policy version),
still without execution authority - B9 remains the sole place
`RiskPlan` + `AIDecision` + operational policy combine into
`ELIGIBLE`/`REJECTED`. The old, informal "B8.6: persist/replay/audit"
scoping language used in a few early B8.1/B8.4 contract docs is fully
superseded by B8.5 Commit 2/Commit 3 - no separate B8.6 phase remains;
see `Docs/PhaseB_Architecture_Baseline.md`'s note. B9 opens next.

## [Unreleased] - Phase B8.5 Commit 3: Full-Chain Integration + Regression Proof, Seal (PASSED 59/59, seal pending)

Opens after Commit 2 PASSED (123/123, real MetaEditor run). Implements
`Docs/PhaseB_B8_5_AIDecisionContract.md`'s Commit 3 addendum (frozen
before code, mirrors B7 Commit 3 / B8.2 Commit 4). See
`Docs/PhaseB_B8_5_Commit3_IntegrationRegressionStatus.md`. Real
MetaEditor run: **59/59 checks passed, ALL PASS.** Adds **zero new
production behavior** - pure test-suite commit. Per this commit's own
Definition of Done, B8.5 is not yet declared SEALED until a manual
re-run of `Test_B8_1_FeatureSnapshot.mq5`/`Test_B8_3_ModelRegistry.mq5`/
`Test_B8_5_AIDecision.mq5`/`Test_B8_5_Commit2_AIDecisionEvent.mq5` in
the same MetaEditor session also confirms clean.

### Added
- `Tests/MLQuantAI_Test_B8_5_Commit3_IntegrationRegression.mq5` (new,
  6 test functions): end-to-end linkage across all four layers
  (candidate/snapshot/model artifact/decision); cross-layer failure
  propagation for BOTH independent upstream chains (candidate/snapshot
  side, and the model side independently); full-chain multi-decision
  restart/crash simulation across all four projections; multi-candidate,
  multi-model cross-linking (shared and distinct models in one store).

On a clean pass (this commit + a manual re-run of
`Test_B8_1_FeatureSnapshot.mq5`/`Test_B8_3_ModelRegistry.mq5`/
`Test_B8_5_AIDecision.mq5`/`Test_B8_5_Commit2_AIDecisionEvent.mq5`),
B8.5 will be declared SEALED.

## [Unreleased] - Phase B8.5 Commit 2: AI_DECISION_CREATED Event + AIDecisionProjection (PASSED 2026-08-20)

Opens after Commit 1 PASSED (72/72, real MetaEditor run). Implements
`Docs/PhaseB_B8_5_AIDecisionContract.md`'s Commit 2 addendum (frozen
before code, after a collision check against
`AI_DECISION_CREATED`/`AIDecisionProjection`/`AIDecisionRegistry`/
`ai_decision_id`/`ai_decision_hash`/`AIDecision_Emit`/
`EVENT_TYPE_AI_DECISION`/`AI_DECISION`/`ENUM_EVENT_TYPE`/
`EVENT_TYPE_CANDIDATE_REJECTED_BY_AI`/`AIResult` - no ownership
collisions found). See
`Docs/PhaseB_B8_5_Commit2_AIDecisionEventStatus.md`. Real MetaEditor
run 1: compiled clean, 122/123 checks passed, 1 real failure -
root-caused to a test-file bug (an exact `==` check on a float-sourced,
`CanonicalDouble`-round-tripped `p_success`, stricter than that
formatter's own documented 8-decimal precision contract), fixed. Real
MetaEditor run 2, after the fix: **123/123 checks passed, ALL PASS.**
B8.5 Commit 2 is PASSED and merged to `mlquantai`.

Persistence + projection + replay only: no execution behavior for any
`decision_outcome` (`ALLOW`/`REJECT`/`ABSTAIN` are all audit evidence
only), no candidate-lifecycle state transition, no B9 logic.

### Added
- `Core/MLQuantAI_Enums.mqh` (additive): `EVENT_TYPE_AI_DECISION_CREATED`
  appended after `EVENT_TYPE_MODEL_ARTIFACT_REGISTERED` (the true
  tail), plus `EventTypeToString`/`EventTypeFromString` cases and
  `AiDecisionOutcomeFromString` (the missing inverse of Commit 1's
  `AiDecisionOutcomeToString`).
- `AI/MLQuantAI_AIDecisionEventEmission.mqh` (new):
  `AIDecision_ToExtraJson` + `AIDecision_EmitAIDecisionCreated` - the
  only outcome-based gate is `ai_decision_id == ""` (a failed build);
  `ALLOW`/`REJECT`/`ABSTAIN` all emit identically.
- `Infrastructure/EventStore/MLQuantAI_AIDecisionProjection.mqh` (new):
  `AIDecisionProjectionRecord` + live-sync/replay/rebuild, mirroring
  `FeatureSnapshotProjection.mqh`. `AIDecisionProjection_RebuildFromFile`
  independently verifies referential integrity against BOTH
  `FeatureSnapshotProjection` and `ModelArtifactProjection` - the first
  projection in this project with two independent upstream lineage
  chains to check.
- `Tests/MLQuantAI_Test_B8_5_Commit2_AIDecisionEvent.mq5` (new, 15 test
  functions, using the real B5/B8.1/B8.3/B8.4/B8.5-Commit-1 pipeline
  for every fixture).

### Fixed (caught by the user's real MetaEditor run - NOT by self-review)
- `Tests/MLQuantAI_Test_B8_5_Commit2_AIDecisionEvent.mq5`: real run 1
  was 122/123 (1 fail: `p_success matches` in
  `Test_ReplayFieldsMatchOriginal`). Root cause: `p_success` is
  float-sourced (already known lossy, per Commit 1's own fix) AND
  persisted through `CanonicalDouble`'s deliberately lossy 8-decimal
  JSON round trip (`DoubleToString(x, 8)` -> `StringToDouble` on
  replay) - the same documented precision contract the `RiskPlan`
  Commit 2 test suite already calls out for arithmetic-derived doubles.
  An exact `==` check was stricter than that contract promises. Fixed
  with an epsilon comparison. Production code
  (`AIDecision_EmitAIDecisionCreated`/`AIDecision_ToExtraJson`/
  `AIDecisionProjection_ApplyLine`) was not touched. See
  `Docs/PhaseB_B8_5_Commit2_AIDecisionEventStatus.md` for full detail.

## [Unreleased] - Phase B8.5 Commit 1: AIDecision + Threshold-Policy Pure Mapping (PASSED 2026-08-20)

Opens after B8.4 SEALED (210/210 automated + manual restart checklist
PASSED). Implements `Docs/PhaseB_B8_5_AIDecisionContract.md` (frozen
before code). See `Docs/PhaseB_B8_5_AIDecisionStatus.md`. Real
MetaEditor run 1: compiled clean, 69/72 checks passed, 3 real
failures - root-caused to a float-to-double widening precision bug in
the TEST FILE (not in `AIDecision_Build`), fixed (see Fixed section
below). Real MetaEditor run 2, after the fix: **72/72 checks passed,
ALL PASS.** B8.5 Commit 1 is PASSED and merged to `mlquantai`.

Pure mapping only: no `AI_DECISION_CREATED`, no event store, no
ONNX/runtime call, no broker/account/tick call, no mutation of any
input.

### Added
- `Core/MLQuantAI_Enums.mqh` (additive): `ENUM_AI_DECISION_OUTCOME`
  (`NONE`/`ALLOW`/`REJECT`/`ABSTAIN`) + `AiDecisionOutcomeToString` -
  a new enum, not a reuse of Phase A's `ENUM_AI_DECISION`
  (`REDUCE_RISK` doesn't fit B8.5's scope).
- `Core/MLQuantAI_ReasonCodes.mqh` (additive): `REASON_AI_ABSTAIN`,
  appended at the true tail of `ENUM_REASON_CODE`.
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_AI_DECISION_SCHEMA_B8_5_V1`.
- `Core/MLQuantAI_Ids.mqh` (additive): `Ids_AIDecisionId(candidateId, modelRegistryId, decisionPolicyVersion)`.
- `AI/MLQuantAI_AIDecisionContract.mqh` (new): `AIDecisionPolicy` +
  `AIDecision` structs, `AIDecision_Init`/`AIDecision_HashPayload`/
  `AIDecision_ComputeHash`.
- `AI/MLQuantAI_AIDecisionBuilder.mqh` (new): `AIDecision_Build` - the
  fail-closed ladder frozen in the contract, taking both
  `InferenceResult` and `FeatureSnapshot` as inputs (the former alone
  carries no `candidate_id`/`candidate_hash`).
- `Tests/MLQuantAI_Test_B8_5_AIDecision.mq5` (new, 13 test functions).

### Fixed (caught by the user's real MetaEditor run - NOT by self-review)
- `Tests/MLQuantAI_Test_B8_5_AIDecision.mq5`: real run 1 was 69/72
  (3 fails). Root cause: `InferenceResult.output_values` is `float[]`;
  `AIDecision.p_success`/`AIDecisionPolicy.allow_threshold` are
  `double` - a `float` literal widened to `double` is not bit-identical
  to an independently-typed `double` literal that merely looks like the
  same decimal number (IEEE 754 widening). Fixed
  `Test_AcceptPath_Allow_AboveThreshold`'s exact-equality check to an
  epsilon comparison, and fixed
  `Test_AcceptPath_Allow_AtThresholdBoundary` to derive
  `allow_threshold` from the same originating float value
  (`(double)0.70f`) instead of an independent double literal, so the
  boundary test genuinely exercises `AIDecision_Build`'s inclusive
  `>=` at true equality. Production code (`AIDecision_Build` and the
  rest of `AI/MLQuantAI_AIDecisionContract.mqh`/
  `AI/MLQuantAI_AIDecisionBuilder.mqh`) was not touched - the defect
  was confined to the test file. See
  `Docs/PhaseB_B8_5_AIDecisionStatus.md` for full detail.

## [Unreleased] - Phase B8.4: FULLY SEALED (2026-08-20)

Automated proof complete across all three commits — Commit 1 (Tier A)
111/111, Commit 2 (Tier B) 61/61, Commit 3 (determinism/handle-lifetime)
38/38, total **210/210**. The manual terminal-restart checklist (see
`Docs/PhaseB_B8_4_Commit3_RuntimeDeterminism.md`) also PASSED for
real: Run A (pre-restart) and Run B (~4 minutes later, after the user
actually closed and reopened the MT5 terminal) reproduced identical
pass counts, the identical `"ONNX: CPU selected"` provider line, and
identical real-`onnxruntime`-matched output values on every comparison
point. Full evidence for both runs in
`Docs/PhaseB_B8_4_Commit3_RuntimeDeterminismStatus.md`'s "Manual
verification" section. B8.4 is sealed as **same-runtime,
same-CPU-provider** scope — cross-machine/cross-provider determinism
is still not claimed. B8.5 (AIDecision) opens next.

## [Unreleased] - Phase B8.4 Commit 3: Runtime Determinism and Handle-Lifetime Seal, Same Runtime Only (PASSED 2026-08-20)

Opens after B8.4 Commit 2 PASSED (61/61). Implements
`Docs/PhaseB_B8_4_Commit3_RuntimeDeterminism.md` (frozen before code).
See `Docs/PhaseB_B8_4_Commit3_RuntimeDeterminismStatus.md`. Confirmed
on a real MetaEditor run: `MLQuantAI_Test_B8_4_Commit3_RuntimeDeterminism.mq5`
38/38 ALL PASS. Merged to `mlquantai`.

Zero new production functions or constants - every test exercises
Commit 2's already-sealed `ModelRuntimeAdapter_LoadAndVerify` /
`ModelRuntimeAdapter_ValidateContractAndRun` / `Ids_Sha256HexBytes`
exactly as they are, against new fixtures/scenarios only. Scoped
explicitly to what this environment can prove: same machine, same
tested CPU provider - no cross-machine/cross-provider claim.

### Added
- `Tests/Fixtures/MLQuantAI_ONNX_Fixture_Valid_Relocated_V1.onnx` (new):
  byte-identical copy of the sealed `..._Valid_V1.onnx` (same SHA-256),
  proving artifact relocation without touching the artifact's identity.
- `Tests/MLQuantAI_Test_B8_4_Commit3_RuntimeDeterminism.mq5` (new, 6
  test functions): artifact relocation; input-perturbation sensitivity
  (two real, independently-`onnxruntime`-computed outputs - `0.5094773`
  vs `0.4129363` - on the same fixture, framed as model-fixture-specific,
  not a universal claim); released-handle reuse (deterministic
  fail-closed, no crash); one-call handle lifetime (no cross-cycle
  leak); no mutation; no side effects (structural, referencing Commit
  2's own proof rather than duplicating it).

### Scope note
- This commit does NOT claim bitwise cross-machine equivalence,
  cross-provider equivalence, or automated terminal-restart proof - a
  manual verification checklist for terminal-restart determinism is
  documented separately and is not part of the automated pass/fail
  count.

## [Unreleased] - Phase B8.4 Commit 2: Artifact Integrity + Runtime Adapter, Tier B (PASSED 2026-08-20)

Opens after B8.4 Commit 1 PASSED (111/111). Implements
`Docs/PhaseB_B8_4_Commit2_RuntimeAdapter.md` (frozen before code). See
`Docs/PhaseB_B8_4_Commit2_RuntimeAdapterStatus.md` for the full record,
including all three real compile/run iterations. Confirmed on the
user's third real run: `MLQuantAI_Test_B8_4_Commit2_RuntimeAdapter.mq5`
61/61 ALL PASS, including a real `OnnxRun` execution producing
`0.5094773` - matching the value independently computed via real
`onnxruntime` in Python. Merged to `mlquantai`.

The project's first commit touching a real ONNX runtime, real binary
file I/O, and MQL5's native `matrixf` tensor type. Every new/changed
file was grepped for the `vector`/`matrix`/`vectorf`/`matrixf`
bare-identifier collision that caused Commit 1's real 121-error compile
failure - confirmed clean (only legitimate type declarations and prose
in comments/strings).

### Added
- `Core/MLQuantAI_Ids.mqh` (additive): `Ids_Sha256HexBytes(const uchar &bytes[])`
  - hashes raw bytes directly via `CryptEncode`, deliberately not built
    on `Ids_Sha256Hex` (that function's `string` -> UTF-8 round-trip is
    lossy/incorrect for arbitrary binary artifact bytes).
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_ONNX_INPUT_TENSOR_NAME`, `MLQUANTAI_ONNX_OUTPUT_TENSOR_NAME`,
  `MLQUANTAI_ONNX_BATCH_SIZE`.
- `Infrastructure/EventStore/MLQuantAI_ModelRuntimeAdapter.mqh` (new):
  `ModelRuntimeAdapter_LoadAndVerify` (I1-I3: single-read, hash-verify
  against `model_artifact_hash`, open an ONNX session from the exact
  same verified buffer - never a path reload) and
  `ModelRuntimeAdapter_ValidateContractAndRun` (I5-I6: real tensor
  reflection against the frozen input/output contract, `OnnxRun`, raw
  output handed to the caller - Tier A's `InferenceOutput_Validate`
  stays the single validator, never duplicated here). Session handle
  owned entirely inside the module, always released before returning.
- `Tests/Fixtures/MLQuantAI_ONNX_Fixture_*.onnx` (7 new real binary
  ONNX models, generated in Python, independently executed against real
  `onnxruntime` before being checked in - not just structurally
  validated): `Valid`, `Tampered`, `Garbage`, `WrongInputName`,
  `WrongInputShape`, `WrongOutputShape`, `WrongInputDtype`.
- `Tests/MLQuantAI_Test_B8_4_Commit2_RuntimeAdapter.mq5` (new, 12 test
  functions) - the project's first non-runtime-independent test suite.

### Fixed (caught during fixture generation, before any MQL5 code was written)
- The first "wrong input dtype" fixture mixed a DOUBLE input against
  FLOAT weights in a `Gemm` node - an invalid ONNX graph that fails to
  load at all in real `onnxruntime`, not a dtype-mismatch-at-inspection
  case as intended. Rebuilt as a fully self-consistent all-DOUBLE model,
  which loads correctly and genuinely exercises the intended
  `INPUT_TYPE_MISMATCH` reflection path.

### Fixed (caught by the user's real MetaEditor compile - 28 errors)
- `OnnxTypeInfo.type` was compared directly against `ONNX_DATA_TYPE_FLOAT`
  (implicit-conversion warning, silently comparing the wrong enum), and
  `.shape.dimensions` doesn't exist on the real struct
  (`undeclared identifier 'shape'`, cascading into further errors).
  Root cause, confirmed against https://www.mql5.com/en/docs/onnx/onnx_structures:
  `OnnxTypeInfo.type` is the parameter *kind* (`ENUM_ONNX_TYPE` -
  tensor/map/sequence), not the element data type; the data type and
  shape both live one level down in a `.tensor` substruct
  (`OnnxTensorTypeInfo.data_type` / `.dimensions[]`). Fixed by adding an
  explicit `.type == ONNX_TYPE_TENSOR` check (a genuine correctness
  improvement, not just a translation) before reading
  `.tensor.data_type` / `.tensor.dimensions[]`. `matrixf`'s
  constructor/indexing syntax and `OnnxRun`'s positional signature were
  confirmed correct by the same compile attempt - zero errors past the
  `OnnxTypeInfo` struct-access code.
- The remaining ~14 `undeclared identifier 'Ids_Sha256HexBytes'` errors
  were not a code bug: the source-of-truth `Core/MLQuantAI_Ids.mqh` in
  this repo already had the function correctly defined. Points to the
  compiled `MQL5\Include\MLQuantAI\Core\MLQuantAI_Ids.mqh` not having
  been fully overwritten with the updated file - no code change made.

### Fixed (caught by the user's real MetaEditor run, after both compile fixes above - 54/60 checks passing, all 6 remaining failures same root cause)
- `OnnxRun` does not auto-size an empty output container -
  `matrixf outputMatrix;` (default-constructed, zero-sized) failed for
  real with `ONNX: parameter is empty`. Fixed by pre-sizing
  `outputMatrix` to the exact `[1,1]` shape the I5 tensor-contract check
  had already confirmed the model declares
  (`matrixf outputMatrix(MLQUANTAI_ONNX_BATCH_SIZE, 1);`). All 6
  failures (the accept-path test and the determinism test, the only two
  that reach a real `OnnxRun` call) traced to this one root cause; every
  negative-path test that never reaches `OnnxRun` passed cleanly.

### Design decision made during implementation (within the frozen contract)
- `ModelArtifact` carries no locator/path field (by design, per B8.3).
  The runtime adapter takes the artifact file path as a plain
  caller-supplied parameter, never a `ModelArtifact` field - consistent
  with (and arguably strengthening) I3's locator-isolation principle,
  and requires zero changes to the sealed `MLQuantAI_ModelArtifact.mqh`.

## [Unreleased] - Phase B8.4 Commit 1: Inference Contract, Tier A (PASSED 2026-08-19)

Opens after B8.3 PASSED (106/106). Implements
`Docs/PhaseB_B8_4_InferenceContract.md` (frozen before code). See
`Docs/PhaseB_B8_4_InferenceTierA.md`. The user's first real compile
failed (121 errors, see Fixed section below); after the fix, confirmed
on a real MetaEditor run: `MLQuantAI_Test_B8_4_InferenceTierA.mq5`
111/111 ALL PASS. Merged to `mlquantai`.

Tier A only - no ONNX session, no model file I/O, no real runtime
call. Collision check clean; `AIResult` confirmed decision-level
(B8.5's future output type), left untouched. Canonical feature
ordering reuses B8.1's own sealed `FeatureSnapshot_VectorHashPayload`
order rather than reinventing one.

### Added
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_INFERENCE_REQUEST_SCHEMA_B8_4_V1`,
  `MLQUANTAI_INFERENCE_CONTRACT_B8_4_V1`,
  `MLQUANTAI_INFERENCE_INPUT_LENGTH_B8_1_V1`,
  `MLQUANTAI_OUTPUT_SCHEMA_P_SUCCESS_V1`.
- `AI/MLQuantAI_InferenceContract.mqh` (new): `ENUM_INFERENCE_FAIL_REASON`
  (full ~19-code vocabulary frozen for both Tier A and Tier B),
  `InferenceRequest` (pinned identity, no "latest," no fallback),
  `InferenceResult` (`output_hash` excludes event metadata/time/path).
- `AI/MLQuantAI_InferenceRequestBuilder.mqh` (new):
  `InferenceRequest_Build` - all fields mandatory, fail-closed.
- `AI/MLQuantAI_CanonicalFeatureVector.mqh` (new):
  `CanonicalFeatureVector_FromSnapshot` - the frozen 12-element
  `float[]` tensor layout, B8.1's own order.
- `AI/MLQuantAI_InferenceOutputValidator.mqh` (new):
  `InferenceOutput_Validate` - one frozen output schema
  (`OUTPUT_P_SUCCESS_V1`) as a concrete proof of the shape.
- `Infrastructure/EventStore/MLQuantAI_ModelInference.mqh` (new):
  `ModelInference_ResolveAndPrepare` + `ModelInference_ValidateAndBuildResult`
  - two pure, testable halves either side of a real runtime call,
  instead of a single "run inference" function that would misrepresent
  that no real runtime call happens in this commit.
- `Tests/MLQuantAI_Test_B8_4_InferenceTierA.mq5` (new, 18 test
  functions).

### Fixed (caught during self-review, before any test run)
- The registry-rejection test's "incompatible" case originally reused
  a `STAGING` artifact to test a `model_target` mismatch, but
  `ModelArtifact_CheckCompatibility` checks `promotion_state` before
  the 6 field comparisons - that case would always have surfaced
  `MODEL_NOT_PROMOTED` instead. Fixed by registering a separate,
  genuinely `PROMOTED` artifact for that specific test.

### Fixed (caught by the user's real MetaEditor compile - NOT by self-review)
- `vector` is a reserved/built-in MQL5 type (native matrix/vector
  math; the compiler's own error suggestions listed built-in
  `vector`/`matrix` overloads). `Tests/MLQuantAI_Test_B8_4_InferenceTierA.mq5`
  used the bare identifier `vector` as an ordinary local variable name
  in six test functions, causing a cascading 121-error compile
  failure. Production `.mqh` files were unaffected - they already used
  `outVector`/`canonicalVector`, never bare `vector`. Fixed by
  renaming every bare `vector` local in the test file to
  `canonicalVec` (word-boundary-safe rename; the distinctly named
  `vector2` fixture was correctly left untouched), then restoring the
  original wording in the string-literal test labels the mechanical
  rename had also altered. Re-verified: balance/identifier-length
  check clean, full re-read confirms no argument-order regressions and
  the STAGING-vs-PROMOTED isolation fix above is still intact, and a
  repo-wide grep confirms no other `vector`/`matrix`/`vectorf`/`matrixf`
  identifier collisions anywhere in `Include/MLQuantAI` or the test
  file (only harmless mentions inside comments).

## [Unreleased] - Phase B8.3: Model Registry / Artifact Contract (PASSED 2026-08-19)

Opens after B8.2 SEALED (394/394). Implements
`Docs/PhaseB_B8_3_ModelRegistryContract.md` (frozen before code). See
`Docs/PhaseB_B8_3_ModelRegistry.md`. Confirmed on a real compile/test
run: `MLQuantAI_Test_B8_3_ModelRegistry.mq5` 106/106 ALL PASS.

Registry/compatibility contract only - no ONNX loading, no inference,
no scoring. Collision check clean; explicitly supersedes
`Docs/PhaseB8_B9_Roadmap_Notes.md`'s informal proposal to place
artifact identity/lineage fields directly on `AIDecision` - those now
live on this independent `ModelArtifact` registry.

### Added
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_MODEL_REGISTRY_SCHEMA_B8_3_V1`.
- `Core/MLQuantAI_Ids.mqh` (additive): `Ids_ModelRegistryId(modelId, modelVersion)`.
- `Core/MLQuantAI_Enums.mqh` (additive): `EVENT_TYPE_MODEL_ARTIFACT_REGISTERED`.
- `AI/MLQuantAI_ModelArtifact.mqh` (new): `ModelArtifact` struct with
  two distinct hashes (`model_artifact_hash` = external binary
  evidence, `model_registry_hash` = internal full-record integrity,
  deliberately including its own schema version in the payload - a
  confirmed departure from the RiskPlan/TrainingDatasetRow precedent),
  `ENUM_MODEL_PROMOTION_STATE`.
- `AI/MLQuantAI_ModelArtifactBuilder.mqh` (new): `ModelArtifact_Build`
  (all fields mandatory, fail-closed) and
  `ModelArtifact_CheckCompatibility` (exact-match-only, fail-closed,
  no search/fallback/substitution).
- `Infrastructure/EventStore/MLQuantAI_ModelArtifactEventEmission.mqh`
  (new): mirrors `RealizedOutcome_EmitTradeOutcomeLabeled`.
- `Infrastructure/EventStore/MLQuantAI_ModelArtifactProjection.mqh`
  (new): registry with no `CandidateProjection` prerequisite (a
  `ModelArtifact` isn't tied to any candidate) - documented as a
  deliberate scope boundary.
- `Infrastructure/EventStore/MLQuantAI_ModelRegistryCompatibility.mqh`
  (new): `ModelRegistry_FindCompatible` - registry-lookup wrapper,
  looks up exactly one named `model_id`+`model_version`.
- `Tests/MLQuantAI_Test_B8_3_ModelRegistry.mq5` (new, 18 test
  functions).

### Fixed (caught during self-review, before any test run)
- `MLQuantAI_ModelArtifactProjection.mqh` was missing an explicit
  `#include` for `MLQuantAI_EventStoreValidator.mqh` -
  `EventStoreValidator_ValidateLines`/`EventStoreValidationReport`
  would have been undeclared identifiers. Every prior projection got
  this transitively via `CandidateProjection.mqh`'s own include, which
  this file deliberately does not depend on.

## [Unreleased] - Phase B8.2 Commit 4: Full-Chain Integration + Regression Proof (PASSED 2026-08-19) - B8.2 SEALED

Opens after B8.2 Commit 3 PASSED (109/109) and merged. Implements
`Docs/PhaseB_B8_2_Commit4_SealRegression.md` (frozen before code). See
`Docs/PhaseB_B8_2_Commit4_Seal.md`. Confirmed on a real compile/test
run: `MLQuantAI_Test_B8_2_Commit4_SealRegression.mq5` 104/104 ALL PASS,
plus the full manual regression checklist (Commit 1: 76/76, Commit 2:
105/105, Commit 3: 109/109) re-run clean in the same session, zero
regressions.

**B8.2 Training Dataset + Outcome Boundary is now SEALED. Total:
76 + 105 + 109 + 104 = 394/394.** No further change to any B8.2
production file is permitted going forward.

Adds zero new production behavior - purely a test-suite commit proving
the already-shipped B8.2 pieces (Commits 1-3) compose correctly end to
end, the same role B7 Commit 3 played for B7. Proves 4 critical gates
compositionally (not just per-layer, as Commits 1-3 already did):
outcome never reaches back into AI input; incomplete candidates are a
skip while corrupted artifacts fail the whole export closed; a
collision at any single layer blocks the export itself; export is
atomic (valid store -> full output, corrupted store -> zero output +
`Init()` manifest). Also clarifies `LABELED_ONLY`: checked the
codebase first (zero matches) - since this commit adds no new
production code, it is proven as a pure client-side filter over
already-shipped fields (`label_available`, `manifest.labeled_count`),
built in test code only.

### Added
- `Tests/MLQuantAI_Test_B8_2_Commit4_SealRegression.mq5` (new, 8 test
  functions): `Test_FullChain_EndToEndLinkage`,
  `Test_CrossLayerFailure_CorruptedCandidateBlocksWholeChain`,
  `Test_IncompleteAndCorrupt_AreNotTheSame`,
  `Test_Leakage_MultiCandidateCohort`,
  `Test_CollisionAnywhereBlocksExport`,
  `Test_ExportAtomicity_ValidVsCorrupted`,
  `Test_LabeledOnlyView_IsPureDerivedFilter`,
  `Test_FullChainRestartSimulation_MultiCandidate`.

## [Unreleased] - Phase B8.2 Commit 3: Outcome/Label Boundary (PASSED 2026-08-19)

Opens after B8.2 Commit 2 PASSED (105/105) and merged. Implements
`Docs/PhaseB_B8_2_Commit3_OutcomeLabelContract.md` (frozen before
code). See `Docs/PhaseB_B8_2_Commit3_OutcomeLabel.md`. Confirmed on a
real compile/test run: `MLQuantAI_Test_B8_2_Commit3_OutcomeLabel.mq5`
109/109 ALL PASS.

Freezing this contract required resolving three open design questions
first (all confirmed): RealizedOutcome is built/tested from synthetic
fixtures only (no live Execution Engine exists - B9/C are future
phases); `candidate_time` = `setup_anchor_bar_time` (the only real
time anchor in the B8.2 lineage); the manifest gets only
`candidate_count`/`incomplete_count`, not permanently-dead
`rejected_count`/`first_rejection_reason` fields.

### Added
- Part 0 (Commit 2 addendum, no behavior change): `TrainingDatasetManifest.candidate_count`/
  `.incomplete_count` (additive), populated by
  `TrainingDatasetExport_BuildDataset`'s existing skip paths.
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_REALIZED_OUTCOME_SCHEMA_B8_2_V1`.
- `Core/MLQuantAI_Ids.mqh` (additive):
  `Ids_RealizedOutcomeId(candidateId, labelSchemaVersion)`.
- `AI/MLQuantAI_RealizedOutcome.mqh` (new): `RealizedOutcome` struct -
  a single full-record hash, no two-hash split (unlike `FeatureSnapshot`).
- `AI/MLQuantAI_RealizedOutcomeBuilder.mqh` (new):
  `RealizedOutcome_Build` - fail-closed validation including a strict
  temporal boundary (`outcome_time` must be after
  `candidate.setup_anchor_bar_time`) and a fixed label schema version.
- `Infrastructure/EventStore/MLQuantAI_RealizedOutcomeEventEmission.mqh`
  (new): `RealizedOutcome_EmitTradeOutcomeLabeled` - reuses the dormant
  Phase A `EVENT_TYPE_TRADE_OUTCOME_LABELED` enum slot.
- `Infrastructure/EventStore/MLQuantAI_RealizedOutcomeProjection.mqh`
  (new): registry with referential integrity AND a replay-time
  temporal-boundary re-check against `CandidateProjection`.
- `Infrastructure/EventStore/MLQuantAI_TrainingDatasetExport.mqh`
  (extended, signature unchanged): looks up a `RealizedOutcome` per
  candidate and passes real label fields to `BuildTrainingDatasetRow`
  when found; `labeled_count`/`unlabeled_count` now tallied for real.
- `Tests/MLQuantAI_Test_B8_2_Commit3_OutcomeLabel.mq5` (new, 18 test
  functions): the 7 groups from the frozen contract, including an
  empirical leakage-protection proof (feature hashes unchanged
  before/after a `RealizedOutcome` exists for a candidate) and a
  split-stability regression test.

## [Unreleased] - Phase B8.2 Commit 2: FeatureSnapshot Persistence + Deterministic Training Dataset Export (PASSED 2026-08-19)

Opens after B8.2 Commit 1 PASSED (76/76) and merged. Implements
`Docs/PhaseB_B8_2_Commit2_ExportContract.md` (frozen before code). See
`Docs/PhaseB_B8_2_Commit2_Export.md`. Confirmed on a real compile/test
run: `MLQuantAI_Test_B8_2_Commit2_Export.mq5` 105/105 ALL PASS
(Commit 1's own suite re-confirmed 76/76 on the same run, unaffected).

Expanded from the original proposal after a collision check found the
proposed export pipeline assumed a `FeatureSnapshotProjection` that
never existed - B8.1 shipped `FeatureSnapshot` with zero event
emission, and no B8 roadmap commit had added one. User-confirmed
resolution: add the missing persistence layer first (Part 0, mirroring
B7 Commit 2's own `RiskPlan` event/projection pattern), then build the
export orchestration on top (Part 1).

### Added
- `Core/MLQuantAI_Enums.mqh` (additive): `EVENT_TYPE_FEATURE_SNAPSHOT_CREATED`
  + `EventTypeToString`/`EventTypeFromString` cases.
- `Infrastructure/EventStore/MLQuantAI_FeatureSnapshotEventEmission.mqh`
  (new): `FeatureSnapshot_EmitFeatureSnapshotCreated` - mirrors
  `RiskPlan_EmitRiskPlanCreated`, guard is `feature_snapshot_id == ""`
  (no `allowed` field on `FeatureSnapshot`).
- `Infrastructure/EventStore/MLQuantAI_FeatureSnapshotProjection.mqh`
  (new): `FeatureSnapshotProjectionRecord` registry, required-field/
  numerical-integrity validation, payload-aware collision-vs-duplicate
  detection, referential-integrity check against `CandidateProjection`,
  `EventStoreValidator`-gated atomic rebuild.
- `Core/MLQuantAI_Ids.mqh` (additive): `Ids_TrainingDatasetId(fileName, modelTarget, datasetHash)`.
- `AI/MLQuantAI_TrainingDatasetRow.mqh` (additive):
  `TrainingDatasetManifest.labeled_count` field.
- `Infrastructure/EventStore/MLQuantAI_TrainingDatasetExport.mqh`
  (new): `TrainingDatasetExport_BuildDataset` - deterministic, read-only
  export joining `CandidateProjection`/`FeatureSnapshotProjection`/
  `RiskPlanProjection`, calling the sealed `BuildTrainingDatasetRow`
  (Commit 1) once per qualifying candidate. Skips candidates missing a
  `FeatureSnapshot`/ALLOWED `RiskPlan` (normal lifecycle state); fails
  closed only on `EventStoreValidator`/projection-rebuild failure or a
  mixed-cohort condition; rows ordered by `setup_anchor_bar_time ASC,
  dataset_row_id ASC`; `source_store_fingerprint` hashes every
  validated input line in original order.
- `Tests/MLQuantAI_Test_B8_2_Commit2_Export.mq5` (new, 19 test
  functions covering both Part 0 and Part 1, including the user's own
  explicitly-requested matrix: mixed-cohort rejection, duplicate-identity
  policy, read-only proof, exclusion proof).

### Fixed (caught during self-review, before any test run)
- `is_kill_zone` would have silently read back `false` always -
  `EventSerializer_GetStr`'s needle requires a quoted value, but
  `is_kill_zone` is emitted as an unquoted JSON boolean literal. Fixed
  with a local `FeatureSnapshotProjection_GetBoolLiteral` helper.
- `TrainingDatasetExport_SortRows`'s insertion sort never actually
  shifted the parallel `anchorTimes[]` array in lockstep with `rows[]`
  despite a comment claiming it did - would have desynced row order.
  Fixed, which required dropping `const` from the `anchorTimes` parameter.

## [Unreleased] - Phase B8.2 Commit 1: Training Dataset Row/Manifest Contract (PASSED 2026-08-19)

Opens Phase B8.2 ("training dataset contract") after B8.1 PASSED
(66/66) and merged. Implements
`Docs/PhaseB_B8_2_TrainingDatasetContract.md` (frozen before code).
Scoped to schema/identity/hash/split/pure-builder only - no event
store export orchestration, no real label/outcome computation. See
`Docs/PhaseB_B8_2_Commit1_TrainingDataset.md`.

A collision check (same discipline that caught B7's `RiskPlan` and
B8.1's `FeatureSnapshot`) confirmed `CandidateDatasetRow`/
`CandidateDatasetManifest` (B6.2, sealed) are a different concept - no
collision, separately named. `MLQUANTAI_LABEL_SCHEMA_VERSION =
"TBM_V1"` (a dormant Phase A placeholder) is not reused - mints
`MLQUANTAI_LABEL_SCHEMA_B8_2_V1` instead, same precedent B8.1 set for
`MLQUANTAI_FEATURE_SCHEMA_V1`.

### Added
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_DATASET_SCHEMA_B8_2_V1`, `MLQUANTAI_LABEL_SCHEMA_B8_2_V1`,
  `MLQUANTAI_DATASET_SPLIT_POLICY_V1`.
- `Core/MLQuantAI_Ids.mqh` (additive):
  `Ids_TrainingDatasetRowId(featureSnapshotId, labelSchemaVersion, modelTarget)`.
- `AI/MLQuantAI_TrainingDatasetRow.mqh` (new, first file in the
  pre-existing empty `AI/` folder): `TrainingDatasetRow`/
  `TrainingDatasetManifest` structs, `ENUM_DATASET_SPLIT`,
  `TrainingDatasetRow_HashPayload`/`_ComputeHash` (a full-record hash -
  lineage + label/outcome + split + target), `TrainingDatasetManifest_DatasetHash`
  (same style B6.2's `CandidateDatasetExport_DatasetHash` already
  established), `TrainingDatasetSplit_Assign` (deterministic,
  hash-derived, keyed on `candidate_id` so the same setup always lands
  in the same split even if re-labeled later under a different
  schema/target).
- `AI/MLQuantAI_TrainingDatasetBuilder.mqh` (new):
  `BuildTrainingDatasetRow` - fail-closed validation, referential-
  integrity checks against the supplied `FeatureSnapshot`/`RiskPlan`
  (an unallowed `RiskPlan` rejected outright - no training row without
  one), verbatim lineage copy, identity + split + hash computed last.
- `Tests/MLQuantAI_Test_B8_2_Commit1_TrainingDataset.mq5` (new):
  determinism (10,000 iterations), `dataset_row_id` dependency checks,
  `row_hash` inclusion/exclusion sweeps, referential integrity,
  fail-closed validation (including both directions of an inconsistent
  `labelAvailable`/label-fields combination), `label_available == false`
  as a valid first-class row, split determinism + a 2,000-sample
  statistical distribution sanity check, `dataset_hash`
  stability/reordering/tamper checks, input immutability, and
  structural no-event-store/no-label-leakage checks.

### Status
Confirmed on a real compile/test run:
`MLQuantAI_Test_B8_2_Commit1_TrainingDataset.mq5` 76/76 ALL PASS. The
2,000-sample split-distribution check landed at TRAIN=70.5%/
VALIDATION=14.3%/TEST=15.2% against the frozen 70/15/15 target. No
production code needed any change.

## [Unreleased] - Phase B8.1: FeatureSnapshot Identity/Lineage/Hash (PASSED 2026-08-19)

Opens Phase B8 ("AI/ML intelligence layer") after B7 SEALED (203/203,
full B5/B6/B7 regression suite 474/474, zero regressions). Implements
`Docs/PhaseB_B8_1_FeatureSnapshotContract.md` (frozen before code, then
revised once more before code per review - see that doc's revision
note). See `Docs/PhaseB_B8_1_FeatureSnapshot.md`.

A real naming collision was found and resolved before writing any
code, the same discipline that caught the B7 `RiskPlan` collision:
`Market/MLQuantAI_FeatureSnapshot.mqh` already existed from Phase B1 -
sealed, unwired, fixed named feature fields, no identity/hash/
candidate-lineage at all. Resolved by extending the existing struct
additively.

### Added
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_FEATURE_SCHEMA_B8_1_V1` - distinct from Phase B1's dormant
  `MLQUANTAI_FEATURE_SCHEMA_V1`, which `FeatureSnapshot_Init()` still
  stamps unchanged (keeps `Test_PhaseBContracts.mq5`'s sealed
  assertion true); `Candidate_ToFeatureSnapshot` overwrites it on
  success.
- `Core/MLQuantAI_Ids.mqh` (additive): `Ids_FeatureSnapshotId(candidateId)`
  - single-argument, since B8.1 has no feature-computation methodology
  choice yet to depend on.
- `Market/MLQuantAI_FeatureSnapshot.mqh` (additive): 7 new fields
  (`feature_snapshot_id`, `candidate_id`, `candidate_hash`,
  `context_hash`, `detector_hash`, `feature_vector_hash`,
  `feature_snapshot_hash`) alongside the unchanged Phase B1 ones;
  `FeatureSnapshot_VectorHashPayload`/`_ComputeVectorHash` (pure
  ML-input content, no lineage) and `FeatureSnapshot_HashPayload`/
  `_ComputeHash` (full record - identity+lineage+content) - a
  two-hash split `RiskPlan` never needed, since a feature vector can
  genuinely be "the same" across two different candidates in a way a
  `RiskPlan` never is.
- `Market/MLQuantAI_FeatureSnapshotBuilder.mqh` (new):
  `Candidate_ToFeatureSnapshot` - the pure candidate-time copy
  function (fail-closed validation, referential-integrity check
  against the supplied `MarketContext`, verbatim copy of every feature
  and lineage field, identity + both hashes computed last).
- `Tests/MLQuantAI_Test_B8_1_FeatureSnapshot.mq5` (new): determinism
  (10,000 iterations), `feature_snapshot_id` identity, `feature_vector_hash`
  inclusion sweep, lineage-only mutation sweep (proves the two-hash
  split - lineage changes move `feature_snapshot_hash` but never
  `feature_vector_hash`), verbatim-lineage-copy checks, cross-candidate
  identity distinctness, referential-integrity rejection, fail-closed
  validation (empty `candidate_id`, wrong `state`, `+Inf` via real
  multiplication overflow), input immutability, and structural
  no-event-store/no-future-field checks.

### Fixed
- `Tests/MLQuantAI_Test_B8_1_FeatureSnapshot.mq5`: originally included
  only `MLQuantAI_CRT_V1_Rules.mqh`, which doesn't transitively provide
  `CRT_ToTradeCandidate` (that lives in the separate
  `MLQuantAI_CRT_V1_ToTradeCandidate.mqh`). Fixed by including that
  file directly. Caught during self-review, before any user test run -
  no production code involved.

### Status
Confirmed on a real compile/test run:
`MLQuantAI_Test_B8_1_FeatureSnapshot.mq5` 66/66 ALL PASS. The only
other obstacles before a clean run were file-placement/sync issues on
the test machine (stale copies of `MLQuantAI_Ids.mqh` surviving
multiple individual file replacements) - resolved by sending a full
zip of `Include/MLQuantAI/` + `Tests/` to extract-and-replace in one
step. No further production code changes were needed.

## [Unreleased] - Phase B7 Commit 3: Full-Chain Integration + Regression Proof (PASSED 2026-08-18) - B7 SEALED

Implements the B7 Commit 3 addendum in
`Docs/PhaseB_B7_RiskPlanContract.md`, per the confirmed
`Docs/PhaseB_Architecture_Baseline.md` scoping. Adds zero new
production behavior - purely a test-suite commit proving the full
`MARKET_CONTEXT_READY` -> `CANDIDATE_CREATED` -> `CandidateProjection`
-> `Candidate_ToRiskPlan` -> `RISK_PLAN_CREATED` -> `RiskPlanProjection`
-> restart/replay chain composes correctly end to end. See
`Docs/PhaseB_B7_Commit3_IntegrationRegression.md`.

### Added
- `Tests/MLQuantAI_Test_B7_Commit3_IntegrationRegression.mq5` (new):
  end-to-end hash/ID linkage across all three layers in one assertion
  sequence; cross-layer failure propagation (a corrupted
  `CANDIDATE_CREATED` line also fails `RiskPlanProjection`'s rebuild,
  via its `CandidateProjection_RebuildFromFile` prerequisite);
  full-chain restart simulation across a 3-candidate store, both
  `CandidateProjection` and `RiskPlanProjection` compared
  byte-identical across two rebuilds; multi-candidate cross-linking
  (every plan checked against every candidate, not just its own).

### Status
Confirmed on a real compile/test run:
`MLQuantAI_Test_B7_Commit3_IntegrationRegression.mq5` 40/40 ALL PASS,
plus the full manual regression checklist re-run clean in the same
MetaEditor session: `Test_CandidateProjection.mq5` 146/146,
`Test_CandidateDatasetExport.mq5` 76/76, `Test_B6_3_HashContract.mq5`
89/89, `Test_B7_Commit1_RiskPlan.mq5` 98/98,
`Test_B7_Commit2_RiskPlanEvent.mq5` 65/65 - all ALL PASS, zero
regressions.

**B7 SEALED.** B7.1 through B7.5 are all PASSED and merged. B8.1
(`FeatureSnapshot`) opens next, per
`Docs/PhaseB_Architecture_Baseline.md`.

## [Unreleased] - Phase B7 Commit 2: RISK_PLAN_CREATED Event + RiskPlanProjection (PASSED 2026-08-18)

Implements B7.4 (`RISK_PLAN_CREATED` event emission) and B7.5
(`RiskPlanProjection` replay/recovery), per
`Docs/PhaseB_B7_RiskPlanContract.md`'s B7 Commit 2 addendum. Mirrors
`CANDIDATE_CREATED`/`CandidateProjection` (B5 Commit 5 / B6.1)
structurally and behaviorally, adapted for a `SystemEvent` since a
`RiskPlan` is a derived artifact tied to a candidate (like
`MarketContext`), not a candidate lifecycle transition. See
`Docs/PhaseB_B7_Commit2_RiskPlanEvent.md`.

### Added
- `Core/MLQuantAI_Enums.mqh` (additive): `EVENT_TYPE_RISK_PLAN_CREATED`
  appended at the end of `ENUM_EVENT_TYPE` (not inserted mid-enum),
  with matching `EventTypeToString`/`EventTypeFromString` cases.
- `Infrastructure/EventStore/MLQuantAI_RiskPlanEventEmission.mqh`
  (new): `RiskPlan_ToExtraJson` (every B7 `RiskPlan` field flattened as
  top-level JSON keys via the existing `CanonicalPrice`/
  `CanonicalDouble`/`CanonicalPercent` helpers), `RiskPlan_EmitRiskPlanCreated`
  (fail-closed on an unfilled/rejected plan; coarse live-session
  duplicate guard via `RiskPlanProjection_TryGet`; live-registry sync
  via `RiskPlanProjection_ApplyLiveRecord` after a successful durable
  write - the same live-sync fix B5 Commit 5 needed for
  `StateProjector`).
- `Infrastructure/EventStore/MLQuantAI_RiskPlanProjection.mqh` (new):
  `RiskPlanProjectionRecord`, the live in-memory registry,
  `RiskPlanProjection_ApplyLine` (line-length bound, type gate, parse,
  required-field/numerical-integrity validation, payload-aware
  collision-vs-duplicate detection on `risk_plan_id`/`plan_hash`),
  `RiskPlanProjection_ApplyLineWithCandidates` (orphan-candidate and
  candidate-hash-mismatch rejection against `CandidateProjection`),
  `RiskPlanProjection_RebuildFromFile` (`EventStoreValidator`-gated,
  then `CandidateProjection_RebuildFromFile` on the same file as a
  referential-integrity prerequisite, then its own rebuild - any stage
  failing leaves the registry untouched).
- `Tests/MLQuantAI_Test_B7_Commit2_RiskPlanEvent.mq5` (new): exactly-
  once emission, live-session duplicate no-op, rejected-plan-emits-
  nothing, replay duplicate (same `risk_plan_id`+`plan_hash`) no-op,
  replay collision (same `risk_plan_id`, different `plan_hash`)
  rejection, replay orphan-candidate rejection, replay candidate-hash-
  mismatch rejection, malformed-line-blocks-whole-rebuild, restart/
  crash-simulation record fidelity across repeated rebuilds, multi-
  session rebuild, and full field-by-field replay fidelity against the
  original in-memory `RiskPlan` (including `plan_hash` itself).

### Notes
- Three bugs were found and fixed in the test file during self-review,
  before any user compile/test run - no production code changed. See
  "Bugs found and fixed during self-review" in
  `Docs/PhaseB_B7_Commit2_RiskPlanEvent.md`.
- First real run: 63/65. Two more test-fixture bugs found and fixed
  (still no production code changed): a malformed-line-rebuild test
  wrongly assumed the registry would be empty rather than "left
  completely untouched" (the actual documented contract) after a
  failed rebuild; a field-fidelity test used exact `==` on
  arithmetic-derived doubles against their canonically-rounded
  (8-decimal) round-tripped values, which is stricter than
  `CanonicalDouble`'s own precision guarantee - fixed with an epsilon
  comparison. See `Docs/PhaseB_B7_Commit2_RiskPlanEvent.md`.

### Status
Confirmed on a real compile/test run:
`MLQuantAI_Test_B7_Commit2_RiskPlanEvent.mq5` 65/65 ALL PASS.

## [Unreleased] - Phase B7 Commit 1: RiskContext / RiskPlan / Candidate_ToRiskPlan (PASSED 2026-08-18)

Opens Phase B7 ("deterministic RiskPlan sizing") after B6 closed in
full (B6.1 146/146, B6.2 75/75, B6.3 89/89, all PASSED and merged).
Implements B7.1 (RiskContext) + B7.2 (RiskPlan schema/identity) + B7.3
(`Candidate_ToRiskPlan`, pure sizing) together, per
`Docs/PhaseB_B7_RiskPlanContract.md` (frozen before any code was
written). B7.4 (event emission) and B7.5 (replay/recovery) are not
part of this commit.

A real naming collision was found and resolved before writing any
code: `Core/MLQuantAI_RiskPlan.mqh` already existed from Phase A
(`decision`/`allowed`/`lot`/`risk_money`/`risk_percent`/
`reject_reason`), unused but sealed, and `Core/MLQuantAI_RiskDecision.mqh`
(Phase B1) had already flagged "B7 reconciles how the two relate when
the Risk Manager is built." Resolved by extending the existing struct
additively rather than declaring a second, differently-shaped
`RiskPlan` - every Phase A field kept unchanged, new B7 fields added
alongside, `Candidate_ToRiskPlan` fills both groups from the same
computation. See `Docs/PhaseB_B7_Commit1_RiskPlan.md`.

### Added
- `Core/MLQuantAI_CanonicalFormat.mqh` (new): `CanonicalPrice`/
  `CanonicalDouble`/`CanonicalPercent` - fixed-literal-precision
  formatting for every B7 hash payload double, never `Digits()`/
  `_Digits`.
- `Core/MLQuantAI_ContractVersions.mqh` (additive):
  `MLQUANTAI_RISK_CONTEXT_SCHEMA_V1`, `MLQUANTAI_RISK_PLAN_SCHEMA_V1`,
  `MLQUANTAI_RISK_SIZING_RULES_V1`.
- `Core/MLQuantAI_Ids.mqh` (additive): `Ids_RiskPlanId(candidateId,
  sizingRulesVersion)`.
- `Core/MLQuantAI_RiskContext.mqh` (new): `RiskContext` struct
  (embeds `AccountSnapshot`/`SymbolSpec` verbatim, snapshot-only),
  `RiskContext_Init`, `RiskContext_HashPayload`/`_ComputeHash`.
- `Core/MLQuantAI_RiskPlan.mqh` (additive): 12 new fields alongside
  the unchanged Phase A ones, `RiskPlan_HashPayload`/`_ComputeHash`.
- `Core/MLQuantAI_RiskSizing.mqh` (new): `Candidate_ToRiskPlan` - the
  frozen fixed-fractional-risk sizing formula (stop distance via
  `tick_size`, risk amount from `balance * target_risk_percent`, raw
  lot via `tick_value`, floor to `volume_step`, reject below
  `volume_min`, clamp above `volume_max`).
- `Tests/MLQuantAI_Test_B7_Commit1_RiskPlan.mq5` (new): sizing formula
  exact-number correctness, `risk_plan_id`/`plan_hash`
  identity-vs-content independence, `risk_context_hash`/`plan_hash`
  inclusion/exclusion mutation sweeps, fail-closed validation
  (non-finite price via real +Inf multiplication overflow -
  0.0/0.0 traps as a hard runtime error in MQL5, unlike Python/C -
  fixed after the first real test run caught it, zero/negative
  prices, wrong-side SL/TP
  ordering, non-positive symbol/account fields), volume normalization
  edge cases (below-min rejects, above-max clamps), a 10,000-iteration
  determinism loop, and input-immutability checks.

### Fixed
- `Tests/MLQuantAI_Test_B7_Commit1_RiskPlan.mq5`: the fail-closed
  "invalid number" test tried to construct a NaN entry_hint via
  `0.0/0.0`, assuming MQL5 follows IEEE754 silently the way Python/C
  do. It doesn't - MQL5 traps `0.0/0.0` as a hard "zero divide"
  runtime error and halts the script, caught on the first real
  compile/test run (the log stopped mid-suite at that exact line).
  Fixed by constructing `+Inf` via a real multiplication overflow
  (`1.0e307 * 1.0e307`) instead, which does not trap - both are
  "not a valid number" as far as `RiskSizing_ValidateInput`'s
  `MathIsValidNumber` check is concerned, so the fix still exercises
  the same code path. No production code needed any change.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_B7_Commit1_RiskPlan.mq5
98/98 ALL PASS. Two clarifications added to the contract doc and code
comments per QA review: risk_context_hash is a rules/spec snapshot
hash (not a full sizing-input hash - equal risk_context_hash values
do not guarantee equal plan_hash, since account.balance/equity
legitimately move plan_hash without moving risk_context_hash); lot/
risk_money (Phase A fields) are compatibility shadow fields, not the
canonical source of truth - risk_amount/lot_size are.

## [Unreleased] - Phase B B6.3: Hash Contract Spec (PASSED 2026-08-15)

Scoped down from the original B6.3 proposal after a gap review with the
user: most of the proposed work items (reject malformed/orphan/
collision lines, block export on a corrupt store, deterministic
byte-identical export, full row-lineage traceability) were confirmed
already built and already passed in B6.1 (146/146) and B6.2 (75/75) -
re-implementing them would have been duplicate work. See
Docs/PhaseB_B6_3_HashContractSpec.md's "What's already covered"
section for the full mapping.

The 3 genuinely new deliverables:

1. **A consolidated Hash Contract Spec** (Docs/PhaseB_B6_3_HashContractSpec.md) -
   the exact payload/inclusion/exclusion rules for `context_hash`,
   `detector_hash`, and `candidate_hash`, previously only scattered
   across code comments in 3 different files. Corrects one loose claim
   made during drafting: `digits` in `detector_hash`/`candidate_hash`
   is not an independently "excluded" field - it's a formatting
   multiplier on the included price fields, so changing it alone DOES
   move the hash (different DoubleToString precision = different
   string). Fixed before it became a test that would have asserted
   something false.
2. **Exhaustive inclusion/exclusion mutation-sweep tests** for
   `context_hash` and `detector_hash`, matching the rigor
   `candidate_hash` already had in Test_CandidateProjection.mq5.
3. **A structured rejection-reason classification**, additive on top
   of `CandidateProjection`'s existing free-text reason strings (which
   are completely unchanged): `ENUM_CANDPROJ_REASON_CATEGORY` +
   `CandidateProjection_ClassifyReason()` + a new
   `CandidateProjectionReport.first_error_code` field.

### Added
- `Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh`
  (additive): `ENUM_CANDPROJ_REASON_CATEGORY` (18 categories -
  NONE/APPLIED/SKIPPED_NOT_RELEVANT/SKIPPED_DUPLICATE/MALFORMED_LINE/
  NOT_GENESIS_SHAPE/EMPTY_CANDIDATE_ID/SCHEMA_VERSION/
  MISSING_REQUIRED_FIELD/INVALID_SIDE/TIME_INTEGRITY/
  NUMERICAL_INTEGRITY/REASON_CONSISTENCY/COLLISION/ORPHAN_CONTEXT/
  CONTEXT_HASH_MISMATCH/STORE_VALIDATION_FAILED/UNKNOWN),
  `CandidateProjection_ClassifyReason(reasonText)` (a pure classifier
  over the reason strings this file's own rejection sites produce -
  never used to change control flow, only to give callers a stable
  machine-readable category instead of parsing prose),
  `CandidateProjectionReport.first_error_code` (classified from the
  RAW per-line reason, before the `"line %d: "` prefix
  `RebuildFromFile` adds - so the prefix-anchored `"missing "` check
  still matches correctly). `first_error`/`outReason` string behavior
  is completely unchanged.
- `Docs/PhaseB_B6_3_HashContractSpec.md` (new).
- `Tests/MLQuantAI_Test_B6_3_HashContract.mq5` (new): `context_hash`
  inclusion sweep (21 fields) + exclusion whitelist (11 fields);
  `detector_hash` inclusion sweep (11 params) + a dedicated test
  proving `digits` is NOT independently excluded (moves the hash via
  reformatting, not directly); `CandidateProjection_ClassifyReason`
  tested both directly against the real pure validator functions
  (schema/required-fields/side/time/numerical/reason-consistency) and
  end-to-end through `ApplyLine`/`ApplyLineWithContext`/
  `RebuildFromFile` for every category (including collision, orphan,
  context-hash-mismatch, and store-level validation failure); a
  dedicated test confirming `report.first_error_code` and
  `report.first_error` stay consistent on the same real rejection.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_B6_3_HashContract.mq5
89/89 ALL PASS.

## [Unreleased] - Phase B B6.2: Canonical Dataset Export (PASSED 2026-08-15)

Closes the 2 remaining gates named at B6.1's approval: dataset export
determinism, and an end-to-end audit path from MARKET_CONTEXT_READY
through to a dataset row. Strictly additive, strictly read-only: reuses
B6.1's sealed `CandidateProjection_RebuildFromFile` for the candidate
set, reads the same store's lines a second time only to join each
candidate against its own MARKET_CONTEXT_READY event - no B5
Strategies/ file touched, no CRT detector call, no event appended, no
existing line rewritten. See Docs/PhaseB_B6_2_DatasetExport.md.

4 of the 9 dataset columns B6.1 flagged as missing (`instrument_id`/
`trigger_timeframe`/`news_decision_hash`/`news_snapshot_identity`) are
resolved by joining against already-persisted MARKET_CONTEXT_READY
fields - not by reopening sealed B5 code. The remaining 5
(`swept_level`/`mss_confirmation_price`/`resolved_zone_kind`/
`resolved_zone_low`/`resolved_zone_high`), plus a 10th discovered during
this commit (`strategy_version`), stay documented NOT AVAILABLE - no
join can produce data nothing was ever persisted. `strategy_name` (not
on the original gap list) is derived via the existing pure
`StrategyIdToString(strategy_id)`.

`row_hash` deliberately does not re-hash every field `candidate_hash`
already covers - it rolls `candidate_hash` up as one value and adds
only the export layer's own contribution (joined context fields,
`candidate_state`). `dataset_hash` hashes every row's `row_hash` in
final sorted order. `manifest.export_time` is populated last and
deliberately excluded from `dataset_hash` - only row content
determines it.

Export stays all-or-nothing, consistent with B6.1's already-approved
RebuildFromFile atomicity: any corrupt/orphaned/out-of-sequence line
anywhere blocks the WHOLE export (`ok == false`, `rows[]` empty), never
a silently-partial dataset. Flagged explicitly: this means
`manifest.rejected_count` is always 0 on any export that returns
`true` - the B6.2 spec's own wording could be read as implying a
different, selective per-row quarantine model, which was deliberately
not built here to stay consistent with the already-approved atomicity
contract.

### Added
- `Infrastructure/EventStore/MLQuantAI_CandidateDatasetExport.mqh`
  (new): `CandidateDatasetRow`, `CandidateDatasetManifest`,
  `CandidateDatasetExport_BuildDataset` (entry point), plus context-join,
  sort, row/dataset hash, and JSONL serialization helpers.
- `Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh`
  (additive): `CandidateProjection_GetAt(index, &out)` - bounds-checked
  full-registry accessor for the export layer's iteration. B6.1's
  sealed/tested behavior otherwise untouched.
- `Tests/MLQuantAI_Test_CandidateDatasetExport.mq5` (new): row
  projection (including all NOT-AVAILABLE fields and derived has_*
  flags), no-duplicate-ids, stable ordering, deterministic export
  (byte-identical JSONL + identical hashes across two builds of the
  same store), hash-changes-with-content, orphan-blocks-whole-export,
  read-only (store byte-identical before/after export), and a full
  end-to-end lineage test tracing MARKET_CONTEXT_READY -> CANDIDATE_CREATED
  -> registry -> dataset row.

### Fixed
- `Tests/MLQuantAI_Test_CandidateDatasetExport.mq5`: `Test_StableOrdering`
  reused `dayOffset = 10` (already used by `Test_NoDuplicateCandidateIds`'s
  `"DUPA"`) for its `"ORDEREARLY"` candidate. Since `candidate_id`/
  `root_event_id` depend only on `(symbol, timeframe, eventType,
  swept_level, mss_confirmation_bar_time)` - never on the test's
  `suffix` - and the fixture always draws identical price data, this
  produced an identical `candidate_id` across two different test
  functions. `StateProjector` (the live idempotency guard
  `CRT_EmitCandidateCreated` uses) is a process-global never reset
  between test functions within one script run - deliberate, sealed B5
  Commit 5 behavior - so the second emission silently returned `false`
  (no write, no error), leaving only 2 of 3 expected candidates in the
  store. No production code (`CandidateDatasetExport.mqh`,
  `CandidateProjection.mqh`, B5 `Strategies/`) needed any change.
  Fixed by using a globally-unique `dayOffset` and wrapping every
  `BuildAndEmitCandidate` call in the file in a `Check(...)` sanity
  assertion so a future collision fails loudly instead of silently.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_CandidateDatasetExport.mq5
75/75 ALL PASS.

## [Unreleased] - Phase B B6.1: Candidate Projection / Registry (hardened, PASSED 2026-08-15)

Opens B6 ("Candidate Dataset QA & Analytics"). Strictly additive,
strictly read-only: no B5 Strategies/ file touched, no live market/
broker/account call - the registry is built purely from persisted
CANDIDATE_CREATED lines via EventStore_ReadAllLines. See
Docs/PhaseB_B6_1_CandidateProjection.md, including a flagged (not
silently resolved) gap: several B6.2 canonical-dataset columns
(swept_level/resolved_zone_*/instrument_id/trigger_timeframe/
news_decision_hash/news_snapshot_identity) aren't in any persisted
CANDIDATE_CREATED event yet - deferred to B6.2's own kickoff decision.

Hardened after a QA review of the initial 104/104 pass, which proved
B6.1's mechanics but not adversarial robustness. The most important
fix: candidate_id reuse with a DIFFERENT candidate_hash is now rejected
as a collision/conflict, never silently treated as an idempotent
duplicate - the original version would have hidden exactly that class
of corruption. See Docs/PhaseB_B6_1_CandidateProjection.md's "Hardening
pass" section for the full gate-by-gate list (schema/time/numerical/
enum/reason-mask/resource-limit integrity, referential integrity against
MARKET_CONTEXT_READY, ordering/atomicity via EventStoreValidator-gated
rebuilds, restart/crash simulation, multi-session, a candidate_hash
mutation sweep, and a 25-candidate scale test). B6 as a whole remains
IN REVIEW / NOT CLOSED - dataset export (B6.2), the integrity validator
(B6.3), and full-phase regression are still outstanding.

### Added
- `Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh` (new):
  `CandidateProjectionRecord`, `CandidateProjection_ApplyLine` (now with
  full schema/time/numerical/enum/reason-mask/resource-limit validation
  and payload-aware collision detection), `CandidateProjection_TryGet`,
  `CandidateProjection_CollectContextHashes`/`_ApplyLineWithContext`
  (referential integrity against MARKET_CONTEXT_READY),
  `CandidateProjection_RebuildFromFile` (now EventStoreValidator-gated -
  ordering/atomicity), `CandidateProjectionReport`.
- `Infrastructure/EventStore/MLQuantAI_EventSerializer.mqh`:
  `EventSerializer_GetStringArray` - a generic `"key":["a","b"]` reader,
  promoted from a pattern previously hand-duplicated in three test files.
- `Tests/MLQuantAI_Test_CandidateProjection.mq5` (rewritten, real
  MARKET_CONTEXT_READY events now persisted per candidate): the original
  6 B6.1 gates plus collision, schema, time, numerical, enum, trigger-
  reasons, resource-limit, referential-integrity, ordering, atomicity,
  restart/crash, multi-session, 25-candidate-scale, and a full
  candidate_hash mutation sweep (decision-bearing fields move it,
  excluded fields don't).

### Fixed
- `CandidateProjection_ApplyLine`: two real bugs found during hardening
  test runs, both only reachable once real `MARKET_CONTEXT_READY` events
  shared a store with candidates for the first time. (1) Every non-
  `CANDIDATE_CREATED` line was misreported as "not a parsable lifecycle
  event line" (a false failure) instead of being skipped, because the
  type check ran after an `EventSerializer_ParseLifecycle()` call that
  requires a `candidate_id` key SystemEvents don't have. (2) The first
  fix over-corrected: a line with no `type` key at all (true garbage)
  was then waved through as "irrelevant, skip" instead of failing
  closed. Fixed by checking `type` via a category-agnostic string lookup
  *and* requiring the key to be present, before ever attempting the
  LifecycleEvent parse.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_CandidateProjection.mq5
146/146 PASS.

## [Unreleased] - Phase B B5 Commit 5: CANDIDATE_CREATED Event Emission (PASSED 2026-08-14, B5 = ALL COMMITS SEALED)

Implements the final Commit 5 boundary: `TradeCandidate ->
CANDIDATE_CREATED -> EventStore append`. Reuses Phase A's sealed
`EventStore_LogCandidateCreated()`/`StateProjector_TryGetState()`
machinery rather than inventing a new event-store primitive or
idempotency mechanism. See Docs/PhaseB_B5_Commit5.md, including a real
live-session idempotency gap this commit found and closed
(`StateProjector` is only populated by replay, never by
`EventStore_LogCandidateCreated()` itself - fixed by having
`CRT_EmitCandidateCreated()` apply the genesis event to `StateProjector`
immediately after each durable write).

### Added
- `Strategies/MLQuantAI_CRT_V1_EventEmission.mqh` (new):
  `CRT_EmitCandidateCreated`, `CRT_CandidateCreatedExtraJson`,
  `CRT_StringArrayToJson`.
- `Infrastructure/EventStore/MLQuantAI_EventStore.mqh`:
  `EventStore_LogCandidateCreated` gained an additive `extraJson=""`
  parameter (every existing Phase A caller unaffected).
- `Tests/MLQuantAI_Test_CRT_V1_CandidateCreatedEvent.mq5` (new): full
  Commit 5 required-test checklist - exactly-one-event-per-detection,
  required fields carried through, ordered trigger_reasons[] preserved,
  duplicate-candidate_id no-op, non-detection emits nothing, replay
  reconstruction via ReplayEngine_Run/StateProjector, replayed-fields-
  match-original, replay idempotency.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_CRT_V1_CandidateCreatedEvent.mq5
43/43 PASS. B5 Commits 1-5 are all SEALED; final B5 integration/replay QA
remains before the whole phase seals.

## [Unreleased] - Phase B B5 Commit 4: CRT_ToTradeCandidate (pure mapping) (PASSED 2026-08-14)

Implements the Commit 4 boundary: `bool CRT_ToTradeCandidate(ctx, crt,
outCandidate)` - copy/map only from Commit 3's `CRTDetectionResult`,
never recompute detector truth. Returns false (candidate left at
`TradeCandidate_Init()` defaults) on `crt.detected == false`; no Event
Store write, no state-machine call, no `CANDIDATE_CREATED` event either
way - that's Commit 5. See Docs/PhaseB_B5_Commit4.md.

### Added
- `Strategies/MLQuantAI_CRT_V1_ToTradeCandidate.mqh` (new):
  `CRT_ToTradeCandidate`, `CRT_CandidateHash`/`CRT_CandidateHashPayload`.
- `Core/MLQuantAI_TradeCandidate.mqh`: `detector_hash` (copied verbatim
  from `CRTDetectionResult.detector_hash`, never recomputed) and
  `candidate_hash` (new - a canonical hash over the candidate's own
  deterministic content, computed last, deliberately excluding
  account/spread/broker state/wall-clock and every B6/B7-owned mutable
  field) - both additive.
- `Tests/MLQuantAI_Test_CRT_V1_ToTradeCandidate.mq5` (new): full mapping
  correctness (both directions), the non-detection guard, the
  `detector_hash`/`candidate_hash` invariants, a 1000-repeat
  `candidate_hash` determinism loop, account-mutation independence,
  detector-input-not-mutated, and the `candidate_id`-differs-across-
  rules-versions acceptance gate.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_CRT_V1_ToTradeCandidate.mq5
79/79 PASS.

## [Unreleased] - Phase B B5 Commit 3: Pure CRT_V1 Detection Rules (PASSED 2026-08-14)

Implements the detection logic Docs/PhaseB_B5_CRTContract.md (Commit 1,
FROZEN) explicitly deferred to this commit: CRT_IsSweepLow/CRT_IsSweepHigh,
CRT_CloseBackInside, CRT_ConfirmMSS, CRT_FindFVG, CRT_FindOrderBlock,
CRT_ResolveZone (FVG_PRIORITY_THEN_OB_FALLBACK), CRT_EvaluateExpiry, and
the CRT_DetectV1() orchestrator. No TradeCandidate construction or event
emission - that's Commit 4. See Docs/PhaseB_B5_Commit3.md for the
implementation-level decisions this commit had to freeze that Commit 1's
contract deliberately left open (swept level = ctx.pdh/ctx.pdl, MSS
checked against the anchor bar only, pre-sweep structure lookback, the
new non-gating CRT_REASON_BIT_NEWS_RISK threshold).

### Added
- `Strategies/MLQuantAI_CRT_V1_Rules.mqh` (new): the pure detection rule
  functions plus `CRT_DetectV1(ctx, result)`, the orchestrator that turns
  a single `MarketContext` into zero or one `CRTDetectionResult`.
- `Tests/MLQuantAI_Test_CRT_V1_Rules.mq5` (new): all 11 QA-approved
  Commit 3 fixture gates (valid bullish/bearish, no-sweep,
  sweep-without-reclaim, reclaim-without-MSS, MSS-without-valid-zone,
  short-history, determinism, exactly-one-sweep/zone-bit) plus boundary
  equality and `CRT_EvaluateExpiry` tests - all hand-built `MqlRates`
  fixtures, no live/broker dependency.
- `Docs/PhaseB_B5_Commit3.md`: full write-up of every algorithmic
  decision this commit made, framed for review since the contract left
  them to Commit 3's discretion.

### Status
Confirmed on a real compile/test run: MLQuantAI_Test_CRT_V1_Rules.mq5
57/57 PASS. Fixed during review: CRT_TimeframeTagToPeriod originally used
StringToEnum(), unavailable in this MQL5 build - replaced with an
explicit if-chain (commit 4cc4199).

## [Unreleased] - Phase B B5 Commit 2: Context Window + CRT_V1 Domain Models (PASSED 2026-08-14)

Implements what Docs/PhaseB_B5_CRTContract.md (Commit 1, FROZEN after 3
QA review rounds) froze. No detection rule logic - no CRT_IsSweepLow/
CRT_ConfirmMSS/CRT_FindFVG/CRT_FindOrderBlock - that's Commit 3.
Confirmed on a real compile/test run: MLQuantAI_Test_CRTContextWindow.mq5
31/31, Test_DataHubDeterminism.mq5 (regression) 44/44, Test_NewsParity.mq5
(regression) 46/46 - 121/121 total.

### Added
- `Market/MLQuantAI_MarketContext.mqh`: `trigger_tf_recent[]` (additive)
  - last `MLQUANTAI_CRT_V1_LOOKBACK_BARS` closed bars on
  `trigger_timeframe`, oldest first, folded into both
  `MarketContext_HashPayload()` and `MarketContext_ToJsonFragment()`.
  `MarketContext_RatesArrayToJson`/`_RatesArrayFromJson`/`_RatesFromJson`
  - the array counterpart to the existing single-bar
  `MarketContext_RatesToJson`, self-contained (no EventSerializer
  dependency), same convention `NewsSnapshot.mqh` already uses.
- `Market/MLQuantAI_FeatureEngine.mqh`: `FeatureEngine_BuildContext()`
  captures `trigger_tf_recent[]` via one `CopyRates(..., 1,
  MLQUANTAI_CRT_V1_LOOKBACK_BARS, ctx.trigger_tf_recent)` call - a plain
  array, so `CopyRates` already fills it oldest-first with no manual
  reversal.
- `Core/MLQuantAI_ContractVersions.mqh`: `MLQUANTAI_CRT_V1_RULES_VERSION
  = "CRT_V1"`.
- `Strategies/MLQuantAI_CRT_V1_Contract.mqh` (new file, new `Strategies/`
  directory): every B5-frozen parameter as `#define`s, the 8
  `CRT_REASON_BIT_*` bit constants, `CRT_ReasonBitLabel`/
  `CRT_ReasonLabelsFromMask` (ascending-bit-order label vocabulary),
  `CRTDetectionResult` + `_Init`, `CRT_DetectorHash` (frozen payload/
  field order/numeric formatting, a pure function of its arguments).
- `Tests/MLQuantAI_Test_CRTContextWindow.mq5`: real-pipeline window
  rules (size, ordering, anchor equality, no forming-bar, determinism
  across rebuilds), pure-function hash-sensitivity and JSON round-trip
  tests, a persisted-payload replay test, and CRT_V1 domain-model tests
  (reason label ordering, detector_hash sensitivity, Init defaults).
- `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`: 2 new payload-
  completeness checks for `trigger_tf_recent[]`.

## [Unreleased] - Phase B B4 seal hardening

Two DoD gates from the original B4 pass weren't genuinely runtime-tested:
`Test_Seal_ReplayNeverCallsSources` only asserted `Check(true, "enforced
by construction")`, and additive schema evolution was never exercised at
all. See `Docs/PhaseB_B4_NewsParity.md`.

### Added
- `Market/MLQuantAI_NewsSource.mqh` / `Market/MLQuantAI_NewsCanonicalizer.mqh`:
  `forecast`/`actual`/`previous` additive fields on `RawNewsEvent`/
  `NormalizedNewsEvent` (both "" by default, not CSV columns - the frozen
  7-column format is unchanged). Folded into `News_SnapshotIdentity()`'s
  payload; deliberately excluded from `News_DecisionHash()` and from
  `NewsSnapshot`/`News_ToSnapshot()` itself.
- `Market/MLQuantAI_NewsEngine.mqh`: `g_NewsEngine_BuildCallCount` -
  increments once per `NewsEngine_Build()` call, turning "replay never
  touches a source" from an architectural claim into something a test can
  mechanically check.
- `Tests/MLQuantAI_Test_NewsReplayIsolation.mq5`: builds a `MarketContext`
  via the pure canonicalizer pipeline only (no `INewsSource` touched),
  persists `MARKET_CONTEXT_READY`, closes the store, re-opens a fresh
  handle, and asserts the replayed `news_decision_hash`/
  `news_snapshot_identity`/`context_hash`/`NewsSnapshot[]` match exactly
  what was computed before persisting - and that `g_NewsEngine_
  BuildCallCount` never moved across the whole sequence.
- `Tests/MLQuantAI_Test_NewsSchemaEvolution.mq5`: additive `forecast`/
  `actual`/`previous` metadata moves `news_snapshot_identity` but never
  `news_decision_hash`/`context_hash`; `normalized_event_key` stays
  stable regardless; the frozen V1 CSV fixture still loads/normalizes
  correctly (new fields read back empty, not misaligned/garbage) after
  the schema grew.

### Removed
- `Tests/MLQuantAI_Test_NewsParity.mq5`: `Test_Seal_ReplayNeverCallsSources`
  - superseded by `Test_NewsReplayIsolation.mq5`'s runtime-verified check.

## [Unreleased] - Phase B B4: News Parity Layer

One Raw -> Normalize -> Dedup -> Sort/Select pipeline shared by the live
MT5 Economic Calendar and a deterministic Tester-only CSV source, so
neither source can drift into its own interpretation of "the same news
event". See `Docs/PhaseB_B4_NewsParity.md`. Still no CRT/`TradeCandidate`/
execution code touched.

### Added
- `Market/MLQuantAI_NewsSource.mqh`: `RawNewsEvent` struct + `INewsSource`
  interface (`ReadRawEvents`/`SourceKind`) - the only shape either source
  is allowed to produce; no normalization at this layer.
- `Market/MLQuantAI_NewsCanonicalizer.mqh`: the pipeline. `NormalizedNewsEvent`,
  `News_NormalizeTitle`/`News_NormalizeImpact`/`News_NormalizeTimeUtc`,
  `News_MakeCanonicalEventKey`, `News_ComputeMinutesToEvent` (truncates
  toward zero both signs), `News_Deduplicate` (priority -> revision_timestamp
  -> lexical source_kind tie-break, fails loudly on an unresolved conflict),
  `News_SortAndSelect` (frozen 24h/24h/top-10 window), `News_DecisionHash`
  (decision-relevant fields only, source-independent) and
  `News_SnapshotIdentity` (full lineage, deliberately source-dependent -
  the B5 audit trail).
- `Market/MLQuantAI_NewsCoverageValidator.mqh`: `News_ValidateCoverage` -
  hard fail-closed gate (not advisory) on a source's raw data not fully
  covering a requested range.
- `Market/MLQuantAI_CsvStaticNewsSource.mqh`: `CsvStaticNewsSource` -
  frozen 7-column CSV format (`Common\Files`), fails closed on missing
  file/bad schema version/any malformed row - never skips a bad row.
- `Market/MLQuantAI_LiveCalendarNewsSource.mqh`: `LiveCalendarNewsSource` -
  wraps `CalendarValueHistory`/`CalendarEventById`/`CalendarCountryById`,
  routes through the same canonicalizer, fails closed (no silent fallback)
  on a calendar read failure.
- `Market/MLQuantAI_NewsEngine.mqh`: `NewsEngine_Build(anchorTime)` -
  the orchestrator; routes to CSV (Tester) or Live (else) by
  `MQL_TESTER`, runs the full pipeline, returns `NewsEngineResult`
  (`snapshots[]`, `news_count`/`max_news_impact`/`nearest_news_minutes`,
  `news_decision_hash`, `news_snapshot_identity`), logs one journal line
  per build. `NewsEngine_InitCsvSource`/`_DeinitCsvSource` load + hard-gate
  CSV coverage once from `OnInit`. Legacy `News_HighImpactNear*` (a
  separate live real-time gate check) kept unchanged.
- `Market/MLQuantAI_MarketContext.mqh`: `news_decision_hash`/
  `news_snapshot_identity` fields (additive). `MarketContext_HashPayload()`'s
  news contribution changed from a per-element `NewsSnapshot_HashFragment`
  loop (included `source_kind`) to the single `news_decision_hash` field -
  a deliberate algorithm change, justified in-file, since no candidate
  dataset yet depends on a historical `context_hash` value.
- `Market/MLQuantAI_NewsSnapshot.mqh`: `normalized_event_key`/`revision_id`/
  `revision_timestamp`/`source_priority` fields (additive lineage).
- `MLQuantAI.mq5`: `OnInit` now hard-gates on `NewsEngine_InitCsvSource()`
  in Tester mode - `INIT_FAILED` on a coverage/schema/file problem, not a
  warning.
- `Tests/MLQuantAI_Test_NewsParity.mq5` + `Tests/Fixtures/
  MLQuantAI_NewsParityFixture_V1.csv`: core parity (live vs. CSV agree on
  `news_decision_hash`, differ on `news_snapshot_identity`), canonicalization
  (case/whitespace/truncation/tie-break/order-independence), selection/
  coverage against the real fixture (>10 events caps to a deterministic
  top 10, dedup winner, fail-closed coverage gap and malformed CSV), and
  seal criteria (metadata-only changes don't move `news_decision_hash`,
  replay never touches a source, B5 lineage fields reach
  `MARKET_CONTEXT_READY`'s JSON payload).
- `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`: `Test_NewsSnapshotCanonicalization`
  renamed/migrated to `Test_NewsDecisionHash_DrivesContextHash` (asserts
  `MarketContext_HashPayload` tracks `news_decision_hash`, not raw `news[]`
  content) plus 2 new payload-completeness checks for the new hash fields.

### Removed
- `Market/MLQuantAI_NewsEngine.mqh`: `News_CsvImpactToInt`, `News_BuildSnapshots_Live`,
  `News_BuildSnapshots_Csv`, `News_BuildSnapshots` - superseded by
  `NewsEngine_Build()`'s shared pipeline; confirmed unused elsewhere.

## [Unreleased] - Phase B B3.5: Data Hub Determinism Seal

Hardens B3's `context_hash` to actually satisfy the 5 seal criteria
(in-session determinism, cross-session determinism, account-exclusion,
full hash coverage, regression) - see `Docs/PhaseB_B3_5_DeterminismSeal.md`.

### Added
- `Market/MLQuantAI_NewsSnapshot.mqh`: `NewsSnapshot_Canonicalize()`
  (sorts by `release_time` then `calendar_event_id`) and
  `NewsSnapshot_HashFragment()`. `FeatureEngine_BuildContext()` now
  canonicalizes `ctx.news` before computing aggregates or the hash, so
  `context_hash` no longer depends on calendar/CSV source ordering.
- `Market/MLQuantAI_MarketContext.mqh`: `MarketContext_HashPayload()`
  extended to include `m5_bar`/`m15_bar`/`h1_bar`/`h4_bar` (time, OHLC,
  tick_volume, historical spread, via the new
  `MarketContext_RatesHashFragment()`) and the full canonically-ordered
  `NewsSnapshot[]` content - previously only `news_count`/
  `max_news_impact`/`nearest_news_minutes` were hashed, not the news
  identity itself. `MarketContext_RatesToJson()` gained `tick_volume` to
  match what's now hashed.
- `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`: `Test_AccountExclusion_
  RealPipeline()` (mutates `.account` on a real built context, asserts
  the hash is unchanged), `Test_NewsSnapshotCanonicalization()`
  (self-contained, proves source-order independence after
  canonicalizing), `Test_CrossSessionFixture()` (persists a
  anchor+hash fixture across script runs to prove the SAME anchor bar
  hashes the same after a "restart").

## [Unreleased] - Phase B B3: Data Hub / Feature Engine Migration + Determinism

Migrates the live Data Hub/Feature Engine/`MLQuantAI.mq5` to the B1-frozen
`Market/MLQuantAI_MarketContext.mqh` contract, closed-bar only. See
`Docs/PhaseB_B3_DataHubDeterminism.md`. Still no CRT/strategy code, no AI,
no execution wiring.

### Added
- `Market/MLQuantAI_FeatureEngine.mqh`: `FeatureEngine_BuildContext()`
  replaces Step 9's `FeatureEngine_Build()` - builds the new
  `MarketContext`, resolves the symbol via B2's `SymbolSpec_BuildResolved()`,
  and reads every field from the closed trigger bar
  (`InpTriggerTimeframe`, default M5) backward, never bar 0/`TimeCurrent()`/
  a live tick. `FeatureEngine_CurrentAnchorBarTime()` exposes the same
  anchor `MLQuantAI.mq5`'s `OnTick()` uses for new-bar detection.
- `Market/MLQuantAI_DataHub.mqh`: `g_hADX_M15` handle;
  `DataHub_AsianRangeAt(symbol, asiaEndHour, asOf, ...)` replaces
  `DataHub_AsianRange()` (read `TimeCurrent()` internally).
- `Market/MLQuantAI_SessionEngine.mqh`: `Session_Id(t)` - one label for
  `MarketContext.session_id`.
- `Market/MLQuantAI_NewsEngine.mqh`: `News_BuildSnapshots()`/`_Live`/`_Csv`
  - a full `NewsSnapshot[]` anchored at an explicit `asOf`, replacing a
  live `TimeCurrent()`-anchored bool for context-building purposes.
  `News_HighImpactNear()` stays as a separate live gate-check utility.
- `Market/MLQuantAI_MarketContext.mqh`: `MarketContext_ComputeHash()` and
  `MarketContext_ToJsonFragment()` (the full `MARKET_CONTEXT_READY`
  payload, including the embedded `NewsSnapshot[]`). The frozen struct's
  fields are unchanged.
- `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`: rebuilds the same anchor
  bar 1,000 times and asserts `context_hash` never changes, plus
  payload-completeness and closed-bar-semantics checks.

### Removed
- `Core/MLQuantAI_MarketContext.mqh` (Step 9's `MarketContext` struct) -
  deleted once nothing referenced it after the migration.

## [Unreleased] - Phase B B2: Symbol Resolution

Contract + resolver only - no DataHub/FeatureEngine/MLQuantAI.mq5 wiring
in this pass (that migration is B3's job).

### Added
- `Core/MLQuantAI_ContractVersions.mqh`: `MLQUANTAI_SYMBOL_SPEC_SCHEMA_V1`.
- `Market/MLQuantAI_SymbolSpec.mqh` extended **additively**: canonical
  `instrument_id` vs. resolved `broker_symbol`, `tick_size`, `tick_value`,
  `currency_margin`, `trade_mode`. Every Step 9 field is unchanged - the
  legacy `SymbolSpec_Build()` still behaves exactly as before, since
  `FeatureEngine_Init()` already calls it directly.
- `Market/MLQuantAI_SymbolResolver.mqh`: `SymbolResolver_LooksLikeAlias`
  (prefix-decoration match + a small built-in XAUUSD alias table for
  brokers using unrelated names like "GOLD" + `InpExtraSymbolAliases` for
  anything broker-specific - deliberately NOT a loose substring/contains
  check), `SymbolResolver_Resolve`/`_ResolveWith` (fails closed on an
  unknown or non-matching symbol), and `SymbolSpec_BuildResolved`/
  `_BuildResolvedWith` - the new B2 entry point B3's DataHub and B5's
  detectors should use instead of the legacy `SymbolSpec_Build()`.
- `Tests/MLQuantAI_Test_SymbolResolver.mq5`: alias-matching (prefix,
  built-in, extra, and rejection of loose/wrong matches), override vs.
  auto-detect resolution, fail-closed behavior on an invalid symbol, and
  full `SymbolSpec` snapshot population.

## [Unreleased] - Phase B B1: Contract Freeze

Contracts only - no DataHub/FeatureEngine/CRT/execution code was written
or changed in this pass. See `Docs/PhaseB_B1_ContractFreeze.md`.

### Added
- `Core/MLQuantAI_ContractVersions.mqh`: Phase B schema version constants
  (`MLQUANTAI_MARKET_CONTEXT_SCHEMA_V1`, `MLQUANTAI_FEATURE_SCHEMA_V1`,
  `MLQUANTAI_CANDIDATE_SCHEMA_V1`, `MLQUANTAI_NEWS_SCHEMA_V1`,
  `MLQUANTAI_RISK_SCHEMA_V1`) - separate from Phase A's
  `MLQuantAI_VersionRegistry.mqh`, which stays untouched.
- `Market/MLQuantAI_MarketContext.mqh`: the new, frozen `MarketContext`
  contract - canonical `instrument_id` vs. `broker_symbol`, closed-bar-only
  `anchor_bar_time`, per-timeframe `MqlRates` bars, an embedded
  `NewsSnapshot[]`, and a `context_hash` that deliberately excludes
  runtime-only account state. Coexists with the Step 9
  `Core/MLQuantAI_MarketContext.mqh` (still what the live Data Hub/Feature
  Engine build) until B2/B3 migrates them to this contract.
- `Market/MLQuantAI_NewsSnapshot.mqh`: one calendar event, replayable via
  JSON (`NewsSnapshot_ToJson`/`FromJson`/array round-trip helpers),
  self-contained from Phase A's `EventSerializer` on purpose.
- `Market/MLQuantAI_FeatureSnapshot.mqh`: contract stub for the eventual
  Feature Store row (not wired to anything - B3+).
- `Core/MLQuantAI_RiskDecision.mqh`: audit record for a future Risk
  Manager (B7) to log for every candidate, approved or rejected - keeps
  rejected setups explainable instead of just dropped (no survivorship
  bias). Distinct from the existing `MLQuantAI_RiskPlan.mqh` (Phase A's
  sizing-output struct).
- `Core/MLQuantAI_TradeCandidate.mqh` extended **additively**:
  `candidate_schema_version`, `context_event_id`/`context_hash`
  (candidate <-> context lineage), `side` (`ENUM_ORDER_TYPE`),
  `setup_anchor_bar_time` + `expiry_after_bars` (closed-bar expiry, via
  the new `TradeCandidate_ComputeExpiryTime` helper - never
  `TimeCurrent() + N minutes`), `entry_hint`/`sl_hint`/`tp_hint`,
  `trigger_reason_mask` + `trigger_reasons[]`. Every Phase A field is
  unchanged - Phase A's sealed tests and `MLQuantAI.mq5`'s Step 8.5 smoke
  test still compile against the same struct untouched.
- `Core/MLQuantAI_Ids.mqh`: `Ids_ContextEventId(symbol, timeframeTag,
  barTime)` - deterministic id for one `MarketContext` snapshot, so a
  `TradeCandidate.context_event_id` can reference the exact context it
  was built from.
- `Tests/MLQuantAI_Test_PhaseBContracts.mq5`: struct-shape, closed-bar
  semantics, hash-excludes-runtime-metadata, and NewsSnapshot
  serialize/deserialize round-trip coverage for all of the above.

## [0.1.0] - Phase A

### Added
- Core contracts: `MarketContext`, `TradeCandidate`, `AIResult`,
  `RiskPlan`, `ExecutionResult`, `RuntimeState`, `AccountSnapshot`,
  `ExternalContext` - each carrying its own schema/version field.
- `ENUM_CANDIDATE_STATE` lifecycle state machine
  (`StateMachine_CanTransition`), enforcing the full CREATED/SUBMITTED
  branching tree and rejecting every illegal transition (including the
  explicit "EXECUTED -> CREATED never happens" / "MERGED -> SUBMITTED
  never happens" rules).
- `ENUM_REASON_CODE`, `ENUM_AI_DECISION`, `ENUM_RISK_DECISION`,
  `ENUM_EVENT_TYPE`, `ENUM_EVENT_STORE_HEALTH`.
- Deterministic ID generation (`Ids_RootEventId`, `Ids_CandidateId`,
  `Ids_CorrelationId`) via SHA-256 (`CryptEncode`) over the identifying
  fields - no `MathRand()`/`GetTickCount()` involved, so the same market
  event always hashes to the same IDs on any run. `Ids_NewRuntimeSessionId`
  stays intentionally non-deterministic (identifies one specific run).
- Append-only JSONL Event Store (`EventStore.mqh`): write-before-commit
  ordering (in-memory candidate state only advances after the event is
  confirmed durably written and flushed), `EventStoreValidator`
  (sequence contiguity per session, schema version, truncation
  detection), `EventStoreHealth` (Safe Mode - blocks new candidates only,
  never force-closes positions), `ReplayEngine` + `StateProjector`
  (reconstructs candidate state and `RuntimeState` from the log alone,
  independently re-validating every transition against the state
  machine).
- `MLQuantAI_BrokerReconciliation.mqh`: compares replayed EXECUTED
  candidates against real MT5 position state
  (`PositionsTotal`/`POSITION_COMMENT`).
- `MLQuantAI.mq5`: the first real EA - opens/validates/replays the Event
  Store and runs broker reconciliation in `OnInit`, logs
  `SYSTEM_STARTED`/`SYSTEM_STOPPED` with the full version registry. No
  strategies, no AI, no order logic yet.
- `Tests/`: `MLQuantAI_Test_DummyLifecycle`, `MLQuantAI_Test_ReplayIntegrity`,
  `MLQuantAI_Test_EventStoreRecovery`, `MLQuantAI_Test_BrokerReconciliation`
  (simulated broker state), `MLQuantAI_Test_StateMachine`,
  `MLQuantAI_Test_DeterministicId`.

### Fixed (found via review + real test runs, not just self-review)
- `EventStore_LogTransition`/`LogCandidateCreated` used to mutate
  in-memory candidate state *before* confirming the event write was
  durable - fixed so a failed write leaves the candidate untouched and
  trips Safe Mode instead.
- `ReplayEngine` used to skip every `SystemEvent` line, so
  `RuntimeState.runtime_session_id`/`session_start_time`/`safe_mode` never
  actually got reconstructed by replay - added `StateProjector_ApplySystem`.
- `EventSerializer_GetStr` stopped at the first quote character including
  an *escaped* one inside a value, silently truncating strings like
  `broker said \"invalid stops\"` - rewritten as a char-by-char scan that
  respects escape sequences.
- `schema_version` was declared in `VersionRegistry` but never actually
  written into serialized events - added, and the Validator now flags a
  missing/mismatched version as corruption.
- The three `EventSerializer_Parse*` functions never read the `"ts"`
  field back out of a line, so every replayed event had `ts=0` regardless
  of what was written - caught by `MLQuantAI_Test_ReplayIntegrity`
  actually failing (15/16) on a real run.

### Not built yet
Strategies (CRT/SMC/Trend Pullback/Breakout/Silver Bullet/Mean
Reversion), Regime Router, Candidate Pool/Dedup/Arbitration, Global Risk
Manager, Execution Engine, Trade Manager, real MT5 Data Hub/Feature
Engine/Session Engine/News Engine, XGBoost/ONNX AI Meta-Filter, External
Context data (DXY/US10Y/VIX/News/Sentiment). All Phase B+.
