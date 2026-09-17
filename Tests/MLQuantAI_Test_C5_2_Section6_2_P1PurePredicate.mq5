//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Section6_2_P1PurePredicate.mq5                  |
//| §6.2 Evidence-Gate Design Contract Rev.8: pure-predicate-level        |
//| coverage of P1_VerifyNoDuplicateSubmissionsInWindow(), called DIRECTLY |
//| with synthetic SubmissionAttemptProjectionRecord entries and minimal    |
//| fabricated lines[] - bypassing BrokerSubmissionAuditProjection_          |
//| RebuildFromFile entirely.                                                 |
//|                                                                             |
//| Exists specifically because QA's ruling (this checkpoint's Test              |
//| Authorization round) confirmed DUPLICATE_CONFLICTING is UNREACHABLE           |
//| through the authoritative E2E path (a conflicting-hash duplicate is            |
//| caught by the audit-chain rebuild's own tamper check first, surfacing as        |
//| audit_chain_broken - see MLQuantAI_Test_C5_2_Section6_2_                          |
//| RolloutGateReadinessEvaluate.mq5's own Test_P1_Conflicting for the empirical         |
//| proof of that). QA explicitly authorized testing this branch here instead,           |
//| at the pure-predicate level with synthetic inputs fed directly to the                   |
//| function, rather than forcing production logic to make it E2E-reachable.                 |
//|                                                                                             |
//| No EventStore file is opened for the registry construction below - only the                 |
//| module-global SubmissionAttemptProjection registry (reset/populated directly)                 |
//| and a small, deliberately minimal, hand-written lines[] array whose only job                   |
//| is to let FindLineIndexByLogEventId() resolve each record's source_log_event_id                   |
//| back to a window position. No OrderSend/CTrade anywhere in this file.                                |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_RolloutGateReadinessEvaluate.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void AppendSyntheticAttempt(string requestId, string requestHash, string correlationId, string logEventId)
{
   SubmissionAttemptProjectionRecord rec;
   SubmissionAttemptProjectionRecord_Init(rec);
   rec.execution_request_id   = requestId;
   rec.execution_request_hash = requestHash;
   rec.correlation_id         = correlationId;
   rec.submit_attempt         = 1;
   rec.source_log_event_id    = logEventId;
   rec.source_sequence_number = 0; // deliberately unused by P1 - window membership is decided via the array index, never this field
   SubmissionAttemptProjection_AppendRecord(rec);
}

void OnStart()
{
   Print("=== MLQuantAI_Test_C5_2_Section6_2_P1PurePredicate.mq5 ===");

   //=====================================================================
   Print("--- 0 in-window attempts -> P1 passes trivially (reason stays NONE) ---");
   {
      SubmissionAttemptProjection_Reset();
      string lines[1];
      lines[0] = "{\"log_event_id\":\"L0\"}"; // windowStartIndex itself - never counted (index <= windowStartIndex is excluded)
      AppendSyntheticAttempt("REQ_A", "HASH_A", "CORR_A", "L0");

      RolloutGateReadinessResult res = P1_VerifyNoDuplicateSubmissionsInWindow(lines, 0);
      Check(res.reason == ROLLOUT_GATE_READINESS_NONE, "the ONLY record sits AT windowStartIndex, not after it - excluded, P1 passes");
   }

   //=====================================================================
   Print("--- one in-window attempt, no duplicate -> P1 passes ---");
   {
      SubmissionAttemptProjection_Reset();
      string lines[2];
      lines[0] = "{\"log_event_id\":\"L0\"}";
      lines[1] = "{\"log_event_id\":\"L1\"}";
      AppendSyntheticAttempt("REQ_A", "HASH_A", "CORR_A", "L1");

      RolloutGateReadinessResult res = P1_VerifyNoDuplicateSubmissionsInWindow(lines, 0);
      Check(res.reason == ROLLOUT_GATE_READINESS_NONE, "exactly one in-window attempt, nothing to collide with - P1 passes");
   }

   //=====================================================================
   Print("--- two different execution_request_ids in-window -> P1 passes (no shared id, not a duplicate) ---");
   {
      SubmissionAttemptProjection_Reset();
      string lines[3];
      lines[0] = "{\"log_event_id\":\"L0\"}";
      lines[1] = "{\"log_event_id\":\"L1\"}";
      lines[2] = "{\"log_event_id\":\"L2\"}";
      AppendSyntheticAttempt("REQ_A", "HASH_A", "CORR_A", "L1");
      AppendSyntheticAttempt("REQ_B", "HASH_B", "CORR_B", "L2");

      RolloutGateReadinessResult res = P1_VerifyNoDuplicateSubmissionsInWindow(lines, 0);
      Check(res.reason == ROLLOUT_GATE_READINESS_NONE, "two distinct execution_request_ids in-window - not a duplicate pair, P1 passes");
   }

   //=====================================================================
   Print("--- duplicate_exact: same execution_request_id, same execution_request_hash, both in-window -> DUPLICATE_EXACT ---");
   {
      SubmissionAttemptProjection_Reset();
      string lines[3];
      lines[0] = "{\"log_event_id\":\"L0\"}";
      lines[1] = "{\"log_event_id\":\"L1\"}";
      lines[2] = "{\"log_event_id\":\"L2\"}";
      AppendSyntheticAttempt("REQ_A", "HASH_A", "CORR_A", "L1");
      AppendSyntheticAttempt("REQ_A", "HASH_A", "CORR_A", "L2");

      RolloutGateReadinessResult res = P1_VerifyNoDuplicateSubmissionsInWindow(lines, 0);
      Check(res.reason == ROLLOUT_GATE_READINESS_DUPLICATE_EXACT, "reason == DUPLICATE_EXACT");
   }

   //=====================================================================
   Print("--- duplicate_conflicting (pure predicate only - CONFIRMED UNREACHABLE via the real E2E/authoritative path per QA's ruling): "
         "same execution_request_id, DIFFERENT execution_request_hash, both in-window -> DUPLICATE_CONFLICTING ---");
   {
      SubmissionAttemptProjection_Reset();
      string lines[3];
      lines[0] = "{\"log_event_id\":\"L0\"}";
      lines[1] = "{\"log_event_id\":\"L1\"}";
      lines[2] = "{\"log_event_id\":\"L2\"}";
      AppendSyntheticAttempt("REQ_A", "HASH_A", "CORR_A", "L1");
      AppendSyntheticAttempt("REQ_A", "HASH_B_DIFFERENT", "CORR_A", "L2");

      RolloutGateReadinessResult res = P1_VerifyNoDuplicateSubmissionsInWindow(lines, 0);
      Check(res.reason == ROLLOUT_GATE_READINESS_DUPLICATE_CONFLICTING,
            "reason == DUPLICATE_CONFLICTING - the predicate itself is correct in isolation, even though the real audit-chain rebuild "
            "never lets this data shape reach it in production (see the companion E2E test file's own Test_P1_Conflicting)");
   }

   //=====================================================================
   Print("--- a record whose source_log_event_id has no matching line in lines[] -> AUDIT_CHAIN_BROKEN (fail-closed, never silently skipped) ---");
   {
      SubmissionAttemptProjection_Reset();
      string lines[1];
      lines[0] = "{\"log_event_id\":\"L0\"}";
      AppendSyntheticAttempt("REQ_A", "HASH_A", "CORR_A", "L_MISSING");

      RolloutGateReadinessResult res = P1_VerifyNoDuplicateSubmissionsInWindow(lines, 0);
      Check(res.reason == ROLLOUT_GATE_READINESS_AUDIT_CHAIN_BROKEN, "reason == AUDIT_CHAIN_BROKEN when the log_event_id cannot be located in the snapshot");
   }

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
