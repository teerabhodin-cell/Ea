//+------------------------------------------------------------------+
//| MLQuantAI_Test_RA62_RealizedOutcomeCommandHandler.mq5              |
//| RA-62 Slice 2 (QA-frozen): proves RecordRealizedOutcomeCommand_    |
//| Process() (MLQuantAI_RealizedOutcomeCommandHandler.mqh) correctly   |
//| distinguishes the 5 outcome classes - CANDIDATE_NOT_FOUND,           |
//| VALIDATION_FAILED, EMIT_FAILED, RECORDED, ALREADY_RECORDED - never    |
//| collapsing "already recorded" into a generic failure, and never       |
//| silently overwriting an existing RealizedOutcome. Uses the real,       |
//| already-sealed CRT pipeline (same BuildAndEmitCandidate-equivalent      |
//| helper convention Tests/MLQuantAI_Test_CandidateProjection.mq5 already  |
//| established) to populate a genuine CandidateProjection record - never   |
//| a hand-typed/tampered line. No OrderSend anywhere in this file, no       |
//| position ever opened. Running this script on a real account is safe.    |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_EventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_RealizedOutcomeCommandHandler.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_RA62_RealizedOutcomeCommandHandler.jsonl"

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

void BuildBaseContext(MarketContext &ctx)
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
   ctx.context_event_id = "CTX_ra62_test";
   ctx.context_hash      = "test_context_hash_ra62";
}

void FillFillerBars(MqlRates &window[], datetime t0)
{
   for(int i = 0; i < 59; i++)
      MakeBar(window[i], t0 + i * PERIOD_SEC_M5, 105.00, 105.20, 104.80, 105.00, 100, 20);
}

// Same fixture geometry as Tests/MLQuantAI_Test_CandidateProjection.mq5's
// own Fixture_Bullish_Valid - proven to produce a real CRT_DetectV1 hit.
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

// Real end-to-end shape: MARKET_CONTEXT_READY -> CRT_DetectV1 ->
// CANDIDATE_CREATED, durably written via the real B5 pipeline - never a
// hand-typed or tampered line. Requires EventStore_Open() to already have
// succeeded. Uses the 2-argument CRT_EmitCandidateCreated() overload, same
// as Tests/MLQuantAI_Test_CandidateProjection.mq5's own BuildAndEmitCandidate
// - CandidateProjection is populated separately via an explicit
// CandidateProjection_RebuildFromFile() call in OnStart (see there for why).
bool BuildAndEmitCandidate(TradeCandidate &c)
{
   MarketContext ctx; BuildBaseContext(ctx);
   datetime t0 = D'2026.01.01 00:00:00';
   datetime anchor;
   Fixture_Bullish_Valid(ctx.trigger_tf_recent, anchor, t0);
   ctx.anchor_bar_time = anchor;

   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY), "market context built", MarketContext_ToJsonFragment(ctx)))
      return false;

   CRTDetectionResult r;
   CRT_DetectV1(ctx, r);
   if(!r.detected) return false;
   if(!CRT_ToTradeCandidate(ctx, r, c)) return false;
   return CRT_EmitCandidateCreated(c, ctx.symbol_spec.digits);
}

void OnStart()
{
   Print("=== MLQuantAI_Test_RA62_RealizedOutcomeCommandHandler.mq5 ===");

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   CandidateProjection_Reset();
   RealizedOutcomeProjection_Reset();

   Check(EventStore_Open(TEST_EVENT_STORE_FILE), "setup: event store opens");

   TradeCandidate candidate;
   Check(BuildAndEmitCandidate(candidate), "setup: real CRT candidate built and durably emitted");

   // BuildAndEmitCandidate uses the 2-argument CRT_EmitCandidateCreated()
   // overload (matching Tests/MLQuantAI_Test_CandidateProjection.mq5's own
   // established convention) - it durably writes and updates StateProjector
   // only. It does NOT live-sync CandidateProjection: that is the SEPARATE
   // 3-argument overload, which RA-39 (AC-CAND-02) restricts to exactly the
   // two real production/ceremony call sites, not test fixtures. So,
   // exactly like that reference test file, CandidateProjection must be
   // populated with an explicit rebuild from the durable file.
   CandidateProjection_RebuildFromFile(TEST_EVENT_STORE_FILE);

   CandidateProjectionRecord candCheck;
   Check(CandidateProjection_TryGet(candidate.candidate_id, candCheck), "setup: candidate registered into CandidateProjection (via rebuild, matching Test_CandidateProjection.mq5's own convention)");

   datetime validOutcomeTime = candidate.setup_anchor_bar_time + 3600; // strictly after, per the sealed contract

   //=====================================================================
   // 1. CANDIDATE_NOT_FOUND
   //=====================================================================
   Print("--- unknown candidate_id -> CANDIDATE_NOT_FOUND ---");
   {
      RecordOutcomeCommandResult result;
      RecordRealizedOutcomeCommand_Process("CND_does_not_exist_ra62", "TP_HIT", "ref", "hash", validOutcomeTime, result);
      Check(result.status == RECORD_OUTCOME_RESULT_CANDIDATE_NOT_FOUND, "status == CANDIDATE_NOT_FOUND");
      Check(result.realized_outcome_id == "", "realized_outcome_id left empty");
   }

   //=====================================================================
   // 2. VALIDATION_FAILED - outcome_time not strictly after setup_anchor_bar_time
   //=====================================================================
   Print("--- outcome_time <= setup_anchor_bar_time -> VALIDATION_FAILED, reason_detail populated ---");
   {
      RecordOutcomeCommandResult result;
      RecordRealizedOutcomeCommand_Process(candidate.candidate_id, "TP_HIT", "ref", "hash",
                                             candidate.setup_anchor_bar_time, result); // == not strictly after
      Check(result.status == RECORD_OUTCOME_RESULT_VALIDATION_FAILED, "status == VALIDATION_FAILED");
      Check(result.reason_detail != "", "reason_detail is populated with the real validation reason");
      Check(result.realized_outcome_id == "", "realized_outcome_id left empty on validation failure");
   }

   //=====================================================================
   // 3. VALIDATION_FAILED - empty label
   //=====================================================================
   Print("--- empty label -> VALIDATION_FAILED ---");
   {
      RecordOutcomeCommandResult result;
      RecordRealizedOutcomeCommand_Process(candidate.candidate_id, "", "ref", "hash", validOutcomeTime, result);
      Check(result.status == RECORD_OUTCOME_RESULT_VALIDATION_FAILED, "status == VALIDATION_FAILED");
   }

   //=====================================================================
   // 4. EMIT_FAILED - EventStore closed, so the durable write itself fails
   //    (CandidateProjection/RealizedOutcome_Build are pure/in-memory and
   //    unaffected by the store being closed - only the final durable
   //    append inside RealizedOutcome_EmitTradeOutcomeLabeled fails).
   //=====================================================================
   Print("--- EventStore closed -> validation/build succeed, but the durable emit itself fails -> EMIT_FAILED ---");
   EventStore_Close();
   {
      RecordOutcomeCommandResult result;
      RecordRealizedOutcomeCommand_Process(candidate.candidate_id, "TP_HIT", "RA62_TEST_REF", "RA62_TEST_HASH",
                                             validOutcomeTime, result);
      Check(result.status == RECORD_OUTCOME_RESULT_EMIT_FAILED, "status == EMIT_FAILED");
      Check(result.realized_outcome_id != "", "realized_outcome_id IS populated even on emit failure - Build itself succeeded, only the durable write failed");
   }
   Check(EventStore_Open(TEST_EVENT_STORE_FILE), "reopen event store for the remaining tests");

   //=====================================================================
   // 5. RECORDED - fresh, first-time durable write
   //=====================================================================
   Print("--- valid candidate + label -> RECORDED (fresh durable write) ---");
   string firstRealizedOutcomeId = "";
   {
      RecordOutcomeCommandResult result;
      RecordRealizedOutcomeCommand_Process(candidate.candidate_id, "TP_HIT", "RA62_TEST_REF", "RA62_TEST_HASH",
                                             validOutcomeTime, result);
      Check(result.status == RECORD_OUTCOME_RESULT_RECORDED, "status == RECORDED");
      Check(result.realized_outcome_id != "", "realized_outcome_id populated");
      firstRealizedOutcomeId = result.realized_outcome_id;

      RealizedOutcomeProjectionRecord projCheck;
      Check(RealizedOutcomeProjection_TryGet(firstRealizedOutcomeId, projCheck), "the durable RealizedOutcome is now visible in RealizedOutcomeProjection");
   }

   //=====================================================================
   // 6. ALREADY_RECORDED - the exact same call again, idempotent no-op,
   //    never re-written, never a generic failure.
   //=====================================================================
   Print("--- re-running the exact same call -> ALREADY_RECORDED, same realized_outcome_id, never a silent overwrite ---");
   {
      RecordOutcomeCommandResult result;
      RecordRealizedOutcomeCommand_Process(candidate.candidate_id, "TP_HIT", "RA62_TEST_REF", "RA62_TEST_HASH",
                                             validOutcomeTime, result);
      Check(result.status == RECORD_OUTCOME_RESULT_ALREADY_RECORDED, "status == ALREADY_RECORDED, not RECORDED again");
      Check(result.realized_outcome_id == firstRealizedOutcomeId, "realized_outcome_id identical to the first call's");
   }

   //=====================================================================
   // 7. ALREADY_RECORDED even with a DIFFERENT label - the sealed
   //    emitter's own guard is deliberately coarse (any existing record
   //    blocks re-emission regardless of content) - never a silent
   //    conflicting relabel.
   //=====================================================================
   Print("--- same candidate_id+label_schema_version but a DIFFERENT label -> still ALREADY_RECORDED, never overwritten with the new label ---");
   {
      RecordOutcomeCommandResult result;
      RecordRealizedOutcomeCommand_Process(candidate.candidate_id, "SL_HIT", "RA62_DIFFERENT_REF", "RA62_DIFFERENT_HASH",
                                             validOutcomeTime, result);
      Check(result.status == RECORD_OUTCOME_RESULT_ALREADY_RECORDED, "status == ALREADY_RECORDED (conflict, not overwrite)");
      Check(result.realized_outcome_id == firstRealizedOutcomeId, "realized_outcome_id still identical - the original TP_HIT record was never replaced");
   }

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
