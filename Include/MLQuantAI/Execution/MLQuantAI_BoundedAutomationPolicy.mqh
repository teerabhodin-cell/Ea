//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_BoundedAutomationPolicy.mqh       |
//| C5.2 §6.3 Design Contract Rev.15 (FROZEN, commit 07a3581), §3.1:   |
//| the BoundedAutomationPolicy shape with its RATIFIED values          |
//| (R1-R8, Rev.14; carried unchanged into Rev.15). R15-A slice.         |
//|                                                                    |
//| These are FROZEN policy values, not operator inputs: no `input`      |
//| variable, no file, no GlobalVariable can change them. Changing any  |
//| value is a policy amendment that needs QA's own ratification.       |
//|                                                                    |
//| R15-A uses only max_lot_size_per_submission, symbol_allowlist and    |
//| strategy_allowlist (static admissibility, §2.3.1). The cap fields    |
//| are defined here with their ratified values but are NOT evaluated   |
//| anywhere yet - cap evaluation is Wave 3.                            |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_BOUNDEDAUTOMATIONPOLICY_MQH__
#define __MLQUANTAI_BOUNDEDAUTOMATIONPOLICY_MQH__

// §3.1 names the version field with an example value; this is that value.
#define MLQUANTAI_BOUNDED_AUTOMATION_POLICY_VERSION "BOUNDEDAUTO_C6_3_V1"

// R1 (§1.2 / P1): minimum distinct in-window candidates for the §6.3
// evidence gate. Not a BoundedAutomationPolicy field in the contract;
// defined here so every ratified R1-R8 value lives in one place. Not used
// by R15-A.
#define MLQUANTAI_BOUNDED_AUTOMATION_P1_MIN_CANDIDATES 5

struct BoundedAutomationPolicy
{
   string bounded_automation_policy_version;

   double max_lot_size_per_submission;        // R2
   double max_daily_volume_lots;              // R3
   int    max_submissions_per_day;            // R4
   int    min_seconds_between_submissions;    // R5
   double max_concurrent_open_risk_percent;   // R6
   int    max_concurrent_open_positions;      // R7
   string symbol_allowlist;                   // R8 - runtime _Symbol (single symbol)
   string strategy_allowlist;                 // R8 - "" = no strategy restriction (NOT "reject all")
   string session_window_server_time;         // R8 - "" = no time-of-day restriction
   string day_of_week_allowlist;              // R8 - "" = no day restriction
};

// The ONE way to obtain the policy. symbol_allowlist is the MQL5 runtime
// value _Symbol (the chart/EA instance's own symbol, e.g. "XAUUSD") - never
// the literal text "_Symbol" (QA Q4 clarification).
void BoundedAutomationPolicy_InitFrozen(BoundedAutomationPolicy &p)
{
   p.bounded_automation_policy_version = MLQUANTAI_BOUNDED_AUTOMATION_POLICY_VERSION;
   p.max_lot_size_per_submission       = 0.01;
   p.max_daily_volume_lots             = 0.05;
   p.max_submissions_per_day           = 3;
   p.min_seconds_between_submissions   = 3600;
   p.max_concurrent_open_risk_percent  = 2.0;
   p.max_concurrent_open_positions     = 2;
   p.symbol_allowlist                  = _Symbol;
   p.strategy_allowlist                = "";
   p.session_window_server_time        = "";
   p.day_of_week_allowlist             = "";
}

#endif // __MLQUANTAI_BOUNDEDAUTOMATIONPOLICY_MQH__
