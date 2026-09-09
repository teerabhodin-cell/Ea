//+------------------------------------------------------------------+
//|                                                   QuantixProEA.mq5|
//|        Dual Mode Grid (Pending / Virtual) + Basket Trailing Stop |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>

CTrade trade;

//=========================== DEMO EXPIRY LOCK ==================================//
// รุ่น Demo - ใช้ได้ถึงวันที่กำหนดเท่านั้น (ฝังเป็นค่าคงที่ใน source code เหมือน License Lock
// **ห้ามทำเป็น input เด็ดขาด** เพราะผู้ใช้จะแก้ค่าเองได้ทันทีจากหน้า Inputs) คนละไฟล์กับ
// QuantixProEA.mq5 (รันได้ไม่จำกัดเวลา ไม่มีล็อควันหมดอายุ)
datetime DemoExpiryDate = D'2026.08.15 23:59:59'; // หมดอายุคืนวันเสาร์ที่ 15 ส.ค. 2026 (ตามเวลา Server)

//=========================== ENUMS ================================//
enum ENUM_LANGUAGE
{
   LNG_TH, // ภาษาไทย (Thai)
   LNG_EN  // English
};

enum ENUM_GRID_TYPE
{
   GRID_VIRTUAL,       // Virtual Grid - Breakout (ซ่อน Pending ในโค้ด, Buy ตอนราคาขึ้น/Sell ตอนราคาลง)
   GRID_PENDING,       // Pending Order (ตั้ง Buy Stop / Sell Stop บน Server)
   GRID_VIRTUAL_LIMIT  // Virtual Grid - Limit (ซ่อน Pending ในโค้ด, Buy ตอนราคาลง/Sell ตอนราคาขึ้น)
};

enum ENUM_LOT_TYPE
{
   LOT_FIXED,        // Fixed Lot (ล็อตคงที่)
   LOT_RISK_PERCENT  // % of Risk (คำนวณตาม % ความเสี่ยง)
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

input group "===== 2. Lot ====="
input ENUM_LOT_TYPE LotType         = LOT_RISK_PERCENT; // Lot Type (ประเภท Lot)
input double BaseLot                = 0.05;      // ใช้เมื่อ LotType = Fixed Lot
input double LotMultiplier          = 1.5;
input double LotRiskPercent         = 1.0;     // Risk % of Equity (ใช้เมื่อ LotType = % of Risk, ต่อระยะ Grid ปัจจุบัน 1 ช่วง)
input bool   UseDynamicLot          = false;   // Dynamic Lot by Equity (Lot ตาม Equity, ใช้เมื่อ LotType = Fixed Lot เท่านั้น)
input double BalancePerLot          = 8000.0;  // Equity per 0.01 Lot
input bool   UseEquityLock          = false;   // Equity Lock (ล็อคพอร์ต)
input double MinEquityLimit         = 4000.0;  // Min Equity Limit
input bool   UseAutoReduceLot       = false;   // Auto Reduce Lot on DD (ลด Lot อัตโนมัติ)
input double ReduceLotThresholdDD   = 20.0;    // Reduce Lot DD Trigger %
input bool   UseMaxLotCap           = false;   // Use Max Lot Cap (จำกัด Lot สูงสุด)
input double MaxLotCap              = 5.0;     // Max Lot Cap (Lot สูงสุดต่อไม้)

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
input bool   UseMinVolatilityFilter = false;   // Use Min Volatility Filter (กรองความผันผวนขั้นต่ำ)
input int    MinVolatilityPoints    = 50;      // Min ATR/BB Distance, pts (ต่ำกว่านี้ไม่เปิดไม้ใหม่)
input bool   UseMaxVolatilityFilter = false;   // Use Max Volatility Filter (กรองความผันผวนสูงสุด)
input int    MaxVolatilityPoints    = 500;     // Max ATR/BB Distance, pts (สูงกว่านี้ไม่เปิดไม้ใหม่)
input ulong  MagicNumber            = 112233;

input group "===== 4. Target & Trailing ====="
input double TargetProfit        = 5.0;    // Target Profit $ (เป้ากำไร)
input double TargetProfitPct     = 0.0;    // Target Profit % of Balance (0=ปิด, ใช้ยอดก่อนเริ่มบาสเก็ตเป็นฐาน)
input double TrailingStopUSD     = 0.2;    // Trailing Distance $ (ระยะเทรล)
input double DailyProfitGoal     = 100.0;  // Daily Profit Goal $ (เป้ากำไรรายวัน, ใช้แสดงในเกจ Dashboard)
input double DailyProfitGoalPct  = 0.0;    // Daily Profit Goal % of Balance (0=ปิด, ใช้ยอดก่อนเริ่มวันเป็นฐาน)
input bool   UseDailyGoalStop    = false;  // Stop Trading at Daily Goal (หยุดเปิดไม้เมื่อถึงเป้ากำไรวันนี้)
input bool   UseDailyLossLimit   = false;  // Use Daily Loss Limit (จำกัดขาดทุนรายวัน)
input double DailyLossLimit      = 100.0;  // Daily Loss Limit $ (เพดานขาดทุนรายวัน)
input double DailyLossLimitPct   = 0.0;    // Daily Loss Limit % of Balance (0=ปิด, ใช้ยอดก่อนเริ่มวันเป็นฐาน)

input group "===== 5. Trend Filters ====="
input bool   UseEMAFilter           = true;    // Use EMA Filter (ใช้ EMA)
input int    EMA_Period             = 200;     // EMA Period
input bool   StrictBuyFilter        = true;    // Block Buy < EMA (ล็อค Buy)
input bool   StrictSellFilter       = true;    // Block Sell > EMA (ล็อค Sell)
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
input bool   UseLatencyGuard          = false; // Use Latency Guard (พักเปิดไม้ถ้า execution ช้าต่อเนื่อง)
input int    MaxLatencyMs             = 500;   // Max Latency, ms (เกินนี้ถือว่าไม้นั้นฟิลช้า)
input int    LatencyGuardTriggerCount = 3;     // Consecutive Slow Fills to Trigger (จำนวนไม้ช้าติดกัน)
input int    LatencyGuardPauseSeconds = 60;    // Pause Duration, Sec (ระยะเวลาพักเปิดไม้ใหม่)

input group "===== 10. News Filter ====="
input bool   UseNewsFilter          = false;                       // Use News Filter (พักเปิดไม้ช่วงข่าว)
input ENUM_CALENDAR_EVENT_IMPORTANCE NewsMinImportance = CALENDAR_IMPORTANCE_HIGH; // Min News Importance (ระดับข่าวขั้นต่ำ)
input int    NewsMinutesBefore      = 15;                          // Minutes Before News (นาทีก่อนข่าว)
input int    NewsMinutesAfter       = 15;                          // Minutes After News (นาทีหลังข่าว)

// รวมทุกพารามิเตอร์ที่มีผลเฉพาะตอน Grid Type = Virtual Limit ไว้ในหมวดเดียว (เดิมกระจายอยู่ทั้งหมวด
// Grid และ Target & Trailing) ให้หาง่ายขึ้น เพราะทั้งหมดนี้เป็น "ค่าทับ" ที่ไม่มีผลเลยตอนใช้ Virtual
// Grid (Breakout) หรือ Pending Order
input group "===== 11. Virtual Limit Mode ====="
input bool   UseLimitModeDistance     = false; // Use Separate Distance (แยกระยะกริด Virtual Limit)
input int    LimitModeDistancePoints  = 150;   // Virtual Limit Distance, pts (ระยะกริดเฉพาะโหมด Virtual Limit)
input bool   UseLimitModeTarget       = false; // Use Separate TP/Trailing (แยก TP/Trailing Virtual Limit)
input double LimitModeTargetProfit    = 5.0;   // Virtual Limit Target Profit $ (เป้ากำไรเฉพาะโหมด Virtual Limit)
input double LimitModeTrailingStopUSD = 0.2;   // Virtual Limit Trailing Distance $ (ระยะเทรลเฉพาะโหมด Virtual Limit)
input bool   UseRSIFilter             = false; // Use RSI Filter (กรองด้วย RSI ก่อนเข้า - เฉพาะ Virtual Limit)
input int    RSI_Period               = 14;    // RSI Period
input double RSI_Oversold             = 30.0;  // RSI Oversold Level (Buy ได้ก็ต่อเมื่อ RSI <= ค่านี้)
input double RSI_Overbought           = 70.0;  // RSI Overbought Level (Sell ได้ก็ต่อเมื่อ RSI >= ค่านี้)

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

// Execution quality ของไม้ล่าสุดที่ฟิลสำเร็จ (grid entry หรือ Force Hedge) - ใช้โชว์บน Dashboard
// เพื่อแยกแยะให้ลูกค้าเห็นเองว่าอาการ "ผลลัพธ์ไม่ตรงกัน/ราคาเพี้ยน" มาจาก execution (ping/สลิปเพจ) ของ
// บัญชี/VPS นั้นๆ ไม่ใช่บั๊กของ EA - อัปเดตทุกครั้งที่ OrderSend() สำเร็จ ไม่ผูกกับ order ที่ถูก reject
double LastFillSlippagePoints = 0.0;  // |ราคาที่ฟิลจริง - ราคาที่ตั้งใจส่ง| เป็นจุด (ราคาตลาดจริง ไม่ปรับ m_multiplier)
uint   LastFillLatencyMs       = 0;    // เวลาระหว่างส่งคำสั่งถึงได้ผลตอบกลับจากโบรกเกอร์ (ms) - ตัวแทนของ ping

// Latency Guard - นับไม้ที่ฟิลช้าติดกัน (latency > MaxLatencyMs) เพื่อพักเปิดไม้ใหม่ชั่วคราว
// เมื่อ execution แย่ต่อเนื่อง (กัน exposure เพิ่มตอนเน็ต/โบรกเกอร์มีปัญหา ซึ่งเป็นสาเหตุที่ทำให้บัญชีเบี่ยงเบนกันได้)
int      ConsecutiveBadLatencyCount = 0;
datetime LatencyGuardActiveUntil    = 0;

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

int      DayStartDay          = -1; // dt.day_of_year ของวันที่รีเซ็ต DailyRealizedProfit ไว้ล่าสุด
double   DailyRealizedProfit  = 0.0; // กำไรวันนี้แบบ "ปิดรอบแล้ว" เท่านั้น - บวกเพิ่มตอนบาสเก็ตปิดจริง ไม่ใช่ floating P/L สด
double   DayStartBalance      = 0.0; // ยอดเงินตอนเริ่มวันใหม่ (ก่อนบาสเก็ตของวันนั้นปิดเลย) - ฐานคำนวณ % ของ Daily Profit Goal / Daily Loss Limit
double   BasketStartBalance   = 0.0; // ยอดเงินตอนเริ่มบาสเก็ตนี้ (ก่อนไม้แรกฟิล) - ฐานคำนวณ % ของ Target Profit

// Handle สำหรับอินดิเคเตอร์ ATR / EMA / Multi-Timeframe EMA / Bollinger Bands
int      atrHandle       = INVALID_HANDLE;
int      emaHandle       = INVALID_HANDLE;
int      mtfEmaHandle    = INVALID_HANDLE;
int      bbHandle        = INVALID_HANDLE;
int      rsiHandle       = INVALID_HANDLE;

bool     IsTestingMode    = false; // true in Strategy Tester - skips slow/diagnostic-only code paths

datetime lastFilterBlockLogTime = 0; // throttles the "why didn't it open" filter diagnostic to once/minute
datetime lastGapLogTime         = 0; // throttles the GAP EXCEEDED re-anchor messages so a choppy market can't spam the Journal every tick
datetime lastSpreadLogTime      = 0; // throttles the SPREAD BLOCKED message - without this, a wide spread during a fast move silently blocks entries with zero Journal output, indistinguishable from a phantom filter
datetime lastTickTimeForGap     = 0; // เวลาของทิคก่อนหน้า ใช้แยก "เทรนด์วิ่งแรงต่อเนื่อง" ออกจาก "Gap จริง" (ราคาข้ามช่วงที่ไม่มีทิคเลย)
int      SecondsSinceLastTick   = 0; // อัปเดตครั้งเดียวต่อทิคใน OnTick() แล้วอ่านใช้ใน ExecuteGridLogic()

bool     NewsBlackoutActive     = false; // ผลตรวจข่าวล่าสุดที่ cache ไว้ - CalendarValueHistory() หนักเกินจะเรียกทุกทิค
datetime LastNewsCheckTime      = 0;     // เวลาที่ตรวจข่าวครั้งล่าสุด (ตรวจซ้ำทุก 60 วินาทีพอ เพราะหน้าต่างข่าวหน่วยเป็นนาทีอยู่แล้ว)

//====================== FUNCTION DECLARE ==========================//

bool IsTradingAllowedByTime();
bool IsNewsBlackout();
bool IsDailyLossLimitReached();
bool IsDailyGoalReached();
bool IsVolatilityTooLow();
bool IsVolatilityTooHigh();
bool CheckEMATrend(bool isBuy);
bool CheckMTFFilter(bool isBuy);
bool CheckRSIFilter(bool isBuy);
double GetCalculatedLotSize(int nextLevel);
double CalcEmergencySL(bool isBuy, double entryPrice, double point);
void RecordFillStats(uint sendTick, double intendedPrice, double filledPrice, double point);
double ComputeEffectiveThreshold(double dollarAmt, double pctAmt, double basisValue);
bool IsLatencyGuardActive();
void ApplyBasketBreakevenAndPartial(double currentProfit);
void CheckForceHedgeOnDD();
bool TryOpenForceHedgeOrder(string reasonTag, string logDetail);
void CheckForceHedgeOnTime();
void LogFilterBlockReason(bool isBuy);
void ExecuteGridLogic(int buyCount, int sellCount, double lastBuyPrice, double lastSellPrice);
void PlacePendingGridServer();
void CheckAndExecuteVirtualGrid(int buyCount, int sellCount, double lastBuyPrice, double lastSellPrice);
void DeleteAllPendingOrders();
void ClearEverythingAsync();
void DrawVisualTSLine(double tsValue);
void DeleteVisualTSLine();

void UpdateDrawdownTracker(int openPositions);

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

string GetUIString(string thText, string enText);

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

   // DIAGNOSTIC: log ทุกครั้งที่ฐานถูกคำนวณใหม่ ทั้งค่าเก่า/ask-bid ที่ใช้/ค่าใหม่ - เอาไว้ตามรอย
   // บั๊ก "ฐานค้างค่าเก่าหลังเปิด EA กลับมา" (ปัญหาฝั่งไลฟ์เท่านั้น) ที่ยังหาสาเหตุแน่ชัดไม่ได้จาก
   // static code review อย่างเดียว - ปิดตอน backtest เพราะฟังก์ชันนี้ถูกเรียกได้บ่อยมากตลอด 4 ปี
   // (ทุกครั้งที่ราคาห่างจากฐานเกิน 2 เท่าระยะกริดตอนพอร์ตว่าง) การ Print ถี่ๆ แบบนี้หน่วง backtest จริง
   if(!IsTestingMode)
   {
      PrintFormat("🧭 [BASE RECALC] Old=%.5f -> Ask=%.5f Bid=%.5f -> New=%.5f",
                  GridBasePrice, ask, bid, NormalizeDouble((ask + bid) / 2.0, _Digits));
   }

   GridBasePrice = NormalizeDouble((ask + bid) / 2.0, _Digits);
   GridBasePriceBuy  = GridBasePrice;
   GridBasePriceSell = GridBasePrice;
   BuyGapAnchor  = 0.0; // every call here means a fresh/flat grid, so any stale gap override is no longer relevant
   SellGapAnchor = 0.0;
   // เช่นเดียวกัน - ทุกครั้งที่ฟังก์ชันนี้ถูกเรียกคือพอร์ตว่างจริง (ยังไม่มีไม้แรกฟิล) ยอดเงิน ณ ตอนนี้
   // เลยเป็นฐาน "ก่อนเริ่มบาสเก็ต" ที่ถูกต้องเสมอสำหรับ Target Profit % (ดู ComputeEffectiveThreshold)
   BasketStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
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

   // GRID_VIRTUAL_LIMIT ราคาวิ่งกลับทิศ (Buy ไล่ราคาลง, Sell ไล่ราคาขึ้น) เลยต้องกลับขั้วเลือก
   // "สุดขั้ว"/"ใกล้ฐานสุด" ของแต่ละฝั่งด้วย - dir ตัวเดียวกับใน CheckAndExecuteVirtualGrid()
   int dir = (GridType == GRID_VIRTUAL_LIMIT) ? -1 : 1;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         buyCount++;
         bool takeLast  = (dir > 0) ? (openPrice > lastBuyPrice  || lastBuyPrice  == 0.0) : (openPrice < lastBuyPrice  || lastBuyPrice  == 0.0);
         bool takeFirst = (dir > 0) ? (openPrice < firstBuyPrice || firstBuyPrice == 0.0) : (openPrice > firstBuyPrice || firstBuyPrice == 0.0);
         if(takeLast)  lastBuyPrice  = openPrice;
         if(takeFirst) firstBuyPrice = openPrice;
      }
      else
      {
         sellCount++;
         bool takeLast  = (dir > 0) ? (openPrice < lastSellPrice  || lastSellPrice  == 0.0) : (openPrice > lastSellPrice  || lastSellPrice  == 0.0);
         bool takeFirst = (dir > 0) ? (openPrice > firstSellPrice || firstSellPrice == 0.0) : (openPrice < firstSellPrice || firstSellPrice == 0.0);
         if(takeLast)  lastSellPrice  = openPrice;
         if(takeFirst) firstSellPrice = openPrice;
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
      estimatedBase = NormalizeDouble(((firstBuyPrice - dir * distPrice) + (firstSellPrice + dir * distPrice)) / 2.0, _Digits);
   else if(buyCount > 0)
      estimatedBase = NormalizeDouble(firstBuyPrice - dir * distPrice, _Digits);
   else
      estimatedBase = NormalizeDouble(firstSellPrice + dir * distPrice, _Digits);

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
//| News Filter - เหมือน Time Filter ทุกอย่างเรื่องนโยบาย: บาสเก็ตที่เปิดอยู่แล้ว |
//| ยังจัดการ/ปิดตามปกติ (กำไรได้ ก็ปิดได้) แค่ "ห้ามเปิดไม้ใหม่" ช่วงใกล้ข่าวแรงเท่านั้น |
//| เช็คจากปฏิทินเศรษฐกิจของ MT5 (currency = สกุลเงินกำไรของสัญลักษณ์ เช่น USD    |
//| สำหรับ XAUUSD) ผลลัพธ์ cache ไว้ 60 วินาที เพราะ CalendarValueHistory()      |
//| หนักเกินจะเรียกทุกทิค และหน้าต่างข่าวหน่วยเป็นนาทีอยู่แล้วไม่ต้องเช็คถี่กว่านั้น |
//+------------------------------------------------------------------+
bool IsNewsBlackout()
{
   if(!UseNewsFilter) return false;

   if(LastNewsCheckTime > 0 && TimeCurrent() - LastNewsCheckTime < 60) return NewsBlackoutActive;
   LastNewsCheckTime = TimeCurrent();

   string curr = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   datetime winStart = TimeCurrent() - NewsMinutesAfter * 60;
   datetime winEnd   = TimeCurrent() + NewsMinutesBefore * 60;

   MqlCalendarValue values[];
   if(CalendarValueHistory(values, winStart, winEnd, NULL, curr) <= 0)
   {
      NewsBlackoutActive = false;
      return false;
   }

   NewsBlackoutActive = false;
   for(int i = 0; i < ArraySize(values); i++)
   {
      MqlCalendarEvent evt;
      if(!CalendarEventById(values[i].event_id, evt)) continue;
      if(evt.importance < NewsMinImportance) continue;

      NewsBlackoutActive = true;
      break;
   }

   return NewsBlackoutActive;
}

//+------------------------------------------------------------------+
//| Daily Loss Limit - นับจากกำไร/ขาดทุนที่ "ปิดรอบแล้วจริง" ของวันนี้เท่านั้น |
//| (DailyRealizedProfit ตัวเดียวกับที่การ์ด "ผลงานวันนี้" ใช้แสดง) ไม่รวม    |
//| floating loss ของบาสเก็ตที่ยังเปิดค้างอยู่ - เพราะ Max DD Stop / Total    |
//| DD Guard / Emergency SL คือกลุ่มที่ดูแลบาสเก็ตเปิดค้างอยู่แล้ว ตัวนี้ป้องกัน  |
//| คนละเคส: กันเปิด/ปิดบาสเก็ตแพ้ซ้ำๆ สะสมทั้งวันแทน เช็ค day rollover ในตัวเอง|
//| ด้วย เผื่อ ClearEverythingAsync ยังไม่มีโอกาสเช็คก่อนในวันใหม่ (ยังไม่มี      |
//| บาสเก็ตไหนปิดตั้งแต่ข้ามวันมา ฯลฯ)                                      |
//+------------------------------------------------------------------+
bool IsDailyLossLimitReached()
{
   if(!UseDailyLossLimit) return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != DayStartDay)
   {
      DayStartDay         = dt.day_of_year;
      DailyRealizedProfit = 0.0;
      DayStartBalance      = AccountInfoDouble(ACCOUNT_BALANCE);
   }

   double effLossLimit = ComputeEffectiveThreshold(DailyLossLimit, DailyLossLimitPct, DayStartBalance);
   return (effLossLimit > 0 && DailyRealizedProfit <= -MathAbs(effLossLimit));
}

//+------------------------------------------------------------------+
//| Daily Goal Stop - ฝั่งตรงข้ามของ Daily Loss Limit ด้านบน: พอกำไรที่ปิด    |
//| รอบแล้วจริงของวันนี้ (DailyRealizedProfit ตัวเดียวกับเกจ "ผลงานวันนี้")   |
//| ถึง DailyProfitGoal ก็หยุดเปิดไม้ใหม่แค่วันนั้น เดิม DailyProfitGoal ใช้   |
//| แสดงผลในเกจอย่างเดียว ไม่เคยบังคับหยุดจริง - ตัวนี้ต้องเปิด UseDailyGoalStop |
//| เองถึงจะบังคับ ไม่งั้นพฤติกรรมเดิม (โชว์เกจเฉยๆ ไม่หยุด) ยังเหมือนเดิมทุก   |
//| ประการ เช็ค day rollover ในตัวเองเหมือน Daily Loss Limit                |
//+------------------------------------------------------------------+
bool IsDailyGoalReached()
{
   if(!UseDailyGoalStop) return false;
   if(DailyProfitGoal <= 0 && DailyProfitGoalPct <= 0) return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != DayStartDay)
   {
      DayStartDay         = dt.day_of_year;
      DailyRealizedProfit = 0.0;
      DayStartBalance      = AccountInfoDouble(ACCOUNT_BALANCE);
   }

   double effGoal = ComputeEffectiveThreshold(DailyProfitGoal, DailyProfitGoalPct, DayStartBalance);
   return (effGoal > 0 && DailyRealizedProfit >= effGoal);
}

//+------------------------------------------------------------------+
//| Min Volatility Filter - ถ้าตลาดนิ่งเกินไป (ระยะ ATR/BB/Fixed ที่คำนวณ  |
//| ได้ ณ ตอนนี้ ต่ำกว่า MinVolatilityPoints ที่ตั้งไว้) ห้ามเปิดไม้ใหม่ทั้งหมด  |
//| เหมือน Time Filter/News Filter/Daily Loss Limit - ไม่แตะบาสเก็ตที่เปิด   |
//| อยู่แล้ว เรียก GetDynamicGridDistance() สดทุกครั้ง (ไม่ใช้ CachedGridDistance |
//| ที่อาจค้างจากตอนบาสเก็ตเริ่ม) เพื่อให้ได้ค่าความผันผวนปัจจุบันจริงๆ         |
//+------------------------------------------------------------------+
bool IsVolatilityTooLow()
{
   if(!UseMinVolatilityFilter) return false;
   return (GetDynamicGridDistance() < MinVolatilityPoints);
}

//+------------------------------------------------------------------+
//| Max Volatility Filter - ฝั่งตรงข้ามของ Min Volatility Filter ด้านบน:    |
//| ถ้าตลาดผันผวนแรงเกินไป (ระยะ ATR/BB/Fixed ที่คำนวณได้ ณ ตอนนี้ สูงกว่า    |
//| MaxVolatilityPoints ที่ตั้งไว้ เช่นช่วงข่าวแรง/ราคาวิ่งพรวด) ห้ามเปิดไม้ใหม่ |
//| ทั้งหมดเช่นกัน - กันเปิดไม้ระยะห่างกว้างผิดปกติที่ risk/lot คำนวณไว้ไม่รองรับ |
//+------------------------------------------------------------------+
bool IsVolatilityTooHigh()
{
   if(!UseMaxVolatilityFilter) return false;
   return (GetDynamicGridDistance() > MaxVolatilityPoints);
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
//| RSI Confirmation Filter - Virtual Limit mode only                |
//| Limit mode buys dips / sells rallies (mean-reversion), so it's   |
//| the direction that actually benefits from an oversold/overbought |
//| confirmation before committing. Breakout/Pending entries chase   |
//| momentum instead, where the same RSI reading would mean the      |
//| opposite thing - so this filter is a no-op outside Virtual Limit.|
//+------------------------------------------------------------------+
bool CheckRSIFilter(bool isBuy)
{
   if(!UseRSIFilter || rsiHandle == INVALID_HANDLE) return true;
   if(GridType != GRID_VIRTUAL_LIMIT) return true;

   double rsiValues[];
   ArraySetAsSeries(rsiValues, true);
   if(CopyBuffer(rsiHandle, 0, 1, 1, rsiValues) <= 0) return true;

   if(isBuy) return (rsiValues[0] <= RSI_Oversold);
   else      return (rsiValues[0] >= RSI_Overbought);
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
   if(UseRSIFilter && !CheckRSIFilter(isBuy)) blockers += "RSI ";

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
//| Execution Quality Tracking                                       |
//| เรียกทันทีหลัง OrderSend() สำเร็จทุกจุด (grid entry + Force Hedge) -   |
//| sendTick มาจาก GetTickCount() ที่จับไว้ "ก่อน" เรียก OrderSend() ที่ตัว   |
//| caller เอง เพราะ OrderSend() เป็น synchronous call ระยะเวลาที่เสียไปตรง  |
//| นี้คือเวลาที่เทอร์มินัลรอผลตอบกลับจากโบรกเกอร์จริง ใช้แทนค่า ping ได้       |
//| ตรงไปตรงมา - filledPrice มาจาก result.price ซึ่ง broker เป็นคนกรอกให้     |
//+------------------------------------------------------------------+
void RecordFillStats(uint sendTick, double intendedPrice, double filledPrice, double point)
{
   if(point <= 0) return;
   LastFillLatencyMs      = GetTickCount() - sendTick;
   LastFillSlippagePoints = MathAbs(filledPrice - intendedPrice) / point;

   if(!UseLatencyGuard) return;

   if(LastFillLatencyMs > (uint)MaxLatencyMs)
   {
      ConsecutiveBadLatencyCount++;
      if(ConsecutiveBadLatencyCount >= LatencyGuardTriggerCount)
      {
         LatencyGuardActiveUntil    = TimeCurrent() + LatencyGuardPauseSeconds;
         ConsecutiveBadLatencyCount = 0;
         PrintFormat("🐢 [LATENCY GUARD] %d fills in a row over %dms - pausing new entries for %ds.",
                     LatencyGuardTriggerCount, MaxLatencyMs, LatencyGuardPauseSeconds);
      }
   }
   else
   {
      ConsecutiveBadLatencyCount = 0;
   }
}

//+------------------------------------------------------------------+
//| ค่าเดียวที่ใช้ตัดสินใจ "ถึงเป้า/เกินเพดาน" เมื่อมีทั้งเวอร์ชัน $ และ % เปิดพร้อมกัน -   |
//| คืนค่าที่ "น้อยกว่า" เสมอ เพราะปริมาณที่เฝ้าดู (กำไรสะสม/ขาดทุนสะสม) วิ่งทางเดียว    |
//| เข้าหาทั้งสองเพดานพร้อมกัน ตัวที่เล็กกว่าย่อมถึงก่อนเสมอ - ใช้ได้ทั้ง Target Profit    |
//| (basisValue = BasketStartBalance) และ Daily Goal/Loss (basisValue = DayStartBalance) |
//| ค่า 0 หมายถึง "ปิด" ตัวนั้น - ถ้าปิดทั้งคู่ ผลลัพธ์คือ dollarAmt (0 เช่นกัน = ปิดจริง)     |
//+------------------------------------------------------------------+
double ComputeEffectiveThreshold(double dollarAmt, double pctAmt, double basisValue)
{
   double pctDollar = (pctAmt > 0 && basisValue > 0) ? basisValue * pctAmt / 100.0 : 0.0;
   if(dollarAmt > 0 && pctDollar > 0) return MathMin(dollarAmt, pctDollar);
   if(pctDollar > 0) return pctDollar;
   return dollarAmt;
}

//+------------------------------------------------------------------+
//| Latency Guard - เมื่อไม้ฟิลช้าติดกันครบ LatencyGuardTriggerCount ครั้ง        |
//| (ตั้งใน RecordFillStats) จะ block การเปิดไม้ใหม่แบบ unconditional เหมือน    |
//| News Filter / Daily Loss Limit คือ block แม้มี basket เปิดค้างอยู่ เพราะ    |
//| จุดประสงค์คือหยุดเพิ่ม exposure ตอน execution แย่ ไม่ใช่แค่กันการเปิดบาสเก็ตใหม่   |
//+------------------------------------------------------------------+
bool IsLatencyGuardActive()
{
   if(!UseLatencyGuard) return false;
   return (TimeCurrent() < LatencyGuardActiveUntil);
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

   if(UseMaxLotCap && MaxLotCap > 0 && lot > MaxLotCap) lot = MaxLotCap;

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

   if(UseMaxLotCap && MaxLotCap > 0 && lot > MaxLotCap) lot = MaxLotCap;

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

   uint sendTick = GetTickCount();
   if(OrderSend(request, result))
   {
      LastOrderSentTime = TimeCurrent();
      RecordFillStats(sendTick, request.price, result.price, point);
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
   PersistSet("DayStartBalance",     DayStartBalance);
   PersistSet("BasketStartBalance",  BasketStartBalance);
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

   // Demo Expiry Lock: เช็คทั้งบัญชีจริง/เดโม/Strategy Tester เหมือนกันหมด (ไม่ยกเว้น
   // IsTestingMode แบบ Backtest-only lock เพราะไฟล์นี้มีไว้ให้ลูกค้าทดลองรัน ไม่ใช่ไฟล์
   // สำหรับนักพัฒนาทดสอบกลยุทธ์) ตรวจแค่ตอน OnInit() ก็พอ เพราะ EA ไม่ได้รันข้ามหลายวันโดย
   // ไม่มีการ reload เทอร์มินัล/ชาร์ตเลยจริงๆ ในทางปฏิบัติ
   if(TimeCurrent() > DemoExpiryDate)
   {
      string expiredMsg = StringFormat("QuantixPro EA (Demo): This demo version expired on %s. Please contact the developer for the full version.", TimeToString(DemoExpiryDate, TIME_DATE));
      Print("❌ [DEMO EXPIRED] ", expiredMsg);
      Alert(expiredMsg);
      return(INIT_FAILED);
   }
   else
   {
      Alert(StringFormat("QuantixPro EA (Demo): This demo version is usable until %s.", TimeToString(DemoExpiryDate, TIME_DATE)));
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
   DayStartBalance      = PersistGet("DayStartBalance", currentBalanceNow);
   BasketStartBalance   = PersistGet("BasketStartBalance", currentBalanceNow);
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

   if(UseRSIFilter)
   {
      rsiHandle = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);
      if(rsiHandle == INVALID_HANDLE)
      {
         Print("Failed to create RSI indicator handle.");
         return(INIT_FAILED);
      }
   }

   // DIAGNOSTIC: บอกเหตุผลที่ OnInit() ถูกเรียกครั้งนี้ (REASON_REMOVE/CHARTCLOSE/RECOMPILE/
   // PARAMETERS/TEMPLATE/... ) กับค่า GridBasePrice ก่อนจะ reconcile - เอาไว้หาสาเหตุบั๊ก
   // "ฐานค้างค่าเก่า" ตอนเปิด EA กลับมาหลังปิดกราฟ/สลับ EA (ปัญหาฝั่งไลฟ์เท่านั้น) - ปิดตอน backtest
   // เพราะ Optimization รัน OnInit() ได้เป็นพันๆ รอบ
   if(!IsTestingMode)
   {
      PrintFormat("🚀 [ONINIT] UninitReason=%d GridType=%d GridBasePrice(before)=%.5f",
                  UninitializeReason(), GridType, GridBasePrice);
   }

   if(GridType == GRID_VIRTUAL || GridType == GRID_VIRTUAL_LIMIT) ReconcileGridStateOnInit();
   else RecalculateBasePrice();

   if(GridType == GRID_VIRTUAL || GridType == GRID_VIRTUAL_LIMIT)
   {
      DeleteAllPendingOrders();
   }

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PersistAllStats(); // เซฟรอบสุดท้ายตอนถอด/รีสตาร์ท EA กันพลาดช่วงระหว่างรอบ periodic save
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(emaHandle != INVALID_HANDLE) IndicatorRelease(emaHandle);
   if(mtfEmaHandle != INVALID_HANDLE) IndicatorRelease(mtfEmaHandle);
   if(bbHandle != INVALID_HANDLE) IndicatorRelease(bbHandle);
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   DeleteVisualTSLine();
}

//+------------------------------------------------------------------+
//| Trade Transaction Event                                          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result)
{
   // Transaction Hook (Reserved)
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
   int    buyCount           = 0;
   int    sellCount          = 0;
   double lastBuyPrice       = 0.0;
   double lastSellPrice      = 0.0;

   // 1. Count Open Positions & Profit - PERF: เก็บ buy/sell count + ราคาไม้ล่าสุดแต่ละฝั่งในสแกน
   // เดียวกันนี้เลย (เดิม CheckAndExecuteVirtualGrid() สแกน PositionsTotal() ซ้ำเองอีกรอบทุก tick
   // ทั้งที่เป็นข้อมูลชุดเดียวกัน) ส่งต่อเป็น parameter แทน ลดจำนวนสแกนซ้ำต่อ tick ลงครึ่งหนึ่ง
   //
   // GRID_VIRTUAL_LIMIT flips which extreme counts as "last" price: breakout mode
   // (default) climbs, so the highest Buy fill / lowest Sell fill is the anchor to
   // extend further; limit mode falls to trigger Buy / rises to trigger Sell, so it's
   // the opposite extreme - lowest Buy fill / highest Sell fill.
   bool isVirtualLimitMode = (GridType == GRID_VIRTUAL_LIMIT);
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      openPositions++;
      currentProfit += PositionGetDouble(POSITION_PROFIT);
      currentProfit += PositionGetDouble(POSITION_SWAP);

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(posType == POSITION_TYPE_BUY)
      {
         buyCount++;
         bool takeBuy = isVirtualLimitMode ? (openPrice < lastBuyPrice || lastBuyPrice == 0.0)
                                            : (openPrice > lastBuyPrice || lastBuyPrice == 0.0);
         if(takeBuy) lastBuyPrice = openPrice;
      }
      else
      {
         sellCount++;
         bool takeSell = isVirtualLimitMode ? (openPrice > lastSellPrice || lastSellPrice == 0.0)
                                             : (openPrice < lastSellPrice || lastSellPrice == 0.0);
         if(takeSell) lastSellPrice = openPrice;
      }
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

   // Virtual Limit mode can run its own Target Profit / Trailing Distance,
   // independent of Breakout's - mean-reversion baskets often want a tighter/
   // wider profit target than trend-following ones. Falls back to the shared
   // TargetProfit/TrailingStopUSD whenever the override is off or GridType
   // isn't Virtual Limit.
   bool   useLimitTarget    = (GridType == GRID_VIRTUAL_LIMIT && UseLimitModeTarget);
   // TargetProfitPct (ถ้าเปิด) ใช้ยอดเงินก่อนเริ่มบาสเก็ตนี้เป็นฐาน - ไม่ใช้กับโหมด Virtual Limit
   // override เพราะ LimitModeTargetProfit เป็นค่าเฉพาะโหมดอยู่แล้ว ไม่ควรมีเวอร์ชัน % ซ้อนอีกชั้น
   double effTargetProfit   = useLimitTarget ? LimitModeTargetProfit
                                              : ComputeEffectiveThreshold(TargetProfit, TargetProfitPct, BasketStartBalance);
   double effTrailingStopUSD = useLimitTarget ? LimitModeTrailingStopUSD : TrailingStopUSD;

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
      if(MaxBasketProfit >= effTargetProfit || currentProfit >= effTargetProfit)
      {
         if(currentProfit > MaxBasketProfit)
         {
            MaxBasketProfit = currentProfit;
         }

         double tsTriggerLine = MaxBasketProfit - effTrailingStopUSD;

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
   bool timeAllowed      = IsTradingAllowedByTime();
   bool newsBlocked      = IsNewsBlackout();
   bool dailyLossBlocked = IsDailyLossLimitReached();
   bool latencyBlocked   = IsLatencyGuardActive();
   bool dailyGoalReached = IsDailyGoalReached();
   bool lowVolatility    = IsVolatilityTooLow();
   bool highVolatility   = IsVolatilityTooHigh();

   // News Filter / Daily Loss Limit ห้ามเปิดไม้ใหม่เด็ดขาด ไม่ว่ามีบาสเก็ตเปิดค้างอยู่หรือไม่ (เป็นกลไก
   // ป้องกันความเสี่ยง ต่อไม้เพิ่มระหว่างที่ทริกเกอร์อยู่ขัดกับจุดประสงค์ของมันเอง) - แต่ Time Filter /
   // Daily Goal Stop / Min & Max Volatility Filter ต่างออกไป: ถ้ามีบาสเก็ตเปิดค้างอยู่แล้ว (openPositions
   // > 0) ต้องปล่อยให้ grid เปิดไม้ต่อตามปกติ ไม่งั้นบาสเก็ตจะค้างครึ่งๆ กลางๆ ขาดชั้นแก้ไม้ที่ควรมี (เสี่ยงกว่าเดิม)
   // - ทั้งสามเป็นตัวกรอง "จังหวะเริ่มไม้ใหม่" ไม่ใช่ตัวจำกัดความเสี่ยงแบบ News/Daily Loss เลยไม่ควรมาห้าม
   // บาสเก็ตที่เริ่มไปแล้วจากเปิดไม้แก้ต่อ นอกเวลาเทรด/ถึงเป้ากำไรวันนี้/ตลาดนิ่งหรือแรงเกินไปแปลว่า "ห้าม
   // เริ่มบาสเก็ตใหม่" เท่านั้น ไม่ใช่ "ทิ้งบาสเก็ตที่กำลังทำอยู่ให้ค้าง"
   bool timeBlocksEntry      = !timeAllowed     && (openPositions == 0);
   bool dailyGoalBlocksEntry = dailyGoalReached && (openPositions == 0);
   bool lowVolBlocksEntry    = lowVolatility    && (openPositions == 0);
   bool highVolBlocksEntry   = highVolatility   && (openPositions == 0);
   if(!timeBlocksEntry && !newsBlocked && !dailyLossBlocked && !latencyBlocked && !dailyGoalBlocksEntry && !lowVolBlocksEntry && !highVolBlocksEntry)
   {
      if(!IsClosingState && !equityLocked && !TradingHalted && (MaxBasketProfit < effTargetProfit) && (TimeCurrent() - LastCloseAllTime >= 3))
      {
         ExecuteGridLogic(buyCount, sellCount, lastBuyPrice, lastSellPrice);
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
            string blockReason = timeBlocksEntry ? "Outside trading hours" : (newsBlocked ? "News blackout window" : (dailyLossBlocked ? "Daily loss limit reached" : (latencyBlocked ? "Latency Guard active (slow execution)" : (dailyGoalBlocksEntry ? "Daily goal reached" : (lowVolBlocksEntry ? "Volatility too low" : "Volatility too high")))));
            PrintFormat("⏰ [ENTRY BLOCKED] %s and in profit -> Auto Closing all active positions...", blockReason);
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
   UpdateDrawdownTracker(openPositions);
   CheckForceHedgeOnDD();
   CheckForceHedgeOnTime();
}

//+------------------------------------------------------------------+
//| Update Max Drawdown Calculation                                 |
//+------------------------------------------------------------------+
void UpdateDrawdownTracker(int openPositions)
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double currentEquity  = AccountInfoDouble(ACCOUNT_EQUITY);

   // FIXED: PeakBalanceForDD เดิมเป็น all-time-high ของยอดเงิน ไม่เคยขยับลงมาเทียบกับจุดเริ่ม
   // บาสเก็ตปัจจุบันเลย (นอกจากตอน Max DD Stop ยิง) ถ้าบาสเก็ตก่อนหน้าปิดกำไรแต่ไม่ทันไล่ทันพีคเก่า
   // (เช่น บัญชีเคยขาดทุนสะสมจากหลายรอบก่อนหน้า) บาสเก็ตใหม่จะเริ่มต้นด้วย DD% ที่ไม่ใช่ศูนย์ทันที
   // ทำให้ Force Hedge on DD (และ Max DD Stop) ยิงทันทีทั้งที่บาสเก็ตใหม่ยังไม่เกิดขาดทุนอะไรเลย -
   // ตอนพอร์ตว่างสนิท (ไม่มีไม้เปิดเลย) ปักหมุด peak ใหม่เท่ากับยอดเงินปัจจุบันเสมอ เพื่อให้ DD% ที่ใช้
   // คำนวณ Force Hedge/Max DD Stop วัดจาก "จุดเริ่มบาสเก็ตนี้" เท่านั้น ไม่ลากยาวข้ามหลายบาสเก็ต
   // (ตัวที่ตั้งใจให้สะสมข้ามบาสเก็ตจริงๆ คือ AccountPeakBalanceAllTime ของ Total DD Guard ด้านล่าง
   // ไม่ใช่ตัวนี้ - ไม่แตะ AccountPeakBalanceAllTime เลย)
   if(openPositions == 0) PeakBalanceForDD = currentBalance;

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
   // Virtual Limit mode can run on its own fixed distance, independent of the
   // Breakout mode's Fixed/ATR/BB settings above - lets the two modes be tuned
   // separately instead of sharing one distance config that has to compromise
   // between trend-following (Breakout) and counter-trend (Limit) spacing needs.
   if(GridType == GRID_VIRTUAL_LIMIT && UseLimitModeDistance)
      return LimitModeDistancePoints * m_multiplier;

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
void ExecuteGridLogic(int buyCount, int sellCount, double lastBuyPrice, double lastSellPrice)
{
   if(GridType == GRID_PENDING)
   {
      PlacePendingGridServer();
   }
   else
   {
      CheckAndExecuteVirtualGrid(buyCount, sellCount, lastBuyPrice, lastSellPrice);
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
// PERF: buyCount/sellCount/lastBuyPrice/lastSellPrice ถูกส่งเข้ามาจาก scan เดียวที่ OnTick() ทำไว้แล้ว
// ("1. Count Open Positions & Profit") แทนที่จะสแกน PositionsTotal() ซ้ำเองอีกรอบทุก tick เหมือนเดิม -
// ฟังก์ชันนี้ถูกเรียกทุก tick ที่ grid ยังไม่เต็ม เลยลด redundant scan ได้เยอะโดยเฉพาะ backtest แบบ
// "every tick" ที่มีจำนวน tick เป็นล้านๆ ครั้งตลอดการรัน
void CheckAndExecuteVirtualGrid(int buyCount, int sellCount, double lastBuyPrice, double lastSellPrice)
{
   if(IsClosingState) return;
   if(TimeCurrent() - LastOrderSentTime < 1) return;

   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   int stepDistance = (CachedGridDistance > 0) ? CachedGridDistance : GetDynamicGridDistance();

   // UseAdaptiveATRGrid: แต่ละฝั่งใช้ระยะของตัวเอง (คำนวณสดจาก ATR ตอนฝั่งนั้น fill ล่าสุด)
   // แทนที่จะใช้ stepDistance ตัวเดียวร่วมกันทั้งสองฝั่ง - ฝั่งที่ยังไม่ fill จะไม่ถูกกระทบเลย
   int buyStepDistance  = IsPerSideDistanceActive() ? ((BuyGridDistance  > 0) ? BuyGridDistance  : GetDynamicGridDistance()) : stepDistance;
   int sellStepDistance = IsPerSideDistanceActive() ? ((SellGridDistance > 0) ? SellGridDistance : GetDynamicGridDistance()) : stepDistance;

   // GRID_VIRTUAL_LIMIT flips the trigger direction for both sides: Buy enters on
   // price falling to base-distance (Buy Limit style) instead of rising to
   // base+distance (Buy Stop / breakout style, the GRID_VIRTUAL default), and Sell
   // mirrors it (enters on price rising to base+distance instead of falling to
   // base-distance). dir=-1 flips every target/gap formula below for both sides at once.
   int dir = (GridType == GRID_VIRTUAL_LIMIT) ? -1 : 1;

   MqlTradeRequest request;
   MqlTradeResult  result;
   ENUM_ORDER_TYPE_FILLING fillMode = GetBestFillingMode();

   int adjGapLimit = MaxAllowedGapPoints * m_multiplier;
   int adjSpread   = MaxSpreadAllowed * m_multiplier;

   bool canBuyFilters  = CheckEMATrend(true)  && CheckMTFFilter(true)  && CheckRSIFilter(true);
   bool canSellFilters = CheckEMATrend(false) && CheckMTFFilter(false) && CheckRSIFilter(false);

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
      // survives across ticks for the buyCount>0 case. Breakout mode (dir=1) wants
      // the HIGHER of the two (price only moves the target up); Limit mode (dir=-1)
      // wants the LOWER of the two, and must ignore BuyGapAnchor while it's unset
      // (0.0) or MathMin would wrongly latch onto it.
      double effectiveLastBuy = (dir > 0)
         ? MathMax(lastBuyPrice, BuyGapAnchor)
         : ((BuyGapAnchor > 0 && BuyGapAnchor < lastBuyPrice) ? BuyGapAnchor : lastBuyPrice);

      double targetPrice = 0.0;
      if(buyCount == 0)
         targetPrice = NormalizeDouble(GridBasePriceBuy + dir * (buyStepDistance * point), _Digits);
      else
         targetPrice = NormalizeDouble(effectiveLastBuy + dir * (buyStepDistance * point), _Digits);

      // Signed so it stays "positive = triggered/overshot in the intended entry
      // direction" for both modes: breakout (dir=1) wants ask above target,
      // limit (dir=-1) wants ask below target.
      double diffPoints = dir * (ask - targetPrice) / point;

      // เป็น Gap "จริง" ก็ต่อเมื่อระยะเกิน adjGapLimit *และ* ไม่มีทิคเข้ามาเลยนานเกิน
      // GapDetectionSeconds (เช่น ข้ามคืน/สุดสัปดาห์) - ถ้าทิคยังเข้ามาต่อเนื่อง (แค่ตลาดวิ่งแรง)
      // จะไม่ถือเป็น Gap เลย แล้วเปิดไม้ต่อได้ตามปกติแม้ระยะจะไกลเกิน adjGapLimit ก็ตาม เพราะไม่งั้น
      // เทรนด์แรงต่อเนื่องจะโดน re-anchor วนไปเรื่อยๆ ทุกทิคโดยไม่มีวันเปิดไม้ต่อได้เลย
      bool isGenuineGap = (UseGapProtection && diffPoints > adjGapLimit && SecondsSinceLastTick >= GapDetectionSeconds);

      bool canSendBuy = (diffPoints >= 0) && !isGenuineGap;

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

            uint sendTick = GetTickCount();
            if(OrderSend(request, result))
            {
               LastOrderSentTime = TimeCurrent();
               RecordFillStats(sendTick, ask, result.price, point);
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
         // sticks, and effectiveLastBuy (above) picks it up next tick.
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
      // persistent override for the sellCount>0 case. Breakout mode (dir=1) wants
      // the LOWER of the two (Sell targets move down); Limit mode (dir=-1) wants
      // the HIGHER, and can use plain MathMax since an unset anchor (0.0) always
      // loses to a real price there.
      double effectiveLastSell = (dir > 0)
         ? ((SellGapAnchor > 0 && SellGapAnchor < lastSellPrice) ? SellGapAnchor : lastSellPrice)
         : MathMax(lastSellPrice, SellGapAnchor);

      double targetPrice = 0.0;
      if(sellCount == 0)
         targetPrice = NormalizeDouble(GridBasePriceSell - dir * (sellStepDistance * point), _Digits);
      else
         targetPrice = NormalizeDouble(effectiveLastSell - dir * (sellStepDistance * point), _Digits);

      // Signed so it stays "positive = triggered/overshot in the intended entry
      // direction" for both modes: breakout (dir=1) wants bid below target,
      // limit (dir=-1) wants bid above target.
      double diffPoints = dir * (targetPrice - bid) / point;

      // เป็น Gap "จริง" ก็ต่อเมื่อระยะเกิน adjGapLimit *และ* ไม่มีทิคเข้ามาเลยนานเกิน
      // GapDetectionSeconds - เหตุผลเดียวกับฝั่ง Buy ด้านบน
      bool isGenuineGap = (UseGapProtection && diffPoints > adjGapLimit && SecondsSinceLastTick >= GapDetectionSeconds);

      bool canSendSell = (diffPoints >= 0) && !isGenuineGap;

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

            uint sendTick = GetTickCount();
            if(OrderSend(request, result))
            {
               LastOrderSentTime = TimeCurrent();
               RecordFillStats(sendTick, bid, result.price, point);
               // Symmetric to the Buy-fills-first case above - same Per-Side ATR gate,
               // same reasoning: outside that mode the base must stay put.
               if(IsPerSideDistanceActive() && buyCount == 0) GridBasePriceBuy = bid;
               SellGapAnchor = 0.0; // lastSellPrice now reflects this real fill, override no longer needed
               // ฝั่ง Sell fill แล้ว - คำนวณระยะ Sell รอบถัดไปใหม่จาก ATR สด ณ ตอนนี้
               // ฝั่ง Buy ที่ยังไม่ fill ไม่ถูกแตะเลย ยังรอที่เป้าเดิมต่อไป
               if(IsPerSideDistanceActive()) SellGridDistance = GetDynamicGridDistance();
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

   // เก็บ ticket ของโพซิชั่นในบาสเก็ตไว้ก่อนปิดจริง (ต้องอ่านตอนโพซิชั่นยังเปิดอยู่ ที่หลังปิดแล้ว
   // PositionGetTicket จะดึงไม่ได้อีก) เอาไว้ย้อนไปรวมยอดจาก deal history จริงหลังปิดเสร็จ แทนการใช้
   // POSITION_PROFIT+SWAP สดตอนนี้ตรงๆ เพราะ PositionGetDouble ไม่มีค่าคอมมิชชั่นให้เลย (คอมมิชชั่นอยู่ใน
   // deal history เท่านั้น) ถ้าใช้ snapshot สดจะได้ตัวเลขกำไรสูงกว่าความจริงเท่ากับค่าคอมที่โบรกเกอร์หักไป
   int   statsPosCount = 0;
   ulong statsTickets[];
   ArrayResize(statsTickets, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      int tn = ArraySize(statsTickets);
      ArrayResize(statsTickets, tn + 1);
      statsTickets[tn] = ticket;
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

   // รวมยอดกำไรจริงจาก deal history ของแต่ละ ticket ที่เก็บไว้ตอนต้นฟังก์ชัน (ทำได้ตอนนี้เพราะโพซิชั่น
   // ปิดจริงแล้วตาม while loop ด้านบน) รวม PROFIT+SWAP+COMMISSION ของทุก deal ในแต่ละ position
   // (deal เปิด + deal ปิด) เพื่อให้ตัวเลข "กำไรวันนี้" ตรงกับที่ MT5 คิดจริง ไม่สูงเกินจริงเพราะขาดค่าคอม
   double statsSnapshotProfit = 0.0;
   for(int ti = 0; ti < ArraySize(statsTickets); ti++)
   {
      if(!HistorySelectByPosition(statsTickets[ti])) continue;
      int dealsCount = HistoryDealsTotal();
      for(int di = 0; di < dealsCount; di++)
      {
         ulong dealTicket = HistoryDealGetTicket(di);
         if(dealTicket == 0) continue;
         statsSnapshotProfit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                               + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                               + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      }
   }

   // บันทึกสถิติจาก ticket ที่เก็บไว้ตอนต้นฟังก์ชัน - นับเป็น "บาสเก็ตที่ปิดแล้ว" เฉพาะตอนที่มีไม้จริงๆ ให้ปิด
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
         DayStartBalance      = AccountInfoDouble(ACCOUNT_BALANCE);
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

      PersistAllStats(); // เซฟทันทีตอนบาสเก็ตปิดจริง กันพลาดถ้า EA ถูกปิดก่อนจะมีจังหวะเซฟรอบถัดไป
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

//+------------------------------------------------------------------+
//| Bilingual (TH/EN) message helper - used by Print()/Alert() calls |
//| throughout the EA for the Journal/log messages.                  |
//+------------------------------------------------------------------+
string GetUIString(string thText, string enText)
{
   return (Language == LNG_TH) ? thText : enText;
}

