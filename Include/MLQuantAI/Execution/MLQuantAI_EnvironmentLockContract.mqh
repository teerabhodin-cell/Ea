//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_EnvironmentLockContract.mqh      |
//| C2 environment-lock checklist (frozen, per                        |
//| Docs/PhaseC_C2_EnvironmentLockChecklist.md): carries ONLY the      |
//| genuinely new field this checklist needs - the frozen              |
//| `ExecutionPolicy` struct (C1.1) is never edited, per this           |
//| project's "no sealed file touched" discipline. A new, additive      |
//| struct instead, exactly the same pattern already used for           |
//| MLQuantAI_BrokerSubmissionAuditReadiness.mqh this phase.             |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_ENVIRONMENTLOCKCONTRACT_MQH__
#define __MLQUANTAI_ENVIRONMENTLOCKCONTRACT_MQH__

struct EnvironmentLockPolicy
{
   string environment_lock_policy_version;
   string trade_server_allowlist; // comma-separated ACCOUNT_SERVER values; empty = unconfigured, fails closed
};

void EnvironmentLockPolicy_Init(EnvironmentLockPolicy &p)
{
   p.environment_lock_policy_version = "";
   p.trade_server_allowlist = "";
}

#endif // __MLQUANTAI_ENVIRONMENTLOCKCONTRACT_MQH__
