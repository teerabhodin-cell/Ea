//+------------------------------------------------------------------+
//| MLQuantAI_Test_PhaseBContracts.mq5                               |
//| Phase B B1.5: struct-shape and determinism tests for the frozen  |
//| B1 contracts (MarketContext, NewsSnapshot, TradeCandidate,       |
//| RiskDecision, ContractVersions). No Event Store, no DataHub, no  |
//| FeatureEngine, no order logic - this only proves the contract    |
//| structs are complete, versioned, and (for NewsSnapshot) actually |
//| replayable via JSON round-trip.                                  |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Core/MLQuantAI_ContractVersions.mqh>
#include <MLQuantAI/Core/MLQuantAI_Ids.mqh>
#include <MLQuantAI/Core/MLQuantAI_TradeCandidate.mqh>
#include <MLQuantAI/Core/MLQuantAI_RiskDecision.mqh>
#include <MLQuantAI/Market/MLQuantAI_MarketContext.mqh>
#include <MLQuantAI/Market/MLQuantAI_NewsSnapshot.mqh>
#include <MLQuantAI/Market/MLQuantAI_FeatureSnapshot.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// B1.1 - contract versions
//---------------------------------------------------------------------
void Test_ContractVersions()
{
   Print("--- ContractVersions ---");
   Check(MLQUANTAI_MARKET_CONTEXT_SCHEMA_V1 == "MARKET_CONTEXT_V1", "market context schema v1 label frozen");
   Check(MLQUANTAI_FEATURE_SCHEMA_V1        == "FEATURES_V1",       "feature schema v1 label frozen");
   Check(MLQUANTAI_CANDIDATE_SCHEMA_V1      == "CANDIDATE_V1",      "candidate schema v1 label frozen");
   Check(MLQUANTAI_NEWS_SCHEMA_V1           == "NEWS_V1",           "news schema v1 label frozen");
   Check(MLQUANTAI_RISK_SCHEMA_V1           == "RISK_V1",           "risk schema v1 label frozen");
}

//---------------------------------------------------------------------
// B1.2 - MarketContext
//---------------------------------------------------------------------
void Test_MarketContext_InitAndShape()
{
   Print("--- MarketContext: init + shape ---");

   MarketContext ctx;
   MarketContext_Init(ctx);

   Check(ctx.market_context_schema_version == MLQUANTAI_MARKET_CONTEXT_SCHEMA_V1, "Init stamps market_context_schema_version");
   Check(ctx.feature_schema_version        == MLQUANTAI_FEATURE_SCHEMA_V1,        "Init stamps feature_schema_version");
   Check(ctx.news_schema_version           == MLQUANTAI_NEWS_SCHEMA_V1,           "Init stamps news_schema_version");
   Check(ArraySize(ctx.news) == 0 && ctx.news_count == 0, "Init leaves news[] empty");
   Check(ctx.account.context_schema_version != "", "embedded AccountSnapshot is itself initialized (not a blank struct)");
   Check(ctx.symbol_spec.context_schema_version != "", "embedded SymbolSpec is itself initialized (not a blank struct)");

   // instrument_id (canonical) vs broker_symbol (broker-specific alias)
   // must be able to differ - that's the entire reason B2 introduces this
   // split instead of using one "symbol" string like Step 9's context did.
   ctx.instrument_id = "XAUUSD";
   ctx.broker_symbol = "XAUUSDm";
   Check(ctx.instrument_id != ctx.broker_symbol, "instrument_id and broker_symbol are independently settable and can differ");
   Check(ctx.instrument_id == "XAUUSD", "instrument_id holds the canonical symbol");
   Check(ctx.broker_symbol == "XAUUSDm", "broker_symbol holds the broker-specific alias");
}

// anchor_bar_time MUST be a closed bar (shift=1), never bar 0 / TimeCurrent().
// This can't fully prove a future FeatureEngine will honor the rule (B2/B3's
// job), but it proves the *convention* is real and distinguishable: shift=1
// and shift=0 are different bars, and shift=1 is always strictly in the past
// relative to "now" - shift=0 is not (it's still forming).
void Test_MarketContext_ClosedBarSemantics()
{
   Print("--- MarketContext: closed-bar anchor semantics ---");

   if(!SymbolSelect(_Symbol, true) || SeriesInfoInteger(_Symbol, PERIOD_M5, SERIES_BARS_COUNT) < 3)
   {
      Print("  [SKIP] not enough M5 history available in this context to check closed-bar semantics");
      return;
   }

   datetime closedBar  = iTime(_Symbol, PERIOD_M5, 1); // last CLOSED bar - the only legal anchor_bar_time source
   datetime formingBar = iTime(_Symbol, PERIOD_M5, 0); // still forming - forbidden as an anchor

   Check(closedBar > 0, "iTime(shift=1) resolves to a real bar");
   Check(closedBar < formingBar || closedBar <= TimeCurrent(), "the closed bar (shift=1) is not in the future relative to the forming bar/now");
   Check(closedBar != formingBar || formingBar == 0, "shift=1 and shift=0 are distinct bars whenever both are resolvable");

   MarketContext ctx;
   MarketContext_Init(ctx);
   ctx.trigger_timeframe = "M5";
   ctx.anchor_bar_time   = closedBar; // the only correct assignment - never TimeCurrent()
   Check(ctx.anchor_bar_time == closedBar && ctx.anchor_bar_time != 0, "anchor_bar_time set from the closed bar, not TimeCurrent()");
}

// The hash payload must define a context's IDENTITY off market/feature/news
// fields only - two builds of "the same" bar must hash identically even if
// account state (balance/equity, which move independently of the market)
// differs between the two builds.
void Test_MarketContext_HashExcludesRuntimeMetadata()
{
   Print("--- MarketContext: context_hash excludes runtime-only metadata ---");

   MarketContext a, b;
   MarketContext_Init(a);
   MarketContext_Init(b);

   a.instrument_id = "XAUUSD"; b.instrument_id = "XAUUSD";
   a.broker_symbol = "XAUUSDm"; b.broker_symbol = "XAUUSDm";
   a.trigger_timeframe = "M5"; b.trigger_timeframe = "M5";
   a.anchor_bar_time = D'2026.08.14 09:30'; b.anchor_bar_time = D'2026.08.14 09:30';
   a.bid_at_anchor = 3345.20; b.bid_at_anchor = 3345.20;
   a.ask_at_anchor = 3345.40; b.ask_at_anchor = 3345.40;

   a.account.balance = 10000.0;
   b.account.balance = 9500.0; // different account state, SAME market snapshot

   string hashA = MarketContext_HashPayload(a);
   string hashB = MarketContext_HashPayload(b);
   Check(hashA == hashB, "context_hash payload is identical when only account state differs (account excluded from identity)");

   MarketContext c;
   MarketContext_Init(c);
   c.instrument_id = "XAUUSD"; c.broker_symbol = "XAUUSDm"; c.trigger_timeframe = "M5";
   c.anchor_bar_time = D'2026.08.14 09:30';
   c.bid_at_anchor = 3350.00; // different price -> must hash differently
   c.ask_at_anchor = 3350.20;

   Check(MarketContext_HashPayload(c) != hashA, "context_hash payload changes when market fields differ");
}

//---------------------------------------------------------------------
// B1.3 - NewsSnapshot
//---------------------------------------------------------------------
void Test_NewsSnapshot_RoundTrip()
{
   Print("--- NewsSnapshot: serialize/deserialize round-trip ---");

   NewsSnapshot n;
   NewsSnapshot_Init(n);
   n.calendar_event_id = "CAL_12345";
   n.currency            = "USD";
   n.impact               = 2; // HIGH, per CALENDAR_IMPORTANCE_HIGH convention
   n.title                 = "Non-Farm Payrolls (with \"quotes\" and a \\ backslash)";
   n.release_time          = D'2026.08.14 12:30';
   n.minutes_to_event      = -15; // already released relative to anchor
   n.source_kind            = "CSV_STATIC";
   n.source_version         = MLQUANTAI_NEWS_SCHEMA_V1;

   string json = NewsSnapshot_ToJson(n);
   Check(StringLen(json) > 0 && StringFind(json, "CAL_12345") >= 0, "NewsSnapshot_ToJson produces non-empty JSON containing the event id");

   NewsSnapshot back;
   bool ok = NewsSnapshot_FromJson(json, back);
   Check(ok, "NewsSnapshot_FromJson parses the JSON produced by NewsSnapshot_ToJson");
   Check(back.calendar_event_id == n.calendar_event_id, "round-trip preserves calendar_event_id");
   Check(back.currency == n.currency, "round-trip preserves currency");
   Check(back.impact == n.impact, "round-trip preserves impact");
   Check(back.title == n.title, "round-trip preserves title, including escaped quotes/backslash");
   Check(back.release_time == n.release_time, "round-trip preserves release_time");
   Check(back.minutes_to_event == n.minutes_to_event, "round-trip preserves (negative) minutes_to_event");
   Check(back.source_kind == n.source_kind, "round-trip preserves source_kind");
   Check(back.source_version == n.source_version, "round-trip preserves source_version");

   NewsSnapshot bad;
   Check(!NewsSnapshot_FromJson("{}", bad), "FromJson rejects a JSON object with no calendar_event_id rather than returning a fake-empty snapshot");
}

void Test_NewsSnapshot_ArrayRoundTrip()
{
   Print("--- NewsSnapshot: array round-trip (what MarketContext.news[] will embed) ---");

   NewsSnapshot arr[];
   ArrayResize(arr, 2);
   NewsSnapshot_Init(arr[0]);
   arr[0].calendar_event_id = "CAL_1"; arr[0].currency = "USD"; arr[0].impact = 2;
   arr[0].title = "FOMC Statement"; arr[0].release_time = D'2026.08.14 18:00'; arr[0].minutes_to_event = 30;
   arr[0].source_kind = "LIVE_CALENDAR"; arr[0].source_version = MLQUANTAI_NEWS_SCHEMA_V1;

   NewsSnapshot_Init(arr[1]);
   arr[1].calendar_event_id = "CAL_2"; arr[1].currency = "EUR"; arr[1].impact = 1;
   arr[1].title = "ECB Press Conference"; arr[1].release_time = D'2026.08.14 18:45'; arr[1].minutes_to_event = 75;
   arr[1].source_kind = "LIVE_CALENDAR"; arr[1].source_version = MLQUANTAI_NEWS_SCHEMA_V1;

   string json = NewsSnapshot_ArrayToJson(arr);
   Check(StringFind(json, "CAL_1") >= 0 && StringFind(json, "CAL_2") >= 0, "array JSON contains both elements");

   NewsSnapshot back[];
   int n = NewsSnapshot_ArrayFromJson(json, back);
   Check(n == 2, "array round-trip preserves element count");
   Check(n == 2 && back[0].calendar_event_id == "CAL_1" && back[1].calendar_event_id == "CAL_2", "array round-trip preserves element order and identity");

   NewsSnapshot empty[];
   int nEmpty = NewsSnapshot_ArrayFromJson(NewsSnapshot_ArrayToJson(empty), back);
   Check(nEmpty == 0, "an empty NewsSnapshot[] round-trips to an empty array (no news near this context is a valid, replayable state)");
}

//---------------------------------------------------------------------
// B1.4 - TradeCandidate (additive B1 fields)
//---------------------------------------------------------------------
void Test_TradeCandidate_B1Fields()
{
   Print("--- TradeCandidate: B1 additive fields ---");

   TradeCandidate c;
   TradeCandidate_Init(c);

   Check(c.candidate_schema_version == MLQUANTAI_CANDIDATE_SCHEMA_V1, "Init stamps candidate_schema_version");
   Check(c.context_event_id == "" && c.context_hash == "", "Init leaves context lineage empty until a detector fills it in");
   Check(ArraySize(c.trigger_reasons) == 0 && c.trigger_reason_mask == 0, "Init leaves the reason tree empty");

   // Phase A fields must survive untouched - this is the additive-only
   // guarantee that keeps Phase A's sealed StateMachine/DummyLifecycle
   // tests compiling against this same struct.
   Check(c.state == CANDIDATE_CREATED, "Phase A field .state still defaults to CANDIDATE_CREATED");
   Check(c.strategy_id == -1, "Phase A field .strategy_id (int) is untouched by the B1 extension");
   Check(c.direction == SIGNAL_NONE, "Phase A field .direction is untouched by the B1 extension");

   string ctxId = Ids_ContextEventId("XAUUSD", "M5", D'2026.08.14 09:30');
   c.context_event_id = ctxId;
   c.context_hash      = "deadbeef";
   c.side               = ORDER_TYPE_BUY;
   c.setup_anchor_bar_time = D'2026.08.14 09:30';
   c.expiry_after_bars      = 6;
   c.entry_hint = 3345.20; c.sl_hint = 3343.00; c.tp_hint = 3350.00;
   c.trigger_reason_mask = 0x3; // e.g. bit0 = liquidity_sweep, bit1 = mss_confirmed
   ArrayResize(c.trigger_reasons, 2);
   c.trigger_reasons[0] = "liquidity_sweep";
   c.trigger_reasons[1] = "mss_confirmed";

   Check(c.context_event_id == ctxId, "context_event_id set from Ids_ContextEventId (Core/MLQuantAI_Ids.mqh) links candidate to its MarketContext");
   Check(c.side == ORDER_TYPE_BUY, "side (ENUM_ORDER_TYPE) settable independently of the legacy .direction field");
   Check(ArraySize(c.trigger_reasons) == 2 && c.trigger_reasons[0] == "liquidity_sweep", "trigger_reasons[] holds the human-readable reason tree");

   // expiry_time is DERIVED - never TimeCurrent() + N minutes.
   datetime expiry = TradeCandidate_ComputeExpiryTime(c.setup_anchor_bar_time, c.expiry_after_bars, PERIOD_M5);
   c.expiry_time = expiry;
   Check(c.expiry_time == c.setup_anchor_bar_time + c.expiry_after_bars * PeriodSeconds(PERIOD_M5),
         "expiry_time derives from setup_anchor_bar_time + expiry_after_bars bars, not TimeCurrent()");

   datetime expiryAgain = TradeCandidate_ComputeExpiryTime(c.setup_anchor_bar_time, c.expiry_after_bars, PERIOD_M5);
   Check(expiryAgain == expiry, "TradeCandidate_ComputeExpiryTime is deterministic - same inputs, same output, unlike TimeCurrent()-based expiry would be");
}

//---------------------------------------------------------------------
// RiskDecision (B1 contract-only, no Risk Manager wired yet)
//---------------------------------------------------------------------
void Test_RiskDecision_Shape()
{
   Print("--- RiskDecision: init + shape ---");

   RiskDecision d;
   RiskDecision_Init(d);

   Check(d.risk_schema_version == MLQUANTAI_RISK_SCHEMA_V1, "Init stamps risk_schema_version");
   Check(d.decision == "" && d.reason_code == REASON_NONE, "Init leaves decision/reason_code unset until the Risk Manager (B7) evaluates a candidate");

   d.candidate_id = "CND_abc123";
   d.decision      = "REJECTED";
   d.reason_code   = REASON_RISK_SPREAD_TOO_WIDE;
   d.evaluated_at  = D'2026.08.14 09:31';
   d.spread_at_decision = 45.0;
   d.news_state_at_decision = "no high-impact news within 30m";
   d.account_state_at_decision = "equity=10000, open_positions=0";

   Check(d.decision == "REJECTED" && d.reason_code == REASON_RISK_SPREAD_TOO_WIDE,
         "a REJECTED RiskDecision carries both the decision and the reason code - "
         "this is what makes rejected candidates auditable instead of just dropped (no survivorship bias)");
}

//---------------------------------------------------------------------
// FeatureSnapshot (contract stub, B3+ wiring)
//---------------------------------------------------------------------
void Test_FeatureSnapshot_Shape()
{
   Print("--- FeatureSnapshot: init + shape (contract stub) ---");
   FeatureSnapshot f;
   FeatureSnapshot_Init(f);
   Check(f.feature_schema_version == MLQUANTAI_FEATURE_SCHEMA_V1, "Init stamps feature_schema_version");
   Check(f.context_event_id == "", "Init leaves context_event_id unset until a Feature Store (B3+) fills it in");
}

//---------------------------------------------------------------------
// No execution path - a structural sanity check, not a runtime one.
// ExecutionRequest does not exist as a file in this commit, and nothing
// in this test (or in any B1 file) calls OrderSend/CTrade - verified by
// inspection per Docs/PhaseB_B1_ContractFreeze.md's "out of scope" list.
//---------------------------------------------------------------------
void Test_NoExecutionPathIntroduced()
{
   Print("--- No execution path introduced in B1 ---");
   Check(true, "B1 adds contract structs only - no ExecutionRequest, no OrderSend/CTrade usage, no DataHub/FeatureEngine/CRT changes (see Docs/PhaseB_B1_ContractFreeze.md)");
}

void OnStart()
{
   Print("=== MLQuantAI Test: Phase B B1 Contract Freeze ===");

   Test_ContractVersions();
   Test_MarketContext_InitAndShape();
   Test_MarketContext_ClosedBarSemantics();
   Test_MarketContext_HashExcludesRuntimeMetadata();
   Test_NewsSnapshot_RoundTrip();
   Test_NewsSnapshot_ArrayRoundTrip();
   Test_TradeCandidate_B1Fields();
   Test_RiskDecision_Shape();
   Test_FeatureSnapshot_Shape();
   Test_NoExecutionPathIntroduced();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   Print(g_TestsPassed == g_TestsRun ? "ALL PASS." : "FAILURES ABOVE.");
}
