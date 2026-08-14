//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh|
//| Phase B B6.1 (hardened): a read-only candidate registry projected  |
//| from persisted CANDIDATE_CREATED lines - the "candidate dataset"   |
//| read model B6.2's export and B6.3's validator both build on.       |
//| Sibling to MLQuantAI_StateProjector.mqh (which folds LifecycleEvents|
//| into lifecycle STATE), except this one folds them into full        |
//| candidate CONTENT (every field Commit 5's extra_json persisted),   |
//| keyed by candidate_id.                                             |
//|                                                                    |
//| Strictly additive and read-only: no B5 Strategies/ file (CRT       |
//| detector, ctx->candidate mapping, or event emission) is touched or |
//| depended on here beyond reading the frozen reason-bit vocabulary    |
//| for validation (see the note above the reason-mask check below).   |
//| Only ever reads persisted lines back, exactly what B6's own "no    |
//| CRT rule changes, everything read-only from the event store"       |
//| discipline requires. No live market call, no CopyRates/iTime/      |
//| AccountInfo*/TimeCurrent(), no event append.                       |
//|                                                                    |
//| HARDENING PASS (post-104/104 QA review): the first version of this |
//| file only checked structural well-formedness (parsable, genesis    |
//| shape, non-empty candidate_id) before registering a record, and     |
//| treated ANY repeat candidate_id as an idempotent duplicate - which  |
//| would silently hide a deterministic-ID collision (two DIFFERENT     |
//| candidates somehow sharing one candidate_id) behind a "nothing to   |
//| see here" no-op. This pass adds: schema-version gating, required-   |
//| field presence, side/time/numerical/SL-TP-ordering integrity,       |
//| reason-mask/reason-labels consistency, resource limits, payload-    |
//| aware collision-vs-duplicate detection, referential integrity       |
//| against MARKET_CONTEXT_READY events, and gating the whole rebuild   |
//| on EventStoreValidator first (ordering/atomicity - a single         |
//| corrupt/out-of-order line blocks the ENTIRE rebuild, registry left  |
//| completely untouched, rather than silently admitting a partial      |
//| dataset). See Docs/PhaseB_B6_1_CandidateProjection.md.              |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CANDIDATEPROJECTION_MQH__
#define __MLQUANTAI_CANDIDATEPROJECTION_MQH__

#include "MLQuantAI_EventStore.mqh"
#include "MLQuantAI_EventStoreValidator.mqh"
// CRT_V1's frozen reason-bit vocabulary, needed ONLY to verify a
// persisted trigger_reason_mask/trigger_reasons[] pair is internally
// consistent (contract section 2's XOR invariant, and that the label
// array is exactly what CRT_ReasonLabelsFromMask would produce for that
// mask). This is a deliberate, flagged exception to "Infrastructure
// doesn't depend on a specific Strategy" - acceptable for now because
// CRT_V1 is the only strategy producing candidates. When a second
// strategy exists, this check needs to become strategy_id-dispatched
// (a small table of {strategy_id -> reason-vocabulary validator}) rather
// than hard-coding CRT_V1's bits here.
#include "../../Strategies/MLQuantAI_CRT_V1_Contract.mqh"

// Defensive bound against a pathological/corrupt line - not a frozen
// protocol limit, just a sanity ceiling no legitimate CANDIDATE_CREATED
// line should ever approach.
#define MLQUANTAI_CANDPROJ_MAX_LINE_LENGTH 65536
#define MLQUANTAI_CANDPROJ_MAX_REASON_COUNT 8   // only 8 canonical reason bits exist (contract section 2)
#define MLQUANTAI_CANDPROJ_MAX_REASON_LABEL_LENGTH 64

// Everything a CANDIDATE_CREATED line actually carries today: the native
// LifecycleEvent fields (candidate_id/root_event_id/correlation_id/
// strategy_id) plus every field Commit 5's CRT_CandidateCreatedExtraJson
// adds via extra_json. Deliberately does NOT include fields no persisted
// CANDIDATE_CREATED event carries yet - swept_level/mss_confirmation_
// price/resolved_zone_kind/resolved_zone_low/resolved_zone_high (only
// ever live on CRTDetectionResult, never copied onto TradeCandidate or
// the event) and instrument_id/trigger_timeframe/news_decision_hash/
// news_snapshot_identity (only live on MarketContext, joinable via
// context_event_id but not duplicated onto the candidate event). B6.2's
// canonical dataset column list wants all of these - inventing them here
// would mean either fabricating data this projection was never given or
// silently reaching into B5's sealed emission code, neither acceptable
// for a "read-only from what's already persisted" B6.1 gate. Flagged for
// the B6.2 kickoff decision: extend Commit 5's extra_json additively, or
// have the B6.2 export join against the corresponding MARKET_CONTEXT_
// READY event via context_event_id (which already exists specifically
// "so every candidate can be traced back to the exact snapshot it came
// from" - MarketContext.mqh's own stated B1 design intent).
struct CandidateProjectionRecord
{
   string   candidate_id;
   string   root_event_id;
   string   correlation_id;
   int      strategy_id;
   ENUM_CANDIDATE_STATE state; // always CANDIDATE_CREATED in this B6-only projection - B6 never applies later transitions

   string   context_event_id;
   string   context_hash;
   string   candidate_hash;
   string   detector_hash;
   string   candidate_schema_version;

   ENUM_ORDER_TYPE side;
   datetime setup_anchor_bar_time;
   int      expiry_after_bars;
   datetime expiry_time;

   double   entry_hint;
   double   sl_hint;
   double   tp_hint;

   ulong    trigger_reason_mask;
   string   trigger_reasons[];

   long     source_sequence_number; // audit trail: which event this record came from
   string   source_log_event_id;
};

void CandidateProjectionRecord_Init(CandidateProjectionRecord &r)
{
   r.candidate_id = "";
   r.root_event_id = "";
   r.correlation_id = "";
   r.strategy_id = -1;
   r.state = CANDIDATE_CREATED;

   r.context_event_id = "";
   r.context_hash = "";
   r.candidate_hash = "";
   r.detector_hash = "";
   r.candidate_schema_version = "";

   r.side = ORDER_TYPE_BUY;
   r.setup_anchor_bar_time = 0;
   r.expiry_after_bars = 0;
   r.expiry_time = 0;

   r.entry_hint = 0;
   r.sl_hint = 0;
   r.tp_hint = 0;

   r.trigger_reason_mask = 0;
   ArrayResize(r.trigger_reasons, 0);

   r.source_sequence_number = 0;
   r.source_log_event_id = "";
}

CandidateProjectionRecord g_CandProj_Records[];
int                       g_CandProj_Count = 0;

void CandidateProjection_Reset()
{
   ArrayResize(g_CandProj_Records, 0);
   g_CandProj_Count = 0;
}

int CandidateProjection_Count() { return g_CandProj_Count; }

int CandidateProjection_FindIndex(string candidateId)
{
   for(int i = 0; i < g_CandProj_Count; i++)
      if(g_CandProj_Records[i].candidate_id == candidateId)
         return i;
   return -1;
}

// The registry lookup B6.1's own spec names explicitly (CandidateLookup).
bool CandidateProjection_TryGet(string candidateId, CandidateProjectionRecord &out)
{
   int idx = CandidateProjection_FindIndex(candidateId);
   if(idx < 0) return false;
   out = g_CandProj_Records[idx];
   return true;
}

// Phase B B6.2: positional access for full-registry iteration (dataset
// export needs every record, not just a by-id lookup) - kept separate
// from reaching into g_CandProj_Records directly so callers outside this
// file never depend on the backing array's own storage layout.
bool CandidateProjection_GetAt(int index, CandidateProjectionRecord &out)
{
   if(index < 0 || index >= g_CandProj_Count) return false;
   out = g_CandProj_Records[index];
   return true;
}

//---------------------------------------------------------------------
// Pure validation helpers - each returns "" if the check passes, or a
// human-readable reason if it doesn't. Kept separate from ApplyLine's
// control flow so each rule is independently readable and testable.
//---------------------------------------------------------------------

string CandidateProjection_ValidateSchemaVersion(string schemaVersion)
{
   if(schemaVersion == "") return "empty candidate_schema_version";
   if(schemaVersion != MLQUANTAI_CANDIDATE_SCHEMA_V1)
      return "unrecognized candidate_schema_version '" + schemaVersion + "' (this build only knows " + MLQUANTAI_CANDIDATE_SCHEMA_V1 + ")";
   return "";
}

string CandidateProjection_ValidateRequiredFields(string rootEventId, string contextEventId, string contextHash,
                                                    string candidateHash, string detectorHash)
{
   if(rootEventId == "")    return "missing root_event_id";
   if(contextEventId == "") return "missing context_event_id";
   if(contextHash == "")    return "missing context_hash";
   if(candidateHash == "")  return "missing candidate_hash";
   if(detectorHash == "")   return "missing detector_hash";
   return "";
}

// Returns "" and sets outSide on success; a reason string on failure.
// Deliberately does NOT silently default an unrecognized value to SELL -
// the original version's ternary (== "BUY" ? BUY : SELL) would have
// mapped a corrupted/garbage side string straight to SELL undetected.
string CandidateProjection_ValidateSide(string sideStr, ENUM_ORDER_TYPE &outSide)
{
   if(sideStr == "BUY")  { outSide = ORDER_TYPE_BUY;  return ""; }
   if(sideStr == "SELL") { outSide = ORDER_TYPE_SELL; return ""; }
   return "invalid side '" + sideStr + "' - must be exactly BUY or SELL";
}

string CandidateProjection_ValidateTimeIntegrity(datetime setupAnchorBarTime, datetime expiryTime, int expiryAfterBars)
{
   if(setupAnchorBarTime <= 0) return "setup_anchor_bar_time is zero/negative";
   if(expiryTime <= 0)         return "expiry_time is zero/negative";
   if(expiryAfterBars <= 0)    return "expiry_after_bars is zero/negative";
   if(expiryTime <= setupAnchorBarTime)
      return "expiry_time is not after setup_anchor_bar_time";
   return "";
}

string CandidateProjection_ValidateNumericalIntegrity(double entryHint, double slHint, double tpHint, ENUM_ORDER_TYPE side)
{
   if(!MathIsValidNumber(entryHint) || !MathIsValidNumber(slHint) || !MathIsValidNumber(tpHint))
      return "entry_hint/sl_hint/tp_hint contains NaN or Inf";
   if(entryHint <= 0 || slHint <= 0 || tpHint <= 0)
      return "entry_hint/sl_hint/tp_hint contains a zero/negative price";

   if(side == ORDER_TYPE_BUY)
   {
      if(!(slHint < entryHint && entryHint < tpHint))
         return "SL/TP ordering violates BUY semantics (need sl_hint < entry_hint < tp_hint)";
   }
   else
   {
      if(!(slHint > entryHint && entryHint > tpHint))
         return "SL/TP ordering violates SELL semantics (need sl_hint > entry_hint > tp_hint)";
   }
   return "";
}

// CRT_V1-specific (see the include note at the top of this file):
// verifies the frozen bit-0/bit-1 and bit-4/bit-5 XOR invariant (contract
// section 2), that no bit outside 0-7 is set, AND that the persisted
// trigger_reasons[] array is exactly what CRT_ReasonLabelsFromMask would
// canonically produce for this mask - same content, same ascending-bit
// order, no duplicates, no unknown labels. A mismatch here means either
// the mask or the label array was corrupted/hand-edited independently of
// the other - rejected rather than silently re-canonicalized, so a
// tampered/buggy record is never quietly "fixed" into looking valid.
string CandidateProjection_ValidateReasonConsistency(ulong reasonMask, const string &reasons[])
{
   if((reasonMask & ~(ulong)0xFF) != 0)
      return "trigger_reason_mask sets a bit outside the defined 0-7 range";

   bool sweepLow  = (reasonMask & CRT_REASON_BIT_SWEEP_LOW) != 0;
   bool sweepHigh = (reasonMask & CRT_REASON_BIT_SWEEP_HIGH) != 0;
   if(sweepLow == sweepHigh) // must be exactly one - XOR
      return "trigger_reason_mask violates the sweep-low/sweep-high XOR invariant";

   bool closeBackInside = (reasonMask & CRT_REASON_BIT_CLOSE_BACK_INSIDE) != 0;
   bool mssConfirmed    = (reasonMask & CRT_REASON_BIT_MSS_CONFIRMED) != 0;
   if(!closeBackInside || !mssConfirmed)
      return "trigger_reason_mask is missing CLOSE_BACK_INSIDE and/or MSS_CONFIRMED (both required on any real candidate)";

   bool fvgFound = (reasonMask & CRT_REASON_BIT_FVG_FOUND) != 0;
   bool obFound  = (reasonMask & CRT_REASON_BIT_OB_FOUND) != 0;
   if(fvgFound == obFound) // must be exactly one - XOR
      return "trigger_reason_mask violates the FVG-found/OB-found XOR invariant";

   if(ArraySize(reasons) > MLQUANTAI_CANDPROJ_MAX_REASON_COUNT)
      return "trigger_reasons[] has more elements than the 8 canonical reason bits allow";

   string expected[];
   CRT_ReasonLabelsFromMask(reasonMask, expected);
   if(ArraySize(expected) != ArraySize(reasons))
      return "trigger_reasons[] length does not match what trigger_reason_mask implies";
   for(int i = 0; i < ArraySize(expected); i++)
   {
      if(StringLen(reasons[i]) > MLQUANTAI_CANDPROJ_MAX_REASON_LABEL_LENGTH)
         return "a trigger_reasons[] label exceeds the sanity length bound";
      if(reasons[i] != expected[i])
         return "trigger_reasons[] content/order does not match what trigger_reason_mask canonically implies";
   }
   return "";
}

//---------------------------------------------------------------------
// Applies one raw persisted line to the registry.
//---------------------------------------------------------------------
//
// Returns false (fail-closed, registry unchanged) for:
//  - a line longer than the defensive sanity bound, an unparsable line,
//    a CANDIDATE_CREATED-typed line whose from/to state isn't the
//    CREATED genesis shape, or an empty candidate_id (structural);
//  - an unrecognized/empty candidate_schema_version;
//  - any missing required identity/lineage field;
//  - an invalid side, a time-integrity violation (zero/negative/
//    inverted timestamps), a numerical-integrity violation (NaN/Inf,
//    non-positive price, or SL/TP ordering that doesn't match side);
//  - a trigger_reason_mask/trigger_reasons[] inconsistency (contract
//    section 2's XOR invariant, or a label array that doesn't match
//    what the mask canonically implies);
//  - a PAYLOAD COLLISION: a candidate_id already registered, but this
//    line's candidate_hash differs from the registered record's. This
//    is the corruption/deterministic-ID-collision case - it must never
//    be treated as a duplicate no-op, or a real data-integrity problem
//    would be silently swallowed.
//
// Returns true (a no-op, NOT an error) for:
//  - a line that isn't a CANDIDATE_CREATED event at all - this
//    projection only cares about candidate genesis, every other event
//    type/category in the store is legitimately irrelevant to it;
//  - a genuine duplicate: candidate_id already registered AND this
//    line's candidate_hash matches the registered record's exactly -
//    idempotent by design, matching StateProjector's own "duplicate
//    CREATED genesis" handling one layer up.
bool CandidateProjection_ApplyLine(string line, string &outReason)
{
   if(StringLen(line) > MLQUANTAI_CANDPROJ_MAX_LINE_LENGTH)
   {
      outReason = "line exceeds the defensive length bound - rejected before parsing";
      return false;
   }

   // Category-agnostic pre-check, BEFORE attempting a LifecycleEvent
   // parse: "type" is read via a plain string lookup that works for any
   // event category, on purpose. EventSerializer_ParseLifecycle()
   // requires a "candidate_id" key just to return true - a SystemEvent
   // line (e.g. MARKET_CONTEXT_READY, which this same store legitimately
   // carries) has no such key and would otherwise be misreported as "not
   // a parsable lifecycle event line" (a false failure that would corrupt
   // CandidateProjectionReport.lines_failed and swallow the real
   // first_error from whatever line actually needed to be reported)
   // instead of being silently skipped as irrelevant.
   //
   // Deliberately gated on the "type" KEY BEING PRESENT, not just its
   // value - a line with no "type" key at all (truncated/garbage, never
   // a real event of any kind) must still fall through to the parse
   // attempt below and fail closed there, not be waved through as
   // "just some other event type". Only a line that genuinely carries a
   // *different* recognized type is skipped as irrelevant.
   if(EventSerializer_HasKey(line, "type") &&
      EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_CANDIDATE_CREATED))
   {
      outReason = "not a CANDIDATE_CREATED event - skipped, not relevant to this projection";
      return true;
   }

   LifecycleEvent e;
   if(!EventSerializer_ParseLifecycle(line, e))
   {
      outReason = "not a parsable lifecycle event line";
      return false;
   }

   if(e.from_state != CANDIDATE_CREATED || e.to_state != CANDIDATE_CREATED)
   {
      outReason = StringFormat("CANDIDATE_CREATED type but from/to state isn't the genesis shape (from=%s to=%s) - corruption",
                                CandidateStateToString(e.from_state), CandidateStateToString(e.to_state));
      return false;
   }

   if(e.candidate_id == "")
   {
      outReason = "empty candidate_id on a CANDIDATE_CREATED line - corruption";
      return false;
   }

   string schemaVersion = EventSerializer_GetStr(line, "candidate_schema_version");
   string schemaErr = CandidateProjection_ValidateSchemaVersion(schemaVersion);
   if(schemaErr != "") { outReason = schemaErr; return false; }

   string contextEventId  = EventSerializer_GetStr(line, "context_event_id");
   string contextHash      = EventSerializer_GetStr(line, "context_hash");
   string candidateHash    = EventSerializer_GetStr(line, "candidate_hash");
   string detectorHash     = EventSerializer_GetStr(line, "detector_hash");
   string fieldsErr = CandidateProjection_ValidateRequiredFields(e.root_event_id, contextEventId, contextHash, candidateHash, detectorHash);
   if(fieldsErr != "") { outReason = fieldsErr; return false; }

   ENUM_ORDER_TYPE side;
   string sideErr = CandidateProjection_ValidateSide(EventSerializer_GetStr(line, "side"), side);
   if(sideErr != "") { outReason = sideErr; return false; }

   datetime setupAnchorBarTime = StringToTime(EventSerializer_GetStr(line, "setup_anchor_bar_time"));
   datetime expiryTime          = StringToTime(EventSerializer_GetStr(line, "expiry_time"));
   int      expiryAfterBars      = EventSerializer_GetInt(line, "expiry_after_bars");
   string timeErr = CandidateProjection_ValidateTimeIntegrity(setupAnchorBarTime, expiryTime, expiryAfterBars);
   if(timeErr != "") { outReason = timeErr; return false; }

   double entryHint = EventSerializer_GetDouble(line, "entry_hint");
   double slHint    = EventSerializer_GetDouble(line, "sl_hint");
   double tpHint    = EventSerializer_GetDouble(line, "tp_hint");
   string numErr = CandidateProjection_ValidateNumericalIntegrity(entryHint, slHint, tpHint, side);
   if(numErr != "") { outReason = numErr; return false; }

   ulong reasonMask = (ulong)EventSerializer_GetLong(line, "trigger_reason_mask");
   string reasons[];
   EventSerializer_GetStringArray(line, "trigger_reasons", reasons);
   string reasonErr = CandidateProjection_ValidateReasonConsistency(reasonMask, reasons);
   if(reasonErr != "") { outReason = reasonErr; return false; }

   int existingIdx = CandidateProjection_FindIndex(e.candidate_id);
   if(existingIdx >= 0)
   {
      if(g_CandProj_Records[existingIdx].candidate_hash == candidateHash)
      {
         outReason = "duplicate candidate_id - already registered with an identical candidate_hash, not re-applied";
         return true;
      }
      outReason = StringFormat("candidate_id collision: '%s' already registered with candidate_hash '%s', "
                                "this line carries a DIFFERENT candidate_hash '%s' - rejected as a conflict, not a duplicate",
                                e.candidate_id, g_CandProj_Records[existingIdx].candidate_hash, candidateHash);
      return false;
   }

   CandidateProjectionRecord rec;
   CandidateProjectionRecord_Init(rec);
   rec.candidate_id   = e.candidate_id;
   rec.root_event_id  = e.root_event_id;
   rec.correlation_id = e.correlation_id;
   rec.strategy_id    = e.strategy_id;
   rec.state          = CANDIDATE_CREATED;

   rec.context_event_id        = contextEventId;
   rec.context_hash             = contextHash;
   rec.candidate_hash           = candidateHash;
   rec.detector_hash            = detectorHash;
   rec.candidate_schema_version = schemaVersion;

   rec.side = side;
   rec.setup_anchor_bar_time = setupAnchorBarTime;
   rec.expiry_after_bars      = expiryAfterBars;
   rec.expiry_time             = expiryTime;

   rec.entry_hint = entryHint;
   rec.sl_hint    = slHint;
   rec.tp_hint    = tpHint;

   rec.trigger_reason_mask = reasonMask;
   ArrayResize(rec.trigger_reasons, ArraySize(reasons));
   for(int i = 0; i < ArraySize(reasons); i++)
      rec.trigger_reasons[i] = reasons[i];

   rec.source_sequence_number = e.base.sequence_number;
   rec.source_log_event_id     = e.base.log_event_id;

   ArrayResize(g_CandProj_Records, g_CandProj_Count + 1);
   g_CandProj_Records[g_CandProj_Count] = rec;
   g_CandProj_Count++;

   outReason = "applied - new candidate registered";
   return true;
}

//---------------------------------------------------------------------
// Referential integrity against MARKET_CONTEXT_READY - a separate,
// explicit step (not folded into ApplyLine itself) because it is
// inherently a cross-line concern: a single line can never prove its own
// context_event_id/context_hash pair actually corresponds to a real,
// persisted MarketContext snapshot without first scanning the rest of
// the file. ApplyLine stays usable standalone (e.g. for unit tests that
// don't need a real MARKET_CONTEXT_READY event present); only
// CandidateProjection_RebuildFromFile enforces this, since it alone has
// the full file available to build the lookup from.
//---------------------------------------------------------------------

int CandidateProjection_CollectContextHashes(const string &lines[], string &outContextIds[], string &outContextHashes[])
{
   ArrayResize(outContextIds, 0);
   ArrayResize(outContextHashes, 0);
   int count = 0;
   for(int i = 0; i < ArraySize(lines); i++)
   {
      if(EventSerializer_GetStr(lines[i], "type") != EventTypeToString(EVENT_TYPE_MARKET_CONTEXT_READY)) continue;
      string id = EventSerializer_GetStr(lines[i], "context_event_id");
      if(id == "") continue;
      ArrayResize(outContextIds, count + 1);
      ArrayResize(outContextHashes, count + 1);
      outContextIds[count]    = id;
      outContextHashes[count] = EventSerializer_GetStr(lines[i], "context_hash");
      count++;
   }
   return count;
}

// Referential-integrity-aware variant used by RebuildFromFile: rejects a
// CANDIDATE_CREATED line as an orphan (no matching MARKET_CONTEXT_READY
// event in the file) or a context_hash mismatch BEFORE ever calling
// CandidateProjection_ApplyLine, so a referentially-broken candidate
// never reaches the registry regardless of how well-formed it otherwise
// looks. Every other line type is passed straight through to ApplyLine
// unchanged.
bool CandidateProjection_ApplyLineWithContext(string line, const string &knownContextIds[], const string &knownContextHashes[], string &outReason)
{
   if(EventSerializer_GetStr(line, "type") != EventTypeToString(EVENT_TYPE_CANDIDATE_CREATED))
      return CandidateProjection_ApplyLine(line, outReason);

   string contextEventId = EventSerializer_GetStr(line, "context_event_id");
   string contextHash     = EventSerializer_GetStr(line, "context_hash");

   int idx = -1;
   for(int i = 0; i < ArraySize(knownContextIds); i++)
      if(knownContextIds[i] == contextEventId) { idx = i; break; }

   if(idx < 0)
   {
      outReason = "orphan candidate: context_event_id '" + contextEventId + "' has no matching MARKET_CONTEXT_READY event in this store - rejected";
      return false;
   }
   if(knownContextHashes[idx] != contextHash)
   {
      outReason = "context_hash mismatch: candidate's context_hash does not match its referenced MARKET_CONTEXT_READY event's context_hash - rejected";
      return false;
   }

   return CandidateProjection_ApplyLine(line, outReason);
}

//---------------------------------------------------------------------
// A from-scratch rebuild. Gated on EventStoreValidator first (ordering/
// atomicity): if the file has ANY malformed line, truncated line, or
// out-of-order/duplicate/gapped sequence number in any session, the
// ENTIRE rebuild is refused and the CURRENT registry is left completely
// untouched (not even Reset()) - a corrupt store must never produce a
// silently-partial dataset. Only once the file passes validation does
// this reset the registry and apply every line in order, referential-
// integrity-checked against every MARKET_CONTEXT_READY event also in
// the file.
//---------------------------------------------------------------------
struct CandidateProjectionReport
{
   bool   ok;
   int    lines_total;
   int    lines_applied;  // genuinely new candidates registered
   int    lines_skipped;  // non-CANDIDATE_CREATED lines, or idempotent duplicates
   int    lines_failed;   // malformed/corrupt/invalid/orphaned CANDIDATE_CREATED-typed lines
   string first_error;
};

void CandidateProjectionReport_Init(CandidateProjectionReport &r)
{
   r.ok = true;
   r.lines_total = 0;
   r.lines_applied = 0;
   r.lines_skipped = 0;
   r.lines_failed = 0;
   r.first_error = "";
}

CandidateProjectionReport CandidateProjection_RebuildFromFile(string fileName)
{
   CandidateProjectionReport report;
   CandidateProjectionReport_Init(report);

   string lines[];
   int n = EventStore_ReadAllLines(fileName, lines);
   report.lines_total = n;

   EventStoreValidationReport validation = EventStoreValidator_ValidateLines(lines);
   if(!validation.ok)
   {
      report.ok = false;
      report.first_error = "event store failed validation - rebuild refused, registry left unchanged: " + validation.first_error;
      return report;
   }

   CandidateProjection_Reset();

   string contextIds[];
   string contextHashes[];
   CandidateProjection_CollectContextHashes(lines, contextIds, contextHashes);

   for(int i = 0; i < n; i++)
   {
      int beforeCount = CandidateProjection_Count();
      string reason;
      bool applied = CandidateProjection_ApplyLineWithContext(lines[i], contextIds, contextHashes, reason);
      if(!applied)
      {
         report.ok = false;
         report.lines_failed++;
         if(report.first_error == "")
            report.first_error = StringFormat("line %d: %s", i, reason);
         continue;
      }
      if(CandidateProjection_Count() > beforeCount)
         report.lines_applied++;
      else
         report.lines_skipped++;
   }
   return report;
}

#endif // __MLQUANTAI_CANDIDATEPROJECTION_MQH__
