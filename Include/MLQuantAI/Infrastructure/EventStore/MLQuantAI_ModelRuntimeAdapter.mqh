//+------------------------------------------------------------------+
//| MLQuantAI - Infrastructure/EventStore/MLQuantAI_ModelRuntimeAdapter.mqh|
//| Phase B8.4 Commit 2 (Tier B): the real ONNX runtime adapter, per   |
//| Docs/PhaseB_B8_4_Commit2_RuntimeAdapter.md. Two phases:            |
//|                                                                    |
//| ModelRuntimeAdapter_LoadAndVerify() (I1-I3): read the artifact     |
//| file exactly once into a uchar[] buffer, hash that exact buffer,   |
//| reject before ever touching ONNX if it doesn't match               |
//| artifact.model_artifact_hash, then open a session from the SAME    |
//| buffer via OnnxCreateFromBuffer - never OnnxCreate(path), never a  |
//| second read of the artifact by locator.                            |
//|                                                                    |
//| ModelRuntimeAdapter_ValidateContractAndRun() (I5-I6): tensor        |
//| reflection against the frozen INPUT_SCHEMA_V1/OUTPUT_P_SUCCESS_V1  |
//| shape, OnnxRun, then hands raw output back to the CALLER - this     |
//| function never calls Tier A's InferenceOutput_Validate /            |
//| ModelInference_ValidateAndBuildResult itself (I6: single owner      |
//| stays in Commit 1). Always releases the session handle before       |
//| returning, success or failure - the handle never outlives one call,|
//| and callers never manage its lifetime directly.                     |
//|                                                                    |
//| KNOWN UNVERIFIED RISK (flagged, not hidden): OnnxTypeInfo's exact  |
//| field names, and the matrixf constructor/indexing syntax used       |
//| below, could not be confirmed against the public MQL5 docs during   |
//| this session (unlike every other MQL5 call in this file, which was |
//| checked against real documentation before being used). This is the |
//| single highest-risk spot for a real-compile failure in this         |
//| commit - see Docs/PhaseB_B8_4_Commit2_RuntimeAdapter.md.            |
//+------------------------------------------------------------------+
#ifndef __MLQUANTAI_MODELRUNTIMEADAPTER_MQH__
#define __MLQUANTAI_MODELRUNTIMEADAPTER_MQH__

#include "../../Core/MLQuantAI_ContractVersions.mqh"
#include "../../Core/MLQuantAI_Ids.mqh"
#include "../../AI/MLQuantAI_ModelArtifact.mqh"
#include "../../AI/MLQuantAI_InferenceContract.mqh"

// Phase 1 (I1-I3). artifactFilePath is a caller-supplied locator -
// deliberately NOT a ModelArtifact field (B8.3's ModelArtifact carries
// no path/locator - "locator isolation" means the path is never part
// of identity/hash, so it is never persisted on the registry struct
// either; it is supplied fresh by whatever resolves model_id+model_version
// to a file at inference time). Reads from Common\Files, matching this
// project's existing fixture-file convention (FILE_COMMON).
bool ModelRuntimeAdapter_LoadAndVerify(const ModelArtifact &artifact, string artifactFilePath,
                                         long &outSessionHandle,
                                         ENUM_INFERENCE_FAIL_REASON &outReasonCode, string &outReasonDetail)
{
   outSessionHandle = INVALID_HANDLE;
   outReasonCode = INFERENCE_FAIL_NONE;
   outReasonDetail = "";

   if(!FileIsExist(artifactFilePath, FILE_COMMON))
   {
      outReasonCode = ARTIFACT_LOCATION_NOT_FOUND;
      outReasonDetail = "no file at the given locator in Common\\Files: " + artifactFilePath;
      return false;
   }

   // Single read, into a uchar[] (1 byte/element) - the only element
   // size for which FileLoad's whole-element truncation can never drop
   // a trailing byte, for any file size.
   uchar fileBytes[];
   long readCount = FileLoad(artifactFilePath, fileBytes, FILE_COMMON);
   if(readCount < 0 || ArraySize(fileBytes) == 0)
   {
      outReasonCode = ARTIFACT_READ_FAILED;
      outReasonDetail = "FileLoad failed or returned zero bytes for " + artifactFilePath;
      return false;
   }

   string actualHash = Ids_Sha256HexBytes(fileBytes);
   if(actualHash == "" || actualHash != artifact.model_artifact_hash)
   {
      outReasonCode = ARTIFACT_HASH_MISMATCH;
      outReasonDetail = "SHA-256 of the raw artifact bytes does not match the registered model_artifact_hash";
      return false;
   }

   // I2/I3: the exact fileBytes buffer just hashed and verified is the
   // buffer handed to the runtime - no path reload, no second read.
   long handle = OnnxCreateFromBuffer(fileBytes, 0);
   if(handle == INVALID_HANDLE)
   {
      outReasonCode = RUNTIME_UNAVAILABLE;
      outReasonDetail = "OnnxCreateFromBuffer failed on hash-verified bytes (GetLastError=" +
                         IntegerToString(GetLastError()) +
                         ") - the bytes are authentic per I1 but not a loadable ONNX model";
      return false;
   }

   outSessionHandle = handle;
   return true;
}

// Phase 2 (I5-I6). Takes ownership of sessionHandle - always releases
// it (OnnxRelease) exactly once before returning, on every exit path.
bool ModelRuntimeAdapter_ValidateContractAndRun(long sessionHandle, const float &canonicalVector[],
                                                  float &outRawOutput[],
                                                  ENUM_INFERENCE_FAIL_REASON &outReasonCode, string &outReasonDetail)
{
   ArrayResize(outRawOutput, 0);
   outReasonCode = INFERENCE_FAIL_NONE;
   outReasonDetail = "";

   long inputCount  = OnnxGetInputCount(sessionHandle);
   long outputCount = OnnxGetOutputCount(sessionHandle);
   if(inputCount != 1 || outputCount != 1)
   {
      outReasonCode = INPUT_SCHEMA_MISMATCH;
      outReasonDetail = StringFormat("expected exactly 1 input and 1 output, got %d input(s) and %d output(s)",
                                       (int)inputCount, (int)outputCount);
      OnnxRelease(sessionHandle);
      return false;
   }

   string inputTensorName  = OnnxGetInputName(sessionHandle, 0);
   string outputTensorName = OnnxGetOutputName(sessionHandle, 0);
   if(inputTensorName != MLQUANTAI_ONNX_INPUT_TENSOR_NAME)
   {
      outReasonCode = INPUT_SCHEMA_MISMATCH;
      outReasonDetail = "expected input tensor name '" + MLQUANTAI_ONNX_INPUT_TENSOR_NAME +
                         "', got '" + inputTensorName + "'";
      OnnxRelease(sessionHandle);
      return false;
   }
   if(outputTensorName != MLQUANTAI_ONNX_OUTPUT_TENSOR_NAME)
   {
      outReasonCode = OUTPUT_SCHEMA_MISMATCH;
      outReasonDetail = "expected output tensor name '" + MLQUANTAI_ONNX_OUTPUT_TENSOR_NAME +
                         "', got '" + outputTensorName + "'";
      OnnxRelease(sessionHandle);
      return false;
   }

   // UNVERIFIED FIELD NAMES (see file header): OnnxTypeInfo.type,
   // .shape.dimensions - best-effort against the documented function
   // list, not confirmed field-by-field against a live struct
   // definition.
   OnnxTypeInfo inputTypeInfo, outputTypeInfo;
   if(!OnnxGetInputTypeInfo(sessionHandle, 0, inputTypeInfo))
   {
      outReasonCode = RUNTIME_UNAVAILABLE;
      outReasonDetail = "OnnxGetInputTypeInfo failed (GetLastError=" + IntegerToString(GetLastError()) + ")";
      OnnxRelease(sessionHandle);
      return false;
   }
   if(!OnnxGetOutputTypeInfo(sessionHandle, 0, outputTypeInfo))
   {
      outReasonCode = RUNTIME_UNAVAILABLE;
      outReasonDetail = "OnnxGetOutputTypeInfo failed (GetLastError=" + IntegerToString(GetLastError()) + ")";
      OnnxRelease(sessionHandle);
      return false;
   }

   if(inputTypeInfo.type != ONNX_DATA_TYPE_FLOAT)
   {
      outReasonCode = INPUT_TYPE_MISMATCH;
      outReasonDetail = "expected input tensor data type FLOAT";
      OnnxRelease(sessionHandle);
      return false;
   }
   if(outputTypeInfo.type != ONNX_DATA_TYPE_FLOAT)
   {
      outReasonCode = OUTPUT_TYPE_MISMATCH;
      outReasonDetail = "expected output tensor data type FLOAT";
      OnnxRelease(sessionHandle);
      return false;
   }

   int inputRank  = ArraySize(inputTypeInfo.shape.dimensions);
   int outputRank = ArraySize(outputTypeInfo.shape.dimensions);
   bool inputShapeOk = (inputRank == 2 &&
                         inputTypeInfo.shape.dimensions[0] == MLQUANTAI_ONNX_BATCH_SIZE &&
                         inputTypeInfo.shape.dimensions[1] == MLQUANTAI_INFERENCE_INPUT_LENGTH_B8_1_V1);
   if(!inputShapeOk)
   {
      outReasonCode = INPUT_SHAPE_MISMATCH;
      outReasonDetail = StringFormat("expected input shape [1,%d], got rank %d",
                                       MLQUANTAI_INFERENCE_INPUT_LENGTH_B8_1_V1, inputRank);
      OnnxRelease(sessionHandle);
      return false;
   }

   bool outputShapeOk = (outputRank == 2 &&
                          outputTypeInfo.shape.dimensions[0] == MLQUANTAI_ONNX_BATCH_SIZE &&
                          outputTypeInfo.shape.dimensions[1] == 1);
   if(!outputShapeOk)
   {
      outReasonCode = OUTPUT_SHAPE_MISMATCH;
      outReasonDetail = StringFormat("expected output shape [1,1], got rank %d", outputRank);
      OnnxRelease(sessionHandle);
      return false;
   }

   if(ArraySize(canonicalVector) != MLQUANTAI_INFERENCE_INPUT_LENGTH_B8_1_V1)
   {
      outReasonCode = INPUT_SHAPE_MISMATCH;
      outReasonDetail = "canonicalVector length does not match the frozen 12-element contract";
      OnnxRelease(sessionHandle);
      return false;
   }

   matrixf inputMatrix(MLQUANTAI_ONNX_BATCH_SIZE, MLQUANTAI_INFERENCE_INPUT_LENGTH_B8_1_V1);
   for(int i = 0; i < MLQUANTAI_INFERENCE_INPUT_LENGTH_B8_1_V1; i++)
      inputMatrix[0][i] = canonicalVector[i];

   matrixf outputMatrix;
   bool ranOk = OnnxRun(sessionHandle, 0, inputMatrix, outputMatrix);
   OnnxRelease(sessionHandle); // the session never outlives this call, success or failure

   if(!ranOk)
   {
      outReasonCode = INFERENCE_FAILED;
      outReasonDetail = "OnnxRun failed (GetLastError=" + IntegerToString(GetLastError()) + ")";
      return false;
   }

   int producedCols = (int)outputMatrix.Cols();
   ArrayResize(outRawOutput, producedCols);
   for(int i = 0; i < producedCols; i++)
      outRawOutput[i] = outputMatrix[0][i];

   return true;
}

#endif // __MLQUANTAI_MODELRUNTIMEADAPTER_MQH__
