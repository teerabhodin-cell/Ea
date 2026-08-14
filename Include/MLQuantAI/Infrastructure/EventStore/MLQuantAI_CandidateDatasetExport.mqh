//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_CandidateDatasetExport.mqh|
//| Phase B B6.2: canonical dataset export - read-only, projected from |
//| B6.1's CandidateProjection registry (which itself only ever reads  |
//| persisted CANDIDATE_CREATED/MARKET_CONTEXT_READY lines back). No    |
//| CRT detector call, no B5 Strategies/ file touched, no event append, |
//| no state mutation - export is purely: rebuild the registry, join    |
//| each candidate against its MARKET_CONTEXT_READY event, sort, hash,  |
//| serialize.                                                          |
//|                                                                    |
//| Column gap (flagged in Docs/PhaseB_B6_1_CandidateProjection.md,     |
//| resolved here by JOINING rather than reopening sealed B5 code):     |
//| instrument_id/trigger_timeframe/news_decision_hash/news_snapshot_   |
//| identity are joined from the candidate's own MARKET_CONTEXT_READY   |
//| event via context_event_id. swept_level/mss_confirmation_price/     |
//| resolved_zone_kind/resolved_zone_low/resolved_zone_high have NO     |
//| persisted source at all - CRTDetectionResult (the only place they   |
//| ever exist) is never itself written to the Event Store, and no      |
//| join can produce data nothing wrote. They export as empty/zero,     |
//| explicitly flagged in the manifest and in code, rather than being   |
//| silently omitted, fabricated, or reconstructed by re-running the    |
//| detector (which would violate "everything read-only from the event  |
//| store" - B6's own standing rule). strategy_version has the same      |
//| problem for a different reason: Commit 5's extra_json never          |
//| persisted it (only strategy_id, a bare int) - strategy_name IS       |
//| available (StrategyIdToString(strategy_id) is a pure function of an  |
//| already-captured field), but the RULES version ("CRT_V1") is not     |
//| recoverable from strategy_id alone and also exports empty.           |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CANDIDATEDATASETEXPORT_MQH__
#define __MLQUANTAI_CANDIDATEDATASETEXPORT_MQH__

#include "MLQuantAI_CandidateProjection.mqh"
#include "../../Core/MLQuantAI_Ids.mqh"

// One exported dataset row - the B6.2 canonical column list from the
// kickoff spec, field for field. Columns marked "NOT AVAILABLE" below
// always export empty/zero in this build - see the file header.
struct CandidateDatasetRow
{
   string   candidate_id;
   string   root_event_id;
   string   candidate_hash;
   string   detector_hash;
   string   context_event_id;
   string   context_hash;
   int      strategy_id;
   string   strategy_name;      // derived from strategy_id via StrategyIdToString() - a pure function of an already-captured field, not a new persisted dependency
   string   strategy_version;   // NOT AVAILABLE - see file header (Commit 5's extra_json never persisted it; strategy_id alone can't reconstruct it)

   string   instrument_id;       // joined from MARKET_CONTEXT_READY
   string   trigger_timeframe;   // joined from MARKET_CONTEXT_READY

   ENUM_ORDER_TYPE side;
   datetime setup_anchor_bar_time;
   datetime expiry_time;

   double   swept_level;             // NOT AVAILABLE - see file header
   double   mss_confirmation_price;  // NOT AVAILABLE
   string   resolved_zone_kind;      // NOT AVAILABLE
   double   resolved_zone_low;       // NOT AVAILABLE
   double   resolved_zone_high;      // NOT AVAILABLE

   double   entry_hint;
   double   sl_hint;
   double   tp_hint;

   ulong    trigger_reason_mask;
   string   trigger_reasons[];

   bool     has_liquidity_sweep;  // derived from trigger_reason_mask, same rule Commit 4's CRT_ToTradeCandidate uses
   bool     has_mss;
   bool     has_fvg;
   bool     has_order_block;
   bool     in_killzone;
   bool     news_risk;

   string   news_decision_hash;      // joined from MARKET_CONTEXT_READY
   string   news_snapshot_identity;  // joined from MARKET_CONTEXT_READY

   string   candidate_state;  // always "CREATED" - this projection never applies later transitions

   int      digits;       // joined from MARKET_CONTEXT_READY's symbol_spec_digits - governs this row's own price formatting
   bool     context_joined; // false if no matching MARKET_CONTEXT_READY was found (should never happen for a row that made it into the registry - RebuildFromFile already enforces referential integrity - kept as a defensive/audit flag, not a gate)

   string   row_hash;  // computed last, see CandidateDatasetExport_RowHash
};

void CandidateDatasetRow_Init(CandidateDatasetRow &r)
{
   r.candidate_id = "";
   r.root_event_id = "";
   r.candidate_hash = "";
   r.detector_hash = "";
   r.context_event_id = "";
   r.context_hash = "";
   r.strategy_id = -1;
   r.strategy_name = "";
   r.strategy_version = "";

   r.instrument_id = "";
   r.trigger_timeframe = "";

   r.side = ORDER_TYPE_BUY;
   r.setup_anchor_bar_time = 0;
   r.expiry_time = 0;

   r.swept_level = 0;
   r.mss_confirmation_price = 0;
   r.resolved_zone_kind = "";
   r.resolved_zone_low = 0;
   r.resolved_zone_high = 0;

   r.entry_hint = 0;
   r.sl_hint = 0;
   r.tp_hint = 0;

   r.trigger_reason_mask = 0;
   ArrayResize(r.trigger_reasons, 0);

   r.has_liquidity_sweep = false;
   r.has_mss = false;
   r.has_fvg = false;
   r.has_order_block = false;
   r.in_killzone = false;
   r.news_risk = false;

   r.news_decision_hash = "";
   r.news_snapshot_identity = "";

   r.candidate_state = "";
   r.digits = 5;
   r.context_joined = false;

   r.row_hash = "";
}

//---------------------------------------------------------------------
// Context join table - context_event_id -> the MARKET_CONTEXT_READY
// fields this export needs. A richer counterpart to CandidateProjection_
// CollectContextHashes (which only needs id+hash for its own referential
// check); this one also pulls instrument_id/trigger_timeframe/
// news_decision_hash/news_snapshot_identity/symbol_spec_digits.
//---------------------------------------------------------------------
struct DatasetContextJoinEntry
{
   string context_event_id;
   string context_hash;
   string instrument_id;
   string trigger_timeframe;
   string news_decision_hash;
   string news_snapshot_identity;
   int    digits;
};

int CandidateDatasetExport_CollectContextJoinTable(const string &lines[], DatasetContextJoinEntry &out[])
{
   ArrayResize(out, 0);
   int count = 0;
   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY)) continue;
      string id = EventSerializer_GetStr(lines[i], "context_event_id");
      if(id == "") continue;
      ArrayResize(out, count + 1);
      out[count].context_event_id       = id;
      out[count].context_hash            = EventSerializer_GetStr(lines[i], "context_hash");
      out[count].instrument_id            = EventSerializer_GetStr(lines[i], "instrument_id");
      out[count].trigger_timeframe        = EventSerializer_GetStr(lines[i], "trigger_timeframe");
      out[count].news_decision_hash       = EventSerializer_GetStr(lines[i], "news_decision_hash");
      out[count].news_snapshot_identity   = EventSerializer_GetStr(lines[i], "news_snapshot_identity");
      out[count].digits                   = EventSerializer_GetInt(lines[i], "symbol_spec_digits");
      count++;
   }
   return count;
}

bool CandidateDatasetExport_FindContextJoin(const DatasetContextJoinEntry &table[], string contextEventId, DatasetContextJoinEntry &out)
{
   for(int i = 0; i < ArraySize(table); i++)
   {
      if(table[i].context_event_id == contextEventId)
      {
         out = table[i];
         return true;
      }
   }
   return false;
}

//---------------------------------------------------------------------
// Row construction - a pure mapping from a registered CandidateProjectionRecord
// (+ its joined context) to a CandidateDatasetRow. has_*/in_killzone/
// news_risk are derived from trigger_reason_mask using the same bit
// definitions CRT_ToTradeCandidate (Commit 4) already uses - not a new
// rule, just not re-persisted since they're redundant with the mask.
//---------------------------------------------------------------------
void CandidateDatasetExport_BuildRow(const CandidateProjectionRecord &rec, const DatasetContextJoinEntry &table[], CandidateDatasetRow &row)
{
   CandidateDatasetRow_Init(row);

   row.candidate_id       = rec.candidate_id;
   row.root_event_id      = rec.root_event_id;
   row.candidate_hash     = rec.candidate_hash;
   row.detector_hash      = rec.detector_hash;
   row.context_event_id   = rec.context_event_id;
   row.context_hash        = rec.context_hash;
   row.strategy_id         = rec.strategy_id;
   row.strategy_name       = StrategyIdToString(rec.strategy_id); // pure function of strategy_id - not a new persisted dependency
   row.strategy_version    = ""; // NOT AVAILABLE - see file header

   row.side = rec.side;
   row.setup_anchor_bar_time = rec.setup_anchor_bar_time;
   row.expiry_time            = rec.expiry_time;

   row.entry_hint = rec.entry_hint;
   row.sl_hint    = rec.sl_hint;
   row.tp_hint    = rec.tp_hint;

   row.trigger_reason_mask = rec.trigger_reason_mask;
   ArrayResize(row.trigger_reasons, ArraySize(rec.trigger_reasons));
   for(int i = 0; i < ArraySize(rec.trigger_reasons); i++)
      row.trigger_reasons[i] = rec.trigger_reasons[i];

   row.has_liquidity_sweep = (rec.trigger_reason_mask & (CRT_REASON_BIT_SWEEP_LOW | CRT_REASON_BIT_SWEEP_HIGH)) != 0;
   row.has_mss              = (rec.trigger_reason_mask & CRT_REASON_BIT_MSS_CONFIRMED) != 0;
   row.has_fvg               = (rec.trigger_reason_mask & CRT_REASON_BIT_FVG_FOUND) != 0;
   row.has_order_block       = (rec.trigger_reason_mask & CRT_REASON_BIT_OB_FOUND) != 0;
   row.in_killzone            = (rec.trigger_reason_mask & CRT_REASON_BIT_KILLZONE) != 0;
   row.news_risk              = (rec.trigger_reason_mask & CRT_REASON_BIT_NEWS_RISK) != 0;

   row.candidate_state = CandidateStateToString(rec.state);

   DatasetContextJoinEntry ctxJoin;
   if(CandidateDatasetExport_FindContextJoin(table, rec.context_event_id, ctxJoin))
   {
      row.context_joined         = true;
      row.instrument_id           = ctxJoin.instrument_id;
      row.trigger_timeframe       = ctxJoin.trigger_timeframe;
      row.news_decision_hash      = ctxJoin.news_decision_hash;
      row.news_snapshot_identity  = ctxJoin.news_snapshot_identity;
      row.digits                  = ctxJoin.digits > 0 ? ctxJoin.digits : 5;
   }
}

//---------------------------------------------------------------------
// Row/dataset hashing - canonical, frozen field order, Ids_Sha256Hex
// (same primitive every other hash in this project uses).
//
// row_hash deliberately does NOT re-hash every raw field candidate_hash
// already covers (candidate_id/root_event_id/side/context_event_id/
// context_hash/setup_anchor_bar_time/expiry_after_bars/entry_hint/
// sl_hint/tp_hint/trigger_reason_mask/detector_hash/schema_version) -
// candidate_hash itself is included as a single rolled-up summary of all
// of that. What row_hash adds beyond candidate_hash is exactly what the
// EXPORT layer itself contributes and candidate_hash could never cover:
// the joined context provenance fields and the row's own candidate_state
// snapshot. This is the same "don't hash the same thing twice" principle
// B5 already used to justify candidate_hash excluding signal_time/
// expiry_time, and Commit 5 used to justify not inventing a separate
// event_hash.
//---------------------------------------------------------------------
string CandidateDatasetExport_RowHashPayload(const CandidateDatasetRow &row)
{
   return row.candidate_id + "|" +
          row.candidate_hash + "|" +
          row.instrument_id + "|" +
          row.trigger_timeframe + "|" +
          row.news_decision_hash + "|" +
          row.news_snapshot_identity + "|" +
          row.candidate_state;
}

string CandidateDatasetExport_RowHash(const CandidateDatasetRow &row)
{
   return Ids_Sha256Hex(CandidateDatasetExport_RowHashPayload(row));
}

// The dataset hash: Ids_Sha256Hex over every row_hash, joined in the
// row's FINAL (sorted) export order - so a reordering, insertion,
// deletion, or single-field change anywhere all move this one value.
string CandidateDatasetExport_DatasetHash(const CandidateDatasetRow &rows[])
{
   string payload = "";
   for(int i = 0; i < ArraySize(rows); i++)
   {
      if(i > 0) payload += "|";
      payload += rows[i].row_hash;
   }
   return Ids_Sha256Hex(payload);
}

//---------------------------------------------------------------------
// Stable sort: setup_anchor_bar_time ASC, candidate_id ASC (frozen tie-
// break, per the B6.2 kickoff spec). Simple insertion sort - dataset
// sizes here are "a few hundred setups" at most (B8's own stated gate),
// not a scale where an O(n^2) sort matters.
//---------------------------------------------------------------------
void CandidateDatasetExport_SortRows(CandidateDatasetRow &rows[])
{
   int n = ArraySize(rows);
   for(int i = 1; i < n; i++)
   {
      CandidateDatasetRow key = rows[i];
      int j = i - 1;
      while(j >= 0 &&
            (rows[j].setup_anchor_bar_time > key.setup_anchor_bar_time ||
             (rows[j].setup_anchor_bar_time == key.setup_anchor_bar_time && rows[j].candidate_id > key.candidate_id)))
      {
         rows[j + 1] = rows[j];
         j--;
      }
      rows[j + 1] = key;
   }
}

// Local string[] -> JSON array helper - deliberately NOT reusing
// Strategies/MLQuantAI_CRT_V1_EventEmission.mqh's CRT_StringArrayToJson,
// which would pull an Infrastructure/ file into depending on a
// Strategies/ one for event-emission logic it doesn't otherwise need
// (this file already has one flagged Infrastructure->Strategies
// dependency via CandidateProjection.mqh's CRT_V1_Contract.mqh include
// for the reason-bit vocabulary - not worth adding a second, heavier one
// just for an 8-line helper).
string CandidateDatasetExport_StringArrayToJson(const string &arr[])
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

//---------------------------------------------------------------------
// JSONL serialization - one row per line, frozen column order, no
// surrounding array brackets (matches the Event Store's own JSONL
// convention). Canonical timestamp formatting (TIME_DATE|TIME_SECONDS,
// same as every other event field in this project) and price precision
// from the row's own joined digits.
//---------------------------------------------------------------------
string CandidateDatasetExport_RowToJson(const CandidateDatasetRow &row)
{
   string s = "{";
   s += "\"candidate_id\":\""      + row.candidate_id + "\",";
   s += "\"root_event_id\":\""     + row.root_event_id + "\",";
   s += "\"candidate_hash\":\""    + row.candidate_hash + "\",";
   s += "\"detector_hash\":\""     + row.detector_hash + "\",";
   s += "\"context_event_id\":\""  + row.context_event_id + "\",";
   s += "\"context_hash\":\""      + row.context_hash + "\",";
   s += "\"strategy_id\":"         + IntegerToString(row.strategy_id) + ",";
   s += "\"strategy_name\":\""     + row.strategy_name + "\",";
   s += "\"strategy_version\":"    + (row.strategy_version == "" ? "null" : "\"" + row.strategy_version + "\"") + ",";
   s += "\"instrument_id\":\""     + row.instrument_id + "\",";
   s += "\"trigger_timeframe\":\"" + row.trigger_timeframe + "\",";
   s += "\"side\":\""              + (row.side == ORDER_TYPE_BUY ? "BUY" : "SELL") + "\",";
   s += "\"setup_anchor_bar_time\":\"" + TimeToString(row.setup_anchor_bar_time, TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"expiry_time\":\""       + TimeToString(row.expiry_time, TIME_DATE|TIME_SECONDS) + "\",";
   s += "\"swept_level\":"              + (row.context_joined ? DoubleToString(row.swept_level, row.digits) : "null") + ",";
   s += "\"mss_confirmation_price\":"   + (row.context_joined ? DoubleToString(row.mss_confirmation_price, row.digits) : "null") + ",";
   s += "\"resolved_zone_kind\":"       + (row.resolved_zone_kind == "" ? "null" : "\"" + row.resolved_zone_kind + "\"") + ",";
   s += "\"resolved_zone_low\":"        + (row.resolved_zone_kind == "" ? "null" : DoubleToString(row.resolved_zone_low, row.digits)) + ",";
   s += "\"resolved_zone_high\":"       + (row.resolved_zone_kind == "" ? "null" : DoubleToString(row.resolved_zone_high, row.digits)) + ",";
   s += "\"entry_hint\":" + DoubleToString(row.entry_hint, row.digits) + ",";
   s += "\"sl_hint\":"    + DoubleToString(row.sl_hint, row.digits) + ",";
   s += "\"tp_hint\":"    + DoubleToString(row.tp_hint, row.digits) + ",";
   s += "\"trigger_reason_mask\":" + IntegerToString((long)row.trigger_reason_mask) + ",";
   s += "\"trigger_reasons\":" + CandidateDatasetExport_StringArrayToJson(row.trigger_reasons) + ",";
   s += "\"has_liquidity_sweep\":" + (row.has_liquidity_sweep ? "true" : "false") + ",";
   s += "\"has_mss\":"             + (row.has_mss ? "true" : "false") + ",";
   s += "\"has_fvg\":"             + (row.has_fvg ? "true" : "false") + ",";
   s += "\"has_order_block\":"     + (row.has_order_block ? "true" : "false") + ",";
   s += "\"in_killzone\":"         + (row.in_killzone ? "true" : "false") + ",";
   s += "\"news_risk\":"           + (row.news_risk ? "true" : "false") + ",";
   s += "\"news_decision_hash\":\""     + row.news_decision_hash + "\",";
   s += "\"news_snapshot_identity\":\"" + row.news_snapshot_identity + "\",";
   s += "\"candidate_state\":\""   + row.candidate_state + "\",";
   s += "\"context_joined\":"      + (row.context_joined ? "true" : "false") + ",";
   s += "\"row_hash\":\""          + row.row_hash + "\"";
   s += "}";
   return s;
}

//---------------------------------------------------------------------
// Manifest - schema/provenance/counts, kept SEPARATE from the row data
// itself. export_time is metadata only, deliberately excluded from
// dataset_hash (two exports of the identical store at different wall-
// clock times must produce the identical dataset_hash - only row CONTENT
// determines it, matching every other "runtime-only, excluded from the
// identity hash" precedent in this project - context_hash excludes
// account, candidate_hash excludes account/spread/wall-clock).
//---------------------------------------------------------------------
#define MLQUANTAI_DATASET_SCHEMA_V1 "DATASET_V1"

struct CandidateDatasetManifest
{
   string   dataset_schema_version;
   string   source_event_store_file;
   int      source_line_count;
   int      row_count;
   int      rejected_count;    // CandidateProjectionReport.lines_failed from the underlying rebuild
   string   dataset_hash;
   datetime export_time;       // metadata only - NOT part of dataset_hash
};

void CandidateDatasetManifest_Init(CandidateDatasetManifest &m)
{
   m.dataset_schema_version = MLQUANTAI_DATASET_SCHEMA_V1;
   m.source_event_store_file = "";
   m.source_line_count = 0;
   m.row_count = 0;
   m.rejected_count = 0;
   m.dataset_hash = "";
   m.export_time = 0;
}

string CandidateDatasetManifest_ToJson(const CandidateDatasetManifest &m)
{
   string s = "{";
   s += "\"dataset_schema_version\":\"" + m.dataset_schema_version + "\",";
   s += "\"source_event_store_file\":\"" + m.source_event_store_file + "\",";
   s += "\"source_line_count\":" + IntegerToString(m.source_line_count) + ",";
   s += "\"row_count\":" + IntegerToString(m.row_count) + ",";
   s += "\"rejected_count\":" + IntegerToString(m.rejected_count) + ",";
   s += "\"dataset_hash\":\"" + m.dataset_hash + "\",";
   s += "\"export_time\":\"" + TimeToString(m.export_time, TIME_DATE|TIME_SECONDS) + "\"";
   s += "}";
   return s;
}

//---------------------------------------------------------------------
// The B6.2 entry point: rebuild the registry (validator-gated, exactly
// like B6.1's own RebuildFromFile), join every candidate against its
// context, sort, hash each row, hash the dataset, build the manifest.
// Returns false (rows[]/manifest left at empty/Init() defaults) if the
// underlying registry rebuild itself failed (corrupt/out-of-order
// store) - a broken store must never produce a silently-partial export,
// same discipline B6.1's RebuildFromFile already established.
//---------------------------------------------------------------------
bool CandidateDatasetExport_BuildDataset(string fileName, CandidateDatasetRow &rows[], CandidateDatasetManifest &manifest)
{
   ArrayResize(rows, 0);
   CandidateDatasetManifest_Init(manifest);
   manifest.source_event_store_file = fileName;

   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);
   manifest.source_line_count = n;

   CandidateProjectionReport report = CandidateProjection_RebuildFromFile(fileName);
   if(!report.ok)
      return false;

   manifest.rejected_count = report.lines_failed;

   DatasetContextJoinEntry contextTable[];
   CandidateDatasetExport_CollectContextJoinTable(lines, contextTable);

   int count = CandidateProjection_Count();
   ArrayResize(rows, count);
   for(int i = 0; i < count; i++)
   {
      CandidateProjectionRecord rec;
      CandidateProjection_GetAt(i, rec);
      CandidateDatasetExport_BuildRow(rec, contextTable, rows[i]);
   }

   CandidateDatasetExport_SortRows(rows);

   for(int i = 0; i < ArraySize(rows); i++)
      rows[i].row_hash = CandidateDatasetExport_RowHash(rows[i]);

   manifest.row_count = ArraySize(rows);
   manifest.dataset_hash = CandidateDatasetExport_DatasetHash(rows);
   manifest.export_time = TimeCurrent(); // metadata only - not part of dataset_hash, see the struct's own comment

   return true;
}

// Serializes rows[] as JSONL text (one row per line, "\n"-joined, no
// trailing newline) - callers that want a physical file write it
// themselves via FileWriteString, same "this function only builds
// strings, callers own I/O" split every other exporter in this project
// follows.
string CandidateDatasetExport_RowsToJsonLines(const CandidateDatasetRow &rows[])
{
   string s = "";
   for(int i = 0; i < ArraySize(rows); i++)
   {
      if(i > 0) s += "\n";
      s += CandidateDatasetExport_RowToJson(rows[i]);
   }
   return s;
}

#endif // __MLQUANTAI_CANDIDATEDATASETEXPORT_MQH__
