# Phase B — B3.5: Data Hub Determinism Seal

**Status: CONDITIONAL PASS - not yet SEALED.** 6 of 7 criteria verified
against a real compile + test run (2026-08-14); the cross-session check
still needs to be re-run across an actual MT5 terminal restart (not just
a script re-invocation within the same running terminal) before this can
be marked SEALED. See `Docs/PhaseB_B3_DataHubDeterminism.md` for B3
itself.

## Evidence so far

`MLQuantAI_Test_DataHubDeterminism` run at 16:07:43 - **38/38 checks
passed**, including the cross-session fixture check:
`[PASS] rebuilt context_hash for the SAME anchor bar matches the hash a
PREVIOUS run of this script persisted`. A second run at 16:10:11 (after
the M5 trigger bar rolled over) correctly reported `[SKIP]` rather than a
false pass/fail - proving the check actually compares against the
fixture rather than trivially passing. Full Phase A + B1 + B2 regression
stayed green across every run in this pass.

## Why this isn't SEALED yet

Both the 16:07:43 and 16:10:11 runs were the script being re-invoked
within the SAME already-running MT5 terminal process - proving the
fixture-compare mechanism itself works, but not proving determinism
survives an actual process boundary (terminal indicator-handle caches,
loaded DLL state, etc. all persisted across those two runs, since the
terminal itself never restarted). The seal criterion is specifically
"restart EA or MT5 session, rebuild the same context, get the same
hash" - that still needs its own piece of evidence.

## What's needed to close this out

No code changes - the mechanism (`Test_CrossSessionFixture()`) is
already correct and doesn't need to change. Just run it across a real
restart, within one M5 window:

1. Run `MLQuantAI_Test_DataHubDeterminism` once (persists the fixture).
2. **Actually restart MT5** (close and reopen the terminal, or at minimum
   fully unload/reload the terminal's script engine - not just re-running
   the script from the Navigator).
3. Run the script again, within the same M5 bar as step 1.
4. Confirm the log shows a new terminal/session startup AND
   `[PASS] rebuilt context_hash for the SAME anchor bar matches the hash
   a PREVIOUS run of this script persisted`.

Once that lands, this file's status flips to SEALED and B3/B3.5 close
per `Docs/PhaseB_B3_DataHubDeterminism.md`'s DoD.

## The 5 seal criteria and what satisfies each one

1. **In-session determinism** - `Test_DeterminismOver1000Rebuilds()`
   (already existed from B3): rebuilds the same anchor bar 1,000 times,
   asserts `context_hash` is identical every time.

2. **Cross-session determinism** - `Test_CrossSessionFixture()`
   (new): persists `anchor_bar_time` + `context_hash` to
   `MLQuantAI_Test_DataHubDeterminism_Fixture.csv` (`Common\Files`). If a
   *previous* run of this same script already left a fixture for the
   *same* anchor bar, asserts the hash matches. Since the trigger bar
   only stays the same for a few minutes of wall-clock time, this
   genuinely exercises "rebuild after a restart" whenever the script is
   run twice within one bar - and honestly reports SKIP (not a false
   pass) when the bar has rolled over between runs, since there's no way
   to force wall-clock time backward in a single automated pass. **To
   actually exercise this check: run the script, then run it again
   within the same trigger-timeframe window (5 minutes, for the default
   M5).**

3. **Account-exclusion** - `Test_AccountExclusion_RealPipeline()` (new):
   takes a REAL context from `FeatureEngine_BuildContext()` (not a
   hand-built test struct - B1's contract test already covers that
   structurally), mutates only `.account`, and asserts the hash payload
   is unchanged.

4. **Hash coverage** - `MarketContext_HashPayload()` was extended to
   include:
   - `m5_bar`/`m15_bar`/`h1_bar`/`h4_bar`: time, OHLC, `tick_volume`, and
     the historical `spread` MT5 recorded for that bar (via the new
     `MarketContext_RatesHashFragment()`).
   - The full, **canonically ordered** `NewsSnapshot[]` content (via the
     new `NewsSnapshot_HashFragment()` per element) - not just
     `news_count`/`max_news_impact`/`nearest_news_minutes` as before.
   - Everything B3 already hashed: `instrument_id`/`broker_symbol`/
     `trigger_timeframe`/`anchor_bar_time`, `bid_at_anchor`/
     `ask_at_anchor`/`spread_points_at_anchor`, `atr_m15`/`adx_m15`/
     `ema_slope_m15`, `pdh`/`pdl`/`asian_range_high`/`asian_range_low`,
     `session_id`/`is_kill_zone`.
   - `MarketContext_RatesToJson()` (the logged payload) was extended
     with `tick_volume` to match what's now hashed - so the logged
     `MARKET_CONTEXT_READY` line carries every field that determines its
     own `context_hash`.

   News ordering: `NewsSnapshot_Canonicalize()` (new, in
   `Market/MLQuantAI_NewsSnapshot.mqh`) sorts a `NewsSnapshot[]` by
   `release_time` ascending, then `calendar_event_id` ascending as a
   tie-breaker. `FeatureEngine_BuildContext()` calls this on `ctx.news`
   immediately after `News_BuildSnapshots()` populates it, BEFORE
   computing `news_count`/`max_news_impact`/`nearest_news_minutes` or the
   hash - so the stored array, the logged JSON, and the hash payload all
   see the same canonical order regardless of what order
   `CalendarValueHistory()`/the CSV scan happened to return rows in.
   `Test_NewsSnapshotCanonicalization()` (new, self-contained, no live
   dependency) proves both that source order actually changes the
   uncanonicalized hash AND that it stops mattering once canonicalized.

5. **Regression** - run `Tests/MLQuantAI_Test_DataHubDeterminism.mq5`
   alongside every Phase A test, `MLQuantAI_Test_PhaseBContracts.mq5`
   (B1), and `MLQuantAI_Test_SymbolResolver.mq5` (B2). Expanding the hash
   payload's *inputs* changes what `context_hash` VALUES look like, but
   doesn't change the *properties* any existing test checks (B1's
   `Test_MarketContext_HashExcludesRuntimeMetadata` only asserts relative
   equality/inequality, never a literal hash string), so no other test
   should need editing for this to pass.

## What "SEALED" means once this run comes back green

`B3 = SEALED` and `B3.5 = SEALED` - the candidate dataset B5's CRT
detector will eventually produce can be trusted to replay identically
across restarts, which is the actual precondition for B4 (News Engine
parity) adding more input surface on top of this.
