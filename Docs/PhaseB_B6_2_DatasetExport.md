# Phase B — B6.2: Canonical Dataset Export

**Status: Implemented, awaiting real compile/test confirmation.**
`Tests/MLQuantAI_Test_CandidateDatasetExport.mq5` has been statically
checked (brace/paren balance, 63-char identifier limit) but has not yet
been run through a real MetaEditor compile — no test evidence exists
yet. Do not treat this as PASSED until a real run is confirmed.

Closes 2 of the 2 remaining gates the user named when approving B6.1:
dataset export determinism, and an end-to-end audit path from
`MARKET_CONTEXT_READY` through to a dataset row. Operational
accumulation of "several hundred real setups" remains a separate, later
B8 gate — not part of B6's code/pipeline closure.

## What this commit adds

- **`Infrastructure/EventStore/MLQuantAI_CandidateDatasetExport.mqh`**
  (new): `CandidateDatasetRow`, `CandidateDatasetManifest`,
  `CandidateDatasetExport_BuildDataset` (the entry point), plus the
  join/sort/hash/serialize helpers it's built from.
- **`Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh`**
  (additive): `CandidateProjection_GetAt(index, &out)` — a simple
  bounds-checked accessor added so the export layer can iterate the
  full registry after a rebuild. B6.1's sealed/tested behavior is
  otherwise untouched.
- **`Tests/MLQuantAI_Test_CandidateDatasetExport.mq5`** (new).

## Strictly additive, strictly read-only

`CandidateDatasetExport_BuildDataset` calls
`CandidateProjection_RebuildFromFile` (B6.1's own sealed entry point) to
get the candidate set, then reads the same file's lines a second time
(via `EventStore_ReadAllLines`) purely to build a `context_event_id ->
context fields` join table. No B5 `Strategies/` file is touched, no
CRT detector call happens, no event is appended, no existing durable
line is rewritten. `Test_ReadOnly_NoStoreMutation` proves this
directly: the store's line count and byte content are identical before
and after building and serializing a full dataset export.

## The column gap: resolved by joining, not by reopening B5

B6.1's own doc flagged 9 dataset columns from the kickoff spec that had
no path to population without either reopening sealed B5 code or
inventing new persisted data: `instrument_id`, `trigger_timeframe`,
`news_decision_hash`, `news_snapshot_identity`, `swept_level`,
`mss_confirmation_price`, `resolved_zone_kind`, `resolved_zone_low`,
`resolved_zone_high`. Implementing B6.2 surfaced a 10th:
`strategy_version`.

**4 of the 10 are resolved by joining at export time**, not by touching
B5: `instrument_id`, `trigger_timeframe`, `news_decision_hash`, and
`news_snapshot_identity` are all already durably written into every
`MARKET_CONTEXT_READY` event's JSON body by
`MarketContext_ToJsonFragment` (Phase B/B2-B4, sealed). Every candidate
already carries `context_event_id`, so
`CandidateDatasetExport_CollectContextJoinTable` reads the whole file
once, builds an `context_event_id -> {instrument_id, trigger_timeframe,
news_decision_hash, news_snapshot_identity, symbol_spec_digits}` table,
and `CandidateDatasetExport_BuildRow` joins each candidate against it.
This is pure export-time enrichment of already-persisted data — nothing
about B5's or B6.1's contracts changes.

**6 of the 10 remain genuinely NOT AVAILABLE**, and export as
`null`/empty/zero rather than being silently omitted, fabricated, or
reconstructed by re-running the detector (which would violate B6's own
"everything read-only from the Event Store" rule):

- `swept_level`, `mss_confirmation_price`, `resolved_zone_kind`,
  `resolved_zone_low`, `resolved_zone_high` — these only ever exist on
  `CRTDetectionResult` (B5 Commit 3's output), which is itself never
  written to the Event Store. `CRT_ToTradeCandidate` (Commit 4)
  deliberately narrows the detector's full result down to only what a
  `TradeCandidate` needs to persist (entry/sl/tp hints, reason mask) —
  the raw zone geometry was never meant to survive past detection. No
  join can produce data nothing ever wrote.
- `strategy_version` — `CRT_CandidateCreatedExtraJson` (Commit 5) only
  ever persisted `strategy_id` (a bare int), never a separate rules
  version string. `strategy_id` alone can't be inverted back into
  `"CRT_V1"` the *rules-version* sense (as opposed to
  `strategy_name`, see below) without a lookup table this project has
  never defined, so it's left NOT AVAILABLE rather than guessed.

Every NOT AVAILABLE field is documented at its declaration site in
`CandidateDatasetRow` and exercised directly by
`Test_RowProjection`'s three "is NOT AVAILABLE" assertions, so a future
reader (or a future B5 change that finally does persist one of these)
has an exact, test-enforced list of what to update.

One field was *not* on the original gap list and needed a small
correction during implementation: `strategy_name`. Unlike
`strategy_version`, `strategy_name` **is** derivable — `strategy_id` is
persisted, and `StrategyIdToString(strategy_id)` (`Core/MLQuantAI_Enums.mqh`,
sealed since Phase A) is a pure function of it, not a new dependency on
anything unpersisted. `CandidateDatasetExport_BuildRow` sets
`row.strategy_name = StrategyIdToString(rec.strategy_id)` directly.

## `row_hash` / `dataset_hash`: don't hash the same thing twice

Consistent with the "don't hash something twice" principle this project
has used since B2 (`context_hash` folds news fields into
`news_decision_hash` rather than re-hashing them; `candidate_hash`
excludes pure derivations like `signal_time`/`expiry_time`; Commit 5
never invented a separate `event_hash` since `candidate_hash` +
`log_event_id` already cover that role) — `row_hash` does **not**
re-hash every raw field `candidate_hash` already covers
(`candidate_id`, `root_event_id`, `side`, `context_event_id`,
`context_hash`, `setup_anchor_bar_time`, `expiry_after_bars`,
`entry_hint`/`sl_hint`/`tp_hint`, `trigger_reason_mask`,
`detector_hash`, `candidate_schema_version`). Instead `row_hash`
includes `candidate_hash` itself as one rolled-up value, and adds only
what the export layer itself contributes and `candidate_hash` could
never cover: the joined context provenance
(`instrument_id`/`trigger_timeframe`/`news_decision_hash`/
`news_snapshot_identity`) and the row's own `candidate_state` snapshot.

`dataset_hash` is `Ids_Sha256Hex` over every row's `row_hash`, joined in
final (sorted) export order — so a reorder, insertion, deletion, or any
single-field change anywhere moves the one dataset-level value.
`Test_HashChangesWithContent` proves a tampered joined field moves both
`row_hash` and `dataset_hash`; `Test_DeterministicExport` proves two
builds of the identical store produce identical hashes (and identical
byte-for-byte JSONL text).

## Deterministic ordering

`CandidateDatasetExport_SortRows` orders rows by
`setup_anchor_bar_time` ascending, `candidate_id` ascending as a frozen
tiebreak — independent of emission/insertion order. An insertion sort is
used deliberately: dataset sizes here are "a few hundred setups" at
most (B8's own stated operational gate), not a scale where an O(n²)
sort matters, and insertion sort keeps the ordering logic trivially
auditable. `Test_StableOrdering` emits three candidates in reverse
chronological order and confirms the exported rows come back strictly
ascending by anchor time.

## Manifest: schema/provenance/counts, kept separate from row data

`CandidateDatasetManifest` carries `dataset_schema_version`
(`"DATASET_V1"`), `source_event_store_file`, `source_line_count`,
`row_count`, `rejected_count`, `dataset_hash`, and `export_time`.
`export_time` is populated last, from `TimeCurrent()`, and is
**deliberately excluded from `dataset_hash`** — two exports of the
identical store at different wall-clock moments must produce the
identical `dataset_hash`; only row content determines it. This matches
every other "runtime-only, excluded from the identity hash" precedent
in this project (`context_hash` excludes account state,
`candidate_hash` excludes account/spread/wall-clock).
`Test_DeterministicExport` proves this directly by mutating
`export_time` after the fact and recomputing `dataset_hash` unchanged.

## All-or-nothing export, `rejected_count` always 0 on success — flagged for review

`CandidateDatasetExport_BuildDataset` calls
`CandidateProjection_RebuildFromFile` and returns `false` (with
`rows[]` left empty) if the underlying rebuild's own report is not
`ok` — i.e. if the store is corrupt, out of sequence, or contains even
one orphaned/invalid `CANDIDATE_CREATED` line anywhere. This is the
same all-or-nothing atomicity B6.1's `RebuildFromFile` already
established and the user already approved: **one bad line blocks the
whole export**, never a silently-partial dataset.
`Test_OrphanBlocksWholeExport` proves this directly — a store with one
good candidate and one orphaned candidate produces `ok == false` and
zero rows, not a 1-row dataset quietly excluding the orphan.

A consequence worth flagging explicitly: because `report.ok` is only
ever `true` when `report.lines_failed == 0`, `manifest.rejected_count`
(wired directly from `report.lines_failed`) is **always 0 on any export
that returns `true`**. The field exists and is wired correctly, but
under this design it can never be observed as nonzero — a rejected
export always fails the whole call instead. The B6.2 kickoff spec's own
wording ("rejected/quarantined count") could be read as implying a
different, selective per-row quarantine model (bad rows excluded, good
rows still exported, count reported). That is a materially different
design — it was not built here, to stay consistent with B6.1's already
-approved atomicity contract, but it's called out explicitly rather
than silently assumed, since it's a legitimate design choice the user
may want revisited.

## Test coverage (`MLQuantAI_Test_CandidateDatasetExport.mq5`)

Built on the same real-pipeline pattern B6.1's own hardening suite
established: real `CRT_DetectV1` → `CRT_ToTradeCandidate` →
`CRT_EmitCandidateCreated` calls, plus real `MARKET_CONTEXT_READY`
events via `EventStore_LogSystem`, never fabricated/synthetic rows.

- **`Test_RowProjection`** — every field of a built row checked against
  its source `TradeCandidate`/joined context, including all NOT
  AVAILABLE fields staying empty/zero and the derived `has_*` flags
  matching the fixture's known reason mask.
- **`Test_NoDuplicateCandidateIds`** — 3 distinct candidates, no two
  rows share a `candidate_id`.
- **`Test_StableOrdering`** — candidates emitted out of chronological
  order come back strictly ascending by `setup_anchor_bar_time`.
- **`Test_DeterministicExport`** — two builds of the identical store
  produce byte-identical JSONL text, identical `dataset_hash`, and
  identical per-row `row_hash`; `export_time` mutation doesn't move the
  recomputed hash.
- **`Test_HashChangesWithContent`** — tampering a joined field moves
  both `row_hash` and `dataset_hash`.
- **`Test_OrphanBlocksWholeExport`** — an orphaned candidate blocks the
  entire export (`ok == false`, `rows[]` empty), not a partial export.
- **`Test_ReadOnly_NoStoreMutation`** — the store's line count and
  content are byte-identical before and after building and serializing
  a dataset.
- **`Test_EndToEndLineage`** — the full chain
  `MARKET_CONTEXT_READY` → `CANDIDATE_CREATED` → `CandidateProjection`
  registry → dataset row is traced explicitly: the row's
  `context_hash`/`detector_hash`/`candidate_hash`/`instrument_id`/
  `news_decision_hash` are each checked against the original
  `MarketContext`/`CRTDetectionResult`/`TradeCandidate` values that
  produced them, the row's `candidate_hash` is checked against the
  registry record's own value (no drift between registry and export),
  and the row's `row_hash` is confirmed reproducible from the row's own
  content via a fresh `CandidateDatasetExport_RowHash` call.

## Open items for B6 closure

- Real compile/test confirmation for this commit (none exists yet).
- B6.3 (dataset integrity validator, per the B6.1 approval message) is
  not part of this commit and remains unscoped until B6.2 is confirmed.
- No physical file is written by this layer — `CandidateDatasetExport_RowsToJsonLines`
  and `CandidateDatasetManifest_ToJson` return strings; a caller that
  wants a `.jsonl`/manifest file on disk writes it itself via
  `FileWriteString`, matching this project's existing "builders return
  strings, callers own I/O" split.
