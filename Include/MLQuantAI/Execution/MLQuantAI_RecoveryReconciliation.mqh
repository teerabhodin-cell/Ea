//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_RecoveryReconciliation.mqh       |
//| C4.2 implementation, per Docs/PhaseC_C4_RecoveryHistoryPolicy.md  |
//| §9 (C4.1 addendum) and §10 (C4.2.1 addendum), both adopted.        |
//|                                                                    |
//| Zero-write, read-only, in-memory only (§7): no EventStore append,  |
//| no StateProjector mutation, no lifecycle transition, no SafeMode   |
//| action, no trade action. RecoveryReconciliation_BuildReport() is a |
//| PURE function of its array arguments - it never calls a History*   |
//| API itself, which is what makes it testable without a live         |
//| terminal (precedent: C2.2's ProcessSendResult extraction).         |
//| RecoveryReconciliation_ScanLive() is the thin orchestrator that     |
//| acquires evidence via IHistorySource and hands it to the builder.  |
//|                                                                    |
//| C4.2 v1 Option B (frozen decision): neither ExecutionRequestProjec-|
//| tionRecord nor OrderAggregateRecord carries a symbol field. Local  |
//| symbol is therefore architecturally always unknown, so the ORDER   |
//| comparison unit (§9.5's symbol/order_type/volume_initial exact-    |
//| equality set) can never reach CORROBORATED/CONFLICT in this        |
//| version - it always resolves to RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE|
//| whenever a local+recovered order-ticket mapping exists. The        |
//| AGGREGATE_DEAL_VOLUME unit needs no symbol and remains independent.|
//|                                                                    |
//| FROZEN LIMITATION (QA-mandated, explicit, not hidden; C4.2.2        |
//| disposition path (a) - see ENUM_RECOVERY_WINDOW_ADEQUACY below):    |
//| C4.2 v1 has no independently-verifiable window-adequacy proof       |
//| mechanism (§3). RecoveryReconciliation_ScanLive() therefore NEVER   |
//| sets adequacy=PROVEN, even when HistorySelect() itself succeeds -   |
//| success only proves the terminal accepted the request, never that  |
//| broker-side retention covered the full interval - a successful      |
//| query is marked UNASSESSED, per §9.7 row 2's own frozen wording     |
//| ("adequacy ... cannot be proven"). Consequence: every                |
//| successfully-queried local fact still resolves to                  |
//| RECOVERY_WINDOW_INSUFFICIENT/DEGRADED in production. C4.2 v1 is     |
//| acquisition + normalization + deterministic diagnostics             |
//| (UNMAPPABLE/DUPLICATE/ORPHAN, which are recovered-evidence-driven   |
//| and independent of adequacy) only - it cannot yet emit an evidence- |
//| sufficiency or corroboration/conflict conclusion. UNASSESSED never  |
//| means "broker retention is known-insufficient" - it means C4.2      |
//| cannot establish adequacy under the currently available API and    |
//| contract mechanisms. See RecoveryReconciliation_ScanLive()'s own    |
//| header comment below and Test_ScanLive_SuccessfulQuery_WindowNeverProvenAdequate.|
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_RECOVERYRECONCILIATION_MQH__
#define __MLQUANTAI_RECOVERYRECONCILIATION_MQH__

#include "MLQuantAI_HistorySource.mqh"
#include "MLQuantAI_ExecutionAuditProjection.mqh"
#include "MLQuantAI_TransactionMatchingProjection.mqh"
#include "../Core/MLQuantAI_ContractVersions.mqh"

// §9.2 planned identifier, first appearance in source.
#define MLQUANTAI_C4_RECOVERY_OVERLAP_MINUTES_DEFAULT 60

//---------------------------------------------------------------------
// §4 frozen enum - declaration order is itself part of the frozen
// contract (used as the sort-key-5 ordinal, §9.9).
//---------------------------------------------------------------------
enum ENUM_RECOVERY_FINDING
{
   RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE,
   RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE,
   RECOVERY_WINDOW_INSUFFICIENT,
   RECOVERY_NO_CORROBORATING_HISTORY,
   RECOVERY_FACT_CORROBORATED,
   RECOVERY_FACT_CONFLICT,
   RECOVERY_ORPHAN_HISTORY_ORDER,
   RECOVERY_ORPHAN_HISTORY_DEAL,
   RECOVERY_DUPLICATE_HISTORY_RECORD,
   RECOVERY_UNMAPPABLE_HISTORY_RECORD
};

// §5 frozen enum.
enum ENUM_RECOVERY_POSTURE
{
   RECOVERY_POSTURE_INFORMATIONAL,
   RECOVERY_POSTURE_DEGRADED,
   RECOVERY_POSTURE_BLOCK_RECOMMENDED
};

// §9.7's frozen finding->posture table.
ENUM_RECOVERY_POSTURE RecoveryFindingToPosture(ENUM_RECOVERY_FINDING f)
{
   switch(f)
   {
      case RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE: return RECOVERY_POSTURE_DEGRADED;
      case RECOVERY_WINDOW_INSUFFICIENT:          return RECOVERY_POSTURE_DEGRADED;
      case RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE:   return RECOVERY_POSTURE_DEGRADED;
      case RECOVERY_UNMAPPABLE_HISTORY_RECORD:    return RECOVERY_POSTURE_BLOCK_RECOMMENDED;
      case RECOVERY_DUPLICATE_HISTORY_RECORD:     return RECOVERY_POSTURE_BLOCK_RECOMMENDED;
      case RECOVERY_ORPHAN_HISTORY_ORDER:         return RECOVERY_POSTURE_BLOCK_RECOMMENDED;
      case RECOVERY_ORPHAN_HISTORY_DEAL:          return RECOVERY_POSTURE_BLOCK_RECOMMENDED;
      case RECOVERY_NO_CORROBORATING_HISTORY:     return RECOVERY_POSTURE_DEGRADED;
      case RECOVERY_FACT_CONFLICT:                return RECOVERY_POSTURE_BLOCK_RECOMMENDED;
      case RECOVERY_FACT_CORROBORATED:            return RECOVERY_POSTURE_INFORMATIONAL;
   }
   return RECOVERY_POSTURE_BLOCK_RECOMMENDED; // defensive, never reached - every value handled above
}

//---------------------------------------------------------------------
// §9.4 planned recovered-fact schemas.
//---------------------------------------------------------------------
struct RecoveredOrderHistoryFact
{
   string   schema_version;
   string   provenance_kind;
   datetime history_select_from;
   datetime history_select_to;
   datetime history_query_server_time;
   string   recovery_session_identity;
   ulong    source_order_ticket;
   bool     source_order_ticket_known;
   string   symbol;
   bool     symbol_known;
   string   order_type;
   bool     order_type_known;
   string   order_state;
   bool     order_state_known;
   double   volume_initial;
   bool     volume_initial_known;
   double   volume_current;
   bool     volume_current_known;
   double   price_open;
   bool     price_open_known;
   double   price_sl;
   bool     price_sl_known;
   double   price_tp;
   bool     price_tp_known;
};

void RecoveredOrderHistoryFact_Init(RecoveredOrderHistoryFact &r)
{
   r.schema_version = "";
   r.provenance_kind = "";
   r.history_select_from = 0;
   r.history_select_to = 0;
   r.history_query_server_time = 0;
   r.recovery_session_identity = "";
   r.source_order_ticket = 0;
   r.source_order_ticket_known = false;
   r.symbol = ""; r.symbol_known = false;
   r.order_type = ""; r.order_type_known = false;
   r.order_state = ""; r.order_state_known = false;
   r.volume_initial = 0; r.volume_initial_known = false;
   r.volume_current = 0; r.volume_current_known = false;
   r.price_open = 0; r.price_open_known = false;
   r.price_sl = 0; r.price_sl_known = false;
   r.price_tp = 0; r.price_tp_known = false;
}

struct RecoveredDealHistoryFact
{
   string   schema_version;
   string   provenance_kind;
   datetime history_select_from;
   datetime history_select_to;
   datetime history_query_server_time;
   string   recovery_session_identity;
   ulong    source_deal_ticket;
   bool     source_deal_ticket_known;
   ulong    source_order_ticket;
   bool     source_order_ticket_known;
   string   symbol;
   bool     symbol_known;
   string   deal_type;
   bool     deal_type_known;
   double   price;
   bool     price_known;
   double   volume;
   bool     volume_known;
};

void RecoveredDealHistoryFact_Init(RecoveredDealHistoryFact &r)
{
   r.schema_version = "";
   r.provenance_kind = "";
   r.history_select_from = 0;
   r.history_select_to = 0;
   r.history_query_server_time = 0;
   r.recovery_session_identity = "";
   r.source_deal_ticket = 0; r.source_deal_ticket_known = false;
   r.source_order_ticket = 0; r.source_order_ticket_known = false;
   r.symbol = ""; r.symbol_known = false;
   r.deal_type = ""; r.deal_type_known = false;
   r.price = 0; r.price_known = false;
   r.volume = 0; r.volume_known = false;
}

//---------------------------------------------------------------------
// LocalOrderRecoveryFact - the pure builder's local-side DTO. Isolates
// RecoveryReconciliation_BuildReport() from OrderAggregateRegistry/
// ExecutionRequestProjection's own globals, so the builder can be
// tested with plain struct literals. Deliberately carries no symbol
// field (C4.2 v1 Option B, above) and carries the C4.2.1 recovery-
// anchor provenance fields unchanged from ExecutionRequestProjectionRecord.
//---------------------------------------------------------------------
struct LocalOrderRecoveryFact
{
   ulong           order_ticket;
   double          running_filled_volume;
   string          candidate_id;              // "" when unmatched/ambiguous
   bool            matched;
   ENUM_ORDER_TYPE local_order_type;
   bool            local_order_type_known;
   double          local_volume_initial;
   bool            local_volume_initial_known;
   datetime        recovery_anchor_time;
   bool            recovery_anchor_time_known;
};

void LocalOrderRecoveryFact_Init(LocalOrderRecoveryFact &r)
{
   r.order_ticket = 0;
   r.running_filled_volume = 0;
   r.candidate_id = "";
   r.matched = false;
   r.local_order_type = ORDER_TYPE_BUY;
   r.local_order_type_known = false;
   r.local_volume_initial = 0;
   r.local_volume_initial_known = false;
   r.recovery_anchor_time = 0;
   r.recovery_anchor_time_known = false;
}

//---------------------------------------------------------------------
// Window-adequacy tri-state (QA-authorized, C4.2.2 disposition -
// path (a): existing §9.7 row 2 frozen wording, "adequacy ... cannot
// be proven", already textually covers a successful Select() with no
// independent retention-coverage proof - no docs amendment needed).
// PRIVATE to this module - not part of any frozen public schema.
// §9's frozen ENUM_RECOVERY_FINDING gains no new value: both UNASSESSED
// and INSUFFICIENT map to the existing RECOVERY_WINDOW_INSUFFICIENT
// finding in RecoveryReconciliation_BuildReport below. Only PROVEN
// unlocks CORROBORATED/CONFLICT/NO_CORROBORATING_HISTORY evaluation.
// UNASSESSED never means "broker retention is known-insufficient" - it
// means C4.2 cannot establish adequacy under the currently available
// API and contract mechanisms; a future, separately adopted retention-
// proof mechanism is what would ever set PROVEN or a positively-
// determined INSUFFICIENT.
//---------------------------------------------------------------------
enum ENUM_RECOVERY_WINDOW_ADEQUACY
{
   RECOVERY_WINDOW_ADEQUACY_UNASSESSED = 0,
   RECOVERY_WINDOW_ADEQUACY_PROVEN,
   RECOVERY_WINDOW_ADEQUACY_INSUFFICIENT
};

//---------------------------------------------------------------------
// RecoveryQueryOutcome - per local order_ticket's window-query provenance,
// tri-state per the acquisition-contract QA round: query_attempted
// (false only when bounds were invalid/anchor unknown - Select() never
// called), query_succeeded (Select()'s own bool return, meaningful only
// when attempted), adequacy (§3's adequacy predicate, now itself a
// tri-state - see ENUM_RECOVERY_WINDOW_ADEQUACY above). Individual
// property-getter failures never affect any of these fields - see
// MLQuantAI_HistorySource.mqh's header comment.
//---------------------------------------------------------------------
struct RecoveryQueryOutcome
{
   datetime query_from;
   datetime query_to;
   bool     query_attempted;
   bool     query_succeeded;
   ENUM_RECOVERY_WINDOW_ADEQUACY adequacy;
   ulong    order_ticket;
   bool     order_ticket_known;
};

void RecoveryQueryOutcome_Init(RecoveryQueryOutcome &r)
{
   r.query_from = 0;
   r.query_to = 0;
   r.query_attempted = false;
   r.query_succeeded = false;
   r.adequacy = RECOVERY_WINDOW_ADEQUACY_UNASSESSED;
   r.order_ticket = 0;
   r.order_ticket_known = false;
}

//---------------------------------------------------------------------
// §9.9 planned report/row shapes.
//---------------------------------------------------------------------
struct RecoveryReconciliationRow
{
   string                 candidate_id;
   ulong                  order_ticket;
   bool                   order_ticket_known;
   ulong                  deal_ticket;
   bool                   deal_ticket_known;
   string                 comparison_scope;   // "ORDER" | "AGGREGATE_DEAL_VOLUME"
   ENUM_RECOVERY_FINDING  finding;
   ENUM_RECOVERY_POSTURE  posture;
   string                 source_record_discriminator;
   string                 detail;
};

void RecoveryReconciliationRow_Init(RecoveryReconciliationRow &r)
{
   r.candidate_id = "";
   r.order_ticket = 0;
   r.order_ticket_known = false;
   r.deal_ticket = 0;
   r.deal_ticket_known = false;
   r.comparison_scope = "";
   r.finding = RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE;
   r.posture = RECOVERY_POSTURE_DEGRADED;
   r.source_record_discriminator = "";
   r.detail = "";
}

struct RecoveryReconciliationReport
{
   string                    schema_version;
   bool                      ok;
   int                       local_facts_scanned;
   int                       recovered_orders_scanned;
   int                       recovered_deals_scanned;
   RecoveryReconciliationRow rows[];
   string                    first_error;
};

void RecoveryReconciliationReport_Init(RecoveryReconciliationReport &r)
{
   r.schema_version = MLQUANTAI_RECOVERY_RECONCILIATION_SCHEMA_C4_V1;
   r.ok = true;
   r.local_facts_scanned = 0;
   r.recovered_orders_scanned = 0;
   r.recovered_deals_scanned = 0;
   ArrayResize(r.rows, 0);
   r.first_error = "";
}

//---------------------------------------------------------------------
// §9.9 source_record_discriminator - canonical serialization of the
// exact field lists frozen there. Ordering/ tiebreaker only - not a
// hash, not a durable identity.
//---------------------------------------------------------------------
string RecoveryReconciliation_OrderDiscriminator(const RecoveredOrderHistoryFact &f)
{
   return StringFormat("%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s",
      f.schema_version, f.provenance_kind,
      TimeToString(f.history_select_from, TIME_DATE|TIME_SECONDS),
      TimeToString(f.history_select_to, TIME_DATE|TIME_SECONDS),
      TimeToString(f.history_query_server_time, TIME_DATE|TIME_SECONDS),
      f.recovery_session_identity,
      f.source_order_ticket_known ? "1" : "0", IntegerToString((long)f.source_order_ticket),
      f.symbol_known ? "1" : "0", f.symbol,
      f.order_type_known ? "1" : "0", f.order_type,
      f.order_state_known ? "1" : "0", f.order_state);
}

string RecoveryReconciliation_DealDiscriminator(const RecoveredDealHistoryFact &f)
{
   return StringFormat("%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s",
      f.schema_version, f.provenance_kind,
      TimeToString(f.history_select_from, TIME_DATE|TIME_SECONDS),
      TimeToString(f.history_select_to, TIME_DATE|TIME_SECONDS),
      TimeToString(f.history_query_server_time, TIME_DATE|TIME_SECONDS),
      f.recovery_session_identity,
      f.source_deal_ticket_known ? "1" : "0", IntegerToString((long)f.source_deal_ticket),
      f.source_order_ticket_known ? "1" : "0", IntegerToString((long)f.source_order_ticket),
      f.symbol_known ? "1" : "0", f.symbol,
      f.deal_type_known ? "1" : "0", f.deal_type,
      f.price_known ? "1" : "0", DoubleToString(f.price, 8),
      f.volume_known ? "1" : "0", DoubleToString(f.volume, 8));
}

//---------------------------------------------------------------------
// Full-fact canonical serialization - used ONLY as the collapse key,
// never for row sort-key 6. Deliberately distinct from (and a strict
// superset of) source_record_discriminator above: the discriminator is
// §9.9's narrower ordering tiebreaker for diagnostic rows, while
// collapse requires every knownness flag AND every value field
// (including volume/price, which the discriminator's own frozen field
// list omits) to match byte-for-byte before two recovered facts may be
// treated as one repeated observation of the same evidence rather than
// two genuinely different recordings of the same ticket - the QA-
// mandated correction distinguishing "same ticket, byte-identical
// complete fact" (collapse, e.g. re-observed across two overlapping
// per-fact windows) from "same known ticket, non-identical complete
// fact" (RECOVERY_DUPLICATE_HISTORY_RECORD, a genuine data-integrity
// finding, never silently normalized away).
//---------------------------------------------------------------------
string RecoveryReconciliation_OrderFullSerialization(const RecoveredOrderHistoryFact &f)
{
   string s = "";
   s = s + f.schema_version + "|" + f.provenance_kind + "|";
   s = s + TimeToString(f.history_select_from, TIME_DATE|TIME_SECONDS) + "|";
   s = s + TimeToString(f.history_select_to, TIME_DATE|TIME_SECONDS) + "|";
   s = s + TimeToString(f.history_query_server_time, TIME_DATE|TIME_SECONDS) + "|";
   s = s + f.recovery_session_identity + "|";
   s = s + (f.source_order_ticket_known ? "1" : "0") + "|" + IntegerToString((long)f.source_order_ticket) + "|";
   s = s + (f.symbol_known ? "1" : "0") + "|" + f.symbol + "|";
   s = s + (f.order_type_known ? "1" : "0") + "|" + f.order_type + "|";
   s = s + (f.order_state_known ? "1" : "0") + "|" + f.order_state + "|";
   s = s + (f.volume_initial_known ? "1" : "0") + "|" + DoubleToString(f.volume_initial, 8) + "|";
   s = s + (f.volume_current_known ? "1" : "0") + "|" + DoubleToString(f.volume_current, 8) + "|";
   s = s + (f.price_open_known ? "1" : "0") + "|" + DoubleToString(f.price_open, 8) + "|";
   s = s + (f.price_sl_known ? "1" : "0") + "|" + DoubleToString(f.price_sl, 8) + "|";
   s = s + (f.price_tp_known ? "1" : "0") + "|" + DoubleToString(f.price_tp, 8);
   return s;
}

string RecoveryReconciliation_DealFullSerialization(const RecoveredDealHistoryFact &f)
{
   string s = "";
   s = s + f.schema_version + "|" + f.provenance_kind + "|";
   s = s + TimeToString(f.history_select_from, TIME_DATE|TIME_SECONDS) + "|";
   s = s + TimeToString(f.history_select_to, TIME_DATE|TIME_SECONDS) + "|";
   s = s + TimeToString(f.history_query_server_time, TIME_DATE|TIME_SECONDS) + "|";
   s = s + f.recovery_session_identity + "|";
   s = s + (f.source_deal_ticket_known ? "1" : "0") + "|" + IntegerToString((long)f.source_deal_ticket) + "|";
   s = s + (f.source_order_ticket_known ? "1" : "0") + "|" + IntegerToString((long)f.source_order_ticket) + "|";
   s = s + (f.symbol_known ? "1" : "0") + "|" + f.symbol + "|";
   s = s + (f.deal_type_known ? "1" : "0") + "|" + f.deal_type + "|";
   s = s + (f.price_known ? "1" : "0") + "|" + DoubleToString(f.price, 8) + "|";
   s = s + (f.volume_known ? "1" : "0") + "|" + DoubleToString(f.volume, 8);
   return s;
}

//---------------------------------------------------------------------
// Canonical duplicate collapse (§9.9, QA-corrected): two recovered
// records are the same normalized evidence item only when their FULL
// canonical serialization (above - every field, not just the narrower
// diagnostic discriminator) is byte-for-byte identical. Collapses to
// one canonical copy each, in first-seen
// order - never based on API enumeration position as an occurrence
// discriminator (the position is only ever used to decide WHICH of two
// identical copies is "first", which is immaterial since they are
// byte-identical).
//---------------------------------------------------------------------
void RecoveryReconciliation_CollapseOrders(const RecoveredOrderHistoryFact &src[], RecoveredOrderHistoryFact &out[])
{
   ArrayResize(out, 0);
   string seen[];
   for(int i = 0; i < ArraySize(src); i++)
   {
      string disc = RecoveryReconciliation_OrderFullSerialization(src[i]);
      bool dup = false;
      for(int j = 0; j < ArraySize(seen); j++)
         if(seen[j] == disc) { dup = true; break; }
      if(dup) continue;
      int si = ArraySize(seen);
      ArrayResize(seen, si + 1);
      seen[si] = disc;
      int oi = ArraySize(out);
      ArrayResize(out, oi + 1);
      out[oi] = src[i];
   }
}

void RecoveryReconciliation_CollapseDeals(const RecoveredDealHistoryFact &src[], RecoveredDealHistoryFact &out[])
{
   ArrayResize(out, 0);
   string seen[];
   for(int i = 0; i < ArraySize(src); i++)
   {
      string disc = RecoveryReconciliation_DealFullSerialization(src[i]);
      bool dup = false;
      for(int j = 0; j < ArraySize(seen); j++)
         if(seen[j] == disc) { dup = true; break; }
      if(dup) continue;
      int si = ArraySize(seen);
      ArrayResize(seen, si + 1);
      seen[si] = disc;
      int oi = ArraySize(out);
      ArrayResize(out, oi + 1);
      out[oi] = src[i];
   }
}

//---------------------------------------------------------------------
// Row/array helpers.
//---------------------------------------------------------------------
void RRAppendRow(RecoveryReconciliationRow &rows[], int &count, const RecoveryReconciliationRow &row)
{
   ArrayResize(rows, count + 1);
   rows[count] = row;
   count++;
}

void RRAppendLocalGatedRow(RecoveryReconciliationRow &rows[], int &count, const LocalOrderRecoveryFact &lf,
                            string scope, ENUM_RECOVERY_FINDING finding)
{
   RecoveryReconciliationRow row;
   RecoveryReconciliationRow_Init(row);
   row.candidate_id = lf.candidate_id;
   row.order_ticket = lf.order_ticket;
   row.order_ticket_known = true;
   row.comparison_scope = scope;
   row.finding = finding;
   row.posture = RecoveryFindingToPosture(finding);
   RRAppendRow(rows, count, row);
}

bool RecoveryReconciliation_DealIsInDuplicateGroup(const RecoveredDealHistoryFact &deals[], int idx)
{
   if(!deals[idx].source_deal_ticket_known) return false;
   int count = 0;
   for(int i = 0; i < ArraySize(deals); i++)
      if(deals[i].source_deal_ticket_known && deals[i].source_deal_ticket == deals[idx].source_deal_ticket)
         count++;
   return count > 1;
}

//---------------------------------------------------------------------
// Sort (§9.9's frozen 6-key order). Stable insertion sort - dataset
// sizes here are recovery-scan scale, never large enough to need
// anything faster, and stability keeps the sort itself deterministic
// without depending on an unstable algorithm's own tie-breaking.
//---------------------------------------------------------------------
int RRScopeOrdinal(string scope) { return (scope == "ORDER") ? 0 : 1; }

bool RRRowLess(const RecoveryReconciliationRow &a, const RecoveryReconciliationRow &b)
{
   if(a.order_ticket_known != b.order_ticket_known) return a.order_ticket_known;
   if(a.order_ticket_known && a.order_ticket != b.order_ticket) return a.order_ticket < b.order_ticket;

   if(a.deal_ticket_known != b.deal_ticket_known) return a.deal_ticket_known;
   if(a.deal_ticket_known && a.deal_ticket != b.deal_ticket) return a.deal_ticket < b.deal_ticket;

   int sa = RRScopeOrdinal(a.comparison_scope), sb = RRScopeOrdinal(b.comparison_scope);
   if(sa != sb) return sa < sb;

   if(a.candidate_id != b.candidate_id) return a.candidate_id < b.candidate_id;

   int fa = (int)a.finding, fb = (int)b.finding;
   if(fa != fb) return fa < fb;

   return a.source_record_discriminator < b.source_record_discriminator;
}

void RRSortRows(RecoveryReconciliationRow &rows[])
{
   int n = ArraySize(rows);
   for(int i = 1; i < n; i++)
   {
      RecoveryReconciliationRow key = rows[i];
      int j = i - 1;
      while(j >= 0 && RRRowLess(key, rows[j]))
      {
         rows[j + 1] = rows[j];
         j--;
      }
      rows[j + 1] = key;
   }
}

//---------------------------------------------------------------------
// RecoveryReconciliation_BuildReport - the pure builder. Never calls a
// History* API, TimeCurrent(), or any registry global directly - every
// input arrives as an array argument, which is what makes this
// function directly unit-testable.
//---------------------------------------------------------------------
RecoveryReconciliationReport RecoveryReconciliation_BuildReport(
   const LocalOrderRecoveryFact &localFacts[],
   const RecoveredOrderHistoryFact &recoveredOrdersIn[],
   const RecoveredDealHistoryFact &recoveredDealsIn[],
   const RecoveryQueryOutcome &queryOutcomes[],
   int effectiveOverlapMinutes,
   bool overrideValid,
   string invalidOverrideError)
{
   RecoveryReconciliationReport report;
   RecoveryReconciliationReport_Init(report);

   if(!overrideValid)
   {
      report.ok = false;
      report.first_error = invalidOverrideError;
      return report;
   }

   // Outcome-array invariant check (QA-mandated): a known order_ticket
   // may appear in queryOutcomes[] at most once. ScanLive's own
   // construction guarantees this (one outcome per local fact), but the
   // pure builder does not trust a caller to uphold it - two outcomes
   // for the same ticket is a caller-side invariant violation, not a
   // per-row diagnostic, and fails the whole scan closed exactly like
   // an invalid override, choosing the deterministic LOWEST such ticket
   // for first_error.
   {
      bool foundAmbiguousOutcome = false;
      ulong lowestAmbiguousTicket = 0;
      for(int oc1 = 0; oc1 < ArraySize(queryOutcomes); oc1++)
      {
         if(!queryOutcomes[oc1].order_ticket_known) continue;
         int dupCount = 0;
         for(int oc2 = 0; oc2 < ArraySize(queryOutcomes); oc2++)
            if(queryOutcomes[oc2].order_ticket_known && queryOutcomes[oc2].order_ticket == queryOutcomes[oc1].order_ticket)
               dupCount++;
         if(dupCount > 1 && (!foundAmbiguousOutcome || queryOutcomes[oc1].order_ticket < lowestAmbiguousTicket))
         {
            foundAmbiguousOutcome = true;
            lowestAmbiguousTicket = queryOutcomes[oc1].order_ticket;
         }
      }
      if(foundAmbiguousOutcome)
      {
         report.ok = false;
         report.first_error = StringFormat("ambiguous query outcome: order_ticket %s appears more than once in queryOutcomes[] - whole scan fail-closed",
                                            IntegerToString((long)lowestAmbiguousTicket));
         return report;
      }
   }

   report.local_facts_scanned = ArraySize(localFacts);
   report.recovered_orders_scanned = ArraySize(recoveredOrdersIn);
   report.recovered_deals_scanned = ArraySize(recoveredDealsIn);

   RecoveredOrderHistoryFact orders[];
   RecoveryReconciliation_CollapseOrders(recoveredOrdersIn, orders);
   RecoveredDealHistoryFact deals[];
   RecoveryReconciliation_CollapseDeals(recoveredDealsIn, deals);

   RecoveryReconciliationRow rows[];
   int rowCount = 0;

   //--- (a) local-fact-driven direction: ORDER + AGGREGATE_DEAL_VOLUME ---
   for(int li = 0; li < ArraySize(localFacts); li++)
   {
      // Defensive ambiguous-local-match guard: ScanLive's own
      // OrderAggregateRegistry is keyed uniquely by order_ticket, so
      // this cannot occur in production, but the pure builder does not
      // rely on a caller upholding that invariant - a caller-supplied
      // localFacts[] with two entries sharing a ticket must not emit
      // two row-pairs for the same comparison-unit slot. Only the
      // FIRST occurrence is processed here; pass (b) below reclassifies
      // the corresponding recovered order as RECOVERY_UNMAPPABLE_HISTORY_RECORD
      // (ambiguous multi-match, §9.7's frozen mapping decision #1)
      // instead of assuming this pass owns it.
      bool dupLocalTicket = false;
      for(int pj = 0; pj < li; pj++)
         if(localFacts[pj].order_ticket == localFacts[li].order_ticket) { dupLocalTicket = true; break; }
      if(dupLocalTicket) continue;

      LocalOrderRecoveryFact lf = localFacts[li];

      RecoveryQueryOutcome outcome;
      RecoveryQueryOutcome_Init(outcome);
      bool haveOutcome = false;
      for(int qi = 0; qi < ArraySize(queryOutcomes); qi++)
      {
         if(queryOutcomes[qi].order_ticket_known && queryOutcomes[qi].order_ticket == lf.order_ticket)
         {
            outcome = queryOutcomes[qi];
            haveOutcome = true;
            break;
         }
      }

      bool gated = true;
      ENUM_RECOVERY_FINDING gateFinding = RECOVERY_WINDOW_INSUFFICIENT;
      if(!haveOutcome || !outcome.query_attempted)
         gateFinding = RECOVERY_WINDOW_INSUFFICIENT;
      else if(!outcome.query_succeeded)
         gateFinding = RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE;
      else if(outcome.adequacy != RECOVERY_WINDOW_ADEQUACY_PROVEN)
         // Both UNASSESSED and INSUFFICIENT map to the same frozen
         // finding here (C4.2.2 disposition, path (a)) - only a PROVEN
         // adequacy unlocks full evidence evaluation below.
         gateFinding = RECOVERY_WINDOW_INSUFFICIENT;
      else
         gated = false;

      if(gated)
      {
         RRAppendLocalGatedRow(rows, rowCount, lf, "ORDER", gateFinding);
         RRAppendLocalGatedRow(rows, rowCount, lf, "AGGREGATE_DEAL_VOLUME", gateFinding);
         continue;
      }

      // ORDER unit: C4.2 v1 Option B - local symbol is architecturally
      // always unknown, so this required compared field is always
      // unavailable on the local side.
      RecoveryReconciliationRow orderRow;
      RecoveryReconciliationRow_Init(orderRow);
      orderRow.candidate_id = lf.candidate_id;
      orderRow.order_ticket = lf.order_ticket;
      orderRow.order_ticket_known = true;
      orderRow.comparison_scope = "ORDER";
      orderRow.finding = RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE;
      orderRow.posture = RecoveryFindingToPosture(orderRow.finding);
      orderRow.detail = "local symbol is never known in C4.2 v1 (Option B) - ORDER unit cannot reach a full comparison";
      RRAppendRow(rows, rowCount, orderRow);

      // AGGREGATE_DEAL_VOLUME unit: independent of symbol, but NOT
      // independent of the deal's own attachment to a resolved recovered
      // order group (QA-mandated correction). A deal contributes to this
      // sum only when ALL of: its own deal_ticket is known; its
      // source_order_ticket is known and matches lf.order_ticket; it is
      // not in a duplicate deal-ticket group (§9.5); it attaches to
      // EXACTLY ONE collapsed recovered order-history fact for this
      // ticket (excludes both the zero-recovered-order/orphan case and
      // the duplicate-recovered-order-group case); and its volume is
      // known. An orphan deal (RECOVERY_ORPHAN_HISTORY_DEAL, emitted
      // separately below) never independently generates a successful
      // aggregate comparison - unresolved evidence must not influence a
      // corroboration/conflict conclusion.
      int recoveredOrderCountForTicket = 0;
      for(int oc3 = 0; oc3 < ArraySize(orders); oc3++)
         if(orders[oc3].source_order_ticket_known && orders[oc3].source_order_ticket == lf.order_ticket)
            recoveredOrderCountForTicket++;
      bool uniqueRecoveredOrderForTicket = (recoveredOrderCountForTicket == 1);

      // Does ANY candidate deal (source_order_ticket known, matching this
      // ticket) exist at all, regardless of eligibility? Distinguishes
      // "zero deal evidence exists" (still RECOVERY_NO_CORROBORATING_HISTORY)
      // from "deal evidence exists but every one of it is orphaned"
      // (recoveredOrderCountForTicket==0 - RECOVERY_ORPHAN_HISTORY_DEAL,
      // emitted separately in pass (c), already owns that discrepancy for
      // each such deal; emitting RECOVERY_NO_CORROBORATING_HISTORY here
      // too would be a duplicate row for the same underlying comparison
      // unit - QA-mandated correction, "dedup ownership").
      bool anyCandidateDealForTicket = false;
      for(int dc = 0; dc < ArraySize(deals); dc++)
         if(deals[dc].source_order_ticket_known && deals[dc].source_order_ticket == lf.order_ticket)
            { anyCandidateDealForTicket = true; break; }

      bool anyDeal = false;
      bool indeterminate = false;
      double sum = 0.0;
      for(int di = 0; di < ArraySize(deals); di++)
      {
         if(!deals[di].source_deal_ticket_known) continue;
         if(!deals[di].source_order_ticket_known || deals[di].source_order_ticket != lf.order_ticket) continue;
         if(RecoveryReconciliation_DealIsInDuplicateGroup(deals, di)) continue; // excluded per §9.5
         if(!uniqueRecoveredOrderForTicket) continue; // excludes orphan-order and duplicate-order-group deals
         anyDeal = true;
         if(!deals[di].volume_known) { indeterminate = true; continue; }
         sum += deals[di].volume;
      }

      // Suppress the AGGREGATE_DEAL_VOLUME row entirely when every
      // candidate deal for this ticket is orphaned (zero recovered order
      // matches) - RECOVERY_ORPHAN_HISTORY_DEAL already owns the
      // discrepancy for each such deal (pass (c) below). anyDeal is
      // necessarily false in this case (the uniqueRecoveredOrderForTicket
      // check above excludes every candidate deal uniformly per-ticket).
      bool suppressAggregateRow = anyCandidateDealForTicket && recoveredOrderCountForTicket == 0;

      if(!suppressAggregateRow)
      {
         RecoveryReconciliationRow aggRow;
         RecoveryReconciliationRow_Init(aggRow);
         aggRow.candidate_id = lf.candidate_id;
         aggRow.order_ticket = lf.order_ticket;
         aggRow.order_ticket_known = true;
         aggRow.comparison_scope = "AGGREGATE_DEAL_VOLUME";

         if(!anyDeal || indeterminate)
            aggRow.finding = RECOVERY_NO_CORROBORATING_HISTORY;
         else if(sum == lf.running_filled_volume)
            aggRow.finding = RECOVERY_FACT_CORROBORATED;
         else
            aggRow.finding = RECOVERY_FACT_CONFLICT;

         aggRow.posture = RecoveryFindingToPosture(aggRow.finding);
         RRAppendRow(rows, rowCount, aggRow);
      }
   }

   //--- (b) recovered-order-driven direction: UNMAPPABLE / DUPLICATE / ORPHAN_HISTORY_ORDER ---
   // ArrayResize does NOT guarantee zero-initialized new elements for a
   // primitive-type array in MQL5, and ArrayInitialize() does not accept
   // a bool array - so this must be initialized explicitly, element by
   // element, rather than relying on either (real-run-caught defect:
   // an unset element could read as garbage-true and silently skip a
   // real diagnostic row below).
   bool orderRowEmitted[];
   ArrayResize(orderRowEmitted, ArraySize(orders));
   for(int oz = 0; oz < ArraySize(orderRowEmitted); oz++) orderRowEmitted[oz] = false;

   for(int oi = 0; oi < ArraySize(orders); oi++)
   {
      if(orderRowEmitted[oi]) continue;

      if(!orders[oi].source_order_ticket_known)
      {
         RecoveryReconciliationRow row;
         RecoveryReconciliationRow_Init(row);
         row.comparison_scope = "ORDER";
         row.finding = RECOVERY_UNMAPPABLE_HISTORY_RECORD;
         row.posture = RecoveryFindingToPosture(row.finding);
         row.source_record_discriminator = RecoveryReconciliation_OrderDiscriminator(orders[oi]);
         RRAppendRow(rows, rowCount, row);
         orderRowEmitted[oi] = true;
         continue;
      }

      int groupIdx[];
      int groupCount = 0;
      for(int oj = oi; oj < ArraySize(orders); oj++)
      {
         if(orderRowEmitted[oj]) continue;
         if(orders[oj].source_order_ticket_known && orders[oj].source_order_ticket == orders[oi].source_order_ticket)
         {
            ArrayResize(groupIdx, groupCount + 1);
            groupIdx[groupCount] = oj;
            groupCount++;
         }
      }
      for(int g = 0; g < groupCount; g++)
         orderRowEmitted[groupIdx[g]] = true;

      if(groupCount > 1)
      {
         RecoveryReconciliationRow row;
         RecoveryReconciliationRow_Init(row);
         row.comparison_scope = "ORDER";
         row.order_ticket = orders[oi].source_order_ticket;
         row.order_ticket_known = true;
         row.finding = RECOVERY_DUPLICATE_HISTORY_RECORD;
         row.posture = RecoveryFindingToPosture(row.finding);
         RRAppendRow(rows, rowCount, row);
         continue;
      }

      int localMatchCount = 0;
      for(int li2 = 0; li2 < ArraySize(localFacts); li2++)
         if(localFacts[li2].order_ticket == orders[oi].source_order_ticket) localMatchCount++;

      if(localMatchCount == 0)
      {
         RecoveryReconciliationRow row;
         RecoveryReconciliationRow_Init(row);
         row.comparison_scope = "ORDER";
         row.order_ticket = orders[oi].source_order_ticket;
         row.order_ticket_known = true;
         row.finding = RECOVERY_ORPHAN_HISTORY_ORDER;
         row.posture = RecoveryFindingToPosture(row.finding);
         RRAppendRow(rows, rowCount, row);
      }
      else if(localMatchCount > 1)
      {
         // Ambiguous multi-match (§9.7's frozen mapping decision #1):
         // the known ticket resolves to more than one eligible local
         // fact. Cannot occur from ScanLive's own OrderAggregateRegistry
         // (unique by ticket), but the pure builder must still classify
         // it correctly if a caller ever supplies such a localFacts[].
         RecoveryReconciliationRow row;
         RecoveryReconciliationRow_Init(row);
         row.comparison_scope = "ORDER";
         row.finding = RECOVERY_UNMAPPABLE_HISTORY_RECORD;
         row.posture = RecoveryFindingToPosture(row.finding);
         row.source_record_discriminator = RecoveryReconciliation_OrderDiscriminator(orders[oi]);
         RRAppendRow(rows, rowCount, row);
      }
      // else (==1): already owned by pass (a)'s LOCAL_EVIDENCE_UNAVAILABLE row for this ticket.
   }

   //--- (c) recovered-deal-driven direction: UNMAPPABLE / DUPLICATE / ORPHAN_HISTORY_DEAL ---
   // Same explicit-initialization requirement as orderRowEmitted[] above.
   bool dealRowEmitted[];
   ArrayResize(dealRowEmitted, ArraySize(deals));
   for(int dz = 0; dz < ArraySize(dealRowEmitted); dz++) dealRowEmitted[dz] = false;

   for(int di = 0; di < ArraySize(deals); di++)
   {
      // Real-run-caught-pattern fix: either missing identity required for
      // recovered-deal handling makes the record unmappable - not just an
      // unknown source_order_ticket. A deal with a known order_ticket but
      // an UNKNOWN source_deal_ticket has no usable deal identity of its
      // own; the old condition here (order_ticket-only) let it fall
      // through this pass untouched, then get `continue`d out of the
      // duplicate-group pass below (which requires source_deal_ticket_known
      // to even attempt grouping), and finally get dealRowEmitted[di]=true
      // set unconditionally at the end of the orphan pass without ever
      // having emitted a row - silently dropping an identity-bearing
      // record from the report whenever hasRecoveredOrder==true or
      // hasLocal2==false for its order_ticket. Checking both knownness
      // flags here closes that gap the same way the symmetric ORDER-side
      // pass (b) already requires source_order_ticket_known up front.
      if(!deals[di].source_deal_ticket_known || !deals[di].source_order_ticket_known)
      {
         RecoveryReconciliationRow row;
         RecoveryReconciliationRow_Init(row);
         row.comparison_scope = "AGGREGATE_DEAL_VOLUME";
         row.finding = RECOVERY_UNMAPPABLE_HISTORY_RECORD;
         row.posture = RecoveryFindingToPosture(row.finding);
         row.source_record_discriminator = RecoveryReconciliation_DealDiscriminator(deals[di]);
         RRAppendRow(rows, rowCount, row);
         dealRowEmitted[di] = true;
      }
   }

   for(int di = 0; di < ArraySize(deals); di++)
   {
      if(dealRowEmitted[di]) continue;
      if(!deals[di].source_deal_ticket_known) continue;

      int groupIdx2[];
      int groupCount2 = 0;
      for(int dj = di; dj < ArraySize(deals); dj++)
      {
         if(dealRowEmitted[dj]) continue;
         if(deals[dj].source_deal_ticket_known && deals[dj].source_deal_ticket == deals[di].source_deal_ticket)
         {
            ArrayResize(groupIdx2, groupCount2 + 1);
            groupIdx2[groupCount2] = dj;
            groupCount2++;
         }
      }
      if(groupCount2 > 1)
      {
         for(int g = 0; g < groupCount2; g++)
            dealRowEmitted[groupIdx2[g]] = true;
         RecoveryReconciliationRow row;
         RecoveryReconciliationRow_Init(row);
         row.comparison_scope = "AGGREGATE_DEAL_VOLUME";
         row.deal_ticket = deals[di].source_deal_ticket;
         row.deal_ticket_known = true;
         row.finding = RECOVERY_DUPLICATE_HISTORY_RECORD;
         row.posture = RecoveryFindingToPosture(row.finding);
         RRAppendRow(rows, rowCount, row);
      }
   }

   for(int di = 0; di < ArraySize(deals); di++)
   {
      if(dealRowEmitted[di]) continue; // order_ticket known, not part of a duplicate group

      bool hasRecoveredOrder = false;
      for(int oi2 = 0; oi2 < ArraySize(orders); oi2++)
         if(orders[oi2].source_order_ticket_known && orders[oi2].source_order_ticket == deals[di].source_order_ticket)
            { hasRecoveredOrder = true; break; }

      bool hasLocal2 = false;
      for(int li3 = 0; li3 < ArraySize(localFacts); li3++)
         if(localFacts[li3].order_ticket == deals[di].source_order_ticket) { hasLocal2 = true; break; }

      if(!hasRecoveredOrder && hasLocal2)
      {
         RecoveryReconciliationRow row;
         RecoveryReconciliationRow_Init(row);
         row.comparison_scope = "AGGREGATE_DEAL_VOLUME";
         row.order_ticket = deals[di].source_order_ticket;
         row.order_ticket_known = true;
         row.deal_ticket = deals[di].source_deal_ticket;
         row.deal_ticket_known = deals[di].source_deal_ticket_known;
         row.finding = RECOVERY_ORPHAN_HISTORY_DEAL;
         row.posture = RecoveryFindingToPosture(row.finding);
         RRAppendRow(rows, rowCount, row);
      }
      dealRowEmitted[di] = true;
   }

   RRSortRows(rows);

   ArrayResize(report.rows, ArraySize(rows));
   for(int i = 0; i < ArraySize(rows); i++)
      report.rows[i] = rows[i];

   report.ok = true;
   for(int i = 0; i < ArraySize(report.rows); i++)
   {
      if(report.rows[i].posture == RECOVERY_POSTURE_DEGRADED || report.rows[i].posture == RECOVERY_POSTURE_BLOCK_RECOMMENDED)
      {
         report.ok = false;
         report.first_error = (report.rows[i].detail != "") ? report.rows[i].detail : EnumToString(report.rows[i].finding);
         break;
      }
   }

   return report;
}

//---------------------------------------------------------------------
// Acquisition layer - the ONLY call sites for HistorySelect()/
// HistoryOrderGet*/HistoryDealGet* in this codebase (via IHistorySource).
//---------------------------------------------------------------------
void RecoveryReconciliation_MaterializeOrder(IHistorySource &src, ulong ticket,
                                              datetime selFrom, datetime selTo, datetime serverTime, string sessionId,
                                              RecoveredOrderHistoryFact &out)
{
   RecoveredOrderHistoryFact_Init(out);
   out.schema_version = MLQUANTAI_RECOVERED_ORDER_HISTORY_SCHEMA_C4_V1;
   out.provenance_kind = "RECOVERED_ORDER_HISTORY";
   out.history_select_from = selFrom;
   out.history_select_to = selTo;
   out.history_query_server_time = serverTime;
   out.recovery_session_identity = sessionId;
   out.source_order_ticket = ticket;
   out.source_order_ticket_known = true;

   long li; double d; string s;

   src.ResetError();
   if(src.OrderGetInteger(ticket, ORDER_TYPE, li)) { out.order_type = EnumToString((ENUM_ORDER_TYPE)li); out.order_type_known = true; }

   src.ResetError();
   if(src.OrderGetInteger(ticket, ORDER_STATE, li)) { out.order_state = EnumToString((ENUM_ORDER_STATE)li); out.order_state_known = true; }

   src.ResetError();
   if(src.OrderGetDouble(ticket, ORDER_VOLUME_INITIAL, d)) { out.volume_initial = d; out.volume_initial_known = true; }

   src.ResetError();
   if(src.OrderGetDouble(ticket, ORDER_VOLUME_CURRENT, d)) { out.volume_current = d; out.volume_current_known = true; }

   src.ResetError();
   if(src.OrderGetDouble(ticket, ORDER_PRICE_OPEN, d)) { out.price_open = d; out.price_open_known = true; }

   src.ResetError();
   if(src.OrderGetDouble(ticket, ORDER_SL, d)) { out.price_sl = d; out.price_sl_known = true; }

   src.ResetError();
   if(src.OrderGetDouble(ticket, ORDER_TP, d)) { out.price_tp = d; out.price_tp_known = true; }

   src.ResetError();
   if(src.OrderGetString(ticket, ORDER_SYMBOL, s)) { out.symbol = s; out.symbol_known = true; }
}

// DEAL_ORDER is an identity reference, not an ordinary value property,
// and needs TWO distinct concepts, not one (QA-mandated correction):
//   - "read succeeded": the bool/out-param getter's own return value -
//     an acquisition-local concept only, never exposed on the frozen
//     RecoveredDealHistoryFact public schema (§9.4 stays untouched).
//   - "linkage known" (source_order_ticket_known, the public field):
//     true only when the read succeeded AND the value is non-zero - a
//     zero parent-order ticket is read-succeeded-but-unusable as a
//     recovery linkage key (C4.0 §6's "valid, known, positive ticket"
//     standard), so it is exposed to the rest of this module as unknown
//     linkage, never as a fabricated ticket. This is NOT a claim that
//     the generic "getter bool return is the sole knownness signal"
//     rule is being violated for an ordinary value property (it is not
//     - DEAL_PRICE==0.0 on a successful read stays known, unchanged);
//     it is a distinct, explicit "read succeeded, but the referenced
//     identity itself is unusable" state, modeled with its own local
//     variable below rather than folded into the generic pattern.
void RecoveryReconciliation_MaterializeDeal(IHistorySource &src, ulong ticket,
                                             datetime selFrom, datetime selTo, datetime serverTime, string sessionId,
                                             RecoveredDealHistoryFact &out)
{
   RecoveredDealHistoryFact_Init(out);
   out.schema_version = MLQUANTAI_RECOVERED_DEAL_HISTORY_SCHEMA_C4_V1;
   out.provenance_kind = "RECOVERED_DEAL_HISTORY";
   out.history_select_from = selFrom;
   out.history_select_to = selTo;
   out.history_query_server_time = serverTime;
   out.recovery_session_identity = sessionId;
   out.source_deal_ticket = ticket;
   out.source_deal_ticket_known = true;

   long li; double d; string s;

   src.ResetError();
   bool orderRefReadSucceeded = src.DealGetInteger(ticket, DEAL_ORDER, li);
   if(orderRefReadSucceeded)
   {
      out.source_order_ticket = (ulong)li;
      out.source_order_ticket_known = (li != 0); // read succeeded but value==0 -> unusable linkage, exposed as unknown
   }
   // orderRefReadSucceeded==false: read itself failed - source_order_ticket_known
   // stays false (its _Init default), source_order_ticket stays 0. Either
   // way, a deal with source_order_ticket_known==false is classified
   // RECOVERY_UNMAPPABLE_HISTORY_RECORD downstream (never RECOVERY_ORPHAN_
   // HISTORY_DEAL, which requires a KNOWN source_order_ticket whose
   // attachment fails) - see RecoveryReconciliation_BuildReport pass (c).

   src.ResetError();
   if(src.DealGetInteger(ticket, DEAL_TYPE, li)) { out.deal_type = EnumToString((ENUM_DEAL_TYPE)li); out.deal_type_known = true; }

   src.ResetError();
   if(src.DealGetDouble(ticket, DEAL_PRICE, d)) { out.price = d; out.price_known = true; }

   src.ResetError();
   if(src.DealGetDouble(ticket, DEAL_VOLUME, d)) { out.volume = d; out.volume_known = true; }

   src.ResetError();
   if(src.DealGetString(ticket, DEAL_SYMBOL, s)) { out.symbol = s; out.symbol_known = true; }
}

// Per-window extraction transaction (frozen): one Select() call,
// immediately followed by full materialization of every order/deal
// fact reachable in THAT selection, before this function returns.
// Never retains a ticket/index across a later Select() call - the next
// window's Select() may only run after this function has returned.
bool RecoveryReconciliation_AcquireWindowEvidence(
   IHistorySource &src,
   datetime queryFrom, datetime queryTo, datetime serverTime, string sessionId,
   RecoveredOrderHistoryFact &outOrders[], RecoveredDealHistoryFact &outDeals[],
   int &outSkippedOrderSlots, int &outSkippedDealSlots)
{
   ArrayResize(outOrders, 0);
   ArrayResize(outDeals, 0);
   outSkippedOrderSlots = 0;
   outSkippedDealSlots = 0;

   if(!src.Select(queryFrom, queryTo))
      return false;

   int ordersTotal = src.OrdersTotal();
   for(int i = 0; i < ordersTotal; i++)
   {
      ulong ticket = src.OrderTicketByIndex(i);
      if(ticket == 0) { outSkippedOrderSlots++; continue; } // enumeration boundary, not a fact
      RecoveredOrderHistoryFact fact;
      RecoveryReconciliation_MaterializeOrder(src, ticket, queryFrom, queryTo, serverTime, sessionId, fact);
      int idx = ArraySize(outOrders);
      ArrayResize(outOrders, idx + 1);
      outOrders[idx] = fact;
   }

   int dealsTotal = src.DealsTotal();
   for(int i = 0; i < dealsTotal; i++)
   {
      ulong ticket = src.DealTicketByIndex(i);
      if(ticket == 0) { outSkippedDealSlots++; continue; }
      RecoveredDealHistoryFact fact;
      RecoveryReconciliation_MaterializeDeal(src, ticket, queryFrom, queryTo, serverTime, sessionId, fact);
      int idx = ArraySize(outDeals);
      ArrayResize(outDeals, idx + 1);
      outDeals[idx] = fact;
   }

   return true;
}

// Internal/diagnostic-only counters (not part of RecoveryReconciliationReport,
// whose shape stays frozen per §9.9 - visible to tests/manual diagnostics only).
struct RecoveryScanDiagnostics
{
   int skipped_order_slots;
   int skipped_deal_slots;
};

void RecoveryScanDiagnostics_Init(RecoveryScanDiagnostics &d)
{
   d.skipped_order_slots = 0;
   d.skipped_deal_slots = 0;
}

//---------------------------------------------------------------------
// RecoveryReconciliation_BuildSessionIdentity - QA re-review correction:
// recovery_session_identity must be a stable fingerprint of the scan's
// CONFIGURATION and logical local-fact population, never of the wall-
// clock instant the scan happened to run. TimeCurrent() is external
// mutable state exactly like MathRand() was - two scans of the identical
// logical population, run in different seconds, must still resolve to
// the same session identity. This function takes NO time input at all
// (not scanServerTime, not TimeCurrent()) - by construction, time cannot
// leak in. Pure and directly testable: identical (effectiveOverlapMinutes,
// localFacts[]) always yields an identical string, in any process, at any
// time, per §9.9's collapse/discriminator determinism intent.
//
// Scope of this guarantee (explicit, not overclaimed): this makes
// recovery_session_identity itself time-independent. It does NOT by
// itself make a full RecoveryReconciliationReport byte-identical across
// two ScanLive() calls separated by real wall-clock time, because
// history_query_server_time (and the history_select_from/to bounds
// derived from it) remain part of every RecoveredOrderHistoryFact/
// RecoveredDealHistoryFact and therefore part of
// RecoveryReconciliation_OrderFullSerialization/DealFullSerialization's
// own collapse key and RecoveryReconciliation_OrderDiscriminator/
// DealDiscriminator's own sort-tiebreak string - not by §9.4 (which only
// defines the struct SHAPE), but by §9.9's own text: "Canonical duplicate
// collapse: Two recovered records are the same normalized evidence item
// when their applicable canonical serialization (as defined above) is
// byte-for-byte identical" - and the serialization "defined above" that
// clause points to is source_record_discriminator's frozen field list,
// which explicitly names history_select_from, history_select_to,
// history_query_server_time, and recovery_session_identity for both
// order and deal facts. So per that frozen §9.9 clause, and per the
// QA-mandated full-fact collapse correction that applied it (see that
// function's own header comment): two genuinely separate broker-history
// query observations must never be silently treated as one just because
// everything else about them matches. recovery_session_identity is
// scan-CLASS provenance; history_query_server_time is scan-INSTANT
// provenance - the two are intentionally different concepts, and only
// the former is addressed by this fix. See
// Test_SessionIdentity_ExcludesTime_QueryTimeDistinguishesFacts
// in Tests/MLQuantAI_Test_C4_2_RecoveryReconciliation.mq5 for the direct
// proof of that remaining, deliberate boundary.
//---------------------------------------------------------------------
string RecoveryReconciliation_BuildSessionIdentity(int effectiveOverlapMinutes, const LocalOrderRecoveryFact &localFacts[])
{
   int n = ArraySize(localFacts);
   string parts[];
   ArrayResize(parts, n);
   for(int i = 0; i < n; i++)
      parts[i] = StringFormat("T%s_A%s_K%s",
         IntegerToString((long)localFacts[i].order_ticket),
         TimeToString(localFacts[i].recovery_anchor_time, TIME_DATE|TIME_SECONDS),
         localFacts[i].recovery_anchor_time_known ? "1" : "0");

   // Canonical (deterministic) ordering, independent of the caller-
   // supplied array order - stable insertion sort, same precedent as
   // RRSortRows elsewhere in this file.
   for(int i = 1; i < n; i++)
   {
      string key = parts[i];
      int j = i - 1;
      while(j >= 0 && parts[j] > key) { parts[j + 1] = parts[j]; j--; }
      parts[j + 1] = key;
   }

   string joined = "";
   for(int i = 0; i < n; i++)
      joined = joined + parts[i] + "|";

   return StringFormat("C4RECOVERY_OVL_%d_%s", effectiveOverlapMinutes, joined);
}

//---------------------------------------------------------------------
// RecoveryReconciliation_ScanLive - the thin orchestrator. Reads the
// already-sealed OrderAggregateRegistry/ExecutionRequestProjection
// globals (never rebuilds them), validates the operator override
// first per §9.2's frozen sequencing (before any TimeCurrent()/
// HistorySelect() call), then acquires per-local-fact window evidence
// and hands everything to the pure builder above.
//
// FROZEN LIMITATION (QA-mandated, deliberate and explicit - not hidden;
// C4.2.2 disposition, path (a) - no docs amendment required, since §9.7
// row 2's own frozen wording already covers this: "adequacy ... cannot
// be proven"): a successful Select() is marked
// RECOVERY_WINDOW_ADEQUACY_UNASSESSED here, for every attempted query,
// NEVER RECOVERY_WINDOW_ADEQUACY_PROVEN. §3's adequacy predicate
// requires proof that the window covers the evidence interval a local
// fact requires - a successful HistorySelect() only proves the terminal
// ACCEPTED the selection request, never that broker-side history
// retention actually covers the full requested interval or omitted
// nothing. C4.2 v1 has no independently-verifiable adequacy-proof
// mechanism (broker retention limits are not queryable from MQL5), so
// this orchestrator can never legitimately claim PROVEN. UNASSESSED
// does NOT mean "broker retention is known-insufficient" - it means
// adequacy cannot be established under the currently available API and
// contract mechanisms. The practical consequence: RecoveryReconciliation_
// BuildReport's per-local-fact gate (only RECOVERY_WINDOW_ADEQUACY_PROVEN
// unlocks RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE/RECOVERY_NO_CORROBORATING_
// HISTORY/RECOVERY_FACT_CONFLICT/RECOVERY_FACT_CORROBORATED; both
// UNASSESSED and INSUFFICIENT map to RECOVERY_WINDOW_INSUFFICIENT) means
// EVERY successfully-queried local fact still resolves to
// RECOVERY_WINDOW_INSUFFICIENT, DEGRADED, in this checkpoint - C4.2 v1
// implements acquisition, normalization, and deterministic diagnostics
// (RECOVERY_UNMAPPABLE_HISTORY_RECORD/RECOVERY_DUPLICATE_HISTORY_RECORD/
// RECOVERY_ORPHAN_HISTORY_ORDER/RECOVERY_ORPHAN_HISTORY_DEAL, which are
// recovered-evidence-driven and independent of adequacy), but it cannot
// yet emit an evidence-sufficiency or corroboration/conflict conclusion.
// That requires a future, separately adopted contract amendment or
// mechanism that can set RECOVERY_WINDOW_ADEQUACY_PROVEN. See
// Test_ScanLive_SuccessfulQuery_WindowNeverProvenAdequate in
// Tests/MLQuantAI_Test_C4_2_RecoveryReconciliation.mq5 for the
// deterministic proof of this limitation.
//---------------------------------------------------------------------
RecoveryReconciliationReport RecoveryReconciliation_ScanLive(
   IHistorySource &src,
   bool overrideSupplied, int overlapMinutesOverride,
   RecoveryScanDiagnostics &outDiag)
{
   RecoveryScanDiagnostics_Init(outDiag);

   if(overrideSupplied && overlapMinutesOverride <= 0)
   {
      LocalOrderRecoveryFact emptyLocal[];
      RecoveredOrderHistoryFact emptyOrders[];
      RecoveredDealHistoryFact emptyDeals[];
      RecoveryQueryOutcome emptyOutcomes[];
      return RecoveryReconciliation_BuildReport(emptyLocal, emptyOrders, emptyDeals, emptyOutcomes,
                                                 overlapMinutesOverride, false,
                                                 "invalid operator-supplied overlap override <= 0 - whole scan fail-closed, no HistorySelect() call made");
   }

   int effectiveOverlapMinutes = overrideSupplied ? overlapMinutesOverride : MLQUANTAI_C4_RECOVERY_OVERLAP_MINUTES_DEFAULT;

   int localCount = OrderAggregateRegistry_Count();
   LocalOrderRecoveryFact localFacts[];
   ArrayResize(localFacts, localCount);
   for(int i = 0; i < localCount; i++)
   {
      OrderAggregateRecord agg;
      if(!OrderAggregateRegistry_GetAt(i, agg))
      {
         // Defensive fail-closed (real-run-caught-defect precedent, same
         // discipline as the ArrayResize bool-init fix above): GetAt only
         // returns false for index<0 or index>=OrderAggregateRegistry_Count(),
         // which cannot happen here since i ranges over [0, localCount) and
         // localCount IS that same Count() captured immediately above, with
         // no intervening call that could shrink the registry. Structurally
         // unreachable today, exactly like the ambiguous-outcome/dupLocalTicket
         // guards in BuildReport - but the return value is never trusted
         // silently. A false return here means the registry's own invariant
         // was violated between Count() and GetAt(); rather than process a
         // never-assigned OrderAggregateRecord as a fabricated local fact,
         // the whole scan fails closed before TimeCurrent(), HistorySelect(),
         // or any history getter call (QA re-review correction: TimeCurrent()
         // used to be captured above this loop - it is now captured only
         // after this loop fully succeeds, below, so this fail-closed branch
         // can never be preceded by ANY external runtime read, not just
         // HistorySelect()).
         LocalOrderRecoveryFact emptyLocal[];
         RecoveredOrderHistoryFact emptyOrders[];
         RecoveredDealHistoryFact emptyDeals[];
         RecoveryQueryOutcome emptyOutcomes[];
         return RecoveryReconciliation_BuildReport(emptyLocal, emptyOrders, emptyDeals, emptyOutcomes,
                                                    effectiveOverlapMinutes, false,
                                                    StringFormat("OrderAggregateRegistry_GetAt(%d) failed unexpectedly - whole scan fail-closed, no HistorySelect() call made", i));
      }
      LocalOrderRecoveryFact_Init(localFacts[i]);
      localFacts[i].order_ticket = agg.order_ticket;
      localFacts[i].running_filled_volume = agg.running_filled_volume;
      if(agg.matched_execution_request_id != "")
      {
         ExecutionRequestProjectionRecord execReq;
         if(ExecutionRequestProjection_TryGet(agg.matched_execution_request_id, execReq))
         {
            localFacts[i].matched = true;
            localFacts[i].candidate_id = execReq.candidate_id;
            localFacts[i].local_order_type = execReq.side;
            localFacts[i].local_order_type_known = true;
            localFacts[i].local_volume_initial = execReq.lot_size;
            localFacts[i].local_volume_initial_known = true;
            localFacts[i].recovery_anchor_time = execReq.recovery_anchor_time;
            localFacts[i].recovery_anchor_time_known = execReq.recovery_anchor_time_known;
         }
      }
   }

   // One capture per scan (§9.2). QA re-review correction: this used to
   // be captured before the local-fact snapshot loop above; it is now
   // captured only here, after that loop has fully succeeded (every
   // OrderAggregateRegistry_GetAt call returned true) - the local
   // registry is the prerequisite that defines the scan population, so a
   // failure to retrieve it must terminate before ANY external runtime
   // input, including this clock read, not merely before HistorySelect().
   // Used ONLY as per-fact query-time provenance below, never as part of
   // sessionId.
   datetime scanServerTime = TimeCurrent();

   // Deterministic, time-independent session identity - built only now
   // that localFacts[] is fully populated, since RecoveryReconciliation_
   // BuildSessionIdentity's whole point is to derive from the scan's
   // logical local-fact population instead of scanServerTime/MathRand().
   string sessionId = RecoveryReconciliation_BuildSessionIdentity(effectiveOverlapMinutes, localFacts);

   RecoveredOrderHistoryFact allOrders[];
   RecoveredDealHistoryFact allDeals[];
   RecoveryQueryOutcome outcomes[];
   ArrayResize(outcomes, localCount);

   for(int i = 0; i < localCount; i++)
   {
      RecoveryQueryOutcome_Init(outcomes[i]);
      outcomes[i].order_ticket = localFacts[i].order_ticket;
      outcomes[i].order_ticket_known = true;

      if(!localFacts[i].recovery_anchor_time_known)
      {
         // No durable local anchor - the window cannot be constructed at
         // all for this ticket. Select() is never called for it. Bounds
         // are invalid, so adequacy is explicitly INSUFFICIENT (per the
         // C4.2.2 disposition table) - though query_attempted staying
         // false already governs the emitted finding regardless.
         outcomes[i].adequacy = RECOVERY_WINDOW_ADEQUACY_INSUFFICIENT;
         continue; // query_attempted/query_succeeded remain false, per _Init
      }

      datetime queryFrom = localFacts[i].recovery_anchor_time - effectiveOverlapMinutes * 60;
      datetime queryTo   = scanServerTime;
      outcomes[i].query_from = queryFrom;
      outcomes[i].query_to   = queryTo;
      outcomes[i].query_attempted = true;

      RecoveredOrderHistoryFact windowOrders[];
      RecoveredDealHistoryFact windowDeals[];
      int skippedO = 0, skippedD = 0;
      bool succeeded = RecoveryReconciliation_AcquireWindowEvidence(src, queryFrom, queryTo, scanServerTime, sessionId,
                                                                      windowOrders, windowDeals, skippedO, skippedD);
      outDiag.skipped_order_slots += skippedO;
      outDiag.skipped_deal_slots  += skippedD;
      outcomes[i].query_succeeded = succeeded;
      // A successful query is marked UNASSESSED, never PROVEN - see this
      // function's header comment (FROZEN LIMITATION / C4.2.2 disposition
      // path (a)). A successful Select() proves only that the terminal
      // accepted the request, never that broker-side history retention
      // actually covered the full requested interval. C4.2 v1 has no
      // independently-verifiable adequacy-proof mechanism, so it never
      // claims PROVEN - deliberately and explicitly, not silently. A
      // failed query (succeeded==false) leaves adequacy at its _Init
      // default (UNASSESSED) too - it is not evaluated in that branch,
      // since RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE already governs.
      outcomes[i].adequacy = RECOVERY_WINDOW_ADEQUACY_UNASSESSED;

      if(succeeded)
      {
         for(int j = 0; j < ArraySize(windowOrders); j++)
         {
            int idx = ArraySize(allOrders);
            ArrayResize(allOrders, idx + 1);
            allOrders[idx] = windowOrders[j];
         }
         for(int j = 0; j < ArraySize(windowDeals); j++)
         {
            int idx = ArraySize(allDeals);
            ArrayResize(allDeals, idx + 1);
            allDeals[idx] = windowDeals[j];
         }
      }
   }

   return RecoveryReconciliation_BuildReport(localFacts, allOrders, allDeals, outcomes,
                                              effectiveOverlapMinutes, true, "");
}

#endif // __MLQUANTAI_RECOVERYRECONCILIATION_MQH__
