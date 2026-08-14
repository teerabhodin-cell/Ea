//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_SymbolResolver.mqh                  |
//| Phase B B2: resolves ONE canonical instrument_id ("XAUUSD") to    |
//| the actual broker_symbol this terminal trades it under            |
//| ("XAUUSDm", "GOLD", "XAUUSD.", ...), and validates the match      |
//| isn't a loose/wrong guess. Every deterministic ID and every       |
//| dataset row keys off instrument_id, which never changes across    |
//| brokers; broker_symbol is what actually gets passed to             |
//| CopyRates/iTime/indicators/(future) execution calls.              |
//|                                                                    |
//| Contract-only in B2: nothing wires this into DataHub/FeatureEngine|
//| or MLQuantAI.mq5 yet - that migration is B3's job. No OrderSend,   |
//| no CTrade, no execution logic here.                                |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_SYMBOLRESOLVER_MQH__
#define __MLQUANTAI_SYMBOLRESOLVER_MQH__

#include "MLQuantAI_SymbolSpec.mqh"

input group "=== Symbol Resolver (Phase B B2) ==="
input string InpInstrumentId         = "XAUUSD"; // canonical instrument id - stable across every broker
input string InpBrokerSymbolOverride = "";        // blank = auto-resolve from the chart's own _Symbol
input string InpExtraSymbolAliases   = "";        // comma-separated extra broker aliases to accept, e.g. "GOLD#,XAUUSD-ECN"

// Broker symbols for XAUUSD are wildly inconsistent - some just add a
// prefix/suffix (XAUUSDm, XAUUSD., .XAUUSD, XAUUSDc, XAUUSD-ECN), but
// some brokers use a name that shares NO substring with "XAUUSD" at all
// (GOLD, GOLD.raw). A pure prefix/substring check can't catch those, so
// this small built-in table exists purely so the common "GOLD" case
// isn't rejected out of the box - InpExtraSymbolAliases covers anything
// broker-specific beyond this. Deliberately NOT a generic multi-
// instrument alias system - this project is XAUUSD-only by design.
string SymbolResolver_BuiltInAliases(string instrumentId)
{
   string upper = instrumentId;
   StringToUpper(upper);
   if(upper == "XAUUSD")
      return "GOLD,GOLD.,GOLDm,GOLDc,GOLD-ECN,GOLD#,XAU/USD,XAUUSD.raw";
   return "";
}

// Splits a comma-separated alias list and checks (case-insensitive,
// whitespace-trimmed) whether candidate matches any entry exactly - NOT
// a substring/contains check, which would be exactly the "too loose"
// matching this policy is meant to avoid (e.g. "XAUUSD" as a substring
// of "GOLD_VS_XAUUSD_BASKET" should never silently pass).
bool SymbolResolver_MatchesAliasList(string candidate, string aliasesCsv)
{
   if(aliasesCsv == "") return false;

   string upperCandidate = candidate;
   StringToUpper(upperCandidate);

   string parts[];
   int n = StringSplit(aliasesCsv, ',', parts);
   for(int i = 0; i < n; i++)
   {
      string a = parts[i];
      StringTrimLeft(a);
      StringTrimRight(a);
      if(a == "") continue;
      string upperA = a;
      StringToUpper(upperA);
      if(upperCandidate == upperA)
         return true;
   }
   return false;
}

// The "not too loose" validation policy: candidate is accepted as a
// broker_symbol for instrumentId only if EITHER
//   (a) candidate starts with instrumentId (covers prefix/suffix broker
//       decorations: XAUUSDm, XAUUSD., XAUUSDc, XAUUSD-ECN, ...), OR
//   (b) candidate exactly matches a known/declared alias (built-in table
//       for common cases like GOLD, or InpExtraSymbolAliases for
//       anything broker-specific this project doesn't already know).
// A plain "contains" check is deliberately NOT used - it would accept
// unrelated symbols that merely happen to embed the instrument id
// somewhere in a longer name.
bool SymbolResolver_LooksLikeAlias(string instrumentId, string candidate, string extraAliasesCsv)
{
   string upperInstrument = instrumentId;
   StringToUpper(upperInstrument);
   string upperCandidate = candidate;
   StringToUpper(upperCandidate);

   if(StringFind(upperCandidate, upperInstrument) == 0)
      return true;

   if(SymbolResolver_MatchesAliasList(candidate, SymbolResolver_BuiltInAliases(instrumentId)))
      return true;

   if(SymbolResolver_MatchesAliasList(candidate, extraAliasesCsv))
      return true;

   return false;
}

// Core resolution logic, parameterized (not read from the live inputs) so
// MLQuantAI_Test_SymbolResolver.mq5 can exercise the override/no-override/
// invalid-symbol branches independently within one script run - the
// input-bound InpBrokerSymbolOverride etc. can only hold ONE value per
// actual EA/script run, which isn't enough to test all branches.
//
// FAILS CLOSED: any failure (unknown symbol, doesn't look like a valid
// alias) returns false with a reason in outError and leaves
// outBrokerSymbol empty - callers must never proceed with a
// candidate.broker_symbol or MarketContext built from a resolution that
// failed.
bool SymbolResolver_ResolveWith(string chartSymbol, string instrumentId, string overrideSymbol, string extraAliasesCsv,
                                 string &outInstrumentId, string &outBrokerSymbol, string &outError)
{
   outInstrumentId = instrumentId;
   outBrokerSymbol = "";
   outError = "";

   string candidate = (overrideSymbol != "") ? overrideSymbol : chartSymbol;

   if(!SymbolSelect(candidate, true))
   {
      outError = StringFormat("broker_symbol '%s' is not known to this terminal (SymbolSelect failed)", candidate);
      return false;
   }

   if(!SymbolResolver_LooksLikeAlias(instrumentId, candidate, extraAliasesCsv))
   {
      outError = StringFormat("broker_symbol '%s' does not look like an alias of instrument_id '%s' - "
                               "add it via InpExtraSymbolAliases if this is intentional", candidate, instrumentId);
      return false;
   }

   outBrokerSymbol = candidate;
   return true;
}

// Convenience wrapper for real runtime use - reads the live inputs.
bool SymbolResolver_Resolve(string chartSymbol, string &outInstrumentId, string &outBrokerSymbol, string &outError)
{
   return SymbolResolver_ResolveWith(chartSymbol, InpInstrumentId, InpBrokerSymbolOverride, InpExtraSymbolAliases,
                                      outInstrumentId, outBrokerSymbol, outError);
}

// Parameterized counterpart to SymbolSpec_BuildResolved(), for the same
// testability reason as SymbolResolver_ResolveWith(). Fails closed: on
// any resolution/build failure, out is left at SymbolSpec_Init()
// defaults and false is returned - never a half-filled spec.
bool SymbolSpec_BuildResolvedWith(string chartSymbol, string instrumentId, string overrideSymbol, string extraAliasesCsv,
                                   SymbolSpec &out, string &outError)
{
   SymbolSpec_Init(out);

   string resolvedInstrumentId, brokerSymbol;
   if(!SymbolResolver_ResolveWith(chartSymbol, instrumentId, overrideSymbol, extraAliasesCsv, resolvedInstrumentId, brokerSymbol, outError))
      return false;

   if(!SymbolSpec_Build(brokerSymbol, out)) // fills digits/point/contract_size/... + out.symbol
   {
      outError = StringFormat("SymbolSpec_Build failed for resolved broker_symbol '%s'", brokerSymbol);
      SymbolSpec_Init(out);
      return false;
   }

   out.symbol_spec_schema_version = MLQUANTAI_SYMBOL_SPEC_SCHEMA_V1;
   out.instrument_id = resolvedInstrumentId;
   out.broker_symbol = brokerSymbol;
   out.tick_size      = SymbolInfoDouble(brokerSymbol, SYMBOL_TRADE_TICK_SIZE);
   out.tick_value      = SymbolInfoDouble(brokerSymbol, SYMBOL_TRADE_TICK_VALUE);
   out.currency_margin  = SymbolInfoString(brokerSymbol, SYMBOL_CURRENCY_MARGIN);
   out.trade_mode        = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(brokerSymbol, SYMBOL_TRADE_MODE);
   return true;
}

// Resolves AND builds the full SymbolSpec snapshot in one call, using the
// live inputs - the B2 entry point future callers (B3's DataHub, B5's
// detectors) should use instead of the legacy SymbolSpec_Build().
bool SymbolSpec_BuildResolved(string chartSymbol, SymbolSpec &out, string &outError)
{
   return SymbolSpec_BuildResolvedWith(chartSymbol, InpInstrumentId, InpBrokerSymbolOverride, InpExtraSymbolAliases, out, outError);
}

#endif // __MLQUANTAI_SYMBOLRESOLVER_MQH__
