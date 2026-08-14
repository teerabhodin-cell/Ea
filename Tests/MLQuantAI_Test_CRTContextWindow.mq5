//+------------------------------------------------------------------+
//| MLQuantAI_Test_CRTContextWindow.mq5                               |
//| Phase B B5 Commit 2 DoD: MarketContext.trigger_tf_recent[] window  |
//| rules (capture, ordering, anchor equality, context_hash/replay     |
//| parity) plus the CRT_V1 domain model utilities (CRTDetectionResult,|
//| reason label ordering, detector_hash). No CRT_IsSweepLow/          |
//| CRT_ConfirmMSS/CRT_FindFVG/CRT_FindOrderBlock or any detection      |
//| rule logic exercised here - that's Commit 3+.                      |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Market/MLQuantAI_FeatureEngine.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_CRTContextWindow.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

// Same extraction helper as Tests/MLQuantAI_Test_NewsReplayIsolation.mq5 -
// finds the "[...]" substring for a top-level JSON array field in a flat
// (non-nested) JSON object line.
string ExtractJsonArray(string line, string key)
{
   string needle = "\"" + key + "\":[";
   int start = StringFind(line, needle);
   if(start < 0) return "";
   int arrStart = start + StringLen(needle) - 1;
   int depth = 0;
   int n = StringLen(line);
   for(int i = arrStart; i < n; i++)
   {
      ushort ch = StringGetCharacter(line, i);
      if(ch == '[') depth++;
      else if(ch == ']')
      {
         depth--;
         if(depth == 0)
            return StringSubstr(line, arrStart, i - arrStart + 1);
      }
   }
   return "";
}

void MakeBar(MqlRates &r, datetime t, double open, double high, double low, double close, long tickVolume, int spread)
{
   ZeroMemory(r);
   r.time = t; r.open = open; r.high = high; r.low = low; r.close = close;
   r.tick_volume = tickVolume; r.spread = spread;
}

//=====================================================================
// Real pipeline - FeatureEngine_BuildContext() on the actual chart
//=====================================================================

void Test_Init()
{
   Print("--- FeatureEngine_Init ---");
   Check(FeatureEngine_Init(_Symbol), "FeatureEngine_Init resolves the symbol and creates indicator handles");
}

void Test_Window_RealPipeline_Rules()
{
   Print("--- trigger_tf_recent[]: rules on a real FeatureEngine_BuildContext() context ---");

   MarketContext ctx = FeatureEngine_BuildContext();
   if(!FeatureEngine_IsReady(ctx))
   {
      Check(false, "FeatureEngine_BuildContext() did not produce a ready context - is the chart symbol resolved and does it have history?");
      return;
   }

   int n = ArraySize(ctx.trigger_tf_recent);
   Check(n <= MLQUANTAI_CRT_V1_LOOKBACK_BARS,
         StringFormat("window never exceeds the frozen LOOKBACK_BARS size (got %d, max %d)", n, MLQUANTAI_CRT_V1_LOOKBACK_BARS));

   bool ascending = true;
   for(int i = 1; i < n; i++)
      if(ctx.trigger_tf_recent[i].time <= ctx.trigger_tf_recent[i-1].time) ascending = false;
   Check(ascending, "window is strictly ascending oldest->newest (no manual reversal needed - CopyRates already fills this order for a plain array)");

   if(n > 0)
      Check(ctx.trigger_tf_recent[n-1].time == ctx.anchor_bar_time,
            "the last element's time equals anchor_bar_time - trigger_tf_recent[N-1] IS the anchor bar");

   datetime formingBarTime = iTime(g_FeatureEngine_BrokerSymbol, InpTriggerTimeframe, 0);
   bool includesFormingBar = false;
   for(int i = 0; i < n; i++)
      if(ctx.trigger_tf_recent[i].time == formingBarTime) includesFormingBar = true;
   Check(!includesFormingBar, "the window never includes the forming/current bar (shift 0)");

   // A real XAUUSD chart should have far more than 64 bars of trigger-
   // timeframe history available - this asserts the "happy path" fills
   // the window to the frozen size, not just "some bars exist".
   Check(n == MLQUANTAI_CRT_V1_LOOKBACK_BARS,
         StringFormat("window reaches the full frozen LOOKBACK_BARS size when history is available (got %d, want %d) - "
                       "if this fails, the chart genuinely doesn't have %d bars of trigger-timeframe history yet",
                       n, MLQUANTAI_CRT_V1_LOOKBACK_BARS, MLQUANTAI_CRT_V1_LOOKBACK_BARS));
}

void Test_Window_RealPipeline_DeterministicAcrossRebuilds()
{
   Print("--- trigger_tf_recent[]: identical across repeated FeatureEngine_BuildContext() calls for the same anchor ---");

   MarketContext ctx1 = FeatureEngine_BuildContext();
   MarketContext ctx2 = FeatureEngine_BuildContext();
   if(!FeatureEngine_IsReady(ctx1) || !FeatureEngine_IsReady(ctx2) || ctx1.anchor_bar_time != ctx2.anchor_bar_time)
   {
      Check(false, "could not get two ready contexts for the same anchor bar to compare (bar likely rolled over mid-test)");
      return;
   }

   Check(ctx1.context_hash == ctx2.context_hash,
         "context_hash (which now includes trigger_tf_recent[]) is identical across two rebuilds of the same anchor bar");

   int n1 = ArraySize(ctx1.trigger_tf_recent), n2 = ArraySize(ctx2.trigger_tf_recent);
   bool windowsMatch = (n1 == n2);
   for(int i = 0; i < MathMin(n1, n2); i++)
      if(ctx1.trigger_tf_recent[i].time != ctx2.trigger_tf_recent[i].time ||
         ctx1.trigger_tf_recent[i].close != ctx2.trigger_tf_recent[i].close)
         windowsMatch = false;
   Check(windowsMatch, "the raw trigger_tf_recent[] content itself (not just the hash) is identical across rebuilds");
}

//=====================================================================
// Pure-function tests - hand-built MqlRates, no live/broker dependency
//=====================================================================

void Test_HashPayload_ChangesWhenWindowContentDiffers()
{
   Print("--- context_hash: changes when trigger_tf_recent[] content differs, all else equal ---");

   MarketContext ctxA, ctxB;
   MarketContext_Init(ctxA);
   MarketContext_Init(ctxB);
   ctxA.instrument_id = "XAUUSD"; ctxB.instrument_id = "XAUUSD";
   ctxA.broker_symbol = "XAUUSD"; ctxB.broker_symbol = "XAUUSD";
   ctxA.trigger_timeframe = "M5"; ctxB.trigger_timeframe = "M5";
   ctxA.anchor_bar_time = D'2026.08.14 12:00:00'; ctxB.anchor_bar_time = D'2026.08.14 12:00:00';

   MqlRates barA; MakeBar(barA, D'2026.08.14 12:00:00', 2400.0, 2401.0, 2399.0, 2400.5, 100, 20);
   MqlRates barB; MakeBar(barB, D'2026.08.14 12:00:00', 2400.0, 2401.0, 2399.0, 2405.5, 100, 20); // different close

   ArrayResize(ctxA.trigger_tf_recent, 1); ctxA.trigger_tf_recent[0] = barA;
   ArrayResize(ctxB.trigger_tf_recent, 1); ctxB.trigger_tf_recent[0] = barB;

   Check(MarketContext_HashPayload(ctxA) != MarketContext_HashPayload(ctxB),
         "two contexts identical except for one trigger_tf_recent[] bar's close price hash differently");
}

void Test_HashPayload_StableWhenWindowContentIdentical()
{
   Print("--- context_hash: identical when trigger_tf_recent[] content is identical ---");

   MarketContext ctxA, ctxB;
   MarketContext_Init(ctxA);
   MarketContext_Init(ctxB);
   ctxA.instrument_id = "XAUUSD"; ctxB.instrument_id = "XAUUSD";
   ctxA.broker_symbol = "XAUUSD"; ctxB.broker_symbol = "XAUUSD";
   ctxA.trigger_timeframe = "M5"; ctxB.trigger_timeframe = "M5";
   ctxA.anchor_bar_time = D'2026.08.14 12:00:00'; ctxB.anchor_bar_time = D'2026.08.14 12:00:00';

   MqlRates bar1; MakeBar(bar1, D'2026.08.14 11:55:00', 2398.0, 2399.0, 2397.0, 2398.5, 90, 18);
   MqlRates bar2; MakeBar(bar2, D'2026.08.14 12:00:00', 2400.0, 2401.0, 2399.0, 2400.5, 100, 20);

   ArrayResize(ctxA.trigger_tf_recent, 2); ctxA.trigger_tf_recent[0] = bar1; ctxA.trigger_tf_recent[1] = bar2;
   ArrayResize(ctxB.trigger_tf_recent, 2); ctxB.trigger_tf_recent[0] = bar1; ctxB.trigger_tf_recent[1] = bar2;

   Check(MarketContext_HashPayload(ctxA) == MarketContext_HashPayload(ctxB),
         "two contexts with byte-identical trigger_tf_recent[] content hash identically");
}

void Test_RatesArray_JsonRoundTrip_PureFunction()
{
   Print("--- trigger_tf_recent[] JSON round-trip (no live/broker dependency) ---");

   MqlRates original[3];
   MakeBar(original[0], D'2026.08.14 11:50:00', 2397.0, 2398.5, 2396.5, 2398.0, 80, 15);
   MakeBar(original[1], D'2026.08.14 11:55:00', 2398.0, 2399.0, 2397.0, 2398.5, 90, 18);
   MakeBar(original[2], D'2026.08.14 12:00:00', 2400.0, 2401.0, 2399.0, 2400.5, 100, 20);

   string json = MarketContext_RatesArrayToJson(original);
   MqlRates parsed[];
   int n = MarketContext_RatesArrayFromJson(json, parsed);

   Check(n == 3, StringFormat("round-trip preserves element count (got %d, want 3)", n));
   if(n != 3) return;

   bool allMatch = true;
   for(int i = 0; i < 3; i++)
   {
      if(parsed[i].time != original[i].time) allMatch = false;
      if(MathAbs(parsed[i].open  - original[i].open)  > 0.00001) allMatch = false;
      if(MathAbs(parsed[i].high  - original[i].high)  > 0.00001) allMatch = false;
      if(MathAbs(parsed[i].low   - original[i].low)   > 0.00001) allMatch = false;
      if(MathAbs(parsed[i].close - original[i].close) > 0.00001) allMatch = false;
      if(parsed[i].tick_volume != original[i].tick_volume) allMatch = false;
      if(parsed[i].spread != original[i].spread) allMatch = false;
   }
   Check(allMatch, "every field of every element round-trips exactly through MarketContext_RatesArrayToJson/FromJson");
}

void Test_Window_ReplayFromPersistedPayload()
{
   Print("--- trigger_tf_recent[]: persisted MARKET_CONTEXT_READY payload replays identically from a fresh handle ---");

   MarketContext ctx;
   MarketContext_Init(ctx);
   ctx.instrument_id = "XAUUSD";
   ctx.broker_symbol = "XAUUSD";
   ctx.trigger_timeframe = "M5";
   ctx.anchor_bar_time = D'2026.08.14 12:00:00';

   MqlRates window[3];
   MakeBar(window[0], D'2026.08.14 11:50:00', 2397.0, 2398.5, 2396.5, 2398.0, 80, 15);
   MakeBar(window[1], D'2026.08.14 11:55:00', 2398.0, 2399.0, 2397.0, 2398.5, 90, 18);
   MakeBar(window[2], D'2026.08.14 12:00:00', 2400.0, 2401.0, 2399.0, 2400.5, 100, 20);
   ArrayResize(ctx.trigger_tf_recent, 3);
   for(int i = 0; i < 3; i++) ctx.trigger_tf_recent[i] = window[i];

   ctx.context_event_id = Ids_ContextEventId(ctx.instrument_id, ctx.trigger_timeframe, ctx.anchor_bar_time);
   ctx.context_hash = MarketContext_ComputeHash(ctx);

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   if(!EventStore_Open(TEST_EVENT_STORE_FILE))
   {
      Check(false, "could not open a fresh scratch event store");
      return;
   }
   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY),
                         "market context built (CRT context window test)", MarketContext_ToJsonFragment(ctx));
   EventStore_Close();

   string lines[];
   int lineCount = EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
   Check(lineCount >= 1, "MARKET_CONTEXT_READY was durably written and re-readable from a fresh handle");
   if(lineCount < 1) return;
   string line = lines[lineCount - 1];

   string replayedContextHash = EventSerializer_GetStr(line, "context_hash");
   Check(replayedContextHash == ctx.context_hash, "replayed context_hash (including the window's contribution) matches the value computed before persisting");

   string windowJson = ExtractJsonArray(line, "trigger_tf_recent");
   MqlRates replayedWindow[];
   int replayedCount = MarketContext_RatesArrayFromJson(windowJson, replayedWindow);
   Check(replayedCount == 3, StringFormat("replayed trigger_tf_recent[] has the same element count as the original (expected 3, got %d)", replayedCount));

   bool allMatch = (replayedCount == 3);
   for(int i = 0; i < MathMin(replayedCount, 3); i++)
   {
      if(replayedWindow[i].time != window[i].time) allMatch = false;
      if(MathAbs(replayedWindow[i].close - window[i].close) > 0.00001) allMatch = false;
   }
   Check(allMatch, "replayed trigger_tf_recent[] round-trips every element exactly through the persisted JSON payload");
}

//=====================================================================
// CRT_V1 domain model utilities (Strategies/MLQuantAI_CRT_V1_Contract.mqh)
//=====================================================================

void Test_ReasonLabels_AscendingBitOrder()
{
   Print("--- CRT_ReasonLabelsFromMask: ascending bit-order, frozen label vocabulary ---");

   ulong mask = CRT_REASON_BIT_SWEEP_LOW | CRT_REASON_BIT_CLOSE_BACK_INSIDE |
                CRT_REASON_BIT_MSS_CONFIRMED | CRT_REASON_BIT_FVG_FOUND;
   string labels[];
   CRT_ReasonLabelsFromMask(mask, labels);

   Check(ArraySize(labels) == 4, StringFormat("exactly 4 labels for 4 set bits (got %d)", ArraySize(labels)));
   if(ArraySize(labels) == 4)
   {
      Check(labels[0] == "liquidity_sweep_low",   "bit 0 label first (ascending order)");
      Check(labels[1] == "close_back_inside",     "bit 2 label second");
      Check(labels[2] == "mss_confirmed",         "bit 3 label third");
      Check(labels[3] == "fvg_found",             "bit 4 label fourth");
   }

   string emptyLabels[];
   CRT_ReasonLabelsFromMask(0, emptyLabels);
   Check(ArraySize(emptyLabels) == 0, "zero mask produces zero labels");

   string allLabels[];
   CRT_ReasonLabelsFromMask(0xFF, allLabels);
   Check(ArraySize(allLabels) == 8 && allLabels[7] == "news_risk_near",
         "all 8 bits set produces all 8 labels, bit 7 last");
}

void Test_DetectorHash_DeterministicAndSensitiveToInputs()
{
   Print("--- CRT_DetectorHash: deterministic, changes only when inputs change ---");

   string h1 = CRT_DetectorHash("XAUUSD", "M5", D'2026.08.14 12:00:00', ORDER_TYPE_BUY,
                                 2395.0, 2398.0, D'2026.08.14 12:00:00', "FVG", 2399.0, 2397.5,
                                 CRT_REASON_BIT_SWEEP_LOW | CRT_REASON_BIT_CLOSE_BACK_INSIDE |
                                 CRT_REASON_BIT_MSS_CONFIRMED | CRT_REASON_BIT_FVG_FOUND, 2);
   string h1Again = CRT_DetectorHash("XAUUSD", "M5", D'2026.08.14 12:00:00', ORDER_TYPE_BUY,
                                 2395.0, 2398.0, D'2026.08.14 12:00:00', "FVG", 2399.0, 2397.5,
                                 CRT_REASON_BIT_SWEEP_LOW | CRT_REASON_BIT_CLOSE_BACK_INSIDE |
                                 CRT_REASON_BIT_MSS_CONFIRMED | CRT_REASON_BIT_FVG_FOUND, 2);
   Check(h1 != "" && h1 == h1Again, "identical inputs produce the identical, non-empty detector_hash");

   string h2 = CRT_DetectorHash("XAUUSD", "M5", D'2026.08.14 12:00:00', ORDER_TYPE_BUY,
                                 2395.0, 2398.0, D'2026.08.14 12:00:00', "OB", 2399.0, 2397.5, // resolved_zone_kind changed
                                 CRT_REASON_BIT_SWEEP_LOW | CRT_REASON_BIT_CLOSE_BACK_INSIDE |
                                 CRT_REASON_BIT_MSS_CONFIRMED | CRT_REASON_BIT_OB_FOUND, 2);
   Check(h1 != h2, "changing resolved_zone_kind (FVG -> OB) changes detector_hash");

   string h3 = CRT_DetectorHash("XAUUSD", "M5", D'2026.08.14 12:00:00', ORDER_TYPE_SELL, // side changed
                                 2395.0, 2398.0, D'2026.08.14 12:00:00', "FVG", 2399.0, 2397.5,
                                 CRT_REASON_BIT_SWEEP_LOW | CRT_REASON_BIT_CLOSE_BACK_INSIDE |
                                 CRT_REASON_BIT_MSS_CONFIRMED | CRT_REASON_BIT_FVG_FOUND, 2);
   Check(h1 != h3, "changing side changes detector_hash");
}

void Test_CRTDetectionResult_InitDefaults()
{
   Print("--- CRTDetectionResult_Init: defaults ---");

   CRTDetectionResult r;
   CRTDetectionResult_Init(r);

   Check(r.detected == false, "detected defaults to false");
   Check(r.resolved_zone_kind == "", "resolved_zone_kind defaults to empty");
   Check(r.reason_mask == 0, "reason_mask defaults to 0");
   Check(ArraySize(r.reason_labels) == 0, "reason_labels[] defaults to empty");
   Check(r.detector_hash == "", "detector_hash defaults to empty");
}

void OnStart()
{
   Print("=== MLQuantAI Test: Phase B B5 Commit 2 - CRT Context Window ===");

   Test_Init();
   Test_Window_RealPipeline_Rules();
   Test_Window_RealPipeline_DeterministicAcrossRebuilds();

   Test_HashPayload_ChangesWhenWindowContentDiffers();
   Test_HashPayload_StableWhenWindowContentIdentical();
   Test_RatesArray_JsonRoundTrip_PureFunction();
   Test_Window_ReplayFromPersistedPayload();

   Test_ReasonLabels_AscendingBitOrder();
   Test_DetectorHash_DeterministicAndSensitiveToInputs();
   Test_CRTDetectionResult_InitDefaults();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   Print(g_TestsPassed == g_TestsRun ? "ALL PASS." : "FAILURES ABOVE.");
}
