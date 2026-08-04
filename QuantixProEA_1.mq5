//+------------------------------------------------------------------+
//|                     Quantix_Classic20_Visual_BasketTS_Virtual.mq5|
//|        Dual Mode Grid (Pending / Virtual) + Basket Trailing Stop |
//|        Extended Horizontal Dashboard with Account Panel          |
//|        [REMOVED: UI Performance Stats Engine]                    |
//|        [FIXED: Added m_multiplier so all *Points inputs scale    |
//|                correctly across 2/3/4/5-digit symbols instead of |
//|                being used as raw, un-adjusted points, and lot    |
//|                volume now normalizes to the symbol's actual      |
//|                VOLUME_STEP/MIN/MAX instead of a fixed 2 decimals]|
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

// ตัวแประบบ Grid
double   GridBasePrice      = 0.0;    
int      CachedGridDistance = 0;    

// ป้องกันการยิงเบิ้ล & คุมสภาวะกำลังปิดพอร์ต (Closing Guard)
datetime LastOrderSentTime  = 0; 
datetime LastCloseAllTime   = 0;    // เวลาปิดพอร์ตล่าสุด
bool     IsClosingState     = false;  // สถานะกำลังปิดพอร์ต ล็อคไม่ให้ยิงไม้ใหม่เด็ดขาด

// ตัวแปรสำหรับคำนวณ Max Drawdown (%) และ ($)
double   PeakBalanceForDD   = 0.0;
double   MaxDrawdownPercent = 0.0;
double   MaxDrawdownUSD     = 0.0; 

string   UI_PREFIX       = "QX_PRO_";
string   BTN_CLOSE_ALL   = "QX_PRO_BtnCloseAll";

// Handle สำหรับอินดิเคเตอร์ ATR
int      atrHandle       = INVALID_HANDLE;

// 10 for 3/5-digit (fractional-pip) symbols, 1 otherwise - keeps every *Points input meaning the same real price distance across symbols
int      m_multiplier    = 1;

// --- [ UI OPTIMIZATION GLOBAL VARS ] ---
uint     lastUIUpdateTime = 0;

//====================== FUNCTION DECLARE ==========================//

bool IsTradingAllowedByTime();
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
double NormalizeLot(double lot);

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
//| Round a lot size to the symbol's actual VOLUME_STEP and clamp    |
//| it to VOLUME_MIN/MAX so OrderSend can't be rejected with an      |
//| invalid-volume error on brokers whose lot step isn't 0.01        |
//| (e.g. 0.1, 1.0, or 0.001 lot steps).                              |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
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
//| Force Reset Base Price directly to Current Market Price          |
//+------------------------------------------------------------------+
void RecalculateBasePrice()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   GridBasePrice = NormalizeDouble((ask + bid) / 2.0, _Digits);
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
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Digits == 3 || _Digits == 5) m_multiplier = 10;
   else m_multiplier = 1;

   trade.LogLevel(LOG_LEVEL_ERRORS);
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(MaxSlippagePoints * m_multiplier);
   
   MaxBasketProfit    = 0.0;
   LastOrderSentTime  = 0;
   LastCloseAllTime   = 0;
   IsClosingState     = false;
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

      if(!GridCreated)
      {
         RecalculateBasePrice();
      }
   }

   // 2. Visual Basket Trailing Stop
   if(openPositions > 0 && !IsClosingState)
   {
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
      if(!IsClosingState && (MaxBasketProfit < TargetProfit) && (TimeCurrent() - LastCloseAllTime >= 3))
      {
         ExecuteGridLogic();
      }
   }
   else
   {
      if((openPositions > 0 || pendingOrders > 0) && !IsClosingState)
      {
         IsClosingState = true;
         Print("⏰ [TIME FILTER] Outside trading hours -> Auto Closing all active positions...");
         ClearEverythingAsync();
         DeleteVisualTSLine();
         RecalculateBasePrice();
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

   double currentATR = atrValues[0];
   double calculatedPoints = (currentATR * ATR_Multiplier) / _Point;
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

   GridBasePrice = (ask + bid) / 2.0;
   CachedGridDistance = GetDynamicGridDistance();

   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();
   MqlTradeRequest request;
   MqlTradeResult  result;

   for(int level = 1; level <= TotalLevels; level++)
   {
      double lot = BaseLot * MathPow(LotMultiplier, level - 1);
      lot = NormalizeLot(lot);

      double targetBuyPrice  = NormalizeDouble(GridBasePrice + (level * CachedGridDistance * point), _Digits);
      double targetSellPrice = NormalizeDouble(GridBasePrice - (level * CachedGridDistance * point), _Digits);

      // BUY STOP (Async)
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

      // SELL STOP (Async)
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

   GridCreated = true;
}

//+------------------------------------------------------------------+
//| Virtual Grid Execution                                           |
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

   // CHECK BUY GRID
   if(buyCount < TotalLevels)
   {
      double targetPrice = 0.0;
      if(buyCount == 0)
         targetPrice = NormalizeDouble(GridBasePrice + (stepDistance * point), _Digits);
      else
         targetPrice = NormalizeDouble(lastBuyPrice + (stepDistance * point), _Digits);

      double diffPoints = (ask - targetPrice) / point;

      bool canSendBuy = false;
      if(diffPoints >= 0)
      {
         if(!UseGapProtection || diffPoints <= adjGapLimit)
            canSendBuy = true;
      }

      if(canSendBuy)
      {
         if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= adjSpread)
         {
            int nextLevel = buyCount + 1;
            double lot = NormalizeLot(BaseLot * MathPow(LotMultiplier, nextLevel - 1));

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
               return;
            }
         }
      }
      else if(UseGapProtection && diffPoints > adjGapLimit)
      {
         PrintFormat("⚠️ [BUY GAP EXCEEDED] Skip Order! Ask: %s | Target: %s | Diff: %.0f pts > Max: %d. Re-anchoring Buy Base...",
                     DoubleToString(ask, _Digits), DoubleToString(targetPrice, _Digits), diffPoints, adjGapLimit);

         if(buyCount == 0) GridBasePrice = ask;
         else lastBuyPrice = ask;
      }
   }

   // CHECK SELL GRID
   if(sellCount < TotalLevels)
   {
      double targetPrice = 0.0;
      if(sellCount == 0)
         targetPrice = NormalizeDouble(GridBasePrice - (stepDistance * point), _Digits);
      else
         targetPrice = NormalizeDouble(lastSellPrice - (stepDistance * point), _Digits);

      double diffPoints = (targetPrice - bid) / point;

      bool canSendSell = false;
      if(diffPoints >= 0)
      {
         if(!UseGapProtection || diffPoints <= adjGapLimit)
            canSendSell = true;
      }

      if(canSendSell)
      {
         if(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= adjSpread)
         {
            int nextLevel = sellCount + 1;
            double lot = NormalizeLot(BaseLot * MathPow(LotMultiplier, nextLevel - 1));

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
               return;
            }
         }
      }
      else if(UseGapProtection && diffPoints > adjGapLimit)
      {
         PrintFormat("⚠️ [SELL GAP EXCEEDED] Skip Order! Bid: %s | Target: %s | Diff: %.0f pts > Max: %d. Re-anchoring Sell Base...",
                     DoubleToString(bid, _Digits), DoubleToString(targetPrice, _Digits), diffPoints, adjGapLimit);

         if(sellCount == 0) GridBasePrice = bid;
         else lastSellPrice = bid;
      }
   }
}

//+------------------------------------------------------------------+
//| Clear Account Function                                           |
//+------------------------------------------------------------------+
void ClearEverythingAsync()
{
   MqlTradeRequest request;
   MqlTradeResult  result;
   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();

   // 1. เคลียร์ Pending Orders
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

   // 2. เคลียร์ Open Positions
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
      
      bool sent = OrderSendAsync(request, result);
      if(!sent) Print("Clear Position OrderAsync failed: ", GetLastError());
   }

   GridCreated        = false; 
   MaxBasketProfit    = 0.0;
   GridBasePrice      = 0.0;
   CachedGridDistance = 0;
   LastOrderSentTime  = 0;
}

//+------------------------------------------------------------------+
//| Draw Visual TS Line Function                                     |
//+------------------------------------------------------------------+
void DrawVisualTSLine(double tsValue)
{
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
   
   // แสดงผล Max DD ทั้งแบบตัวเงิน (-$XX.XX) และ (-XX.XX%)
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