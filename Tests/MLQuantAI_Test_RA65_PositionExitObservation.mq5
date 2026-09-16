//+------------------------------------------------------------------+
//| MLQuantAI_Test_RA65_PositionExitObservation.mq5                     |
//| RA-65 Slice 2 (QA-frozen Addendums A/B/C): proves the pure decision   |
//| core in MLQuantAI_PositionExitObservation.mqh - reducing-deal          |
//| classification, FULL/PARTIAL classification, closing_deal_ticket        |
//| idempotency (duplicate-same-payload vs conflicting-payload), durable      |
//| POSITION_CLOSED emission/round-trip fidelity, restart/rebuild survival,    |
//| and both Safe Mode failure paths (conflicting payload, durable write        |
//| failure).                                                                     |
//|                                                                                |
//| Deliberately does NOT exercise PositionExitObservation_Handle() itself -        |
//| that orchestration function calls live PositionSelectByTicket()/                 |
//| PositionGetDouble(), the same live-Position*-dependent class                       |
//| BrokerReconciliation_HasMatchingPosition() already has, and which this               |
//| project's own precedent (Tests/MLQuantAI_Test_BrokerReconciliation.mq5's own          |
//| header comment) proves via real runtime evidence, not an automated fixture.             |
//| Every DECISION the handler makes is instead exercised here directly, pure and            |
//| fabricated. No OrderSend, no OnTradeTransaction wiring exercised - running on a            |
//| real account is safe.                                                                        |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_PositionExitObservation.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_RA65_PositionExitObservation.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void MakeFact(PositionClosedFact &f, ulong positionTicket, ulong closingDealTicket, ulong orderTicket,
               string execReqId, string candidateId, string correlationId,
               ENUM_POSITION_CLOSE_KIND closeKind, double volumeClosed, double volumeRemaining,
               string symbol, double price)
{
   PositionClosedFact_Init(f);
   f.position_ticket = positionTicket;
   f.closing_deal_ticket = closingDealTicket;
   f.order_ticket = orderTicket;
   f.execution_request_id = execReqId;
   f.candidate_id = candidateId;
   f.correlation_id = correlationId;
   f.close_kind = closeKind;
   f.volume_closed = volumeClosed;
   f.volume_remaining = volumeRemaining;
   f.symbol = symbol;
   f.price = price;
}

void OnStart()
{
   Print("=== MLQuantAI_Test_RA65_PositionExitObservation.mq5 ===");

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   SafeMode_Clear();
   Check(EventStore_Open(TEST_EVENT_STORE_FILE), "setup: event store opens");

   //=====================================================================
   // 1. Reducing-deal classification (Addendum B, part 1) - "missing
   //    close evidence": an entry/averaging-in deal never qualifies.
   //=====================================================================
   Print("--- reducing-deal classification ---");
   Check(PositionExit_IsReducingDeal(DEAL_TYPE_SELL, ORDER_TYPE_BUY), "BUY candidate + SELL deal = reducing");
   Check(!PositionExit_IsReducingDeal(DEAL_TYPE_BUY, ORDER_TYPE_BUY), "BUY candidate + BUY deal = NOT reducing (averaging-in, missing close evidence)");
   Check(PositionExit_IsReducingDeal(DEAL_TYPE_BUY, ORDER_TYPE_SELL), "SELL candidate + BUY deal = reducing");
   Check(!PositionExit_IsReducingDeal(DEAL_TYPE_SELL, ORDER_TYPE_SELL), "SELL candidate + SELL deal = NOT reducing (averaging-in, missing close evidence)");

   //=====================================================================
   // 2. FULL vs PARTIAL classification (Addendum B, part 2).
   //=====================================================================
   Print("--- FULL/PARTIAL classification from a live-position snapshot ---");
   {
      PositionLiveSnapshot notFound;
      PositionLiveSnapshot_Init(notFound);
      notFound.found = false;
      Check(PositionExit_ClassifyCloseKind(notFound) == POSITION_CLOSE_KIND_FULL, "position not found -> FULL");

      PositionLiveSnapshot stillOpen;
      PositionLiveSnapshot_Init(stillOpen);
      stillOpen.found = true;
      stillOpen.volume = 0.03;
      Check(PositionExit_ClassifyCloseKind(stillOpen) == POSITION_CLOSE_KIND_PARTIAL, "position still found (any volume) -> PARTIAL");
   }

   //=====================================================================
   // 3. FULL close: fresh emission + durable round-trip fidelity.
   //=====================================================================
   Print("--- FULL close: fresh emission, durable line round-trips exactly ---");
   {
      PositionClosedFact fact;
      MakeFact(fact, 7101, 9101, 5101, "EXECREQ_ra65s2_a", "CND_ra65s2_a", "CORR_ra65s2_a",
                POSITION_CLOSE_KIND_FULL, 0.05, 0.0, "XAUUSD", 100.25);

      string linesBefore[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesBefore);
      Check(PositionExitObservation_EmitIfNeeded(fact, linesBefore), "EmitIfNeeded succeeds for a fresh FULL close");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      Check(ArraySize(linesAfter) == ArraySize(linesBefore) + 1, "exactly one new durable line appended");

      ENUM_POSITION_CLOSED_IDEMPOTENCY idem = PositionClosedFact_CheckIdempotency(fact, linesAfter);
      Check(idem == POSITION_CLOSED_IDEMPOTENCY_DUPLICATE_SAME_PAYLOAD, "the just-written fact now reads back as a duplicate-same-payload");

      // Round-trip fidelity: re-parse the actual written line and compare every field.
      PositionClosedFact roundTripped;
      bool found = false;
      for(int i = 0; i < ArraySize(linesAfter); i++)
      {
         if(EventSerializer_GetStr(linesAfter[i], "type") != "POSITION_CLOSED") continue;
         if((ulong)EventSerializer_GetLong(linesAfter[i], "closing_deal_ticket") != fact.closing_deal_ticket) continue;
         PositionClosedFact_FromLine(linesAfter[i], roundTripped);
         found = true;
         break;
      }
      Check(found, "the durable POSITION_CLOSED line is locatable");
      Check(PositionClosedFact_SamePayload(fact, roundTripped), "round-tripped fact matches the original exactly");
      Check(roundTripped.close_kind == POSITION_CLOSE_KIND_FULL, "round-tripped close_kind == FULL");
   }

   //=====================================================================
   // 4. PARTIAL close: fresh emission, distinct closing_deal_ticket.
   //=====================================================================
   Print("--- PARTIAL close: fresh emission ---");
   {
      PositionClosedFact fact;
      MakeFact(fact, 7102, 9102, 5102, "EXECREQ_ra65s2_b", "CND_ra65s2_b", "CORR_ra65s2_b",
                POSITION_CLOSE_KIND_PARTIAL, 0.02, 0.03, "XAUUSD", 100.50);

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
      Check(PositionExitObservation_EmitIfNeeded(fact, lines), "EmitIfNeeded succeeds for a fresh PARTIAL close");

      string linesAfter[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfter);
      PositionClosedFact roundTripped;
      for(int i = 0; i < ArraySize(linesAfter); i++)
      {
         if(EventSerializer_GetStr(linesAfter[i], "type") != "POSITION_CLOSED") continue;
         if((ulong)EventSerializer_GetLong(linesAfter[i], "closing_deal_ticket") != fact.closing_deal_ticket) continue;
         PositionClosedFact_FromLine(linesAfter[i], roundTripped);
         break;
      }
      Check(roundTripped.close_kind == POSITION_CLOSE_KIND_PARTIAL, "round-tripped close_kind == PARTIAL");
      Check(roundTripped.volume_remaining == 0.03, "volume_remaining preserved exactly");
   }

   //=====================================================================
   // 5. Duplicate identical close: same fact emitted twice -> no second
   //    line, no error.
   //=====================================================================
   Print("--- duplicate identical close: idempotent no-op, no second durable line ---");
   {
      PositionClosedFact fact;
      MakeFact(fact, 7103, 9103, 5103, "EXECREQ_ra65s2_c", "CND_ra65s2_c", "CORR_ra65s2_c",
                POSITION_CLOSE_KIND_FULL, 0.04, 0.0, "XAUUSD", 101.00);

      string lines1[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines1);
      Check(PositionExitObservation_EmitIfNeeded(fact, lines1), "first emission succeeds");

      string lines2[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines2);
      int countBeforeSecondCall = ArraySize(lines2);
      Check(PositionExitObservation_EmitIfNeeded(fact, lines2), "second, identical emission also reports success (no-op)");

      string lines3[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines3);
      Check(ArraySize(lines3) == countBeforeSecondCall, "no new durable line was appended by the duplicate call");
      Check(!SafeMode_IsActive(), "duplicate-same-payload never trips Safe Mode");
   }

   //=====================================================================
   // 6. Duplicate conflicting close: same closing_deal_ticket, different
   //    field -> Safe Mode trips, no second line.
   //=====================================================================
   Print("--- duplicate conflicting close: Safe Mode trips, never silently overwritten ---");
   {
      PositionClosedFact original;
      MakeFact(original, 7104, 9104, 5104, "EXECREQ_ra65s2_d", "CND_ra65s2_d", "CORR_ra65s2_d",
                 POSITION_CLOSE_KIND_FULL, 0.06, 0.0, "XAUUSD", 102.00);

      string lines1[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines1);
      Check(PositionExitObservation_EmitIfNeeded(original, lines1), "original close emits successfully");

      PositionClosedFact conflicting;
      MakeFact(conflicting, 7104, 9104, 5104, "EXECREQ_ra65s2_d", "CND_ra65s2_d", "CORR_ra65s2_d",
                 POSITION_CLOSE_KIND_PARTIAL, 0.06, 0.01, "XAUUSD", 102.00); // same ticket, different close_kind/volume_remaining

      string lines2[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines2);
      int countBeforeConflict = ArraySize(lines2);
      Check(!SafeMode_IsActive(), "sanity: Safe Mode not yet active before the conflicting call");
      Check(!PositionExitObservation_EmitIfNeeded(conflicting, lines2), "conflicting-payload emission reports failure");
      Check(SafeMode_IsActive(), "conflicting payload trips Safe Mode");
      Check(StringFind(SafeMode_Reason(), "9104") >= 0, "Safe Mode reason names the conflicting closing_deal_ticket");

      string lines3[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines3);
      Check(ArraySize(lines3) == countBeforeConflict, "no new durable line was appended for the conflicting fact");

      SafeMode_Clear();
   }

   //=====================================================================
   // 7. Restart/rebuild: idempotency survives an EventStore close+reopen
   //    (simulating an EA restart), reading fresh lines from disk.
   //=====================================================================
   Print("--- restart/rebuild: duplicate detection survives EventStore close+reopen ---");
   {
      PositionClosedFact fact;
      MakeFact(fact, 7105, 9105, 5105, "EXECREQ_ra65s2_e", "CND_ra65s2_e", "CORR_ra65s2_e",
                POSITION_CLOSE_KIND_FULL, 0.07, 0.0, "XAUUSD", 103.00);

      string linesBefore[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesBefore);
      Check(PositionExitObservation_EmitIfNeeded(fact, linesBefore), "emission succeeds before the simulated restart");

      EventStore_Close();
      Check(EventStore_Open(TEST_EVENT_STORE_FILE), "simulated restart: event store reopens on the same file");

      string linesAfterRestart[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, linesAfterRestart);
      ENUM_POSITION_CLOSED_IDEMPOTENCY idem = PositionClosedFact_CheckIdempotency(fact, linesAfterRestart);
      Check(idem == POSITION_CLOSED_IDEMPOTENCY_DUPLICATE_SAME_PAYLOAD, "post-restart, the fact is still recognized as an already-recorded duplicate");
      Check(PositionExitObservation_EmitIfNeeded(fact, linesAfterRestart), "post-restart re-emission is still a clean no-op, not a Safe Mode trip");
      Check(!SafeMode_IsActive(), "no Safe Mode trip across the simulated restart");
   }

   //=====================================================================
   // 8. Safe Mode failure path: the durable write itself fails (store
   //    closed) for a genuinely fresh, non-duplicate fact.
   //=====================================================================
   Print("--- Safe Mode failure path: durable write failure (EventStore closed) ---");
   {
      PositionClosedFact fact;
      MakeFact(fact, 7106, 9106, 5106, "EXECREQ_ra65s2_f", "CND_ra65s2_f", "CORR_ra65s2_f",
                POSITION_CLOSE_KIND_FULL, 0.08, 0.0, "XAUUSD", 104.00);

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines); // read while still open
      EventStore_Close();

      Check(!SafeMode_IsActive(), "sanity: Safe Mode not yet active before the write-failure attempt");
      Check(!PositionExitObservation_EmitIfNeeded(fact, lines), "emission reports failure when the durable write itself fails");
      Check(SafeMode_IsActive(), "durable write failure trips Safe Mode");

      SafeMode_Clear();
      Check(EventStore_Open(TEST_EVENT_STORE_FILE), "cleanup: event store reopens for the final tally");
   }

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
