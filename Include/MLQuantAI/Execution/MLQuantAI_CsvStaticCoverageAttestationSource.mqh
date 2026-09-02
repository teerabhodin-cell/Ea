//+------------------------------------------------------------------+
//| MLQuantAI - Execution/MLQuantAI_CsvStaticCoverageAttestationSource|
//| .mqh                                                              |
//| C4.3.1 implementation, per this checkpoint's frozen design.       |
//| Docs/PhaseC_C4_RecoveryHistoryPolicy.md §11.5 already authorizes  |
//| a CsvStaticCoverageAttestationSource as one of exactly two v1     |
//| ICoverageAttestationSource implementations; this file supplies    |
//| it without amending §11's text.                                   |
//|                                                                    |
//| One physical CSV data line is one attestation - no multi-row      |
//| lookup, no identity-keyed selection. TryGet() ignores its two      |
//| identity arguments entirely, exactly like                         |
//| MLQuantAI_ParameterCoverageAttestationSource.mqh.                  |
//|                                                                    |
//| File format (Common\Files, FILE_TXT so FileReadString reads one   |
//| whole line at a time, FILE_ANSI - matching the established         |
//| MLQuantAI_CsvStaticNewsSource.mqh convention exactly):             |
//|   line 1: required header, exact 9 column names, exact order,     |
//|     case-sensitive -                                              |
//|     "broker_identity,account_identity,server_time_basis,          |
//|      coverage_from,coverage_to,valid_until,issuer_identity,        |
//|      evidence_reference,integrity_identifier"                     |
//|   line 2: exactly one non-empty data row, exactly 9               |
//|     comma-separated fields.                                       |
//|   A trailing zero-length line at EOF is tolerated; nothing else   |
//|   after the one data row is.                                      |
//|                                                                    |
//| CSV lexical subset (frozen this checkpoint): each physical line    |
//| is one record; a comma is always a field boundary; there is no    |
//| quoted-field, escaped-quote, embedded-comma, or embedded-newline   |
//| support. Double-quote characters, if present, are ordinary        |
//| preserved characters. No trimming or normalization is applied to  |
//| any parsed field before header comparison, field-count            |
//| validation, required-field checks, datetime parsing, or DTO       |
//| assignment - every field here is a machine identifier, timestamp, |
//| a fixed marker, or free-form provenance text, with no domain need |
//| for embedded commas.                                              |
//|                                                                    |
//| A UTF-8 BOM-prefixed file fails through the ordinary               |
//| exact-header-mismatch path below - FileReadString() under         |
//| FILE_ANSI returns the BOM bytes as part of line 1's string         |
//| content, so it can never equal the required header literal. No    |
//| dedicated BOM-stripping logic exists or is added; fixture/source   |
//| files must be plain ANSI/UTF-8-without-BOM text.                  |
//|                                                                    |
//| Validation-ownership boundary (frozen this checkpoint, mirrors     |
//| MLQuantAI_ParameterCoverageAttestationSource.mqh's already-shipped |
//| boundary): this source owns file access, physical-line/row         |
//| cardinality, header shape, field count, and datetime               |
//| parseability, plus presence of the three required identity/       |
//| time-basis fields - all fail Load() closed. integrity_identifier   |
//| correctness, coverage-bounds ordering, staleness, and identity     |
//| equality against scan context are evaluator-owned                 |
//| (MLQuantAI_RecoveryCoverageEvaluator.mqh) - this source never      |
//| inspects those fields' content beyond parsing them, only the      |
//| three identity/time-basis fields' presence.                       |
//|                                                                    |
//| coverage_from/coverage_to/valid_until: an empty field, or a field   |
//| that does not match the exact "YYYY.MM.DD HH:MM:SS" (19-character) |
//| shape checked by IsWellFormedDateTime19() below, fails Load()       |
//| closed before StringToTime() is ever called on it. Real-platform    |
//| testing during this checkpoint showed StringToTime() does not      |
//| reliably return 0 for non-numeric garbage input (e.g. "NOT_A_DATE" |
//| parsed to a non-zero value) - so unlike                            |
//| MLQuantAI_CsvStaticNewsSource.mqh's required release_time_utc       |
//| field, which trusts a StringToTime()==0 check alone, this source    |
//| validates the literal string shape first and treats StringToTime()  |
//| purely as the final conversion step, never as the validator.       |
//| Consequence (deliberate, narrow, and outside this checkpoint's      |
//| 22-case test scope): this source cannot represent a literal        |
//| valid_until==0 attestation; that value remains reachable only via   |
//| direct construction or                                             |
//| MLQuantAI_ParameterCoverageAttestationSource.mqh.                  |
//|                                                                    |
//| A failed Load() (including a reload after a prior success)         |
//| invalidates any previously cached attestation before attempting    |
//| to parse anything new - TryGet() never serves stale cached data    |
//| after a failed reload.                                             |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_CSVSTATICCOVERAGEATTESTATIONSOURCE_MQH__
#define __MLQUANTAI_CSVSTATICCOVERAGEATTESTATIONSOURCE_MQH__

#include "MLQuantAI_CoverageAttestation.mqh"

#define MLQUANTAI_C4_3_1_COVERAGE_CSV_REQUIRED_HEADER \
   "broker_identity,account_identity,server_time_basis,coverage_from,coverage_to,valid_until,issuer_identity,evidence_reference,integrity_identifier"

class CsvStaticCoverageAttestationSource : public ICoverageAttestationSource
{
private:
   string                       m_fileName;
   bool                         m_loaded;
   RecoveryCoverageAttestation  m_cached;

   // Validates the exact "YYYY.MM.DD HH:MM:SS" shape (19 characters;
   // digits at every numeric position, '.' at 4/7, ' ' at 10, ':' at
   // 13/16) that every datetime field in this contract uses, WITHOUT
   // relying on StringToTime()'s own parsing fallback for malformed
   // input. Real-platform testing showed StringToTime() does not
   // reliably return 0 for non-numeric garbage (e.g. "NOT_A_DATE") -
   // so format validity is checked here first, deterministically, and
   // StringToTime() is only ever called on a string already proven to
   // have the right shape.
   bool IsWellFormedDateTime19(string s)
   {
      if(StringLen(s) != 19) return false;

      int digitPositions[] = {0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18};
      for(int i = 0; i < ArraySize(digitPositions); i++)
      {
         ushort c = StringGetCharacter(s, digitPositions[i]);
         if(c < '0' || c > '9') return false;
      }
      if(StringGetCharacter(s, 4)  != '.') return false;
      if(StringGetCharacter(s, 7)  != '.') return false;
      if(StringGetCharacter(s, 10) != ' ') return false;
      if(StringGetCharacter(s, 13) != ':') return false;
      if(StringGetCharacter(s, 16) != ':') return false;
      return true;
   }

   bool ParseDataLine(string line, RecoveryCoverageAttestation &out, string &outError)
   {
      RecoveryCoverageAttestation_Init(out);

      string fields[];
      int nf = StringSplit(line, ',', fields);
      if(nf != 9)
      {
         outError = StringFormat("CsvStaticCoverageAttestationSource: data row has %d fields, expected 9", nf);
         return false;
      }

      out.broker_identity      = fields[0];
      out.account_identity     = fields[1];
      out.server_time_basis    = fields[2];
      out.issuer_identity      = fields[6];
      out.evidence_reference   = fields[7];
      out.integrity_identifier = fields[8];

      if(out.broker_identity == "")
      {
         outError = "CsvStaticCoverageAttestationSource: broker_identity is empty";
         return false;
      }
      if(out.account_identity == "")
      {
         outError = "CsvStaticCoverageAttestationSource: account_identity is empty";
         return false;
      }
      if(out.server_time_basis == "")
      {
         outError = "CsvStaticCoverageAttestationSource: server_time_basis is empty";
         return false;
      }

      if(fields[3] == "" || !IsWellFormedDateTime19(fields[3]))
      {
         outError = "CsvStaticCoverageAttestationSource: coverage_from is not a parseable datetime";
         return false;
      }
      out.coverage_from = StringToTime(fields[3]);
      if(out.coverage_from == 0)
      {
         outError = "CsvStaticCoverageAttestationSource: coverage_from is not a parseable datetime";
         return false;
      }

      if(fields[4] == "" || !IsWellFormedDateTime19(fields[4]))
      {
         outError = "CsvStaticCoverageAttestationSource: coverage_to is not a parseable datetime";
         return false;
      }
      out.coverage_to = StringToTime(fields[4]);
      if(out.coverage_to == 0)
      {
         outError = "CsvStaticCoverageAttestationSource: coverage_to is not a parseable datetime";
         return false;
      }

      if(fields[5] == "" || !IsWellFormedDateTime19(fields[5]))
      {
         outError = "CsvStaticCoverageAttestationSource: valid_until is not a parseable datetime";
         return false;
      }
      out.valid_until = StringToTime(fields[5]);
      if(out.valid_until == 0)
      {
         outError = "CsvStaticCoverageAttestationSource: valid_until is not a parseable datetime";
         return false;
      }

      return true;
   }

public:
   CsvStaticCoverageAttestationSource(string fileName)
   {
      m_fileName = fileName;
      m_loaded = false;
      RecoveryCoverageAttestation_Init(m_cached);
   }

   // Must be called (and must succeed) before TryGet() can ever return
   // true. Fails closed - and invalidates any previously cached
   // attestation first, unconditionally - on: missing/unopenable file,
   // an empty file, a missing or malformed header line, a data row with
   // the wrong field count, a second non-empty data row, an empty
   // required identity/time-basis field, or an unparseable required
   // datetime field. There is only ever one row to accept or reject -
   // never a "skip a bad row and continue" path.
   bool Load(string &outError)
   {
      outError = "";
      m_loaded = false;
      RecoveryCoverageAttestation_Init(m_cached);

      int handle = FileOpen(m_fileName, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(handle == INVALID_HANDLE)
      {
         outError = StringFormat("CsvStaticCoverageAttestationSource: could not open '%s', err=%d", m_fileName, GetLastError());
         return false;
      }

      if(FileIsEnding(handle))
      {
         FileClose(handle);
         outError = StringFormat("CsvStaticCoverageAttestationSource: '%s' is empty", m_fileName);
         return false;
      }
      string headerLine = FileReadString(handle);
      if(headerLine != MLQUANTAI_C4_3_1_COVERAGE_CSV_REQUIRED_HEADER)
      {
         FileClose(handle);
         outError = "CsvStaticCoverageAttestationSource: missing or malformed header line";
         return false;
      }

      if(FileIsEnding(handle))
      {
         FileClose(handle);
         outError = StringFormat("CsvStaticCoverageAttestationSource: '%s' has a header line but no data row", m_fileName);
         return false;
      }
      string dataLine = FileReadString(handle);

      RecoveryCoverageAttestation parsed;
      if(!ParseDataLine(dataLine, parsed, outError))
      {
         FileClose(handle);
         return false;
      }

      // Only zero-length trailing line(s) after the one data row are
      // tolerated - a whitespace-only or otherwise non-empty line is a
      // second data row and fails closed. No trimming is applied here
      // either (§ lexical subset, above): the check is a strict
      // StringLen(line)==0, never a trimmed-emptiness check.
      while(!FileIsEnding(handle))
      {
         string trailing = FileReadString(handle);
         if(StringLen(trailing) != 0)
         {
            FileClose(handle);
            outError = "CsvStaticCoverageAttestationSource: more than one non-empty data row present";
            return false;
         }
      }
      FileClose(handle);

      m_cached = parsed;
      m_loaded = true;
      return true;
   }

   virtual bool TryGet(
      string broker_identity,
      string account_identity,
      RecoveryCoverageAttestation &out_attestation,
      string &out_reason
   ) override
   {
      RecoveryCoverageAttestation_Init(out_attestation);
      if(!m_loaded)
      {
         out_reason = "coverage attestation source is not loaded";
         return false;
      }
      out_attestation = m_cached;
      out_reason = "";
      return true;
   }
};

#endif // __MLQUANTAI_CSVSTATICCOVERAGEATTESTATIONSOURCE_MQH__
