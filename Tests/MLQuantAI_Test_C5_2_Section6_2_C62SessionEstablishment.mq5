//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Section6_2_C62SessionEstablishment.mq5          |
//| §6.2 Evidence-Gate Design Contract Rev.8 §7.2/P4c: coverage of the    |
//| session marker tri-state (CheckSessionActiveMarker), the establishment  |
//| sequence (C62_EstablishSession), the clean-shutdown clearing rule         |
//| (C62_ClearSessionActiveMarkerOnCleanShutdown), and P4c's Safe-Mode-        |
//| ever-engaged-in-window + quarantine-witness helpers. Uses a real            |
//| EventStore file (EA_SESSION_STARTED/SAFE_MODE_ENGAGED/CLEARED must be         |
//| durably written for real). No OrderSend/CTrade anywhere in this file.          |
//|                                                                                   |
//| Not covered here: MARKER_CHECK_FAILED (a genuine FileIsExist() I/O error         |
//| distinct from "not found") - reproducing that deterministically would          |
//| require mocking file I/O, which this codebase's test convention does not      |
//| do; CheckSessionActiveMarker()'s CONFIRMED_ABSENT/CONFIRMED_PRESENT paths       |
//| are covered directly, and §7.2's own frozen rule (CHECK_FAILED treated          |
//| identically to PRESENT, never to ABSENT) is documented and enforced in the        |
//| production code's own switch statement, read and confirmed during Diff Review.    |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Infrastructure/EventStore/MLQuantAI_C62SessionEstablishment.mqh>

#define TEST_EVENT_STORE_FILE "MLQuantAI_Test_C6_2_C62SessionEstablishment.jsonl"

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
   Print("=== MLQuantAI_Test_C5_2_Section6_2_C62SessionEstablishment.mq5 ===");

   FileDelete(TEST_EVENT_STORE_FILE, FILE_COMMON);
   FileDelete(MLQUANTAI_SESSION_ACTIVE_FILENAME, FILE_COMMON);
   FileDelete(MLQUANTAI_SAFEMODE_WITNESS_FILENAME, FILE_COMMON);
   SafeMode_Clear();
   g_RolloutIntegrityFatalHalt = false;
   g_C62SessionEstablishmentResult = C62_SESSION_NOT_YET_ESTABLISHED;
   Check(EventStore_Open(TEST_EVENT_STORE_FILE), "setup: event store opens");

   //=====================================================================
   Print("--- marker genuinely absent -> CONFIRMED_ABSENT ---");
   {
      ENUM_MARKER_CHECK_RESULT r = CheckSessionActiveMarker();
      Check(r == MARKER_CONFIRMED_ABSENT, "result == MARKER_CONFIRMED_ABSENT");
   }

   //=====================================================================
   Print("--- C62_EstablishSession() with an absent marker: creates the marker, writes EA_SESSION_STARTED, -> ESTABLISHED ---");
   {
      ENUM_C62_SESSION_ESTABLISHMENT_RESULT r = C62_EstablishSession();
      Check(r == C62_SESSION_ESTABLISHED, "result == C62_SESSION_ESTABLISHED");
      Check(g_C62SessionEstablishmentResult == C62_SESSION_ESTABLISHED, "module global mirrors the return value");
      Check(C62SessionEstablishmentResult_PermitsEvaluation(g_C62SessionEstablishmentResult), "PermitsEvaluation(ESTABLISHED) == true");

      ENUM_MARKER_CHECK_RESULT markerAfter = CheckSessionActiveMarker();
      Check(markerAfter == MARKER_CONFIRMED_PRESENT, "the marker file now genuinely exists on disk");

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
      string sessionStartedType = EventTypeToString(EVENT_TYPE_EA_SESSION_STARTED);
      int count = 0;
      for(int i = 0; i < ArraySize(lines); i++)
         if(EventSerializer_GetStr(lines[i], "type") == sessionStartedType) count++;
      Check(count == 1, "exactly one durable EA_SESSION_STARTED line was written");
   }

   //=====================================================================
   Print("--- calling C62_EstablishSession() AGAIN without clearing the marker first -> SUSPENDED_UNCLEAN_PRIOR, no second EA_SESSION_STARTED ---");
   {
      ENUM_C62_SESSION_ESTABLISHMENT_RESULT r = C62_EstablishSession();
      Check(r == C62_SESSION_SUSPENDED_UNCLEAN_PRIOR, "result == C62_SESSION_SUSPENDED_UNCLEAN_PRIOR");
      Check(!C62SessionEstablishmentResult_PermitsEvaluation(r), "PermitsEvaluation(SUSPENDED_UNCLEAN_PRIOR) == false");

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
      string sessionStartedType = EventTypeToString(EVENT_TYPE_EA_SESSION_STARTED);
      int count = 0;
      for(int i = 0; i < ArraySize(lines); i++)
         if(EventSerializer_GetStr(lines[i], "type") == sessionStartedType) count++;
      Check(count == 1, "still exactly one EA_SESSION_STARTED line - the suspended attempt wrote nothing new");
   }

   //=====================================================================
   Print("--- C62_ClearSessionActiveMarkerOnCleanShutdown() with g_RolloutIntegrityFatalHalt == true is a deliberate NO-OP ---");
   {
      g_RolloutIntegrityFatalHalt = true;
      C62_ClearSessionActiveMarkerOnCleanShutdown();
      Check(CheckSessionActiveMarker() == MARKER_CONFIRMED_PRESENT, "marker is STILL present - an incident shutdown never clears it");
      g_RolloutIntegrityFatalHalt = false; // cleanup
   }

   //=====================================================================
   Print("--- C62_ClearSessionActiveMarkerOnCleanShutdown() with g_RolloutIntegrityFatalHalt == false clears it, restart can re-establish cleanly ---");
   {
      C62_ClearSessionActiveMarkerOnCleanShutdown();
      Check(CheckSessionActiveMarker() == MARKER_CONFIRMED_ABSENT, "marker is gone after an ordinary clean shutdown");

      ENUM_C62_SESSION_ESTABLISHMENT_RESULT r = C62_EstablishSession();
      Check(r == C62_SESSION_ESTABLISHED, "a fresh restart re-establishes cleanly");

      string lines[];
      EventStore_ReadAllLines(TEST_EVENT_STORE_FILE, lines);
      string sessionStartedType = EventTypeToString(EVENT_TYPE_EA_SESSION_STARTED);
      int count = 0;
      for(int i = 0; i < ArraySize(lines); i++)
         if(EventSerializer_GetStr(lines[i], "type") == sessionStartedType) count++;
      Check(count == 2, "a SECOND EA_SESSION_STARTED line now exists - one per real established session");
   }

   //=====================================================================
   Print("--- P4c: SafeModeProjection_ReplayEngagedDuringWindow - never engaged in-window -> false ---");
   {
      string lines[3];
      lines[0] = "{\"type\":\"SYSTEM_STARTED\"}"; // windowStartIndex itself
      lines[1] = "{\"type\":\"CANDIDATE_CREATED\"}";
      lines[2] = "{\"type\":\"EA_SESSION_STARTED\"}";
      bool everEngaged;
      SafeModeProjection_ReplayEngagedDuringWindow(lines, 0, everEngaged);
      Check(!everEngaged, "everEngaged == false - no SAFE_MODE_ENGAGED line in-window at all");
   }

   //=====================================================================
   Print("--- P4c: engaged strictly AT/BEFORE windowStartIndex (not after it) -> false, excluded from the window ---");
   {
      string lines[2];
      lines[0] = "{\"type\":\"SAFE_MODE_ENGAGED\"}"; // AT windowStartIndex itself - excluded
      lines[1] = "{\"type\":\"CANDIDATE_CREATED\"}";
      bool everEngaged;
      SafeModeProjection_ReplayEngagedDuringWindow(lines, 0, everEngaged);
      Check(!everEngaged, "everEngaged == false - the ENGAGED line sits at windowStartIndex, not strictly after it");
   }

   //=====================================================================
   Print("--- P4c: engaged in-window, later cleared in the SAME window -> STILL true ('ever engaged', not 'currently engaged') ---");
   {
      string lines[4];
      lines[0] = "{\"type\":\"SYSTEM_STARTED\"}";
      lines[1] = "{\"type\":\"SAFE_MODE_ENGAGED\"}";
      lines[2] = "{\"type\":\"SAFE_MODE_CLEARED\"}";
      lines[3] = "{\"type\":\"CANDIDATE_CREATED\"}";
      bool everEngaged;
      SafeModeProjection_ReplayEngagedDuringWindow(lines, 0, everEngaged);
      Check(everEngaged, "everEngaged == true even though a CLEARED line follows it in the same window - an episode that happened and was cleared still happened");
   }

   //=====================================================================
   Print("--- P4c: quarantine witness file - absent by default, present after SafeMode_WriteQuarantineWitness() ---");
   {
      Check(!SafeModeQuarantineWitness_Exists(), "witness absent before it is ever written");
      Check(SafeMode_WriteQuarantineWitness(), "SafeMode_WriteQuarantineWitness() succeeds");
      Check(SafeModeQuarantineWitness_Exists(), "witness now exists");
      FileDelete(MLQUANTAI_SAFEMODE_WITNESS_FILENAME, FILE_COMMON); // cleanup
      Check(!SafeModeQuarantineWitness_Exists(), "witness gone after manual cleanup (this checkpoint's §8 open item - a human-only ceremony, simulated here by a direct delete)");
   }

   EventStore_Close();
   FileDelete(MLQUANTAI_SESSION_ACTIVE_FILENAME, FILE_COMMON); // leave no marker behind for other test scripts in the same run

   Print("=== Result: ", g_TestsPassed, "/", g_TestsRun, " checks passed ===");
   if(g_TestsPassed == g_TestsRun) Print("ALL PASS.");
   else                            Print("SOME FAILED - see [FAIL] lines above.");
}
