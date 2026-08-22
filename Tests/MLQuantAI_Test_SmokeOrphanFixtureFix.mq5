//+------------------------------------------------------------------+
//| MLQuantAI_Test_SmokeOrphanFixtureFix.mq5                          |
//| Isolated forward-behavior verification for the Step 8.5 smoke-test |
//| fix (branch fix/smoke-test-orphan-candidate, commit af8222f) -     |
//| duplicates the EXACT (fixed) candidate-creation logic that now     |
//| lives in MLQuantAI.mq5's RunRuntimeLifecycleSmokeTest()/           |
//| BuildSmokeTestContext()/SmokeTestCandidateCreatedExtraJson(), per  |
//| this project's own established per-test-file duplication          |
//| convention (never shared via a common header).                    |
//|                                                                    |
//| Uses ONLY a dedicated, deterministically-named test event store    |
//| file (MLQuantAI_Test_SmokeOrphanFixtureFix.jsonl). Never opens,    |
//| renames, deletes, or otherwise touches MLQuantAI_events_2026-08-   |
//| 21.jsonl or any other production/daily store - this is a fresh-    |
//| file forward-behavior proof only, not a repair or rotation.        |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Core/MLQuantAI_VersionRegistry.mqh>
#include <MLQuantAI/Core/MLQuantAI_Enums.mqh>
#include <MLQuantAI/Logging/MLQuantAI_SystemLogger.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStore.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_EventStoreHealth.mqh>
#include <MLQuantAI/Market/MLQuantAI_MarketContext.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh>
#include <MLQuantAI/Execution/MLQuantAI_BrokerSubmissionAuditReadiness.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ManualApprovalReadiness.mqh>
#include <MLQuantAI/Execution/MLQuantAI_TransactionMatchingReadiness.mqh>
#include <MLQuantAI/Strategies/MLQuantAI_CRT_V1_Contract.mqh>

#define TEST_FILE "MLQuantAI_Test_SmokeOrphanFixtureFix.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Exact duplicate of the FIXED logic in MLQuantAI.mq5 (commit af8222f) -
// BuildSmokeTestCandidateId / BuildSmokeTestContext / SMOKE_TEST_
// REASON_MASK / SmokeTestStringArrayToJson / SmokeTestCandidateCreated
// ExtraJson / the CREATED->SUBMITTED->REJECTED_BY_BROKER write sequence
// from RunRuntimeLifecycleSmokeTest(). Copied verbatim (function bodies
// unchanged) so this test proves the SAME code that ships in the live
// EA, not a reimplementation that could silently diverge.
//---------------------------------------------------------------------
string BuildSmokeTestCandidateId(string &outRootEventId)
{
   datetime approxDayStart = TimeCurrent() - (TimeCurrent() % 86400);
   outRootEventId = Ids_RootEventId(_Symbol, "SMOKE", "RUNTIME_LIFECYCLE_SMOKE_TEST", 0.0, approxDayStart, 0);
   return Ids_CandidateId(outRootEventId, "SMOKE", "V1");
}

void BuildSmokeTestContext(MarketContext &ctx, datetime approxDayStart)
{
   MarketContext_Init(ctx);
   ctx.instrument_id     = "SMOKE";
   ctx.broker_symbol     = _Symbol;
   ctx.trigger_timeframe = "SMOKE";
   ctx.anchor_bar_time   = approxDayStart;
   ctx.context_event_id  = Ids_ContextEventId(ctx.instrument_id, ctx.trigger_timeframe, ctx.anchor_bar_time);
   ctx.context_hash      = MarketContext_ComputeHash(ctx);
}

#define SMOKE_TEST_REASON_MASK (CRT_REASON_BIT_SWEEP_LOW | CRT_REASON_BIT_CLOSE_BACK_INSIDE | CRT_REASON_BIT_MSS_CONFIRMED | CRT_REASON_BIT_FVG_FOUND)

string SmokeTestStringArrayToJson(const string &arr[])
{
   string s = "[";
   for(int i = 0; i < ArraySize(arr); i++)
   {
      if(i > 0) s += ",";
      s += "\"" + EventSerializer_Escape(arr[i]) + "\"";
   }
   s += "]";
   return s;
}

string SmokeTestCandidateCreatedExtraJson(const TradeCandidate &c)
{
   string reasons[];
   CRT_ReasonLabelsFromMask(c.trigger_reason_mask, reasons);

   string s = "";
   s += "\"candidate_schema_version\":\"" + EventSerializer_Escape(c.candidate_schema_version) + "\",";
   s += "\"context_event_id\":\""          + EventSerializer_Escape(c.context_event_id) + "\",";
   s += "\"context_hash\":\""              + EventSerializer_Escape(c.context_hash) + "\",";
   s += "\"candidate_hash\":\""            + EventSerializer_Escape(c.candidate_hash) + "\",";
   s += "\"detector_hash\":\""             + EventSerializer_Escape(c.detector_hash) + "\",";
   s += "\"side\":\""                      + (c.side == ORDER_TYPE_BUY ? "BUY" : "SELL") + "\",";
   s += "\"setup_anchor_bar_time\":\""     + TimeToString(c.setup_anchor_bar_time, TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"expiry_after_bars\":"           + IntegerToString(c.expiry_after_bars) + ",";
   s += "\"expiry_time\":\""               + TimeToString(c.expiry_time, TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"entry_hint\":"                  + DoubleToString(c.entry_hint, 5) + ",";
   s += "\"sl_hint\":"                     + DoubleToString(c.sl_hint, 5) + ",";
   s += "\"tp_hint\":"                     + DoubleToString(c.tp_hint, 5) + ",";
   s += "\"trigger_reason_mask\":"         + IntegerToString((long)c.trigger_reason_mask) + ",";
   s += "\"trigger_reasons\":"             + SmokeTestStringArrayToJson(reasons);
   return s;
}

// Writes the smoke-test candidate (MARKET_CONTEXT_READY -> CREATED ->
// SUBMITTED -> REJECTED_BY_BROKER) into the already-open TEST_FILE,
// exactly as RunRuntimeLifecycleSmokeTest() does in the live EA - minus
// the StateProjector_TryGetState "already exists today" guard, which is
// irrelevant here since this script never runs ReplayEngine and the
// store starts empty every time.
bool WriteSmokeTestCandidate(string &outSmokeId)
{
   string rootEventId;
   string smokeId = BuildSmokeTestCandidateId(rootEventId);
   outSmokeId = smokeId;

   datetime approxDayStart = TimeCurrent() - (TimeCurrent() % 86400);
   MarketContext smokeCtx;
   BuildSmokeTestContext(smokeCtx, approxDayStart);
   if(!EventStore_LogSystem(EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY),
                              "synthetic market context for the Step 8.5 lifecycle smoke test - not a real MarketContext",
                              MarketContext_ToJsonFragment(smokeCtx)))
      return false;

   TradeCandidate smoke;
   TradeCandidate_Init(smoke);
   smoke.candidate_id  = smokeId;
   smoke.root_event_id = rootEventId;
   smoke.strategy_id   = -1;
   smoke.strategy_name = "RuntimeLifecycleSmokeTest";
   smoke.signal_time   = TimeCurrent();

   smoke.context_event_id = smokeCtx.context_event_id;
   smoke.context_hash      = smokeCtx.context_hash;
   smoke.candidate_hash    = "SMOKE_CANDIDATE_HASH_" + smokeId;
   smoke.detector_hash     = "SMOKE_DETECTOR_HASH_V1";

   smoke.side                  = ORDER_TYPE_BUY;
   smoke.setup_anchor_bar_time = approxDayStart;
   smoke.expiry_after_bars     = 1;
   smoke.expiry_time           = TradeCandidate_ComputeExpiryTime(smoke.setup_anchor_bar_time, smoke.expiry_after_bars, PERIOD_M1);
   smoke.entry_hint            = 1.5;
   smoke.sl_hint                = 1.0;
   smoke.tp_hint                = 2.0;
   smoke.trigger_reason_mask   = SMOKE_TEST_REASON_MASK;

   string createdExtraJson = SmokeTestCandidateCreatedExtraJson(smoke);
   if(!EventStore_LogCandidateCreated(smoke, createdExtraJson)) return false;
   if(!EventStore_LogTransition(smoke, CANDIDATE_SUBMITTED, REASON_SUBMITTED_OK)) return false;
   smoke.correlation_id = Ids_CorrelationId(smoke.candidate_id);
   if(!EventStore_LogTransition(smoke, CANDIDATE_REJECTED_BY_BROKER, REASON_BROKER_REJECT)) return false;

   return true;
}

//---------------------------------------------------------------------
void OnStart()
{
   Print("=== MLQuantAI Test: Step 8.5 smoke-test orphan fix - isolated forward-behavior verification ===");
   Print("Test store: ", TEST_FILE, " (dedicated test file - MLQuantAI_events_2026-08-21.jsonl is never opened by this script)");

   // 1. Test-store filename and confirmation it starts empty/absent.
   EventStore_Close();
   SafeMode_Clear();
   BrokerSubmissionAuditReadiness_Reset();
   ManualApprovalReadiness_Reset();
   TransactionMatchingReadiness_Reset();
   if(FileIsExist(TEST_FILE, FILE_COMMON))
      FileDelete(TEST_FILE, FILE_COMMON);
   Check(!FileIsExist(TEST_FILE, FILE_COMMON), "1. test store does not exist before this run (fresh file)");

   Check(EventStore_Open(TEST_FILE), "EventStore opens/creates the fresh test store");

   string preLines[];
   int preCount = EventStore_ReadAllLines(TEST_FILE, preLines);
   Check(preCount == 0, "1. test store has 0 lines before the smoke candidate is written");

   // 2. Write the smoke-test candidate via the exact fixed logic.
   string smokeId;
   Check(WriteSmokeTestCandidate(smokeId), "2. smoke-test candidate written (MARKET_CONTEXT_READY -> CREATED -> SUBMITTED -> REJECTED_BY_BROKER)");
   Print("2. Smoke candidate ID: ", smokeId);
   EventStore_Close();

   // 3. Event types/line count written to the test store.
   string lines[];
   int n = EventStore_ReadAllLines(TEST_FILE, lines);
   int contextLines = 0, createdLines = 0, submittedLines = 0, rejectedLines = 0, otherLines = 0;
   for(int i = 0; i < n; i++)
   {
      if(StringFind(lines[i], "\"MARKET_CONTEXT_READY\"") >= 0)            contextLines++;
      else if(StringFind(lines[i], "\"CANDIDATE_CREATED\"") >= 0)          createdLines++;
      else if(StringFind(lines[i], "\"CANDIDATE_SUBMITTED\"") >= 0)        submittedLines++;
      else if(StringFind(lines[i], "\"CANDIDATE_REJECTED_BY_BROKER\"") >= 0) rejectedLines++;
      else                                                                  otherLines++;
   }
   Print("3. Test store line count: ", n, " (MARKET_CONTEXT_READY=", contextLines, " CANDIDATE_CREATED=", createdLines,
         " CANDIDATE_SUBMITTED=", submittedLines, " CANDIDATE_REJECTED_BY_BROKER=", rejectedLines, " other=", otherLines, ")");
   Check(n == 4, "3. exactly 4 lines written (1 context + 3 lifecycle events)");
   Check(contextLines == 1 && createdLines == 1 && submittedLines == 1 && rejectedLines == 1 && otherLines == 0,
         "3. event-type composition matches exactly (no stray/missing lines)");

   // 4. CandidateProjection replay, called directly (not just inferred
   // transitively) - this is the exact projection whose "orphan
   // candidate" rejection caused the original cascading failure.
   CandidateProjectionReport candReport = CandidateProjection_RebuildFromFile(TEST_FILE);
   Check(candReport.ok, "4. CandidateProjection replay: PASS");
   Print("4. CandidateProjection report: ok=", candReport.ok, " lines_applied=", candReport.lines_applied,
         " lines_failed=", candReport.lines_failed, " first_error=[", candReport.first_error, "]");

   // 5-7. Run the SAME staged rebuild chain OnInit runs, against the
   // isolated test store. CandidateProjection sits deep inside this
   // chain too (BrokerSubmissionAudit -> ExecutionAudit(C1.3) ->
   // EligibilityDecision -> RiskPlan -> CandidateProjection), so these
   // three also independently re-confirm item 4's own result via the
   // same "black-box gate" staging precedent every C1-C3 projection in
   // this codebase already relies on.
   BrokerSubmissionAuditProjectionReport auditReport = BrokerSubmissionAudit_StartupRebuild(TEST_FILE);
   Check(auditReport.ok, "5. BrokerSubmissionAudit rebuild (stages C1.3 -> Eligibility -> RiskPlan -> CandidateProjection): PASS");
   Print("5. BrokerSubmissionAudit report: ok=", auditReport.ok, " lines_total=", auditReport.lines_total,
         " lines_failed=", auditReport.lines_failed, " first_error=[", auditReport.first_error, "]");

   ManualApprovalProjectionReport approvalReport = ManualApproval_StartupRebuild(TEST_FILE);
   Check(approvalReport.ok, "6. ManualApproval rebuild (stages the same C1.3 chain independently): PASS");
   Print("6. ManualApproval report: ok=", approvalReport.ok, " lines_failed=", approvalReport.lines_failed,
         " first_error=[", approvalReport.first_error, "]");

   bool txReady = TransactionMatching_StartupRebuild(TEST_FILE);
   TransactionMatchingReadinessReport txRep;
   TransactionMatchingReadiness_LastReport(txRep);
   Check(txReady, "7. TransactionMatching startup rebuild (stages BrokerSubmissionAudit as its own gate): PASS");
   Print("7. TransactionMatching report: ok=", txRep.base.ok, " deals_applied=", txRep.base.deals_applied,
         " deals_failed=", txRep.base.deals_failed, " orders_total=", txRep.orders_total,
         " first_error=[", txRep.base.first_error, "]");

   // 8. No orphan-candidate warning anywhere across all four reports.
   bool anyOrphanMention = (StringFind(candReport.first_error, "orphan") >= 0)
                         || (StringFind(auditReport.first_error, "orphan") >= 0)
                         || (StringFind(approvalReport.first_error, "orphan") >= 0)
                         || (StringFind(txRep.base.first_error, "orphan") >= 0);
   Check(!anyOrphanMention, "8. no 'orphan candidate' text anywhere in any of the four reports' first_error");
   Check(candReport.lines_failed == 0 && auditReport.lines_failed == 0 && approvalReport.lines_failed == 0 && txRep.base.deals_failed == 0,
         "8. zero failed lines across every rebuild - nothing was rejected");

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");

   Print("NOTE: this script's own test store (", TEST_FILE, ") is left in place for inspection - it is NOT ",
         "MLQuantAI_events_2026-08-21.jsonl or any other production/daily store, and was never touched.");
}
