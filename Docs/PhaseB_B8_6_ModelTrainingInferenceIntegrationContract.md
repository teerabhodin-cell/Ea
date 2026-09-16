# B8.6 model training & inference integration design contract (RA-63, documentation only)

**Status**: **FROZEN / APPROVED for Components A/B/C. Component D
(§6) ARCHITECTURALLY DEFERRED**, per QA's post-implementation-discovery
ruling: `MLQuantAI.mq5`'s real `OnTick` has no live candidate path to wire
ONNX inference into - every step from `CRT_DetectV1` through
`AIDecision_Build` is gated behind the pre-existing, deliberate
`MQLInfoInteger(MQL_TESTER)` check (the C5.0 Strategy-Tester-only fixture).
Building a live path is the separately-gated future C5 environment-ladder
phase, never authorized by RA-63. §6's text is retained as design intent
for that future checkpoint, not as executable scope for B8.6. Components
A/B/C's implementation is authorized and proceeding; Component D's is not.
No `MQL_TESTER` gate lift, no live candidate-generation activation, is
authorized by this contract. Separate authorization is still required for
training run / model promotion / live inference / commit / push, none of
which are granted by this design freeze alone. Document retained below in
its revision-3 form as the historical design record; text below is read as
frozen wherever it says so, EXCEPT §6, which is design-intent-only per this
notice.

Revision history (kept for audit — earlier revision text below is otherwise
unchanged):
QA's second "CONDITIONAL APPROVAL" with 2 remaining must-fix points plus one
still-undecided item; all three addressed this revision:
(1) §8 reworded to match the Class 1/Class 2 sealed-file boundary already
declared in the Status header/§2, instead of contradicting it;
(2) a new §3.0 freezes EXPORT POPULATION vs. TRAINING-ELIGIBLE POPULATION as
two distinct, never-conflated terms, and every population-sensitive field
(§5.3's `row_count`, §5.4's `dataset_id` input list, §5.5's `dataset_hash`
input rows) is now explicit that it means the training-eligible population
only, per QA's own directive;
(3) §5.6's dataset-collision outcome now carries a reasoned PROPOSED
resolution (rejected/failed export, never Safe Mode) rather than being left
fully open - still pending QA's explicit confirmation.
No `.mqh`/`.mq5` file, no test file, no `MLQuantAI.mq5` wiring, no compile,
no test run, no training run, no model deployment, no live inference, no
`OrderSend`, no commit, no push. Implementation remains its own, separately
authorized future step (B8.6 Commit 1+), per QA's explicit boundary: *"ยังไม่
ควรแตะ source implementation จนกว่าจะส่ง contract ฉบับเต็มให้ QA ตรวจอีกครั้ง"*.
This revision is submitted for QA's final design freeze; it is not itself a
freeze.

**Sealed-file boundary (corrected — QA's point 1, option A adopted)**: two
distinct classes, never conflated:

```
Class 1 - UNTOUCHED, byte-for-byte, not even an additive change:
  MLQuantAI_ModelArtifact.mqh, MLQuantAI_ModelArtifactBuilder.mqh,
  MLQuantAI_ModelArtifactEventEmission.mqh, MLQuantAI_ModelArtifactProjection.mqh,
  MLQuantAI_AIDecisionContract.mqh, MLQuantAI_AIDecisionBuilder.mqh,
  MLQuantAI_AIDecisionEventEmission.mqh, MLQuantAI_AIDecisionProjection.mqh,
  MLQuantAI_InferenceContract.mqh, MLQuantAI_ModelRuntimeAdapter.mqh,
  MLQuantAI_TrainingDatasetBuilder.mqh's existing BuildTrainingDatasetRow logic,
  MLQuantAI_TrainingDatasetExport.mqh's existing orchestration logic.

Class 2 - ADDITIVE AMENDMENT EXPLICITLY AUTHORIZED BY THIS CONTRACT:
  every field, function, and behavior these files already have is UNCHANGED
  in meaning, shape, and semantics - B8.6 only ever ADDS a new field or a
  new function alongside what already exists, never edits/removes/
  reinterprets an existing one:
    - MLQuantAI_RealizedOutcomeProjection.mqh: + new read accessor
      RealizedOutcomeProjection_TryGetByCandidateId() (§3.2), alongside its
      existing realized_outcome_id-keyed lookup, unchanged.
    - MLQuantAI_TrainingDatasetRow.mqh: + new field
      label_source_realized_outcome_id (§3.3) on the TrainingDatasetRow
      struct; every existing field's meaning is unchanged.
    - Core/MLQuantAI_Enums.mqh: + new EVENT_TYPE_TRAINING_DATASET_CREATED
      value (§5.2), appended at the end per this project's append-only
      enum discipline - no existing value renumbered or reinterpreted.

No file outside these two explicit lists may be touched by any future B8.6
implementation commit without its own separate authorization.

**Baseline**: `mlquantai@febc506` (RA-62 Slice 1+2, RA-65 Slice 1+2 sealed and
deployed).

**Predecessor contracts, unchanged and reused, not superseded**:
`Docs/PhaseB_B8_1_FeatureSnapshotContract.md`,
`Docs/PhaseB_B8_2_TrainingDatasetContract.md`,
`Docs/PhaseB_B8_3_ModelRegistryContract.md`,
`Docs/PhaseB_B8_4_InferenceContract.md`,
`Docs/PhaseB_B8_4_Commit2_RuntimeAdapter.md`,
`Docs/PhaseB_B8_5_AIDecisionContract.md`. Where this document is silent, those
govern.

**QA's three frozen decisions this contract implements** (verbatim dispositions,
not re-litigated here):

```
1. Label eligibility:      ALL THREE RealizedOutcome classes (TP_HIT/SL_HIT/
                            TIMEOUT) are eligible training labels. TIMEOUT is
                            not excluded - it is RA-62's own frozen, meaningful
                            third class, not bad data.
2. Split methodology:      ADD SPLIT_CHRONOLOGICAL_V1 as a new, separate,
                            versioned policy. SPLIT_70_15_15_V1 is NEVER
                            reinterpreted or modified - it remains legacy/frozen,
                            untouched.
3. Dataset lineage gap:    CLOSE IT. Add a durable TRAINING_DATASET_CREATED
                            identity/provenance event, additive to the existing
                            B8.2/B8.3 contracts - never a redefinition of their
                            sealed meaning.
```

---

## 1. Purpose and non-goals

Purpose: close the four concrete gaps RA-63's grounding research found between
already-sealed B8.1-B8.5 infrastructure and an actually-functioning training/
inference loop:

```
1. RealizedOutcome (RA-62) -> TrainingDatasetRow.label: no automatic join exists.
2. TrainingDatasetSplit_Assign: hash-only, no chronological option exists.
3. ModelArtifact.training_dataset_id/training_dataset_hash: caller-declared,
   zero referential integrity against any durable event.
4. MLQuantAI_ModelRuntimeAdapter.mqh (the real ONNX adapter): built, sealed,
   correct - and called from nowhere outside its own test file.
```

Non-goals for this contract's scope (design only; B8.6 Commit 1+ implementation
is separately authorized in the future):

```
- no training run of any kind (offline, this system does not run Python/ML
  training - "training" here means the deterministic MQL5-side dataset
  materialization and export only; the actual model-fitting step happens
  OUTSIDE this repository, exactly as B8.2/B8.3's own frozen design already
  assumes - a model is REGISTERED via ModelArtifact_Build with externally
  computed model_artifact_hash, never trained in-process)
- no model deployment / promotion workflow change (ModelArtifact_
  CheckCompatibility's PROMOTED-only gate is reused verbatim, unchanged)
- no live inference execution, no OrderSend, no candidate-lifecycle
  transition, no SafeMode change
- no change to B5 (CRT detection)/B7 (RiskPlan/sizing) - AI remains gate-only,
  exactly as already structurally enforced by AIDecision's own field shape
  (no entry/sl/tp/lot/risk_amount field exists on AIDecision at all)
```

---

## 2. Scope guard (frozen)

```
Docs only. This commit changes exactly one file:
  - Docs/PhaseB_B8_6_ModelTrainingInferenceIntegrationContract.md (this file, new)
No new .mqh/.mq5 file. No test file. No MLQuantAI.mq5 wiring. No edit to any
Class 1 (fully untouched) file listed in the Status header above. No
OrderSend/CTrade/History*/live Position* API anywhere. No candidate-lifecycle
transition, no event append, no new struct/enum value actually ADDED TO
SOURCE CODE by this document - every struct/enum shape below (including the
Class 2 additive amendments) is a frozen SPEC for the future implementation
commit(s), not code shipped by this one. The Class 2 list itself (which
files may later receive an additive amendment, and exactly what that
amendment is) IS frozen by this document - only the actual code change is
deferred to B8.6 Commit 1+.
```

---

## 3. Component A — RealizedOutcome -> TrainingDatasetRow auto-join

### 3.0 Population terminology (frozen — QA's point 2, new this revision)

```
Two distinct populations, never conflated by name or by field:

EXPORT POPULATION
  = every TrainingDatasetRow the existing, sealed BuildTrainingDatasetRow
    path already produces for a given export run - includes rows with
    label_available == false. This population, and whatever B8.2's own
    existing export file/mechanism already does with it, is UNCHANGED by
    B8.6 - it is a pre-existing artifact class this contract does not
    rename, redefine, or take ownership of.

TRAINING-ELIGIBLE POPULATION
  = the strict subset of the export population where label_available ==
    true AND label is one of TP_HIT/SL_HIT/TIMEOUT (§3.1). This is the
    ONLY population TRAINING_DATASET_CREATED (§5), its dataset_id (§5.4),
    and its dataset_hash (§5.5) ever describe. row_count on
    TrainingDatasetManifestRecord (§5.3) means the size of THIS population
    only - every row it counts has label_available == true by definition,
    so no separate "labeled vs total" distinction is needed inside that
    event (the removed labeled_row_count field from revision 1 is
    superseded by this section - see §5.3's updated shape).

TRAINING_DATASET_CREATED never references, counts, or hashes an unlabeled
(export-population-only) row. If a future need arises to give the broader
export population its own durable identity, that is explicitly a SEPARATE,
NOT-YET-AUTHORIZED artifact class (a "candidate export artifact"), never
retroactively folded into TRAINING_DATASET_CREATED or into
ModelArtifact.training_dataset_id/training_dataset_hash.
```

### 3.1 Eligibility (frozen, per QA decision 1)

```
A RealizedOutcome record is ELIGIBLE for training-dataset inclusion iff:
  - it exists (durably, in RealizedOutcomeProjection) for a given candidate_id
  - its label is one of the three RA-62-frozen classes: TP_HIT, SL_HIT, TIMEOUT
    (same_bar_tiebreak_applied TP_HIT/SL_HIT records ARE eligible - the
    tiebreak flag is provenance metadata, never a disqualifier)
  - label_schema_version == MLQUANTAI_LABEL_SCHEMA_B8_2_V1 (the same sealed
    constant RealizedOutcomeBuilder_ValidateInput already requires - no new
    schema-version gate invented here)

A candidate_id with NO RealizedOutcome record yet is simply NOT eligible
(label_available = false on its TrainingDatasetRow, per B8.2's own existing
field) - never an error, never excluded from the candidate population for any
other reason, never fabricated.
```

### 3.2 Join mechanism (frozen, offline/export-time - never live)

```
Ownership: a NEW, read-only join step inside the training-dataset EXPORT path
(MLQuantAI_TrainingDatasetExport.mqh's existing orchestration, Commit 2) - NOT
a live OnTick concern, matching B8.2's own existing "dataset export is an
offline batch operation" design.

For each candidate_id already staged as a TrainingDatasetRow (via the existing,
unmodified BuildTrainingDatasetRow path):
  1. Look up RealizedOutcomeProjection by candidate_id (a NEW read accessor,
     RealizedOutcomeProjection_TryGetByCandidateId() - additive to the sealed
     RealizedOutcomeProjection.mqh, alongside its existing realized_outcome_id-
     keyed lookup, never replacing it).
  2. If found and eligible (3.1): set row.label = the RealizedOutcome's label,
     row.label_available = true, row.label_source_realized_outcome_id = the
     RealizedOutcome's own id (NEW field, pure provenance, on
     TrainingDatasetRow - additive, see 3.3).
  3. If not found: row.label_available = false, row.label left at its
     existing default - unchanged from B8.2's current behavior.

Multiplicity: RA-62's OWN sealed idempotency guarantee (RealizedOutcome_
EmitTradeOutcomeLabeled rejects re-emission once a realized_outcome_id already
exists, and realized_outcome_id is deterministically candidate_id + label_
schema_version) already ensures at most ONE eligible RealizedOutcome per
(candidate_id, label_schema_version) pair. This join step performs NO new
ambiguity handling of its own - it inherits RA-62's uniqueness guarantee
structurally, the same "reuse, never reinvent an already-sealed guarantee"
discipline this project used throughout RA-62/RA-65.
```

### 3.3 TrainingDatasetRow additive field (frozen SPEC, not yet implemented)

```cpp
// planned additive field on the existing, sealed TrainingDatasetRow struct -
// NOT a modification of any existing field's meaning
string label_source_realized_outcome_id; // "" when label_available == false
```

---

## 4. Component B — `SPLIT_CHRONOLOGICAL_V1`

### 4.1 Relationship to the legacy policy (frozen, per QA decision 2)

```
SPLIT_70_15_15_V1 (MLQUANTAI_DATASET_SPLIT_POLICY_V1): UNCHANGED, UNTOUCHED,
remains a valid, selectable, legacy split_policy_version value forever.
TrainingDatasetSplit_Assign() (the existing per-row hash function) is NEVER
edited.

SPLIT_CHRONOLOGICAL_V1 (new constant, e.g.
MLQUANTAI_DATASET_SPLIT_POLICY_CHRONOLOGICAL_V1 = "SPLIT_CHRONOLOGICAL_V1"):
a NEW, additive split policy. Selected the same way split_policy_version is
already selected today (a caller-supplied parameter to the export step) -
no default changes, no existing caller silently switches policy.
```

### 4.2 Algorithm (frozen SPEC)

```
Architecturally different from TrainingDatasetSplit_Assign() by necessity:
the existing function is a PURE, per-row, context-free hash of one
candidate_id - it can decide a row's split without seeing any other row.
Chronological assignment is NOT context-free: a row's split depends on where
its own setup_anchor_bar_time ranks among the WHOLE eligible population. This
is therefore a NEW function operating over the full eligible row set at once,
never a per-row drop-in replacement:

  ENUM_DATASET_SPLIT[] TrainingDatasetSplit_AssignChronological(
      const TrainingDatasetRow &eligibleRows[])

Algorithm:
  1. Sort eligible rows by setup_anchor_bar_time ASCENDING.
  2. Tie-break (frozen): equal setup_anchor_bar_time sorts by candidate_id
     ASCENDING (string comparison) - deterministic, never input-array-order-
     dependent, matching this project's existing tie-break discipline (e.g.
     C3.8.1's own submitted_sequence_number-then-candidate_id ordering rule).
  3. Partition the SORTED list by INDEX POSITION, not by a value threshold:
       first  70% (by count, rounded per 4.3) -> TRAIN       (oldest)
       next   15% (by count, rounded per 4.3) -> VALIDATION  (middle)
       last   15% (by count, rounded per 4.3) -> TEST        (newest)
  4. Output preserves the ORIGINAL (unsorted) row identity - the sort in step
     1 is an internal working order only, never a reordering of the emitted
     dataset rows themselves.

This guarantees TRAIN is always strictly earlier in time than VALIDATION,
which is always strictly earlier than TEST (up to the tie-break rule at
exact-boundary timestamps) - the temporal-leakage property SPLIT_70_15_15_V1
does not have and was never designed to have.
```

### 4.3 Rounding rule (frozen SPEC - must be pinned before implementation)

```
row_count is not guaranteed divisible by 20 (for a clean 70/15/15). Frozen
rule: train_count = floor(row_count * 0.70); validation_count =
floor(row_count * 0.15); test_count = row_count - train_count -
validation_count (the remainder absorbs all rounding, always assigned to
TEST - the newest, most "production-representative" slice, never to TRAIN,
which would silently inflate the training population's share run over run).
Deterministic for a fixed row_count - no random tie-break, no floating
mid-point ambiguity.
```

### 4.4 Small-population degenerate case (frozen SPEC)

```
If row_count < 20 (or any count produces validation_count == 0 or
test_count == 0), the export function MUST NOT silently proceed with an
empty split. It reports a structured, non-fatal finding (e.g.
DATASET_SPLIT_POPULATION_TOO_SMALL) in its own report struct and still emits
the split (empty groups are a valid, honestly-reported outcome) - never
fabricates rows, never blocks the whole export over an otherwise-valid
population size. Matches this project's established "report the honest
degenerate case, never silently mask it" discipline (e.g. C3.8 §6's unknown-
age handling).
```

---

## 5. Component C — durable training-dataset identity (`TRAINING_DATASET_CREATED`)

### 5.1 Purpose (frozen, per QA decision 3)

```
Closes B8.3's own admitted gap: ModelArtifact.training_dataset_id/
training_dataset_hash are today caller-declared strings with ZERO referential
integrity against anything durable. This component gives dataset
materialization a real, durable, replayable identity - additive lineage
evidence, never a redefinition of ModelArtifact's or TrainingDatasetRow's
existing sealed field meanings.
```

### 5.2 New event type (frozen SPEC)

```cpp
// planned addition to ENUM_EVENT_TYPE - appended at the end, per this
// project's append-only enum discipline (never inserted earlier, never
// renumbering an existing value)
EVENT_TYPE_TRAINING_DATASET_CREATED
```

### 5.3 Schema (frozen SPEC)

```cpp
// planned extra_json fields for a TRAINING_DATASET_CREATED SystemEvent line -
// same convention every other derived-artifact event already uses
struct TrainingDatasetManifestRecord   // durable identity/provenance record
{
   string   training_dataset_schema_version; // MLQUANTAI_TRAINING_DATASET_MANIFEST_SCHEMA_V1
   string   dataset_id;         // deterministic identity, see 5.4
   string   dataset_hash;       // hash of the exact exported artifact, split assignment included, see 5.5
   string   split_policy_version;    // "SPLIT_70_15_15_V1" | "SPLIT_CHRONOLOGICAL_V1" | future
   string   label_schema_version;    // MLQUANTAI_LABEL_SCHEMA_B8_2_V1 (RA-62, unchanged)
   string   model_target;            // same field this project's ModelArtifact already carries
   int      row_count;               // size of the TRAINING-ELIGIBLE population ONLY (§3.0) -
                                      // every counted row has label_available == true by
                                      // definition; the export population's total size (including
                                      // unlabeled rows) is NOT carried on this record at all
   datetime export_server_time;      // TimeCurrent() at export, server-time discipline (C3.8 §5 precedent)
};
```

### 5.4 `dataset_id` determinism (frozen SPEC)

```
dataset_id = Ids_<NewFunction>(sorted candidate_id list, split_policy_version,
                                 label_schema_version, model_target)

Frozen: the identity input is the exact SORTED (ascending, string comparison)
list of every candidate_id in the TRAINING-ELIGIBLE POPULATION ONLY (§3.0 -
never the broader export population, never an unlabeled row's candidate_id),
concatenated deterministically (e.g. joined with a fixed separator, matching
this project's existing Ids_* concatenation conventions) plus the three
versioning fields above. This guarantees: re-running the SAME export over an
unchanged event store with the SAME policy parameters always reproduces the
SAME dataset_id (idempotent, matching every other Ids_* function in this
codebase) - a genuinely different training-eligible population or a
different policy version always produces a genuinely different id.
```

### 5.5 `dataset_hash` (frozen SPEC — CORRECTED, QA's point 2, option B adopted)

```
dataset_hash is the hash of the EXACT EXPORTED DATASET ARTIFACT, not merely
of the underlying candidate population. It INCLUDES each row's assigned
split (DATASET_SPLIT_TRAIN/VALIDATION/TEST) as part of what is hashed - the
same underlying candidate rows exported under SPLIT_70_15_15_V1 vs
SPLIT_CHRONOLOGICAL_V1 MUST produce two DIFFERENT dataset_hash values, because
they are two different training artifacts (a model trained against one
split assignment is not interchangeable with a model trained against the
other, even if every row's feature/label content is identical). This is
consistent with, not redundant with, dataset_id already including
split_policy_version (§5.4) - dataset_id identifies WHICH artifact this is
by its declared parameters; dataset_hash independently PROVES what that
artifact's actual exported content was, split assignment included, the same
"declared identity vs. proven content" separation this project's other
identity/hash pairs already use (e.g. execution_request_id vs.
execution_request_hash).

dataset_hash = SHA-256 over the canonical serialization of every row in the
TRAINING-ELIGIBLE POPULATION ONLY (§3.0 - never an unlabeled export-
population row) (feature/label fields AND its assigned split field, all
included), in a fixed, deterministic ROW order: candidate_id ascending.
Row ORDER for hashing purposes is fixed regardless of split policy (never
grouped-by-split, never file-write order) so the hash computation itself
stays deterministic and independent of incidental export-implementation
choices - only each row's CONTENT (including its now-included split value)
determines the hash, never the order rows happen to be produced in. Same
"canonical, order-independent-of-irrelevant-factors" discipline this
project already applies to every other content hash (e.g. candidate_hash,
execution_request_hash).
```

### 5.6 Emission ownership and idempotency (FROZEN — final QA verdict)

QA confirmed the proposed resolution below verbatim: collision = rejected/
failed export, never Safe Mode.

```
Owner: the SAME export step that already builds the TrainingDatasetManifest
in memory (MLQuantAI_TrainingDatasetExport.mqh, Commit 2) - a new, additive
emission call at the end of a successful export, never a separate process.

Idempotency: BEFORE emitting, the export step MUST check whether a
TRAINING_DATASET_CREATED record with the same dataset_id already exists
(scan durable lines, or a future read accessor over a projection of this
event type - implementation detail, not frozen here). Same three-way outcome
class RA-62 already established for RealizedOutcome:
  - no existing record            -> emit, durable write failure -> SafeMode_Trip
                                      (this event append follows the LIFECYCLE-
                                      event SafeMode precedent - a training-
                                      lineage record failing to persist is a
                                      genuine integrity gap, not a soft-fail)
  - existing record, same dataset_hash    -> idempotent no-op (dataset_id
                                              already proves the SAME content
                                              was already recorded)
  - existing record, DIFFERENT dataset_hash -> collision - the same
                                                 training-eligible-population+
                                                 policy identity somehow
                                                 produced different row content
                                                 across two exports (e.g. the
                                                 event store gained/lost lines
                                                 between runs) - reported as a
                                                 structured error, NEVER
                                                 silently overwritten.

PROPOSED RESOLUTION: a REJECTED/FAILED EXPORT OUTCOME, NOT a Safe Mode trip.
Reasoning:
  1. This export step is an offline/operator-triggered tool-level operation,
     architecturally separate from the live EA's own trading-safety loop -
     unlike POSITION_CLOSED (RA-65), which observes a LIVE OnTradeTransaction
     fact mid-session, this runs on-demand, not on the live candidate path.
  2. Safe Mode's own established purpose throughout this codebase
     (BrokerReconciliation, RA-65) is specifically "block NEW CANDIDATES
     because live broker/event-store integrity is in doubt." A training-
     dataset export collision says nothing about whether it is currently
     safe to manage live positions or open new ones - tripping Safe Mode for
     it would be a disproportionate blast radius (halting live trading) for
     a fault confined to an unrelated tooling subsystem.
  3. The export step already has a natural place to report a structured,
     non-fatal-to-the-EA failure - the same report-struct pattern §4.4
     already uses for the small-population degenerate case.
  4. The durable-write-failure branch above (no existing record, append
     itself fails) DOES still trip Safe Mode - that case is a genuine
     append-durability fact indistinguishable in class from any other
     LIFECYCLE-event write failure this codebase already treats that way.
     Only the COLLISION branch (a logical content inconsistency, not a
     write failure) is reclassified here.
```

### 5.7 `ModelArtifact` lineage cross-check (frozen SPEC — additive, read-only)

```
ModelArtifact.mqh, ModelArtifactBuilder.mqh, and ModelArtifact_
CheckCompatibility() are NOT edited by this component - their sealed
behavior, hash computation, and compatibility-gate logic are reused byte-
for-byte unchanged.

Instead: a NEW, separate, read-only diagnostic function (same "pure
composition over already-sealed sources" pattern C3.8 established for
BrokerReconciliation/TransactionMatching/DeferredTransactionProcessor):

  bool ModelArtifactLineage_Verify(const ModelArtifact &artifact,
                                     out ENUM_LINEAGE_VERIFY_RESULT)

Looks up a TRAINING_DATASET_CREATED record (5.3) by dataset_id ==
artifact.training_dataset_id, and if found, compares dataset_hash ==
artifact.training_dataset_hash. Three outcomes (LINEAGE_VERIFIED /
LINEAGE_NO_RECORD / LINEAGE_HASH_MISMATCH) - read-only, no write, no
Safe Mode, no candidate-lifecycle authority. This is a DIAGNOSTIC an
operator or a future promotion-gate consumer can run before promoting a
model to PROMOTED - it is NOT wired into ModelArtifact_CheckCompatibility's
existing PROMOTED-only runtime gate by this contract (that would be
touching a sealed file, requiring its own separate authorization if ever
proposed).
```

---

## 6. Component D — ONNX live inference wiring (ARCHITECTURALLY DEFERRED — NOT IMPLEMENTED IN B8.6)

**QA final scope decision, post-implementation discovery**: during B8.6
Commit 1 implementation, direct source inspection of `MLQuantAI.mq5`'s real
`OnTick` found that NO live candidate path exists to wire into. Every step
from `CRT_DetectV1` through `AIDecision_Build` through `ExecutionRequest`
lives entirely inside a block gated by `if(!MQLInfoInteger(MQL_TESTER))
return;` (line ~1440) - the C5.0 Strategy-Tester-only fixture, an existing,
predating, deliberate design freeze ("per the C5.0 design freeze which
bounded broker reachability, not durability"). This section's own §6.1 text
below (unchanged, kept as the historical design record) assumed a real live
path existed to wire into - it does not, and creating one is explicitly the
separately-gated **C5 environment-ladder** phase (TEST FIXTURE → DEMO
DRY-RUN → DEMO REAL-SUBMIT → ...), never authorized by RA-63/B8.6 or any
earlier checkpoint in this project.

QA's ruling: Component D is **architecturally deferred**, not a B8.6
failure - it is a dependency boundary onto the future, separately-authorized
C5 checkpoint. Neither of the two paths considered (wiring ONNX into the
still-tester-gated C5.0 block, or building a live candidate path as part of
B8.6) is authorized - the former would silently redefine what the C5.0
fixture is for without closing the live-wiring gap Component D actually
named; the latter would smuggle C5's own authorization into RA-63, breaking
this project's phase sequencing. The text below (§6.1-§6.5) remains the
frozen DESIGN INTENT for whenever C5 authorizes a real live candidate path -
it is not executable now, and no code implementing it is authorized by this
contract. `EVENT_TYPE_TRAINING_DATASET_CREATED`'s Class 2 authorization and
Components A/B/C are entirely unaffected by this deferral.

### 6.1 Ownership and call site (design intent only — not executable, see §6's deferral notice above)

```
NEW code only - MLQuantAI_ModelRuntimeAdapter.mqh (the real, sealed ONNX
adapter) is called, never edited. A new, thin orchestration file (e.g.
MLQuantAI_LiveInferenceOrchestrator.mqh, exact name TBD at implementation
time) owns the call sequence below. Call site: the REAL OnTick path, at the
point a FeatureSnapshot already exists for a candidate awaiting an AI
decision (i.e. after B8.1's existing FeatureSnapshot construction, before
B9's existing eligibility/execution path) - NEVER the C5.0 Strategy-Tester-
only fixture block (MLQuantAI.mq5's own MQL_TESTER-gated section), which
stays exactly as-is, untouched, for its own existing fixture purpose.
```

### 6.2 Model resolution (design intent only — not executable, see §6's deferral notice above)

```
The live EA needs to know WHICH model_id/model_version is "the" active
model for real decisions. Two new EA inputs (e.g. InpActiveModelId,
InpActiveModelVersion, exact names TBD at Commit 1), resolved once at
OnInit via ModelArtifactProjection's existing read accessors, gated through
the ALREADY-SEALED ModelArtifact_CheckCompatibility() (which already
requires promotion_state == MODEL_PROMOTION_PROMOTED and schema/runtime
exact-match, unchanged). No new selection/ranking logic is invented - this
reuses the sealed gate exactly, it only decides WHEN to call it (OnInit,
once, not per-tick).

FROZEN (QA's final verdict): OnInit failing to resolve a compatible,
promoted model (none configured, or the configured one fails
ModelArtifact_CheckCompatibility) BLOCKS THE WHOLE EA FROM STARTING -
init failure, not a degraded-but-running session. No fallback state where
"the EA runs but the AI gate is disabled and candidates proceed without an
AI decision" is permitted - that would be an implicit AI-bypass path,
contradicting B8.6's own frozen boundary that AI is a gate BEFORE B9's
eligibility path and every candidate-without-a-decision case is fail-
closed, never fail-open.
```

### 6.3 Session handle lifecycle (design intent only — not executable, see §6's deferral notice above)

```
ModelRuntimeAdapter_LoadAndVerify() is called ONCE per EA session (OnInit,
after model resolution succeeds) - never per-tick, never per-candidate.
The returned ONNX session handle is held in a single EA-lifetime variable
and reused across every ModelRuntimeAdapter_ValidateContractAndRun() call.
Released (OnnxRelease, already inside the sealed adapter's own error paths
for run-time failures) explicitly in OnDeinit, and on any detected need to
swap models (out of scope for v1 - single fixed model per session only).
```

### 6.4 Per-candidate call sequence (design intent only — not executable, see §6's deferral notice above)

```
FeatureSnapshot (existing, B8.1, unchanged)
   -> build InferenceRequest (existing InferenceContract.mqh shape, unchanged)
   -> ModelRuntimeAdapter_ValidateContractAndRun (existing, sealed, unchanged)
   -> build InferenceResult (existing shape, unchanged)
   -> AIDecision_Build (existing, sealed, pure, unchanged)
   -> AIDecision_EmitAIDecisionCreated (existing, sealed, unchanged)

The new orchestration file's own job is ONLY to sequence these five already-
sealed steps for a REAL FeatureSnapshot instead of a fixture, plus the
one genuinely new decision below (6.5).
```

### 6.5 Inference-failure gating policy (design intent only — not executable, see §6's deferral notice above)

```
CORRECTION: revision 1 conflated "the adapter/build layer technically
failed" with "AIDecision_Build produced a decision other than ALLOW" under
one label ("effective REJECT"). These are NOT the same thing and must never
be merged into one bucket - a persisted REJECT or ABSTAIN is a real,
meaningful, audit-relevant AI decision; a technical failure is the ABSENCE
of any decision at all. Collapsing them would make a future ABSTAIN
(frozen-reachable in the enum, even though no code path produces it today)
indistinguishable from an ONNX crash in the durable record - destroying
exactly the information replay/audit exists to preserve.

Two frozen, mutually exclusive classes:

CLASS 1 - TECHNICAL/BUILD FAILURE (no AIDecision exists at all):
  ONNX adapter failure (session invalid, shape/dtype mismatch, OnnxRun
  failure) OR AIDecision_Build itself declining to produce ANY AIDecision
  (per B8.5's own frozen fail-closed rule: a failed inference reaching
  AIDecision_Build produces no AIDecision, full stop - this is unchanged,
  reused verbatim from B8.5).
    -> NO AIDecision is built or emitted - nothing is persisted for this
       candidate this cycle.
    -> this candidate does NOT proceed past the AI gate this cycle (fail-
       closed, never fail-open, since there is no decision to consume).
    -> Safe Mode is NEVER tripped for this - a per-candidate inference-
       layer technical failure is a data/model-runtime fact, not a durable
       event-store integrity violation (same class of reasoning RA-65's
       Addendum already applied to unresolved/ambiguous provenance:
       "cannot prove X" is not itself a fault).
    -> the candidate's own CRT/state-machine lifecycle is UNCHANGED by
       this - whatever state a candidate without an AI decision sits in
       today (per B9's existing eligibility contract) is exactly what it
       sits in when AI inference is wired in but technically fails; B8.6
       does not change B9's own frozen state semantics.

CLASS 2 - A VALID, PERSISTED AIDECISION with decision_outcome == REJECT or
ABSTAIN (ALLOW is the third possible value, not a failure case at all):
    -> AIDecision_Build ran successfully and AIDecision_
       EmitAIDecisionCreated durably persisted the real decision_outcome
       AS-IS - REJECT stays REJECT, ABSTAIN stays ABSTAIN in the durable
       record, forever. Neither is silently relabeled, upgraded, or
       downgraded to look like the other or like a technical failure.
    -> the eligibility layer (B9, unchanged by this contract) consumes the
       ACTUAL persisted decision_outcome value under its own existing
       rules - this document does not invent or change what B9 does with
       a REJECT vs. an ABSTAIN, it only guarantees the real value reaches
       B9 unaltered.
    -> Safe Mode is never touched by either outcome - both are ordinary,
       expected, valid decision results.
```

---

## 7. Preserved boundaries (restated, unchanged, not reopened by this contract)

```
AI = inference / gate decision only (ALLOW/REJECT/ABSTAIN). AI never owns
     entry, SL/TP, lot sizing, or risk_amount - AIDecision's own struct
     shape has no such field, structurally enforcing this; B8.6 adds no
     field to AIDecision.

Replay = persisted-only. AIDecision_EmitAIDecisionCreated durably records a
     live decision exactly once; AIDecisionProjection/ReplayEngine restore
     it from the durable event on every rebuild. The new live-inference
     orchestration (Component D) is authorized to run ONLY from the real
     OnTick live-decision path - NEVER from OnInit/ReplayEngine/any restart-
     time code path. A future model/runtime change can change what a NEW
     decision would be; it can never change what an ALREADY-PERSISTED
     decision WAS.

B5/B7 untouched. CRT detection and RiskPlan/sizing remain fully
     deterministic, unchanged by this contract in any way.
```

---

## 8. Explicitly NOT authorized by this contract

```
No .mqh/.mq5 implementation file, no test file, no MLQuantAI.mq5 edit, no
    compile, no test run - all remain separate, future B8.6 Commit 1+ steps,
    each requiring its own explicit authorization.
No edit to any Class 1 file (the "UNTOUCHED, byte-for-byte" list in the
    Status header's sealed-file boundary). Class 2 additive amendments (also
    listed in the Status header) are explicitly authorized BY THIS CONTRACT
    as a frozen spec for a future implementation commit - but this document
    itself still adds no code: the actual edits to
    MLQuantAI_RealizedOutcomeProjection.mqh / MLQuantAI_TrainingDatasetRow.mqh
    / Core/MLQuantAI_Enums.mqh remain B8.6 Commit 1+ work. No existing
    Class 2 field/function meaning or behavior may ever be modified, only
    new ones added alongside them.
No new ENUM_EVENT_TYPE value actually added to Core/MLQuantAI_Enums.mqh BY
    THIS DOCUMENT - EVENT_TYPE_TRAINING_DATASET_CREATED is a frozen SPEC name,
    with its future addition pre-authorized under Class 2 above, but not
    added to source by this docs-only commit.
No training run, no model file, no model_artifact_hash computation, no
    ModelArtifact promotion.
No live inference execution, no OrderSend/CTrade, no candidate-lifecycle
    transition, no Safe Mode change.
No commit, no push.
```

---

## 9. Implementation-time naming (not architecturally load-bearing; §5.6/§6.2 both now fully frozen above)

```
1. Exact new-file name(s) and exact new Ids_* function name/input order for
   dataset_id (5.4) - implementation-time detail, not architecturally
   load-bearing, left open deliberately per this project's own precedent
   (e.g. C4.1's overlap-minutes constant was similarly left to its own
   implementation-authorizing addendum). QA authorized deciding these at
   B8.6 Commit 1 - the exact name may vary, the frozen semantics may not.
2. Exact EA input names for model resolution (§6.2) - same authorization.
```
