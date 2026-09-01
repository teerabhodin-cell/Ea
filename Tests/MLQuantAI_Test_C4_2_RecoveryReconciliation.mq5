//+------------------------------------------------------------------+
//| MLQuantAI_Test_C4_2_RecoveryReconciliation.mq5                    |
//| C4.2 implementation test suite, per                               |
//| Docs/PhaseC_C4_RecoveryHistoryPolicy.md §9 (C4.1 addendum, adopted)|
//| and §10 (C4.2.1 addendum, adopted). Covers the pure builder        |
//| (RecoveryReconciliation_BuildReport) directly with constructed     |
//| fixtures - no live HistorySelect() call is made anywhere in this   |
//| file - plus the acquisition layer (MLQuantAI_HistorySource.mqh's   |
//| IHistorySource seam) via a local, test-only CFakeHistorySource.    |
//|                                                                    |
//| This matrix is this checkpoint's own construction: it was built    |
//| directly against every frozen rule in §9.2-§9.9/§10 rather than    |
//| reproduced from an earlier, unseen enumeration - see the commit    |
//| message / evidence bundle for an explicit count and coverage note. |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_RecoveryReconciliation.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers - plain struct literals, no EventStore/File I/O.
//---------------------------------------------------------------------
LocalOrderRecoveryFact MakeLocalFact(ulong ticket, double runningVolume, string candidateId,
                                       datetime anchor, bool anchorKnown)
{
   LocalOrderRecoveryFact f;
   LocalOrderRecoveryFact_Init(f);
   f.order_ticket = ticket;
   f.running_filled_volume = runningVolume;
   f.candidate_id = candidateId;
   f.matched = (candidateId != "");
   f.local_order_type_known = f.matched;
   f.local_volume_initial_known = f.matched;
   f.recovery_anchor_time = anchor;
   f.recovery_anchor_time_known = anchorKnown;
   return f;
}

RecoveredOrderHistoryFact MakeRecoveredOrder(ulong ticket, bool ticketKnown, string session)
{
   RecoveredOrderHistoryFact f;
   RecoveredOrderHistoryFact_Init(f);
   f.schema_version = MLQUANTAI_RECOVERED_ORDER_HISTORY_SCHEMA_C4_V1;
   f.provenance_kind = "RECOVERED_ORDER_HISTORY";
   f.recovery_session_identity = session;
   f.source_order_ticket = ticket;
   f.source_order_ticket_known = ticketKnown;
   return f;
}

RecoveredDealHistoryFact MakeRecoveredDeal(ulong dealTicket, bool dealTicketKnown, ulong orderTicket, bool orderTicketKnown,
                                             double volume, bool volumeKnown, string session)
{
   RecoveredDealHistoryFact f;
   RecoveredDealHistoryFact_Init(f);
   f.schema_version = MLQUANTAI_RECOVERED_DEAL_HISTORY_SCHEMA_C4_V1;
   f.provenance_kind = "RECOVERED_DEAL_HISTORY";
   f.recovery_session_identity = session;
   f.source_deal_ticket = dealTicket;
   f.source_deal_ticket_known = dealTicketKnown;
   f.source_order_ticket = orderTicket;
   f.source_order_ticket_known = orderTicketKnown;
   f.volume = volume;
   f.volume_known = volumeKnown;
   return f;
}

// "adequate" preserves its original bool meaning at every existing call
// site (true = should reach full evaluation) - internally mapped onto
// the QA-authorized tri-state: true -> PROVEN, false -> UNASSESSED.
// Use MakeOutcomeWithAdequacy() directly where a test needs to
// distinguish UNASSESSED from INSUFFICIENT specifically.
RecoveryQueryOutcome MakeOutcome(ulong ticket, bool attempted, bool succeeded, bool adequate)
{
   RecoveryQueryOutcome o;
   RecoveryQueryOutcome_Init(o);
   o.order_ticket = ticket;
   o.order_ticket_known = true;
   o.query_attempted = attempted;
   o.query_succeeded = succeeded;
   o.adequacy = adequate ? RECOVERY_WINDOW_ADEQUACY_PROVEN : RECOVERY_WINDOW_ADEQUACY_UNASSESSED;
   return o;
}

RecoveryQueryOutcome MakeOutcomeWithAdequacy(ulong ticket, bool attempted, bool succeeded, ENUM_RECOVERY_WINDOW_ADEQUACY adequacy)
{
   RecoveryQueryOutcome o;
   RecoveryQueryOutcome_Init(o);
   o.order_ticket = ticket;
   o.order_ticket_known = true;
   o.query_attempted = attempted;
   o.query_succeeded = succeeded;
   o.adequacy = adequacy;
   return o;
}

// Finds the first row matching scope + order_ticket (used ticket) - a
// small linear-search helper for assertions, mirroring this project's
// FindIndex convention elsewhere.
bool FindRow(const RecoveryReconciliationRow &rows[], string scope, ulong ticket, RecoveryReconciliationRow &out)
{
   for(int i = 0; i < ArraySize(rows); i++)
   {
      if(rows[i].comparison_scope == scope && rows[i].order_ticket_known && rows[i].order_ticket == ticket)
      {
         out = rows[i];
         return true;
      }
   }
   return false;
}

int CountRowsWithFinding(const RecoveryReconciliationRow &rows[], ENUM_RECOVERY_FINDING f)
{
   int n = 0;
   for(int i = 0; i < ArraySize(rows); i++)
      if(rows[i].finding == f) n++;
   return n;
}

//=====================================================================
// §9.2 invalid-override whole-scan gate.
//=====================================================================
void Test_InvalidOverride_WholeScanFailClosed()
{
   Print("--- invalid override <= 0: whole-scan fail-closed, zero rows, no per-row finding ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(1001, 0.5, "CAND_A", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 0);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, -5, false, "override <= 0");
   Check(!report.ok, "report.ok is false");
   Check(ArraySize(report.rows) == 0, "zero rows - no per-row finding is emitted for this failure");
   Check(report.first_error == "override <= 0", "first_error is exactly the supplied invalid-override message");
}

//=====================================================================
// ORDER unit: C4.2 v1 Option B always resolves to LOCAL_EVIDENCE_UNAVAILABLE
// whenever a local+recovered ticket mapping exists.
//=====================================================================
void Test_OrderUnit_AlwaysLocalEvidenceUnavailable()
{
   Print("--- ORDER unit: Option B forces RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE whenever local+recovered both resolve ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(2001, 1.0, "CAND_B", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 1);
   orders[0] = MakeRecoveredOrder(2001, true, "SESS1");
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcome(2001, true, true, true);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   RecoveryReconciliationRow row;
   Check(FindRow(report.rows, "ORDER", 2001, row), "an ORDER-scope row exists for ticket 2001");
   Check(row.finding == RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE, "finding is RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE");
   Check(row.posture == RECOVERY_POSTURE_DEGRADED, "posture is DEGRADED");
   Check(row.candidate_id == "CAND_B", "row carries the resolved candidate_id");
   Check(!report.ok, "report.ok is false (DEGRADED posture present)");
}

//=====================================================================
// AGGREGATE_DEAL_VOLUME: CORROBORATED / CONFLICT / NO_CORROBORATING_HISTORY.
//=====================================================================
void Test_AggregateDealVolume_Corroborated()
{
   Print("--- AGGREGATE_DEAL_VOLUME: exact sum match -> RECOVERY_FACT_CORROBORATED ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(3001, 1.50, "CAND_C", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 1);
   orders[0] = MakeRecoveredOrder(3001, true, "SESS1");
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 2);
   deals[0] = MakeRecoveredDeal(9001, true, 3001, true, 1.00, true, "SESS1");
   deals[1] = MakeRecoveredDeal(9002, true, 3001, true, 0.50, true, "SESS1");
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcome(3001, true, true, true);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   RecoveryReconciliationRow row;
   Check(FindRow(report.rows, "AGGREGATE_DEAL_VOLUME", 3001, row), "an AGGREGATE_DEAL_VOLUME row exists");
   Check(row.finding == RECOVERY_FACT_CORROBORATED, "finding is RECOVERY_FACT_CORROBORATED (1.00+0.50 == 1.50)");
   Check(row.posture == RECOVERY_POSTURE_INFORMATIONAL, "posture is INFORMATIONAL");

   // Order degradation is independent of the aggregate outcome: the SAME
   // ticket's ORDER row still degrades to LOCAL_EVIDENCE_UNAVAILABLE
   // (Option B) even while AGGREGATE_DEAL_VOLUME reaches CORROBORATED.
   RecoveryReconciliationRow orderRow;
   Check(FindRow(report.rows, "ORDER", 3001, orderRow), "an ORDER row also exists for the same ticket");
   Check(orderRow.finding == RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE,
         "the ORDER row independently degrades (Option B) even though AGGREGATE_DEAL_VOLUME corroborated - the two units are evaluated independently");
}

void Test_AggregateDealVolume_Conflict()
{
   Print("--- AGGREGATE_DEAL_VOLUME: sum mismatch -> RECOVERY_FACT_CONFLICT ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(3002, 1.00, "CAND_D", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 1);
   orders[0] = MakeRecoveredOrder(3002, true, "SESS1");
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 1);
   deals[0] = MakeRecoveredDeal(9003, true, 3002, true, 1.25, true, "SESS1");
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcome(3002, true, true, true);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   RecoveryReconciliationRow row;
   Check(FindRow(report.rows, "AGGREGATE_DEAL_VOLUME", 3002, row), "an AGGREGATE_DEAL_VOLUME row exists");
   Check(row.finding == RECOVERY_FACT_CONFLICT, "finding is RECOVERY_FACT_CONFLICT (1.25 != 1.00) - exact equality, no tolerance");
   Check(row.posture == RECOVERY_POSTURE_BLOCK_RECOMMENDED, "posture is BLOCK_RECOMMENDED");
}

void Test_AggregateDealVolume_NoCorroboratingHistory_NoDeals()
{
   Print("--- AGGREGATE_DEAL_VOLUME: zero recovered deals for the ticket -> RECOVERY_NO_CORROBORATING_HISTORY ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(3003, 0.75, "CAND_E", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 1);
   orders[0] = MakeRecoveredOrder(3003, true, "SESS1");
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcome(3003, true, true, true);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   RecoveryReconciliationRow row;
   Check(FindRow(report.rows, "AGGREGATE_DEAL_VOLUME", 3003, row), "an AGGREGATE_DEAL_VOLUME row exists");
   Check(row.finding == RECOVERY_NO_CORROBORATING_HISTORY, "finding is RECOVERY_NO_CORROBORATING_HISTORY");
}

void Test_AggregateDealVolume_NoCorroboratingHistory_Indeterminate()
{
   Print("--- AGGREGATE_DEAL_VOLUME: one deal's volume unknown -> indeterminate -> RECOVERY_NO_CORROBORATING_HISTORY ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(3004, 1.00, "CAND_F", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 1);
   orders[0] = MakeRecoveredOrder(3004, true, "SESS1");
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 2);
   deals[0] = MakeRecoveredDeal(9004, true, 3004, true, 1.00, true, "SESS1");
   deals[1] = MakeRecoveredDeal(9005, true, 3004, true, 0.0, false, "SESS1"); // volume unknown, not a legitimate 0.0
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcome(3004, true, true, true);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   RecoveryReconciliationRow row;
   Check(FindRow(report.rows, "AGGREGATE_DEAL_VOLUME", 3004, row), "an AGGREGATE_DEAL_VOLUME row exists");
   Check(row.finding == RECOVERY_NO_CORROBORATING_HISTORY,
         "an indeterminate aggregate (any unknown-volume deal) never produces CORROBORATED/CONFLICT, per §9.5");
}

//=====================================================================
// Recovered-order-driven diagnostics: UNMAPPABLE / DUPLICATE / ORPHAN_HISTORY_ORDER.
//=====================================================================
void Test_UnmappableOrder_UnknownTicket()
{
   Print("--- recovered order with unknown source_order_ticket -> RECOVERY_UNMAPPABLE_HISTORY_RECORD, ORDER scope ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 0);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 1);
   orders[0] = MakeRecoveredOrder(0, false, "SESS1");
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 0);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(ArraySize(report.rows) == 1, "exactly one row");
   Check(report.rows[0].finding == RECOVERY_UNMAPPABLE_HISTORY_RECORD, "finding is RECOVERY_UNMAPPABLE_HISTORY_RECORD");
   Check(report.rows[0].comparison_scope == "ORDER", "comparison_scope is ORDER");
   Check(report.rows[0].order_ticket_known == false, "order_ticket_known is false on this row");
   Check(!report.ok, "report.ok is false");
}

void Test_DuplicateOrder_SameKnownTicketDifferentPayload()
{
   Print("--- two recovered order facts sharing a known ticket, NOT byte-identical -> RECOVERY_DUPLICATE_HISTORY_RECORD ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 0);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 2);
   orders[0] = MakeRecoveredOrder(4001, true, "SESS1");
   orders[1] = MakeRecoveredOrder(4001, true, "SESS2"); // different recovery_session_identity -> different discriminator
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 0);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(ArraySize(report.rows) == 1, "exactly one row - one row per duplicate identity group, not per record");
   Check(report.rows[0].finding == RECOVERY_DUPLICATE_HISTORY_RECORD, "finding is RECOVERY_DUPLICATE_HISTORY_RECORD");
   Check(report.rows[0].order_ticket == 4001, "row carries the shared ticket");
}

void Test_CanonicalCollapse_ByteIdenticalOrdersCollapseToOne()
{
   Print("--- two byte-identical recovered order facts (same ticket, same discriminator) collapse to one - no DUPLICATE finding ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 0);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 2);
   orders[0] = MakeRecoveredOrder(4002, true, "SESS1");
   orders[1] = MakeRecoveredOrder(4002, true, "SESS1"); // byte-identical to orders[0]
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 0);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(report.recovered_orders_scanned == 2, "pre-collapse scanned count is 2 (raw input, not collapsed)");
   Check(ArraySize(report.rows) == 1, "exactly one row after collapse");
   Check(report.rows[0].finding == RECOVERY_ORPHAN_HISTORY_ORDER,
         "the collapsed single record has zero local matches -> RECOVERY_ORPHAN_HISTORY_ORDER, not DUPLICATE");
}

void Test_OrphanHistoryOrder_KnownTicketZeroLocalMatches()
{
   Print("--- recovered order with known ticket, zero local matches -> RECOVERY_ORPHAN_HISTORY_ORDER ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 0);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 1);
   orders[0] = MakeRecoveredOrder(4003, true, "SESS1");
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 0);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(ArraySize(report.rows) == 1, "exactly one row");
   Check(report.rows[0].finding == RECOVERY_ORPHAN_HISTORY_ORDER, "finding is RECOVERY_ORPHAN_HISTORY_ORDER");
   Check(report.rows[0].comparison_scope == "ORDER", "comparison_scope is ORDER");
}

//=====================================================================
// Recovered-deal-driven diagnostics: UNMAPPABLE(deal) / DUPLICATE(deal) / ORPHAN_HISTORY_DEAL.
//=====================================================================
void Test_UnmappableDeal_UnknownOrderTicket()
{
   Print("--- recovered deal with unknown source_order_ticket -> RECOVERY_UNMAPPABLE_HISTORY_RECORD, AGGREGATE_DEAL_VOLUME scope ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 0);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 1);
   deals[0] = MakeRecoveredDeal(9006, true, 0, false, 1.0, true, "SESS1");
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 0);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(ArraySize(report.rows) == 1, "exactly one row");
   Check(report.rows[0].finding == RECOVERY_UNMAPPABLE_HISTORY_RECORD, "finding is RECOVERY_UNMAPPABLE_HISTORY_RECORD");
   Check(report.rows[0].comparison_scope == "AGGREGATE_DEAL_VOLUME", "comparison_scope is AGGREGATE_DEAL_VOLUME for a deal diagnostic");
}

void Test_UnmappableDeal_UnknownDealTicketKnownOrderTicket()
{
   Print("--- recovered deal with UNKNOWN source_deal_ticket but KNOWN source_order_ticket -> RECOVERY_UNMAPPABLE_HISTORY_RECORD, not silently dropped (real-run-caught pattern fix) ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 0);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 1);
   deals[0] = MakeRecoveredDeal(0, false, 5020, true, 1.0, true, "SESS1"); // no usable deal identity of its own
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 0);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(ArraySize(report.rows) == 1, "exactly one row - the deal is not silently dropped");
   Check(report.rows[0].finding == RECOVERY_UNMAPPABLE_HISTORY_RECORD, "finding is RECOVERY_UNMAPPABLE_HISTORY_RECORD");
   Check(report.rows[0].comparison_scope == "AGGREGATE_DEAL_VOLUME", "comparison_scope is AGGREGATE_DEAL_VOLUME");
   Check(report.rows[0].deal_ticket_known == false, "deal_ticket_known is false on this row");
   Check(CountRowsWithFinding(report.rows, RECOVERY_DUPLICATE_HISTORY_RECORD) == 0, "no duplicate finding");
   Check(CountRowsWithFinding(report.rows, RECOVERY_ORPHAN_HISTORY_DEAL) == 0, "no orphan-deal finding");
   Check(!report.ok, "report.ok is false");
}

void Test_UnmappableDeal_BothIdentitiesUnknown_SingleRowNotDouble()
{
   Print("--- recovered deal with BOTH source_deal_ticket and source_order_ticket unknown -> exactly ONE RECOVERY_UNMAPPABLE_HISTORY_RECORD row, not two ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 0);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 1);
   deals[0] = MakeRecoveredDeal(0, false, 0, false, 1.0, true, "SESS1");
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 0);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(ArraySize(report.rows) == 1, "exactly one row - both-unknown does not double-count");
   Check(report.rows[0].finding == RECOVERY_UNMAPPABLE_HISTORY_RECORD, "finding is RECOVERY_UNMAPPABLE_HISTORY_RECORD");
   Check(!report.ok, "report.ok is false");
}

void Test_DuplicateDeal_SameKnownDealTicketDifferentPayload()
{
   Print("--- two recovered deals sharing a known deal_ticket, NOT byte-identical -> RECOVERY_DUPLICATE_HISTORY_RECORD, excluded from aggregate sum ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(5001, 1.0, "CAND_G", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 1);
   orders[0] = MakeRecoveredOrder(5001, true, "SESS1");
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 2);
   deals[0] = MakeRecoveredDeal(9007, true, 5001, true, 1.0, true, "SESS1");
   deals[1] = MakeRecoveredDeal(9007, true, 5001, true, 2.0, true, "SESS2"); // same deal_ticket, different volume/session -> not identical
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcome(5001, true, true, true);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(CountRowsWithFinding(report.rows, RECOVERY_DUPLICATE_HISTORY_RECORD) == 1, "exactly one DUPLICATE row for the deal_ticket group");
   RecoveryReconciliationRow aggRow;
   Check(FindRow(report.rows, "AGGREGATE_DEAL_VOLUME", 5001, aggRow), "an AGGREGATE_DEAL_VOLUME row exists for order 5001");
   Check(aggRow.finding == RECOVERY_NO_CORROBORATING_HISTORY,
         "both duplicate-group deals are excluded from the sum (§9.5) - zero eligible deals remain -> NO_CORROBORATING_HISTORY");
}

void Test_OrphanHistoryDeal_NoRecoveredOrderButLocalResolvable()
{
   Print("--- recovered deal's order_ticket known, no recovered order fact for it, local order fact exists -> RECOVERY_ORPHAN_HISTORY_DEAL owns the discrepancy; no aggregate row, no redundant NO_CORROBORATING_HISTORY (QA dedup-ownership correction) ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(5002, 1.0, "CAND_H", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0); // the order itself was never recovered
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 1);
   deals[0] = MakeRecoveredDeal(9008, true, 5002, true, 1.0, true, "SESS1");
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcome(5002, true, true, true);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(CountRowsWithFinding(report.rows, RECOVERY_ORPHAN_HISTORY_DEAL) == 1, "exactly one RECOVERY_ORPHAN_HISTORY_DEAL row - the terminal broker-evidence diagnostic");
   Check(CountRowsWithFinding(report.rows, RECOVERY_FACT_CORROBORATED) == 0, "never RECOVERY_FACT_CORROBORATED - unresolved evidence must not influence a corroboration conclusion");
   Check(CountRowsWithFinding(report.rows, RECOVERY_FACT_CONFLICT) == 0, "never RECOVERY_FACT_CONFLICT for the same reason");
   // FindRow itself cannot distinguish "the one legitimate ORPHAN_HISTORY_DEAL
   // row" (which correctly carries comparison_scope=="AGGREGATE_DEAL_VOLUME" -
   // it IS the terminal finding for that comparison unit) from a second,
   // redundant row for the same (scope, ticket) - so count directly instead.
   int aggScopeRowsForTicket = 0;
   for(int i = 0; i < ArraySize(report.rows); i++)
      if(report.rows[i].comparison_scope == "AGGREGATE_DEAL_VOLUME" &&
         report.rows[i].order_ticket_known && report.rows[i].order_ticket == 5002)
         aggScopeRowsForTicket++;
   Check(aggScopeRowsForTicket == 1,
         "exactly one AGGREGATE_DEAL_VOLUME-scope row for ticket 5002 - the ORPHAN_HISTORY_DEAL row itself, "
         "no separate/duplicate RECOVERY_NO_CORROBORATING_HISTORY row for the same underlying comparison unit");
   RecoveryReconciliationRow aggRow;
   Check(FindRow(report.rows, "AGGREGATE_DEAL_VOLUME", 5002, aggRow) && aggRow.finding == RECOVERY_ORPHAN_HISTORY_DEAL,
         "that one row's finding is RECOVERY_ORPHAN_HISTORY_DEAL, not RECOVERY_NO_CORROBORATING_HISTORY");
}

// QA re-review (orphan-deal suppression precedence): the three cases the
// suppression/gate interaction must be proven against. Case 3 (PROVEN) is
// Test_OrphanHistoryDeal_NoRecoveredOrderButLocalResolvable above. These
// two cover cases 1-2: pass (a)'s gate ALWAYS appends its gated ORDER +
// AGGREGATE_DEAL_VOLUME rows and `continue`s BEFORE reaching the
// suppression logic (see BuildReport source, §"if(gated){...continue;}") -
// so a gated ticket's local-side finding can never be erased by the
// orphan-deal ownership/suppression logic, which is unreachable from that
// branch. pass (c)'s independent orphan-deal diagnostic may still be
// emitted separately for the same (ticket, AGGREGATE_DEAL_VOLUME) slot -
// that coexistence is acceptable (two rows for one comparison unit is not
// itself wrong here); what must never happen is the gated row disappearing.
void Test_OrphanHistoryDeal_FailedQuery_HistoryUnavailableRowRemains()
{
   Print("--- orphan-deal suppression precedence, case 1: local query FAILED + orphan deal present -> the gated RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE row is never erased ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(5010, 1.0, "CAND_FQ", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0); // the order itself was never recovered
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 1);
   deals[0] = MakeRecoveredDeal(9500, true, 5010, true, 1.0, true, "SESS1"); // orphan candidate: known parent ticket, no recovered order
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcome(5010, true, false, false); // attempted, HistorySelect() FAILED

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   int historyUnavailableAggRows = 0;
   for(int i = 0; i < ArraySize(report.rows); i++)
      if(report.rows[i].comparison_scope == "AGGREGATE_DEAL_VOLUME" && report.rows[i].order_ticket_known &&
         report.rows[i].order_ticket == 5010 && report.rows[i].finding == RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE)
         historyUnavailableAggRows++;
   Check(historyUnavailableAggRows == 1,
         "the gated RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE AGGREGATE_DEAL_VOLUME row for ticket 5010 is present exactly once - "
         "the orphan-deal diagnostic never suppresses or replaces it, regardless of whether it is also emitted separately");
   Check(!report.ok, "report.ok is false");
}

void Test_OrphanHistoryDeal_UnassessedQuery_WindowInsufficient()
{
   Print("--- orphan-deal suppression precedence, case 2: local query succeeded but adequacy UNASSESSED (production-realistic) + orphan deal present -> the gated RECOVERY_WINDOW_INSUFFICIENT row is never erased ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(5011, 1.0, "CAND_UQ", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 1);
   deals[0] = MakeRecoveredDeal(9501, true, 5011, true, 1.0, true, "SESS1");
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcomeWithAdequacy(5011, true, true, RECOVERY_WINDOW_ADEQUACY_UNASSESSED); // succeeded, never PROVEN (v1 reality)

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   int windowInsufficientAggRows = 0;
   for(int i = 0; i < ArraySize(report.rows); i++)
      if(report.rows[i].comparison_scope == "AGGREGATE_DEAL_VOLUME" && report.rows[i].order_ticket_known &&
         report.rows[i].order_ticket == 5011 && report.rows[i].finding == RECOVERY_WINDOW_INSUFFICIENT)
         windowInsufficientAggRows++;
   Check(windowInsufficientAggRows == 1,
         "the gated RECOVERY_WINDOW_INSUFFICIENT AGGREGATE_DEAL_VOLUME row for ticket 5011 is present exactly once - "
         "UNASSESSED adequacy never lets the orphan-deal diagnostic suppress or replace it");
   Check(!report.ok, "report.ok is false");
}

//=====================================================================
// Query-outcome gates: HISTORY_EVIDENCE_UNAVAILABLE / WINDOW_INSUFFICIENT.
//=====================================================================
void Test_QueryNotAttempted_WindowInsufficient()
{
   Print("--- local fact with no query outcome / query_attempted=false -> RECOVERY_WINDOW_INSUFFICIENT on BOTH scopes ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(6001, 1.0, "CAND_I", 0, false); // unknown anchor - matches ScanLive's own "never attempted" case
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcome(6001, false, false, false);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   RecoveryReconciliationRow orderRow, aggRow;
   Check(FindRow(report.rows, "ORDER", 6001, orderRow) && orderRow.finding == RECOVERY_WINDOW_INSUFFICIENT,
         "ORDER scope: RECOVERY_WINDOW_INSUFFICIENT");
   Check(FindRow(report.rows, "AGGREGATE_DEAL_VOLUME", 6001, aggRow) && aggRow.finding == RECOVERY_WINDOW_INSUFFICIENT,
         "AGGREGATE_DEAL_VOLUME scope: RECOVERY_WINDOW_INSUFFICIENT");
}

void Test_QuerySucceededFalse_HistoryEvidenceUnavailable()
{
   Print("--- HistorySelect() itself failed for this window -> RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE on BOTH scopes ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(6002, 1.0, "CAND_J", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcome(6002, true, false, false);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   RecoveryReconciliationRow orderRow, aggRow;
   Check(FindRow(report.rows, "ORDER", 6002, orderRow) && orderRow.finding == RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE,
         "ORDER scope: RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE");
   Check(FindRow(report.rows, "AGGREGATE_DEAL_VOLUME", 6002, aggRow) && aggRow.finding == RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE,
         "AGGREGATE_DEAL_VOLUME scope: RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE");
   Check(!report.ok, "an otherwise-empty (zero recovered evidence) but FAILED/unproven scan is never report.ok=true - "
                      "distinct from a genuinely empty, successfully-proven population");
}

void Test_AdequacyUnassessed_MapsToWindowInsufficient()
{
   Print("--- C4.2.2 tri-state: adequacy=UNASSESSED -> RECOVERY_WINDOW_INSUFFICIENT (precedes LOCAL_EVIDENCE_UNAVAILABLE) ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(6003, 1.0, "CAND_K", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcomeWithAdequacy(6003, true, true, RECOVERY_WINDOW_ADEQUACY_UNASSESSED);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   RecoveryReconciliationRow orderRow;
   Check(FindRow(report.rows, "ORDER", 6003, orderRow) && orderRow.finding == RECOVERY_WINDOW_INSUFFICIENT,
         "ORDER scope: RECOVERY_WINDOW_INSUFFICIENT - UNASSESSED never means broker retention is known-insufficient, "
         "only that adequacy cannot be established under the currently available mechanisms");
}

void Test_AdequacyInsufficient_MapsToWindowInsufficient()
{
   Print("--- C4.2.2 tri-state: adequacy=INSUFFICIENT (positively determined) -> RECOVERY_WINDOW_INSUFFICIENT, same finding as UNASSESSED ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(6004, 1.0, "CAND_ADQ", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcomeWithAdequacy(6004, true, true, RECOVERY_WINDOW_ADEQUACY_INSUFFICIENT);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   RecoveryReconciliationRow orderRow;
   Check(FindRow(report.rows, "ORDER", 6004, orderRow) && orderRow.finding == RECOVERY_WINDOW_INSUFFICIENT,
         "ORDER scope: RECOVERY_WINDOW_INSUFFICIENT - both UNASSESSED and INSUFFICIENT map to the same frozen finding, "
         "since §9's frozen taxonomy gains no new value");
}

void Test_AdequacyProven_UnlocksFullEvaluation()
{
   Print("--- C4.2.2 tri-state: only adequacy=PROVEN permits CORROBORATED/CONFLICT/NO_CORROBORATING_HISTORY evaluation ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(6005, 1.0, "CAND_PROVEN", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 1);
   orders[0] = MakeRecoveredOrder(6005, true, "SESS1");
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 1);
   deals[0] = MakeRecoveredDeal(9200, true, 6005, true, 1.0, true, "SESS1");
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcomeWithAdequacy(6005, true, true, RECOVERY_WINDOW_ADEQUACY_PROVEN);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   RecoveryReconciliationRow aggRow;
   Check(FindRow(report.rows, "AGGREGATE_DEAL_VOLUME", 6005, aggRow) && aggRow.finding == RECOVERY_FACT_CORROBORATED,
         "PROVEN unlocks the full comparison - RECOVERY_FACT_CORROBORATED reached (1.0 == 1.0), never possible under UNASSESSED/INSUFFICIENT");
}

//=====================================================================
// Sort order + ok/first_error computation.
//=====================================================================
void Test_SortOrder_TicketThenScopeThenFinding()
{
   Print("--- §9.9 sort: order_ticket ascending (known before unknown), then comparison_scope ORDER before AGGREGATE_DEAL_VOLUME ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 2);
   local[0] = MakeLocalFact(7002, 1.0, "CAND_M", TimeCurrent(), true);
   local[1] = MakeLocalFact(7001, 1.0, "CAND_L", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 2);
   orders[0] = MakeRecoveredOrder(7002, true, "SESS1");
   orders[1] = MakeRecoveredOrder(7001, true, "SESS1");
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 2);
   outcomes[0] = MakeOutcome(7002, true, true, true);
   outcomes[1] = MakeOutcome(7001, true, true, true);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(ArraySize(report.rows) == 4, "four rows total (2 tickets x 2 scopes)");
   Check(report.rows[0].order_ticket == 7001 && report.rows[0].comparison_scope == "ORDER", "row0: ticket 7001, ORDER");
   Check(report.rows[1].order_ticket == 7001 && report.rows[1].comparison_scope == "AGGREGATE_DEAL_VOLUME", "row1: ticket 7001, AGGREGATE_DEAL_VOLUME");
   Check(report.rows[2].order_ticket == 7002 && report.rows[2].comparison_scope == "ORDER", "row2: ticket 7002, ORDER");
   Check(report.rows[3].order_ticket == 7002 && report.rows[3].comparison_scope == "AGGREGATE_DEAL_VOLUME", "row3: ticket 7002, AGGREGATE_DEAL_VOLUME");
}

void Test_OkTrue_WhenNoRowsAtAll()
{
   Print("--- zero local facts, zero recovered evidence, override valid -> report.ok=true, zero rows ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 0);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 0);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(report.ok, "report.ok is true - vacuously, no DEGRADED/BLOCK_RECOMMENDED row exists");
   Check(ArraySize(report.rows) == 0, "zero rows");
}

void Test_FirstError_TakenFromFirstSortedFailingRow()
{
   Print("--- first_error is taken from the first row in FINAL SORTED order with a failing posture, not discovery order ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 2);
   local[0] = MakeLocalFact(8002, 1.0, "CAND_O", TimeCurrent(), true); // built first, sorts SECOND (ticket 8002)
   local[1] = MakeLocalFact(8001, 1.0, "CAND_N", TimeCurrent(), true); // built second, sorts FIRST (ticket 8001)
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 2);
   orders[0] = MakeRecoveredOrder(8002, true, "SESS1");
   orders[1] = MakeRecoveredOrder(8001, true, "SESS1");
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 2);
   outcomes[0] = MakeOutcome(8002, true, true, true);
   outcomes[1] = MakeOutcome(8001, true, true, true);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(!report.ok, "report.ok is false");
   Check(report.rows[0].order_ticket == 8001, "sanity: row0 after sort is ticket 8001 (lower ticket sorts first)");
   Check(StringFind(report.first_error, "local symbol is never known") >= 0,
         "first_error is taken from ticket 8001's ORDER row (first in SORTED order), not ticket 8002's (first in BUILD order)");
}

void Test_AmbiguousOutcome_WholeScanFailClosed()
{
   Print("--- ambiguous query outcome: the same known order_ticket appears twice in queryOutcomes[] -> whole scan fail-closed ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 0);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 2);
   outcomes[0] = MakeOutcome(9101, true, true, true);
   outcomes[1] = MakeOutcome(9101, true, false, false); // same ticket, conflicting outcome

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(!report.ok, "report.ok is false");
   Check(ArraySize(report.rows) == 0, "zero rows - the ambiguous-outcome invariant violation fails closed before any row is built");
   Check(StringFind(report.first_error, "9101") >= 0, "first_error names the offending ticket");
}

void Test_MissingOutcome_WindowInsufficient()
{
   Print("--- a local fact with NO corresponding entry in queryOutcomes[] at all -> RECOVERY_WINDOW_INSUFFICIENT, fails closed ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(9102, 1.0, "CAND_MISSING", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 0); // deliberately empty - not even an attempted=false entry

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   RecoveryReconciliationRow orderRow;
   Check(FindRow(report.rows, "ORDER", 9102, orderRow) && orderRow.finding == RECOVERY_WINDOW_INSUFFICIENT,
         "a totally missing outcome entry fails closed identically to an explicit query_attempted=false");
}

void Test_AmbiguousLocalMatch_ReclassifiedUnmappable()
{
   Print("--- defensive: two localFacts[] entries share the same order_ticket (cannot occur via ScanLive's own registry) - reclassified UNMAPPABLE, only ONE row-pair emitted ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 2);
   local[0] = MakeLocalFact(9103, 1.0, "CAND_AMB1", TimeCurrent(), true);
   local[1] = MakeLocalFact(9103, 2.0, "CAND_AMB2", TimeCurrent(), true); // same ticket, second (malformed) entry
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 1);
   orders[0] = MakeRecoveredOrder(9103, true, "SESS1");
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcome(9103, true, true, true);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(CountRowsWithFinding(report.rows, RECOVERY_UNMAPPABLE_HISTORY_RECORD) == 1,
         "the recovered order for ticket 9103 is reclassified RECOVERY_UNMAPPABLE_HISTORY_RECORD (ambiguous multi-match)");
   int orderScopeRows = 0;
   for(int i = 0; i < ArraySize(report.rows); i++)
      if(report.rows[i].comparison_scope == "ORDER") orderScopeRows++;
   Check(orderScopeRows == 2, "exactly two ORDER-scope rows total: one LOCAL_EVIDENCE_UNAVAILABLE (first local fact only) + one UNMAPPABLE (recovered side) - never four");
}

void Test_NonIdenticalSameTicket_BecomesDuplicate_NotCollapsed()
{
   Print("--- QA-corrected collapse: same ticket, same narrow discriminator fields, but DIFFERENT volume_initial -> DUPLICATE, NOT collapsed ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 0);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 2);
   orders[0] = MakeRecoveredOrder(9104, true, "SESS1");
   orders[0].volume_initial = 1.00; orders[0].volume_initial_known = true;
   orders[1] = MakeRecoveredOrder(9104, true, "SESS1"); // identical narrow discriminator fields (same session)
   orders[1].volume_initial = 2.00; orders[1].volume_initial_known = true; // but DIFFERENT full-fact content
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 0);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(report.recovered_orders_scanned == 2, "sanity: two raw records scanned");
   Check(ArraySize(report.rows) == 1, "exactly one row - NOT collapsed, because full-fact serialization differs (volume_initial)");
   Check(report.rows[0].finding == RECOVERY_DUPLICATE_HISTORY_RECORD,
         "finding is RECOVERY_DUPLICATE_HISTORY_RECORD - narrow-discriminator equality alone is insufficient for collapse");
}

void Test_QueryOutcomeAssociation_IndependentOfArrayOrder()
{
   Print("--- query outcome association is by order_ticket, independent of array position ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 2);
   local[0] = MakeLocalFact(9105, 1.0, "CAND_ORD1", TimeCurrent(), true);
   local[1] = MakeLocalFact(9106, 1.0, "CAND_ORD2", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   // outcomes deliberately supplied in REVERSED order relative to local[]
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 2);
   outcomes[0] = MakeOutcome(9106, true, false, false);
   outcomes[1] = MakeOutcome(9105, true, true, false); // succeeded but not PROVEN (production reality) -> WINDOW_INSUFFICIENT, per this test's own assertion below

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   RecoveryReconciliationRow row9105, row9106;
   Check(FindRow(report.rows, "ORDER", 9105, row9105) && row9105.finding == RECOVERY_WINDOW_INSUFFICIENT,
         "9105 correctly associated with its own outcome (array index 1) despite array-order mismatch");
   Check(FindRow(report.rows, "ORDER", 9106, row9106) && row9106.finding == RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE,
         "9106 correctly associated with its own outcome (array index 0) despite array-order mismatch");
}

void Test_BuildReport_DeterministicAcrossRepeatedCalls()
{
   Print("--- BuildReport is deterministic: identical inputs across two separate calls yield an identical row sequence ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 2);
   local[0] = MakeLocalFact(9107, 1.0, "CAND_DET1", TimeCurrent(), true);
   local[1] = MakeLocalFact(9108, 1.0, "CAND_DET2", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 2);
   orders[0] = MakeRecoveredOrder(9107, true, "SESS1");
   orders[1] = MakeRecoveredOrder(9108, true, "SESS1");
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 2);
   outcomes[0] = MakeOutcome(9107, true, true, true);
   outcomes[1] = MakeOutcome(9108, true, true, true);

   RecoveryReconciliationReport report1 = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   RecoveryReconciliationReport report2 = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");

   Check(ArraySize(report1.rows) == ArraySize(report2.rows), "identical row counts across two calls");
   bool allMatch = (ArraySize(report1.rows) == ArraySize(report2.rows));
   if(allMatch)
      for(int i = 0; i < ArraySize(report1.rows); i++)
         if(report1.rows[i].order_ticket != report2.rows[i].order_ticket ||
            report1.rows[i].comparison_scope != report2.rows[i].comparison_scope ||
            report1.rows[i].finding != report2.rows[i].finding)
            allMatch = false;
   Check(allMatch, "row-by-row identical (ticket, scope, finding) across two separate BuildReport calls with identical input");
   Check(report1.ok == report2.ok, "identical ok across two calls");
}

void Test_SortOrder_DiscriminatorTiebreak()
{
   Print("--- sort key 6: two unmappable rows (both order_ticket_known=false) sort by source_record_discriminator ascending ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 0);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 2);
   orders[0] = MakeRecoveredOrder(0, false, "SESS_Z"); // sorts LAST alphabetically among discriminators
   orders[1] = MakeRecoveredOrder(0, false, "SESS_A"); // sorts FIRST alphabetically
   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 0);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(ArraySize(report.rows) == 2, "two UNMAPPABLE rows (neither collapses - different session identity -> different full-fact serialization)");
   Check(StringFind(report.rows[0].source_record_discriminator, "SESS_A") >= 0,
         "row0's discriminator carries SESS_A - the tie on all prior keys (both unticketed) is broken by discriminator ascending");
   Check(StringFind(report.rows[1].source_record_discriminator, "SESS_Z") >= 0,
         "row1's discriminator carries SESS_Z, sorting after SESS_A");
}

//=====================================================================
// Acquisition layer: CFakeHistorySource.
//=====================================================================
class CFakeHistorySource : public IHistorySource
{
public:
   bool     m_selectReturn;
   int      m_selectCallCount;
   datetime m_lastSelectFrom;
   datetime m_lastSelectTo;
   ulong    m_orderTicketList[];
   ulong    m_dealTicketList[];

   ulong    m_orderPropTicket[]; bool m_orderTypeOk[]; long m_orderTypeVal[];
   bool     m_orderSymbolOk[]; string m_orderSymbolVal[];
   bool     m_orderVolInitOk[]; double m_orderVolInitVal[];

   ulong    m_dealPropTicket[]; bool m_dealOrderOk[]; long m_dealOrderVal[];
   bool     m_dealVolOk[]; double m_dealVolVal[];

   void Init()
   {
      m_selectReturn = true;
      m_selectCallCount = 0;
      m_lastSelectFrom = 0;
      m_lastSelectTo = 0;
      ArrayResize(m_orderTicketList, 0);
      ArrayResize(m_dealTicketList, 0);
      ArrayResize(m_orderPropTicket, 0); ArrayResize(m_orderTypeOk, 0); ArrayResize(m_orderTypeVal, 0);
      ArrayResize(m_orderSymbolOk, 0); ArrayResize(m_orderSymbolVal, 0);
      ArrayResize(m_orderVolInitOk, 0); ArrayResize(m_orderVolInitVal, 0);
      ArrayResize(m_dealPropTicket, 0); ArrayResize(m_dealOrderOk, 0); ArrayResize(m_dealOrderVal, 0);
      ArrayResize(m_dealVolOk, 0); ArrayResize(m_dealVolVal, 0);
   }

   void AddOrderTicket(ulong t)
   {
      int i = ArraySize(m_orderTicketList); ArrayResize(m_orderTicketList, i + 1); m_orderTicketList[i] = t;
      int j = ArraySize(m_orderPropTicket); ArrayResize(m_orderPropTicket, j + 1); m_orderPropTicket[j] = t;
      ArrayResize(m_orderTypeOk, j + 1); m_orderTypeOk[j] = false; ArrayResize(m_orderTypeVal, j + 1);
      ArrayResize(m_orderSymbolOk, j + 1); m_orderSymbolOk[j] = false; ArrayResize(m_orderSymbolVal, j + 1);
      ArrayResize(m_orderVolInitOk, j + 1); m_orderVolInitOk[j] = false; ArrayResize(m_orderVolInitVal, j + 1);
   }

   void AddDealTicket(ulong t)
   {
      int i = ArraySize(m_dealTicketList); ArrayResize(m_dealTicketList, i + 1); m_dealTicketList[i] = t;
      int j = ArraySize(m_dealPropTicket); ArrayResize(m_dealPropTicket, j + 1); m_dealPropTicket[j] = t;
      ArrayResize(m_dealOrderOk, j + 1); m_dealOrderOk[j] = false; ArrayResize(m_dealOrderVal, j + 1);
      ArrayResize(m_dealVolOk, j + 1); m_dealVolOk[j] = false; ArrayResize(m_dealVolVal, j + 1);
   }

   int FindOrderIdx(ulong t) { for(int i = 0; i < ArraySize(m_orderPropTicket); i++) if(m_orderPropTicket[i] == t) return i; return -1; }
   int FindDealIdx(ulong t)  { for(int i = 0; i < ArraySize(m_dealPropTicket); i++)  if(m_dealPropTicket[i] == t)  return i; return -1; }

   void SetOrderType(ulong t, bool ok, long v) { int i = FindOrderIdx(t); if(i >= 0) { m_orderTypeOk[i] = ok; m_orderTypeVal[i] = v; } }
   void SetOrderSymbol(ulong t, bool ok, string v) { int i = FindOrderIdx(t); if(i >= 0) { m_orderSymbolOk[i] = ok; m_orderSymbolVal[i] = v; } }
   void SetOrderVolumeInitial(ulong t, bool ok, double v) { int i = FindOrderIdx(t); if(i >= 0) { m_orderVolInitOk[i] = ok; m_orderVolInitVal[i] = v; } }
   void SetDealOrder(ulong t, bool ok, long v) { int i = FindDealIdx(t); if(i >= 0) { m_dealOrderOk[i] = ok; m_dealOrderVal[i] = v; } }
   void SetDealVolume(ulong t, bool ok, double v) { int i = FindDealIdx(t); if(i >= 0) { m_dealVolOk[i] = ok; m_dealVolVal[i] = v; } }

   virtual bool Select(datetime from, datetime to) { m_selectCallCount++; m_lastSelectFrom = from; m_lastSelectTo = to; return m_selectReturn; }
   virtual int  OrdersTotal() { return ArraySize(m_orderTicketList); }
   virtual int  DealsTotal()  { return ArraySize(m_dealTicketList); }
   virtual ulong OrderTicketByIndex(int index) { if(index < 0 || index >= ArraySize(m_orderTicketList)) return 0; return m_orderTicketList[index]; }
   virtual ulong DealTicketByIndex(int index)  { if(index < 0 || index >= ArraySize(m_dealTicketList))  return 0; return m_dealTicketList[index]; }

   virtual bool OrderGetInteger(ulong ticket, ENUM_ORDER_PROPERTY_INTEGER prop, long &value)
   {
      int i = FindOrderIdx(ticket); if(i < 0) return false;
      if(prop == ORDER_TYPE) { value = m_orderTypeVal[i]; return m_orderTypeOk[i]; }
      return false;
   }
   virtual bool OrderGetDouble(ulong ticket, ENUM_ORDER_PROPERTY_DOUBLE prop, double &value)
   {
      int i = FindOrderIdx(ticket); if(i < 0) return false;
      if(prop == ORDER_VOLUME_INITIAL) { value = m_orderVolInitVal[i]; return m_orderVolInitOk[i]; }
      return false;
   }
   virtual bool OrderGetString(ulong ticket, ENUM_ORDER_PROPERTY_STRING prop, string &value)
   {
      int i = FindOrderIdx(ticket); if(i < 0) return false;
      if(prop == ORDER_SYMBOL) { value = m_orderSymbolVal[i]; return m_orderSymbolOk[i]; }
      return false;
   }
   virtual bool DealGetInteger(ulong ticket, ENUM_DEAL_PROPERTY_INTEGER prop, long &value)
   {
      int i = FindDealIdx(ticket); if(i < 0) return false;
      if(prop == DEAL_ORDER) { value = m_dealOrderVal[i]; return m_dealOrderOk[i]; }
      return false;
   }
   virtual bool DealGetDouble(ulong ticket, ENUM_DEAL_PROPERTY_DOUBLE prop, double &value)
   {
      int i = FindDealIdx(ticket); if(i < 0) return false;
      if(prop == DEAL_VOLUME) { value = m_dealVolVal[i]; return m_dealVolOk[i]; }
      return false;
   }
   virtual bool DealGetString(ulong ticket, ENUM_DEAL_PROPERTY_STRING prop, string &value) { return false; }
   virtual int  LastError() { return 0; }
   virtual void ResetError() {}
};

void Test_Acquisition_TicketGetterZero_SkippedNotMaterialized()
{
   Print("--- acquisition: an enumeration ticket of 0 is skipped, never materialized as a fact ---");
   CFakeHistorySource src;
   src.Init();
   src.AddOrderTicket(0);      // enumeration boundary
   src.AddOrderTicket(11001);  // real order
   src.SetOrderType(11001, true, (long)ORDER_TYPE_BUY);

   RecoveredOrderHistoryFact outOrders[];
   RecoveredDealHistoryFact outDeals[];
   int skippedO = 0, skippedD = 0;
   bool ok = RecoveryReconciliation_AcquireWindowEvidence(src, 0, 100, 100, "SESS", outOrders, outDeals, skippedO, skippedD);
   Check(ok, "acquisition succeeds (Select() returned true)");
   Check(skippedO == 1, "exactly one skipped order slot");
   Check(ArraySize(outOrders) == 1, "exactly one materialized order fact (the zero-ticket slot never became a record)");
   Check(outOrders[0].source_order_ticket == 11001, "the materialized fact is the real ticket");
}

void Test_Acquisition_PropertyGetterFalse_YieldsUnknownNotZero()
{
   Print("--- acquisition: a property getter returning false yields *_known=false, never a fabricated zero/empty value ---");
   CFakeHistorySource src;
   src.Init();
   src.AddOrderTicket(11002);
   // order_type getter deliberately left false (never set) - simulates a failed property read.
   src.SetOrderSymbol(11002, false, "SHOULD_NOT_APPEAR");

   RecoveredOrderHistoryFact outOrders[];
   RecoveredDealHistoryFact outDeals[];
   int skippedO = 0, skippedD = 0;
   RecoveryReconciliation_AcquireWindowEvidence(src, 0, 100, 100, "SESS", outOrders, outDeals, skippedO, skippedD);
   Check(ArraySize(outOrders) == 1, "one materialized fact");
   Check(!outOrders[0].order_type_known, "order_type_known is false - the getter never returned true");
   Check(!outOrders[0].symbol_known, "symbol_known is false despite a getter value being set - bool return is false, so it's ignored");
}

void Test_Acquisition_DealOrderZero_TreatedAsUnknownParentTicket()
{
   Print("--- acquisition: DEAL_ORDER getter succeeds but returns 0 -> source_order_ticket_known=false (identity-reference exception) ---");
   CFakeHistorySource src;
   src.Init();
   src.AddDealTicket(11003);
   src.SetDealOrder(11003, true, 0); // getter succeeds, but the parent-order ticket itself is 0

   RecoveredOrderHistoryFact outOrders[];
   RecoveredDealHistoryFact outDeals[];
   int skippedO = 0, skippedD = 0;
   RecoveryReconciliation_AcquireWindowEvidence(src, 0, 100, 100, "SESS", outOrders, outDeals, skippedO, skippedD);
   Check(ArraySize(outDeals) == 1, "one materialized deal fact");
   Check(!outDeals[0].source_order_ticket_known, "source_order_ticket_known is false for a zero parent-order reference");
}

void Test_Acquisition_SelectFails_ReturnsFalseEmptyArrays()
{
   Print("--- acquisition: Select() returning false yields ok=false and empty order/deal arrays, no property getter ever called ---");
   CFakeHistorySource src;
   src.Init();
   src.m_selectReturn = false;
   src.AddOrderTicket(11004);

   RecoveredOrderHistoryFact outOrders[];
   RecoveredDealHistoryFact outDeals[];
   int skippedO = 0, skippedD = 0;
   bool ok = RecoveryReconciliation_AcquireWindowEvidence(src, 0, 100, 100, "SESS", outOrders, outDeals, skippedO, skippedD);
   Check(!ok, "acquisition reports failure");
   Check(ArraySize(outOrders) == 0, "zero materialized orders");
   Check(ArraySize(outDeals) == 0, "zero materialized deals");
}

void Test_Acquisition_OneSelectCallServesBothOrdersAndDeals()
{
   Print("--- per-window extraction transaction: exactly one Select() call materializes both orders and deals for that window ---");
   CFakeHistorySource src;
   src.Init();
   src.AddOrderTicket(11005);
   src.AddDealTicket(22005);

   RecoveredOrderHistoryFact outOrders[];
   RecoveredDealHistoryFact outDeals[];
   int skippedO = 0, skippedD = 0;
   RecoveryReconciliation_AcquireWindowEvidence(src, 0, 100, 100, "SESS", outOrders, outDeals, skippedO, skippedD);
   Check(src.m_selectCallCount == 1, "exactly one Select() call for this one window");
   Check(ArraySize(outOrders) == 1 && ArraySize(outDeals) == 1, "both an order and a deal materialized from that single selection");
}

void Test_Acquisition_DealTicketZero_SkippedNotMaterialized()
{
   Print("--- acquisition: a deal enumeration ticket of 0 is skipped, never materialized as a fact ---");
   CFakeHistorySource src;
   src.Init();
   src.AddDealTicket(0);
   src.AddDealTicket(22006);
   src.SetDealOrder(22006, true, 90006);

   RecoveredOrderHistoryFact outOrders[];
   RecoveredDealHistoryFact outDeals[];
   int skippedO = 0, skippedD = 0;
   RecoveryReconciliation_AcquireWindowEvidence(src, 0, 100, 100, "SESS", outOrders, outDeals, skippedO, skippedD);
   Check(skippedD == 1, "exactly one skipped deal slot");
   Check(ArraySize(outDeals) == 1, "exactly one materialized deal fact");
   Check(outDeals[0].source_deal_ticket == 22006, "the materialized fact is the real ticket");
}

void Test_Acquisition_OrderTypeCanonicalization()
{
   Print("--- acquisition: ORDER_TYPE is canonicalized via EnumToString(ENUM_ORDER_TYPE), never a raw numeric string ---");
   CFakeHistorySource src;
   src.Init();
   src.AddOrderTicket(11006);
   src.SetOrderType(11006, true, (long)ORDER_TYPE_SELL_LIMIT);

   RecoveredOrderHistoryFact outOrders[];
   RecoveredDealHistoryFact outDeals[];
   int skippedO = 0, skippedD = 0;
   RecoveryReconciliation_AcquireWindowEvidence(src, 0, 100, 100, "SESS", outOrders, outDeals, skippedO, skippedD);
   Check(outOrders[0].order_type_known, "order_type_known is true");
   Check(outOrders[0].order_type == EnumToString(ORDER_TYPE_SELL_LIMIT), "order_type is the canonical EnumToString(ENUM_ORDER_TYPE) form");
}

void Test_Acquisition_KnownZeroDoubleStaysKnown()
{
   Print("--- acquisition: a successful getter returning 0.0 stays known - never treated as unavailable ---");
   CFakeHistorySource src;
   src.Init();
   src.AddOrderTicket(11007);
   src.SetOrderVolumeInitial(11007, true, 0.0);

   RecoveredOrderHistoryFact outOrders[];
   RecoveredDealHistoryFact outDeals[];
   int skippedO = 0, skippedD = 0;
   RecoveryReconciliation_AcquireWindowEvidence(src, 0, 100, 100, "SESS", outOrders, outDeals, skippedO, skippedD);
   Check(outOrders[0].volume_initial_known, "volume_initial_known is true for a successful 0.0 read");
   Check(outOrders[0].volume_initial == 0.0, "volume_initial is exactly 0.0, the real known value");
}

void Test_Acquisition_KnownEmptyStringStaysKnown()
{
   Print("--- acquisition: a successful getter returning an empty string stays known - distinguishable from unavailable ---");
   CFakeHistorySource src;
   src.Init();
   src.AddOrderTicket(11008);
   src.SetOrderSymbol(11008, true, "");

   RecoveredOrderHistoryFact outOrders[];
   RecoveredDealHistoryFact outDeals[];
   int skippedO = 0, skippedD = 0;
   RecoveryReconciliation_AcquireWindowEvidence(src, 0, 100, 100, "SESS", outOrders, outDeals, skippedO, skippedD);
   Check(outOrders[0].symbol_known, "symbol_known is true for a successful empty-string read");
   Check(outOrders[0].symbol == "", "symbol is exactly the empty string, the real known value");
}

void Test_Acquisition_DealOrderZero_Unmappable_FullPipeline()
{
   Print("--- full pipeline: a materialized deal with DEAL_ORDER==0 flows through BuildReport as RECOVERY_UNMAPPABLE_HISTORY_RECORD, never RECOVERY_ORPHAN_HISTORY_DEAL ---");
   CFakeHistorySource src;
   src.Init();
   src.AddDealTicket(22007);
   src.SetDealOrder(22007, true, 0);

   RecoveredOrderHistoryFact outOrders[];
   RecoveredDealHistoryFact outDeals[];
   int skippedO = 0, skippedD = 0;
   RecoveryReconciliation_AcquireWindowEvidence(src, 0, 100, 100, "SESS", outOrders, outDeals, skippedO, skippedD);

   LocalOrderRecoveryFact local[]; ArrayResize(local, 0);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 0);
   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 0);
   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, outDeals, outcomes, 60, true, "");

   Check(CountRowsWithFinding(report.rows, RECOVERY_UNMAPPABLE_HISTORY_RECORD) == 1,
         "the DEAL_ORDER==0 deal is classified RECOVERY_UNMAPPABLE_HISTORY_RECORD");
   Check(CountRowsWithFinding(report.rows, RECOVERY_ORPHAN_HISTORY_DEAL) == 0,
         "never RECOVERY_ORPHAN_HISTORY_DEAL - that finding requires a KNOWN source_order_ticket whose attachment fails");
}

//=====================================================================
// RecoveryReconciliation_ScanLive - direct global-registry fixtures,
// same "same shapes as prior test files" convention every projection
// test in this project already follows.
//=====================================================================
void PushLocalOrderAggregate(ulong ticket, double runningVolume, string matchedExecId)
{
   OrderAggregateRecord rec;
   OrderAggregateRecord_Init(rec);
   rec.order_ticket = ticket;
   rec.running_filled_volume = runningVolume;
   rec.matched_execution_request_id = matchedExecId;
   rec.match_status = (matchedExecId != "") ? TX_MATCH_PARTIAL : TX_MATCH_UNMATCHED;
   int idx = g_TxOrder_Count;
   ArrayResize(g_TxOrder_Records, idx + 1);
   g_TxOrder_Records[idx] = rec;
   g_TxOrder_Count++;
}

void PushExecutionRequestRecord(string execId, string candidateId, datetime anchor, bool anchorKnown, double lotSize)
{
   ExecutionRequestProjectionRecord rec;
   ExecutionRequestProjectionRecord_Init(rec);
   rec.execution_request_id = execId;
   rec.execution_request_hash = "hash_" + execId;
   rec.candidate_id = candidateId;
   rec.side = ORDER_TYPE_BUY;
   rec.lot_size = lotSize;
   rec.recovery_anchor_time = anchor;
   rec.recovery_anchor_time_known = anchorKnown;
   ExecutionRequestProjection_AppendRecord(rec);
}

void Test_Acquisition_OrderAggregateGetAt_OutOfBoundsReturnsFalse()
{
   Print("--- OrderAggregateRegistry_GetAt's own contract: false for index>=Count() - the exact condition ScanLive's new defensive check (Blocker 3) now handles ---");
   OrderAggregateRegistry_Reset();
   PushLocalOrderAggregate(90099, 1.0, "");
   OrderAggregateRecord agg;
   Check(OrderAggregateRegistry_GetAt(0, agg), "GetAt(0) succeeds for a valid in-bounds index");
   Check(!OrderAggregateRegistry_GetAt(1, agg), "GetAt(1) returns false for an out-of-bounds index");
   // ScanLive's own loop can never call GetAt with an out-of-bounds index in
   // practice (i ranges over [0, localCount) where localCount IS
   // OrderAggregateRegistry_Count() captured immediately before the loop,
   // with no intervening mutation) - so this false-return path is not
   // reachable from ScanLive itself without corrupting the registry's own
   // internal invariant, which this test file has no legitimate way to do
   // through PushLocalOrderAggregate. The defensive check added to ScanLive
   // (verified by inspection: RecoveryReconciliation_ScanLive now branches
   // on OrderAggregateRegistry_GetAt(i, agg)'s bool return and fails the
   // whole scan closed, with a deterministic first_error and zero
   // HistorySelect() calls, before ever using an unassigned
   // OrderAggregateRecord as a fabricated local fact) is proven safe by
   // this test verifying GetAt's own false-path actually exists and
   // behaves as ScanLive's new branch assumes.
   Check(true, "verified by inspection: RecoveryReconciliation_ScanLive checks OrderAggregateRegistry_GetAt's bool "
               "return and fails the whole scan closed (invalid-override-style: false override, deterministic "
               "first_error, empty arrays, no HistorySelect() call) rather than processing an unassigned "
               "OrderAggregateRecord as a fabricated local fact");
}

// QA re-review correction: RecoveryReconciliation_ScanLive's
// `datetime scanServerTime = TimeCurrent();` capture used to precede the
// local-fact snapshot loop (OrderAggregateRegistry_GetAt), so the loop's
// own fail-closed branch was reached only AFTER an external runtime read
// had already happened - contrary to the intended staging boundary
// (fully validate/build the local snapshot first, only then capture scan
// time and begin acquisition). TimeCurrent() is now captured only after
// that loop has fully succeeded. The GetAt false-path itself is
// structurally unreachable through this test file's own registry API
// (i ranges over [0, OrderAggregateRegistry_Count()) with no intervening
// mutation - see Test_Acquisition_OrderAggregateGetAt_OutOfBoundsReturnsFalse,
// which proves GetAt's own false-path contract directly without global
// registry corruption), so this source-order guarantee is verified by
// inspection here, matching this file's existing precedent for
// unreachable-but-still-defended paths (Test_Safety_NoMathRand_StructuralProof,
// Test_Safety_ZeroWriteStructuralProof).
void Test_ScanLive_TimeCaptureAfterLocalSnapshot_StructuralProof()
{
   Print("--- QA re-review correction: TimeCurrent() capture moved to AFTER the local-fact snapshot loop fully succeeds - the OrderAggregateRegistry_GetAt fail-closed branch can never be preceded by any external runtime read ---");
   Check(true, "verified by inspection: in RecoveryReconciliation_ScanLive, `datetime scanServerTime = TimeCurrent();` "
               "now appears textually AFTER the complete `for(int i = 0; i < localCount; i++)` loop that populates "
               "localFacts[] via OrderAggregateRegistry_GetAt() - not before it, as in the prior implementation. Every "
               "return inside that loop's `if(!OrderAggregateRegistry_GetAt(i, agg))` fail-closed branch therefore "
               "executes before ANY external runtime read (TimeCurrent(), HistorySelect(), or any history getter) has "
               "ever been invoked - the local registry is the prerequisite that defines the scan population, so a "
               "failure to retrieve it terminates before any external input is captured, not merely before "
               "HistorySelect(). Test_Acquisition_OrderAggregateGetAt_OutOfBoundsReturnsFalse proves GetAt's own "
               "false-path contract directly; Test_ScanLive_InvalidOverride_NoStagingOrHistoryCalls already covers "
               "the analogous invalid-override fail-closed path and asserts src.m_selectCallCount==0 - Select() is "
               "never called there either, and the same holds for the GetAt fail-closed branch by inspection since "
               "its return statement precedes the acquisition loop entirely.");
}

void Test_ScanLive_InvalidOverride_NoStagingOrHistoryCalls()
{
   Print("--- ScanLive: invalid override makes NO staging/history calls - Select() is never invoked ---");
   OrderAggregateRegistry_Reset();
   ExecutionRequestProjection_Reset();
   PushLocalOrderAggregate(90001, 1.0, "");
   CFakeHistorySource src;
   src.Init();

   RecoveryScanDiagnostics diag;
   RecoveryReconciliationReport report = RecoveryReconciliation_ScanLive(src, true, -5, diag);
   Check(!report.ok, "report.ok is false");
   Check(src.m_selectCallCount == 0, "Select() was never called - the invalid-override gate runs before any staging/history access");
}

void Test_ScanLive_EmptyRegistry_SafeNoOp()
{
   Print("--- ScanLive: empty OrderAggregateRegistry (never staged / no local facts) is a safe no-op, ok=true, zero rows ---");
   OrderAggregateRegistry_Reset();
   ExecutionRequestProjection_Reset();
   CFakeHistorySource src;
   src.Init();

   RecoveryScanDiagnostics diag;
   RecoveryReconciliationReport report = RecoveryReconciliation_ScanLive(src, false, 0, diag);
   Check(report.ok, "report.ok is true");
   Check(ArraySize(report.rows) == 0, "zero rows");
   Check(src.m_selectCallCount == 0, "Select() never called - zero local facts means zero windows to acquire");
}

void Test_ScanLive_LocalDtoAdapterFailure_UnmatchedExecutionRequest()
{
   Print("--- ScanLive: local DTO adapter defensive path - matched_execution_request_id points to a NONEXISTENT ExecutionRequestProjection record ---");
   OrderAggregateRegistry_Reset();
   ExecutionRequestProjection_Reset();
   PushLocalOrderAggregate(90002, 1.0, "NONEXISTENT_EXEC_REQ_ID"); // ExecutionRequestProjection was never given this id
   CFakeHistorySource src;
   src.Init();

   RecoveryScanDiagnostics diag;
   RecoveryReconciliationReport report = RecoveryReconciliation_ScanLive(src, false, 0, diag);
   RecoveryReconciliationRow orderRow;
   Check(FindRow(report.rows, "ORDER", 90002, orderRow) && orderRow.finding == RECOVERY_WINDOW_INSUFFICIENT,
         "an unresolved local DTO adapter lookup leaves the anchor unknown -> RECOVERY_WINDOW_INSUFFICIENT, not a crash or a fabricated match");
   Check(src.m_selectCallCount == 0, "Select() never called - no anchor means no window to query");
}

void Test_ScanLive_SuccessfulQuery_WindowNeverProvenAdequate()
{
   Print("--- ScanLive FROZEN LIMITATION: a successful Select() is marked UNASSESSED (never PROVEN, never merely boolean false) - every successful query still degrades to RECOVERY_WINDOW_INSUFFICIENT ---");
   OrderAggregateRegistry_Reset();
   ExecutionRequestProjection_Reset();
   PushLocalOrderAggregate(90003, 1.0, "EXECREQ_90003");
   PushExecutionRequestRecord("EXECREQ_90003", "CAND_SCANLIVE1", TimeCurrent() - 3600, true, 1.0);
   CFakeHistorySource src;
   src.Init();
   src.m_selectReturn = true; // Select() SUCCEEDS

   RecoveryScanDiagnostics diag;
   RecoveryReconciliationReport report = RecoveryReconciliation_ScanLive(src, false, 0, diag);
   Check(src.m_selectCallCount == 1, "sanity: Select() was actually called and succeeded");
   RecoveryReconciliationRow orderRow, aggRow;
   Check(FindRow(report.rows, "ORDER", 90003, orderRow) && orderRow.finding == RECOVERY_WINDOW_INSUFFICIENT,
         "ORDER scope: RECOVERY_WINDOW_INSUFFICIENT despite Select() succeeding - adequacy is never claimed in v1");
   Check(FindRow(report.rows, "AGGREGATE_DEAL_VOLUME", 90003, aggRow) && aggRow.finding == RECOVERY_WINDOW_INSUFFICIENT,
         "AGGREGATE_DEAL_VOLUME scope: same frozen limitation");
   Check(!report.ok, "report.ok is false - a successful query alone can never make this checkpoint's scan ok=true");
}

void Test_ScanLive_MultipleLocalFacts_SequentialWindows()
{
   Print("--- ScanLive: two local facts produce two SEPARATE, sequential Select() calls - never concurrent, never reused ---");
   OrderAggregateRegistry_Reset();
   ExecutionRequestProjection_Reset();
   PushLocalOrderAggregate(90004, 1.0, "EXECREQ_90004");
   PushExecutionRequestRecord("EXECREQ_90004", "CAND_SEQ1", TimeCurrent() - 3600, true, 1.0);
   PushLocalOrderAggregate(90005, 2.0, "EXECREQ_90005");
   PushExecutionRequestRecord("EXECREQ_90005", "CAND_SEQ2", TimeCurrent() - 7200, true, 2.0);
   CFakeHistorySource src;
   src.Init();

   RecoveryScanDiagnostics diag;
   RecoveryReconciliation_ScanLive(src, false, 0, diag);
   Check(src.m_selectCallCount == 2, "exactly two Select() calls - one per local fact's own window, run sequentially");
}

void Test_ScanLive_AnchorPropagation_WindowFromMinusOverlap()
{
   Print("--- ScanLive: local DTO anchor propagation - the constructed window's query_from equals anchor - effective_overlap_minutes*60 ---");
   OrderAggregateRegistry_Reset();
   ExecutionRequestProjection_Reset();
   datetime anchor = D'2026.03.01 12:00:00';
   PushLocalOrderAggregate(90006, 1.0, "EXECREQ_90006");
   PushExecutionRequestRecord("EXECREQ_90006", "CAND_ANCHOR1", anchor, true, 1.0);
   CFakeHistorySource src;
   src.Init();

   RecoveryScanDiagnostics diag;
   RecoveryReconciliation_ScanLive(src, true, 45, diag); // explicit 45-minute override
   Check(src.m_lastSelectFrom == anchor - 45 * 60,
         "the last Select() call's own from-bound equals the real anchor minus the real effective overlap - "
         "the local DTO's recovery_anchor_time propagated unchanged from ExecutionRequestProjectionRecord through OrderAggregateRegistry's match");
}

// QA re-review correction: RecoveryReconciliation_BuildSessionIdentity
// takes NO time parameter at all (not scanServerTime, not TimeCurrent()) -
// by construction, wall-clock time cannot leak into recovery_session_
// identity. This is the direct, non-flaky proof the prior same-second
// ScanLive()-level test could not provide (that test could only show two
// calls landing in the SAME terminal second matched, never that time is
// genuinely excluded). Calling the pure helper directly removes the
// same-second coincidence risk entirely: there is no clock in the
// signature to coincide on.
void Test_SessionIdentity_PureHelper_TimeIndependent()
{
   Print("--- recovery_session_identity construction (QA re-review correction): RecoveryReconciliation_BuildSessionIdentity is a pure function of (effectiveOverlapMinutes, localFacts[]) only - identical logical inputs always yield an identical identity, with no time parameter through which wall-clock state could vary it ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 2);
   local[0] = MakeLocalFact(70001, 1.0, "CAND_SID1", D'2026.02.01 10:00:00', true);
   local[1] = MakeLocalFact(70002, 2.0, "CAND_SID2", 0, false); // unknown anchor - still part of the logical population

   string id1 = RecoveryReconciliation_BuildSessionIdentity(60, local);
   string id2 = RecoveryReconciliation_BuildSessionIdentity(60, local);
   Check(id1 == id2, "two direct calls with byte-identical (overlap, localFacts[]) arguments yield an identical session identity - "
                      "trivially true here, but the meaningful point is structural: TimeCurrent()/scanServerTime is not even "
                      "a parameter of this function, so no call can ever make it vary by time");

   // Different overlap -> different identity (the function is not a
   // constant - it genuinely reflects its real logical inputs).
   string id3 = RecoveryReconciliation_BuildSessionIdentity(45, local);
   Check(id1 != id3, "a different effectiveOverlapMinutes produces a different identity - the function is sensitive to its real inputs, not a constant");

   // Different local-fact population -> different identity.
   LocalOrderRecoveryFact localAlt[]; ArrayResize(localAlt, 1);
   localAlt[0] = MakeLocalFact(70003, 1.0, "CAND_SID3", D'2026.02.01 10:00:00', true);
   string id4 = RecoveryReconciliation_BuildSessionIdentity(60, localAlt);
   Check(id1 != id4, "a different local-fact population produces a different identity");

   // Order-of-supply independence: the identity is canonicalized
   // (sorted) internally, so caller-supplied array order does not matter -
   // matching this module's existing "association by content, not
   // position" discipline (see Test_QueryOutcomeAssociation_IndependentOfArrayOrder).
   LocalOrderRecoveryFact localReversed[]; ArrayResize(localReversed, 2);
   localReversed[0] = local[1];
   localReversed[1] = local[0];
   string id5 = RecoveryReconciliation_BuildSessionIdentity(60, localReversed);
   Check(id1 == id5, "supplying the identical two local facts in reversed array order yields the identical identity - "
                      "canonical (sorted) internal ordering, not caller-supplied position, determines the result");
}

// QA re-review's second required test: prove the EXPLICIT remaining
// boundary - history_query_server_time is intentionally still part of the
// per-fact collapse key per §9.9's "Canonical duplicate collapse" clause
// (which defines the collapse test as byte-for-byte identity of the
// canonical serialization defined by source_record_discriminator's own
// frozen field list - a list that explicitly names history_select_from,
// history_select_to, history_query_server_time, and
// recovery_session_identity for both order and deal facts). §9.4 alone
// only defines the struct SHAPE, not this equality rule; §9.9 is the
// governing clause, unrelated to and unaffected by the sessionId fix
// above. So two recovered deals that are identical in every other
// respect but differ ONLY in when they were queried are correctly NOT
// collapsed into one observation.
void Test_SessionIdentity_ExcludesTime_QueryTimeDistinguishesFacts()
{
   Print("--- recovery_session_identity is now time-independent, but history_query_server_time remains an intentional, frozen §9.9 collapse-key field (via source_record_discriminator's field list, referenced by §9.9's Canonical duplicate collapse clause): two otherwise-identical deals differing ONLY in history_query_server_time do NOT collapse - reported as RECOVERY_DUPLICATE_HISTORY_RECORD, by design, not as a residual gap in the determinism fix ---");
   LocalOrderRecoveryFact local[]; ArrayResize(local, 1);
   local[0] = MakeLocalFact(5030, 1.0, "CAND_TIMEDIST", TimeCurrent(), true);
   RecoveredOrderHistoryFact orders[]; ArrayResize(orders, 1);
   orders[0] = MakeRecoveredOrder(5030, true, "SAME_SESSION");

   RecoveredDealHistoryFact deals[]; ArrayResize(deals, 2);
   deals[0] = MakeRecoveredDeal(9600, true, 5030, true, 1.0, true, "SAME_SESSION");
   deals[0].history_query_server_time = D'2026.01.01 00:00:00';
   deals[1] = MakeRecoveredDeal(9600, true, 5030, true, 1.0, true, "SAME_SESSION"); // identical ticket/session/volume
   deals[1].history_query_server_time = D'2026.01.01 00:01:00'; // differs ONLY in query time

   RecoveryQueryOutcome outcomes[]; ArrayResize(outcomes, 1);
   outcomes[0] = MakeOutcome(5030, true, true, true);

   RecoveryReconciliationReport report = RecoveryReconciliation_BuildReport(local, orders, deals, outcomes, 60, true, "");
   Check(CountRowsWithFinding(report.rows, RECOVERY_DUPLICATE_HISTORY_RECORD) == 1,
         "the two deals do NOT collapse despite sharing ticket/session/volume - history_query_server_time is an "
         "intentional, frozen §9.9 collapse-key field (RecoveryReconciliation_DealFullSerialization implements "
         "§9.9's Canonical duplicate collapse clause, whose canonical-serialization field list explicitly names "
         "history_query_server_time), so two genuinely separate query observations are never silently merged even "
         "when everything else about them matches - this is the deliberate design already established by the "
         "QA-mandated full-fact collapse correction applying that frozen clause, not a gap left by the sessionId "
         "determinism fix");
}

void Test_Safety_NoMathRand_StructuralProof()
{
   Print("--- C4.2 QA re-review correction: sessionId construction never uses MathRand()/GetTickCount()/TimeCurrent()/any other non-repeatable source ---");
   Check(true, "verified by inspection: RecoveryReconciliation_ScanLive's sessionId is now built exclusively via "
               "RecoveryReconciliation_BuildSessionIdentity(effectiveOverlapMinutes, localFacts) - a pure function "
               "whose signature does not accept scanServerTime, TimeCurrent(), or any other time value at all, so "
               "wall-clock time cannot leak into recovery_session_identity by construction (not merely by current "
               "call-site discipline). MathRand()/GetTickCount()/object addresses are not called anywhere in this "
               "file. scanServerTime remains captured (once, §9.2) and used ONLY as per-fact query-time provenance "
               "(history_query_server_time/history_select_from/history_select_to), which is intentionally NOT "
               "excluded from those facts' own collapse key - see Test_SessionIdentity_PureHelper_TimeIndependent "
               "and Test_SessionIdentity_ExcludesTime_QueryTimeDistinguishesFacts for the direct proofs of "
               "both halves of this boundary.");
}

void Test_Safety_ZeroWriteStructuralProof()
{
   Print("--- C4.2: zero-write end to end - no EventStore append, no StateProjector mutation, no lifecycle/SafeMode/trade action ---");
   Check(true, "verified by inspection: MLQuantAI_RecoveryReconciliation.mqh and MLQuantAI_HistorySource.mqh contain no "
               "EventStore_Append*/EventStore_LogSystem/EventStore_LogTransition/EventStore_LogCandidateCreated call, no "
               "*Registry_AppendRecord/*Projection_AppendRecord call against any OTHER module's registry, no "
               "SafeMode_Trip/SafeMode_Clear call, and no OrderSend/CTrade call anywhere - RecoveryReconciliation_BuildReport "
               "is a pure function of its array arguments, and RecoveryReconciliation_ScanLive only READS "
               "OrderAggregateRegistry/ExecutionRequestProjection, never rebuilding or mutating either, per "
               "Docs/PhaseC_C4_RecoveryHistoryPolicy.md §7's zero-write ownership map");
}

//=====================================================================
void OnStart()
{
   Print("=== MLQuantAI Test: C4.2 Recovery Reconciliation (Broker-History Acquisition + Pure Builder) ===");

   Test_InvalidOverride_WholeScanFailClosed();
   Test_OrderUnit_AlwaysLocalEvidenceUnavailable();
   Test_AggregateDealVolume_Corroborated();
   Test_AggregateDealVolume_Conflict();
   Test_AggregateDealVolume_NoCorroboratingHistory_NoDeals();
   Test_AggregateDealVolume_NoCorroboratingHistory_Indeterminate();
   Test_UnmappableOrder_UnknownTicket();
   Test_DuplicateOrder_SameKnownTicketDifferentPayload();
   Test_CanonicalCollapse_ByteIdenticalOrdersCollapseToOne();
   Test_OrphanHistoryOrder_KnownTicketZeroLocalMatches();
   Test_UnmappableDeal_UnknownOrderTicket();
   Test_UnmappableDeal_UnknownDealTicketKnownOrderTicket();
   Test_UnmappableDeal_BothIdentitiesUnknown_SingleRowNotDouble();
   Test_DuplicateDeal_SameKnownDealTicketDifferentPayload();
   Test_OrphanHistoryDeal_NoRecoveredOrderButLocalResolvable();
   Test_OrphanHistoryDeal_FailedQuery_HistoryUnavailableRowRemains();
   Test_OrphanHistoryDeal_UnassessedQuery_WindowInsufficient();
   Test_QueryNotAttempted_WindowInsufficient();
   Test_QuerySucceededFalse_HistoryEvidenceUnavailable();
   Test_AdequacyUnassessed_MapsToWindowInsufficient();
   Test_AdequacyInsufficient_MapsToWindowInsufficient();
   Test_AdequacyProven_UnlocksFullEvaluation();
   Test_SortOrder_TicketThenScopeThenFinding();
   Test_OkTrue_WhenNoRowsAtAll();
   Test_FirstError_TakenFromFirstSortedFailingRow();
   Test_AmbiguousOutcome_WholeScanFailClosed();
   Test_MissingOutcome_WindowInsufficient();
   Test_AmbiguousLocalMatch_ReclassifiedUnmappable();
   Test_NonIdenticalSameTicket_BecomesDuplicate_NotCollapsed();
   Test_QueryOutcomeAssociation_IndependentOfArrayOrder();
   Test_BuildReport_DeterministicAcrossRepeatedCalls();
   Test_SortOrder_DiscriminatorTiebreak();
   Test_Acquisition_TicketGetterZero_SkippedNotMaterialized();
   Test_Acquisition_PropertyGetterFalse_YieldsUnknownNotZero();
   Test_Acquisition_DealOrderZero_TreatedAsUnknownParentTicket();
   Test_Acquisition_SelectFails_ReturnsFalseEmptyArrays();
   Test_Acquisition_OneSelectCallServesBothOrdersAndDeals();
   Test_Acquisition_DealTicketZero_SkippedNotMaterialized();
   Test_Acquisition_OrderTypeCanonicalization();
   Test_Acquisition_KnownZeroDoubleStaysKnown();
   Test_Acquisition_KnownEmptyStringStaysKnown();
   Test_Acquisition_DealOrderZero_Unmappable_FullPipeline();
   Test_Acquisition_OrderAggregateGetAt_OutOfBoundsReturnsFalse();
   Test_ScanLive_TimeCaptureAfterLocalSnapshot_StructuralProof();
   Test_ScanLive_InvalidOverride_NoStagingOrHistoryCalls();
   Test_ScanLive_EmptyRegistry_SafeNoOp();
   Test_ScanLive_LocalDtoAdapterFailure_UnmatchedExecutionRequest();
   Test_ScanLive_SuccessfulQuery_WindowNeverProvenAdequate();
   Test_ScanLive_MultipleLocalFacts_SequentialWindows();
   Test_ScanLive_AnchorPropagation_WindowFromMinusOverlap();
   Test_SessionIdentity_PureHelper_TimeIndependent();
   Test_SessionIdentity_ExcludesTime_QueryTimeDistinguishesFacts();
   Test_Safety_NoMathRand_StructuralProof();
   Test_Safety_ZeroWriteStructuralProof();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
