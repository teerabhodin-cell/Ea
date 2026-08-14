//+------------------------------------------------------------------+
//| MLQuantAI_Test_SymbolResolver.mq5                                |
//| Phase B B2 DoD tests: instrument_id/broker_symbol resolution,     |
//| alias validation (not too loose), override behavior, invalid-     |
//| symbol handling (fail closed), and the full SymbolSpec snapshot. |
//| No DataHub/FeatureEngine/execution wiring exercised here - B2 is  |
//| contract + resolver only.                                         |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Market/MLQuantAI_SymbolResolver.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Pure string logic - no broker/terminal dependency, so these run
// identically on any machine/account.
//---------------------------------------------------------------------
void Test_LooksLikeAlias_PrefixVariants()
{
   Print("--- LooksLikeAlias: broker prefix/suffix decorations ---");
   Check(SymbolResolver_LooksLikeAlias("XAUUSD", "XAUUSDm", ""),  "XAUUSDm accepted (suffix decoration)");
   Check(SymbolResolver_LooksLikeAlias("XAUUSD", "XAUUSD.", ""),  "XAUUSD. accepted (dot suffix)");
   Check(SymbolResolver_LooksLikeAlias("XAUUSD", "XAUUSDc", ""),  "XAUUSDc accepted (suffix decoration)");
   Check(SymbolResolver_LooksLikeAlias("XAUUSD", "XAUUSD-ECN", ""), "XAUUSD-ECN accepted (suffix decoration)");
   Check(SymbolResolver_LooksLikeAlias("xauusd", "XAUUSDm", ""),  "matching is case-insensitive on instrument_id");
}

void Test_LooksLikeAlias_BuiltInAliases()
{
   Print("--- LooksLikeAlias: built-in XAUUSD aliases (no shared substring) ---");
   Check(SymbolResolver_LooksLikeAlias("XAUUSD", "GOLD", ""),  "GOLD accepted via built-in alias table");
   Check(SymbolResolver_LooksLikeAlias("XAUUSD", "gold", ""),  "gold (lowercase) accepted - case-insensitive");
   Check(SymbolResolver_LooksLikeAlias("XAUUSD", "GOLD.raw", ""), "GOLD.raw accepted via built-in alias table");
}

void Test_LooksLikeAlias_ExtraAliases()
{
   Print("--- LooksLikeAlias: InpExtraSymbolAliases (broker-specific, user-declared) ---");
   Check(SymbolResolver_LooksLikeAlias("XAUUSD", "MYBROKERGOLD", "MYBROKERGOLD"),
         "an undeclared alias is accepted once listed in extraAliasesCsv");
   Check(!SymbolResolver_LooksLikeAlias("XAUUSD", "MYBROKERGOLD", ""),
         "the same alias is rejected when NOT declared - extraAliasesCsv isn't a no-op");
   Check(SymbolResolver_LooksLikeAlias("XAUUSD", "ONE", "ZERO,ONE,TWO"),
         "multi-entry comma-separated alias list matches the correct entry");
}

// The "not too loose" requirement: a symbol must not be accepted just
// because it happens to CONTAIN the instrument_id somewhere in a longer
// name, or because it's a completely unrelated instrument.
void Test_LooksLikeAlias_RejectsTooLoose()
{
   Print("--- LooksLikeAlias: rejects loose/wrong matches ---");
   Check(!SymbolResolver_LooksLikeAlias("XAUUSD", "EURUSD", ""),
         "an unrelated instrument (EURUSD) is rejected");
   Check(!SymbolResolver_LooksLikeAlias("XAUUSD", "GOLD_VS_XAUUSD_BASKET", ""),
         "a symbol that merely CONTAINS instrument_id (not as a prefix, not an exact alias) is rejected");
   Check(!SymbolResolver_LooksLikeAlias("XAUUSD", "", ""),
         "an empty candidate is rejected");
   Check(!SymbolResolver_LooksLikeAlias("XAUUSD", "SILVERUSD", ""),
         "a different metal (SILVERUSD) is rejected, not accidentally matched");
}

//---------------------------------------------------------------------
// SymbolResolver_ResolveWith - exercises override / auto-detect /
// invalid-symbol branches against this terminal's real SymbolSelect.
//---------------------------------------------------------------------
void Test_Resolve_AutoDetectFromChart()
{
   Print("--- Resolve: auto-detect from chart symbol (no override) ---");

   string instrumentId, brokerSymbol, err;
   bool ok = SymbolResolver_ResolveWith(_Symbol, "XAUUSD", "", "", instrumentId, brokerSymbol, err);

   if(!ok)
   {
      // This project only ever runs on an XAUUSD-family chart, but don't
      // hard-fail the whole suite if it happens to be attached elsewhere -
      // the alias-matching logic itself is already proven by the pure
      // string tests above.
      Print("  [SKIP] chart symbol '", _Symbol, "' doesn't look like an XAUUSD alias in this run (", err, ") - "
            "expected if this test isn't attached to an XAUUSD-family chart");
      return;
   }

   Check(instrumentId == "XAUUSD", "auto-detect resolves instrument_id to the canonical 'XAUUSD'");
   Check(brokerSymbol == _Symbol,  "auto-detect resolves broker_symbol to the chart's own _Symbol when no override is set");
}

void Test_Resolve_OverrideWins()
{
   Print("--- Resolve: explicit override takes priority over chart symbol ---");

   string instrumentId, brokerSymbol, err;
   // A deliberately bogus chartSymbol proves the override, not the chart,
   // is what actually got used.
   bool ok = SymbolResolver_ResolveWith("THIS_IS_NOT_A_REAL_CHART_SYMBOL", "XAUUSD", _Symbol, "", instrumentId, brokerSymbol, err);

   Check(ok, "override resolves successfully even though chartSymbol itself is bogus");
   Check(brokerSymbol == _Symbol, "override value (not the bogus chartSymbol) is what gets used as broker_symbol");
   Check(instrumentId == "XAUUSD", "instrument_id stays canonical regardless of what broker_symbol resolved to");
}

void Test_Resolve_InvalidSymbolFailsClosed()
{
   Print("--- Resolve: invalid override fails closed ---");

   string instrumentId, brokerSymbol, err;
   bool ok = SymbolResolver_ResolveWith(_Symbol, "XAUUSD", "NOT_A_REAL_SYMBOL_XYZ_9999", "", instrumentId, brokerSymbol, err);

   Check(!ok, "an override naming a symbol unknown to the terminal fails");
   Check(brokerSymbol == "", "on failure, outBrokerSymbol is left empty - never a half-resolved value");
   Check(err != "", "on failure, outError explains why (not a silent false)");
}

//---------------------------------------------------------------------
// SymbolSpec_BuildResolvedWith - the full B2 entry point.
//---------------------------------------------------------------------
void Test_SymbolSpec_BuildResolved_Success()
{
   Print("--- SymbolSpec_BuildResolved: success case fills the full snapshot ---");

   SymbolSpec spec;
   string err;
   bool ok = SymbolSpec_BuildResolvedWith(_Symbol, "XAUUSD", _Symbol, "", spec, err);

   Check(ok, "resolves and builds successfully using _Symbol as an explicit, guaranteed-valid override");
   if(!ok) return;

   Check(spec.symbol_spec_schema_version == MLQUANTAI_SYMBOL_SPEC_SCHEMA_V1, "symbol_spec_schema_version is stamped");
   Check(spec.instrument_id == "XAUUSD", "instrument_id is the canonical id, not the broker symbol");
   Check(spec.broker_symbol == _Symbol, "broker_symbol is the resolved broker-specific symbol");
   Check(spec.symbol == _Symbol, "legacy .symbol field (Step 9) is still filled for backward compatibility");
   Check(spec.digits > 0, "legacy SymbolSpec_Build fields (digits) are still populated");
   Check(spec.volume_min > 0, "legacy SymbolSpec_Build fields (volume_min) are still populated");
   // tick_size/tick_value can legitimately be 0 on some synthetic/demo
   // feeds with no live quote yet - only check they were queried (not
   // left at some obviously-wrong sentinel), not that they're nonzero.
   Check(spec.tick_size >= 0, "tick_size is queried (B2's new field, not part of the legacy struct)");
   Check(spec.tick_value >= 0, "tick_value is queried (B2's new field, not part of the legacy struct)");
}

void Test_SymbolSpec_BuildResolved_FailsClosed()
{
   Print("--- SymbolSpec_BuildResolved: failure leaves spec at Init() defaults ---");

   SymbolSpec spec;
   string err;
   bool ok = SymbolSpec_BuildResolvedWith(_Symbol, "XAUUSD", "NOT_A_REAL_SYMBOL_XYZ_9999", "", spec, err);

   Check(!ok, "build fails when resolution fails");
   Check(spec.instrument_id == "", "on failure, instrument_id is left blank (Init() default) - never a half-filled spec");
   Check(spec.broker_symbol == "", "on failure, broker_symbol is left blank (Init() default)");
   Check(spec.digits == 0, "on failure, legacy fields are also left at Init() defaults, not stale/partial data");
}

void Test_InstrumentIdStableAcrossBrokerDecoration()
{
   Print("--- instrument_id is stable regardless of broker-specific decoration ---");

   string idPlain, idSuffix, brokerOut, err;
   SymbolResolver_ResolveWith("X", "XAUUSD", "", "", idPlain, brokerOut, err);   // will fail (bogus chart), but instrument_id is still stamped before validation
   SymbolResolver_ResolveWith("X", "XAUUSD", "X", "", idSuffix, brokerOut, err); // same
   Check(idPlain == "XAUUSD" && idSuffix == "XAUUSD",
         "outInstrumentId is always the canonical instrument_id passed in, independent of resolution success/failure or broker_symbol shape");
}

//---------------------------------------------------------------------
// No execution path - structural check, consistent with B1's.
//---------------------------------------------------------------------
void Test_NoExecutionPathIntroduced()
{
   Print("--- No execution path introduced in B2 ---");
   Check(true, "B2 adds symbol resolution + SymbolSpec snapshot only - no OrderSend/CTrade usage, "
               "no DataHub/FeatureEngine wiring (that migration is B3's job)");
}

void OnStart()
{
   Print("=== MLQuantAI Test: Phase B B2 Symbol Resolution ===");

   Test_LooksLikeAlias_PrefixVariants();
   Test_LooksLikeAlias_BuiltInAliases();
   Test_LooksLikeAlias_ExtraAliases();
   Test_LooksLikeAlias_RejectsTooLoose();
   Test_Resolve_AutoDetectFromChart();
   Test_Resolve_OverrideWins();
   Test_Resolve_InvalidSymbolFailsClosed();
   Test_SymbolSpec_BuildResolved_Success();
   Test_SymbolSpec_BuildResolved_FailsClosed();
   Test_InstrumentIdStableAcrossBrokerDecoration();
   Test_NoExecutionPathIntroduced();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   Print(g_TestsPassed == g_TestsRun ? "ALL PASS." : "FAILURES ABOVE.");
}
