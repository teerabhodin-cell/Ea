//+------------------------------------------------------------------+
//| MLQuantAI - Core/MLQuantAI_Ids.mqh                                |
//| ID generators for the candidate lifecycle.                        |
//|                                                                    |
//| root_event_id / candidate_id / correlation_id are DETERMINISTIC:  |
//| the same inputs always produce the same ID, on any run, on any    |
//| machine. That's required for two things: the deduplicator finding |
//| CRT and SMC candidates that reference the same underlying sweep   |
//| (they hash the same event-defining fields to the same             |
//| root_event_id), and replay reproducing byte-identical IDs to the  |
//| original run so a replayed event stream can be compared directly |
//| against the original.                                             |
//|                                                                    |
//| runtime_session_id is NOT deterministic on purpose - it identifies|
//| one specific EA run, so it's derived from account+time+a random   |
//| salt. log_event_id = runtime_session_id + sequence_number, which  |
//| is what MLQuantAI_EventStore.mqh actually builds; this file only  |
//| generates the session id itself.                                  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_IDS_MQH__
#define __MLQUANTAI_IDS_MQH__

// SHA-256 via the platform's built-in CryptEncode - the standard way to
// hash in MQL5 without pulling in an external library. Truncated to 16 hex
// chars (64 bits) for a readable ID; collision risk at that length is
// negligible for the number of candidates one trading system will ever
// generate.
string Ids_Sha256Hex(string text)
{
   uchar data[];
   int n = StringToCharArray(text, data, 0, -1, CP_UTF8);
   if(n > 0 && data[n-1] == 0) // StringToCharArray null-terminates; strip it before hashing
      ArrayResize(data, n-1);

   uchar key[];   // hash methods ignore the key
   uchar result[];
   int hashLen = CryptEncode(CRYPT_HASH_SHA256, data, key, result);
   if(hashLen <= 0)
      return "";

   string hex = "";
   for(int i=0; i<ArraySize(result); i++)
      hex += StringFormat("%02x", result[i]);
   return hex;
}

string Ids_Deterministic(string prefix, string keyParts)
{
   string h = Ids_Sha256Hex(keyParts);
   if(h == "")
   {
      // CryptEncode failing would be unusual (platform/build issue), but an
      // ID generator must never return an empty/colliding ID silently - a
      // visibly-broken fallback is safer than a hash that quietly repeats.
      return prefix + "_HASHFAIL_" + IntegerToString((int)GetTickCount());
   }
   return prefix + "_" + StringSubstr(h, 0, 16);
}

// root_event_id: same underlying market event -> same id, always. Round
// the price to the symbol's digits before hashing so two reads of "the
// same" sweep price a few micro-fractions apart (e.g. bid vs ask, or two
// slightly different double representations) still collide correctly.
string Ids_RootEventId(string symbol, string timeframeTag, string eventType, double price, datetime barTime, int digits)
{
   string key = symbol + "|" + timeframeTag + "|" + eventType + "|" +
                DoubleToString(price, digits) + "|" + TimeToString(barTime, TIME_DATE|TIME_SECONDS);
   return Ids_Deterministic("EVT", key);
}

// context_event_id: one MarketContext snapshot, identified by symbol +
// timeframe + bar_time alone (no price rounding needed - bar_time is
// already discrete). Same bar -> same id, so a TradeCandidate can stamp
// which exact context snapshot it was built from (candidate <-> context
// lineage, per Phase B's B1/B3 requirements) and replay can confirm the
// referenced context genuinely exists in the log.
string Ids_ContextEventId(string symbol, string timeframeTag, datetime barTime)
{
   string key = symbol + "|" + timeframeTag + "|" + TimeToString(barTime, TIME_DATE|TIME_SECONDS);
   return Ids_Deterministic("CTX", key);
}

// candidate_id: one strategy's candidate against one root event. Same
// root_event_id + same strategy + same strategy_version -> same
// candidate_id, so replaying the same event stream reproduces identical
// candidate IDs.
string Ids_CandidateId(string rootEventId, string strategyTag, string strategyVersion)
{
   string key = rootEventId + "|" + strategyTag + "|" + strategyVersion;
   return Ids_Deterministic("CND", key);
}

// correlation_id: ties one submitted candidate to its order/fill/position/
// close/label chain. Deterministic from candidate_id + submit attempt
// number (attempt > 1 only if a broker-level retry resubmits the same
// candidate), so replay reproduces the same correlation_id for the same
// submission attempt.
string Ids_CorrelationId(string candidateId, int submitAttempt=1)
{
   string key = candidateId + "|attempt:" + IntegerToString(submitAttempt);
   return Ids_Deterministic("CORR", key);
}

// risk_plan_id (Phase B7): one candidate's risk plan under one sizing
// rules version. Same candidate_id + same sizing_rules_version -> same
// risk_plan_id, always - deliberately independent of risk_context_hash,
// balance/equity, or any computed sizing output, so a later replay/audit
// pass can detect "same identity, different content" as a genuine drift
// signal instead of a normal identity change. See
// Docs/PhaseB_B7_RiskPlanContract.md section 3.
string Ids_RiskPlanId(string candidateId, string sizingRulesVersion)
{
   string key = candidateId + "|" + sizingRulesVersion;
   return Ids_Deterministic("RPLAN", key);
}

// feature_snapshot_id (Phase B8.1): one candidate's AI feature vector.
// Same candidate_id -> same feature_snapshot_id, always - depends on
// nothing else, since Candidate_ToFeatureSnapshot is a pure verbatim
// copy with no methodology choice yet (unlike risk_plan_id, which
// depends on sizing_rules_version because B7 has more than one
// possible sizing methodology). See
// Docs/PhaseB_B8_1_FeatureSnapshotContract.md section 2.
string Ids_FeatureSnapshotId(string candidateId)
{
   return Ids_Deterministic("FSNAP", candidateId);
}

// dataset_row_id (Phase B8.2): one training-dataset row. Depends on
// feature_snapshot_id (not candidate_id directly - a FeatureSnapshot
// already has 1:1 identity with its candidate, this keeps the
// dependency chain explicit) plus label_schema_version and
// model_target - the same underlying setup can legitimately produce
// more than one training row if labeled under a different schema
// version or targeting a different model_target later. See
// Docs/PhaseB_B8_2_TrainingDatasetContract.md section 2.
string Ids_TrainingDatasetRowId(string featureSnapshotId, string labelSchemaVersion, string modelTarget)
{
   string key = featureSnapshotId + "|" + labelSchemaVersion + "|" + modelTarget;
   return Ids_Deterministic("TDROW", key);
}

int g_Ids_SessionCounter = 0;

// runtime_session_id: identifies one EA run. Deliberately NOT deterministic
// - two runs at the same instant on the same account should still get
// different session ids. Uniqueness is guaranteed by g_Ids_SessionCounter
// (always increments, in-process), not by the time/random components -
// an earlier version reseeded MathRand() via MathSrand((int)GetTickCount())
// on every call, but GetTickCount() only has millisecond resolution, so two
// calls microseconds apart (e.g. back-to-back in a test) could reseed with
// the identical value and produce the identical "random" number, defeating
// the whole point. GetMicrosecondCount() and MathRand() are still mixed in
// as extra salt, but the counter is what actually guarantees no collision.
string Ids_NewRuntimeSessionId()
{
   g_Ids_SessionCounter++;
   string key = IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN)) + "|" +
                TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + "|" +
                IntegerToString((int)GetMicrosecondCount()) + "|" +
                IntegerToString(g_Ids_SessionCounter) + "|" +
                IntegerToString(MathRand());
   return "SESS_" + StringSubstr(Ids_Sha256Hex(key), 0, 12);
}

#endif // __MLQUANTAI_IDS_MQH__
