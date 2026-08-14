# Phase B — B4: News Parity Layer

**Status: CONDITIONAL PASS — not yet SEALED.** `MLQuantAI_Test_NewsParity`
(47/47) and the `MLQuantAI_Test_DataHubDeterminism` regression (41/41)
both passed on real compiles/runs, and merged into `mlquantai`. Two gates
from the original DoD were under-tested at that point and are being
closed out here before B4 is actually sealed:

1. **Source-free replay** — the original `Test_Seal_ReplayNeverCallsSources`
   only asserted `Check(true, ...)` with a "true by construction" comment.
   That's an architectural claim, not a verified one - it never actually
   built data, persisted it, threw away in-memory state, and re-derived
   the same hashes from disk alone. See `Tests/MLQuantAI_Test_NewsReplayIsolation.mq5`.
2. **Additive schema evolution** — B4 never exercised what happens when a
   news event carries fields the current schema didn't originally define
   (the exact scenario `news_schema_version` exists to eventually support).
   See `Tests/MLQuantAI_Test_NewsSchemaEvolution.mq5` and the new
   `forecast`/`actual`/`previous` pass-through fields below.

Builds a single Raw → Normalize → Dedup → Sort/Select pipeline shared by
both the live MT5 Economic Calendar and a deterministic Tester-only CSV
source, so `MarketContext.news[]` — and everything derived from it — is
identical regardless of which source supplied the data. No CRT/
`TradeCandidate`/execution code touched. See `Docs/PhaseB_B3_5_
DeterminismSeal.md` for B3/B3.5 (B3.5 stays SEALED — its one `[SKIP]`
run was a bar rollover between script runs, not a regression, and doesn't
affect its sealed status).

## Why a shared pipeline

Before B4, `News_BuildSnapshots_Live()` and `News_BuildSnapshots_Csv()`
(B3) each normalized impact/dedup'd/sorted independently — two sources
could legally disagree on what "the same event" even means. B4 replaces
both with one interface (`INewsSource`) that only *reads raw data*, and
one pipeline (`Market/MLQuantAI_NewsCanonicalizer.mqh`) that is the ONLY
place normalization, dedup, sort, and select logic lives. Neither
`LiveCalendarNewsSource` nor `CsvStaticNewsSource` is allowed its own
copy of that logic.

```
INewsSource.ReadRawEvents() -> RawNewsEvent[]
   -> News_NormalizeAll()                  -> NormalizedNewsEvent[]
   -> News_Deduplicate()                   -> NormalizedNewsEvent[] (deduped)
   -> News_SortAndSelect(..., MAX_EVENTS)  -> NormalizedNewsEvent[] (final, top 10)
   -> News_ToSnapshotArray()               -> NewsSnapshot[]        (embedded in MarketContext)
```

`Market/MLQuantAI_NewsEngine.mqh`'s `NewsEngine_Build(anchorTime)` is the
only caller of this pipeline; `FeatureEngine_BuildContext()` is the only
caller of `NewsEngine_Build()`. Replay never re-enters any of this — see
"Replay never touches a source" below.

## Frozen contract

### `RawNewsEvent` (`Market/MLQuantAI_NewsSource.mqh`)

Exactly what a source read, before any normalization — field values are
whatever the source itself reports (e.g. `impact_raw` can be `"HIGH"`,
`"High"`, or `"3"`; `release_time` is the source's own native clock).

```
provider_event_id, currency, impact_raw, title, release_time,
source_kind, source_version, source_content_hash, source_priority,
revision_id, revision_timestamp
```

### `NormalizedNewsEvent` (`Market/MLQuantAI_NewsCanonicalizer.mqh`)

The pipeline's internal working struct — decision fields plus full
lineage, INCLUDING `source_content_hash` (audit-only, dropped before the
final `NewsSnapshot` conversion since it describes the raw payload, not
the normalized event).

```
calendar_event_id, normalized_event_key, currency, impact_normalized,
title_normalized, release_time_utc, minutes_to_event,
news_schema_version, revision_id, revision_timestamp,
source_kind, source_version, source_content_hash, source_priority
```

### Freeze rules

```
normalized_event_key = UPPER(currency) + "|" + normalized_title + "|" + release_time_utc
minutes_to_event      = truncate_toward_zero((release_time_utc - anchor_time_utc) / 60)

MLQUANTAI_NEWS_LOOKBACK_MINUTES  = 1440   (24h)
MLQUANTAI_NEWS_LOOKAHEAD_MINUTES = 1440   (24h)
MLQUANTAI_NEWS_MAX_EVENTS        = 10
```

These three constants are `#define`s, not EA inputs — they are not
tunable, because changing them changes what "the same anchor bar"
selects, which would break replay determinism for anything already
logged under the current values.

`title_normalized` = trim + collapse internal whitespace runs to one
space + uppercase (`News_NormalizeTitle`). `impact_normalized` maps
`HIGH`/`3`→3, `MEDIUM`/`MODERATE`/`2`→2, `LOW`/`1`→1, anything else→0,
case-insensitively (`News_NormalizeImpact`).

**Known limitation, documented not hidden:** `News_NormalizeTimeUtc()` is
an identity pass-through. MQL5 has no reliable way to convert an
arbitrary *historical* datetime to true UTC (no historical GMT-offset
API, and DST transitions make this worse), so "UTC" throughout this
pipeline means "this project's single canonical clock" — broker server
time, the same clock `anchor_bar_time`/`iTime()` already use everywhere
else in the project. Not a real UTC conversion.

## Dedup tie-break (`News_CompareForDedup` / `News_Deduplicate`)

Two raw rows that normalize to the same `normalized_event_key` collapse
to one, in this order:

1. Higher `source_priority` wins outright.
2. Equal priority → later `revision_timestamp` wins.
3. Equal priority AND revision_timestamp → lexically smaller
   `source_kind` wins (arbitrary, but deterministic).
4. Fully tied on all three AND the decision fields
   (`impact_normalized`/`release_time_utc`) also agree → keep either,
   no-op.
5. Fully tied on all three but decision fields **conflict** → `News_
   Deduplicate` returns `false` with a reason. A genuine data-quality
   conflict fails loudly instead of nondeterministically picking a
   winner based on array order.

Default priorities: `CsvStaticNewsSource` = 10, `LiveCalendarNewsSource`
= 20 (a live read is generally more current than a static file — in
practice the two never compete within one EA run, since Tester uses CSV
and live trading uses the calendar; this mostly matters for the parity
test's explicit tie-break coverage).

## Sort + select (`News_SortLess` / `News_SortAndSelect`)

Ascending `abs(minutes_to_event)`, then descending `impact_normalized`,
then ascending `release_time_utc`, then ascending `normalized_event_key`
as a final deterministic tie-break — then truncate to
`MLQUANTAI_NEWS_MAX_EVENTS`. Every tie is resolved by a field further
down the chain, so the same input set always selects the same top-10
regardless of what order the source originally returned it in
(`Test_SortAndSelect_OrderIndependent`).

## The two hashes

`MarketContext` carries two news-derived hashes with deliberately
different scope:

- **`news_decision_hash`** (`News_DecisionHash`) — hashes ONLY
  `currency|impact_normalized|release_time_utc|minutes_to_event` per
  selected event, in final sorted order. Source-independent: the same
  underlying event reported by Live vs. CSV produces the SAME
  `news_decision_hash`. This is what feeds `MarketContext_HashPayload()`
  — metadata-only differences (which source, which revision, which
  provider id) must never move `context_hash`.
- **`news_snapshot_identity`** (`News_SnapshotIdentity`) — hashes the
  full selected set INCLUDING lineage (`normalized_event_key`,
  `calendar_event_id`, `revision_id`, `revision_timestamp`,
  `source_kind`, `source_priority`). Deliberately source-DEPENDENT — this
  is the audit-trail hash B5's dataset lineage will key off, and it
  changes on exactly the metadata differences `news_decision_hash`
  ignores.

`MarketContext_HashPayload()`'s news contribution is `news_decision_hash`
alone (not a per-element loop over `news[]`) — see that file's own
comment for why this is a deliberate, one-time-safe algorithm change (no
real candidate dataset yet depends on a historical `context_hash` value,
since B5 hasn't started).

## CSV source (`Market/MLQuantAI_CsvStaticNewsSource.mqh`)

Tester-only, deterministic, and the parity test's oracle. Reads from
`Common\Files` (`FILE_TXT`, so `FileReadString()` reads one whole line at
a time):

```
line 1: # news_schema_version=NEWS_V1;source_version=...;source_content_hash=...
line 2: provider_event_id,currency,impact,title,release_time_utc,revision_id,revision_timestamp_utc   (header, not parsed)
line 3+: one event per line, exactly 7 comma-separated fields
```

`Load()` fails closed — returns `false` with a reason — on: a missing
file, a metadata line that isn't well-formed or names a schema version
this build doesn't recognize, or ANY data row that doesn't parse to
exactly 7 fields with non-empty `provider_event_id`/`currency`/
`release_time_utc`. It never skips a bad row and proceeds with the rest.

`ValidateCoverage(rangeStart, rangeEnd, outError)` is a hard gate (not
advisory) — `MLQuantAI.mq5`'s `OnInit` calls `NewsEngine_InitCsvSource()`
in Tester mode and returns `INIT_FAILED` if it fails.

## Live adapter (`Market/MLQuantAI_LiveCalendarNewsSource.mqh`)

Converts `CalendarValueHistory()`/`CalendarEventById()`/
`CalendarCountryById()` output into `RawNewsEvent[]`, then hands it to
the exact same canonicalizer — no normalization logic of its own. A
`CalendarValueHistory()` failure returns `false` with a reason; it never
silently falls back to "no news". It never writes `NewsSnapshot` directly
— only `NewsEngine_Build()` does that, after routing through the shared
pipeline.

## Replay never touches a source

`NewsEngine_Build()` is only ever called from `FeatureEngine_
BuildContext()`, which `MLQuantAI.mq5`'s `OnTick()` calls on a new closed
trigger bar. `Infrastructure/EventStore/MLQuantAI_ReplayEngine.mqh`'s
`StateProjector` reconstructs state purely from already-logged
`MARKET_CONTEXT_READY` events (including the embedded `NewsSnapshot[]`,
`news_decision_hash`, `news_snapshot_identity`) — it never calls
`NewsEngine_Build()` or touches an `INewsSource`. This is true by
construction (there is exactly one call site for `NewsEngine_Build()` in
the whole project), not enforced by a runtime assertion.

## Test coverage (`Tests/MLQuantAI_Test_NewsParity.mq5`)

Requires `Tests/Fixtures/MLQuantAI_NewsParityFixture_V1.csv` copied into
the terminal's `Common\Files` folder before running (same convention as
the existing `MLQuantAI_News.csv` fixture).

- **Core parity** — the same underlying event reported by a synthetic
  Live raw row and a synthetic CSV raw row (differing in numeric vs.
  string impact, and whitespace/case title variance) normalizes to the
  same `normalized_event_key`/`impact_normalized`/`minutes_to_event`/
  `news_decision_hash`, but a DIFFERENT `news_snapshot_identity` (by
  design). A hand-built Live-shaped and CSV-shaped `MarketContext` with
  the same `news_decision_hash` but different `news[]` content/count
  produce identical `MarketContext_HashPayload()`.
- **Canonicalization** — impact case-insensitivity (`HIGH`/`High`/`high`),
  title whitespace/case normalization (including tabs/newlines), `minutes_
  to_event` truncation toward zero for both signs (±90s → ±1, not ±2;
  ±30s → 0, not rounded), the full 3-level dedup tie-break order plus the
  agree/conflict outcomes, and sort/select order-independence from input
  order.
- **Selection/coverage** — run against the real fixture: >10 USD
  candidate events near the anchor cap to exactly the canonical top 10
  (the fixture is built so the closest 10 by `abs(minutes_to_event)` are
  precisely the 5/10/15/20/25/30(NFP, post-dedup)/35/40/45/50-minute
  events, deterministically excluding 55/60/120/180-minute events), the
  duplicate Non-Farm Payrolls pair resolves to the later-revision winner,
  a missing/wrong event is provably absent (not just trivially passing),
  and both a too-wide coverage request and a missing/malformed CSV file
  fail closed with a reason.
- **Seal criteria** — metadata-only differences (`revision_id`/
  `source_kind`/`source_priority`) leave `news_decision_hash` unchanged
  while still moving `news_snapshot_identity`; the replay/no-source-access
  guarantee (structural, see above); a hand-built `MarketContext` logged
  to a scratch event store round-trips `normalized_event_key`/
  `revision_id`/`source_priority`/`news_decision_hash`/
  `news_snapshot_identity` through `MARKET_CONTEXT_READY`'s JSON payload.

## B4 seal criteria (Step 9)

B4 closes when, on a real compile + run:

- `MLQuantAI_Test_NewsParity.mq5` = ALL PASS
- `MLQuantAI_Test_DataHubDeterminism.mq5` (B3/B3.5 regression) = PASS
- No source access during replay = verified (true by construction, see
  above)
- Coverage failure = fails closed (`Test_CoverageValidation_
  FailsClosedOnGap`, `NewsEngine_InitCsvSource` gating `MLQuantAI.mq5`'s
  `OnInit`)
- Live/CSV parity = verified (`Test_Parity_*`)
- `MARKET_CONTEXT_READY` includes the B5 lineage fields
  (`normalized_event_key`/`revision_id`/`revision_timestamp`/
  `source_priority`, plus `news_decision_hash`/`news_snapshot_identity`
  at the `MarketContext` level)

Once all of the above are confirmed by a real MetaEditor compile and test
run, B4 merges into `mlquantai`, tagged `phase-b-b4-news-parity-v1`, and
B5 (CRT detector-only) opens.
