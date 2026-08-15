//+------------------------------------------------------------------+
//| MLQuantAI_Test_B6_3_HashContract.mq5                              |
//| Phase B B6.3 DoD: consolidated hash contract freeze + structured  |
//| rejection-reason classification. Two independent concerns:        |
//|  1. Exhaustive inclusion/exclusion mutation sweeps for            |
//|     context_hash and detector_hash, matching the rigor            |
//|     candidate_hash already has in Test_CandidateProjection.mq5.   |
//|     Pure-function tests - no event store I/O.                     |
//|  2. CandidateProjection_ClassifyReason() - a NEW, additive-only    |
//|     structured category on top of the existing free-text reason   |
//|     strings. Tested both directly (against the real pure          |
//|     validator functions B6.1 already ships) and end-to-end        |
//|     (through RebuildFromFile, for the categories only reachable    |
//|     via the two-pass referential-integrity path or the store       |
//|     validator gate).                                              |
//| See Docs/PhaseB_B6_3_HashContractSpec.md for the frozen field      |
//| lists this file asserts against.                                  |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_B6_3_HashContract.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void MakeBar(MqlRates &r, datetime t, double open, double high, double low, double close, long tickVolume, int spread)
{
   ZeroMemory(r);
   r.time = t; r.open = open; r.high = high; r.low = low; r.close = close;
   r.tick_volume = tickVolume; r.spread = spread;
}

#define PERIOD_SEC_M5 300

// Replaces "key":"oldvalue" with "key":"newValue" (string-typed field) -
// same helper Test_CandidateProjection.mq5 already established, reused
// here so tampers exercise the REAL persisted line format rather than a
// hand-typed guess at the JSON shape (EventSerializer_ParseLifecycle
// looks for "seq", not "sequence_number", among other exact key names
// this avoids having to get right by hand).
string TamperStringField(string line, string key, string newValue)
{
   string needle = "\"" + key + "\":\"";
   int p = StringFind(line, needle);
   if(p < 0) return line;
   int start = p + StringLen(needle);
   int n = StringLen(line);
   int end = start;
   while(end < n && StringGetCharacter(line, end) != '"') end++;
   return StringSubstr(line, 0, start) + newValue + StringSubstr(line, end);
}

//=====================================================================
// Part 1: context_hash inclusion/exclusion mutation sweep
//=====================================================================

// A fully-populated, valid baseline MarketContext - every field the
// spec's INCLUDED table names gets a distinct non-zero/non-empty value
// so a mutation is unambiguous, and every EXCLUDED field is also
// populated (not left at Init() defaults) so mutating it is a genuine
// change to test against, not a no-op on an already-empty field.
void BuildBaselineContext(MarketContext &ctx)
{
   MarketContext_Init(ctx);
   ctx.context_event_id = "CTX_baseline";
   ctx.instrument_id = "XAUUSD";
   ctx.broker_symbol = "XAUUSDm";
   ctx.trigger_timeframe = "M5";
   ctx.anchor_bar_time = D'2026.01.01 12:00:00';

   MakeBar(ctx.m5_bar,  D'2026.01.01 12:00:00', 100.0, 100.5, 99.5, 100.2, 100, 20);
   MakeBar(ctx.m15_bar, D'2026.01.01 12:00:00', 100.0, 101.0, 99.0, 100.3, 300, 20);
   MakeBar(ctx.h1_bar,  D'2026.01.01 12:00:00', 100.0, 102.0, 98.0, 100.5, 1200, 20);
   MakeBar(ctx.h4_bar,  D'2026.01.01 12:00:00', 100.0, 103.0, 97.0, 100.8, 4800, 20);

   ArrayResize(ctx.trigger_tf_recent, 3);
   MakeBar(ctx.trigger_tf_recent[0], D'2026.01.01 11:50:00', 99.0, 99.5, 98.5, 99.2, 100, 20);
   MakeBar(ctx.trigger_tf_recent[1], D'2026.01.01 11:55:00', 99.2, 99.8, 98.8, 99.6, 100, 20);
   MakeBar(ctx.trigger_tf_recent[2], D'2026.01.01 12:00:00', 99.6, 100.5, 99.5, 100.2, 100, 20);

   ctx.bid_at_anchor = 100.19;
   ctx.ask_at_anchor = 100.21;
   ctx.spread_points_at_anchor = 2.0;

   ctx.atr_m15 = 1.5;
   ctx.adx_m15 = 25.0;
   ctx.ema_slope_m15 = 0.05;

   ctx.pdh = 110.0;
   ctx.pdl = 90.0;
   ctx.asian_range_high = 105.0;
   ctx.asian_range_low  = 95.0;

   ctx.session_id = "LONDON";
   ctx.is_kill_zone = true;

   ctx.news_count = 2;
   ctx.max_news_impact = 3;
   ctx.nearest_news_minutes = 15;
   ctx.news_decision_hash = "baseline_news_decision_hash";
   ctx.news_snapshot_identity = "baseline_news_snapshot_identity";

   ctx.account.balance = 10000.0;
   ctx.account.equity = 10050.0;
   ctx.symbol_spec.digits = 2;
   ctx.symbol_spec.point = 0.01;
}

void Test_ContextHash_IncludedFieldsMoveHash()
{
   Print("--- context_hash: every INCLUDED field change moves the hash ---");
   MarketContext baseline; BuildBaselineContext(baseline);
   string baseHash = MarketContext_ComputeHash(baseline);
   Check(baseHash != "", "sanity: baseline context_hash computed");

   MarketContext m;

   m = baseline; m.instrument_id = "EURUSD";
   Check(MarketContext_ComputeHash(m) != baseHash, "instrument_id change moves context_hash");

   m = baseline; m.broker_symbol = "OTHER_BROKER_SYM";
   Check(MarketContext_ComputeHash(m) != baseHash, "broker_symbol change moves context_hash");

   m = baseline; m.trigger_timeframe = "M15";
   Check(MarketContext_ComputeHash(m) != baseHash, "trigger_timeframe change moves context_hash");

   m = baseline; m.anchor_bar_time = baseline.anchor_bar_time + PERIOD_SEC_M5;
   Check(MarketContext_ComputeHash(m) != baseHash, "anchor_bar_time change moves context_hash");

   m = baseline; m.m5_bar.close += 0.01;
   Check(MarketContext_ComputeHash(m) != baseHash, "m5_bar change moves context_hash");

   m = baseline; m.m15_bar.close += 0.01;
   Check(MarketContext_ComputeHash(m) != baseHash, "m15_bar change moves context_hash");

   m = baseline; m.h1_bar.close += 0.01;
   Check(MarketContext_ComputeHash(m) != baseHash, "h1_bar change moves context_hash");

   m = baseline; m.h4_bar.close += 0.01;
   Check(MarketContext_ComputeHash(m) != baseHash, "h4_bar change moves context_hash");

   m = baseline; m.trigger_tf_recent[1].close += 0.01;
   Check(MarketContext_ComputeHash(m) != baseHash, "trigger_tf_recent[] content change moves context_hash");

   m = baseline; m.bid_at_anchor += 0.01;
   Check(MarketContext_ComputeHash(m) != baseHash, "bid_at_anchor change moves context_hash");

   m = baseline; m.ask_at_anchor += 0.01;
   Check(MarketContext_ComputeHash(m) != baseHash, "ask_at_anchor change moves context_hash");

   m = baseline; m.spread_points_at_anchor += 1.0;
   Check(MarketContext_ComputeHash(m) != baseHash, "spread_points_at_anchor change moves context_hash");

   m = baseline; m.atr_m15 += 0.1;
   Check(MarketContext_ComputeHash(m) != baseHash, "atr_m15 change moves context_hash");

   m = baseline; m.adx_m15 += 1.0;
   Check(MarketContext_ComputeHash(m) != baseHash, "adx_m15 change moves context_hash");

   m = baseline; m.ema_slope_m15 += 0.01;
   Check(MarketContext_ComputeHash(m) != baseHash, "ema_slope_m15 change moves context_hash");

   m = baseline; m.pdh += 1.0;
   Check(MarketContext_ComputeHash(m) != baseHash, "pdh change moves context_hash");

   m = baseline; m.pdl += 1.0;
   Check(MarketContext_ComputeHash(m) != baseHash, "pdl change moves context_hash");

   m = baseline; m.asian_range_high += 1.0;
   Check(MarketContext_ComputeHash(m) != baseHash, "asian_range_high change moves context_hash");

   m = baseline; m.asian_range_low += 1.0;
   Check(MarketContext_ComputeHash(m) != baseHash, "asian_range_low change moves context_hash");

   m = baseline; m.session_id = "NEW_YORK";
   Check(MarketContext_ComputeHash(m) != baseHash, "session_id change moves context_hash");

   m = baseline; m.is_kill_zone = !baseline.is_kill_zone;
   Check(MarketContext_ComputeHash(m) != baseHash, "is_kill_zone change moves context_hash");

   m = baseline; m.news_decision_hash = "OTHER_NEWS_DECISION_HASH";
   Check(MarketContext_ComputeHash(m) != baseHash, "news_decision_hash change moves context_hash");
}

void Test_ContextHash_ExcludedFieldsDoNotMoveHash()
{
   Print("--- context_hash: whitelist of fields that must NOT move the hash ---");
   MarketContext baseline; BuildBaselineContext(baseline);
   string baseHash = MarketContext_ComputeHash(baseline);
   MarketContext m;

   m = baseline; m.context_event_id = "OTHER_CTX_EVENT_ID";
   Check(MarketContext_ComputeHash(m) == baseHash, "context_event_id change does NOT move context_hash");

   m = baseline; m.market_context_schema_version = "OTHER_SCHEMA";
   Check(MarketContext_ComputeHash(m) == baseHash, "market_context_schema_version change does NOT move context_hash");

   m = baseline; m.feature_schema_version = "OTHER_SCHEMA";
   Check(MarketContext_ComputeHash(m) == baseHash, "feature_schema_version change does NOT move context_hash");

   m = baseline; m.news_schema_version = "OTHER_SCHEMA";
   Check(MarketContext_ComputeHash(m) == baseHash, "news_schema_version change does NOT move context_hash");

   m = baseline; m.news_count += 5;
   Check(MarketContext_ComputeHash(m) == baseHash, "news_count change does NOT move context_hash (redundant with news_decision_hash)");

   m = baseline; m.max_news_impact += 1;
   Check(MarketContext_ComputeHash(m) == baseHash, "max_news_impact change does NOT move context_hash (redundant with news_decision_hash)");

   m = baseline; m.nearest_news_minutes += 5;
   Check(MarketContext_ComputeHash(m) == baseHash, "nearest_news_minutes change does NOT move context_hash (redundant with news_decision_hash)");

   m = baseline; m.news_snapshot_identity = "OTHER_NEWS_SNAPSHOT_IDENTITY";
   Check(MarketContext_ComputeHash(m) == baseHash, "news_snapshot_identity change does NOT move context_hash");

   m = baseline; m.account.balance += 1000.0;
   Check(MarketContext_ComputeHash(m) == baseHash, "account.balance change does NOT move context_hash");

   m = baseline; m.account.equity += 1000.0;
   Check(MarketContext_ComputeHash(m) == baseHash, "account.equity change does NOT move context_hash");

   m = baseline; m.symbol_spec.digits = 5;
   Check(MarketContext_ComputeHash(m) == baseHash, "symbol_spec.digits change does NOT move context_hash");

   m = baseline; m.symbol_spec.point = 0.00001;
   Check(MarketContext_ComputeHash(m) == baseHash, "symbol_spec.point change does NOT move context_hash");
}

//=====================================================================
// Part 2: detector_hash inclusion/exclusion mutation sweep
//=====================================================================

string BaselineDetectorHash()
{
   return CRT_DetectorHash("XAUUSD", "M5", D'2026.01.01 12:00:00',
                            ORDER_TYPE_BUY, 99.50, 104.50,
                            D'2026.01.01 12:00:00', "FVG",
                            103.50, 102.30, 0x1D /* SWEEP_LOW|CLOSE_BACK_INSIDE|MSS_CONFIRMED|FVG_FOUND */, 2);
}

void Test_DetectorHash_IncludedFieldsMoveHash()
{
   Print("--- detector_hash: every INCLUDED field change moves the hash ---");
   string baseHash = BaselineDetectorHash();
   Check(baseHash != "", "sanity: baseline detector_hash computed");

   Check(CRT_DetectorHash("EURUSD", "M5", D'2026.01.01 12:00:00', ORDER_TYPE_BUY, 99.50, 104.50,
         D'2026.01.01 12:00:00', "FVG", 103.50, 102.30, 0x1D, 2) != baseHash,
         "instrumentId change moves detector_hash");

   Check(CRT_DetectorHash("XAUUSD", "M15", D'2026.01.01 12:00:00', ORDER_TYPE_BUY, 99.50, 104.50,
         D'2026.01.01 12:00:00', "FVG", 103.50, 102.30, 0x1D, 2) != baseHash,
         "triggerTimeframe change moves detector_hash");

   Check(CRT_DetectorHash("XAUUSD", "M5", D'2026.01.01 12:05:00', ORDER_TYPE_BUY, 99.50, 104.50,
         D'2026.01.01 12:00:00', "FVG", 103.50, 102.30, 0x1D, 2) != baseHash,
         "setupAnchorBarTime change moves detector_hash");

   Check(CRT_DetectorHash("XAUUSD", "M5", D'2026.01.01 12:00:00', ORDER_TYPE_SELL, 99.50, 104.50,
         D'2026.01.01 12:00:00', "FVG", 103.50, 102.30, 0x1D, 2) != baseHash,
         "side change moves detector_hash");

   Check(CRT_DetectorHash("XAUUSD", "M5", D'2026.01.01 12:00:00', ORDER_TYPE_BUY, 99.60, 104.50,
         D'2026.01.01 12:00:00', "FVG", 103.50, 102.30, 0x1D, 2) != baseHash,
         "sweptLevel change moves detector_hash");

   Check(CRT_DetectorHash("XAUUSD", "M5", D'2026.01.01 12:00:00', ORDER_TYPE_BUY, 99.50, 104.60,
         D'2026.01.01 12:00:00', "FVG", 103.50, 102.30, 0x1D, 2) != baseHash,
         "mssConfirmationPrice change moves detector_hash");

   Check(CRT_DetectorHash("XAUUSD", "M5", D'2026.01.01 12:00:00', ORDER_TYPE_BUY, 99.50, 104.50,
         D'2026.01.01 12:05:00', "FVG", 103.50, 102.30, 0x1D, 2) != baseHash,
         "mssConfirmationBarTime change moves detector_hash");

   Check(CRT_DetectorHash("XAUUSD", "M5", D'2026.01.01 12:00:00', ORDER_TYPE_BUY, 99.50, 104.50,
         D'2026.01.01 12:00:00', "OB", 103.50, 102.30, 0x1D, 2) != baseHash,
         "resolvedZoneKind change moves detector_hash");

   Check(CRT_DetectorHash("XAUUSD", "M5", D'2026.01.01 12:00:00', ORDER_TYPE_BUY, 99.50, 104.50,
         D'2026.01.01 12:00:00', "FVG", 103.60, 102.30, 0x1D, 2) != baseHash,
         "resolvedZoneHigh change moves detector_hash");

   Check(CRT_DetectorHash("XAUUSD", "M5", D'2026.01.01 12:00:00', ORDER_TYPE_BUY, 99.50, 104.50,
         D'2026.01.01 12:00:00', "FVG", 103.50, 102.40, 0x1D, 2) != baseHash,
         "resolvedZoneLow change moves detector_hash");

   Check(CRT_DetectorHash("XAUUSD", "M5", D'2026.01.01 12:00:00', ORDER_TYPE_BUY, 99.50, 104.50,
         D'2026.01.01 12:00:00', "FVG", 103.50, 102.30, 0x1D ^ 0x40, 2) != baseHash,
         "reasonMask change moves detector_hash");
}

void Test_DetectorHash_DigitsAffectsFormatting()
{
   Print("--- detector_hash: digits is a formatting multiplier on price fields, not an excluded field ---");
   // Same underlying values, different digits -> different DoubleToString
   // rendering of sweptLevel/mssConfirmationPrice/resolvedZoneHigh/
   // resolvedZoneLow -> the hash MUST move. This is the opposite of an
   // "excluded field" claim - see Docs/PhaseB_B6_3_HashContractSpec.md's
   // note on why digits isn't listed as an independently-excluded row.
   string hashAt2Digits = BaselineDetectorHash();
   string hashAt4Digits = CRT_DetectorHash("XAUUSD", "M5", D'2026.01.01 12:00:00', ORDER_TYPE_BUY, 99.50, 104.50,
                                            D'2026.01.01 12:00:00', "FVG", 103.50, 102.30, 0x1D, 4);
   Check(hashAt2Digits != hashAt4Digits, "digits change moves detector_hash (it reformats the already-included price fields)");

   // But the SAME digits, called twice, is still fully deterministic.
   string hashAt2DigitsAgain = BaselineDetectorHash();
   Check(hashAt2Digits == hashAt2DigitsAgain, "detector_hash is deterministic when digits is held constant");
}

//=====================================================================
// Part 3: structured rejection-reason classification
//=====================================================================

void Test_ClassifyReason_DirectValidatorOutputs()
{
   Print("--- CandidateProjection_ClassifyReason: classifies the REAL validator functions' own output ---");

   Check(CandidateProjection_ClassifyReason("") == CANDPROJ_REASON_NONE, "empty string classifies as NONE");
   Check(CandidateProjection_ClassifyReason("applied - new candidate registered") == CANDPROJ_REASON_APPLIED,
         "the real success string classifies as APPLIED");

   string schemaErr1 = CandidateProjection_ValidateSchemaVersion("");
   Check(CandidateProjection_ClassifyReason(schemaErr1) == CANDPROJ_REASON_SCHEMA_VERSION,
         "ValidateSchemaVersion('') classifies as SCHEMA_VERSION");
   string schemaErr2 = CandidateProjection_ValidateSchemaVersion("GARBAGE_VERSION");
   Check(CandidateProjection_ClassifyReason(schemaErr2) == CANDPROJ_REASON_SCHEMA_VERSION,
         "ValidateSchemaVersion(unrecognized) classifies as SCHEMA_VERSION");

   string fieldsErr = CandidateProjection_ValidateRequiredFields("", "CTX1", "HASH1", "CANDHASH1", "DETHASH1");
   Check(CandidateProjection_ClassifyReason(fieldsErr) == CANDPROJ_REASON_MISSING_REQUIRED_FIELD,
         "ValidateRequiredFields(missing root_event_id) classifies as MISSING_REQUIRED_FIELD");
   string fieldsErr2 = CandidateProjection_ValidateRequiredFields("ROOT1", "CTX1", "", "CANDHASH1", "DETHASH1");
   Check(CandidateProjection_ClassifyReason(fieldsErr2) == CANDPROJ_REASON_MISSING_REQUIRED_FIELD,
         "ValidateRequiredFields(missing context_hash) classifies as MISSING_REQUIRED_FIELD");

   ENUM_ORDER_TYPE side;
   string sideErr = CandidateProjection_ValidateSide("GARBAGE", side);
   Check(CandidateProjection_ClassifyReason(sideErr) == CANDPROJ_REASON_INVALID_SIDE,
         "ValidateSide(garbage) classifies as INVALID_SIDE");

   string timeErr1 = CandidateProjection_ValidateTimeIntegrity(0, 0, 0);
   Check(CandidateProjection_ClassifyReason(timeErr1) == CANDPROJ_REASON_TIME_INTEGRITY,
         "ValidateTimeIntegrity(zero times) classifies as TIME_INTEGRITY");
   string timeErr2 = CandidateProjection_ValidateTimeIntegrity(D'2026.01.01 12:00:00', D'2026.01.01 11:00:00', 5);
   Check(CandidateProjection_ClassifyReason(timeErr2) == CANDPROJ_REASON_TIME_INTEGRITY,
         "ValidateTimeIntegrity(expiry before anchor) classifies as TIME_INTEGRITY");

   string numErr1 = CandidateProjection_ValidateNumericalIntegrity(100.0, 99.0, 98.0, ORDER_TYPE_BUY);
   Check(CandidateProjection_ClassifyReason(numErr1) == CANDPROJ_REASON_NUMERICAL_INTEGRITY,
         "ValidateNumericalIntegrity(inverted BUY SL/TP) classifies as NUMERICAL_INTEGRITY");
   string numErr2 = CandidateProjection_ValidateNumericalIntegrity(0.0, 99.0, 101.0, ORDER_TYPE_BUY);
   Check(CandidateProjection_ClassifyReason(numErr2) == CANDPROJ_REASON_NUMERICAL_INTEGRITY,
         "ValidateNumericalIntegrity(zero price) classifies as NUMERICAL_INTEGRITY");

   ulong badMask = 0x03; // both SWEEP_LOW and SWEEP_HIGH set - violates the XOR invariant
   string reasons[];
   string reasonErr = CandidateProjection_ValidateReasonConsistency(badMask, reasons);
   Check(CandidateProjection_ClassifyReason(reasonErr) == CANDPROJ_REASON_REASON_CONSISTENCY,
         "ValidateReasonConsistency(XOR violation) classifies as REASON_CONSISTENCY");
}

void Test_ClassifyReason_EndToEnd_ApplyLine()
{
   Print("--- CandidateProjection_ClassifyReason: end-to-end via ApplyLine/ApplyLineWithContext/RebuildFromFile ---");

   string reason;

   // MALFORMED_LINE: an unparsable line.
   Check(!CandidateProjection_ApplyLine("not even json", reason), "sanity: garbage line rejected");
   Check(CandidateProjection_ClassifyReason(reason) == CANDPROJ_REASON_MALFORMED_LINE,
         "unparsable line classifies as MALFORMED_LINE");

   // SKIPPED_NOT_RELEVANT: a real, valid, non-CANDIDATE_CREATED line.
   CandidateProjection_Reset();
   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   EventStore_Open(TEST_EVENT_STORE_FILE);
   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", "\"instrument_id\":\"XAUUSD\"");
   EventStore_Close();
   string lines[];
   EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
   Check(ArraySize(lines) == 1, "sanity: one context line written");
   Check(CandidateProjection_ApplyLine(lines[0], reason), "sanity: non-CANDIDATE_CREATED line is a no-op success");
   Check(CandidateProjection_ClassifyReason(reason) == CANDPROJ_REASON_SKIPPED_NOT_RELEVANT,
         "a real MARKET_CONTEXT_READY line classifies as SKIPPED_NOT_RELEVANT");

   // EMPTY_CANDIDATE_ID / NOT_GENESIS_SHAPE / COLLISION / SKIPPED_DUPLICATE /
   // ORPHAN_CONTEXT / CONTEXT_HASH_MISMATCH / STORE_VALIDATION_FAILED: all
   // require a full CANDIDATE_CREATED line, easiest built via the real B5
   // pipeline (same pattern Test_CandidateProjection.mq5 already proved).
   CandidateProjection_Reset();
   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   EventStore_Open(TEST_EVENT_STORE_FILE);
   MarketContext ctx; BuildBaselineContext(ctx);
   ctx.context_event_id = "CTX_e2e";
   ctx.context_hash = "e2e_context_hash";
   ArrayResize(ctx.trigger_tf_recent, 64);
   for(int i = 0; i < 59; i++)
      MakeBar(ctx.trigger_tf_recent[i], D'2026.02.01 00:00:00' + i * PERIOD_SEC_M5, 105.00, 105.20, 104.80, 105.00, 100, 20);
   MakeBar(ctx.trigger_tf_recent[59], D'2026.02.01 00:00:00' + 59 * PERIOD_SEC_M5, 100.80, 100.90, 99.50,  100.50, 100, 20);
   MakeBar(ctx.trigger_tf_recent[60], D'2026.02.01 00:00:00' + 60 * PERIOD_SEC_M5, 100.50, 101.50, 100.40, 101.40, 100, 20);
   MakeBar(ctx.trigger_tf_recent[61], D'2026.02.01 00:00:00' + 61 * PERIOD_SEC_M5, 101.40, 102.50, 101.30, 102.40, 100, 20);
   MakeBar(ctx.trigger_tf_recent[62], D'2026.02.01 00:00:00' + 62 * PERIOD_SEC_M5, 102.40, 103.50, 102.30, 103.40, 100, 20);
   MakeBar(ctx.trigger_tf_recent[63], D'2026.02.01 00:00:00' + 63 * PERIOD_SEC_M5, 103.40, 104.60, 103.30, 104.50, 100, 20);
   ctx.anchor_bar_time = ctx.trigger_tf_recent[63].time;
   ctx.pdl = 100.00; ctx.pdh = 110.00;
   ctx.symbol_spec.digits = 2; ctx.symbol_spec.point = 0.01;
   ctx.instrument_id = "XAUUSD"; ctx.trigger_timeframe = "M5";

   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx));

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(r.detected, "sanity: e2e fixture detects");
   TradeCandidate c;
   Check(CRT_ToTradeCandidate(ctx, r, c), "sanity: e2e fixture maps to candidate");
   Check(CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits), "sanity: e2e fixture emitted");
   EventStore_Close();

   string linesE2E[];
   EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesE2E);
   string candLine = "";
   for(int i = 0; i < ArraySize(linesE2E); i++)
      if(StringFind(linesE2E[i], "\"type\":\"CANDIDATE_CREATED\"") >= 0) candLine = linesE2E[i];
   Check(candLine != "", "sanity: the real CANDIDATE_CREATED line was found");

   // First application -> a genuinely new candidate -> APPLIED.
   Check(CandidateProjection_ApplyLine(candLine, reason), "sanity: the first application of the real line succeeds");
   Check(CandidateProjection_ClassifyReason(reason) == CANDPROJ_REASON_APPLIED,
         "the first application of a real CANDIDATE_CREATED line classifies as APPLIED");

   // Re-apply the identical line -> SKIPPED_DUPLICATE.
   Check(CandidateProjection_ApplyLine(candLine, reason), "sanity: re-applying the identical line is a no-op success");
   Check(CandidateProjection_ClassifyReason(reason) == CANDPROJ_REASON_SKIPPED_DUPLICATE,
         "re-applying an identical CANDIDATE_CREATED line classifies as SKIPPED_DUPLICATE");

   // Same candidate_id, tampered candidate_hash -> COLLISION.
   string tampered = TamperStringField(candLine, "candidate_hash", "TAMPERED_HASH");
   Check(!CandidateProjection_ApplyLine(tampered, reason), "sanity: a tampered candidate_hash on the same candidate_id is rejected");
   Check(CandidateProjection_ClassifyReason(reason) == CANDPROJ_REASON_COLLISION,
         "candidate_id reused with a different candidate_hash classifies as COLLISION");

   // Orphan / context-hash-mismatch: only reachable via ApplyLineWithContext.
   string knownIds[1];   knownIds[0] = "SOME_OTHER_CONTEXT_ID";
   string knownHashes[1]; knownHashes[0] = "SOME_OTHER_CONTEXT_HASH";
   CandidateProjection_Reset();
   Check(!CandidateProjection_ApplyLineWithContext(candLine, knownIds, knownHashes, reason),
         "sanity: a candidate whose context_event_id isn't in the known table is rejected");
   Check(CandidateProjection_ClassifyReason(reason) == CANDPROJ_REASON_ORPHAN_CONTEXT,
         "an unmatched context_event_id classifies as ORPHAN_CONTEXT");

   string knownIds2[1];   knownIds2[0] = ctx.context_event_id;
   string knownHashes2[1]; knownHashes2[0] = "WRONG_CONTEXT_HASH";
   CandidateProjection_Reset();
   Check(!CandidateProjection_ApplyLineWithContext(candLine, knownIds2, knownHashes2, reason),
         "sanity: a candidate whose context_hash doesn't match the known table entry is rejected");
   Check(CandidateProjection_ClassifyReason(reason) == CANDPROJ_REASON_CONTEXT_HASH_MISMATCH,
         "a context_hash mismatch classifies as CONTEXT_HASH_MISMATCH");

   // STORE_VALIDATION_FAILED: RebuildFromFile itself, on a truncated file.
   CandidateProjection_Reset();
   string truncFile = "MLQuantAI_Test_B6_3_HashContract_Truncated.jsonl";
   FileDelete(truncFile, FILE_COMMON);
   int h = FileOpen(truncFile, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   FileWriteString(h, "{\"schema_version\":\"EVENTS_V1\",\"type\":\"CANDIDATE_CREATED\",\"sequence_number\":1,truncated_garbage");
   FileClose(h);
   CandidateProjectionReport report = CandidateProjection_RebuildFromFile(truncFile);
   Check(!report.ok, "sanity: a truncated store fails the rebuild");
   Check(report.first_error_code == CANDPROJ_REASON_STORE_VALIDATION_FAILED,
         "report.first_error_code == STORE_VALIDATION_FAILED for a store-level validation failure");
}

void Test_RebuildFromFile_FirstErrorCode_MatchesFirstErrorString()
{
   Print("--- report.first_error_code is consistent with report.first_error across a real rejection ---");
   CandidateProjection_Reset();

   // Build a real context+candidate pair (natural seq 1,2 in one fresh
   // session, so EventStoreValidator's own contiguity check passes) via
   // the real B5 pipeline, then tamper ONLY the candidate line's
   // candidate_id to "" - this exercises CandidateProjection's own
   // per-line rejection, not the store-level validator (see
   // Test_ClassifyReason_EndToEnd_ApplyLine's separate
   // STORE_VALIDATION_FAILED case for that one).
   string malformedFile = "MLQuantAI_Test_B6_3_HashContract_Malformed.jsonl";
   FileDelete(malformedFile, FILE_COMMON);
   EventStore_Open(malformedFile);
   MarketContext ctx; BuildBaselineContext(ctx);
   ctx.context_event_id = "CTX_malformed";
   ctx.context_hash = "malformed_context_hash";
   ArrayResize(ctx.trigger_tf_recent, 64);
   for(int i = 0; i < 59; i++)
      MakeBar(ctx.trigger_tf_recent[i], D'2026.03.01 00:00:00' + i * PERIOD_SEC_M5, 105.00, 105.20, 104.80, 105.00, 100, 20);
   MakeBar(ctx.trigger_tf_recent[59], D'2026.03.01 00:00:00' + 59 * PERIOD_SEC_M5, 100.80, 100.90, 99.50,  100.50, 100, 20);
   MakeBar(ctx.trigger_tf_recent[60], D'2026.03.01 00:00:00' + 60 * PERIOD_SEC_M5, 100.50, 101.50, 100.40, 101.40, 100, 20);
   MakeBar(ctx.trigger_tf_recent[61], D'2026.03.01 00:00:00' + 61 * PERIOD_SEC_M5, 101.40, 102.50, 101.30, 102.40, 100, 20);
   MakeBar(ctx.trigger_tf_recent[62], D'2026.03.01 00:00:00' + 62 * PERIOD_SEC_M5, 102.40, 103.50, 102.30, 103.40, 100, 20);
   MakeBar(ctx.trigger_tf_recent[63], D'2026.03.01 00:00:00' + 63 * PERIOD_SEC_M5, 103.40, 104.60, 103.30, 104.50, 100, 20);
   ctx.anchor_bar_time = ctx.trigger_tf_recent[63].time;
   ctx.pdl = 100.00; ctx.pdh = 110.00;
   ctx.symbol_spec.digits = 2; ctx.symbol_spec.point = 0.01;
   ctx.instrument_id = "XAUUSD"; ctx.trigger_timeframe = "M5";

   EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx));
   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   Check(r.detected, "sanity: malformed-file fixture detects");
   TradeCandidate c;
   Check(CRT_ToTradeCandidate(ctx, r, c), "sanity: malformed-file fixture maps to candidate");
   Check(CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits), "sanity: malformed-file fixture emitted");
   EventStore_Close();

   string rawLines[];
   int n = EventStore_ReadAllLines(malformedFile, rawLines);
   Check(n == 2, "sanity: exactly context + candidate lines written");
   for(int i = 0; i < n; i++)
      if(StringFind(rawLines[i], "\"type\":\"CANDIDATE_CREATED\"") >= 0)
         rawLines[i] = TamperStringField(rawLines[i], "candidate_id", "");
   int h = FileOpen(malformedFile, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < n; i++)
      FileWriteString(h, rawLines[i] + "\r\n");
   FileClose(h);

   CandidateProjectionReport report = CandidateProjection_RebuildFromFile(malformedFile);
   Check(!report.ok, "sanity: an empty candidate_id fails the rebuild");
   Check(StringFind(report.first_error, "empty candidate_id on a CANDIDATE_CREATED line") >= 0,
         "report.first_error carries the real, unwrapped-of-classification reason text");
   Check(report.first_error_code == CANDPROJ_REASON_EMPTY_CANDIDATE_ID,
         "report.first_error_code == EMPTY_CANDIDATE_ID, consistent with first_error's text");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B B6.3 - Hash Contract Spec + Reason Classification ===");

   Test_ContextHash_IncludedFieldsMoveHash();
   Test_ContextHash_ExcludedFieldsDoNotMoveHash();
   Test_DetectorHash_IncludedFieldsMoveHash();
   Test_DetectorHash_DigitsAffectsFormatting();
   Test_ClassifyReason_DirectValidatorOutputs();
   Test_ClassifyReason_EndToEnd_ApplyLine();
   Test_RebuildFromFile_FirstErrorCode_MatchesFirstErrorString();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
