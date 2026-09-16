//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Commit2_CeremonyCommandTypes.mq5                 |
//| C5.2 Commit 2 (QA-frozen Design Revision 2, Docs/PhaseC_C5_2_Commit2_ |
//| RuntimeIntegrationDesignContract.md §D): proves the 3 new              |
//| ENUM_CEREMONY_COMMAND_TYPE values and the 3 new ENUM_CEREMONY_COMMAND_   |
//| STATE terminal values round-trip correctly (ToString/FromString), that    |
//| the 3 new states are correctly classified terminal, and that the new       |
//| CeremonyCommand request/result fields (c52_target_rollout_stage/            |
//| c52_evidence_reference/c52_operator_identity/c52_result_rollout_stage_       |
//| after) survive a ToJson/FromJson round-trip without disturbing any            |
//| pre-existing field. Same isolation convention as                               |
//| Tests/MLQuantAI_Test_RA31_CeremonyCommandProtocol.mq5 - no OrderSend            |
//| anywhere in this file, running on a real account is safe.                        |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_CeremonyCommandEventEmission.mqh>

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

void OnStart()
{
   Print("=== MLQuantAI_Test_C5_2_Commit2_CeremonyCommandTypes.mq5 ===");

   //=====================================================================
   // 1. ENUM_CEREMONY_COMMAND_TYPE round-trip for the 3 new values.
   //=====================================================================
   Print("--- CeremonyCommandType_ToString/FromString round-trip ---");
   Check(CeremonyCommandType_ToString(CEREMONY_COMMAND_TYPE_TRANSITION_ROLLOUT_STAGE) == "TRANSITION_ROLLOUT_STAGE", "TRANSITION_ROLLOUT_STAGE -> string");
   Check(CeremonyCommandType_FromString("TRANSITION_ROLLOUT_STAGE") == CEREMONY_COMMAND_TYPE_TRANSITION_ROLLOUT_STAGE, "string -> TRANSITION_ROLLOUT_STAGE");
   Check(CeremonyCommandType_ToString(CEREMONY_COMMAND_TYPE_ENGAGE_KILL_SWITCH) == "ENGAGE_KILL_SWITCH", "ENGAGE_KILL_SWITCH -> string");
   Check(CeremonyCommandType_FromString("ENGAGE_KILL_SWITCH") == CEREMONY_COMMAND_TYPE_ENGAGE_KILL_SWITCH, "string -> ENGAGE_KILL_SWITCH");
   Check(CeremonyCommandType_ToString(CEREMONY_COMMAND_TYPE_CLEAR_KILL_SWITCH) == "CLEAR_KILL_SWITCH", "CLEAR_KILL_SWITCH -> string");
   Check(CeremonyCommandType_FromString("CLEAR_KILL_SWITCH") == CEREMONY_COMMAND_TYPE_CLEAR_KILL_SWITCH, "string -> CLEAR_KILL_SWITCH");
   Check(CeremonyCommandType_FromString("not_a_real_type") == CEREMONY_COMMAND_TYPE_UNKNOWN, "unrecognized string -> UNKNOWN, fail-closed");

   //=====================================================================
   // 2. ENUM_CEREMONY_COMMAND_STATE round-trip for the 3 new values.
   //=====================================================================
   Print("--- CeremonyCommandState_ToString/FromString round-trip ---");
   Check(CeremonyCommandState_ToString(CEREMONY_STATE_ROLLOUT_STAGE_TRANSITIONED) == "ROLLOUT_STAGE_TRANSITIONED", "ROLLOUT_STAGE_TRANSITIONED -> string");
   Check(CeremonyCommandState_FromString("ROLLOUT_STAGE_TRANSITIONED") == CEREMONY_STATE_ROLLOUT_STAGE_TRANSITIONED, "string -> ROLLOUT_STAGE_TRANSITIONED");
   Check(CeremonyCommandState_ToString(CEREMONY_STATE_KILL_SWITCH_ENGAGED) == "KILL_SWITCH_ENGAGED", "KILL_SWITCH_ENGAGED -> string");
   Check(CeremonyCommandState_FromString("KILL_SWITCH_ENGAGED") == CEREMONY_STATE_KILL_SWITCH_ENGAGED, "string -> KILL_SWITCH_ENGAGED");
   Check(CeremonyCommandState_ToString(CEREMONY_STATE_KILL_SWITCH_CLEARED) == "KILL_SWITCH_CLEARED", "KILL_SWITCH_CLEARED -> string");
   Check(CeremonyCommandState_FromString("KILL_SWITCH_CLEARED") == CEREMONY_STATE_KILL_SWITCH_CLEARED, "string -> KILL_SWITCH_CLEARED");

   //=====================================================================
   // 3. Terminal-state classification: all 3 new states must be terminal
   //    (each is reached directly from CEREMONY_IN_PROGRESS and is a final
   //    outcome, matching CEREMONY_STATE_OUTCOME_RECORDED/_APPROVAL_
   //    RECORDED/_ENTRY_COMPATIBILITY_EVALUATED's own precedent).
   //=====================================================================
   Print("--- CeremonyCommandState_IsTerminal: all 3 new states are terminal ---");
   Check(CeremonyCommandState_IsTerminal(CEREMONY_STATE_ROLLOUT_STAGE_TRANSITIONED) == true, "ROLLOUT_STAGE_TRANSITIONED is terminal");
   Check(CeremonyCommandState_IsTerminal(CEREMONY_STATE_KILL_SWITCH_ENGAGED) == true, "KILL_SWITCH_ENGAGED is terminal");
   Check(CeremonyCommandState_IsTerminal(CEREMONY_STATE_KILL_SWITCH_CLEARED) == true, "KILL_SWITCH_CLEARED is terminal");
   // Non-terminal precedent unaffected:
   Check(CeremonyCommandState_IsTerminal(CEREMONY_STATE_CEREMONY_IN_PROGRESS) == false, "CEREMONY_IN_PROGRESS remains non-terminal, unaffected by this addition");

   //=====================================================================
   // 4. CeremonyCommand ToJson/FromJson round-trip - the new fields
   //    survive, and no pre-existing field is disturbed.
   //=====================================================================
   Print("--- CeremonyCommand_ToJson/FromJson round-trip preserves the 4 new C5.2 fields ---");
   {
      CeremonyCommand cmd;
      CeremonyCommand_Init(cmd);
      cmd.command_id                    = "CMD_c52_test_1";
      cmd.command_type                  = CEREMONY_COMMAND_TYPE_TRANSITION_ROLLOUT_STAGE;
      cmd.command_sequence               = 1.0;
      cmd.expected_ea_binding_nonce      = 42.0;
      cmd.expected_eventstore_filename   = "MLQuantAI_Test_c52.jsonl";
      cmd.c52_target_rollout_stage       = "DEMO_DRY_RUN";
      cmd.c52_evidence_reference         = "manual_review_2026_09_16";
      cmd.c52_operator_identity          = "qa_operator";
      cmd.mailbox_status                 = CEREMONY_MAILBOX_STATUS_PENDING;

      string json = CeremonyCommand_ToJson(cmd);
      CeremonyCommand roundTrip;
      CeremonyCommand_FromJson(json, roundTrip);

      Check(roundTrip.command_id == cmd.command_id, "command_id survives round-trip");
      Check(roundTrip.command_type == CEREMONY_COMMAND_TYPE_TRANSITION_ROLLOUT_STAGE, "command_type survives round-trip");
      Check(roundTrip.c52_target_rollout_stage == "DEMO_DRY_RUN", "c52_target_rollout_stage survives round-trip");
      Check(roundTrip.c52_evidence_reference == "manual_review_2026_09_16", "c52_evidence_reference survives round-trip");
      Check(roundTrip.c52_operator_identity == "qa_operator", "c52_operator_identity survives round-trip");

      // Pre-existing fields, untouched by this addition, still round-trip correctly.
      Check(roundTrip.expected_ea_binding_nonce == 42.0, "pre-existing field expected_ea_binding_nonce unaffected");
      Check(roundTrip.expected_eventstore_filename == "MLQuantAI_Test_c52.jsonl", "pre-existing field expected_eventstore_filename unaffected");
   }

   //=====================================================================
   // 5. Result-side field: c52_result_rollout_stage_after round-trips too.
   //=====================================================================
   Print("--- c52_result_rollout_stage_after survives round-trip ---");
   {
      CeremonyCommand cmd;
      CeremonyCommand_Init(cmd);
      cmd.command_id = "CMD_c52_test_2";
      cmd.c52_result_rollout_stage_after = "DEMO_BOUNDED_AUTOMATION";

      string json = CeremonyCommand_ToJson(cmd);
      CeremonyCommand roundTrip;
      CeremonyCommand_FromJson(json, roundTrip);
      Check(roundTrip.c52_result_rollout_stage_after == "DEMO_BOUNDED_AUTOMATION", "c52_result_rollout_stage_after survives round-trip");
   }

   //=====================================================================
   // 6. CeremonyCommand_Init leaves all 4 new fields empty (fail-closed
   //    default, matching every other string field's own Init default).
   //=====================================================================
   Print("--- CeremonyCommand_Init: all 4 new fields default to empty ---");
   {
      CeremonyCommand cmd;
      CeremonyCommand_Init(cmd);
      Check(cmd.c52_target_rollout_stage == "", "c52_target_rollout_stage defaults to empty");
      Check(cmd.c52_evidence_reference == "", "c52_evidence_reference defaults to empty");
      Check(cmd.c52_operator_identity == "", "c52_operator_identity defaults to empty");
      Check(cmd.c52_result_rollout_stage_after == "", "c52_result_rollout_stage_after defaults to empty");
   }

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
