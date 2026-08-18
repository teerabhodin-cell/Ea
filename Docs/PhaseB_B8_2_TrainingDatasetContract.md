# Phase B8.2 — Training Dataset Contract: Commit 1 (FROZEN)

**Status: FROZEN, before any code exists.** Written per this project's
standing "freeze before code" discipline. B8.2 opens after B8.1
PASSED (66/66) and merged. Scoped to Commit 1 only, per the agreed
4-commit roadmap:

```
B8.2 Commit 1  DatasetRow + Manifest schema/identity/hash/split contract  <- this document
B8.2 Commit 2  Deterministic projection/export from persisted artifacts only
B8.2 Commit 3  Label/outcome boundary + leakage and split tests
B8.2 Commit 4  Replay/export regression + seal
```

Commit 1 covers: the `TrainingDatasetRow`/`TrainingDatasetManifest`
struct shapes, `dataset_row_id` identity, `row_hash`/`dataset_hash`
content integrity, the deterministic split policy, and
`BuildTrainingDatasetRow` — a pure function building one row from
already-persisted-shape inputs (`TradeCandidate`, `FeatureSnapshot`,
`RiskPlan`, plus optional label/outcome references). **No event
store rebuild/export orchestration yet** — that's Commit 2, mirroring
how B7 Commit 1 froze `RiskContext`/`RiskPlan`/`Candidate_ToRiskPlan`
before B7 Commit 2 added `RISK_PLAN_CREATED` emission/replay.

## Collision check (same discipline that caught `RiskPlan`/`FeatureSnapshot`)

Three things were checked in the repo before writing this contract:

1. **`Infrastructure/EventStore/MLQuantAI_CandidateDatasetExport.mqh`**
   (B6.2, sealed, 75/75 PASSED) already has `CandidateDatasetRow`/
   `CandidateDatasetManifest`. Read in full — no collision. B6.2's row
   is a candidate+context provenance/analysis export (no
   `FeatureSnapshot`, no `RiskPlan`, no label, no split, no
   `model_target`). `TrainingDatasetRow`/`TrainingDatasetManifest` are
   a genuinely different concept (a supervised-training artifact) and
   get their own, separately-named structs — not an extension of
   B6.2's.
2. **`EVENT_TYPE_TRADE_OUTCOME_LABELED`** already exists in
   `Core/MLQuantAI_Enums.mqh` as a Phase A enum placeholder — never
   wired to any struct or emission function. Flagged for whichever
   later commit first emits an event for `RealizedOutcome`/label data
   (B8.2 Commit 3 at the earliest, more likely B8.5) — that commit
   should reuse this enum value, not invent a new one. Not used by
   Commit 1, which has no event emission at all.
3. **`MLQUANTAI_LABEL_SCHEMA_VERSION` = `"TBM_V1"`** already exists in
   `Core/MLQuantAI_VersionRegistry.mqh` (Phase A's session-manifest
   constant list, listed in `SYSTEM_STARTED`'s `extraJson`) — a
   placeholder, never backed by any real struct, same dormant-stub
   status `MLQUANTAI_FEATURE_SCHEMA_V1` had before B8.1. Its name
   ("TBM" = Triple Barrier Method) lines up suggestively with the
   `RealizedOutcome` fields already sketched for a later commit
   (`realized_r_multiple`, `mae`, `mfe`, `close_reason` are textbook
   Triple-Barrier-Method labeling outputs) — but Commit 1 does not
   decide this. Per the same precedent B8.1 already established
   (mint a new, phase-specific constant rather than reuse a dormant
   Phase A one, so model-registry compatibility questions stay
   unambiguous), Commit 1 mints its own
   `MLQUANTAI_LABEL_SCHEMA_B8_2_V1`. Whether the real label semantics
   frozen in Commit 3 end up actually BEING Triple Barrier Method
   (making `TBM_V1` the fitting eventual name) is a decision for
   Commit 3, not this one.

## New version constants (additive, `Core/MLQuantAI_ContractVersions.mqh`)

```cpp
#define MLQUANTAI_DATASET_SCHEMA_B8_2_V1   "TRAINING_DATASET_B8_2_V1"
#define MLQUANTAI_LABEL_SCHEMA_B8_2_V1     "LABEL_B8_2_V1"
#define MLQUANTAI_DATASET_SPLIT_POLICY_V1  "SPLIT_70_15_15_V1"
```

## 1. `TrainingDatasetRow` — struct

```cpp
enum ENUM_DATASET_SPLIT
{
   DATASET_SPLIT_TRAIN,
   DATASET_SPLIT_VALIDATION,
   DATASET_SPLIT_TEST
};

struct TrainingDatasetRow
{
   string dataset_schema_version;

   string dataset_row_id;    // identity - section 2

   string candidate_id;
   string candidate_hash;

   string feature_snapshot_id;
   string feature_snapshot_hash;
   string feature_vector_hash;
   string feature_schema_version;

   string risk_plan_id;
   string plan_hash;
   string sizing_rules_version;

   bool   label_available;
   string label_schema_version;
   string label;              // "" when label_available == false
   string outcome_reference;  // "" when label_available == false
   string outcome_hash;       // "" when label_available == false

   ENUM_DATASET_SPLIT split;
   string split_policy_version;
   string model_target;

   string row_hash;    // content integrity - section 3
};
```

No `feature_values` copied onto the row directly (no `atr_m15` etc.)
— a training row references the feature vector by
`feature_snapshot_id`/`feature_vector_hash`, it does not duplicate the
feature values themselves. Whoever actually builds a training matrix
(a later commit / an external tool) joins rows against the persisted
`FeatureSnapshot` registry by `feature_snapshot_id` — same
join-not-duplicate principle B6.2 already established for
`CandidateDatasetRow` joining against `MARKET_CONTEXT_READY`.

`RiskPlan`'s sizing OUTPUTS (`lot_size`, `risk_amount`, `planned_entry`/
`sl`/`tp`) are deliberately NOT copied onto the row either — only
`risk_plan_id`/`plan_hash`/`sizing_rules_version` (provenance
references). Per the agreed reasoning: the model is a setup-quality
meta-filter, not a position-sizing model, and account-dependent
sizing outputs should not leak into what it's trained on by default.
If a future commit decides a specific sizing field genuinely belongs
in the feature vector, that's an explicit `feature_schema_version`
bump on `FeatureSnapshot` itself (B8.1's own contract), not a side
door through the training row.

## 2. Identity: `dataset_row_id`

```cpp
string Ids_TrainingDatasetRowId(string featureSnapshotId, string labelSchemaVersion, string modelTarget)
{
   string key = featureSnapshotId + "|" + labelSchemaVersion + "|" + modelTarget;
   return Ids_Deterministic("TDROW", key);
}
```

Depends on `feature_snapshot_id` (not `candidate_id` directly — a
`FeatureSnapshot` already has 1:1 identity with its candidate, so this
is equivalent but keeps the dependency chain explicit), plus
`label_schema_version` and `model_target` — the same underlying setup
can legitimately produce more than one training row if labeled under
a different schema version or targeting a different `model_target`
later, and each such row needs its own identity.

`Core/MLQuantAI_Ids.mqh` gets this function added (additive), next to
`Ids_FeatureSnapshotId`.

## 3. Content integrity: `row_hash` and `dataset_hash`

```cpp
string TrainingDatasetRow_HashPayload(const TrainingDatasetRow &row)
{
   string s = "";
   s += row.candidate_id + "|";
   s += row.candidate_hash + "|";
   s += row.feature_snapshot_id + "|";
   s += row.feature_snapshot_hash + "|";
   s += row.feature_vector_hash + "|";
   s += row.feature_schema_version + "|";
   s += row.risk_plan_id + "|";
   s += row.plan_hash + "|";
   s += row.sizing_rules_version + "|";
   s += (row.label_available ? "1" : "0") + "|";
   s += row.label_schema_version + "|";
   s += row.label + "|";
   s += row.outcome_reference + "|";
   s += row.outcome_hash + "|";
   s += DatasetSplitToString(row.split) + "|";
   s += row.split_policy_version + "|";
   s += row.model_target;
   return s;
}

string TrainingDatasetRow_ComputeHash(const TrainingDatasetRow &row)
{
   return Ids_Sha256Hex(TrainingDatasetRow_HashPayload(row));
}
```

**INCLUDED**: every lineage reference, every label/outcome field
(including `label_available` and the split), `model_target`. Per the
agreed rule, `row_hash` covers input references, label references,
split, target, and schema versions together — this is a "full
record" hash in the same sense B8.1's `feature_snapshot_hash` is, not
a narrow content-only hash. `TrainingDatasetRow` has no equivalent
need for a B8.1-style content/lineage split, since the row itself IS
the lineage-plus-label record — there is no separate "pure content"
concept to isolate the way a feature vector's raw numeric values were
worth isolating from their candidate lineage.

**EXCLUDED**: `dataset_row_id` (identity — derivable from
`feature_snapshot_id`/`label_schema_version`/`model_target`, already
present separately in the payload via those inputs, so including the
identity string itself would be pure redundancy with no new
information, unlike B8.1's deliberate inclusion of
`feature_snapshot_id` alongside `candidate_id` — there,
`feature_snapshot_id` depended on nothing else in that payload;
here, `dataset_row_id` depends on three fields already individually
present), `dataset_schema_version` (struct-shape marker, same
exclusion precedent every other schema-version field gets).

```cpp
string TrainingDatasetManifest_DatasetHash(const TrainingDatasetRow &rows[])
{
   string payload = "";
   for(int i = 0; i < ArraySize(rows); i++)
   {
      if(i > 0) payload += "|";
      payload += rows[i].row_hash;
   }
   return Ids_Sha256Hex(payload);
}
```

Same style B6.2's `CandidateDatasetExport_DatasetHash` already
established: `Ids_Sha256Hex` over every row's `row_hash`, joined in
final (sorted) order — a reordering, insertion, deletion, or single-
field change anywhere moves this one value. Canonical row order for
Commit 1: `dataset_row_id` ascending (a simple, sufficient stable
tiebreak — `TrainingDatasetRow` carries no anchor-bar-time field of
its own the way `CandidateDatasetRow` does, so B6.2's
time-then-candidate_id order isn't available here without adding a
field purely for sorting, which nothing else needs).

## 4. Split policy: deterministic, hash-derived, versioned

```cpp
// MLQUANTAI_DATASET_SPLIT_POLICY_V1 defined above, in ContractVersions.mqh

ENUM_DATASET_SPLIT TrainingDatasetSplit_Assign(string candidateId, string splitPolicyVersion)
{
   string h = Ids_Sha256Hex(candidateId + "|" + splitPolicyVersion);
   ulong bucket = DatasetSplit_HexToUlong(StringSubstr(h, 0, 8)) % 100; // 0..99
   if(bucket < 70) return DATASET_SPLIT_TRAIN;
   if(bucket < 85) return DATASET_SPLIT_VALIDATION;
   return DATASET_SPLIT_TEST;
}
```

Split is keyed on `candidate_id`, not `dataset_row_id` — a deliberate
choice: if the same underlying setup ever produces more than one
training row (different `label_schema_version` or `model_target`
later), all of them land in the same split. Splitting by the
row-level identity instead could put the same setup in `TRAIN` under
one labeling scheme and `TEST` under another, which isn't a leakage
risk in the strict sense but is a needless, avoidable inconsistency
this design closes off for free by keying on the more stable, upstream
identity.

70/15/15 is a plain default, not derived from anything — versioned via
`MLQUANTAI_DATASET_SPLIT_POLICY_V1` specifically so changing the ratio
later is a new constant, never a silent edit of what `V1` means (same
rule every other frozen constant in this project follows). `DatasetSplit_HexToUlong`
is a small local hex-decode helper (8 hex chars -> a `ulong` in
`[0, 2^32-1]`) — MQL5's `StringToInteger` is not relied on for hex
parsing, since its hex-prefix support isn't something this project
wants to depend on implicitly.

## 5. `BuildTrainingDatasetRow` — the pure builder function

```cpp
bool BuildTrainingDatasetRow(const TradeCandidate &candidate, const FeatureSnapshot &snapshot, const RiskPlan &plan,
                              bool labelAvailable, string label, string outcomeReference, string outcomeHash,
                              string modelTarget, TrainingDatasetRow &outRow)
```

Frozen algorithm:

1. **Fail-closed input validation.** Reject (return `false`, leave
   `outRow` at `TrainingDatasetRow_Init()` defaults) if any of:
   `candidate.candidate_id == ""`; `candidate.state != CANDIDATE_CREATED`;
   `snapshot.candidate_id != candidate.candidate_id` or
   `snapshot.candidate_hash != candidate.candidate_hash` (the
   `FeatureSnapshot` passed in must actually be this candidate's own);
   `!plan.allowed` or `plan.candidate_id != candidate.candidate_id` or
   `plan.candidate_hash != candidate.candidate_hash` (only an ALLOWED
   `RiskPlan` for this exact candidate is eligible — a candidate that
   never got a valid plan has no training row at all, per "every row
   traces to candidate, feature snapshot, risk plan, and outcome
   reference"); `modelTarget == ""`; `labelAvailable == false` but any
   of `label`/`outcomeReference`/`outcomeHash` is non-empty (an
   inconsistent input is rejected outright, never silently cleared);
   `labelAvailable == true` but `label == ""` or `outcomeReference == ""`
   or `outcomeHash == ""` (a claimed-available label must actually
   carry all three).
2. Copy lineage references verbatim: `candidate_id`/`candidate_hash`
   from `candidate`; `feature_snapshot_id`/`feature_snapshot_hash`/
   `feature_vector_hash`/`feature_schema_version` from `snapshot`;
   `risk_plan_id`/`plan_hash`/`sizing_rules_version` from `plan`. No
   recomputation anywhere.
3. Copy `label_available`/`label`/`outcome_reference`/`outcome_hash`
   verbatim from the caller's inputs (already validated in step 1).
4. Set `label_schema_version = MLQUANTAI_LABEL_SCHEMA_B8_2_V1`,
   `dataset_schema_version = MLQUANTAI_DATASET_SCHEMA_B8_2_V1`,
   `split_policy_version = MLQUANTAI_DATASET_SPLIT_POLICY_V1`,
   `model_target = modelTarget`.
5. Compute `dataset_row_id = Ids_TrainingDatasetRowId(snapshot.feature_snapshot_id, label_schema_version, model_target)`.
6. Compute `split = TrainingDatasetSplit_Assign(candidate.candidate_id, split_policy_version)`.
7. Compute `row_hash` LAST, over the finished struct — same
   "hash the finished object" convention every other hash in this
   project follows.
8. Return `true`. No event append, no broker/order/history call, no
   mutation of `candidate`/`snapshot`/`plan` (all passed `const &`).

## 6. `TrainingDatasetManifest` — struct

```cpp
struct TrainingDatasetManifest
{
   string dataset_schema_version;
   string dataset_id;
   string dataset_hash;
   string feature_schema_version;
   string label_schema_version;
   string split_policy_version;
   string model_target;
   int    row_count;
   int    train_count;
   int    validation_count;
   int    test_count;
   int    unlabeled_count;
   string source_store_fingerprint; // NOT populated by Commit 1 - see below
};
```

`source_store_fingerprint` is part of the frozen shape now (so Commit
2's export orchestration doesn't need a struct change to add it later)
but Commit 1 has no event store to fingerprint — building a
`TrainingDatasetManifest` from a set of already-built
`TrainingDatasetRow`s (for QA-gate purposes) leaves it empty. Commit
2 is responsible for actually populating it once real export-from-store
exists — this mirrors B7 Commit 1 freezing `RiskPlan`'s full shape
before `RISK_PLAN_CREATED` emission existed to fill in
`source_sequence_number`-equivalent provenance.

## 7. Leakage boundary (binding on every later B8.2 commit, restated here)

- `RealizedOutcome`/label data must never enter `FeatureSnapshot`,
  `feature_vector_hash`, or any inference-path input — restated from
  the agreed proposal, already structurally impossible for
  `Candidate_ToFeatureSnapshot` (B8.1, sealed) to violate, since that
  function has no label/outcome parameter at all.
  `BuildTrainingDatasetRow` keeps them in entirely separate fields
  from the feature-lineage fields, never blended into one hash
  payload that could be mistaken for a feature vector.
- `label_available == false` is a valid, first-class lifecycle state,
  not an error — an unlabeled row still has full provenance and can
  be exported for inference-time audit datasets, just never included
  in a supervised-training split. (Which export path — full vs.
  training-only — filters on `label_available` is Commit 2's concern;
  Commit 1 only needs to represent the state correctly.)
- Split assignment never depends on time-of-export or any random
  source — same `candidate_id` + same `split_policy_version` always
  produces the same split, on any run, on any machine.

## 8. QA gate for B8.2 Commit 1 (binding on its test suite)

- Same inputs -> identical `dataset_row_id`, `row_hash`, and `split`,
  called repeatedly (10,000 iterations, mirroring B7/B8.1's own
  determinism loops) -> zero mismatches.
- `dataset_row_id` depends only on `feature_snapshot_id`/
  `label_schema_version`/`model_target` — changing any one alone
  changes it; changing anything else (e.g. `label` content, `split`)
  does not.
- `row_hash` inclusion sweep: every included field, changed alone,
  moves the hash.
- `row_hash` exclusion whitelist: `dataset_row_id` and
  `dataset_schema_version` changed alone do NOT move the hash.
- Referential integrity: a `FeatureSnapshot` or `RiskPlan` whose
  `candidate_id`/`candidate_hash` doesn't match the candidate's own is
  rejected; an unallowed (`!plan.allowed`) `RiskPlan` is rejected.
- Fail-closed: empty `candidate_id`, wrong `state`, empty
  `model_target`, an inconsistent `labelAvailable`/label-fields
  combination (both directions) are all rejected, with `outRow` left
  at `Init()` defaults.
- Split determinism: same `candidate_id` always produces the same
  split across repeated calls and across different
  `label_schema_version`/`model_target` combinations for the same
  candidate; split distribution over a large synthetic sample of
  distinct `candidate_id`s lands close to 70/15/15 (a statistical
  sanity check, not an exact-count assertion).
- `dataset_hash` over a small set of rows changes if any one row's
  `row_hash` changes, or if row order changes, and is stable across
  repeated computation from the same row set.
- `candidate`/`snapshot`/`plan` parameters byte-identical before and
  after the call (no mutation).
- No event store line appended, no broker/order/history/tick call
  anywhere in the call path.
- No future/outcome leakage into feature-only paths: structural check
  (verified by inspection, same class as B8.1's own) that
  `Candidate_ToFeatureSnapshot` has no label/outcome parameter and
  that `FeatureSnapshot_HashPayload`/`FeatureSnapshot_VectorHashPayload`
  reference no field this file adds.

## Explicitly out of scope for B8.2 Commit 1

Event store export/rebuild orchestration (Commit 2), any real label/
outcome computation from a backtest or broker fixture (Commit 3), any
leakage/split statistical test suite beyond Commit 1's own sanity
check (Commit 3), replay/regression sealing (Commit 4), any
`AI_DECISION_CREATED` or `TRADE_OUTCOME_LABELED` event emission, any
change to an already-sealed B5/B6/B7/B8.1 production file.
