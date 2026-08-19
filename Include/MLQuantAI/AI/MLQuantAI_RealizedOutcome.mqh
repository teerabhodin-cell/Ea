//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_RealizedOutcome.mqh                      |
//| Phase B8.2 Commit 3: RealizedOutcome - the only sanctioned source  |
//| of a training row's label, per                                     |
//| Docs/PhaseB_B8_2_Commit3_OutcomeLabelContract.md. A RealizedOutcome |
//| references its candidate by identity/hash - it never carries a     |
//| copy of the candidate's own feature/risk data. No two-hash split   |
//| the way FeatureSnapshot needed one - a RealizedOutcome is           |
//| inherently 1:1 with one candidate's outcome, so a single            |
//| full-record hash (same role RiskPlan.plan_hash plays) is enough.    |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_REALIZEDOUTCOME_MQH__
#define __MLQUANTAI_REALIZEDOUTCOME_MQH__

#include "../Core/MLQuantAI_ContractVersions.mqh"
#include "../Core/MLQuantAI_Ids.mqh"

struct RealizedOutcome
{
   string   realized_outcome_schema_version; // MLQUANTAI_REALIZED_OUTCOME_SCHEMA_B8_2_V1

   string   realized_outcome_id;   // identity - depends only on candidate_id + label_schema_version
   string   candidate_id;
   string   candidate_hash;

   string   label_schema_version;  // MUST equal MLQUANTAI_LABEL_SCHEMA_B8_2_V1 - see contract scope decision 5
   string   label;                 // opaque string - label methodology is not this commit's concern
   string   outcome_reference;     // external evidence pointer (ticket id / backtest run id / fixture id)
   string   outcome_hash;          // content hash of that external evidence - supplied, not computed here
   datetime outcome_time;          // MUST be strictly after the candidate's setup_anchor_bar_time

   string   realized_outcome_hash; // full-record content hash - computed last
};

void RealizedOutcome_Init(RealizedOutcome &o)
{
   o.realized_outcome_schema_version = MLQUANTAI_REALIZED_OUTCOME_SCHEMA_B8_2_V1;

   o.realized_outcome_id = "";
   o.candidate_id = "";
   o.candidate_hash = "";

   o.label_schema_version = "";
   o.label = "";
   o.outcome_reference = "";
   o.outcome_hash = "";
   o.outcome_time = 0;

   o.realized_outcome_hash = "";
}

// Excludes realized_outcome_schema_version/realized_outcome_id
// (identity, not content) - same "don't hash the identity fields"
// rule RiskPlan_HashPayload already follows.
string RealizedOutcome_HashPayload(const RealizedOutcome &o)
{
   return o.candidate_id + "|" +
          o.candidate_hash + "|" +
          o.label_schema_version + "|" +
          o.label + "|" +
          o.outcome_reference + "|" +
          o.outcome_hash + "|" +
          TimeToString(o.outcome_time, TIME_DATE|TIME_SECONDS);
}

string RealizedOutcome_ComputeHash(const RealizedOutcome &o)
{
   return Ids_Sha256Hex(RealizedOutcome_HashPayload(o));
}

#endif // __MLQUANTAI_REALIZEDOUTCOME_MQH__
