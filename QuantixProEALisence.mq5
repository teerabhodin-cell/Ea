//+------------------------------------------------------------------+
//|                                                   QuantixProEA.mq5|
//|        Dual Mode Grid (Pending / Virtual) + Basket Trailing Stop |
//|        Extended Horizontal Dashboard with Account Panel          |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>
#include <Canvas\Canvas.mqh>

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

enum ENUM_LOT_TYPE
{
   LOT_FIXED,        // Fixed Lot (ล็อตคงที่)
   LOT_RISK_PERCENT  // % of Risk (คำนวณตาม % ความเสี่ยง)
};

//=========================== HARD LICENSE LOCK ================================//
// รายชื่อเลขบัญชี MT5 ที่อนุญาตให้รัน EA นี้ได้ (ทั้งเดโมและบัญชีจริง) - ไฟล์นี้คนละตัวกับ
// QuantixProEA.mq5 (รันบนชาร์ตจริงได้ปกติ ไม่มีล็อคบัญชี) **ห้ามทำเป็น input เด็ดขาด**
// เพราะถ้าเป็น input ผู้ใช้จะเปิดหน้า Inputs แล้วแก้ค่าเองได้ทันที ทำให้ล็อคไม่มีความหมายอะไรเลย -
// ต้องเป็นค่าคงที่ใน source code เท่านั้นถึงจะบังคับได้จริง
const long LicensedAccountNumbers[] = {257431196, 41004623, 2121992812, 416094438};

bool IsLicensed = false; // เซ็ตค่าจริงใน OnInit() - เทียบ ACCOUNT_LOGIN ปัจจุบันกับลิสต์ด้านบน

//=========================== INPUT ================================//
input group "===== 1. Time & Language ====="
input ENUM_LANGUAGE Language = LNG_TH; // Select Language ( default: Thai )
input bool    UseTimer         = true;    // Time Filter (คุมเวลา)
input bool    UseLocalTime     = false;   // Use Local PC Time (อิงตามเครื่อง, ไม่ใช่ Server)
input int     StartHour        = 2;       // Start Hour (ชม.เริ่ม)
input int     StartMinute      = 0;
input int     EndHour          = 22;      // Stop Hour (ชม.หยุด)
input int     EndMinute        = 0;

input group "===== 2. Lot ====="
input ENUM_LOT_TYPE LotType         = LOT_FIXED; // Lot Type (ประเภท Lot)
input double BaseLot                = 0.05;      // ใช้เมื่อ LotType = Fixed Lot
input double LotMultiplier          = 1.5;
input double LotRiskPercent         = 1.0;     // Risk % of Equity (ใช้เมื่อ LotType = % of Risk, ต่อระยะ Grid ปัจจุบัน 1 ช่วง)
input bool   UseDynamicLot          = false;   // Dynamic Lot by Equity (Lot ตาม Equity, ใช้เมื่อ LotType = Fixed Lot เท่านั้น)
input double BalancePerLot          = 8000.0;  // Equity per 0.01 Lot
input bool   UseEquityLock          = false;   // Equity Lock (ล็อคพอร์ต)
input double MinEquityLimit         = 4000.0;  // Min Equity Limit
input bool   UseAutoReduceLot       = false;   // Auto Reduce Lot on DD (ลด Lot อัตโนมัติ)
input double ReduceLotThresholdDD   = 20.0;    // Reduce Lot DD Trigger %

input group "===== 3. Grid ====="
input ENUM_GRID_TYPE GridType       = GRID_VIRTUAL; // Grid Type (รูปแบบ Grid)
input int    TotalLevels            = 10;      // Levels per Side (จำนวนชั้น/ฝั่ง)
input bool   UseATRDistance         = true;    // Use ATR Distance (ระยะตาม ATR)
input int    ATR_Period             = 14;      // ATR Period
input double ATR_Multiplier         = 1.05;    // ATR Multiplier
input bool   UseAdaptiveATRGrid     = false;   // Per-Side ATR Distance (แยกระยะต่อฝั่ง)
input bool   UseBBDistance          = false;   // Use Bollinger Bands Distance (ระยะตาม BB, สำคัญกว่า ATR ถ้าเปิดพร้อมกัน)
input int    BB_Period              = 20;      // BB Period
input double BB_Deviation           = 2.0;     // BB Deviation
input double BB_Multiplier          = 1.0;     // BB Width Multiplier
input bool   UseAdaptiveBBGrid      = false;   // Per-Side BB Distance (แยกระยะต่อฝั่งตาม BB)
input int    DistancePoints         = 250;     // Fixed Distance, pts (ระยะคงที่)
input ulong  MagicNumber            = 112233;

input group "===== 4. Target & Trailing ====="
input double TargetProfit        = 5.0;    // Target Profit $ (เป้ากำไร)
input double TrailingStopUSD     = 0.2;    // Trailing Distance $ (ระยะเทรล)
input double DailyProfitGoal     = 100.0;  // Daily Profit Goal $ (เป้ากำไรรายวัน, ใช้แสดงในเกจ Dashboard)

input group "===== 5. Trend Filters ====="
input bool   UseEMAFilter           = false;   // Use EMA Filter (ใช้ EMA)
input int    EMA_Period             = 200;     // EMA Period
input bool   StrictBuyFilter        = false;   // Block Buy < EMA (ล็อค Buy)
input bool   StrictSellFilter       = false;   // Block Sell > EMA (ล็อค Sell)
input bool   UseMTFFilter          = false;   // Use MTF Filter (ใช้ MTF)
input ENUM_TIMEFRAMES MTF_Period   = PERIOD_H1; // MTF Timeframe

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

input group "===== 10. Dashboard ====="
input double UIScaleMultiplier   = 1.3;    // Dashboard Size Multiplier (ตัวคูณขนาดแดชบอร์ด)
input bool   ShowDashboardInBacktest = false; // Show Dashboard in Backtest (โชว์ UI ตอน backtest, ช้าลง - เปิดไว้ดูใน Visual Mode เท่านั้น)

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
string   CANVAS_NAME     = "QX_PRO_Canvas";

// --- Canvas Dashboard (pixel-drawn: gauge, equity curve chart, icon grid) ---
// DASH_W/DASH_H hold the CURRENT actual canvas resolution (recomputed from
// UIScale each time InitDashboard() runs - see ComputeUIScale()/S()/SF() near
// the dashboard drawing code further down) so the panel scales to fit the
// chart window instead of overflowing below it.
CCanvas  DashCanvas;
int      DASH_W = 1450;
int      DASH_H = 1095;

#define EQUITY_HISTORY_MAX 120
double   EquityHistoryBuf[EQUITY_HISTORY_MAX];
int      EquityHistoryCount    = 0;
datetime LastEquitySampleTime  = 0;

#define EVENT_LOG_MAX 5
string   EventLogText[EVENT_LOG_MAX];
datetime EventLogTimeVal[EVENT_LOG_MAX];

int      DayStartDay          = -1; // dt.day_of_year ของวันที่รีเซ็ต DailyRealizedProfit ไว้ล่าสุด
double   DailyRealizedProfit  = 0.0; // กำไรวันนี้แบบ "ปิดรอบแล้ว" เท่านั้น - บวกเพิ่มตอนบาสเก็ตปิดจริง ไม่ใช่ floating P/L สด

// Handle สำหรับอินดิเคเตอร์ ATR / EMA / Multi-Timeframe EMA / Bollinger Bands
int      atrHandle       = INVALID_HANDLE;
int      emaHandle       = INVALID_HANDLE;
int      mtfEmaHandle    = INVALID_HANDLE;
int      bbHandle        = INVALID_HANDLE;

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
bool IsPerSideDistanceActive();
void RecalculateBasePrice();
void ReconcileGridStateOnInit();
ENUM_ORDER_TYPE_FILLING GetBestFillingMode();

// State persistence (Global Variables ของเทอร์มินัล - อยู่ข้าม EA restart/ปิดเปิดเทอร์มินัล)
string PersistKey(string key);
void   PersistSet(string key, double value);
double PersistGet(string key, double defaultValue);
void   PersistAllStats();

// UI Engine Functions
void InitDashboard();
void DeleteDashboard();
void ShowUnlicensedWarning();
void UpdateDashboard(double currentProfit, double maxProfit, double currentTS, int openPos, int pendingOrders);
void CreateButton(string name, int x, int y, int w, int h, string text, color bgClr, color textClr, int fontSize = 9);
string GetUIString(string thText, string enText);
string GetUIFont();
void LogEvent(string text); // News & Alerts feed on the Canvas dashboard
int S(double v);   // Responsive scaling helpers (defined near InitDashboard, forward-declared for use in Draw* functions above)
int SF(double v);
double ComputeUIScale();

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
   // ราคาไม้ "level 1" ของแต่ละฝั่ง (สุดขั้วตรงข้ามกับ lastBuyPrice/lastSellPrice ด้านบน ซึ่งคือ
   // ไม้ล่าสุด/ชั้นสูงสุด) ใช้ย้อนกลับไปหาว่าฐานเดิม (GridBasePrice) ตอนบาสเก็ตนี้เริ่มคือราคาไหน
   double firstBuyPrice = 0.0, firstSellPrice = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         buyCount++;
         if(openPrice > lastBuyPrice  || lastBuyPrice  == 0.0) lastBuyPrice  = openPrice;
         if(openPrice < firstBuyPrice || firstBuyPrice == 0.0) firstBuyPrice = openPrice;
      }
      else
      {
         sellCount++;
         if(openPrice < lastSellPrice  || lastSellPrice  == 0.0) lastSellPrice  = openPrice;
         if(openPrice > firstSellPrice || firstSellPrice == 0.0) firstSellPrice = openPrice;
      }
   }

   if(buyCount == 0 && sellCount == 0)
   {
      // ไม่มีไม้เก่าค้างเลย - พอร์ตว่างจริงๆ ใช้ RecalculateBasePrice() ปกติได้เลย
      RecalculateBasePrice();
      return;
   }

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    distNow  = (CachedGridDistance > 0) ? CachedGridDistance : GetDynamicGridDistance();
   double distPrice = distNow * point;

   // FIXED: เดิม GridBasePrice ถูกรีเซ็ตไปที่ราคาตลาด ณ ตอน restart ตรงๆ ทุกครั้ง ทั้งที่มีไม้
   // เปิดค้างอยู่แล้ว ทำให้ "ราคาฐาน" ที่โชว์บน dashboard (และสูตรคำนวณเป้า level 1 ของฝั่งที่ยัง
   // ว่างในโหมด Fixed/ATR ปกติ) กลายเป็นค่าที่ไม่เกี่ยวข้องกับฐานจริงตอนบาสเก็ตเริ่มเลย - หลังรีสตาร์ท
   // ราคาที่โชว์เป็น "ฐาน" กับราคาที่ไม้จริงเปิดไปแล้วเลยไม่ตรงกัน ("buy sell ไม่ตรงจุด" ที่รายงานมา)
   // ย้อนกลับไปประมาณฐานเดิมจากไม้ level 1 จริงแทน (level 1 = base +/- ระยะ เป๊ะ ตราบใดที่ไม่มี
   // การ pin ระหว่างทาง ซึ่งตอนนี้ปิดไปแล้วในโหมด Fixed/ATR ปกติ)
   double estimatedBase;
   if(buyCount > 0 && sellCount > 0)
      estimatedBase = NormalizeDouble(((firstBuyPrice - distPrice) + (firstSellPrice + distPrice)) / 2.0, _Digits);
   else if(buyCount > 0)
      estimatedBase = NormalizeDouble(firstBuyPrice - distPrice, _Digits);
   else
      estimatedBase = NormalizeDouble(firstSellPrice + distPrice, _Digits);

   GridBasePrice = estimatedBase;

   // ฝั่งที่มีไม้อยู่แล้ว (count>0) ไม่ได้ใช้ GridBasePriceBuy/Sell อีกต่อไปอยู่แล้ว
   // (ExecuteGridLogic ใช้ราคาไม้จริงคำนวณแทน) แต่ฝั่งที่ยังว่าง (count==0) ยังต้องพึ่งค่านี้อยู่ -
   // เหมือนกับ live pin ใน CheckAndExecuteVirtualGrid ที่แก้ไปแล้ว ผูกกับราคาไม้ล่าสุดของอีกฝั่ง
   // ได้เฉพาะ Per-Side ATR เท่านั้น โหมด Fixed/ATR ปกติต้องกลับไปที่ GridBasePrice (ฐานจริงที่เพิ่ง
   // ประมาณย้อนกลับไว้ด้านบน) ไม่งั้นฝั่งที่ยังว่างจะเปิดไม้ก่อนถึงเส้นฐานเหมือนบั๊กที่เพิ่งแก้ไปแทน
   GridBasePriceBuy  = (buyCount  > 0) ? lastBuyPrice  : ((IsPerSideDistanceActive() && sellCount > 0) ? lastSellPrice : GridBasePrice);
   GridBasePriceSell = (sellCount > 0) ? lastSellPrice : ((IsPerSideDistanceActive() && buyCount  > 0) ? lastBuyPrice  : GridBasePrice);

   BuyGapAnchor  = 0.0;
   SellGapAnchor = 0.0;
   CachedGridDistance = distNow;
   BuyGridDistance    = CachedGridDistance;
   SellGridDistance   = CachedGridDistance;
   GridCreated = true;

   PrintFormat("🔄 [RECONCILE] EA (re)started with existing positions (Buy:%d Sell:%d) - anchors reconstructed instead of reset (Base=%.5f, Buy anchor=%.5f, Sell anchor=%.5f).",
               buyCount, sellCount, GridBasePrice, GridBasePriceBuy, GridBasePriceSell);
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
   // LotType = % of Risk: คำนวณ base lot จาก "ถ้าราคาขยับผิดทาง 1 ช่วงระยะ Grid ปัจจุบัน จะเสียไม่เกิน
   // LotRiskPercent% ของ equity" - ใช้ระยะ Grid ปัจจุบันเป็นตัวอ้างอิงความเสี่ยง (ไม่ใช่ Emergency SL
   // ซึ่งตั้งใจให้กว้างมากเป็น backstop สุดท้าย ไม่เหมาะเป็นฐานคำนวณความเสี่ยงต่อไม้) - LotType นี้ตัด
   // Dynamic Lot by Equity ทิ้งไปเลย เพราะเป็นสูตรที่ผูกกับความเสี่ยงจริงมากกว่าอยู่แล้ว ไม่ต้องมีสองระบบ
   // คำนวณ base lot ซ้อนกัน
   if(LotType == LOT_RISK_PERCENT)
   {
      double currentEq       = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskAmount      = currentEq * (LotRiskPercent / 100.0);
      int    distPoints      = (CachedGridDistance > 0) ? CachedGridDistance : GetDynamicGridDistance();
      double distPrice       = distPoints * _Point;
      double tickValue       = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize        = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double valuePerLotMove = (tickSize > 0) ? (distPrice / tickSize) * tickValue : 0.0;

      base = (valuePerLotMove > 0) ? NormalizeDouble(riskAmount / valuePerLotMove, 2) : BaseLot;
      if(base < 0.01) base = 0.01;
   }
   else if(UseDynamicLot)
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
      LogEvent(GetUIString("Partial Close ทำงานแล้ว", "Partial Close executed"));
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
      LogEvent(StringFormat(GetUIString("Force Hedge ทำงาน (%s)", "Force Hedge fired (%s)"), reasonTag));
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
//| State persistence                                                 |
//| ผู้ใช้รายงานว่าปิดเปิด EA แล้วสถิติ/กำไรวันนี้/พีคยอดเงินรีเป็น 0 ทุกครั้ง เพราะตัวแปรพวกนี้ |
//| เป็นแค่ตัวแปรในหน่วยความจำของ EA เท่านั้น หายทันทีที่ EA ถูกถอด/รีสตาร์ท ใช้ Global      |
//| Variable ของเทอร์มินัล (คนละอย่างกับตัวแปร global ของ EA เอง) เก็บแทน เพราะอยู่ข้าม        |
//| EA restart ได้จริงจนกว่าจะลบเองหรือไม่ได้แตะ 4 สัปดาห์ - ข้ามตอน backtest/optimize เสมอ    |
//| เพราะแต่ละรอบทดสอบควรเริ่มนับใหม่จากศูนย์ ไม่งั้นรอบทดสอบถัดไปจะเห็นสถิติรอบก่อนติดมาด้วย |
//+------------------------------------------------------------------+
string PersistKey(string key)
{
   return "QPEA_" + IntegerToString(MagicNumber) + "_" + _Symbol + "_" + key;
}

void PersistSet(string key, double value)
{
   if(IsTestingMode) return;
   GlobalVariableSet(PersistKey(key), value);
}

double PersistGet(string key, double defaultValue)
{
   if(IsTestingMode) return defaultValue;
   if(GlobalVariableCheck(PersistKey(key)))
      return GlobalVariableGet(PersistKey(key));
   return defaultValue;
}

void PersistAllStats()
{
   PersistSet("DayStartDay",         DayStartDay);
   PersistSet("DailyRealizedProfit", DailyRealizedProfit);
   PersistSet("StatsTotalBaskets",   StatsTotalBaskets);
   PersistSet("StatsWinCount",       StatsWinCount);
   PersistSet("StatsLossCount",      StatsLossCount);
   PersistSet("StatsSumWinProfit",   StatsSumWinProfit);
   PersistSet("StatsSumLossAmount",  StatsSumLossAmount);
   PersistSet("PeakBalanceForDD",          PeakBalanceForDD);
   PersistSet("MaxDrawdownPercent",        MaxDrawdownPercent);
   PersistSet("MaxDrawdownUSD",            MaxDrawdownUSD);
   PersistSet("AccountPeakBalanceAllTime", AccountPeakBalanceAllTime);
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   IsTestingMode = (bool)MQLInfoInteger(MQL_TESTER);

   // Hard License Lock: skipped in the Strategy Tester (virtual account numbers don't
   // match any real license anyway, and backtesting isn't "using" the strategy on real
   // money) - enforced strictly on live/demo accounts otherwise. See
   // LicensedAccountNumbers near the top of the file. เช็คแค่ตอน OnInit() ก็พอ เพราะ
   // สลับบัญชีในเทอร์มินัลจะทำให้ MT5 เรียก OnInit() ใหม่เสมอ
   long currentAccount = AccountInfoInteger(ACCOUNT_LOGIN);
   IsLicensed = IsTestingMode;
   if(!IsLicensed)
   {
      for(int li = 0; li < ArraySize(LicensedAccountNumbers); li++)
      {
         if(LicensedAccountNumbers[li] == currentAccount) { IsLicensed = true; break; }
      }
   }

   if(!IsLicensed)
   {
      // %d ตัดทอนเป็น 32-bit เสมอใน MQL5 ต่อให้ argument เป็น long ก็ตาม - เลขบัญชีใหญ่ๆ (เกิน
      // INT_MAX ~2.1 พันล้าน) จะ overflow ได้ค่าผิดเพี้ยนไปคนละเลขเลย ต้องใช้ %I64d กับ long เท่านั้น
      string licMsg = StringFormat("QuantixPro EA: Account #%I64d is NOT LICENSED to run this EA. Contact the developer to register this account.", currentAccount);
      Print("🔒 [LICENSE] ", licMsg);
      Alert(licMsg);
      // Deliberately still returns INIT_SUCCEEDED below so the chart keeps the EA
      // attached and OnTick() draws a persistent Comment() warning instead of
      // silently detaching - easier to tell "not licensed" from "broken" this way.
   }

   // Hard cap: LotMultiplier ห้ามเกิน 3.0 เด็ดขาด (กันตั้งค่า/optimize สูงเกินไปจนกลายเป็น
   // martingale ที่รุนแรงเกินควบคุม) - input เป็น read-only แก้ค่าเองในโค้ดไม่ได้ (MQL5 ห้าม
   // reassign ตัวแปร input) เลยต้อง reject การ init ไปเลยแทนการ clamp เงียบๆ ให้เห็นชัดว่าค่านี้
   // ใช้ไม่ได้ ไม่ใช่แอบรันด้วยค่าอื่นลับหลัง - ระหว่าง optimize จะ fail เร็วสำหรับทุก pass ที่เกิน 3.0
   // แทนที่จะเสียเวลารันเต็มรอบด้วยค่าเดียวกันซ้ำๆ
   if(LotMultiplier > 3.0)
   {
      Alert(StringFormat("QuantixPro EA: LotMultiplier %.2f exceeds the maximum allowed (3.0). Please lower it and reload.", LotMultiplier));
      Print("❌ [INPUT LIMIT] LotMultiplier ", LotMultiplier, " > 3.0 max - EA init blocked.");
      return(INIT_FAILED);
   }

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
   // กู้สถิติ/พีคที่เคยเซฟไว้กลับมา (เดโม/ไลฟ์เท่านั้น - PersistGet คืนค่า default ตรงๆ ตอน
   // backtest) แทนที่จะรีเป็น 0/ยอดเงินปัจจุบันทุกครั้งที่ปิดเปิด EA เหมือนเดิม ถ้าไม่เคยเซฟไว้
   // เลย (รันครั้งแรกจริงๆ) PersistGet จะคืนค่า default เดิมที่เคยใช้อยู่แล้วทุกตัว
   double currentBalanceNow = AccountInfoDouble(ACCOUNT_BALANCE);
   DayStartDay          = (int)PersistGet("DayStartDay", -1);
   DailyRealizedProfit  = PersistGet("DailyRealizedProfit", 0.0);
   StatsTotalBaskets    = (int)PersistGet("StatsTotalBaskets", 0);
   StatsWinCount        = (int)PersistGet("StatsWinCount", 0);
   StatsLossCount       = (int)PersistGet("StatsLossCount", 0);
   StatsSumWinProfit    = PersistGet("StatsSumWinProfit", 0.0);
   StatsSumLossAmount   = PersistGet("StatsSumLossAmount", 0.0);
   PeakBalanceForDD   = PersistGet("PeakBalanceForDD", currentBalanceNow);
   MaxDrawdownPercent = PersistGet("MaxDrawdownPercent", 0.0);
   MaxDrawdownUSD     = PersistGet("MaxDrawdownUSD", 0.0);
   AccountPeakBalanceAllTime = PersistGet("AccountPeakBalanceAllTime", currentBalanceNow);
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

   if(UseBBDistance)
   {
      bbHandle = iBands(_Symbol, _Period, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
      if(bbHandle == INVALID_HANDLE)
      {
         Print("Failed to create Bollinger Bands indicator handle.");
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

   // ข้าม dashboard เต็มรูปแบบไปเลยตอนไม่มีไลเซนส์ - OnTick() โชว์คำเตือนแบบ Comment() แทน
   if(IsLicensed) InitDashboard();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // DeleteDashboard() ด้านล่างลบ CANVAS_NAME (ทั้งตอน dashboard ปกติ และตอน warning
   // "NOT LICENSED") อยู่แล้ว เพราะทั้งคู่ขึ้นต้นด้วย UI_PREFIX เหมือนกัน ไม่ต้องเคลียร์แยก
   PersistAllStats(); // เซฟรอบสุดท้ายตอนถอด/รีสตาร์ท EA กันพลาดช่วงระหว่างรอบ periodic save
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);
   if(mtfEmaHandle != INVALID_HANDLE) IndicatorRelease(mtfEmaHandle);
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
   // Hard License Lock: single choke point - every trading path (grid entries, Force
   // Hedge, trailing stop, everything) is reached only from inside OnTick(), so
   // stopping here before any of it runs is a complete, functional lock. Draws the
   // same Canvas-styled warning card as the rest of the dashboard instead of a plain
   // Comment(), so it's obvious this is a licensing block, not the EA looking broken.
   if(!IsLicensed)
   {
      ShowUnlicensedWarning();
      return;
   }

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
            LogEvent(StringFormat(GetUIString("ปิดบาสเก็ต - ล็อกกำไร $%.2f", "Basket closed - locked $%.2f"), currentProfit));
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

// Per-Side ATR/BB Distance เป็นส่วนขยายของ ATR Distance / BB Distance เท่านั้น - ถ้าปิดตัวหลัก
// ไว้ (ใช้ Fixed Distance) ต่อให้เปิด Per-Side ของตัวนั้นก็ต้องไม่มีผลอะไรเลย เพราะไม่มี "ระยะสด"
// ให้แยกต่อฝั่งตั้งแต่แรก - เช็คคู่กันตามแหล่งระยะที่ GetDynamicGridDistance() เลือกใช้จริง (BB มา
// ก่อน ATR เสมอถ้าเปิดทั้งคู่ ดู GetDynamicGridDistance())
bool IsPerSideDistanceActive()
{
   if(UseBBDistance)  return UseAdaptiveBBGrid;
   if(UseATRDistance) return UseAdaptiveATRGrid;
   return false;
}

//+------------------------------------------------------------------+
//| Calculate Dynamic Grid Distance using Bollinger Bands / ATR      |
//| ลำดับความสำคัญ: BB Distance (ถ้าเปิดและอ่านค่าได้) > ATR Distance   |
//| (ถ้าเปิดและอ่านค่าได้) > Fixed Distance (fallback สุดท้ายเสมอ)      |
//+------------------------------------------------------------------+
int GetDynamicGridDistance()
{
   if(UseBBDistance && bbHandle != INVALID_HANDLE)
   {
      double upperBuf[], lowerBuf[];
      ArraySetAsSeries(upperBuf, true);
      ArraySetAsSeries(lowerBuf, true);

      // iBands buffer index: 0=Base Line, 1=Upper Band, 2=Lower Band
      if(CopyBuffer(bbHandle, 1, 1, 1, upperBuf) > 0 && CopyBuffer(bbHandle, 2, 1, 1, lowerBuf) > 0)
      {
         double bbWidth = upperBuf[0] - lowerBuf[0];
         if(bbWidth > 0)
         {
            double bbPoints = (bbWidth * BB_Multiplier) / _Point;
            return (int)MathMax(10 * m_multiplier, MathRound(bbPoints));
         }
      }
      // ดึงค่า BB ไม่สำเร็จ (buffer ยังไม่พร้อม/error) - ไหลลงไปเช็ค ATR/Fixed ด้านล่างแทน
   }

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
   int buyStepDistance  = IsPerSideDistanceActive() ? ((BuyGridDistance  > 0) ? BuyGridDistance  : GetDynamicGridDistance()) : stepDistance;
   int sellStepDistance = IsPerSideDistanceActive() ? ((SellGridDistance > 0) ? SellGridDistance : GetDynamicGridDistance()) : stepDistance;

   MqlTradeRequest request;
   MqlTradeResult  result;
   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();

   int adjGapLimit = MaxAllowedGapPoints * m_multiplier;
   int adjSpread   = MaxSpreadAllowed * m_multiplier;

   bool canBuyFilters  = CheckEMATrend(true)  && CheckMTFFilter(true);
   bool canSellFilters = CheckEMATrend(false) && CheckMTFFilter(false);

   // Level Unlock: once BOTH sides have filled every configured TotalLevels
   // (neither side has any more room, and the basket still isn't profitable),
   // optionally allow opening further levels past the cap. This does NOT need
   // its own profit check - ExecuteGridLogic() is already gated by
   // (MaxBasketProfit < TargetProfit) in OnTick(), so grid execution (and
   // this unlock) automatically stops the moment the basket reaches
   // TargetProfit.
   bool bothSidesMaxed = (buyCount >= TotalLevels && sellCount >= TotalLevels);
   bool buyLevelAvailable  = (buyCount  < TotalLevels) ||
      (UseLevelUnlock && bothSidesMaxed && (MaxUnlockedLevels <= 0 || buyCount  < TotalLevels + MaxUnlockedLevels));
   bool sellLevelAvailable = (sellCount < TotalLevels) ||
      (UseLevelUnlock && bothSidesMaxed && (MaxUnlockedLevels <= 0 || sellCount < TotalLevels + MaxUnlockedLevels));

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
               // Pin the still-empty Sell side's level-0 target to the price that was
               // just traded, instead of leaving it anchored to wherever the basket
               // started - but ONLY in Per-Side ATR mode, where each side's distance
               // already moves live so re-anchoring to the latest price is expected.
               // In Fixed/plain-ATR mode the user wants the base to stay pinned at the
               // original level-1 anchor for the life of the basket - re-anchoring it
               // here made Sell's real trigger silently drift off of GridBasePrice
               // (which the dashboard shows as the fixed base), so the still-empty
               // side ended up opening before/past what the UI displayed as its base.
               if(IsPerSideDistanceActive() && sellCount == 0) GridBasePriceSell = ask;
               BuyGapAnchor = 0.0; // lastBuyPrice now reflects this real fill, override no longer needed
               // ฝั่ง Buy fill แล้ว - คำนวณระยะ Buy รอบถัดไปใหม่จาก ATR สด ณ ตอนนี้
               // ฝั่ง Sell ที่ยังไม่ fill ไม่ถูกแตะเลย ยังรอที่เป้าเดิมต่อไป
               if(IsPerSideDistanceActive()) BuyGridDistance = GetDynamicGridDistance();
               LogEvent(StringFormat(GetUIString("เปิดออเดอร์ Buy ชั้น %d", "Opened Buy Level %d"), nextLevel));
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
               // Symmetric to the Buy-fills-first case above - same Per-Side ATR gate,
               // same reasoning: outside that mode the base must stay put.
               if(IsPerSideDistanceActive() && buyCount == 0) GridBasePriceBuy = bid;
               SellGapAnchor = 0.0; // lastSellPrice now reflects this real fill, override no longer needed
               // ฝั่ง Sell fill แล้ว - คำนวณระยะ Sell รอบถัดไปใหม่จาก ATR สด ณ ตอนนี้
               // ฝั่ง Buy ที่ยังไม่ fill ไม่ถูกแตะเลย ยังรอที่เป้าเดิมต่อไป
               if(IsPerSideDistanceActive()) SellGridDistance = GetDynamicGridDistance();
               LogEvent(StringFormat(GetUIString("เปิดออเดอร์ Sell ชั้น %d", "Opened Sell Level %d"), nextLevel));
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
//| FIXED: position closes go through a confirm-and-retry loop that   |
//| re-scans real PositionsTotal() every pass instead of trusting a   |
//| single fire-and-forget send. Plain fire-and-forget OrderSendAsync |
//| with no follow-up check never verified the close actually         |
//| happened - if a broker rejected/requoted it (or just hadn't       |
//| processed it by the next tick), the position stayed open forever  |
//| while every caller had already set IsClosingState = true and      |
//| never reset it back to false. Since the only reset path required  |
//| openPositions==0 first, the EA would freeze completely (no more   |
//| Trailing Stop checks, no more grid additions) while the position  |
//| kept floating unmanaged - dashboard stuck on "CLOSING ALL..."     |
//| with positions still open and profit still moving. The individual |
//| close requests below use OrderSendAsync() (fast - no per-position |
//| round-trip wait), but the safety net is the outer while loop      |
//| re-checking real positions and retrying, NOT the send call's      |
//| return value - so this keeps the same actually-verified-closed    |
//| guarantee while closing multi-position baskets much faster.       |
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

         // Async แทน sync ตรงนี้เพื่อยิงปิดทุกไม้พร้อมกันโดยไม่ต้องรอ round-trip ทีละไม้ (ไม้เยอะ
         // จะได้ปิดไวขึ้นมาก) - ความปลอดภัย "ยืนยันว่าปิดจริง" ยังอยู่ครบเหมือนเดิม เพราะ retry loop
         // ด้านนอกยัง re-scan PositionsTotal() จริงทุกรอบอยู่ดี ไม่ได้อิงผลจาก OrderSend ตรงนี้เลย
         if(!OrderSendAsync(request, result))
         {
            Print("Clear Position OrderSendAsync failed: ", GetLastError(), " retcode: ", result.retcode);
         }
      }

      retryCount++;
      // Sleep() blocks real wall-clock time in the Strategy Tester too, and every
      // basket close (TS/Breakeven/DD Stop/time-filter) pays it at least once
      // even when OrderSend() already closed everything on the first pass - it's
      // only needed live, to give the broker time to actually process the close.
      // In the tester OrderSend() is synchronous/deterministic, so skip it.
      // Lowered from 50ms - just needs to be long enough for the async sends above to
      // land before the next re-scan; real close speed is now dominated by actual
      // network round-trip to the broker (ping), which this can't shrink any further.
      if(retryCount < 10 && !IsTestingMode) Sleep(20);
   }

   // บันทึกสถิติจาก snapshot ที่เก็บไว้ตอนต้นฟังก์ชัน - นับเป็น "บาสเก็ตที่ปิดแล้ว" เฉพาะตอนที่มีไม้จริงๆ ให้ปิด
   // (กันนับซ้ำตอนกดปุ่ม Close All ทั้งที่พอร์ตว่างอยู่แล้ว)
   if(statsPosCount > 0)
   {
      // กำไรวันนี้ (การ์ด Today) นับเฉพาะตอนบาสเก็ตปิดจริงเท่านั้น ไม่ใช่ floating P/L เรียลไทม์ -
      // เช็ค day rollover ตรงนี้ด้วยเพราะ dashboard (ที่เช็คปกติ) ไม่ทำงานตอน backtest
      MqlDateTime statsDt;
      TimeToStruct(TimeCurrent(), statsDt);
      if(statsDt.day_of_year != DayStartDay)
      {
         DayStartDay          = statsDt.day_of_year;
         DailyRealizedProfit  = 0.0;
      }
      DailyRealizedProfit += statsSnapshotProfit;

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

      PersistAllStats(); // เซฟทันทีตอนบาสเก็ตปิดจริง ไม่ต้องรอรอบเซฟ periodic ใน UpdateDashboard
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
   if(IsTestingMode && !ShowDashboardInBacktest) return;

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
   // Trebuchet MS แทบไม่มีน้ำหนักตัวหนาแยกจริงในหลายเครื่อง/VPS ทำให้ FW_BOLD ได้แค่ fake-bold
   // อ่อนๆ เกือบไม่ต่างจากปกติ - Arial มี Bold face จริงแยกต่างหาก (arialbd) ติดตั้งมากับ Windows
   // แทบทุกเครื่องเสมอ ทำให้ FW_BOLD เห็นผลชัดกว่ามาก
   return (Language == LNG_TH) ? "Tahoma" : "Arial";
}

// ตัวห่อ DashCanvas.FontSet() รวมศูนย์: โหมดภาษาอังกฤษให้ตัวหนาทั้ง UI เสมอ (ฟอนต์ปกติบางเกินไป
// อ่านยาก) ส่วนภาษาไทยยังคงพฤติกรรมเดิม (bold เฉพาะจุดที่ระบุไว้)
void UIFontSet(int fontSize, uint style = 0) // 0 = CCanvas::FontSet's own default weight (FW_NORMAL isn't a confirmed constant here, unlike FW_BOLD which the file already used)
{
   if(Language != LNG_TH) style = FW_BOLD;
   DashCanvas.FontSet(GetUIFont(), fontSize, style);
}

//+------------------------------------------------------------------+
//| Pushes a timestamped line into the ring buffer the "NEWS &       |
//| ALERTS" panel reads from. Newest entry always at index 0.        |
//+------------------------------------------------------------------+
void LogEvent(string text)
{
   for(int i = EVENT_LOG_MAX - 1; i > 0; i--)
   {
      EventLogText[i]    = EventLogText[i-1];
      EventLogTimeVal[i] = EventLogTimeVal[i-1];
   }
   EventLogText[0]    = text;
   EventLogTimeVal[0] = TimeCurrent();
}

void CreateButton(string name, int x, int y, int w, int h, string text, color bgClr, color textClr, int fontSize = 9) {
   if(IsTestingMode && !ShowDashboardInBacktest) return;
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

//+------------------------------------------------------------------+
//| Canvas drawing helpers - pixel-level drawing via CCanvas, used   |
//| for the gauge/equity-curve elements plain OBJ_LABEL/OBJ_RECT     |
//| objects can't do (arcs, gradients, connected line series).       |
//+------------------------------------------------------------------+
color BlendColor(color c1, color c2, double t)
{
   t = MathMax(0.0, MathMin(1.0, t));
   int r1 = (int)(c1 & 0xFF),        g1 = (int)((c1 >> 8) & 0xFF),  b1 = (int)((c1 >> 16) & 0xFF);
   int r2 = (int)(c2 & 0xFF),        g2 = (int)((c2 >> 8) & 0xFF),  b2 = (int)((c2 >> 16) & 0xFF);
   int r  = (int)(r1 + (r2 - r1) * t);
   int g  = (int)(g1 + (g2 - g1) * t);
   int b  = (int)(b1 + (b2 - b1) * t);
   return (color)(r | (g << 8) | (b << 16));
}

int EstimateTextWidth(string text, int fontSize)
{
   return (int)(StringLen(text) * fontSize * 0.58);
}

void DrawKV(int x, int y, int w, string label, string value, color labelColor, color valueColor, int fontSize = 18)
{
   int fs = SF(fontSize);
   UIFontSet(fs);
   DashCanvas.TextOut(x, y, label, ColorToARGB(labelColor));
   // ค่า (value) ใช้ bold เสมอ - ตัวบางที่ anti-alias บนพื้นเข้มดูจางง่าย ทำให้ตัวเลขที่สำคัญอ่านชัดกว่า label
   UIFontSet(fs, FW_BOLD);
   int vw = EstimateTextWidth(value, fs);
   DashCanvas.TextOut(x + w - vw, y, value, ColorToARGB(valueColor));
}

void DrawCardBG(int x, int y, int w, int h, string title)
{
   DashCanvas.FillRectangle(x, y, x + w, y + h, ColorToARGB(C'20,20,34'));
   DashCanvas.Rectangle(x, y, x + w, y + h, ColorToARGB(C'45,45,65'));
   UIFontSet(SF(17), FW_BOLD);
   DashCanvas.TextOut(x + S(12), y + S(10), title, ColorToARGB(C'160,160,190'));
}

// เกจวงแหวน (donut gauge) ไล่สีเขียว -> ฟ้า ตามสัดส่วน percent (0..1)
// cx/cy/radius/thickness เป็นพิกัดที่ scale มาแล้วจากผู้เรียก (caller ห่อด้วย S() ให้แล้ว)
void DrawArcGauge(int cx, int cy, int radius, int thickness, double percent)
{
   percent = MathMax(0.0, MathMin(1.0, percent));
   int steps = 120;

   for(int i = 0; i < steps; i++)
   {
      double a1 = (2.0 * M_PI) * i / steps - M_PI / 2.0;
      double a2 = (2.0 * M_PI) * (i + 1) / steps - M_PI / 2.0;
      for(int r = radius - thickness; r <= radius; r++)
      {
         int x1 = cx + (int)(r * MathCos(a1)), y1 = cy + (int)(r * MathSin(a1));
         int x2 = cx + (int)(r * MathCos(a2)), y2 = cy + (int)(r * MathSin(a2));
         DashCanvas.Line(x1, y1, x2, y2, ColorToARGB(C'40,40,55'));
      }
   }

   int fillSteps = (int)(steps * percent);
   for(int i = 0; i < fillSteps; i++)
   {
      double a1 = (2.0 * M_PI) * i / steps - M_PI / 2.0;
      double a2 = (2.0 * M_PI) * (i + 1) / steps - M_PI / 2.0;
      double t  = (fillSteps > 1) ? (double)i / (fillSteps - 1) : 0.0;
      color  c  = BlendColor(C'34,197,94', C'59,130,246', t);
      for(int r = radius - thickness; r <= radius; r++)
      {
         int x1 = cx + (int)(r * MathCos(a1)), y1 = cy + (int)(r * MathSin(a1));
         int x2 = cx + (int)(r * MathCos(a2)), y2 = cy + (int)(r * MathSin(a2));
         DashCanvas.Line(x1, y1, x2, y2, ColorToARGB(c));
      }
   }
}

void DrawEquityCurveChart(int x, int y, int w, int h)
{
   DashCanvas.FillRectangle(x, y, x + w, y + h, ColorToARGB(C'14,14,24'));

   if(EquityHistoryCount < 2)
   {
      UIFontSet(SF(14));
      DashCanvas.TextOut(x + S(10), y + h / 2 - S(7), GetUIString("กำลังเก็บข้อมูล...", "Collecting data..."), ColorToARGB(C'100,100,120'));
      return;
   }

   double minV = EquityHistoryBuf[0], maxV = EquityHistoryBuf[0];
   for(int i = 1; i < EquityHistoryCount; i++)
   {
      if(EquityHistoryBuf[i] < minV) minV = EquityHistoryBuf[i];
      if(EquityHistoryBuf[i] > maxV) maxV = EquityHistoryBuf[i];
   }
   double range = maxV - minV;
   if(range < 1.0) range = 1.0;

   int prevX = x, prevY = y + h;
   for(int i = 0; i < EquityHistoryCount; i++)
   {
      int px = x + (int)((double)i / (EquityHistoryCount - 1) * (w - 4)) + 2;
      int py = y + h - 4 - (int)((EquityHistoryBuf[i] - minV) / range * (h - 8));
      if(i > 0) DashCanvas.LineAA(prevX, prevY, px, py, ColorToARGB(C'59,130,246'));
      prevX = px;
      prevY = py;
   }
}

void DrawFeatureIcon(int x, int cellW, int y, string emoji, string labelTh, string labelEn, bool isOn)
{
   int cx       = x + cellW / 2;
   int circleR  = S(30);
   int circleCY = y + S(32);
   color bgColor = isOn ? C'34,197,94' : C'50,50,65';
   DashCanvas.FillCircle(cx, circleCY, circleR, ColorToARGB(bgColor));

   UIFontSet(SF(24));
   int ew = EstimateTextWidth(emoji, SF(24));
   DashCanvas.TextOut(cx - ew / 2, circleCY - S(12), emoji, ColorToARGB(clrWhite));

   UIFontSet(SF(14));
   string label = GetUIString(labelTh, labelEn);
   int lw = EstimateTextWidth(label, SF(14));
   DashCanvas.TextOut(cx - lw / 2, y + S(66), label, ColorToARGB(C'200,200,215'));

   string statusTxt = isOn ? GetUIString("เปิด", "ON") : GetUIString("ปิด", "OFF");
   UIFontSet(SF(14), FW_BOLD);
   int sw = EstimateTextWidth(statusTxt, SF(14));
   DashCanvas.TextOut(cx - sw / 2, y + S(86), statusTxt, ColorToARGB(isOn ? C'34,197,94' : C'120,120,135'));
}

void CountPositions(int &buyCount, int &sellCount, double &totalLots)
{
   buyCount = 0; sellCount = 0; totalLots = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      totalLots += PositionGetDouble(POSITION_VOLUME);
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buyCount++;
      else sellCount++;
   }
}

int GetCurrentATRPoints()
{
   if(!UseATRDistance || atrHandle == INVALID_HANDLE) return 0;
   double atrValues[];
   ArraySetAsSeries(atrValues, true);
   if(CopyBuffer(atrHandle, 0, 1, 1, atrValues) <= 0) return 0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return 0;
   return (int)MathRound(atrValues[0] / point);
}

string GetTimeframeString()
{
   string s = EnumToString((ENUM_TIMEFRAMES)_Period);
   StringReplace(s, "PERIOD_", "");
   return s;
}

// สำหรับแสดงผลบน dashboard เท่านั้น (ไม่แตะ trading logic จริงเลย) - คำนวณ "ราคาที่จะเปิดไม้ชั้นถัดไป"
// ของฝั่งที่ระบุ ด้วยสูตรเดียวกับที่ CheckAndExecuteVirtualGrid() ใช้จริงเป๊ะ: level แรก (count==0)
// คือ GridBasePriceBuy/Sell +/- ระยะ, level ถัดไปคือ ราคาไม้ล่าสุดจริง (หรือ gap anchor) +/- ระยะ
double GetNextGridTargetPrice(bool isBuy)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
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

   int stepDistance     = (CachedGridDistance > 0) ? CachedGridDistance : GetDynamicGridDistance();
   int buyStepDistance  = IsPerSideDistanceActive() ? ((BuyGridDistance  > 0) ? BuyGridDistance  : GetDynamicGridDistance()) : stepDistance;
   int sellStepDistance = IsPerSideDistanceActive() ? ((SellGridDistance > 0) ? SellGridDistance : GetDynamicGridDistance()) : stepDistance;

   // เฉพาะ Per-Side ATR Distance ที่ "ใช้งานจริง" (ต้องเปิด ATR Distance ด้วย ไม่งั้น Per-Side
   // ไม่มีผลอะไรเลย) เท่านั้นที่ทำให้ระยะแต่ละฝั่งไม่เท่ากันและเปลี่ยนสดทุกครั้งที่ฝั่งนั้น fill -
   // เลยให้ฐานเลื่อนตามไม้ล่าสุดจริงเฉพาะโหมดนี้ ส่วน ATR Distance ปกติ (ไม่ per-side) หรือ
   // Fixed Distance ให้ยึดฐานเดิมที่ level 1 ตายตัวเสมอ
   bool dynamicTarget = IsPerSideDistanceActive();

   // ระดับ 2+ ของทั้ง 2 ฝั่ง เคาะสูตร "ไม้ล่าสุดจริง +/- ระยะ" ในเอนจิ้นจริงเสมอ ไม่ว่าโหมดไหน -
   // ความแตกต่างของ dynamicTarget มีผลแค่ระดับ 1 เท่านั้น (ฐานคงที่ vs ไล่ตามราคาที่อีกฝั่งเพิ่ง fill)
   // ระดับ 2+ ต้องเลื่อนตามไม้ล่าสุดเสมอ เหมือนเอนจิ้นจริง ไม่งั้นค่าที่โชว์จะค้างอยู่ที่ระดับ 1 ตลอด
   // ทั้งที่ราคาที่จะ trigger จริงเปลี่ยนไปไกลแล้ว
   if(isBuy)
   {
      double effectiveLastBuy = MathMax(lastBuyPrice, BuyGapAnchor);
      if(buyCount > 0) return NormalizeDouble(effectiveLastBuy + (buyStepDistance * point), _Digits);
      // Fixed/non-per-side โหมด: อ้างอิงจาก GridBasePrice (ราคาศูนย์กลางจริง) ตรงๆ เท่านั้น -
      // ห้ามใช้ GridBasePriceBuy เพราะตัวแปรนั้นอาจถูก "pin" ไปที่ราคาตอนอีกฝั่ง fill ครั้งแรก
      // (คนละกลไกกับที่นี่ ใช้กันไม้ครั้งแรกหลัง gap) ทำให้ค่าที่โชว์เพี้ยนไปจากฐานจริง
      if(!dynamicTarget) return NormalizeDouble(GridBasePrice + (buyStepDistance * point), _Digits);
      return NormalizeDouble(GridBasePriceBuy + (buyStepDistance * point), _Digits);
   }
   else
   {
      double effectiveLastSell = (SellGapAnchor > 0 && SellGapAnchor < lastSellPrice) ? SellGapAnchor : lastSellPrice;
      if(sellCount > 0) return NormalizeDouble(effectiveLastSell - (sellStepDistance * point), _Digits);
      if(!dynamicTarget) return NormalizeDouble(GridBasePrice - (sellStepDistance * point), _Digits);
      return NormalizeDouble(GridBasePriceSell - (sellStepDistance * point), _Digits);
   }
}

// ประมาณความกว้างของสตริงตัวเลข/สัญลักษณ์ (เช่น "-13.4%") ได้แม่นกว่า EstimateTextWidth
// ทั่วไป เพราะตัวเลข/จุด/เปอร์เซ็นต์มีความกว้างต่างจากตัวอักษรค่าเฉลี่ยพอสมควร ใช้จัดกึ่งกลางเกจ %
int EstimateNumericTextWidth(string text, int fontSize)
{
   int n = StringLen(text);
   double total = 0.0;
   for(int i = 0; i < n; i++)
   {
      ushort ch = StringGetCharacter(text, i);
      if(ch == '.')                    total += 0.28;
      else if(ch == '-' || ch == '+')  total += 0.36;
      else if(ch == '%')               total += 0.78;
      else                             total += 0.52; // เลข 0-9
   }
   return (int)(total * fontSize);
}

//+------------------------------------------------------------------+
//| Section drawers - each returns the Y cursor for the next section |
//| Landscape layout: 6 stat cards side-by-side in one row, then     |
//| equity curve + feature grid share a second row, so the panel is  |
//| wide and short instead of a single narrow scrolling column.      |
//| Every fixed margin/offset goes through S(), every font size      |
//| through SF(). DASH_W is already the current scaled width, so     |
//| anything derived purely from it (card widths, badge/dot          |
//| positions) follows along automatically without its own S().      |
//+------------------------------------------------------------------+
int DrawHeader(int y)
{
   UIFontSet(SF(34), FW_BOLD);
   DashCanvas.TextOut(S(14), y, "QUANTIX PRO", ColorToARGB(clrWhite));
   DashCanvas.TextOut(S(14), y + S(31), "TERMINAL", ColorToARGB(C'168,85,247'));

   UIFontSet(SF(15));
   DashCanvas.TextOut(S(14), y + S(66), GetUIString("แดชบอร์ดวิเคราะห์แบบเรียลไทม์", "MULTI-ANALYTICS DASHBOARD"), ColorToARGB(C'150,120,200'));

   int badgeW = S(145), badgeH = S(30);
   int bx = DASH_W - S(14) - badgeW;
   DashCanvas.FillRectangle(bx, y, bx + badgeW, y + badgeH, ColorToARGB(C'30,30,48'));
   DashCanvas.Rectangle(bx, y, bx + badgeW, y + badgeH, ColorToARGB(C'80,80,110'));
   UIFontSet(SF(15), FW_BOLD);
   DashCanvas.TextOut(bx + S(12), y + S(6), GetUIString("เรียลไทม์", "UI REAL-TIME"), ColorToARGB(clrWhite));

   return y + S(90);
}

int DrawInfoBar(int y)
{
   DashCanvas.FillRectangle(S(14), y, DASH_W - S(14), y + S(36), ColorToARGB(C'16,16,28'));
   UIFontSet(SF(14), FW_BOLD);
   string txt = StringFormat("%s: %s   |   TIMEFRAME: %s   |   BROKER: %s",
                              GetUIString("สัญลักษณ์", "SYMBOL"), _Symbol, GetTimeframeString(),
                              AccountInfoString(ACCOUNT_COMPANY));
   DashCanvas.TextOut(S(24), y + S(9), txt, ColorToARGB(C'170,170,190'));
   return y + S(46);
}

int DrawServerTimeRow(int y, int openPos, int pendingOrders)
{
   UIFontSet(SF(15), FW_BOLD);
   string timeTxt = StringFormat("%s: %s", GetUIString("เวลาเซิร์ฟเวอร์", "SERVER TIME"), TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   DashCanvas.TextOut(S(14), y, timeTxt, ColorToARGB(C'150,150,170'));

   bool  timeAllowed = IsTradingAllowedByTime();
   color dotColor    = C'34,197,94';
   string statusTxt  = GetUIString("EA กำลังทำงาน", "EA RUNNING");

   if(TradingHalted)                              { dotColor = C'239,68,68';  statusTxt = GetUIString("EA หยุดถาวร", "EA HALTED"); }
   else if(IsClosingState)                        { dotColor = C'251,146,60'; statusTxt = GetUIString("กำลังปิดไม้", "CLOSING"); }
   else if(!timeAllowed)                           { dotColor = C'239,68,68';  statusTxt = GetUIString("นอกเวลาเทรด", "OFF-TIME"); }
   else if(openPos == 0 && pendingOrders == 0)     { dotColor = C'251,193,7';  statusTxt = GetUIString("พร้อมทำงาน", "STANDBY"); }

   int sw   = EstimateTextWidth(statusTxt, SF(15));
   int dotX = DASH_W - S(14) - sw - S(20);
   DashCanvas.FillCircle(dotX, y + S(6), S(6), ColorToARGB(dotColor));
   DashCanvas.TextOut(dotX + S(14), y, statusTxt, ColorToARGB(dotColor));

   return y + S(38);
}

// 6 การ์ดสถิติเรียงแถวเดียวแนวนอน: Account | Performance | Basket | Orders | Grid | Risk
int DrawStatCardsRow(int y, double balance, double equity, double dailyProfit, double currentProfit, double maxProfit)
{
   int cols   = 6;
   int gap    = S(10);
   int cardW  = (DASH_W - S(14) * 2 - gap * (cols - 1)) / cols;
   int cardH  = S(258);
   int innerW = cardW - S(24);
   int rowStep = S(29);

   int buyCount, sellCount; double totalLots;
   CountPositions(buyCount, sellCount, totalLots);
   int totalOrders = buyCount + sellCount;
   double margin      = AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin  = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginLevel = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   double lockedProfit = BreakevenActivated ? BreakevenLockUSD : 0.0;
   int adjSpread    = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int curLevel     = (int)MathMax(buyCount, sellCount);
   int nextDist     = (CachedGridDistance > 0) ? CachedGridDistance : GetDynamicGridDistance();
   double bidNow    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ddLimit   = UseTotalDDGuard ? MaxTotalDD_Pct : (UseMaxDDStop ? MaxAllowedDD_Pct : 0.0);

   int cx = S(14);

   // คอลัมน์ 1: ข้อมูลบัญชี
   DrawCardBG(cx, y, cardW, cardH, "👤 " + GetUIString("บัญชี", "ACCOUNT"));
   int ry = y + S(44);
   DrawKV(cx + S(12), ry, innerW, GetUIString("ยอดเงิน", "Balance"), "$" + DoubleToString(balance, 2), C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("มูลค่าสุทธิ", "Equity"), "$" + DoubleToString(equity, 2), C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("หลักประกัน", "Margin"), "$" + DoubleToString(margin, 2), C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ประกันเหลือ", "Free Mgn"), "$" + DoubleToString(freeMargin, 2), C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ระดับประกัน", "Mgn Lvl"), (marginLevel > 0 ? DoubleToString(marginLevel, 1) + "%" : "—"), C'160,160,180', C'34,197,94');

   // คอลัมน์ 2: ผลงานวันนี้
   cx += cardW + gap;
   DrawCardBG(cx, y, cardW, cardH, "📅 " + GetUIString("ผลงานวันนี้", "TODAY"));
   int gcx = cx + cardW / 2;
   int gcy = y + S(44) + S(58);
   double dailyPct = (DailyProfitGoal > 0) ? (dailyProfit / DailyProfitGoal) : 0.0;
   DrawArcGauge(gcx, gcy, S(48), S(11), dailyPct);
   string pctTxt = StringFormat("%+.1f%%", dailyPct * 100.0);
   int pctFs = SF(23);
   UIFontSet(pctFs, FW_BOLD);
   int pw = EstimateNumericTextWidth(pctTxt, pctFs);
   DashCanvas.TextOut(gcx - pw / 2, gcy - (int)(pctFs * 0.42), pctTxt, ColorToARGB(dailyProfit >= 0 ? C'34,197,94' : C'239,68,68'));
   int py2 = y + S(44) + S(128);
   DrawKV(cx + S(12), py2, innerW, GetUIString("กำไรวันนี้", "Daily P/L"),
          (dailyProfit >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(dailyProfit), 2), C'160,160,180', dailyProfit >= 0 ? C'34,197,94' : C'239,68,68');
   py2 += rowStep;
   DrawKV(cx + S(12), py2, innerW, GetUIString("เป้าหมาย", "Goal"),
          "$" + DoubleToString(DailyProfitGoal, 0) + " (" + DoubleToString(MathMax(0, dailyPct * 100.0), 0) + "%)", C'160,160,180', clrWhite);

   // คอลัมน์ 3: สถานะบาสเก็ต
   cx += cardW + gap;
   DrawCardBG(cx, y, cardW, cardH, "📦 " + GetUIString("บาสเก็ต", "BASKET"));
   ry = y + S(44);
   DrawKV(cx + S(12), ry, innerW, GetUIString("กำไรลอย", "Floating"), (currentProfit >= 0 ? "+$" : "-$") + DoubleToString(MathAbs(currentProfit), 2), C'160,160,180', currentProfit >= 0 ? C'34,197,94' : C'239,68,68'); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("สูงสุด", "Peak"), "+$" + DoubleToString(maxProfit, 2), C'160,160,180', C'34,197,94'); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ล็อกไว้", "Locked"), (lockedProfit > 0 ? "+$" + DoubleToString(lockedProfit, 2) : "—"), C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ย่อตัว", "Drawdown"), "-$" + DoubleToString(MaxDrawdownUSD, 2), C'160,160,180', C'239,68,68'); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("คุ้มทุน", "Breakeven"), (BreakevenActivated ? "$" + DoubleToString(BreakevenLockUSD, 2) : "—"), C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("บาสเก็ตปิด", "Baskets"), IntegerToString(StatsTotalBaskets), C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ออเดอร์รวม", "Orders"), IntegerToString(totalOrders), C'160,160,180', clrWhite);

   // คอลัมน์ 4: ข้อมูลออเดอร์
   cx += cardW + gap;
   DrawCardBG(cx, y, cardW, cardH, "📋 " + GetUIString("ออเดอร์", "ORDERS"));
   ry = y + S(44);
   DrawKV(cx + S(12), ry, innerW, GetUIString("ไม้ Buy", "Buy"), IntegerToString(buyCount), C'160,160,180', C'34,197,94'); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ไม้ Sell", "Sell"), IntegerToString(sellCount), C'160,160,180', C'239,68,68'); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("รวม", "Total"), IntegerToString(totalOrders), C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ล็อตรวม", "Lots"), DoubleToString(totalLots, 2), C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ระยะ Grid", "Distance"), IntegerToString(DistancePoints) + " P", C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, "ATR", (UseATRDistance ? IntegerToString(GetCurrentATRPoints()) + " P" : "—"), C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("สเปรด", "Spread"), IntegerToString(adjSpread) + " P", C'160,160,180', adjSpread > MaxSpreadAllowed * m_multiplier ? C'239,68,68' : clrWhite);

   // คอลัมน์ 5: สถานะกริด
   cx += cardW + gap;
   DrawCardBG(cx, y, cardW, cardH, "⚙️ " + GetUIString("กริด", "GRID"));
   ry = y + S(44);
   DrawKV(cx + S(12), ry, innerW, GetUIString("โหมด", "Mode"), (GridType == GRID_VIRTUAL ? "VIRTUAL" : "PENDING"), C'160,160,180', C'251,193,7'); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ชั้น", "Levels"), IntegerToString(curLevel) + " / " + IntegerToString(TotalLevels), C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ระยะถัดไป", "Next Dist"), IntegerToString(nextDist) + " P", C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ราคาฐาน", "Base Price"), DoubleToString(GridBasePrice, _Digits), C'160,160,180', clrWhite); ry += rowStep;
   // ฐาน Buy/Sell = ราคาที่จะเปิดไม้ชั้นถัดไปจริง (base +/- ระยะ) ไม่ใช่ราคาศูนย์กลางดิบๆ
   DrawKV(cx + S(12), ry, innerW, GetUIString("ฐาน Buy", "Base Buy"), DoubleToString(GetNextGridTargetPrice(true), _Digits), C'160,160,180', C'34,197,94'); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ฐาน Sell", "Base Sell"), DoubleToString(GetNextGridTargetPrice(false), _Digits), C'160,160,180', C'239,68,68'); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ราคาตลาด", "Price"), DoubleToString(bidNow, _Digits), C'160,160,180', clrWhite);

   // คอลัมน์ 6: บริหารความเสี่ยง
   cx += cardW + gap;
   DrawCardBG(cx, y, cardW, cardH, "🛡️ " + GetUIString("ความเสี่ยง", "RISK"));
   ry = y + S(44);
   DrawKV(cx + S(12), ry, innerW, GetUIString("ย่อตัวสูงสุด", "Max DD"), DoubleToString(MaxDrawdownPercent, 2) + "%", C'160,160,180', MaxDrawdownPercent > 5 ? C'239,68,68' : C'34,197,94'); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ลิมิต", "DD Limit"), (ddLimit > 0 ? DoubleToString(ddLimit, 1) + "%" : "—"), C'160,160,180', clrWhite); ry += rowStep;
   DrawKV(cx + S(12), ry, innerW, GetUIString("ล็อตเริ่มต้น", "Base Lot"), DoubleToString(BaseLot, 2), C'160,160,180', clrWhite); ry += rowStep;
   string lotModeTxt = (LotType == LOT_RISK_PERCENT) ? GetUIString("% ความเสี่ยง", "% of Risk") : (UseDynamicLot ? GetUIString("อัตโนมัติ", "Dynamic") : GetUIString("คงที่", "Fixed"));
   DrawKV(cx + S(12), ry, innerW, GetUIString("โหมดล็อต", "Lot Mode"), lotModeTxt, C'160,160,180', clrWhite); ry += rowStep;
   string riskStatusTxt = GetUIString("ปลอดภัย", "SAFE");
   color  riskStatusClr = C'34,197,94';
   if(TradingHalted) { riskStatusTxt = GetUIString("หยุดถาวร", "HALTED"); riskStatusClr = C'239,68,68'; }
   else if(ddLimit > 0 && MaxDrawdownPercent >= ddLimit * 0.7) { riskStatusTxt = GetUIString("เฝ้าระวัง", "WARNING"); riskStatusClr = C'251,146,60'; }
   DrawKV(cx + S(12), ry, innerW, GetUIString("สถานะ", "Status"), riskStatusTxt, C'160,160,180', riskStatusClr);

   return y + cardH + S(12);
}

// แถวที่สอง: กราฟเส้นทุน (ซ้าย) + กริดฟีเจอร์ที่ใช้งาน (ขวา) เรียงข้างกันแนวนอน
int DrawEquityFeatureRow(int y)
{
   int gap   = S(12);
   int totalW = DASH_W - S(14) * 2 - gap;
   int eqW   = (int)(totalW * 0.58);
   int ftW   = totalW - eqW;
   int rowH  = S(265);

   DrawCardBG(S(14), y, eqW, rowH, "📈 " + GetUIString("กราฟเส้นทุน", "EQUITY CURVE"));
   int chartY = y + S(44);
   int chartH = rowH - S(44) - S(32);
   DrawEquityCurveChart(S(14) + S(10), chartY, eqW - S(20), chartH);
   UIFontSet(SF(14), FW_BOLD);
   string ddTxt = GetUIString("ย่อตัวสูงสุด: ", "MAX DRAWDOWN: ") + DoubleToString(MaxDrawdownPercent, 2) + "%";
   int tw = EstimateTextWidth(ddTxt, SF(14));
   DashCanvas.TextOut(S(14) + eqW - S(14) - tw, y + rowH - S(27), ddTxt, ColorToARGB(C'239,68,68'));

   int fx = S(14) + eqW + gap;
   DrawCardBG(fx, y, ftW, rowH, "🧩 " + GetUIString("ฟีเจอร์ที่ใช้งาน", "ACTIVE FEATURES"));
   int cols  = 4;
   int cellW = (ftW - S(20)) / cols;
   int row1Y = y + S(46);
   int row2Y = row1Y + S(104);

   DrawFeatureIcon(fx + S(10) + cellW * 0, cellW, row1Y, "🕸️", "GRID เสมือน", "VIRTUAL GRID", GridType == GRID_VIRTUAL);
   DrawFeatureIcon(fx + S(10) + cellW * 1, cellW, row1Y, "🧺", "เครื่องยนต์", "BASKET ENGINE", true);
   DrawFeatureIcon(fx + S(10) + cellW * 2, cellW, row1Y, "📉", "เทรลลิ่งสต็อป", "TRAILING STOP", true);
   DrawFeatureIcon(fx + S(10) + cellW * 3, cellW, row1Y, "🔒", "ล็อกคุ้มทุน", "BREAKEVEN LOCK", UseBasketBreakeven);

   DrawFeatureIcon(fx + S(10) + cellW * 0, cellW, row2Y, "✂️", "ปิดบางส่วน", "PARTIAL CLOSE", UsePartialClose);
   DrawFeatureIcon(fx + S(10) + cellW * 1, cellW, row2Y, "🩹", "โหมดแก้ไม้", "RECOVERY MODE", UseRecoveryMode);
   DrawFeatureIcon(fx + S(10) + cellW * 2, cellW, row2Y, "⚔️", "ฟอร์ซเฮดจ์", "FORCE HEDGE", UseForceHedgeOnDD || UseForceHedgeOnTime);
   DrawFeatureIcon(fx + S(10) + cellW * 3, cellW, row2Y, "🛡️", "กัน Gap", "GAP PROTECTION", UseGapProtection);

   return y + rowH + S(12);
}

int DrawStatsRow(int y)
{
   int cardW = DASH_W - S(14) * 2;
   int cardH = S(84);
   DashCanvas.FillRectangle(S(14), y, S(14) + cardW, y + cardH, ColorToARGB(C'20,20,34'));
   DashCanvas.Rectangle(S(14), y, S(14) + cardW, y + cardH, ColorToARGB(C'45,45,65'));

   double winRate = (StatsTotalBaskets > 0) ? (StatsWinCount * 100.0 / StatsTotalBaskets) : 0.0;
   double avgWin   = (StatsWinCount  > 0) ? (StatsSumWinProfit  / StatsWinCount)  : 0.0;
   double avgLoss  = (StatsLossCount > 0) ? (StatsSumLossAmount / StatsLossCount) : 0.0;

   string labels[6];
   labels[0] = GetUIString("บาสเก็ตรวม", "TOTAL BASKETS");
   labels[1] = GetUIString("อัตราชนะ", "WIN RATE");
   labels[2] = GetUIString("ชนะ", "WINS");
   labels[3] = GetUIString("แพ้", "LOSSES");
   labels[4] = GetUIString("ชนะเฉลี่ย", "AVG WIN");
   labels[5] = GetUIString("แพ้เฉลี่ย", "AVG LOSS");

   string values[6];
   values[0] = IntegerToString(StatsTotalBaskets);
   values[1] = DoubleToString(winRate, 2) + "%";
   values[2] = IntegerToString(StatsWinCount);
   values[3] = IntegerToString(StatsLossCount);
   values[4] = "+$" + DoubleToString(avgWin, 2);
   values[5] = "-$" + DoubleToString(avgLoss, 2);

   color valColors[6];
   valColors[0] = clrWhite; valColors[1] = C'34,197,94'; valColors[2] = C'34,197,94';
   valColors[3] = C'239,68,68'; valColors[4] = C'34,197,94'; valColors[5] = C'239,68,68';

   int colW = cardW / 6;
   for(int i = 0; i < 6; i++)
   {
      int cx = S(14) + colW * i + colW / 2;
      UIFontSet(SF(20), FW_BOLD);
      int vw = EstimateTextWidth(values[i], SF(20));
      DashCanvas.TextOut(cx - vw / 2, y + S(15), values[i], ColorToARGB(valColors[i]));

      UIFontSet(SF(14));
      int lw = EstimateTextWidth(labels[i], SF(14));
      DashCanvas.TextOut(cx - lw / 2, y + S(47), labels[i], ColorToARGB(C'140,140,160'));
   }

   return y + cardH + S(12);
}

int DrawNewsCard(int y)
{
   int cardW = DASH_W - S(14) * 2;
   int cardH = S(162);
   DrawCardBG(S(14), y, cardW, cardH, "📰 " + GetUIString("ข่าวและการแจ้งเตือน", "NEWS & ALERTS"));

   int ry = y + S(46);
   bool any = false;
   for(int i = 0; i < EVENT_LOG_MAX; i++)
   {
      if(EventLogTimeVal[i] == 0) continue;
      any = true;
      MqlDateTime dt;
      TimeToStruct(EventLogTimeVal[i], dt);
      string line = StringFormat("%02d:%02d  %s", dt.hour, dt.min, EventLogText[i]);
      UIFontSet(SF(15), FW_BOLD);
      DashCanvas.TextOut(S(14) + S(14), ry, "✓", ColorToARGB(C'34,197,94'));
      DashCanvas.TextOut(S(14) + S(34), ry, line, ColorToARGB(C'190,190,205'));
      ry += S(23);
   }
   if(!any)
   {
      UIFontSet(SF(15));
      DashCanvas.TextOut(S(14) + S(14), ry, GetUIString("ยังไม่มีเหตุการณ์", "No events yet"), ColorToARGB(C'110,110,130'));
   }

   return y + cardH + S(14);
}
//+------------------------------------------------------------------+
//| Responsive scaling - DASH_W/DASH_H hold the CURRENT (possibly    |
//| scaled) resolution the canvas is actually drawn+created at, so   |
//| every layout formula that derives from them (card widths, badge  |
//| positions, etc.) scales automatically. S()/SF() scale everything |
//| else (fixed margins, row heights, font sizes, radii) that isn't  |
//| already width-derived. Recomputed once whenever the chart height |
//| changes meaningfully - the canvas is destroyed and recreated at  |
//| the new resolution (previous attempt tried to fake this by       |
//| stretching the display object's XSIZE/YSIZE after drawing at a   |
//| fixed resolution, but CCanvas.Update() resets those back to the  |
//| buffer's real size, so it just got clipped instead of scaled).   |
//+------------------------------------------------------------------+
double UIScale       = 1.0;
int    DASH_W_BASE   = 1450;
int    DASH_H_BASE   = 1095;

int S(double v)  { return (int)MathRound(v * UIScale); }
// พื้นฟอนต์ต่ำมาก (8px) แค่กันกรณีสุดขั้ว - ถ้าตั้งพื้นสูงกว่านี้ ฟอนต์จะไม่ย่อตามการ์ดที่หดลงจริง
// ทำให้ label/value ยาวเกินกรอบการ์ดจนทับกัน (ตามที่เจอในหน้าจอแคบ) การ์ดถูกออกแบบให้พอดีกับฟอนต์ที่ scale
// ตามสัดส่วนเดียวกันเป๊ะ ไม่ใช่ฟอนต์คงที่ขณะการ์ดหด
int SF(double v) { int f = (int)MathRound(v * UIScale); return (f < 8) ? 8 : f; }

double ComputeUIScale()
{
   long chartH = ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   long chartW = ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   if(chartH <= 0 || chartW <= 0) return 1.0;

   double scaleH = (chartH - 40.0) / (double)DASH_H_BASE;
   double scaleW = (chartW - 60.0) / (double)DASH_W_BASE; // แนวนอนกว้างขึ้น ต้องเช็คความกว้างชาร์ตด้วย ไม่งั้นล้นด้านข้าง
   double scale  = MathMin(scaleH, scaleW);
   // UIScaleMultiplier: ตัวคูณเพิ่มเติมที่ผู้ใช้ปรับเองได้ (default 1.3) เผื่อ auto-fit ตามขนาดจอแล้วยังเล็กไป
   // ถ้าปรับเพิ่มมากไป panel อาจใหญ่กว่าที่จอมองเห็นได้พอดี - ลดค่านี้ลงได้จาก Inputs
   scale *= UIScaleMultiplier;
   // วาดใหม่ทุกครั้งที่ resolution เปลี่ยน (ไม่ใช่ stretch บิตแมปเดิม) ขยายเกิน 1.0 ได้โดยไม่เบลอ
   if(scale > 2.4) scale = 2.4;   // กันขยายจนใหญ่เกินจอ
   if(scale < 0.4) scale = 0.4;   // กันหดจนเล็กเกินไป (SF() มีพื้นฟอนต์กันไว้อีกชั้น)
   return scale;
}

//+------------------------------------------------------------------+
//| Persistent Canvas-drawn warning shown instead of the normal       |
//| dashboard whenever the current account isn't in                  |
//| LicensedAccountNumbers. Draws once (checks ObjectFind first) -    |
//| OnTick() calls this every tick while unlicensed, so this must     |
//| stay cheap and idempotent, same styling as the rest of the        |
//| Canvas dashboard (dark card, colored border, UIFontSet text).     |
//+------------------------------------------------------------------+
void ShowUnlicensedWarning()
{
   if(IsTestingMode) return;
   if(ObjectFind(0, CANVAS_NAME) >= 0) return; // วาดครั้งเดียวพอ ไม่ต้องรีเฟรชทุกทิค

   UIScale = ComputeUIScale();
   int w = S(560);
   int h = S(150);

   DashCanvas.CreateBitmapLabel(CANVAS_NAME, 15, 15, w, h, COLOR_FORMAT_ARGB_NORMALIZE);
   ObjectSetInteger(0, CANVAS_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, CANVAS_NAME, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, CANVAS_NAME, OBJPROP_BACK, false);

   DashCanvas.Erase(ColorToARGB(C'8,8,16'));
   DashCanvas.FillRectangle(0, 0, w, h, ColorToARGB(C'26,10,10'));
   DashCanvas.Rectangle(0, 0, w - 1, h - 1, ColorToARGB(C'220,38,38'));

   UIFontSet(SF(22), FW_BOLD);
   DashCanvas.TextOut(S(18), S(16), "🔒 " + GetUIString("EA ยังไม่ได้ลงทะเบียน", "EA NOT LICENSED"), ColorToARGB(C'239,68,68'));

   UIFontSet(SF(16), FW_BOLD);
   string accLine = StringFormat("Account #%I64d", AccountInfoInteger(ACCOUNT_LOGIN)); // %I64d ไม่ใช่ %d - กัน overflow บัญชีเลขใหญ่ (ดูเหตุผลเดียวกันใน OnInit())
   DashCanvas.TextOut(S(18), S(58), accLine, ColorToARGB(clrWhite));

   UIFontSet(SF(14));
   DashCanvas.TextOut(S(18), S(90), GetUIString("บัญชีนี้ไม่ได้รับอนุญาตให้ใช้ EA นี้", "This account is not authorized to run this EA."), ColorToARGB(C'200,200,215'));
   DashCanvas.TextOut(S(18), S(112), GetUIString("ติดต่อผู้พัฒนาเพื่อลงทะเบียนบัญชีนี้", "Contact the developer to register this account."), ColorToARGB(C'200,200,215'));

   DashCanvas.Update();
}

//+------------------------------------------------------------------+
//| Dashboard lifecycle                                              |
//+------------------------------------------------------------------+
void InitDashboard()
{
   if(IsTestingMode && !ShowDashboardInBacktest) return;
   DeleteDashboard();

   UIScale = ComputeUIScale();
   DASH_W  = S(DASH_W_BASE);
   DASH_H  = S(DASH_H_BASE);

   DashCanvas.CreateBitmapLabel(CANVAS_NAME, 15, 15, DASH_W, DASH_H, COLOR_FORMAT_ARGB_NORMALIZE);
   ObjectSetInteger(0, CANVAS_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, CANVAS_NAME, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, CANVAS_NAME, OBJPROP_BACK, false);
   ObjectSetInteger(0, CANVAS_NAME, OBJPROP_HIDDEN, true);

   string btnText = GetUIString("🚨 ปิดรวบทุกไม้ (CLOSE ALL)", "🚨 CLOSE ALL POSITIONS");
   CreateButton(BTN_CLOSE_ALL, 15 + S(14), 15 + DASH_H - S(54), DASH_W - S(28), S(40), btnText, C'220,38,38', clrWhite, SF(10));

   DashCanvas.Erase(ColorToARGB(C'8,8,16'));
   DashCanvas.Update();
}

void UpdateDashboard(double currentProfit, double maxProfit, double currentTS, int openPos, int pendingOrders)
{
   if(IsTestingMode && !ShowDashboardInBacktest) return;
   if(ObjectFind(0, CANVAS_NAME) < 0) InitDashboard();
   else if(MathAbs(ComputeUIScale() - UIScale) >= 0.03) InitDashboard(); // ขนาดหน้าต่างชาร์ตเปลี่ยนพอสมควร - สร้าง canvas ใหม่ที่ความละเอียดใหม่

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(TimeCurrent() - LastEquitySampleTime >= 60 || EquityHistoryCount == 0)
   {
      LastEquitySampleTime = TimeCurrent();
      if(EquityHistoryCount < EQUITY_HISTORY_MAX)
      {
         EquityHistoryBuf[EquityHistoryCount] = equity;
         EquityHistoryCount++;
      }
      else
      {
         for(int i = 0; i < EQUITY_HISTORY_MAX - 1; i++) EquityHistoryBuf[i] = EquityHistoryBuf[i + 1];
         EquityHistoryBuf[EQUITY_HISTORY_MAX - 1] = equity;
      }
   }

   MqlDateTime nowDt;
   TimeToStruct(TimeCurrent(), nowDt);
   if(nowDt.day_of_year != DayStartDay)
   {
      DayStartDay          = nowDt.day_of_year;
      DailyRealizedProfit  = 0.0; // ขึ้นวันใหม่ - ล้างยอดกำไรวันนี้ แม้จะยังไม่มีบาสเก็ตปิดเลยก็ตาม
   }
   // การ์ด Today อัปเดตเฉพาะตอนบาสเก็ตปิดจริง (ดู ClearEverythingAsync) ไม่ใช่ floating P/L เรียลไทม์
   double dailyProfit = DailyRealizedProfit;

   // เซฟ PeakBalanceForDD/MaxDrawdown/AccountPeakBalanceAllTime เป็นระยะ (UpdateDashboard ถูก
   // throttle ไว้ที่ทุก 500ms อยู่แล้ว) เพราะค่าพวกนี้อัปเดตทุกทิคใน UpdateDrawdownTracker() ไม่ได้
   // ผูกกับ event ปิดบาสเก็ตเหมือน Stats* ด้านบน เลยต้องมีจุดเซฟ periodic แยกต่างหาก
   PersistAllStats();

   DashCanvas.Erase(ColorToARGB(C'8,8,16'));

   int y = S(14);
   y = DrawHeader(y);
   y = DrawInfoBar(y);
   y = DrawServerTimeRow(y, openPos, pendingOrders);
   y = DrawStatCardsRow(y, balance, equity, dailyProfit, currentProfit, maxProfit);
   y = DrawEquityFeatureRow(y);
   y = DrawStatsRow(y);
   y = DrawNewsCard(y);

   DashCanvas.Update();
}

void DeleteDashboard()
{
   DashCanvas.Destroy();
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, UI_PREFIX) == 0) ObjectDelete(0, name);
   }
   ChartRedraw();
}
