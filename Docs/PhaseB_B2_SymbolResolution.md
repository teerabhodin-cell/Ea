# Phase B — B2: Symbol Resolution

Status: contract + resolver frozen. No DataHub/FeatureEngine/`MLQuantAI.mq5`
wiring in this pass — migrating them to call `SymbolSpec_BuildResolved()`
instead of the legacy `SymbolSpec_Build()` is **B3**.

## What this pass added

- `MLQUANTAI_SYMBOL_SPEC_SCHEMA_V1` in `Core/MLQuantAI_ContractVersions.mqh`.
- `Market/MLQuantAI_SymbolSpec.mqh` extended **additively**: `instrument_id`,
  `broker_symbol`, `tick_size`, `tick_value`, `currency_margin`,
  `trade_mode` sit alongside every Step 9 field, unchanged. The legacy
  `SymbolSpec_Build(symbol, out)` still behaves exactly as before —
  `FeatureEngine_Init()` still calls it directly and still compiles.
- `Market/MLQuantAI_SymbolResolver.mqh` — the new B2 logic:
  - `SymbolResolver_LooksLikeAlias(instrument_id, candidate, extraAliasesCsv)`
    — the "not too loose" validation policy. Accepts a candidate only if
    it's a **prefix** of instrument_id (covers broker decorations like
    `XAUUSDm`, `XAUUSD.`, `XAUUSDc`, `XAUUSD-ECN`) or an **exact** match
    against a known alias (a small built-in table for brokers that use an
    unrelated name like `GOLD`, plus `InpExtraSymbolAliases` for anything
    else broker-specific). A plain substring/"contains" check is
    deliberately not used — it would accept something like
    `GOLD_VS_XAUUSD_BASKET` just because `XAUUSD` appears in it somewhere.
  - `SymbolResolver_Resolve()` / `_ResolveWith()` — resolves
    `instrument_id` → `broker_symbol`, preferring `InpBrokerSymbolOverride`
    when set, otherwise the chart's own `_Symbol`. **Fails closed**: an
    unknown symbol (`SymbolSelect` fails) or one that doesn't pass the
    alias check returns `false` with a reason, and leaves the output
    symbol blank — never a half-resolved value.
  - `SymbolSpec_BuildResolved()` / `_BuildResolvedWith()` — resolves and
    builds the full `SymbolSpec` snapshot in one call. On any failure,
    `out` is left at `SymbolSpec_Init()` defaults, not partially filled.
- `Tests/MLQuantAI_Test_SymbolResolver.mq5` — the B2 DoD checklist:
  alias prefix/built-in/extra matching, rejection of loose/wrong matches,
  override-wins-over-chart-symbol, fail-closed on an invalid symbol, and
  the full `SymbolSpec` snapshot (including the new `tick_size`/
  `tick_value`/`currency_margin`/`trade_mode` fields).

## Why `instrument_id` and `broker_symbol` are separate fields

`instrument_id` ("XAUUSD") is the canonical key every deterministic ID and
every dataset row should reference — it never changes across brokers.
`broker_symbol` is whatever this specific terminal actually calls it
(`XAUUSDm`, `GOLD`, `XAUUSD.`, ...) — it's what gets passed to
`CopyRates`/`iTime`/indicator calls and (later) execution. Conflating the
two would make a dataset built on one broker unusable for comparison
against another, and would make `root_event_id`/`candidate_id` hashes
change purely because of a broker's suffix convention.

## What is explicitly out of scope for B2

- No `DataHub`/`FeatureEngine`/`MLQuantAI.mq5` change — they still call the
  legacy `SymbolSpec_Build()` untouched. Migrating them to
  `SymbolSpec_BuildResolved()` and to the B1-frozen
  `Market/MLQuantAI_MarketContext.mqh` contract is **B3**.
- No `OrderSend`/`CTrade`/execution logic.
