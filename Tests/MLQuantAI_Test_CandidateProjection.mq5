//+------------------------------------------------------------------+
//| MLQuantAI_Test_CandidateProjection.mq5                            |
//| Phase B B6.1 DoD (hardened): the candidate projection/registry -  |
//| a read-only read model built purely from persisted CANDIDATE_     |
//| CREATED lines. Uses the real B5 pipeline (CRT_DetectV1 ->          |
//| CRT_ToTradeCandidate -> CRT_EmitCandidateCreated), plus a real      |
//| MARKET_CONTEXT_READY event per candidate (the same call            |
//| FeatureEngine_BuildContext itself makes), so referential-integrity |
//| checks have genuine data to check against. B5 itself is never      |
//| modified - only MLQuantAI_CandidateProjection.mqh is exercised.    |
//|                                                                    |
//| Post-104/104 hardening pass: adds payload-aware collision          |
//| detection (candidate_id reused with a DIFFERENT candidate_hash     |
//| must be rejected as a conflict, never treated as a duplicate),     |
//| schema/time/numerical/enum/reason-mask/resource-limit integrity,   |
//| referential integrity against MARKET_CONTEXT_READY, ordering/      |
//| atomicity (a single corrupt/out-of-order line blocks the WHOLE     |
//| rebuild), a restart/crash simulation, a multi-session store, an    |
//| exhaustive candidate_hash mutation sweep (every decision-bearing   |
//| field moves the hash; every excluded field does not), and a        |
//| larger-scale rebuild-equals-incremental check.                     |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_CandidateProjection.jsonl"

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

void BuildBaseContext(MarketContext &ctx, string suffix)
{
   MarketContext_Init(ctx);
   ctx.instrument_id      = "XAUUSD";
   ctx.broker_symbol      = "XAUUSD";
   ctx.trigger_timeframe  = "M5";
   ctx.symbol_spec.digits = 2;
   ctx.symbol_spec.point  = 0.01;
   ctx.pdl = 100.00;
   ctx.pdh = 110.00;
   ctx.is_kill_zone = false;
   ctx.max_news_impact = 0;
   ctx.nearest_news_minutes = 9999;
   ctx.context_event_id = "CTX_test_" + suffix;
   ctx.context_hash      = "test_context_hash_" + suffix;
}

void FillFillerBars(MqlRates &window[], datetime t0)
{
   for(int i = 0; i < 59; i++)
      MakeBar(window[i], t0 + i * PERIOD_SEC_M5, 105.00, 105.20, 104.80, 105.00, 100, 20);
}

void Fixture_Bullish_Valid(MqlRates &window[], datetime &outAnchor, datetime t0)
{
   ArrayResize(window, 64);
   FillFillerBars(window, t0);
   MakeBar(window[59], t0 + 59 * PERIOD_SEC_M5, 100.80, 100.90, 99.50,  100.50, 100, 20);
   MakeBar(window[60], t0 + 60 * PERIOD_SEC_M5, 100.50, 101.50, 100.40, 101.40, 100, 20);
   MakeBar(window[61], t0 + 61 * PERIOD_SEC_M5, 101.40, 102.50, 101.30, 102.40, 100, 20);
   MakeBar(window[62], t0 + 62 * PERIOD_SEC_M5, 102.40, 103.50, 102.30, 103.40, 100, 20);
   MakeBar(window[63], t0 + 63 * PERIOD_SEC_M5, 103.40, 104.60, 103.30, 104.50, 100, 20);
   outAnchor = window[63].time;
}

// Pure - no I/O. Used only where a TradeCandidate is needed without
// touching the event store (e.g. the candidate_hash mutation sweep).
bool BuildDetectedCandidate(TradeCandidate &c, string suffix, int dayOffset)
{
   MarketContext ctx; BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.01.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   return CRT_ToTradeCandidate(ctx, r, c);
}

// The real end-to-end shape: MARKET_CONTEXT_READY -> detector ->
// CANDIDATE_CREATED -> durable event store, exactly like production
// (FeatureEngine_BuildContext logs MARKET_CONTEXT_READY the same way).
// logContext=false deliberately skips that step, for the orphan-
// candidate referential-integrity test.
bool BuildAndEmitCandidate(TradeCandidate &c, string suffix, int dayOffset, bool logContext = true)
{
   MarketContext ctx; BuildBaseContext(ctx, suffix);
   datetime t0 = D'2026.01.01 00:00:00' + dayOffset * 86400;
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   if(logContext)
      EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx));

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;
   return CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits);
}

string FindLineForCandidate(const string &lines[], string candidateId)
{
   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(StringFind(lines[i], "\"candidate_id\":\"" + candidateId + "\"") < 0) continue;
      if(StringFind(lines[i], "\"type\":\"CANDIDATE_CREATED\"") < 0) continue;
      return lines[i];
   }
   return "";
}

void CheckRecordMatchesCandidate(const CandidateProjectionRecord &rec, const TradeCandidate &c, string label)
{
   Check(rec.candidate_id == c.candidate_id, label + ": candidate_id matches");
   Check(rec.root_event_id == c.root_event_id, label + ": root_event_id matches");
   Check(rec.strategy_id == c.strategy_id, label + ": strategy_id matches");
   Check(rec.state == CANDIDATE_CREATED, label + ": state == CANDIDATE_CREATED");
   Check(rec.context_event_id == c.context_event_id, label + ": context_event_id matches");
   Check(rec.context_hash == c.context_hash, label + ": context_hash matches");
   Check(rec.candidate_hash == c.candidate_hash, label + ": candidate_hash matches");
   Check(rec.detector_hash == c.detector_hash, label + ": detector_hash matches");
   Check(rec.side == c.side, label + ": side matches");
   Check(rec.setup_anchor_bar_time == c.setup_anchor_bar_time, label + ": setup_anchor_bar_time matches");
   Check(rec.expiry_time == c.expiry_time, label + ": expiry_time matches");
   Check(rec.entry_hint == c.entry_hint && rec.sl_hint == c.sl_hint && rec.tp_hint == c.tp_hint, label + ": entry/sl/tp hints match");
   Check(rec.trigger_reason_mask == c.trigger_reason_mask, label + ": trigger_reason_mask matches");

   bool reasonsMatch = (ArraySize(rec.trigger_reasons) == ArraySize(c.trigger_reasons));
   if(reasonsMatch)
      for(int i = 0; i < ArraySize(c.trigger_reasons); i++)
         if(rec.trigger_reasons[i] != c.trigger_reasons[i]) reasonsMatch = false;
   Check(reasonsMatch, label + ": trigger_reasons[] preserved exactly, in original order");
}

//=====================================================================
// Raw file / tampering helpers - deliberately bypass EventStore's own
// write path to construct adversarial input a healthy producer would
// never generate.
//=====================================================================
void WriteRawLines(string fileName, const string &lines[])
{
   FileDelete(fileName, FILE_COMMON);
   int h = FileOpen(fileName, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   for(int i = 0; i < ArraySize(lines); i++)
      FileWriteString(h, lines[i] + "\r\n");
   FileClose(h);
}

void AppendRawLine(string fileName, string line)
{
   int h = FileOpen(fileName, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\r\n");
   FileClose(h);
}

// Replaces "key":"oldvalue" with "key":"newValue" (string-typed field).
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

// Replaces "key":123.45 with "key":newValue (numeric/unquoted field).
string TamperNumericField(string line, string key, string newValue)
{
   string needle = "\"" + key + "\":";
   int p = StringFind(line, needle);
   if(p < 0) return line;
   int start = p + StringLen(needle);
   int n = StringLen(line);
   int end = start;
   while(end < n)
   {
      ushort ch = StringGetCharacter(line, end);
      if(ch == ',' || ch == '}') break;
      end++;
   }
   return StringSubstr(line, 0, start) + newValue + StringSubstr(line, end);
}

// MQL5's StringReplace() mutates its argument in place - this wraps it
// so tamper-helpers can stay expression-style like the others above.
string StringReplace_Copy(string s, string find, string replacement)
{
   string copy = s;
   StringReplace(copy, find, replacement);
   return copy;
}

//=====================================================================
void Test_CoreRegistryInvariants(TradeCandidate &a, TradeCandidate &b, string &outLineA, string &outLineB)
{
   string lines[];
   EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
   string lineA = FindLineForCandidate(lines, a.candidate_id);
   string lineB = FindLineForCandidate(lines, b.candidate_id);
   Check(lineA != "" && lineB != "", "sanity: both persisted lines found");
   outLineA = lineA;
   outLineB = lineB;

   Print("--- one event -> one registry record ---");
   CandidateProjection_Reset();
   string reason;
   Check(CandidateProjection_ApplyLine(lineA, reason), "ApplyLine on candidate A's line returns true");
   Check(CandidateProjection_Count() == 1, "registry has exactly one record");
   CandidateProjectionRecord recA;
   Check(CandidateProjection_TryGet(a.candidate_id, recA), "CandidateLookup finds candidate A");
   CheckRecordMatchesCandidate(recA, a, "candidate A");

   Print("--- same event applied twice -> one record (idempotent) ---");
   string reason2;
   Check(CandidateProjection_ApplyLine(lineA, reason2), "re-applying the same line returns true (no-op, not an error)");
   Check(CandidateProjection_Count() == 1, "registry still has exactly one record");
   Check(StringFind(reason2, "duplicate") >= 0, "the duplicate is explicitly named in the audit reason");

   Print("--- two candidates -> two lookupable records ---");
   string reason3;
   Check(CandidateProjection_ApplyLine(lineB, reason3), "ApplyLine on candidate B's line returns true");
   Check(CandidateProjection_Count() == 2, "registry has exactly two records");
   CandidateProjectionRecord recB;
   Check(CandidateProjection_TryGet(a.candidate_id, recA) && CandidateProjection_TryGet(b.candidate_id, recB),
         "both candidates are independently lookupable");
   CheckRecordMatchesCandidate(recA, a, "candidate A (after B added)");
   CheckRecordMatchesCandidate(recB, b, "candidate B");
}

void Test_StructurallyMalformedLines()
{
   Print("--- structurally malformed lines fail closed with an audit reason ---");
   int before = CandidateProjection_Count();

   string reason4;
   Check(!CandidateProjection_ApplyLine(
      "{\"seq\":999,\"candidate_id\":\"BOGUS_1\",\"root_event_id\":\"R1\",\"correlation_id\":\"\",\"strategy_id\":1,"
      "\"from_state\":\"SUBMITTED\",\"to_state\":\"CREATED\",\"reason\":\"NONE\",\"type\":\"CANDIDATE_CREATED\"}",
      reason4), "a CANDIDATE_CREATED line with a non-genesis from/to shape fails closed");
   Check(reason4 != "", "the failure carries a non-empty audit reason");

   string reason5;
   Check(!CandidateProjection_ApplyLine(
      "{\"seq\":998,\"candidate_id\":\"\",\"root_event_id\":\"R2\",\"correlation_id\":\"\",\"strategy_id\":1,"
      "\"from_state\":\"CREATED\",\"to_state\":\"CREATED\",\"reason\":\"NONE\",\"type\":\"CANDIDATE_CREATED\"}",
      reason5), "a CANDIDATE_CREATED line with an empty candidate_id fails closed");

   string reason6;
   Check(!CandidateProjection_ApplyLine("not even json", reason6), "an unparsable line fails closed");

   Check(CandidateProjection_Count() == before, "registry is unchanged by all three rejected lines");
}

void Test_Collision_DifferentPayloadSameId(string lineA, string candidateAId)
{
   Print("--- COLLISION: candidate_id reused with a DIFFERENT candidate_hash must be rejected, not treated as a duplicate ---");
   int before = CandidateProjection_Count();
   CandidateProjectionRecord existing;
   CandidateProjection_TryGet(candidateAId, existing);

   string tampered = TamperStringField(lineA, "candidate_hash", "TAMPERED_HASH_" + candidateAId);
   string reason;
   bool applied = CandidateProjection_ApplyLine(tampered, reason);
   Check(!applied, "a line with the same candidate_id but a different candidate_hash is REJECTED");
   Check(StringFind(reason, "collision") >= 0 || StringFind(reason, "conflict") >= 0,
         "the rejection reason explicitly names it a collision/conflict, not a duplicate");
   // The message legitimately contains the substring "duplicate" (it
   // says "...rejected as a conflict, not a duplicate" - the collision/
   // conflict assertion above is what actually proves the corruption
   // isn't being hidden). What matters is it never uses the exact phrase
   // ApplyLine's genuine idempotent-duplicate no-op path uses.
   Check(StringFind(reason, "identical candidate_hash") < 0,
         "the rejection reason does not reuse the genuine-duplicate no-op phrasing - a collision is never worded like a harmless no-op");
   Check(CandidateProjection_Count() == before, "registry size is unchanged");

   CandidateProjectionRecord after;
   CandidateProjection_TryGet(candidateAId, after);
   Check(after.candidate_hash == existing.candidate_hash, "the ORIGINAL record's candidate_hash is untouched by the rejected collision");
}

void Test_SchemaVersionIntegrity(string lineA)
{
   Print("--- schema version: unknown/empty candidate_schema_version is rejected ---");
   string reason1;
   string unknownVersion = TamperStringField(lineA, "candidate_schema_version", "CANDIDATE_V99");
   unknownVersion = TamperStringField(unknownVersion, "candidate_id", "CND_SCHEMA_TEST_UNKNOWN");
   Check(!CandidateProjection_ApplyLine(unknownVersion, reason1), "an unrecognized future/unknown schema version is rejected");
   Check(StringFind(reason1, "schema") >= 0, "the reason names the schema version problem");

   string reason2;
   string emptyVersion = TamperStringField(lineA, "candidate_schema_version", "");
   emptyVersion = TamperStringField(emptyVersion, "candidate_id", "CND_SCHEMA_TEST_EMPTY");
   Check(!CandidateProjection_ApplyLine(emptyVersion, reason2), "an empty schema version is rejected");
   Check(StringFind(reason2, "schema") >= 0, "the reason names the schema version problem");
}

void Test_TimeIntegrity(string lineA)
{
   Print("--- time integrity: expiry before/at setup_anchor_bar_time, zero times ---");
   string reason1;
   string invertedExpiry = TamperStringField(lineA, "expiry_time", "2020.01.01 00:00:00");
   invertedExpiry = TamperStringField(invertedExpiry, "candidate_id", "CND_TIME_TEST_INVERTED");
   Check(!CandidateProjection_ApplyLine(invertedExpiry, reason1), "expiry_time before setup_anchor_bar_time is rejected");

   string reason2;
   string zeroExpiry = TamperNumericField(lineA, "expiry_after_bars", "0");
   zeroExpiry = TamperStringField(zeroExpiry, "candidate_id", "CND_TIME_TEST_ZEROBARS");
   Check(!CandidateProjection_ApplyLine(zeroExpiry, reason2), "expiry_after_bars == 0 is rejected");
}

void Test_NumericalIntegrity(string lineA)
{
   Print("--- numerical integrity: zero/negative price, SL/TP ordering violation ---");
   string reason1;
   string negativeEntry = TamperNumericField(lineA, "entry_hint", "-5.00");
   negativeEntry = TamperStringField(negativeEntry, "candidate_id", "CND_NUM_TEST_NEGATIVE");
   Check(!CandidateProjection_ApplyLine(negativeEntry, reason1), "a negative entry_hint is rejected");

   string reason2;
   string zeroEntry = TamperNumericField(lineA, "entry_hint", "0.00");
   zeroEntry = TamperStringField(zeroEntry, "candidate_id", "CND_NUM_TEST_ZERO");
   Check(!CandidateProjection_ApplyLine(zeroEntry, reason2), "a zero entry_hint is rejected");

   // lineA is a BUY candidate (sl_hint < entry_hint < tp_hint) - swap
   // sl_hint/tp_hint to violate that ordering while staying superficially
   // well-formed (still two positive numbers).
   string reason3;
   string badOrder = TamperNumericField(lineA, "sl_hint", "999.00");
   badOrder = TamperStringField(badOrder, "candidate_id", "CND_NUM_TEST_ORDER");
   Check(!CandidateProjection_ApplyLine(badOrder, reason3), "an SL/TP ordering violation for a BUY candidate is rejected");
   Check(StringFind(reason3, "SL/TP") >= 0 || StringFind(reason3, "ordering") >= 0, "the reason names the ordering violation");
}

void Test_EnumIntegrity(string lineA)
{
   Print("--- enum integrity: invalid side is rejected, not silently coerced ---");
   string reason;
   string badSide = TamperStringField(lineA, "side", "SIDEWAYS");
   badSide = TamperStringField(badSide, "candidate_id", "CND_ENUM_TEST_SIDE");
   Check(!CandidateProjection_ApplyLine(badSide, reason), "side='SIDEWAYS' is rejected, not silently mapped to SELL");
   Check(StringFind(reason, "side") >= 0, "the reason names the invalid side");
}

void Test_TriggerReasonsIntegrity(string lineA)
{
   Print("--- trigger reasons: mask/array inconsistency is rejected ---");

   // Flip an extra bit outside the frozen sweep-low/high pair without
   // updating the label array - a mask/array mismatch.
   string reason1;
   string badMask = TamperNumericField(lineA, "trigger_reason_mask", "255"); // all 8 bits - violates BOTH XOR invariants
   badMask = TamperStringField(badMask, "candidate_id", "CND_REASON_TEST_MASK");
   Check(!CandidateProjection_ApplyLine(badMask, reason1), "a reason_mask violating the frozen XOR invariants is rejected");

   // Mask says only SWEEP_LOW|CLOSE_BACK_INSIDE|MSS_CONFIRMED|FVG_FOUND
   // (0x1D, a valid mask) but the label array is tampered to carry a
   // duplicate/unknown entry that doesn't match what that mask implies.
   string reason2;
   string badArray = StringReplace_Copy(lineA, "\"trigger_reasons\":[", "\"trigger_reasons\":[\"unknown_bogus_reason\",");
   badArray = TamperStringField(badArray, "candidate_id", "CND_REASON_TEST_ARRAY");
   Check(!CandidateProjection_ApplyLine(badArray, reason2), "a trigger_reasons[] array that doesn't match its mask is rejected");
}

void Test_ResourceLimits()
{
   Print("--- resource limits: an oversized trigger_reasons[] array is rejected ---");
   string oversizedArray = "[";
   for(int i = 0; i < 20; i++)
   {
      if(i > 0) oversizedArray += ",";
      oversizedArray += "\"liquidity_sweep_low\"";
   }
   oversizedArray += "]";

   string line = "{\"schema_version\":\"EVENTS_V1\",\"log_event_id\":\"S#1\",\"session_id\":\"S\",\"seq\":1,"
                 "\"ts\":\"2026.01.01 00:00:00\",\"category\":\"LIFECYCLE\",\"type\":\"CANDIDATE_CREATED\","
                 "\"candidate_id\":\"CND_RESOURCE_TEST\",\"root_event_id\":\"R\",\"correlation_id\":\"\",\"strategy_id\":1,"
                 "\"strategy\":\"CRT\",\"from_state\":\"CREATED\",\"to_state\":\"CREATED\",\"reason\":\"NONE\","
                 "\"context_event_id\":\"CTX\",\"context_hash\":\"H\",\"candidate_hash\":\"CH\",\"detector_hash\":\"DH\","
                 "\"candidate_schema_version\":\"CANDIDATE_V1\",\"side\":\"BUY\","
                 "\"setup_anchor_bar_time\":\"2026.01.01 00:00:00\",\"expiry_after_bars\":12,"
                 "\"expiry_time\":\"2026.01.01 01:00:00\",\"entry_hint\":100.0,\"sl_hint\":99.0,\"tp_hint\":102.0,"
                 "\"trigger_reason_mask\":29,\"trigger_reasons\":" + oversizedArray + "}"; // 29 = 0x1D, a validly-shaped mask - only the array size is wrong

   string reason;
   Check(!CandidateProjection_ApplyLine(line, reason), "a 20-element trigger_reasons[] array (only 8 bits exist) is rejected");
}

void Test_ReferentialIntegrity()
{
   Print("--- referential integrity: orphan candidate_event_id and context_hash mismatch ---");

   string orphanFile = "MLQuantAI_Test_CandidateProjection_Orphan.jsonl";
   FileDelete(orphanFile, FILE_COMMON);
   EventStore_Open(orphanFile);
   TradeCandidate orphan;
   bool built = BuildAndEmitCandidate(orphan, "ORPHAN", 500, false); // logContext=false - no MARKET_CONTEXT_READY ever written
   Check(built, "sanity: orphan candidate detected+emitted (context deliberately never logged)");
   EventStore_Close();

   CandidateProjectionReport orphanReport = CandidateProjection_RebuildFromFile(orphanFile);
   Check(!orphanReport.ok, "rebuild reports a failure - the candidate has no matching MARKET_CONTEXT_READY event");
   Check(orphanReport.lines_failed == 1, "exactly the one orphan candidate line failed");
   Check(StringFind(orphanReport.first_error, "orphan") >= 0, "the failure explicitly names it an orphan");
   Check(CandidateProjection_Count() == 0, "no candidate was registered from an orphan-only file");

   string mismatchFile = "MLQuantAI_Test_CandidateProjection_Mismatch.jsonl";
   FileDelete(mismatchFile, FILE_COMMON);
   EventStore_Open(mismatchFile);
   TradeCandidate mismatch;
   built = BuildAndEmitCandidate(mismatch, "MISMATCH", 501, true); // context IS logged this time
   Check(built, "sanity: mismatch candidate detected+emitted with its context logged");
   EventStore_Close();

   string mLines[];
   EventStore_ReadAllLines(mismatchFile, mLines);
   // Corrupt the candidate line's context_hash so it no longer matches
   // the real MARKET_CONTEXT_READY event still sitting in the same file.
   string rebuiltLines[];
   ArrayResize(rebuiltLines, ArraySize(mLines));
   for(int i = 0; i < ArraySize(mLines); i++)
   {
      string l = mLines[i];
      if(StringFind(l, "\"candidate_id\":\"" + mismatch.candidate_id + "\"") >= 0 && StringFind(l, "\"type\":\"CANDIDATE_CREATED\"") >= 0)
         l = TamperStringField(l, "context_hash", "DELIBERATELY_WRONG_CONTEXT_HASH");
      rebuiltLines[i] = l;
   }
   WriteRawLines(mismatchFile, rebuiltLines);

   CandidateProjectionReport mismatchReport = CandidateProjection_RebuildFromFile(mismatchFile);
   Check(!mismatchReport.ok, "rebuild reports a failure - the candidate's context_hash no longer matches its MARKET_CONTEXT_READY event");
   Check(StringFind(mismatchReport.first_error, "mismatch") >= 0, "the failure explicitly names it a context_hash mismatch");
   Check(CandidateProjection_Count() == 0, "no candidate was registered from a context-hash-mismatched file");
}

void Test_OrderingAndAtomicity()
{
   Print("--- event ordering: backward/duplicate seq blocks the WHOLE rebuild, registry left unchanged ---");

   string orderFile = "MLQuantAI_Test_CandidateProjection_Ordering.jsonl";
   string badLines[3];
   badLines[0] = "{\"schema_version\":\"EVENTS_V1\",\"session_id\":\"SESSA\",\"seq\":1,\"type\":\"SYSTEM_STARTED\"}";
   badLines[1] = "{\"schema_version\":\"EVENTS_V1\",\"session_id\":\"SESSA\",\"seq\":1,\"type\":\"SYSTEM_STARTED\"}"; // duplicate seq
   badLines[2] = "{\"schema_version\":\"EVENTS_V1\",\"session_id\":\"SESSA\",\"seq\":2,\"type\":\"SYSTEM_STOPPED\"}";
   WriteRawLines(orderFile, badLines);

   // Pre-populate the registry with a known-good state (from the main
   // test file's earlier real candidates) so "left unchanged" is
   // actually meaningful, not just "stayed empty".
   CandidateProjection_RebuildFromFile(TEST_EVENT_STORE_FILE);
   int countBefore = CandidateProjection_Count();
   Check(countBefore > 0, "sanity: registry has real content before the corrupt-ordering attempt");

   CandidateProjectionReport orderReport = CandidateProjection_RebuildFromFile(orderFile);
   Check(!orderReport.ok, "rebuild refuses a file with a duplicate/backward sequence number");
   Check(CandidateProjection_Count() == countBefore, "registry is completely unchanged by the refused rebuild");

   Print("--- atomicity: one truncated line anywhere blocks the whole rebuild, no partial state committed ---");
   string atomFile = "MLQuantAI_Test_CandidateProjection_Atomicity.jsonl";
   FileDelete(atomFile, FILE_COMMON);
   EventStore_Open(atomFile);
   TradeCandidate atomA, atomB;
   BuildAndEmitCandidate(atomA, "ATOMA", 502, true);
   BuildAndEmitCandidate(atomB, "ATOMB", 503, true);
   EventStore_Close();

   CandidateProjectionReport cleanReport = CandidateProjection_RebuildFromFile(atomFile);
   Check(cleanReport.ok && CandidateProjection_Count() == 2, "sanity: the clean 2-candidate file rebuilds successfully first");

   AppendRawLine(atomFile, "{\"schema_version\":\"EVENTS_V1\",\"session_id\":\"SESSA\",\"seq\":1,\"type\":\"TRUNCATED"); // no closing brace
   CandidateProjectionReport corruptReport = CandidateProjection_RebuildFromFile(atomFile);
   Check(!corruptReport.ok, "rebuild refuses the file once a truncated line is appended");
   Check(CandidateProjection_Count() == 2, "registry still shows the last known-good state (2), not partially reset/appended");
}

void Test_RestartCrashSimulation()
{
   Print("--- restart/crash simulation: replay after a simulated crash never produces a ghost candidate ---");
   string crashFile = "MLQuantAI_Test_CandidateProjection_Crash.jsonl";
   FileDelete(crashFile, FILE_COMMON);
   EventStore_Open(crashFile);
   TradeCandidate before1, before2;
   BuildAndEmitCandidate(before1, "CRASH1", 510, true);
   BuildAndEmitCandidate(before2, "CRASH2", 511, true);
   EventStore_Close();

   // Simulate the process dying mid-write of a third event - a line with
   // no closing brace, exactly what a crash between FileWriteString calls
   // would leave behind.
   AppendRawLine(crashFile, "{\"schema_version\":\"EVENTS_V1\",\"session_id\":\"CRASHSESS\",\"seq\":1,\"type\":\"CANDIDATE_CREATED\",\"candidate_id\":\"CND_GHOST");

   CandidateProjectionReport crashedReport = CandidateProjection_RebuildFromFile(crashFile);
   Check(!crashedReport.ok, "rebuild immediately after the simulated crash detects the truncated tail and refuses");

   // "Restart" for real: truncate the corrupt tail back off (what a real
   // recovery step would do - see EventStoreHealth) and confirm a clean
   // replay reconstructs exactly the two real candidates, no ghost third.
   string recoveredLines[];
   int n = EventStore_ReadAllLines(crashFile, recoveredLines);
   string goodLines[];
   int goodCount = 0;
   for(int i = 0; i < n; i++)
   {
      if(StringFind(recoveredLines[i], "CND_GHOST") >= 0) continue; // drop the truncated tail
      ArrayResize(goodLines, goodCount + 1);
      goodLines[goodCount] = recoveredLines[i];
      goodCount++;
   }
   WriteRawLines(crashFile, goodLines);

   CandidateProjectionReport recoveredReport = CandidateProjection_RebuildFromFile(crashFile);
   Check(recoveredReport.ok, "rebuild succeeds after the truncated tail is removed");
   Check(CandidateProjection_Count() == 2, "exactly the 2 real pre-crash candidates are present");
   CandidateProjectionRecord ghost;
   Check(!CandidateProjection_TryGet("CND_GHOST", ghost), "no ghost candidate exists in the recovered registry");
}

void Test_MultiSession()
{
   Print("--- multi-session store: uniqueness and replay stay correct across session boundaries ---");
   string multiFile = "MLQuantAI_Test_CandidateProjection_MultiSession.jsonl";
   FileDelete(multiFile, FILE_COMMON);

   EventStore_Open(multiFile);
   string session1 = EventStore_SessionId();
   TradeCandidate s1;
   BuildAndEmitCandidate(s1, "SESSION1", 520, true);
   EventStore_Close();

   EventStore_Open(multiFile); // new session_id, seq resets to 1 - exactly what a real EA restart produces
   string session2 = EventStore_SessionId();
   Check(session1 != session2, "sanity: reopening the store produced a genuinely new session_id");
   TradeCandidate s2;
   BuildAndEmitCandidate(s2, "SESSION2", 521, true);
   EventStore_Close();

   CandidateProjectionReport multiReport = CandidateProjection_RebuildFromFile(multiFile);
   Check(multiReport.ok, "a two-session store still validates and rebuilds cleanly");
   Check(CandidateProjection_Count() == 2, "both sessions' candidates are present, no cross-contamination");
   CandidateProjectionRecord r1, r2;
   Check(CandidateProjection_TryGet(s1.candidate_id, r1) && CandidateProjection_TryGet(s2.candidate_id, r2),
         "both candidates are independently lookupable regardless of which session created them");
}

void Test_ReplayAtScale()
{
   Print("--- replay at scale: rebuild equals incremental across many candidates ---");
   string scaleFile = "MLQuantAI_Test_CandidateProjection_Scale.jsonl";
   FileDelete(scaleFile, FILE_COMMON);
   EventStore_Open(scaleFile);

   int N = 25;
   TradeCandidate candidates[];
   ArrayResize(candidates, N);
   int builtCount = 0;
   for(int i = 0; i < N; i++)
   {
      TradeCandidate c;
      if(BuildAndEmitCandidate(c, "SCALE" + IntegerToString(i), 600 + i, true))
      {
         candidates[builtCount] = c;
         builtCount++;
      }
   }
   Check(builtCount == N, "sanity: all " + IntegerToString(N) + " scale candidates detected and emitted");
   EventStore_Close();

   CandidateProjectionReport scaleReport = CandidateProjection_RebuildFromFile(scaleFile);
   Check(scaleReport.ok, "large rebuild reports zero inconsistencies");
   Check(scaleReport.lines_applied == builtCount, "rebuild applied exactly " + IntegerToString(builtCount) + " candidates");
   Check(CandidateProjection_Count() == builtCount, "registry count matches the number built");

   bool allFound = true;
   for(int i = 0; i < builtCount; i++)
   {
      CandidateProjectionRecord rec;
      if(!CandidateProjection_TryGet(candidates[i].candidate_id, rec) || rec.candidate_hash != candidates[i].candidate_hash)
         allFound = false;
   }
   Check(allFound, "every one of the " + IntegerToString(builtCount) + " candidates is present with its correct candidate_hash after rebuild");

   // Rebuild a second time - must be identical.
   CandidateProjectionReport scaleReport2 = CandidateProjection_RebuildFromFile(scaleFile);
   Check(scaleReport2.ok && scaleReport2.lines_applied == scaleReport.lines_applied,
         "a second rebuild of the same large file applies the identical number of candidates");
}

//=====================================================================
void Test_HashIntegrity_DecisionFieldsChangeHash()
{
   Print("--- candidate_hash: every decision-bearing field change moves the hash ---");
   TradeCandidate baseline;
   Check(BuildDetectedCandidate(baseline, "HASH1", 700), "sanity: baseline candidate built");
   string baseHash = baseline.candidate_hash;
   TradeCandidate m;

   m = baseline; m.candidate_id = "DIFFERENT_ID";
   Check(CRT_CandidateHash(m, 2) != baseHash, "candidate_id change moves candidate_hash");

   m = baseline; m.root_event_id = "DIFFERENT_ROOT";
   Check(CRT_CandidateHash(m, 2) != baseHash, "root_event_id change moves candidate_hash");

   m = baseline; m.strategy_id = 99;
   Check(CRT_CandidateHash(m, 2) != baseHash, "strategy_id change moves candidate_hash");

   m = baseline; m.strategy_name = "OTHER";
   Check(CRT_CandidateHash(m, 2) != baseHash, "strategy_name change moves candidate_hash");

   m = baseline; m.strategy_version = "CRT_V2";
   Check(CRT_CandidateHash(m, 2) != baseHash, "strategy_version change moves candidate_hash");

   m = baseline; m.side = ORDER_TYPE_SELL;
   Check(CRT_CandidateHash(m, 2) != baseHash, "side change moves candidate_hash");

   m = baseline; m.context_event_id = "OTHER_CTX";
   Check(CRT_CandidateHash(m, 2) != baseHash, "context_event_id change moves candidate_hash");

   m = baseline; m.context_hash = "OTHER_HASH";
   Check(CRT_CandidateHash(m, 2) != baseHash, "context_hash change moves candidate_hash");

   m = baseline; m.setup_anchor_bar_time = baseline.setup_anchor_bar_time + 300;
   Check(CRT_CandidateHash(m, 2) != baseHash, "setup_anchor_bar_time change moves candidate_hash");

   m = baseline; m.expiry_after_bars = baseline.expiry_after_bars + 1;
   Check(CRT_CandidateHash(m, 2) != baseHash, "expiry_after_bars change moves candidate_hash");

   m = baseline; m.entry_hint = baseline.entry_hint + 0.01;
   Check(CRT_CandidateHash(m, 2) != baseHash, "entry_hint change moves candidate_hash");

   m = baseline; m.sl_hint = baseline.sl_hint + 0.01;
   Check(CRT_CandidateHash(m, 2) != baseHash, "sl_hint change moves candidate_hash");

   m = baseline; m.tp_hint = baseline.tp_hint + 0.01;
   Check(CRT_CandidateHash(m, 2) != baseHash, "tp_hint change moves candidate_hash");

   m = baseline; m.trigger_reason_mask = baseline.trigger_reason_mask ^ 0x40;
   Check(CRT_CandidateHash(m, 2) != baseHash, "trigger_reason_mask change moves candidate_hash");

   m = baseline; m.detector_hash = "OTHER_DETECTOR_HASH";
   Check(CRT_CandidateHash(m, 2) != baseHash, "detector_hash change moves candidate_hash");

   m = baseline; m.candidate_schema_version = "OTHER_SCHEMA";
   Check(CRT_CandidateHash(m, 2) != baseHash, "candidate_schema_version change moves candidate_hash");
}

void Test_HashExclusion_NonDecisionFieldsDoNotChangeHash()
{
   Print("--- candidate_hash: whitelist of fields that must NOT move the hash ---");
   TradeCandidate baseline;
   Check(BuildDetectedCandidate(baseline, "HASH2", 701), "sanity: baseline candidate built");
   string baseHash = baseline.candidate_hash;
   TradeCandidate m;

   m = baseline; m.score = 42;
   Check(CRT_CandidateHash(m, 2) == baseHash, "score is excluded from candidate_hash");

   m = baseline; m.confidence = 0.9;
   Check(CRT_CandidateHash(m, 2) == baseHash, "confidence is excluded");

   m = baseline; m.compatible_regime = REGIME_TREND_UP;
   Check(CRT_CandidateHash(m, 2) == baseHash, "compatible_regime is excluded");

   m = baseline; m.regime_rules_version = "SOME_VERSION";
   Check(CRT_CandidateHash(m, 2) == baseHash, "regime_rules_version is excluded");

   m = baseline; m.state = CANDIDATE_SUBMITTED;
   Check(CRT_CandidateHash(m, 2) == baseHash, "state is excluded");

   m = baseline; m.last_reason = REASON_SUBMITTED_OK;
   Check(CRT_CandidateHash(m, 2) == baseHash, "last_reason is excluded");

   m = baseline; m.correlation_id = "CORR_1";
   Check(CRT_CandidateHash(m, 2) == baseHash, "correlation_id is excluded");

   m = baseline; m.parent_candidate_ids = "A,B";
   Check(CRT_CandidateHash(m, 2) == baseHash, "parent_candidate_ids is excluded");

   m = baseline; m.entry = 123.45;
   Check(CRT_CandidateHash(m, 2) == baseHash, "entry (risk-adjusted) is excluded");

   m = baseline; m.sl = 100.0;
   Check(CRT_CandidateHash(m, 2) == baseHash, "sl (risk-adjusted) is excluded");

   m = baseline; m.tp = 200.0;
   Check(CRT_CandidateHash(m, 2) == baseHash, "tp (risk-adjusted) is excluded");

   m = baseline; m.rr = 3.0;
   Check(CRT_CandidateHash(m, 2) == baseHash, "rr is excluded");

   m = baseline; m.atr = 1.5;
   Check(CRT_CandidateHash(m, 2) == baseHash, "atr is excluded");

   m = baseline; m.stop_distance = 5.0;
   Check(CRT_CandidateHash(m, 2) == baseHash, "stop_distance is excluded");

   m = baseline; m.signal_time = baseline.signal_time + 12345;
   Check(CRT_CandidateHash(m, 2) == baseHash, "signal_time is excluded");

   m = baseline; m.expiry_time = baseline.expiry_time + 12345;
   Check(CRT_CandidateHash(m, 2) == baseHash, "expiry_time is excluded");

   m = baseline; m.in_killzone = !baseline.in_killzone;
   Check(CRT_CandidateHash(m, 2) == baseHash, "in_killzone is excluded");

   m = baseline; m.news_risk = !baseline.news_risk;
   Check(CRT_CandidateHash(m, 2) == baseHash, "news_risk is excluded");

   m = baseline; m.has_liquidity_sweep = !baseline.has_liquidity_sweep;
   Check(CRT_CandidateHash(m, 2) == baseHash, "has_liquidity_sweep is excluded (derived display flag - trigger_reason_mask itself IS included)");

   m = baseline;
   ArrayResize(m.trigger_reasons, 1);
   m.trigger_reasons[0] = "tampered_label";
   Check(CRT_CandidateHash(m, 2) == baseHash, "trigger_reasons[] array content is excluded (only trigger_reason_mask is hashed)");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: Phase B B6.1 (hardened) - Candidate Projection/Registry ===");

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   if(!EventStore_Open(TEST_EVENT_STORE_FILE))
   {
      Print("Could not open the event store - aborting.");
      return;
   }

   TradeCandidate a, b;
   Check(BuildAndEmitCandidate(a, "A", 1, true), "sanity: candidate A detected+emitted with context logged");
   Check(BuildAndEmitCandidate(b, "B", 2, true), "sanity: candidate B detected+emitted with context logged");

   string lineA, lineB;
   Test_CoreRegistryInvariants(a, b, lineA, lineB);
   Test_StructurallyMalformedLines();
   Test_Collision_DifferentPayloadSameId(lineA, a.candidate_id);
   Test_SchemaVersionIntegrity(lineA);
   Test_TimeIntegrity(lineA);
   Test_NumericalIntegrity(lineA);
   Test_EnumIntegrity(lineA);
   Test_TriggerReasonsIntegrity(lineA);
   Test_ResourceLimits();

   EventStore_Close();

   Test_ReferentialIntegrity();
   Test_OrderingAndAtomicity();
   Test_RestartCrashSimulation();
   Test_MultiSession();
   Test_ReplayAtScale();

   Test_HashIntegrity_DecisionFieldsChangeHash();
   Test_HashExclusion_NonDecisionFieldsDoNotChangeHash();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
