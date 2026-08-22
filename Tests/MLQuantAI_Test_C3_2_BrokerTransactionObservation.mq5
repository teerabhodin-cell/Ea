//+------------------------------------------------------------------+
//| MLQuantAI_Test_C3_2_BrokerTransactionObservation.mq5              |
//| C3.2 implementation DoD, per                                       |
//| Docs/PhaseC_C3_TransactionReconciliationContract.md sections       |
//| 10-19. Fixture-only, per section 18's finding: MQL5 gives no way   |
//| to synthesize a real OnTradeTransaction callback under a test       |
//| harness, so every case here constructs a plain, in-memory           |
//| MqlTradeTransaction/MqlTradeResult struct directly and feeds it     |
//| straight to the real, pure functions under test - the same          |
//| fixture-fed-pure-function pattern already established by            |
//| MLQuantAI_Test_BrokerReconciliation.mq5.                             |
//|                                                                     |
//| No OnTradeTransaction callback is invoked anywhere in this file -   |
//| MQL5 provides no way to trigger one from a script. No OrderSend,     |
//| no History*/PositionSelect/OrderSelect call, no candidate ever       |
//| constructed or mutated.                                              |
//+------------------------------------------------------------------+
#property copyright "MLQuantAI"
#property script_show_inputs

#include <MLQuantAI/Execution/MLQuantAI_BrokerTransactionObservation.mqh>

#define TEST_FILE "MLQuantAI_Test_C3_2_BrokerTransactionObservation.jsonl"

int g_TestsRun    = 0;
int g_TestsPassed = 0;

void Check(bool cond, string label)
{
   g_TestsRun++;
   if(cond) { g_TestsPassed++; Print("  [PASS] ", label); }
   else               Print("  [FAIL] ", label);
}

//---------------------------------------------------------------------
// Fixture helpers
//---------------------------------------------------------------------
// MqlTradeTransaction/MqlTradeResult contain string members (symbol;
// comment) - MQL5's string type is a reference-counted handle, not raw
// bytes, so ZeroMemory() on a struct containing one does not reliably
// leave it as "" (already documented and empirically confirmed by a
// real MetaEditor run - see Execution/MLQuantAI_BrokerSubmissionBuilder.
// mqh's MqlTradeRequest_ZeroInit). Manual field-by-field init avoids
// that platform pitfall entirely, same precedent.
void MakeTrans(MqlTradeTransaction &t, ENUM_TRADE_TRANSACTION_TYPE type, ulong deal, ulong order,
                ulong position, ulong positionBy, string symbol, double price, double volume)
{
   t.type            = type;
   t.deal            = deal;
   t.order           = order;
   t.symbol          = symbol;
   t.order_type      = ORDER_TYPE_BUY;
   t.order_state     = ORDER_STATE_FILLED;
   t.deal_type       = DEAL_TYPE_BUY;
   t.time_type       = ORDER_TIME_GTC;
   t.time_expiration = 0;
   t.price           = price;
   t.price_trigger   = 0.0;
   t.price_sl        = 0.0;
   t.price_tp        = 0.0;
   t.volume          = volume;
   t.position        = position;
   t.position_by     = positionBy;
}

void MakeResult(MqlTradeResult &r, uint requestId)
{
   r.retcode          = 0;
   r.deal             = 0;
   r.order             = 0;
   r.volume            = 0;
   r.price             = 0;
   r.bid               = 0;
   r.ask               = 0;
   r.comment           = "";
   r.request_id        = requestId;
   r.retcode_external  = 0;
}

void MakeEmptyRequest(MqlTradeRequest &req)
{
   req.action        = (ENUM_TRADE_REQUEST_ACTIONS)0;
   req.magic         = 0;
   req.order         = 0;
   req.symbol        = "";
   req.volume        = 0;
   req.price         = 0;
   req.stoplimit     = 0;
   req.sl            = 0;
   req.tp            = 0;
   req.deviation     = 0;
   req.type          = ORDER_TYPE_BUY;
   req.type_filling  = ORDER_FILLING_FOK;
   req.type_time     = ORDER_TIME_GTC;
   req.expiration    = 0;
   req.comment       = "";
   req.position      = 0;
   req.position_by   = 0;
}

void ResetTestFile()
{
   EventStore_Close();
   SafeMode_Clear();
   if(FileIsExist(TEST_FILE, FILE_COMMON))
      FileDelete(TEST_FILE, FILE_COMMON);
}

//---------------------------------------------------------------------
// ENUM_EVENT_TYPE: append-only insertion point + ToString/FromString
//---------------------------------------------------------------------
void Test_EnumAppendOnly_AndRoundTrip()
{
   Print("--- Test_EnumAppendOnly_AndRoundTrip ---");
   Check((int)EVENT_TYPE_BROKER_TRANSACTION_OBSERVED == (int)EVENT_TYPE_EXECUTION_MANUAL_APPROVAL_GRANTED + 1,
         "BROKER_TRANSACTION_OBSERVED is appended immediately after the prior last enum value (append-only, section 2/18)");
   Check(EventTypeToString(EVENT_TYPE_BROKER_TRANSACTION_OBSERVED) == "BROKER_TRANSACTION_OBSERVED",
         "EventTypeToString maps the new value to \"BROKER_TRANSACTION_OBSERVED\"");
   Check(EventTypeFromString("BROKER_TRANSACTION_OBSERVED") == EVENT_TYPE_BROKER_TRANSACTION_OBSERVED,
         "EventTypeFromString round-trips back to the enum value (no ToString/FromString drift)");
}

//---------------------------------------------------------------------
// Trust boundary (section 12): trans is the only reliable evidence;
// request_id is read ONLY for TRADE_TRANSACTION_REQUEST.
//---------------------------------------------------------------------
void Test_EnvelopeBuild_RequestType_IncludesRequestId()
{
   Print("--- Test_EnvelopeBuild_RequestType_IncludesRequestId ---");
   MqlTradeTransaction t;
   MakeTrans(t, TRADE_TRANSACTION_REQUEST, 111, 222, 333, 444, "XAUUSD", 1900.50, 0.10);
   MqlTradeResult r;
   MakeResult(r, 9999);

   BrokerTransactionEnvelope env;
   BrokerTransactionEnvelope_Build(t, r, env);

   Check(env.request_id == "9999", "request_id is captured from result.request_id for TRADE_TRANSACTION_REQUEST");
   Check(env.deal_ticket == 111 && env.order_ticket == 222 && env.position_ticket == 333 && env.position_by_ticket == 444,
         "ticket fields are captured directly from trans");
   Check(env.symbol == "XAUUSD" && env.price == 1900.50 && env.volume == 0.10,
         "symbol/price/volume are captured directly from trans");
   Check(env.transaction_type == "TRADE_TRANSACTION_REQUEST", "transaction_type is EnumToString(trans.type)");
}

void Test_EnvelopeBuild_NonRequestType_RequestIdNotApplicable()
{
   Print("--- Test_EnvelopeBuild_NonRequestType_RequestIdNotApplicable ---");
   MqlTradeTransaction t;
   MakeTrans(t, TRADE_TRANSACTION_DEAL_ADD, 555, 666, 777, 0, "EURUSD", 1.0850, 0.20);
   MqlTradeResult r;
   MakeResult(r, 12345); // deliberately non-zero - proves this is NOT read for a non-REQUEST transaction

   BrokerTransactionEnvelope env;
   BrokerTransactionEnvelope_Build(t, r, env);

   Check(env.request_id == BROKER_TX_NOT_APPLICABLE,
         "request_id is the explicit not_applicable sentinel for a non-REQUEST transaction, never a fabricated/zero value");
   Check(env.deal_ticket == 555 && env.order_ticket == 666 && env.position_ticket == 777,
         "ticket fields are still captured directly from trans for a non-REQUEST transaction");
   Check(env.transaction_type == "TRADE_TRANSACTION_DEAL_ADD", "transaction_type reflects the real fixture type");
}

//---------------------------------------------------------------------
// Append success: exactly one event, Safe Mode unchanged
//---------------------------------------------------------------------
void Test_RecordAndGuard_Success_OneEventNoSafeMode()
{
   Print("--- Test_RecordAndGuard_Success_OneEventNoSafeMode ---");
   ResetTestFile();
   Check(EventStore_Open(TEST_FILE), "EventStore opens for this test");
   SafeMode_Clear();

   MqlTradeTransaction t;
   MakeTrans(t, TRADE_TRANSACTION_DEAL_ADD, 1001, 2002, 3003, 0, "XAUUSD", 1901.00, 0.10);
   MqlTradeRequest req;
   MakeEmptyRequest(req);
   MqlTradeResult r;
   MakeResult(r, 0);

   bool ok = BrokerTransactionObservation_RecordAndGuard(t, req, r);

   Check(ok == true, "RecordAndGuard returns true on a successful durable append");
   Check(!SafeMode_IsActive(), "Safe Mode remains unchanged (inactive) after a successful append");

   string lines[];
   int n = EventStore_ReadAllLines(TEST_FILE, lines);
   Check(n == 1, "exactly one line was durably written for one callback invocation");
   if(n == 1)
   {
      Check(EventSerializer_GetStr(lines[0], "type") == "BROKER_TRANSACTION_OBSERVED",
            "the written line's own type field is BROKER_TRANSACTION_OBSERVED");
      Check(EventSerializer_GetLong(lines[0], "deal_ticket") == 1001,
            "deal_ticket round-trips through the actually-written line");
      Check(EventSerializer_GetLong(lines[0], "order_ticket") == 2002,
            "order_ticket round-trips through the actually-written line");
      Check(EventSerializer_GetStr(lines[0], "request_id") == "not_applicable",
            "request_id is the not_applicable sentinel in the actual written line for this non-REQUEST fixture");
   }
   EventStore_Close();
}

//---------------------------------------------------------------------
// Append failure / unopened EventStore: Safe Mode trips, no retry
// (section 19: "EventStore not open" and "append fails" are the SAME
// EventStore_WriteLine guard/code path - one test covers both)
//---------------------------------------------------------------------
void Test_RecordAndGuard_AppendFailure_TripsSafeMode_NoRetry()
{
   Print("--- Test_RecordAndGuard_AppendFailure_TripsSafeMode_NoRetry ---");
   ResetTestFile(); // leaves EventStore closed (g_EventStore_Handle == INVALID_HANDLE) and Safe Mode clear

   MqlTradeTransaction t;
   MakeTrans(t, TRADE_TRANSACTION_DEAL_ADD, 4004, 5005, 0, 0, "XAUUSD", 1902.00, 0.10);
   MqlTradeRequest req;
   MakeEmptyRequest(req);
   MqlTradeResult r;
   MakeResult(r, 0);

   bool ok = BrokerTransactionObservation_RecordAndGuard(t, req, r);

   Check(ok == false, "RecordAndGuard returns false when the append could not be durably written");
   Check(SafeMode_IsActive(), "Safe Mode becomes active on a durability failure (section 17, frozen)");
   Check(SafeMode_Reason() == "broker transaction observation append failed",
         "Safe Mode carries the exact frozen reason string");

   // Single-attempt-bounded (section 19): a second, independent call
   // must not loop, must not silently recover, and leaves the SAME
   // reason string - consistent with each call making exactly one
   // append attempt, never a retry.
   bool ok2 = BrokerTransactionObservation_RecordAndGuard(t, req, r);
   Check(ok2 == false, "a second, independent call also fails closed - no silent recovery");
   Check(SafeMode_Reason() == "broker transaction observation append failed",
         "Safe Mode reason is unchanged after the second call - one attempt per call, never a retry loop");

   SafeMode_Clear();
}

void OnStart()
{
   Print("=== MLQuantAI C3.2 BrokerTransactionObservation test suite ===");
   Test_EnumAppendOnly_AndRoundTrip();
   Test_EnvelopeBuild_RequestType_IncludesRequestId();
   Test_EnvelopeBuild_NonRequestType_RequestIdNotApplicable();
   Test_RecordAndGuard_Success_OneEventNoSafeMode();
   Test_RecordAndGuard_AppendFailure_TripsSafeMode_NoRetry();

   ResetTestFile();
   Print(StringFormat("=== %d/%d tests passed ===", g_TestsPassed, g_TestsRun));
}
