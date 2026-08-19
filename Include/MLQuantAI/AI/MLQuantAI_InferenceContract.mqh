//+------------------------------------------------------------------+
//| MLQuantAI - AI/MLQuantAI_InferenceContract.mqh                     |
//| Phase B8.4 Commit 1 (Tier A): InferenceRequest/InferenceResult -    |
//| the pinned, fail-closed boundary between a compatible registered   |
//| artifact (B8.3) and whatever eventually runs it (Tier B). See      |
//| Docs/PhaseB_B8_4_InferenceContract.md. Neither struct is a          |
//| persisted event in this commit - InferenceRequest is caller        |
//| intent, InferenceResult is ephemeral, pre-decision output.          |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_INFERENCECONTRACT_MQH__
#define __MLQUANTAI_INFERENCECONTRACT_MQH__

#include "../Core/MLQuantAI_CanonicalFormat.mqh"
#include "../Core/MLQuantAI_ContractVersions.mqh"
#include "../Core/MLQuantAI_Ids.mqh"

// The full fail-closed reason vocabulary, frozen now for both Tier A
// and Tier B so Tier B never needs a second enum. Codes marked below
// have no Tier A code path yet (no file I/O, no runtime, and MQL5's
// static typing already prevents a float[] from ever being the wrong
// element type) - their own QA gate is deferred to the Tier B commit
// that actually implements the code path each one guards.
enum ENUM_INFERENCE_FAIL_REASON
{
   INFERENCE_FAIL_NONE,           // success - no failure
   MODEL_NOT_FOUND,
   MODEL_NOT_PROMOTED,
   MODEL_INCOMPATIBLE,
   ARTIFACT_LOCATION_NOT_FOUND,   // Tier B only
   ARTIFACT_READ_FAILED,          // Tier B only
   ARTIFACT_HASH_MISMATCH,        // Tier B only
   RUNTIME_UNAVAILABLE,           // Tier B only
   RUNTIME_VERSION_MISMATCH,      // Tier B only
   MODEL_LOAD_FAILED,             // Tier B only
   INPUT_SCHEMA_MISMATCH,
   INPUT_SHAPE_MISMATCH,          // reserved - Tier A's one frozen input shape never varies yet
   INPUT_TYPE_MISMATCH,           // reserved - unreachable under MQL5 static typing in Tier A
   INPUT_NONFINITE,
   INFERENCE_FAILED,              // Tier B only
   OUTPUT_SCHEMA_MISMATCH,
   OUTPUT_SHAPE_MISMATCH,
   OUTPUT_TYPE_MISMATCH,          // reserved - unreachable under MQL5 static typing in Tier A
   OUTPUT_NONFINITE,
   OUTPUT_RANGE_INVALID
};

string InferenceFailReasonToString(ENUM_INFERENCE_FAIL_REASON r)
{
   switch(r)
   {
      case INFERENCE_FAIL_NONE:            return "NONE";
      case MODEL_NOT_FOUND:                return "MODEL_NOT_FOUND";
      case MODEL_NOT_PROMOTED:             return "MODEL_NOT_PROMOTED";
      case MODEL_INCOMPATIBLE:             return "MODEL_INCOMPATIBLE";
      case ARTIFACT_LOCATION_NOT_FOUND:    return "ARTIFACT_LOCATION_NOT_FOUND";
      case ARTIFACT_READ_FAILED:           return "ARTIFACT_READ_FAILED";
      case ARTIFACT_HASH_MISMATCH:         return "ARTIFACT_HASH_MISMATCH";
      case RUNTIME_UNAVAILABLE:            return "RUNTIME_UNAVAILABLE";
      case RUNTIME_VERSION_MISMATCH:       return "RUNTIME_VERSION_MISMATCH";
      case MODEL_LOAD_FAILED:              return "MODEL_LOAD_FAILED";
      case INPUT_SCHEMA_MISMATCH:          return "INPUT_SCHEMA_MISMATCH";
      case INPUT_SHAPE_MISMATCH:           return "INPUT_SHAPE_MISMATCH";
      case INPUT_TYPE_MISMATCH:            return "INPUT_TYPE_MISMATCH";
      case INPUT_NONFINITE:                return "INPUT_NONFINITE";
      case INFERENCE_FAILED:               return "INFERENCE_FAILED";
      case OUTPUT_SCHEMA_MISMATCH:         return "OUTPUT_SCHEMA_MISMATCH";
      case OUTPUT_SHAPE_MISMATCH:          return "OUTPUT_SHAPE_MISMATCH";
      case OUTPUT_TYPE_MISMATCH:           return "OUTPUT_TYPE_MISMATCH";
      case OUTPUT_NONFINITE:               return "OUTPUT_NONFINITE";
      case OUTPUT_RANGE_INVALID:           return "OUTPUT_RANGE_INVALID";
      default:                             return "UNKNOWN";
   }
}

struct InferenceRequest
{
   string inference_request_schema_version; // MLQUANTAI_INFERENCE_REQUEST_SCHEMA_B8_4_V1

   string model_id;
   string model_version;

   string feature_snapshot_id;
   string feature_snapshot_hash;
   string feature_vector_hash;
   string feature_schema_version;

   string model_target;
   string input_schema_version;
   string output_schema_version;

   string runtime_framework;
   string runtime_version;
};

void InferenceRequest_Init(InferenceRequest &r)
{
   r.inference_request_schema_version = MLQUANTAI_INFERENCE_REQUEST_SCHEMA_B8_4_V1;

   r.model_id = "";
   r.model_version = "";

   r.feature_snapshot_id = "";
   r.feature_snapshot_hash = "";
   r.feature_vector_hash = "";
   r.feature_schema_version = "";

   r.model_target = "";
   r.input_schema_version = "";
   r.output_schema_version = "";

   r.runtime_framework = "";
   r.runtime_version = "";
}

struct InferenceResult
{
   string inference_contract_version; // MLQUANTAI_INFERENCE_CONTRACT_B8_4_V1

   string model_registry_id;
   string model_registry_hash;
   string model_artifact_hash;

   string feature_snapshot_id;
   string feature_snapshot_hash;
   string feature_vector_hash;

   string output_schema_version;
   float  output_values[];
   string output_hash;

   string runtime_framework;
   string runtime_version;
};

void InferenceResult_Init(InferenceResult &r)
{
   r.inference_contract_version = MLQUANTAI_INFERENCE_CONTRACT_B8_4_V1;

   r.model_registry_id = "";
   r.model_registry_hash = "";
   r.model_artifact_hash = "";

   r.feature_snapshot_id = "";
   r.feature_snapshot_hash = "";
   r.feature_vector_hash = "";

   r.output_schema_version = "";
   ArrayResize(r.output_values, 0);
   r.output_hash = "";

   r.runtime_framework = "";
   r.runtime_version = "";
}

// output_hash: output_schema_version + every output_values entry,
// joined - NEVER event metadata, sequence number, session ID,
// timestamp, or file path/URI. Each float is widened to double before
// CanonicalDouble so the same canonical formatting every other hash
// payload in this project uses applies here too.
string InferenceResult_OutputHashPayload(const InferenceResult &r)
{
   string s = r.output_schema_version;
   for(int i = 0; i < ArraySize(r.output_values); i++)
      s += "|" + CanonicalDouble((double)r.output_values[i]);
   return s;
}

string InferenceResult_ComputeOutputHash(const InferenceResult &r)
{
   return Ids_Sha256Hex(InferenceResult_OutputHashPayload(r));
}

#endif // __MLQUANTAI_INFERENCECONTRACT_MQH__
