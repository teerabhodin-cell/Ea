//+------------------------------------------------------------------+
//| MLQuantAI_Test_RA31_CeremonyCommandProtocol.mq5                    |
//| RA-31 (QA-frozen Single-Writer Command/Response Protocol).         |
//| Regression coverage for the mailbox claim/ack protocol             |
//| (MLQuantAI_CeremonyCommandMailbox.mqh) and the durable command      |
//| state machine/registry (MLQuantAI_CeremonyCommandEventEmission.mqh)|
//| in isolation - it exercises the SAME functions MLQuantAI.mq5's own |
//| RA31_ProcessCeremonyCommand()/RunC22CeremonyFixtureCommand()/       |
//| GrantManualApprovalCommand()/SubmitOrderCommand() call, against a   |
//| throwaway, isolated EventStore file this test owns end to end.      |
//|                                                                    |
//| Scope, disclosed (not hidden): this file proves the CLAIM/ACK,      |
//| STALE-REJECTION, DUPLICATE-REJECTION, and RESTART-SEMANTICS         |
//| invariants QA listed - it does NOT run a real candidate build, a    |
//| real OrderSend, or a real OnTradeTransaction, since those require   |
//| live market/broker context this isolated test deliberately never    |
//| touches (no OrderSend anywhere in this file). Full L1->L2->L3        |
//| end-to-end proof can only come from a real, QA-authorized ceremony  |
//| run - this file's job is to prove the NEW protocol layer            |
//| (mailbox+registry) behaves exactly as RA-31.1/RA-31.2 specify,      |
//| independent of that.                                                |
//|                                                                    |
//| Safety: uses its own isolated EventStore file                       |
//| (MLQuantAI_Test_RA31_Fixture.jsonl, deleted and recreated at the    |
//| start of every run, same convention as every other Tests/*.mq5      |
//| fixture in this project) and its own test-only GlobalVariable       |
//| namespace/binding nonce - can never collide with a real ceremony's  |
//| canonical file or a real EA instance's live binding.                |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CeremonyCommandEventEmission.mqh>

#define RA31_TEST_FILE "MLQuantAI_Test_RA31_Fixture.jsonl"
#define RA31_TEST_NONCE 424242.0

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

// Builds a valid PENDING command targeting RA31_TEST_FILE/RA31_TEST_NONCE,
// with a fresh command_id each call.
void MakeValidPendingCommand(string commandId, ENUM_CEREMONY_COMMAND_TYPE type, CeremonyCommand &out)
{
   CeremonyCommand_Init(out);
   out.command_id                  = commandId;
   out.command_type                = type;
   out.command_sequence             = 1.0;
   out.expected_ea_binding_nonce    = RA31_TEST_NONCE;
   out.expected_eventstore_filename = RA31_TEST_FILE;
   out.mailbox_status               = CEREMONY_MAILBOX_STATUS_PENDING;
}

void OnStart()
{
   Print("=== RA-31 Ceremony Command Protocol - regression test ===");

   // Isolation: delete any leftover fixture file/mailbox/registry state
   // from a previous run before starting, same convention as every other
   // Tests/*.mq5 fixture file in this project.
   if(FileIsExist(RA31_TEST_FILE, FILE_COMMON))
      FileDelete(RA31_TEST_FILE, FILE_COMMON);
   GlobalVariableDel("MLQuantAI_CommandPending__" + RA31_TEST_FILE);
   GlobalVariableDel("MLQuantAI_CommandCounter__" + RA31_TEST_FILE);

   if(!EventStore_Open(RA31_TEST_FILE))
   {
      Print("ABORTED: could not open isolated test fixture file '", RA31_TEST_FILE, "'.");
      return;
   }
   CeremonyCommandRegistry_RebuildFromFile(RA31_TEST_FILE); // starts empty - fresh file

   CeremonyCommand claimed;
   bool ok;

   // --- Mailbox: PENDING -> CLAIMED -> terminal ------------------------
   CeremonyCommand cmdA;
   MakeValidPendingCommand("CMD_ra31_test_a", CEREMONY_COMMAND_TYPE_RUN_C22_CEREMONY_FIXTURE, cmdA);
   Check(CeremonyCommandMailbox_Write(cmdA), "setup: write PENDING command A to mailbox");

   ok = CeremonyCommand_TryClaim(RA31_TEST_FILE, RA31_TEST_NONCE, claimed);
   Check(ok && claimed.command_id == "CMD_ra31_test_a", "RA31-Mailbox: valid PENDING command is claimed");

   CeremonyCommand afterClaim;
   Check(CeremonyCommandMailbox_Read(afterClaim) && afterClaim.mailbox_status == CEREMONY_MAILBOX_STATUS_CLAIMED,
         "RA31-Mailbox: mailbox_status becomes CLAIMED after a successful claim");
   Check(CeremonyCommandRegistry_GetState("CMD_ra31_test_a") == CEREMONY_STATE_COMMAND_RECEIVED,
         "RA31-Mailbox: durable registry shows COMMAND_RECEIVED after claim");
   Check(!CeremonyCommandMailbox_IsFreeForNewCommand(),
         "RA31-Mailbox: mailbox is NOT free for a new command while CLAIMED (not yet terminal)");

   Check(CeremonyCommand_Complete(afterClaim, CEREMONY_STATE_COMMAND_RECEIVED, CEREMONY_STATE_CEREMONY_READY, "test_complete", ""),
         "setup: complete command A -> CEREMONY_READY");
   Check(CeremonyCommandMailbox_IsFreeForNewCommand(),
         "RA31-Mailbox: mailbox IS free for a new command once terminal (COMPLETE)");

   // --- Mailbox: duplicate command_id is never re-executed -------------
   CeremonyCommand dupSignal;
   MakeValidPendingCommand("CMD_ra31_test_a", CEREMONY_COMMAND_TYPE_RUN_C22_CEREMONY_FIXTURE, dupSignal); // SAME command_id as above
   CeremonyCommandMailbox_Write(dupSignal); // simulate a stale/replayed PENDING signal reappearing
   CeremonyCommand dupClaim;
   ok = CeremonyCommand_TryClaim(RA31_TEST_FILE, RA31_TEST_NONCE, dupClaim);
   Check(!ok, "RA31-Duplicate: a command_id already known in the registry (even terminal) is never re-claimed/re-executed");

   // --- Mailbox: stale nonce rejection -----------------------------------
   CeremonyCommand cmdStale;
   MakeValidPendingCommand("CMD_ra31_test_stale_nonce", CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL, cmdStale);
   cmdStale.expected_ea_binding_nonce = RA31_TEST_NONCE - 1.0; // wrong on purpose
   CeremonyCommandMailbox_Write(cmdStale);
   CeremonyCommand staleClaim;
   ok = CeremonyCommand_TryClaim(RA31_TEST_FILE, RA31_TEST_NONCE, staleClaim);
   Check(!ok, "RA31-StaleNonce: TryClaim returns false for a mismatched nonce");
   CeremonyCommand staleResult;
   CeremonyCommandMailbox_Read(staleResult);
   Check(staleResult.mailbox_status == CEREMONY_MAILBOX_STATUS_REJECTED && staleResult.result_reason_code == "stale_ea_binding_nonce",
         "RA31-StaleNonce: mailbox durably shows REJECTED/stale_ea_binding_nonce");
   Check(CeremonyCommandRegistry_GetState("CMD_ra31_test_stale_nonce") == CEREMONY_STATE_COMMAND_REJECTED,
         "RA31-StaleNonce: durable registry shows COMMAND_REJECTED");

   // --- Mailbox: filename mismatch rejection -----------------------------
   CeremonyCommand cmdWrongFile;
   MakeValidPendingCommand("CMD_ra31_test_wrong_file", CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL, cmdWrongFile);
   cmdWrongFile.expected_eventstore_filename = "MLQuantAI_SomeOtherFile.jsonl"; // wrong on purpose
   CeremonyCommandMailbox_Write(cmdWrongFile);
   CeremonyCommand wrongFileClaim;
   ok = CeremonyCommand_TryClaim(RA31_TEST_FILE, RA31_TEST_NONCE, wrongFileClaim);
   Check(!ok, "RA31-FilenameMismatch: TryClaim returns false for a mismatched expected_eventstore_filename");
   CeremonyCommand wrongFileResult;
   CeremonyCommandMailbox_Read(wrongFileResult);
   Check(wrongFileResult.mailbox_status == CEREMONY_MAILBOX_STATUS_REJECTED && wrongFileResult.result_reason_code == "eventstore_filename_mismatch",
         "RA31-FilenameMismatch: mailbox durably shows REJECTED/eventstore_filename_mismatch");

   // --- Restart semantics: CEREMONY_IN_PROGRESS is force-failed, never resumed
   EventStore_LogCeremonyCommandState("CMD_ra31_test_restart_ip", CEREMONY_COMMAND_TYPE_RUN_C22_CEREMONY_FIXTURE,
                                       CEREMONY_STATE_COMMAND_RECEIVED, CEREMONY_STATE_CEREMONY_IN_PROGRESS, "test_setup", "");
   CeremonyCommandRegistry_RebuildFromFile(RA31_TEST_FILE); // simulate an EA restart re-reading the file
   Check(CeremonyCommandRegistry_GetState("CMD_ra31_test_restart_ip") == CEREMONY_STATE_CEREMONY_IN_PROGRESS,
         "RA31-Restart: rebuild alone leaves CEREMONY_IN_PROGRESS untouched (no auto-anything yet)");
   int failedCount = CeremonyCommandRegistry_FailInterruptedCommands();
   Check(failedCount >= 1, "RA31-Restart: FailInterruptedCommands() reports at least the one interrupted command");
   Check(CeremonyCommandRegistry_GetState("CMD_ra31_test_restart_ip") == CEREMONY_STATE_COMMAND_FAILED,
         "RA31-Restart: CEREMONY_IN_PROGRESS is force-failed (COMMAND_FAILED) after restart, never resumed");

   // --- Restart semantics: CEREMONY_READY is left alone (safe to resume waiting)
   EventStore_LogCeremonyCommandState("CMD_ra31_test_restart_ready", CEREMONY_COMMAND_TYPE_RUN_C22_CEREMONY_FIXTURE,
                                       CEREMONY_STATE_COMMAND_RECEIVED, CEREMONY_STATE_CEREMONY_READY, "test_setup", "EXECREQ_ra31_test");
   CeremonyCommandRegistry_RebuildFromFile(RA31_TEST_FILE);
   CeremonyCommandRegistry_FailInterruptedCommands();
   Check(CeremonyCommandRegistry_GetState("CMD_ra31_test_restart_ready") == CEREMONY_STATE_CEREMONY_READY,
         "RA31-Restart: CEREMONY_READY survives a restart untouched (stable, safe to resume waiting)");

   // --- RA-31.2 condition B: global unresolved-submission block ----------
   Check(!CeremonyCommandRegistry_HasUnresolvedSubmission(), "RA31-UnresolvedGate: no unresolved submission before any SUBMISSION_IN_PROGRESS exists");
   EventStore_LogCeremonyCommandState("CMD_ra31_test_submission", CEREMONY_COMMAND_TYPE_SUBMIT_ORDER,
                                       CEREMONY_STATE_COMMAND_RECEIVED, CEREMONY_STATE_SUBMISSION_IN_PROGRESS, "test_setup", "EXECREQ_ra31_test");
   Check(CeremonyCommandRegistry_HasUnresolvedSubmission(), "RA31-UnresolvedGate: becomes true once a command is at SUBMISSION_IN_PROGRESS");
   EventStore_LogCeremonyCommandState("CMD_ra31_test_submission", CEREMONY_COMMAND_TYPE_SUBMIT_ORDER,
                                       CEREMONY_STATE_SUBMISSION_IN_PROGRESS, CEREMONY_STATE_SUBMISSION_COMPLETE, "test_setup", "EXECREQ_ra31_test");
   Check(!CeremonyCommandRegistry_HasUnresolvedSubmission(), "RA31-UnresolvedGate: clears once that command reaches SUBMISSION_COMPLETE");

   // Also true after a restart rebuild (not just in the same session):
   EventStore_LogCeremonyCommandState("CMD_ra31_test_submission2", CEREMONY_COMMAND_TYPE_SUBMIT_ORDER,
                                       CEREMONY_STATE_COMMAND_RECEIVED, CEREMONY_STATE_SUBMISSION_IN_PROGRESS, "test_setup", "EXECREQ_ra31_test2");
   CeremonyCommandRegistry_RebuildFromFile(RA31_TEST_FILE);
   Check(CeremonyCommandRegistry_HasUnresolvedSubmission(),
         "RA31-UnresolvedGate: an unresolved SUBMISSION_IN_PROGRESS is detected again after a fresh rebuild (restart-safe)");

   EventStore_Close();

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else Print("SOME CHECKS FAILED - see [FAIL] lines above.");
}
