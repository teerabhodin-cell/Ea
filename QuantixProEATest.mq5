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
input group "===== 1. Trading Time & Language (เวลาเทรด & ภาษา) ====="
input ENUM_LANGUAGE Language = LNG_TH; // Select Language ( default: Thai )
input bool    UseTimer         = false;   // Enable Time Filter (เปิดใช้งานระบบคุมเวลา)
input int     StartHour        = 2;       // Start trading hour, Server Time (เวลาเริ่มทำงาน ตามเวลา Server)
input int     StartMinute      = 0;
input int     EndHour          = 23;      // Stop trading hour, Server Time (เวลาหยุดทำงาน ตามเวลา Server)
input int     EndMinute        = 0;

input group "===== 2. Main Grid (Grid หลัก) ====="
input ENUM_GRID_TYPE GridType       = GRID_VIRTUAL; // Select Grid type: Virtual or Pending (เลือกรูปแบบ Grid)
input double BaseLot                = 0.01;
input double LotMultiplier          = 2.0;
input int    TotalLevels            = 10;      // Levels per side (10 Buy Stop + 10 Sell Stop) (จำนวนชั้นต่อฝั่ง)
input bool   UseATRDistance         = false;   // Use ATR-based grid distance (เปิดใช้ระยะ Grid ตามค่า ATR)
input int    ATR_Period             = 14;      // ATR calculation period (รอบคำนวณ ATR)
input double ATR_Multiplier         = 1.5;     // ATR multiplier, e.g. 1.5x ATR (ตัวคูณ ATR)
input bool   UseAdaptiveATRGrid     = false;   // Independent per-side (Buy/Sell) grid distance, recalculated fresh from live ATR each time that side fills - the still-pending side is untouched (requires UseATRDistance=true to have any effect) (แยกระยะ Grid เป็นอิสระต่อฝั่ง คำนวณจาก ATR สดทุกครั้งที่ฝั่งนั้น fill ต้องเปิด UseATRDistance ด้วย)
input int    DistancePoints         = 300;     // Fixed distance in points (used when UseATRDistance is off) (ระยะห่าง Fixed Points ใช้กรณีปิด UseATRDistance)
input ulong  MagicNumber            = 112233;

input group "===== 3. Target Profit & Trailing Stop (เป้ากำไร & Trailing Stop) ====="
input double TargetProfit        = 1.0;    // Minimum Profit ($) to activate Trailing (กำไรขั้นต่ำที่จะเริ่มเทรลลิ่ง)
input double TrailingStopUSD     = 0.5;    // Trailing Distance ($) (ระยะห่าง Trailing)

input group "===== 4. Trend Filters: EMA / MTF (ตัวกรองเทรนด์) ====="
input bool   UseEMAFilter           = false;   // Enable EMA trend filter (เปิดใช้ตัวกรองเทรนด์ EMA)
input int    EMA_Period             = 200;     // EMA period (Period ของเส้น EMA)
input bool   StrictBuyFilter        = false;   // Lock Buy side: block Buy when price is below EMA (ล็อคฝั่ง Buy ห้ามเปิดหากราคาต่ำกว่า EMA)
input bool   StrictSellFilter       = false;   // Lock Sell side: block Sell when price is above EMA (ล็อคฝั่ง Sell ห้ามเปิดหากราคาเหนือ EMA)
input bool   UseMTFFilter          = false;   // Enable higher-timeframe trend filter (set MTF_Period higher than the chart's actual timeframe, otherwise it duplicates the main EMA filter) (เปิดตัวกรองเทรนด์จาก Timeframe สูงกว่า ตั้ง MTF_Period ให้สูงกว่ากราฟจริง ไม่งั้นจะซ้ำกับ EMA filter)
input ENUM_TIMEFRAMES MTF_Period   = PERIOD_H1; // Timeframe used for the higher-TF trend filter (Timeframe ที่ใช้กรองเทรนด์หลัก)

input group "===== 5. Lot Size & Capital Protection (ขนาด Lot & ป้องกันทุน) ====="
input bool   UseDynamicLot          = false;   // Enable automatic lot sizing based on Equity (เปิดใช้งานการคำนวณ Lot อัตโนมัติตาม Equity)
input double BalancePerLot          = 10000.0; // Equity amount per 0.01 lot (สัดส่วนเงิน Equity ต่อ Lot เริ่มต้น 0.01)
input bool   UseEquityLock          = false;   // Enable Equity Lock: stop opening new orders immediately if Equity falls below the limit (เปิดระบบล็อคพอร์ต หยุดเปิดไม้ใหม่หาก Equity ต่ำกว่ากำหนด)
input double MinEquityLimit         = 500.0;   // Minimum Equity limit - new orders stop below this (ขีดจำกัด Equity ขั้นต่ำ หากต่ำกว่านี้จะหยุดเปิดไม้ใหม่)
input bool   UseAutoReduceLot       = false;   // Enable automatic lot reduction when Drawdown rises (เปิดใช้งานระบบลดขนาด Lot อัตโนมัติเมื่อ Drawdown สูงขึ้น)
input double ReduceLotThresholdDD   = 5.0;     // Drawdown (%) threshold that halves the lot size (เปอร์เซ็นต์ Drawdown ที่เริ่มลดขนาด Lot ลงครึ่งหนึ่ง)

input group "===== 6. Max Drawdown Stop / Emergency Brake (เบรกฉุกเฉิน) ====="
input bool   UseMaxDDStop           = false;   // Enable emergency stop-loss when Max DD exceeds the limit (เปิดใช้งานระบบตัดขาดทุนฉุกเฉินเมื่อ Max DD เกินกำหนด)
input double MaxAllowedDD_USD       = 50.0;    // Maximum loss allowed in $ - closes everything immediately if exceeded (set 0 to disable this $ check) (ยอมให้ขาดทุนสูงสุดเป็นเงิน เกินแล้วปิดทิ้งทันที ตั้ง 0 เพื่อปิดการเช็คแบบเงิน)
input double MaxAllowedDD_Pct       = 10.0;    // Maximum loss allowed as % of peak Balance (set 0 to disable this % check) (ยอมให้ขาดทุนสูงสุดเป็น % จากยอด Balance สูงสุด ตั้ง 0 เพื่อปิดการเช็คแบบ %)
input bool   UseEmergencySL         = false;   // Attach a server-side emergency Stop Loss to every order, in case the EA/terminal disconnects - not a strategy SL, set very wide so it never triggers in normal trading (ติด SL ฉุกเฉินบนทุกไม้ server-side เผื่อ EA/เทอร์มินัลหลุด ตั้งกว้างมากไม่ให้ชนตอนเทรดปกติ)
input int    EmergencySL_Points     = 3000;    // Emergency SL distance from entry (points), auto-adjusted by m_multiplier (ระยะ SL ฉุกเฉินจากราคาเข้า ปรับตาม m_multiplier อัตโนมัติแล้ว)
input bool   UseTotalDDGuard        = false;   // Account-wide emergency brake: caps cumulative DD from the all-time peak Balance since the EA started (does not reset after each stop like MaxDDStop above) - prevents several losing episodes, each within MaxAllowedDD, from compounding into a much larger total loss (เบรกฉุกเฉินระดับพอร์ตรวม คุม DD สะสมจาก Peak Balance ตั้งแต่เริ่ม EA ไม่ reset เหมือน MaxDDStop กันขาดทุนติดกันหลายรอบสะสมจนพอร์ตพัง)
input double MaxTotalDD_Pct         = 15.0;    // Maximum cumulative account DD (%) allowed - exceeding it closes everything and permanently halts new orders (restart the EA to resume) (DD สะสมสูงสุดของพอร์ตที่ยอมรับได้ เกินแล้วปิดทั้งหมดและหยุดเปิดไม้ใหม่ถาวร ต้อง restart EA เอง)

input group "===== 7. Position Management: Breakeven / Partial Close / Recovery Mode (แก้ไม้) ====="
input bool   UseBasketBreakeven     = false;   // Enable Breakeven (move stop to lock in partial profit) (เปิดระบบขยับจุดคุ้มทุน ล็อคกำไรบางส่วน)
input double BreakevenTriggerUSD    = 10.0;    // Minimum profit ($) that activates Breakeven (กำไรขั้นต่ำที่จะเริ่มเปิดใช้งานระบบ Breakeven)
input double BreakevenLockUSD       = 3.0;     // Minimum profit ($) locked in if price retraces (กำไรขั้นต่ำที่ต้องเหลือล็อกไว้เมื่อราคาถอยกลับ)
input bool   UsePartialClose        = false;   // Enable Partial Close (take partial profit) (เปิดใช้งานระบบทยอยปิดทำกำไรบางส่วน)
input double PartialCloseProfitUSD  = 15.0;    // Profit ($) target that triggers a partial close (กำไรที่ถึงเป้าแล้วสั่งปิดบางส่วน)
input double PartialClosePercent    = 50.0;    // Percentage of the order volume to close, e.g. 50% (สัดส่วนเปอร์เซ็นต์ของออเดอร์ที่จะปิด)
input bool   UseRecoveryMode        = false;   // Enable Recovery Mode: boosts lot size to recover faster once Drawdown exceeds RecoveryDD_TriggerPercent (เปิดโหมดแก้ไม้ เร่งเก็บบาสเกตเมื่อ Drawdown สูงเกิน RecoveryDD_TriggerPercent)
input double RecoveryDD_TriggerPercent = 5.0;  // Minimum Drawdown (%) that activates the Recovery boost (below this, lot is calculated normally) (Drawdown ขั้นต่ำที่จะเริ่มเปิด Recovery Boost ต่ำกว่านี้ lot คำนวณตามปกติ)
input double RecoveryLotBoost          = 1.2;  // Extra lot multiplier applied while Recovery Mode is active (ตัวคูณ lot เพิ่มเติมตอน Recovery Mode ทำงาน)

input group "===== 8. Overflow: Level Unlock & Force Hedge (High DD / Prolonged Negative) (DD สูง / ติดลบนาน) ====="
input bool   UseLevelUnlock      = false;   // Enable Level Unlock: once either side (Buy or Sell) has filled every TotalLevels, allow that side to keep opening further levels until the basket reaches TargetProfit (grid execution auto-stops the instant target is reached anyway) - high risk, lot keeps growing per LotMultiplier, always pair with UseMaxDDStop (เปิดระบบปลดล็อคชั้นเพิ่ม เมื่อฝั่งใดฝั่งหนึ่งเต็ม TotalLevels เสี่ยงสูง ควรเปิด UseMaxDDStop คู่กันเสมอ)
input int    MaxUnlockedLevels   = 5;       // Maximum extra levels per side allowed beyond TotalLevels (0 = unlimited, very dangerous) (จำนวนชั้นเพิ่มสูงสุดต่อฝั่ง ตั้ง 0 = ไม่จำกัด อันตรายมาก)
input bool   UseForceHedgeOnDD          = false;  // Enable/disable force-opening the opposite side when DD is high (bypasses all EMA/MTF filters - the goal is to hedge the side a filter is currently blocking) (เปิด/ปิดบังคับเปิดไม้ฝั่งตรงข้ามเมื่อ DD สูง ข้าม filter ทั้งหมด)
input double ForceHedgeDD_TriggerPercent = 6.0;   // Minimum Drawdown (%) that force-opens the underweight side (Drawdown ขั้นต่ำที่จะบังคับเปิดไม้ฝั่งที่มีไม้น้อยกว่า)
input double ForceHedgeResetPercent      = 3.0;   // DD must drop below this before firing again (prevents spamming orders while DD stays elevated) (DD ต้องลดต่ำกว่านี้ก่อนถึงจะบังคับเปิดซ้ำได้ กัน spam ตอน DD ค้างสูง)
input double ForceHedgeLotMultiplier     = 1.0;   // Lot multiplier for the forced order, applied on top of that side's normal next-level lot (ตัวคูณ lot ของไม้ที่ถูกบังคับเปิด คูณทับ lot ปกติของระดับถัดไป)
input bool   UseForceHedgeOnTime        = false;  // Enable/disable force-opening a recovery order once the basket has been negative for too long (only looks at elapsed "time", ignores DD% entirely - can be used separately from or alongside Force Hedge on DD above, fires the same way with the same ForceHedgeLotMultiplier) (เปิด/ปิดบังคับเปิดไม้แก้เมื่อบาสเก็ตติดลบนานเกินกำหนด ดูแค่เวลา ไม่สน DD%)
input int    ForceHedgeTimeMinutes      = 30;     // Minutes the basket may stay continuously negative before force-opening the underweight side - repeats every N minutes while still negative (no need to flip positive first) until Buy/Sell balance out or hit the TotalLevels/Level Unlock cap (จำนวนนาทีที่ยอมให้บาสเก็ตติดลบต่อเนื่องก่อนบังคับเปิดไม้แก้ ยิงซ้ำได้ทุก N นาทีถ้ายังติดลบไม่หยุด)

input group "===== 9. Gap / Slippage Protection (ป้องกัน Gap / Slippage) ====="
input bool   UseGapProtection    = false;  // Enable/disable the price gap check (เปิด/ปิดการเช็ค Gap ราคาโดด)
input int    MaxAllowedGapPoints = 100;    // Maximum gap tolerated (points) - a bigger jump triggers a reset, but only counts as a genuine gap when it's also been longer than GapDetectionSeconds since the last tick (prevents a strong continuous trend from being mistaken for a gap on every tick and never opening another order) (Gap ยอมรับได้สูงสุด เกินแล้ว Reset แต่นับเป็น Gap จริงก็ต่อเมื่อห่างจากทิคก่อนหน้าเกิน GapDetectionSeconds ด้วย)
input int    GapDetectionSeconds = 60;     // Seconds with zero ticks required to count as a genuine gap (e.g. price jumping over a holiday/weekend) - if ticks keep arriving continuously (a fast market, not a real break), it's not treated as a gap and orders open normally even beyond MaxAllowedGapPoints (ระยะเวลาที่ไม่มีทิคเข้ามาเลยถึงจะถือว่าเป็น Gap จริง ถ้าทิคยังเข้ามาต่อเนื่องจะไม่ถือเป็น Gap)
input int    MaxSlippagePoints   = 20;     // Maximum slippage allowed (points), 20-30 recommended for reliable fills (ล็อค Slippage สูงสุด แนะนำ 20-30)
input int    MaxSpreadAllowed    = 40;     // Maximum spread allowed to open an order, points (Virtual Mode) (สเปรดสูงสุดที่อนุญาตให้เปิดไม้)

input group "===== 10. Dashboard UI Colors (สี Dashboard UI) ====="
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

   // 2. SYSTEM STATUS PANEL (Force Hedge / Level Unlock / Basket Stats)
   int SysY = Y + 270;
   CreatePanel(UI_PREFIX+"SysBG", X_Right, SysY, PanelW, 200, UI_PanelBG, UI_PanelBG);
   CreateLabel(UI_PREFIX+"SysTitle", X_Right+12, SysY+6, GetUIString("สถานะระบบเสริม (SYSTEM STATUS)", "SYSTEM STATUS"), 8, UI_Accent);

   int sysY = SysY + 26;
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

   int barWidth = (int)(362 * percent);
   ObjectSetInteger(0, UI_PREFIX+"Prog_Fill", OBJPROP_XSIZE, barWidth);

   if(percent >= 1.0) ObjectSetInteger(0, UI_PREFIX+"Prog_Fill", OBJPROP_BGCOLOR, clrOrange);
   else ObjectSetInteger(0, UI_PREFIX+"Prog_Fill", OBJPROP_BGCOLOR, UI_Accent);

   ObjectSetString(0, UI_PREFIX+"Prog_Pct", OBJPROP_TEXT, IntegerToString((int)(percent * 100)) + "%");

   bool timeAllowed = IsTradingAllowedByTime();

   if(TradingHalted) {
      ObjectSetInteger(0, UI_PREFIX+"LED_Icon", OBJPROP_COLOR, UI_Loss);
      ObjectSetString(0, UI_PREFIX+"LED_Text", OBJPROP_TEXT, GetUIString("หยุดถาวร (TOTAL DD GUARD)", "HALTED (TOTAL DD GUARD)"));
   } else if(IsClosingState) {
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
