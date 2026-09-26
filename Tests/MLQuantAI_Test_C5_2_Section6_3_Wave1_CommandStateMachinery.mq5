//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Section6_3_Wave1_CommandStateMachinery.mq5    |
//| C5.2 §6.3 Bounded-Automation Design Contract Rev.14 (commit        |
//| 6b7e836), Implementation Wave 1: command / mailbox / state          |
//| machinery (Include/MLQuantAI/Execution/                             |
//| MLQuantAI_BoundedAutomationContract.mqh,                            |
//| MLQuantAI_BoundedAutomationIssuance.mqh).                           |
//|                                                                    |
//| Coverage:                                                           |
//|   A  constants (reserved identity = PROV-1 AUTOMATION token)         |
//|   B  §2.3.2 pure derivation - every branch, incl. Rev.6's            |
//|      APPROVAL_QUEUED reachability fix and "registry never consulted |
//|      while the mailbox is occupied"                                 |
//|   C  §2.3.2 step 1 precondition + E2 raw scan over REAL lines        |
//|      written to an isolated fixture store (E1 must not match)        |
//|   D  EvaluateCandidateState() against the sealed approval registry   |
//|      (readiness, identity match, expiry, asOf)                       |
//|   E  command builder + §2.3.2b confirmation classification (pure)    |
//|   F  §2.3.2a issuance protocol against the real mailbox file         |
//|                                                                    |
//| Not covered (disclosed): WRITE_FAILED needs an induced FileOpen       |
//| failure on the mailbox; a true external-writer race needs a second  |
//| OS process. The LOST branch is covered at the pure classification    |
//| level (E). No OrderSend/CTrade, no C2 gate, no MLQuantAI.mq5 code in  |
//| this file.                                                           |
//|                                                                    |
//| PRECONDITION - run only with NO MLQuantAI EA attached on any terminal|
//| sharing this machine's Common\Files folder. Section F writes the     |
//| shared ceremony mailbox (MLQuantAI_CeremonyCommand.json is a fixed    |
//| FILE_COMMON name, as in Tests/MLQuantAI_Test_RA31_CeremonyCommand     |
//| Protocol.mq5). Every command written here carries a test-only nonce  |
//| and a test-only EventStore filename, and the file is left in a       |
//| terminal (COMPLETE) state at the end, but a live EA polling during    |
//| the run could still claim-reject a PENDING test command into its own |
//| real EventStore.                                                     |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_BoundedAutomationIssuance.mqh>

#define W1_SCAN_FILE     "MLQuantAI_Test_C63_W1_Scan.jsonl"
#define W1_CORRUPT_FILE  "MLQuantAI_Test_C63_W1_Corrupt.jsonl"
#define W1_READY_FILE    "MLQuantAI_Test_C63_W1_Ready.jsonl"
#define W1_MISSING_FILE  "MLQuantAI_Test_C63_W1_DoesNotExist.jsonl"
#define W1_TEST_NONCE    515151.0

int g_TestsRun    = 0;
int g_TestsPassed = 0;

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

ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE Derive(bool e2, bool present, ENUM_CEREMONY_MAILBOX_STATUS status,
                                                ENUM_CEREMONY_COMMAND_TYPE type, string target,
                                                string erid, bool approval)
{
   BoundedAutomationMailboxSnapshot s;
   MakeSnapshot(present, status, type, target, s);
   return BoundedAutomation_DeriveCandidateState(e2, s, erid, approval);
}

// Same key set and order as the sealed ExecutionSubmissionAttempt_ToExtraJson()
// (MLQuantAI_BrokerSubmissionAdapter.mqh:105-114), written through the same
// sealed EventStore_LogSystem() BrokerSubmission_RecordAttempt() uses (:152).
bool AppendE2(string erid)
{
   string extra = "";
   extra += "\"execution_request_id\":\""   + EventSerializer_Escape(erid) + "\",";
   extra += "\"execution_request_hash\":\"" + EventSerializer_Escape("HASH_" + erid) + "\",";
   extra += "\"correlation_id\":\""         + EventSerializer_Escape("CORR_" + erid) + "\",";
   extra += "\"submit_attempt\":"           + IntegerToString(1);
   return EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_SUBMISSION_ATTEMPTED), "execution submission attempted", extra);
}

// A real E1 (CEREMONY_COMMAND_STATE_CHANGED, to_state SUBMISSION_IN_PROGRESS)
// via the sealed writer - it carries execution_request_id too.
bool AppendE1(string commandId, string erid)
{
   return EventStore_LogCeremonyCommandState(commandId, CEREMONY_COMMAND_TYPE_SUBMIT_ORDER,
                                             CEREMONY_STATE_COMMAND_RECEIVED, CEREMONY_STATE_SUBMISSION_IN_PROGRESS,
                                             "submitting", erid);
}

void MakeRequestRecord(string erid, ExecutionRequestProjectionRecord &out)
{
   ExecutionRequestProjectionRecord_Init(out);
   out.execution_request_id     = erid;
   out.execution_request_hash   = "HASH_" + erid;
   out.execution_policy_version = "POLICY_V1";
   out.candidate_id             = "CAND_" + erid;
   out.correlation_id           = "CORR_" + erid;
}

void AppendApprovalRecord(const ExecutionRequestProjectionRecord &req, string approver, datetime ts, datetime expiry)
{
   ManualApprovalProjectionRecord rec;
   ManualApprovalProjectionRecord_Init(rec);
   rec.execution_request_id     = req.execution_request_id;
   rec.execution_request_hash   = req.execution_request_hash;
   rec.execution_policy_version = req.execution_policy_version;
   rec.candidate_id             = req.candidate_id;
   rec.correlation_id           = req.correlation_id;
   rec.approver_identity        = approver;
   rec.approval_timestamp       = ts;
   rec.approval_expiry          = expiry;
   rec.approval_nonce           = "NONCE_" + req.execution_request_id;
   ManualApprovalProjection_AppendRecord(rec);
}

bool WriteTerminalMailbox(string commandId)
{
   CeremonyCommand t;
   CeremonyCommand_Init(t);
   t.command_id     = commandId;
   t.mailbox_status = CEREMONY_MAILBOX_STATUS_COMPLETE;
   return CeremonyCommandMailbox_Write(t);
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
   Print("=== MLQuantAI_Test_C5_2_Section6_3_Wave1_CommandStateMachinery.mq5 ===");
   Print("*** No OrderSend/CTrade/C2 gate anywhere in this file. Precondition: no live MLQuantAI EA attached. ***");

   DeleteFixture(W1_SCAN_FILE);
   DeleteFixture(W1_CORRUPT_FILE);
   DeleteFixture(W1_READY_FILE);
   DeleteFixture(W1_MISSING_FILE);
   ArrayResize(g_CeremonyCommandRegistry, 0);

   //=====================================================================
   Print("--- A. constants ---");
   Check(MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY == "SYSTEM_BOUNDED_AUTOMATION_V1",
         "reserved identity == PROV-1 AUTOMATION token SYSTEM_BOUNDED_AUTOMATION_V1");
   Check(MLQUANTAI_BOUNDED_AUTOMATION_GRANT_VALIDITY_MINUTES == 15,
         "system GRANT validity == sealed GrantManualApprovalCommand() fallback (15)");

   //=====================================================================
   Print("--- B. §2.3.2 pure derivation ---");
   string A = "ER_W1_A", B = "ER_W1_B";
   ENUM_CEREMONY_COMMAND_TYPE SUB = CEREMONY_COMMAND_TYPE_SUBMIT_ORDER;
   ENUM_CEREMONY_COMMAND_TYPE GRT = CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL;
   ENUM_CEREMONY_COMMAND_TYPE OTH = CEREMONY_COMMAND_TYPE_TRANSITION_ROLLOUT_STAGE;

   // step 1 outranks everything
   Check(Derive(true, false, CEREMONY_MAILBOX_STATUS_UNKNOWN, SUB, "", A, true) == BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED,
         "step 1: E2 exists, mailbox absent -> SUBMISSION_ISSUED");
   Check(Derive(true, true, CEREMONY_MAILBOX_STATUS_PENDING, GRT, B, A, false) == BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED,
         "step 1: E2 exists, mailbox occupied by another candidate -> SUBMISSION_ISSUED (durable evidence first)");
   // 2a
   Check(Derive(false, true, CEREMONY_MAILBOX_STATUS_PENDING, SUB, A, A, false) == BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED,
         "2a: own SUBMIT_ORDER PENDING -> SUBMISSION_ISSUED");
   Check(Derive(false, true, CEREMONY_MAILBOX_STATUS_CLAIMED, SUB, A, A, false) == BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED,
         "2a: own SUBMIT_ORDER CLAIMED -> SUBMISSION_ISSUED");
   // 2b - Rev.6 reachability fix
   Check(Derive(false, true, CEREMONY_MAILBOX_STATUS_PENDING, GRT, A, A, false) == BOUNDED_AUTOMATION_STATE_APPROVAL_QUEUED,
         "2b: own GRANT PENDING -> APPROVAL_QUEUED (reachable, Rev.6)");
   Check(Derive(false, true, CEREMONY_MAILBOX_STATUS_CLAIMED, GRT, A, A, true) == BOUNDED_AUTOMATION_STATE_APPROVAL_QUEUED,
         "2b: own GRANT CLAIMED, approval=true supplied -> still APPROVAL_QUEUED");
   // 2c
   Check(Derive(false, true, CEREMONY_MAILBOX_STATUS_PENDING, GRT, B, A, false) == BOUNDED_AUTOMATION_STATE_MAILBOX_BUSY,
         "2c: another candidate's GRANT -> MAILBOX_BUSY");
   Check(Derive(false, true, CEREMONY_MAILBOX_STATUS_PENDING, SUB, B, A, false) == BOUNDED_AUTOMATION_STATE_MAILBOX_BUSY,
         "2c: another candidate's SUBMIT -> MAILBOX_BUSY");
   Check(Derive(false, true, CEREMONY_MAILBOX_STATUS_CLAIMED, OTH, "", A, false) == BOUNDED_AUTOMATION_STATE_MAILBOX_BUSY,
         "2c: a different command type -> MAILBOX_BUSY");
   Check(Derive(false, true, CEREMONY_MAILBOX_STATUS_UNKNOWN, GRT, A, A, false) == BOUNDED_AUTOMATION_STATE_APPROVAL_QUEUED,
         "occupancy mirrors sealed IsFree: unrecognised status is not terminal -> occupied (own GRANT -> APPROVAL_QUEUED)");
   Check(Derive(false, true, CEREMONY_MAILBOX_STATUS_UNKNOWN, OTH, "", A, true) == BOUNDED_AUTOMATION_STATE_MAILBOX_BUSY,
         "unrecognised status + other command -> MAILBOX_BUSY even with approval=true");
   Check(Derive(false, true, CEREMONY_MAILBOX_STATUS_PENDING, SUB, B, A, true) == BOUNDED_AUTOMATION_STATE_MAILBOX_BUSY,
         "registry never consulted while occupied: approval=true + busy -> MAILBOX_BUSY");
   // 2d -> 3/4
   Check(Derive(false, false, CEREMONY_MAILBOX_STATUS_UNKNOWN, SUB, "", A, true) == BOUNDED_AUTOMATION_STATE_APPROVED_NOT_SUBMITTED,
         "2d->3: mailbox absent, valid grant -> APPROVED_NOT_SUBMITTED");
   Check(Derive(false, false, CEREMONY_MAILBOX_STATUS_UNKNOWN, SUB, "", A, false) == BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED,
         "2d->4: mailbox absent, no grant -> NOT_YET_APPROVED");
   Check(Derive(false, true, CEREMONY_MAILBOX_STATUS_COMPLETE, GRT, A, A, true) == BOUNDED_AUTOMATION_STATE_APPROVED_NOT_SUBMITTED,
         "terminal COMPLETE own GRANT is FREE -> step 3 APPROVED_NOT_SUBMITTED");
   Check(Derive(false, true, CEREMONY_MAILBOX_STATUS_FAILED, GRT, A, A, false) == BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED,
         "terminal FAILED own GRANT is FREE -> step 4 NOT_YET_APPROVED (failed GRANT falls through)");
   Check(Derive(false, true, CEREMONY_MAILBOX_STATUS_REJECTED, SUB, B, A, false) == BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED,
         "terminal REJECTED other command is FREE -> NOT_YET_APPROVED");
   // fail-closed
   Check(Derive(false, false, CEREMONY_MAILBOX_STATUS_UNKNOWN, SUB, "", "", true) == BOUNDED_AUTOMATION_STATE_UNKNOWN,
         "empty execution_request_id -> UNKNOWN");

   ENUM_CEREMONY_COMMAND_TYPE issued;
   Check(BoundedAutomation_StateIssuesCommand(BOUNDED_AUTOMATION_STATE_APPROVED_NOT_SUBMITTED, issued) && issued == SUB,
         "transition: APPROVED_NOT_SUBMITTED issues SUBMIT_ORDER");
   Check(BoundedAutomation_StateIssuesCommand(BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED, issued) && issued == GRT,
         "transition: NOT_YET_APPROVED issues GRANT_MANUAL_APPROVAL");
   Check(!BoundedAutomation_StateIssuesCommand(BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED, issued) && issued == CEREMONY_COMMAND_TYPE_UNKNOWN,
         "transition: SUBMISSION_ISSUED issues nothing");
   Check(!BoundedAutomation_StateIssuesCommand(BOUNDED_AUTOMATION_STATE_APPROVAL_QUEUED, issued), "transition: APPROVAL_QUEUED issues nothing");
   Check(!BoundedAutomation_StateIssuesCommand(BOUNDED_AUTOMATION_STATE_MAILBOX_BUSY, issued), "transition: MAILBOX_BUSY issues nothing");
   Check(!BoundedAutomation_StateIssuesCommand(BOUNDED_AUTOMATION_STATE_UNKNOWN, issued), "transition: UNKNOWN issues nothing");

   //=====================================================================
   Print("--- C. §2.3.2 step 1 precondition + E2 raw scan (real fixture lines) ---");
   {
      string lines[];
      string err;
      Check(!BoundedAutomation_ReadValidatedSnapshot(W1_MISSING_FILE, lines, err) && ArraySize(lines) == 0 && err != "",
            "missing/unopenable store -> zero lines -> false (never vacuously valid)");

      if(!EventStore_Open(W1_SCAN_FILE))
         Check(false, "setup: open scan fixture");
      else
      {
         Check(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SYSTEM_STARTED), "wave1 fixture start"), "setup: system line");
         Check(AppendE1("CMD_W1_E1_ONLY", "ER_W1_E1_ONLY"), "setup: E1 only for ER_W1_E1_ONLY");
         Check(AppendE1("CMD_W1_BOTH", "ER_W1_BOTH"), "setup: E1 for ER_W1_BOTH");
         Check(AppendE2("ER_W1_BOTH"), "setup: E2 for ER_W1_BOTH");
         Check(AppendE2("ER_W1_E2_ONLY"), "setup: E2 only for ER_W1_E2_ONLY");

         // Evaluate first, then build the label: MQL5 evaluates call arguments
         // right to left, so an inline label would show the previous call's err.
         bool validOk = BoundedAutomation_ReadValidatedSnapshot(W1_SCAN_FILE, lines, err);
         Check(validOk && ArraySize(lines) == 5,
               "valid store -> true, all 5 lines returned (lines=" + IntegerToString(ArraySize(lines)) + ", err='" + err + "')");
         Check(BoundedAutomation_HasSubmissionAttempt(lines, "ER_W1_BOTH"), "E2 scan: ER_W1_BOTH found");
         Check(BoundedAutomation_HasSubmissionAttempt(lines, "ER_W1_E2_ONLY"), "E2 scan: ER_W1_E2_ONLY found");
         Check(!BoundedAutomation_HasSubmissionAttempt(lines, "ER_W1_E1_ONLY"), "E2 scan: E1-only request NOT matched (E1 != E2)");
         Check(!BoundedAutomation_HasSubmissionAttempt(lines, "ER_W1_ABSENT"), "E2 scan: unknown request not matched");
         Check(!BoundedAutomation_HasSubmissionAttempt(lines, "ER_W1"), "E2 scan: exact key only, no prefix match");
         Check(!BoundedAutomation_HasSubmissionAttempt(lines, ""), "E2 scan: empty id never matches");
         string noLines[];
         Check(!BoundedAutomation_HasSubmissionAttempt(noLines, "ER_W1_BOTH"), "E2 scan: empty array -> false");
         EventStore_Close();
      }

      // corrupted store: one valid line, then a garbage line appended outside the EventStore writer
      if(!EventStore_Open(W1_CORRUPT_FILE))
         Check(false, "setup: open corrupt fixture");
      else
      {
         Check(EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SYSTEM_STARTED), "wave1 corrupt fixture"), "setup: valid line");
         EventStore_Close();
         int h = FileOpen(W1_CORRUPT_FILE, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
         if(h == INVALID_HANDLE)
            Check(false, "setup: reopen corrupt fixture for raw append");
         else
         {
            FileSeek(h, 0, SEEK_END);
            FileWriteString(h, "{\"type\":\"EXECUTION_SUBMISSION_ATTEMPTED\",\"execution_request_id\":\"ER_W1_FORGED\"\r\n");
            FileClose(h);
            bool corruptOk = BoundedAutomation_ReadValidatedSnapshot(W1_CORRUPT_FILE, lines, err);
            Check(!corruptOk && err != "",
                  "malformed line -> ValidateLines not ok -> false (err='" + err + "')");
         }
      }
   }

   //=====================================================================
   Print("--- D. EvaluateCandidateState() with the sealed approval registry ---");
   {
      datetime asOf = D'2026.06.01 12:00:00';
      string lines[];
      string err;
      BoundedAutomationMailboxSnapshot mbFree;
      MakeSnapshot(false, CEREMONY_MAILBOX_STATUS_UNKNOWN, CEREMONY_COMMAND_TYPE_UNKNOWN, "", mbFree);
      BoundedAutomationMailboxSnapshot mbBusy;
      MakeSnapshot(true, CEREMONY_MAILBOX_STATUS_PENDING, SUB, "ER_OTHER", mbBusy);

      ExecutionRequestProjectionRecord reqA, reqE2;
      MakeRequestRecord("ER_W1_READY_A", reqA);
      MakeRequestRecord("ER_W1_BOTH", reqE2);

      // lines for the E2 case, from section C's valid fixture
      BoundedAutomation_ReadValidatedSnapshot(W1_SCAN_FILE, lines, err);

      ManualApprovalReadiness_Reset();
      Check(BoundedAutomation_EvaluateCandidateState(lines, mbFree, reqA, asOf) == BOUNDED_AUTOMATION_STATE_UNKNOWN,
            "registry not ready, mailbox free, no E2 -> UNKNOWN (issue nothing)");
      Check(BoundedAutomation_EvaluateCandidateState(lines, mbFree, reqE2, asOf) == BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED,
            "registry not ready but E2 exists -> SUBMISSION_ISSUED (registry not consulted)");
      Check(BoundedAutomation_EvaluateCandidateState(lines, mbBusy, reqA, asOf) == BOUNDED_AUTOMATION_STATE_MAILBOX_BUSY,
            "registry not ready but mailbox busy -> MAILBOX_BUSY (registry not consulted)");

      if(!EventStore_Open(W1_READY_FILE))
         Check(false, "setup: open readiness fixture");
      else
      {
         EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SYSTEM_STARTED), "wave1 readiness fixture");
         ManualApprovalProjectionReport rebuild = ManualApproval_StartupRebuild(W1_READY_FILE);
         Check(rebuild.ok && ManualApprovalReadiness_IsReady(), "setup: registry rebuilt clean -> ready");
         EventStore_Close();

         Check(BoundedAutomation_EvaluateCandidateState(lines, mbFree, reqA, asOf) == BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED,
               "ready, empty registry -> NOT_YET_APPROVED");
         Check(BoundedAutomation_EvaluateCandidateState(lines, mbFree, reqA, 0) == BOUNDED_AUTOMATION_STATE_UNKNOWN,
               "asOf <= 0 -> UNKNOWN");

         AppendApprovalRecord(reqA, MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY, asOf - 60, asOf + 15 * 60);
         Check(BoundedAutomation_EvaluateCandidateState(lines, mbFree, reqA, asOf) == BOUNDED_AUTOMATION_STATE_APPROVED_NOT_SUBMITTED,
               "valid unexpired grant on all 5 identity fields -> APPROVED_NOT_SUBMITTED");
         Check(BoundedAutomation_EvaluateCandidateState(lines, mbBusy, reqA, asOf) == BOUNDED_AUTOMATION_STATE_MAILBOX_BUSY,
               "valid grant but mailbox busy -> MAILBOX_BUSY");
         Check(BoundedAutomation_EvaluateCandidateState(lines, mbFree, reqA, asOf + 15 * 60) == BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED,
               "grant expired at asOf (expiry > asOf is false) -> NOT_YET_APPROVED");

         ExecutionRequestProjectionRecord reqMismatch = reqA;
         reqMismatch.execution_request_hash = "HASH_DIFFERENT";
         Check(BoundedAutomation_EvaluateCandidateState(lines, mbFree, reqMismatch, asOf) == BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED,
               "grant for a different execution_request_hash does not count -> NOT_YET_APPROVED");

         ExecutionRequestProjectionRecord reqEmpty = reqA;
         reqEmpty.execution_request_id = "";
         Check(BoundedAutomation_EvaluateCandidateState(lines, mbFree, reqEmpty, asOf) == BOUNDED_AUTOMATION_STATE_UNKNOWN,
               "empty execution_request_id -> UNKNOWN");
      }
      ManualApprovalReadiness_Reset();
      ManualApprovalProjection_Reset();
   }

   //=====================================================================
   Print("--- E. command builder + confirmation classification (pure) ---");
   {
      CeremonyCommand g;
      Check(BoundedAutomation_BuildCommand(GRT, "ER_W1_BUILD", W1_TEST_NONCE, W1_SCAN_FILE, g), "build GRANT ok");
      Check(g.command_type == GRT && g.target_execution_request_id == "ER_W1_BUILD", "GRANT: type + target");
      Check(g.approver_identity == MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY, "GRANT: reserved approver_identity");
      Check(g.approval_validity_minutes == MLQUANTAI_BOUNDED_AUTOMATION_GRANT_VALIDITY_MINUTES, "GRANT: validity minutes");
      Check(g.expected_ea_binding_nonce == W1_TEST_NONCE && g.expected_eventstore_filename == W1_SCAN_FILE, "GRANT: nonce + filename");
      Check(g.mailbox_status == CEREMONY_MAILBOX_STATUS_PENDING, "GRANT: PENDING");
      Check(StringLen(g.command_id) == 20 && StringSubstr(g.command_id, 0, 4) == "CMD_", "GRANT: command_id shape CMD_ + 16 hex");

      CeremonyCommand s;
      Check(BoundedAutomation_BuildCommand(SUB, "ER_W1_BUILD", W1_TEST_NONCE, W1_SCAN_FILE, s), "build SUBMIT ok");
      Check(s.command_type == SUB && s.approver_identity == MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY,
            "SUBMIT: type + reserved approver_identity (set on BOTH command types)");
      Check(s.approval_validity_minutes == 0, "SUBMIT: no approval validity");
      Check(s.command_id != g.command_id, "two builds -> two distinct command_ids");

      CeremonyCommand x;
      Check(!BoundedAutomation_BuildCommand(CEREMONY_COMMAND_TYPE_RUN_C22_CEREMONY_FIXTURE, "ER", W1_TEST_NONCE, W1_SCAN_FILE, x),
            "build refuses any type other than GRANT/SUBMIT");
      Check(!BoundedAutomation_BuildCommand(OTH, "ER", W1_TEST_NONCE, W1_SCAN_FILE, x), "build refuses TRANSITION_ROLLOUT_STAGE");
      Check(!BoundedAutomation_BuildCommand(GRT, "", W1_TEST_NONCE, W1_SCAN_FILE, x), "build refuses empty execution_request_id");
      Check(!BoundedAutomation_BuildCommand(GRT, "ER", 0.0, W1_SCAN_FILE, x), "build refuses nonce <= 0");
      Check(!BoundedAutomation_BuildCommand(GRT, "ER", W1_TEST_NONCE, "", x), "build refuses empty EventStore filename");
      Check(x.command_id == "", "refused build leaves no command_id");

      CeremonyCommand confirm;
      CeremonyCommand_Init(confirm);
      confirm.command_id = g.command_id;
      Check(BoundedAutomation_ClassifyConfirmation(true, confirm, g.command_id) == BOUNDED_AUTOMATION_ISSUANCE_ISSUED_CONFIRMED,
            "confirm: read ok + own id -> ISSUED_CONFIRMED");
      confirm.command_id = "CMD_SOMEONE_ELSE";
      Check(BoundedAutomation_ClassifyConfirmation(true, confirm, g.command_id) == BOUNDED_AUTOMATION_ISSUANCE_LOST,
            "confirm: another writer's id -> LOST (overwritten)");
      confirm.command_id = g.command_id;
      Check(BoundedAutomation_ClassifyConfirmation(false, confirm, g.command_id) == BOUNDED_AUTOMATION_ISSUANCE_LOST,
            "confirm: read-back failed -> LOST (same accounting case, §2.3.2b)");
      Check(BoundedAutomation_ClassifyConfirmation(true, confirm, "") == BOUNDED_AUTOMATION_ISSUANCE_LOST,
            "confirm: empty issued id -> LOST");

      CeremonyCommand bad = g;
      bad.approver_identity = "human_operator";
      Check(!BoundedAutomation_IsIssuableCommand(bad), "issuable: non-reserved identity refused");
      bad = g; bad.command_type = OTH;
      Check(!BoundedAutomation_IsIssuableCommand(bad), "issuable: other command type refused");
      bad = g; bad.mailbox_status = CEREMONY_MAILBOX_STATUS_CLAIMED;
      Check(!BoundedAutomation_IsIssuableCommand(bad), "issuable: non-PENDING status refused");
      bad = g; bad.command_id = "";
      Check(!BoundedAutomation_IsIssuableCommand(bad), "issuable: empty command_id refused");
      bad = g; bad.target_execution_request_id = "";
      Check(!BoundedAutomation_IsIssuableCommand(bad), "issuable: empty target refused");
      Check(BoundedAutomation_IsIssuableCommand(g) && BoundedAutomation_IsIssuableCommand(s), "issuable: built GRANT/SUBMIT accepted");
   }

   //=====================================================================
   Print("--- F. §2.3.2a issuance protocol against the real mailbox file ---");
   {
      Check(WriteTerminalMailbox("TEST_W1_SETUP") && CeremonyCommandMailbox_IsFreeForNewCommand(),
            "setup: mailbox terminal -> free");

      CeremonyCommand grantA;
      BoundedAutomation_BuildCommand(GRT, "ER_W1_MB_A", W1_TEST_NONCE, W1_SCAN_FILE, grantA);
      Check(BoundedAutomation_IssueCommand(grantA) == BOUNDED_AUTOMATION_ISSUANCE_ISSUED_CONFIRMED,
            "free mailbox: GRANT issued -> ISSUED_CONFIRMED");

      CeremonyCommand onDisk;
      Check(CeremonyCommandMailbox_Read(onDisk) && onDisk.command_id == grantA.command_id
            && onDisk.mailbox_status == CEREMONY_MAILBOX_STATUS_PENDING
            && onDisk.command_type == GRT
            && onDisk.approver_identity == MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY
            && onDisk.target_execution_request_id == "ER_W1_MB_A"
            && onDisk.approval_validity_minutes == MLQUANTAI_BOUNDED_AUTOMATION_GRANT_VALIDITY_MINUTES
            && onDisk.expected_ea_binding_nonce == W1_TEST_NONCE
            && onDisk.expected_eventstore_filename == W1_SCAN_FILE,
            "mailbox now holds the issued GRANT, PENDING, every field round-tripped");

      BoundedAutomationMailboxSnapshot snap;
      BoundedAutomation_ReadMailboxSnapshot(snap);
      Check(BoundedAutomation_DeriveCandidateState(false, snap, "ER_W1_MB_A", true) == BOUNDED_AUTOMATION_STATE_APPROVAL_QUEUED,
            "real snapshot: own GRANT pending -> APPROVAL_QUEUED (no re-issue)");
      Check(BoundedAutomation_DeriveCandidateState(false, snap, "ER_W1_MB_B", true) == BOUNDED_AUTOMATION_STATE_MAILBOX_BUSY,
            "real snapshot: other candidate -> MAILBOX_BUSY");

      CeremonyCommand submitB;
      BoundedAutomation_BuildCommand(SUB, "ER_W1_MB_B", W1_TEST_NONCE, W1_SCAN_FILE, submitB);
      Check(BoundedAutomation_IssueCommand(submitB) == BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_MAILBOX_BUSY,
            "occupied mailbox: SUBMIT not attempted -> NOT_ATTEMPTED_MAILBOX_BUSY");
      Check(MailboxCommandId() == grantA.command_id, "occupied mailbox: GRANT untouched (no overwrite)");

      // the EA finishes the GRANT: terminal status frees the slot
      onDisk.mailbox_status = CEREMONY_MAILBOX_STATUS_COMPLETE;
      Check(CeremonyCommandMailbox_Write(onDisk) && CeremonyCommandMailbox_IsFreeForNewCommand(), "setup: GRANT terminal -> free");

      Check(BoundedAutomation_IssueCommand(submitB) == BOUNDED_AUTOMATION_ISSUANCE_ISSUED_CONFIRMED,
            "free again: SUBMIT issued -> ISSUED_CONFIRMED");
      BoundedAutomation_ReadMailboxSnapshot(snap);
      Check(BoundedAutomation_DeriveCandidateState(false, snap, "ER_W1_MB_B", true) == BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED,
            "real snapshot: own SUBMIT pending -> SUBMISSION_ISSUED (2a)");

      // invalid commands are never written, even onto a free slot
      Check(WriteTerminalMailbox("TEST_W1_FREE") && CeremonyCommandMailbox_IsFreeForNewCommand(), "setup: mailbox free again");
      CeremonyCommand human = grantA;
      human.command_id = "CMD_W1_HUMAN";
      human.approver_identity = "human_operator";
      Check(BoundedAutomation_IssueCommand(human) == BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_INVALID_COMMAND,
            "non-reserved identity -> NOT_ATTEMPTED_INVALID_COMMAND");
      CeremonyCommand other = grantA;
      other.command_id = "CMD_W1_OTHER";
      other.command_type = OTH;
      Check(BoundedAutomation_IssueCommand(other) == BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_INVALID_COMMAND,
            "non-issuable type -> NOT_ATTEMPTED_INVALID_COMMAND");
      Check(MailboxCommandId() == "TEST_W1_FREE", "invalid commands never reached the mailbox file");

      Check(WriteTerminalMailbox("TEST_W1_CLEANUP") && CeremonyCommandMailbox_IsFreeForNewCommand(),
            "cleanup: mailbox left terminal (COMPLETE)");
   }

   DeleteFixture(W1_SCAN_FILE);
   DeleteFixture(W1_CORRUPT_FILE);
   DeleteFixture(W1_READY_FILE);

   Print(StringFormat("=== RESULT: %d/%d passed ===", g_TestsPassed, g_TestsRun));
}
