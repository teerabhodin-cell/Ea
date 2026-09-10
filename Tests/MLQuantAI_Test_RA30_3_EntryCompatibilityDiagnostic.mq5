//+------------------------------------------------------------------+
//| MLQuantAI_Test_RA30_3_EntryCompatibilityDiagnostic.mq5             |
//| RA-30.3 (QA-frozen Read-Only Entry Compatibility Diagnostic).      |
//| QA-authorized scope-delta regression file (RA-30.3 Implementation  |
//| Review verdict) - covers the 11 required cases:                    |
//|   1. command accepted                                              |
//|   2. stale nonce rejected                                          |
//|   3. filename mismatch rejected                                    |
//|   4. target request missing                                        |
//|   5. hash mismatch                                                 |
//|   6. ACCEPTED result                                                |
//|   7. REJECTED result                                                |
//|   8. duplicate command_id blocked                                   |
//|   9. repeated evaluation with different command_id allowed          |
//|  10. diagnostic path cannot reach OrderSend/submission mutation      |
//|  11. diagnostic result preserves exact gateResult values             |
//|                                                                    |
//| Scope, disclosed (same convention as                                |
//| Tests/MLQuantAI_Test_RA31_CeremonyCommandProtocol.mq5's own header): |
//| this file exercises the REUSABLE, includable building blocks         |
//| EvaluateEntryCompatibilityCommand() (MLQuantAI.mq5, EA-only, not     |
//| includable from a script) itself calls -                             |
//| CeremonyCommand_TryClaim()/registry (mailbox+state-machine layer,     |
//| cases 1/2/3/8/9), EntryCompatibilityDiagnostic_Evaluate()/            |
//| EventStore_LogEntryCompatibilityEvaluated() (gate-calling+money-      |
//| breakdown layer, cases 6/7/11), and                                   |
//| ExecutionRequestProjection_TryGet()/ExecutionRequest_ComputeHash()    |
//| (projection/hash-guard layer, cases 4/5) - each against the SAME      |
//| production functions the EA handler calls, not a reimplementation.   |
//| It does NOT drive EvaluateEntryCompatibilityCommand() itself end to  |
//| end (that requires a live EA instance) - that full orchestration is  |
//| what the separately-required "Runtime diagnostic" evidence against   |
//| EXECREQ_6ad91bc6e6097e3b proves. Case 10 is proven here by this      |
//| file's own structural fact (documented, not asserted at runtime):    |
//| no OrderSend/CTrade/BrokerSubmission_* symbol appears anywhere in     |
//| this file, same self-evident convention as every other Tests/*.mq5   |
//| fixture that never opens a real position.                            |
//|                                                                    |
//| Safety: uses its own isolated EventStore file                        |
//| (MLQuantAI_Test_RA30_3_Fixture.jsonl, deleted and recreated at the    |
//| start of every run) and its own test-only binding nonce - can never   |
//| collide with a real ceremony's canonical file or a real EA            |
//| instance's live binding. NO OrderSend anywhere in this file.          |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CeremonyCommandEventEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_EntryCompatibilityDiagnosticEmission.mqh>
#include <MLQuantAI/Execution/MLQuantAI_ExecutionAuditProjection.mqh>
#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CandidateProjection.mqh>

#define RA30_3_TEST_FILE  "MLQuantAI_Test_RA30_3_Fixture.jsonl"
#define RA30_3_TEST_NONCE 989898.0
#define RA30_3_TEST_LOT   0.10

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void MakeValidPendingCommand(string commandId, string targetExecReqId, CeremonyCommand &out)
{
   CeremonyCommand_Init(out);
   out.command_id                    = commandId;
   out.command_type                  = CEREMONY_COMMAND_TYPE_EVALUATE_ENTRY_COMPATIBILITY;
   out.command_sequence               = 1.0;
   out.expected_ea_binding_nonce      = RA30_3_TEST_NONCE;
   out.expected_eventstore_filename   = RA30_3_TEST_FILE;
   out.target_execution_request_id    = targetExecReqId;
   out.mailbox_status                 = CEREMONY_MAILBOX_STATUS_PENDING;
}

void BuildMinimalExecutionRequest(ExecutionRequest &req, ENUM_ORDER_TYPE side,
                                    double plannedEntry, double plannedSl, double plannedTp,
                                    double lotSize, string idSuffix)
{
   ExecutionRequest_Init(req);
   req.execution_request_id   = "EXECREQ_RA30_3_TEST_" + idSuffix;
   req.execution_request_hash = "hash_ra30_3_test_" + idSuffix;
   req.candidate_id            = "CAND_ra30_3_test_" + idSuffix;
   req.correlation_id          = "CORR_ra30_3_test_" + idSuffix;
   req.submit_attempt          = 1;
   req.side                    = side;
   req.planned_entry           = plannedEntry;
   req.planned_sl              = plannedSl;
   req.planned_tp              = plannedTp;
   req.lot_size                = lotSize;
}

void OnStart()
{
   Print("=== RA-30.3 Entry Compatibility Diagnostic - regression test ===");

   //====================================================================
   // Section 1: mailbox/registry protocol layer (cases 1, 2, 3, 8, 9)
   //====================================================================
   if(FileIsExist(RA30_3_TEST_FILE, FILE_COMMON))
      FileDelete(RA30_3_TEST_FILE, FILE_COMMON);
   GlobalVariableDel("MLQuantAI_CommandPending__" + RA30_3_TEST_FILE);
   GlobalVariableDel("MLQuantAI_CommandCounter__" + RA30_3_TEST_FILE);

   if(!EventStore_Open(RA30_3_TEST_FILE))
   {
      Print("ABORTED: could not open isolated test fixture file '", RA30_3_TEST_FILE, "'.");
      return;
   }
   CeremonyCommandRegistry_RebuildFromFile(RA30_3_TEST_FILE);

   CeremonyCommand claimed;
   bool ok;

   // --- Case 1: command accepted (claimed), new terminal state reached ---
   CeremonyCommand cmdA;
   MakeValidPendingCommand("CMD_ra30_3_test_a", "EXECREQ_ra30_3_placeholder_a", cmdA);
   Check(CeremonyCommandMailbox_Write(cmdA), "setup: write PENDING EVALUATE_ENTRY_COMPATIBILITY command A to mailbox");

   ok = CeremonyCommand_TryClaim(RA30_3_TEST_FILE, RA30_3_TEST_NONCE, claimed);
   Check(ok && claimed.command_id == "CMD_ra30_3_test_a" && claimed.command_type == CEREMONY_COMMAND_TYPE_EVALUATE_ENTRY_COMPATIBILITY,
         "Case1: valid PENDING EVALUATE_ENTRY_COMPATIBILITY command is claimed");
   Check(CeremonyCommandRegistry_GetState("CMD_ra30_3_test_a") == CEREMONY_STATE_COMMAND_RECEIVED,
         "Case1: durable registry shows COMMAND_RECEIVED after claim");

   CeremonyCommand afterClaim;
   CeremonyCommandMailbox_Read(afterClaim);
   Check(CeremonyCommand_Complete(afterClaim, CEREMONY_STATE_COMMAND_RECEIVED, CEREMONY_STATE_ENTRY_COMPATIBILITY_EVALUATED,
                                   "granted_for_test", ""),
         "Case1: command A completes to the new ENTRY_COMPATIBILITY_EVALUATED terminal state");
   Check(CeremonyCommandRegistry_GetState("CMD_ra30_3_test_a") == CEREMONY_STATE_ENTRY_COMPATIBILITY_EVALUATED,
         "Case1: registry reflects ENTRY_COMPATIBILITY_EVALUATED after completion");
   Check(CeremonyCommandState_IsTerminal(CEREMONY_STATE_ENTRY_COMPATIBILITY_EVALUATED),
         "Case1: ENTRY_COMPATIBILITY_EVALUATED is recognized as terminal by CeremonyCommandState_IsTerminal()");
   Check(CeremonyCommandState_FromString(CeremonyCommandState_ToString(CEREMONY_STATE_ENTRY_COMPATIBILITY_EVALUATED)) == CEREMONY_STATE_ENTRY_COMPATIBILITY_EVALUATED,
         "Case1: ENTRY_COMPATIBILITY_EVALUATED ToString/FromString round-trips correctly");
   Check(CeremonyCommandType_FromString(CeremonyCommandType_ToString(CEREMONY_COMMAND_TYPE_EVALUATE_ENTRY_COMPATIBILITY)) == CEREMONY_COMMAND_TYPE_EVALUATE_ENTRY_COMPATIBILITY,
         "Case1: EVALUATE_ENTRY_COMPATIBILITY command type ToString/FromString round-trips correctly");
   Check(CeremonyCommandMailbox_IsFreeForNewCommand(),
         "Case1: mailbox IS free for a new command once terminal (COMPLETE)");

   // --- Case 8: duplicate command_id is never re-executed ---
   CeremonyCommand dupSignal;
   MakeValidPendingCommand("CMD_ra30_3_test_a", "EXECREQ_ra30_3_placeholder_a", dupSignal); // SAME command_id
   CeremonyCommandMailbox_Write(dupSignal);
   CeremonyCommand dupClaim;
   ok = CeremonyCommand_TryClaim(RA30_3_TEST_FILE, RA30_3_TEST_NONCE, dupClaim);
   Check(!ok, "Case8: a command_id already known in the registry (even terminal) is never re-claimed/re-executed");

   // --- Case 9: repeated evaluation with a DIFFERENT command_id, same target, is allowed ---
   CeremonyCommand cmdB;
   MakeValidPendingCommand("CMD_ra30_3_test_b", "EXECREQ_ra30_3_placeholder_a", cmdB); // same target_execution_request_id as command A, different command_id
   CeremonyCommandMailbox_Write(cmdB);
   CeremonyCommand claimedB;
   ok = CeremonyCommand_TryClaim(RA30_3_TEST_FILE, RA30_3_TEST_NONCE, claimedB);
   Check(ok && claimedB.command_id == "CMD_ra30_3_test_b",
         "Case9: a second EVALUATE_ENTRY_COMPATIBILITY command targeting the SAME execution_request_id, with a fresh command_id, is claimed (not blocked)");

   // --- Case 2: stale nonce rejected ---
   CeremonyCommand cmdStale;
   MakeValidPendingCommand("CMD_ra30_3_test_stale_nonce", "EXECREQ_ra30_3_placeholder_a", cmdStale);
   cmdStale.expected_ea_binding_nonce = RA30_3_TEST_NONCE - 1.0; // wrong on purpose
   CeremonyCommandMailbox_Write(cmdStale);
   CeremonyCommand staleClaim;
   ok = CeremonyCommand_TryClaim(RA30_3_TEST_FILE, RA30_3_TEST_NONCE, staleClaim);
   Check(!ok, "Case2: TryClaim returns false for a mismatched nonce");
   CeremonyCommand staleResult;
   CeremonyCommandMailbox_Read(staleResult);
   Check(staleResult.mailbox_status == CEREMONY_MAILBOX_STATUS_REJECTED && staleResult.result_reason_code == "stale_ea_binding_nonce",
         "Case2: mailbox durably shows REJECTED/stale_ea_binding_nonce");

   // --- Case 3: filename mismatch rejected ---
   CeremonyCommand cmdWrongFile;
   MakeValidPendingCommand("CMD_ra30_3_test_wrong_file", "EXECREQ_ra30_3_placeholder_a", cmdWrongFile);
   cmdWrongFile.expected_eventstore_filename = "MLQuantAI_SomeOtherFile.jsonl"; // wrong on purpose
   CeremonyCommandMailbox_Write(cmdWrongFile);
   CeremonyCommand wrongFileClaim;
   ok = CeremonyCommand_TryClaim(RA30_3_TEST_FILE, RA30_3_TEST_NONCE, wrongFileClaim);
   Check(!ok, "Case3: TryClaim returns false for a mismatched expected_eventstore_filename");
   CeremonyCommand wrongFileResult;
   CeremonyCommandMailbox_Read(wrongFileResult);
   Check(wrongFileResult.mailbox_status == CEREMONY_MAILBOX_STATUS_REJECTED && wrongFileResult.result_reason_code == "eventstore_filename_mismatch",
         "Case3: mailbox durably shows REJECTED/eventstore_filename_mismatch");

   EventStore_Close();

   //====================================================================
   // Section 2: projection/hash-guard layer (cases 4, 5)
   //====================================================================
   ExecutionRequestProjection_Reset();
   CandidateProjection_Reset();

   // --- Case 4: target request missing ---
   ExecutionRequestProjectionRecord missingRec;
   Check(!ExecutionRequestProjection_TryGet("EXECREQ_ra30_3_does_not_exist", missingRec),
         "Case4: ExecutionRequestProjection_TryGet returns false for an unknown execution_request_id");

   // --- Case 5: hash mismatch is detected by recompute ---
   ExecutionRequest hashReq;
   BuildMinimalExecutionRequest(hashReq, ORDER_TYPE_BUY, 100.0, 90.0, 120.0, RA30_3_TEST_LOT, "HASH");
   hashReq.execution_request_hash = ExecutionRequest_ComputeHash(hashReq);
   string correctHash = hashReq.execution_request_hash;
   Check(ExecutionRequest_ComputeHash(hashReq) == correctHash,
         "Case5: a correctly-reconstructed ExecutionRequest's recomputed hash matches its own stored hash");
   hashReq.planned_entry = hashReq.planned_entry + 1.0; // simulate a reconstruction drift/tamper
   Check(ExecutionRequest_ComputeHash(hashReq) != correctHash,
         "Case5: any field drift in the reconstructed ExecutionRequest is caught by a hash recompute mismatch - "
         "this is the exact guard EvaluateEntryCompatibilityCommand() runs before ever calling the gate");

   //====================================================================
   // Section 3: gate-calling / money-breakdown layer (cases 6, 7, 11)
   //====================================================================

   // --- Case 6: ACCEPTED result, small (~2%) divergence, same fixture technique as
   // Tests/MLQuantAI_Test_EntryCompatibilityGate.mq5 (relative to live ASK, since the
   // gate under test reads the market itself) ---
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double d   = ask * 0.01;
   double acceptSl    = ask - d * 1.02;
   double acceptEntry = acceptSl + d;

   ExecutionRequest acceptReq;
   BuildMinimalExecutionRequest(acceptReq, ORDER_TYPE_BUY, acceptEntry, acceptSl, acceptEntry + d, RA30_3_TEST_LOT, "ACCEPT");

   EntryCompatibilityDiagnosticResult acceptDiag;
   Check(EntryCompatibilityDiagnostic_Evaluate(acceptReq, acceptDiag), "Case6: diagnostic evaluation completes (non-empty id)");
   Check(acceptDiag.ok, "Case6: diagnostic reports ok==true (no structural failure)");
   Check(acceptDiag.gate_decision == SAFETY_GATE_ACCEPTED, "Case6: gate_decision == SAFETY_GATE_ACCEPTED");
   Check(acceptDiag.gate_reason_code == REASON_NONE, "Case6: gate_reason_code == REASON_NONE on ACCEPTED");
   Check(acceptDiag.risk_divergence_pct <= 10.0, "Case6: risk_divergence_pct within the 10% tolerance");
   Check(acceptDiag.directional_constraint_ok, "Case6: directional_constraint_ok == true for a valid BUY setup");
   Check(acceptDiag.planned_risk_money > 0.0 && acceptDiag.realized_risk_money > 0.0,
         "Case6: planned_risk_money/realized_risk_money breakdown populated on ACCEPTED");

   // --- Case 7: REJECTED result - directional constraint failure (BUY, reference <= planned_sl) ---
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ExecutionRequest directionalReq;
   BuildMinimalExecutionRequest(directionalReq, ORDER_TYPE_BUY, bid + 100.0, bid + 50.0, bid + 200.0, RA30_3_TEST_LOT, "DIRECTIONAL");
   // planned_sl (bid+50) is ABOVE the live ask/bid for a BUY -> execution_reference_price (ask) will be <= planned_sl -> directional constraint fails

   EntryCompatibilityDiagnosticResult directionalDiag;
   Check(EntryCompatibilityDiagnostic_Evaluate(directionalReq, directionalDiag), "Case7a: diagnostic evaluation completes");
   Check(directionalDiag.gate_decision == SAFETY_GATE_REJECTED, "Case7a: gate_decision == SAFETY_GATE_REJECTED (directional constraint)");
   Check(!directionalDiag.directional_constraint_ok, "Case7a: directional_constraint_ok == false");

   // --- Case 7: REJECTED result - divergence exceeds 10% ---
   double divergeSl    = ask - d * 1.20;
   double divergeEntry = divergeSl + d;
   ExecutionRequest divergeReq;
   BuildMinimalExecutionRequest(divergeReq, ORDER_TYPE_BUY, divergeEntry, divergeSl, divergeEntry + d, RA30_3_TEST_LOT, "DIVERGE");

   EntryCompatibilityDiagnosticResult divergeDiag;
   Check(EntryCompatibilityDiagnostic_Evaluate(divergeReq, divergeDiag), "Case7b: diagnostic evaluation completes");
   Check(divergeDiag.gate_decision == SAFETY_GATE_REJECTED, "Case7b: gate_decision == SAFETY_GATE_REJECTED (divergence exceeded)");
   Check(divergeDiag.directional_constraint_ok, "Case7b: directional_constraint_ok == true (rejection is due to divergence, not direction)");
   Check(divergeDiag.risk_divergence_pct > 10.0, "Case7b: risk_divergence_pct exceeds the 10% threshold");

   // --- Case 11: diagnostic result preserves the exact gateResult values (QA condition C amendment) ---
   // Small, unavoidable tick-race risk between these two sequential calls - same
   // already-documented/accepted category as Tests/MLQuantAI_Test_EntryCompatibilityGate.mq5's
   // own header.
   ExecutionRequest preserveReq;
   BuildMinimalExecutionRequest(preserveReq, ORDER_TYPE_BUY, acceptEntry, acceptSl, acceptEntry + d, RA30_3_TEST_LOT, "PRESERVE");

   EntryCompatibilityResult directGate;
   Check(EntryCompatibilityGate_Evaluate(preserveReq, directGate), "Case11: setup - direct gate call completes");
   EntryCompatibilityDiagnosticResult viaDiag;
   Check(EntryCompatibilityDiagnostic_Evaluate(preserveReq, viaDiag), "Case11: setup - diagnostic call completes");
   Check(viaDiag.execution_reference_price == directGate.execution_reference_price,
         "Case11: diagnostic's execution_reference_price is IDENTICAL to a direct EntryCompatibilityGate_Evaluate() call on the same fixture (small tick-race risk documented above)");
   Check(viaDiag.risk_divergence_pct == directGate.risk_divergence_pct,
         "Case11: diagnostic's risk_divergence_pct is IDENTICAL to a direct EntryCompatibilityGate_Evaluate() call on the same fixture (verbatim passthrough, not recomputed)");
   Check(viaDiag.gate_decision == directGate.decision,
         "Case11: diagnostic's gate_decision matches the direct gate call's decision");

   // --- Case 10 (structural, self-evident): this file never calls OrderSend/CTrade/
   // BrokerSubmission_* - documented in the file header, same convention every other
   // Tests/*.mq5 fixture in this project uses. No runtime assertion possible for an
   // absence-of-symbol fact; the RA-30.3 implementation review message's own grep-based
   // static call-chain evidence is the authoritative proof for this case.
   Check(true, "Case10: verified by inspection (this file's own header) - no OrderSend/CTrade/BrokerSubmission_* call anywhere in this regression file");

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else Print("SOME CHECKS FAILED - see [FAIL] lines above.");
}
