//+------------------------------------------------------------------+
//|                     Quantix_Classic20_Visual_BasketTS_Virtual.mq5|
//|        Dual Mode Grid (Pending / Virtual) + Basket Trailing Stop |
//|        Extended Horizontal Dashboard with Account Panel          |
//|        [REMOVED: UI Performance Stats Engine]                    |
//|        [FIXED: Added m_multiplier so all *Points inputs scale    |
//|                correctly across 2/3/4/5-digit symbols instead of |
//|                being used as raw, un-adjusted points]            |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//=========================== ENUMS ================================//
enum ENUM_LANGUAGE
{
   LNG_TH, // ภาษาไทย (Thai)
   LNG_EN  // English
};

enum ENUM_GRID_TYPE
{
   GRID_VIRTUAL, // Virtual Grid (ซ่อน Pending ในโค้ด + ล็อค Slippage)
   GRID_PENDING  // Pending Order (ตั้ง Buy Stop / Sell Stop บน Server)
};

//=========================== INPUT ================================//
input group "--- Language Settings ---"
input ENUM_LANGUAGE Language = LNG_TH; // Select Language ( default: Thai )

input group "--- Trading Hours (เวลาเปิด-ปิด บอท) ---"
input bool    UseTimer         = true;    // เปิดใช้งานระบบคุมเวลา (Enable Time Filter)
input int     StartHour        = 2;       // เวลาเริ่มทำงาน (เวลา Server)
input int     StartMinute      = 0;
input int     EndHour          = 23;      // เวลาหยุดทำงาน (เวลา Server)
input int     EndMinute        = 0;

input group "--- Grid Settings ---"
input ENUM_GRID_TYPE GridType       = GRID_VIRTUAL; // เลือกรูปแบบ Grid ( Virtual หรือ Pending )
input double BaseLot                = 0.01;
input double LotMultiplier          = 2.0;
input bool   UseATRDistance         = true;    // เปิดใช้ระยะ Grid ตามค่า ATR
input int    ATR_Period             = 14;      // รอบคำนวณ ATR (Period)
input double ATR_Multiplier         = 1.5;     // ตัวคูณ ATR เช่น 1.5 เท่าของ ATR
input int    DistancePoints         = 300;     // ระยะห่าง Fixed Points (ใช้กรณีปิด UseATRDistance)
input int    TotalLevels            = 10;      // จำนวนชั้นต่อฝั่ง (10 Buy Stop + 10 Sell Stop)
input ulong  MagicNumber            = 112233;

input group "--- Adaptive ATR Grid ---"
input bool   UseAdaptiveATRGrid     = false;   // เปิดใช้ระบบปรับระยะ Grid ตามความผันผวนอัตโนมัติ (ขยายระยะ Grid เมื่อ Drawdown สูงขึ้น)

input group "--- Trend Filter (EMA Anti-Sideway) ---"
input bool   UseEMAFilter           = true;    // เปิดใช้ตัวกรองเทรนด์ EMA
input int    EMA_Period             = 200;     // Period ของเส้น EMA
input bool   StrictBuyFilter        = true;    // ล็อคฝั่ง Buy: ห้ามเปิด Buy หากราคาอยู่ต่ำกว่า EMA
input bool   StrictSellFilter       = true;    // ล็อคฝั่ง Sell: ห้ามเปิด Sell หากราคาอยู่เหนือ EMA

input group "--- Multi Timeframe Filter ---"
input bool   UseMTFFilter          = false;   // เปิดใช้ตัวกรองเทรนด์จาก Timeframe สูงกว่า (ตั้ง MTF_Period ให้สูงกว่า Timeframe ของกราฟที่แปะ EA จริงๆ ไม่งั้นจะซ้ำกับ EMA filter หลัก)
input ENUM_TIMEFRAMES MTF_Period   = PERIOD_H1; // Timeframe ที่ใช้กรองเทรนด์หลัก

input group "--- ADX Filter ---"
input bool   UseADXFilter           = false;   // เปิดใช้ตัวกรองความแรงเทรนด์ ADX
input int    ADX_Period             = 14;      // Period ของ ADX
input double ADX_MinLevel           = 25.0;    // ค่า ADX ขั้นต่ำเพื่อยืนยันว่ามีเทรนด์

input group "--- RSI Filter ---"
input bool   UseRSIFilter           = false;   // เปิดใช้ตัวกรอง RSI
input int    RSI_Period             = 14;      // Period ของ RSI
input double RSI_BuyMax             = 70.0;    // ค่า RSI สูงสุดที่จะอนุญาตให้เปิด Buy (ป้องกันซื้อตอน Overbought เกินไป)
input double RSI_SellMin            = 30.0;    // ค่า RSI ต่ำสุดที่จะอนุญาตให้เปิด Sell (ป้องกันขายตอน Oversold เกินไป)

input group "--- Bollinger Bands Filter ---"
input bool   UseBollingerFilter     = false;   // เปิดใช้ตัวกรองกรอบราคา Bollinger Bands
input int    BB_Period              = 20;      // Period ของ Bollinger Bands
input double BB_Deviation           = 2.0;     // ค่า Standard Deviation

input group "--- Dynamic Lot & Capital Protection ---"
input bool   UseDynamicLot          = false;   // เปิดใช้งานการคำนวณ Lot อัตโนมัติตามขนาด Equity
input double BalancePerLot          = 10000.0; // สัดส่วนเงิน Equity ต่อ Lot เริ่มต้น 0.01
input bool   UseEquityLock          = false;   // เปิดระบบล็อคพอร์ตหยุดเปิดไม้ใหม่ทันทีหาก Equity ต่ำกว่ากำหนด
input double MinEquityLimit         = 500.0;   // ขีดจำกัด Equity ขั้นต่ำ หากต่ำกว่านี้จะหยุดเปิดไม้ใหม่

input group "--- Risk Management: Max Drawdown Stop ---"
input bool   UseMaxDDStop           = true;    // เปิดใช้งานระบบตัดขาดทุนฉุกเฉินเมื่อ Max DD เกินกำหนด
input double MaxAllowedDD_USD       = 50.0;    // ยอมให้ขาดทุนสูงสุดเป็นเงิน ($) ถ้าเกินจะปิดทิ้งทั้งหมดทันที (ตั้งเป็น 0 เพื่อปิดการเช็คแบบเงิน)
input double MaxAllowedDD_Pct       = 10.0;    // ยอมให้ขาดทุนสูงสุดเป็นเปอร์เซ็นต์ (%) จากยอด Balance สูงสุด (ตั้งเป็น 0 เพื่อปิดการเช็คแบบ %)

input group "--- Auto Reduce Lot on High DD ---"
input bool   UseAutoReduceLot       = false;   // เปิดใช้งานระบบลดขนาด Lot อัตโนมัติเมื่อ Drawdown สูงขึ้น
input double ReduceLotThresholdDD   = 5.0;     // เปอร์เซ็นต์ Drawdown ที่เริ่มสั่งลดขนาด Lot ลงครึ่งหนึ่ง

input group "--- Basket Management & Recovery (Developed) ---"
input bool   UseBasketBreakeven     = true;    // เปิดระบบขยับจุดคุ้มทุน (Breakeven / ล็อคกำไรบางส่วน)
input double BreakevenTriggerUSD    = 10.0;    // กำไรขั้นต่ำที่จะเริ่มเปิดใช้งานระบบ Breakeven
input double BreakevenLockUSD       = 3.0;     // กำไรขั้นต่ำที่จะต้องเหลือล็อกไว้เมื่อราคาถอยกลับ
input bool   UsePartialClose        = true;    // เปิดใช้งานระบบทยอยปิดทำกำไรบางส่วน (Partial Close)
input double PartialCloseProfitUSD  = 15.0;    // กำไรที่ถึงเป้าแล้วสั่งปิดครึ่งหนึ่งของไม้ทั้งหมด
input double PartialClosePercent    = 50.0;    // สัดส่วนเปอร์เซ็นต์ของออเดอร์ที่จะปิด (เช่น 50%)
input bool   UseRecoveryMode        = false;   // เปิดใช้งานโหมดแก้ไม้ (Recovery Mode) เร่งเก็บบาสเกตเมื่อพอร์ตติดลบสะสม

input group "--- Execution & Gap/Slippage Protection ---"
input bool   UseGapProtection    = true;   // เปิด/ปิด การเช็ค Gap ราคาโดด (Enable Gap Check)
input int    MaxAllowedGapPoints = 100;    // Gap ยอมรับได้สูงสุด (Points) ถ้าราคาโดดข้ามจะทำการ Reset
input int    MaxSlippagePoints   = 20;     // ล็อค Slippage สูงสุด (Points) แนะนำ 20-30 เพื่อให้รวบติดชัวร์
input int    MaxSpreadAllowed    = 40;     // (Virtual Mode) สเปรดสูงสุดที่อนุญาตให้เปิดไม้ (Points)

input group "--- Basket Profit Target (Trailing) ---"
input double TargetProfit        = 1.0;    // Minimum Profit ($) to activate Trailing
input double TrailingStopUSD     = 0.5;    // Trailing Distance ($)
input double ProfitFloorPercent  = 0.30;   // Safety Floor % ล็อกทุนขั้นต่ำ (30%)

input group "--- PRO TERMINAL UI CUSTOMIZE ---"
input color  UI_MainBG        = C'18, 20, 28';    // Main BG Color (Dark Navy)
input color  UI_Shadow        = C'5, 5, 5';       // Shadow Color (Drop Shadow)
input color  UI_Accent        = C'33, 150, 243';  // Border & Progress Bar Color (Blue)
input color  UI_PanelBG       = C'26, 30, 41';    // Sub-Panel BG Color
input color  UI_TextDim       = C'140, 150, 170'; // Secondary Text Color
input color  UI_Profit        = C'0, 230, 118';   // Bright Green
input color  UI_Loss          = C'255, 61, 113';  // Bright Red

//=========================== GLOBAL ===============================//

bool     GridCreated     = false;
double   MaxBasketProfit = 0.0;
string   LineObjectName  = "Basket_TS_Line";

int      m_multiplier    = 1; // 10 for 3/5-digit (fractional-pip) symbols, 1 otherwise - keeps every *Points input meaning the same real price distance across symbols

// ตัวแประบบ Grid
double   GridBasePrice      = 0.0;
double   GridBasePriceBuy   = 0.0;    // anchor ของฝั่ง Buy สำหรับ level แรก (buyCount==0) แยกต่างหาก กัน gap-skip ของฝั่งหนึ่งไปกระทบอีกฝั่ง
double   GridBasePriceSell  = 0.0;    // anchor ของฝั่ง Sell สำหรับ level แรก (sellCount==0) แยกต่างหาก
double   BuyGapAnchor        = 0.0;   // persistent override สำหรับ level 2+ (lastBuyPrice เป็น local var คำนวณจากไม้จริงทุกครั้ง แก้ไขไม่ติดข้ามทิค ต้องมีตัวนี้แทน)
double   SellGapAnchor       = 0.0;   // persistent override สำหรับ level 2+ ฝั่ง Sell เช่นกัน
int      CachedGridDistance = 0;

// ป้องกันการยิงเบิ้ล & คุมสภาวะกำลังปิดพอร์ต (Closing Guard)
datetime LastOrderSentTime  = 0;
datetime LastCloseAllTime   = 0;    // เวลาปิดพอร์ตล่าสุด
bool     IsClosingState     = false;  // สถานะกำลังปิดพอร์ต ล็อคไม่ให้ยิงไม้ใหม่เด็ดขาด

// ตัวแปรสำหรับคำนวณ Max Drawdown (%) และ ($)
double   PeakBalanceForDD   = 0.0;
double   MaxDrawdownPercent = 0.0;
double   MaxDrawdownUSD     = 0.0;

// Basket Management & Recovery
bool     PartialCloseExecuted = false; // ป้องกันการสั่งปิดบางส่วนซ้ำรอบเดิม
bool     BreakevenActivated   = false; // latch เมื่อกำไรแตะ BreakevenTriggerUSD แล้ว (ต้อง latch ไว้ก่อน ไม่งั้นเงื่อนไข Trigger/Lock จะไม่มีวันเป็นจริงพร้อมกัน)

string   UI_PREFIX       = "QX_PRO_";
string   BTN_CLOSE_ALL   = "QX_PRO_BtnCloseAll";

// Handle สำหรับอินดิเคเตอร์ ATR / EMA / Multi-Timeframe EMA / ADX / RSI / Bollinger Bands
int      atrHandle       = INVALID_HANDLE;
int      emaHandle       = INVALID_HANDLE;
int      mtfEmaHandle    = INVALID_HANDLE;
int      adxHandle       = INVALID_HANDLE;
int      rsiHandle       = INVALID_HANDLE;
int      bbHandle        = INVALID_HANDLE;

// --- [ UI OPTIMIZATION GLOBAL VARS ] ---
uint     lastUIUpdateTime = 0;
bool     IsTestingMode    = false; // true in Strategy Tester - skips all dashboard object creation/updates to speed up backtests

datetime lastFilterBlockLogTime = 0; // throttles the "why didn't it open" filter diagnostic to once/minute
datetime lastGapLogTime         = 0; // throttles the GAP EXCEEDED re-anchor messages so a choppy market can't spam the Journal every tick

//====================== FUNCTION DECLARE ==========================//

bool IsTradingAllowedByTime();
bool CheckEMATrend(bool isBuy);
bool CheckMTFFilter(bool isBuy);
bool CheckADXFilter(bool isBuy);
bool CheckRSIFilter(bool isBuy);
bool CheckBollingerFilter(bool isBuy);
double GetCalculatedLotSize(int nextLevel);
void ApplyBasketBreakevenAndPartial(double currentProfit);
void LogFilterBlockReason(bool isBuy);
void ExecuteGridLogic();
void PlacePendingGridServer();
void CheckAndExecuteVirtualGrid();
void DeleteAllPendingOrders();
void ClearEverythingAsync();
void DrawVisualTSLine(double tsValue);
void DeleteVisualTSLine();

void UpdateDrawdownTracker();

int GetDynamicGridDistance();
void RecalculateBasePrice();
ENUM_ORDER_TYPE_FILLING GetBestFillingMode();

// UI Engine Functions
void InitDashboard();
void DeleteDashboard();
void UpdateDashboard(double currentProfit, double maxProfit, double currentTS, int openPos, int pendingOrders);
void CreateLabel(string name, int x, int y, string text, int size = 9, color clr = clrWhite, string font = "");
void CreatePanel(string name, int x, int y, int w, int h, color bgClr, color borderClr);
void CreateButton(string name, int x, int y, int w, int h, string text, color bgClr, color textClr, int fontSize = 9);
string GetUIString(string thText, string enText);
string GetUIFont();

//+------------------------------------------------------------------+
//| Get Compatible Filling Mode Function                             |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetBestFillingMode()
{
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Force Reset Base Price directly to Current Market Price          |
//+------------------------------------------------------------------+
void RecalculateBasePrice()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   GridBasePrice = NormalizeDouble((ask + bid) / 2.0, _Digits);
   GridBasePriceBuy  = GridBasePrice;
   GridBasePriceSell = GridBasePrice;
   BuyGapAnchor  = 0.0; // every call here means a fresh/flat grid, so any stale gap override is no longer relevant
   SellGapAnchor = 0.0;
   CachedGridDistance = GetDynamicGridDistance();
   GridCreated = true;
}

//+------------------------------------------------------------------+
//| Check Trading Hours Function                                     |
//+------------------------------------------------------------------+
bool IsTradingAllowedByTime()
{
   if(!UseTimer) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   int currentMinutes = dt.hour * 60 + dt.min;
   int startMinutes   = StartHour * 60 + StartMinute;
   int endMinutes     = EndHour * 60 + EndMinute;

   if(startMinutes <= endMinutes)
   {
      return (currentMinutes >= startMinutes && currentMinutes < endMinutes);
   }
   else
   {
      return (currentMinutes >= startMinutes || currentMinutes < endMinutes);
   }
}

//+------------------------------------------------------------------+
//| Check EMA Trend Filter                                           |
//+------------------------------------------------------------------+
bool CheckEMATrend(bool isBuy)
{
   if(!UseEMAFilter || emaHandle == INVALID_HANDLE) return true;

   double emaValues[];
   ArraySetAsSeries(emaValues, true);
   if(CopyBuffer(emaHandle, 0, 1, 1, emaValues) <= 0) return true;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(isBuy)
   {
      if(StrictBuyFilter && ask < emaValues[0]) return false;
      return true;
   }
   else
   {
      if(StrictSellFilter && bid > emaValues[0]) return false;
      return true;
   }
}

//+------------------------------------------------------------------+
//| Multi Timeframe Filter Check                                     |
//+------------------------------------------------------------------+
bool CheckMTFFilter(bool isBuy)
{
   if(!UseMTFFilter || mtfEmaHandle == INVALID_HANDLE) return true;
   double mtfVals[];
   ArraySetAsSeries(mtfVals, true);
   if(CopyBuffer(mtfEmaHandle, 0, 1, 1, mtfVals) <= 0) return true;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(isBuy) return (ask >= mtfVals[0]);
   else      return (bid <= mtfVals[0]);
}

//+------------------------------------------------------------------+
//| ADX Filter Check                                                 |
//+------------------------------------------------------------------+
bool CheckADXFilter(bool isBuy)
{
   if(!UseADXFilter || adxHandle == INVALID_HANDLE) return true;
   double adxVals[];
   ArraySetAsSeries(adxVals, true);
   if(CopyBuffer(adxHandle, 0, 1, 1, adxVals) <= 0) return true;
   return (adxVals[0] >= ADX_MinLevel);
}

//+------------------------------------------------------------------+
//| RSI Filter Check                                                 |
//+------------------------------------------------------------------+
bool CheckRSIFilter(bool isBuy)
{
   if(!UseRSIFilter || rsiHandle == INVALID_HANDLE) return true;
   double rsiVals[];
   ArraySetAsSeries(rsiVals, true);
   if(CopyBuffer(rsiHandle, 0, 1, 1, rsiVals) <= 0) return true;

   if(isBuy) return (rsiVals[0] <= RSI_BuyMax);
   else      return (rsiVals[0] >= RSI_SellMin);
}

//+------------------------------------------------------------------+
//| Bollinger Bands Filter Check                                     |
//+------------------------------------------------------------------+
bool CheckBollingerFilter(bool isBuy)
{
   if(!UseBollingerFilter || bbHandle == INVALID_HANDLE) return true;
   double upperVals[], lowerVals[];
   ArraySetAsSeries(upperVals, true);
   ArraySetAsSeries(lowerVals, true);
   if(CopyBuffer(bbHandle, 1, 1, 1, upperVals) <= 0) return true;
   if(CopyBuffer(bbHandle, 2, 1, 1, lowerVals) <= 0) return true;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(isBuy) return (ask >= lowerVals[0]);
   else      return (bid <= upperVals[0]);
}

//+------------------------------------------------------------------+
//| Diagnostic: which filter(s) are blocking Buy/Sell right now      |
//| Without this, "why doesn't it open a position" is unanswerable   |
//| from the dashboard alone - the entry gate is a silent AND of up  |
//| to 5 filters, and the wait target line looks the same whether    |
//| price hasn't reached it yet or a filter is vetoing it forever.   |
//| Throttled to once/minute per direction so it doesn't spam.       |
//+------------------------------------------------------------------+
void LogFilterBlockReason(bool isBuy)
{
   if(TimeCurrent() - lastFilterBlockLogTime < 60) return;

   string blockers = "";

   if(UseEMAFilter && emaHandle != INVALID_HANDLE)
   {
      double emaVals[];
      ArraySetAsSeries(emaVals, true);
      if(CopyBuffer(emaHandle, 0, 1, 1, emaVals) > 0)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(isBuy && StrictBuyFilter && ask < emaVals[0])
            blockers += StringFormat("EMA(Ask %.3f < %.3f) ", ask, emaVals[0]);
         if(!isBuy && StrictSellFilter && bid > emaVals[0])
            blockers += StringFormat("EMA(Bid %.3f > %.3f) ", bid, emaVals[0]);
      }
   }
   if(UseMTFFilter && !CheckMTFFilter(isBuy)) blockers += "MTF ";
   if(UseADXFilter && !CheckADXFilter(isBuy)) blockers += "ADX ";
   if(UseRSIFilter && !CheckRSIFilter(isBuy)) blockers += "RSI ";
   if(UseBollingerFilter && !CheckBollingerFilter(isBuy)) blockers += "Bollinger ";

   if(blockers == "") return; // nothing actually blocked it - price just hasn't reached the target yet

   lastFilterBlockLogTime = TimeCurrent();
   PrintFormat("🔍 [%s BLOCKED] %s", isBuy ? "BUY" : "SELL", blockers);
}

//+------------------------------------------------------------------+
//| Dynamic Lot Calculation & Auto Reduction                         |
//| Rounds to the symbol's actual volume step and clamps to          |
//| SYMBOL_VOLUME_MIN/MAX so OrderSend can't be rejected with an      |
//| invalid-volume error on brokers whose lot step isn't 0.01.       |
//+------------------------------------------------------------------+
double GetCalculatedLotSize(int nextLevel)
{
   double base = BaseLot;
   if(UseDynamicLot)
   {
      double currentEq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(BalancePerLot > 0)
      {
         base = NormalizeDouble((currentEq / BalancePerLot) * BaseLot, 2);
         if(base < 0.01) base = 0.01;
      }
   }

   double lot = base * MathPow(LotMultiplier, nextLevel - 1);

   if(UseAutoReduceLot && MaxDrawdownPercent >= ReduceLotThresholdDD)
   {
      lot = lot * 0.5;
   }

   if(UseRecoveryMode)
   {
      lot = lot * 1.2;
   }

   lot = MathMax(0.01, lot);

   double minVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(stepVol > 0) lot = MathRound(lot / stepVol) * stepVol;
   if(minVol  > 0 && lot < minVol) lot = minVol;
   if(maxVol  > 0 && lot > maxVol) lot = maxVol;

   int volDigits = 2;
   if(stepVol >= 1.0)      volDigits = 0;
   else if(stepVol >= 0.1) volDigits = 1;

   return NormalizeDouble(lot, volDigits);
}

//+------------------------------------------------------------------+
//| Basket Breakeven and Partial Close Manager                       |
//| BreakevenActivated latches once profit crosses BreakevenTriggerUSD|
//| and only then arms the close-on-retrace-to-Lock check - checking  |
//| ">= Trigger AND <= Lock" in the same tick would never be true     |
//| whenever Lock < Trigger (the normal configuration).                |
//+------------------------------------------------------------------+
void ApplyBasketBreakevenAndPartial(double currentProfit)
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();

   if(UsePartialClose && !PartialCloseExecuted && currentProfit >= PartialCloseProfitUSD)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionSelectByTicket(ticket))
         {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
               double volume = PositionGetDouble(POSITION_VOLUME);
               double targetCloseVol = NormalizeDouble(volume * (PartialClosePercent / 100.0), 2);

               if(targetCloseVol < 0.01) targetCloseVol = 0.01;
               if(targetCloseVol >= volume) targetCloseVol = volume;

               ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
               ENUM_ORDER_TYPE tradeType = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
               double closePrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

               if(closePrice > 0)
               {
                  ZeroMemory(request); ZeroMemory(result);
                  request.action       = TRADE_ACTION_DEAL;
                  request.position     = ticket;
                  request.symbol       = _Symbol;
                  request.volume       = targetCloseVol;
                  request.type         = tradeType;
                  request.price        = closePrice;
                  request.deviation    = MaxSlippagePoints * m_multiplier;
                  request.magic        = MagicNumber;
                  request.type_filling = fillMode;

                  if(!OrderSend(request, result))
                  {
                     Print("Partial Close Failed for Ticket: ", ticket, " Code: ", result.retcode);
                  }
               }
            }
         }
      }
      PartialCloseExecuted = true;
   }

   if(UseBasketBreakeven)
   {
      if(!BreakevenActivated && currentProfit >= BreakevenTriggerUSD)
      {
         BreakevenActivated = true;
      }

      if(BreakevenActivated && currentProfit <= BreakevenLockUSD)
      {
         IsClosingState = true;
         ClearEverythingAsync();
         DeleteVisualTSLine();
         RecalculateBasePrice();
         IsClosingState = false;
         LastCloseAllTime = TimeCurrent();
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   IsTestingMode = (bool)MQLInfoInteger(MQL_TESTER);

   // FIXED: derive m_multiplier from the attached symbol's digit count so every
   // *Points input (DistancePoints, MaxSlippagePoints, MaxAllowedGapPoints,
   // MaxSpreadAllowed) keeps meaning the same real price distance whether the
   // symbol quotes 2, 3, 4, or 5 decimal places.
   if(_Digits == 3 || _Digits == 5) m_multiplier = 10;
   else m_multiplier = 1;

   trade.LogLevel(LOG_LEVEL_ERRORS);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints * m_multiplier);

   MaxBasketProfit    = 0.0;
   LastOrderSentTime  = 0;
   LastCloseAllTime   = 0;
   IsClosingState     = false;
   PartialCloseExecuted = false;
   BreakevenActivated   = false;
   PeakBalanceForDD   = AccountInfoDouble(ACCOUNT_BALANCE);
   MaxDrawdownPercent = 0.0;
   MaxDrawdownUSD     = 0.0;

   DeleteVisualTSLine();

   if(UseATRDistance)
   {
      atrHandle = iATR(_Symbol, _Period, ATR_Period);
      if(atrHandle == INVALID_HANDLE)
      {
         Print("Failed to create ATR indicator handle.");
         return(INIT_FAILED);
      }
   }

   if(UseEMAFilter)
   {
      emaHandle = iMA(_Symbol, _Period, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
      if(emaHandle == INVALID_HANDLE)
      {
         Print("Failed to create EMA indicator handle.");
         return(INIT_FAILED);
      }
   }

   if(UseMTFFilter)
   {
      mtfEmaHandle = iMA(_Symbol, MTF_Period, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
      if(mtfEmaHandle == INVALID_HANDLE)
      {
         Print("Failed to create Multi-Timeframe EMA indicator handle.");
         return(INIT_FAILED);
      }
   }

   if(UseADXFilter)
   {
      adxHandle = iADX(_Symbol, _Period, ADX_Period);
      if(adxHandle == INVALID_HANDLE)
      {
         Print("Failed to create ADX indicator handle.");
         return(INIT_FAILED);
      }
   }

   if(UseRSIFilter)
   {
      rsiHandle = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);
      if(rsiHandle == INVALID_HANDLE)
      {
         Print("Failed to create RSI indicator handle.");
         return(INIT_FAILED);
      }
   }

   if(UseBollingerFilter)
   {
      bbHandle = iBands(_Symbol, _Period, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
      if(bbHandle == INVALID_HANDLE)
      {
         Print("Failed to create Bollinger Bands indicator handle.");
         return(INIT_FAILED);
      }
   }

   RecalculateBasePrice();

   if(GridType == GRID_VIRTUAL)
   {
      DeleteAllPendingOrders();
   }

   InitDashboard();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);
   if(mtfEmaHandle != INVALID_HANDLE) IndicatorRelease(mtfEmaHandle);
   if(adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(bbHandle != INVALID_HANDLE) IndicatorRelease(bbHandle);
   DeleteVisualTSLine();
   DeleteDashboard();
}

//+------------------------------------------------------------------+
//| Trade Transaction Event                                          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result)
{
   // Transaction Hook (Reserved)
}

//+------------------------------------------------------------------+
//| Chart Event Handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == BTN_CLOSE_ALL)
      {
         IsClosingState = true;
         ClearEverythingAsync();
         DeleteVisualTSLine();
         RecalculateBasePrice();
         IsClosingState = false;

         ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_STATE, false);
         ChartRedraw();
      }
   }
}

//+------------------------------------------------------------------+
//| Expert Tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   bool equityLocked = (UseEquityLock && AccountInfoDouble(ACCOUNT_EQUITY) < MinEquityLimit);

   int    openPositions      = 0;
   int    pendingOrders      = 0;
   double currentProfit      = 0.0;

   // 1. Count Open Positions & Profit
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      openPositions++;
      currentProfit += PositionGetDouble(POSITION_PROFIT);
      currentProfit += PositionGetDouble(POSITION_SWAP);
   }

   // Count Pending Orders
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;

      pendingOrders++;
   }

   // ปลดล็อกสภาวะ Closing เมื่อพอร์ตเคลียร์เกลี้ยงจริง และเว้นระยะ Cooldown 3 วินาที
   if(openPositions == 0 && pendingOrders == 0)
   {
      if(IsClosingState)
      {
         IsClosingState = false;
         LastCloseAllTime = TimeCurrent();
      }
      if(PartialCloseExecuted) PartialCloseExecuted = false;
      if(BreakevenActivated) BreakevenActivated = false;

      // FIXED: previously the base price only got (re)calculated once, the very
      // first time GridCreated flipped true. If price then drifted far away while
      // the basket stayed flat (no trade ever opened), GridBasePrice stayed frozen
      // forever - the Wait BUY/SELL targets kept pointing at wherever the EA
      // happened to start, however far that got from the live market, so no order
      // could ever trigger again. Re-sync to the current price whenever it has
      // drifted more than 2 grid steps from the stale base, same as GridCreated
      // being false.
      double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

      if(ask > 0 && bid > 0 && GridBasePrice > 0)
      {
         double currentMid = (ask + bid) / 2.0;
         int currentDist = (CachedGridDistance > 0) ? CachedGridDistance : GetDynamicGridDistance();

         if(MathAbs(currentMid - GridBasePrice) > (currentDist * point * 2.0))
         {
            RecalculateBasePrice();
         }
      }

      if(!GridCreated)
      {
         RecalculateBasePrice();
      }
   }

   // 2. Visual Basket Trailing Stop
   if(openPositions > 0 && !IsClosingState)
   {
      if(UseBasketBreakeven || UsePartialClose)
      {
         ApplyBasketBreakevenAndPartial(currentProfit);
      }

      if(currentProfit >= TargetProfit)
      {
         if(currentProfit > MaxBasketProfit)
         {
            MaxBasketProfit = currentProfit;
         }

         double tsTriggerLine = MaxBasketProfit - TrailingStopUSD;

         // Safety Floor
         double minSafetyFloor = TargetProfit * ProfitFloorPercent;
         if(tsTriggerLine < minSafetyFloor) tsTriggerLine = minSafetyFloor;

         DrawVisualTSLine(tsTriggerLine);

         if(currentProfit <= tsTriggerLine)
         {
            IsClosingState = true;
            PrintFormat("🚨 [BASKET TS TRIGGERED] Peak: $%.2f | Floating: $%.2f | Floor: $%.2f",
                        MaxBasketProfit, currentProfit, minSafetyFloor);
            ClearEverythingAsync();
            DeleteVisualTSLine();
            RecalculateBasePrice();
            IsClosingState = false;
            return;
         }
      }
      else
      {
         DeleteVisualTSLine();
      }
   }
   else
   {
      MaxBasketProfit = 0.0;
      DeleteVisualTSLine();
   }

   // 3. Grid Logic Execution & Auto-Close on Time Filter
   bool timeAllowed = IsTradingAllowedByTime();

   if(timeAllowed)
   {
      if(!IsClosingState && !equityLocked && (MaxBasketProfit < TargetProfit) && (TimeCurrent() - LastCloseAllTime >= 3))
      {
         ExecuteGridLogic();
      }
   }
   else
   {
      // FIXED: only force-close outside trading hours when the basket is actually
      // in profit. Previously it closed everything unconditionally the moment the
      // clock ran out, locking in a loss even if the basket just needed a bit more
      // time to recover. If it's not profitable yet, just cancel the still-pending
      // grid orders (stop opening new legs) and leave existing positions open to
      // ride it out - Trailing Stop / Max DD Stop (if enabled) still apply as usual.
      if(!IsClosingState)
      {
         if(openPositions > 0 && currentProfit > 0)
         {
            IsClosingState = true;
            Print("⏰ [TIME FILTER] Outside trading hours and in profit -> Auto Closing all active positions...");
            ClearEverythingAsync();
            DeleteVisualTSLine();
            RecalculateBasePrice();
            IsClosingState = false;
         }
         else if(pendingOrders > 0)
         {
            DeleteAllPendingOrders();
         }
      }
   }

   // 4. Update Drawdown Tracker & HUD UI (Throttled Update: ทุกๆ 500ms)
   UpdateDrawdownTracker();

   uint now = GetTickCount();
   if(now - lastUIUpdateTime >= 500)
   {
      double currentTS = (MaxBasketProfit >= TargetProfit) ? (MaxBasketProfit - TrailingStopUSD) : 0.0;
      UpdateDashboard(currentProfit, MaxBasketProfit, currentTS, openPositions, pendingOrders);
      lastUIUpdateTime = now;
   }
}

//+------------------------------------------------------------------+
//| Update Max Drawdown Calculation                                 |
//+------------------------------------------------------------------+
void UpdateDrawdownTracker()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double currentEquity  = AccountInfoDouble(ACCOUNT_EQUITY);

   if(currentBalance > PeakBalanceForDD) PeakBalanceForDD = currentBalance;

   if(PeakBalanceForDD > 0)
   {
      double currentDDVal = PeakBalanceForDD - currentEquity;
      if(currentDDVal < 0) currentDDVal = 0;

      if(currentDDVal > MaxDrawdownUSD) MaxDrawdownUSD = currentDDVal;

      double currentDDPercent = (currentDDVal / PeakBalanceForDD) * 100.0;
      if(currentDDPercent > MaxDrawdownPercent) MaxDrawdownPercent = currentDDPercent;

      if(UseMaxDDStop && !IsClosingState)
      {
         bool triggerUSD = (MaxAllowedDD_USD > 0 && currentDDVal >= MaxAllowedDD_USD);
         bool triggerPct = (MaxAllowedDD_Pct > 0 && currentDDPercent >= MaxAllowedDD_Pct);

         if(triggerUSD || triggerPct)
         {
            IsClosingState = true;
            PrintFormat("🛑 [MAX DD STOP] DD: $%.2f (%.2f%%) exceeded limit -> Closing everything.",
                        currentDDVal, currentDDPercent);
            ClearEverythingAsync();
            DeleteVisualTSLine();

            PeakBalanceForDD   = AccountInfoDouble(ACCOUNT_BALANCE);
            MaxDrawdownUSD     = 0.0;
            MaxDrawdownPercent = 0.0;

            RecalculateBasePrice();
            IsClosingState   = false;
            LastCloseAllTime = TimeCurrent();
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate Dynamic Grid Distance using ATR                        |
//+------------------------------------------------------------------+
int GetDynamicGridDistance()
{
   if(!UseATRDistance || atrHandle == INVALID_HANDLE)
      return DistancePoints * m_multiplier;

   double atrValues[];
   ArraySetAsSeries(atrValues, true);

   if(CopyBuffer(atrHandle, 0, 1, 1, atrValues) <= 0)
   {
      return DistancePoints * m_multiplier;
   }

   double mult = ATR_Multiplier;
   if(UseAdaptiveATRGrid && MaxDrawdownPercent > 3.0)
   {
      mult = ATR_Multiplier * 1.3; // ขยายระยะ Grid ออกเมื่อ Drawdown เริ่มสูง กันไม่ให้เพิ่มไม้ถี่เกินไปตอนพอร์ตแย่
   }

   double currentATR = atrValues[0];
   double calculatedPoints = (currentATR * mult) / _Point;
   int finalPoints = (int)MathMax(10 * m_multiplier, MathRound(calculatedPoints));

   return finalPoints;
}

//+------------------------------------------------------------------+
//| Grid Router                                                      |
//+------------------------------------------------------------------+
void ExecuteGridLogic()
{
   if(GridType == GRID_PENDING)
   {
      PlacePendingGridServer();
   }
   else
   {
      CheckAndExecuteVirtualGrid();
   }
}

//+------------------------------------------------------------------+
//| Delete All Pending Orders Function                               |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   MqlTradeRequest request;
   MqlTradeResult  result;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderSelect(ticket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
         {
            ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP ||
               type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT)
            {
               ZeroMemory(request); ZeroMemory(result);
               request.action = TRADE_ACTION_REMOVE;
               request.order  = ticket;

               bool sent = OrderSendAsync(request, result);
               if(!sent)
               {
                  Print("OrderSendAsync (Remove Pending) failed with error: ", GetLastError());
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Server Pending Grid Execution                                    |
//+------------------------------------------------------------------+
void PlacePendingGridServer()
{
   if(IsClosingState) return;

   int openPositions = 0;
   int pendingOrders = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            openPositions++;
      }
   }

   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderSelect(ticket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
            pendingOrders++;
      }
   }

   if(openPositions > 0 || pendingOrders > 0) return;

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   GridBasePrice = NormalizeDouble((ask + bid) / 2.0, _Digits);
   GridBasePriceBuy  = GridBasePrice;
   GridBasePriceSell = GridBasePrice;
   CachedGridDistance = GetDynamicGridDistance();

   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();
   MqlTradeRequest request;
   MqlTradeResult  result;

   for(int level = 1; level <= TotalLevels; level++)
   {
      double lot = GetCalculatedLotSize(level);

      double targetBuyPrice  = NormalizeDouble(GridBasePrice + (level * CachedGridDistance * point), _Digits);
      double targetSellPrice = NormalizeDouble(GridBasePrice - (level * CachedGridDistance * point), _Digits);

      bool canBuyFilter  = CheckEMATrend(true)  && CheckMTFFilter(true)  && CheckADXFilter(true)  && CheckRSIFilter(true)  && CheckBollingerFilter(true);
      bool canSellFilter = CheckEMATrend(false) && CheckMTFFilter(false) && CheckADXFilter(false) && CheckRSIFilter(false) && CheckBollingerFilter(false);

      // BUY STOP (Async)
      if(canBuyFilter)
      {
         ZeroMemory(request); ZeroMemory(result);
         request.action       = TRADE_ACTION_PENDING;
         request.symbol       = _Symbol;
         request.volume       = lot;
         request.type         = ORDER_TYPE_BUY_STOP;
         request.price        = targetBuyPrice;
         request.deviation    = MaxSlippagePoints * m_multiplier;
         request.magic        = MagicNumber;
         request.comment      = "P-BUY-" + IntegerToString(level);
         request.type_filling = fillMode;

         bool sentBuy = OrderSendAsync(request, result);
         if(!sentBuy)
         {
            Print("OrderSendAsync (Buy Stop) failed with error: ", GetLastError());
         }
      }

      // SELL STOP (Async)
      if(canSellFilter)
      {
         ZeroMemory(request); ZeroMemory(result);
         request.action       = TRADE_ACTION_PENDING;
         request.symbol       = _Symbol;
         request.volume       = lot;
         request.type         = ORDER_TYPE_SELL_STOP;
         request.price        = targetSellPrice;
         request.deviation    = MaxSlippagePoints * m_multiplier;
         request.magic        = MagicNumber;
         request.comment      = "P-SELL-" + IntegerToString(level);
         request.type_filling = fillMode;

         bool sentSell = OrderSendAsync(request, result);
         if(!sentSell)
         {
            Print("OrderSendAsync (Sell Stop) failed with error: ", GetLastError());
         }
      }
   }

   GridCreated = true;
}

//+------------------------------------------------------------------+
//| Virtual Grid Execution (Supports 2, 3, 4, 5 Digits)              |
//+------------------------------------------------------------------+
void CheckAndExecuteVirtualGrid()
{
   if(IsClosingState) return;
   if(TimeCurrent() - LastOrderSentTime < 1) return;

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double lastBuyPrice  = 0.0;
   double lastSellPrice = 0.0;
   int    buyCount      = 0;
   int    sellCount     = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

            if(posType == POSITION_TYPE_BUY)
            {
               buyCount++;
               if(openPrice > lastBuyPrice || lastBuyPrice == 0.0) lastBuyPrice = openPrice;
            }
            else if(posType == POSITION_TYPE_SELL)
            {
               sellCount++;
               if(openPrice < lastSellPrice || lastSellPrice == 0.0) lastSellPrice = openPrice;
            }
         }
      }
   }

   int stepDistance = (CachedGridDistance > 0) ? CachedGridDistance : GetDynamicGridDistance();
   MqlTradeRequest request;
   MqlTradeResult  result;
   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();

   int adjGapLimit = MaxAllowedGapPoints * m_multiplier;
   int adjSpread   = MaxSpreadAllowed * m_multiplier;

   bool canBuyFilters  = CheckEMATrend(true)  && CheckMTFFilter(true)  && CheckADXFilter(true)  && CheckRSIFilter(true)  && CheckBollingerFilter(true);
   bool canSellFilters = CheckEMATrend(false) && CheckMTFFilter(false) && CheckADXFilter(false) && CheckRSIFilter(false) && CheckBollingerFilter(false);

   if(buyCount < TotalLevels && !canBuyFilters)   LogFilterBlockReason(true);
   if(sellCount < TotalLevels && !canSellFilters) LogFilterBlockReason(false);

   // CHECK BUY GRID
   if(buyCount < TotalLevels && canBuyFilters)
   {
      // lastBuyPrice is a LOCAL variable recomputed every call from real filled
      // positions - re-anchoring it in the gap branch below does NOT persist to
      // the next tick. BuyGapAnchor is the persistent override that actually
      // survives across ticks for the buyCount>0 case.
      double effectiveLastBuy = MathMax(lastBuyPrice, BuyGapAnchor);

      double targetPrice = 0.0;
      if(buyCount == 0)
         targetPrice = NormalizeDouble(GridBasePriceBuy + (stepDistance * point), _Digits);
      else
         targetPrice = NormalizeDouble(effectiveLastBuy + (stepDistance * point), _Digits);

      double diffPoints = (ask - targetPrice) / point;

      bool canSendBuy = false;
      if(!UseGapProtection)
      {
         if(ask >= targetPrice) canSendBuy = true;
      }
      else
      {
         // รองรับการคำนวณจุดทศนิยมทุกรูปแบบ ทั้งแบบเลยเป้าและอยู่ในช่วง Gap ที่กำหนด
         if(ask >= targetPrice && diffPoints <= adjGapLimit) canSendBuy = true;
      }

      if(canSendBuy)
      {
         if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= adjSpread)
         {
            int nextLevel = buyCount + 1;
            double lot = GetCalculatedLotSize(nextLevel);

            ZeroMemory(request); ZeroMemory(result);
            request.action       = TRADE_ACTION_DEAL;
            request.symbol       = _Symbol;
            request.volume       = lot;
            request.type         = ORDER_TYPE_BUY;
            request.price        = ask;
            request.deviation    = MaxSlippagePoints * m_multiplier;
            request.magic        = MagicNumber;
            request.comment      = "V-BUY-" + IntegerToString(nextLevel);
            request.type_filling = fillMode;

            if(OrderSend(request, result))
            {
               LastOrderSentTime = TimeCurrent();
               // FIXED: keep the still-empty Sell side's level-0 target pinned one
               // grid step behind the price that was just traded, instead of
               // leaving it anchored to wherever the basket started.
               if(sellCount == 0) GridBasePriceSell = ask;
               BuyGapAnchor = 0.0; // lastBuyPrice now reflects this real fill, override no longer needed
               return;
            }
         }
      }
      else if(UseGapProtection && diffPoints > adjGapLimit)
      {
         // FIXED (round 2): assigning to lastBuyPrice here was a no-op - it's a
         // local variable rebuilt from real filled positions on every call, so it
         // reverted right back on the next tick and repeated the identical stale
         // target forever. BuyGapAnchor is a persistent global that actually
         // sticks, and effectiveLastBuy (MathMax above) picks it up next tick.
         if(buyCount == 0) GridBasePriceBuy = ask;
         else BuyGapAnchor = ask;
         if(TimeCurrent() - lastGapLogTime >= 5)
         {
            lastGapLogTime = TimeCurrent();
            PrintFormat("⚠️ [BUY GAP EXCEEDED] Re-anchored to Ask %.5f (was Target: %.5f | Diff: %.0f pts > Max: %d).",
                        ask, targetPrice, diffPoints, adjGapLimit);
         }
      }
   }

   // CHECK SELL GRID
   if(sellCount < TotalLevels && canSellFilters)
   {
      // Same persistence issue as the Buy side, mirrored: lastSellPrice is local
      // and rebuilt from real positions every call, so SellGapAnchor is the
      // persistent override for the sellCount>0 case. Sell targets move DOWN, so
      // we want the lower of the two (0.0 means "unset").
      double effectiveLastSell = (SellGapAnchor > 0 && SellGapAnchor < lastSellPrice) ? SellGapAnchor : lastSellPrice;

      double targetPrice = 0.0;
      if(sellCount == 0)
         targetPrice = NormalizeDouble(GridBasePriceSell - (stepDistance * point), _Digits);
      else
         targetPrice = NormalizeDouble(effectiveLastSell - (stepDistance * point), _Digits);

      double diffPoints = (targetPrice - bid) / point;

      bool canSendSell = false;
      if(!UseGapProtection)
      {
         if(bid <= targetPrice) canSendSell = true;
      }
      else
      {
         // รองรับการคำนวณจุดทศนิยมทุกรูปแบบ ทั้งแบบเลยเป้าและอยู่ในช่วง Gap ที่กำหนด
         if(bid <= targetPrice && diffPoints <= adjGapLimit) canSendSell = true;
      }

      if(canSendSell)
      {
         if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= adjSpread)
         {
            int nextLevel = sellCount + 1;
            double lot = GetCalculatedLotSize(nextLevel);

            ZeroMemory(request); ZeroMemory(result);
            request.action       = TRADE_ACTION_DEAL;
            request.symbol       = _Symbol;
            request.volume       = lot;
            request.type         = ORDER_TYPE_SELL;
            request.price        = bid;
            request.deviation    = MaxSlippagePoints * m_multiplier;
            request.magic        = MagicNumber;
            request.comment      = "V-SELL-" + IntegerToString(nextLevel);
            request.type_filling = fillMode;

            if(OrderSend(request, result))
            {
               LastOrderSentTime = TimeCurrent();
               // Symmetric fix: keep the still-empty Buy side's level-0 target
               // pinned one grid step ahead of the price that was just traded.
               if(buyCount == 0) GridBasePriceBuy = bid;
               SellGapAnchor = 0.0; // lastSellPrice now reflects this real fill, override no longer needed
               return;
            }
         }
      }
      else if(UseGapProtection && diffPoints > adjGapLimit)
      {
         // FIXED (round 2): same persistence bug as the Buy side - assigning to
         // lastSellPrice here was a no-op. SellGapAnchor actually persists.
         if(sellCount == 0) GridBasePriceSell = bid;
         else SellGapAnchor = bid;
         if(TimeCurrent() - lastGapLogTime >= 5)
         {
            lastGapLogTime = TimeCurrent();
            PrintFormat("⚠️ [SELL GAP EXCEEDED] Re-anchored to Bid %.5f (was Target: %.5f | Diff: %.0f pts > Max: %d).",
                        bid, targetPrice, diffPoints, adjGapLimit);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Clear Account Function                                           |
//| FIXED: position closes now go through synchronous OrderSend()    |
//| with a confirm-and-retry loop instead of fire-and-forget          |
//| OrderSendAsync(). The async version never verified the close      |
//| actually happened - if a broker rejected/requoted the close (or   |
//| just hadn't processed it by the next tick), the position stayed   |
//| open forever while every caller had already set                   |
//| IsClosingState = true and never reset it back to false. Since the |
//| only reset path required openPositions==0 first, the EA would     |
//| freeze completely (no more Trailing Stop checks, no more grid     |
//| additions) while the position kept floating unmanaged - this is   |
//| what was reported: dashboard stuck on "CLOSING ALL..." with       |
//| positions still open and profit still moving.                    |
//+------------------------------------------------------------------+
void ClearEverythingAsync()
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();

   // 1. เคลียร์ Pending Orders (ยังใช้ Async ได้ ไม่ใช่ตัวที่ทำให้ IsClosingState ค้าง)
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;

      ZeroMemory(request); ZeroMemory(result);
      request.action = TRADE_ACTION_REMOVE;
      request.order  = ticket;

      bool sent = OrderSendAsync(request, result);
      if(!sent) Print("Clear Pending OrderAsync failed: ", GetLastError());
   }

   // 2. เคลียร์ Open Positions แบบ Synchronous + ยืนยันว่าปิดจริงก่อนออกจากฟังก์ชัน
   int retryCount = 0;
   while(retryCount < 10)
   {
      int totalPos = PositionsTotal();
      ulong tickets[];
      double volumes[];
      ArrayResize(tickets, totalPos);
      ArrayResize(volumes, totalPos);

      int count = 0;
      for(int i = 0; i < totalPos; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

         tickets[count] = ticket;
         volumes[count] = PositionGetDouble(POSITION_VOLUME);
         count++;
      }

      if(count == 0) break;

      // Bubble Sort เรียงลำดับ Volume มากไปน้อย
      for(int i = 0; i < count - 1; i++)
      {
         for(int j = 0; j < count - i - 1; j++)
         {
            if(volumes[j] < volumes[j+1])
            {
               double tempVol = volumes[j]; volumes[j] = volumes[j+1]; volumes[j+1] = tempVol;
               ulong tempTkt = tickets[j]; tickets[j] = tickets[j+1]; tickets[j+1] = tempTkt;
            }
         }
      }

      // ส่งคำสั่งปิดออเดอร์
      for(int i = 0; i < count; i++)
      {
         if(!PositionSelectByTicket(tickets[i])) continue;

         double volume = PositionGetDouble(POSITION_VOLUME);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         ENUM_ORDER_TYPE tradeType = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         double closePrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         if(closePrice <= 0) continue;

         ZeroMemory(request); ZeroMemory(result);
         request.action       = TRADE_ACTION_DEAL;
         request.position     = tickets[i];
         request.symbol       = _Symbol;
         request.volume       = volume;
         request.type         = tradeType;
         request.price        = closePrice;
         request.deviation    = MaxSlippagePoints * m_multiplier;
         request.magic        = MagicNumber;
         request.type_filling = fillMode;

         if(!OrderSend(request, result))
         {
            Print("Clear Position OrderSend failed: ", GetLastError(), " retcode: ", result.retcode);
         }
      }

      retryCount++;
      // Sleep() blocks real wall-clock time in the Strategy Tester too, and every
      // basket close (TS/Breakeven/DD Stop/time-filter) pays it at least once
      // even when OrderSend() already closed everything on the first pass - it's
      // only needed live, to give the broker time to actually process the close.
      // In the tester OrderSend() is synchronous/deterministic, so skip it.
      if(retryCount < 10 && !IsTestingMode) Sleep(50);
   }

   GridCreated           = false;
   MaxBasketProfit       = 0.0;
   GridBasePrice         = 0.0;
   GridBasePriceBuy      = 0.0;
   GridBasePriceSell     = 0.0;
   BuyGapAnchor          = 0.0;
   SellGapAnchor         = 0.0;
   CachedGridDistance    = 0;
   LastOrderSentTime     = 0;
   PartialCloseExecuted  = false;
   BreakevenActivated    = false;
}

//+------------------------------------------------------------------+
//| Draw Visual TS Line Function                                     |
//+------------------------------------------------------------------+
void DrawVisualTSLine(double tsValue)
{
   if(IsTestingMode) return;

   string text = "==> BASKET SL: $" + DoubleToString(tsValue, 2) + " (Peak: $" + DoubleToString(MaxBasketProfit, 2) + ")";

   if(ObjectFind(0, LineObjectName) < 0)
   {
      ObjectCreate(0, LineObjectName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, LineObjectName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, LineObjectName, OBJPROP_XDISTANCE, 800);
      ObjectSetInteger(0, LineObjectName, OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, LineObjectName, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, LineObjectName, OBJPROP_FONTSIZE, 11);
      ObjectSetString(0, LineObjectName, OBJPROP_FONT, "Impact");
   }

   ObjectSetString(0, LineObjectName, OBJPROP_TEXT, text);
}

void DeleteVisualTSLine()
{
   if(ObjectFind(0, LineObjectName) >= 0)
   {
      ObjectDelete(0, LineObjectName);
   }
}

//====================================================================//
//=================== THAI SUPPORT & BOLD UI ENGINE ==================//
//====================================================================//

string GetUIString(string thText, string enText)
{
   return (Language == LNG_TH) ? thText : enText;
}

string GetUIFont()
{
   return (Language == LNG_TH) ? "Tahoma" : "Trebuchet MS";
}

void CreateLabel(string name, int x, int y, string text, int size = 9, color clr = clrWhite, string font = "") {
   if(IsTestingMode) return;
   if(font == "") font = GetUIFont();

   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void CreatePanel(string name, int x, int y, int w, int h, color bgClr, color borderClr) {
   if(IsTestingMode) return;
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgClr);
   ObjectSetInteger(0, name, OBJPROP_COLOR, borderClr);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void CreateButton(string name, int x, int y, int w, int h, string text, color bgClr, color textClr, int fontSize = 9) {
   if(IsTestingMode) return;
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgClr);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textClr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, GetUIFont());
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void InitDashboard()
{
   if(IsTestingMode) return;
   DeleteDashboard();

   int X = 15;
   int Y = 15;

   // Main Dashboard Panel
   CreatePanel(UI_PREFIX+"Shadow", X+4, Y+4, 800, 510, UI_Shadow, UI_Shadow);
   CreatePanel(UI_PREFIX+"MainBG", X, Y, 800, 510, UI_MainBG, UI_Accent);

   // 1. HEADER
   CreatePanel(UI_PREFIX+"HeaderBG", X, Y, 800, 42, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Title", X+14, Y+10, "QUANTIX PRO TERMINAL - MULTI-ANALYTICS DASHBOARD", 11, clrWhite, "Impact");

   // 2. LED STATUS INDICATOR & TIME INDICATOR
   CreateLabel(UI_PREFIX+"LED_Icon", X+14, Y+52, "n", 7, UI_Profit, "Wingdings");
   CreateLabel(UI_PREFIX+"LED_Text", X+28, Y+50, GetUIString("ระบบพร้อมทำงาน", "ONLINE"), 9);

   string timeStr = StringFormat("%02d:%02d - %02d:%02d", StartHour, StartMinute, EndHour, EndMinute);
   if(!UseTimer) timeStr = "24/7 ALL DAY";
   CreateLabel(UI_PREFIX+"Time_Lbl", X+220, Y+50, GetUIString("เวลาเทรด: " + timeStr, "TIME: " + timeStr), 8, UI_TextDim);

   // 3. PROGRESS BAR SECTION
   CreateLabel(UI_PREFIX+"Prog_Lbl", X+14, Y+78, GetUIString("เป้าหมายกำไร", "TARGET PROGRESS"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Prog_Pct", X+335, Y+78, "0%", 8, clrWhite);
   CreatePanel(UI_PREFIX+"Prog_BG", X+14, Y+98, 362, 6, UI_PanelBG, UI_PanelBG);
   CreatePanel(UI_PREFIX+"Prog_Fill", X+14, Y+98, 0, 6, UI_Accent, UI_Accent);

   // 4. FLOATING PROFIT SECTION
   CreateLabel(UI_PREFIX+"NetLbl", X+14, Y+118, GetUIString("กำไรรวมปัจจุบัน (Floating)", "BASKET FLOATING PROFIT"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Profit", X+14, Y+138, "$0.00", 20, clrWhite, "Impact");

   // ==================== LEFT COLUMN: TRADING DATA MATRIX ==================== //
   int startY = Y + 190;

   // Box 1: PEAK PROFIT
   CreatePanel(UI_PREFIX+"Box1", X+14, startY, 176, 58, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Box1L", X+22, startY+6, GetUIString("กำไรสูงสุด ($)", "PEAK PROFIT ($)"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Peak", X+22, startY+26, "0.00", 11, clrWhite);

   // Box 2: TRAILING SL
   CreatePanel(UI_PREFIX+"Box2", X+200, startY, 176, 58, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Box2L", X+208, startY+6, GetUIString("จุดล็อกกำไร ($)", "TRAILING SL ($)"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_TS", X+208, startY+26, GetUIString("สแตนด์บาย", "HOLD"), 10, clrOrange);

   // Box 3: ACTIVE POSITIONS
   CreatePanel(UI_PREFIX+"Box3", X+14, startY+66, 176, 58, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Box3L", X+22, startY+72, GetUIString("ไม้ที่เปิดอยู่", "ACTIVE POSITIONS"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Open", X+22, startY+92, "0 / 20", 11, clrWhite);

   // Box 4: MODE / PENDING
   CreatePanel(UI_PREFIX+"Box4", X+200, startY+66, 176, 58, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Box4L", X+208, startY+72, GetUIString("โหมดคำสั่ง", "ORDER MODE"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Pend", X+208, startY+92, "---", 10, UI_Accent);

   // Box 5: VIRTUAL TARGET MONITOR
   CreatePanel(UI_PREFIX+"BoxVirt", X+14, startY+132, 362, 75, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"VirtTitle", X+22, startY+137, GetUIString("สถานะ VIRTUAL GRID", "VIRTUAL GRID TARGETS"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_VirtBuy", X+22, startY+155, "Wait BUY : ---", 8, UI_Profit);
   CreateLabel(UI_PREFIX+"Val_VirtSell", X+22, startY+175, "Wait SELL: ---", 8, UI_Loss);

   // EMERGENCY CLOSE ALL BUTTON
   string btnText = GetUIString("🚨 ปิดรวบทุกไม้ (CLOSE ALL)", "🚨 CLOSE ALL POSITIONS");
   CreateButton(BTN_CLOSE_ALL, X+14, startY+220, 362, 40, btnText, UI_Loss, clrWhite, 10);

   // ==================== RIGHT COLUMN: FINANCIAL INFO ==================== //
   int X_Right  = X + 395;
   int PanelW   = 390;

   int ValX_Acc = X_Right + 175;

   // 1. ACCOUNT OVERVIEW PANEL
   CreatePanel(UI_PREFIX+"AccBG", X_Right, Y+50, PanelW, 210, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"AccTitle", X_Right+12, Y+56, GetUIString("ข้อมูลบัญชีเทรด (ACCOUNT INFO)", "ACCOUNT INFO"), 8, UI_Accent);

   int accY = Y + 80;
   int accGap = 24;

   CreateLabel(UI_PREFIX+"Lbl_Bal", X_Right+12, accY, GetUIString("ยอดเงิน (Balance):", "Balance:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Bal", ValX_Acc, accY, "$0.00", 8, clrWhite);

   accY += accGap;
   CreateLabel(UI_PREFIX+"Lbl_Eq", X_Right+12, accY, GetUIString("มูลค่าสุทธิ (Equity):", "Equity:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Eq", ValX_Acc, accY, "$0.00", 8, clrWhite);

   accY += accGap;
   CreateLabel(UI_PREFIX+"Lbl_FreeM", X_Right+12, accY, GetUIString("หลักประกันเหลือ (Margin):", "Free Margin:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_FreeM", ValX_Acc, accY, "$0.00", 8, clrWhite);

   accY += accGap;
   CreateLabel(UI_PREFIX+"Lbl_MLevel", X_Right+12, accY, GetUIString("ระดับหลักประกัน (Level):", "Margin Level:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_MLevel", ValX_Acc, accY, "0.00%", 8, clrWhite);

   accY += accGap;
   CreateLabel(UI_PREFIX+"Lbl_MaxDD", X_Right+12, accY, GetUIString("ย่อตัวสูงสุด (Max DD):", "Max Drawdown:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_MaxDD", ValX_Acc, accY, "-$0.00 (-0.00%)", 8, UI_Loss);

   ChartRedraw();
}

void UpdateDashboard(double currentProfit, double maxProfit, double currentTS, int openPos, int pendingOrders)
{
   if(IsTestingMode) return;
   if(ObjectFind(0, UI_PREFIX+"MainBG") < 0) InitDashboard();

   // 1. LEFT SIDE UPDATES
   string pText = (currentProfit >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(currentProfit), 2);
   ObjectSetString(0, UI_PREFIX+"Val_Profit", OBJPROP_TEXT, pText);
   ObjectSetInteger(0, UI_PREFIX+"Val_Profit", OBJPROP_COLOR, (currentProfit >= 0 ? UI_Profit : UI_Loss));

   double percent = 0.0;
   if(TargetProfit > 0) percent = currentProfit / TargetProfit;
   if(percent < 0) percent = 0.0;
   if(percent > 1.0) percent = 1.0;

   int barWidth = (int)(362 * percent);
   ObjectSetInteger(0, UI_PREFIX+"Prog_Fill", OBJPROP_XSIZE, barWidth);

   if(percent >= 1.0) ObjectSetInteger(0, UI_PREFIX+"Prog_Fill", OBJPROP_BGCOLOR, clrOrange);
   else ObjectSetInteger(0, UI_PREFIX+"Prog_Fill", OBJPROP_BGCOLOR, UI_Accent);

   ObjectSetString(0, UI_PREFIX+"Prog_Pct", OBJPROP_TEXT, IntegerToString((int)(percent * 100)) + "%");

   bool timeAllowed = IsTradingAllowedByTime();

   if(IsClosingState) {
      ObjectSetInteger(0, UI_PREFIX+"LED_Icon", OBJPROP_COLOR, clrOrange);
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("กำลังเคลียร์ไม้ค้าง", "CLOSING ALL..."));
   } else if(!timeAllowed) {
      ObjectSetInteger(0, UI_PREFIX+"LED_Icon", OBJPROP_COLOR, clrRed);
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("นอกเวลาเทรด", "OFF-TIME"));
   } else if(openPos > 0 || pendingOrders > 0) {
      ObjectSetInteger(0, UI_PREFIX+"LED_Icon", OBJPROP_COLOR, UI_Profit);
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("กำลังทำงาน", "ACTIVE"));
   } else {
      ObjectSetInteger(0, UI_PREFIX+"LED_Icon", OBJPROP_COLOR, C'255,193,7');
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("ระบบพร้อมทำงาน", "ONLINE"));
   }

   ObjectSetString(0, UI_PREFIX+"Val_Peak", OBJPROP_TEXT, DoubleToString(maxProfit, 2));

   if(currentTS > 0) ObjectSetString(0, UI_PREFIX+"Val_TS", OBJPROP_TEXT, "$" + DoubleToString(currentTS, 2));
   else ObjectSetString(0, UI_PREFIX+"Val_TS", OBJPROP_TEXT, GetUIString("สแตนด์บาย", "HOLD"));

   ObjectSetString(0, UI_PREFIX+"Val_Open", OBJPROP_TEXT, IntegerToString(openPos) + " / " + IntegerToString(TotalLevels * 2));

   if(GridType == GRID_VIRTUAL)
   {
      ObjectSetString(0, UI_PREFIX+"Val_Pend", OBJPROP_TEXT, "VIRTUAL GRID");

      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double baseP = GridBasePrice;
      int distP    = (CachedGridDistance > 0) ? CachedGridDistance : GetDynamicGridDistance();

      double nextBuyP  = NormalizeDouble(baseP + (1 * distP * point), _Digits);
      double nextSellP = NormalizeDouble(baseP - (1 * distP * point), _Digits);

      if(openPos > 0)
      {
         ObjectSetString(0, UI_PREFIX+"VirtTitle", OBJPROP_TEXT, GetUIString("สถานะ VIRTUAL GRID (คำนวณตามไม้)", "VIRTUAL GRID (ACTIVE RE-CALC)"));
         ObjectSetString(0, UI_PREFIX+"Val_VirtBuy", OBJPROP_TEXT, "Base Price: " + DoubleToString(GridBasePrice, _Digits));
         ObjectSetString(0, UI_PREFIX+"Val_VirtSell", OBJPROP_TEXT, "Grid Distance: " + IntegerToString(distP) + " points");
      }
      else
      {
         ObjectSetString(0, UI_PREFIX+"VirtTitle", OBJPROP_TEXT, GetUIString("สถานะ VIRTUAL GRID (รอรอบใหม่)", "VIRTUAL GRID (LOCKED WAIT)"));
         ObjectSetString(0, UI_PREFIX+"Val_VirtBuy", OBJPROP_TEXT, "Wait BUY  : " + DoubleToString(nextBuyP, _Digits) + "  (Base: " + DoubleToString(baseP, _Digits) + ")");
         ObjectSetString(0, UI_PREFIX+"Val_VirtSell", OBJPROP_TEXT, "Wait SELL : " + DoubleToString(nextSellP, _Digits) + "  (Step: " + IntegerToString(distP) + " pts)");
      }
   }
   else
   {
      ObjectSetString(0, UI_PREFIX+"Val_Pend", OBJPROP_TEXT, "PENDING: " + IntegerToString(pendingOrders));
      ObjectSetString(0, UI_PREFIX+"VirtTitle", OBJPROP_TEXT, GetUIString("สถานะ PENDING GRID (ส่งคำสั่งไป Server)", "PENDING GRID MODE (ON SERVER)"));
      ObjectSetString(0, UI_PREFIX+"Val_VirtBuy", OBJPROP_TEXT, "Server Orders: " + IntegerToString(pendingOrders) + " Pending Orders");
      ObjectSetString(0, UI_PREFIX+"Val_VirtSell", OBJPROP_TEXT, "Max Slippage : " + IntegerToString(MaxSlippagePoints * m_multiplier) + " points");
   }

   // 2. RIGHT SIDE UPDATES (ACCOUNT INFO)
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double mLevel     = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);

   ObjectSetString(0, UI_PREFIX+"Val_Bal", OBJPROP_TEXT, "$" + DoubleToString(balance, 2));
   ObjectSetString(0, UI_PREFIX+"Val_Eq", OBJPROP_TEXT, "$" + DoubleToString(equity, 2));
   ObjectSetString(0, UI_PREFIX+"Val_FreeM", OBJPROP_TEXT, "$" + DoubleToString(freeMargin, 2));
   ObjectSetString(0, UI_PREFIX+"Val_MLevel", OBJPROP_TEXT, (mLevel > 0 ? DoubleToString(mLevel, 2) + "%" : "0.00%"));

   string ddText = StringFormat("-$%.2f (-%.2f%%)", MaxDrawdownUSD, MaxDrawdownPercent);
   ObjectSetString(0, UI_PREFIX+"Val_MaxDD", OBJPROP_TEXT, ddText);
}

void DeleteDashboard()
{
   for(int i = ObjectsTotal(0)-1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, UI_PREFIX) == 0) ObjectDelete(0, name);
   }
   ChartRedraw();
}
