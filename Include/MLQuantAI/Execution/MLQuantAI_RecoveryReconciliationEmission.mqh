//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_RecoveryReconciliationEmission.mqh |
//| RA-33.2 (QA-frozen C4.4 Row-Level Evidence Emission): durably       |
//| records every NON-CLEAN row already computed by                     |
//| MLQuantAI_RecoveryReconciliation.mqh's RecoveryReconciliation_       |
//| StartupScan() - that sealed file is never modified by this one, and  |
//| this file adds no new reconciliation LOGIC at all, only a durable    |
//| write of a result that already existed in memory and was previously  |
//| only summarized into a LogInfo line and then discarded.              |
//|                                                                      |
//| Non-clean (QA-frozen definition): posture != RECOVERY_POSTURE_       |
//| INFORMATIONAL (the only posture RECOVERY_FACT_CORROBORATED - the      |
//| "everything lines up" finding - ever maps to, per                     |
//| RecoveryFindingToPosture's own frozen table). Every other finding     |
//| maps to DEGRADED or BLOCK_RECOMMENDED and is emitted.                 |
//|                                                                      |
//| source_record_discriminator is carried through VERBATIM from the      |
//| row - never reconstructed/re-derived here (QA's explicit provenance   |
//| rule) - it already embeds ticket/symbol/type/volume/price/history-    |
//| window identity per RecoveryReconciliation_DealDiscriminator()/       |
//| _OrderDiscriminator()'s own frozen field lists.                       |
//|                                                                      |
//| position_ticket has no representation anywhere in                    |
//| RecoveredOrderHistoryFact/RecoveredDealHistoryFact (C4.x's own        |
//| query model never captures it) - always emitted as                    |
//| position_ticket_known=false/position_ticket=0, never fabricated,      |
//| never silently omitted (QA's explicit "UNKNOWN != 0-real-ticket"      |
//| semantic).                                                            |
//|                                                                      |
//| Diagnostic-only, same philosophy as C4.4 itself (Docs/                |
//| PhaseC_C4_RecoveryCoverageAttestationContract.md): an emission         |
//| failure here is logged and counted, never trips Safe Mode, never      |
//| blocks EA initialization, and never alters                            |
//| RecoveryReconciliationReport.ok or any other field of the report      |
//| this file only reads (QA condition AC-6).                             |
//|                                                                      |
//| No OrderSend/CTrade/broker call anywhere in this file. No             |
//| candidate-lifecycle transition. No BROKER_TRANSACTION_OBSERVED write  |
//| - EVENT_TYPE_RECOVERY_RECONCILIATION_ROW_OBSERVED is a distinct type  |
//| with no ticket/deal/retcode top-level shape a parser keyed on L3      |
//| could mistake for a live broker transaction (QA condition AC-8).      |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_RECOVERYRECONCILIATIONEMISSION_MQH__
#define __MLQUANTAI_RECOVERYRECONCILIATIONEMISSION_MQH__

#include "../Infrastructure/EventStore/MLQuantAI_EventStore.mqh"
#include "../Core/MLQuantAI_Enums.mqh"
#include "MLQuantAI_RecoveryReconciliation.mqh"

#define MLQUANTAI_RECOVERY_RECONCILIATION_ROW_EMISSION_SCHEMA_V1 "RECOVERY_RECONCILIATION_ROW_EMISSION_V1"

//---------------------------------------------------------------------
// Round-trip string conversions for the two sealed enums this file
// reads but never redefines (ENUM_RECOVERY_FINDING/ENUM_RECOVERY_
// POSTURE both live in MLQuantAI_RecoveryReconciliation.mqh, untouched -
// no ToString/FromString existed there before this file; adding them
// HERE instead of in the sealed file keeps that file's own diff at
// zero, per RA-33.2's authorized scope).
//---------------------------------------------------------------------
string RecoveryFindingToString(ENUM_RECOVERY_FINDING f)
{
   switch(f)
   {
      case RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE:   return "LOCAL_EVIDENCE_UNAVAILABLE";
      case RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE: return "HISTORY_EVIDENCE_UNAVAILABLE";
      case RECOVERY_WINDOW_INSUFFICIENT:          return "WINDOW_INSUFFICIENT";
      case RECOVERY_NO_CORROBORATING_HISTORY:     return "NO_CORROBORATING_HISTORY";
      case RECOVERY_FACT_CORROBORATED:            return "FACT_CORROBORATED";
      case RECOVERY_FACT_CONFLICT:                return "FACT_CONFLICT";
      case RECOVERY_ORPHAN_HISTORY_ORDER:         return "ORPHAN_HISTORY_ORDER";
      case RECOVERY_ORPHAN_HISTORY_DEAL:          return "ORPHAN_HISTORY_DEAL";
      case RECOVERY_DUPLICATE_HISTORY_RECORD:     return "DUPLICATE_HISTORY_RECORD";
      case RECOVERY_UNMAPPABLE_HISTORY_RECORD:    return "UNMAPPABLE_HISTORY_RECORD";
   }
   return "UNKNOWN";
}

ENUM_RECOVERY_FINDING RecoveryFindingFromString(string s)
{
   if(s == "LOCAL_EVIDENCE_UNAVAILABLE")   return RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE;
   if(s == "HISTORY_EVIDENCE_UNAVAILABLE") return RECOVERY_HISTORY_EVIDENCE_UNAVAILABLE;
   if(s == "WINDOW_INSUFFICIENT")          return RECOVERY_WINDOW_INSUFFICIENT;
   if(s == "NO_CORROBORATING_HISTORY")     return RECOVERY_NO_CORROBORATING_HISTORY;
   if(s == "FACT_CORROBORATED")            return RECOVERY_FACT_CORROBORATED;
   if(s == "FACT_CONFLICT")                return RECOVERY_FACT_CONFLICT;
   if(s == "ORPHAN_HISTORY_ORDER")         return RECOVERY_ORPHAN_HISTORY_ORDER;
   if(s == "ORPHAN_HISTORY_DEAL")          return RECOVERY_ORPHAN_HISTORY_DEAL;
   if(s == "DUPLICATE_HISTORY_RECORD")     return RECOVERY_DUPLICATE_HISTORY_RECORD;
   if(s == "UNMAPPABLE_HISTORY_RECORD")    return RECOVERY_UNMAPPABLE_HISTORY_RECORD;
   return RECOVERY_LOCAL_EVIDENCE_UNAVAILABLE; // no UNKNOWN member exists on this sealed enum - see file header
}

string RecoveryPostureToString(ENUM_RECOVERY_POSTURE p)
{
   switch(p)
   {
      case RECOVERY_POSTURE_INFORMATIONAL:    return "INFORMATIONAL";
      case RECOVERY_POSTURE_DEGRADED:         return "DEGRADED";
      case RECOVERY_POSTURE_BLOCK_RECOMMENDED: return "BLOCK_RECOMMENDED";
   }
   return "UNKNOWN";
}

ENUM_RECOVERY_POSTURE RecoveryPostureFromString(string s)
{
   if(s == "INFORMATIONAL")     return RECOVERY_POSTURE_INFORMATIONAL;
   if(s == "DEGRADED")          return RECOVERY_POSTURE_DEGRADED;
   if(s == "BLOCK_RECOMMENDED") return RECOVERY_POSTURE_BLOCK_RECOMMENDED;
   return RECOVERY_POSTURE_INFORMATIONAL; // no UNKNOWN member exists on this sealed enum - see file header
}

// QA-frozen non-clean definition: RECOVERY_FACT_CORROBORATED is the only
// finding RecoveryFindingToPosture ever maps to RECOVERY_POSTURE_
// INFORMATIONAL - every other finding is DEGRADED or BLOCK_RECOMMENDED.
bool RecoveryReconciliationRow_IsNonClean(const RecoveryReconciliationRow &row)
{
   return row.posture != RECOVERY_POSTURE_INFORMATIONAL;
}

string RecoveryReconciliationRow_ToExtraJson(const RecoveryReconciliationRow &row)
{
   string s = "";
   s += "\"recovery_reconciliation_row_schema_version\":\"" + MLQUANTAI_RECOVERY_RECONCILIATION_ROW_EMISSION_SCHEMA_V1 + "\",";
   s += "\"candidate_id\":\""          + EventSerializer_Escape(row.candidate_id) + "\",";
   s += "\"order_ticket_known\":"      + (row.order_ticket_known ? "true" : "false") + ",";
   s += "\"order_ticket\":"            + IntegerToString((long)row.order_ticket) + ",";
   s += "\"deal_ticket_known\":"       + (row.deal_ticket_known ? "true" : "false") + ",";
   s += "\"deal_ticket\":"             + IntegerToString((long)row.deal_ticket) + ",";
   // position_ticket: no representation anywhere in the source Fact
   // structs (QA-acknowledged gap, out of RA-33.2 scope to close) -
   // always explicitly UNKNOWN, never fabricated as a real 0 ticket.
   s += "\"position_ticket_known\":false,";
   s += "\"position_ticket\":0,";
   s += "\"comparison_scope\":\""      + EventSerializer_Escape(row.comparison_scope) + "\",";
   s += "\"finding\":\""               + EventSerializer_Escape(RecoveryFindingToString(row.finding)) + "\",";
   s += "\"posture\":\""               + EventSerializer_Escape(RecoveryPostureToString(row.posture)) + "\",";
   // Verbatim, never reconstructed - QA's explicit provenance rule.
   s += "\"source_record_discriminator\":\"" + EventSerializer_Escape(row.source_record_discriminator) + "\",";
   s += "\"detail\":\""                + EventSerializer_Escape(row.detail) + "\"";
   return s;
}

bool EventStore_LogRecoveryReconciliationRow(const RecoveryReconciliationRow &row)
{
   return EventStore_LogSystem(EventTypeToString(EVENT_TYPE_RECOVERY_RECONCILIATION_ROW_OBSERVED),
                                 "recovery reconciliation row observed",
                                 RecoveryReconciliationRow_ToExtraJson(row));
}

struct RecoveryReconciliationEmissionReport
{
   int rows_total;
   int rows_non_clean;
   int rows_emitted;
   int rows_emit_failed;
};

void RecoveryReconciliationEmissionReport_Init(RecoveryReconciliationEmissionReport &r)
{
   r.rows_total = 0;
   r.rows_non_clean = 0;
   r.rows_emitted = 0;
   r.rows_emit_failed = 0;
}

// The one entry point MLQuantAI.mq5's OnInit calls, immediately after
// RecoveryReconciliation_StartupScan() returns - reads report.rows[]
// only, never re-runs or mutates the scan itself. An emit failure is
// counted (rows_emit_failed) and the loop continues - never trips Safe
// Mode, never blocks EA initialization, and this function returns no
// pass/fail verdict of its own for the caller to misread as having
// changed the underlying recovery result (QA condition AC-6/AC-7).
RecoveryReconciliationEmissionReport RecoveryReconciliationEmission_EmitNonCleanRows(const RecoveryReconciliationReport &report)
{
   RecoveryReconciliationEmissionReport er;
   RecoveryReconciliationEmissionReport_Init(er);

   er.rows_total = ArraySize(report.rows);
   for(int i = 0; i < er.rows_total; i++)
   {
      if(!RecoveryReconciliationRow_IsNonClean(report.rows[i]))
         continue;
      er.rows_non_clean++;

      if(EventStore_LogRecoveryReconciliationRow(report.rows[i]))
         er.rows_emitted++;
      else
         er.rows_emit_failed++;
   }
   return er;
}

#endif // __MLQUANTAI_RECOVERYRECONCILIATIONEMISSION_MQH__
