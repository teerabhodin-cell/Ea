# Phase B8.2 — Commit 3: Outcome/Label Boundary (FROZEN)

**Status: FROZEN, before any code exists.** Opens after B8.2 Commit 2
PASSED (105/105) and merged. Title: **RealizedOutcome — the only
sanctioned way a training row's label can move, without ever touching
candidate-time AI input.**

```
Candidate-time (immutable once persisted)
    MarketContext -> TradeCandidate -> FeatureSnapshot -> RiskPlan
                                            |
                                   AI / training input
                                            |
                                  ---- FUTURE BOUNDARY ----
                                            |
                                    RealizedOutcome
                                    (candidate_id + candidate_hash,
                                     outcome_time > setup_anchor_bar_time)
                                            |
                                   TrainingDatasetRow.label*
```

The one-sentence goal, verbatim from the proposal that opened this
commit: **future outcome evidence may enrich the training label, but
it can never alter the immutable candidate-time AI input or its
provenance.**

## Scope decisions confirmed before freezing (see below for why each matters)

1. **Synthetic fixtures only.** `ExecutionResult`/`ExecutionEvent`
   (`Core/MLQuantAI_ExecutionResult.mqh`,
   `Infrastructure/EventStore/MLQuantAI_ExecutionEvent.mqh`) are
   confirmed, by direct inspection, to still be Phase A dormant
   placeholders — nothing produces them live, since B9/C (the
   Execution Engine) don't exist yet. `RealizedOutcome` is therefore
   built and tested the same way every other B8.2 fixture already is:
   from data constructed directly in the test file, not from a live
   broker or backtest run. Wiring `RealizedOutcome` to a real
   Execution Engine is out of scope until B9/C exist.
2. **`candidate_time` = `setup_anchor_bar_time`.** The only real,
   persisted time anchor available anywhere in the B8.2 lineage —
   `FeatureSnapshot` deliberately carries no time field of its own
   (B8.1), `RiskPlan` carries none either, and this is already what
   Commit 2's own row ordering uses.
3. **`EVENT_TYPE_TRADE_OUTCOME_LABELED` is reused, not re-minted.**
   Confirmed still present and still dormant (`Core/MLQuantAI_Enums.mqh`,
   appended in the original Phase A "execution/position" block,
   comment: "schema locked now, nothing produces these until Phase B's
   Execution Engine exists"). This is the slot it was scaffolded for.
4. **`MLQUANTAI_LABEL_SCHEMA_B8_2_V1` stays the only label schema
   constant in play.** The dormant Phase A `MLQUANTAI_LABEL_SCHEMA_VERSION
   = "TBM_V1"` (`Core/MLQuantAI_VersionRegistry.mqh`, still referenced
   by that file's own session-manifest JSON fragment) is not reused —
   same precedent B8.1 already set for `MLQUANTAI_FEATURE_SCHEMA_V1`.
5. **`BuildTrainingDatasetRow` (Commit 1, sealed) is not reopened.**
   Its signature already takes `label`/`outcomeReference`/`outcomeHash`
   as plain strings, and its own step 4 unconditionally stamps
   `outRow.label_schema_version = MLQUANTAI_LABEL_SCHEMA_B8_2_V1` —
   it does not accept a caller-supplied label schema version at all.
   Consequence, made binding below: `RealizedOutcome_Build` (this
   commit) rejects any `labelSchemaVersion` other than
   `MLQUANTAI_LABEL_SCHEMA_B8_2_V1`. If a future label methodology
   needs its own schema version, `BuildTrainingDatasetRow`'s signature
   is the thing that has to change then — not something this commit
   should route around now.

## Part 0 — incomplete-cohort semantics, made normative (Commit 2 addendum)

No behavior changes; this section only documents, as a binding table,
the skip-vs-fail-closed policy Commit 2 already implements, and adds
two manifest counters so it's visible in the manifest instead of only
inferable from logs.

| Candidate state | Export outcome |
|---|---|
| Has FeatureSnapshot + an ALLOWED RiskPlan | Row built |
| Missing FeatureSnapshot and/or ALLOWED RiskPlan | Skipped; `incomplete_count++` |
| A referenced artifact fails hash/lineage/schema validation | Fail-closed (whole export) |
| Identity collision (same id, different hash) | Fail-closed (whole export) |
| Malformed/truncated event store line | Fail-closed (whole export) |

`TrainingDatasetManifest` gets two additive fields (same "extend a
sealed struct additively" precedent as `labeled_count` itself):

```
int candidate_count;    // every CandidateProjection record considered, before any skip/build decision
int incomplete_count;   // candidates skipped for missing FeatureSnapshot/ALLOWED RiskPlan - candidate_count - row_count - (any future skip reason)
```

`rejected_count`/`first_rejection_reason` are deliberately **not**
added: under the current fail-closed design, any genuine rejection
(hash/lineage/schema failure, collision, malformed line) always aborts
the *entire* export before any manifest is populated — there is no
partial-rejection state a successful manifest could ever report a
nonzero count for. Adding permanently-dead fields that always read
`0`/`""` would misleadingly imply a per-row rejection tolerance this
design deliberately does not have. If a future commit ever changes
fail-closed to a per-row policy, that's the point to add them — not
now.

`TrainingDatasetExport_BuildDataset` (Commit 2) is extended to
populate `candidate_count` (== `CandidateProjection_Count()` at
iteration time) and `incomplete_count` (incremented on each of the two
existing `continue` skip paths). No other line of that function's
control flow changes.

## Part 1 — `RealizedOutcome`

### Collision check

`grep -rn "RealizedOutcome"` across `Include/`/`Tests/`/`Docs/`: zero
matches. No struct, no event, no dormant placeholder under this name.
Clean.

### `RealizedOutcome` struct

```cpp
struct RealizedOutcome
{
   string   realized_outcome_schema_version; // MLQUANTAI_REALIZED_OUTCOME_SCHEMA_B8_2_V1

   string   realized_outcome_id;   // identity
   string   candidate_id;
   string   candidate_hash;

   string   label_schema_version;  // MUST equal MLQUANTAI_LABEL_SCHEMA_B8_2_V1 - see scope decision 5
   string   label;                 // opaque string, methodology is a later commit's concern
   string   outcome_reference;     // external evidence pointer (ticket id / backtest run id / fixture id)
   string   outcome_hash;          // content hash of that external evidence, supplied not computed here
   datetime outcome_time;          // MUST be > the candidate's setup_anchor_bar_time

   string   realized_outcome_hash; // full-record hash, computed last
};
```

Deliberately **no** two-hash split the way `FeatureSnapshot` needed
one. `FeatureSnapshot` needed a lineage-free `feature_vector_hash`
because the same feature *content* can legitimately recur across
different candidates (a dedup/model-input concern). `RealizedOutcome`
has no such use case — it is inherently 1:1 with one candidate's
outcome, so a single full-record hash (`realized_outcome_hash`, same
role as `RiskPlan.plan_hash`) is sufficient.

### Identity

```cpp
string Ids_RealizedOutcomeId(string candidateId, string labelSchemaVersion)
{
   string key = candidateId + "|" + labelSchemaVersion;
   return Ids_Deterministic("OUT", key);
}
```

Same identity philosophy as `Ids_RiskPlanId`/`Ids_FeatureSnapshotId`:
identity depends on **what this is an outcome of** (candidate +
schema), never on the outcome's own computed content (`label`,
`outcome_reference`, `outcome_hash`, `outcome_time`). This is what
makes "same identity, different hash" a genuine collision/drift signal
on replay, rather than an expected, ordinary state — exactly the
property Commit 3's own leakage/collision tests below depend on.

### `RealizedOutcome_Build` — validation ladder (fail-closed, mirrors `TrainingDatasetBuilder_ValidateInput`'s shape)

```cpp
bool RealizedOutcome_Build(const TradeCandidate &candidate, string label, string outcomeReference,
                             string outcomeHash, datetime outcomeTime, string labelSchemaVersion,
                             RealizedOutcome &outOutcome)
```

Rejected (return `false`, `outOutcome` left at `Init()` defaults) if
any of:

- `candidate.candidate_id == ""`
- `candidate.state != CANDIDATE_CREATED`
- `label == ""`, `outcomeReference == ""`, or `outcomeHash == ""` —
  unlike `TrainingDatasetRow`, `RealizedOutcome` has no "unlabeled"
  state of its own. "Unlabeled" is represented by the **absence** of a
  `RealizedOutcome` for a candidate at export time, not by a
  `RealizedOutcome` with empty fields. A `RealizedOutcome` that exists
  at all is, by construction, always fully labeled.
- `labelSchemaVersion != MLQUANTAI_LABEL_SCHEMA_B8_2_V1` — see scope
  decision 5.
- `outcomeTime <= candidate.setup_anchor_bar_time` — the temporal
  boundary. Strictly after, not "on or after": a fabricated outcome
  timestamped at the exact candidate-time instant is exactly as
  suspect as one before it.

On success: `realized_outcome_id` computed first (from
`candidate_id`+`labelSchemaVersion` only), all fields copied verbatim,
`realized_outcome_hash` computed last over the finished struct — same
"identity/content-hash-last" order every prior B8 builder already
uses.

### Event emission + projection

`EVENT_TYPE_TRADE_OUTCOME_LABELED` (reused, not re-minted — scope
decision 3) via `RealizedOutcome_EmitTradeOutcomeLabeled(outcome)`,
mirroring `FeatureSnapshot_EmitFeatureSnapshotCreated` exactly:

- Guard: `outcome.realized_outcome_id == ""` -> `false`, no write.
- Live-session duplicate guard via `RealizedOutcomeProjection_TryGet`
  (coarse, same as `RiskPlan`/`FeatureSnapshot`'s own emitters).
- Durable write via `EventStore_LogSystem`, then live-sync into
  `RealizedOutcomeProjection` via `..._ApplyLiveRecord`.

`RealizedOutcomeProjection` (new file, same folder,
`Infrastructure/EventStore/`) mirrors `FeatureSnapshotProjection`
field-for-field in structure:

- Required-field + `outcome_time` sanity validation.
- Duplicate-vs-collision on `realized_outcome_id` +
  `realized_outcome_hash`.
- Referential integrity on replay: `candidate_id` must exist in
  `CandidateProjection` (rebuilt from the same file first, same
  dependency direction every prior projection already has), and
  `candidate_hash` must match.
- `EventStoreValidator`-gated atomic rebuild — registry left untouched
  on any failure.

### The leakage-protection invariant (the actual point of this commit)

> Adding or changing future outcome evidence may change the training
> row's label/content hash, but MUST NEVER change the candidate-time
> feature vector or its hash.

This holds **structurally**, not by a runtime check, and Commit 3
must add nothing that could weaken it:

- `Candidate_ToFeatureSnapshot` (B8.1, sealed) has no `RealizedOutcome`
  parameter and never will — reopening its signature is out of scope
  for every remaining B8 commit, not just this one.
- `FeatureSnapshot_HashPayload`/`FeatureSnapshot_VectorHashPayload`
  (B8.1, sealed) reference no field this commit adds.
- `FeatureSnapshotProjection`/`TrainingDatasetExport_BuildDataset`'s
  own feature-snapshot lookup path (Commit 2) is untouched by this
  commit — `RealizedOutcomeProjection` is looked up independently, in
  parallel, never merged into or read by the feature-snapshot lookup.

Verified by inspection (structural test, same class as every prior
B8.2 commit's own exclusion proof), not by a runtime assertion — there
is no runtime path by which a `RealizedOutcome` value could reach
`Candidate_ToFeatureSnapshot` or its hashes to begin with.

### Split stability invariant

`TrainingDatasetSplit_Assign(candidate.candidate_id, splitPolicyVersion)`
(Commit 1, sealed) is not modified, and its call site inside
`BuildTrainingDatasetRow` (Commit 1, sealed, step 6) is not touched.
Split depends only on `candidate_id` + `split_policy_version` — never
on `label`, `label_available`, or anything `RealizedOutcome`-derived.
Consequence: the same candidate's row lands in the same split whether
exported before or after its `RealizedOutcome` exists. This is true by
construction (Commit 3 adds no new call into
`TrainingDatasetSplit_Assign` and reads no label data before calling
`BuildTrainingDatasetRow`), and is proven directly by a regression test
(below) rather than only asserted.

### Export integration (`TrainingDatasetExport_BuildDataset`, Commit 2 — extended, not reopened at the signature level)

For each candidate that already qualifies for a row (has a
`FeatureSnapshot` + an ALLOWED `RiskPlan`, per Commit 2's own logic,
unchanged): additionally look up a `RealizedOutcomeProjection` record
for the same `candidate_id`.

- Found: `BuildTrainingDatasetRow(candidate, snapshot, plan, true, rec.label, rec.outcome_reference, rec.outcome_hash, modelTarget, row)`.
- Not found: unchanged from Commit 2 —
  `BuildTrainingDatasetRow(candidate, snapshot, plan, false, "", "", "", modelTarget, row)`.

No referential re-verification of the `RealizedOutcome` record's own
`candidate_hash` at this call site — same trust-boundary rule Commit 2
already established for `FeatureSnapshotProjection`/`RiskPlanProjection`
records: a record that successfully survived `RealizedOutcomeProjection`'s
own rebuild-time referential-integrity check is trusted here, not
re-checked.

`manifest.labeled_count`/`unlabeled_count` become real (tallied from
each row's `label_available`), replacing Commit 2's hardcoded
`labeled_count=0`/`unlabeled_count=row_count`.

Mixed-cohort rejection (Commit 2, unchanged) is **not** extended to
`label_schema_version` — every `RealizedOutcome` accepted by
`RealizedOutcome_Build` already carries the one allowed
`MLQUANTAI_LABEL_SCHEMA_B8_2_V1` value (scope decision 5), so no
per-row divergence is possible to check for.

## QA gate for Commit 3 (binding on its test suite)

**Part 0** (manifest normativity): `candidate_count`/`incomplete_count`
correctly tallied against a store with a known mix of
complete/incomplete candidates; `candidate_count == row_count +
incomplete_count` holds on every export.

**Part 1**, the 7 groups from the proposal that opened this commit,
each restated as a binding gate:

1. **Outcome identity/determinism** — repeated `RealizedOutcome_Build`
   calls, same inputs, identical `realized_outcome_id`/
   `realized_outcome_hash` every time.
2. **Temporal boundary** — `outcome_time > setup_anchor_bar_time`
   accepted; `outcome_time == setup_anchor_bar_time` rejected;
   `outcome_time < setup_anchor_bar_time` rejected.
3. **Referential integrity** — candidate_id/candidate_hash mismatch on
   replay rejected; orphan `candidate_id` rejected; missing
   `outcome_reference`/`outcome_hash`/`label` rejected at build time.
4. **Duplicate/collision** — same identity + same hash on replay is a
   no-op; same identity + different hash is a collision, rebuild
   fails entirely; multi-session/restart replay is byte-identical.
5. **Leakage protection** — structural inspection proof (per the
   invariant above): `Candidate_ToFeatureSnapshot`'s call signature
   and `FeatureSnapshot_HashPayload`/`_VectorHashPayload`'s referenced
   fields are unchanged from B8.1; `feature_snapshot_hash`/
   `feature_vector_hash` for a fixed candidate are identical whether
   or not a `RealizedOutcome` exists for it.
6. **Dataset integration** — an unlabeled row still exports
   successfully (Commit 2 behavior, unaffected); a labeled row gets
   real `label`/`outcome_reference`/`outcome_hash`/`label_available=true`;
   `row_hash` moves when the label legitimately changes (a new
   `RealizedOutcome` under a re-run); `dataset_hash` moves accordingly;
   `manifest.labeled_count`/`unlabeled_count` are correct and sum to
   `row_count`.
7. **Split stability** — the same candidate's `split` is identical
   whether its row is built unlabeled (no `RealizedOutcome` yet) or
   labeled (a `RealizedOutcome` now exists) — direct regression test,
   not just structural reasoning.

## Explicitly out of scope for Commit 3

Any real broker/backtest producer of `RealizedOutcome` (stays out of
scope until B9/C exist); any label *methodology* decision (what "WIN"/
"LOSS"/a numeric target actually means, e.g. Triple Barrier Method or
otherwise — `label` stays an opaque string here, same as Commit 1);
any change to `TrainingDatasetRow`'s own identity/hash/split semantics
(frozen in Commit 1); any change to `Candidate_ToFeatureSnapshot`,
`Candidate_ToRiskPlan`, or `BuildTrainingDatasetRow`'s signatures
(sealed); any model/ONNX/training-loop code; full replay/export
regression across the whole B8.2 arc (that is Commit 4's job, the
actual sealing commit).
