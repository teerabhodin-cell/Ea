//+------------------------------------------------------------------+
//|                     Quantix_Classic20_Visual_BasketTS_Virtual.mq5|
//|        Dual Mode Grid (Pending / Virtual) + Basket Trailing Stop |
//|        [OPTIMIZED: Core Stable + Functional Breakeven/Partial]   |
//|        [FIXED: Equity Lock froze the whole tick (including the  |
//|                base-price recalculation and dashboard refresh), |
//|                Breakeven trigger/lock was an unreachable AND,   |
//|                Buy/Sell gap-anchor cross-contamination, Lot     |
//|                volume step/min/max normalization]                |
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

//=========================== INPUT ================================--
input group "--- Language Settings ---"
input ENUM_LANGUAGE Language = LNG_TH;

input group "--- Trading Hours (เวลาเปิด-ปิด บอท) ---"
input bool    UseTimer         = true;
input int     StartHour        = 2;
input int     StartMinute      = 0;
input int     EndHour          = 23;
input int     EndMinute        = 0;

input group "--- London/New York Session Filter ---"
input bool   UseSessionFilter      = false;   // เปิดใช้งานตัวกรองเวลาเปิดตลาด London / New York
input int    LondonStartHour       = 8;       // เวลาเริ่มตลาดลอนดอน (GMT/UTC)
input int    LondonEndHour         = 17;      // เวลาปิดตลาดลอนดอน
input int    NYStartHour           = 13;      // เวลาเริ่มตลาดนิวยอร์ก (GMT/UTC)
input int    NYEndHour             = 22;      // เวลาปิดตลาดนิวยอร์ก

input group "--- Multi Timeframe Filter ---"
input bool   UseMTFFilter          = false;   // เปิดใช้ตัวกรองเทรนด์จาก Timeframe สูงกว่า
input ENUM_TIMEFRAMES MTF_Period   = PERIOD_H1; // Timeframe ที่ใช้กรองเทรนด์หลัก

input group "--- Grid Settings ---"
input ENUM_GRID_TYPE GridType       = GRID_VIRTUAL;
input double BaseLot                = 0.01;
input double LotMultiplier          = 2.0;
input bool   UseATRDistance         = true;
input int    ATR_Period             = 14;
input double ATR_Multiplier         = 1.5;
input int    DistancePoints         = 300;
input int    TotalLevels            = 10;
input ulong  MagicNumber            = 112233;

input group "--- Adaptive ATR Grid ---"
input bool   UseAdaptiveATRGrid     = false;   // เปิดใช้ระบบปรับระยะ Grid ตามความผันผวนอัตโนมัติ

input group "--- Trend Filter (EMA Anti-Sideway) ---"
input bool   UseEMAFilter           = true;    // เปิดใช้ตัวกรองเทรนด์ EMA
input int    EMA_Period             = 200;     // Period ของเส้น EMA
input bool   StrictBuyFilter        = true;    // ล็อคฝั่ง Buy: ห้ามเปิด Buy หากราคาอยู่ต่ำกว่า EMA
input bool   StrictSellFilter       = true;    // ล็อคฝั่ง Sell: ห้ามเปิด Sell หากราคาอยู่เหนือ EMA

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
input double MaxAllowedDD_USD       = 50.0;    // ยอมให้ขาดทุนสูงสุดเป็นเงิน ($) ถ้าเกินจะปิดทิ้งทั้งหมดทันที
input double MaxAllowedDD_Pct       = 10.0;    // ยอมให้ขาดทุนสูงสุดเป็นเปอร์เซ็นต์ (%) จากยอด Balance สูงสุด

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
input bool   UseGapProtection    = true;
input int    MaxAllowedGapPoints = 100;
input int    MaxSlippagePoints   = 20;
input int    MaxSpreadAllowed    = 40;

input group "--- Basket Profit Target (Trailing) ---"
input double TargetProfit        = 1.0;    // Minimum Profit ($) to activate Trailing
input double TrailingStopUSD     = 0.5;    // Trailing Distance ($)

input group "--- PRO TERMINAL UI CUSTOMIZE ---"
input color  UI_MainBG        = C'18, 20, 28';
input color  UI_Shadow        = C'5, 5, 5';
input color  UI_Accent        = C'33, 150, 243';
input color  UI_PanelBG       = C'26, 30, 41';
input color  UI_TextDim       = C'140, 150, 170';
input color  UI_Profit        = C'0, 230, 118';
input color  UI_Loss          = C'255, 61, 113';

//=========================== GLOBAL ===============================//

bool     GridCreated     = false;
double   MaxBasketProfit = 0.0;
string   LineObjectName  = "Basket_TS_Line";

int      m_multiplier    = 1;

double   GridBasePrice      = 0.0;
double   GridBasePriceBuy   = 0.0;    // independent gap-skip anchor for the Buy side
double   GridBasePriceSell  = 0.0;    // independent gap-skip anchor for the Sell side
int      CachedGridDistance = 0;

datetime LastOrderSentTime  = 0;
datetime LastCloseAllTime   = 0;
bool     IsClosingState     = false;

double   PeakBalanceForDD   = 0.0;
double   MaxDrawdownPercent = 0.0;
double   MaxDrawdownUSD     = 0.0;

bool     PartialCloseExecuted = false; // ป้องกันการสั่งซ้ำรอบเดิม
bool     BreakevenActivated   = false; // latch เมื่อกำไรแตะ BreakevenTriggerUSD แล้ว

string   UI_PREFIX       = "QX_PRO_";
string   BTN_CLOSE_ALL   = "QX_PRO_BtnCloseAll";

int      atrHandle       = INVALID_HANDLE;
int      emaHandle       = INVALID_HANDLE;
int      adxHandle       = INVALID_HANDLE;
int      rsiHandle       = INVALID_HANDLE;
int      bbHandle        = INVALID_HANDLE;
int      mtfEmaHandle    = INVALID_HANDLE;

uint     lastUIUpdateTime = 0;
bool     IsTestingMode   = false;

//====================== FUNCTION DECLARE ==========================//

bool IsTradingAllowedByTime();
bool IsTradingAllowedBySession();
bool CheckADXFilter(bool isBuy);
bool CheckRSIFilter(bool isBuy);
bool CheckBollingerFilter(bool isBuy);
bool CheckMTFFilter(bool isBuy);
double GetCalculatedLotSize(int nextLevel);
void ApplyBasketBreakevenAndPartial(double currentProfit);
void ExecuteGridLogic();
void PlacePendingGridServer();
void CheckAndExecuteVirtualGrid();
void DeleteAllPendingOrders();
void ManualCloseAllSync();
void DrawVisualTSLine(double tsValue);
void DeleteVisualTSLine();
void UpdateDrawdownTracker();
int  GetDynamicGridDistance();
bool CheckEMATrend(bool isBuy);
void RecalculateBasePrice();
ENUM_ORDER_TYPE_FILLING GetBestFillingMode();

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

   if(ask > 0 && bid > 0)
   {
      GridBasePrice = NormalizeDouble((ask + bid) / 2.0, _Digits);
      GridBasePriceBuy  = GridBasePrice;
      GridBasePriceSell = GridBasePrice;
      CachedGridDistance = GetDynamicGridDistance();
      GridCreated = true;
   }
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
      return (currentMinutes >= startMinutes && currentMinutes < endMinutes);
   else
      return (currentMinutes >= startMinutes || currentMinutes < endMinutes);
}

//+------------------------------------------------------------------+
//| London / New York Session Filter                                 |
//+------------------------------------------------------------------+
bool IsTradingAllowedBySession()
{
   if(!UseSessionFilter) return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentHour = dt.hour;

   bool isLondon = (currentHour >= LondonStartHour && currentHour < LondonEndHour);
   bool isNY     = (currentHour >= NYStartHour && currentHour < NYEndHour);

   return (isLondon || isNY);
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
//| Dynamic Lot Calculation & Auto Reduction                         |
//| FIXED: now rounds to the symbol's actual volume step and clamps  |
//| to SYMBOL_VOLUME_MIN/MAX so OrderSend can't be rejected with     |
//| an invalid-volume error on brokers whose lot step isn't 0.01.    |
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
//| DEVELOPED: Basket Breakeven and Partial Close Manager            |
//| FIXED: BreakevenActivated now latches once profit crosses the    |
//| trigger, so the retrace-to-lock close can actually fire. The old |
//| code required currentProfit >= Trigger AND <= Lock in the same   |
//| tick, which is unreachable whenever Lock < Trigger (the default  |
//| 10 vs 3 here), so breakeven never closed anything.                |
//+------------------------------------------------------------------+
void ApplyBasketBreakevenAndPartial(double currentProfit)
{
   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();
   MqlTradeRequest request;
   MqlTradeResult  result;
   bool unused_ret = false;

   // 1. ระบบ Partial Close (ทยอยปิดทำกำไรบางส่วนเมื่อถึงเป้าที่กำหนด เช่น ปิด 50% ของแต่ละออเดอร์)
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

               // ตรวจสอบขั้นต่ำของล็อต
               if(targetCloseVol < 0.01) targetCloseVol = 0.01;
               if(targetCloseVol >= volume) targetCloseVol = volume; // ถ้าคำนวณแล้วเท่ากับหรือมากกว่า ให้ปิดหมดเปลือก

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

                  unused_ret = OrderSend(request, result);
               }
            }
         }
      }
      PartialCloseExecuted = true; // ล็อคไว้ไม่ให้สั่งซ้ำรอบนี้
   }

   // 2. ระบบ Basket Breakeven (ขยับจุดล็อคกำไรคุ้มทุน เมื่อพอร์ตพุ่งไปแตะเงื่อนไข)
   if(UseBasketBreakeven)
   {
      if(!BreakevenActivated && currentProfit >= BreakevenTriggerUSD)
      {
         BreakevenActivated = true;
      }

      // หากกำไรเคยพุ่งเกินจุด Trigger มาก่อน (latched) แล้วตกลงมาแตะเส้น BreakevenLockUSD ให้สั่งปิดล้างกระดานเพื่อล็อคกำไรทันที
      if(BreakevenActivated && currentProfit <= BreakevenLockUSD)
      {
         IsClosingState = true;
         ManualCloseAllSync();
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

   if(_Digits == 3 || _Digits == 5) m_multiplier = 10;
   else m_multiplier = 1;

   trade.LogLevel(LOG_LEVEL_ERRORS);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints * m_multiplier);

   MaxBasketProfit      = 0.0;
   LastOrderSentTime    = 0;
   LastCloseAllTime     = 0;
   IsClosingState       = false;
   PartialCloseExecuted = false;
   BreakevenActivated   = false;
   PeakBalanceForDD     = AccountInfoDouble(ACCOUNT_BALANCE);
   MaxDrawdownPercent   = 0.0;
   MaxDrawdownUSD       = 0.0;

   DeleteVisualTSLine();

   if(UseATRDistance)
   {
      atrHandle = iATR(_Symbol, _Period, ATR_Period);
      if(atrHandle == INVALID_HANDLE) return(INIT_FAILED);
   }

   if(UseEMAFilter)
   {
      emaHandle = iMA(_Symbol, _Period, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
      if(emaHandle == INVALID_HANDLE) return(INIT_FAILED);
   }

   if(UseADXFilter)
   {
      adxHandle = iADX(_Symbol, _Period, ADX_Period);
      if(adxHandle == INVALID_HANDLE) return(INIT_FAILED);
   }

   if(UseRSIFilter)
   {
      rsiHandle = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);
      if(rsiHandle == INVALID_HANDLE) return(INIT_FAILED);
   }

   if(UseBollingerFilter)
   {
      bbHandle = iBands(_Symbol, _Period, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
      if(bbHandle == INVALID_HANDLE) return(INIT_FAILED);
   }

   if(UseMTFFilter)
   {
      mtfEmaHandle = iMA(_Symbol, MTF_Period, EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
      if(mtfEmaHandle == INVALID_HANDLE) return(INIT_FAILED);
   }

   RecalculateBasePrice();

   if(GridType == GRID_VIRTUAL) DeleteAllPendingOrders();

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
   if(adxHandle != INVALID_HANDLE) IndicatorRelease(adxHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(bbHandle != INVALID_HANDLE) IndicatorRelease(bbHandle);
   if(mtfEmaHandle != INVALID_HANDLE) IndicatorRelease(mtfEmaHandle);
   DeleteVisualTSLine();
   DeleteDashboard();
}

//+------------------------------------------------------------------+
//| Chart Event Handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK && sparam == BTN_CLOSE_ALL)
   {
      IsClosingState = true;
      ManualCloseAllSync();
      DeleteVisualTSLine();
      RecalculateBasePrice();
      IsClosingState = false;
      LastCloseAllTime = TimeCurrent();
      PartialCloseExecuted = false;
      ObjectSetInteger(0, BTN_CLOSE_ALL, OBJPROP_STATE, false);
      ChartRedraw();
   }
}

//+------------------------------------------------------------------+
//| Expert Tick                                                      |
//| FIXED: UseEquityLock previously did `return;` as the very first  |
//| line of OnTick(), so once Equity dropped under MinEquityLimit,   |
//| absolutely nothing else ran anymore - not the position/profit    |
//| scan, not UpdateDrawdownTracker() (Max DD emergency stop), not   |
//| RecalculateBasePrice() (GridBasePrice/GridBasePriceBuy/Sell stay |
//| stuck at 0.0 forever), and not UpdateDashboard() (the panel      |
//| freezes on "Wait BUY : ---" / "Wait SELL: ---" with no feedback  |
//| at all). Per the input's own description ("หยุดเปิดไม้ใหม่" /    |
//| stop opening NEW orders), it must only block ExecuteGridLogic()  |
//| below - everything else (drawdown protection, breakeven/partial- |
//| close, trailing stop, base-price tracking, dashboard) keeps      |
//| running so existing exposure is still managed and the panel      |
//| still shows real numbers while equity is under the limit.        |
//+------------------------------------------------------------------+
void OnTick()
{
   bool equityLocked = (UseEquityLock && AccountInfoDouble(ACCOUNT_EQUITY) < MinEquityLimit);

   int    openPositions      = 0;
   int    pendingOrders      = 0;
   double currentProfit      = 0.0;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      openPositions++;
      currentProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      pendingOrders++;
   }

   UpdateDrawdownTracker();

   if(openPositions == 0 && pendingOrders == 0)
   {
      if(IsClosingState) IsClosingState = false;
      if(PartialCloseExecuted) PartialCloseExecuted = false;

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
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

      if(!GridCreated) RecalculateBasePrice();
      MaxBasketProfit = 0.0;
   }

   if(openPositions > 0 && GridBasePrice == 0.0)
   {
      RecalculateBasePrice();
   }

   if(openPositions > 0 && !IsClosingState)
   {
      if(currentProfit > MaxBasketProfit)
      {
         MaxBasketProfit = currentProfit;
      }

      // เรียกใช้งานฟังก์ชันจัดการ Breakeven และ Partial Close ที่พัฒนาแล้ว
      if(UseBasketBreakeven || UsePartialClose)
      {
         ApplyBasketBreakevenAndPartial(currentProfit);
      }

      if(currentProfit >= TargetProfit)
      {
         double tsTriggerLine = MaxBasketProfit - TrailingStopUSD;
         DrawVisualTSLine(tsTriggerLine);

         // TargetProfit only ARMS the trailing stop - the basket keeps running and
         // only actually closes once profit pulls back by TrailingStopUSD from its
         // peak (MaxBasketProfit). That is by design (let winners run).
         if(currentProfit <= tsTriggerLine)
         {
            // FIXED: every other ManualCloseAllSync() caller resets IsClosingState
            // back to false right after the call; this branch used to `return`
            // without doing so. If ManualCloseAllSync() ever failed to fully flatten
            // the basket (a rejected close order, requote, brief connectivity blip),
            // IsClosingState stayed stuck at true forever - which disables this
            // entire block (`if(openPositions > 0 && !IsClosingState)`) AND the grid
            // gate (`!IsClosingState` in the ExecuteGridLogic() condition) permanently,
            // since the only other reset path requires openPositions==0 first. The
            // basket would then sit open and completely unmanaged - no more trailing
            // checks, no more breakeven, no more grid additions - while price kept
            // moving, exactly matching profit running far past TargetProfit with no
            // close ever firing.
            IsClosingState = true;
            ManualCloseAllSync();
            DeleteVisualTSLine();
            RecalculateBasePrice();
            PartialCloseExecuted = false;
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
      if(!IsClosingState)
      {
         MaxBasketProfit = 0.0;
         DeleteVisualTSLine();
      }
   }

   if(IsTradingAllowedByTime() && IsTradingAllowedBySession())
   {
      if(!IsClosingState && !equityLocked && (currentProfit < TargetProfit) && (TimeCurrent() - LastCloseAllTime >= 3))
      {
         ExecuteGridLogic();
      }
   }
   else
   {
      if(pendingOrders > 0 && !IsClosingState) DeleteAllPendingOrders();
   }

   uint now = GetTickCount();
   uint updateInterval = IsTestingMode ? 5000 : 500;
   if(now - lastUIUpdateTime >= updateInterval)
   {
      double currentTS = (currentProfit >= TargetProfit) ? (MaxBasketProfit - TrailingStopUSD) : 0.0;
      UpdateDashboard(currentProfit, MaxBasketProfit, currentTS, openPositions, pendingOrders);
      lastUIUpdateTime = now;
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
//| Update Max Drawdown Calculation & Emergency Stop                 |
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
            ManualCloseAllSync();
            DeleteVisualTSLine();

            PeakBalanceForDD   = AccountInfoDouble(ACCOUNT_BALANCE);
            MaxDrawdownUSD     = 0.0;
            MaxDrawdownPercent = 0.0;
            PartialCloseExecuted = false;

            RecalculateBasePrice();
            IsClosingState     = false;
            LastCloseAllTime   = TimeCurrent();
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate Dynamic Grid Distance                                  |
//+------------------------------------------------------------------+
int GetDynamicGridDistance()
{
   if(!UseATRDistance || atrHandle == INVALID_HANDLE)
      return DistancePoints * m_multiplier;

   double atrValues[];
   ArraySetAsSeries(atrValues, true);

   if(CopyBuffer(atrHandle, 0, 1, 1, atrValues) <= 0) return DistancePoints * m_multiplier;

   double mult = ATR_Multiplier;
   if(UseAdaptiveATRGrid && MaxDrawdownPercent > 3.0)
   {
      mult = ATR_Multiplier * 1.3;
   }

   double calculatedPoints = (atrValues[0] * mult) / _Point;
   return (int)MathMax(10 * m_multiplier, MathRound(calculatedPoints));
}

//+------------------------------------------------------------------+
//| Grid Router                                                      |
//+------------------------------------------------------------------+
void ExecuteGridLogic()
{
   if(GridType == GRID_PENDING) PlacePendingGridServer();
   else CheckAndExecuteVirtualGrid();
}

//+------------------------------------------------------------------+
//| Delete All Pending Orders Function                               |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   bool unused_ret;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderSelect(ticket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
         {
            ZeroMemory(request); ZeroMemory(result);
            request.action = TRADE_ACTION_REMOVE;
            request.order  = ticket;
            unused_ret = OrderSendAsync(request, result);
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
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) openPositions++;
   }

   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderSelect(ticket))
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber) pendingOrders++;
   }

   if(openPositions > 0 || pendingOrders > 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;

   GridBasePrice = NormalizeDouble((ask + bid) / 2.0, _Digits);
   GridBasePriceBuy  = GridBasePrice;
   GridBasePriceSell = GridBasePrice;
   CachedGridDistance = GetDynamicGridDistance();

   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();
   MqlTradeRequest request;
   MqlTradeResult  result;
   bool unused_ret;

   for(int level = 1; level <= TotalLevels; level++)
   {
      double lot = GetCalculatedLotSize(level);
      double targetBuyPrice  = NormalizeDouble(GridBasePrice + (level * CachedGridDistance * _Point), _Digits);
      double targetSellPrice = NormalizeDouble(GridBasePrice - (level * CachedGridDistance * _Point), _Digits);

      bool canBuyFilter = CheckEMATrend(true) && CheckADXFilter(true) && CheckRSIFilter(true) && CheckBollingerFilter(true) && CheckMTFFilter(true);
      bool canSellFilter = CheckEMATrend(false) && CheckADXFilter(false) && CheckRSIFilter(false) && CheckBollingerFilter(false) && CheckMTFFilter(false);

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
         request.type_filling = fillMode;
         unused_ret = OrderSendAsync(request, result);
      }

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
         request.type_filling = fillMode;
         unused_ret = OrderSendAsync(request, result);
      }
   }
   GridCreated = true;
}

//+------------------------------------------------------------------+
//| Virtual Grid Execution                                           |
//| FIXED: Buy and Sell sides now track independent gap-skip anchors |
//| (GridBasePriceBuy / GridBasePriceSell) instead of sharing the    |
//| single GridBasePrice global. Previously, a gap-skip on the Buy   |
//| side mutated GridBasePrice, which the Sell branch then read      |
//| later in the very same tick (and every tick after), silently     |
//| dragging the Sell grid's anchor along with an unrelated Buy-side |
//| event.                                                            |
//+------------------------------------------------------------------+
void CheckAndExecuteVirtualGrid()
{
   if(IsClosingState) return;
   if(TimeCurrent() - LastOrderSentTime < 1) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;

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
   int adjSpread = MaxSpreadAllowed * m_multiplier;

   bool canBuyFilters = CheckEMATrend(true) && CheckADXFilter(true) && CheckRSIFilter(true) && CheckBollingerFilter(true) && CheckMTFFilter(true);
   bool canSellFilters = CheckEMATrend(false) && CheckADXFilter(false) && CheckRSIFilter(false) && CheckBollingerFilter(false) && CheckMTFFilter(false);

   if(buyCount < TotalLevels && canBuyFilters)
   {
      double targetPrice = (buyCount == 0) ?
         NormalizeDouble(GridBasePriceBuy + (stepDistance * _Point), _Digits) :
         NormalizeDouble(lastBuyPrice + (stepDistance * _Point), _Digits);

      double diffPoints = (ask - targetPrice) / _Point;

      bool canSendBuy = false;
      if(diffPoints >= 0)
      {
         if(!UseGapProtection || diffPoints <= adjGapLimit) canSendBuy = true;
      }

      if(canSendBuy && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= adjSpread)
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
         request.type_filling = fillMode;

         if(OrderSend(request, result))
         {
            LastOrderSentTime = TimeCurrent();
            // Keep the still-empty Sell side's first-entry trigger pinned one grid
            // step behind the price that was just traded, instead of leaving it
            // anchored to wherever the basket started. Without this, once Buy has
            // climbed several levels, the Sell side's level-0 target stays frozen at
            // (original center - step) - so a pullback has to travel all the way
            // back to that stale, far-away point before the hedge ever arms, even
            // though the configured grid step is much smaller.
            if(sellCount == 0) GridBasePriceSell = ask;
            return;
         }
      }
      else if(UseGapProtection && diffPoints > adjGapLimit)
      {
         if(buyCount == 0) GridBasePriceBuy = ask;
         else lastBuyPrice = ask;
      }
   }

   if(sellCount < TotalLevels && canSellFilters)
   {
      double targetPrice = (sellCount == 0) ?
         NormalizeDouble(GridBasePriceSell - (stepDistance * _Point), _Digits) :
         NormalizeDouble(lastSellPrice - (stepDistance * _Point), _Digits);

      double diffPoints = (targetPrice - bid) / _Point;

      bool canSendSell = false;
      if(diffPoints >= 0)
      {
         if(!UseGapProtection || diffPoints <= adjGapLimit) canSendSell = true;
      }

      if(canSendSell && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= adjSpread)
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
         request.type_filling = fillMode;

         if(OrderSend(request, result))
         {
            LastOrderSentTime = TimeCurrent();
            // Symmetric fix: keep the still-empty Buy side's first-entry trigger
            // pinned one grid step ahead of the price that was just traded.
            if(buyCount == 0) GridBasePriceBuy = bid;
            return;
         }
      }
      else if(UseGapProtection && diffPoints > adjGapLimit)
      {
         if(sellCount == 0) GridBasePriceSell = bid;
         else lastSellPrice = bid;
      }
   }
}

//+------------------------------------------------------------------+
//| Synchronous Close All                                            |
//+------------------------------------------------------------------+
void ManualCloseAllSync()
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();
   bool unused_sync_ret = false;
   int emergencyDeviation = 100 * m_multiplier;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderSelect(ticket))
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MagicNumber)
         {
            ZeroMemory(request); ZeroMemory(result);
            request.action = TRADE_ACTION_REMOVE;
            request.order  = ticket;
            unused_sync_ret = OrderSend(request, result);
         }
      }
   }

   int retryCount = 0;
   while(retryCount < 10)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

         double volume = PositionGetDouble(POSITION_VOLUME);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         ENUM_ORDER_TYPE tradeType = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         double closePrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         if(closePrice <= 0) continue;

         ZeroMemory(request); ZeroMemory(result);
         request.action       = TRADE_ACTION_DEAL;
         request.position     = ticket;
         request.symbol       = _Symbol;
         request.volume       = volume;
         request.type         = tradeType;
         request.price        = closePrice;
         request.deviation    = emergencyDeviation;
         request.magic        = MagicNumber;
         request.type_filling = fillMode;

         unused_sync_ret = OrderSend(request, result);
      }

      int activeCount = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionSelectByTicket(ticket))
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MagicNumber) activeCount++;
      }

      if(activeCount == 0) break;
      retryCount++;
      Sleep(50);
   }

   GridCreated          = false;
   MaxBasketProfit      = 0.0;
   GridBasePrice        = 0.0;
   GridBasePriceBuy     = 0.0;
   GridBasePriceSell    = 0.0;
   CachedGridDistance   = 0;
   LastOrderSentTime    = 0;
   PartialCloseExecuted = false;
   BreakevenActivated   = false;
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
   if(ObjectFind(0, LineObjectName) >= 0) ObjectDelete(0, LineObjectName);
}

//====================================================================//
//=================== THAI SUPPORT & BOLD UI ENGINE ==================//
//====================================================================//

string GetUIString(string thText, string enText) { return (Language == LNG_TH) ? thText : enText; }
string GetUIFont() { return (Language == LNG_TH) ? "Tahoma" : "Trebuchet MS"; }

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
   int X = 15; int Y = 15;

   CreatePanel(UI_PREFIX+"Shadow", X+4, Y+4, 800, 510, UI_Shadow, UI_Shadow);
   CreatePanel(UI_PREFIX+"MainBG", X, Y, 800, 510, UI_MainBG, UI_Accent);

   CreatePanel(UI_PREFIX+"HeaderBG", X, Y, 800, 42, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Title", X+14, Y+10, "QUANTIX PRO TERMINAL - MULTI-ANALYTICS DASHBOARD", 11, clrWhite, "Impact");

   CreateLabel(UI_PREFIX+"LED_Icon", X+14, Y+52, "n", 7, UI_Profit, "Wingdings");
   CreateLabel(UI_PREFIX+"LED_Text", X+28, Y+50, GetUIString("ระบบพร้อมทำงาน", "ONLINE"), 9);

   string timeStr = StringFormat("%02d:%02d - %02d:%02d", StartHour, StartMinute, EndHour, EndMinute);
   if(!UseTimer) timeStr = "24/7 ALL DAY";
   CreateLabel(UI_PREFIX+"Time_Lbl", X+220, Y+50, GetUIString("เวลาเทรด: " + timeStr, "TIME: " + timeStr), 8, UI_TextDim);

   CreateLabel(UI_PREFIX+"Prog_Lbl", X+14, Y+78, GetUIString("เป้าหมายกำไร", "TARGET PROGRESS"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Prog_Pct", X+335, Y+78, "0%", 8, clrWhite);
   CreatePanel(UI_PREFIX+"Prog_BG", X+14, Y+98, 362, 6, UI_PanelBG, UI_PanelBG);
   CreatePanel(UI_PREFIX+"Prog_Fill", X+14, Y+98, 0, 6, UI_Accent, UI_Accent);

   CreateLabel(UI_PREFIX+"NetLbl", X+14, Y+118, GetUIString("กำไรรวมปัจจุบัน (Floating)", "BASKET FLOATING PROFIT"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Profit", X+14, Y+138, "$0.00", 20, clrWhite, "Impact");

   int startY = Y + 190;

   CreatePanel(UI_PREFIX+"Box1", X+14, startY, 176, 58, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Box1L", X+22, startY+6, GetUIString("กำไรสูงสุด ($)", "PEAK PROFIT ($)"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Peak", X+22, startY+26, "0.00", 11, clrWhite);

   CreatePanel(UI_PREFIX+"Box2", X+200, startY, 176, 58, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Box2L", X+208, startY+6, GetUIString("จุดล็อกกำไร ($)", "TRAILING SL ($)"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_TS", X+208, startY+26, GetUIString("สแตนด์บาย", "HOLD"), 10, clrOrange);

   CreatePanel(UI_PREFIX+"Box3", X+14, startY+66, 176, 58, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Box3L", X+22, startY+72, GetUIString("ไม้ที่เปิดอยู่", "ACTIVE POSITIONS"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Open", X+22, startY+92, "0 / 20", 11, clrWhite);

   CreatePanel(UI_PREFIX+"Box4", X+200, startY+66, 176, 58, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Box4L", X+208, startY+72, GetUIString("โหมดคำสั่ง", "ORDER MODE"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Pend", X+208, startY+92, "---", 10, UI_Accent);

   CreatePanel(UI_PREFIX+"BoxVirt", X+14, startY+132, 362, 75, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"VirtTitle", X+22, startY+137, GetUIString("สถานะ VIRTUAL GRID", "VIRTUAL GRID TARGETS"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_VirtBuy", X+22, startY+155, "Wait BUY : ---", 8, UI_Profit);
   CreateLabel(UI_PREFIX+"Val_VirtSell", X+22, startY+175, "Wait SELL: ---", 8, UI_Loss);

   string btnText = GetUIString("🚨 ปิดรวบทุกไม้ (CLOSE ALL)", "🚨 CLOSE ALL POSITIONS");
   CreateButton(BTN_CLOSE_ALL, X+14, startY+220, 362, 40, btnText, UI_Loss, clrWhite, 10);

   int X_Right  = X + 395;
   int PanelW   = 390;
   int ValX_Acc = X_Right + 175;

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

   string pText = (currentProfit >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(currentProfit), 2);
   ObjectSetString(0, UI_PREFIX+"Val_Profit", OBJPROP_TEXT, pText);
   ObjectSetInteger(0, UI_PREFIX+"Val_Profit", OBJPROP_COLOR, (currentProfit >= 0 ? UI_Profit : UI_Loss));

   double percent = 0.0;
   if(TargetProfit > 0) percent = currentProfit / TargetProfit;
   if(percent < 0) percent = 0.0;
   if(percent > 1.0) percent = 1.0;

   int barWidth = (int)(362 * percent);
   ObjectSetInteger(0, UI_PREFIX+"Prog_Fill", OBJPROP_XSIZE, barWidth);
   ObjectSetInteger(0, UI_PREFIX+"Prog_Fill", OBJPROP_BGCOLOR, (percent >= 1.0) ? clrOrange : UI_Accent);
   ObjectSetString(0, UI_PREFIX+"Prog_Pct", OBJPROP_TEXT, IntegerToString((int)(percent * 100)) + "%");

   bool timeAllowed = IsTradingAllowedByTime() && IsTradingAllowedBySession();

   if(IsClosingState) {
      ObjectSetInteger(0, UI_PREFIX+"LED_Icon", OBJPROP_COLOR, clrOrange);
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("กำลังเคลียร์ไม้ค้าง", "CLOSING ALL..."));
   } else if(!timeAllowed) {
      ObjectSetInteger(0, UI_PREFIX+"LED_Icon", OBJPROP_COLOR, clrRed);
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("นอกเวลาเซสชัน/เวลาเทรด", "OFF-TIME/SESSION"));
   } else if(openPos > 0 || pendingOrders > 0) {
      ObjectSetInteger(0, UI_PREFIX+"LED_Icon", OBJPROP_COLOR, UI_Profit);
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("กำลังทำงาน", "ACTIVE"));
   } else {
      ObjectSetInteger(0, UI_PREFIX+"LED_Icon", OBJPROP_COLOR, C'255,193,7');
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("ระบบพร้อมทำงาน", "ONLINE"));
   }

   ObjectSetString(0, UI_PREFIX+"Val_Peak", OBJPROP_TEXT, DoubleToString(maxProfit, 2));
   ObjectSetString(0, UI_PREFIX+"Val_TS", OBJPROP_TEXT, (currentTS > 0) ? "$" + DoubleToString(currentTS, 2) : GetUIString("สแตนด์บาย", "HOLD"));
   ObjectSetString(0, UI_PREFIX+"Val_Open", OBJPROP_TEXT, IntegerToString(openPos) + " / " + IntegerToString(TotalLevels * 2));

   if(GridType == GRID_VIRTUAL)
   {
      ObjectSetString(0, UI_PREFIX+"Val_Pend", OBJPROP_TEXT, "VIRTUAL GRID");
      double baseP = GridBasePrice;
      int distP    = (CachedGridDistance > 0) ? CachedGridDistance : GetDynamicGridDistance();
      double nextBuyP  = NormalizeDouble(baseP + (1 * distP * _Point), _Digits);
      double nextSellP = NormalizeDouble(baseP - (1 * distP * _Point), _Digits);

      if(openPos > 0)
      {
         ObjectSetString(0, UI_PREFIX+"VirtTitle", OBJPROP_TEXT, GetUIString("สถานะ VIRTUAL GRID (คำนวณตามไม้)", "VIRTUAL GRID (ACTIVE)"));
         ObjectSetString(0, UI_PREFIX+"Val_VirtBuy", OBJPROP_TEXT, "Base Price: " + DoubleToString(GridBasePrice, _Digits));
         ObjectSetString(0, UI_PREFIX+"Val_VirtSell", OBJPROP_TEXT, "Grid Distance: " + IntegerToString(distP) + " points");
      }
      else
      {
         ObjectSetString(0, UI_PREFIX+"VirtTitle", OBJPROP_TEXT, GetUIString("สถานะ VIRTUAL GRID (พร้อมเปิดไม้แรก)", "VIRTUAL GRID (READY)"));
         ObjectSetString(0, UI_PREFIX+"Val_VirtBuy", OBJPROP_TEXT, "Wait BUY  : " + DoubleToString(nextBuyP, _Digits));
         ObjectSetString(0, UI_PREFIX+"Val_VirtSell", OBJPROP_TEXT, "Wait SELL : " + DoubleToString(nextSellP, _Digits));
      }
   }
   else
   {
      ObjectSetString(0, UI_PREFIX+"Val_Pend", OBJPROP_TEXT, "PENDING: " + IntegerToString(pendingOrders));
      ObjectSetString(0, UI_PREFIX+"VirtTitle", OBJPROP_TEXT, GetUIString("สถานะ PENDING GRID (บน Server)", "PENDING GRID MODE"));
      ObjectSetString(0, UI_PREFIX+"Val_VirtBuy", OBJPROP_TEXT, "Server Orders: " + IntegerToString(pendingOrders));
      ObjectSetString(0, UI_PREFIX+"Val_VirtSell", OBJPROP_TEXT, "Max Slippage : " + IntegerToString(MaxSlippagePoints * m_multiplier) + " points");
   }

   ObjectSetString(0, UI_PREFIX+"Val_Bal", OBJPROP_TEXT, "$" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   ObjectSetString(0, UI_PREFIX+"Val_Eq", OBJPROP_TEXT, "$" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   ObjectSetString(0, UI_PREFIX+"Val_FreeM", OBJPROP_TEXT, "$" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2));
   ObjectSetString(0, UI_PREFIX+"Val_MLevel", OBJPROP_TEXT, DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), 2) + "%");
   ObjectSetString(0, UI_PREFIX+"Val_MaxDD", OBJPROP_TEXT, StringFormat("-$%.2f (-%.2f%%)", MaxDrawdownUSD, MaxDrawdownPercent));
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
