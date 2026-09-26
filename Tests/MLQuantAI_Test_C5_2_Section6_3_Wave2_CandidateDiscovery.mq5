//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Section6_3_Wave2_CandidateDiscovery.mq5       |
//| C5.2 §6.3 Bounded-Automation Design Contract Rev.14 (commit        |
//| 6b7e836), Implementation Wave 2: candidate discovery + invocation   |
//| ordering (Include/MLQuantAI/Execution/                              |
//| MLQuantAI_BoundedAutomationDiscovery.mqh), on top of the CLOSED     |
//| Wave 1 machinery.                                                   |
//|                                                                    |
//| Coverage:                                                           |
//|   A  §2.3.2 frozen rule - one mailbox read; occupied (by anything,   |
//|      incl. the first candidate's own GRANT) -> whole invocation is   |
//|      a no-op, zero candidates evaluated                              |
//|   B  §2.3.1/§2.3.1a (R16) - native GetAt(0..n) order, first eligible |
//|      wins, scan stops there, no priority by state or by id, no       |
//|      hidden state between invocations                                |
//|   C  fail-closed - an UNKNOWN candidate stops the scan (never        |
//|      skipped), incl. an untrusted record ahead of an eligible one    |
//|   D  per-invocation entry point against real files - invalid store  |
//|      -> nothing, real mailbox occupancy honoured, and no side effect |
//|      on the mailbox, the EventStore or the ceremony registry         |
//|                                                                    |
//| ExecutionRequestProjection and the manual-approval registry are     |
//| populated directly with synthetic records (same technique as        |
//| MLQuantAI_Test_C5_2_Section6_2_P1PurePredicate.mq5). Every result is |
//| stored in a variable before Check() so labels reflect the current    |
//| call (MQL5 evaluates arguments right to left).                       |
//|                                                                    |
//| PRECONDITION - run only with NO MLQuantAI EA attached on any terminal|
//| sharing this machine's Common\Files folder: section D writes the     |
//| shared ceremony mailbox (test-only nonce/filename, left COMPLETE).   |
//| No OrderSend/CTrade/C2 gate anywhere in this file.                   |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_BoundedAutomationDiscovery.mqh>

#define W2_SCAN_FILE     "MLQuantAI_Test_C63_W2_Scan.jsonl"
#define W2_READY_FILE    "MLQuantAI_Test_C63_W2_Ready.jsonl"
#define W2_CORRUPT_FILE  "MLQuantAI_Test_C63_W2_Corrupt.jsonl"
#define W2_MISSING_FILE  "MLQuantAI_Test_C63_W2_DoesNotExist.jsonl"
#define W2_TEST_NONCE    626262.0

int g_TestsRun    = 0;
int g_TestsPassed = 0;

datetime g_AsOf = D'2026.06.01 12:00:00';

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void DeleteFixture(string fileName)
{
   if(FileIsExist(fileName, FILE_COMMON))
      FileDelete(fileName, FILE_COMMON);
}

bool AppendE2(string erid)
{
   string extra = "";
   extra += "\"execution_request_id\":\""   + EventSerializer_Escape(erid) + "\",";
   extra += "\"execution_request_hash\":\"" + EventSerializer_Escape("HASH_" + erid) + "\",";
   extra += "\"correlation_id\":\""         + EventSerializer_Escape("CORR_" + erid) + "\",";
   extra += "\"submit_attempt\":"           + IntegerToString(1);
   return EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED), "execution submission attempted", extra);
}

void MakeRequestRecord(string erid, ExecutionRequestProjectionRecord &out)
{
   ExecutionRequestProjectionRecord_Init(out);
   out.execution_request_id     = erid;
   out.execution_request_hash   = "HASH_" + erid;
   out.execution_policy_version = "POLICY_V1";
   out.candidate_id             = "CAND_" + erid;
   out.correlation_id           = "CORR_" + erid;
   out.lot_size                 = 0.01;
}

// R15-A fixture reconciliation (Rev.15 §2.3.1): a request is only
// admissible with an ACCEPTED dry-run record for the runtime _Symbol, so
// every synthetic request gets one. The Wave 2 assertions are unchanged.
void AddRequest(string erid)
{
   ExecutionRequestProjectionRecord rec;
   MakeRequestRecord(erid, rec);
   ExecutionRequestProjection_AppendRecord(rec);

   DryRunResultProjectionRecord dr;
   DryRunResultProjectionRecord_Init(dr);
   dr.execution_request_id   = erid;
   dr.execution_request_hash = rec.execution_request_hash;
   dr.decision               = SAFETY_GATE_ACCEPTED;
   dr.observed_symbol        = _Symbol;
   DryRunResultProjection_AppendRecord(dr);
}

void AddGrant(string erid)
{
   ExecutionRequestProjectionRecord req;
   MakeRequestRecord(erid, req);
   ManualApprovalProjectionRecord rec;
   ManualApprovalProjectionRecord_Init(rec);
   rec.execution_request_id     = req.execution_request_id;
   rec.execution_request_hash   = req.execution_request_hash;
   rec.execution_policy_version = req.execution_policy_version;
   rec.candidate_id             = req.candidate_id;
   rec.correlation_id           = req.correlation_id;
   rec.approver_identity        = MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY;
   rec.approval_timestamp       = g_AsOf - 60;
   rec.approval_expiry          = g_AsOf + 15 * 60;
   rec.approval_nonce           = "NONCE_" + erid;
   ManualApprovalProjection_AppendRecord(rec);
}

// Rebuilding the approval registry also rebuilds (resets) the
// ExecutionRequestProjection from the readiness fixture, so every case
// starts here and adds its synthetic records afterwards.
bool ResetReady()
{
   ManualApprovalProjectionReport r = ManualApproval_StartupRebuild(W2_READY_FILE);
   ExecutionRequestProjection_Reset();
   DryRunResultProjection_Reset();
   ManualApprovalProjection_Reset();
   return r.ok && ManualApprovalReadiness_IsReady();
}

void MakeSnapshot(bool present, ENUM_CEREMONY_MAILBOX_STATUS status, ENUM_CEREMONY_COMMAND_TYPE type,
                  string target, BoundedAutomationMailboxSnapshot &out)
{
   out.present = present;
   CeremonyCommand_Init(out.command);
   out.command.command_id                  = "SNAPSHOT_CMD";
   out.command.mailbox_status              = status;
   out.command.command_type                = type;
   out.command.target_execution_request_id = target;
}

string Describe(const BoundedAutomationSelection &s)
{
   return StringFormat("outcome=%s index=%d scanned=%d erid='%s' cmd=%s detail='%s'",
                       BoundedAutomationDiscoveryOutcome_ToString(s.outcome), s.selected_index, s.candidates_scanned,
                       s.selected_request.execution_request_id, CeremonyCommandType_ToString(s.command_type), s.detail);
}

bool WriteMailbox(string commandId, ENUM_CEREMONY_MAILBOX_STATUS status)
{
   CeremonyCommand c;
   CeremonyCommand_Init(c);
   c.command_id                   = commandId;
   c.command_type                 = CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL;
   c.expected_ea_binding_nonce    = W2_TEST_NONCE;
   c.expected_eventstore_filename = W2_SCAN_FILE;
   c.target_execution_request_id  = "ER_W2_MAILBOX";
   c.mailbox_status               = status;
   return CeremonyCommandMailbox_Write(c);
}

string MailboxCommandId()
{
   CeremonyCommand c;
   if(!CeremonyCommandMailbox_Read(c))
      return "";
   return c.command_id;
}

void OnStart()
{
   Print("=== MLQuantAI_Test_C5_2_Section6_3_Wave2_CandidateDiscovery.mq5 ===");
   Print("*** Selection only - nothing is issued. Precondition: no live MLQuantAI EA attached. ***");

   DeleteFixture(W2_SCAN_FILE);
   DeleteFixture(W2_READY_FILE);
   DeleteFixture(W2_CORRUPT_FILE);
   DeleteFixture(W2_MISSING_FILE);
   ArrayResize(g_CeremonyCommandRegistry, 0);

   bool setupOk = true;

   // readiness fixture: one clean system line
   if(!EventStore_Open(W2_READY_FILE)) setupOk = false;
   else { EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SYSTEM_STARTED), "wave2 readiness fixture"); EventStore_Close(); }

   // scan fixture: two durable E2 lines
   if(!EventStore_Open(W2_SCAN_FILE)) setupOk = false;
   else
   {
      EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SYSTEM_STARTED), "wave2 scan fixture");
      if(!AppendE2("ER_W2_ATTEMPTED_1")) setupOk = false;
      if(!AppendE2("ER_W2_ATTEMPTED_2")) setupOk = false;
      EventStore_Close();
   }

   string lines[];
   string err;
   bool snapOk = BoundedAutomation_ReadValidatedSnapshot(W2_SCAN_FILE, lines, err);
   int  snapLines = ArraySize(lines);
   Check(setupOk && snapOk && snapLines == 3,
         StringFormat("setup: fixtures written, validated snapshot has 3 lines (lines=%d, err='%s')", snapLines, err));

   BoundedAutomationMailboxSnapshot mbFree, mbTerminal, mbPendingOther, mbOwnGrant, mbClaimed, mbGarbled;
   MakeSnapshot(false, CEREMONY_MAILBOX_STATUS_UNKNOWN,  CEREMONY_COMMAND_TYPE_UNKNOWN, "", mbFree);
   MakeSnapshot(true,  CEREMONY_MAILBOX_STATUS_COMPLETE, CEREMONY_COMMAND_TYPE_SUBMIT_ORDER, "ER_W2_NEW_X", mbTerminal);
   MakeSnapshot(true,  CEREMONY_MAILBOX_STATUS_PENDING,  CEREMONY_COMMAND_TYPE_SUBMIT_ORDER, "ER_SOMEWHERE_ELSE", mbPendingOther);
   MakeSnapshot(true,  CEREMONY_MAILBOX_STATUS_PENDING,  CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL, "ER_W2_NEW_X", mbOwnGrant);
   MakeSnapshot(true,  CEREMONY_MAILBOX_STATUS_CLAIMED,  CEREMONY_COMMAND_TYPE_TRANSITION_ROLLOUT_STAGE, "", mbClaimed);
   MakeSnapshot(true,  CEREMONY_MAILBOX_STATUS_UNKNOWN,  CEREMONY_COMMAND_TYPE_UNKNOWN, "", mbGarbled);

   BoundedAutomationSelection s;

   //=====================================================================
   Print("--- A. one mailbox read per invocation; occupied -> whole invocation is a no-op ---");
   {
      bool ready = ResetReady();
      BoundedAutomation_SelectCandidate(lines, mbFree, g_AsOf, s);
      Check(ready && s.outcome == BOUNDED_AUTOMATION_DISCOVERY_NO_ELIGIBLE_CANDIDATE && s.candidates_scanned == 0 && s.selected_index == -1,
            "empty registry -> NO_ELIGIBLE_CANDIDATE, 0 scanned (" + Describe(s) + ")");

      AddRequest("ER_W2_NEW_X");          // eligible (NOT_YET_APPROVED) at index 0
      BoundedAutomation_SelectCandidate(lines, mbPendingOther, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_MAILBOX_OCCUPIED && s.candidates_scanned == 0 && s.selected_index == -1
            && s.command_type == CEREMONY_COMMAND_TYPE_UNKNOWN,
            "PENDING other command -> MAILBOX_OCCUPIED, 0 candidates evaluated (" + Describe(s) + ")");

      BoundedAutomation_SelectCandidate(lines, mbOwnGrant, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_MAILBOX_OCCUPIED && s.candidates_scanned == 0,
            "first candidate's OWN GRANT pending -> still a whole-invocation no-op (" + Describe(s) + ")");

      BoundedAutomation_SelectCandidate(lines, mbClaimed, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_MAILBOX_OCCUPIED && s.candidates_scanned == 0,
            "CLAIMED command of another type -> MAILBOX_OCCUPIED (" + Describe(s) + ")");

      BoundedAutomation_SelectCandidate(lines, mbGarbled, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_MAILBOX_OCCUPIED && s.candidates_scanned == 0,
            "unrecognised mailbox status counts as occupied, same as sealed IsFree (" + Describe(s) + ")");

      BoundedAutomation_SelectCandidate(lines, mbTerminal, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_SELECTED && s.selected_index == 0,
            "terminal (COMPLETE) mailbox is free -> scan runs, candidate selected (" + Describe(s) + ")");
   }

   //=====================================================================
   Print("--- B. native GetAt(0..n) order, first eligible wins, scan stops ---");
   {
      ResetReady();
      AddRequest("ER_W2_ATTEMPTED_1");    // E2 exists -> skipped
      AddRequest("ER_W2_NEW_X");          // no grant -> NOT_YET_APPROVED
      AddRequest("ER_W2_NEW_Y"); AddGrant("ER_W2_NEW_Y"); // APPROVED_NOT_SUBMITTED, but later in order
      BoundedAutomation_SelectCandidate(lines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_SELECTED && s.selected_index == 1
            && s.selected_request.execution_request_id == "ER_W2_NEW_X"
            && s.selected_state == BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED
            && s.command_type == CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL && s.candidates_scanned == 2,
            "[attempted, new_x, approved_y] -> index 1 new_x GRANT; a later APPROVED candidate gets no priority (" + Describe(s) + ")");
      Check(s.selected_request.execution_request_hash == "HASH_ER_W2_NEW_X" && s.selected_request.candidate_id == "CAND_ER_W2_NEW_X",
            "selected_request is the full record at that index");

      ResetReady();
      AddRequest("ER_W2_ATTEMPTED_1");
      AddRequest("ER_W2_ATTEMPTED_2");
      AddRequest("ER_W2_NEW_Y"); AddGrant("ER_W2_NEW_Y");
      BoundedAutomation_SelectCandidate(lines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_SELECTED && s.selected_index == 2
            && s.selected_state == BOUNDED_AUTOMATION_STATE_APPROVED_NOT_SUBMITTED
            && s.command_type == CEREMONY_COMMAND_TYPE_SUBMIT_ORDER && s.candidates_scanned == 3,
            "[attempted, attempted, approved_y] -> index 2 SUBMIT_ORDER (" + Describe(s) + ")");

      ResetReady();
      AddRequest("ER_W2_ATTEMPTED_1");
      AddRequest("ER_W2_ATTEMPTED_2");
      BoundedAutomation_SelectCandidate(lines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_NO_ELIGIBLE_CANDIDATE && s.candidates_scanned == 2 && s.selected_index == -1,
            "every candidate already attempted -> NO_ELIGIBLE_CANDIDATE after scanning all (" + Describe(s) + ")");

      ResetReady();
      AddRequest("ER_W2_ZULU");
      AddRequest("ER_W2_ALPHA");
      BoundedAutomation_SelectCandidate(lines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_SELECTED && s.selected_request.execution_request_id == "ER_W2_ZULU"
            && s.selected_index == 0 && s.candidates_scanned == 1,
            "insertion [ZULU, ALPHA] -> ZULU: native order, not id order; scan stops at the first (" + Describe(s) + ")");

      ResetReady();
      AddRequest("ER_W2_ALPHA");
      AddRequest("ER_W2_ZULU");
      BoundedAutomation_SelectCandidate(lines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_SELECTED && s.selected_request.execution_request_id == "ER_W2_ALPHA"
            && s.selected_index == 0,
            "insertion [ALPHA, ZULU] -> ALPHA: order follows insertion both ways (" + Describe(s) + ")");

      ResetReady();
      AddRequest("ER_W2_ATTEMPTED_1");
      AddRequest("ER_W2_NEW_X");
      AddRequest("ER_W2_NEW_Y");
      AddRequest("ER_W2_NEW_Z");
      BoundedAutomationSelection first, second;
      BoundedAutomation_SelectCandidate(lines, mbFree, g_AsOf, first);
      BoundedAutomation_SelectCandidate(lines, mbFree, g_AsOf, second);
      Check(first.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_SELECTED && first.selected_index == 1
            && first.candidates_scanned == first.selected_index + 1,
            "several eligible -> exactly one selected, nothing evaluated past it (" + Describe(first) + ")");
      Check(second.outcome == first.outcome && second.selected_index == first.selected_index
            && second.selected_request.execution_request_id == first.selected_request.execution_request_id
            && second.command_type == first.command_type && second.candidates_scanned == first.candidates_scanned,
            "same inputs twice -> identical selection: no in-memory 'already processed' state");
   }

   //=====================================================================
   Print("--- C. fail-closed: an UNKNOWN candidate stops the scan ---");
   {
      ResetReady();
      AddRequest("ER_W2_ATTEMPTED_1");
      AddRequest("ER_W2_NEW_X");
      ManualApprovalReadiness_Reset();   // registry not ready this session
      BoundedAutomation_SelectCandidate(lines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_STATE_UNKNOWN && s.selected_index == 1 && s.candidates_scanned == 2
            && s.command_type == CEREMONY_COMMAND_TYPE_UNKNOWN,
            "registry not ready -> attempted one skipped, next is UNKNOWN -> stop, nothing selected (" + Describe(s) + ")");

      bool ready = ResetReady();
      AddRequest("ER_W2_NEW_X");
      BoundedAutomation_SelectCandidate(lines, mbFree, 0, s);
      Check(ready && s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_STATE_UNKNOWN && s.selected_index == 0,
            "asOf <= 0 -> CANDIDATE_STATE_UNKNOWN, nothing selected (" + Describe(s) + ")");

      ResetReady();
      AddRequest("");                    // untrusted record ahead of an eligible one
      AddRequest("ER_W2_NEW_X");
      BoundedAutomation_SelectCandidate(lines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_STATE_UNKNOWN && s.selected_index == 0 && s.candidates_scanned == 1,
            "empty execution_request_id at index 0 -> stop there, the eligible index 1 is NOT selected (" + Describe(s) + ")");
   }

   //=====================================================================
   Print("--- D. per-invocation entry point against real files, no side effects ---");
   {
      BoundedAutomation_DiscoverForInvocation(W2_MISSING_FILE, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_SNAPSHOT_INVALID && s.detail != "" && s.candidates_scanned == 0,
            "missing EventStore -> SNAPSHOT_INVALID, nothing scanned (" + Describe(s) + ")");

      bool corruptSetup = false;
      if(EventStore_Open(W2_CORRUPT_FILE))
      {
         EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SYSTEM_STARTED), "wave2 corrupt fixture");
         EventStore_Close();
         int h = FileOpen(W2_CORRUPT_FILE, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
         if(h != INVALID_HANDLE)
         {
            FileSeek(h, 0, SEEK_END);
            FileWriteString(h, "not a valid event line\r\n");
            FileClose(h);
            corruptSetup = true;
         }
      }
      BoundedAutomation_DiscoverForInvocation(W2_CORRUPT_FILE, g_AsOf, s);
      Check(corruptSetup && s.outcome == BOUNDED_AUTOMATION_DISCOVERY_SNAPSHOT_INVALID && s.detail != "",
            "malformed EventStore -> SNAPSHOT_INVALID (" + Describe(s) + ")");

      ResetReady();
      AddRequest("ER_W2_ATTEMPTED_1");
      AddRequest("ER_W2_NEW_X");

      bool wroteTerminal = WriteMailbox("TEST_W2_TERMINAL", CEREMONY_MAILBOX_STATUS_COMPLETE);
      string mbBefore = MailboxCommandId();
      int registryBefore = ArraySize(g_CeremonyCommandRegistry);
      BoundedAutomation_DiscoverForInvocation(W2_SCAN_FILE, g_AsOf, s);
      string mbAfter = MailboxCommandId();
      string linesAfter[];
      string errAfter;
      BoundedAutomation_ReadValidatedSnapshot(W2_SCAN_FILE, linesAfter, errAfter);
      int storeAfter = ArraySize(linesAfter);
      int registryAfter = ArraySize(g_CeremonyCommandRegistry);
      Check(wroteTerminal && s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_SELECTED && s.selected_index == 1
            && s.selected_request.execution_request_id == "ER_W2_NEW_X",
            "real store (E2 for ATTEMPTED_1) + real terminal mailbox -> index 1 selected (" + Describe(s) + ")");
      Check(mbBefore == "TEST_W2_TERMINAL" && mbAfter == mbBefore,
            "selection never writes the mailbox (before='" + mbBefore + "' after='" + mbAfter + "')");
      Check(storeAfter == snapLines && registryAfter == registryBefore,
            StringFormat("selection never writes the EventStore or the ceremony registry (lines %d->%d, registry %d->%d)",
                         snapLines, storeAfter, registryBefore, registryAfter));

      bool wrotePending = WriteMailbox("TEST_W2_PENDING", CEREMONY_MAILBOX_STATUS_PENDING);
      BoundedAutomation_DiscoverForInvocation(W2_SCAN_FILE, g_AsOf, s);
      Check(wrotePending && s.outcome == BOUNDED_AUTOMATION_DISCOVERY_MAILBOX_OCCUPIED && s.candidates_scanned == 0,
            "real PENDING mailbox -> MAILBOX_OCCUPIED, 0 candidates evaluated (" + Describe(s) + ")");

      bool cleaned = WriteMailbox("TEST_W2_CLEANUP", CEREMONY_MAILBOX_STATUS_COMPLETE);
      bool freeAfter = CeremonyCommandMailbox_IsFreeForNewCommand();
      Check(cleaned && freeAfter, "cleanup: mailbox left terminal (COMPLETE)");
   }

   ManualApprovalReadiness_Reset();
   ManualApprovalProjection_Reset();
   ExecutionRequestProjection_Reset();
   DryRunResultProjection_Reset();
   DeleteFixture(W2_SCAN_FILE);
   DeleteFixture(W2_READY_FILE);
   DeleteFixture(W2_CORRUPT_FILE);

   Print(StringFormat("=== RESULT: %d/%d passed ===", g_TestsPassed, g_TestsRun));
}
