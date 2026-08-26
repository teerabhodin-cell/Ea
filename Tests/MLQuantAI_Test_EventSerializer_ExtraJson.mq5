//+------------------------------------------------------------------+
//| MLQuantAI_Test_EventSerializer_ExtraJson.mq5                       |
//| Dedicated regression suite for EventSerializer_ParseLifecycle()'s  |
//| extra_json extraction (added this C3.7 round to close a real,      |
//| previously-latent gap: the parser never populated out.extra_json   |
//| at all before this fix - see CHANGELOG.md's "Amendment" entry).    |
//|                                                                    |
//| Scope: this file tests ONLY EventSerializer_ParseLifecycle()'s     |
//| extra_json behavior directly, via hand-built raw JSONL lines and   |
//| the real EventSerializer_ToJson() round trip. It does not touch    |
//| the event store, does not open a file, and performs no durable     |
//| write of its own except where explicitly noted. Fixture lines are  |
//| built to exactly mirror EventSerializer_ToJson()'s real field       |
//| order (schema_version/log_event_id/session_id/seq/ts/category/     |
//| type/candidate_id/root_event_id/correlation_id/strategy_id/        |
//| strategy/from_state/to_state/reason[,extra_json]/}), so every test |
//| exercises the parser against a realistic line shape, not a          |
//| synthetic one the parser would never actually see.                  |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_LifecycleAuthorityProcessor.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Builds a realistic LIFECYCLE line matching EventSerializer_ToJson()'s
// exact field order/shape. reasonRaw is embedded VERBATIM between the
// quotes of "reason" - callers control escaping themselves so tests can
// construct both well-formed and deliberately escaped/malformed values.
// extraFragment, if non-empty, is spliced in exactly like the real
// EventSerializer_ToJson() does: a leading comma, then the fragment
// verbatim, before the closing brace.
//---------------------------------------------------------------------
string BuildFullLine(string candidateId, string fromState, string toState, string reasonRaw, string extraFragment)
{
   string s = "{";
   s += "\"schema_version\":\"EVENTS_V1\",";
   s += "\"log_event_id\":\"SESS_SERTEST#1\",";
   s += "\"session_id\":\"SESS_SERTEST\",";
   s += "\"seq\":1,";
   s += "\"ts\":\"2026.01.01 00:00:00\",";
   s += "\"category\":\"LIFECYCLE\",";
   s += "\"type\":\"CANDIDATE_CREATED\",";
   s += "\"candidate_id\":\"" + candidateId + "\",";
   s += "\"root_event_id\":\"EVT_ROOT\",";
   s += "\"correlation_id\":\"\",";
   s += "\"strategy_id\":0,";
   s += "\"strategy\":\"CRT\",";
   s += "\"from_state\":\"" + fromState + "\",";
   s += "\"to_state\":\"" + toState + "\",";
   s += "\"reason\":\"" + reasonRaw + "\"";
   if(extraFragment != "")
      s += "," + extraFragment;
   s += "}";
   return s;
}

//---------------------------------------------------------------------
// 1. Legacy no-extra fragment: a line ending immediately after "reason"
//    (the shape every Phase A line and every extraJson="" caller has
//    always produced) parses with extra_json == "" - identical to the
//    pre-fix behavior, and every fixed field still parses correctly.
//---------------------------------------------------------------------
void Test_LegacyLine_NoExtraFragment()
{
   Print("--- Test_LegacyLine_NoExtraFragment ---");
   string line = BuildFullLine("CND_LEGACY01", "CREATED", "CREATED", "NONE", "");

   LifecycleEvent e;
   bool ok = EventSerializer_ParseLifecycle(line, e);

   Check(ok, "legacy line parses successfully");
   Check(e.candidate_id == "CND_LEGACY01", "candidate_id parses correctly");
   Check(e.from_state == CANDIDATE_CREATED && e.to_state == CANDIDATE_CREATED, "from/to state parse correctly (genesis shape)");
   Check(e.reason == REASON_NONE, "reason parses correctly");
   Check(e.base.sequence_number == 1, "sequence_number parses correctly");
   Check(e.base.log_event_id == "SESS_SERTEST#1", "log_event_id parses correctly");
   Check(e.extra_json == "", "extra_json is empty - identical to pre-fix behavior for a line with no spliced fragment");
}

//---------------------------------------------------------------------
// 2. Simple extra fragment: a flat trailing fragment extracts to the
//    EXACT expected substring - no leading comma, no trailing brace.
//---------------------------------------------------------------------
void Test_SimpleExtraFragment_ExactMatch()
{
   Print("--- Test_SimpleExtraFragment_ExactMatch ---");
   string fragment = "\"foo\":\"bar\",\"baz\":123";
   string line = BuildFullLine("CND_SIMPLE01", "CREATED", "SUBMITTED", "NONE", fragment);

   LifecycleEvent e;
   bool ok = EventSerializer_ParseLifecycle(line, e);

   Check(ok, "line with a simple flat fragment parses successfully");
   Check(e.candidate_id == "CND_SIMPLE01", "sanity: candidate_id still correct alongside the fragment");
   Check(e.extra_json == fragment, "extra_json equals the exact expected fragment - no leading comma, no trailing brace");
   Check(StringFind(e.extra_json, "{") < 0 && StringGetCharacter(e.extra_json, 0) != ',',
         "extraction carries no leading comma and no stray outer-brace artifact");
}

//---------------------------------------------------------------------
// 3. Escaped reason text: production's ReasonCodeToString() never emits
//    escapable characters today (enum names only), but the closing-quote
//    scan itself must still be correct independent of what production
//    currently emits - the same "prove the scanner, not just today's
//    callers" precedent this project already established for
//    EventSerializer_GetStr's own escape-aware walk. This fixture is
//    deliberately synthetic (constructed, not producible by any current
//    real emitter) to isolate exactly that.
//---------------------------------------------------------------------
void Test_EscapedReasonText_ScanFindsRealClosingQuote()
{
   Print("--- Test_EscapedReasonText_ScanFindsRealClosingQuote ---");
   // MQL5 source \\\" -> literal \" (backslash+quote) in the resulting
   // string value; \\\\ -> literal \\ (backslash+backslash). The
   // resulting reasonRaw, once embedded between quotes, contains a real
   // escaped quote and a real escaped backslash inside the reason value.
   string reasonRaw = "SOME_REASON_WITH_\\\"QUOTE\\\"_AND_\\\\BACKSLASH";
   string fragment = "\"marker\":\"AFTER_ESCAPED_REASON\"";
   string line = BuildFullLine("CND_ESCREASON01", "CREATED", "SUBMITTED", reasonRaw, fragment);

   LifecycleEvent e;
   bool ok = EventSerializer_ParseLifecycle(line, e);

   Check(ok, "line with an escaped-quote/backslash reason value parses successfully (no crash, no early bail)");
   Check(e.candidate_id == "CND_ESCREASON01", "sanity: candidate_id still correct");
   Check(e.extra_json == fragment,
         "extra fragment is still extracted exactly - the scan correctly walked past the escaped quote/backslash "
         "inside reason's own value instead of mistaking either for the value's real closing quote");
}

//---------------------------------------------------------------------
// 4. Escaped content inside the extra fragment itself: nested-looking
//    JSON (quotes, backslash, braces, brackets, commas, array content)
//    is preserved byte-for-byte, since extraction is a pure substring
//    capture between the real end of "reason" and the line's own final
//    '}' - it never needs to understand the fragment's internal
//    structure to extract it correctly.
//---------------------------------------------------------------------
void Test_EscapedContentInsideExtraFragment_ByteEquivalent()
{
   Print("--- Test_EscapedContentInsideExtraFragment_ByteEquivalent ---");
   string fragment = "\"note\":\"He said \\\"hi\\\"\",\"arr\":[1,2,3],\"nested\":{\"a\":1,\"b\":[true,false]},\"tail\":\"end\"";
   string line = BuildFullLine("CND_NESTED01", "SUBMITTED", "EXECUTED", "EXECUTED_OK", fragment);

   LifecycleEvent e;
   bool ok = EventSerializer_ParseLifecycle(line, e);

   Check(ok, "line with nested quotes/braces/brackets/arrays inside its fragment parses successfully");
   Check(e.from_state == CANDIDATE_SUBMITTED && e.to_state == CANDIDATE_EXECUTED, "sanity: from/to state still correct");
   Check(e.reason == REASON_EXECUTED_OK, "sanity: reason still correct");
   Check(e.extra_json == fragment,
         "extra_json preserves the fragment byte-for-byte, including its own internal quotes/braces/brackets/commas - "
         "the outer scan for the line's final '}' always lands on the TRUE outer brace (the absolute last character "
         "of the line, by construction of EventSerializer_ToJson), never a brace belonging to nested content");
}

//---------------------------------------------------------------------
// 5. Round-trip: a real LifecycleEvent, serialized via the real
//    EventSerializer_ToJson() and parsed back via
//    EventSerializer_ParseLifecycle(), reproduces every fixed field AND
//    the exact original extra_json fragment.
//---------------------------------------------------------------------
void Test_RoundTrip_ToJsonThenParseLifecycle()
{
   Print("--- Test_RoundTrip_ToJsonThenParseLifecycle ---");

   LifecycleEvent original;
   LifecycleEvent_Init(original);
   original.base.log_event_id       = "SESS_RT#7";
   original.base.runtime_session_id = "SESS_RT";
   original.base.sequence_number    = 7;
   original.base.ts                 = D'2026.01.01 00:00:00';
   original.base.category           = EVENT_CAT_LIFECYCLE;
   original.base.event_type         = "CANDIDATE_EXECUTED";
   original.candidate_id             = "CND_ROUNDTRIP01";
   original.root_event_id            = "EVT_ROOT_RT";
   original.correlation_id           = "CORR_RT01";
   original.strategy_id              = 1;
   original.from_state               = CANDIDATE_SUBMITTED;
   original.to_state                 = CANDIDATE_EXECUTED;
   original.reason                   = REASON_EXECUTED_OK;
   original.extra_json               = "\"round_trip_marker\":\"yes\",\"nums\":[1,2,3],\"flag\":true";

   string json = EventSerializer_ToJson(original);

   LifecycleEvent parsed;
   bool ok = EventSerializer_ParseLifecycle(json, parsed);

   Check(ok, "the real ToJson() output parses back successfully");
   Check(parsed.base.log_event_id == original.base.log_event_id, "log_event_id round-trips");
   Check(parsed.base.sequence_number == original.base.sequence_number, "sequence_number round-trips");
   Check(parsed.candidate_id == original.candidate_id, "candidate_id round-trips");
   Check(parsed.root_event_id == original.root_event_id, "root_event_id round-trips");
   Check(parsed.correlation_id == original.correlation_id, "correlation_id round-trips");
   Check(parsed.strategy_id == original.strategy_id, "strategy_id round-trips");
   Check(parsed.from_state == original.from_state && parsed.to_state == original.to_state, "from/to state round-trip");
   Check(parsed.reason == original.reason, "reason round-trips");
   Check(parsed.extra_json == original.extra_json, "extra_json round-trips EXACTLY - the real ToJson->ParseLifecycle cycle is lossless");
}

//---------------------------------------------------------------------
// 6. Malformed / fail-closed. This sealed parser's own contract (see
//    its own doc comment) only rejects a line outright (returns false)
//    if "seq" or "candidate_id" is missing entirely - it does not
//    globally validate every field's own well-formedness. Per explicit
//    instruction, these three cases therefore test the specific
//    invariant that matters: extra_json must remain empty (never a
//    truncated/partial fragment mistaken for valid data), regardless of
//    what the overall parse call returns.
//---------------------------------------------------------------------
void Test_MalformedReason_MissingClosingQuote_ExtraJsonStaysEmpty()
{
   Print("--- Test_MalformedReason_MissingClosingQuote_ExtraJsonStaysEmpty ---");
   // No closing quote anywhere after "reason":" - the value (and the
   // line) simply ends mid-value.
   string line = "{\"schema_version\":\"EVENTS_V1\",\"log_event_id\":\"SESS_SERTEST#1\",\"session_id\":\"SESS_SERTEST\","
                 + "\"seq\":1,\"ts\":\"2026.01.01 00:00:00\",\"category\":\"LIFECYCLE\",\"type\":\"CANDIDATE_CREATED\","
                 + "\"candidate_id\":\"CND_MALFORMED01\",\"root_event_id\":\"EVT_ROOT\",\"correlation_id\":\"\","
                 + "\"strategy_id\":0,\"strategy\":\"CRT\",\"from_state\":\"CREATED\",\"to_state\":\"CREATED\","
                 + "\"reason\":\"NONE_UNTERMINATED_NO_CLOSING_QUOTE_OR_BRACE_ANYWHERE_AFTER_THIS_POINT";

   LifecycleEvent e;
   EventSerializer_ParseLifecycle(line, e);
   Check(e.extra_json == "", "missing closing quote on reason's value: extra_json stays empty, never a partial fragment");
}

void Test_MalformedLine_NoClosingBrace_ExtraJsonStaysEmpty()
{
   Print("--- Test_MalformedLine_MissingFinalClosingBrace_ExtraJsonStaysEmpty ---");
   // reason closes correctly and a fragment follows, but the line has NO
   // closing brace anywhere - it is simply truncated.
   string line = BuildFullLine("CND_MALFORMED02", "CREATED", "CREATED", "NONE", "\"foo\":\"bar\"");
   // Strip the trailing '}' that BuildFullLine appended, to simulate a
   // genuinely truncated durable line (e.g. a torn write).
   line = StringSubstr(line, 0, StringLen(line) - 1);

   LifecycleEvent e;
   EventSerializer_ParseLifecycle(line, e);
   Check(e.extra_json == "", "missing final closing brace: extra_json stays empty, never a partial fragment");
}

void Test_MalformedReason_DanglingEscape_ExtraJsonStaysEmpty()
{
   Print("--- Test_MalformedReason_DanglingEscape_ExtraJsonStaysEmpty ---");
   // reason's value ends in a single trailing backslash with nothing
   // after it (not even a closing quote) - the line simply ends there.
   string line = "{\"schema_version\":\"EVENTS_V1\",\"log_event_id\":\"SESS_SERTEST#1\",\"session_id\":\"SESS_SERTEST\","
                 + "\"seq\":1,\"ts\":\"2026.01.01 00:00:00\",\"category\":\"LIFECYCLE\",\"type\":\"CANDIDATE_CREATED\","
                 + "\"candidate_id\":\"CND_MALFORMED03\",\"root_event_id\":\"EVT_ROOT\",\"correlation_id\":\"\","
                 + "\"strategy_id\":0,\"strategy\":\"CRT\",\"from_state\":\"CREATED\",\"to_state\":\"CREATED\","
                 + "\"reason\":\"NONE\\";

   LifecycleEvent e;
   EventSerializer_ParseLifecycle(line, e);
   Check(e.extra_json == "", "dangling escape at end of line: scan does not read past the end of the string, extra_json stays empty");
}

//---------------------------------------------------------------------
// 7. C3.7 provenance compatibility: a real C3.7-shaped extra_json
//    fragment (mirroring C37_BuildExtraJson's own frozen field set)
//    parses correctly, and C3.7's own C37_FindMatchingExecutedLine()
//    helper can identify the same action_id unambiguously from it -
//    proving this fix actually closes the loop C3.7 depends on, using
//    the same isolated-helper technique already authorized for the
//    zero/multiple-match tests in the C3.7 suite itself.
//---------------------------------------------------------------------
void Test_C37ProvenanceFragment_MatchingHelperIdentifiesActionId()
{
   Print("--- Test_C37ProvenanceFragment_MatchingHelperIdentifiesActionId ---");

   string candidateId = "CND_C37FIXTURE01";
   string actionId     = "C36|EXECUTED|CND_C37FIXTURE01|EXECREQ_FIXTURE01|5099|MATCHED_VOLUME_REACHED|[6099]|v1";
   string execReqId    = "EXECREQ_FIXTURE01";

   string fragment = "";
   fragment += "\"c3_7_schema_version\":\"C37_V1\",";
   fragment += "\"c3_6_action_id\":\"" + actionId + "\",";
   fragment += "\"execution_request_id\":\"" + execReqId + "\",";
   fragment += "\"order_ticket\":5099,";
   fragment += "\"deal_tickets_sorted\":[6099],";
   fragment += "\"terminal_match_status\":\"MATCHED_VOLUME_REACHED\",";
   fragment += "\"running_filled_volume\":0.01000000,";
   fragment += "\"intended_lot_size\":0.01000000,";
   fragment += "\"execution_request_source_log_event_id\":\"SESS_FIXTURE#3\",";
   fragment += "\"execution_request_source_sequence_number\":3,";
   fragment += "\"deal_source_log_event_ids_sorted\":[\"SESS_FIXTURE#5\"],";
   fragment += "\"deal_source_sequence_numbers_sorted\":[5]";

   string line = BuildFullLine(candidateId, "SUBMITTED", "EXECUTED", "EXECUTED_OK", fragment);

   LifecycleEvent parsed;
   bool ok = EventSerializer_ParseLifecycle(line, parsed);
   Check(ok, "the C3.7-shaped fixture line parses successfully");
   Check(parsed.extra_json == fragment, "sanity: the parsed extra_json equals the exact C3.7-shaped fragment");

   string lines[1];
   lines[0] = line;
   LifecycleEvent recovered;
   int matchCount = C37_FindMatchingExecutedLine(lines, 1, candidateId, actionId, recovered);

   Check(matchCount == 1, "C37_FindMatchingExecutedLine identifies exactly one match against this fixture");
   Check(recovered.candidate_id == candidateId, "the matched event's candidate_id is correct");
   Check(recovered.from_state == CANDIDATE_SUBMITTED && recovered.to_state == CANDIDATE_EXECUTED, "the matched event's from/to state is correct");
   Check(recovered.reason == REASON_EXECUTED_OK, "the matched event's reason is correct");
   Check(StringFind(recovered.extra_json, "\"c3_6_action_id\":\"" + actionId + "\"") >= 0,
         "the matched event's own extra_json carries the same action_id C37_FindMatchingExecutedLine searched for - "
         "proving the parsed field, not just the raw line, is what the helper actually matched against");
}

//---------------------------------------------------------------------
void OnStart()
{
   Print("=== MLQuantAI Test: EventSerializer extra_json extraction ===");

   Test_LegacyLine_NoExtraFragment();
   Test_SimpleExtraFragment_ExactMatch();
   Test_EscapedReasonText_ScanFindsRealClosingQuote();
   Test_EscapedContentInsideExtraFragment_ByteEquivalent();
   Test_RoundTrip_ToJsonThenParseLifecycle();
   Test_MalformedReason_MissingClosingQuote_ExtraJsonStaysEmpty();
   Test_MalformedLine_NoClosingBrace_ExtraJsonStaysEmpty();
   Test_MalformedReason_DanglingEscape_ExtraJsonStaysEmpty();
   Test_C37ProvenanceFragment_MatchingHelperIdentifiesActionId();

   Print(StringFormat("=== Result: %d/%d checks passed ===", g_TestsPassed, g_TestsRun));
   if(g_TestsRun > 0 && g_TestsPassed == g_TestsRun)
      Print("ALL PASS.");
   else
      Print("FAILURES PRESENT - review the [FAIL] lines above.");
}
