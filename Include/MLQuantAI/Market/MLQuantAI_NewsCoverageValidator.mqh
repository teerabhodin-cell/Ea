//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_NewsCoverageValidator.mqh           |
//| Phase B B4: hard coverage gate for a news source's raw data       |
//| against a requested time window (typically the full backtest      |
//| range). Step 9's B4 seal criterion "coverage failure = fail       |
//| closed" means this is no longer advisory (Step 9's old            |
//| News_ValidateCsvCoverage only warned) - a source that doesn't      |
//| cover the requested window must block startup, not silently run   |
//| with an incomplete news dataset.                                  |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_NEWSCOVERAGEVALIDATOR_MQH__
#define __MLQUANTAI_NEWSCOVERAGEVALIDATOR_MQH__

#include "MLQuantAI_NewsSource.mqh"

struct NewsCoverageRange
{
   bool     has_data;
   datetime min_time;
   datetime max_time;
};

void NewsCoverageRange_Init(NewsCoverageRange &r)
{
   r.has_data = false;
   r.min_time = 0;
   r.max_time = 0;
}

NewsCoverageRange News_ComputeCoverageRange(const RawNewsEvent &arr[])
{
   NewsCoverageRange r;
   NewsCoverageRange_Init(r);

   int n = ArraySize(arr);
   if(n == 0) return r;

   datetime minT = arr[0].release_time, maxT = arr[0].release_time;
   for(int i = 1; i < n; i++)
   {
      if(arr[i].release_time < minT) minT = arr[i].release_time;
      if(arr[i].release_time > maxT) maxT = arr[i].release_time;
   }

   r.has_data = true;
   r.min_time = minT;
   r.max_time = maxT;
   return r;
}

// Hard gate: does the source's raw data fully cover [rangeStart,
// rangeEnd]? Returns false (with a reason in outError) rather than a
// warning - callers (CsvStaticNewsSource, MLQuantAI.mq5's OnInit) MUST
// treat false as "refuse to proceed", not "proceed with a gap".
bool News_ValidateCoverage(const RawNewsEvent &arr[], datetime rangeStart, datetime rangeEnd, string &outError)
{
   outError = "";

   NewsCoverageRange cov = News_ComputeCoverageRange(arr);
   if(!cov.has_data)
   {
      outError = "news source has no rows at all - coverage cannot be validated";
      return false;
   }

   if(cov.min_time > rangeStart || cov.max_time < rangeEnd)
   {
      outError = StringFormat("news source coverage %s .. %s does not fully cover the requested range %s .. %s",
                 TimeToString(cov.min_time, TIME_DATE|TIME_SECONDS), TimeToString(cov.max_time, TIME_DATE|TIME_SECONDS),
                 TimeToString(rangeStart, TIME_DATE|TIME_SECONDS), TimeToString(rangeEnd, TIME_DATE|TIME_SECONDS));
      return false;
   }

   return true;
}

#endif // __MLQUANTAI_NEWSCOVERAGEVALIDATOR_MQH__
