//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_OutcomeLabelPolicy.mqh                   |
//| RA-62 (QA-frozen Outcome Label Methodology V1): the versioned,     |
//| durable policy constants governing how a RealizedOutcome's label   |
//| is computed. These are the exact three numbers QA froze after       |
//| direct source verification of this project's own feature lookback  |
//| (PDH/PDL = previous full D1 bar, worst case 48h reach-back on the   |
//| PERIOD_M5 trigger_timeframe = 576 bars) plus a QA-approved,          |
//| explicitly-flagged methodology choice for the forward label          |
//| horizon (864 bars = 72h, NOT source-derived - a genuine policy       |
//| decision, distinct from the lookback figure).                        |
//|                                                                       |
//| All three values are expressed in bars of InpTriggerTimeframe        |
//| (MLQuantAI_FeatureEngine.mqh's own PERIOD_M5 default) - the SAME     |
//| unit TradeCandidate.expiry_after_bars already uses, never an          |
//| absolute wall-clock duration independent of timeframe.                |
//|                                                                       |
//| Versioned deliberately as its own policy identity (never folded       |
//| into MLQUANTAI_LABEL_SCHEMA_B8_2_V1, which BuildTrainingDatasetRow     |
//| already owns and unconditionally stamps) - changing any of these      |
//| three numbers later must mint a new version string, never silently    |
//| redefine what this one already means, per this project's standing     |
//| "never silently reinterpret an existing version" rule.                |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_OUTCOMELABELPOLICY_MQH__
#define __MLQUANTAI_OUTCOMELABELPOLICY_MQH__

#define MLQUANTAI_OUTCOME_LABEL_POLICY_RA62_V1 "OUTCOME_LABEL_POLICY_RA62_V1"

// QA-frozen (RA-62), source-verified: worst-case reach-back of
// DataHub_PrevDayHigh()/DataHub_PrevDayLow() (iHigh/iLow(symbol,
// PERIOD_D1, 1) - the previous full D1 bar, up to 48h before "now" in
// the worst case) expressed in PERIOD_M5 bars (InpTriggerTimeframe's
// real production default). MLQUANTAI_CRT_V1_LOOKBACK_BARS (64) is
// already contained within this window. Informational/metadata only -
// this policy file does not itself read any feature, it only records
// the figure so dataset/split metadata can cite it verbatim.
#define MLQUANTAI_OUTCOME_LABEL_FEATURE_LOOKBACK_BARS_V1  576

// QA-frozen (RA-62) methodology decision - NOT derived from any
// existing source constant. 864 bars = 72h at PERIOD_M5 (3 sessions),
// chosen to give this strategy's own intraday/short-swing setup
// geometry (MarketContext.is_kill_zone/asian_range_*) room to resolve
// without dragging in stale, unrelated price action. A RealizedOutcome
// whose scan exhausts this many bars without a TP or SL touch is
// labeled OUTCOME_LABEL_TIMEOUT - a distinct third class, never folded
// into TP_HIT or SL_HIT.
#define MLQUANTAI_OUTCOME_LABEL_MAX_LOOKFORWARD_BARS_V1   864

// QA-frozen (RA-62): purged-cross-validation embargo gap for the
// RA-63 chronological dataset split (not consulted by the labeling
// engine itself - recorded here only because it is definitionally
// FEATURE_LOOKBACK_BARS_V1 + MAX_LOOKFORWARD_BARS_V1, and QA required
// this be an explicit, versioned, recorded policy value, never a
// silently-recomputed one). = 576 + 864 = 1440.
#define MLQUANTAI_OUTCOME_LABEL_EMBARGO_BARS_V1           1440

#endif // __MLQUANTAI_OUTCOMELABELPOLICY_MQH__
