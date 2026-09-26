//+------------------------------------------------------------------+
//| MLQuantAI_Test_C5_2_Section6_3_R15A_ProvenanceAdmissibility.mq5   |
//| C5.2 §6.3 Design Contract Rev.15 (FROZEN, commit 07a3581),          |
//| implementation slice R15-A:                                         |
//|   A  frozen policy values (R1-R8; _Symbol is the runtime value)      |
//|   B  PROV-1 reader, pure (CASE A / CASE B, counted k, exact tokens) |
//|   C  PROV-1 on REAL lines written by the sealed writers              |
//|   D  step 1b AUTOMATION_EXHAUSTED (TC-01..TC-05)                     |
//|   E  static ADMISSIBLE(X) (TC-07..TC-16)                             |
//|   F  amended R16 scan order + R15 halt (TC-17..TC-20)                |
//|                                                                    |
//| Every check runs unconditionally (no setup-only Check(false)), and   |
//| every result is stored before Check() so labels show the current     |
//| call. No mailbox write, no OrderSend/CTrade/C2 gate in this file.    |
//| Writes only its own isolated EventStore fixture files.               |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_BoundedAutomationDiscovery.mqh>

#define R15A_READY_FILE "MLQuantAI_Test_C63_R15A_Ready.jsonl"
#define R15A_REAL_FILE  "MLQuantAI_Test_C63_R15A_Real.jsonl"

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

//--- handcrafted snapshot lines (the reader only needs these keys) ---
string StageLine(string ts, string toStage)
{
   return "{\"ts\":\"" + ts + "\",\"type\":\"EXECUTION_ROLLOUT_STAGE_CHANGED\",\"to_stage\":\"" + toStage + "\"}";
}

string E1Line(string ts, string erid, string provenanceFragment)
{
   return "{\"ts\":\"" + ts + "\",\"type\":\"CEREMONY_COMMAND_STATE_CHANGED\",\"command_type\":\"SUBMIT_ORDER\","
          "\"to_state\":\"SUBMISSION_IN_PROGRESS\",\"execution_request_id\":\"" + erid + "\"" + provenanceFragment + "}";
}

string E2Line(string erid)
{
   return "{\"ts\":\"2026.06.01 11:30:00\",\"type\":\"EXECUTION_SUBMISSION_ATTEMPTED\",\"execution_request_id\":\"" + erid + "\"}";
}

string C22Line(string erid)
{
   return "{\"ts\":\"2026.06.01 09:00:00\",\"type\":\"CEREMONY_COMMAND_STATE_CHANGED\",\"command_type\":\"RUN_C22_CEREMONY_FIXTURE\","
          "\"to_state\":\"CEREMONY_READY\",\"execution_request_id\":\"" + erid + "\"}";
}

#define PROV_AUTO  ",\"submission_provenance\":\"SYSTEM_BOUNDED_AUTOMATION_V1\""
#define PROV_HUMAN ",\"submission_provenance\":\"HUMAN\""

void Push(string &arr[], string line)
{
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n] = line;
}

//--- synthetic projection records ---
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

void AddRequestOnly(string erid)
{
   ExecutionRequestProjectionRecord rec;
   MakeRequestRecord(erid, rec);
   ExecutionRequestProjection_AppendRecord(rec);
}

void AddDryRun(string erid, ENUM_SAFETY_GATE_DECISION decision, string symbol)
{
   DryRunResultProjectionRecord dr;
   DryRunResultProjectionRecord_Init(dr);
   dr.execution_request_id   = erid;
   dr.execution_request_hash = "HASH_" + erid;
   dr.decision               = decision;
   dr.observed_symbol        = symbol;
   DryRunResultProjection_AppendRecord(dr);
}

// admissible request: record + one ACCEPTED dry-run for the runtime _Symbol
void AddAdmissible(string erid)
{
   AddRequestOnly(erid);
   AddDryRun(erid, SAFETY_GATE_ACCEPTED, _Symbol);
}

void AddCandidate(string candidateId, int strategyId)
{
   int n = g_CandProj_Count;
   ArrayResize(g_CandProj_Records, n + 1);
   CandidateProjectionRecord_Init(g_CandProj_Records[n]);
   g_CandProj_Records[n].candidate_id = candidateId;
   g_CandProj_Records[n].strategy_id  = strategyId;
   g_CandProj_Count = n + 1;
}

bool ResetAll()
{
   ManualApprovalProjectionReport r = ManualApproval_StartupRebuild(R15A_READY_FILE);
   ExecutionRequestProjection_Reset();
   DryRunResultProjection_Reset();
   ManualApprovalProjection_Reset();
   CandidateProjection_Reset();
   return r.ok && ManualApprovalReadiness_IsReady();
}

void MakeFreeMailbox(BoundedAutomationMailboxSnapshot &out)
{
   out.present = false;
   CeremonyCommand_Init(out.command);
}

string Describe(const BoundedAutomationSelection &s)
{
   return StringFormat("outcome=%s index=%d scanned=%d skipped(inadm=%d,issued=%d,exhausted=%d) erid='%s' detail='%s'",
                       BoundedAutomationDiscoveryOutcome_ToString(s.outcome), s.selected_index, s.candidates_scanned,
                       s.skipped_inadmissible, s.skipped_submission_issued, s.skipped_automation_exhausted,
                       s.selected_request.execution_request_id, s.detail);
}

void OnStart()
{
   Print("=== MLQuantAI_Test_C5_2_Section6_3_R15A_ProvenanceAdmissibility.mq5 ===");
   Print("*** Classification/discovery only - nothing is issued, no mailbox write. ***");

   DeleteFixture(R15A_READY_FILE);
   DeleteFixture(R15A_REAL_FILE);
   ArrayResize(g_CeremonyCommandRegistry, 0);

   bool readyFixture = EventStore_Open(R15A_READY_FILE);
   if(readyFixture)
   {
      EventStore_LogSystem(EventTypeToString(EVENT_TYPE_SYSTEM_STARTED), "r15a readiness fixture");
      EventStore_Close();
   }

   //=====================================================================
   Print("--- A. frozen policy values ---");
   {
      BoundedAutomationPolicy p;
      BoundedAutomationPolicy_InitFrozen(p);
      Check(p.max_lot_size_per_submission == 0.01 && p.max_daily_volume_lots == 0.05 && p.max_submissions_per_day == 3
            && p.min_seconds_between_submissions == 3600 && p.max_concurrent_open_risk_percent == 2.0
            && p.max_concurrent_open_positions == 2,
            "R2-R7 ratified values");
      Check(p.symbol_allowlist == _Symbol && _Symbol != "" && p.symbol_allowlist != "_Symbol",
            "R8 symbol_allowlist is the runtime _Symbol ('" + p.symbol_allowlist + "'), not the text \"_Symbol\"");
      Check(p.strategy_allowlist == "" && p.session_window_server_time == "" && p.day_of_week_allowlist == "",
            "R8 strategy/session/day values are empty (contract field names)");
      Check(p.bounded_automation_policy_version == "BOUNDEDAUTO_C6_3_V1" && MLQUANTAI_BOUNDED_AUTOMATION_P1_MIN_CANDIDATES == 5,
            "policy version + R1 N = 5");
      Check(MLQUANTAI_RESERVED_FIXTURE_EXECUTION_POLICY_VERSION == "EXECPOLICY_C2_SMOKE_V1",
            "M1 reserved literal == sealed RUN_C22 literal");
   }

   //=====================================================================
   Print("--- B. PROV-1 reader, pure ---");
   {
      string cutLines[];
      Push(cutLines, StageLine("2026.06.01 09:00:00", "DEMO_REAL_SUBMIT"));
      Push(cutLines, StageLine("2026.06.01 10:00:00", "DEMO_BOUNDED_AUTOMATION"));
      Push(cutLines, StageLine("2026.06.01 11:00:00", "DEMO_BOUNDED_AUTOMATION"));
      BoundedAutomationProvenanceCutoff cut;
      BoundedAutomation_FindProvenanceCutoff(cutLines, cut);
      Check(cut.found && cut.line_index == 1 && cut.ts == D'2026.06.01 10:00:00',
            StringFormat("cutoff = FIRST-ever to_stage DEMO_BOUNDED_AUTOMATION (index=%d)", cut.line_index));

      string none[];
      Push(none, StageLine("2026.06.01 09:00:00", "DEMO_REAL_SUBMIT"));
      BoundedAutomationProvenanceCutoff noCut;
      BoundedAutomation_FindProvenanceCutoff(none, noCut);
      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c0 = BoundedAutomation_ClassifyE1(E1Line("2026.06.01 12:00:00", "ER_B", ""), noCut);
      Check(!noCut.found && c0 == BOUNDED_AUTOMATION_E1_PROVENANCE_PRE_MECHANISM,
            "no cutoff in snapshot -> PRE_MECHANISM (" + BoundedAutomationE1Provenance_ToString(c0) + ")");

      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c1 = BoundedAutomation_ClassifyE1(E1Line("2026.06.01 09:59:59", "ER_B", PROV_AUTO), cut);
      Check(c1 == BOUNDED_AUTOMATION_E1_PROVENANCE_PRE_MECHANISM, "CASE A: earlier than cutoff -> PRE_MECHANISM even with the AUTOMATION token (TC-03)");

      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c2 = BoundedAutomation_ClassifyE1(E1Line("2026.06.01 10:00:00", "ER_B", PROV_AUTO), cut);
      Check(c2 == BOUNDED_AUTOMATION_E1_PROVENANCE_AUTOMATION, "same second as cutoff is not earlier -> CASE B -> AUTOMATION");

      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c3 = BoundedAutomation_ClassifyE1(E1Line("2026.06.01 12:00:00", "ER_B", PROV_HUMAN), cut);
      Check(c3 == BOUNDED_AUTOMATION_E1_PROVENANCE_HUMAN, "k==1 HUMAN -> HUMAN");

      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c4 = BoundedAutomation_ClassifyE1(E1Line("2026.06.01 12:00:00", "ER_B", ""), cut);
      Check(c4 == BOUNDED_AUTOMATION_E1_PROVENANCE_INVALID, "missing key (k==0) -> INVALID");

      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c5 = BoundedAutomation_ClassifyE1(E1Line("2026.06.01 12:00:00", "ER_B", PROV_AUTO + PROV_AUTO), cut);
      Check(c5 == BOUNDED_AUTOMATION_E1_PROVENANCE_INVALID, "duplicate key (k==2, same token) -> INVALID (HasKey-only would accept) (TC-04)");

      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c6 = BoundedAutomation_ClassifyE1(
         E1Line("2026.06.01 12:00:00", "ER_B", ",\"submission_provenance\":\"SYSTEM_BOUNDED_AUTOMATION_V2\""), cut);
      Check(c6 == BOUNDED_AUTOMATION_E1_PROVENANCE_INVALID, "other token value -> INVALID");

      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c7 = BoundedAutomation_ClassifyE1(
         E1Line("2026.06.01 12:00:00", "ER_B", ",\"submission_provenance\":\"\""), cut);
      Check(c7 == BOUNDED_AUTOMATION_E1_PROVENANCE_INVALID, "empty value -> INVALID");

      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c8 = BoundedAutomation_ClassifyE1(
         E1Line("2026.06.01 12:00:00", "ER_B", ",\"reason\":\"SYSTEM_BOUNDED_AUTOMATION_V1\""), cut);
      Check(c8 == BOUNDED_AUTOMATION_E1_PROVENANCE_INVALID, "token only inside another field, no key -> INVALID (TC-06)");

      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c9 = BoundedAutomation_ClassifyE1(E1Line("2026.06.01 12:00:00", "", PROV_AUTO), cut);
      Check(c9 == BOUNDED_AUTOMATION_E1_PROVENANCE_INVALID, "empty execution_request_id -> INVALID");

      // An unparsable ts must never PROVE "earlier". What StringToTime("")
      // returns is platform behaviour, so the expectation is derived from it:
      // CASE A only if it parsed to a positive time before the cutoff.
      datetime parsedEmpty = StringToTime("");
      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c10 = BoundedAutomation_ClassifyE1(E1Line("", "ER_B", PROV_AUTO), cut);
      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE c10Expected = (parsedEmpty > 0 && parsedEmpty < cut.ts)
                                                           ? BOUNDED_AUTOMATION_E1_PROVENANCE_PRE_MECHANISM
                                                           : BOUNDED_AUTOMATION_E1_PROVENANCE_AUTOMATION;
      Check(c10 == c10Expected,
            StringFormat("empty E1 ts (StringToTime(\"\")=%I64d) never proves CASE A unless it parses before the cutoff -> %s",
                         (long)parsedEmpty, BoundedAutomationE1Provenance_ToString(c10)));

      bool ready = ResetAll();
      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE l1 = BoundedAutomation_ClassifyE1WithLookup(E1Line("2026.06.01 12:00:00", "ER_B_NOREC", PROV_AUTO), cut);
      AddRequestOnly("ER_B_REC");
      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE l2 = BoundedAutomation_ClassifyE1WithLookup(E1Line("2026.06.01 12:00:00", "ER_B_REC", PROV_AUTO), cut);
      ENUM_BOUNDED_AUTOMATION_E1_PROVENANCE l3 = BoundedAutomation_ClassifyE1WithLookup(E1Line("2026.06.01 12:00:00", "ER_B_NOREC", PROV_HUMAN), cut);
      Check(ready && l1 == BOUNDED_AUTOMATION_E1_PROVENANCE_INVALID && l2 == BOUNDED_AUTOMATION_E1_PROVENANCE_AUTOMATION
            && l3 == BOUNDED_AUTOMATION_E1_PROVENANCE_HUMAN,
            "lookup rule: AUTOMATION with no request record -> INVALID; with record -> AUTOMATION; HUMAN needs no lookup");

      int k1 = BoundedAutomation_CountOccurrences("a\"submission_provenance\":b\"submission_provenance\":", MLQUANTAI_E1_PROVENANCE_KEY_NEEDLE);
      int k2 = BoundedAutomation_CountOccurrences("\\\"submission_provenance\\\":\"x\"", MLQUANTAI_E1_PROVENANCE_KEY_NEEDLE);
      Check(k1 == 2 && k2 == 0, StringFormat("k counts exact key occurrences (k1=%d, escaped-in-value k2=%d)", k1, k2));
   }

   //=====================================================================
   Print("--- C. PROV-1 on REAL lines from the sealed writers ---");
   {
      bool ready = ResetAll();
      AddRequestOnly("ER_R15A_REAL_AUTO");
      bool opened = EventStore_Open(R15A_REAL_FILE);
      bool w1 = false, w2 = false, w3 = false;
      if(opened)
      {
         w1 = EventStore_LogSystem(EventTypeToString(EVENT_TYPE_EXECUTION_ROLLOUT_STAGE_CHANGED), "r15a stage fixture",
                                   "\"to_stage\":\"" + ExecutionRolloutStageToString(ROLLOUT_STAGE_DEMO_BOUNDED_AUTOMATION) + "\"");
         w2 = EventStore_LogCeremonyCommandState("CMD_R15A_AUTO", CEREMONY_COMMAND_TYPE_SUBMIT_ORDER,
                                                 CEREMONY_STATE_COMMAND_RECEIVED, CEREMONY_STATE_SUBMISSION_IN_PROGRESS,
                                                 "submitting", "ER_R15A_REAL_AUTO",
                                                 "\"submission_provenance\":\"" + MLQUANTAI_RESERVED_SYSTEM_AUTOMATION_IDENTITY + "\"");
         w3 = EventStore_LogCeremonyCommandState("CMD_R15A_HUMAN", CEREMONY_COMMAND_TYPE_SUBMIT_ORDER,
                                                 CEREMONY_STATE_COMMAND_RECEIVED, CEREMONY_STATE_SUBMISSION_IN_PROGRESS,
                                                 "submitting", "ER_R15A_REAL_HUMAN", "\"submission_provenance\":\"HUMAN\"");
         EventStore_Close();
      }
      string lines[];
      string err;
      bool valid = BoundedAutomation_ReadValidatedSnapshot(R15A_REAL_FILE, lines, err);
      BoundedAutomationProvenanceScan scan;
      BoundedAutomation_ScanProvenance(lines, scan);
      Check(ready && opened && w1 && w2 && w3 && valid && ArraySize(lines) == 3,
            StringFormat("real fixture: 3 validated lines (lines=%d, err='%s')", ArraySize(lines), err));
      Check(scan.cutoff.found && scan.e1_lines == 2 && scan.automation == 1 && scan.human == 1 && scan.invalid == 0,
            StringFormat("real serialization: cutoff found, E1=%d AUTOMATION=%d HUMAN=%d INVALID=%d",
                         scan.e1_lines, scan.automation, scan.human, scan.invalid));
      ENUM_BOUNDED_AUTOMATION_REQUEST_E1_STATUS st = BoundedAutomation_RequestE1Status(lines, "ER_R15A_REAL_AUTO");
      Check(st == BOUNDED_AUTOMATION_REQUEST_E1_EXHAUSTED, "real AUTOMATION E1 -> request EXHAUSTED");
   }

   //=====================================================================
   Print("--- D. step 1b AUTOMATION_EXHAUSTED ---");
   {
      BoundedAutomationMailboxSnapshot mbFree;
      MakeFreeMailbox(mbFree);
      BoundedAutomationMailboxSnapshot mbBusy;
      mbBusy.present = true;
      CeremonyCommand_Init(mbBusy.command);
      mbBusy.command.mailbox_status = CEREMONY_MAILBOX_STATUS_PENDING;
      mbBusy.command.command_type   = CEREMONY_COMMAND_TYPE_GRANT_MANUAL_APPROVAL;
      mbBusy.command.target_execution_request_id = "ER_OTHER";

      ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE p1 = BoundedAutomation_DeriveCandidateState(false, true, mbFree, "ER_D", true);
      ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE p2 = BoundedAutomation_DeriveCandidateState(true, true, mbFree, "ER_D", true);
      ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE p3 = BoundedAutomation_DeriveCandidateState(false, true, mbBusy, "ER_D", false);
      ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE p4 = BoundedAutomation_DeriveCandidateState(false, false, mbFree, "ER_D", true);
      Check(p1 == BOUNDED_AUTOMATION_STATE_AUTOMATION_EXHAUSTED && p2 == BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED
            && p3 == BOUNDED_AUTOMATION_STATE_AUTOMATION_EXHAUSTED && p4 == BOUNDED_AUTOMATION_STATE_APPROVED_NOT_SUBMITTED,
            "pure order: step 1 (E2) > step 1b (exhausted) > step 2 (mailbox) > step 3");
      ENUM_CEREMONY_COMMAND_TYPE issued;
      bool issues = BoundedAutomation_StateIssuesCommand(BOUNDED_AUTOMATION_STATE_AUTOMATION_EXHAUSTED, issued);
      Check(!issues && issued == CEREMONY_COMMAND_TYPE_UNKNOWN, "AUTOMATION_EXHAUSTED issues nothing");

      bool ready = ResetAll();
      AddRequestOnly("ER_D_AUTO");
      AddRequestOnly("ER_D_HUMAN");
      AddRequestOnly("ER_D_PRE");
      AddRequestOnly("ER_D_DUP");
      AddRequestOnly("ER_D_BOTH");
      string lines[];
      Push(lines, E1Line("2026.06.01 08:00:00", "ER_D_PRE", PROV_AUTO));          // pre-cutoff
      Push(lines, StageLine("2026.06.01 10:00:00", "DEMO_BOUNDED_AUTOMATION"));     // cutoff
      Push(lines, E1Line("2026.06.01 10:30:00", "ER_D_AUTO", PROV_AUTO));
      Push(lines, E1Line("2026.06.01 10:30:00", "ER_D_HUMAN", PROV_HUMAN));
      Push(lines, E1Line("2026.06.01 10:30:00", "ER_D_DUP", PROV_AUTO + PROV_AUTO));
      Push(lines, E1Line("2026.06.01 10:30:00", "ER_D_BOTH", PROV_AUTO));
      Push(lines, E2Line("ER_D_BOTH"));

      ExecutionRequestProjectionRecord rAuto, rHuman, rPre, rDup, rBoth;
      MakeRequestRecord("ER_D_AUTO", rAuto);
      MakeRequestRecord("ER_D_HUMAN", rHuman);
      MakeRequestRecord("ER_D_PRE", rPre);
      MakeRequestRecord("ER_D_DUP", rDup);
      MakeRequestRecord("ER_D_BOTH", rBoth);

      ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE sAuto  = BoundedAutomation_EvaluateCandidateState(lines, mbFree, rAuto, g_AsOf);
      ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE sHuman = BoundedAutomation_EvaluateCandidateState(lines, mbFree, rHuman, g_AsOf);
      ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE sPre   = BoundedAutomation_EvaluateCandidateState(lines, mbFree, rPre, g_AsOf);
      ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE sDup   = BoundedAutomation_EvaluateCandidateState(lines, mbFree, rDup, g_AsOf);
      ENUM_BOUNDED_AUTOMATION_CANDIDATE_STATE sBoth  = BoundedAutomation_EvaluateCandidateState(lines, mbFree, rBoth, g_AsOf);
      Check(ready && sAuto == BOUNDED_AUTOMATION_STATE_AUTOMATION_EXHAUSTED,
            "TC-01 automation E1, no E2 -> " + BoundedAutomationCandidateState_ToString(sAuto));
      Check(sHuman == BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED,
            "TC-02 human E1, no E2 -> not exhausted (" + BoundedAutomationCandidateState_ToString(sHuman) + ") - human path not blocked");
      Check(sPre == BOUNDED_AUTOMATION_STATE_NOT_YET_APPROVED,
            "TC-03 pre-cutoff automation-token E1 -> not exhausted (" + BoundedAutomationCandidateState_ToString(sPre) + ")");
      Check(sDup == BOUNDED_AUTOMATION_STATE_UNKNOWN,
            "TC-04 duplicated key -> INVALID -> fail closed (" + BoundedAutomationCandidateState_ToString(sDup) + ")");
      Check(sBoth == BOUNDED_AUTOMATION_STATE_SUBMISSION_ISSUED,
            "TC-05 automation E1 + E2 -> SUBMISSION_ISSUED (" + BoundedAutomationCandidateState_ToString(sBoth) + ")");
   }

   //=====================================================================
   Print("--- E. static ADMISSIBLE(X) ---");
   {
      bool ready = ResetAll();
      BoundedAutomationPolicy frozen;
      BoundedAutomationPolicy_InitFrozen(frozen);
      string lines[];
      Push(lines, C22Line("ER_E_M2"));
      Push(lines, C22Line(""));   // RUN_C22 line with an empty id must not mark anyone

      ExecutionRequestProjectionRecord r;

      MakeRequestRecord("ER_E_NODR", r);
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a1 = BoundedAutomation_CheckAdmissible(r, lines, frozen);
      Check(ready && a1 == BOUNDED_AUTOMATION_INADMISSIBLE_NO_DRY_RUN_RECORD, "TC-07 no dry-run record -> " + BoundedAutomationAdmissibility_ToString(a1));

      AddDryRun("ER_E_MIX", SAFETY_GATE_ACCEPTED, _Symbol);
      AddDryRun("ER_E_MIX", SAFETY_GATE_REJECTED, _Symbol);
      MakeRequestRecord("ER_E_MIX", r);
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a2 = BoundedAutomation_CheckAdmissible(r, lines, frozen);
      Check(a2 == BOUNDED_AUTOMATION_INADMISSIBLE_DRY_RUN_NOT_ACCEPTED, "TC-08 ACCEPTED + REJECTED records -> " + BoundedAutomationAdmissibility_ToString(a2));

      AddDryRun("ER_E_LOT", SAFETY_GATE_ACCEPTED, _Symbol);
      MakeRequestRecord("ER_E_LOT", r);
      r.lot_size = 0.02;
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a3 = BoundedAutomation_CheckAdmissible(r, lines, frozen);
      r.lot_size = 0.01;
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a3b = BoundedAutomation_CheckAdmissible(r, lines, frozen);
      Check(a3 == BOUNDED_AUTOMATION_INADMISSIBLE_LOT_ABOVE_MAX && a3b == BOUNDED_AUTOMATION_ADMISSIBLE,
            "TC-09 lot 0.02 -> " + BoundedAutomationAdmissibility_ToString(a3) + "; lot 0.01 (boundary) -> " + BoundedAutomationAdmissibility_ToString(a3b));

      // P-c: R2 is a hard ceiling - a value only 1e-10 above 0.01 (inside
      // the old 1e-9 tolerance window) must be rejected.
      r.lot_size = 0.0100000001;
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a3c = BoundedAutomation_CheckAdmissible(r, lines, frozen);
      Check(a3c == BOUNDED_AUTOMATION_INADMISSIBLE_LOT_ABOVE_MAX,
            "TC-09b lot 0.0100000001 -> " + BoundedAutomationAdmissibility_ToString(a3c) + " (no tolerance above the R2 ceiling)");

      // P-c: 0.01 as it arrives from a real line - sealed writer format
      // (CanonicalDouble) read back through the sealed EventSerializer_GetDouble
      // the projection uses - is not falsely rejected by the exact comparison.
      string lotLine = "{\"lot_size\":" + CanonicalDouble(0.01) + ",\"x\":1}";
      r.lot_size = EventSerializer_GetDouble(lotLine, "lot_size");
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a3d = BoundedAutomation_CheckAdmissible(r, lines, frozen);
      Check(a3d == BOUNDED_AUTOMATION_ADMISSIBLE,
            "TC-09c lot parsed from line '" + lotLine + "' (" + DoubleToString(r.lot_size, 17) + ") -> " + BoundedAutomationAdmissibility_ToString(a3d));
      r.lot_size = 0.01;

      AddDryRun("ER_E_SYM", SAFETY_GATE_ACCEPTED, _Symbol + "_OTHER");
      MakeRequestRecord("ER_E_SYM", r);
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a4 = BoundedAutomation_CheckAdmissible(r, lines, frozen);
      Check(a4 == BOUNDED_AUTOMATION_INADMISSIBLE_SYMBOL_NOT_ALLOWED, "TC-10 observed_symbol != runtime _Symbol -> " + BoundedAutomationAdmissibility_ToString(a4));

      AddDryRun("ER_E_OK", SAFETY_GATE_ACCEPTED, _Symbol);
      MakeRequestRecord("ER_E_OK", r);
      int candidatesBefore = CandidateProjection_Count();
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a5 = BoundedAutomation_CheckAdmissible(r, lines, frozen);
      Check(a5 == BOUNDED_AUTOMATION_ADMISSIBLE && candidatesBefore == 0,
            "TC-11 strategy_allowlist \"\" admits with NO candidate record (no lookup) -> " + BoundedAutomationAdmissibility_ToString(a5));

      BoundedAutomationPolicy restricted = frozen;
      restricted.strategy_allowlist = "CRT";
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a6 = BoundedAutomation_CheckAdmissible(r, lines, restricted);
      AddCandidate("CAND_ER_E_OK", STRAT_SMC);
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a7 = BoundedAutomation_CheckAdmissible(r, lines, restricted);
      CandidateProjection_Reset();
      AddCandidate("CAND_ER_E_OK", STRAT_CRT);
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a8 = BoundedAutomation_CheckAdmissible(r, lines, restricted);
      Check(a6 == BOUNDED_AUTOMATION_INADMISSIBLE_STRATEGY_LOOKUP_FAILED && a7 == BOUNDED_AUTOMATION_INADMISSIBLE_STRATEGY_NOT_ALLOWED
            && a8 == BOUNDED_AUTOMATION_ADMISSIBLE,
            "TC-12 non-empty strategy list: lookup fails -> " + BoundedAutomationAdmissibility_ToString(a6) + ", SMC -> "
            + BoundedAutomationAdmissibility_ToString(a7) + ", CRT -> " + BoundedAutomationAdmissibility_ToString(a8));

      AddDryRun("ER_E_M1", SAFETY_GATE_ACCEPTED, _Symbol);
      MakeRequestRecord("ER_E_M1", r);
      r.execution_policy_version = MLQUANTAI_RESERVED_FIXTURE_EXECUTION_POLICY_VERSION;
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a9 = BoundedAutomation_CheckAdmissible(r, lines, frozen);
      Check(a9 == BOUNDED_AUTOMATION_INADMISSIBLE_FIXTURE_M1, "TC-13 M1 policy literal -> " + BoundedAutomationAdmissibility_ToString(a9));

      AddDryRun("ER_E_M2", SAFETY_GATE_ACCEPTED, _Symbol);
      MakeRequestRecord("ER_E_M2", r);
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a10 = BoundedAutomation_CheckAdmissible(r, lines, frozen);
      Check(a10 == BOUNDED_AUTOMATION_INADMISSIBLE_FIXTURE_M2, "TC-14 M2 RUN_C22 ceremony line -> " + BoundedAutomationAdmissibility_ToString(a10));

      MakeRequestRecord("ER_E_OK", r);
      ENUM_BOUNDED_AUTOMATION_ADMISSIBILITY a11 = BoundedAutomation_CheckAdmissible(r, lines, frozen);
      bool m2Empty = BoundedAutomation_IsFixtureM2(lines, "ER_E_OK");
      Check(a11 == BOUNDED_AUTOMATION_ADMISSIBLE && !m2Empty,
            "TC-15/16 clean request admissible; the empty-id RUN_C22 line marks nobody -> " + BoundedAutomationAdmissibility_ToString(a11));
   }

   //=====================================================================
   Print("--- F. amended R16 scan order + R15 halt ---");
   {
      BoundedAutomationMailboxSnapshot mbFree;
      MakeFreeMailbox(mbFree);
      string noLines[];
      BoundedAutomationSelection s;

      ResetAll();
      AddRequestOnly("ER_F_INADM");            // no dry-run -> inadmissible
      AddAdmissible("ER_F_OK");
      BoundedAutomation_SelectCandidate(noLines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_SELECTED && s.selected_index == 1 && s.skipped_inadmissible == 1
            && s.selected_request.execution_request_id == "ER_F_OK",
            "TC-17 [inadmissible, eligible] -> SKIP then SELECT index 1 (" + Describe(s) + ")");

      ResetAll();
      AddAdmissible("ER_F_EXH");
      AddAdmissible("ER_F_OK");
      string exhLines[];
      Push(exhLines, StageLine("2026.06.01 10:00:00", "DEMO_BOUNDED_AUTOMATION"));
      Push(exhLines, E1Line("2026.06.01 10:30:00", "ER_F_EXH", PROV_AUTO));
      BoundedAutomation_SelectCandidate(exhLines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_SELECTED && s.selected_index == 1 && s.skipped_automation_exhausted == 1,
            "TC-18 [exhausted, eligible] -> SKIP then SELECT index 1 (" + Describe(s) + ")");

      ResetAll();
      AddAdmissible("");                        // untrusted record (even with a dry-run record)
      AddAdmissible("ER_F_OK");
      BoundedAutomation_SelectCandidate(noLines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_STATE_UNKNOWN && s.selected_index == 0 && s.skipped_inadmissible == 0,
            "TC-19 [empty-ID, eligible] -> STOP at 0, not skipped as inadmissible (" + Describe(s) + ")");

      ResetAll();
      AddRequestOnly("ER_F_INADM");
      AddAdmissible("ER_F_OK");
      ManualApprovalReadiness_Reset();
      BoundedAutomation_SelectCandidate(noLines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_STATE_UNKNOWN && s.selected_index == 1 && s.skipped_inadmissible == 1,
            "TC-20 registry not ready: inadmissible skipped at 0, STOP at 1 (P-3) (" + Describe(s) + ")");

      ResetAll();
      AddAdmissible("ER_F_OK");
      string badLines[];
      Push(badLines, StageLine("2026.06.01 10:00:00", "DEMO_BOUNDED_AUTOMATION"));
      Push(badLines, E1Line("2026.06.01 10:30:00", "ER_UNRELATED", ""));   // post-cutoff, no key -> INVALID
      BoundedAutomation_SelectCandidate(badLines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_PROVENANCE_INVALID && s.candidates_scanned == 0,
            "R15: any post-cutoff INVALID E1 (even another request's) halts discovery (" + Describe(s) + ")");

      ResetAll();
      AddAdmissible("ER_F_OK");
      string preLines[];
      Push(preLines, E1Line("2026.06.01 08:00:00", "ER_UNRELATED", ""));   // pre-cutoff garbage
      Push(preLines, StageLine("2026.06.01 10:00:00", "DEMO_BOUNDED_AUTOMATION"));
      BoundedAutomation_SelectCandidate(preLines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_CANDIDATE_SELECTED && s.selected_index == 0,
            "R15 scope: a PRE-cutoff line without the key does not halt (" + Describe(s) + ")");

      ResetAll();
      AddRequestOnly("ER_F_A");
      AddRequestOnly("ER_F_B");
      BoundedAutomation_SelectCandidate(noLines, mbFree, g_AsOf, s);
      Check(s.outcome == BOUNDED_AUTOMATION_DISCOVERY_NO_ELIGIBLE_CANDIDATE && s.candidates_scanned == 2 && s.skipped_inadmissible == 2,
            "all inadmissible -> NO_ELIGIBLE_CANDIDATE with skip accounting (" + Describe(s) + ")");
   }

   ManualApprovalReadiness_Reset();
   ManualApprovalProjection_Reset();
   ExecutionRequestProjection_Reset();
   DryRunResultProjection_Reset();
   CandidateProjection_Reset();
   DeleteFixture(R15A_READY_FILE);
   DeleteFixture(R15A_REAL_FILE);

   Print(StringFormat("=== RESULT: %d/%d passed ===", g_TestsPassed, g_TestsRun));
}
