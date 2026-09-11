//+------------------------------------------------------------------+
//| MLQuantAI_Test_RA33_2_RecoveryReconciliationEmission.mq5           |
//| RA-33.2 (QA-frozen C4.4 Row-Level Evidence Emission): regression    |
//| for Include/MLQuantAI/Execution/MLQuantAI_RecoveryReconciliationEmission.mqh |
//| - the ONLY file this round's production fix lives in, alongside a   |
//| new event type (MLQuantAI_Enums.mqh) and one call site             |
//| (MLQuantAI.mq5). Covers the 10 QA-required cases plus the exact-    |
//| attribution case for a BLOCK_RECOMMENDED finding.                   |
//|                                                                    |
//| RecoveryReconciliationRow/RecoveryReconciliationReport are pure,    |
//| self-contained data structs (MLQuantAI_RecoveryReconciliation.mqh)  |
//| with no lineage/hash validation dependency on any other projection  |
//| - fixtures here are hand-built directly, no full B5->C1 pipeline    |
//| needed (unlike RA-30.4's ManualApproval suite, which has a real     |
//| orphan/dry-run-accepted validation chain this layer simply does     |
//| not have).                                                          |
//|                                                                    |
//| NOT touched by this file, per QA's explicit scope: OrderSend,       |
//| position 3800463826, EventStore core, RecoveryReconciliation        |
//| engine logic, C4.4 scan algorithm.                                  |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_RecoveryReconciliationEmission.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

#define RA33_2_TEST_FILE "MLQuantAI_Test_RA33_2_Fixture.jsonl"

void BuildRow(RecoveryReconciliationRow &row, string candidateId, ulong orderTicket, bool orderKnown,
               ulong dealTicket, bool dealKnown, string scope, ENUM_RECOVERY_FINDING finding,
               string discriminator, string detail)
{
   RecoveryReconciliationRow_Init(row);
   row.candidate_id = candidateId;
   row.order_ticket = orderTicket;
   row.order_ticket_known = orderKnown;
   row.deal_ticket = dealTicket;
   row.deal_ticket_known = dealKnown;
   row.comparison_scope = scope;
   row.finding = finding;
   row.posture = RecoveryFindingToPosture(finding); // real, unmodified §9.7 table
   row.source_record_discriminator = discriminator;
   row.detail = detail;
}

void MakeSingleRowReport(RecoveryReconciliationReport &report, const RecoveryReconciliationRow &row)
{
   RecoveryReconciliationReport_Init(report);
   ArrayResize(report.rows, 1);
   report.rows[0] = row;
}

// Counts how many raw lines in the isolated fixture file have
// "type":"RECOVERY_RECONCILIATION_ROW_OBSERVED".
int CountEmittedRowEvents()
{
   string lines[];
   int n = EventStore_ReadAllLines(RA33_2_TEST_FILE, lines);
   int count = 0;
   for(int i = 0; i < n; i++)
      if(EventSerializer_GetStr(lines[i], "type") == "RECOVERY_RECONCILIATION_ROW_OBSERVED")
         count++;
   return count;
}

// Returns the LAST such line (most recently appended), or "" if none.
string LastEmittedRowEventLine()
{
   string lines[];
   int n = EventStore_ReadAllLines(RA33_2_TEST_FILE, lines);
   for(int i = n - 1; i >= 0; i--)
      if(EventSerializer_GetStr(lines[i], "type") == "RECOVERY_RECONCILIATION_ROW_OBSERVED")
         return lines[i];
   return "";
}

void OnStart()
{
   Print("=== RA-33.2 Recovery Reconciliation Row Emission - regression test ===");

   if(FileIsExist(RA33_2_TEST_FILE, FILE_COMMON))
      FileDelete(RA33_2_TEST_FILE, FILE_COMMON);
   Check(EventStore_Open(RA33_2_TEST_FILE), "setup: isolated test fixture file opens");

   //====================================================================
   // Case 1: non-clean DEAL row -> emit exactly 1 event
   //====================================================================
   RecoveryReconciliationRow dealRow;
   BuildRow(dealRow, "", 0, false, 3442407998, true, "AGGREGATE_DEAL_VOLUME",
            RECOVERY_ORPHAN_HISTORY_DEAL,
            "RECOVERY_C4_V1|MT5_HISTORY|2026.09.10 23:00:00|2026.09.11 00:00:00|2026.09.10 23:50:00|SESS_test1|1|3442407998|1|0|1||1|DEAL_TYPE_BALANCE|1|0.00000000|1|0.00000000",
            "test: orphan history deal");
   RecoveryReconciliationReport dealReport;
   MakeSingleRowReport(dealReport, dealRow);

   int beforeCase1 = CountEmittedRowEvents();
   RecoveryReconciliationEmissionReport er1 = RecoveryReconciliationEmission_EmitNonCleanRows(dealReport);
   Check(er1.rows_total == 1 && er1.rows_non_clean == 1, "Case1: exactly 1 row scanned, 1 non-clean");
   Check(er1.rows_emitted == 1 && er1.rows_emit_failed == 0, "Case1: exactly 1 row emitted, 0 failures");
   Check(CountEmittedRowEvents() == beforeCase1 + 1, "Case1: DEAL row produces exactly 1 durable event");

   //====================================================================
   // Case 2: non-clean ORDER row -> emit exactly 1 event
   //====================================================================
   RecoveryReconciliationRow orderRow;
   BuildRow(orderRow, "", 3800463826, true, 0, false, "ORDER",
            RECOVERY_WINDOW_INSUFFICIENT,
            "RECOVERY_C4_V1|MT5_HISTORY|2026.09.10 23:00:00|2026.09.11 00:00:00|2026.09.10 23:50:00|SESS_test1|1|3800463826|1|XAUUSD|1|ORDER_TYPE_BUY|1|ORDER_STATE_FILLED",
            "test: window insufficient");
   RecoveryReconciliationReport orderReport;
   MakeSingleRowReport(orderReport, orderRow);

   int beforeCase2 = CountEmittedRowEvents();
   RecoveryReconciliationEmissionReport er2 = RecoveryReconciliationEmission_EmitNonCleanRows(orderReport);
   Check(er2.rows_emitted == 1 && er2.rows_emit_failed == 0, "Case2: exactly 1 ORDER row emitted, 0 failures");
   Check(CountEmittedRowEvents() == beforeCase2 + 1, "Case2: ORDER row produces exactly 1 durable event");

   //====================================================================
   // Case 3: CLEAN/HEALTHY row -> no event
   //====================================================================
   RecoveryReconciliationRow cleanRow;
   BuildRow(cleanRow, "CND_test", 3800463826, true, 3442405520, true, "ORDER",
            RECOVERY_FACT_CORROBORATED, "irrelevant_for_clean_row", "");
   Check(cleanRow.posture == RECOVERY_POSTURE_INFORMATIONAL, "Case3 setup: RECOVERY_FACT_CORROBORATED maps to INFORMATIONAL (unmodified §9.7 table)");
   RecoveryReconciliationReport cleanReport;
   MakeSingleRowReport(cleanReport, cleanRow);

   int beforeCase3 = CountEmittedRowEvents();
   RecoveryReconciliationEmissionReport er3 = RecoveryReconciliationEmission_EmitNonCleanRows(cleanReport);
   Check(er3.rows_total == 1 && er3.rows_non_clean == 0, "Case3: CLEAN row is not counted as non-clean");
   Check(er3.rows_emitted == 0, "Case3: CLEAN row emits nothing");
   Check(CountEmittedRowEvents() == beforeCase3, "Case3: no new durable event for a CLEAN/HEALTHY row");

   //====================================================================
   // Case 4: source_record_discriminator preserved VERBATIM (incl. special chars)
   //====================================================================
   string trickyDiscriminator = "RECOVERY_C4_V1|MT5_HISTORY|has\"quote|has\\backslash|has|pipe|2026.09.10 23:50:00";
   RecoveryReconciliationRow trickyRow;
   BuildRow(trickyRow, "", 0, false, 999888777, true, "AGGREGATE_DEAL_VOLUME",
            RECOVERY_UNMAPPABLE_HISTORY_RECORD, trickyDiscriminator, "test: verbatim preservation");
   RecoveryReconciliationReport trickyReport;
   MakeSingleRowReport(trickyReport, trickyRow);
   RecoveryReconciliationEmission_EmitNonCleanRows(trickyReport);

   string trickyLine = LastEmittedRowEventLine();
   Check(EventSerializer_GetStr(trickyLine, "source_record_discriminator") == trickyDiscriminator,
         "Case4: source_record_discriminator round-trips byte-for-byte, including quote/backslash/pipe characters");

   //====================================================================
   // Case 5: known/unknown ticket semantics preserved (+ position_ticket always UNKNOWN)
   //====================================================================
   RecoveryReconciliationRow unknownTicketRow;
   BuildRow(unknownTicketRow, "", 0, false, 0, false, "AGGREGATE_DEAL_VOLUME",
            RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE, "disc_unknown_ticket_case", "");
   RecoveryReconciliationReport unknownReport;
   MakeSingleRowReport(unknownReport, unknownTicketRow);
   RecoveryReconciliationEmission_EmitNonCleanRows(unknownReport);
   // order_ticket_known/deal_ticket_known/position_ticket_known are
   // written as bare JSON booleans (true/false, unquoted) - EventSerializer_
   // GetStr only matches QUOTED string values (needle "\"key\":\"") so it
   // is the wrong reader here; EventSerializer_GetRawNumber (despite its
   // name, a pure raw-text-until-delimiter extractor, unmodified) reads
   // any unquoted token correctly, same technique EventSerializer_GetLong
   // itself is built on.
   string unknownLine = LastEmittedRowEventLine();
   Check(EventSerializer_GetRawNumber(unknownLine, "order_ticket_known") == "false", "Case5: order_ticket_known=false preserved distinctly from a real 0 ticket");
   Check(EventSerializer_GetRawNumber(unknownLine, "deal_ticket_known") == "false", "Case5: deal_ticket_known=false preserved");
   Check(EventSerializer_GetRawNumber(unknownLine, "position_ticket_known") == "false", "Case5: position_ticket_known is ALWAYS false (no representation in source Fact structs)");
   Check(EventSerializer_GetLong(unknownLine, "position_ticket") == 0, "Case5: position_ticket is always 0 (never fabricated as a real ticket)");

   RecoveryReconciliationRow knownZeroTicketRow;
   BuildRow(knownZeroTicketRow, "", 0, true, 3442407998, true, "AGGREGATE_DEAL_VOLUME",
            RECOVERY_ORPHAN_HISTORY_DEAL, "disc_known_zero_ticket_case", "");
   RecoveryReconciliationReport knownZeroReport;
   MakeSingleRowReport(knownZeroReport, knownZeroTicketRow);
   RecoveryReconciliationEmission_EmitNonCleanRows(knownZeroReport);
   string knownZeroLine = LastEmittedRowEventLine();
   Check(EventSerializer_GetRawNumber(knownZeroLine, "order_ticket_known") == "true" && EventSerializer_GetLong(knownZeroLine, "order_ticket") == 0,
         "Case5: order_ticket_known=true with order_ticket=0 is distinguishable from order_ticket_known=false - exact real-world shape of the RA-33.1 balance-deal finding");

   //====================================================================
   // Case 6: finding serialization round-trip (all 10 values)
   //====================================================================
   ENUM_RECOVERY_FINDING allFindings[10] = {
      RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE, RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE, RECOVERY_WINDOW_INSUFFICIENT,
      RECOVERY_NO_CORROBORATING_HISTORY, RECOVERY_FACT_CORROBORATED, RECOVERY_FACT_CONFLICT,
      RECOVERY_ORPHAN_HISTORY_ORDER, RECOVERY_ORPHAN_HISTORY_DEAL, RECOVERY_DUPLICATE_HISTORY_RECORD,
      RECOVERY_UNMAPPABLE_HISTORY_RECORD
   };
   bool allFindingsRoundTrip = true;
   for(int i = 0; i < 10; i++)
      if(RecoveryFindingFromString(RecoveryFindingToString(allFindings[i])) != allFindings[i])
         allFindingsRoundTrip = false;
   Check(allFindingsRoundTrip, "Case6: all 10 ENUM_RECOVERY_FINDING values round-trip exactly through ToString/FromString");

   //====================================================================
   // Case 7: posture serialization round-trip (all 3 values)
   //====================================================================
   ENUM_RECOVERY_POSTURE allPostures[3] = {
      RECOVERY_POSTURE_INFORMATIONAL, RECOVERY_POSTURE_DEGRADED, RECOVERY_POSTURE_BLOCK_RECOMMENDED
   };
   bool allPosturesRoundTrip = true;
   for(int i = 0; i < 3; i++)
      if(RecoveryPostureFromString(RecoveryPostureToString(allPostures[i])) != allPostures[i])
         allPosturesRoundTrip = false;
   Check(allPosturesRoundTrip, "Case7: all 3 ENUM_RECOVERY_POSTURE values round-trip exactly through ToString/FromString");

   //====================================================================
   // Case 8: emission failure -> fail-closed, counted, never silently "success"
   //====================================================================
   EventStore_Close(); // deterministic write-failure technique, same as RA-30.4's AC-3
   RecoveryReconciliationRow failRow;
   BuildRow(failRow, "", 0, false, 111222333, true, "AGGREGATE_DEAL_VOLUME",
            RECOVERY_ORPHAN_HISTORY_DEAL, "disc_should_fail_to_write", "");
   RecoveryReconciliationReport failReport;
   MakeSingleRowReport(failReport, failRow);
   RecoveryReconciliationEmissionReport er8 = RecoveryReconciliationEmission_EmitNonCleanRows(failReport);
   Check(er8.rows_non_clean == 1, "Case8 setup: row is still correctly classified non-clean even though the store is closed");
   Check(er8.rows_emitted == 0 && er8.rows_emit_failed == 1, "Case8: durable write failure is counted as rows_emit_failed, never as rows_emitted (fail-closed)");
   Check(EventStore_LogRecoveryReconciliationRow(failRow) == false, "Case8: EventStore_LogRecoveryReconciliationRow() itself returns false when the store is closed");
   Check(EventStore_Open(RA33_2_TEST_FILE), "setup: reopen store to continue");

   //====================================================================
   // Case 9: emitted event is structurally distinct from BROKER_TRANSACTION_OBSERVED (never mistakable as L3)
   //====================================================================
   RecoveryReconciliationRow distinctRow;
   BuildRow(distinctRow, "", 0, false, 555666777, true, "AGGREGATE_DEAL_VOLUME",
            RECOVERY_DUPLICATE_HISTORY_RECORD, "disc_case9", "");
   RecoveryReconciliationReport distinctReport;
   MakeSingleRowReport(distinctReport, distinctRow);
   RecoveryReconciliationEmission_EmitNonCleanRows(distinctReport);
   string distinctLine = LastEmittedRowEventLine();
   Check(EventSerializer_GetStr(distinctLine, "type") == "RECOVERY_RECONCILIATION_ROW_OBSERVED",
         "Case9: emitted event's own type field is RECOVERY_RECONCILIATION_ROW_OBSERVED, never BROKER_TRANSACTION_OBSERVED");
   Check(!EventSerializer_HasKey(distinctLine, "retcode") && !EventSerializer_HasKey(distinctLine, "transaction_type"),
         "Case9: emitted event carries none of BROKER_TRANSACTION_OBSERVED's own top-level fields (retcode/transaction_type) - structurally unmistakable for L3");

   //====================================================================
   // Case 10: existing recovery report values are NOT mutated by emission
   //====================================================================
   RecoveryReconciliationRow immutRow;
   BuildRow(immutRow, "CND_immut", 42, true, 43, true, "ORDER", RECOVERY_ORPHAN_HISTORY_ORDER, "disc_immut", "detail_immut");
   RecoveryReconciliationReport immutReport;
   RecoveryReconciliationReport_Init(immutReport);
   immutReport.ok = true;
   immutReport.local_facts_scanned = 7;
   immutReport.recovered_orders_scanned = 3;
   immutReport.recovered_deals_scanned = 2;
   ArrayResize(immutReport.rows, 1);
   immutReport.rows[0] = immutRow;

   bool okBefore = immutReport.ok;
   int localFactsBefore = immutReport.local_facts_scanned;
   int rowsCountBefore = ArraySize(immutReport.rows);
   string candidateIdBefore = immutReport.rows[0].candidate_id;
   RecoveryReconciliationEmission_EmitNonCleanRows(immutReport); // const & parameter - compiler-enforced immutability
   Check(immutReport.ok == okBefore && immutReport.local_facts_scanned == localFactsBefore &&
         ArraySize(immutReport.rows) == rowsCountBefore && immutReport.rows[0].candidate_id == candidateIdBefore,
         "Case10: RecoveryReconciliationReport fields are unchanged after emission - EmitNonCleanRows takes report by const reference (compiler-enforced, not just observed)");

   //====================================================================
   // Attribution test: BLOCK_RECOMMENDED row's discriminator matches the
   // EXACT discriminator the real (unmodified) RecoveryReconciliation_
   // DealDiscriminator() would produce for the real RA-33.1 balance-deal
   // fact (deal_ticket=3442407998, order_ticket=0, DEAL_TYPE_BALANCE) -
   // closes the loop that RA-33.1's manual investigation had to do by
   // hand: this proves the emitted event alone would have been enough.
   //====================================================================
   RecoveredDealHistoryFact realFact;
   RecoveredDealHistoryFact_Init(realFact);
   realFact.schema_version = "RECOVERY_C4_V1";
   realFact.provenance_kind = "MT5_HISTORY";
   realFact.history_select_from = D'2026.09.10 23:00:00';
   realFact.history_select_to   = D'2026.09.11 00:00:00';
   realFact.history_query_server_time = D'2026.09.10 23:49:16';
   realFact.recovery_session_identity = "SESS_b92de2b984fd";
   realFact.source_deal_ticket = 3442407998; realFact.source_deal_ticket_known = true;
   realFact.source_order_ticket = 0;          realFact.source_order_ticket_known = true;
   realFact.symbol = ""; realFact.symbol_known = true;
   realFact.deal_type = "DEAL_TYPE_BALANCE"; realFact.deal_type_known = true;
   realFact.price = 0.0; realFact.price_known = true;
   realFact.volume = 0.0; realFact.volume_known = true;
   string realDiscriminator = RecoveryReconciliation_DealDiscriminator(realFact); // the real, unmodified sealed function

   RecoveryReconciliationRow attribRow;
   BuildRow(attribRow, "", 0, true, 3442407998, true, "AGGREGATE_DEAL_VOLUME",
            RECOVERY_ORPHAN_HISTORY_DEAL, realDiscriminator, "RA-33.1 attribution proof");
   Check(attribRow.posture == RECOVERY_POSTURE_BLOCK_RECOMMENDED, "Attribution setup: RECOVERY_ORPHAN_HISTORY_DEAL maps to BLOCK_RECOMMENDED (unmodified §9.7 table)");
   RecoveryReconciliationReport attribReport;
   MakeSingleRowReport(attribReport, attribRow);
   RecoveryReconciliationEmission_EmitNonCleanRows(attribReport);

   string attribLine = LastEmittedRowEventLine();
   Check(EventSerializer_GetStr(attribLine, "posture") == "BLOCK_RECOMMENDED", "Attribution: emitted posture is BLOCK_RECOMMENDED");
   Check(EventSerializer_GetStr(attribLine, "finding") == "ORPHAN_HISTORY_DEAL", "Attribution: emitted finding is ORPHAN_HISTORY_DEAL");
   Check(EventSerializer_GetStr(attribLine, "source_record_discriminator") == realDiscriminator,
         "Attribution: emitted source_record_discriminator EXACTLY matches the real, unmodified DealDiscriminator() output for the RA-33.1 balance-deal fact - a future block_recommended row would be attributable to its exact broker-history record from this event alone");

   EventStore_Close();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else Print("SOME CHECKS FAILED - see [FAIL] lines above.");
}
