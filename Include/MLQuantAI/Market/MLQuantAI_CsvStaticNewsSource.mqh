//+------------------------------------------------------------------+
//| MLQuantAI - Market/MLQuantAI_CsvStaticNewsSource.mqh             |
//| Phase B B4: the deterministic, fully-controlled news source used  |
//| in the Strategy Tester (and as the parity test's oracle - see     |
//| Tests/MLQuantAI_Test_NewsParity.mq5). Reads a FROZEN 7-column CSV |
//| format, fails closed on any file/schema/row/coverage problem -    |
//| never silently skips a bad row or proceeds with a coverage gap.   |
//|                                                                    |
//| File format (Common\Files, FILE_TXT so FileReadString reads one   |
//| whole line at a time):                                            |
//|   line 1: metadata comment -                                      |
//|     "# news_schema_version=NEWS_V1;source_version=...;            |
//|      source_content_hash=..."                                     |
//|   line 2: column header (human-readable, not parsed) -             |
//|     "provider_event_id,currency,impact,title,release_time_utc,    |
//|      revision_id,revision_timestamp_utc"                          |
//|   line 3+: one event per line, exactly 7 comma-separated fields.  |
//| See Tests/Fixtures/MLQuantAI_NewsParityFixture_V1.csv for a real  |
//| example.                                                           |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CSVSTATICNEWSSOURCE_MQH__
#define __MLQUANTAI_CSVSTATICNEWSSOURCE_MQH__

#include "MLQuantAI_NewsSource.mqh"
#include "MLQuantAI_NewsCoverageValidator.mqh"
#include "../Core/MLQuantAI_ContractVersions.mqh"

// Default tie-break priority when two sources report the same
// normalized_event_key (see MLQuantAI_NewsCanonicalizer.mqh's
// News_CompareForDedup) - CSV_STATIC is deliberately lower than
// LIVE_CALENDAR's default (MLQuantAI_LiveCalendarNewsSource.mqh), since
// a live read is generally more current than a static file. In
// practice the two never compete within one EA run (Tester uses CSV,
// live trading uses the calendar), so this mostly matters for the
// parity test's explicit tie-break coverage.
#define MLQUANTAI_CSV_NEWS_SOURCE_DEFAULT_PRIORITY 10

class CsvStaticNewsSource : public INewsSource
{
private:
   string       m_fileName;
   int          m_priority;
   bool         m_loaded;
   string       m_schemaVersion;
   string       m_sourceVersion;
   string       m_sourceContentHash;
   RawNewsEvent m_rows[];

   bool ParseMetaLine(string line, string &outError)
   {
      if(StringFind(line, "#") != 0)
      {
         outError = "CsvStaticNewsSource: line 1 must be a '# key=value;...' metadata comment";
         return false;
      }
      string body = StringSubstr(line, 1);
      StringTrimLeft(body);

      m_schemaVersion = "";
      m_sourceVersion = "";
      m_sourceContentHash = "";

      string parts[];
      int n = StringSplit(body, ';', parts);
      for(int i = 0; i < n; i++)
      {
         string kv[];
         if(StringSplit(parts[i], '=', kv) != 2) continue;
         string key = kv[0]; StringTrimLeft(key); StringTrimRight(key);
         string val = kv[1]; StringTrimLeft(val); StringTrimRight(val);
         if(key == "news_schema_version") m_schemaVersion = val;
         else if(key == "source_version") m_sourceVersion = val;
         else if(key == "source_content_hash") m_sourceContentHash = val;
      }

      if(m_schemaVersion == "")
      {
         outError = "CsvStaticNewsSource: metadata line missing news_schema_version";
         return false;
      }
      if(m_schemaVersion != MLQUANTAI_NEWS_SCHEMA_V1)
      {
         outError = StringFormat("CsvStaticNewsSource: news_schema_version '%s' does not match this build's '%s'",
                                  m_schemaVersion, MLQUANTAI_NEWS_SCHEMA_V1);
         return false;
      }
      if(m_sourceVersion == "")
      {
         outError = "CsvStaticNewsSource: metadata line missing source_version";
         return false;
      }
      return true;
   }

   bool ParseDataLine(string line, int lineNumber, RawNewsEvent &out, string &outError)
   {
      RawNewsEvent_Init(out);

      string fields[];
      int nf = StringSplit(line, ',', fields);
      if(nf != 7)
      {
         outError = StringFormat("CsvStaticNewsSource: line %d has %d fields, expected 7 "
                                  "(provider_event_id,currency,impact,title,release_time_utc,revision_id,revision_timestamp_utc)",
                                  lineNumber, nf);
         return false;
      }

      out.provider_event_id = fields[0];
      out.currency           = fields[1];
      out.impact_raw          = fields[2];
      out.title                = fields[3];
      out.release_time         = StringToTime(fields[4]);
      out.revision_id           = fields[5];
      out.revision_timestamp     = (fields[6] == "") ? 0 : StringToTime(fields[6]);

      if(out.provider_event_id == "" || out.currency == "" || out.release_time == 0)
      {
         outError = StringFormat("CsvStaticNewsSource: line %d failed to parse "
                                  "(provider_event_id/currency/release_time_utc must all be non-empty/valid)", lineNumber);
         return false;
      }

      out.source_kind          = SourceKind();
      out.source_version        = m_sourceVersion;
      out.source_content_hash    = m_sourceContentHash;
      out.source_priority         = m_priority;
      return true;
   }

public:
   CsvStaticNewsSource(string fileName, int priority = MLQUANTAI_CSV_NEWS_SOURCE_DEFAULT_PRIORITY)
   {
      m_fileName = fileName;
      m_priority = priority;
      m_loaded = false;
      m_schemaVersion = "";
      m_sourceVersion = "";
      m_sourceContentHash = "";
   }

   // Must be called (and must succeed) before ReadRawEvents()/
   // ValidateCoverage(). Fails closed on: missing file, a metadata line
   // that isn't well-formed or names a schema version this build doesn't
   // recognize, or any data row that doesn't parse to exactly 7 fields
   // with non-empty identity/time fields - never skips a bad row.
   bool Load(string &outError)
   {
      outError = "";
      ArrayResize(m_rows, 0);
      m_loaded = false;

      int handle = FileOpen(m_fileName, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(handle == INVALID_HANDLE)
      {
         outError = StringFormat("CsvStaticNewsSource: could not open '%s', err=%d", m_fileName, GetLastError());
         return false;
      }

      if(FileIsEnding(handle))
      {
         FileClose(handle);
         outError = StringFormat("CsvStaticNewsSource: '%s' is empty", m_fileName);
         return false;
      }
      string metaLine = FileReadString(handle);
      if(!ParseMetaLine(metaLine, outError))
      {
         FileClose(handle);
         return false;
      }

      if(FileIsEnding(handle))
      {
         FileClose(handle);
         outError = StringFormat("CsvStaticNewsSource: '%s' has a metadata line but no header/data rows", m_fileName);
         return false;
      }
      FileReadString(handle); // column header line - human-readable only, not parsed

      int count = 0;
      int lineNumber = 2;
      while(!FileIsEnding(handle))
      {
         string line = FileReadString(handle);
         lineNumber++;
         if(StringLen(line) == 0) continue; // tolerate a trailing blank line at EOF only

         RawNewsEvent row;
         if(!ParseDataLine(line, lineNumber, row, outError))
         {
            FileClose(handle);
            ArrayResize(m_rows, 0);
            return false;
         }

         ArrayResize(m_rows, count + 1);
         m_rows[count] = row;
         count++;
      }
      FileClose(handle);

      m_loaded = true;
      return true;
   }

   virtual bool ReadRawEvents(string currency, datetime anchorTime, int lookbackMinutes, int lookaheadMinutes,
                               RawNewsEvent &outArr[], string &outError) override
   {
      ArrayResize(outArr, 0);
      if(!m_loaded)
      {
         outError = "CsvStaticNewsSource: Load() must succeed before ReadRawEvents()";
         return false;
      }

      datetime from = anchorTime - lookbackMinutes * 60;
      datetime to   = anchorTime + lookaheadMinutes * 60;

      int count = 0;
      for(int i = 0; i < ArraySize(m_rows); i++)
      {
         if(m_rows[i].release_time < from || m_rows[i].release_time > to) continue;
         if(currency != "" && m_rows[i].currency != currency) continue;
         ArrayResize(outArr, count + 1);
         outArr[count] = m_rows[i];
         count++;
      }
      outError = "";
      return true;
   }

   virtual string SourceKind() override { return "CSV_STATIC"; }

   // The B4 hard gate: does this file's coverage span the full requested
   // range (typically the whole backtest window)? Callers (B4's
   // MLQuantAI.mq5 OnInit wiring) treat false as INIT_FAILED - never a
   // warning.
   bool ValidateCoverage(datetime rangeStart, datetime rangeEnd, string &outError)
   {
      if(!m_loaded)
      {
         outError = "CsvStaticNewsSource: not loaded";
         return false;
      }
      return News_ValidateCoverage(m_rows, rangeStart, rangeEnd, outError);
   }

   int RowCount() { return ArraySize(m_rows); }
   string SourceVersion() { return m_sourceVersion; }
   string SourceContentHash() { return m_sourceContentHash; }
};

#endif // __MLQUANTAI_CSVSTATICNEWSSOURCE_MQH__
