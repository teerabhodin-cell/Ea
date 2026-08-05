//+------------------------------------------------------------------+
//|                                                   QuantixProEA.mq5|
//|        Dual Mode Grid (Pending / Virtual) + Basket Trailing Stop |
//|        Extended Horizontal Dashboard with Account Panel          |
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
input group "===== 1. Time & Language ====="
input ENUM_LANGUAGE Language = LNG_TH; // Select Language ( default: Thai )
input bool    UseTimer         = true;    // Time Filter (คุมเวลา)
input bool    UseLocalTime     = false;   // Use Local PC Time (อิงตามเครื่อง, ไม่ใช่ Server)
input int     StartHour        = 2;       // Start Hour (ชม.เริ่ม)
input int     StartMinute      = 0;
input int     EndHour          = 22;      // Stop Hour (ชม.หยุด)
input int     EndMinute        = 0;

input group "===== 2. Main Grid ====="
input ENUM_GRID_TYPE GridType       = GRID_VIRTUAL; // Grid Type (รูปแบบ Grid)
input double BaseLot                = 0.05;
input double LotMultiplier          = 1.5;
input int    TotalLevels            = 10;      // Levels per Side (จำนวนชั้น/ฝั่ง)
input bool   UseATRDistance         = true;    // Use ATR Distance (ระยะตาม ATR)
input int    ATR_Period             = 14;      // ATR Period
input double ATR_Multiplier         = 1.05;    // ATR Multiplier
input bool   UseAdaptiveATRGrid     = false;   // Per-Side ATR Distance (แยกระยะต่อฝั่ง)
input int    DistancePoints         = 250;     // Fixed Distance, pts (ระยะคงที่)
input ulong  MagicNumber            = 112233;

input group "===== 3. Target & Trailing ====="
input double TargetProfit        = 5.0;    // Target Profit $ (เป้ากำไร)
input double TrailingStopUSD     = 0.2;    // Trailing Distance $ (ระยะเทรล)

input group "===== 4. Trend Filters ====="
input bool   UseEMAFilter           = false;   // Use EMA Filter (ใช้ EMA)
input int    EMA_Period             = 200;     // EMA Period
input bool   StrictBuyFilter        = false;   // Block Buy < EMA (ล็อค Buy)
input bool   StrictSellFilter       = false;   // Block Sell > EMA (ล็อค Sell)
input bool   UseMTFFilter          = true;    // Use MTF Filter (ใช้ MTF)
input ENUM_TIMEFRAMES MTF_Period   = PERIOD_H1; // MTF Timeframe

input group "===== 5. Lot & Capital ====="
input bool   UseDynamicLot          = false;   // Dynamic Lot by Equity (Lot ตาม Equity)
input double BalancePerLot          = 8000.0;  // Equity per 0.01 Lot
input bool   UseEquityLock          = false;   // Equity Lock (ล็อคพอร์ต)
input double MinEquityLimit         = 4000.0;  // Min Equity Limit
input bool   UseAutoReduceLot       = false;   // Auto Reduce Lot on DD (ลด Lot อัตโนมัติ)
input double ReduceLotThresholdDD   = 20.0;    // Reduce Lot DD Trigger %

input group "===== 6. Max DD Stop ====="
input bool   UseMaxDDStop           = false;   // Max DD Stop (ตัดขาดทุน)
input double MaxAllowedDD_USD       = 1000.0;  // Max DD Allowed $ (0=off)
input double MaxAllowedDD_Pct       = 0.0;     // Max DD Allowed % (0=off)
input bool   UseEmergencySL         = false;   // Emergency SL (SL ฉุกเฉิน)
input int    EmergencySL_Points     = 10000;   // Emergency SL Distance, pts
input bool   UseTotalDDGuard        = false;   // Total DD Guard (คุม DD สะสม)
input double MaxTotalDD_Pct         = 15.0;    // Max Total DD %

input group "===== 7. Position Mgmt ====="
input bool   UseBasketBreakeven     = false;   // Breakeven (คุ้มทุน)
input double BreakevenTriggerUSD    = 5.0;     // Breakeven Trigger $
input double BreakevenLockUSD       = 2.0;     // Breakeven Lock $
input bool   UsePartialClose        = false;   // Partial Close (ปิดบางส่วน)
input double PartialCloseProfitUSD  = 20.0;    // Partial Close Trigger $
input double PartialClosePercent    = 50.0;    // Partial Close %
input bool   UseRecoveryMode        = false;   // Recovery Mode (แก้ไม้)
input double RecoveryDD_TriggerPercent = 10.0; // Recovery DD Trigger %
input double RecoveryLotBoost          = 2.0;  // Recovery Lot Boost

input group "===== 8. Overflow ====="
input bool   UseLevelUnlock      = true;    // Level Unlock (ปลดล็อคชั้น)
input int    MaxUnlockedLevels   = 0;       // Max Unlocked Levels (0=∞)
input bool   UseForceHedgeOnDD          = false;  // Force Hedge on DD
input double ForceHedgeDD_TriggerPercent = 10.0;  // Force Hedge DD Trigger %
input double ForceHedgeResetPercent      = 5.0;   // Force Hedge Reset %
input double ForceHedgeLotMultiplier     = 1.4;   // Force Hedge Lot Multiplier
input bool   UseForceHedgeOnTime        = false;  // Force Hedge on Time
input int    ForceHedgeTimeMinutes      = 33;     // Force Hedge Time, Min

input group "===== 9. Gap / Slippage ====="
input bool   UseGapProtection    = true;   // Gap Protection (กันช่องว่างราคา)
input int    MaxAllowedGapPoints = 100;    // Max Gap Allowed, pts
input int    GapDetectionSeconds = 60;     // Gap Detection, Sec
input int    MaxSlippagePoints   = 20;     // Max Slippage, pts
input int    MaxSpreadAllowed    = 40;     // Max Spread Allowed, pts

input group "===== 10. Dashboard Colors ====="
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
// UseAdaptiveATRGrid: ระยะ Grid แยกอิสระต่อฝั่ง คำนวณจาก ATR สดใหม่ทุกครั้งที่ฝั่งนั้น fill
// (ไม่ใช่ค่าเดียวใช้ร่วมกันสองฝั่งเหมือน CachedGridDistance) ฝั่งที่ยังไม่ fill จะไม่ถูกแตะเลย
int      BuyGridDistance    = 0;
int      SellGridDistance   = 0;

// ป้องกันการยิงเบิ้ล & คุมสภาวะกำลังปิดพอร์ต (Closing Guard)
datetime LastOrderSentTime  = 0;
datetime LastCloseAllTime   = 0;    // เวลาปิดพอร์ตล่าสุด
bool     IsClosingState     = false;  // สถานะกำลังปิดพอร์ต ล็อคไม่ให้ยิงไม้ใหม่เด็ดขาด

// ตัวแปรสำหรับคำนวณ Max Drawdown (%) และ ($)
double   PeakBalanceForDD   = 0.0;
double   MaxDrawdownPercent = 0.0;
double   MaxDrawdownUSD     = 0.0;

// Total DD Guard: peak ที่ไม่ reset หลังตัดขาดทุนแต่ละรอบ (ต่างจาก PeakBalanceForDD ด้านบน)
// ใช้คุม DD สะสมของทั้งพอร์ตตั้งแต่เริ่ม EA
double   AccountPeakBalanceAllTime = 0.0;
bool     TradingHalted              = false; // true = ทะลุ MaxTotalDD_Pct แล้ว หยุดเปิดไม้ใหม่ถาวรจนกว่าจะ restart EA

// Basket Management & Recovery
bool     PartialCloseExecuted = false; // ป้องกันการสั่งปิดบางส่วนซ้ำรอบเดิม
bool     BreakevenActivated   = false; // latch เมื่อกำไรแตะ BreakevenTriggerUSD แล้ว (ต้อง latch ไว้ก่อน ไม่งั้นเงื่อนไข Trigger/Lock จะไม่มีวันเป็นจริงพร้อมกัน)
bool     ForceHedgeArmed      = false; // latch กัน Force Hedge ยิงรัวๆ ทุกทิคตอน DD ค้างสูง ต้องรอ DD ลดต่ำกว่า ForceHedgeResetPercent ก่อนถึงจะยิงซ้ำได้
datetime BasketNegativeSinceTime = 0;   // เวลาที่บาสเก็ตเริ่มติดลบต่อเนื่อง (0 = ไม่ได้ติดลบอยู่ตอนนี้) ใช้กับ Force Hedge on Time
datetime LastForceHedgeTimeFire  = 0;   // เวลาที่ Force Hedge on Time ยิงไม้ล่าสุด (0 = ยังไม่เคยยิงในรอบติดลบปัจจุบัน) - ยิงซ้ำได้ทุกๆ ForceHedgeTimeMinutes ถ้ายังติดลบไม่หยุด ไม่ต้องรอพลิกบวกก่อน

// สถิติสรุปผล (นับตอนบาสเก็ตปิดจริงใน ClearEverythingAsync เท่านั้น)
int      StatsTotalBaskets   = 0;
int      StatsWinCount       = 0;
int      StatsLossCount      = 0;
double   StatsSumWinProfit   = 0.0;
double   StatsSumLossAmount  = 0.0; // เก็บเป็นค่าบวกเสมอ (magnitude ของขาดทุน)

string   UI_PREFIX       = "QX_PRO_";
string   BTN_CLOSE_ALL   = "QX_PRO_BtnCloseAll";

// Handle สำหรับอินดิเคเตอร์ ATR / EMA / Multi-Timeframe EMA
int      atrHandle       = INVALID_HANDLE;
int      emaHandle       = INVALID_HANDLE;
int      mtfEmaHandle    = INVALID_HANDLE;

// --- [ UI OPTIMIZATION GLOBAL VARS ] ---
uint     lastUIUpdateTime = 0;
bool     IsTestingMode    = false; // true in Strategy Tester - skips all dashboard object creation/updates to speed up backtests

datetime lastFilterBlockLogTime = 0; // throttles the "why didn't it open" filter diagnostic to once/minute
datetime lastGapLogTime         = 0; // throttles the GAP EXCEEDED re-anchor messages so a choppy market can't spam the Journal every tick
datetime lastSpreadLogTime      = 0; // throttles the SPREAD BLOCKED message - without this, a wide spread during a fast move silently blocks entries with zero Journal output, indistinguishable from a phantom filter
datetime lastTickTimeForGap     = 0; // เวลาของทิคก่อนหน้า ใช้แยก "เทรนด์วิ่งแรงต่อเนื่อง" ออกจาก "Gap จริง" (ราคาข้ามช่วงที่ไม่มีทิคเลย)
int      SecondsSinceLastTick   = 0; // อัปเดตครั้งเดียวต่อทิคใน OnTick() แล้วอ่านใช้ใน ExecuteGridLogic()

//====================== FUNCTION DECLARE ==========================//

bool IsTradingAllowedByTime();
bool CheckEMATrend(bool isBuy);
bool CheckMTFFilter(bool isBuy);
double GetCalculatedLotSize(int nextLevel);
double CalcEmergencySL(bool isBuy, double entryPrice, double point);
void ApplyBasketBreakevenAndPartial(double currentProfit);
void CheckForceHedgeOnDD();
bool TryOpenForceHedgeOrder(string reasonTag, string logDetail);
void CheckForceHedgeOnTime();
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
void ReconcileGridStateOnInit();
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
   BuyGridDistance    = CachedGridDistance;
   SellGridDistance   = CachedGridDistance;
   GridCreated = true;
}

//+------------------------------------------------------------------+
//| Called once from OnInit() instead of blindly calling              |
//| RecalculateBasePrice(). If the EA restarts/recompiles while a     |
//| basket is still open (very common - changing an input forces MT5  |
//| to re-run OnInit but real positions stay open), the old code reset|
//| GridBasePriceBuy/Sell straight to the CURRENT market price no     |
//| matter what, ignoring any position that already exists. For the   |
//| side that's still empty (count==0), that produces a target        |
//| completely disconnected from where the other side's most recent   |
//| fill actually was - e.g. Sell fills, EA restarts before Buy ever   |
//| opens, Buy's anchor resets to "whatever price is right now"       |
//| instead of staying pinned above the Sell fill like it would if    |
//| the EA had kept running - so Buy can end up opening BELOW where   |
//| Sell just filled, which looks like nonsense from the trade list.  |
//| Reconstructing the anchor from the actual last fill on the        |
//| opposite side reproduces the same pin the live "keep the          |
//| still-empty side's target pinned" logic already does everywhere   |
//| else, so a restart mid-basket behaves the same as if it had never |
//| restarted at all.                                                 |
//+------------------------------------------------------------------+
void ReconcileGridStateOnInit()
{
   int    buyCount = 0, sellCount = 0;
   double lastBuyPrice = 0.0, lastSellPrice = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         buyCount++;
         if(openPrice > lastBuyPrice || lastBuyPrice == 0.0) lastBuyPrice = openPrice;
      }
      else
      {
         sellCount++;
         if(openPrice < lastSellPrice || lastSellPrice == 0.0) lastSellPrice = openPrice;
      }
   }

   if(buyCount == 0 && sellCount == 0)
   {
      // ไม่มีไม้เก่าค้างเลย - พอร์ตว่างจริงๆ ใช้ RecalculateBasePrice() ปกติได้เลย
      RecalculateBasePrice();
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   GridBasePrice = NormalizeDouble((ask + bid) / 2.0, _Digits);

   // ฝั่งที่มีไม้อยู่แล้ว (count>0) ไม่ได้ใช้ GridBasePriceBuy/Sell อีกต่อไปอยู่แล้ว
   // (ExecuteGridLogic ใช้ราคาไม้จริงคำนวณแทน) แต่ฝั่งที่ยังว่าง (count==0) ยังต้องพึ่ง
   // ค่านี้อยู่ - ผูกกับราคาไม้ล่าสุดของอีกฝั่งแทนที่จะรีเซ็ตไปที่ราคาตลาดปัจจุบันตรงๆ
   GridBasePriceBuy  = (buyCount  > 0) ? lastBuyPrice  : ((sellCount > 0) ? lastSellPrice : GridBasePrice);
   GridBasePriceSell = (sellCount > 0) ? lastSellPrice : ((buyCount  > 0) ? lastBuyPrice  : GridBasePrice);

   BuyGapAnchor  = 0.0;
   SellGapAnchor = 0.0;
   CachedGridDistance = GetDynamicGridDistance();
   BuyGridDistance    = CachedGridDistance;
   SellGridDistance   = CachedGridDistance;
   GridCreated = true;

   PrintFormat("🔄 [RECONCILE] EA (re)started with existing positions (Buy:%d Sell:%d) - anchors reconstructed instead of reset (Buy anchor=%.5f, Sell anchor=%.5f).",
               buyCount, sellCount, GridBasePriceBuy, GridBasePriceSell);
}

//+------------------------------------------------------------------+
//| Check Trading Hours Function                                     |
//+------------------------------------------------------------------+
bool IsTradingAllowedByTime()
{
   if(!UseTimer) return true;

   // UseLocalTime: อิงเวลาเครื่อง (TimeLocal) แทน Server Time (TimeCurrent) - ใช้ได้เฉพาะ
   // เทรดจริง/เดโม่เท่านั้น เพราะใน Strategy Tester เวลาเครื่องจริงตอนรันเทสไม่ได้ sync
   // กับเวลาในตลาดจำลองเลย ถ้าเปิดตัวนี้ตอน backtest ผลลัพธ์จะไม่มีความหมาย
   MqlDateTime dt;
   TimeToStruct(UseLocalTime ? TimeLocal() : TimeCurrent(), dt);

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
//| Diagnostic: which filter(s) are blocking Buy/Sell right now      |
//| Without this, "why doesn't it open a position" is unanswerable   |
//| from the dashboard alone - the entry gate is a silent AND of up  |
//| to 2 filters, and the wait target line looks the same whether    |
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

   if(blockers == "") return; // nothing actually blocked it - price just hasn't reached the target yet

   lastFilterBlockLogTime = TimeCurrent();
   PrintFormat("🔍 [%s BLOCKED] %s", isBuy ? "BUY" : "SELL", blockers);
}

//+------------------------------------------------------------------+
//| Emergency Stop Loss (server-side last resort, NOT a strategy SL) |
//| Returns 0.0 (no SL) when UseEmergencySL is off. When on, computes |
//| a price EmergencySL_Points away from entry - deliberately wide so |
//| it never interferes with normal basket management, only protects |
//| the account if the EA/terminal stops running entirely.           |
//+------------------------------------------------------------------+
double CalcEmergencySL(bool isBuy, double entryPrice, double point)
{
   if(!UseEmergencySL) return 0.0;
   double dist = EmergencySL_Points * m_multiplier * point;
   return isBuy ? NormalizeDouble(entryPrice - dist, _Digits) : NormalizeDouble(entryPrice + dist, _Digits);
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

   // FIXED: UseRecoveryMode used to boost every lot by a flat 1.2x unconditionally,
   // even at zero drawdown - despite its own description saying it's meant to
   // "accelerate recovery when the account has accumulated losses". Now it only
   // boosts once MaxDrawdownPercent actually crosses RecoveryDD_TriggerPercent, by
   // the configurable RecoveryLotBoost multiplier.
   if(UseRecoveryMode && MaxDrawdownPercent >= RecoveryDD_TriggerPercent)
   {
      lot = lot * RecoveryLotBoost;
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
//| Force Hedge on High DD                                            |
//| When (live, current) drawdown crosses ForceHedgeDD_TriggerPercent, |
//| immediately market-opens one order on whichever side has FEWER    |
//| positions (the side that isn't currently hedging), bypassing      |
//| every directional filter (EMA/MTF) and the                        |
//| normal grid price-target wait entirely - those filters are        |
//| exactly what can leave one side unhedged during a strong trend,   |
//| which is the scenario this is meant to rescue.                   |
//|                                                                    |
//| Uses LIVE drawdown (PeakBalanceForDD vs current equity right now), |
//| not the session's all-time-worst MaxDrawdownPercent - that one    |
//| only ever grows, so gating on it would let this fire at most once |
//| per session and never re-arm after the account recovers.          |
//|                                                                    |
//| Latches after firing until live DD drops back below                |
//| ForceHedgeResetPercent, so it fires once per DD spike instead of   |
//| stacking a new forced order every tick while DD stays elevated.    |
//+------------------------------------------------------------------+
// Shared executor for both Force Hedge triggers (DD-based and Time-based) -
// they open the exact same kind of order via the exact same lot/cap logic,
// just armed by a different condition. reasonTag goes into the order
// comment and log line so it's obvious in the journal which trigger fired.
bool TryOpenForceHedgeOrder(string reasonTag, string logDetail)
{
   int buyCount = 0, sellCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buyCount++;
      else sellCount++;
   }

   if(buyCount == sellCount) return false; // สมดุลอยู่แล้ว ไม่มีฝั่งไหนต้องบังคับเปิดเพิ่ม

   bool needBuy = (sellCount > buyCount); // Sell มีไม้มากกว่า (ขาด Buy ไปถ่วง) -> เปิด Buy
   int  neededSideCount = needBuy ? buyCount : sellCount;

   int cap = TotalLevels;
   if(UseLevelUnlock) cap += (MaxUnlockedLevels <= 0 ? 999999 : MaxUnlockedLevels);
   if(neededSideCount >= cap) return false; // เต็มเพดานแล้ว (รวม Level Unlock ถ้าเปิด) บังคับเพิ่มไม่ได้

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(ask <= 0 || bid <= 0) return false;

   // Force Hedge IS its own recovery mechanism (active: force-open now, vs.
   // Recovery Mode's passive boost-when-the-grid-triggers-anyway) - it computes
   // lot from the same BaseLot/LotMultiplier progression directly instead of
   // going through GetCalculatedLotSize(), which would also bake in
   // UseAutoReduceLot's cut and UseRecoveryMode's boost. Stacking those on top
   // of ForceHedgeLotMultiplier made the two DD-recovery systems compound in a
   // way that's hard to reason about (and RecoveryMode's own trigger check uses
   // the session's all-time-peak DD, which never resets, so it could stay
   // silently baked in long after the account recovered from an earlier spike).
   double baseLot = BaseLot;
   if(UseDynamicLot)
   {
      double currentEq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(BalancePerLot > 0)
      {
         baseLot = NormalizeDouble((currentEq / BalancePerLot) * BaseLot, 2);
         if(baseLot < 0.01) baseLot = 0.01;
      }
   }
   double lot = baseLot * MathPow(LotMultiplier, neededSideCount) * ForceHedgeLotMultiplier;

   double minVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepVol > 0) lot = MathRound(lot / stepVol) * stepVol;
   if(minVol  > 0 && lot < minVol) lot = minVol;
   if(maxVol  > 0 && lot > maxVol) lot = maxVol;
   lot = NormalizeDouble(MathMax(0.01, lot), 2);

   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request); ZeroMemory(result);
   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = _Symbol;
   request.volume       = lot;
   request.type         = needBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price        = needBuy ? ask : bid;
   request.sl           = CalcEmergencySL(needBuy, needBuy ? ask : bid, point);
   request.deviation    = MaxSlippagePoints * m_multiplier;
   request.magic        = MagicNumber;
   request.comment      = reasonTag + (needBuy ? "-BUY" : "-SELL");
   request.type_filling = fillMode;

   if(OrderSend(request, result))
   {
      LastOrderSentTime = TimeCurrent();
      PrintFormat("🆘 [%s] %s -> Forced %s %.2f lot (Buy:%d Sell:%d before).",
                  reasonTag, logDetail, needBuy ? "BUY" : "SELL", lot, buyCount, sellCount);
      return true;
   }

   Print(reasonTag, " OrderSend failed: ", GetLastError(), " retcode: ", result.retcode);
   return false;
}

void CheckForceHedgeOnDD()
{
   if(!UseForceHedgeOnDD || IsClosingState || TradingHalted) return;

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double liveDDPercent = 0.0;
   if(PeakBalanceForDD > 0)
   {
      double liveDDVal = PeakBalanceForDD - currentEquity;
      if(liveDDVal < 0) liveDDVal = 0;
      liveDDPercent = (liveDDVal / PeakBalanceForDD) * 100.0;
   }

   if(liveDDPercent < ForceHedgeResetPercent)
   {
      ForceHedgeArmed = false;
      return;
   }

   if(liveDDPercent < ForceHedgeDD_TriggerPercent || ForceHedgeArmed) return;

   string detail = StringFormat("Live DD %.2f%% >= %.2f%%", liveDDPercent, ForceHedgeDD_TriggerPercent);
   if(TryOpenForceHedgeOrder("FORCE-HEDGE-DD", detail)) ForceHedgeArmed = true;
}

//+------------------------------------------------------------------+
//| Force Hedge on Time                                              |
//| Independent of DD% entirely - if the basket has been sitting     |
//| continuously underwater (currentProfit < 0) for longer than      |
//| ForceHedgeTimeMinutes, force-open the underweight side right     |
//| away instead of waiting for the grid to reach the next level or  |
//| for DD% to climb high enough to trip Force Hedge on DD.          |
//|                                                                    |
//| REPEATS every ForceHedgeTimeMinutes for as long as the basket    |
//| stays negative - it does NOT wait for a flip to profit before    |
//| firing again, unlike Force Hedge on DD's percent-based re-arm.   |
//| Each fire nudges Buy/Sell count one step closer to balanced, and |
//| TryOpenForceHedgeOrder() naturally stops once counts are equal   |
//| or the level cap (TotalLevels [+ Level Unlock]) is reached, so   |
//| this can't run away past that. BasketNegativeSinceTime is        |
//| tracked once per tick in OnTick() and resets to 0 the moment the |
//| basket turns flat/positive or closes, which also resets the      |
//| repeat clock below for the next negative streak.                 |
//+------------------------------------------------------------------+
void CheckForceHedgeOnTime()
{
   if(!UseForceHedgeOnTime || IsClosingState || TradingHalted) return;

   if(BasketNegativeSinceTime == 0)
   {
      LastForceHedgeTimeFire = 0;
      return;
   }

   datetime sinceRef = (LastForceHedgeTimeFire > 0) ? LastForceHedgeTimeFire : BasketNegativeSinceTime;
   int secondsSince = (int)(TimeCurrent() - sinceRef);
   if(secondsSince < ForceHedgeTimeMinutes * 60) return;

   int totalMinNegative = (int)((TimeCurrent() - BasketNegativeSinceTime) / 60);
   string detail = StringFormat("Basket negative continuously for %d min (still stuck %d min after last force-hedge)",
                                 totalMinNegative, secondsSince / 60);
   if(TryOpenForceHedgeOrder("FORCE-HEDGE-TIME", detail)) LastForceHedgeTimeFire = TimeCurrent();
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
   ForceHedgeArmed      = false;
   BasketNegativeSinceTime = 0;
   LastForceHedgeTimeFire  = 0;
   StatsTotalBaskets    = 0;
   StatsWinCount        = 0;
   StatsLossCount       = 0;
   StatsSumWinProfit    = 0.0;
   StatsSumLossAmount   = 0.0;
   PeakBalanceForDD   = AccountInfoDouble(ACCOUNT_BALANCE);
   MaxDrawdownPercent = 0.0;
   MaxDrawdownUSD     = 0.0;
   AccountPeakBalanceAllTime = AccountInfoDouble(ACCOUNT_BALANCE);
   TradingHalted             = false;

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

   if(GridType == GRID_VIRTUAL) ReconcileGridStateOnInit();
   else RecalculateBasePrice();

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
   // วัดระยะเวลาตั้งแต่ทิคก่อนหน้า - ใช้แยกแยะ "ราคาวิ่งแรงต่อเนื่อง" (ทิคยังเข้ามาปกติ)
   // ออกจาก "Gap จริง" (ไม่มีทิคเข้ามาเลยช่วงหนึ่ง เช่น ข้ามคืน/สุดสัปดาห์) ใน Gap Protection ด้านล่าง
   SecondsSinceLastTick = (lastTickTimeForGap > 0) ? (int)(TimeCurrent() - lastTickTimeForGap) : 0;
   lastTickTimeForGap   = TimeCurrent();

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

   // ติดตามว่าบาสเก็ตติดลบต่อเนื่องมานานแค่ไหน สำหรับ Force Hedge on Time -
   // นับใหม่ทันทีที่พลิกมาเป็นบวก/เท่าทุน หรือปิดหมด
   if(openPositions > 0 && currentProfit < 0)
   {
      if(BasketNegativeSinceTime == 0) BasketNegativeSinceTime = TimeCurrent();
   }
   else
   {
      BasketNegativeSinceTime = 0;
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

      // FIXED: previously gated on (currentProfit >= TargetProfit), so once the
      // basket had climbed above target and MaxBasketProfit recorded a real peak,
      // a fast enough reversal that jumped straight from above TargetProfit to
      // BELOW it in a single tick (skipping over the trigger zone entirely, e.g.
      // a Force Hedge fill landing right before a sharp move) fell into the else
      // branch below and never got checked against tsTriggerLine again - ever.
      // MaxBasketProfit stayed frozen at the old peak (blocking ExecuteGridLogic
      // too, since it's gated on MaxBasketProfit < TargetProfit), and the basket
      // was stuck open with no exit, bleeding indefinitely. Gating on
      // (MaxBasketProfit >= TargetProfit) instead means once a real peak has ever
      // been recorded, every subsequent tick keeps checking the floor regardless
      // of where currentProfit currently sits, so a crash like that gets caught
      // and closed on the very next tick instead of being silently abandoned.
      if(MaxBasketProfit >= TargetProfit || currentProfit >= TargetProfit)
      {
         if(currentProfit > MaxBasketProfit)
         {
            MaxBasketProfit = currentProfit;
         }

         double tsTriggerLine = MaxBasketProfit - TrailingStopUSD;

         DrawVisualTSLine(tsTriggerLine);

         if(currentProfit <= tsTriggerLine)
         {
            IsClosingState = true;
            PrintFormat("🚨 [BASKET TS TRIGGERED] Peak: $%.2f | Floating: $%.2f",
                        MaxBasketProfit, currentProfit);
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
      if(!IsClosingState && !equityLocked && !TradingHalted && (MaxBasketProfit < TargetProfit) && (TimeCurrent() - LastCloseAllTime >= 3))
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
   CheckForceHedgeOnDD();
   CheckForceHedgeOnTime();

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

   // Total DD Guard: ใช้ AccountPeakBalanceAllTime ซึ่งไม่ reset หลังตัดขาดทุนแต่ละรอบ
   // ต่างจาก PeakBalanceForDD ด้านบนที่ reset ทุกครั้งที่ MaxDDStop ยิง - ตัวนี้จับ DD
   // สะสมจริงของทั้งพอร์ต กันขาดทุนติดกันหลายรอบย่อยๆ (แต่ละรอบไม่เกิน MaxAllowedDD)
   // รวมกันแล้วกินพอร์ตหนักเกินไป
   if(currentBalance > AccountPeakBalanceAllTime) AccountPeakBalanceAllTime = currentBalance;

   if(UseTotalDDGuard && !TradingHalted && AccountPeakBalanceAllTime > 0)
   {
      double totalDDVal = AccountPeakBalanceAllTime - currentEquity;
      if(totalDDVal < 0) totalDDVal = 0;
      double totalDDPercent = (totalDDVal / AccountPeakBalanceAllTime) * 100.0;

      if(totalDDPercent >= MaxTotalDD_Pct)
      {
         TradingHalted  = true;
         IsClosingState = true;
         PrintFormat("🛑🛑🛑 [TOTAL DD GUARD] Cumulative account DD: $%.2f (%.2f%%) exceeded MaxTotalDD_Pct=%.2f%% -> Closing everything and HALTING new trades permanently. Restart EA to resume.",
                     totalDDVal, totalDDPercent, MaxTotalDD_Pct);
         ClearEverythingAsync();
         DeleteVisualTSLine();
         DeleteAllPendingOrders();
         IsClosingState = false;
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

      bool canBuyFilter  = CheckEMATrend(true)  && CheckMTFFilter(true);
      bool canSellFilter = CheckEMATrend(false) && CheckMTFFilter(false);

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

   // UseAdaptiveATRGrid: แต่ละฝั่งใช้ระยะของตัวเอง (คำนวณสดจาก ATR ตอนฝั่งนั้น fill ล่าสุด)
   // แทนที่จะใช้ stepDistance ตัวเดียวร่วมกันทั้งสองฝั่ง - ฝั่งที่ยังไม่ fill จะไม่ถูกกระทบเลย
   int buyStepDistance  = UseAdaptiveATRGrid ? ((BuyGridDistance  > 0) ? BuyGridDistance  : GetDynamicGridDistance()) : stepDistance;
   int sellStepDistance = UseAdaptiveATRGrid ? ((SellGridDistance > 0) ? SellGridDistance : GetDynamicGridDistance()) : stepDistance;

   MqlTradeRequest request;
   MqlTradeResult  result;
   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();

   int adjGapLimit = MaxAllowedGapPoints * m_multiplier;
   int adjSpread   = MaxSpreadAllowed * m_multiplier;

   bool canBuyFilters  = CheckEMATrend(true)  && CheckMTFFilter(true);
   bool canSellFilters = CheckEMATrend(false) && CheckMTFFilter(false);

   // Level Unlock: once EITHER side has filled every configured TotalLevels
   // (that side has no more room, and the basket still isn't profitable),
   // optionally allow opening further levels past the cap on that side. This
   // does NOT need its own profit check - ExecuteGridLogic() is already gated
   // by (MaxBasketProfit < TargetProfit) in OnTick(), so grid execution (and
   // this unlock) automatically stops the moment the basket reaches
   // TargetProfit.
   bool eitherSideMaxed = (buyCount >= TotalLevels || sellCount >= TotalLevels);
   bool buyLevelAvailable  = (buyCount  < TotalLevels) ||
      (UseLevelUnlock && eitherSideMaxed && (MaxUnlockedLevels <= 0 || buyCount  < TotalLevels + MaxUnlockedLevels));
   bool sellLevelAvailable = (sellCount < TotalLevels) ||
      (UseLevelUnlock && eitherSideMaxed && (MaxUnlockedLevels <= 0 || sellCount < TotalLevels + MaxUnlockedLevels));

   if(buyLevelAvailable  && !canBuyFilters)  LogFilterBlockReason(true);
   if(sellLevelAvailable && !canSellFilters) LogFilterBlockReason(false);

   // CHECK BUY GRID
   if(buyLevelAvailable && canBuyFilters)
   {
      // lastBuyPrice is a LOCAL variable recomputed every call from real filled
      // positions - re-anchoring it in the gap branch below does NOT persist to
      // the next tick. BuyGapAnchor is the persistent override that actually
      // survives across ticks for the buyCount>0 case.
      double effectiveLastBuy = MathMax(lastBuyPrice, BuyGapAnchor);

      double targetPrice = 0.0;
      if(buyCount == 0)
         targetPrice = NormalizeDouble(GridBasePriceBuy + (buyStepDistance * point), _Digits);
      else
         targetPrice = NormalizeDouble(effectiveLastBuy + (buyStepDistance * point), _Digits);

      double diffPoints = (ask - targetPrice) / point;

      // เป็น Gap "จริง" ก็ต่อเมื่อระยะเกิน adjGapLimit *และ* ไม่มีทิคเข้ามาเลยนานเกิน
      // GapDetectionSeconds (เช่น ข้ามคืน/สุดสัปดาห์) - ถ้าทิคยังเข้ามาต่อเนื่อง (แค่ตลาดวิ่งแรง)
      // จะไม่ถือเป็น Gap เลย แล้วเปิดไม้ต่อได้ตามปกติแม้ระยะจะไกลเกิน adjGapLimit ก็ตาม เพราะไม่งั้น
      // เทรนด์แรงต่อเนื่องจะโดน re-anchor วนไปเรื่อยๆ ทุกทิคโดยไม่มีวันเปิดไม้ต่อได้เลย
      bool isGenuineGap = (UseGapProtection && diffPoints > adjGapLimit && SecondsSinceLastTick >= GapDetectionSeconds);

      bool canSendBuy = (ask >= targetPrice) && !isGenuineGap;

      if(canSendBuy)
      {
         long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
         if(currentSpread <= adjSpread)
         {
            int nextLevel = buyCount + 1;
            double lot = GetCalculatedLotSize(nextLevel);

            ZeroMemory(request); ZeroMemory(result);
            request.action       = TRADE_ACTION_DEAL;
            request.symbol       = _Symbol;
            request.volume       = lot;
            request.type         = ORDER_TYPE_BUY;
            request.price        = ask;
            request.sl           = CalcEmergencySL(true, ask, point);
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
               // ฝั่ง Buy fill แล้ว - คำนวณระยะ Buy รอบถัดไปใหม่จาก ATR สด ณ ตอนนี้
               // ฝั่ง Sell ที่ยังไม่ fill ไม่ถูกแตะเลย ยังรอที่เป้าเดิมต่อไป
               if(UseAdaptiveATRGrid) BuyGridDistance = GetDynamicGridDistance();
               return;
            }
         }
         else if(TimeCurrent() - lastSpreadLogTime >= 5)
         {
            // ไม่ใช่ filter เลยสักตัว แต่ spread กว้างเกิน MaxSpreadAllowed ตอนราคาวิ่งแรง/ข่าวแรง
            // จะบล็อคเงียบๆ เหมือนโดน filter บล็อคทุกประการ ถ้าไม่มี log บรรทัดนี้จะดูเหมือนบั๊กลึกลับ
            lastSpreadLogTime = TimeCurrent();
            PrintFormat("📊 [BUY SPREAD BLOCKED] Current spread %d pts > MaxSpreadAllowed %d pts - order eligible but skipped.",
                        currentSpread, adjSpread);
         }
      }
      else if(isGenuineGap)
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
   if(sellLevelAvailable && canSellFilters)
   {
      // Same persistence issue as the Buy side, mirrored: lastSellPrice is local
      // and rebuilt from real positions every call, so SellGapAnchor is the
      // persistent override for the sellCount>0 case. Sell targets move DOWN, so
      // we want the lower of the two (0.0 means "unset").
      double effectiveLastSell = (SellGapAnchor > 0 && SellGapAnchor < lastSellPrice) ? SellGapAnchor : lastSellPrice;

      double targetPrice = 0.0;
      if(sellCount == 0)
         targetPrice = NormalizeDouble(GridBasePriceSell - (sellStepDistance * point), _Digits);
      else
         targetPrice = NormalizeDouble(effectiveLastSell - (sellStepDistance * point), _Digits);

      double diffPoints = (targetPrice - bid) / point;

      // เป็น Gap "จริง" ก็ต่อเมื่อระยะเกิน adjGapLimit *และ* ไม่มีทิคเข้ามาเลยนานเกิน
      // GapDetectionSeconds - เหตุผลเดียวกับฝั่ง Buy ด้านบน
      bool isGenuineGap = (UseGapProtection && diffPoints > adjGapLimit && SecondsSinceLastTick >= GapDetectionSeconds);

      bool canSendSell = (bid <= targetPrice) && !isGenuineGap;

      if(canSendSell)
      {
         long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
         if(currentSpread <= adjSpread)
         {
            int nextLevel = sellCount + 1;
            double lot = GetCalculatedLotSize(nextLevel);

            ZeroMemory(request); ZeroMemory(result);
            request.action       = TRADE_ACTION_DEAL;
            request.symbol       = _Symbol;
            request.volume       = lot;
            request.type         = ORDER_TYPE_SELL;
            request.price        = bid;
            request.sl           = CalcEmergencySL(false, bid, point);
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
               // ฝั่ง Sell fill แล้ว - คำนวณระยะ Sell รอบถัดไปใหม่จาก ATR สด ณ ตอนนี้
               // ฝั่ง Buy ที่ยังไม่ fill ไม่ถูกแตะเลย ยังรอที่เป้าเดิมต่อไป
               if(UseAdaptiveATRGrid) SellGridDistance = GetDynamicGridDistance();
               return;
            }
         }
         else if(TimeCurrent() - lastSpreadLogTime >= 5)
         {
            lastSpreadLogTime = TimeCurrent();
            PrintFormat("📊 [SELL SPREAD BLOCKED] Current spread %d pts > MaxSpreadAllowed %d pts - order eligible but skipped.",
                        currentSpread, adjSpread);
         }
      }
      else if(isGenuineGap)
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

   // สแนปช็อตกำไร/ขาดทุนของบาสเก็ตไว้ก่อนปิดจริง (ต้องอ่านตอนโพซิชั่นยังเปิดอยู่)
   // เพื่อเอาไปนับสถิติ Win/Loss - อ่านทีหลังหลังปิดแล้วจะดึงค่าไม่ได้
   double statsSnapshotProfit = 0.0;
   int    statsPosCount       = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      statsSnapshotProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      statsPosCount++;
   }

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

   // บันทึกสถิติจาก snapshot ที่เก็บไว้ตอนต้นฟังก์ชัน - นับเป็น "บาสเก็ตที่ปิดแล้ว" เฉพาะตอนที่มีไม้จริงๆ ให้ปิด
   // (กันนับซ้ำตอนกดปุ่ม Close All ทั้งที่พอร์ตว่างอยู่แล้ว)
   if(statsPosCount > 0)
   {
      StatsTotalBaskets++;
      if(statsSnapshotProfit > 0)
      {
         StatsWinCount++;
         StatsSumWinProfit += statsSnapshotProfit;
      }
      else
      {
         StatsLossCount++;
         StatsSumLossAmount += MathAbs(statsSnapshotProfit);
      }
   }

   GridCreated           = false;
   MaxBasketProfit       = 0.0;
   GridBasePrice         = 0.0;
   GridBasePriceBuy      = 0.0;
   GridBasePriceSell     = 0.0;
   BuyGapAnchor          = 0.0;
   SellGapAnchor         = 0.0;
   CachedGridDistance    = 0;
   BuyGridDistance       = 0;
   SellGridDistance      = 0;
   LastOrderSentTime     = 0;
   PartialCloseExecuted  = false;
   BreakevenActivated    = false;
   ForceHedgeArmed       = false;
   BasketNegativeSinceTime = 0;
   LastForceHedgeTimeFire  = 0;
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
   int W = 800;
   int H = 510;

   // Outer shadow + main card, thin accent border for a bit of depth
   CreatePanel(UI_PREFIX+"Shadow", X+5, Y+5, W, H, UI_Shadow, UI_Shadow);
   CreatePanel(UI_PREFIX+"MainBG", X, Y, W, H, UI_MainBG, UI_Accent);

   // 1. HEADER (with a thin accent underline to separate it from the body)
   CreatePanel(UI_PREFIX+"HeaderBG", X, Y, W, 44, UI_PanelBG, UI_PanelBG);
   CreatePanel(UI_PREFIX+"HeaderLine", X, Y+44, W, 2, UI_Accent, UI_Accent);
   CreateLabel(UI_PREFIX+"Title", X+16, Y+13, "⚡ QUANTIX PRO TERMINAL", 12, clrWhite, "Impact");
   CreateLabel(UI_PREFIX+"SubTitle", X+250, Y+16, GetUIString("แดชบอร์ดวิเคราะห์แบบเรียลไทม์", "REAL-TIME ANALYTICS"), 8, UI_TextDim);

   // 2. STATUS LED + TIME
   CreateLabel(UI_PREFIX+"LED_Icon", X+16, Y+58, "n", 8, UI_Profit, "Wingdings");
   CreateLabel(UI_PREFIX+"LED_Text", X+30, Y+56, GetUIString("ระบบพร้อมทำงาน", "ONLINE"), 9, UI_Profit);

   string timeStr = StringFormat("%02d:%02d - %02d:%02d (%s)", StartHour, StartMinute, EndHour, EndMinute,
                                  UseLocalTime ? GetUIString("เครื่อง", "Local") : GetUIString("Server", "Server"));
   if(!UseTimer) timeStr = "24/7 ALL DAY";
   CreateLabel(UI_PREFIX+"Time_Lbl", X+225, Y+56, "🕐 " + timeStr, 8, UI_TextDim);

   // 3. PROGRESS BAR (rounded-look end caps + 3-tier fill color, driven in UpdateDashboard)
   CreateLabel(UI_PREFIX+"Prog_Lbl", X+16, Y+86, "🎯 " + GetUIString("เป้าหมายกำไร", "TARGET PROGRESS"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Prog_Pct", X+335, Y+86, "0%", 8, clrWhite, "Impact");
   CreatePanel(UI_PREFIX+"Prog_BG", X+16, Y+106, 360, 8, UI_Shadow, UI_Shadow);
   CreatePanel(UI_PREFIX+"Prog_Fill", X+16, Y+106, 0, 8, UI_Accent, UI_Accent);
   CreatePanel(UI_PREFIX+"Prog_CapL", X+16, Y+106, 2, 8, UI_Accent, UI_Accent);
   CreatePanel(UI_PREFIX+"Prog_CapR", X+16, Y+106, 2, 8, UI_Accent, UI_Accent);

   // 4. FLOATING PROFIT (hero number)
   CreateLabel(UI_PREFIX+"NetLbl", X+16, Y+128, GetUIString("กำไรรวมปัจจุบัน (Floating)", "BASKET FLOATING PROFIT"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Profit", X+16, Y+148, "$0.00", 22, clrWhite, "Impact");

   // ==================== LEFT COLUMN: TRADING DATA MATRIX ==================== //
   int startY = Y + 198;
   int boxW = 174, boxH = 60, boxGap = 12;

   // Box 1: PEAK PROFIT (green accent)
   CreatePanel(UI_PREFIX+"Box1Accent", X+16, startY, boxW, 3, UI_Profit, UI_Profit);
   CreatePanel(UI_PREFIX+"Box1", X+16, startY+3, boxW, boxH-3, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Box1L", X+24, startY+11, "📈 " + GetUIString("กำไรสูงสุด ($)", "PEAK PROFIT ($)"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Peak", X+24, startY+31, "0.00", 12, UI_Profit, "Impact");

   // Box 2: TRAILING SL (orange accent)
   int box2X = X+16+boxW+boxGap;
   CreatePanel(UI_PREFIX+"Box2Accent", box2X, startY, boxW, 3, clrOrange, clrOrange);
   CreatePanel(UI_PREFIX+"Box2", box2X, startY+3, boxW, boxH-3, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Box2L", box2X+8, startY+11, "🔒 " + GetUIString("จุดล็อกกำไร ($)", "TRAILING SL ($)"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_TS", box2X+8, startY+31, GetUIString("สแตนด์บาย", "HOLD"), 11, clrOrange, "Impact");

   int row2Y = startY + boxH + boxGap;

   // Box 3: ACTIVE POSITIONS (accent blue)
   CreatePanel(UI_PREFIX+"Box3Accent", X+16, row2Y, boxW, 3, UI_Accent, UI_Accent);
   CreatePanel(UI_PREFIX+"Box3", X+16, row2Y+3, boxW, boxH-3, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Box3L", X+24, row2Y+11, "📊 " + GetUIString("ไม้ที่เปิดอยู่", "ACTIVE POSITIONS"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Open", X+24, row2Y+31, "0 / 20", 12, clrWhite, "Impact");

   // Box 4: MODE / PENDING (accent blue)
   CreatePanel(UI_PREFIX+"Box4Accent", box2X, row2Y, boxW, 3, UI_Accent, UI_Accent);
   CreatePanel(UI_PREFIX+"Box4", box2X, row2Y+3, boxW, boxH-3, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"Box4L", box2X+8, row2Y+11, "⚙️ " + GetUIString("โหมดคำสั่ง", "ORDER MODE"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Pend", box2X+8, row2Y+31, "---", 11, UI_Accent, "Impact");

   int virtY = row2Y + boxH + boxGap;

   // Box 5: VIRTUAL TARGET MONITOR
   CreatePanel(UI_PREFIX+"BoxVirtAccent", X+16, virtY, 358, 3, UI_Accent, UI_Accent);
   CreatePanel(UI_PREFIX+"BoxVirt", X+16, virtY+3, 358, 76, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"VirtTitle", X+24, virtY+11, "📡 " + GetUIString("สถานะ VIRTUAL GRID", "VIRTUAL GRID TARGETS"), 7, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_VirtBuy", X+24, virtY+30, "Wait BUY : ---", 8, UI_Profit);
   CreateLabel(UI_PREFIX+"Val_VirtSell", X+24, virtY+50, "Wait SELL: ---", 8, UI_Loss);

   // EMERGENCY CLOSE ALL BUTTON
   string btnText = GetUIString("🚨 ปิดรวบทุกไม้ (CLOSE ALL)", "🚨 CLOSE ALL POSITIONS");
   CreateButton(BTN_CLOSE_ALL, X+16, virtY+3+76+14, 358, 40, btnText, UI_Loss, clrWhite, 10);

   // ==================== VERTICAL DIVIDER ==================== //
   CreatePanel(UI_PREFIX+"VDivider", X+392, Y+56, 1, H-70, UI_Shadow, UI_Shadow);

   // ==================== RIGHT COLUMN: FINANCIAL INFO ==================== //
   int X_Right  = X + 408;
   int PanelW   = W - (X_Right - X) - 16;

   int ValX_Acc = X_Right + 185;

   // 1. ACCOUNT OVERVIEW PANEL
   CreatePanel(UI_PREFIX+"AccAccent", X_Right, Y+56, PanelW, 3, UI_Accent, UI_Accent);
   CreatePanel(UI_PREFIX+"AccBG", X_Right, Y+59, PanelW, 205, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"AccTitle", X_Right+12, Y+68, "💰 " + GetUIString("ข้อมูลบัญชีเทรด", "ACCOUNT INFO"), 9, UI_Accent, "Impact");
   CreatePanel(UI_PREFIX+"AccTitleLine", X_Right+12, Y+88, PanelW-24, 1, UI_Shadow, UI_Shadow);

   int accY = Y + 100;
   int accGap = 24;

   CreateLabel(UI_PREFIX+"Lbl_Bal", X_Right+12, accY, GetUIString("ยอดเงิน (Balance):", "Balance:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Bal", ValX_Acc, accY, "$0.00", 9, clrWhite);

   accY += accGap;
   CreateLabel(UI_PREFIX+"Lbl_Eq", X_Right+12, accY, GetUIString("มูลค่าสุทธิ (Equity):", "Equity:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Eq", ValX_Acc, accY, "$0.00", 9, clrWhite);

   accY += accGap;
   CreateLabel(UI_PREFIX+"Lbl_FreeM", X_Right+12, accY, GetUIString("หลักประกันเหลือ (Margin):", "Free Margin:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_FreeM", ValX_Acc, accY, "$0.00", 9, clrWhite);

   accY += accGap;
   CreateLabel(UI_PREFIX+"Lbl_MLevel", X_Right+12, accY, GetUIString("ระดับหลักประกัน (Level):", "Margin Level:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_MLevel", ValX_Acc, accY, "0.00%", 9, clrWhite);

   accY += accGap;
   CreateLabel(UI_PREFIX+"Lbl_MaxDD", X_Right+12, accY, GetUIString("ย่อตัวสูงสุด (Max DD):", "Max Drawdown:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_MaxDD", ValX_Acc, accY, "-$0.00 (-0.00%)", 9, UI_Loss);

   // 2. SYSTEM STATUS PANEL (Force Hedge / Level Unlock / Basket Stats)
   int SysY = Y + 278;
   CreatePanel(UI_PREFIX+"SysAccent", X_Right, SysY, PanelW, 3, UI_Accent, UI_Accent);
   CreatePanel(UI_PREFIX+"SysBG", X_Right, SysY+3, PanelW, 197, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"SysTitle", X_Right+12, SysY+12, "⚙️ " + GetUIString("สถานะระบบเสริม", "SYSTEM STATUS"), 9, UI_Accent, "Impact");
   CreatePanel(UI_PREFIX+"SysTitleLine", X_Right+12, SysY+32, PanelW-24, 1, UI_Shadow, UI_Shadow);

   int sysY = SysY + 44;
   CreateLabel(UI_PREFIX+"Lbl_ForceHedge", X_Right+12, sysY, GetUIString("Force Hedge:", "Force Hedge:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_ForceHedge", ValX_Acc, sysY, "OFF", 8, UI_TextDim);

   sysY += accGap;
   CreateLabel(UI_PREFIX+"Lbl_LevelUnlock", X_Right+12, sysY, GetUIString("Level Unlock:", "Level Unlock:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_LevelUnlock", ValX_Acc, sysY, "OFF", 8, UI_TextDim);

   sysY += accGap;
   CreateLabel(UI_PREFIX+"Lbl_Baskets", X_Right+12, sysY, GetUIString("บาสเก็ตที่ปิดแล้ว:", "Baskets Closed:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_Baskets", ValX_Acc, sysY, "0", 8, clrWhite);

   sysY += accGap;
   CreateLabel(UI_PREFIX+"Lbl_WinRate", X_Right+12, sysY, GetUIString("อัตราชนะ (Win Rate):", "Win Rate:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_WinRate", ValX_Acc, sysY, "0.0% (0W/0L)", 8, clrWhite);

   sysY += accGap;
   CreateLabel(UI_PREFIX+"Lbl_AvgWL", X_Right+12, sysY, GetUIString("เฉลี่ยกำไร/ขาดทุน:", "Avg Win/Loss:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_AvgWL", ValX_Acc, sysY, "+$0.00 / -$0.00", 8, clrWhite);

   sysY += accGap;
   CreateLabel(UI_PREFIX+"Lbl_NegTime", X_Right+12, sysY, GetUIString("ติดลบนาน (Force Hedge Time):", "Negative Duration:"), 8, UI_TextDim);
   CreateLabel(UI_PREFIX+"Val_NegTime", ValX_Acc, sysY, "OFF", 8, UI_TextDim);

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

   int barLeftX = 15 + 16; // matches Prog_BG's X+16 anchor in InitDashboard (X is fixed at 15 there)
   int barWidth = (int)(360 * percent);
   ObjectSetInteger(0, UI_PREFIX+"Prog_Fill", OBJPROP_XSIZE, barWidth);

   color progColor = UI_Accent;
   if(percent >= 1.0) progColor = clrOrange;
   else if(percent >= 0.7) progColor = UI_Profit;

   ObjectSetInteger(0, UI_PREFIX+"Prog_Fill", OBJPROP_BGCOLOR, progColor);
   ObjectSetInteger(0, UI_PREFIX+"Prog_CapL", OBJPROP_BGCOLOR, progColor);
   ObjectSetInteger(0, UI_PREFIX+"Prog_CapR", OBJPROP_BGCOLOR, progColor);
   ObjectSetInteger(0, UI_PREFIX+"Prog_CapR", OBJPROP_XDISTANCE, barLeftX + barWidth - 2);

   ObjectSetString(0, UI_PREFIX+"Prog_Pct", OBJPROP_TEXT, IntegerToString((int)(percent * 100)) + "%");

   bool timeAllowed = IsTradingAllowedByTime();

   color ledColor = UI_Profit;
   if(TradingHalted) {
      ledColor = UI_Loss;
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("หยุดถาวร (TOTAL DD GUARD)", "HALTED (TOTAL DD GUARD)"));
   } else if(IsClosingState) {
      ledColor = clrOrange;
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("กำลังเคลียร์ไม้ค้าง", "CLOSING ALL..."));
   } else if(!timeAllowed) {
      ledColor = clrRed;
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("นอกเวลาเทรด", "OFF-TIME"));
   } else if(openPos > 0 || pendingOrders > 0) {
      ledColor = UI_Profit;
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("กำลังทำงาน", "ACTIVE"));
   } else {
      ledColor = C'255,193,7';
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("ระบบพร้อมทำงาน", "ONLINE"));
   }

   ObjectSetInteger(0, UI_PREFIX+"LED_Icon", OBJPROP_COLOR, ledColor);
   ObjectSetInteger(0, UI_PREFIX+"LED_Text", OBJPROP_COLOR, ledColor);

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

   // 3. SYSTEM STATUS PANEL UPDATES
   if(!UseForceHedgeOnDD)
   {
      ObjectSetString(0, UI_PREFIX+"Val_ForceHedge", OBJPROP_TEXT, GetUIString("ปิดใช้งาน", "OFF"));
      ObjectSetInteger(0, UI_PREFIX+"Val_ForceHedge", OBJPROP_COLOR, UI_TextDim);
   }
   else if(ForceHedgeArmed)
   {
      ObjectSetString(0, UI_PREFIX+"Val_ForceHedge", OBJPROP_TEXT, GetUIString("ยิงแล้ว (รอ DD ลด)", "FIRED (waiting DD drop)"));
      ObjectSetInteger(0, UI_PREFIX+"Val_ForceHedge", OBJPROP_COLOR, UI_Loss);
   }
   else
   {
      ObjectSetString(0, UI_PREFIX+"Val_ForceHedge", OBJPROP_TEXT, GetUIString("พร้อมทำงาน", "READY"));
      ObjectSetInteger(0, UI_PREFIX+"Val_ForceHedge", OBJPROP_COLOR, UI_Profit);
   }

   if(!UseLevelUnlock)
   {
      ObjectSetString(0, UI_PREFIX+"Val_LevelUnlock", OBJPROP_TEXT, GetUIString("ปิดใช้งาน", "OFF"));
      ObjectSetInteger(0, UI_PREFIX+"Val_LevelUnlock", OBJPROP_COLOR, UI_TextDim);
   }
   else
   {
      int buyCntUI = 0, sellCntUI = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buyCntUI++;
         else sellCntUI++;
      }
      int extraBuy  = (int)MathMax(0, buyCntUI  - TotalLevels);
      int extraSell = (int)MathMax(0, sellCntUI - TotalLevels);
      string capTxt = (MaxUnlockedLevels <= 0) ? "∞" : IntegerToString(MaxUnlockedLevels);
      ObjectSetString(0, UI_PREFIX+"Val_LevelUnlock", OBJPROP_TEXT, StringFormat("B+%d S+%d / %s", extraBuy, extraSell, capTxt));
      ObjectSetInteger(0, UI_PREFIX+"Val_LevelUnlock", OBJPROP_COLOR, (extraBuy > 0 || extraSell > 0) ? UI_Loss : UI_Profit);
   }

   ObjectSetString(0, UI_PREFIX+"Val_Baskets", OBJPROP_TEXT, IntegerToString(StatsTotalBaskets));

   double winRate = (StatsTotalBaskets > 0) ? (StatsWinCount * 100.0 / StatsTotalBaskets) : 0.0;
   ObjectSetString(0, UI_PREFIX+"Val_WinRate", OBJPROP_TEXT,
                   StringFormat("%.1f%% (%dW/%dL)", winRate, StatsWinCount, StatsLossCount));

   double avgWin  = (StatsWinCount  > 0) ? (StatsSumWinProfit  / StatsWinCount)  : 0.0;
   double avgLoss = (StatsLossCount > 0) ? (StatsSumLossAmount / StatsLossCount) : 0.0;
   ObjectSetString(0, UI_PREFIX+"Val_AvgWL", OBJPROP_TEXT, StringFormat("+$%.2f / -$%.2f", avgWin, avgLoss));

   if(!UseForceHedgeOnTime)
   {
      ObjectSetString(0, UI_PREFIX+"Val_NegTime", OBJPROP_TEXT, GetUIString("ปิดใช้งาน", "OFF"));
      ObjectSetInteger(0, UI_PREFIX+"Val_NegTime", OBJPROP_COLOR, UI_TextDim);
   }
   else if(BasketNegativeSinceTime == 0)
   {
      ObjectSetString(0, UI_PREFIX+"Val_NegTime", OBJPROP_TEXT, GetUIString("ยังไม่ติดลบ", "Not negative"));
      ObjectSetInteger(0, UI_PREFIX+"Val_NegTime", OBJPROP_COLOR, UI_Profit);
   }
   else
   {
      int minsNegative  = (int)((TimeCurrent() - BasketNegativeSinceTime) / 60);
      datetime sinceRef = (LastForceHedgeTimeFire > 0) ? LastForceHedgeTimeFire : BasketNegativeSinceTime;
      int minsToNext    = ForceHedgeTimeMinutes - (int)((TimeCurrent() - sinceRef) / 60);
      if(minsToNext < 0) minsToNext = 0;

      ObjectSetString(0, UI_PREFIX+"Val_NegTime", OBJPROP_TEXT,
                       StringFormat(GetUIString("ติดลบ %d min | ยิงถัดไปใน %d min", "%d min neg | next in %d min"), minsNegative, minsToNext));
      ObjectSetInteger(0, UI_PREFIX+"Val_NegTime", OBJPROP_COLOR, (LastForceHedgeTimeFire > 0) ? UI_Loss : C'255,193,7');
   }
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
