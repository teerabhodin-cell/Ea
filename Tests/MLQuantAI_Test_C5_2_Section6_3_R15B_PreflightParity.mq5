//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Section6_3_R15B_PreflightParity.mq5           |
//| C5.2 §6.3 Design Contract Rev.15 (commit 07a3581), R15-B slice:     |
//| D7 / F1c pre-flight parity before a SUBMIT_ORDER is issued          |
//| (Include/MLQuantAI/Execution/MLQuantAI_BoundedAutomationPreflight.mqh|
//| + its enforcement point in BoundedAutomation_IssueCommand()).       |
//|                                                                    |
//| Coverage:                                                           |
//|   A  the helper alone: TC-B1..B6, B10, sealed "unresolved" semantics |
//|   B  the helper writes nothing (TC-B9)                              |
//|   C  enforcement in IssueCommand against the real mailbox file:     |
//|      TC-B1..B5, B7, B8, and pre-flight never replaces the existing  |
//|      invalid-command / mailbox decisions (QA Q-B2 ordering)          |
//|                                                                    |
//| PRECONDITION - run only with NO MLQuantAI EA attached on any terminal|
//| sharing this machine's Common\Files folder. Section C writes the     |
//| shared ceremony mailbox (fixed FILE_COMMON name). Every command      |
//| written carries a test-only nonce and EventStore filename, and the   |
//| mailbox is left terminal (COMPLETE) at the end. No OrderSend/CTrade, |
//| no C2 gate, no MLQuantAI.mq5 code in this file.                      |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_BoundedAutomationIssuance.mqh>

#define R15B_STORE_FILE "MLQuantAI_Test_C63_R15B_Store.jsonl"
#define R15B_TEST_NONCE 616161.0

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

//--- fixture builders (projections / registry only - no durable write) ---
void ResetAll()
{
   ArrayResize(g_CeremonyCommandRegistry, 0);
   ExecutionRequestProjection_Reset();
   CandidateProjection_Reset();
   StateProjector_Reset();
}

void AddRequest(string erid, string candidateId)
{
   ExecutionRequestProjectionRecord rec;
   ExecutionRequestProjectionRecord_Init(rec);
   rec.execution_request_id   = erid;
   rec.execution_request_hash = "HASH_" + erid;
   rec.candidate_id           = candidateId;
   ExecutionRequestProjection_AppendRecord(rec);
}

void AddCandidate(string candidateId)
{
   int n = g_CandProj_Count;
   ArrayResize(g_CandProj_Records, n + 1);
   CandidateProjectionRecord_Init(g_CandProj_Records[n]);
   g_CandProj_Records[n].candidate_id = candidateId;
   g_CandProj_Count = n + 1;
}

// sealed StateProjector_Apply() genesis event - same synthetic technique as
// MLQuantAI_Test_C3_10B_AsyncTerminalRejectionAuthority.mq5
bool AddState(string candidateId)
{
   LifecycleEvent genesis;
   LifecycleEvent_Init(genesis);
   genesis.candidate_id = candidateId;
   genesis.from_state   = CANDIDATE_CREATED;
   genesis.to_state     = CANDIDATE_CREATED;
   string err;
   return StateProjector_Apply(genesis, err);
}

void AddRegistryEntry(string commandId, ENUM_CEREMONY_COMMAND_STATE state)
{
   int n = ArraySize(g_CeremonyCommandRegistry);
   ArrayResize(g_CeremonyCommandRegistry, n + 1);
   g_CeremonyCommandRegistry[n].command_id           = commandId;
   g_CeremonyCommandRegistry[n].command_type         = CEREMONY_COMMAND_TYPE_SUBMIT_ORDER;
   g_CeremonyCommandRegistry[n].current_state        = state;
   g_CeremonyCommandRegistry[n].execution_request_id = "ER_OTHER";
}

// request + candidate + state, all resolvable: every pre-flight check passes
bool SeedFull(string erid)
{
   AddRequest(erid, "CAND_" + erid);
   AddCandidate("CAND_" + erid);
   return AddState("CAND_" + erid);
}

string PF(ENUM_BOUNDED_AUTOMATION_PREFLIGHT p) { return BoundedAutomationPreflight_ToString(p); }
string IO(ENUM_BOUNDED_AUTOMATION_ISSUANCE_OUTCOME o) { return BoundedAutomationIssuanceOutcome_ToString(o); }

//--- mailbox helpers ---
bool WriteTerminalMailbox(string commandId)
{
   CeremonyCommand t;
   CeremonyCommand_Init(t);
   t.command_id     = commandId;
   t.mailbox_status = CEREMONY_MAILBOX_STATUS_COMPLETE;
   return CeremonyCommandMailbox_Write(t);
}

bool WritePendingMailbox(string commandId)
{
   CeremonyCommand t;
   CeremonyCommand_Init(t);
   t.command_id     = commandId;
   t.command_type   = CEREMONY_COMMAND_TYPE_TRANSITION_ROLLOUT_STAGE;
   t.mailbox_status = CEREMONY_MAILBOX_STATUS_PENDING;
   return CeremonyCommandMailbox_Write(t);
}

string MailboxCommandId()
{
   CeremonyCommand c;
   if(!CeremonyCommandMailbox_Read(c))
      return "";
   return c.command_id;
}

string Detail(ENUM_BOUNDED_AUTOMATION_ISSUANCE_OUTCOME o, const BoundedAutomationIssuanceDetail &d)
{
   return StringFormat("outcome=%s preflight_evaluated=%s preflight=%s cand='%s' mailbox='%s'",
                       IO(o), d.preflight_evaluated ? "true" : "false", d.preflight_evaluated ? PF(d.preflight) : "NOT_EVALUATED",
                       d.preflight_candidate_id, MailboxCommandId());
}

void OnStart()
{
   Print("=== MLQuantAI_Test_C5_2_Section6_3_R15B_PreflightParity.mq5 ===");
   Print("*** Pre-flight parity only - no OrderSend/CTrade/C2 gate. Precondition: no live MLQuantAI EA attached. ***");

   DeleteFixture(R15B_STORE_FILE);
   string cand = "";

   //=====================================================================
   Print("--- A. the pre-flight helper alone (sealed pre-E1 checks, same order) ---");
   {
      ResetAll();
      bool seeded = SeedFull("ER_B_OK");
      ENUM_BOUNDED_AUTOMATION_PREFLIGHT p5 = BoundedAutomation_PreflightSubmit("ER_B_OK", cand);
      Check(seeded && p5 == BOUNDED_AUTOMATION_PREFLIGHT_PASS && cand == "CAND_ER_B_OK",
            "TC-B5 all four checks pass -> " + PF(p5) + " (resolved cand='" + cand + "')");

      AddRegistryEntry("CMD_B_STUCK", CEREMONY_STATE_SUBMISSION_IN_PROGRESS);
      ENUM_BOUNDED_AUTOMATION_PREFLIGHT p1 = BoundedAutomation_PreflightSubmit("ER_B_OK", cand);
      Check(p1 == BOUNDED_AUTOMATION_PREFLIGHT_UNRESOLVED_SUBMISSION,
            "TC-B1 an unrelated command stuck at SUBMISSION_IN_PROGRESS blocks this SUBMIT -> " + PF(p1));

      ResetAll();
      AddRegistryEntry("CMD_B_DONE", CEREMONY_STATE_SUBMISSION_COMPLETE);
      AddRegistryEntry("CMD_B_FAIL", CEREMONY_STATE_COMMAND_FAILED);
      SeedFull("ER_B_OK");
      ENUM_BOUNDED_AUTOMATION_PREFLIGHT pT = BoundedAutomation_PreflightSubmit("ER_B_OK", cand);
      Check(pT == BOUNDED_AUTOMATION_PREFLIGHT_PASS,
            "sealed semantics: only SUBMISSION_IN_PROGRESS is 'unresolved' - COMPLETE/FAILED entries -> " + PF(pT));

      ResetAll();
      AddCandidate("CAND_ER_B_NOREQ");
      AddState("CAND_ER_B_NOREQ");
      ENUM_BOUNDED_AUTOMATION_PREFLIGHT p2 = BoundedAutomation_PreflightSubmit("ER_B_NOREQ", cand);
      Check(p2 == BOUNDED_AUTOMATION_PREFLIGHT_REQUEST_NOT_FOUND && cand == "",
            "TC-B2 request not in ExecutionRequestProjection (candidate + state present) -> " + PF(p2));

      ResetAll();
      AddRequest("ER_B_NOCAND", "CAND_ER_B_NOCAND");
      AddState("CAND_ER_B_NOCAND");
      ENUM_BOUNDED_AUTOMATION_PREFLIGHT p3 = BoundedAutomation_PreflightSubmit("ER_B_NOCAND", cand);
      Check(p3 == BOUNDED_AUTOMATION_PREFLIGHT_CANDIDATE_NOT_FOUND,
            "TC-B3 candidate not in CandidateProjection (request + state present) -> " + PF(p3));

      ResetAll();
      AddRequest("ER_B_NOSTATE", "CAND_ER_B_NOSTATE");
      AddCandidate("CAND_ER_B_NOSTATE");
      ENUM_BOUNDED_AUTOMATION_PREFLIGHT p4 = BoundedAutomation_PreflightSubmit("ER_B_NOSTATE", cand);
      Check(p4 == BOUNDED_AUTOMATION_PREFLIGHT_CANDIDATE_STATE_NOT_FOUND,
            "TC-B4 candidate has no StateProjector state (request + candidate present) -> " + PF(p4));

      // TC-B6: the first failing check in sealed order wins
      ResetAll();
      AddRegistryEntry("CMD_B_STUCK", CEREMONY_STATE_SUBMISSION_IN_PROGRESS);
      ENUM_BOUNDED_AUTOMATION_PREFLIGHT o1 = BoundedAutomation_PreflightSubmit("ER_B_NOTHING", cand);
      ResetAll();
      ENUM_BOUNDED_AUTOMATION_PREFLIGHT o2 = BoundedAutomation_PreflightSubmit("ER_B_NOTHING", cand);
      AddRequest("ER_B_NOTHING", "CAND_ER_B_NOTHING");
      ENUM_BOUNDED_AUTOMATION_PREFLIGHT o3 = BoundedAutomation_PreflightSubmit("ER_B_NOTHING", cand);
      Check(o1 == BOUNDED_AUTOMATION_PREFLIGHT_UNRESOLVED_SUBMISSION
            && o2 == BOUNDED_AUTOMATION_PREFLIGHT_REQUEST_NOT_FOUND
            && o3 == BOUNDED_AUTOMATION_PREFLIGHT_CANDIDATE_NOT_FOUND,
            "TC-B6 order 1>2>3>4: unresolved+nothing -> " + PF(o1) + "; nothing -> " + PF(o2)
            + "; request only (no candidate, no state) -> " + PF(o3));

      // TC-B10: execution_request_id -> rec.candidate_id continuity
      ResetAll();
      AddRequest("ER_B_CONT_2", "CAND_WRONG");           // near-miss id, different candidate
      AddRequest("ER_B_CONT", "CAND_REAL_X");            // the target: candidate_id is NOT "CAND_" + erid
      AddCandidate("CAND_ER_B_CONT");                    // a guessed candidate_id - must not be used
      AddState("CAND_ER_B_CONT");
      ENUM_BOUNDED_AUTOMATION_PREFLIGHT c1 = BoundedAutomation_PreflightSubmit("ER_B_CONT", cand);
      string cand1 = cand;
      AddCandidate("CAND_REAL_X");
      AddState("CAND_REAL_X");
      ENUM_BOUNDED_AUTOMATION_PREFLIGHT c2 = BoundedAutomation_PreflightSubmit("ER_B_CONT", cand);
      Check(c1 == BOUNDED_AUTOMATION_PREFLIGHT_CANDIDATE_NOT_FOUND && cand1 == "CAND_REAL_X"
            && c2 == BOUNDED_AUTOMATION_PREFLIGHT_PASS && cand == "CAND_REAL_X",
            "TC-B10 checks 3/4 use rec.candidate_id of the EXACT id: only guessed candidate seeded -> " + PF(c1)
            + " (resolved '" + cand1 + "'); real candidate seeded -> " + PF(c2) + " (resolved '" + cand + "')");

      ResetAll();
      AddRequest("ER_B_PREFIX_2", "CAND_P");
      AddCandidate("CAND_P");
      AddState("CAND_P");
      ENUM_BOUNDED_AUTOMATION_PREFLIGHT px = BoundedAutomation_PreflightSubmit("ER_B_PREFIX", cand);
      Check(px == BOUNDED_AUTOMATION_PREFLIGHT_REQUEST_NOT_FOUND,
            "TC-B10 exact id only: 'ER_B_PREFIX' does not resolve to 'ER_B_PREFIX_2' -> " + PF(px));
   }

   //=====================================================================
   Print("--- B. the helper writes nothing (TC-B9) ---");
   {
      bool storeOk = EventStore_Open(R15B_STORE_FILE);
      if(storeOk)
         storeOk = EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SYSTEM_STARTED), "r15b store fixture");

      ResetAll();
      SeedFull("ER_B_OK");
      AddRequest("ER_B_NOCAND", "CAND_ER_B_NOCAND");
      AddRequest("ER_B_NOSTATE", "CAND_ER_B_NOSTATE");
      AddCandidate("CAND_ER_B_NOSTATE");
      string mailboxBefore = MailboxCommandId();
      int regBefore = ArraySize(g_CeremonyCommandRegistry);
      int reqBefore = ExecutionRequestProjection_Count();
      int candBefore = CandidateProjection_Count();
      int stateBefore = StateProjector_Count();

      BoundedAutomation_PreflightSubmit("ER_B_OK", cand);
      BoundedAutomation_PreflightSubmit("ER_B_MISSING", cand);
      BoundedAutomation_PreflightSubmit("ER_B_NOCAND", cand);
      BoundedAutomation_PreflightSubmit("ER_B_NOSTATE", cand);
      AddRegistryEntry("CMD_B_STUCK", CEREMONY_STATE_SUBMISSION_IN_PROGRESS);
      regBefore++;
      BoundedAutomation_PreflightSubmit("ER_B_OK", cand);

      EventStore_Close();
      string lines[];
      int n = EventStore_ReadAllLines(R15B_STORE_FILE, lines);
      Check(storeOk && n == 1,
            StringFormat("TC-B9 EventStore untouched by every branch (lines=%d, expected 1)", n));
      Check(ArraySize(g_CeremonyCommandRegistry) == regBefore && ExecutionRequestProjection_Count() == reqBefore
            && CandidateProjection_Count() == candBefore && StateProjector_Count() == stateBefore
            && MailboxCommandId() == mailboxBefore,
            StringFormat("TC-B9 registry/projections/mailbox untouched (reg %d, req %d, cand %d, state %d, mailbox '%s')",
                         ArraySize(g_CeremonyCommandRegistry), ExecutionRequestProjection_Count(),
                         CandidateProjection_Count(), StateProjector_Count(), MailboxCommandId()));
   }

   //=====================================================================
   Print("--- C. enforcement in IssueCommand against the real mailbox file ---");
   {
      BoundedAutomationIssuanceDetail d;
      ENUM_BOUNDED_AUTOMATION_ISSUANCE_OUTCOME o;
      CeremonyCommand sub;

      Check(WriteTerminalMailbox("TEST_R15B_FREE") && CeremonyCommandMailbox_IsFreeForNewCommand(),
            "setup: mailbox terminal -> free");

      // TC-B1..B4 at issuance level + TC-B8 (mailbox never written)
      ResetAll();
      SeedFull("ER_B_OK");
      AddRegistryEntry("CMD_B_STUCK", CEREMONY_STATE_SUBMISSION_IN_PROGRESS);
      BoundedAutomation_BuildCommand(CEREMONY_COMMAND_TYPE_SUBMIT_ORDER, "ER_B_OK", R15B_TEST_NONCE, R15B_STORE_FILE, sub);
      o = BoundedAutomation_IssueCommandDetailed(sub, d);
      Check(o == BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_PREFLIGHT && d.preflight_evaluated
            && d.preflight == BOUNDED_AUTOMATION_PREFLIGHT_UNRESOLVED_SUBMISSION && MailboxCommandId() == "TEST_R15B_FREE",
            "TC-B1/B8 unresolved -> no issuance, mailbox untouched (" + Detail(o, d) + ")");

      ResetAll();
      BoundedAutomation_BuildCommand(CEREMONY_COMMAND_TYPE_SUBMIT_ORDER, "ER_B_NOREQ", R15B_TEST_NONCE, R15B_STORE_FILE, sub);
      o = BoundedAutomation_IssueCommandDetailed(sub, d);
      Check(o == BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_PREFLIGHT
            && d.preflight == BOUNDED_AUTOMATION_PREFLIGHT_REQUEST_NOT_FOUND && MailboxCommandId() == "TEST_R15B_FREE",
            "TC-B2/B8 request not found -> no issuance, mailbox untouched (" + Detail(o, d) + ")");

      ResetAll();
      AddRequest("ER_B_NOCAND", "CAND_ER_B_NOCAND");
      AddState("CAND_ER_B_NOCAND");
      BoundedAutomation_BuildCommand(CEREMONY_COMMAND_TYPE_SUBMIT_ORDER, "ER_B_NOCAND", R15B_TEST_NONCE, R15B_STORE_FILE, sub);
      o = BoundedAutomation_IssueCommandDetailed(sub, d);
      Check(o == BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_PREFLIGHT
            && d.preflight == BOUNDED_AUTOMATION_PREFLIGHT_CANDIDATE_NOT_FOUND && MailboxCommandId() == "TEST_R15B_FREE",
            "TC-B3/B8 candidate not found -> no issuance, mailbox untouched (" + Detail(o, d) + ")");

      ResetAll();
      AddRequest("ER_B_NOSTATE", "CAND_ER_B_NOSTATE");
      AddCandidate("CAND_ER_B_NOSTATE");
      BoundedAutomation_BuildCommand(CEREMONY_COMMAND_TYPE_SUBMIT_ORDER, "ER_B_NOSTATE", R15B_TEST_NONCE, R15B_STORE_FILE, sub);
      o = BoundedAutomation_IssueCommandDetailed(sub, d);
      Check(o == BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_PREFLIGHT
            && d.preflight == BOUNDED_AUTOMATION_PREFLIGHT_CANDIDATE_STATE_NOT_FOUND && MailboxCommandId() == "TEST_R15B_FREE",
            "TC-B4/B8 candidate state not found -> no issuance, mailbox untouched (" + Detail(o, d) + ")");

      // Q-B2 ordering: pre-flight is the LAST step - it never replaces the
      // existing invalid-command or mailbox-occupancy decisions
      ResetAll();
      AddRegistryEntry("CMD_B_STUCK", CEREMONY_STATE_SUBMISSION_IN_PROGRESS);
      CeremonyCommand human;
      BoundedAutomation_BuildCommand(CEREMONY_COMMAND_TYPE_SUBMIT_ORDER, "ER_B_NOTHING", R15B_TEST_NONCE, R15B_STORE_FILE, human);
      human.approver_identity = "human_operator";
      o = BoundedAutomation_IssueCommandDetailed(human, d);
      Check(o == BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_INVALID_COMMAND && !d.preflight_evaluated,
            "ordering: invalid command is decided first, pre-flight not evaluated (" + Detail(o, d) + ")");

      Check(WritePendingMailbox("TEST_R15B_PENDING"), "setup: mailbox PENDING (occupied)");
      BoundedAutomation_BuildCommand(CEREMONY_COMMAND_TYPE_SUBMIT_ORDER, "ER_B_NOTHING", R15B_TEST_NONCE, R15B_STORE_FILE, sub);
      o = BoundedAutomation_IssueCommandDetailed(sub, d);
      Check(o == BOUNDED_AUTOMATION_ISSUANCE_NOT_ATTEMPTED_MAILBOX_BUSY && !d.preflight_evaluated
            && MailboxCommandId() == "TEST_R15B_PENDING",
            "ordering: occupied mailbox is decided before pre-flight, which is not evaluated (" + Detail(o, d) + ")");

      // TC-B7: GRANT is never pre-flighted, even with unresolved = true and no records
      Check(WriteTerminalMailbox("TEST_R15B_FREE") && CeremonyCommandMailbox_IsFreeForNewCommand(), "setup: mailbox free again");
      CeremonyCommand grant;
      BoundedAutomation_BuildCommand(CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL, "ER_B_NOTHING", R15B_TEST_NONCE, R15B_STORE_FILE, grant);
      o = BoundedAutomation_IssueCommandDetailed(grant, d);
      Check(o == BOUNDED_AUTOMATION_ISSUANCE_ISSUED_CONFIRMED && !d.preflight_evaluated
            && CeremonyCommandRegistry_HasUnresolvedSubmission() && MailboxCommandId() == grant.command_id,
            "TC-B7 GRANT bypasses pre-flight (unresolved=true, no records) -> issued (" + Detail(o, d) + ")");

      // TC-B5: all four pass -> ISSUED_CONFIRMED
      Check(WriteTerminalMailbox("TEST_R15B_FREE") && CeremonyCommandMailbox_IsFreeForNewCommand(), "setup: mailbox free again");
      ResetAll();
      SeedFull("ER_B_OK");
      BoundedAutomation_BuildCommand(CEREMONY_COMMAND_TYPE_SUBMIT_ORDER, "ER_B_OK", R15B_TEST_NONCE, R15B_STORE_FILE, sub);
      o = BoundedAutomation_IssueCommandDetailed(sub, d);
      Check(o == BOUNDED_AUTOMATION_ISSUANCE_ISSUED_CONFIRMED && d.preflight_evaluated
            && d.preflight == BOUNDED_AUTOMATION_PREFLIGHT_PASS && d.preflight_candidate_id == "CAND_ER_B_OK"
            && MailboxCommandId() == sub.command_id,
            "TC-B5 all four pass -> SUBMIT issued (" + Detail(o, d) + ")");

      Check(WriteTerminalMailbox("TEST_R15B_CLEANUP") && CeremonyCommandMailbox_IsFreeForNewCommand(),
            "cleanup: mailbox left terminal (COMPLETE)");
   }

   ResetAll();
   DeleteFixture(R15B_STORE_FILE);

   Print(StringFormat("=== RESULT: %d/%d passed ===", g_TestsPassed, g_TestsRun));
}
